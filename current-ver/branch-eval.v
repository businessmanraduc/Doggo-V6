`include "isa.vh"

// =============================================================================
// PHANTOM-32  ──  Branch Taken Evaluator
// =============================================================================
// Pure combinational comparison unit for branch condition evaluation.
// Used in EX stage to determine if a branch should be taken.
//
// Supports all 6 RV32I branch conditions:
//   BEQ, BNE, BLT, BGE, BLTU, BGEU
//
// Also used by compressed branches (C.BEQZ, C.BNEZ) - same comparison logic.
// =============================================================================
module branch_eval (
  input wire [31:0] rs1_data,
  input wire [31:0] rs2_data,
  input wire [2:0]  branch_type,
  output reg        branch_taken
);

  always @(*) begin
    case (branch_type)
      `F3_BEQ:  branch_taken = (rs1_data == rs2_data);
      `F3_BNE:  branch_taken = (rs1_data != rs2_data);
      `F3_BLT:  branch_taken = ($signed(rs1_data) <  $signed(rs2_data));
      `F3_BGE:  branch_taken = ($signed(rs1_data) >= $signed(rs2_data));
      `F3_BLTU: branch_taken = (rs1_data <  rs2_data);
      `F3_BGEU: branch_taken = (rs1_data >= rs2_data);
      default:  branch_taken = 1'b0;
    endcase
  end

endmodule
