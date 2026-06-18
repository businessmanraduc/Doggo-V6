// =============================================================================
// PHANTOM-32  ──  SDRAM adapter  (32-bit CPU  <->  16-bit BL=8 burst)
// =============================================================================
// Turn a fixed 8-halfwords burst per Read/Write
//
// Read:
//    cpu_burst=0 (single-word data load):
//        issue burst, present word0, pulse cpu_ready on that word.
//    cpu_burst=1 (I-Cache line fill):
//        stream all 4 words, one cpu_rvalid pulse per word, cpu_ready on 4th
//        (last) word.
// Write (single-word): burst still runs 8 beats; beats 0/1 carry the word with
//        real dqm, beats 2..7 are masked.
module sdram_adapter (
  input  logic        clk,
  input  logic        resetn,

  // ── CPU side ───────────────────────────────────────────────────────────────
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:0] cpu_addr,     // byte offset within SDRAM
  /* verilator lint_on  UNUSEDSIGNAL */
  input  logic        cpu_req,      // access to SDRAM this cycle
  input  logic        cpu_we,       // 1 = store
  input  logic        cpu_burst,    // 1 = 4-word read burst (I-Cache fill)
  input  logic [31:0] cpu_wdata,
  input  logic [3:0]  cpu_be,       // byte enables
  output logic [31:0] cpu_rdata,    // current word (valid with cpu_rvalid/cpu_ready)
  output logic        cpu_rvalid,   // burst: one pulse per returned word
  output logic        cpu_ready,    // 1 = access complete this cycle

  // ── Controller side (sdram_ctrl, BURST_LEN = 8) ────────────────────────────
  output logic [23:0] u_addr,
  output logic        u_we,
  output logic        u_dbl,        // 1 = 2-burst (8-word) read for line fill
  output logic        u_req,
  input  logic        u_ready,
  input  logic [15:0] u_rdata,
  input  logic        u_rvalid,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [2:0]  u_wbeat,
  input  logic        u_wstrobe,
  /* verilator lint_on  UNUSEDSIGNAL */
  output logic [15:0] u_wdata,
  output logic [1:0]  u_wdqm
);

  typedef enum logic [1:0] { A_IDLE, A_RD, A_WR } astate_t;
  astate_t astate;

  logic [31:0] wdata_q;     // latched store data
  logic [3:0]  be_q;        // latched byte enables
  logic        burst_q;     // latched cpu_burst
  logic [15:0] rd_lo;       // captured low half of the word in flight
  logic [3:0]  rbeat;       // read beat index 0..15
  logic        wr_started;  // controller has gone busy (write)

  // ── Combinational outputs ──────────────────────────────────────────────────
  always_comb begin
    u_req      = 1'b0;
    u_we       = cpu_we;
    u_dbl      = cpu_burst;
    u_addr     = {cpu_addr[24:2], 1'b0};
    cpu_ready  = 1'b0;
    cpu_rvalid = 1'b0;
    cpu_rdata  = {u_rdata, rd_lo};

    u_wdata =
      (u_wbeat == 3'd0) ? wdata_q[15:0]  :
      (u_wbeat == 3'd1) ? wdata_q[31:16] :
    16'd0;
    u_wdqm  =
      (u_wbeat == 3'd0) ? ~be_q[1:0]     :
      (u_wbeat == 3'd1) ? ~be_q[3:2]     :
    2'b11;

    case (astate)
      A_IDLE: begin
        if (cpu_req  && u_ready) // kick off the burst
          u_req = 1'b1;
      end

      A_RD: begin
        if (u_rvalid && rbeat[0])
          cpu_rvalid = burst_q;
        if (u_rvalid && (burst_q ? (rbeat == 4'd15) : (rbeat == 4'd1)))
          cpu_ready = 1'b1;
      end

      A_WR: begin
        if (wr_started && u_ready)
          cpu_ready = 1'b1;
      end

      default: ;
    endcase
  end

  // ── Sequencer ───────────────────────────────────────────────────────────────
  always_ff @(posedge clk) begin
    if (!resetn) begin
      astate     <= A_IDLE;
      rbeat      <= 4'd0;
      wr_started <= 1'b0;
    end else begin
      case (astate)
        A_IDLE: begin
          if (cpu_req && u_ready) begin
            wdata_q    <= cpu_wdata;
            be_q       <= cpu_be;
            burst_q    <= cpu_burst;
            rbeat      <= 4'b0;
            wr_started <= 1'b0;
            astate     <= cpu_we ? A_WR : A_RD;
          end
        end

        A_RD: begin
          if (u_rvalid) begin
            if (!rbeat[0])
              rd_lo <= u_rdata;
            if (burst_q ? (rbeat == 4'd15) : (rbeat == 4'd1))
              astate <= A_IDLE;
            rbeat <= rbeat + 4'd1;
          end
        end

        A_WR: begin
          if (!u_ready)              wr_started <= 1'b1;
          if (wr_started && u_ready) astate     <= A_IDLE;
        end

        default: astate <= A_IDLE;
      endcase
    end
  end

endmodule

