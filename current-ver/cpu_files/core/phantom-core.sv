`include "isa.vh"
// =============================================================================
// PHANTOM-32  ──  Phantom Core  (6-Stage Pipelined RV32IC Execution Core)
// =============================================================================
// Single execution pipeline - instantiated by cpu.sv which adds caches and
// the memory bus. tb_core.sv instantiates this module directly for compliance
// simulation using behavioural memory models.
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
// ── Branch prediction (gshare, pipelined) ────────────────────────────────────
//   PHT: 8192 × 2-bit saturating counters (1 EBR block).
//     Index = BHR[12:0] XOR r_pc[13:1]  (computed in PreIF, MAR latches at edge)
//     Output available combinationally in IF (1-cycle BSRAM read latency).
//
//   BTB: 512 × 32-bit target addresses (1 EBR block).
//     MAR ← next_pc[9:1] at each clock edge.
//     Output = predicted target for r_pc, available combinationally in IF.
//
//   BHR: 13-bit shift register.  Speculatively updated in IF by "join"
//     (shift left, insert prediction bit).  Reset to 0 on branch_miss.
//
//   Prediction decision ("comb"): pred_taken = pht_rdata[1] (PHT MSB).
//     If pred_taken: next_pc = r_predpc (BTB target), else sequential.
//
//   Misprediction detection ("branch_miss") in MA:
//     Compares actual taken/target against what was predicted.
//     Flushes 3 stages; restores PC to TruePC and BHR to 0.
//
//   PHT written in MA with 2-bit saturating counter update (branches only).
//   BTB written in MA with actual target on any taken branch/jump.
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
module phantom_core (
  input  logic        clk,
  input  logic        resetn,          // active-low synchronous reset
 
  // ── Instruction memory ─────────────────────────────────────────────────────
  output logic [31:0] imem_addr_a,     // fetch address: NextPC
  output logic [31:0] imem_addr_b,     // fetch address: NextPC + 2
  input  logic [15:0] imem_data_a,     // halfword at PC
  input  logic [15:0] imem_data_b,     // halfword at PC + 2
 
  // ── Data memory ────────────────────────────────────────────────────────────
  output logic [31:0] dmem_raddr,      // read address  (EX    -> SDPB Port B)
  output logic [31:0] dmem_waddr,      // write address (EX/MA -> SDPB Port A)
  output logic [31:0] dmem_wdata,      // store data (byte-lane shifted)
  output logic        dmem_we,         // write enable (gated off on trap)
  output logic [3:0]  dmem_be,         // per-byte write enables
  input  logic [31:0] dmem_rdata       // load data (full 32-bit word)
);

  // ===========================================================================
  // BRANCH PREDICTOR DIMENSIONS & BSRAM ARRAYS
  // ===========================================================================
  // PHT: 8192 × 2-bit saturating counters.  Yosys infers one DP16KD EBR block.
  // BTB: 512  × 32-bit target addresses.    Yosys infers one DP16KD EBR block.
  // Both initialize to 0 (predict not-taken / target=0) on FPGA power-up.
  // ===========================================================================
    localparam integer PHT_DEPTH  = 8192; // 2^13 PHT entries (2-bit counters)
    localparam integer PHT_IDX_W  = 13;
    localparam integer BTB_DEPTH  = 512;  // 2^9  BTB entries (32-bit targets)
    localparam integer BTB_IDX_W  = 9;
    localparam integer BHR_W      = 13;

    (* ram_style = "block" *) logic [1:0]  pht [0:PHT_DEPTH - 1];
    (* ram_style = "block" *) logic [31:0] btb [0:BTB_DEPTH - 1];
  // ===========================================================================
  // BRANCH PREDICTOR DIMENSIONS & BSRAM ARRAYS
  // ===========================================================================
 

  // ===========================================================================
  // PIPELINE REGISTER STORAGE
  // ===========================================================================

    // ── PreIF/IF ─────────────────────────────────────────────────────────────
    logic [31:0] r_pc;              // Main ProgramCounter register
    logic [31:0] r_pc2;             // Main ProgramCounter register (+2)
    logic [31:0] r_pc4;             // Main ProgramCounter register (+4)
    logic [31:0] r_pc6;             // Main ProgramCounter register (+6)
    // ── Branch predictor PreIF/IF registers ──────────────────────────────────
    logic [31:0]      r_predpc;     // BTB predicted target for r_pc
    logic [31:0]      r_predpc2;    // r_predpc + 2
    logic             r_predTaken;  // 1 = prediction was taken for r_pc
    logic [BHR_W-1:0] r_bhr;        // Branch History Register (speculative)

    // ── IF/ID ────────────────────────────────────────────────────────────────
    logic [31:0] if_id_instr;       // assembled instruction word
    logic [31:0] if_id_pc;          // PC of the current instruction in ID
    logic [31:0] if_id_pc2;         // PC + 2 of the current instruction in ID
    logic [31:0] if_id_pc4;         // PC + 4 of the current instruction in ID
    logic        if_id_isComp;      // 0 = 32-bit instruction | 1 = 16-bit compressed
    logic [4:0]  if_id_rs1Index;    // rs1 index (from fast_decoder)
    logic [4:0]  if_id_rs2Index;    // rs2 index (from fast_decoder)
    logic [4:0]  if_id_rdIndex;     // rd  index (from fast_decoder, for hazard unit)
    logic        if_id_isLoad;      // 1 = load  (from fast_decoder, for hazard unit)
    // ── Branch predictor IF/ID registers ─────────────────────────────────────
    logic [31:0]          if_id_predpc;     // propagate predicted target to MA-stage
    logic                 if_id_predTaken;  // propagate prediction bit   to MA-stage
    logic [1:0]           if_id_phtOld;     // PHT counter value at prediction time
    logic [PHT_IDX_W-1:0] if_id_phtIdx;     // PHT index used for this prediction

    // ── ID/EX ────────────────────────────────────────────────────────────────
    logic [3:0]  id_ex_aluOp;       // ALU opcode
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
    logic        id_ex_isECALL;     // ECALL   instruction flag
    logic        id_ex_isEBREAK;    // EBREAK  instruction flag
    logic        id_ex_isMRET;      // MRET    instruction flag
    logic        id_ex_isIllegal;   // illegal instruction flag
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
    logic [31:0] id_ex_imm2;        // imm + 2, used for TakenPC_2 = ex_targetAddr + 2
    logic [31:0] id_ex_instr;       // raw instruction word
    // ── Branch predictor ID/EX registers ─────────────────────────────────────
    logic [31:0]          id_ex_predpc;     // propagate predicted target to MA-stage
    logic                 id_ex_predTaken;  // propagate prediction bit   to MA-stage
    logic [1:0]           id_ex_phtOld;     // PHT counter value at prediction time
    logic [PHT_IDX_W-1:0] id_ex_phtIdx;     // PHT index used for this prediction

    // ── EX/MA ────────────────────────────────────────────────────────────────
    logic [31:0] ex_ma_aluResult;   // Result from the ALU unit
    logic [31:0] ex_ma_dmemAddr;    // DMEM byte address (rs1_fwd + imm)
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
    logic        ex_ma_isECALL;     // ECALL   instruction flag
    logic        ex_ma_isEBREAK;    // EBREAK  instruction flag
    logic        ex_ma_isMRET;      // MRET    instruction flag
    logic        ex_ma_isIllegal;   // illegal instruction flag
    logic [31:0] ex_ma_pc;          // PC of the current instruction in MA
    logic [31:0] ex_ma_pc2;         // |
    logic [31:0] ex_ma_pc4;         // |> used for BelowPC computation/selector
    logic        ex_ma_isComp;      // \
    logic [31:0] ex_ma_instr;       // raw instruction word
    logic [31:0] ex_ma_linkAddr;    // PC + 2 or PC + 4 (JAL/JALR link)
    logic        ex_ma_rdNonZero;   // 1 = ex_ma_rdIndex != 5'd0
    logic        ex_ma_csrWrGuard;  // 1 = csr write is allowed
    // ── Branch predictor EX/MA registers ─────────────────────────────────────
    logic [31:0]          ex_ma_predpc;      // what target did the predictor give?
    logic                 ex_ma_predTaken;   // was prediction taken for this instr?
    logic [1:0]           ex_ma_phtOld;      // old PHT counter (for saturating update)
    logic [PHT_IDX_W-1:0] ex_ma_phtIdx;      // PHT write-back index
    logic [31:0]          ex_ma_targetAddr;  // actual branch/jump target (for TruePC)
    logic                 ex_ma_branchTaken; // actual taken result from branch_eval
    logic                 ex_ma_isBranch;    // 1 = conditional branch instruction
    logic                 ex_ma_isJump;      // 1 = unconditional jump (JAL/JALR)

    // ── MA/WB ────────────────────────────────────────────────────────────────
    logic [31:0] ma_wb_aluResult;   // Result from the ALU unit
    logic [31:0] ma_wb_loadData;    // sign/zero-extended load result
    logic [31:0] ma_wb_csrOldData;  // old CSR value (returned to rd)
    logic [31:0] ma_wb_linkAddr;    // PC + 2 or PC + 4 (JAL/JALR link)
    logic [4:0]  ma_wb_rdIndex;     // rd index to write data into
    logic        ma_wb_regWrite;    // Register Write flag
    logic [1:0]  ma_wb_wbSel;       // Write-Back Stage MUX selector
    logic        ma_wb_rdNonZero;   // 1 = ma_wb_rdIndex != 5'd0

  // ===========================================================================
  // PIPELINE REGISTER STORAGE
  // ===========================================================================


  // ===========================================================================
  // INTERMEDIATE SIGNAL DECLARATIONS
  // ===========================================================================

    // ── Control / Hazard / Flush ─────────────────────────────────────────────
    logic        stall;           // Stall Fetch flag
    logic        branch_miss;     // Misprediction detected in MA-stage
    logic        trap_en;         // Trap Enable flag
    logic        mret_en;         // MRET flag
    logic        flush_if_id;     // 1 = flush the IF/ID pipeline register
    logic        flush_id_ex;     // 1 = flush the ID/EX pipeline register
    logic        flush_ex_ma;     // 1 = flush the EX/MA pipeline register
    logic [31:0] next_pc;         // NextPC     value from NextPC MUX
    logic [31:0] next_pc2;        // NextPC + 2 value from NextPC MUX

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
    logic        id_aluLHS;        // rs1Data pre-select (0 = rs1, 1 = PC)
    logic        id_aluRHS;        // rs2Data pre-select (0 = rs2, 1 = imm)
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
    logic [31:0] alu_lhs;          // ALU LHS input value
    logic [31:0] alu_rhs;          // ALU RHS input value
    logic [31:0] alu_result;       // ALU output result value
    logic [31:0] ex_dmem_addr;     // dedicated DMEM address (rs1_fwd + imm)
    logic        branch_taken;     // Computed (NOT predicted) branch taken
    /* verilator lint_off UNUSEDSIGNAL */
    logic [31:0] csr_rdData;       // CSR read with write-before-read forwarding
    /* verilator lint_on UNUSEDSIGNAL */
    logic [31:0] csr_rdDataRaw;    // CSR RAW read (NO forwarding) - used for RMW
    logic [31:0] ex_linkAddr;      // PC + 2 or PC + 4 (JAL/JALR link)
    logic        ex_csrWrGuard;    // 1 = write is allowed

    // ── Branch predictor EX signals ──────────────────────────────────────────
    logic [31:0] ex_targetAddr;    // branch/jump target address
    /* verilator lint_off UNUSEDSIGNAL */
    logic [31:0] ex_targetAddr2;   // branch/jump target address + 2
    /* verilator lint_on  UNUSEDSIGNAL */

    // ── Branch predictor PreIF signals ───────────────────────────────────────
    logic [PHT_IDX_W-1:0] pht_mar; // PHT Memory Access Register
    logic [BTB_IDX_W-1:0] btb_mar; // BTB Memory Access Register
    logic [1:0]  pht_rdata;        // combinational PHT output (2-bit counter)
    logic [31:0] btb_rdata;        // combinational BTB output (target address)
    logic        pred_taken;       // prediction bit: pht_rdata[1]

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

    // ── Branch predictor MA signals ───────────────────────────────────────────
    logic [31:0] truepc;           // TruePC  - the correct PC to redirect to
    logic [31:0] below_pc;         // BelowPC - instruction following the branch

    // ── MemoryAccess Combinational Registers ─────────────────────────────────
    logic [31:0] load_data;        // load instruction's fetched data
    logic [3:0]  store_be;         // per-byte write enable register
    logic [31:0] store_data;       // store data (byte-lane shifted)

  // ===========================================================================
  // INTERMEDIATE SIGNAL DECLARATIONS
  // ===========================================================================


  // ===========================================================================
  // PreIF STAGE  ──  NextPC MUX, PC register, PHT/BTB MAR, BHR update
  // ===========================================================================
  //
  //  PreIF input registers: r_pc, r_pc2, r_pc4, r_pc6, r_bhr
  //    These receive their values at the clock edge from the IF stage outputs
  //    (next_pc, next_pc2, bhr_join).
  //
  //  PreIF combinational:
  //    pht_rd_idx = r_bhr XOR r_pc[13:1]  → feeds PHT MAR (latches at clock edge)
  //    BTB MAR ← next_pc[BTB_IDX_W:1]                     (latches at clock edge)
  //
  //  After the clock edge, in IF:
  //    PHT data = pht[pht_mar]  (combinational, 1-cycle latency)
  //    BTB data = btb[btb_mar]  (combinational, 1-cycle latency)
  //    These give the prediction for the instruction now at r_pc.
  // ===========================================================================

    // ── PC registers (r_pc = old next_pc, r_pc2 = old next_pc2) ──────────────
    always_ff @(posedge clk) begin
      r_pc  <= next_pc;
      r_pc2 <= next_pc2;
      r_pc4 <= next_pc2 + 32'd2;
      r_pc6 <= next_pc2 + 32'd4;
    end

    // ── PHT MAR: latch XOR(r_bhr, r_pc[13:1]) at every clock edge ────────────
    always_ff @(posedge clk) pht_mar <= r_bhr ^ r_pc[PHT_IDX_W:1];

    // ── BTB MAR: latch next_pc[BTB_IDX_W:1] at every clock edge ──────────────
    always_ff @(posedge clk) btb_mar <= next_pc[BTB_IDX_W:1];

    // ── PHT and BTB combinational reads (data valid in IF stage) ─────────────
    assign pht_rdata = pht[pht_mar];
    assign btb_rdata = btb[btb_mar];

    // ── Prediction decision ("comb" unit) ────────────────────────────────────
    // MSB of the 2-bit saturating counter: 1x = weakly/strongly taken.
    assign pred_taken = pht_rdata[1];
    // ── BHR register: speculative update ("join") or recovery ────────────────
    // join:        shift BHR left, insert prediction bit at LSB.
    // branch_miss: reset to 0
    always_ff @(posedge clk) begin
      if (!resetn || branch_miss) begin
        r_bhr <= '0;
      end else if (!stall) begin
        r_bhr <= {r_bhr[BHR_W-2:0], pred_taken};
      end
    end
    // ── PredPC / PredPC_2 / r_predTaken registers ───────────────────────────
    always_ff @(posedge clk) begin
      if (!resetn || branch_miss || trap_en || mret_en) begin
        r_predTaken  <= 1'b0;
        r_predpc     <= 32'd0;
        r_predpc2    <= 32'd2;
      end else if (stall) begin
        // hold: prediction registers stay unchanged while PC frozen
      end else begin
        r_predTaken  <= pred_taken;
        r_predpc     <= btb_rdata;
        r_predpc2    <= btb_rdata + 32'd2;
      end
    end

  // ===========================================================================
  // PreIF STAGE
  // ===========================================================================


  // ===========================================================================
  // IF STAGE  ──  Instruction assembly and fast decode
  // ===========================================================================
  // NextPC MUX Priority (highest first):
  //   0: !resetn      → RESET_VECTOR          (reset)
  //   1: trap_en      → csr_mtvec             (exception entry)
  //   2: mret_en      → csr_mepc              (return from trap)
  //   3: branch_miss  → truepc                (misprediction correction, from MA)
  //   4: stall        → r_pc                  (load-use stall, hold PC)
  //   5: pred_taken   → r_predpc              (follow branch prediction)
  //   6: default      → pc_inc_seq (+2 or +4) (sequential advance)
  // ===========================================================================

    // ── IMEM port assignments ────────────────────────────────────────────────
    assign imem_addr_a = next_pc;
    assign imem_addr_b = next_pc2;

    // ── Pre-calculating ALL possible targets ─────────────────────────────────
    logic [31:0] pc_inc_seq;   assign pc_inc_seq    = if_isCompressed ? r_pc2 : r_pc4;
    logic [31:0] pc_inc_seq2;  assign pc_inc_seq2   = if_isCompressed ? r_pc4 : r_pc6;
    logic [31:0] csr_mtvec2;   assign csr_mtvec2    = csr_mtvec     + 32'd2;
    logic [31:0] csr_mepc2;    assign csr_mepc2     = csr_mepc      + 32'd2;
    logic [31:0] truepc2_wire; assign truepc2_wire  = truepc        + 32'd2;

    // ── One-Hot nextpc_sel ───────────────────────────────────────────────────
    logic [6:0] nextpc_sel;
    assign nextpc_sel[0] = !resetn;
    assign nextpc_sel[1] =  resetn &&  trap_en;
    assign nextpc_sel[2] =  resetn && !trap_en &&  mret_en;
    assign nextpc_sel[3] =  resetn && !trap_en && !mret_en &&  branch_miss;
    assign nextpc_sel[4] =  resetn && !trap_en && !mret_en && !branch_miss &&  stall;
    assign nextpc_sel[5] =  resetn && !trap_en && !mret_en && !branch_miss && !stall &&  pred_taken;
    assign nextpc_sel[6] =  resetn && !trap_en && !mret_en && !branch_miss && !stall && !pred_taken;

    // ── Parallel NextPC MUX ──────────────────────────────────────────────────
    always_comb begin
      unique case (1'b1)
        nextpc_sel[0]: next_pc = `RESET_VECTOR;
        nextpc_sel[1]: next_pc = csr_mtvec;
        nextpc_sel[2]: next_pc = csr_mepc;
        nextpc_sel[3]: next_pc = truepc;
        nextpc_sel[4]: next_pc = r_pc;
        nextpc_sel[5]: next_pc = r_predpc;
        nextpc_sel[6]: next_pc = pc_inc_seq;
        default:       next_pc = `RESET_VECTOR;
      endcase
    end

    // ── Parallel NextPC + 2 MUX ──────────────────────────────────────────────
    always_comb begin
      unique case (1'b1)
        nextpc_sel[0]: next_pc2 = `RESET_VECTOR + 32'd2;
        nextpc_sel[1]: next_pc2 = csr_mtvec2;
        nextpc_sel[2]: next_pc2 = csr_mepc2;
        nextpc_sel[3]: next_pc2 = truepc2_wire;
        nextpc_sel[4]: next_pc2 = r_pc2;
        nextpc_sel[5]: next_pc2 = r_predpc2;
        nextpc_sel[6]: next_pc2 = pc_inc_seq2;
        default:       next_pc2 = `RESET_VECTOR + 32'd2;
      endcase
    end

    // ── Instruction assembly ─────────────────────────────────────────────────
    assign if_isCompressed = (imem_data_a[1:0] != 2'b11);
    assign if_instr        =
       if_isCompressed     ? {16'd0,       imem_data_a}
      /* not compressed */ : {imem_data_b, imem_data_a};

    // ── fast_decoder ─────────────────────────────────────────────────────────
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
  // Flush on branch_miss (same 3-cycle penalty as trap/MRET).
  // Stall inserts NOP and holds PC — prediction registers cleared too
  // (the stalled instruction will be re-evaluated with correct prediction
  // when it re-enters IF on the next cycle).
  // ===========================================================================
    assign flush_if_id = branch_miss || trap_en || mret_en;
    always_ff @(posedge clk) begin
      if (!resetn || flush_if_id) begin
        if_id_instr     <= `NOP_INSTR;
        if_id_pc        <= 32'd0;
        if_id_pc2       <= 32'd0;
        if_id_pc4       <= 32'd0;
        if_id_isComp    <= 1'b0;
        if_id_rs1Index  <= 5'd0;
        if_id_rs2Index  <= 5'd0;
        if_id_rdIndex   <= 5'd0;
        if_id_isLoad    <= 1'b0;
        if_id_predTaken <= 1'b0;
        if_id_predpc    <= 32'd0;
        if_id_phtIdx    <= '0;
        if_id_phtOld    <= 2'b01;
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
        if_id_predTaken <= 1'b0;
        if_id_predpc    <= 32'd0;
        if_id_phtIdx    <= '0;
        if_id_phtOld    <= 2'b01;
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
        if_id_predTaken <= r_predTaken;
        if_id_predpc    <= r_predpc;
        if_id_phtIdx    <= pht_mar;
        if_id_phtOld    <= pht_rdata;
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
    assign flush_id_ex = branch_miss || trap_en || mret_en;
    always_ff @(posedge clk) begin
      if (!resetn || flush_id_ex) begin
        id_ex_aluOp      <= `ALU_ADD;
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
        id_ex_predTaken  <= 1'b0;
        id_ex_predpc     <= 32'd0;
        id_ex_phtIdx     <= '0;
        id_ex_phtOld     <= 2'b01;
      end else begin
        id_ex_aluOp      <= id_aluOp;
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
        id_ex_rs1Data    <= id_aluLHS ? if_id_pc : rf_rs1Data;
        id_ex_rs2Data    <= id_aluRHS ? id_imm   : rf_rs2Data;
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
        id_ex_predTaken  <= if_id_predTaken;
        id_ex_predpc     <= if_id_predpc;
        id_ex_phtIdx     <= if_id_phtIdx;
        id_ex_phtOld     <= if_id_phtOld;
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
    assign ex_linkAddr = id_ex_isComp ? id_ex_pc2 : id_ex_pc4;
    always_comb begin
      case (ex_ma_wbSel)
        2'b00: ma_fwdValue = ex_ma_aluResult;
        2'b01: ma_fwdValue = 32'hDEADBEEF;
        2'b10: ma_fwdValue = ex_ma_linkAddr;
        2'b11: ma_fwdValue = csr_rdDataRaw;
      endcase
    end

    // ── Forwarding unit ──────────────────────────────────────────────────────
    forward_unit u_fwd (
      .ex_rs1_index  (id_ex_rs1Index),
      .ex_rs2_index  (id_ex_rs2Index),
      .ma_rd_index   (ex_ma_rdIndex),
      .ma_reg_write  (ex_ma_regWrite),
      .ma_rd_nonzero (ex_ma_rdNonZero),
      .wb_rd_index   (ma_wb_rdIndex),
      .wb_reg_write  (ma_wb_regWrite),
      .wb_rd_nonzero (ma_wb_rdNonZero),
      .fwd_A_sel     (fwd_rs1Sel),
      .fwd_B_sel     (fwd_rs2Sel)
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
    assign alu_lhs = fwd_rs1Value;
    assign alu_rhs = fwd_rs2Value;
 
    // ── Dedicated DMEM address adder ──────────────────────────────────────────
    // rs1_fwd + imm with no intervening muxes or ALU case statement.
    assign ex_dmem_addr = fwd_rs1Value + id_ex_imm;

    // ── ALU ──────────────────────────────────────────────────────────────────
    alu u_alu (
      .lhs    (alu_lhs),
      .rhs    (alu_rhs),
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
      .pc            (id_ex_pc),
      .rs1_data      (fwd_rs1Value),
      .immediate     (id_ex_imm),
      .immediate_2   (id_ex_imm2),
      .is_jalr       (id_ex_isJalr),
      .target_addr   (ex_targetAddr),
      .target_addr_2 (ex_targetAddr2)
    );

    assign ex_csrWrGuard = (id_ex_csrOp == `CSR_OP_RW) || (id_ex_csrUseImm
      ? (|id_ex_instr[19:15])
      : (id_ex_rs1Index != 5'd0));

  // ===========================================================================
  // EX STAGE
  // ===========================================================================


  // ===========================================================================
  // EX/MA PIPELINE REGISTER
  // ===========================================================================
  // Flushed on trap or MRET & branch_miss
  // rs1Fwd / rs2Fwd carry the forwarded operands into MA for CSR RMW and
  // store data respectively.
  // ===========================================================================
    assign flush_ex_ma = branch_miss || trap_en || mret_en;
    always_ff @(posedge clk) begin
      if (!resetn || flush_ex_ma) begin
        ex_ma_aluResult   <= 32'd0;
        ex_ma_dmemAddr    <= 32'd0;
        ex_ma_rs1Fwd      <= 32'd0;
        ex_ma_rs2Fwd      <= 32'd0;
        ex_ma_rdIndex     <= 5'd0;
        ex_ma_regWrite    <= 1'b0;
        ex_ma_wbSel       <= 2'b00;
        ex_ma_memRead     <= 1'b0;
        ex_ma_memWrite    <= 1'b0;
        ex_ma_memWidth    <= `WIDTH_W;
        ex_ma_csrEnable   <= 1'b0;
        ex_ma_csrOp       <= 2'b00;
        ex_ma_csrUseImm   <= 1'b0;
        ex_ma_csrIndex    <= 12'h000;
        ex_ma_isECALL     <= 1'b0;
        ex_ma_isEBREAK    <= 1'b0;
        ex_ma_isMRET      <= 1'b0;
        ex_ma_isIllegal   <= 1'b0;
        ex_ma_pc          <= 32'd0;
        ex_ma_pc2         <= 32'd0;
        ex_ma_pc4         <= 32'd0;
        ex_ma_isComp      <= 1'b0;
        ex_ma_instr       <= `NOP_INSTR;
        ex_ma_linkAddr    <= 32'd0;
        ex_ma_rdNonZero   <= 1'b0;
        ex_ma_csrWrGuard  <= 1'b0;
        ex_ma_predTaken   <= 1'b0;
        ex_ma_predpc      <= 32'd0;
        ex_ma_phtIdx      <= '0;
        ex_ma_phtOld      <= 2'b01;
        ex_ma_targetAddr  <= 32'd0;
        ex_ma_branchTaken <= 1'b0;
        ex_ma_isBranch    <= 1'b0;
        ex_ma_isJump      <= 1'b0;
      end else begin
        ex_ma_aluResult   <= alu_result;
        ex_ma_dmemAddr    <= ex_dmem_addr;
        ex_ma_rs1Fwd      <= fwd_rs1Value;
        ex_ma_rs2Fwd      <= fwd_rs2Value;
        ex_ma_rdIndex     <= id_ex_rdIndex;
        ex_ma_regWrite    <= id_ex_regWrite;
        ex_ma_wbSel       <= id_ex_wbSel;
        ex_ma_memRead     <= id_ex_memRead;
        ex_ma_memWrite    <= id_ex_memWrite;
        ex_ma_memWidth    <= id_ex_memWidth;
        ex_ma_csrEnable   <= id_ex_csrEnable;
        ex_ma_csrOp       <= id_ex_csrOp;
        ex_ma_csrUseImm   <= id_ex_csrUseImm;
        ex_ma_csrIndex    <= id_ex_csrIndex;
        ex_ma_isECALL     <= id_ex_isECALL;
        ex_ma_isEBREAK    <= id_ex_isEBREAK;
        ex_ma_isMRET      <= id_ex_isMRET;
        ex_ma_isIllegal   <= id_ex_isIllegal;
        ex_ma_pc          <= id_ex_pc;
        ex_ma_pc2         <= id_ex_pc2;
        ex_ma_pc4         <= id_ex_pc4;
        ex_ma_isComp      <= id_ex_isComp;
        ex_ma_instr       <= id_ex_instr;
        ex_ma_linkAddr    <= ex_linkAddr;
        ex_ma_rdNonZero   <= (id_ex_rdIndex != 5'd0);
        ex_ma_csrWrGuard  <= ex_csrWrGuard;
        ex_ma_predTaken   <= id_ex_predTaken;
        ex_ma_predpc      <= id_ex_predpc;
        ex_ma_phtIdx      <= id_ex_phtIdx;
        ex_ma_phtOld      <= id_ex_phtOld;
        ex_ma_targetAddr  <= ex_targetAddr;
        ex_ma_branchTaken <= (id_ex_isBranch && branch_taken) || id_ex_isJump;
        ex_ma_isBranch    <= id_ex_isBranch;
        ex_ma_isJump      <= id_ex_isJump;
      end
    end
  // ===========================================================================
  // EX/MA PIPELINE REGISTER
  // ===========================================================================


  // ===========================================================================
  // MA STAGE  ──  Trap detection, CSR access, DMEM access, load extension
  //               branch_miss detection, TruePC computation, PHT/BTB update
  // ===========================================================================

    // ── Trap unit ────────────────────────────────────────────────────────────
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
      .trap_en       (trap_en),
      .trap_mepc     (trap_mepc),
      .trap_mcause   (trap_mcause),
      .trap_mtval    (trap_mtval),
      .mret_en       (mret_en)
    );
    
    // ── Branch misprediction detection ───────────────────────────────────────
    // branch_miss fires when a branch or jump resolved to a different outcome
    // than predicted.
    // On branch_miss: flush 3 stages, redirect to truepc.
    assign branch_miss = !trap_en && !mret_en && (ex_ma_isBranch || ex_ma_isJump) &&
      (
        (ex_ma_branchTaken != ex_ma_predTaken) ||
        (ex_ma_branchTaken && (ex_ma_targetAddr != ex_ma_predpc))
      );

    // ── TruePC and BelowPC computation ───────────────────────────────────────
    // BelowPC = address of the instruction immediately AFTER the branch.
    //   Compressed branch: BelowPC = branch_pc + 2  (= ex_ma_pc2)
    //   32-bit branch:     BelowPC = branch_pc + 4  (= ex_ma_pc4)
    // TruePC: if the branch WAS actually taken, go to the real target.
    //         if NOT taken, go to the instruction after the branch.
    assign below_pc  = ex_ma_isComp      ? ex_ma_pc2        : ex_ma_pc4;
    assign truepc    = ex_ma_branchTaken ? ex_ma_targetAddr : below_pc;

    // ── PHT write-back: saturating counter update ────────────────────────────
    // Only conditional branches update the PHT (not unconditional jumps).
    // Uses the stored PHT index (ex_ma_phtIdx) and old counter (ex_ma_phtOld)
    // that were captured when the instruction was in IF.
    logic [1:0] pht_wdata;
    always_comb begin
      pht_wdata = ex_ma_phtOld;  // default: no update
      if (ex_ma_isBranch) begin
        if (ex_ma_branchTaken)
          pht_wdata = (ex_ma_phtOld == 2'b11) ? 2'b11 : ex_ma_phtOld + 2'b01;
        else
          pht_wdata = (ex_ma_phtOld == 2'b00) ? 2'b00 : ex_ma_phtOld - 2'b01;
      end
    end
    always_ff @(posedge clk) begin
      if (ex_ma_isBranch) pht[ex_ma_phtIdx] <= pht_wdata;
    end

    // ── BTB write-back: update target on any taken branch or jump ────────────
    // Index = branch instruction PC [BTB_IDX_W:1] (halfword-addressed).
    // After this write, subsequent encounters of the same branch PC will have
    // the correct target in BTB (and PHT will predict taken after training).
    always_ff @(posedge clk) begin
      if ((ex_ma_isBranch && ex_ma_branchTaken) || ex_ma_isJump)
        btb[ex_ma_pc[BTB_IDX_W:1]] <= ex_ma_targetAddr;
    end

    // ── CSR Read-Modify-Write ────────────────────────────────────────────────
    // csr_rdDataRaw is the raw flip-flop value, free of write-before-read
    // forwarding, so csr_wrData does not feed back into csr_rdDataRaw.
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
    assign csr_wrEnable = ex_ma_csrEnable && ex_ma_csrWrGuard;

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
      unique case ({ex_ma_memWidth, ex_ma_dmemAddr[1:0]})
        // ── LB  (signed byte) ─────────────────────────────────────────────────
        {`WIDTH_B,  2'b00}: load_data = {{24{dmem_rdata[7]}},  dmem_rdata[7:0]};
        {`WIDTH_B,  2'b01}: load_data = {{24{dmem_rdata[15]}}, dmem_rdata[15:8]};
        {`WIDTH_B,  2'b10}: load_data = {{24{dmem_rdata[23]}}, dmem_rdata[23:16]};
        {`WIDTH_B,  2'b11}: load_data = {{24{dmem_rdata[31]}}, dmem_rdata[31:24]};
        // ── LH  (signed halfword) ─────────────────────────────────────────────
        {`WIDTH_H,  2'b00}: load_data = {{16{dmem_rdata[15]}}, dmem_rdata[15:0]};
        {`WIDTH_H,  2'b10}: load_data = {{16{dmem_rdata[31]}}, dmem_rdata[31:16]};
        // ── LW  (word) ────────────────────────────────────────────────────────
        {`WIDTH_W,  2'b00}: load_data = dmem_rdata;
        // ── LBU (unsigned byte) ───────────────────────────────────────────────
        {`WIDTH_BU, 2'b00}: load_data = {24'd0, dmem_rdata[7:0]};
        {`WIDTH_BU, 2'b01}: load_data = {24'd0, dmem_rdata[15:8]};
        {`WIDTH_BU, 2'b10}: load_data = {24'd0, dmem_rdata[23:16]};
        {`WIDTH_BU, 2'b11}: load_data = {24'd0, dmem_rdata[31:24]};
        // ── LHU (unsigned halfword) ───────────────────────────────────────────
        {`WIDTH_HU, 2'b00}: load_data = {16'd0, dmem_rdata[15:0]};
        {`WIDTH_HU, 2'b10}: load_data = {16'd0, dmem_rdata[31:16]};
        // ── safe default (covers misaligned cases) ────────────────────────────
        default:            load_data = dmem_rdata;
      endcase
    end

    // ── DMEM store: byte enables and write-data lane placement ────────────────
    // The byte-enable mask activates only the lanes being written.
    // Write data is placed in the correct lane; unused lanes hold zero.
    always_comb begin
      unique case ({ex_ma_memWidth, ex_ma_dmemAddr[1:0]})
        // ── SB (byte) ─────────────────────────────────────────────────────────
        {`WIDTH_B, 2'b00}: begin store_be = 4'b0001; store_data = {24'd0, ex_ma_rs2Fwd[7:0]};        end
        {`WIDTH_B, 2'b01}: begin store_be = 4'b0010; store_data = {16'd0, ex_ma_rs2Fwd[7:0],  8'd0}; end
        {`WIDTH_B, 2'b10}: begin store_be = 4'b0100; store_data = {8'd0,  ex_ma_rs2Fwd[7:0], 16'd0}; end
        {`WIDTH_B, 2'b11}: begin store_be = 4'b1000; store_data = {       ex_ma_rs2Fwd[7:0], 24'd0}; end
        // ── SH (halfword) ─────────────────────────────────────────────────────
        {`WIDTH_H, 2'b00}: begin store_be = 4'b0011; store_data = {16'd0, ex_ma_rs2Fwd[15:0]};       end
        {`WIDTH_H, 2'b10}: begin store_be = 4'b1100; store_data = {ex_ma_rs2Fwd[15:0], 16'd0};       end
        // ── SW (word) ─────────────────────────────────────────────────────────
        {`WIDTH_W, 2'b00}: begin store_be = 4'b1111; store_data = ex_ma_rs2Fwd;                       end
        // ── safe default (misaligned stores - trapped before reaching here) ───
        default:           begin store_be = 4'b1111; store_data = ex_ma_rs2Fwd;                       end
      endcase
    end

    // ── DMEM port assignments ─────────────────────────────────────────────────
    // dmem_we is gated off when a trap fires: the trapping instruction must not
    // commit a store to memory (precise exception requirement).
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
        ma_wb_rdNonZero  <= 1'b0;
      end else begin
        ma_wb_aluResult  <= ex_ma_aluResult;
        ma_wb_loadData   <= load_data;
        ma_wb_csrOldData <= csr_rdDataRaw;
        ma_wb_linkAddr   <= ex_ma_linkAddr;
        ma_wb_rdIndex    <= ex_ma_rdIndex;
        ma_wb_regWrite   <= ex_ma_regWrite && !trap_en;
        ma_wb_wbSel      <= ex_ma_wbSel;
        ma_wb_rdNonZero  <= ex_ma_rdNonZero;
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
  //   • regfile.wr_data  - commits the result to the architectural register file
  //   • fwd_rs1Value / fwd_rs2Value via the 2'b01 path in the EX forwarding muxes
  // No additional logic is required in this stage.
  // ===========================================================================

endmodule

