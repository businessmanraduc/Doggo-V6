`include "isa.vh"

// =============================================================================
// PHANTOM-32  ──  Branch Target Evaluator
// =============================================================================
// Pure combinational comparison unit for branch target evaluation.
// Used in EX stage to determine the targeted address for a branch.
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
        : ((pc       + immediate) & 32'hFFFFFFFE);

endmodule

