`include "isa.vh"

// =============================================================================
// PHANTOM-32  ──  Branch Target Evaluator
// =============================================================================
// Computes the target address for all PC-redirecting instructions:
//   Branches (BEQ/BNE/BLT/BGE/BLTU/BGEU): PC + immediate
//   JAL:                                  PC + immediate
//   JALR:                                 (rs1 + immediate) & ~1
//
// The &~1 on JALR is mandated by the RISC-V spec to guarantee halfword
// alignment, clearing bit 0 regardless of the computed sum.
//
// Pure combinational - no state, no clock.
// =============================================================================
module branch_target (
  input  logic [31:0] pc,
  input  logic [31:0] pc2,
  input  logic [31:0] pc4,
  input  logic [31:0] rs1_data,
  input  logic [31:0] immediate,
  input  logic        is_jalr,
  input  logic        is_comp,
  output logic [31:0] below_addr,
  output logic [31:0] target_addr
);

  assign target_addr = (is_jalr)
    ? ((rs1_data + immediate) & 32'hFFFFFFFE)
    : ((pc       + immediate) & 32'hFFFFFFFF);
  assign below_addr  = is_comp ? pc2 : pc4;

endmodule

