`include "isa.vh"
// ============================================================================
// PHANTOM-32  ──  Control Unit  (ID Stage)
// ============================================================================
// Full instruction decoder for both 32-bit (RV32I) and 16-bit compressed
// (RV32C) instructions.  Generates all pipeline control signals as a single
// purely combinational stage (no state, no clock).
//
// ── wb_sel encoding (writeback source mux) ──────────────────────────────────
//   2'b00  ALU result        arithmetic, logic, LUI, AUIPC
//   2'b01  Memory load data  LW / LH / LB / LHU / LBU / C.LW / C.LWSP
//   2'b10  Link address      PC+2 or PC+4
//   2'b11  CSR read data     CSRRW/RS/RC and immediate variants
//
// ── alu_src_a encoding ──────────────────────────────────────────────────────
//   1'b0  rs1 (after forwarding mux)   all instructions except AUIPC
//   1'b1  PC                           AUIPC only
//
// ── Notes for the top-level integration ─────────────────────────────────────
//   • branch_type [2:0] uses the RV32I func3 encoding, fed directly to
//     branch_eval.  C.BEQZ/BNEZ set branch_type = F3_BEQ / F3_BNE with
//     rs2=x0 already provided by fast_decoder.
//   • csr_op [1:0] = func3[1:0], mapping: 01=RW  10=RS  11=RC - matches
//     the CSR_OP_* constants in isa.vh.
//   • RMW (CSRRS / CSRRC) is performed by the MA stage before calling
//     csr_regfile.wr_data, this module only asserts csr_en.
//   • mem_width carries the func3 value directly for loads and stores,
//     matching the WIDTH_* constants in isa.vh.
//   • is_illegal is forwarded to trap_unit in MA; the MA stage suppresses
//     mem_read/mem_write for illegal instructions before they reach DMEM.
// ============================================================================
module control_unit (
  // ── Instruction from IF/ID pipeline register ──────────────────────────────
  input  logic [31:0] instrWord,     // raw 32-bit fetch word
 
  // ── EX stage control signals ──────────────────────────────────────────────
  output logic [3:0]  alu_op,        // ALU opcode  (`ALU_* constants)
  output logic        alu_src_a,     // 0 = rs1 (forwarded)   1 = PC  (AUIPC only)
  output logic        alu_src_b,     // 0 = rs2 (forwarded)   1 = immediate
  output logic        is_branch,     // instruction is a conditional branch
  output logic [2:0]  branch_type,   // branch condition code → branch_eval
  output logic        is_jump,       // unconditional jump  (JAL / JALR family)
  output logic        is_jalr,       // target = rs1+imm  (JALR / C.JALR / C.JR)
  output logic        is_muldiv,     // RV32M instruction

  // ── MA stage control signals ──────────────────────────────────────────────
  output logic        mem_read,      // 1 = load from data memory
  output logic        mem_write,     // 1 = store to data memory
  output logic [2:0]  mem_width,     // load/store width  (`WIDTH_* constants)
  output logic        csr_en,        // 1 = CSR read-modify-write active
  output logic [1:0]  csr_op,        // CSR operation  (`CSR_OP_* constants)
  output logic        csr_use_imm,   // 1 = use zimm field  (CSRRxI variants)
  output logic [11:0] csr_addr,      // CSR address from instrWord[31:20]
  output logic        is_ecall,      // ECALL exception
  output logic        is_ebreak,     // EBREAK / C.EBREAK exception
  output logic        is_mret,       // MRET return from trap handler
  output logic        is_illegal,    // unrecognized / reserved encoding → trap
 
  // ── WB stage control signals ──────────────────────────────────────────────
  output logic        reg_write,     // 1 = write result to rd in regfile
  output logic [1:0]  wb_sel         // writeback source select  (see header)
);

  // ==========================================================================
  // FIELD EXTRACTION
  // ==========================================================================
    logic [6:0] op32;    assign op32    = instrWord[6:0];
    logic [2:0] func3;   assign func3   = instrWord[14:12];
    logic       func7b5; assign func7b5 = instrWord[30];
    logic [1:0] quad;    assign quad    = instrWord[1:0];
    logic [2:0] cfunc3;  assign cfunc3  = instrWord[15:13];
  // ==========================================================================
  // FIELD EXTRACTION
  // ==========================================================================
 

  // ==========================================================================
  // COMBINATIONAL DECODE
  // ==========================================================================
    always_comb begin
      // ── NOP defaults - only departures are listed per opcode ──────────────
      alu_op      = `ALU_ADD; alu_src_a   = 1'b0;    alu_src_b   = 1'b0;
      reg_write   = 1'b0;     wb_sel      = 2'b00;
      mem_read    = 1'b0;     mem_write   = 1'b0;    mem_width   = `WIDTH_W;
      is_branch   = 1'b0;     branch_type = 3'b000;
      is_jump     = 1'b0;     is_jalr     = 1'b0;    is_muldiv   = 1'b0;
      csr_en      = 1'b0;     csr_op      = 2'b00;
      csr_use_imm = 1'b0;     csr_addr    = 12'h000;
      is_ecall    = 1'b0;     is_ebreak   = 1'b0;    is_mret     = 1'b0;
      is_illegal  = 1'b0;

      case (quad)
        // ====================================================================
        // QUADRANT 0  (instrWord[1:0] = 2'b00)
        // ====================================================================
        `CQ0: begin
          case (cfunc3)
            `CF3_C_ADDI4SPN: begin      // rd' = sp + nzuimm8
              if (instrWord[12:5] == 8'd0) begin
                is_illegal = 1'b1;      // nzuimm=0 reserved per RVC spec
              end else begin
                alu_op  = `ALU_ADD; alu_src_b = 1'b1; reg_write = 1'b1;
              end
            end
            `CF3_C_LW:       begin      // rd' = mem32[rs1' + uimm5]
              alu_op    = `ALU_ADD; alu_src_b = 1'b1; reg_write = 1'b1;
              mem_width = `WIDTH_W; mem_read  = 1'b1; wb_sel    = 2'b01;
            end
            `CF3_C_SW:       begin      // mem32[rs1' + uimm5] = rs2'
              alu_op    = `ALU_ADD; alu_src_b = 1'b0; mem_write = 1'b1;
              mem_width = `WIDTH_W;
            end
            default: is_illegal = 1'b1; // all other cfunc3 reserved
          endcase
        end
        // ====================================================================
        // QUADRANT 0  (instrWord[1:0] = 2'b00)
        // ====================================================================
 
        // ====================================================================
        // QUADRANT 1  (instrWord[1:0] = 2'b01)
        // ====================================================================
        `CQ1: begin
          case (cfunc3)
            `CF3_C_ADDI:     begin      // rd = rd + nzimm6 (C.NOP when rd=x0 and imm=0)
              alu_op    = `ALU_ADD; alu_src_b = 1'b1; reg_write = 1'b1;
            end
            `CF3_C_JAL:      begin      // x1 = PC + 2, PC = PC + offset11
              is_jump   = 1'b1;     wb_sel   = 2'b10; reg_write = 1'b1;
            end
            `CF3_C_LI:       begin      // rd = imm6 (rs1 = x0 -> 0 + imm = imm)
              alu_op    = `ALU_ADD; alu_src_b = 1'b1; reg_write = 1'b1;
            end
            `CF3_C_ADDI16SP: begin
              // C.ADDI16SP (rd == x2): sp = sp + nzimm10
              // C.LUI      (rd != x2): rd = nzimm18
              alu_op    = `ALU_ADD; alu_src_b = 1'b1; reg_write = 1'b1;
            end
            `CF3_C_ARITH:    begin
              reg_write = 1'b1;
              case (instrWord[11:10])
                2'b00:       begin      // rd' >>= shamt (logical)
                  if (instrWord[12]) begin is_illegal = 1'b1;     reg_write = 1'b0; end
                  else               begin alu_op     = `ALU_SRL; alu_src_b = 1'b1; end
                end
                2'b01:       begin      // rd' >>= shamt (arithmetic)
                  if (instrWord[12]) begin is_illegal = 1'b1;     reg_write = 1'b0; end
                  else               begin alu_op     = `ALU_SRA; alu_src_b = 1'b1; end
                end
                2'b10:       begin      // rd' &=  imm6
                  alu_op = `ALU_AND; alu_src_b = 1'b1;
                end
                default:     begin      // 2-register ops
                  case (instrWord[6:5])
                    2'b00: alu_op = `ALU_SUB;
                    2'b01: alu_op = `ALU_XOR;
                    2'b10: alu_op = `ALU_OR;
                    2'b11: alu_op = `ALU_AND;
                  endcase
                end
              endcase
            end
            `CF3_C_J:        begin      // PC = PC + offset11
              is_jump   = 1'b1;
            end
            `CF3_C_BEQZ:     begin      // if (rs1' == 0) branch
              is_branch = 1'b1; branch_type = `F3_BEQ;
            end
            `CF3_C_BNEZ:     begin
              is_branch = 1'b1; branch_type = `F3_BNE;
            end
            default: is_illegal = 1'b1;
          endcase
        end
        // ====================================================================
        // QUADRANT 1  (instrWord[1:0] = 2'b01)
        // ====================================================================

        // ====================================================================
        // QUADRANT 2  (instrWord[1:0] = 2'b10)
        // ====================================================================
        `CQ2: begin
          case (cfunc3)
            `CF3_C_SLLI:      begin     // rd = rd << shamt
              if (instrWord[12]) is_illegal = 1'b1;
              else begin
                alu_op    = `ALU_SLL; alu_src_b = 1'b1; reg_write = 1'b1;
              end
            end
            `CF3_C_LWSP:      begin     // rd = mem32[sp + uimm6]
              if (instrWord[11:7] == 5'd0) is_illegal = 1'b1;
              else begin
                alu_op    = `ALU_ADD; alu_src_b = 1'b1; reg_write = 1'b1;
                mem_width = `WIDTH_W; mem_read  = 1'b1; wb_sel    = 2'b01;
              end
            end
            `CF3_C_MISC:      begin
              if (instrWord[12] == 1'b0) begin
                if (instrWord[6:2] == 5'd0) begin // C.JR PC = rs1
                  if (instrWord[11:7] == 5'd0) is_illegal = 1'b1;
                  else begin
                    is_jump = 1'b1;   is_jalr   = 1'b1;
                  end
                end else begin                    // C.MV rd = rs2
                  alu_op  = `ALU_ADD; alu_src_b = 1'b0; reg_write = 1'b1;
                end
              end else begin
                if (instrWord[11:7] == 5'd0 && instrWord[6:2] == 5'd0) begin
                  // C.EBREAK
                  is_ebreak = 1'b1;
                end else if (instrWord[6:2] == 5'd0) begin
                  // C.JALR x1 = PC + 2, PC = rs1
                  is_jump = 1'b1;     is_jalr   = 1'b1; reg_write = 1'b1;
                  wb_sel  = 2'b10;
                end else begin
                  // C.ADD  rd = rd + rs2
                  alu_op  = `ALU_ADD; alu_src_b = 1'b0; reg_write = 1'b1;
                end
              end
            end
            `CF3_C_SWSP:      begin     // mem32[sp + uimm6] = rs2
              alu_op    = `ALU_ADD; alu_src_b = 1'b0; mem_write = 1'b1;
              mem_width = `WIDTH_W;
            end
            default: is_illegal = 1'b1;
          endcase
        end
        // ====================================================================
        // QUADRANT 2  (instrWord[1:0] = 2'b10)
        // ====================================================================

        // ====================================================================
        // 32-BIT PATH  (instrWord[1:0] = 2'b11)
        // ====================================================================
        default: begin
          case (op32)
            `OP_LUI:     begin // rd = imm20 << 12
              alu_op = `ALU_PASS_B; alu_src_b = 1'b1; reg_write = 1'b1;
            end
            `OP_AUIPC:   begin // rd = PC + (imm20 << 12)
              alu_op    = `ALU_ADD; alu_src_a = 1'b1; alu_src_b = 1'b1;
              reg_write = 1'b1;
            end
            `OP_JAL:     begin // rd = PC + 4, PC = PC + imm21
              is_jump   = 1'b1;     reg_write = 1'b1; wb_sel    = 2'b10;
            end
            `OP_JALR:    begin // rd = PC + 4, PC = (rs1 + imm12) & ~1;
              if (func3 == `F3_JALR) begin
                is_jump = 1'b1;     reg_write = 1'b1; wb_sel    = 2'b10;
                is_jalr = 1'b1;
              end else begin
                is_illegal = 1'b1; // func3 != 000 is reserved
              end
            end
            `OP_BRANCH:  begin
              case (func3)
                `F3_BEQ, `F3_BNE, `F3_BLT, `F3_BGE, `F3_BLTU, `F3_BGEU: begin
                  is_branch = 1'b1; branch_type = func3;
                end
                default: is_illegal = 1'b1;
              endcase
            end
            `OP_LOAD:    begin
              case (func3)
                `F3_LB, `F3_LH, `F3_LW, `F3_LBU, `F3_LHU: begin
                  alu_op = `ALU_ADD; alu_src_b = 1'b1; reg_write = 1'b1;
                  mem_width = func3; mem_read  = 1'b1; wb_sel    = 2'b01;
                end
                default: is_illegal = 1'b1;
              endcase
            end
            `OP_STORE:   begin
              case (func3)
                `F3_SB, `F3_SH, `F3_SW: begin
                  alu_op = `ALU_ADD; alu_src_b = 1'b0; mem_write = 1'b1;
                  mem_width = func3;
                end
                default: is_illegal = 1'b1;
              endcase
            end
            `OP_ARITH_I: begin
              alu_src_b = 1'b1; reg_write = 1'b1;
              case (func3)
                `F3_ADDI:  alu_op = `ALU_ADD;
                `F3_SLTI:  alu_op = `ALU_SLT;
                `F3_SLTIU: alu_op = `ALU_SLTU;
                `F3_XORI:  alu_op = `ALU_XOR;
                `F3_ORI:   alu_op = `ALU_OR;
                `F3_ANDI:  alu_op = `ALU_AND;
                `F3_SLLI:  begin
                  if (instrWord[31:25] != 7'b0000000) begin
                    reg_write = 1'b0; is_illegal = 1'b1;
                  end else begin
                    alu_op = `ALU_SLL;
                  end
                end
                `F3_SRLI:  begin
                  if      (instrWord[31:25] == 7'b0000000) alu_op = `ALU_SRL;
                  else if (instrWord[31:25] == 7'b0100000) alu_op = `ALU_SRA;
                  else begin
                    reg_write = 1'b0; is_illegal = 1'b1;
                  end
                end
                default:   begin
                  reg_write = 1'b0; is_illegal = 1'b1;
                end
              endcase
            end
            `OP_ARITH_R: begin
              if (instrWord[31:25] == 7'b0000001) begin
                is_muldiv = 1'b1; reg_write = 1'b1;
              end else if (instrWord[31:25] == `F7_NORMAL || (instrWord[31:25] == `F7_ALT &&
                          (func3 == `F3_ADD || func3 == `F3_SRL))) begin
                alu_src_b = 1'b0; reg_write = 1'b1;
                case (func3)
                  `F3_ADD:   alu_op = func7b5 ? `ALU_SUB : `ALU_ADD;
                  `F3_SLL:   alu_op = `ALU_SLL;
                  `F3_SLT:   alu_op = `ALU_SLT;
                  `F3_SLTU:  alu_op = `ALU_SLTU;
                  `F3_XOR:   alu_op = `ALU_XOR;
                  `F3_SRL:   alu_op = func7b5 ? `ALU_SRA : `ALU_SRL;
                  `F3_OR:    alu_op = `ALU_OR;
                  `F3_AND:   alu_op = `ALU_AND;
                  default: begin
                    reg_write = 1'b0; is_illegal = 1'b1;
                  end
                endcase
              end else begin
                is_illegal = 1'b1;
              end
            end
            `OP_SYSTEM:  begin
              case (func3)
                `F3_ECALL: begin
                  case (instrWord)
                    `INSTR_ECALL:  is_ecall  = 1'b1;
                    `INSTR_EBREAK: is_ebreak = 1'b1;
                    `INSTR_MRET:   is_mret   = 1'b1;
                    `INSTR_WFI:    ; // WFI treated as NOP in Phase 1
                    default: is_illegal = 1'b1;
                  endcase
                end
                `F3_CSRRW, `F3_CSRRS, `F3_CSRRC,
                `F3_CSRRWI, `F3_CSRRSI, `F3_CSRRCI: begin
                  csr_en = 1'b1;  csr_op    = func3[1:0]; csr_use_imm = func3[2];
                  wb_sel = 2'b11; reg_write = 1'b1;       csr_addr    = instrWord[31:20];
                end
                default: is_illegal = 1'b1;
              endcase
            end
            `OP_FENCE:   begin
              // FENCE and FENCE.I both treated as NOPs; No ordering guarantees
              // needed in a single-hart in-order pipeline with no I-Cache
              if (func3 != 3'b000 && func3 != 3'b001) is_illegal = 1'b1;
            end
            default: is_illegal = 1'b1;
          endcase
        end
        // ====================================================================
        // 32-BIT PATH  (instrWord[1:0] = 2'b11)
        // ====================================================================

      endcase
    end
  // ==========================================================================
  // COMBINATIONAL DECODE
  // ==========================================================================

endmodule
