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
  input  wire [31:0] pc,
  input  wire [31:0] rs1_data,
  input  wire [31:0] immediate,
  input  wire        is_jalr,
  output wire [31:0] target_addr
);

  assign target_addr = (is_jalr)
        ? ((rs1_data + immediate) & 32'hFFFFFFFE)
        : ((pc       + immediate) & 32'hFFFFFFFF);

endmodule

