`include "isa.vh"
// =============================================================================
// PHANTOM-32  ──  Phantom Core  (RV32IMC in-order execution core)
// =============================================================================
// Decoupled fetch front end (fetch_unit: PC-gen + I$ + fetch FIFO + RVC aligner,
// with a bimodal PHT) feeding a 4-stage in-order backend. IMEM/DMEM are held in
// common by the cpu module.
//
//   [ decoupled fetch ] -> ID -> EX -> MA -> WB
//
// =============================================================================
module phantom_core (
  input logic         clk,
  input logic         resetn,         // active-low synchronous reset

  // ── Instruction memory ─────────────────────────────────────────────────────
  output logic [31:0] imem_addr,      // fetch address: word-aligned
  input  logic [31:0] imem_data,      // instrWord at imem_addr
  input  logic        imem_ready,     // 1 = imem_data valid for fetching

  // ── Data memory ────────────────────────────────────────────────────────────
  output logic [31:0] dmem_raddr,     // DMEM read  address
  output logic [31:0] dmem_waddr,     // DMEM write address
  output logic [31:0] dmem_wdata,     // store data (byte-lane shifted)
  output logic        dmem_we,        // write enable
  output logic [3:0]  dmem_be,        // per-byte write enables
  input  logic [31:0] dmem_rdata,     // load data (full 32-bit word)
  output logic        dmem_req,       // 1 = MA holds a load/store
  input  logic        dmem_ready,     // 1 = memAccess complete this cycle

  // ── Interrupt request lines (level-sensitive, drive mip) ─────────────────────
  input  logic        irq_timer,      // machine timer    interrupt (CLINT mtip)
  input  logic        irq_soft,       // machine software interrupt (CLINT msip)
  input  logic        irq_ext         // machine external interrupt (PLIC/ext)
);

  // ===========================================================================
  // FETCH FRONT-END DIMENSIONS
  // ===========================================================================
    localparam integer FETCH_DEPTH = 4; // decoupled fetch FIFO entries
    localparam integer PHT_IDX_W   = 9; // 512-entry bimodal direction predictor
  // ===========================================================================
  // FETCH FRONT-END DIMENSIONS
  // ===========================================================================


  // ===========================================================================
  // PIPELINE REGISTER STORAGE
  // ===========================================================================

    // ── Decoupled fetch front end ────────────────────────────────────────────
    logic [31:0]      fe_instr;         // aligned instruction word
    logic [31:0]      fe_pc;            // aligned instruction byte PC
    logic             fe_isComp;        // 1 => 16-bit compressed
    logic             fe_valid;         // 1 => aligner has instruction ready
    logic             fe_consume;       // 1 => IF/ID accepts aligner head
    logic             redirect_en;      // flush+reload fetch (branch/trap/mret)
    logic [31:0]      redirect_pc;      // redirect target PC

    // ── IF/ID ────────────────────────────────────────────────────────────────
    logic [31:0]      if_id_pc;         // PC value for IF's instruction
    logic [31:0]      if_id_pc2;
    logic [31:0]      if_id_pc4;

    logic [31:0]      if_id_instr;      // full instruction word
    logic             if_id_isComp;     // 1 => current instruction is 16-bit C

    logic [4:0]       if_id_rs1Index;   // extracted rs1 index
    logic [4:0]       if_id_rs2Index;   // extracted rs2 index
    logic [4:0]       if_id_rdIndex;    // extracted rd  index
    logic             if_id_valid;      // 1 => real instruction (not a bubble)
    logic [1:0]       if_id_phtCounter; // bimodal PHT counter

    // ── ID/EX ────────────────────────────────────────────────────────────────
    logic [31:0]      id_ex_pc;         // PC value for ID's instruction
    logic [31:0]      id_ex_pc2;
    logic [31:0]      id_ex_pc4;

    logic [31:0]      id_ex_instr;
    logic             id_ex_isComp;
    logic [31:0]      id_ex_imm;
    logic             id_ex_isJump;     // 1 => current instruction is a jump
    logic             id_ex_isJalr;     // 1 => current instruction is a jalr
    logic             id_ex_isMulDiv;   // 1 => current instruction is RV32M
    logic             id_ex_isBranch;   // 1 => current instruction is a branch
    logic [2:0]       id_ex_branchType; // type of decoded branch
    logic             id_ex_predTaken;  // 1 => branch taken prediction
    logic [1:0]       id_ex_phtOld;     // PHT counter read at predict time

    logic [4:0]       id_ex_rs1Index;
    logic [4:0]       id_ex_rdIndex;
    logic [31:0]      id_ex_rs1Data;    // rs1 data fetched from the regfile
    logic [31:0]      id_ex_rs2Data;    // rs2 data fetched from the regfile
    logic [3:0]       id_ex_aluOp;      // ALU opcode

    logic             id_ex_memRead;
    logic             id_ex_memWrite;
    logic [2:0]       id_ex_memWidth;   // width of the data to be read/written
    logic             id_ex_regWrite;
    logic [1:0]       id_ex_wbSel;      // writeback MUX selector

    logic             id_ex_csrEnable;  // 1 => current instruction makes use of CSR
    logic [1:0]       id_ex_csrOp;      // CSR opcode
    logic             id_ex_csrUseImm;
    logic [11:0]      id_ex_csrIndex;   // CSR index
    logic             id_ex_isECALL;
    logic             id_ex_isEBREAK;
    logic             id_ex_isMRET;
    logic             id_ex_isIllegal;
    logic             id_ex_valid;

    // ── EX/MA ────────────────────────────────────────────────────────────────
    logic [31:0]      ex_ma_pc;
    logic [31:0]      ex_ma_linkAddr;   // PC + 2 or PC + 4 (JAL/JALR link)

    logic [31:0]      ex_ma_belowAddr;  // PC target if branch NOT taken
    logic [31:0]      ex_ma_targetAddr; // actual branch/jump target
    logic             ex_ma_branchTaken;
    logic             ex_ma_predTaken;  // prediction carried for MA verification
    logic             ex_ma_isBranch;   // 1 => conditional branch
    logic [1:0]       ex_ma_phtOld;     // PHT counter at predict time

    logic [31:0]      ex_ma_instr;

    logic [4:0]       ex_ma_rdIndex;
    logic [31:0]      ex_ma_rs1Fwd;     // forwarded rs1 value
    logic [31:0]      ex_ma_rs2Fwd;     // forwarded rs2 value
    logic [31:0]      ex_ma_aluResult;
    logic [31:0]      ex_ma_dmemAddr;   // DMEM byte address (rs1_fwd + imm)

    logic             ex_ma_memRead;
    logic             ex_ma_memWrite;
    logic [2:0]       ex_ma_memWidth;
    logic             ex_ma_regWrite;
    logic [1:0]       ex_ma_wbSel;

    logic             ex_ma_csrEnable;
    logic [1:0]       ex_ma_csrOp;
    logic             ex_ma_csrUseImm;
    logic [11:0]      ex_ma_csrIndex;
    logic             ex_ma_isECALL;
    logic             ex_ma_isEBREAK;
    logic             ex_ma_isMRET;
    logic             ex_ma_isIllegal;
    logic             ex_ma_csrLegal;   // 1 => CSR write allowed
    logic             ex_ma_valid;      // 1 => MA instr is real (irq inject qualifier)

    // ── MA/WB ────────────────────────────────────────────────────────────────
    /* verilator lint_off UNUSEDSIGNAL */
    logic [31:0]      ma_wb_pc;
    /* verilator lint_on  UNUSEDSIGNAL */

    logic [4:0]       ma_wb_rdIndex;
    logic [31:0]      ma_wb_aluResult;

    logic [31:0]      ma_wb_loadData;   // sign/zero extended load result
    logic [31:0]      ma_wb_csrData;    // old CSR value returned to rd
    logic [31:0]      ma_wb_linkAddr;

    logic             ma_wb_regWrite;
    logic [1:0]       ma_wb_wbSel;

  // ===========================================================================
  // PIPELINE REGISTER STORAGE
  // ===========================================================================


  // ===========================================================================
  // INTERMEDIATE SIGNAL DECLARATIONS
  // ===========================================================================
  
    // ── Pipeline control ─────────────────────────────────────────────────────
    logic             stall;            // load-use stall
    logic             mem_access;       // MA instr is a load/store
    logic             dmem_stall;       // MA memory access not yet complete
    logic             branch_miss;      // taken branch/jump resolved in MA
    logic             trap_en;
    logic             mret_en;
    logic             flush_id_ex;
    logic             flush_ex_ma;

    // ── IF: fast_decoder outputs ─────────────────────────────────────────────
    logic [4:0]       fd_rs1Index;
    logic [4:0]       fd_rs2Index;
    logic [4:0]       fd_rdIndex;

    // ── ID: control_unit outputs ─────────────────────────────────────────────
    logic             id_isJump;
    logic             id_isJalr;
    logic             id_isMulDiv;
    logic             id_isBranch;
    logic [2:0]       id_branchType;
    logic [3:0]       id_aluOp;
    logic             id_aluLHS;
    logic             id_aluRHS;
    logic             id_memRead;
    logic             id_memWrite;
    logic [2:0]       id_memWidth;
    logic             id_regWrite;
    logic [1:0]       id_wbSel;
    logic             id_csrEnable;
    logic [1:0]       id_csrOp;
    logic             id_csrUseImm;
    logic [11:0]      id_csrIndex;
    logic             id_isECALL;
    logic             id_isEBREAK;
    logic             id_isMRET;
    logic             id_isIllegal;

    // ── ID: regfile outputs ──────────────────────────────────────────────────
    logic [31:0]      rf_rs1Data;
    logic [31:0]      rf_rs2Data;

    // ── ID: imm_generator output ─────────────────────────────────────────────
    logic [31:0]      id_imm;

    // ── ID: branch predictor (BTFNT) ─────────────────────────────────────────
    logic             pred_taken;       // 1 => predict branch/jump taken
    logic [31:0]      pred_target;      // predicted target
    logic             pred_redirect;    // ID-sourced predicted-taken redirect
    logic             ma_redirect;      // MA-sourced (branch_miss/trap/mret)

    // ── Scoreboard control ───────────────────────────────────────────────────
    logic             rs1_ready;        // ID rs1 operand available
    logic             rs2_ready;        // ID rs2 operand available
    logic             id_wr_en;         // ID writer reserves rd   (counter +1)
    logic             ma_wr_en;         // MA writer leaves for WB (counter -1)
    logic             ex_undo_en;       // squashed EX writer undo (counter -1)

    // ── EX: branch_eval + branch_target outputs ──────────────────────────────
    logic [31:0]      ex_linkAddr;
    logic             branch_taken;
    logic             ex_branchTaken;
    logic [31:0]      ex_belowAddr;
    logic [31:0]      ex_targetAddr;

    logic [31:0]      truepc;

    // ── EX: operands & ALU ───────────────────────────────────────────────────
    logic [31:0]      wb_fwdValue;      // WB writeback value (also regfile wr_data)
    logic [31:0]      fwd_rs1Value;     // EX operand A
    logic [31:0]      fwd_rs2Value;     // EX operand B
    logic [31:0]      alu_lhs;
    logic [31:0]      alu_rhs;
    logic [31:0]      alu_result;
    logic [31:0]      ex_dmem_addr;
    logic [31:0]      muldiv_result;
    logic             muldiv_done;      // 1 = muldiv result valid
    logic             muldiv_active;    // 1 = muldiv instruction inside EX
    logic             ex_busy;          // 1 = stall (muldiv not finished)
    logic [31:0]      ex_result;        // EX writeback value (ALU or muldiv)

    // ── EX: CSR read ─────────────────────────────────────────────────────────
    logic [31:0]      csr_rdData;
    logic             ex_csrLegal;

    // ── MA: trap_unit outputs (synchronous exceptions only) ──────────────────
    logic             sync_trap;
    logic [31:0]      sync_mepc;
    logic [31:0]      sync_mcause;
    logic [31:0]      sync_mtval;

    // ── MA: interrupt_unit + combined trap signals ───────────────────────────
    logic             irq_take;
    logic [3:0]       irq_cause;
    logic [31:0]      trap_mepc;    // combined: sync exception OR interrupt
    logic [31:0]      trap_mcause;
    logic [31:0]      trap_mtval;

    // ── MA: CSR ──────────────────────────────────────────────────────────────
    logic [31:0]      csr_mtvec;
    logic [31:0]      csr_mepc;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [31:0]      csr_mstatus;
    /* verilator lint_on  UNUSEDSIGNAL */
    logic [31:0]      csr_mie;
    logic [31:0]      csr_mip;
    logic [31:0]      csr_zimm;
    logic [31:0]      csr_rs1Value;
    logic [31:0]      csr_wrDataRS;
    logic [31:0]      csr_wrDataRC;
    logic [31:0]      csr_wrData;
    logic             csr_wrEnable;

    // ── MA: DMEM ─────────────────────────────────────────────────────────────
    logic [31:0]      load_data;
    logic [3:0]       store_be;
    logic [31:0]      store_data;

  // ===========================================================================
  // INTERMEDIATE SIGNAL DECLARATIONS
  // ===========================================================================


  // ===========================================================================
  // FETCH FRONT END  ──  decoupled fetch FIFO + RVC aligner (fetch_unit)
  // ===========================================================================
  // Fetch advances by a constant +4 (word-aligned) into the I-cache; the
  // I-cache word lands in the fetch FIFO; the aligner extracts the 16/32-bit
  // instruction off the fetch-address path.
  // ===========================================================================

    fetch_unit #(
      .DEPTH (FETCH_DEPTH)
    ) u_fetch (
      .clk         (clk),
      .resetn      (resetn),
      .redirect_en (redirect_en),
      .redirect_pc (redirect_pc),
      .consume     (fe_consume),
      .imem_addr   (imem_addr),
      .imem_data   (imem_data),
      .imem_ready  (imem_ready),
      .instr       (fe_instr),
      .pc          (fe_pc),
      .is_comp     (fe_isComp),
      .valid       (fe_valid)
    );

    assign ma_redirect = branch_miss || trap_en || mret_en;
    assign redirect_en = ma_redirect || pred_redirect;
    assign redirect_pc =
      trap_en     ? csr_mtvec :
      mret_en     ? csr_mepc  :
      branch_miss ? truepc    :
    pred_target;

    pht #(
      .PHT_IDX_W (PHT_IDX_W),
      .INIT      (2'b10)
    ) u_pht (
      .clk        (clk),
      .rd_en      (!redirect_en && !stall && !ex_busy && !dmem_stall && fe_valid),
      .rd_idx     (fe_pc[PHT_IDX_W:1]),
      .rd_counter (if_id_phtCounter),
      .wr_en      (resetn && ex_ma_valid && ex_ma_isBranch && !dmem_stall),
      .wr_idx     (ex_ma_pc[PHT_IDX_W:1]),
      .wr_old     (ex_ma_phtOld),
      .wr_taken   (ex_ma_branchTaken)
    );

  // ===========================================================================
  // FETCH FRONT END
  // ===========================================================================


  // ===========================================================================
  // IF STAGE  ──  fast decode of the aligner head instruction
  // ===========================================================================

    fast_decoder u_fd (
      .instrWord      (fe_instr),
      .rs1_index      (fd_rs1Index),
      .rs2_index      (fd_rs2Index),
      .rd_index       (fd_rdIndex)
    );

    assign fe_consume = fe_valid && !stall && !ex_busy && !dmem_stall && !redirect_en;

  // ===========================================================================
  // IF STAGE
  // ===========================================================================


  // ===========================================================================
  // IF/ID PIPELINE REGISTER
  // ===========================================================================
  // Latches the aligner head into ID. Priority:
  //   redirect                     -> bubble (flush)
  //   stall / ex_busy / dmem_stall -> hold
  //   aligner valid                -> advance (load instruction)
  //   aligner not valid            -> bubble (fetch starved / I-cache miss)
  // ===========================================================================

    always_ff @(posedge clk) begin
      if (!resetn || redirect_en) begin                 // flush -> bubble
        if_id_pc       <= 32'd0;
        if_id_pc2      <= 32'd0;
        if_id_pc4      <= 32'd0;
        if_id_instr    <= `NOP_INSTR;
        if_id_isComp   <= 1'b0;
        if_id_rs1Index <= 5'd0;
        if_id_rs2Index <= 5'd0;
        if_id_rdIndex  <= 5'd0;
        if_id_valid    <= 1'b0;
      end else if (!stall && !ex_busy && !dmem_stall) begin
        if (fe_valid) begin                             // advance
          if_id_pc       <= fe_pc;
          if_id_pc2      <= fe_pc + 32'd2;
          if_id_pc4      <= fe_pc + 32'd4;
          if_id_instr    <= fe_instr;
          if_id_isComp   <= fe_isComp;
          if_id_rs1Index <= fd_rs1Index;
          if_id_rs2Index <= fd_rs2Index;
          if_id_rdIndex  <= fd_rdIndex;
          if_id_valid    <= 1'b1;
        end else begin                                  // fetch starved -> bubble
          if_id_pc       <= 32'd0;
          if_id_pc2      <= 32'd0;
          if_id_pc4      <= 32'd0;
          if_id_instr    <= `NOP_INSTR;
          if_id_isComp   <= 1'b0;
          if_id_rs1Index <= 5'd0;
          if_id_rs2Index <= 5'd0;
          if_id_rdIndex  <= 5'd0;
          if_id_valid    <= 1'b0;
        end
      end
    end

  // ===========================================================================
  // IF/ID PIPELINE REGISTER
  // ===========================================================================


  // ===========================================================================
  // ID STAGE  ──  Full decode, regfile read, hazard detect
  // ===========================================================================

    // ── imm_generator ────────────────────────────────────────────────────────
    imm_generator u_immgen (
      .instrWord      (if_id_instr),
      .is_compressed  (if_id_isComp),
      .immediate      (id_imm)
    );

    // ── control_unit ─────────────────────────────────────────────────────────
    control_unit u_ctrl (
      .instrWord      (if_id_instr),
      .alu_op         (id_aluOp),
      .alu_src_a      (id_aluLHS),
      .alu_src_b      (id_aluRHS),
      .is_branch      (id_isBranch),
      .branch_type    (id_branchType),
      .is_jump        (id_isJump),
      .is_jalr        (id_isJalr),
      .is_muldiv      (id_isMulDiv),
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

    // ── regfile ──────────────────────────────────────────────────────────────
    regfile u_rf (
      .clk            (clk),
      .resetn         (resetn),
      .rd_index_a     (if_id_rs1Index),
      .rd_data_a      (rf_rs1Data),
      .rd_index_b     (if_id_rs2Index),
      .rd_data_b      (rf_rs2Data),
      .wr_index       (ma_wb_rdIndex),
      .wr_data        (wb_fwdValue),
      .wr_en          (ma_wb_regWrite),
      .rs1_ready      (rs1_ready),
      .rs2_ready      (rs2_ready),
      .id_wr_en       (id_wr_en),
      .id_wr_index    (if_id_rdIndex),
      .ma_wr_en       (ma_wr_en),
      .ma_wr_index    (ex_ma_rdIndex),
      .ex_undo_en     (ex_undo_en),
      .ex_undo_index  (id_ex_rdIndex)
    );
 
    assign stall      = if_id_valid && (!rs1_ready || !rs2_ready);
    assign id_wr_en   = if_id_valid && id_regWrite    && !stall && !flush_id_ex && !ex_busy && !dmem_stall;
    assign ex_undo_en = id_ex_valid && id_ex_regWrite && (branch_miss || trap_en || mret_en);
    assign ma_wr_en   = ex_ma_valid && ex_ma_regWrite && !dmem_stall;

    // ── Branch predictor: bimodal PHT direction ──────────────────────────────
    assign pred_target = if_id_pc + id_imm;
    assign pred_taken  = if_id_valid && (
      (id_isJump   && !id_isJalr) ||
      (id_isBranch && if_id_phtCounter[1])
    );
    assign pred_redirect = pred_taken && !stall && !ex_busy && !dmem_stall && !ma_redirect;

  // ===========================================================================
  // ID STAGE
  // ===========================================================================


  // ===========================================================================
  // ID/EX PIPELINE REGISTER
  // ===========================================================================

    assign flush_id_ex = branch_miss || trap_en || mret_en;
    always_ff @(posedge clk) begin
      if ((!ex_busy && !dmem_stall) || flush_id_ex) begin
      id_ex_pc          <= (flush_id_ex || stall) ? 32'd0      : if_id_pc;
      id_ex_pc2         <= (flush_id_ex || stall) ? 32'd0      : if_id_pc2;
      id_ex_pc4         <= (flush_id_ex || stall) ? 32'd0      : if_id_pc4;

      id_ex_instr       <= (flush_id_ex || stall) ? `NOP_INSTR : if_id_instr;
      id_ex_isComp      <= (flush_id_ex || stall) ? 1'b0       : if_id_isComp;
      id_ex_imm         <= (flush_id_ex || stall) ? 32'd0      : id_imm;
      id_ex_isJump      <= (flush_id_ex || stall) ? 1'b0       : id_isJump;
      id_ex_isJalr      <= (flush_id_ex || stall) ? 1'b0       : id_isJalr;
      id_ex_isMulDiv    <= (flush_id_ex || stall) ? 1'b0       : id_isMulDiv;
      id_ex_isBranch    <= (flush_id_ex || stall) ? 1'b0       : id_isBranch;
      id_ex_branchType  <= (flush_id_ex || stall) ? 3'b000     : id_branchType;
      id_ex_predTaken   <= (flush_id_ex || stall) ? 1'b0       : pred_taken;
      id_ex_phtOld      <= (flush_id_ex || stall) ? 2'b01      : if_id_phtCounter;

      id_ex_rs1Index    <= (flush_id_ex || stall) ? 5'd0       : if_id_rs1Index;
      id_ex_rdIndex     <= (flush_id_ex || stall) ? 5'd0       : if_id_rdIndex;
      id_ex_rs1Data     <= (flush_id_ex || stall) ? 32'd0      : (id_aluLHS ? if_id_pc  : rf_rs1Data);
      id_ex_rs2Data     <= (flush_id_ex || stall) ? 32'd0      : (id_aluRHS ? id_imm : rf_rs2Data);
      id_ex_aluOp       <= (flush_id_ex || stall) ? `ALU_ADD   : id_aluOp;

      id_ex_memRead     <= (flush_id_ex || stall) ? 1'b0       : id_memRead;
      id_ex_memWrite    <= (flush_id_ex || stall) ? 1'b0       : id_memWrite;
      id_ex_memWidth    <= (flush_id_ex || stall) ? `WIDTH_W   : id_memWidth;
      id_ex_regWrite    <= (flush_id_ex || stall) ? 1'b0       : id_regWrite;
      id_ex_wbSel       <= (flush_id_ex || stall) ? 2'b00      : id_wbSel;

      id_ex_csrEnable   <= (flush_id_ex || stall) ? 1'b0       : id_csrEnable;
      id_ex_csrOp       <= (flush_id_ex || stall) ? 2'b00      : id_csrOp;
      id_ex_csrUseImm   <= (flush_id_ex || stall) ? 1'b0       : id_csrUseImm;
      id_ex_csrIndex    <= (flush_id_ex || stall) ? 12'd0      : id_csrIndex;
      id_ex_isECALL     <= (flush_id_ex || stall) ? 1'b0       : id_isECALL;
      id_ex_isEBREAK    <= (flush_id_ex || stall) ? 1'b0       : id_isEBREAK;
      id_ex_isMRET      <= (flush_id_ex || stall) ? 1'b0       : id_isMRET;
      id_ex_isIllegal   <= (flush_id_ex || stall) ? 1'b0       : id_isIllegal;
      id_ex_valid       <= (!resetn || flush_id_ex || stall)   ? 1'b0 : if_id_valid;
      end
    end

  // ===========================================================================
  // ID/EX PIPELINE REGISTER
  // ===========================================================================


  // ===========================================================================
  // EX STAGE  ──  ALU, muldiv, branch evaluation + target, CSR read
  // ===========================================================================

    // ── EX operands ──────────────────────────────────────────────────────────
    assign ex_linkAddr = id_ex_isComp ? id_ex_pc2 : id_ex_pc4;

    assign fwd_rs1Value = id_ex_rs1Data;
    assign fwd_rs2Value = id_ex_rs2Data;

    assign alu_lhs      = fwd_rs1Value;
    assign alu_rhs      = fwd_rs2Value;
    assign ex_dmem_addr = fwd_rs1Value + id_ex_imm;

    // ── ALU ──────────────────────────────────────────────────────────────────
    alu u_alu (
      .lhs    (alu_lhs),
      .rhs    (alu_rhs),
      .op     (id_ex_aluOp),
      .result (alu_result)
    );

    // ── muldiv_unit (RV32M, multi-cycle fork in EX) ──────────────────────────
    assign muldiv_active = id_ex_isMulDiv && id_ex_valid;
    assign ex_busy       = resetn && muldiv_active && !muldiv_done;

    muldiv_unit u_muldiv (
      .clk      (clk),
      .resetn   (resetn),
      .valid_in (muldiv_active),
      .consume  (!dmem_stall),
      .flush    (flush_id_ex),
      .opcode   (id_ex_instr[14:12]),
      .a        (fwd_rs1Value),
      .b        (fwd_rs2Value),
      .result   (muldiv_result),
      .done     (muldiv_done)
    );

    assign ex_result = id_ex_isMulDiv ? muldiv_result : alu_result;

    // ── branch_eval ──────────────────────────────────────────────────────────
    branch_eval u_beval (
      .rs1_data     (fwd_rs1Value),
      .rs2_data     (fwd_rs2Value),
      .branch_type  (id_ex_branchType),
      .branch_taken (branch_taken)
    );

    // ── branch_target ────────────────────────────────────────────────────────
    branch_target u_btarget (
      .pc             (id_ex_pc),
      .pc2            (id_ex_pc2),
      .pc4            (id_ex_pc4),
      .rs1_data       (fwd_rs1Value),
      .immediate      (id_ex_imm),
      .is_jalr        (id_ex_isJalr),
      .is_comp        (id_ex_isComp),
      .below_addr     (ex_belowAddr),
      .target_addr    (ex_targetAddr)
    );

    // ── Branch Taken Detection ───────────────────────────────────────────────
    assign ex_branchTaken = (id_ex_isBranch && branch_taken) || id_ex_isJump;

    assign ex_csrLegal = (id_ex_csrOp == `CSR_OP_RW) || (id_ex_csrUseImm
      ? (|id_ex_instr[19:15])
      : (|id_ex_rs1Index));

    // ── CSR regfile (read port -> write happens in MA) ───────────────────────
    csr_regfile u_csr (
      .clk         (clk),
      .resetn      (resetn),
      .rd_addr     (ex_ma_csrIndex),
      .rd_data     (csr_rdData),
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
      .out_mepc    (csr_mepc),
      .out_mie     (csr_mie),
      .out_mip     (csr_mip),
      .hw_mtip     (irq_timer),
      .hw_msip     (irq_soft),
      .hw_meip     (irq_ext)
    );

  // ===========================================================================
  // EX STAGE
  // ===========================================================================


  // ===========================================================================
  // EX/MA PIPELINE REGISTER
  // ===========================================================================

    assign flush_ex_ma = trap_en || mret_en || branch_miss || ex_busy;
    always_ff @(posedge clk) begin
      if (!dmem_stall) begin
      ex_ma_pc          <= (flush_ex_ma) ? 32'd0      : id_ex_pc;
      ex_ma_linkAddr    <= (flush_ex_ma) ? 32'd0      : ex_linkAddr;
 
      ex_ma_belowAddr   <= (flush_ex_ma) ? 32'd0      : ex_belowAddr;
      ex_ma_targetAddr  <= (flush_ex_ma) ? 32'd0      : ex_targetAddr;
      ex_ma_branchTaken <= (flush_ex_ma) ? 1'b0       : ex_branchTaken;
      ex_ma_predTaken   <= (flush_ex_ma) ? 1'b0       : id_ex_predTaken;
      ex_ma_isBranch    <= (flush_ex_ma) ? 1'b0       : id_ex_isBranch;
      ex_ma_phtOld      <= (flush_ex_ma) ? 2'b01      : id_ex_phtOld;

      ex_ma_instr       <= (flush_ex_ma) ? `NOP_INSTR : id_ex_instr;
 
      ex_ma_rdIndex     <= (flush_ex_ma) ? 5'd0       : id_ex_rdIndex;
      ex_ma_rs1Fwd      <= (flush_ex_ma) ? 32'd0      : fwd_rs1Value;
      ex_ma_rs2Fwd      <= (flush_ex_ma) ? 32'd0      : fwd_rs2Value;
      ex_ma_aluResult   <= (flush_ex_ma) ? 32'd0      : ex_result;
      ex_ma_dmemAddr    <= (flush_ex_ma) ? 32'd0      : ex_dmem_addr;
 
      ex_ma_memRead     <= (flush_ex_ma) ? 1'b0       : id_ex_memRead;
      ex_ma_memWrite    <= (flush_ex_ma) ? 1'b0       : id_ex_memWrite;
      ex_ma_memWidth    <= (flush_ex_ma) ? `WIDTH_W   : id_ex_memWidth;
      ex_ma_regWrite    <= (flush_ex_ma) ? 1'b0       : id_ex_regWrite;
      ex_ma_wbSel       <= (flush_ex_ma) ? 2'b00      : id_ex_wbSel;
 
      ex_ma_csrEnable   <= (flush_ex_ma) ? 1'b0       : id_ex_csrEnable;
      ex_ma_csrOp       <= (flush_ex_ma) ? 2'b00      : id_ex_csrOp;
      ex_ma_csrUseImm   <= (flush_ex_ma) ? 1'b0       : id_ex_csrUseImm;
      ex_ma_csrIndex    <= (flush_ex_ma) ? 12'd0      : id_ex_csrIndex;
      ex_ma_isECALL     <= (flush_ex_ma) ? 1'b0       : id_ex_isECALL;
      ex_ma_isEBREAK    <= (flush_ex_ma) ? 1'b0       : id_ex_isEBREAK;
      ex_ma_isMRET      <= (flush_ex_ma) ? 1'b0       : id_ex_isMRET;
      ex_ma_isIllegal   <= (flush_ex_ma) ? 1'b0       : id_ex_isIllegal;
      ex_ma_csrLegal    <= (flush_ex_ma) ? 1'b0       : ex_csrLegal;
      ex_ma_valid       <= (!resetn || flush_ex_ma)   ? 1'b0 : id_ex_valid;
      end
    end

  // ===========================================================================
  // EX/MA PIPELINE REGISTER
  // ===========================================================================


  // ===========================================================================
  // MA STAGE  ──  Trap detection, CSR access, DMEM access, load extraction,
  //               branch resolution + PHT/BTB update
  // ===========================================================================
 
    // ── trap_unit ────────────────────────────────────────────────────────────
    trap_unit u_trap (
      .ma_pc         (ex_ma_pc),
      .ma_instr      (ex_ma_instr),
      .ma_dmemAddr   (ex_ma_dmemAddr),
      .ma_mem_read   (ex_ma_memRead),
      .ma_mem_write  (ex_ma_memWrite),
      .ma_mem_width  (ex_ma_memWidth),
      .ma_is_ecall   (ex_ma_isECALL),
      .ma_is_ebreak  (ex_ma_isEBREAK),
      .ma_is_illegal (ex_ma_isIllegal),
      .ma_is_mret    (ex_ma_isMRET),
      .trap_en       (sync_trap),
      .trap_mepc     (sync_mepc),
      .trap_mcause   (sync_mcause),
      .trap_mtval    (sync_mtval),
      .mret_en       (mret_en)
    );

    // ── interrupt_unit: evaluate async interrupts at the MA instruction ──────
    interrupt_unit u_irq (
      .mie         (csr_mie),
      .mip         (csr_mip),
      .mstatus_mie (csr_mstatus[3]),
      .ma_valid    (ex_ma_valid && !dmem_stall),
      .sync_trap   (sync_trap),
      .irq_take    (irq_take),
      .irq_cause   (irq_cause)
    );

    // ── Combined trap: synchronous exception OR asynchronous interrupt ───────
    // Both save the MA instruction's PC (sync_mepc == ex_ma_pc). The interrupted
    // instruction does not commit so it cleanly re-executes when the handler returns.
    assign trap_en      = sync_trap || irq_take;
    assign trap_mepc    = sync_mepc;
    assign trap_mcause  = irq_take ? {1'b1, 27'b0, irq_cause} : sync_mcause;
    assign trap_mtval   = irq_take ? 32'd0 : sync_mtval;

    // ── Multi-cycle memory stall ─────────────────────────────────────────────
    assign mem_access = ex_ma_valid && (ex_ma_memRead || ex_ma_memWrite);
    assign dmem_req   = mem_access  && !sync_trap;
    assign dmem_stall  = resetn && dmem_req && !dmem_ready;

    // ── Branch Miss Detection ────────────────────────────────────────────────
    assign branch_miss   = !trap_en && !mret_en && (ex_ma_branchTaken != ex_ma_predTaken);

    assign truepc  = ex_ma_branchTaken ? ex_ma_targetAddr  : ex_ma_belowAddr;

    // ── CSR Read-Modify-Write ────────────────────────────────────────────────
    assign csr_zimm     = {27'd0, ex_ma_instr[19:15]};
    assign csr_rs1Value = ex_ma_csrUseImm ? csr_zimm : ex_ma_rs1Fwd;
    assign csr_wrDataRS = csr_rdData |  csr_rs1Value;
    assign csr_wrDataRC = csr_rdData & ~csr_rs1Value;
    always_comb begin
      case (ex_ma_csrOp)
        `CSR_OP_RW: csr_wrData = csr_rs1Value;
        `CSR_OP_RS: csr_wrData = csr_wrDataRS;
        `CSR_OP_RC: csr_wrData = csr_wrDataRC;
        default:    csr_wrData = 32'd0;
      endcase
    end
    assign csr_wrEnable = ex_ma_csrEnable && ex_ma_csrLegal;

    // ── DMEM load extraction ─────────────────────────────────────────────────
    always_comb begin
      unique case ({ex_ma_memWidth, ex_ma_dmemAddr[1:0]})
        // ── LB  (signed byte) ────────────────────────────────────────────────
        {`WIDTH_B,  2'b00}: load_data = {{24{dmem_rdata[7]}},  dmem_rdata[7:0]};
        {`WIDTH_B,  2'b01}: load_data = {{24{dmem_rdata[15]}}, dmem_rdata[15:8]};
        {`WIDTH_B,  2'b10}: load_data = {{24{dmem_rdata[23]}}, dmem_rdata[23:16]};
        {`WIDTH_B,  2'b11}: load_data = {{24{dmem_rdata[31]}}, dmem_rdata[31:24]};
        // ── LBU (unsigned byte) ──────────────────────────────────────────────
        {`WIDTH_BU, 2'b00}: load_data = {24'd0, dmem_rdata[7:0]};
        {`WIDTH_BU, 2'b01}: load_data = {24'd0, dmem_rdata[15:8]};
        {`WIDTH_BU, 2'b10}: load_data = {24'd0, dmem_rdata[23:16]};
        {`WIDTH_BU, 2'b11}: load_data = {24'd0, dmem_rdata[31:24]};
        // ── LH  (signed halfword) ────────────────────────────────────────────
        {`WIDTH_H,  2'b00}: load_data = {{16{dmem_rdata[15]}}, dmem_rdata[15:0]};
        {`WIDTH_H,  2'b10}: load_data = {{16{dmem_rdata[31]}}, dmem_rdata[31:16]};
        // ── LHU (unsigned halfword) ──────────────────────────────────────────
        {`WIDTH_HU, 2'b00}: load_data = {16'd0, dmem_rdata[15:0]};
        {`WIDTH_HU, 2'b10}: load_data = {16'd0, dmem_rdata[31:16]};
        // ── LW  (word) ───────────────────────────────────────────────────────
        {`WIDTH_W,  2'b00}: load_data = dmem_rdata;
        default:            load_data = dmem_rdata;
      endcase
    end
 
    // ── DMEM store: byte enables and lane placement ──────────────────────────
    always_comb begin
      unique case ({ex_ma_memWidth, ex_ma_dmemAddr[1:0]})
        // ── SB (byte) ────────────────────────────────────────────────────────
        {`WIDTH_B, 2'b00}: begin store_be = 4'b0001; store_data = {24'd0, ex_ma_rs2Fwd[7:0]};        end
        {`WIDTH_B, 2'b01}: begin store_be = 4'b0010; store_data = {16'd0, ex_ma_rs2Fwd[7:0],  8'd0}; end
        {`WIDTH_B, 2'b10}: begin store_be = 4'b0100; store_data = {8'd0,  ex_ma_rs2Fwd[7:0], 16'd0}; end
        {`WIDTH_B, 2'b11}: begin store_be = 4'b1000; store_data = {       ex_ma_rs2Fwd[7:0], 24'd0}; end
        // ── SH (halfword) ────────────────────────────────────────────────────
        {`WIDTH_H, 2'b00}: begin store_be = 4'b0011; store_data = {16'd0, ex_ma_rs2Fwd[15:0]};       end
        {`WIDTH_H, 2'b10}: begin store_be = 4'b1100; store_data = {ex_ma_rs2Fwd[15:0], 16'd0};       end
        // ── SW (word) ────────────────────────────────────────────────────────
        {`WIDTH_W, 2'b00}: begin store_be = 4'b1111; store_data = ex_ma_rs2Fwd;                       end
        default:           begin store_be = 4'b1111; store_data = ex_ma_rs2Fwd;                       end
      endcase
    end

    // ── DMEM port assignments ────────────────────────────────────────────────
    assign dmem_raddr = ex_dmem_addr;
    assign dmem_waddr = ex_ma_dmemAddr;
    assign dmem_we    = ex_ma_memWrite && !trap_en;
    assign dmem_be    = store_be;
    assign dmem_wdata = store_data;

  // ===========================================================================
  // MA STAGE
  // ===========================================================================


  // ===========================================================================
  // MA/WB PIPELINE REGISTER
  // ===========================================================================

    always_ff @(posedge clk) begin
      ma_wb_pc        <= (dmem_stall)            ? 32'd0  : ex_ma_pc;
      ma_wb_rdIndex   <= (dmem_stall)            ? 5'd0   : ex_ma_rdIndex;
      ma_wb_aluResult <= (dmem_stall)            ? 32'd0  : ex_ma_aluResult;
      ma_wb_loadData  <= (dmem_stall)            ? 32'd0  : load_data;
      ma_wb_csrData   <= (dmem_stall)            ? 32'd0  : csr_rdData;
      ma_wb_linkAddr  <= (dmem_stall)            ? 32'd0  : ex_ma_linkAddr;
      ma_wb_regWrite  <= (dmem_stall || !resetn) ? 1'b0   : ex_ma_regWrite && !trap_en;
      ma_wb_wbSel     <= (dmem_stall)            ? 2'b00  : ex_ma_wbSel;
    end

  // ===========================================================================
  // MA/WB PIPELINE REGISTER
  // ===========================================================================


  // ===========================================================================
  // WB STAGE  ──  Writeback mux (wb_fwdValue)
  // ===========================================================================
  // wb_fwdValue simultaneously drives:
  //   • regfile.wr_data  - commits result to the architectural register file
  // ===========================================================================

    always_comb begin
      case (ma_wb_wbSel)
        2'b00: wb_fwdValue = ma_wb_aluResult;
        2'b01: wb_fwdValue = ma_wb_loadData;
        2'b10: wb_fwdValue = ma_wb_linkAddr;
        2'b11: wb_fwdValue = ma_wb_csrData;
      endcase
    end

  // ===========================================================================
  // WB STAGE
  // ===========================================================================


endmodule

