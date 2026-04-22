`include "isa.vh"
// =============================================================================
// PHANTOM-32  ──  ALU
// =============================================================================
// Purely combinational arithmetic and logic unit.  No clock, no state.
// Inputs change → result settles within one combinational delay → captured
// by the EX/MA pipeline register on the next rising edge.
//
// Operand A: rs1 value (after forwarding)
// Operand B: rs2 or immediate (selected by ALUBSel mux before this module)
// Opcode:    4-bit operation select (`ALU_* constants from isa.vh)
//
// Branch comparisons are NOT here — the EX stage handles those directly
// with Verilog comparison operators to keep the critical path short.
// =============================================================================
module alu (
  input  wire [31:0] lhs,     // operand A  (rs1 or ProgramCounter, post-forwarding)
  input  wire [31:0] rhs,     // operand B  (rs2 or immediate, post-ALUBSel)
  input  wire [3:0]  op,      // operation select
  output reg  [31:0] result   // computed result
);

  always @(*) begin
    case (op)
      // ── Arithmetic ─────────────────────────────────────────────────────────
      `ALU_ADD:    result = lhs + rhs;                         // ADD, ADDI, AUIPC, loads, stores
      `ALU_SUB:    result = lhs - rhs;                         // SUB

      // ── Bitwise Logic ──────────────────────────────────────────────────────
      `ALU_AND:    result = lhs & rhs;                         // AND, ANDI
      `ALU_OR:     result = lhs | rhs;                         // OR, ORI
      `ALU_XOR:    result = lhs ^ rhs;                         // XOR, XORI

      // ── Shifts ─────────────────────────────────────────────────────────────
      `ALU_SLL:    result = lhs << rhs[4:0];                   // SLL, SLLI
      `ALU_SRL:    result = lhs >> rhs[4:0];                   // SRL, SRLI  (logical: zero-fill)
      `ALU_SRA:    result = $signed(lhs) >>> rhs[4:0];         // SRA, SRAI  (arithmetic: sign-fill)

      // ── Set-If-Less-Than ───────────────────────────────────────────────────
      `ALU_SLT:    result = ($signed(lhs) < $signed(rhs)) ? 32'd1 : 32'd0;  // SLT, SLTI
      `ALU_SLTU:   result = (lhs < rhs)                   ? 32'd1 : 32'd0;  // SLTU, SLTIU

      // ── Pass-Through ───────────────────────────────────────────────────────
      `ALU_PASS_B: result = rhs;                             // LUI (immediate already shifted)

      // ── Safe Default ───────────────────────────────────────────────────────
      default:     result = 32'hDEADBEEF;                  // illegal opcode sentinel
    endcase
  end

endmodule
