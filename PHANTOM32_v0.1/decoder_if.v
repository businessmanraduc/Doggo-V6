`include "isa.vh"
// =============================================================================
// PHANTOM-32  ──  ParallelDecoderIF  (Instruction Fetch stage decoder)
// =============================================================================
// Lightweight parallel decoder that runs in the IF stage.
//
// Purpose — hazard detection and register file pre-addressing only.
// The full control signal decode happens in ParallelDecoderID (ID stage).
// This module exists for one reason: the load-use hazard detector in the ID
// stage needs to know the rs1 and rs2 indices of the instruction currently
// in ID *before* that instruction has been fully decoded.  Those indices
// come from here, registered through the IF/ID (StageIII_) pipeline register.
//
// Outputs produced:
//   is_compressed   — selects 16-bit vs 32-bit instruction path downstream
//   rd_index        — destination register (for forwarding / WB tracking)
//   rs1_index       — source register 1   (for load-use stall check in ID)
//   rs2_index       — source register 2   (for load-use stall check in ID)
//   is_load         — 1 when this instruction is a load (LW / C.LW / C.LWSP)
//
// Inputs:
//   instr_lo [15:0] — halfword at PC   (Port A BRAM data  = imem_data_a)
//   instr_hi [15:0] — halfword at PC+2 (Port B BRAM data  = imem_data_b)
//
// Two paths run in parallel, selected at the output by is_compressed:
//   32-bit path — straightforward: register fields are always at fixed
//     positions in RV32I (rs1=[19:15], rs2=[24:20], rd=[11:7]).
//   16-bit path — more involved: compressed formats scatter register fields
//     and use a 3-bit "restricted register" encoding for some operands that
//     maps to x8–x15 (actual index = {2'b01, field[2:0]}).  Each quadrant
//     and funct3 combination is handled explicitly.
//
// All outputs are purely combinational (no clock, no state).
// =============================================================================
module decoder_if (
  input  wire [15:0] instr_lo,       // halfword at PC   (always from Port A)
  input  wire [15:0] instr_hi,       // halfword at PC+2 (always from Port B)

  output wire        is_compressed,  // 1 = 16-bit C instruction
  output reg  [4:0]  rd_index,       // destination register index
  output reg  [4:0]  rs1_index,      // source register 1 index
  output reg  [4:0]  rs2_index,      // source register 2 index
  output reg         is_load         // 1 = this instruction reads from data memory
);

  // =============================================================================
  // ── INSTRUCTION SIZE DETECTION ───────────────────────────────────────────────
  // =============================================================================
  // Any 32-bit RV32I instruction has bits [1:0] = 2'b11.
  // Any 16-bit RV32C instruction has bits [1:0] != 2'b11  (00, 01, or 10).
  // We test instr_lo because that is always the halfword at PC — the first
  // halfword of whatever instruction starts here.
  // =============================================================================
  assign is_compressed = (instr_lo[1:0] != 2'b11);


  // =============================================================================
  // ── FIELD EXTRACTION HELPERS ──────────────────────────────────────────────────
  // =============================================================================
  // 32-bit instruction fields (from the full {instr_hi, instr_lo} window).
  // Named wires make the always blocks below readable and self-documenting.
  // =============================================================================
    wire [31:0] instrWord                    = {instr_hi, instr_lo};  // full 32-bit instruction window
    wire [4:0]  destRegIndex                 = instrWord[11:7];       // rd
    wire [4:0]  srcReg1Index                 = instrWord[19:15];      // rs1
    wire [4:0]  srcReg2Index                 = instrWord[24:20];      // rs2
    wire [6:0]  primaryOpcode                = instrWord[6:0];        // opcode [6:0]

    // 16-bit compressed instruction fields (from instr_lo only).
    wire [1:0]  compressedQuadrant           = instr_lo[1:0];         // quadrant (CQ0 / CQ1 / CQ2)
    wire [2:0]  compressedFunct3             = instr_lo[15:13];       // funct3 (top 3 bits of 16-bit word)

    // Restricted register fields (CL / CS / CB / CIW formats): 3 bits → x8–x15
    // The spec defines: actual_reg = {2'b01, field[2:0]}
    wire [4:0]  compressedDestRegRes  = {2'b01, instr_lo[4:2]};  // restricted rd'  (bits [4:2])
    wire [4:0]  compressedSrcReg1Res  = {2'b01, instr_lo[9:7]};  // restricted rs1' (bits [9:7])
    wire [4:0]  compressedSrcReg2Res  = {2'b01, instr_lo[4:2]};  // restricted rs2' (bits [4:2])
                                                                 // (rs2' shares the rd' bit field
                                                                 //  in CS-format stores)

    // Full (non-restricted) register fields used by CR / CI / CSS / Q2 formats
    wire [4:0]  compressedDestRegFull        = instr_lo[11:7];   // full rd / rs1 (CR, CI, Q2 formats)
    wire [4:0]  compressedSrcReg2Full        = instr_lo[6:2];    // full rs2       (CR, CSS formats)


  // =============================================================================
  // ── 32-BIT DECODE PATH ───────────────────────────────────────────────────────
  // =============================================================================
    reg [4:0] destReg32;
    reg [4:0] srcReg1_32;
    reg [4:0] srcReg2_32;
    reg       isLoad32;

    always @(*) begin
      // Sensible defaults: no register reads, no register write, not a load
      destReg32  = 5'd0;
      srcReg1_32 = 5'd0;
      srcReg2_32 = 5'd0;
      isLoad32   = 1'b0;

      case (primaryOpcode)
        // ── R-type: rd, rs1, rs2 all present ──────────────────────────────────────────────────
        `OP_ARITH_R: begin destReg32  = destRegIndex; srcReg1_32 = srcReg1Index; srcReg2_32 = srcReg2Index; end
        // ── I-type arithmetic: rd and rs1, no rs2 ─────────────────────────────────────────────
        `OP_ARITH_I: begin destReg32  = destRegIndex; srcReg1_32 = srcReg1Index;                            end
        // ── Loads: rd and rs1 (base address), no rs2; IS a load ───────────────────────────────
        `OP_LOAD:    begin destReg32  = destRegIndex; srcReg1_32 = srcReg1Index; isLoad32   = 1'b1;         end
        // ── Stores: rs1 (base) and rs2 (data), no destination register ────────────────────────
        `OP_STORE:   begin srcReg1_32 = srcReg1Index; srcReg2_32 = srcReg2Index;                            end
        // ── Branches: rs1 and rs2 compared, no destination register ───────────────────────────
        `OP_BRANCH:  begin srcReg1_32 = srcReg1Index; srcReg2_32 = srcReg2Index;                            end
        // ── JALR: rd (link) and rs1 (jump base), no rs2 ───────────────────────────────────────
        `OP_JALR:    begin destReg32  = destRegIndex; srcReg1_32 = srcReg1Index;                            end
        // ── JAL: rd (link) only, no source registers ──────────────────────────────────────────
        `OP_JAL:     begin destReg32  = destRegIndex;                                                       end
        // ── LUI / AUIPC: rd only, no source registers ─────────────────────────────────────────
        `OP_LUI:     begin destReg32  = destRegIndex;                                                       end
        `OP_AUIPC:   begin destReg32  = destRegIndex;                                                       end
        // ── SYSTEM (ECALL/EBREAK/MRET/CSR*): rd and rs1 for CSR instructions ──────────────────
        `OP_SYSTEM:  begin destReg32  = destRegIndex; srcReg1_32 = srcReg1Index;                            end
        // ── FENCE / FENCE.I: treated as NOP for hazard purposes ───────────────────────────────
        `OP_FENCE:   begin                                                                                  end
        // ── Unknown opcode: safe default (no reads/writes, not a load) ────────────────────────
        default:     begin                                                                                  end
      endcase
    end


  // =============================================================================
  // ── 16-BIT (COMPRESSED) DECODE PATH ─────────────────────────────────────────
  // =============================================================================
  // Organised by quadrant first, then funct3.
  // For each instruction we only extract the fields needed by the hazard unit:
  // rs1, rs2, rd, and is_load.  The full semantic decode happens in decoder_id.
  //
  // Key register encoding rules:
  //   Res (CL/CS/CB/CIW): 3-bit field → {2'b01, field} = x8–x15
  //   Full (CR/CI/CSS/Q2):       5-bit field from instr_lo[11:7] or [6:2]
  // =============================================================================
    reg [4:0] destRegC;
    reg [4:0] srcReg1C;
    reg [4:0] srcReg2C;
    reg       isLoadC;

    always @(*) begin
      // Safe defaults
      destRegC = 5'd0;
      srcReg1C = 5'd0;
      srcReg2C = 5'd0;
      isLoadC  = 1'b0;

      case (compressedQuadrant)
        // =======================================================================
        // QUADRANT 0  (instr_lo[1:0] = 2'b00)
        // =======================================================================
        `CQ0: begin
          case (compressedFunct3)
            // C.ADDI4SPN: rd' = instr[4:2], implicit rs1 = x2 (sp)
            `CF3_C_ADDI4SPN: begin destRegC = compressedDestRegRes; srcReg1C = 5'd2;                    end
            // C.LW: rd' = instr[4:2], rs1' = instr[9:7] — IS A LOAD
            `CF3_C_LW:       begin destRegC = compressedDestRegRes; srcReg1C = compressedSrcReg1Res; isLoadC = 1'b1;  end
            // C.SW: rs2' = instr[4:2], rs1' = instr[9:7] — store, no rd
            `CF3_C_SW:       begin srcReg1C = compressedSrcReg1Res; srcReg2C = compressedSrcReg2Res;    end
            // All other Q0 encodings are reserved in RV32C — treat as NOP
            default: begin end
          endcase
        end

        // =======================================================================
        // QUADRANT 1  (instr_lo[1:0] = 2'b01)
        // =======================================================================
        `CQ1: begin
          case (compressedFunct3)
            // C.NOP (rd=0, imm=0) / C.ADDI (rd≠0): rd/rs1 = instr[11:7]
            `CF3_C_ADDI:     begin destRegC = compressedDestRegFull;  srcReg1C = compressedDestRegFull; end
            // C.JAL (RV32C only): implicit rd = x1 (ra), no source registers
            `CF3_C_JAL:      begin destRegC = 5'd1;                                                     end
            // C.LI: rd = instr[11:7], implicit rs1 = x0 (zero-extended imm added)
            `CF3_C_LI:       begin destRegC = compressedDestRegFull;                                    end
            // C.ADDI16SP (rd=x2) / C.LUI (rd≠x0, rd≠x2): both use instr[11:7] as rd
            // C.ADDI16SP reads and modifies sp (x2); C.LUI has no source register.
            // if rd == x2 → C.ADDI16SP: rs1 = x2; otherwise C.LUI: rs1 = x0
            `CF3_C_ADDI16SP: begin destRegC = compressedDestRegFull;
              srcReg1C = (compressedDestRegFull == 5'd2) ? 5'd2 : 5'd0;
            end
            // C.ARITH: C.SRLI / C.SRAI / C.ANDI / C.SUB / C.XOR / C.OR / C.AND
            // All use restricted rs1' = instr[9:7] as both source and destination.
            // Only C.SUB/C.XOR/C.OR/C.AND (instr[11:10]=2'b11) have rs2
            `CF3_C_ARITH:    begin destRegC = compressedSrcReg1Res;  srcReg1C = compressedSrcReg1Res;
              if (instr_lo[11:10] == 2'b11) srcReg2C = compressedSrcReg2Res;
            end
            // C.J: unconditional jump, no rd (writes x0 = discarded), no source regs
            `CF3_C_J:        begin                                                                      end
            // C.BEQZ: rs1' = instr[9:7], no rd
            `CF3_C_BEQZ:     begin srcReg1C = compressedSrcReg1Res;                                     end
            // C.BNEZ: rs1' = instr[9:7], no rd
            `CF3_C_BNEZ:     begin srcReg1C = compressedSrcReg1Res;                                     end
            default: begin end
          endcase
        end

        // =======================================================================
        // QUADRANT 2  (instr_lo[1:0] = 2'b10)
        // =======================================================================
        `CQ2: begin
          case (compressedFunct3)
            // C.SLLI: rd/rs1 = instr[11:7]
            `CF3_C_SLLI: begin destRegC = compressedDestRegFull;  srcReg1C = compressedDestRegFull; end
            // C.LWSP: rd = instr[11:7], implicit rs1 = x2 (sp) — IS A LOAD
            `CF3_C_LWSP: begin destRegC = compressedDestRegFull;  srcReg1C = 5'd2; isLoadC = 1'b1;  end
            // C.SWSP: rs2 = instr[6:2], implicit rs1 = x2 (sp) — store, no rd
            `CF3_C_SWSP: begin srcReg1C = 5'd2;                   srcReg2C = compressedSrcReg2Full; end
            // C.MISC: C.JR / C.MV / C.EBREAK / C.JALR / C.ADD
            // All share funct3=100; distinguished by instr[12] and instr[6:2].
            `CF3_C_MISC: begin
              if (!instr_lo[12]) begin
                if (compressedSrcReg2Full == 5'd0) begin
                  // C.JR: PC = rs1, no link register write.  rd = x0 (discarded).
                  srcReg1C = compressedDestRegFull;    // rs1 lives in the rd field position
                end else begin
                  // C.MV: rd = instr[11:7], rs2 = instr[6:2], rs1 = x0
                  destRegC = compressedDestRegFull;
                  srcReg2C = compressedSrcReg2Full;
                end
              end else begin
                if (compressedDestRegFull == 5'd0 && compressedSrcReg2Full == 5'd0) begin
                  // C.EBREAK: no registers
                end else if (compressedSrcReg2Full == 5'd0) begin
                  // C.JALR: rd = x1 (ra), rs1 = instr[11:7]
                  destRegC = 5'd1;                     // ra = x1
                  srcReg1C = compressedDestRegFull;
                end else begin
                  // C.ADD: rd/rs1 = instr[11:7], rs2 = instr[6:2]
                  destRegC = compressedDestRegFull;
                  srcReg1C = compressedDestRegFull;
                  srcReg2C = compressedSrcReg2Full;
                end
              end
            end
            default: begin end
          endcase
        end

        // Quadrant 3 cannot appear here: is_compressed would be 0 for [1:0]=11
        default: begin end
      endcase
    end


  // =============================================================================
  // ── OUTPUT MUX ───────────────────────────────────────────────────────────────
  // =============================================================================
  // Select between the 32-bit and 16-bit decode results based on is_compressed.
  // All four outputs are registered into StageIII_ on the next rising edge by
  // the IF stage always block in cpu.v.
  // =============================================================================
    always @(*) begin
      if (is_compressed) begin
        rd_index  = destRegC;
        rs1_index = srcReg1C;
        rs2_index = srcReg2C;
        is_load   = isLoadC;
      end else begin
        rd_index  = destReg32;
        rs1_index = srcReg1_32;
        rs2_index = srcReg2_32;
        is_load   = isLoad32;
      end
    end

endmodule
