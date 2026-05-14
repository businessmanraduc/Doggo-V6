`include "isa.vh"
// =============================================================================
// PHANTOM-32  ──  CPU Top Level  (6-Stage Pipelined RV32IC Core)
// =============================================================================
// Complete PHANTOM-32 pipeline:
//
//   PreIF → IF → ID → EX → MA → WB
//
// ── Hazard handling ──────────────────────────────────────────────────────────
//   Load-use stall (1 cycle):
//     NOP written into IF/ID (upcoming instruction suppressed).
//     Load in IF/ID proceeds to ID/EX normally (not flushed).
//     PC held - dependent instruction re-fetched next cycle.
//     One cycle later the load result is in MA/WB; WB→EX forwarding handles it.
//
//   Branch taken / unconditional jump (2-cycle penalty):
//     Flush IF/ID and ID/EX (two wrong-path instructions behind the branch).
//     PC ← branch/jump target.
//
//   Trap / MRET (3-cycle penalty):
//     Flush IF/ID, ID/EX, and EX/MA (three instructions behind the trap).
//     PC ← mtvec (trap) or mepc (MRET).
//     MA/WB reg_write suppressed for the trapping instruction itself.
//
// ── CSR old-value read ───────────────────────────────────────────────────────
//   The CSR register file is READ in MA stage (rd_addr = ex_ma_csr_addr).
//   csr_regfile exposes two combinational outputs for the same rd_addr:
//     rd_data     - with write-before-read forwarding (new value if wr_en)
//     rd_data_raw - raw flip-flop value, no forwarding (always old value)
//   The MA stage uses rd_data_raw for:
//     • The RMW computation (CSRRS: old|rs1, CSRRC: old&~rs1)
//     • The rd writeback value (all CSR instructions return the old value)
//   rd_data (forwarded) is wired but not used directly in cpu.v; the
//   write-before-read forwarding inside csr_regfile automatically supplies
//   the new value to the next CSR instruction reading the same address.
//
// ── IMEM interface ───────────────────────────────────────────────────────────
//   16-bit wide, synchronous (1-cycle latency) read, dual port.
//   Simultaneously reads at PC (addr_a) and PC+2 (addr_b) each cycle.
//   If imem_data_a[1:0] = 2'b11 the instruction is 32-bit and both halves
//   are concatenated; otherwise only imem_data_a is used (16-bit compressed).
// =============================================================================
module cpu (
  input  wire        clk,
  input  wire        resetn,          // active-low synchronous reset
 
  // ── Instruction memory ─────────────────────────────────────────────────────
  output wire [31:0] imem_addr_a,     // fetch address: PC
  output wire [31:0] imem_addr_b,     // fetch address: PC + 2
  input  wire [15:0] imem_data_a,     // halfword at PC
  input  wire [15:0] imem_data_b,     // halfword at PC + 2
 
  // ── Data memory ────────────────────────────────────────────────────────────
  output wire [31:0] dmem_addr,       // byte address
  output wire [31:0] dmem_wdata,      // store data (byte-lane shifted)
  output wire        dmem_we,         // write enable (gated off on trap)
  output wire [3:0]  dmem_be,         // per-byte write enables
  input  wire [31:0] dmem_rdata       // load data (full 32-bit word)
);


  // ===========================================================================
  // PIPELINE REGISTER STORAGE
  // ===========================================================================

    // ── PreIF/IF ─────────────────────────────────────────────────────────────
    reg [31:0] r_pc;              // Main ProgramCounter register
    reg [31:0] r_pc2;             // Main ProgramCounter register (+2)

    // ── IF/ID ────────────────────────────────────────────────────────────────
    reg [31:0] if_id_instr;       // assembled instruction word
    reg [31:0] if_id_pc;          // PC of the current instruction in ID
    reg        if_id_isComp;      // 0 = 32-bit instruction | 1 = 16-bit compressed
    reg [4:0]  if_id_rs1;         // rs1 index (from fast_decoder)
    reg [4:0]  if_id_rs2;         // rs2 index (from fast_decoder)
    reg [4:0]  if_id_rd;          // rd  index (from fast_decoder, for hazard unit)
    reg        if_id_isLoad;      // 1 = load  (from fast_decoder, for hazard unit)

    // ── ID/EX ────────────────────────────────────────────────────────────────
    reg [3:0]  id_ex_aluOp;       // ALU opcode
    reg        id_ex_aluLHS;      // ALU Left-Hand-Side:  0 = rs1 | 1 = PC
    reg        id_ex_aluRHS;      // ALU Right-Hand-Side: 0 = rs2 | 1 = immediate
    reg        id_ex_isBranch;    // conditional branch flag
    reg [2:0]  id_ex_branchType;  // conditional branch type
    reg        id_ex_isJump;      // jump flag
    reg        id_ex_isJalr;      // jump with linking register flag
    reg        id_ex_memRead;     // Memory Read flag
    reg        id_ex_memWrite;    // Memory Write flag
    reg [2:0]  id_ex_memWidth;    // Memory access data width
    reg        id_ex_csrEnable;   // CSR-type instruction flag
    reg [1:0]  id_ex_csrOp;       // CSR opcode
    reg        id_ex_csrUseImm;   // CSR use-immediate flag
    reg [11:0] id_ex_csrIndex;    // CSR register index
    reg        id_ex_isECALL;     // CSR ECALL  instruction flag
    reg        id_ex_isEBREAK;    // CSR EBREAK instruction flag
    reg        id_ex_isMRET;      // CSR MRET   instruction flag
    reg        id_ex_isIllegal;   // illegal    instruction flag
    reg        id_ex_regWrite;    // Register Write flag
    reg [1:0]  id_ex_wbSel;       // Write-Back Stage MUX selector
    reg [31:0] id_ex_rs1Data;     // regfile rs1 read
    reg [31:0] id_ex_rs2Data;     // regfile rs2 read
    reg [4:0]  id_ex_rs1Index;    // rs1 index (forwarding unit)
    reg [4:0]  id_ex_rs2Index;    // rs2 index (forwarding unit)
    reg [4:0]  id_ex_rdIndex;     // rd  index (pipelines toward WB)
    reg [31:0] id_ex_pc;          // PC of the current instruction in EX
    reg        id_ex_isComp;      // 0 = 32-bit instruction | 1 = 16-bit compressed
    reg [31:0] id_ex_imm;         // Immediate value
    reg [31:0] id_ex_instr;       // raw instruction word

    // ── EX/MA ────────────────────────────────────────────────────────────────
    reg [31:0] ex_ma_aluResult;   // Result from the ALU unit
    reg [31:0] ex_ma_rs1Fwd;      // forwarded rs1 (CSR RMW source in MA)
    reg [31:0] ex_ma_rs2Fwd;      // forwarded rs2 (store data in MA)
    reg [4:0]  ex_ma_rdIndex;     // rd index (pipelines toward WB)
    reg        ex_ma_regWrite;    // Register Write flag
    reg [1:0]  ex_ma_wbSel;       // Write-Back Stage MUX selector
    reg        ex_ma_memRead;     // Memory Read flag
    reg        ex_ma_memWrite;    // Memory Write flag
    reg [2:0]  ex_ma_memWidth;    // Memory access data width
    reg        ex_ma_csrEnable;   // CSR-type instruction flag
    reg [1:0]  ex_ma_csrOp;       // CSR opcode
    reg        ex_ma_csrUseImm;   // CSR use-immediate flag
    reg [11:0] ex_ma_csrIndex;    // CSR register index
    reg        ex_ma_isECALL;     // CSR ECALL  instruction flag
    reg        ex_ma_isEBREAK;    // CSR EBREAK instruction flag
    reg        ex_ma_isMRET;      // CSR MRET   instruction flag
    reg        ex_ma_isIllegal;   // illegal    instruction flag
    reg [31:0] ex_ma_pc;          // PC of the current instruction in MA
    reg        ex_ma_isComp;      // 0 = 32-bit instruction | 1 = 16-bit compressed
    reg [31:0] ex_ma_instr;       // raw instruction word

    // ── MA/WB ────────────────────────────────────────────────────────────────
    reg [31:0] ma_wb_aluResult;   // Result from the ALU unit
    reg [31:0] ma_wb_loadData;    // sign/zero-extended load result
    reg [31:0] ma_wb_csrOldData;  // old CSR value (returned to rd)
    reg [31:0] ma_wb_linkAddr;    // PC + 2 or PC + 4 (JAL/JALR link)
    reg [4:0]  ma_wb_rdIndex;     // rd index to write data into
    reg        ma_wb_regWrite;    // Register Write flag
    reg [1:0]  ma_wb_wbSel;       // Write-Back Stage MUX selector

  // ===========================================================================
  // PIPELINE REGISTER STORAGE
  // ===========================================================================


  // ===========================================================================
  // INTERMEDIATE SIGNAL DECLARATIONS
  // ===========================================================================

    // ── Control / Hazard / Flush ─────────────────────────────────────────────
    wire         stall;           // Stall Fetch flag
    wire         branch_flush;    // Branch Flush (misprediction) flag
    wire         trap_en;         // Trap Enable flag
    wire         mret_en;         // MRET flag
    logic [31:0] nextPC;          // NextPC     value from NextPC MUX
    logic [31:0] nextPC2;         // NextPC + 2 value from NextPC MUX

    // ── IMEM / IF instruction assembly ───────────────────────────────────────
    wire        if_isCompressed;  // Compressed instruction flag
    wire [31:0] if_instr;         // Fetched instruction (from IMEM)

    // ── fast_decoder outputs ─────────────────────────────────────────────────
    wire        fd_isCompressed;  // Compressed instruction flag (OBSOLETE)
    wire [4:0]  fd_rs1Index;      // extracted rs1 index
    wire [4:0]  fd_rs2Index;      // extracted rs2 index
    wire [4:0]  fd_rdIndex;       // extracted rd  index
    wire        fd_isLoad;        // extracted isLoad flag

    // ── control_unit outputs ─────────────────────────────────────────────────
    wire [3:0]  id_aluOp;         // extracted ALU opcode
    wire        id_AluLHS;        // extracted LHS MUX selector (0 = rs1, 1 = PC)
    wire        id_AluRHS;        // extracted RHS MUX selector (0 = rs2, 1 = imm)
    wire        id_isBranch;      // extracted Conditional Branch flag
    wire [2:0]  id_branchType;    // conditional branch type
    wire        id_isJump;        // extracted jump flag
    wire        id_isJalr;        // extracted jalr flag
    wire        id_memRead;       // extracted Memory Read flag
    wire        id_memWrite;      // extracted Memory Write flag
    wire [2:0]  id_memWidth;      // extracted Memory data width
    wire        id_csrEnable;     // CSR Enable flag
    wire [1:0]  id_csrOp;         // CSR opcode
    wire        id_csrUseImm;     // CSR use-immediate flag
    wire [11:0] id_csrIndex;      // CSR register index
    wire        id_isECALL;       // ECALL   instruction flag
    wire        id_isEBREAK;      // EBREAK  instruction flag
    wire        id_isMRET;        // MRET    instruction flag
    wire        id_isIllegal;     // illegal instruction flag
    wire        id_regWrite;      // Register Write flag
    wire [1:0]  id_wbSel;         // extracted Write-Back Stage MUX selector

    // ── imm_generator outputs ────────────────────────────────────────────────
    wire [31:0] id_imm;           // extracted immediate value
    wire [31:0] id_imm2;          // extracted immediate value (+2)

    // ── regfile outputs ──────────────────────────────────────────────────────
    wire [31:0] rf_rs1Data;       // fetched rs1 value
    wire [31:0] rf_rs2Data;       // fetched rs2 value

    // ── Execute Stage ────────────────────────────────────────────────────────
    wire [1:0]  fwd_rs1Sel;       // forwarded rs1 MUX selector
    wire [1:0]  fwd_rs2Sel;       // forwarded rs2 MUX selector
    wire [31:0] ma_fwdValue;      // forwarded MA Stage instruction's value
    wire [31:0] wb_fwdValue;      // forwarded WB Stage MUX value
    wire [31:0] fwd_rs1Value;     // forwarded ALU LHS operand
    wire [31:0] fwd_rs2Value;     // forwarded ALU RHS operand
    wire [31:0] alu_LHS;          // ALU LHS input value
    wire [31:0] alu_RHS;          // ALU RHS input value
    wire [31:0] alu_result;       // ALU output result value
    wire        branch_taken;     // Computed (NOT predicted) branch taken
    wire [31:0] ex_targetAddr;    // PC's target address (IF branch taken)
    wire [31:0] csr_rdData;       // CSR read with write-before-read forwarding
    wire [31:0] csr_rdDataRaw;    // CSR RAW read (NO forwarding) - used for RMW

    // ── MemoryAccess Stage ───────────────────────────────────────────────────
    wire [31:0] trap_mepc;        // trap mepc    value
    wire [31:0] trap_mcause;      // trap mcause  value
    wire [31:0] trap_mtval;       // trap mtval   value
    wire [31:0] csr_mtvec;        // CSR  mtvec   value
    wire [31:0] csr_mepc;         // CSR  mepc    value
    wire [31:0] csr_mstatus;      // CSR  mstatus value
    wire [31:0] csr_zimm;         // CSR  immediate
    wire [31:0] csr_rs1Value;     // CSR  rs1 value
    wire [31:0] csr_wrData;       // CSR data to be written
    wire        csr_wrEnable;     // CSR Register Write flag
    wire [31:0] ma_linkAddr;      // PC + 2 or PC + 4 (JAL/JALR link)
    wire [7:0]  load_byte;        // load instruction's fetched byte
    wire [15:0] load_halfWord;    // load instruction's fetched halfword

    // ── MemoryAccess Combinational Registers ─────────────────────────────────
    reg  [31:0] load_data;        // load instruction's fetched data
    reg  [3:0]  dmem_be_r;        // per-byte write enable register
    reg  [31:0] dmem_wdata_r;     // store data (byte-lane shifted)

  // ===========================================================================
  // INTERMEDIATE SIGNAL DECLARATIONS
  // ===========================================================================


  // ===========================================================================
  // PreIF STAGE  ──  NextPC MUX and PC register
  // ===========================================================================
  // NextPC MUX Priority (highest first):
  //   trap_en      → mtvec         exception entry
  //   mret_en      → mepc          return from trap
  //   branch_flush → target        branch/jump resolved in EX
  //   stall        → hold r_pc     load-use stall (re-fetch same instruction)
  //   default      → r_pc + 2/4    sequential advance
  // ===========================================================================

    assign imem_addr_a  = nextPC;
    assign imem_addr_b  = nextPC2;
    assign branch_flush = (id_ex_isBranch && branch_taken) || id_ex_isJump;

    // Pre-calculating ALL possible targets
    wire [31:0] pc_inc_base  = if_isCompressed ? 32'd2 : 32'd4;
    wire [31:0] pc_inc_base2 = if_isCompressed ? 32'd4 : 32'd6;
    wire [31:0] pc_inc_seq   = r_pc + pc_inc_base;
    wire [31:0] pc_inc_seq2  = r_pc + pc_inc_base2;

    // Pre-calculating +2 versions for dual-issue fetch
    wire [31:0] csr_mtvec2   = csr_mtvec     + 32'd2;
    wire [31:0] csr_mepc2    = csr_mepc      + 32'd2;
    wire [31:0] ex_target2   = ex_targetAddr + 32'd2;
    wire [31:0] r_pc_2       = r_pc          + 32'd2;

    // One-Hot selection signal
    wire [5:0] nextpc_sel;
    assign nextpc_sel[0] = !resetn;                                                    // Reset (Highest)
    assign nextpc_sel[1] = resetn &&  trap_en;                                         // TRAP
    assign nextpc_sel[2] = resetn && !trap_en &&  mret_en;                             // MRET
    assign nextpc_sel[3] = resetn && !trap_en && !mret_en &&  branch_flush;            // Branch/Jump
    assign nextpc_sel[4] = resetn && !trap_en && !mret_en && !branch_flush &&  stall;  // Stall
    assign nextpc_sel[5] = resetn && !trap_en && !mret_en && !branch_flush && !stall;  // Default (Lowest)

    // Parallel NextPC MUX
    always_comb begin
      unique case (1'b1)
        nextpc_sel[0]: nextPC = `RESET_VECTOR;
        nextpc_sel[1]: nextPC = csr_mtvec;
        nextpc_sel[2]: nextPC = csr_mepc;
        nextpc_sel[3]: nextPC = ex_targetAddr;
        nextpc_sel[4]: nextPC = r_pc;
        nextpc_sel[5]: nextPC = pc_inc_seq;
        default:       nextPC = `RESET_VECTOR;
      endcase
    end

    // Parallel NextPC + 2 MUX
    always_comb begin
      unique case (1'b1)
        nextpc_sel[0]: nextPC2 = `RESET_VECTOR + 32'd2;
        nextpc_sel[1]: nextPC2 = csr_mtvec2;
        nextpc_sel[2]: nextPC2 = csr_mepc2;
        nextpc_sel[3]: nextPC2 = ex_target2;
        nextpc_sel[4]: nextPC2 = r_pc_2;
        nextpc_sel[5]: nextPC2 = pc_inc_seq2;
        default:       nextPC2 = `RESET_VECTOR + 32'd2;
      endcase
    end

    always @(posedge clk) begin
      r_pc  <= nextPC;
      r_pc2 <= nextPC2;
    end

  // ===========================================================================
  // PreIF STAGE  ──  NextPC MUX and PC register
  // ===========================================================================


  // ===========================================================================
  // IF STAGE  ──  Instruction assembly and fast decode
  // ===========================================================================
    assign if_isCompressed = (imem_data_a[1:0] != 2'b11);
    assign if_instr        =
       if_isCompressed     ? {16'd0,       imem_data_a}
      /*not compressed*/   : {imem_data_b, imem_data_a};

    fast_decoder u_fd (
      .instrWord     (if_instr),
      .is_compressed (fd_isCompressed),
      .rs1_index     (fd_rs1Index),
      .rs2_index     (fd_rs2Index),
      .rd_index      (fd_rdIndex),
      .is_load       (fd_isLoad)
    );
  // ===========================================================================
  // IF STAGE
  // ===========================================================================


endmodule
