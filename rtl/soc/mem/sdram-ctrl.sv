// =============================================================================
// PHANTOM-32  ──  SDR SDRAM Controller
// =============================================================================
// SDRAM Controller for the ULX3S onboard SDR SDRAM
// (W9825G6KH: 32MB, 16-bit, 4 banks, 8192 rows x 512 cols)
//
// DQ is split (out/oe/in) so it simulates cleanly; the hardware top merges
// the three into one real bidirectional `inout [15:0] pin.
//
// Address map (24-bit word address): [23:22]=bank [21:9]=row [8:0]=column
module sdram_ctrl #(
  parameter int BURST_LEN    = 8,     // words per transfer (1/2/4/8)
  parameter int INIT_CYCLES  = 20000, // power-up wait
  parameter int CAS_LATENCY  = 2,     // READ      -> first data word ready
  parameter int T_RCD        = 3,     // ACTIVE    -> READ/WRITE  (tRCD ~18ns)
  parameter int T_RP         = 3,     // PRECHARGE -> next ACTIVE (tRP  ~18ns)
  parameter int T_RFC        = 8,     // AUTO-REFRESH duration    (tRFC ~60ns)
  parameter int T_MRD        = 2,     // LOAD MODE REGISTER recovery
  parameter int T_WR         = 2,     // WRITE     -> PRECHARGE   (write recovery)
  parameter int REFRESH_CYC  = 750,   // issue refresh every N cycles
  parameter int INIT_REFRESH = 8      // noOfRefreshes in power-up
) (
  input  logic        clk,
  input  logic        resetn,

  // ── User port ───────────────────────────────────────────────────────────────
  input  logic [23:0] u_addr,         // base word address of burst
  input  logic        u_we,           // 1 = write burst, 0 = read burst
  input  logic        u_req,          // assert 1 cycle while u_ready is high
  output logic        u_ready,        // idle + init done

  // ── read result: BURST_LEN words, each flagged by a u_rvalid pulse, in order
  output logic [15:0] u_rdata,
  output logic        u_rvalid,

  // ── write source: when u_wstrobe is high, present the word for index u_wbeat
  output logic [2:0]  u_wbeat,
  output logic        u_wstrobe,
  input  logic [15:0] u_wdata,
  input  logic [1:0]  u_wdqm,         // per-beat byte mask

  // ── SDRAM pins ──────────────────────────────────────────────────────────────
  output logic        sdram_cke,
  output logic        sdram_cs_n,
  output logic        sdram_ras_n,
  output logic        sdram_cas_n,
  output logic        sdram_we_n,
  output logic [1:0]  sdram_ba,
  output logic [12:0] sdram_a,
  output logic [1:0]  sdram_dqm,
  output logic [15:0] sdram_dq_out,
  output logic        sdram_dq_oe,
  input  logic [15:0] sdram_dq_in
);

  localparam int BEAT_W = (BURST_LEN <= 1) ? 1 : $clog2(BURST_LEN);

  // ── Command encoding {cs_n, ras_n, cas_n, we_n} ─────────────────────────────
  localparam logic [3:0] CMD_DESELECT   = 4'b1111;
  localparam logic [3:0] CMD_NOP        = 4'b0111;
  localparam logic [3:0] CMD_ACTIVE     = 4'b0011;
  localparam logic [3:0] CMD_READ       = 4'b0101;
  localparam logic [3:0] CMD_WRITE      = 4'b0100;
  localparam logic [3:0] CMD_PRECHARGE  = 4'b0010;
  localparam logic [3:0] CMD_REFRESH    = 4'b0001;
  localparam logic [3:0] CMD_LOADMODE   = 4'b0000;

  // ── Mode register: burst length code, sequential, CAS latency ───────────────
  //   A[2:0] = log2(BURST_LEN) (000=1,001=2,010=4,011=8)  A[3]=0  A[6:4]=CL
  localparam logic [2:0] BL_CODE  = 3'(BEAT_W);
  localparam logic [12:0] MODE_REG = {3'b000, 1'b0, 2'b00, 3'(CAS_LATENCY), 1'b0, BL_CODE};

  logic [3:0] cmd;
  assign {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n} = cmd;
  assign sdram_cke = 1'b1;

  // ── State ───────────────────────────────────────────────────────────────────
  typedef enum logic [4:0] {
    S_INIT_WAIT, S_INIT_PRE, S_INIT_TRP, S_INIT_REF, S_INIT_TRFC,
    S_INIT_MODE, S_INIT_TMRD,
    S_IDLE, S_REF, S_REF_TRFC,
    S_WLOAD, S_ACT, S_TRCD, S_WR, S_RD, S_RD_CAS, S_RD_DATA, S_RECOVER
  } state_t;

  state_t      state;
  logic [15:0] wait_cnt;
  logic [15:0] refresh_timer;
  logic        refresh_due;
  logic [15:0] init_ref_cnt;
  logic [BEAT_W:0] beat;

  // Latched request
  logic [1:0]  req_bank;
  logic [12:0] req_row;
  logic [8:0]  req_col;
  logic        req_we;

  // Write data buffer (filled in S_WLOAD, streamed in S_WR)
  logic [15:0] wbuf   [0:BURST_LEN-1];
  logic [1:0]  dqmbuf [0:BURST_LEN-1];

  localparam logic [BEAT_W:0] LAST_BEAT = (BEAT_W+1)'(BURST_LEN-1);

  logic [12:0] col_addr;
  assign col_addr  = {2'b00, 1'b1, 1'b0, req_col};

  assign u_ready   = (state == S_IDLE) && !refresh_due;

  assign u_wstrobe = (state == S_WLOAD);
  assign u_wbeat   = 3'(beat);

  // ── Refresh timer ───────────────────────────────────────────────────────────
  always_ff @(posedge clk) begin
    if (!resetn) begin
      refresh_timer   <= 16'd0;
      refresh_due     <= 1'b0;
    end else begin
      if (refresh_timer >= REFRESH_CYC[15:0]) begin
        refresh_timer <= 16'd0;
        refresh_due   <= 1'b1;
      end else begin
        refresh_timer <= refresh_timer + 16'd1;
      end

      if (state == S_REF) begin
        refresh_due <= 1'b0;
      end
    end
  end

  // ── Main FSM ────────────────────────────────────────────────────────────────
  always_ff @(posedge clk) begin
    if (!resetn) begin
      state         <= S_INIT_WAIT;
      wait_cnt      <= INIT_CYCLES[15:0];
      cmd           <= CMD_NOP;
      sdram_a       <= 13'd0;
      sdram_ba      <= 2'd0;
      sdram_dq_out  <= 16'd0;
      sdram_dq_oe   <= 1'b0;
      sdram_dqm     <= 2'b00;
      u_rdata       <= 16'd0;
      u_rvalid      <= 1'b0;
      init_ref_cnt  <= INIT_REFRESH[15:0];
      beat          <= '0;
    end else begin
      cmd           <= CMD_NOP;
      sdram_dq_oe   <= 1'b0;
      sdram_dqm     <= 2'b00;
      u_rvalid      <= 1'b0;

      case (state)
        // ── Power-up ritual ───────────────────────────────────────────────────
        S_INIT_WAIT: begin
          cmd <= CMD_DESELECT;
          if (wait_cnt == 0) state <= S_INIT_PRE;
          else               wait_cnt <= wait_cnt - 16'd1;
        end
        S_INIT_PRE: begin
          cmd      <= CMD_PRECHARGE;
          sdram_a  <= 13'(1) << 10;          // A10=1 -> all banks
          wait_cnt <= T_RP[15:0];
          state    <= S_INIT_TRP;
        end
        S_INIT_TRP: begin
          if (wait_cnt == 0) begin wait_cnt <= T_RFC[15:0]; state <= S_INIT_REF; end
          else                 wait_cnt <= wait_cnt - 16'd1;
        end
        S_INIT_REF: begin
          cmd      <= CMD_REFRESH;
          wait_cnt <= T_RFC[15:0];
          state    <= S_INIT_TRFC;
        end
        S_INIT_TRFC: begin
          if (wait_cnt == 0) begin
            if (init_ref_cnt <= 16'd1) state <= S_INIT_MODE;
            else begin init_ref_cnt <= init_ref_cnt - 16'd1; state <= S_INIT_REF; end
          end else wait_cnt <= wait_cnt - 16'd1;
        end
        S_INIT_MODE: begin
          cmd      <= CMD_LOADMODE;
          sdram_a  <= MODE_REG;
          sdram_ba <= 2'd0;
          wait_cnt <= T_MRD[15:0];
          state    <= S_INIT_TMRD;
        end
        S_INIT_TMRD: begin
          if (wait_cnt == 0) state <= S_IDLE;
          else               wait_cnt <= wait_cnt - 16'd1;
        end

        // ── Idle ──────────────────────────────────────────────────────────────
        S_IDLE: begin
          beat <= '0;
          if (refresh_due) begin
            state <= S_REF;
          end else if (u_req) begin
            req_bank <= u_addr[23:22];
            req_row  <= u_addr[21:9];
            req_col  <= u_addr[8:0];
            req_we   <= u_we;
            state    <= u_we ? S_WLOAD : S_ACT;
          end
        end

        // ── Refresh ───────────────────────────────────────────────────────────
        S_REF: begin
          cmd      <= CMD_REFRESH;
          wait_cnt <= T_RFC[15:0];
          state    <= S_REF_TRFC;
        end
        S_REF_TRFC: begin
          if (wait_cnt == 0) state <= S_IDLE;
          else               wait_cnt <= wait_cnt - 16'd1;
        end

        // ── Write: pull the whole burst into wbuf first, then open the row ────
        S_WLOAD: begin
          wbuf[beat[BEAT_W-1:0]]   <= u_wdata;  // u_wbeat/u_wstrobe are combinational
          dqmbuf[beat[BEAT_W-1:0]] <= u_wdqm;
          if (beat == LAST_BEAT) begin beat <= '0; state <= S_ACT; end
          else                         beat <= beat + 1'b1;
        end

        // ── Open the row ──────────────────────────────────────────────────────
        S_ACT: begin
          cmd      <= CMD_ACTIVE;
          sdram_ba <= req_bank;
          sdram_a  <= req_row;
          wait_cnt <= T_RCD[15:0];
          state    <= S_TRCD;
        end
        S_TRCD: begin
          if (wait_cnt == 0) state <= req_we ? S_WR : S_RD;
          else               wait_cnt <= wait_cnt - 16'd1;
        end

        // ── Write burst: one WRITE command, then stream wbuf word per cycle ───
        S_WR: begin
          sdram_ba     <= req_bank;
          sdram_dq_out <= wbuf[beat[BEAT_W-1:0]];
          sdram_dq_oe  <= 1'b1;
          sdram_dqm    <= dqmbuf[beat[BEAT_W-1:0]];
          if (beat == 0) begin
            cmd     <= CMD_WRITE;     // command + first word on the same cycle
            sdram_a <= col_addr;      // A10=1 auto-precharge
          end
          if (beat == LAST_BEAT) begin
            beat     <= '0;
            wait_cnt <= T_WR[15:0] + T_RP[15:0];
            state    <= S_RECOVER;
          end else beat <= beat + 1'b1;
        end

        // ── Read burst: one READ command, wait CAS, then stream every word ────
        //    through one uniform capture path (no special-casing word 0, which
        //    is what caused an off-by-one between the first and later beats).
        S_RD: begin
          cmd      <= CMD_READ;
          sdram_ba <= req_bank;
          sdram_a  <= col_addr;       // A10=1 auto-precharge
          wait_cnt <= CAS_LATENCY[15:0] - 16'd1;
          beat     <= '0;
          state    <= S_RD_CAS;
        end
        S_RD_CAS: begin
          if (wait_cnt == 0) state <= S_RD_DATA;
          else               wait_cnt <= wait_cnt - 16'd1;
        end
        S_RD_DATA: begin
          u_rdata  <= sdram_dq_in;
          u_rvalid <= 1'b1;
          if (beat == LAST_BEAT) begin
            beat     <= '0;
            wait_cnt <= T_RP[15:0];
            state    <= S_RECOVER;
          end else beat <= beat + 1'b1;
        end

        S_RECOVER: begin
          if (wait_cnt == 0) state <= S_IDLE;
          else               wait_cnt <= wait_cnt - 16'd1;
        end

        default: state <= S_INIT_WAIT;
      endcase
    end
  end

endmodule

