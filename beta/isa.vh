`ifndef ISA_VH
`define ISA_VH
// =============================================================================
// PHANTOM-16 ISA
// =============================================================================
// 16-bit fixed-width instructions, word-addressed memory.
// 8 general-purpose registers: R0 (always zero) through R7.
//
// Instruction formats:
//
//  R-type  [ADD SUB AND OR XOR SHL SHR]
//   15:12  11:9  8:6   5:3   2:0
//   opcode  rd   rs1   rs2  unused
//
//  I-type  [ADDI LW JALR]
//   15:12  11:9  8:6   5:0
//   opcode  rd   rs1   imm6 (signed)
//
//  S-type  [SW]
//   15:12  11:9  8:6   5:0
//   opcode  rs2  rs1   imm6 (signed)    mem[rs1 + imm6] = rs2
//
//  B-type  [BEQ BNE]
//   15:12  11:9  8:6   5:0
//   opcode  rs2  rs1   imm6 (signed)    if cond: PC = (PC+1) + imm6
//
//  J-type  [JMP]
//   15:12  11:9  8:0
//   opcode  rd   imm9 (signed)          PC = (PC+1) + imm9 ; rd = PC+1
//
//  U-type  [LI]
//   15:12  11:9  8:0
//   opcode  rd   imm9 (zero-extended)   rd = imm9
//
//  SYS     [NOP / HALT]
//   15:12  11:0
//   1111   0x000  → NOP
//   1111   0x001  → HALT
// =============================================================================

// ── Opcodes (4-bit field [15:12]) ─────────────────────────────────────────────
`define OP_ADD   4'h0    // R   rd = rs1 + rs2
`define OP_SUB   4'h1    // R   rd = rs1 - rs2
`define OP_AND   4'h2    // R   rd = rs1 & rs2
`define OP_OR    4'h3    // R   rd = rs1 | rs2
`define OP_XOR   4'h4    // R   rd = rs1 ^ rs2
`define OP_SHL   4'h5    // R   rd = rs1 << rs2[3:0]
`define OP_SHR   4'h6    // R   rd = rs1 >> rs2[3:0]
`define OP_ADDI  4'h7    // I   rd = rs1 + sext(imm6)
`define OP_LW    4'h8    // I   rd = mem[rs1 + sext(imm6)]
`define OP_SW    4'h9    // S   mem[rs1 + sext(imm6)] = rs2
`define OP_BEQ   4'hA    // B   if rs1 == rs2 : PC += sext(imm6)
`define OP_BNE   4'hB    // B   if rs1 != rs2 : PC += sext(imm6)
`define OP_JMP   4'hC    // J   PC += sext(imm9) ; rd = PC+1
`define OP_LI    4'hD    // U   rd = zext(imm9)
`define OP_JALR  4'hE    // I   rd = PC+1 ; PC = rs1 + sext(imm6)
`define OP_SYS   4'hF    // SYS [11:0]==0→NOP  [11:0]==1→HALT

// ── Internal ALU operation codes ──────────────────────────────────────────────
`define ALU_ADD   3'd0
`define ALU_SUB   3'd1
`define ALU_AND   3'd2
`define ALU_OR    3'd3
`define ALU_XOR   3'd4
`define ALU_SHL   3'd5
`define ALU_SHR   3'd6
`define ALU_PASS  3'd7    // result = B operand unchanged (used by LI)

// ── Canonical NOP encoding ────────────────────────────────────────────────────
`define NOP_INSTR  16'hF000   // SYS with imm = 0

`endif
