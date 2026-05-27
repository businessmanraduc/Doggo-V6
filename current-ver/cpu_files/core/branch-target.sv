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
  input  logic [31:0] rs1_data,
  input  logic [31:0] immediate,
  input  logic [31:0] immediate_2,
  input  logic        is_jalr,
  output logic [31:0] target_addr,
  output logic [31:0] target_addr_2
);

  assign target_addr   = (is_jalr)
        ? ((rs1_data + immediate)   & 32'hFFFFFFFE)
        : ((pc       + immediate)   & 32'hFFFFFFFF);

  assign target_addr_2 = (is_jalr)
        ? ((rs1_data + immediate_2) & 32'hFFFFFFFE)
        : ((pc       + immediate_2) & 32'hFFFFFFFF);

endmodule

