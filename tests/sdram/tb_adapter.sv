// =============================================================================
// PHANTOM-32  ──  SDRAM adapter self-test (32-bit single access over a burst)
// =============================================================================
// adapter + sdram_ctrl(BURST_LEN=2) + behavioural model.  Drives the CPU-side
// single-access port and checks:
//   - a full 32-bit word write then read back
//   - a single-byte masked write (dqm) leaves the other 3 bytes intact
//   - a halfword masked write touches only the upper 16 bits
// Prints "Result: 1" if every read matches.
// =============================================================================
module tb_adapter (
  input logic clk,
  input logic resetn
);

  localparam logic [31:0] X = 32'h0000_0040;

  // ── CPU-side ────────────────────────────────────────────────────────────────
  logic [31:0] cpu_addr, cpu_wdata, cpu_rdata;
  logic        cpu_req, cpu_we, cpu_ready;
  logic [3:0]  cpu_be;

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

  sdram_adapter u_adapt (
    .clk(clk), .resetn(resetn),
    .cpu_addr(cpu_addr), .cpu_req(cpu_req), .cpu_we(cpu_we),
    .cpu_wdata(cpu_wdata), .cpu_be(cpu_be), .cpu_rdata(cpu_rdata), .cpu_ready(cpu_ready),
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
    .CAS_LATENCY(2), .BURST_LEN(2)
  ) u_model (
    .clk(clk), .cke(cke), .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n),
    .ba(ba), .a(a), .dqm(dqm), .dq_in(dq_c2m), .dq_oe(dq_oe), .dq_out(dq_m2c)
  );

  // ── Op sequence (combinational, keyed on step) ──────────────────────────────
  logic [2:0]  step;
  logic [31:0] exp_rdata;
  always_comb begin
    cpu_addr  = X;
    cpu_we    = 1'b0;  cpu_wdata = 32'd0;  cpu_be = 4'b0000;  exp_rdata = 32'd0;
    case (step)
      3'd0: begin cpu_we=1; cpu_wdata=32'hAABBCCDD; cpu_be=4'b1111; end // full word
      3'd1: begin                                   exp_rdata=32'hAABBCCDD; end
      3'd2: begin cpu_we=1; cpu_wdata=32'h0000_3300; cpu_be=4'b0010; end // byte1 only
      3'd3: begin                                   exp_rdata=32'hAABB33DD; end
      3'd4: begin cpu_we=1; cpu_wdata=32'h9988_0000; cpu_be=4'b1100; end // upper half
      3'd5: begin                                   exp_rdata=32'h998833DD; end
      default: ;
    endcase
  end

  typedef enum logic [1:0] { RUN, GAP, FINISH } ds_t;
  ds_t  ds;
  logic fail;

  assign cpu_req = (ds == RUN);

  always_ff @(posedge clk) begin
    if (!resetn) begin
      step <= 3'd0; ds <= RUN; fail <= 1'b0;
    end else begin
      case (ds)
        RUN: if (cpu_ready) begin
          if (!cpu_we) begin
            $display("  step %0d: read 0x%08h  exp 0x%08h  %s",
                     step, cpu_rdata, exp_rdata, (cpu_rdata == exp_rdata) ? "OK" : "BAD");
            if (cpu_rdata != exp_rdata) fail <= 1'b1;
          end else begin
            $display("  step %0d: write be=%b data=0x%08h", step, cpu_be, cpu_wdata);
          end
          ds <= GAP;
        end
        GAP: begin
          if (step == 3'd5) ds <= FINISH;
          else begin step <= step + 3'd1; ds <= RUN; end
        end
        FINISH: begin
          $display("SDRAM adapter self-test.  Result: %h", fail ? 32'h0 : 32'h1);
          $finish;
        end
        default: ds <= FINISH;
      endcase
    end
  end

endmodule
