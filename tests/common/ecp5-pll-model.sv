// =============================================================================
// PHANTOM-32  ──  ECP5 EHXPLLL Behavioral Simulation Model
// =============================================================================
// Provides a behavioral stub for the Lattice ECP5 EHXPLLL primitive used in
// soc.sv. This file is ONLY for Verilator elaboration - never passed to
// nextpnr/prjtrellis, which provides its own native primitive library.
//
// Simulation behavior:
//   CLKOP = CLKI  (frequency multiplication is not modeled)
//   LOCK  = ~RST  (asserts immediately; PLL convergence is not modeled)
//
// This is sufficient for structural verification of soc.sv. The reset
// sequencer sees LOCK assert on the first cycle after RST deasserts, so
// cpu_resetn releases after 32 cpu_clk cycles - same as real hardware
// (PLL convergence is fast relative to the 32-cycle reset hold).
// =============================================================================
 
module EHXPLLL #(
  // Accepted for ECP5 primitive interface compatibility; not used in stub.
  /* verilator lint_off UNUSEDPARAM */
  parameter         PLLRST_ENA      = "DISABLED",
  parameter         INTFB_WAKE      = "DISABLED",
  parameter         STDBY_ENABLE    = "DISABLED",
  parameter         DPHASE_SOURCE   = "DISABLED",
  parameter         OUTDIVIDER_MUXA = "DIVA",
  parameter         OUTDIVIDER_MUXB = "DIVB",
  parameter         OUTDIVIDER_MUXC = "DIVC",
  parameter         OUTDIVIDER_MUXD = "DIVD",
  parameter integer CLKI_DIV        = 1,
  parameter         CLKOP_ENABLE    = "ENABLED",
  parameter integer CLKOP_DIV       = 12,
  parameter integer CLKOP_CPHASE    = 5,
  parameter integer CLKOP_FPHASE    = 0,
  parameter         CLKOS_ENABLE    = "DISABLED",
  parameter         CLKOS2_ENABLE   = "DISABLED",
  parameter         CLKOS3_ENABLE   = "DISABLED",
  parameter         FEEDBK_PATH     = "CLKOP",
  parameter integer CLKFB_DIV       = 1
  /* verilator lint_on  UNUSEDPARAM */
) (
  input  logic CLKI,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic CLKFB,
  /* verilator lint_on  UNUSEDSIGNAL */
  output logic CLKOP,
  output logic LOCK,
  // ── Secondary clock outputs (not used by PHANTOM-32) ──────────────────────
  output logic CLKOS,
  output logic CLKOS2,
  output logic CLKOS3,
  output logic INTLOCK,
  output logic REFCLK,
  output logic CLKINTFB,
  // ── Control inputs (hardware-tuning only; not modeled) ────────────────────
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic RST,
  input  logic STDBY,
  input  logic PHASESEL0,
  input  logic PHASESEL1,
  input  logic PHASEDIR,
  input  logic PHASESTEP,
  input  logic PHASELOADREG,
  input  logic PLLWAKESYNC,
  input  logic ENCLKOP,
  input  logic ENCLKOS,
  input  logic ENCLKOS2,
  input  logic ENCLKOS3
  /* verilator lint_on  UNUSEDSIGNAL */
);

  // CLKOP passes CLKIN through; frequency ratio is not modeled in simulation.
  // LOCK asserts as soon as RST is deasserted (convergence delay not modeled).
  // Secondary outputs are tied low - they are not used in PHANTOM-32.
  assign CLKOP    = CLKI;
  assign LOCK     = ~RST;
  assign CLKOS    = 1'b0;
  assign CLKOS2   = 1'b0;
  assign CLKOS3   = 1'b0;
  assign INTLOCK  = 1'b0;
  assign REFCLK   = 1'b0;
  assign CLKINTFB = 1'b0;

endmodule
