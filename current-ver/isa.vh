`ifndef ISA_VH
`define ISA_VH
// =============================================================================
// PHANTOM-32  ──  ISA Constants
// =============================================================================
// Central header included by every module.  All opcode maps, ALU codes,
// control-signal widths, CSR addresses, trap codes, and magic encodings
// live here
// =============================================================================


// =============================================================================
// ── RV32I PRIMARY OPCODES  [6:0] ─────────────────────────────────────────────
// =============================================================================
// Bits [1:0] of every 32-bit instruction are always 2'b11.
// Bits [1:0] of every 16-bit compressed instruction are NOT 2'b11.
// The decoder uses this to distinguish instruction widths before anything else.
// =============================================================================
`define OP_LUI      7'b0110111   // U-type: Load Upper Immediate
`define OP_AUIPC    7'b0010111   // U-type: Add Upper Immediate to PC
`define OP_JAL      7'b1101111   // J-type: Jump And Link (PC-relative)
`define OP_JALR     7'b1100111   // I-type: Jump And Link Register (indirect)
`define OP_BRANCH   7'b1100011   // B-type: all conditional branches
`define OP_LOAD     7'b0000011   // I-type: all loads (LB/LH/LW/LBU/LHU)
`define OP_STORE    7'b0100011   // S-type: all stores (SB/SH/SW)
`define OP_ARITH_I  7'b0010011   // I-type: register-immediate arithmetic
`define OP_ARITH_R  7'b0110011   // R-type: register-register arithmetic
`define OP_SYSTEM   7'b1110011   // I-type: ECALL, EBREAK, MRET, CSR*
`define OP_FENCE    7'b0001111   // I-type: FENCE, FENCE.I (NOP in Phase 1)


// =============================================================================
// ── FUNC3 FIELDS ─────────────────────────────────────────────────────────────
// =============================================================================
// func3 [14:12] disambiguates instructions that share an opcode.
// Named constants prevent confusion between, e.g., ADD func3 and BEQ func3
// even though both happen to be 3'b000.
// =============================================================================

// ── Branch func3 ─────────────────────────────────────────────────────────────
`define F3_BEQ      3'b000
`define F3_BNE      3'b001
`define F3_BLT      3'b100
`define F3_BGE      3'b101
`define F3_BLTU     3'b110
`define F3_BGEU     3'b111

// ── Load func3 ───────────────────────────────────────────────────────────────
`define F3_LB       3'b000
`define F3_LH       3'b001
`define F3_LW       3'b010
`define F3_LBU      3'b100
`define F3_LHU      3'b101

// ── Store func3 ──────────────────────────────────────────────────────────────
`define F3_SB       3'b000
`define F3_SH       3'b001
`define F3_SW       3'b010

// ── Register-immediate arithmetic func3 ──────────────────────────────────────
`define F3_ADDI     3'b000
`define F3_SLTI     3'b010
`define F3_SLTIU    3'b011
`define F3_XORI     3'b100
`define F3_ORI      3'b110
`define F3_ANDI     3'b111
`define F3_SLLI     3'b001   // func7 must be 7'b0000000
`define F3_SRLI     3'b101   // func7 = 7'b0000000 → logical
`define F3_SRAI     3'b101   // func7 = 7'b0100000 → arithmetic (same func3 as SRLI)

// ── Register-register arithmetic func3 ───────────────────────────────────────
// ADD and SUB share func3 = 000; they are told apart by func7 bit 30.
// SRL and SRA share func3 = 101; same story.
`define F3_ADD      3'b000
`define F3_SUB      3'b000   // same as ADD — distinguished by F7_SUB below
`define F3_SLL      3'b001
`define F3_SLT      3'b010
`define F3_SLTU     3'b011
`define F3_XOR      3'b100
`define F3_SRL      3'b101
`define F3_SRA      3'b101   // same as SRL — distinguished by F7_SRA below
`define F3_OR       3'b110
`define F3_AND      3'b111

// ── System / CSR func3 ───────────────────────────────────────────────────────
`define F3_ECALL    3'b000   // also covers EBREAK and MRET (full encoding distinguishes them)
`define F3_CSRRW    3'b001
`define F3_CSRRS    3'b010
`define F3_CSRRC    3'b011
`define F3_CSRRWI   3'b101
`define F3_CSRRSI   3'b110
`define F3_CSRRCI   3'b111

// ── JALR func3 (must be 000 — any other value is illegal) ────────────────────
`define F3_JALR     3'b000


