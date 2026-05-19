// =============================================================================
// PHANTOM-32  ──  Gowin BSRAM Behavioral Simulation Models
// =============================================================================
// Provides behavioral models for Gowin BSRAM primitives used in cpu.sv.
// This file is ONLY for Verilator elaboration - never passed to Gowin IDE,
// which provides its own native primitive library.
//
// Both models implement READ_MODE=0 (bypass mode):
//   Address is latched into an internal MAR on the rising clock edge.
//   Data output is combinational from the MAR, giving 1-cycle read latency.
//   This matches the IMEM and DMEM timing contracts in phantom_core.
// =============================================================================


// =============================================================================
// DPB  ──  True Dual-Port BSRAM
// =============================================================================
// IMEM configuration: 16-bit × 4096, both ports read-only (WREA=WREB=0).
// Write ports are modeled but never exercised in this configuration.
// =============================================================================
module DPB #(
  /* verilator lint_off UNUSEDPARAM */
  parameter         READ_MODE0  = 1'b0,
  parameter         READ_MODE1  = 1'b0,
  parameter [1:0]   WRITE_MODE0 = 2'b00,
  parameter [1:0]   WRITE_MODE1 = 2'b00,
  parameter integer BIT_WIDTH_0 = 16,
  parameter integer BIT_WIDTH_1 = 16,
  parameter integer DEPTH_0     = 4096,
  parameter integer DEPTH_1     = 4096,
  parameter         RESET_MODE  = "SYNC",
  parameter         INIT_FILE   = ""
  /* verilator lint_on  UNUSEDPARAM */
) (
  // ── Port A ─────────────────────────────────────────────────────────────────
  input logic         CLKA,
  input logic         CEA,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic        OCEA,    // output register clock enable - READ_MODE=1 only
  /* verilator lint_on  UNUSEDSIGNAL */
  input  logic        RESETA,
  input  logic        WREA,
  input  logic [11:0] ADA,
  input  logic [15:0] DIA,
  output logic [15:0] DOA,
  // ── Port B ─────────────────────────────────────────────────────────────────
  input  logic        CLKB,
  input  logic        CEB,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic        OCEB,    // output register clock enable - READ_MODE=1 only
  /* verilator lint_on  UNUSEDSIGNAL */
  input  logic        RESETB,
  input  logic        WREB,
  input  logic [11:0] ADB,
  input  logic [15:0] DIB,
  output logic [15:0] DOB
);

  logic [15:0] mem [0:4095];

  // ── Port A: MAR latch, optional write, combinational read ──────────────────
  logic [11:0] mar_a;
  always_ff @(posedge CLKA) begin
    if (RESETA)   begin mar_a <= 12'd0; end
    else if (CEA) begin
      mar_a <= ADA;
      if (WREA) mem[ADA] <= DIA;
    end
  end
  assign DOA = mem[mar_a];

  // ── Port B: MAR latch, optional write, combinational read ──────────────────
  logic [11:0] mar_b;
  always_ff @(posedge CLKB) begin
    if (RESETB)   begin mar_b <= 12'd0; end
    else if (CEB) begin
      mar_b <= ADB;
      if (WREB) mem[ADB] <= DIB;
    end
  end
  assign DOB = mem[mar_b];

endmodule


// =============================================================================
// SDPB  ──  Semi-Dual-Port BSRAM
// =============================================================================
// DMEM configuration: 8-bit × 1024, Port A write / Port B read.
// Four instances generated in cpu.sv - one per byte lane.
// =============================================================================
module SDPB #(
  /* verilator lint_off UNUSEDPARAM */
  parameter         READ_MODE   = 1'b0,
  parameter integer BIT_WIDTH_0 = 8,
  parameter integer BIT_WIDTH_1 = 8,
  parameter integer DEPTH       = 1024,
  parameter         RESET_MODE  = "SYNC"
  /* verilator lint_on  UNUSEDPARAM */
) (
  // ── Port A  (write) ────────────────────────────────────────────────────────
  input  logic       CLKA,
  input  logic       CEA,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic       RESETA,   // Port A reset - not modeled; tied to 0 in cpu.sv
  /* verilator lint_on  UNUSEDSIGNAL */
  input  logic       WREA,
  input  logic [9:0] ADA,
  input  logic [7:0] DIA,
  // ── Port B  (read) ─────────────────────────────────────────────────────────
  input  logic       CLKB,
  input  logic       CEB,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic       OCEB,    // output register clock enable - READ_MODE=1 only
  /* verilator lint_on  UNUSEDSIGNAL */
  input  logic       RESETB,
  input  logic [9:0] ADB,
  output logic [7:0] DOB
);

  logic [7:0] mem [0:1023];

  // ── Port A: synchronous write ──────────────────────────────────────────────
  always_ff @(posedge CLKA) begin
    if (CEA && WREA) mem[ADA] <= DIA;
  end

  // ── Port B: MAR latch and combinational read ───────────────────────────────
  logic [9:0] mar_b;
  always_ff @(posedge CLKB) begin
    if (RESETB)   mar_b <= 10'd0;
    else if (CEB) mar_b <= ADB;
  end
  assign DOB = mem[mar_b];

endmodule


