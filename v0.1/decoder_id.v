`include "isa.vh"
// =============================================================================
// PHANTOM-32  ──  ParallelDecoderID  (Instruction Decode stage decoder)
// =============================================================================
// Full parallel decoder that runs in the ID stage.
//
// Both the 32-bit and 16-bit decode paths run simultaneously on every cycle.
// The output mux at the bottom selects between them based on is_compressed,
// which was determined in the IF stage and propagated through StageIII_.
//
// No decompressor is used: 16-bit instructions are decoded directly to
// control signals without first expanding them to their 32-bit equivalents.
// This keeps the decompressor off the critical path and avoids the frequency
// penalty seen in designs that use a decompressor before a unified decoder.
// (see: RVCoreP-32IC paper, section III-B)
//
// Outputs:
//   immediate    — 32-bit sign/zero-extended immediate (for ALU and address calc)
//   immediate2   — immediate + 2  (pre-computed for dual-PC fetch's TruePC_2)
//   CTRL_*       — pipeline control signals propagated through StageIV_
//
// All outputs are purely combinational (no clock, no state).
// =============================================================================
module decoder_id (
  input  wire [31:0] instrWord,             // full 32-bit window {instr_hi, instr_lo}
  input  wire        is_compressed,         // 1 = 16-bit C instruction (from StageIII_)

  // ── Immediate values ────────────────────────────────────────────────────────
  output reg  [31:0] immediate,             // sign-/zero-extended immediate
  output reg  [31:0] immediate2,            // immediate + 2  (for TruePC_2)

  // ── Pipeline control signals ────────────────────────────────────────────────
  output reg         CTRL_destRegWrite,     // 1 = write result to rd in WB
  output reg         CTRL_memRead,          // 1 = load  (LW / C.LW / C.LWSP)
  output reg         CTRL_memWrite,         // 1 = store (SW / C.SW / C.SWSP)
  output reg         CTRL_isBranch,         // 1 = conditional branch
  output reg         CTRL_isJump,           // 1 = unconditional jump (JAL/JALR/C.J/C.JAL/C.JR/C.JALR)
  output reg         CTRL_ALUBSel,          // 0 = ALU B operand is rs2 value; 1 = ALU B operand is immediate
  output reg         CTRL_memToReg,         // 0 = write ALU result to rd;     1 = write load data to rd
  output reg  [3:0]  CTRL_ALUOpcode,        // ALU operation  (`ALU_* from isa.vh)
  output reg  [2:0]  CTRL_branchCond,       // branch comparison func3 (BEQ/BNE/BLT/BGE/BLTU/BGEU)
  output reg         CTRL_isJALR,           // 1 = target is rs1 + imm  (not PC + imm)
  output reg         CTRL_isLink,           // 1 = write return address to rd (JAL/JALR family)
  output reg  [2:0]  CTRL_loadWidth,        // load width and signedness  (`WIDTH_* from isa.vh)
  output reg  [1:0]  CTRL_storeWidth,       // store width  (00=byte, 01=half, 10=word)
  output reg         CTRL_isCSR,            // 1 = CSR instruction
  output reg  [11:0] CTRL_CSRAddr,          // CSR register address [11:0]
  output reg  [1:0]  CTRL_CSROp,            // CSR operation type (`CSR_OP_* from isa.vh)
  output reg         CTRL_CSRUseImm,        // 1 = use zimm[4:0] as write data (CSRRWI/CSRRSI/CSRRCI)
  output reg         CTRL_isAUIPC,          // 1 = EX must feed PC into ALU port A
  output reg         CTRL_isECALL,          // 1 = ECALL  → M-mode trap, cause 11
  output reg         CTRL_isEBREAK,         // 1 = EBREAK → M-mode trap, cause  3
  output reg         CTRL_isMRET,           // 1 = MRET   → return from M-mode trap
  output reg         CTRL_isIllegal,        // 1 = illegal / unrecognised instruction → trap, cause 2
  output reg         CTRL_HALT              // 1 = stop CPU when this retires (mapped to EBREAK)
);

  // =============================================================================
  // ── FIELD EXTRACTION HELPERS  (32-bit) ───────────────────────────────────────
  // =============================================================================
  // All 32-bit RV32I fields sit at fixed bit positions regardless of instruction
  // type.  Pre-computing them as named wires keeps the decode always block clean.
  // =============================================================================
    wire [6:0]  primaryOpcode   = instrWord[6:0];
    wire [2:0]  func3           = instrWord[14:12];
    wire [6:0]  func7           = instrWord[31:25];

    // Pre-computed 32-bit immediates for each instruction format.
    // Building them as wires avoids repeating the bit-scatter logic inside
    // the case statements and makes each format's reconstruction explicit.
    wire [31:0] immTypeI   = {{20{instrWord[31]}}, instrWord[31:20]};
    wire [31:0] immTypeS   = {{20{instrWord[31]}}, instrWord[31:25], instrWord[11:7]};
    wire [31:0] immTypeB   = {{19{instrWord[31]}}, instrWord[31],    instrWord[7],     instrWord[30:25], instrWord[11:8],  1'b0};
    wire [31:0] immTypeU   = {instrWord[31:12],    12'b0};
    wire [31:0] immTypeJ   = {{11{instrWord[31]}}, instrWord[31],    instrWord[19:12], instrWord[20],    instrWord[30:21], 1'b0};
    // Shift immediate: only bits [24:20] are the 5-bit shift amount.
    // immTypeI would incorrectly include func7 bits in the upper portion of the
    // immediate for shift instructions, so we isolate the shamt in its own wire.
    wire [31:0] immShamt32 = {27'b0,               instrWord[24:20]};
  // =============================================================================
  // ── FIELD EXTRACTION HELPERS  (32-bit) ───────────────────────────────────────
  // =============================================================================


  // =============================================================================
  // ── FIELD EXTRACTION HELPERS  (16-bit compressed) ────────────────────────────
  // =============================================================================
  // All 16-bit fields live in instrWord[15:0] = instr_lo.
  // instrWord[31:16] = instr_hi is irrelevant for compressed instructions.
  // =============================================================================
    wire [1:0]  compressedQuadrant    = instrWord[1:0];
    wire [2:0]  compressedFunct3      = instrWord[15:13];
    // Full register encoding (CR / CI / CSS / Q2 formats)
    wire [4:0]  compressedDestRegFull = instrWord[11:7];  // full rd / rs1
    wire [4:0]  compressedSrcReg2Full = instrWord[6:2];   // full rs2

    // ── Pre-computed 16-bit immediates. ────────────────────────────────────────
    // C.LW / C.SW (CL/CS): zero-extended 7-bit word-aligned offset
    //   [12:10]=imm[5:3], [6]=imm[2], [5]=imm[6]
    wire [31:0] immCLW       = {25'b0, instrWord[5],    instrWord[12:10], instrWord[6],    2'b00};
    // C.ADDI4SPN (CIW): zero-extended 10-bit word-aligned immediate
    //   [12:11]=nzuimm[5:4], [10:7]=nzuimm[9:6], [6]=nzuimm[2], [5]=nzuimm[3]
    wire [31:0] immCAddi4Spn = {22'b0, instrWord[10:7], instrWord[12:11], instrWord[5],    instrWord[6],   2'b00};
    // C.ADDI / C.LI / C.ANDI: sign-extended 6-bit
    //   [12]=imm[5], [6:2]=imm[4:0]
    wire [31:0] immCI6       = {{26{instrWord[12]}},    instrWord[12],    instrWord[6:2]};
    // C.JAL / C.J (CJ format): sign-extended 12-bit PC offset
    //   [12]=imm[11], [11]=imm[4], [10:9]=imm[9:8], [8]=imm[10],
    //   [7]=imm[6],   [6]=imm[7],  [5:3]=imm[3:1],  [2]=imm[5]
    wire [31:0] immCJ        = {{20{instrWord[12]}},    instrWord[12],    instrWord[8],    instrWord[10:9], instrWord[6],
                                instrWord[7],           instrWord[2],     instrWord[11],   instrWord[5:3],  1'b0};
    // C.ADDI16SP: sign-extended 10-bit (4-bit trailing zeros, scaled by 16)
    //   [12]=nzimm[9], [6]=nzimm[4], [5]=nzimm[6], [4:3]=nzimm[8:7], [2]=nzimm[5]
    wire [31:0] immCAddi16Sp = {{22{instrWord[12]}},    instrWord[12],    instrWord[4:3],  instrWord[5],    instrWord[2],
                                instrWord[6],           4'b0000};
    // C.LUI: sign-extended 18-bit upper immediate (12 trailing zeros)
    //   [12]=nzimm[17], [6:2]=nzimm[16:12]
    wire [31:0] immCLui      = {{14{instrWord[12]}},    instrWord[12],    instrWord[6:2],  12'b0};
    // C.BEQZ / C.BNEZ (CB format): sign-extended 9-bit PC offset
    //   [12]=offset[8], [11:10]=offset[4:3], [6:5]=offset[7:6],
    //   [4:3]=offset[2:1], [2]=offset[5]
    wire [31:0] immCB        = {{23{instrWord[12]}},    instrWord[12],    instrWord[6:5],  instrWord[2],    instrWord[11:10],
                                instrWord[4:3],         1'b0};
    // C.SRLI / C.SRAI / C.SLLI: 5-bit shift amount (RV32C: instrWord[12] must be 0)
    wire [31:0] immCShamt    = {27'b0, instrWord[6:2]};
    // C.LWSP (CI): zero-extended 8-bit word-aligned offset
    //   [12]=imm[5], [6:4]=imm[4:2], [3:2]=imm[7:6]
    wire [31:0] immCLwsp     = {24'b0, instrWord[3:2],  instrWord[12],    instrWord[6:4],  2'b00};
    // C.SWSP (CSS): zero-extended 8-bit word-aligned offset
    //   [12:9]=imm[5:2], [8:7]=imm[7:6]
    wire [31:0] immCSwsp     = {24'b0, instrWord[8:7],  instrWord[12:9],  2'b00};
  // =============================================================================
  // ── FIELD EXTRACTION HELPERS  (16-bit compressed) ────────────────────────────
  // =============================================================================


  // =============================================================================
  // ── 32-BIT DECODE PATH ───────────────────────────────────────────────────────
  // =============================================================================
  // Decodes all RV32I base instructions plus ECALL/EBREAK/MRET and all CSR
  // variants.  Every output has a safe default of 0 / NOP at the top of the
  // block; each case branch only sets signals that deviate from the default.
  // =============================================================================
    reg [31:0] imm32;
    reg        destRegWrite32,  memRead32,     memWrite32,   isBranch32,  isJump32;
    reg        ALUBSel32,       memToReg32;
    reg [3:0]  ALUOpcode32;
    reg [2:0]  branchCond32;
    reg        isJALR32,        isLink32;
    reg [2:0]  loadWidth32;
    reg [1:0]  storeWidth32;
    reg        isCSR32;
    reg [11:0] CSRAddr32;
    reg [1:0]  CSROp32;
    reg        CSRUseImm32;
    reg        isAUIPC32;
    reg        isECALL32,       isEBREAK32,    isMRET32,     isIllegal32, HALT32;

    always @(*) begin
      // ── Safe defaults: every signal is 0 / NOP ─────────────────────────────────
      imm32          = 32'h0;
      destRegWrite32 = 1'b0;  memRead32      = 1'b0;   memWrite32  = 1'b0;
      isBranch32     = 1'b0;  isJump32       = 1'b0;
      ALUBSel32      = 1'b0;  memToReg32     = 1'b0;   ALUOpcode32 = `ALU_ADD;
      branchCond32   = 3'd0;  isJALR32       = 1'b0;   isLink32    = 1'b0;
      loadWidth32    = 3'd0;  storeWidth32   = 2'd0;
      isCSR32        = 1'b0;  CSRAddr32      = 12'd0;
      CSROp32        = 2'd0;  CSRUseImm32    = 1'b0;
      isAUIPC32      = 1'b0;
      isECALL32      = 1'b0;  isEBREAK32     = 1'b0;
      isMRET32       = 1'b0;  isIllegal32    = 1'b0;   HALT32      = 1'b0;

      case (primaryOpcode)
        // ── LUI ──────────────────────────────────────────────────────────────────
        // rd = {imm[31:12], 12'b0}  — pass upper immediate straight through ALU B
        `OP_LUI: begin
          imm32         = immTypeU;     destRegWrite32 = 1'b1;  ALUBSel32    = 1'b1;
          ALUOpcode32   = `ALU_PASS_B;
        end

        // ── AUIPC ────────────────────────────────────────────────────────────────
        // rd = PC + {imm[31:12], 12'b0}  — EX feeds PC into ALU port A via isAUIPC
        `OP_AUIPC: begin
          imm32         = immTypeU;     destRegWrite32 = 1'b1;  ALUBSel32    = 1'b1;
          ALUOpcode32   = `ALU_ADD;     isAUIPC32      = 1'b1;
        end

        // ── JAL ──────────────────────────────────────────────────────────────────
        // rd = PC+4;  PC = PC + sext(imm21)
        `OP_JAL: begin
          imm32         = immTypeJ;     destRegWrite32 = 1'b1;  isJump32     = 1'b1;
          isLink32      = 1'b1;
        end

        // ── JALR ─────────────────────────────────────────────────────────────────
        // rd = PC+4;  PC = (rs1 + sext(imm12)) & ~1
        `OP_JALR: begin
          if (func3 == `F3_JALR) begin
            imm32       = immTypeI;     destRegWrite32 = 1'b1;  ALUBSel32    = 1'b1;
            ALUOpcode32 = `ALU_ADD;     isJump32       = 1'b1;  isJALR32     = 1'b1;
            isLink32    = 1'b1;
          end else begin
            isIllegal32 = 1'b1;  // func3 != 000 is reserved for JALR
          end
        end

        // ── BRANCH ───────────────────────────────────────────────────────────────
        // if (rs1 COND rs2): PC = PC + sext(imm13)
        `OP_BRANCH: begin
          if (func3 == 3'b010 || func3 == 3'b011) begin
            isIllegal32 = 1'b1;
          end else begin
            imm32       = immTypeB;     isBranch32     = 1'b1;  branchCond32 = func3;
          end
        end

        // ── LOAD ─────────────────────────────────────────────────────────────────
        // rd = sext/zext(mem[rs1 + sext(imm12)])  — width from func3
        `OP_LOAD: begin
          case (func3)
            `F3_LB, `F3_LH, `F3_LW, `F3_LBU, `F3_LHU: begin
              imm32       = immTypeI;   destRegWrite32 = 1'b1;  ALUBSel32    = 1'b1;
              ALUOpcode32 = `ALU_ADD;   memRead32      = 1'b1;  memToReg32   = 1'b1;
              loadWidth32 = func3;       // func3 == `WIDTH_* directly
            end
            default: isIllegal32 = 1'b1; // func3 = 011, 110, 111 are not defined loads
          endcase
        end

        // ── STORE ────────────────────────────────────────────────────────────────
        // mem[rs1 + sext(imm12)] = rs2  — width from func3
        `OP_STORE: begin
          case (func3)
            `F3_SB, `F3_SH, `F3_SW: begin
              imm32       = immTypeS;   ALUBSel32      = 1'b1;  ALUOpcode32  = `ALU_ADD;
              memWrite32  = 1'b1; storeWidth32   = func3[1:0];   // 00=SB, 01=SH, 10=SW
            end
            default: isIllegal32 = 1'b1; // any other values for func3 are not defined
          endcase
        end

        // ── REGISTER-IMMEDIATE ARITHMETIC ────────────────────────────────────────
        // rd = rs1 OP sext(imm12)
        `OP_ARITH_I: begin
          destRegWrite32  = 1'b1;       ALUBSel32      = 1'b1;
          case (func3)
            `F3_ADDI:  begin ALUOpcode32 = `ALU_ADD;  imm32 = immTypeI;  end
            `F3_SLTI:  begin ALUOpcode32 = `ALU_SLT;  imm32 = immTypeI;  end
            `F3_SLTIU: begin ALUOpcode32 = `ALU_SLTU; imm32 = immTypeI;  end
            `F3_XORI:  begin ALUOpcode32 = `ALU_XOR;  imm32 = immTypeI;  end
            `F3_ORI:   begin ALUOpcode32 = `ALU_OR;   imm32 = immTypeI;  end
            `F3_ANDI:  begin ALUOpcode32 = `ALU_AND;  imm32 = immTypeI;  end
            `F3_SLLI: begin
              if (func7 == `F7_NORMAL) begin ALUOpcode32 = `ALU_SLL; imm32 = immShamt32; end
              else                     begin isIllegal32 = 1'b1;                         end
            end
            `F3_SRLI: begin  // func3 shared between SRLI and SRAI; func7 distinguishes them
              case (func7)
                `F7_NORMAL: begin ALUOpcode32 = `ALU_SRL; imm32 = immShamt32; end
                `F7_ALT:    begin ALUOpcode32 = `ALU_SRA; imm32 = immShamt32; end
                default:    begin isIllegal32 = 1'b1;                         end
              endcase
            end
            default: isIllegal32 = 1'b1;
          endcase
        end

        // ── REGISTER-REGISTER ARITHMETIC ─────────────────────────────────────────
        // rd = rs1 OP rs2
        `OP_ARITH_R: begin
          destRegWrite32 = 1'b1;
          case (func7)
            // func7 = 0000000: ADD, SLL, SLT, SLTU, XOR, SRL, OR, AND
            `F7_NORMAL: begin
              case (func3)
                `F3_ADD:  ALUOpcode32 = `ALU_ADD;
                `F3_SLL:  ALUOpcode32 = `ALU_SLL;
                `F3_SLT:  ALUOpcode32 = `ALU_SLT;
                `F3_SLTU: ALUOpcode32 = `ALU_SLTU;
                `F3_XOR:  ALUOpcode32 = `ALU_XOR;
                `F3_SRL:  ALUOpcode32 = `ALU_SRL;
                `F3_OR:   ALUOpcode32 = `ALU_OR;
                `F3_AND:  ALUOpcode32 = `ALU_AND;
                default:  isIllegal32 = 1'b1;
              endcase
            end
            // func7 = 0100000: SUB and SRA only; all other func3 are illegal
            `F7_ALT: begin
              case (func3)
                `F3_SUB: ALUOpcode32 = `ALU_SUB;
                `F3_SRA: ALUOpcode32 = `ALU_SRA;
                default: isIllegal32 = 1'b1;
              endcase
            end
            // Any other func7 (e.g. 0000001 = M extension) is illegal in RV32I base
            default: isIllegal32 = 1'b1;
          endcase
        end

        // ── SYSTEM ───────────────────────────────────────────────────────────────
        // ECALL, EBREAK, MRET, WFI, and all CSR instructions share this opcode.
        // We first check the full 32-bit encoding for the no-operand instructions,
        // then fall through to func3-based CSR decode for everything else.
        `OP_SYSTEM: begin
          case (instrWord)
            `INSTR_ECALL:  begin isECALL32  = 1'b1;                 end
            `INSTR_EBREAK: begin isEBREAK32 = 1'b1;  HALT32 = 1'b1; end
            `INSTR_MRET:   begin isMRET32   = 1'b1;                 end
            `INSTR_WFI:    begin /* WFI: treat as NOP in Phase 1 */ end
            default: begin
              if (func3 != 3'b000) begin
                destRegWrite32 = 1'b1;              // old CSR value written to rd
                isCSR32        = 1'b1;
                CSRAddr32      = instrWord[31:20];
                CSROp32        = func3[1:0];        // 01=RW, 10=RS, 11=RC
                CSRUseImm32    = func3[2];          // 1 = CSRRWI / CSRRSI / CSRRCI
              end else begin
                isIllegal32    = 1'b1;  // func3=000 with no matching full encoding
              end
            end
          endcase
        end

        // ── FENCE / FENCE.I ──────────────────────────────────────────────────────
        // Treated as NOP in Phase 1: single-core in-order pipeline has no reordering
        `OP_FENCE: begin /* NOP */ end

        // ── Unknown / reserved opcode ─────────────────────────────────────────────
        default: isIllegal32 = 1'b1;
      endcase
    end
  // =============================================================================
  // ── 32-BIT DECODE PATH ───────────────────────────────────────────────────────
  // =============================================================================


  // =============================================================================
  // ── 16-BIT (COMPRESSED) DECODE PATH ─────────────────────────────────────────
  // =============================================================================
  // Organised by quadrant first, then funct3, then sub-group bits as needed.
  // Each instruction is decoded directly to equivalent control signals.
  //
  // Key register encoding rules (same as decoder_if):
  //   Restricted (CL/CS/CB/CIW): 3-bit field → {2'b01, field} = x8–x15
  //   Full (CR/CI/CSS/Q2):       5-bit field from instrWord[11:7] or [6:2]
  // =============================================================================
    reg [31:0] immC;
    reg        destRegWriteC, memReadC,     memWriteC,    isBranchC,   isJumpC;
    reg        ALUBSelC,      memToRegC;
    reg [3:0]  ALUOpcodeC;
    reg [2:0]  branchCondC;
    reg        isJALRC,       isLinkC;
    reg [2:0]  loadWidthC;
    reg [1:0]  storeWidthC;
    reg        isEBREAKC,     isIllegalC,   HALTC;

    always @(*) begin
      // ── Safe defaults ──────────────────────────────────────────────────────────
      immC          = 32'h0;
      destRegWriteC = 1'b0;   memReadC      = 1'b0;   memWriteC   = 1'b0;
      isBranchC     = 1'b0;   isJumpC       = 1'b0;
      ALUBSelC      = 1'b0;   memToRegC     = 1'b0;   ALUOpcodeC  = `ALU_ADD;
      branchCondC   = 3'd0;   isJALRC       = 1'b0;   isLinkC     = 1'b0;
      loadWidthC    = 3'd0;   storeWidthC   = 2'd0;
      isEBREAKC     = 1'b0;   isIllegalC    = 1'b0;   HALTC       = 1'b0;

      case (compressedQuadrant)
        // =======================================================================
        // QUADRANT 0  (instrWord[1:0] = 2'b00)
        // =======================================================================
        `CQ0: begin
          case (compressedFunct3)
            // C.ADDI4SPN: rd' = sp + nzuimm[9:2]  →  ADDI rd', x2, nzuimm
            `CF3_C_ADDI4SPN: begin
              immC       = immCAddi4Spn; destRegWriteC = 1'b1; ALUBSelC = 1'b1;
              ALUOpcodeC = `ALU_ADD;
            end
            // C.LW: rd' = mem[rs1' + uimm]  →  LW rd', uimm(rs1')
            `CF3_C_LW: begin
              immC       = immCLW;       destRegWriteC = 1'b1; ALUBSelC   = 1'b1;
              ALUOpcodeC = `ALU_ADD;     memReadC      = 1'b1; memToRegC  = 1'b1;
              loadWidthC = `WIDTH_W;
            end
            // C.SW: mem[rs1' + uimm] = rs2'  →  SW rs2', uimm(rs1')
            `CF3_C_SW: begin
              immC        = immCLW;      ALUBSelC      = 1'b1; ALUOpcodeC = `ALU_ADD;
              memWriteC   = 1'b1;        storeWidthC   = 2'b10;      // SW = word
            end
            // Reserved Q0 encodings — treat as NOP in Phase 1
            default: begin end
          endcase
        end
        // =======================================================================
        // QUADRANT 0
        // =======================================================================


        // =======================================================================
        // QUADRANT 1  (instrWord[1:0] = 2'b01)
        // =======================================================================
        `CQ1: begin
          case (compressedFunct3)
            // C.NOP (rd=0, imm=0) / C.ADDI (rd≠0): rd = rd + sext(imm6)  →  ADDI rd, rd, imm
            `CF3_C_ADDI: begin
              immC       = immCI6;   destRegWriteC = 1'b1; ALUBSelC = 1'b1;
              ALUOpcodeC = `ALU_ADD;
            end
            // C.JAL (RV32C only): x1 = PC+2;  PC = PC + sext(imm12)  →  JAL x1, offset
            `CF3_C_JAL: begin
              immC       = immCJ;    destRegWriteC = 1'b1; isJumpC  = 1'b1;
              isLinkC    = 1'b1;
            end
            // C.LI: rd = sext(imm6)  →  ADDI rd, x0, imm
            // ALU computes 0 + imm = imm  (srcReg1 is x0 from StageIII_)
            `CF3_C_LI: begin
              immC       = immCI6;   destRegWriteC = 1'b1; ALUBSelC = 1'b1;
              ALUOpcodeC = `ALU_ADD;
            end
            // C.ADDI16SP (rd=x2) / C.LUI (rd≠x0, rd≠x2) — both use funct3=011
            // Distinguished by rd field; cpu.v passes StageIII_destRegIndex to tell them apart.
            `CF3_C_ADDI16SP: begin
              destRegWriteC = 1'b1;  ALUBSelC      = 1'b1;
              if (compressedDestRegFull == 5'd2) begin
                // C.ADDI16SP: sp = sp + sext(nzimm10)
                immC        = immCAddi16Sp;
                ALUOpcodeC  = `ALU_ADD;
              end else begin
                // C.LUI: rd = {nzimm[17:12], 12'b0}
                immC        = immCLui;
                ALUOpcodeC  = `ALU_PASS_B;
              end
            end
            // C.ARITH: C.SRLI / C.SRAI / C.ANDI / C.SUB / C.XOR / C.OR / C.AND
            `CF3_C_ARITH: begin
              destRegWriteC = 1'b1;
              case (instrWord[11:10])
                2'b00: begin ALUOpcodeC = `ALU_SRL; immC = immCShamt; ALUBSelC = 1'b1; end  // C.SRLI
                2'b01: begin ALUOpcodeC = `ALU_SRA; immC = immCShamt; ALUBSelC = 1'b1; end  // C.SRAI
                2'b10: begin ALUOpcodeC = `ALU_AND; immC = immCI6;    ALUBSelC = 1'b1; end  // C.ANDI
                2'b11: begin
                  // C.SUB / C.XOR / C.OR / C.AND — register-register variants
                  case (instrWord[6:5])
                    2'b00: ALUOpcodeC   = `ALU_SUB;                                         // C.SUB
                    2'b01: ALUOpcodeC   = `ALU_XOR;                                         // C.XOR
                    2'b10: ALUOpcodeC   = `ALU_OR;                                          // C.OR
                    2'b11: ALUOpcodeC   = `ALU_AND;                                         // C.AND
                    default: begin end
                  endcase
                end
                default: begin end
              endcase
            end
            // C.J: PC = PC + sext(imm12)  →  JAL x0, offset  (unconditional, no link)
            `CF3_C_J: begin
              immC  = immCJ; isJumpC   = 1'b1;
            end
            // C.BEQZ: if (rs1' == 0): PC = PC + sext(imm9)  →  BEQ rs1', x0, offset
            `CF3_C_BEQZ: begin
              immC  = immCB; isBranchC = 1'b1; branchCondC = `F3_BEQ;
            end
            // C.BNEZ: if (rs1' != 0): PC = PC + sext(imm9)  →  BNE rs1', x0, offset
            `CF3_C_BNEZ: begin
              immC  = immCB; isBranchC = 1'b1; branchCondC = `F3_BNE;
            end
            default: begin end
          endcase
        end
        // =======================================================================
        // QUADRANT 1
        // =======================================================================


        // =======================================================================
        // QUADRANT 2  (instrWord[1:0] = 2'b10)
        // =======================================================================
        `CQ2: begin
          case (compressedFunct3)
            // C.SLLI: rd <<= shamt  →  SLLI rd, rd, shamt
            `CF3_C_SLLI: begin
              immC       = immCShamt; destRegWriteC = 1'b1; ALUBSelC  = 1'b1;
              ALUOpcodeC = `ALU_SLL;
            end
            // C.LWSP: rd = mem[sp + uimm]  →  LW rd, uimm(sp)
            `CF3_C_LWSP: begin
              immC       = immCLwsp;  destRegWriteC = 1'b1; ALUBSelC  = 1'b1;
              ALUOpcodeC = `ALU_ADD;  memReadC      = 1'b1; memToRegC = 1'b1;
              loadWidthC = `WIDTH_W;
            end
            // C.MISC: C.JR / C.MV / C.EBREAK / C.JALR / C.ADD
            `CF3_C_MISC: begin
              if (!instrWord[12]) begin
                if (compressedSrcReg2Full == 5'd0) begin
                  // C.JR: PC = rs1  →  JALR x0, rs1, 0  (no link, imm=0)
                  isJumpC       = 1'b1; isJALRC     = 1'b1;
                end else begin
                  // C.MV: rd = rs2  →  ADD rd, x0, rs2
                  destRegWriteC = 1'b1; ALUOpcodeC  = `ALU_ADD;
                end
              end else begin
                if (compressedDestRegFull == 5'd0 && compressedSrcReg2Full == 5'd0) begin
                  // C.EBREAK
                  isEBREAKC     = 1'b1; HALTC       = 1'b1;
                end else if (compressedSrcReg2Full == 5'd0) begin
                  // C.JALR: x1 = PC+2;  PC = rs1  →  JALR x1, rs1, 0
                  destRegWriteC = 1'b1; isJumpC     = 1'b1;
                  isJALRC       = 1'b1; isLinkC     = 1'b1;
                end else begin
                  // C.ADD: rd = rd + rs2  →  ADD rd, rd, rs2
                  destRegWriteC = 1'b1; ALUOpcodeC  = `ALU_ADD;
                end
              end
            end
            // C.SWSP: mem[sp + uimm] = rs2  →  SW rs2, uimm(sp)
            `CF3_C_SWSP: begin
              immC        = immCSwsp;   ALUBSelC    = 1'b1;  ALUOpcodeC = `ALU_ADD;
              memWriteC   = 1'b1;       storeWidthC = 2'b10;          // SW = word
            end
            default: begin end
          endcase
        end
        // =======================================================================
        // QUADRANT 2
        // =======================================================================


        // Quadrant 3 cannot appear here: is_compressed = 0 for [1:0] = 2'b11
        default: begin end
      endcase
    end
  // =============================================================================
  // ── 16-BIT (COMPRESSED) DECODE PATH ─────────────────────────────────────────
  // =============================================================================


  // =============================================================================
  // ── OUTPUT MUX ───────────────────────────────────────────────────────────────
  // =============================================================================
  // Selects between the 32-bit and 16-bit decode results based on is_compressed.
  // immediate2 is computed here as selectedImmediate + 2, which avoids a
  // separate imm2 register in both decode paths — the single adder is cheap.
  // All outputs are registered into StageIV_ by the ID stage in cpu.v.
  // =============================================================================
    always @(*) begin
      if (is_compressed) begin
        immediate         = immC;           immediate2      = immC + 32'h2;
        CTRL_destRegWrite = destRegWriteC;  CTRL_memRead    = memReadC;     CTRL_memWrite  = memWriteC;
        CTRL_isBranch     = isBranchC;      CTRL_isJump     = isJumpC;
        CTRL_ALUBSel      = ALUBSelC;       CTRL_memToReg   = memToRegC;    CTRL_ALUOpcode = ALUOpcodeC;
        CTRL_branchCond   = branchCondC;    CTRL_isJALR     = isJALRC;      CTRL_isLink    = isLinkC;
        CTRL_loadWidth    = loadWidthC;     CTRL_storeWidth = storeWidthC;
        CTRL_isCSR        = 1'b0;           CTRL_CSRAddr    = 12'd0;
        CTRL_CSROp        = 2'd0;           CTRL_CSRUseImm  = 1'b0;         // no CSR instructions in RV32C
        CTRL_isAUIPC      = 1'b0;    // no AUIPC in RV32C
        CTRL_isECALL      = 1'b0;    // no ECALL in RV32C
        CTRL_isEBREAK     = isEBREAKC;
        CTRL_isMRET       = 1'b0;    // no MRET in RV32C
        CTRL_isIllegal    = isIllegalC;
        CTRL_HALT         = HALTC;
      end else begin
        immediate         = imm32;          immediate2      = imm32 + 32'h2;
        CTRL_destRegWrite = destRegWrite32; CTRL_memRead    = memRead32;    CTRL_memWrite  = memWrite32;
        CTRL_isBranch     = isBranch32;     CTRL_isJump     = isJump32;
        CTRL_ALUBSel      = ALUBSel32;      CTRL_memToReg   = memToReg32;   CTRL_ALUOpcode = ALUOpcode32;
        CTRL_branchCond   = branchCond32;   CTRL_isJALR     = isJALR32;     CTRL_isLink    = isLink32;
        CTRL_loadWidth    = loadWidth32;    CTRL_storeWidth = storeWidth32;
        CTRL_isCSR        = isCSR32;        CTRL_CSRAddr    = CSRAddr32;
        CTRL_CSROp        = CSROp32;        CTRL_CSRUseImm  = CSRUseImm32;
        CTRL_isAUIPC      = isAUIPC32;
        CTRL_isECALL      = isECALL32;
        CTRL_isEBREAK     = isEBREAK32;
        CTRL_isMRET       = isMRET32;
        CTRL_isIllegal    = isIllegal32;
        CTRL_HALT         = HALT32;
      end
    end
  // =============================================================================
  // ── OUTPUT MUX ───────────────────────────────────────────────────────────────
  // =============================================================================
endmodule