// =============================================================================
// ── FUNC7 FIELDS ─────────────────────────────────────────────────────────────
// =============================================================================
// Only bits [31:25] of R-type and shift-immediate instructions.
// We only care about bit 30 in practice: it toggles ADD-SUB and SRL-SRA.
// =============================================================================
`define F7_NORMAL   7'b0000000   // ADD, SRL, SLLI, SRLI (and all others)
`define F7_ALT      7'b0100000   // SUB, SRA, SRAI


// =============================================================================
// ── FULL INSTRUCTION ENCODINGS  (for SYSTEM instructions) ────────────────────
// =============================================================================
// These instructions are recognised by their complete 32-bit encoding,
// not just opcode + func3, because they share both.
// =============================================================================
`define INSTR_ECALL   32'h0000_0073
`define INSTR_EBREAK  32'h0010_0073
`define INSTR_MRET    32'h3020_0073
`define INSTR_WFI     32'h1050_0073   // Wait For Interrupt (treat as NOP in current version)
`define INSTR_FENCEI  32'h0000_100F   // FENCE.I (treat as NOP in current version)


// =============================================================================
// ── RV32C COMPRESSED INSTRUCTION QUADRANTS ───────────────────────────────────
// =============================================================================
// The bottom 2 bits of a compressed instruction identify its quadrant.
// Quadrant 3 (2'b11) is reserved for 32-bit instructions — never a C instr.
// =============================================================================
`define CQ0   2'b00   // Quadrant 0
`define CQ1   2'b01   // Quadrant 1
`define CQ2   2'b10   // Quadrant 2

// ── Compressed funct3 [15:13] ────────────────────────────────────────────────
// Quadrant 0
`define CF3_C_ADDI4SPN  3'b000
`define CF3_C_LW        3'b010
`define CF3_C_SW        3'b110
// Quadrant 1
`define CF3_C_ADDI      3'b000   // also C.NOP when rd=0 and imm=0
`define CF3_C_JAL       3'b001   // RV32C only
`define CF3_C_LI        3'b010
`define CF3_C_ADDI16SP  3'b011   // when rd = x2; otherwise C.LUI
`define CF3_C_LUI       3'b011   // when rd ≠ x0 and rd ≠ x2
`define CF3_C_ARITH     3'b100   // C.SRLI / C.SRAI / C.ANDI / C.SUB / C.XOR / C.OR / C.AND
`define CF3_C_J         3'b101
`define CF3_C_BEQZ      3'b110
`define CF3_C_BNEZ      3'b111
// Quadrant 2
`define CF3_C_SLLI      3'b000
`define CF3_C_LWSP      3'b010
`define CF3_C_MISC      3'b100   // C.JR / C.MV / C.EBREAK / C.JALR / C.ADD
`define CF3_C_SWSP      3'b110


// =============================================================================
// ── ALU OPERATION CODES  [3:0] ───────────────────────────────────────────────
// =============================================================================
// These codes travel through the pipeline in StageIV_ALUOpcode and are
// presented to the ALU module in the EX stage.  The ALU is purely
// combinational: opcode in → result out, no state.
// =============================================================================
`define ALU_ADD     4'h0   // a + b                            (ADD, ADDI, loads, stores, AUIPC, JALR)
`define ALU_SUB     4'h1   // a - b                            (SUB)
`define ALU_AND     4'h2   // a & b                            (AND, ANDI)
`define ALU_OR      4'h3   // a | b                            (OR, ORI)
`define ALU_XOR     4'h4   // a ^ b                            (XOR, XORI)
`define ALU_SLL     4'h5   // a << b[4:0]                      (SLL, SLLI)
`define ALU_SRL     4'h6   // a >> b[4:0] (logical, zero-fill) (SRL, SRLI)
`define ALU_SRA     4'h7   // a >> b[4:0] (arith, sign-fill)   (SRA, SRAI)
`define ALU_SLT     4'h8   // ($signed(a) < $signed(b)) ? 1:0  (SLT, SLTI)
`define ALU_SLTU    4'h9   // (a < b) ? 1 : 0  unsigned        (SLTU, SLTIU)
`define ALU_PASS_B  4'hA   // b (pass-through)                 (LUI — rs1 unused)


// =============================================================================
// ── LOAD / STORE WIDTH CODES  [2:0] ──────────────────────────────────────────
// =============================================================================
// These match the func3 field of the load/store instruction directly,
// so the decoder can just wire func3 straight into StageIV_loadWidth /
// StageIV_storeWidth without any translation.
// =============================================================================
`define WIDTH_B     3'b000   // byte,     signed  (LB / SB)
`define WIDTH_H     3'b001   // halfword, signed  (LH / SH)
`define WIDTH_W     3'b010   // word              (LW / SW)
`define WIDTH_BU    3'b100   // byte,     unsigned (LBU)
`define WIDTH_HU    3'b101   // halfword, unsigned (LHU)


