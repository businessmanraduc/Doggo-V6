`include "isa.vh"
// =============================================================================
// PHANTOM-32  ──  Hazard Detection Unit
// =============================================================================
// Detects load-use data hazards and generates a one-cycle stall to prevent
// the instruction following a load from reading a stale register value.
//
// A load-use hazard occurs when:
//   1. The instruction in ID is a load (result not available until end of MA)
//   2. The instruction in IF reads the same register the load writes to
//
// =============================================================================
module hazard_unit (
  // ── From IF stage (fast_decoder, before IF/ID pipeline register) ──────────
  input  wire [4:0]  if_rs1_index,   // rs1 of instruction currently in IF
  input  wire [4:0]  if_rs2_index,   // rs2 of instruction currently in IF

  // ── From ID stage (instruction currently being decoded) ───────────────────
  input  wire [4:0]  id_rd_index,    // destination register of ID instruction
  input  wire        id_is_load,     // 1 = ID instruction is a load

  // ── Stall output ──────────────────────────────────────────────────────────
  output wire        stall           // 1 = write NOP to IF/ID (StageIII_), freeze PC + StageII_
);

  assign stall  = ((id_is_load)
               &&  (id_rd_index != 5'd0))
               && ((id_rd_index == if_rs1_index)
               ||  (id_rd_index == if_rs2_index));

endmodule
