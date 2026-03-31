`include "isa.vh"
// =============================================================================
// PHANTOM-32  ──  ALU
// =============================================================================
// Purely combinational: no clock, no state, no side effects.
// Inputs change → outputs settle within one combinational delay.
// The result is captured by the EX/MA pipeline register (StageV_) on
// the next rising clock edge.
//
// Branch comparisons are NOT performed here.  The EX stage computes branch
// outcomes directly using Verilog comparison operators on the forwarded
// operand values.  This keeps the ALU clean and the critical path short.
//
// Port A is always the rs1 operand (after forwarding).
// Port B is either the rs2 operand or the sign-extended immediate, selected
// by the StageIV_ALUBSel control signal before this module is reached.
// =============================================================================
module alu (
  input  wire [31:0] a,        // operand A  (rs1, after forwarding mux)
  input  wire [31:0] b,        // operand B  (rs2 or immediate, after ALUBSel mux)
  input  wire [3:0]  op,       // operation select  (`ALU_* constants from isa.vh)
  output reg  [31:0] result    // computed result  (registered by pipeline on next edge)
);

  always @(*) begin
    case (op)
      // ── Arithmetic ─────────────────────────────────────────────────────────
      `ALU_ADD:    result = a + b;
      `ALU_SUB:    result = a - b;

      // ── Bitwise logic ───────────────────────────────────────────────────────
      `ALU_AND:    result = a & b;
      `ALU_OR:     result = a | b;
      `ALU_XOR:    result = a ^ b;

      // ── Shifts ─────────────────────────────────────────────────────────────
      `ALU_SLL:    result = a << b[4:0];
      `ALU_SRL:    result = a >> b[4:0];                  // logical: zero-fill
      `ALU_SRA:    result = $signed(a) >>> b[4:0];        // arithmetic: sign-fill

      // ── Set-if-less-than ────────────────────────────────────────────────────
      `ALU_SLT:    result = ($signed(a) < $signed(b)) ? 32'd1 : 32'd0;
      `ALU_SLTU:   result = (a < b)                   ? 32'd1 : 32'd0;

      // ── Pass-through ────────────────────────────────────────────────────────
      // Used by LUI: the upper immediate is already fully formed in B
      // (shifted left 12 by the immediate generator), so we just pass it
      // through.  Port A (rs1) is ignored by the control logic for LUI.
      `ALU_PASS_B: result = b;

      // ── Safe default ────────────────────────────────────────────────────────
      default:     result = 32'h0;
    endcase
  end

endmodule
