`include "isa.vh"
// =============================================================================
// PHANTOM-32  ──  IF-Stage Decoder
// =============================================================================
// Lightweight register index extractor for the IF pipeline stage.
// Provides register indices and key flags ONE STAGE EARLY so the hazard
// unit can detect load-use dependencies before the ID stage decodes fully.
//
// Implements PARALLEL 16/32-bit decode paths — no decompressor step.
//
// Register index mapping for compressed instructions:
//   Full (CR/CI/CSS): instrWord[11:7] and instrWord[6:2]   → x0–x31
//   Prime (CL/CS/CA/CB): instrWord[9:7] and instrWord[4:2] → x8–x15
//     (3-bit field maps to x8–x15: index = {2'b01, field[2:0]})
// =============================================================================
module fast_decoder (
  input  wire [31:0] instrWord,      // raw fetched instruction word
  output wire        is_compressed,  // 1 = 16-bit C instruction
  output reg  [4:0]  rs1_index,      // source register 1
  output reg  [4:0]  rs2_index,      // source register 2
  output reg  [4:0]  rd_index,       // destination register
  output wire        is_load         // 1 = load instruction (triggers hazard check)
);

  assign is_compressed = (instrWord[1:0] != 2'b11);

  // =============================================================================
  // 32-BIT FIELD EXTRACTION
  // =============================================================================
  wire [6:0] op32    = instrWord[6:0];
  wire [4:0] rs1_32  = instrWord[19:15];
  wire [4:0] rs2_32  = instrWord[24:20];
  wire [4:0] rd_32   = instrWord[11:7];

  // =============================================================================
  // 16-BIT FIELD EXTRACTION
  // =============================================================================
  wire [1:0] quad    = instrWord[1:0];    // compressed quadrant
  wire [2:0] cfunc3  = instrWord[15:13];  // compressed func3
  // ── Prime register fields (CL/CS/CA/CB formats → x8-x15) ─────────────────
  wire [4:0] rs1_prime = {2'b01, instrWord[9:7]};
  wire [4:0] rs2_prime = {2'b01, instrWord[4:2]};
  // ── Full register fields (CR/CI/CSS/CIW formats → x0-x31) ────────────────
  wire [4:0] rs1_full  = instrWord[11:7]; // rd/rs1 field
  wire [4:0] rs2_full  = instrWord[6:2];  // rs2 field
  // =============================================================================
  // IS_LOAD DETECTION
  // =============================================================================
  wire is_load32 = (op32 == `OP_LOAD);
  wire is_load16 = (quad == `CQ0 && cfunc3 == `CF3_C_LW) ||
                   (quad == `CQ2 && cfunc3 == `CF3_C_LWSP);
  assign is_load = is_compressed ? is_load16 : is_load32;


  // =============================================================================
  // REGISTER INDEX MUX  ──  32-bit path
  // =============================================================================
  // Straightforward: all register fields live at fixed positions.
  // =============================================================================

  // =============================================================================
  // REGISTER INDEX MUX  ──  16-bit path
  // =============================================================================
  // Decoded per-quadrant, per-funct3.  Each case identifies which register
  // fields are READ (→ rs1/rs2) and which is WRITTEN (→ rd).
  // x0 is used as a safe "no register" sentinel — writes to x0 are discarded
  // by the regfile and x0 reads never cause hazards.
  // =============================================================================
    always @(*) begin
      case (quad)
        `CQ0: begin
          case (cfunc3)
            `CF3_C_ADDI4SPN: begin rs1_index = 5'd2;      rs2_index = 5'd0;      rd_index = rs2_prime; end
            `CF3_C_LW:       begin rs1_index = rs1_prime; rs2_index = 5'd0;      rd_index = rs2_prime; end
            `CF3_C_SW:       begin rs1_index = rs1_prime; rs2_index = rs2_prime; rd_index = 5'd0;      end
            default:         begin rs1_index = 5'd0;      rs2_index = 5'd0;      rd_index = 5'd0;      end
          endcase
        end

        `CQ1: begin
          case (cfunc3)
            `CF3_C_ADDI:     begin rs1_index = rs1_full;  rs2_index = 5'd0;      rd_index = rs1_full;  end
            `CF3_C_JAL:      begin rs1_index = 5'd0;      rs2_index = 5'd0;      rd_index = 5'd1;      end
            `CF3_C_LI:       begin rs1_index = 5'd0;      rs2_index = 5'd0;      rd_index = rs1_full;  end
            `CF3_C_ADDI16SP: begin
              if (instrWord[11:7] == 5'd2) begin    // C.ADDI16SP
                rs1_index = 5'd2;  rs2_index = 5'd0;      rd_index = 5'd2;
              end else begin                        // C.LUI
                rs1_index = 5'd0;  rs2_index = 5'd0;      rd_index = rs1_full;
              end
            end
            `CF3_C_ARITH:    begin
              if (instrWord[11:10] != 2'b11) begin  // C.SRLI (10=00) / C.SRAI (10=01) / C.ANDI (10=10)
                rs1_index = rs1_prime; rs2_index = 5'd0;      rd_index = rs1_prime;
              end else begin                        // C.SUB/C.XOR/C.OR/C.AND (10=11)
                rs1_index = rs1_prime; rs2_index = rs2_prime; rd_index = rs1_prime;
              end
            end
            `CF3_C_J:        begin rs1_index = 5'd0;      rs2_index = 5'd0;      rd_index = 5'd0;      end
            `CF3_C_BEQZ:     begin rs1_index = rs1_prime; rs2_index = 5'd0;      rd_index = 5'd0;      end
            `CF3_C_BNEZ:     begin rs1_index = rs1_prime; rs2_index = 5'd0;      rd_index = 5'd0;      end
            default:         begin rs1_index = 5'd0;      rs2_index = 5'd0;      rd_index = 5'd0;      end
          endcase
        end

        `CQ2: begin
          case (cfunc3)
            `CF3_C_SLLI:     begin rs1_index = rs1_full;  rs2_index = 5'd0;      rd_index = rs1_full;  end
            `CF3_C_LWSP:     begin rs1_index = 5'd2;      rs2_index = 5'd0;      rd_index = rs1_full;  end
            `CF3_C_MISC:     begin 
              if (instrWord[12] == 1'b0) begin
                if (instrWord[6:2] == 5'd0) begin                            // C.JR
                  rs1_index = rs1_full; rs2_index = 5'd0;     rd_index = 5'd0;
                end else begin                                               // C.MV
                  rs1_index = 5'd0;     rs2_index = rs2_full; rd_index = rs1_full;
                end
              end else begin
                if (instrWord[11:7] == 5'd0 && instrWord[6:2] == 5'd0) begin // C.EBREAK
                  rs1_index = 5'd0;     rs2_index = 5'd0;     rd_index = 5'd0;
                end else if (instrWord[6:2] == 5'd0) begin                   // C.JALR
                  rs1_index = rs1_full; rs2_index = 5'd0;     rd_index = 5'd1;
                end else begin                                               // C.ADD
                  rs1_index = rs1_full; rs2_index = rs2_full; rd_index = rs1_full;
                end
              end
            end
            `CF3_C_SWSP:     begin rs1_index = 5'd2;      rs2_index = rs2_full;  rd_index = 5'd0;      end
            default:         begin rs1_index = 5'd0;      rs2_index = 5'd0;      rd_index = 5'd0;      end
          endcase
        end

        default:             begin rs1_index = rs1_32;    rs2_index = rs2_32;    rd_index = rd_32;     end
      endcase
    end
  // =============================================================================
  // REGISTER INDEX MUX  ──  16-bit path
  // =============================================================================

endmodule
