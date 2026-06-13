// =============================================================================
// PHANTOM-32  ──  SDRAM controller v2 self-test (burst read/write)
// =============================================================================
// Writes N bursts of BURST_LEN words with a known pattern, reads them back,
// compares. Prints "Result: 1" if every word matches.
// =============================================================================
module tb_sdram (
  input logic clk,
  input logic resetn
);

  localparam int BURST_LEN = 8;
  localparam int N_BURSTS  = 4;
  localparam int TOTAL     = N_BURSTS * BURST_LEN;
  localparam logic [23:0] BASE       = 24'h000040;
  localparam logic [7:0]  LAST_BURST = 8'(N_BURSTS-1);
  localparam logic [7:0]  TOTAL_8    = 8'(TOTAL);

  logic [23:0] u_addr;
  logic        u_we, u_req, u_ready;
  logic [15:0] u_rdata;
  logic        u_rvalid;
  logic [2:0]  u_wbeat;
  /* verilator lint_off UNUSEDSIGNAL */
  logic        u_wstrobe;
  /* verilator lint_on  UNUSEDSIGNAL */
  logic [15:0] u_wdata;

  logic        cke, cs_n, ras_n, cas_n, we_n;
  logic [1:0]  ba, dqm;
  logic [12:0] a;
  logic [15:0] dq_c2m, dq_m2c;
  logic        dq_oe;

  sdram_ctrl #(
    .BURST_LEN   (BURST_LEN),
    .INIT_CYCLES (16),
    .REFRESH_CYC (200)
  ) u_ctrl (
    .clk(clk), .resetn(resetn),
    .u_addr(u_addr), .u_we(u_we), .u_req(u_req), .u_ready(u_ready),
    .u_rdata(u_rdata), .u_rvalid(u_rvalid),
    .u_wbeat(u_wbeat), .u_wstrobe(u_wstrobe), .u_wdata(u_wdata), .u_wdqm(2'b00),
    .sdram_cke(cke), .sdram_cs_n(cs_n), .sdram_ras_n(ras_n),
    .sdram_cas_n(cas_n), .sdram_we_n(we_n), .sdram_ba(ba), .sdram_a(a),
    .sdram_dqm(dqm), .sdram_dq_out(dq_c2m), .sdram_dq_oe(dq_oe), .sdram_dq_in(dq_m2c)
  );

  sdram_model #(
    .CAS_LATENCY(2), .BURST_LEN(BURST_LEN)
  ) u_model (
    .clk(clk), .cke(cke), .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n),
    .ba(ba), .a(a), .dqm(dqm), .dq_in(dq_c2m), .dq_oe(dq_oe), .dq_out(dq_m2c)
  );

  // Known-answer pattern keyed on absolute word address.
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic [15:0] patt(input [23:0] addr);
    patt = 16'h1234 + (addr[15:0] * 16'h0007);
  endfunction
  /* verilator lint_on  UNUSEDSIGNAL */

  typedef enum logic [2:0] { T_INIT, T_WREQ, T_WBUSY, T_RREQ, T_RBUSY, T_DONE } tstate_t;
  tstate_t     tstate;
  logic [7:0]  burst_idx;     // which burst (0..N_BURSTS-1)
  logic [3:0]  rbeat;         // read beat counter within a burst
  logic [7:0]  pass_cnt;

  logic [23:0] cur_addr;
  assign cur_addr = BASE + 24'(burst_idx) * 24'(BURST_LEN);

  assign u_req   = (tstate == T_WREQ) || (tstate == T_RREQ);
  assign u_we    = (tstate == T_WREQ);
  assign u_addr  = cur_addr;
  assign u_wdata = patt(cur_addr + 24'(u_wbeat));

  always_ff @(posedge clk) begin
    if (!resetn) begin
      tstate <= T_INIT; burst_idx <= 8'd0; rbeat <= 4'd0; pass_cnt <= 8'd0;
    end else begin
      case (tstate)
        T_INIT: if (u_ready) begin burst_idx <= 8'd0; tstate <= T_WREQ; end

        T_WREQ:  if (u_ready) tstate <= T_WBUSY;
        T_WBUSY: if (u_ready) begin
          if (burst_idx == LAST_BURST) begin burst_idx <= 8'd0; tstate <= T_RREQ; end
          else                          begin burst_idx <= burst_idx + 8'd1; tstate <= T_WREQ; end
        end

        T_RREQ:  if (u_ready) begin rbeat <= 4'd0; tstate <= T_RBUSY; end
        T_RBUSY: begin
          if (u_rvalid) begin
            if (u_rdata == patt(cur_addr + 24'(rbeat))) pass_cnt <= pass_cnt + 8'd1;
            $display("  rd addr=0x%06h beat=%0d got=0x%04h exp=0x%04h %s",
                     cur_addr + 24'(rbeat), rbeat, u_rdata, patt(cur_addr + 24'(rbeat)),
                     (u_rdata == patt(cur_addr + 24'(rbeat))) ? "OK" : "BAD");
            rbeat <= rbeat + 4'd1;
          end
          if (u_ready) begin
            if (burst_idx == LAST_BURST) tstate <= T_DONE;
            else begin burst_idx <= burst_idx + 8'd1; tstate <= T_RREQ; end
          end
        end

        T_DONE: begin
          $display("SDRAM v2 burst self-test: %0d/%0d words OK.  Result: %h",
                   pass_cnt, TOTAL, (pass_cnt == TOTAL_8) ? 32'h1 : 32'h0);
          $finish;
        end
        default: tstate <= T_INIT;
      endcase
    end
  end

endmodule