// =============================================================================
// ── CSR OPERATION CODES  [1:0] ───────────────────────────────────────────────
// =============================================================================
// Maps from func3[1:0] to the CSR operation.  func3 bit 2 distinguishes
// register-source (0) from immediate-source (1) — handled separately by
// StageIV_CSR_useImm.
// =============================================================================
`define CSR_OP_RW   2'b01   // Read-Write  (CSRRW / CSRRWI)
`define CSR_OP_RS   2'b10   // Read-Set    (CSRRS / CSRRSI)
`define CSR_OP_RC   2'b11   // Read-Clear  (CSRRC / CSRRCI)


// =============================================================================
// ── CSR ADDRESSES  [11:0] ────────────────────────────────────────────────────
// =============================================================================
`define CSR_MSTATUS    12'h300
`define CSR_MISA       12'h301
`define CSR_MIE        12'h304
`define CSR_MTVEC      12'h305
`define CSR_MSCRATCH   12'h340
`define CSR_MEPC       12'h341
`define CSR_MCAUSE     12'h342
`define CSR_MTVAL      12'h343
`define CSR_MIP        12'h344
`define CSR_MVENDORID  12'hF11
`define CSR_MARCHID    12'hF12
`define CSR_MIMPID     12'hF13
`define CSR_MHARTID    12'hF14

// ── Read-only CSR values (hardwired, not stored in a register) ────────────────
`define CSR_VAL_MVENDORID  32'h0000_0000   // non-commercial implementation
`define CSR_VAL_MARCHID    32'h0000_0000
`define CSR_VAL_MIMPID     32'h0000_0001   // PHANTOM-32 revision 1
`define CSR_VAL_MHARTID    32'h0000_0000   // single hart
// misa: MXL=01 (32-bit), Extensions = I (bit 8) + C (bit 2) = 0x104
`define CSR_VAL_MISA       32'h4000_0104


// =============================================================================
// ── TRAP / EXCEPTION CAUSE CODES  [3:0] ──────────────────────────────────────
// =============================================================================
// These are the lower bits of mcause.  The MSB of mcause (bit 31) is 0 for
// synchronous exceptions and 1 for asynchronous interrupts.  Phase 1 has
// no interrupt sources, so bit 31 is always 0.
// =============================================================================
`define TRAP_INSTR_MISALIGN  4'd0    // PC not halfword-aligned (JAL/JALR target)
`define TRAP_INSTR_FAULT     4'd1    // instruction access fault (Phase 2+)
`define TRAP_ILLEGAL_INSTR   4'd2    // unrecognized or invalid instruction encoding
`define TRAP_BREAKPOINT      4'd3    // EBREAK instruction
`define TRAP_LOAD_MISALIGN   4'd4    // load effective address not naturally aligned
`define TRAP_LOAD_FAULT      4'd5    // load access fault (Phase 2+)
`define TRAP_STORE_MISALIGN  4'd6    // store effective address not naturally aligned
`define TRAP_STORE_FAULT     4'd7    // store access fault (Phase 2+)
`define TRAP_ECALL_M         4'd11   // ECALL from M-mode


// =============================================================================
// ── MAGIC INSTRUCTION ENCODINGS ──────────────────────────────────────────────
// =============================================================================
// A NOP bubble inserted into the pipeline is the canonical RISC-V NOP:
//   ADDI x0, x0, 0  →  0x00000013
// This encoding is safe to inject anywhere: it writes nothing, reads nothing,
// has no side effects, and the decoder will correctly produce all-zero control.
// =============================================================================
`define NOP_INSTR   32'h0000_0013

// Reset vector: where the CPU begins executing after reset.
// Matches the start of IMEM in our Phase 1 flat address space.
`define RESET_VECTOR  32'h0000_0000


`endif // ISA_VH
