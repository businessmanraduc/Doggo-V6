// =============================================================================
// PHANTOM-32  ──  SDRAM single-access adapter  (32-bit CPU  <->  16-bit burst)
// =============================================================================
// Turn one 32-bit CPU load/store into one 2-beat SDRAM burst
//
// Read:  fetch both halves, present {hi, lo} and pulse cpu_ready on 2nd beat.
// Write: split the word into two halves; sub-word stores (SB/SH) masked with
//        the controller's per-beat dqm (dqm = ~byte-enable). cpu_ready held
//        until the controller is fully idle.
module sdram_adapter (
  input  logic        clk,
  input  logic        resetn,

  // ── CPU side: one 32-bit access (only driven for the SDRAM region) ─────────
  input  logic [31:0] cpu_addr,     // byte offset within SDRAM
  input  logic        cpu_req,      // load/store to SDRAM in MA this cycle
  input  logic        cpu_we,       // 1 = store
  input  logic [31:0] cpu_wdata,
  input  logic [3:0]  cpu_be,       // byte enables
  output logic [31:0] cpu_rdata,    // assembled word (valid with cpu_ready)
  output logic        cpu_ready,    // 1 = access complete this cycle

  // ── Controller side (sdram_ctrl, BURST_LEN = 2) ────────────────────────────
  output logic [23:0] u_addr,
  output logic        u_we,
  output logic        u_req,
  input  logic        u_ready,
  input  logic [15:0] u_rdata,
  input  logic        u_rvalid,
  input  logic [2:0]  u_wbeat,
  input  logic        u_wstrobe,
  output logic [15:0] u_wdata,
  output logic [1:0]  u_wdqm
);

  typedef enum logic [1:0] { A_IDLE, A_RD, A_WR } astate_t;
  astate_t astate;

  logic [31:0] wdata_q;     // latched store data
  logic [3:0]  be_q;        // latched byte enables
  logic [15:0] rd_lo;       // captured low half of a read
  logic        rbeat;       // read beat index
  logic        wr_started;  // controller has gone busy

  // ── Combinational outputs ──────────────────────────────────────────────────
  always_comb begin
    u_req     = 1'b0;
    u_we      = cpu_we;
    u_addr    = cpu_addr[24:1];
    cpu_ready = 1'b0;
    cpu_rdata = {u_rdata, rd_lo};

    u_wdata   = (u_wbeat[0] == 1'b0) ? wdata_q[15:0] : wdata_q[31:16];
    u_wdqm    = (u_wbeat[0] == 1'b0) ? ~be_q[1:0]    : ~be_q[3:2];

    case (astate)
      A_IDLE: if (cpu_req    && u_ready)  u_req     = 1'b1; // kick off the burst
      A_RD:   if (u_rvalid   && rbeat)    cpu_ready = 1'b1; // 2nd beat -> done
      A_WR:   if (wr_started && u_ready)  cpu_ready = 1'b1; // controller idle -> done
      default: ;
    endcase
  end

  // ── Sequencer ───────────────────────────────────────────────────────────────
  always_ff @(posedge clk) begin
    if (!resetn) begin
      astate     <= A_IDLE;
      rbeat      <= 1'b0;
      wr_started <= 1'b0;
    end else begin
      case (astate)
        A_IDLE: begin
          if (cpu_req && u_ready) begin
            wdata_q    <= cpu_wdata;
            be_q       <= cpu_be;
            rbeat      <= 1'b0;
            wr_started <= 1'b0;
            astate     <= cpu_we ? A_WR : A_RD;
          end
        end

        A_RD: begin
          if (u_rvalid) begin
            if (!rbeat) begin rd_lo  <= u_rdata; rbeat <= 1'b1; end
            else        begin astate <= A_IDLE;                 end
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

