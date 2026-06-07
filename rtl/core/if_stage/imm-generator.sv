`include "isa.vh"

// =============================================================================
// PHANTOM-32  ──  Immediate Generator
// =============================================================================
// Extracts and sign-extends immediate values from both 32-bit (RV32I) and
// 16-bit compressed (RV32C) instructions. Supports all immediate formats:
//
// RV32I formats:  I, S, B, U, J, shift-amount
// RV32C formats:  CI, CIW, CL, CS, CB, CJ, CSS (all quadrants)
//
// Outputs:
//   immediate   - The extracted immediate value (sign-extended where applicable)
//
// Pure combinational - no state, no clock. Decode paths run in parallel;
// output mux selects based on is_compressed flag.
// =============================================================================
module imm_generator (
  input  logic [31:0] instrWord,
  input  logic        is_compressed,
  output logic [31:0] immediate
);

  // ── 32-bit (RV32I) immediate layouts ───────────────────────────────────────
  logic [31:0] immTypeI; assign immTypeI = {{20{instrWord[31]}}, instrWord[31:20]};
  logic [31:0] immTypeS; assign immTypeS = {{20{instrWord[31]}}, instrWord[31:25], instrWord[11:7]};
  logic [31:0] immTypeB; assign immTypeB = {{19{instrWord[31]}}, instrWord[31], instrWord[7], instrWord[30:25], instrWord[11:8], 1'b0};
  logic [31:0] immTypeJ; assign immTypeJ = {{11{instrWord[31]}}, instrWord[31], instrWord[19:12], instrWord[20], instrWord[30:21], 1'b0};
  logic [31:0] immTypeU; assign immTypeU = {instrWord[31:12], 12'b0};

  // ── 16-bit (RV32C) immediate layouts ────────────────────────────────────────
  logic [31:0] immCLWSP; assign immCLWSP = {24'b0, instrWord[3:2], instrWord[12], instrWord[6:4], 2'b0};
  logic [31:0] immCSWSP; assign immCSWSP = {24'b0, instrWord[8:7], instrWord[12:9], 2'b0};
  logic [31:0] immC4SPN; assign immC4SPN = {22'b0, instrWord[10:7], instrWord[12:11], instrWord[5], instrWord[6], 2'b0};
  logic [31:0] immCLW;   assign immCLW   = {25'b0, instrWord[5], instrWord[12:10], instrWord[6], 2'b0};            // also C.SW
  logic [31:0] immCLI;   assign immCLI   = {{26{instrWord[12]}}, instrWord[12], instrWord[6:2]};                   // also C.ADDI/C.ANDI + shamts
  logic [31:0] immCLUI;  assign immCLUI  = {{14{instrWord[12]}}, instrWord[12], instrWord[6:2], 12'b0};
  logic [31:0] immC16SP; assign immC16SP = {{22{instrWord[12]}}, instrWord[12], instrWord[4:3], instrWord[5], instrWord[2], instrWord[6], 4'b0};
  logic [31:0] immCB;    assign immCB    = {{23{instrWord[12]}}, instrWord[12], instrWord[6:5], instrWord[2], instrWord[11:10], instrWord[4:3], 1'b0};
  logic [31:0] immCJ;    assign immCJ    = {{20{instrWord[12]}}, instrWord[12], instrWord[8], instrWord[10:9], instrWord[6], instrWord[7], instrWord[2], instrWord[11], instrWord[5:3], 1'b0};

  // ── Selectors ───────────────────────────────────────────────────────────────
  logic [6:0] opcode; assign opcode = instrWord[6:0];
  logic [4:0] ckey;   assign ckey   = {instrWord[1:0], instrWord[15:13]};   // {quadrant, funct3}

  logic [31:0] imm32;
  logic [31:0] imm16;

  // ── 32-bit select: one flat case on the primary opcode ──────────────────────
  always_comb begin
    case (opcode)
      `OP_LUI, `OP_AUIPC:              imm32 = immTypeU;
      `OP_JAL:                         imm32 = immTypeJ;
      `OP_BRANCH:                      imm32 = immTypeB;
      `OP_STORE:                       imm32 = immTypeS;
      `OP_JALR, `OP_LOAD, `OP_ARITH_I: imm32 = immTypeI;
      default:                         imm32 = 32'b0;
    endcase
  end

  // ── 16-bit select: one flat case keyed by {quadrant, funct3} ────────────────
  always_comb begin
    case (ckey)
      {`CQ0, `CF3_C_ADDI4SPN}: imm16 = immC4SPN;
      {`CQ0, `CF3_C_LW}:       imm16 = immCLW;
      {`CQ0, `CF3_C_SW}:       imm16 = immCLW;
      {`CQ1, `CF3_C_ADDI}:     imm16 = immCLI;
      {`CQ1, `CF3_C_JAL}:      imm16 = immCJ;
      {`CQ1, `CF3_C_LI}:       imm16 = immCLI;
      {`CQ1, `CF3_C_ADDI16SP}: imm16 = (instrWord[11:7] == 5'd2) ? immC16SP : immCLUI;
      {`CQ1, `CF3_C_ARITH}:    imm16 = immCLI;             // C.ANDI imm / C.SRLI,C.SRAI shamt (low 5)
      {`CQ1, `CF3_C_J}:        imm16 = immCJ;
      {`CQ1, `CF3_C_BEQZ}:     imm16 = immCB;
      {`CQ1, `CF3_C_BNEZ}:     imm16 = immCB;
      {`CQ2, `CF3_C_SLLI}:     imm16 = immCLI;             // shamt in low 5
      {`CQ2, `CF3_C_LWSP}:     imm16 = immCLWSP;
      {`CQ2, `CF3_C_SWSP}:     imm16 = immCSWSP;
      default:                 imm16 = 32'b0;
    endcase
  end

  // ── Final width select ──────────────────────────────────────────────────────
  assign immediate = is_compressed ? imm16 : imm32;

endmodule
