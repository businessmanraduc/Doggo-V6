`include "isa.vh"
// =============================================================================
// PHANTOM-32  ──  IF-stage Branch/Jump Target Precompute
// =============================================================================
// Computes pc + imm for the predictable-taken instruction formats only:
//
//   32-bit:  JAL (J-type)   BRANCH (B-type)
//   16-bit:  C.J / C.JAL (CJ)   C.BEQZ / C.BNEZ (CB)
// =============================================================================
module bj_target (
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:0] instrWord,
  /* verilator lint_on  UNUSEDSIGNAL */
  input  logic        is_compressed,
  output logic [31:0] bj_imm
);
  
  // ── Immediate layouts ──────────────────────────────────────────────────────
  logic [31:0] immTypeB; assign immTypeB = {{19{instrWord[31]}}, instrWord[31], instrWord[7], instrWord[30:25], instrWord[11:8], 1'b0};
  logic [31:0] immTypeJ; assign immTypeJ = {{11{instrWord[31]}}, instrWord[31], instrWord[19:12], instrWord[20], instrWord[30:21], 1'b0};
  logic [31:0] immCB;    assign immCB    = {{23{instrWord[12]}}, instrWord[12], instrWord[6:5], instrWord[2], instrWord[11:10], instrWord[4:3], 1'b0};
  logic [31:0] immCJ;    assign immCJ    = {{20{instrWord[12]}}, instrWord[12], instrWord[8], instrWord[10:9], instrWord[6], instrWord[7], instrWord[2], instrWord[11], instrWord[5:3], 1'b0};

  // ── Format select ──────────────────────────────────────────────────────────
  logic [31:0] imm32;    assign imm32    = (instrWord[6:0] == `OP_JAL) ? immTypeJ : immTypeB;
  logic [31:0] imm16;    assign imm16    = (instrWord[14]  == 1'b0)    ? immCJ    : immCB;

  assign bj_imm = is_compressed ? imm16 : imm32;

endmodule

