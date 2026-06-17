`include "isa.vh"
// =============================================================================
// PHANTOM-32  ──  IF-Stage Decoder
// =============================================================================
// Lightweight register index extractor for the aligner output. Provides the
// rs1/rs2/rd indices at the IF/ID boundary so the regfile read + operand-ready
// scoreboard can run in ID without waiting for full control_unit decode.
//
// Implements PARALLEL 16/32-bit decode paths (no decompressor)
//
// Register index mapping for compressed instructions:
//   Full (CR/CI/CSS): instrWord[11:7] and instrWord[6:2]   → x0–x31
//   Prime (CL/CS/CA/CB): instrWord[9:7] and instrWord[4:2] → x8–x15
//     (3-bit field maps to x8–x15: index = {2'b01, field[2:0]})
// =============================================================================
module fast_decoder (
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:0] instrWord,      // raw fetched instruction word
  /* verilator lint_on UNUSEDSIGNAL */
  output logic [4:0]  rs1_index,      // source register 1
  output logic [4:0]  rs2_index,      // source register 2
  output logic [4:0]  rd_index        // destination register
);

  // =============================================================================
  // 32-BIT FIELD EXTRACTION
  // =============================================================================
  logic [6:0] op32;      assign op32      = instrWord[6:0];
  logic [4:0] rs1_32;    assign rs1_32    = instrWord[19:15];
  logic [4:0] rs2_32;    assign rs2_32    = instrWord[24:20];
  logic [4:0] rd_32;     assign rd_32     = instrWord[11:7];
  logic [4:0] rs1_Sys32; assign rs1_Sys32 = instrWord[14] ? 5'd0 : rs1_32;

  // =============================================================================
  // 16-BIT FIELD EXTRACTION
  // =============================================================================
  logic [1:0] quad;      assign quad      = instrWord[1:0];    // compressed quadrant
  logic [2:0] cfunc3;    assign cfunc3    = instrWord[15:13];  // compressed func3
  // ── Prime register fields (CL/CS/CA/CB formats → x8-x15) ─────────────────
  logic [4:0] rs1_prime; assign rs1_prime = {2'b01, instrWord[9:7]};
  logic [4:0] rs2_prime; assign rs2_prime = {2'b01, instrWord[4:2]};
  // ── Full register fields (CR/CI/CSS/CIW formats → x0-x31) ────────────────
  logic [4:0] rs1_full;  assign rs1_full  = instrWord[11:7]; // rd/rs1 field
  logic [4:0] rs2_full;  assign rs2_full  = instrWord[6:2];  // rs2 field


  // =============================================================================
  // REGISTER INDEX MUX
  // =============================================================================
  // Both decode paths live in one always block, selected by instrWord[1:0]:
  //   CQ0/CQ1/CQ2 (2'b00/01/10) → 16-bit compressed path, decoded per cfunc3
  //   default     (2'b11)        → 32-bit path, decoded per opcode
  //
  // Fields that do not hold a register index for a given instruction type are
  // driven to 5'd0 (x0).  This is critical: if immediate bits are allowed to
  // propagate as fake register indices, the hazard unit may stall the pipeline
  // on a load-use that does not actually exist, wasting cycles silently.
  //
  // 32-bit format summary (which positions hold real register indices):
  //   R-type  (ARITH_R):           rs1=[19:15]  rs2=[24:20]  rd=[11:7]
  //   I-type  (ARITH_I/LOAD/JALR): rs1=[19:15]  [24:20]=imm  rd=[11:7]
  //   S-type  (STORE):             rs1=[19:15]  rs2=[24:20]  [11:7]=imm
  //   B-type  (BRANCH):            rs1=[19:15]  rs2=[24:20]  [11:7]=imm
  //   U-type  (LUI/AUIPC):         [19:15]=imm  [24:20]=imm  rd=[11:7]
  //   J-type  (JAL):               [19:15]=imm  [24:20]=imm  rd=[11:7]
  //   SYSTEM  (CSRRx):             rs1=[19:15]  [24:20]=imm  rd=[11:7]
  //   SYSTEM  (CSRRxI, func3[2]=1):[19:15]=zimm [24:20]=imm  rd=[11:7]
  // =============================================================================
    always_comb begin
      case (quad)
        // =========================================================================
        // QUADRANT 0
        // =========================================================================
        `CQ0: begin
          case (cfunc3)
            `CF3_C_ADDI4SPN: begin rs1_index = 5'd2;      rs2_index = 5'd0;      rd_index = rs2_prime; end
            `CF3_C_LW:       begin rs1_index = rs1_prime; rs2_index = 5'd0;      rd_index = rs2_prime; end
            `CF3_C_SW:       begin rs1_index = rs1_prime; rs2_index = rs2_prime; rd_index = 5'd0;      end
            default:         begin rs1_index = 5'd0;      rs2_index = 5'd0;      rd_index = 5'd0;      end
          endcase
        end

        // =========================================================================
        // QUADRANT 1
        // =========================================================================
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

        // =========================================================================
        // QUADRANT 2
        // =========================================================================
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

        // =========================================================================
        // 32-BIT PATH  (instrWord[1:0] = 2'b11)
        // =========================================================================
        // Disambiguate by opcode so that immediate bits are never mistaken for
        // register indices.  Every operand field that does not contain a real
        // register index for a given format is driven to 5'd0.
        //
        // OP_SYSTEM extra case: func3[2] (instrWord[14]) = 1 for CSRRxI variants
        // (CSRRWI/CSRRSI/CSRRCI), which use instrWord[19:15] as zimm, not rs1.
        // =========================================================================
        default: begin
          case (op32)
            `OP_ARITH_R: begin rs1_index = rs1_32;               rs2_index = rs2_32; rd_index = rd_32; end
            `OP_ARITH_I: begin rs1_index = rs1_32;               rs2_index = 5'd0;   rd_index = rd_32; end
            `OP_LOAD:    begin rs1_index = rs1_32;               rs2_index = 5'd0;   rd_index = rd_32; end
            `OP_JALR:    begin rs1_index = rs1_32;               rs2_index = 5'd0;   rd_index = rd_32; end
            `OP_STORE:   begin rs1_index = rs1_32;               rs2_index = rs2_32; rd_index = 5'd0;  end
            `OP_BRANCH:  begin rs1_index = rs1_32;               rs2_index = rs2_32; rd_index = 5'd0;  end
            `OP_JAL:     begin rs1_index = 5'd0;                 rs2_index = 5'd0;   rd_index = rd_32; end
            `OP_LUI:     begin rs1_index = 5'd0;                 rs2_index = 5'd0;   rd_index = rd_32; end
            `OP_AUIPC:   begin rs1_index = 5'd0;                 rs2_index = 5'd0;   rd_index = rd_32; end
            `OP_SYSTEM:  begin rs1_index = rs1_Sys32;            rs2_index = 5'd0;   rd_index = rd_32; end
            `OP_FENCE:   begin rs1_index = 5'd0;                 rs2_index = 5'd0;   rd_index = 5'd0;  end
            default:     begin rs1_index = 5'd0;                 rs2_index = 5'd0;   rd_index = 5'd0;  end
          endcase
        end
      endcase
    end
  // =============================================================================
  // REGISTER INDEX MUX
  // =============================================================================

endmodule
