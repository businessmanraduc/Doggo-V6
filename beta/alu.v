`include "isa.vh"
// =============================================================================
// PHANTOM-16  ──  ALU
// =============================================================================
// Purely combinational: no clock, no state.
// Inputs change → outputs settle within one combinational delay.
// The result is captured by the EX/MEM pipeline register on the next edge.
//
// The `zero` flag is used by branch instructions:
//   BEQ  →  branch if zero  (rs1 - rs2 == 0  means rs1 == rs2)
//   BNE  →  branch if !zero (rs1 - rs2 != 0  means rs1 != rs2)
// =============================================================================
module alu (
  input  wire [15:0] a,        // operand A  (always from rs1 / forwarding mux)
  input  wire [15:0] b,        // operand B  (from rs2 or immediate)
  input  wire [2:0]  op,       // operation code  (`ALU_* constants)
  output reg  [15:0] result,   // computed result
  output wire        zero      // 1 when result == 0
);
  assign zero = (result == 16'h0);

  always @(*) begin
    case (op)
      `ALU_ADD:  result = a + b;
      `ALU_SUB:  result = a - b;
      `ALU_AND:  result = a & b;
      `ALU_OR:   result = a | b;
      `ALU_XOR:  result = a ^ b;
      `ALU_SHL:  result = a << b[3:0];    // shift amount: low 4 bits of b
      `ALU_SHR:  result = a >> b[3:0];
      `ALU_PASS: result = b;              // LI: pass immediate straight through
      default:   result = 16'h0;
    endcase
  end
endmodule
