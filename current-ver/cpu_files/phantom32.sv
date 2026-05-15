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
//   The CSR register file is READ in MA stage (rd_addr = ex_ma_csrIndex).
//   csr_regfile exposes two combinational outputs for the same rd_addr:
//     rd_data     - with write-before-read forwarding (new value if wr_en)
//     rd_data_raw - raw flip-flop value, no forwarding (always old value)
//   The MA stage uses rd_data_raw for:
//     • The RMW computation (CSRRS: old|rs1, CSRRC: old&~rs1)
//     • The rd writeback value (all CSR instructions return the old value)
//   rd_data (forwarded) is wired but not used directly in phantom32.sv; the
//   write-before-read forwarding inside csr_regfile automatically supplies
//   the new value to the next CSR instruction reading the same address.
//
// ── IMEM interface ───────────────────────────────────────────────────────────
//   16-bit wide, synchronous (1-cycle latency) read, dual port.
//   Simultaneously reads at NextPC (addr_a) and NextPC+2 (addr_b) each cycle.
//   If imem_data_a[1:0] = 2'b11 the instruction is 32-bit and both halves
//   are concatenated; otherwise only imem_data_a is used (16-bit compressed).
// =============================================================================
module cpu (
  input  logic        clk,
  input  logic        resetn,          // active-low synchronous reset
 
  // ── Instruction memory ─────────────────────────────────────────────────────
  output logic [31:0] imem_addr_a,     // fetch address: NextPC
  output logic [31:0] imem_addr_b,     // fetch address: NextPC + 2
  input  logic [15:0] imem_data_a,     // halfword at PC
  input  logic [15:0] imem_data_b,     // halfword at PC + 2
 
  // ── Data memory ────────────────────────────────────────────────────────────
  output logic [31:0] dmem_addr,       // byte address
  output logic [31:0] dmem_wdata,      // store data (byte-lane shifted)
  output logic        dmem_we,         // write enable (gated off on trap)
  output logic [3:0]  dmem_be,         // per-byte write enables
  input  logic [31:0] dmem_rdata       // load data (full 32-bit word)
);


  // ===========================================================================
  // PIPELINE REGISTER STORAGE
  // ===========================================================================

    // ── PreIF/IF ─────────────────────────────────────────────────────────────
    logic [31:0] r_pc;              // Main ProgramCounter register
    logic [31:0] r_pc2;             // Main ProgramCounter register (+2)
    logic [31:0] r_pc4;             // Main ProgramCounter register (+4)
    logic [31:0] r_pc6;             // Main ProgramCounter register (+6)

    // ── IF/ID ────────────────────────────────────────────────────────────────
    logic [31:0] if_id_instr;       // assembled instruction word
    logic [31:0] if_id_pc;          // PC of the current instruction in ID
    logic [31:0] if_id_pc2;         // PC + 2 of the cureent instruction in ID
    logic [31:0] if_id_pc4;         // PC + 4 of the current instruction in ID
    logic        if_id_isComp;      // 0 = 32-bit instruction | 1 = 16-bit compressed
    logic [4:0]  if_id_rs1Index;    // rs1 index (from fast_decoder)
    logic [4:0]  if_id_rs2Index;    // rs2 index (from fast_decoder)
    logic [4:0]  if_id_rdIndex;     // rd  index (from fast_decoder, for hazard unit)
    logic        if_id_isLoad;      // 1 = load  (from fast_decoder, for hazard unit)

    // ── ID/EX ────────────────────────────────────────────────────────────────
    logic [3:0]  id_ex_aluOp;       // ALU opcode
    logic        id_ex_aluLHS;      // ALU Left-Hand-Side:  0 = rs1 | 1 = PC
    logic        id_ex_aluRHS;      // ALU Right-Hand-Side: 0 = rs2 | 1 = immediate
    logic        id_ex_isBranch;    // conditional branch flag
    logic [2:0]  id_ex_branchType;  // conditional branch type
    logic        id_ex_isJump;      // jump flag
    logic        id_ex_isJalr;      // jump with linking register flag
    logic        id_ex_memRead;     // Memory Read flag
    logic        id_ex_memWrite;    // Memory Write flag
    logic [2:0]  id_ex_memWidth;    // Memory access data width
    logic        id_ex_csrEnable;   // CSR-type instruction flag
    logic [1:0]  id_ex_csrOp;       // CSR opcode
    logic        id_ex_csrUseImm;   // CSR use-immediate flag
    logic [11:0] id_ex_csrIndex;    // CSR register index
    logic        id_ex_isECALL;     // CSR ECALL  instruction flag
    logic        id_ex_isEBREAK;    // CSR EBREAK instruction flag
    logic        id_ex_isMRET;      // CSR MRET   instruction flag
    logic        id_ex_isIllegal;   // illegal    instruction flag
    logic        id_ex_regWrite;    // Register Write flag
    logic [1:0]  id_ex_wbSel;       // Write-Back Stage MUX selector
    logic [31:0] id_ex_rs1Data;     // regfile rs1 read
    logic [31:0] id_ex_rs2Data;     // regfile rs2 read
    logic [4:0]  id_ex_rs1Index;    // rs1 index (forwarding unit)
    logic [4:0]  id_ex_rs2Index;    // rs2 index (forwarding unit)
    logic [4:0]  id_ex_rdIndex;     // rd  index (pipelines toward WB)
    logic [31:0] id_ex_pc;          // PC of the current instruction in EX
    logic [31:0] id_ex_pc2;         // PC + 2 of the current instruction in EX
    logic [31:0] id_ex_pc4;         // PC + 4 of the current instruction in EX
    logic        id_ex_isComp;      // 0 = 32-bit instruction | 1 = 16-bit compressed
    logic [31:0] id_ex_imm;         // Immediate value
    /* verilator lint_off UNUSEDSIGNAL */
    logic [31:0] id_ex_imm2;        // Immediate + 2
    /* verilator lint_on UNUSEDSIGNAL */
    logic [31:0] id_ex_instr;       // raw instruction word

    // ── EX/MA ────────────────────────────────────────────────────────────────
    logic [31:0] ex_ma_aluResult;   // Result from the ALU unit
    logic [31:0] ex_ma_rs1Fwd;      // forwarded rs1 (CSR RMW source in MA)
    logic [31:0] ex_ma_rs2Fwd;      // forwarded rs2 (store data in MA)
    logic [4:0]  ex_ma_rdIndex;     // rd index (pipelines toward WB)
    logic        ex_ma_regWrite;    // Register Write flag
    logic [1:0]  ex_ma_wbSel;       // Write-Back Stage MUX selector
    logic        ex_ma_memRead;     // Memory Read flag
    logic        ex_ma_memWrite;    // Memory Write flag
    logic [2:0]  ex_ma_memWidth;    // Memory access data width
    logic        ex_ma_csrEnable;   // CSR-type instruction flag
    logic [1:0]  ex_ma_csrOp;       // CSR opcode
    logic        ex_ma_csrUseImm;   // CSR use-immediate flag
    logic [11:0] ex_ma_csrIndex;    // CSR register index
    logic        ex_ma_isECALL;     // CSR ECALL  instruction flag
    logic        ex_ma_isEBREAK;    // CSR EBREAK instruction flag
    logic        ex_ma_isMRET;      // CSR MRET   instruction flag
    logic        ex_ma_isIllegal;   // illegal    instruction flag
    logic [31:0] ex_ma_pc;          // PC of the current instruction in MA
    logic [31:0] ex_ma_pc2;         // PC + 2 of the current instruction in MA
    logic [31:0] ex_ma_pc4;         // PC + 4 of the current instruction in MA
    logic        ex_ma_isComp;      // 0 = 32-bit instruction | 1 = 16-bit compressed
    logic [31:0] ex_ma_instr;       // raw instruction word

    // ── MA/WB ────────────────────────────────────────────────────────────────
    logic [31:0] ma_wb_aluResult;   // Result from the ALU unit
    logic [31:0] ma_wb_loadData;    // sign/zero-extended load result
    logic [31:0] ma_wb_csrOldData;  // old CSR value (returned to rd)
    logic [31:0] ma_wb_linkAddr;    // PC + 2 or PC + 4 (JAL/JALR link)
    logic [4:0]  ma_wb_rdIndex;     // rd index to write data into
    logic        ma_wb_regWrite;    // Register Write flag
    logic [1:0]  ma_wb_wbSel;       // Write-Back Stage MUX selector

  // ===========================================================================
  // PIPELINE REGISTER STORAGE
  // ===========================================================================


  // ===========================================================================
  // INTERMEDIATE SIGNAL DECLARATIONS
  // ===========================================================================

    // ── Control / Hazard / Flush ─────────────────────────────────────────────
    logic        stall;           // Stall Fetch flag
    logic        branch_flush;    // Branch Flush (misprediction) flag
    logic        trap_en;         // Trap Enable flag
    logic        mret_en;         // MRET flag
    logic [31:0] nextPC;          // NextPC     value from NextPC MUX
    logic [31:0] nextPC2;         // NextPC + 2 value from NextPC MUX

    // ── IMEM / IF instruction assembly ───────────────────────────────────────
    logic        if_isCompressed;  // Compressed instruction flag
    logic [31:0] if_instr;         // Fetched instruction (from IMEM)

    // ── fast_decoder outputs ─────────────────────────────────────────────────
    logic [4:0]  fd_rs1Index;      // extracted rs1 index
    logic [4:0]  fd_rs2Index;      // extracted rs2 index
    logic [4:0]  fd_rdIndex;       // extracted rd  index
    logic        fd_isLoad;        // extracted isLoad flag

    // ── control_unit outputs ─────────────────────────────────────────────────
    logic [3:0]  id_aluOp;         // extracted ALU opcode
    logic        id_aluLHS;        // extracted LHS MUX selector (0 = rs1, 1 = PC)
    logic        id_aluRHS;        // extracted RHS MUX selector (0 = rs2, 1 = imm)
    logic        id_isBranch;      // extracted Conditional Branch flag
    logic [2:0]  id_branchType;    // conditional branch type
    logic        id_isJump;        // extracted jump flag
    logic        id_isJalr;        // extracted jalr flag
    logic        id_memRead;       // extracted Memory Read flag
    logic        id_memWrite;      // extracted Memory Write flag
    logic [2:0]  id_memWidth;      // extracted Memory data width
    logic        id_csrEnable;     // CSR Enable flag
    logic [1:0]  id_csrOp;         // CSR opcode
    logic        id_csrUseImm;     // CSR use-immediate flag
    logic [11:0] id_csrIndex;      // CSR register index
    logic        id_isECALL;       // ECALL   instruction flag
    logic        id_isEBREAK;      // EBREAK  instruction flag
    logic        id_isMRET;        // MRET    instruction flag
    logic        id_isIllegal;     // illegal instruction flag
    logic        id_regWrite;      // Register Write flag
    logic [1:0]  id_wbSel;         // extracted Write-Back Stage MUX selector

    // ── imm_generator outputs ────────────────────────────────────────────────
    logic [31:0] id_imm;           // extracted immediate value
    logic [31:0] id_imm2;          // extracted immediate value (+2)

    // ── regfile outputs ──────────────────────────────────────────────────────
    logic [31:0] rf_rs1Data;       // fetched rs1 value
    logic [31:0] rf_rs2Data;       // fetched rs2 value

    // ── Execute Stage ────────────────────────────────────────────────────────
    logic [1:0]  fwd_rs1Sel;       // forwarded rs1 MUX selector
    logic [1:0]  fwd_rs2Sel;       // forwarded rs2 MUX selector
    logic [31:0] ma_fwdValue;      // forwarded MA Stage instruction's value
    logic [31:0] wb_fwdValue;      // forwarded WB Stage MUX value
    logic [31:0] fwd_rs1Value;     // forwarded ALU LHS operand
    logic [31:0] fwd_rs2Value;     // forwarded ALU RHS operand
    logic [31:0] alu_LHS;          // ALU LHS input value
    logic [31:0] alu_RHS;          // ALU RHS input value
    logic [31:0] alu_result;       // ALU output result value
    logic        branch_taken;     // Computed (NOT predicted) branch taken
    logic [31:0] ex_targetAddr;    // PC's target address (IF branch taken)
    /* verilator lint_off UNUSEDSIGNAL */
    logic [31:0] csr_rdData;       // CSR read with write-before-read forwarding
    /* verilator lint_on UNUSEDSIGNAL */
    logic [31:0] csr_rdDataRaw;    // CSR RAW read (NO forwarding) - used for RMW

    // ── MemoryAccess Stage ───────────────────────────────────────────────────
    logic [31:0] trap_mepc;        // trap mepc    value
    logic [31:0] trap_mcause;      // trap mcause  value
    logic [31:0] trap_mtval;       // trap mtval   value
    logic [31:0] csr_mtvec;        // CSR  mtvec   value
    logic [31:0] csr_mepc;         // CSR  mepc    value
    /* verilator lint_off UNUSEDSIGNAL */
    logic [31:0] csr_mstatus;      // CSR  mstatus value
    /* verilator lint_on UNUSEDSIGNAL */
    logic [31:0] csr_zimm;         // CSR  immediate
    logic [31:0] csr_rs1Value;     // CSR  rs1 value
    logic [31:0] csr_wrData;       // CSR data to be written
    logic        csr_wrEnable;     // CSR Register Write flag
    logic [31:0] ma_linkAddr;      // PC + 2 or PC + 4 (JAL/JALR link)
    logic [7:0]  load_byte;        // load instruction's fetched byte
    logic [15:0] load_halfWord;    // load instruction's fetched halfword

    // ── MemoryAccess Combinational Registers ─────────────────────────────────
    logic [31:0] load_data;        // load instruction's fetched data
    logic [3:0]  dmem_be_r;        // per-byte write enable register
    logic [31:0] dmem_wdata_r;     // store data (byte-lane shifted)

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
    logic [31:0] pc_inc_seq;   assign pc_inc_seq   = if_isCompressed ? r_pc2 : r_pc4;
    logic [31:0] pc_inc_seq2;  assign pc_inc_seq2  = if_isCompressed ? r_pc4 : r_pc6;
    logic [31:0] csr_mtvec2;   assign csr_mtvec2   = csr_mtvec       + 32'd2;
    logic [31:0] csr_mepc2;    assign csr_mepc2    = csr_mepc        + 32'd2;
    logic [31:0] ex_target2;   assign ex_target2   = ex_targetAddr   + 32'd2;

    // One-Hot selection signal
    logic [5:0] nextpc_sel;
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
        nextpc_sel[4]: nextPC2 = r_pc2;
        nextpc_sel[5]: nextPC2 = pc_inc_seq2;
        default:       nextPC2 = `RESET_VECTOR + 32'd2;
      endcase
    end

    always_ff @(posedge clk) begin
      r_pc  <= nextPC;
      r_pc2 <= nextPC2;
      r_pc4 <= nextPC2 + 32'd2;
      r_pc6 <= nextPC2 + 32'd4;
    end

  // ===========================================================================
  // PreIF STAGE
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
      .is_compressed (if_isCompressed),
      .rs1_index     (fd_rs1Index),
      .rs2_index     (fd_rs2Index),
      .rd_index      (fd_rdIndex),
      .is_load       (fd_isLoad)
    );
  // ===========================================================================
  // IF STAGE
  // ===========================================================================


  // ===========================================================================
  // IF/ID PIPELINE REGISTER
  // ===========================================================================
  // Flush  (branch / trap / MRET): NOP - wrong-path instruction discarded.
  // Stall  (load-use hazard):      NOP - upcoming instruction suppressed.
  //   The load currently in IF/ID propagates normally into ID/EX this cycle.
  //   PC is held so the suppressed instruction is re-fetched next cycle.
  // Normal: capture current IF-stage fetch.
  // ===========================================================================
    always_ff @(posedge clk) begin
      if (!resetn || branch_flush || trap_en || mret_en) begin
        if_id_instr     <= `NOP_INSTR;
        if_id_pc        <= 32'd0;
        if_id_pc2       <= 32'd0;
        if_id_pc4       <= 32'd0;
        if_id_isComp    <= 1'b0;
        if_id_rs1Index  <= 5'd0;
        if_id_rs2Index  <= 5'd0;
        if_id_rdIndex   <= 5'd0;
        if_id_isLoad    <= 1'b0;
      end else if (stall) begin
        if_id_instr     <= `NOP_INSTR;
        if_id_pc        <= 32'd0;
        if_id_pc2       <= 32'd0;
        if_id_pc4       <= 32'd0;
        if_id_isComp    <= 1'b0;
        if_id_rs1Index  <= 5'd0;
        if_id_rs2Index  <= 5'd0;
        if_id_rdIndex   <= 5'd0;
        if_id_isLoad    <= 1'b0;
      end else begin
        if_id_instr     <= if_instr;
        if_id_pc        <= r_pc;
        if_id_pc2       <= r_pc2;
        if_id_pc4       <= r_pc4;
        if_id_isComp    <= if_isCompressed;
        if_id_rs1Index  <= fd_rs1Index;
        if_id_rs2Index  <= fd_rs2Index;
        if_id_rdIndex   <= fd_rdIndex;
        if_id_isLoad    <= fd_isLoad;
      end
    end
  // ===========================================================================
  // IF/ID PIPELINE REGISTER
  // ===========================================================================


  // ===========================================================================
  // ID STAGE  ──  Full decode, immediate generation, regfile read, hazard detect
  // ===========================================================================
    control_unit u_ctrl (
      .instrWord      (if_id_instr),
      .alu_op         (id_aluOp),
      .alu_src_a      (id_aluLHS),
      .alu_src_b      (id_aluRHS),
      .is_branch      (id_isBranch),
      .branch_type    (id_branchType),
      .is_jump        (id_isJump),
      .is_jalr        (id_isJalr),
      .mem_read       (id_memRead),
      .mem_write      (id_memWrite),
      .mem_width      (id_memWidth),
      .csr_en         (id_csrEnable),
      .csr_op         (id_csrOp),
      .csr_use_imm    (id_csrUseImm),
      .csr_addr       (id_csrIndex),
      .is_ecall       (id_isECALL),
      .is_ebreak      (id_isEBREAK),
      .is_mret        (id_isMRET),
      .is_illegal     (id_isIllegal),
      .reg_write      (id_regWrite),
      .wb_sel         (id_wbSel)
    );

    imm_generator u_immgen (
      .instrWord      (if_id_instr),
      .is_compressed  (if_id_isComp),
      .immediate      (id_imm),
      .immediate_2    (id_imm2)
    );

    regfile u_rf (
      .clk            (clk),
      .rd_index_a     (if_id_rs1Index),
      .rd_data_a      (rf_rs1Data),
      .rd_index_b     (if_id_rs2Index),
      .rd_data_b      (rf_rs2Data),
      .wr_index       (ma_wb_rdIndex),
      .wr_data        (wb_fwdValue),
      .wr_en          (ma_wb_regWrite)
    );

    hazard_unit u_haz (
      .if_rs1_index   (fd_rs1Index),
      .if_rs2_index   (fd_rs2Index),
      .id_rd_index    (if_id_rdIndex),
      .id_is_load     (if_id_isLoad),
      .stall          (stall)
    );
  // ===========================================================================
  // ID STAGE
  // ===========================================================================


  // ===========================================================================
  // ID/EX PIPELINE REGISTER
  // ===========================================================================
  // Flush (branch / trap / MRET): NOP.
  // On load-use stall: the LOAD in IF/ID proceeds normally into ID/EX.
  // The NOP was already written to IF/ID so the dependent instruction cannot
  // enter this register.
  // ===========================================================================
    always_ff @(posedge clk) begin
      if (!resetn || branch_flush || trap_en || mret_en) begin
        id_ex_aluOp      <= `ALU_ADD;
        id_ex_aluLHS     <= 1'b0;
        id_ex_aluRHS     <= 1'b0;
        id_ex_isBranch   <= 1'b0;
        id_ex_branchType <= 3'b000;
        id_ex_isJump     <= 1'b0;
        id_ex_isJalr     <= 1'b0;
        id_ex_memRead    <= 1'b0;
        id_ex_memWrite   <= 1'b0;
        id_ex_memWidth   <= `WIDTH_W;
        id_ex_csrEnable  <= 1'b0;
        id_ex_csrOp      <= 2'b00;
        id_ex_csrUseImm  <= 1'b0;
        id_ex_csrIndex   <= 12'h000;
        id_ex_isECALL    <= 1'b0;
        id_ex_isEBREAK   <= 1'b0;
        id_ex_isMRET     <= 1'b0;
        id_ex_isIllegal  <= 1'b0;
        id_ex_regWrite   <= 1'b0;
        id_ex_wbSel      <= 2'b00;
        id_ex_rs1Data    <= 32'd0;
        id_ex_rs2Data    <= 32'd0;
        id_ex_rs1Index   <= 5'd0;
        id_ex_rs2Index   <= 5'd0;
        id_ex_rdIndex    <= 5'd0;
        id_ex_pc         <= 32'd0;
        id_ex_pc2        <= 32'd0;
        id_ex_pc4        <= 32'd0;
        id_ex_isComp     <= 1'b0;
        id_ex_imm        <= 32'd0;
        id_ex_imm2       <= 32'd0;
        id_ex_instr      <= `NOP_INSTR;
      end else begin
        id_ex_aluOp      <= id_aluOp;
        id_ex_aluLHS     <= id_aluLHS;
        id_ex_aluRHS     <= id_aluRHS;
        id_ex_isBranch   <= id_isBranch;
        id_ex_branchType <= id_branchType;
        id_ex_isJump     <= id_isJump;
        id_ex_isJalr     <= id_isJalr;
        id_ex_memRead    <= id_memRead;
        id_ex_memWrite   <= id_memWrite;
        id_ex_memWidth   <= id_memWidth;
        id_ex_csrEnable  <= id_csrEnable;
        id_ex_csrOp      <= id_csrOp;
        id_ex_csrUseImm  <= id_csrUseImm;
        id_ex_csrIndex   <= id_csrIndex;
        id_ex_isECALL    <= id_isECALL;
        id_ex_isEBREAK   <= id_isEBREAK;
        id_ex_isMRET     <= id_isMRET;
        id_ex_isIllegal  <= id_isIllegal;
        id_ex_regWrite   <= id_regWrite;
        id_ex_wbSel      <= id_wbSel;
        id_ex_rs1Data    <= rf_rs1Data;
        id_ex_rs2Data    <= rf_rs2Data;
        id_ex_rs1Index   <= if_id_rs1Index;
        id_ex_rs2Index   <= if_id_rs2Index;
        id_ex_rdIndex    <= if_id_rdIndex;
        id_ex_pc         <= if_id_pc;
        id_ex_pc2        <= if_id_pc2;
        id_ex_pc4        <= if_id_pc4;
        id_ex_isComp     <= if_id_isComp;
        id_ex_imm        <= id_imm;
        id_ex_imm2       <= id_imm2;
        id_ex_instr      <= if_id_instr;
      end
    end

  // ===========================================================================
  // ID/EX PIPELINE REGISTER
  // ===========================================================================


  // ===========================================================================
  // EX STAGE  ──  Forwarding muxes, ALU, branch evaluation, branch target
  // ===========================================================================
  //
  // ── WB-stage mux (wb_fwdValue) ─────────────────────────────────────────────
  //   Drives both regfile.wr_data and the 2'b01 path in the EX forwarding muxes.
  //   wb_sel encoding:
  //     2'b00  ALU result     arithmetic, logic, LUI, AUIPC, address computation
  //     2'b01  Load data      sign/zero-extended byte / halfword / word from DMEM
  //     2'b10  Link address   PC + 2 (compressed) or PC + 4 (32-bit) for jumps
  //     2'b11  Old CSR value  CSRRW / CSRRS / CSRRC and immediate variants
  //
  // ── MA-stage forwarding value (ma_fwdValue) ────────────────────────────────
  //   The value the MA-stage instruction will write back, made available one
  //   cycle early.  wb_sel 01 (load) is excluded because hazard_unit stalls
  //   to ensure a load is never in MA at the same time its consumer is in EX.
  //
  // ── Forwarding select encoding ─────────────────────────────────────────────
  //   2'b10  ma_fwdValue  (MA-stage result, 1 cycle old)
  //   2'b01  wb_fwdValue  (WB-stage result, 2 cycles old)
  //   2'b00  regfile read (no hazard / regfile write-before-read covers it)
  // ===========================================================================

    // ── WB-stage writeback value ─────────────────────────────────────────────
    always_comb begin
      case (ma_wb_wbSel)
        2'b00: wb_fwdValue = ma_wb_aluResult;
        2'b01: wb_fwdValue = ma_wb_loadData;
        2'b10: wb_fwdValue = ma_wb_linkAddr;
        2'b11: wb_fwdValue = ma_wb_csrOldData;
      endcase
    end

    // ── MA-stage forwarding value ────────────────────────────────────────────
    assign ma_linkAddr = ex_ma_isComp ? ex_ma_pc2 : ex_ma_pc4;
    always_comb begin
      case (ex_ma_wbSel)
        2'b00: ma_fwdValue = ex_ma_aluResult;
        2'b01: ma_fwdValue = 32'hDEADBEEF;
        2'b10: ma_fwdValue = ma_linkAddr;
        2'b11: ma_fwdValue = csr_rdDataRaw;
      endcase
    end

    // ── Forwarding unit ──────────────────────────────────────────────────────
    forward_unit u_fwd (
      .ex_rs1_index (id_ex_rs1Index),
      .ex_rs2_index (id_ex_rs2Index),
      .ma_rd_index  (ex_ma_rdIndex),
      .ma_reg_write (ex_ma_regWrite),
      .wb_rd_index  (ma_wb_rdIndex),
      .wb_reg_write (ma_wb_regWrite),
      .fwd_A_sel    (fwd_rs1Sel),
      .fwd_B_sel    (fwd_rs2Sel)
    );

    // ── Three-way forwarding muxes ───────────────────────────────────────────
    always_comb begin
      case (fwd_rs1Sel)
        2'b00: fwd_rs1Value = id_ex_rs1Data;
        2'b01: fwd_rs1Value = wb_fwdValue;
        2'b10: fwd_rs1Value = ma_fwdValue;
        2'b11: fwd_rs1Value = 32'hDEADBEEF;
      endcase
    end

    always_comb begin
      case (fwd_rs2Sel)
        2'b00: fwd_rs2Value = id_ex_rs2Data;
        2'b01: fwd_rs2Value = wb_fwdValue;
        2'b10: fwd_rs2Value = ma_fwdValue;
        2'b11: fwd_rs2Value = 32'hDEADBEEF;
      endcase
    end

    // ── ALU source muxes ─────────────────────────────────────────────────────
    assign alu_LHS = id_ex_aluLHS ? id_ex_pc  : fwd_rs1Value;
    assign alu_RHS = id_ex_aluRHS ? id_ex_imm : fwd_rs2Value;

    // ── ALU ──────────────────────────────────────────────────────────────────
    alu u_alu (
      .lhs    (alu_LHS),
      .rhs    (alu_RHS),
      .op     (id_ex_aluOp),
      .result (alu_result)
    );

    // ── Branch condition evaluator ───────────────────────────────────────────
    branch_eval u_beval (
      .rs1_data     (fwd_rs1Value),
      .rs2_data     (fwd_rs2Value),
      .branch_type  (id_ex_branchType),
      .branch_taken (branch_taken)
    );

    // ── Branch / jump target address ─────────────────────────────────────────
    branch_target u_btarget (
      .pc          (id_ex_pc),
      .rs1_data    (fwd_rs1Value),
      .immediate   (id_ex_imm),
      .is_jalr     (id_ex_isJalr),
      .target_addr (ex_targetAddr)
    );
  // ===========================================================================
  // EX STAGE
  // ===========================================================================


  // ===========================================================================
  // EX/MA PIPELINE REGISTER
  // ===========================================================================
  // Flushed on trap or MRET only (branch flush does not reach this register).
  // rs1Fwd / rs2Fwd carry the forwarded operands into MA for CSR RMW and
  // store data respectively.
  // ===========================================================================
    always_ff @(posedge clk) begin
      if (!resetn || trap_en || mret_en) begin
        ex_ma_aluResult  <= 32'd0;
        ex_ma_rs1Fwd     <= 32'd0;
        ex_ma_rs2Fwd     <= 32'd0;
        ex_ma_rdIndex    <= 5'd0;
        ex_ma_regWrite   <= 1'b0;
        ex_ma_wbSel      <= 2'b00;
        ex_ma_memRead    <= 1'b0;
        ex_ma_memWrite   <= 1'b0;
        ex_ma_memWidth   <= `WIDTH_W;
        ex_ma_csrEnable  <= 1'b0;
        ex_ma_csrOp      <= 2'b00;
        ex_ma_csrUseImm  <= 1'b0;
        ex_ma_csrIndex   <= 12'h000;
        ex_ma_isECALL    <= 1'b0;
        ex_ma_isEBREAK   <= 1'b0;
        ex_ma_isMRET     <= 1'b0;
        ex_ma_isIllegal  <= 1'b0;
        ex_ma_pc         <= 32'd0;
        ex_ma_pc2        <= 32'd0;
        ex_ma_pc4        <= 32'd0;
        ex_ma_isComp     <= 1'b0;
        ex_ma_instr      <= `NOP_INSTR;
      end else begin
        ex_ma_aluResult  <= alu_result;
        ex_ma_rs1Fwd     <= fwd_rs1Value;
        ex_ma_rs2Fwd     <= fwd_rs2Value;
        ex_ma_rdIndex    <= id_ex_rdIndex;
        ex_ma_regWrite   <= id_ex_regWrite;
        ex_ma_wbSel      <= id_ex_wbSel;
        ex_ma_memRead    <= id_ex_memRead;
        ex_ma_memWrite   <= id_ex_memWrite;
        ex_ma_memWidth   <= id_ex_memWidth;
        ex_ma_csrEnable  <= id_ex_csrEnable;
        ex_ma_csrOp      <= id_ex_csrOp;
        ex_ma_csrUseImm  <= id_ex_csrUseImm;
        ex_ma_csrIndex   <= id_ex_csrIndex;
        ex_ma_isECALL    <= id_ex_isECALL;
        ex_ma_isEBREAK   <= id_ex_isEBREAK;
        ex_ma_isMRET     <= id_ex_isMRET;
        ex_ma_isIllegal  <= id_ex_isIllegal;
        ex_ma_pc         <= id_ex_pc;
        ex_ma_pc2        <= id_ex_pc2;
        ex_ma_pc4        <= id_ex_pc4;
        ex_ma_isComp     <= id_ex_isComp;
        ex_ma_instr      <= id_ex_instr;
      end
    end
  // ===========================================================================
  // EX/MA PIPELINE REGISTER
  // ===========================================================================


  // ===========================================================================
  // MA STAGE  ──  Trap detection, CSR access, DMEM access, load extension
  // ===========================================================================

    // ── Trap unit ────────────────────────────────────────────────────────────
    trap_unit u_trap (
      .ma_pc         (ex_ma_pc),
      .ma_instr      (ex_ma_instr),
      .ma_alu_result (ex_ma_aluResult),
      .ma_mem_read   (ex_ma_memRead),
      .ma_mem_write  (ex_ma_memWrite),
      .ma_mem_width  (ex_ma_memWidth),
      .ma_is_ecall   (ex_ma_isECALL),
      .ma_is_ebreak  (ex_ma_isEBREAK),
      .ma_is_illegal (ex_ma_isIllegal),
      .ma_is_mret    (ex_ma_isMRET),
      .trap_en       (trap_en),
      .trap_mepc     (trap_mepc),
      .trap_mcause   (trap_mcause),
      .trap_mtval    (trap_mtval),
      .mret_en       (mret_en)
    );

    // ── CSR Read-Modify-Write ────────────────────────────────────────────────
    // csr_rdDataRaw is the raw flip-flop value, free of write-before-read
    // forwarding, so csr_wrData does not feed back into csr_rdDataRaw.
    //
    // CSRRxI variants: fast_decoder set rs1 to x0 (ex_ma_rs1Fwd = 0).
    //   The real 5-bit zimm lives in ex_ma_instr[19:15] and is zero-extended.
    //
    // CSRRS/CSRRC: if rs1=x0 or zimm=0 the CSR must NOT be written (read-only
    //   access semantics).  CSRRW always writes regardless.
    assign        csr_zimm     = {27'd0, ex_ma_instr[19:15]};
    assign        csr_rs1Value = ex_ma_csrUseImm ? csr_zimm : ex_ma_rs1Fwd;
    logic  [31:0] csr_wrDataRS;
    logic  [31:0] csr_wrDataRC;
    assign csr_wrDataRS = (csr_rdDataRaw |  csr_rs1Value);
    assign csr_wrDataRC = (csr_rdDataRaw & ~csr_rs1Value);
    always_comb begin
      case (ex_ma_csrOp)
        `CSR_OP_RW: csr_wrData = csr_rs1Value;
        `CSR_OP_RS: csr_wrData = csr_wrDataRS;
        `CSR_OP_RC: csr_wrData = csr_wrDataRC;
        default:    csr_wrData = 32'd0;
      endcase
    end
    assign csr_wrEnable = ex_ma_csrEnable
      && (ex_ma_csrOp == `CSR_OP_RW || csr_rs1Value != 32'd0);

    // ── CSR register file ────────────────────────────────────────────────────
    // Read and write both happen in MA stage (rd_addr = ex_ma_csrIndex).
    // csr_rdDataRaw returns the raw flip-flop value (no write-before-read
    // forwarding) so the RMW computation has no combinational cycle.
    csr_regfile u_csr (
      .clk         (clk),
      .resetn      (resetn),
      .rd_addr     (ex_ma_csrIndex),
      .rd_data     (csr_rdData),
      .rd_data_raw (csr_rdDataRaw),
      .wr_addr     (ex_ma_csrIndex),
      .wr_data     (csr_wrData),
      .wr_en       (csr_wrEnable),
      .trap_en     (trap_en),
      .trap_mepc   (trap_mepc),
      .trap_mcause (trap_mcause),
      .trap_mtval  (trap_mtval),
      .mret_en     (mret_en),
      .out_mstatus (csr_mstatus),
      .out_mtvec   (csr_mtvec),
      .out_mepc    (csr_mepc)
    );

    // ── DMEM load byte / halfword extraction ──────────────────────────────────
    // DMEM returns a full 32-bit word.  The two low address bits select which
    // byte or halfword lane to extract, which is then sign/zero-extended.
    always_comb begin
      case (ex_ma_aluResult[1:0])
        2'b00: load_byte = dmem_rdata[7:0];
        2'b01: load_byte = dmem_rdata[15:8];
        2'b10: load_byte = dmem_rdata[23:16];
        2'b11: load_byte = dmem_rdata[31:24];
      endcase
    end

    always_comb begin
      case (ex_ma_aluResult[1])
        1'b0: load_halfWord = dmem_rdata[15:0];
        1'b1: load_halfWord = dmem_rdata[31:16];
      endcase
    end

    always_comb begin
      case (ex_ma_memWidth)
        `WIDTH_B:  load_data = {{24{load_byte[7]}},      load_byte};
        `WIDTH_H:  load_data = {{16{load_halfWord[15]}}, load_halfWord};
        `WIDTH_W:  load_data = dmem_rdata;
        `WIDTH_BU: load_data = {24'd0, load_byte};
        `WIDTH_HU: load_data = {16'd0, load_halfWord};
        default:   load_data = dmem_rdata;
      endcase
    end

    // ── DMEM store: byte enables and write-data lane placement ────────────────
    // The byte-enable mask activates only the lanes being written.
    // Write data is placed in the correct lane; unused lanes hold zero.
    always_comb begin
      dmem_be_r    = 4'b1111;
      dmem_wdata_r = ex_ma_rs2Fwd;
      case (ex_ma_memWidth)
        `WIDTH_B: begin
          dmem_be_r = 4'b0001 << ex_ma_aluResult[1:0];
          case (ex_ma_aluResult[1:0])
            2'b00: dmem_wdata_r = {24'd0, ex_ma_rs2Fwd[7:0]};
            2'b01: dmem_wdata_r = {16'd0, ex_ma_rs2Fwd[7:0], 8'd0};
            2'b10: dmem_wdata_r = {8'd0,  ex_ma_rs2Fwd[7:0], 16'd0};
            2'b11: dmem_wdata_r = {       ex_ma_rs2Fwd[7:0], 24'd0};
          endcase
        end
        `WIDTH_H: begin
          if (ex_ma_aluResult[1]) begin
            dmem_be_r    = 4'b1100;
            dmem_wdata_r = {ex_ma_rs2Fwd[15:0], 16'd0};
          end else begin
            dmem_be_r    = 4'b0011;
            dmem_wdata_r = {16'd0, ex_ma_rs2Fwd[15:0]};
          end
        end
        default:  begin
          dmem_be_r      = 4'b1111;
          dmem_wdata_r   = ex_ma_rs2Fwd;
        end
      endcase
    end

    // ── DMEM port assignments ─────────────────────────────────────────────────
    // dmem_we is gated off when a trap fires: the trapping instruction must not
    // commit a store to memory (precise exception requirement).
    assign dmem_addr  = ex_ma_aluResult;
    assign dmem_we    = ex_ma_memWrite && !trap_en;
    assign dmem_be    = dmem_be_r;
    assign dmem_wdata = dmem_wdata_r;

  // ===========================================================================
  // MA STAGE
  // ===========================================================================


  // ===========================================================================
  // MA/WB PIPELINE REGISTER
  // ===========================================================================
  // regWrite is suppressed when trap_en fires.  Most trapping instructions
  // (ECALL, EBREAK, MRET, illegal) already have regWrite=0 from control_unit.
  // The suppression here specifically covers load-misalignment, where the load
  // would otherwise write garbage DMEM data to the register file.
  // ===========================================================================
    always_ff @(posedge clk) begin
      if (!resetn) begin
        ma_wb_aluResult  <= 32'd0;
        ma_wb_loadData   <= 32'd0;
        ma_wb_csrOldData <= 32'd0;
        ma_wb_linkAddr   <= 32'd0;
        ma_wb_rdIndex    <= 5'd0;
        ma_wb_regWrite   <= 1'b0;
        ma_wb_wbSel      <= 2'b00;
      end else begin
        ma_wb_aluResult  <= ex_ma_aluResult;
        ma_wb_loadData   <= load_data;
        ma_wb_csrOldData <= csr_rdDataRaw;
        ma_wb_linkAddr   <= ma_linkAddr;
        ma_wb_rdIndex    <= ex_ma_rdIndex;
        ma_wb_regWrite   <= ex_ma_regWrite && !trap_en;
        ma_wb_wbSel      <= ex_ma_wbSel;
      end
    end
  // ===========================================================================
  // MA/WB PIPELINE REGISTER
  // ===========================================================================


  // ===========================================================================
  // WB STAGE  ──  Writeback mux
  // ===========================================================================
  // wb_fwdValue is a combinational assign (in the EX section above).
  // It simultaneously drives:
  //   • regfile.wr_data  — commits the result to the architectural register file
  //   • fwd_rs1Value / fwd_rs2Value via the 2'b01 path in the EX forwarding muxes
  // No additional logic is required in this stage.
  // ===========================================================================

endmodule
