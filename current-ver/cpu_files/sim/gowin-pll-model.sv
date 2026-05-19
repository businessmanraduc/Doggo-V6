// =============================================================================
// PHANTOM-32  ──  Gowin rPLL Behavioral Simulation Model
// =============================================================================
// Provides a behavioral stub for the Gowin rPLL primitive used in soc.sv.
// This file is ONLY for Verilator elaboration - never passed to Gowin IDE,
// which provides its own native primitive library.
//
// Simulation behavior:
//   CLKOUT = CLKIN  (frequency multiplication is not modeled)
//   LOCK   = ~RESET (asserts immediately; PLL convergence is not modeled)
//
// This is sufficient for structural verification and simulation of soc.sv.
// The reset sequencer will see LOCK assert on the first cycle after RESET
// deasserts, so the cpu will come out of reset after 32 clock cycles - the
// same behavior as on real hardware (PLL convergence is fast relative to the
// 32-cycle reset hold).
// =============================================================================

module rPLL #(
  // Accepted for Gowin primitive interface compatibility; not used in the stub.
  /* verilator lint_off UNUSEDPARAM */
  parameter         FCLKIN    = "27",
  parameter         DEVICE    = "GW2AR-18C",
  parameter integer IDIV_SEL  = 0,
  parameter integer FBDIV_SEL = 0,
  parameter integer ODIV_SEL  = 8
  /* verilator lint_on  UNUSEDPARAM */
) (
  input  logic       CLKIN,
  output logic       CLKOUT,
  output logic       LOCK,
  input  logic       RESET,
  // ── Ports only relevant to Gowin hardware tuning; not modeled ───────────────
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic       RESET_P,
  input  logic       CLKFB,
  input  logic [5:0] FBDSEL,
  input  logic [5:0] IDSEL,
  input  logic [5:0] ODSEL,
  input  logic [3:0] PSDA,
  input  logic [3:0] DUTYDA,
  input  logic [3:0] FDLY
  /* verilator lint_on  UNUSEDSIGNAL */
);

  // CLKOUT passes CLKIN through; frequency ratio is not modeled in simulation.
  // LOCK asserts as soon as RESET is deasserted (convergence not modeled).
  assign CLKOUT = CLKIN;
  assign LOCK   = ~RESET;

endmodule
