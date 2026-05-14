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
//   immediate_2 - immediate + 2 (used for dual-PC branch target calculation)
//
// Pure combinational - no state, no clock. Decode paths run in parallel;
// output mux selects based on is_compressed flag.
// =============================================================================
module imm_generator (
  input  wire [31:0] instrWord,
  input  wire        is_compressed,
  output reg  [31:0] immediate,
  output reg  [31:0] immediate_2
);

  // =============================================================================
  // ── IMMEDIATE EXTRACTION HELPERS  (32-bit) ───────────────────────────────────
  // =============================================================================
  // All 32-bit RV32I fields sit at fixed bit positions regardless of instruction
  // type.  Pre-computing them as named wires keeps the decode always block clean.
  // =============================================================================
    wire [6:0]  primaryOpcode = instrWord[6:0];
    wire [2:0]  func3         = instrWord[14:12];
    reg  [31:0] imm32;

    wire [31:0] immTypeI   = {{20{instrWord[31]}}, instrWord[31:20]};
    wire [31:0] immTypeS   = {{20{instrWord[31]}}, instrWord[31:25],  instrWord[11:7]};
    wire [31:0] immTypeB   = {{19{instrWord[31]}}, instrWord[31],     instrWord[7],     instrWord[30:25], instrWord[11:8],  1'b0};
    wire [31:0] immTypeJ   = {{11{instrWord[31]}}, instrWord[31],     instrWord[19:12], instrWord[20],    instrWord[30:21], 1'b0}; 
    wire [31:0] immTypeU   = {instrWord[31:12],    12'b0};
    wire [31:0] immShamt32 = {27'b0,               instrWord[24:20]};
  // =============================================================================
  // ── IMMEDIATE EXTRACTION HELPERS  (32-bit) ───────────────────────────────────
  // =============================================================================


  // =============================================================================
  // ── IMMEDIATE EXTRACTION HELPERS  (16-bit compressed) ────────────────────────
  // =============================================================================
  // All 16-bit fields live in instrWord[15:0]
  // instrWord[31:16] is irrelevant for compressed instructions.
  // =============================================================================
    wire [1:0]  compressedQuadrant    = instrWord[1:0];
    wire [2:0]  compressedFunc3       = instrWord[15:13];
    wire [4:0]  compressedDestRegFull = instrWord[11:7];
    reg  [31:0] imm16;

    wire [31:0] immCTypeLWSP = {24'b0, instrWord[3:2],  instrWord[12],    instrWord[6:4], 2'b0};
    wire [31:0] immCTypeSWSP = {24'b0, instrWord[8:7],  instrWord[12:9],  2'b0};
    wire [31:0] immCType4SPN = {22'b0, instrWord[10:7], instrWord[12:11], instrWord[5],   instrWord[6],    2'b0};
    wire [31:0] immCTypeSHMT = {27'b0, instrWord[6:2]};
    wire [31:0] immCTypeLW   = {25'b0, instrWord[5],    instrWord[12:10], instrWord[6],   2'b0}; // also applies for C.SW
    wire [31:0] immCTypeLI   = {{26{instrWord[12]}},    instrWord[12],    instrWord[6:2]};       // also applies for C.ADDI & C.ANDI
    wire [31:0] immCTypeLUI  = {{14{instrWord[12]}},    instrWord[12],    instrWord[6:2], 12'b0};
    wire [31:0] immCType16SP = {{22{instrWord[12]}},    instrWord[12],    instrWord[4:3], instrWord[5],    instrWord[2],
                                    instrWord[6],       4'b0};
    wire [31:0] immCTypeB    = {{23{instrWord[12]}},    instrWord[12],    instrWord[6:5], instrWord[2],    instrWord[11:10],
                                    instrWord[4:3],     1'b0};
    wire [31:0] immCTypeJ    = {{20{instrWord[12]}},    instrWord[12],    instrWord[8],   instrWord[10:9], instrWord[6],
                                    instrWord[7],       instrWord[2],     instrWord[11],  instrWord[5:3],  1'b0};
  // =============================================================================
  // ── IMMEDIATE EXTRACTION HELPERS  (16-bit compressed) ────────────────────────
  // =============================================================================


  // =============================================================================
  // ── 32-BIT DECODE PATH ───────────────────────────────────────────────────────
  // This section does NOT care if the instruction is actually in a illegal
  // state, it simply extracts the immediate value regardless.
  // =============================================================================
    always @(*) begin
      case (primaryOpcode)
        `OP_LUI:     begin imm32 = immTypeU; end
        `OP_AUIPC:   begin imm32 = immTypeU; end
        `OP_JAL:     begin imm32 = immTypeJ; end
        `OP_JALR:    begin imm32 = immTypeI; end
        `OP_BRANCH:  begin imm32 = immTypeB; end
        `OP_LOAD:    begin imm32 = immTypeI; end
        `OP_STORE:   begin imm32 = immTypeS; end
        `OP_ARITH_I: begin
          case (func3)
            `F3_ADDI, `F3_SLTI, `F3_SLTIU, `F3_XORI, `F3_ORI, `F3_ANDI: imm32 = immTypeI;
            `F3_SLLI, `F3_SRLI:                                         imm32 = immShamt32;
            default:                                                    imm32 = 32'b0;
          endcase
        end
        default:     begin imm32 = 32'b0;    end
      endcase
    end
  // =============================================================================
  // ── 32-BIT DECODE PATH ───────────────────────────────────────────────────────
  // =============================================================================


  // =============================================================================
  // ── 16-BIT (COMPRESSED) DECODE PATH ──────────────────────────────────────────
  // =============================================================================
    always @(*) begin
      case (compressedQuadrant)
        `CQ0: begin
          case (compressedFunc3)
            `CF3_C_ADDI4SPN: begin imm16 = immCType4SPN; end
            `CF3_C_LW:       begin imm16 = immCTypeLW;   end
            `CF3_C_SW:       begin imm16 = immCTypeLW;   end
            default:         imm16 = 32'b0;
          endcase
        end

        `CQ1: begin
          case (compressedFunc3)
            `CF3_C_ADDI:     begin imm16 = immCTypeLI;   end
            `CF3_C_JAL:      begin imm16 = immCTypeJ;    end
            `CF3_C_LI:       begin imm16 = immCTypeLI;   end
            `CF3_C_ADDI16SP: begin
              if (compressedDestRegFull == 5'd2) imm16 = immCType16SP;
              else                               imm16 = immCTypeLUI;
            end
            `CF3_C_ARITH:    begin
              case (instrWord[11:10])
                2'b00:       begin imm16 = immCTypeSHMT; end
                2'b01:       begin imm16 = immCTypeSHMT; end
                2'b10:       begin imm16 = immCTypeLI;   end
                2'b11:       begin imm16 = 32'b0;        end
              endcase
            end
            `CF3_C_J:        begin imm16 = immCTypeJ;    end
            `CF3_C_BEQZ:     begin imm16 = immCTypeB;    end
            `CF3_C_BNEZ:     begin imm16 = immCTypeB;    end
            default:         begin imm16 = 32'b0;        end
          endcase
        end

        `CQ2: begin
          case (compressedFunc3)
            `CF3_C_SLLI:     begin imm16 = immCTypeSHMT; end
            `CF3_C_LWSP:     begin imm16 = immCTypeLWSP; end
            `CF3_C_SWSP:     begin imm16 = immCTypeSWSP; end
            default:         begin imm16 = 32'b0;        end
          endcase
        end

        default:             begin imm16 = 32'h0;        end
      endcase
    end
  // =============================================================================
  // ── 16-BIT (COMPRESSED) DECODE PATH ──────────────────────────────────────────
  // =============================================================================


  // =============================================================================
  // ── OUTPUT MUX ───────────────────────────────────────────────────────────────
  // =============================================================================
  // Selects between the 32-bit and 16-bit decode results based on is_compressed.
  // =============================================================================
    always @(*) begin
      if (is_compressed) begin
        immediate   = imm16;
        immediate_2 = imm16 + 32'h2;
      end else begin
        immediate   = imm32;
        immediate_2 = imm32 + 32'h2;
      end
    end
  // =============================================================================
  // ── OUTPUT MUX ───────────────────────────────────────────────────────────────
  // =============================================================================

endmodule
