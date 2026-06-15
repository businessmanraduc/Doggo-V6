`include "isa.vh"
module tb_soc_icache (
  input logic clk,
  input logic resetn
);

  // ── CPU peripheral bus ──────────────────────────────────────────────────────
  logic [31:0] periph_addr, periph_wdata;
  logic        periph_we;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [3:0]  periph_be;
  /* verilator lint_on  UNUSEDSIGNAL */
  logic [31:0] periph_rdata;
  assign periph_rdata = 32'd0;

  // ── CPU SDRAM memory bus ────────────────────────────────────────────────────
  logic [31:0] mem_addr, mem_wdata, mem_rdata;
  logic        mem_req, mem_we, mem_ready;
  logic [3:0]  mem_be;

  cpu u_cpu (
    .clk          (clk),
    .resetn       (resetn),
    .irq_timer    (1'b0),
    .irq_soft     (1'b0),
    .irq_ext      (1'b0),
    .periph_addr  (periph_addr),
    .periph_wdata (periph_wdata),
    .periph_we    (periph_we),
    .periph_be    (periph_be),
    .periph_rdata (periph_rdata),
    .mem_addr     (mem_addr),
    .mem_req      (mem_req),
    .mem_we       (mem_we),
    .mem_wdata    (mem_wdata),
    .mem_be       (mem_be),
    .mem_rdata    (mem_rdata),
    .mem_ready    (mem_ready)
  );

  // ── adapter <-> controller ──────────────────────────────────────────────────
  logic [23:0] u_addr;
  logic        u_we, u_req, u_ready, u_rvalid, u_wstrobe;
  logic [15:0] u_rdata, u_wdata;
  logic [2:0]  u_wbeat;
  logic [1:0]  u_wdqm;

  // ── controller <-> model (SDRAM pins) ───────────────────────────────────────
  logic        cke, cs_n, ras_n, cas_n, we_n, dq_oe;
  logic [1:0]  ba, dqm;
  logic [12:0] a;
  logic [15:0] dq_c2m, dq_m2c;

  sdram_adapter u_adapter (
    .clk(clk), .resetn(resetn),
    .cpu_addr(mem_addr), .cpu_req(mem_req), .cpu_we(mem_we),
    .cpu_wdata(mem_wdata), .cpu_be(mem_be),
    .cpu_rdata(mem_rdata), .cpu_ready(mem_ready),
    .u_addr(u_addr), .u_we(u_we), .u_req(u_req), .u_ready(u_ready),
    .u_rdata(u_rdata), .u_rvalid(u_rvalid),
    .u_wbeat(u_wbeat), .u_wstrobe(u_wstrobe), .u_wdata(u_wdata), .u_wdqm(u_wdqm)
  );

  sdram_ctrl #(
    .BURST_LEN(2), .INIT_CYCLES(16), .REFRESH_CYC(200)
  ) u_ctrl (
    .clk(clk), .resetn(resetn),
    .u_addr(u_addr), .u_we(u_we), .u_req(u_req), .u_ready(u_ready),
    .u_rdata(u_rdata), .u_rvalid(u_rvalid),
    .u_wbeat(u_wbeat), .u_wstrobe(u_wstrobe), .u_wdata(u_wdata), .u_wdqm(u_wdqm),
    .sdram_cke(cke), .sdram_cs_n(cs_n), .sdram_ras_n(ras_n),
    .sdram_cas_n(cas_n), .sdram_we_n(we_n), .sdram_ba(ba), .sdram_a(a),
    .sdram_dqm(dqm), .sdram_dq_out(dq_c2m), .sdram_dq_oe(dq_oe), .sdram_dq_in(dq_m2c)
  );

  sdram_model #(
    .CAS_LATENCY(2), .BURST_LEN(2), .INIT_FILE("prog.hex")
  ) u_model (
    .clk(clk), .cke(cke), .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n),
    .ba(ba), .a(a), .dqm(dqm), .dq_in(dq_c2m), .dq_oe(dq_oe), .dq_out(dq_m2c)
  );

  // ── Finish hook + watchdog ──────────────────────────────────────────────────
  logic [31:0] cyc;
  always_ff @(posedge clk) begin
    if (!resetn) cyc <= 32'd0;
    else         cyc <= cyc + 32'd1;

    if (resetn && periph_we && (periph_addr == 32'h8000_1000)) begin
      $display("SoC I-cache test Finished. Result: %h  (cycles=%0d)", periph_wdata, cyc);
      if (periph_wdata == 32'h0000_1356) $display("SOC ICACHE TEST: PASS");
      else                               $display("SOC ICACHE TEST: FAIL");
      $finish;
    end
    if (cyc == 32'd200000) begin
      $display("SOC ICACHE TEST: TIMEOUT (no result)");
      $finish;
    end
  end

endmodule
