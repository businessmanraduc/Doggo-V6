`include "isa.vh"
// =============================================================================
// PHANTOM-32  ──  6-Stage Pipelined CPU  (RV32IC)
// =============================================================================
//
//  ┌───────┐  ┌────────┐  ┌───────┐  ┌────────┐  ┌───────┐  ┌────────┐
//  │ PreIF │─▶│   IF   │─▶│  ID   │─▶│   EX   │─▶│  MA   │─▶│   WB   │
//  │  (I)  │  │  (II)  │  │ (III) │  │  (IV)  │  │  (V)  │  │  (VI)  │
//  └───────┘  └────────┘  └───────┘  └────────┘  └───────┘  └────────┘
//
//  Hazards handled:
//
//  1. DATA HAZARD — full forwarding
//     EX/MA result (StageV_)  forwarded to EX operand muxes  (1-cycle-old)
//     MA/WB result (StageVI_) forwarded to EX operand muxes  (2-cycle-old)
//     CSR read result forwarded combinationally from MA to EX (isCSR path)
//     WB write-before-read forwarding is handled inside regfile.v itself
//
//  2. LOAD-USE HAZARD — 1 stall cycle
//     LW immediately followed by a dependent instruction: stall PC + StageII_ +
//     StageIII_ for 1 cycle, bubble inserted into EX.  After stall, the loaded
//     value arrives via the MA/WB (StageVI_) forwarding path.
//
//  3. CONTROL HAZARD — always-not-taken predictor, 2-cycle flush penalty
//     Branch/jump resolved in EX.  If taken: flush StageIII_ and StageIV_
//     (2 bubbles), redirect PC to TruePC.  Synchronous BRAM requires a
//     flushDelayed register to kill the in-flight wrong fetch in cycle N+1.
//
//  4. TRAP / MRET — detected in EX, committed in MA
//     ECALL, EBREAK, illegal instruction, load/store misalignment: detected
//     in EX, pipeline flushed to mtvec immediately.  StageV_isTrap drives
//     csr_regfile to save mepc/mcause/mstatus atomically in MA.
//     MRET: detected in EX, pipeline flushed to mepc.  StageV_isMRET drives
//     csr_regfile to restore mstatus in MA.
//
//  Memory interfaces use synchronous BRAM reads (1-cycle latency).
//  The dual-port 16-bit IMEM approach follows RVCoreP-32IC (arXiv:2011.11246).
// =============================================================================
module cpu #(
  parameter IMEM_ADDR_W = 12,   // halfword address width  (2^12 = 4096 × 16-bit = 8 KB)
  parameter DMEM_ADDR_W = 10    // word address width      (2^10 = 1024 × 32-bit = 4 KB)
) (
  input  wire        clk,
  input  wire        resetn,                  // active-low synchronous reset

  // ── Instruction memory (synchronous read, dual-port, 16-bit wide) ──────────
  // Port A: halfword at PC.  Port B: halfword at PC+2.
  // Both ports are driven every cycle so the full 32-bit window {B,A} always
  // covers any instruction regardless of 32-bit/16-bit or boundary alignment.
  output wire [IMEM_ADDR_W-1:0] imem_addr_a,  // halfword address  = PC[IMEM_ADDR_W:1]
  output wire [IMEM_ADDR_W-1:0] imem_addr_b,  // halfword address  = PC[IMEM_ADDR_W:1] + 1
  input  wire [15:0]            imem_data_a,  // halfword at addr_a (1-cycle latency)
  input  wire [15:0]            imem_data_b,  // halfword at addr_b (1-cycle latency)

  // ── Data memory (combinational read, synchronous byte-enable write) ────────
  output wire [DMEM_ADDR_W-1:0] dmem_addr,    // word address = effective_addr[N:2]
  output wire [31:0]            dmem_wdata,   // write data (byte-replicated for SB/SH)
  output wire [3:0]             dmem_we,      // byte enables  (0001/0011/1111 for SB/SH/SW)
  input  wire [31:0]            dmem_rdata,   // read data (combinational)

  output reg                    halted        // asserted when HALT retires in WB
);


  // =============================================================================
  // ─── PROGRAM COUNTER  (PC and PC_2) ──────────────────────────────────────────
  // =============================================================================
  // Two registered values maintained in sync at all times:
  //   PC   → drives imem_addr_a  (halfword at current fetch address)
  //   PC_2 → drives imem_addr_b  (halfword at PC+2, always = PC+2)
  //
  // PC advancement uses IF_isCompressed — the combinational output of decoder_if
  // based on the BRAM data currently arriving in IF.
  //
  // Update priority (highest to lowest):
  //   1. Reset          → PC=RESET_VECTOR, PC_2=RESET_VECTOR+2
  //   2. Halted         → freeze both
  //   3. maFlush        → PC=maTruePC, PC_2=maTruePC+2
  //   4. exFlush        → PC=TruePC,   PC_2=TruePC+2
  //   5. stall OR
  //      flushDelayed OR
  //      maFlushDelayed → hold both  (flushDelayed must hold PC so the correct
  //                                   TruePC address settles into the BRAM before
  //                                   we advance; otherwise IF_isCompressed would
  //                                   be stale and PC would advance incorrectly)
  //   6. Normal         → PC+=2 (compressed) or PC+=4 (32-bit), PC_2 tracks +2
  // =============================================================================
    reg [31:0] PC;
    reg [31:0] PC_2;

    always @(posedge clk) begin
      if (!resetn) begin
        PC     <= `RESET_VECTOR;
        PC_2   <= `RESET_VECTOR + 32'd2;
      end else if (halted) begin
        // ── CPU halted: freeze PC ────────────────────────────────────────────
      end else begin
        if (maFlush) begin
          // ── Misalignment trap from MA: redirect to mtvec ───────────────────
          PC   <= maTruePC;
          PC_2 <= maTruePC + 32'd2;
        end else if (exFlush) begin
          // ── Branch / jump / EX trap: redirect to TruePC ────────────────────
          PC   <= TruePC;
          PC_2 <= TruePC_2;
        end else if (stall || flushDelayed || maFlushDelayed) begin
          // ── Hold: load-use stall, or delayed flush letting correct BRAM data
          // settle (PC already points to TruePC from the exFlush last cycle)
          // No assignment = registers hold their current value
        end else begin
          // ── Normal advance: step by 2 or 4 based on instruction size ───────
          if (IF_isCompressed) begin
            PC   <= PC   + 32'd2;
            PC_2 <= PC_2 + 32'd2;
          end else begin
            PC   <= PC   + 32'd4;
            PC_2 <= PC_2 + 32'd4;
          end
        end
      end
    end

    // ── BRAM address outputs: combinational, driven from registered PC / PC_2
    assign imem_addr_a = PC  [IMEM_ADDR_W:1];
    assign imem_addr_b = PC_2[IMEM_ADDR_W:1];
  // ===========================================================================
  // ─── PROGRAM COUNTER ───────────────────────────────────────────────────────
  // ===========================================================================


  // =============================================================================
  // ─── STAGE I → II PIPELINE REGISTER  (PreIF → IF) ────────────────────────────
  // =============================================================================
  // StageII_PC records the PC that was used to address the BRAM this cycle.
  // When the BRAM data arrives in IF (next cycle), StageII_PC tells the IF stage
  // which byte address that data corresponds to.
  // =============================================================================
    reg [31:0] StageII_PC;

    always @(posedge clk) begin
      if (!resetn) begin
        StageII_PC <= 32'h0;
      end else if (halted) begin
        // ── CPU halted: freeze ─────────────────────────────────────────────────
      end else if (maFlush) begin
        StageII_PC <= maTruePC;
      end else if (exFlush) begin
        StageII_PC <= TruePC;
      end else if (!stall && !flushDelayed && !maFlushDelayed) begin
        StageII_PC <= PC;
      end
      // stall: hold
    end
  // =============================================================================
  // ─── STAGE I → II PIPELINE REGISTER  (PreIF → IF) ────────────────────────────
  // =============================================================================


  // =============================================================================
  // ─── STAGE II: INSTRUCTION FETCH (IF) ────────────────────────────────────────
  // =============================================================================
  // BRAM data for the address driven last cycle is now available.
  // Form the 32-bit window, detect instruction size, run ParallelDecoderIF.
  // =============================================================================

    // ── 32-bit window from dual-port BRAM ─────────────────────────────────────
    // imem_data_a = halfword at StageII_PC   (Port A)
    // imem_data_b = halfword at StageII_PC+2 (Port B)
    // Together they always cover the full instruction regardless of alignment.
    wire [31:0] IF_instrWindow = {imem_data_b, imem_data_a};

    // ── ParallelDecoderIF: extract register indices and load flag ──────────────
    wire        IF_isCompressed;
    wire [4:0]  IF_rd_index;
    wire [4:0]  IF_rs1_index;
    wire [4:0]  IF_rs2_index;
    wire        IF_isLoad;

    decoder_if u_decoder_if (
      .instr_lo     (imem_data_a),
      .instr_hi     (imem_data_b),
      .is_compressed(IF_isCompressed),
      .rd_index     (IF_rd_index),
      .rs1_index    (IF_rs1_index),
      .rs2_index    (IF_rs2_index),
      .is_load      (IF_isLoad)
    );

    // ── StageIII_ pipeline registers (IF → ID) ────────────────────────────────
    reg [31:0] StageIII_PC;
    reg [31:0] StageIII_Instr;           // raw 32-bit window {imem_b, imem_a}
    reg        StageIII_isCompressed;    // 1 = 16-bit C instruction
    reg [4:0]  StageIII_rd_index;        // from ParallelDecoderIF
    reg [4:0]  StageIII_rs1_index;       // from ParallelDecoderIF
    reg [4:0]  StageIII_rs2_index;       // from ParallelDecoderIF
    reg        StageIII_isLoad;          // from ParallelDecoderIF

    always @(posedge clk) begin
      if (!resetn) begin
        StageIII_PC           <= 32'h0;
        StageIII_Instr        <= `NOP_INSTR;
        StageIII_isCompressed <= 1'b0;
        StageIII_rd_index     <= 5'd0;
        StageIII_rs1_index    <= 5'd0;
        StageIII_rs2_index    <= 5'd0;
        StageIII_isLoad       <= 1'b0;
      end else if (halted) begin
        // ── CPU halted: freeze ─────────────────────────────────────────────────
      end else if (exFlush || flushDelayed || maFlush || maFlushDelayed) begin
        // ── Flush: discard incorrectly fetched instruction → NOP bubble ────────
        // exFlush + flushDelayed together kill 2 cycles of wrong fetches.
        // maFlush + maFlushDelayed do the same for MA-detected traps.
        StageIII_PC           <= StageII_PC;
        StageIII_Instr        <= `NOP_INSTR;
        StageIII_isCompressed <= 1'b0;
        StageIII_rd_index     <= 5'd0;
        StageIII_rs1_index    <= 5'd0;
        StageIII_rs2_index    <= 5'd0;
        StageIII_isLoad       <= 1'b0;
      end else if (!stall) begin
        // ── Normal advance ────────────────────────────────────────────────────
        StageIII_PC           <= StageII_PC;
        StageIII_Instr        <= IF_instrWindow;
        StageIII_isCompressed <= IF_isCompressed;
        StageIII_rd_index     <= IF_rd_index;
        StageIII_rs1_index    <= IF_rs1_index;
        StageIII_rs2_index    <= IF_rs2_index;
        StageIII_isLoad       <= IF_isLoad;
      end
      // stall: hold all StageIII_ registers
    end
  // =============================================================================
  // ─── STAGE II: INSTRUCTION FETCH (IF) ────────────────────────────────────────
  // =============================================================================


  // =============================================================================
  // ─── STAGE III: INSTRUCTION DECODE (ID) ──────────────────────────────────────
  // =============================================================================
  // Full parallel decode of the instruction in StageIII_Instr.
  // Read the register file using indices from decoder_if (already in StageIII_).
  // Generate the immediate and all control signals via decoder_id.
  // Perform load-use hazard detection.
  // =============================================================================

    // ── Register file ─────────────────────────────────────────────────────────
    // Read ports are driven by the indices that decoder_if extracted in IF.
    // Write port is driven by WB (StageVI_).  The write-before-read forwarding
    // from WB to ID is handled inside regfile.v — no extra logic needed here.
    wire [31:0] ID_rs1_data;
    wire [31:0] ID_rs2_data;

    regfile u_regfile (
      .clk       (clk),
      .rd_index_a(StageIII_rs1_index),
      .rd_data_a (ID_rs1_data),
      .rd_index_b(StageIII_rs2_index),
      .rd_data_b (ID_rs2_data),
      .wr_index  (StageVI_rd_index),
      .wr_data   (StageVI_writeData),
      .wr_en     (StageVI_writeEnable)
    );

    // ── ParallelDecoderID: full decode, both 32-bit and 16-bit paths ──────────
    wire [31:0] ID_immediate;
    wire [31:0] ID_immediate2;
    wire        ID_destRegWrite, ID_memRead,   ID_memWrite,  ID_isBranch, ID_isJump;
    wire        ID_ALUBSel,      ID_memToReg;
    wire [3:0]  ID_ALUOpcode;
    wire [2:0]  ID_branchCond;
    wire        ID_isJALR,       ID_isLink;
    wire [2:0]  ID_loadWidth;
    wire [1:0]  ID_storeWidth;
    wire        ID_isCSR;
    wire [11:0] ID_CSRAddr;
    wire [1:0]  ID_CSROp;
    wire        ID_CSRUseImm,    ID_isAUIPC;
    wire        ID_isECALL,      ID_isEBREAK,  ID_isMRET;
    wire        ID_isIllegal,    ID_HALT;

    decoder_id u_decoder_id (
      .instrWord        (StageIII_Instr),
      .is_compressed    (StageIII_isCompressed),
      .immediate        (ID_immediate),
      .immediate2       (ID_immediate2),
      .CTRL_destRegWrite(ID_destRegWrite),
      .CTRL_memRead     (ID_memRead),
      .CTRL_memWrite    (ID_memWrite),
      .CTRL_isBranch    (ID_isBranch),
      .CTRL_isJump      (ID_isJump),
      .CTRL_ALUBSel     (ID_ALUBSel),
      .CTRL_memToReg    (ID_memToReg),
      .CTRL_ALUOpcode   (ID_ALUOpcode),
      .CTRL_branchCond  (ID_branchCond),
      .CTRL_isJALR      (ID_isJALR),
      .CTRL_isLink      (ID_isLink),
      .CTRL_loadWidth   (ID_loadWidth),
      .CTRL_storeWidth  (ID_storeWidth),
      .CTRL_isCSR       (ID_isCSR),
      .CTRL_CSRAddr     (ID_CSRAddr),
      .CTRL_CSROp       (ID_CSROp),
      .CTRL_CSRUseImm   (ID_CSRUseImm),
      .CTRL_isAUIPC     (ID_isAUIPC),
      .CTRL_isECALL     (ID_isECALL),
      .CTRL_isEBREAK    (ID_isEBREAK),
      .CTRL_isMRET      (ID_isMRET),
      .CTRL_isIllegal   (ID_isIllegal),
      .CTRL_HALT        (ID_HALT)
    );

    // ── Load-use hazard detection ──────────────────────────────────────────────
    // Triggered when the instruction currently in EX (StageIV_) is a load AND
    // the instruction currently in ID (StageIII_) reads the register being loaded.
    // Effect: stall PC + StageII_ + StageIII_ for 1 cycle, bubble into EX.
    // After the stall, the loaded value arrives via MA/WB (StageVI_) forwarding.
    wire stall = StageIV_memRead
              && (StageIV_rd_index != 5'd0)
              && (StageIV_rd_index == StageIII_rs1_index
              ||  StageIV_rd_index == StageIII_rs2_index);

    // ── StageIV_ pipeline registers (ID → EX) ─────────────────────────────────
    // Declared before EX so the forwarding unit (in EX) can reference them.
    reg [31:0] StageIV_PC;
    reg        StageIV_isCompressed;
    reg [4:0]  StageIV_rd_index;
    reg [4:0]  StageIV_rs1_index;
    reg [4:0]  StageIV_rs2_index;
    reg [31:0] StageIV_rs1_data;
    reg [31:0] StageIV_rs2_data;
    reg [31:0] StageIV_immediate;
    reg [31:0] StageIV_immediate2;
    reg        StageIV_destRegWrite;
    reg        StageIV_memRead;
    reg        StageIV_memWrite;
    reg        StageIV_isBranch;
    reg        StageIV_isJump;
    reg        StageIV_ALUBSel;
    reg        StageIV_memToReg;
    reg [3:0]  StageIV_ALUOpcode;
    reg [2:0]  StageIV_branchCond;
    reg        StageIV_isJALR;
    reg        StageIV_isLink;
    reg [2:0]  StageIV_loadWidth;
    reg [1:0]  StageIV_storeWidth;
    reg        StageIV_isCSR;
    reg [11:0] StageIV_CSRAddr;
    reg [1:0]  StageIV_CSROp;
    reg        StageIV_CSRUseImm;
    reg        StageIV_isAUIPC;
    reg        StageIV_isECALL;
    reg        StageIV_isEBREAK;
    reg        StageIV_isMRET;
    reg        StageIV_isIllegal;
    reg        StageIV_HALT;

    always @(posedge clk) begin
      if (!resetn) begin
        StageIV_PC           <= 32'h0;  StageIV_isCompressed <= 1'b0;
        StageIV_rd_index     <= 5'd0;
        StageIV_rs1_index    <= 5'd0;   StageIV_rs2_index    <= 5'd0;
        StageIV_rs1_data     <= 32'h0;  StageIV_rs2_data     <= 32'h0;
        StageIV_immediate    <= 32'h0;  StageIV_immediate2   <= 32'h0;
        StageIV_destRegWrite <= 1'b0;   StageIV_memRead      <= 1'b0;
        StageIV_memWrite     <= 1'b0;   StageIV_isBranch     <= 1'b0;
        StageIV_isJump       <= 1'b0;   StageIV_ALUBSel      <= 1'b0;
        StageIV_memToReg     <= 1'b0;   StageIV_ALUOpcode    <= `ALU_ADD;
        StageIV_branchCond   <= 3'd0;   StageIV_isJALR       <= 1'b0;
        StageIV_isLink       <= 1'b0;   StageIV_loadWidth    <= 3'd0;
        StageIV_storeWidth   <= 2'd0;   StageIV_isCSR        <= 1'b0;
        StageIV_CSRAddr      <= 12'd0;  StageIV_CSROp        <= 2'd0;
        StageIV_CSRUseImm    <= 1'b0;   StageIV_isAUIPC      <= 1'b0;
        StageIV_isECALL      <= 1'b0;   StageIV_isEBREAK     <= 1'b0;
        StageIV_isMRET       <= 1'b0;   StageIV_isIllegal    <= 1'b0;
        StageIV_HALT         <= 1'b0;
      end else if (halted) begin
        // ── CPU halted: freeze ─────────────────────────────────────────────────
      end else if (exFlush || stall || maFlush) begin
        // ── Flush or stall: insert NOP bubble into EX ─────────────────────────
        // On flush: the instruction in ID was fetched from the wrong path.
        // On stall: insert a bubble so EX does nothing while ID re-decodes.
        // On maFlush: MA detected a misalignment; kill what is in EX.
        StageIV_PC           <= StageIII_PC;  StageIV_isCompressed <= 1'b0;
        StageIV_rd_index     <= 5'd0;
        StageIV_rs1_index    <= 5'd0;         StageIV_rs2_index    <= 5'd0;
        StageIV_rs1_data     <= 32'h0;        StageIV_rs2_data     <= 32'h0;
        StageIV_immediate    <= 32'h0;        StageIV_immediate2   <= 32'h0;
        StageIV_destRegWrite <= 1'b0;         StageIV_memRead      <= 1'b0;
        StageIV_memWrite     <= 1'b0;         StageIV_isBranch     <= 1'b0;
        StageIV_isJump       <= 1'b0;         StageIV_ALUBSel      <= 1'b0;
        StageIV_memToReg     <= 1'b0;         StageIV_ALUOpcode    <= `ALU_ADD;
        StageIV_branchCond   <= 3'd0;         StageIV_isJALR       <= 1'b0;
        StageIV_isLink       <= 1'b0;         StageIV_loadWidth    <= 3'd0;
        StageIV_storeWidth   <= 2'd0;         StageIV_isCSR        <= 1'b0;
        StageIV_CSRAddr      <= 12'd0;        StageIV_CSROp        <= 2'd0;
        StageIV_CSRUseImm    <= 1'b0;         StageIV_isAUIPC      <= 1'b0;
        StageIV_isECALL      <= 1'b0;         StageIV_isEBREAK     <= 1'b0;
        StageIV_isMRET       <= 1'b0;         StageIV_isIllegal    <= 1'b0;
        StageIV_HALT         <= 1'b0;
      end else begin
        // ── Normal advance ─────────────────────────────────────────────────────
        StageIV_PC           <= StageIII_PC;          StageIV_isCompressed <= StageIII_isCompressed;
        StageIV_rd_index     <= StageIII_rd_index;
        StageIV_rs1_index    <= StageIII_rs1_index;   StageIV_rs2_index    <= StageIII_rs2_index;
        StageIV_rs1_data     <= ID_rs1_data;          StageIV_rs2_data     <= ID_rs2_data;
        StageIV_immediate    <= ID_immediate;         StageIV_immediate2   <= ID_immediate2;
        StageIV_destRegWrite <= ID_destRegWrite;      StageIV_memRead      <= ID_memRead;
        StageIV_memWrite     <= ID_memWrite;          StageIV_isBranch     <= ID_isBranch;
        StageIV_isJump       <= ID_isJump;            StageIV_ALUBSel      <= ID_ALUBSel;
        StageIV_memToReg     <= ID_memToReg;          StageIV_ALUOpcode    <= ID_ALUOpcode;
        StageIV_branchCond   <= ID_branchCond;        StageIV_isJALR       <= ID_isJALR;
        StageIV_isLink       <= ID_isLink;            StageIV_loadWidth    <= ID_loadWidth;
        StageIV_storeWidth   <= ID_storeWidth;        StageIV_isCSR        <= ID_isCSR;
        StageIV_CSRAddr      <= ID_CSRAddr;           StageIV_CSROp        <= ID_CSROp;
        StageIV_CSRUseImm    <= ID_CSRUseImm;         StageIV_isAUIPC      <= ID_isAUIPC;
        StageIV_isECALL      <= ID_isECALL;           StageIV_isEBREAK     <= ID_isEBREAK;
        StageIV_isMRET       <= ID_isMRET;            StageIV_isIllegal    <= ID_isIllegal;
        StageIV_HALT         <= ID_HALT;
      end
    end
  // =============================================================================
  // ─── STAGE III: INSTRUCTION DECODE (ID) ──────────────────────────────────────
  // =============================================================================


  // =============================================================================
  // ─── STAGE IV: EXECUTE (EX) ──────────────────────────────────────────────────
  // =============================================================================
  // Forwarding → operand selection → ALU → branch comparison → TruePC →
  // trap / MRET detection → flush signal.
  //
  // StageV_ and StageVI_ pipeline registers are declared here (forward
  // declaration) because the forwarding unit in EX needs to read them.
  // =============================================================================

    // ── Forward declaration of StageV_ (EX → MA) ────────────────────────────
    // Needed by: forwarding unit (to read EX/MA result), stall check (memRead).
    reg [31:0] StageV_PC;
    reg [4:0]  StageV_rd_index;
    reg        StageV_destRegWrite;
    reg [31:0] StageV_ALUResult;      // ALU output for this instruction
    reg [31:0] StageV_rs2_data;       // forwarded rs2 value (store data)
    reg        StageV_memRead;
    reg        StageV_memWrite;
    reg        StageV_memToReg;
    reg        StageV_isLink;
    reg [31:0] StageV_LinkValue;      // PC+2 or PC+4 (return address for JAL/JALR)
    reg [2:0]  StageV_loadWidth;
    reg [1:0]  StageV_storeWidth;
    reg        StageV_isCSR;
    reg [11:0] StageV_CSRAddr;
    reg [1:0]  StageV_CSROp;
    reg [31:0] StageV_CSR_wdata;      // rs1-forwarded or zimm value for CSR write
    reg        StageV_isTrap;         // EX-detected trap committed in MA
    reg [3:0]  StageV_trapCause;      // mcause exception code
    reg [31:0] StageV_trapPC;         // PC of the trapping instruction → mepc
    reg [31:0] StageV_trapVal;        // faulting address or 0
    reg        StageV_isMRET;
    reg        StageV_HALT;

    // ── Forward declaration of StageVI_ (MA → WB) ────────────────────────────
    // Needed by: forwarding unit (MA/WB result), WB write enable.
    reg [4:0]  StageVI_rd_index;
    reg        StageVI_destRegWrite;
    reg [31:0] StageVI_ALUResult;     // ALU result OR old CSR value placed here by MA
    reg [31:0] StageVI_loadData;      // sign/zero-extended load result
    reg        StageVI_memToReg;
    reg        StageVI_isLink;
    reg [31:0] StageVI_LinkValue;
    reg        StageVI_HALT;

    // ── WB write data and enable ───────────────────────────────────────────────
    // Declared here because they are used by both the forwarding mux (EX)
    // and the register file write port (WB section below).
    wire [31:0] StageVI_writeData =
      StageVI_isLink   ? StageVI_LinkValue  :
      StageVI_memToReg ? StageVI_loadData   :
      StageVI_ALUResult;

    wire StageVI_writeEnable = StageVI_destRegWrite
                             && (StageVI_rd_index != 5'd0)
                             && !halted;

    // ── CSR module outputs (needed by forwarding unit and MA stage) ───────────
    // Declared here (as wires) because the forwarding mux needs csr_rd_data
    // combinationally, and the CSR module is instantiated in the MA section.
    wire [31:0] csr_rd_data;
    wire [31:0] csr_out_mstatus;
    wire [31:0] csr_out_mtvec;
    wire [31:0] csr_out_mepc;

    // ── Forwarding unit ────────────────────────────────────────────────────────
    // forward_x encoding:
    //   2'b00 → no forward: use value from StageIV_ (register file read in ID)
    //   2'b01 → MA/WB forward: use StageVI_writeData  (2-cycle-old result)
    //   2'b10 → EX/MA forward: use StageV_fwdValue    (1-cycle-old result)
    // StageV_ (EX/MA) takes priority over StageVI_ (MA/WB) when both match.
    wire [1:0] forward_a =
      (StageV_destRegWrite  && StageV_rd_index  != 5'd0 && StageV_rd_index  == StageIV_rs1_index) ? 2'b10 :
      (StageVI_destRegWrite && StageVI_rd_index != 5'd0 && StageVI_rd_index == StageIV_rs1_index) ? 2'b01 :
      2'b00;

    wire [1:0] forward_b =
      (StageV_destRegWrite  && StageV_rd_index  != 5'd0 && StageV_rd_index  == StageIV_rs2_index) ? 2'b10 :
      (StageVI_destRegWrite && StageVI_rd_index != 5'd0 && StageVI_rd_index == StageIV_rs2_index) ? 2'b01 :
      2'b00;

    // ── EX/MA forwarded value ─────────────────────────────────────────────────
    // For CSR instructions: the result written to rd is the OLD CSR value, which
    // is available combinationally from csr_rd_data when the CSR instruction is
    // in MA (StageV_isCSR=1).  We use this instead of the irrelevant ALU result.
    // For JAL/JALR: the result written to rd is the link address, not ALU output.
    wire [31:0] StageV_fwdValue =
      StageV_isLink ? StageV_LinkValue :
      StageV_isCSR  ? csr_rd_data      :
      StageV_ALUResult;

    // ── Forwarded operand values ───────────────────────────────────────────────
    wire [31:0] forwardedSrcReg1 =
      (forward_a == 2'b10) ? StageV_fwdValue    :
      (forward_a == 2'b01) ? StageVI_writeData  :
      StageIV_rs1_data;

    wire [31:0] forwardedSrcReg2 =
      (forward_b == 2'b10) ? StageV_fwdValue    :
      (forward_b == 2'b01) ? StageVI_writeData  :
      StageIV_rs2_data;

    // ── ALU operand selection ─────────────────────────────────────────────────
    // AUIPC: ALU port A receives PC (not rs1) so the adder computes PC + imm.
    // LUI:   ALU port A is irrelevant (ALU_PASS_B ignores A).
    // All other instructions: ALU port A = forwarded rs1.
    wire [31:0] ALU_A = StageIV_isAUIPC ? StageIV_PC        : forwardedSrcReg1;
    wire [31:0] ALU_B = StageIV_ALUBSel ? StageIV_immediate : forwardedSrcReg2;

    // ── ALU ───────────────────────────────────────────────────────────────────
    wire [31:0] aluResult;

    alu u_alu (
      .a     (ALU_A),
      .b     (ALU_B),
      .op    (StageIV_ALUOpcode),
      .result(aluResult)
    );

    // ── Branch comparison ─────────────────────────────────────────────────────
    // The branch condition is evaluated directly in EX using Verilog comparison
    // operators on the forwarded operands.  The ALU runs in parallel but its
    // output is not used for branches (branches write no register).
    reg branchTaken;
    always @(*) begin
      case (StageIV_branchCond)
        `F3_BEQ:  branchTaken = (forwardedSrcReg1 == forwardedSrcReg2);
        `F3_BNE:  branchTaken = (forwardedSrcReg1 != forwardedSrcReg2);
        `F3_BLT:  branchTaken = ($signed(forwardedSrcReg1) <  $signed(forwardedSrcReg2));
        `F3_BGE:  branchTaken = ($signed(forwardedSrcReg1) >= $signed(forwardedSrcReg2));
        `F3_BLTU: branchTaken = (forwardedSrcReg1 <  forwardedSrcReg2);
        `F3_BGEU: branchTaken = (forwardedSrcReg1 >= forwardedSrcReg2);
        default:  branchTaken = 1'b0;
      endcase
    end

    // ── TruePC: branch/jump/trap/MRET target address ─────────────────────────
    // For JALR: target = (rs1 + sext(imm)) & ~1  (low bit forced to 0)
    // For branches/JAL: target = PC + sext(imm)  (PC-relative)
    // For traps: target = {mtvec[31:2], 2'b00}   (direct mode, Phase 1)
    // For MRET: target = mepc
    // TruePC_2 = TruePC + 2 uses the pre-computed immediate2 to avoid an extra
    // adder on the critical path (immediate2 = immediate + 2 from decoder_id).
    wire [31:0] jumpTarget =
      StageIV_isJALR ? ((forwardedSrcReg1 + StageIV_immediate) & ~32'h1) :
                       (StageIV_PC + StageIV_immediate);

    wire [31:0] jumpTarget_2 =
      StageIV_isJALR ? (jumpTarget + 32'd2) :
                       (StageIV_PC + StageIV_immediate2);

    // Trap and MRET targets use the CSR direct outputs (combinational wires).
    wire [31:0] trapTarget = {csr_out_mtvec[31:2], 2'b00};  // direct mode
    wire [31:0] mretTarget = (StageV_isCSR && StageV_CSRAddr == `CSR_MEPC)
                           ? MA_csrNewData
                           : csr_out_mepc;

    // ── Load/store misalignment detection ─────────────────────────────────────
    // Effective address = aluResult.  Misalignment is checked against the
    // natural alignment requirement for each width.
    wire loadMisalign  = StageIV_memRead  && (
        ((StageIV_loadWidth == `WIDTH_H || StageIV_loadWidth == `WIDTH_HU) && aluResult[0])  ||
        ( StageIV_loadWidth == `WIDTH_W                                    && aluResult[1:0] != 2'b00));

    wire storeMisalign = StageIV_memWrite && (
        (StageIV_storeWidth == 2'b01 && aluResult[0])              ||   // SH
        (StageIV_storeWidth == 2'b10 && aluResult[1:0] != 2'b00));      // SW

    // ── Trap detection in EX ──────────────────────────────────────────────────
    wire EX_isTrap = StageIV_isECALL   || StageIV_isEBREAK || StageIV_isIllegal ||
                     loadMisalign      || storeMisalign;

    wire [3:0] EX_trapCause =
      StageIV_isECALL   ? `TRAP_ECALL_M         :
      StageIV_isEBREAK  ? `TRAP_BREAKPOINT      :
      loadMisalign      ? `TRAP_LOAD_MISALIGN   :
      storeMisalign     ? `TRAP_STORE_MISALIGN  :
      /* isIllegal */     `TRAP_ILLEGAL_INSTR   ;

    // trapVal: faulting address for misalignment; 0 for others (optional in spec)
    wire [31:0] EX_trapVal = (loadMisalign || storeMisalign) ? aluResult : 32'h0;

    // ── Flush and TruePC selection ────────────────────────────────────────────
    // Priority: MRET > trap > taken branch/jump.
    // (In practice only one of these fires at a time in a correct program.)
    wire exFlush = StageIV_isMRET || EX_isTrap ||
                   (StageIV_isBranch && branchTaken) || StageIV_isJump;

    wire [31:0] TruePC =
      StageIV_isMRET                  ? mretTarget  :
      EX_isTrap                       ? trapTarget  :
      /* taken branch or JAL/JALR */  jumpTarget    ;
    wire [31:0] TruePC_2 =
      StageIV_isMRET                  ? (mretTarget + 32'd2) :
      EX_isTrap                       ? (trapTarget + 32'd2) :
      /* taken branch or JAL/JALR */  jumpTarget_2           ;


    // ── Delayed flush: kills the BRAM data that was in-flight during exFlush ──
    // The BRAM read is synchronous: the wrong address driven in cycle N produces
    // wrong data in cycle N+1.  flushDelayed kills that data by inserting a
    // second NOP into StageIII_.  Together exFlush + flushDelayed give the
    // 2-cycle branch penalty on taken branches/jumps.
    reg flushDelayed;
    always @(posedge clk) begin
      if (!resetn) flushDelayed <= 1'b0;
      else if (halted) flushDelayed <= 1'b0;
      else flushDelayed <= exFlush;
    end

    // ── Link address (return address for JAL/JALR family) ─────────────────────
    // PC+2 for compressed instructions (C.JAL, C.JALR), PC+4 for 32-bit.
    wire [31:0] EX_linkValue = StageIV_isCompressed ? (StageIV_PC + 32'd2)
                                                    : (StageIV_PC + 32'd4);

    // ── CSR write data (finalised in EX after forwarding) ─────────────────────
    // For CSRRWI/CSRRSI/CSRRCI: write data = {27'b0, rs1_index} (zimm field).
    // For CSRRW/CSRRS/CSRRC: write data = forwarded rs1 value.
    wire [31:0] EX_csrWriteData = StageIV_CSRUseImm ? {27'b0, StageIV_rs1_index}
                                                    : forwardedSrcReg1;

    // ── StageV_ latch (EX → MA) ──────────────────────────────────────────────
    always @(posedge clk) begin
      if (!resetn) begin
        StageV_PC           <= 32'h0;   StageV_rd_index     <= 5'd0;
        StageV_destRegWrite <= 1'b0;    StageV_ALUResult    <= 32'h0;
        StageV_rs2_data     <= 32'h0;   StageV_memRead      <= 1'b0;
        StageV_memWrite     <= 1'b0;    StageV_memToReg     <= 1'b0;
        StageV_isLink       <= 1'b0;    StageV_LinkValue    <= 32'h0;
        StageV_loadWidth    <= 3'd0;    StageV_storeWidth   <= 2'd0;
        StageV_isCSR        <= 1'b0;    StageV_CSRAddr      <= 12'd0;
        StageV_CSROp        <= 2'd0;    StageV_CSR_wdata    <= 32'h0;
        StageV_isTrap       <= 1'b0;    StageV_trapCause    <= 4'd0;
        StageV_trapPC       <= 32'h0;   StageV_trapVal      <= 32'h0;
        StageV_isMRET       <= 1'b0;    StageV_HALT         <= 1'b0;
      end else if (halted) begin
        // ── CPU halted: freeze ─────────────────────────────────────────────────
      end else begin
        StageV_PC           <= StageIV_PC;
        StageV_rd_index     <= StageIV_rd_index;
        StageV_destRegWrite <= StageIV_destRegWrite && !EX_isTrap;
        StageV_ALUResult    <= aluResult;
        StageV_rs2_data     <= forwardedSrcReg2;   // forwarded store data
        StageV_memRead      <= StageIV_memRead;
        StageV_memWrite     <= StageIV_memWrite;
        StageV_memToReg     <= StageIV_memToReg;
        StageV_isLink       <= StageIV_isLink;
        StageV_LinkValue    <= EX_linkValue;
        StageV_loadWidth    <= StageIV_loadWidth;
        StageV_storeWidth   <= StageIV_storeWidth;
        StageV_isCSR        <= StageIV_isCSR;
        StageV_CSRAddr      <= StageIV_CSRAddr;
        StageV_CSROp        <= StageIV_CSROp;
        StageV_CSR_wdata    <= EX_csrWriteData;
        StageV_isTrap       <= EX_isTrap;
        StageV_trapCause    <= EX_trapCause;
        StageV_trapPC       <= StageIV_PC;
        StageV_trapVal      <= EX_trapVal;
        StageV_isMRET       <= StageIV_isMRET;
        StageV_HALT         <= StageIV_HALT;
      end
    end
  // =============================================================================
  // ─── STAGE IV: EXECUTE (EX) ──────────────────────────────────────────────────
  // =============================================================================


  // =============================================================================
  // ─── STAGE V: MEMORY ACCESS (MA) ─────────────────────────────────────────────
  // =============================================================================
  // Data memory read/write, load data extraction, CSR read-modify-write,
  // trap entry (mepc/mcause/mstatus update), MRET (mstatus restore).
  // Also detects misalignment traps not caught in EX (none expected in Phase 1,
  // but the maFlush mechanism is present for correctness).
  // =============================================================================

    // ── DMEM address ──────────────────────────────────────────────────────────
    // Word-address = effective_addr[N:2]  (drops byte-offset bits [1:0])
    assign dmem_addr = StageV_ALUResult[DMEM_ADDR_W+1:2];

    // ── Store byte-enable and write-data generation ───────────────────────────
    // SB: replicate byte to all 4 lanes; enable only the target byte.
    // SH: replicate halfword to both lanes; enable the target 2 bytes.
    // SW: write full word; enable all 4 bytes.
    reg [3:0]  MA_dmem_we;
    reg [31:0] MA_dmem_wdata;

    always @(*) begin
      MA_dmem_we    = 4'b0000;
      MA_dmem_wdata = 32'h0;
      if (StageV_memWrite && !StageV_isTrap) begin
        case (StageV_storeWidth)
          2'b00: begin  // SB
            MA_dmem_wdata = {4{StageV_rs2_data[7:0]}};
            case (StageV_ALUResult[1:0])
              2'b00: MA_dmem_we = 4'b0001;
              2'b01: MA_dmem_we = 4'b0010;
              2'b10: MA_dmem_we = 4'b0100;
              2'b11: MA_dmem_we = 4'b1000;
            endcase
          end
          2'b01: begin  // SH
            MA_dmem_wdata = {2{StageV_rs2_data[15:0]}};
            MA_dmem_we    = StageV_ALUResult[1] ? 4'b1100 : 4'b0011;
          end
          2'b10: begin  // SW
            MA_dmem_wdata = StageV_rs2_data;
            MA_dmem_we    = 4'b1111;
          end
          default: begin end
        endcase
      end
    end

    assign dmem_we    = MA_dmem_we;
    assign dmem_wdata = MA_dmem_wdata;

    // ── Load data extraction and sign/zero extension ──────────────────────────
    // The DMEM delivers a 32-bit word.  We extract the correct byte or halfword
    // using addr[1:0], then extend based on the load width / signedness.
    wire [7:0] MA_loadByte =
      StageV_ALUResult[1:0] == 2'b00 ? dmem_rdata[7:0]    :
      StageV_ALUResult[1:0] == 2'b01 ? dmem_rdata[15:8]   :
      StageV_ALUResult[1:0] == 2'b10 ? dmem_rdata[23:16]  :
                                        dmem_rdata[31:24] ;

    wire [15:0] MA_loadHalf =
      StageV_ALUResult[1] ? dmem_rdata[31:16] : dmem_rdata[15:0];

    reg [31:0] MA_loadData;
    always @(*) begin
      case (StageV_loadWidth)
        `WIDTH_B:  MA_loadData = {{24{MA_loadByte[7]}},  MA_loadByte};
        `WIDTH_H:  MA_loadData = {{16{MA_loadHalf[15]}}, MA_loadHalf};
        `WIDTH_W:  MA_loadData = dmem_rdata;
        `WIDTH_BU: MA_loadData = {24'h0, MA_loadByte};
        `WIDTH_HU: MA_loadData = {16'h0, MA_loadHalf};
        default:   MA_loadData = dmem_rdata;
      endcase
    end

    // ── CSR register file ─────────────────────────────────────────────────────
    // Read happens combinationally (rd_data available this cycle).
    // Write happens on posedge clk (driven by wr_en this cycle).
    // The read-modify-write for CSRRS/CSRRC is computed here combinationally,
    // then presented on wr_data.
    wire [31:0] MA_csrNewData;
    assign MA_csrNewData =
      (StageV_CSROp == `CSR_OP_RW) ? StageV_CSR_wdata                        :
      (StageV_CSROp == `CSR_OP_RS) ? (csr_rd_data |  StageV_CSR_wdata)       :
      (StageV_CSROp == `CSR_OP_RC) ? (csr_rd_data & ~StageV_CSR_wdata)       :
                                     StageV_CSR_wdata;

    // Spec: CSRRS/CSRRC with wdata=0 must NOT write (to avoid side effects).
    // CSRRW always writes.
    wire MA_csrWriteEn = StageV_isCSR && !StageV_isTrap
                      && (StageV_CSROp == `CSR_OP_RW || StageV_CSR_wdata != 32'h0);

    csr_regfile u_csr_regfile (
      .clk         (clk),
      .resetn      (resetn),
      .rd_addr     (StageV_CSRAddr),
      .rd_data     (csr_rd_data),          // combinational; used by forwarding + RMW
      .wr_addr     (StageV_CSRAddr),
      .wr_data     (MA_csrNewData),
      .wr_en       (MA_csrWriteEn),
      .trap_en     (StageV_isTrap),
      .trap_mepc   (StageV_trapPC),
      .trap_mcause ({28'h0, StageV_trapCause}),
      .trap_mtval  (StageV_trapVal),
      .mret_en     (StageV_isMRET),
      .out_mstatus (csr_out_mstatus),
      .out_mtvec   (csr_out_mtvec),
      .out_mepc    (csr_out_mepc)
    );

    // ── MA misalignment trap (load/store detected late) ───────────────────────
    // In our design, misalignment is detected in EX from the ALU result.
    // This maFlush path handles the degenerate case where a misalignment
    // somehow reaches MA without being caught in EX (should not occur in
    // Phase 1 with correct programs, but the mechanism is present).
    // For Phase 1: maFlush is never asserted; it remains as infrastructure.
    wire        maFlush;
    wire [31:0] maTruePC;
    assign maFlush = 1'b0;
    assign maTruePC = {csr_out_mtvec[31:2], 2'b00};

    reg maFlushDelayed;
    always @(posedge clk) begin
      if (!resetn) maFlushDelayed <= 1'b0;
      else if (halted) maFlushDelayed <= 1'b0;
      else maFlushDelayed <= maFlush;
    end

    // ── StageVI_ latch (MA → WB) ──────────────────────────────────────────────
    // For CSR instructions: MA places csr_rd_data (old CSR value) into
    // StageVI_ALUResult so WB writes it to the destination register normally.
    always @(posedge clk) begin
      if (!resetn) begin
        StageVI_rd_index     <= 5'd0;    StageVI_destRegWrite <= 1'b0;
        StageVI_ALUResult    <= 32'h0;   StageVI_loadData     <= 32'h0;
        StageVI_memToReg     <= 1'b0;    StageVI_isLink       <= 1'b0;
        StageVI_LinkValue    <= 32'h0;   StageVI_HALT         <= 1'b0;
      end else if (halted) begin
        // ── CPU halted: freeze ─────────────────────────────────────────────────
      end else begin
        StageVI_rd_index     <= StageV_rd_index;
        StageVI_destRegWrite <= StageV_destRegWrite;
        StageVI_ALUResult    <= StageV_isCSR ? csr_rd_data : StageV_ALUResult;
        StageVI_loadData     <= MA_loadData;
        StageVI_memToReg     <= StageV_memToReg;
        StageVI_isLink       <= StageV_isLink;
        StageVI_LinkValue    <= StageV_LinkValue;
        StageVI_HALT         <= StageV_HALT;
      end
    end
  // =============================================================================
  // ─── STAGE V: MEMORY ACCESS (MA) ─────────────────────────────────────────────
  // =============================================================================


  // =============================================================================
  // ─── STAGE VI: WRITE BACK (WB) ───────────────────────────────────────────────
  // =============================================================================
  // Select the write data (ALU result / load data / link address / old CSR value),
  // write it to the register file, and assert halted when HALT retires.
  //
  // StageVI_writeData and StageVI_writeEnable are declared in the EX section
  // (forward declarations) because the forwarding unit needs them.
  // The register file write port is driven by those wires — no logic here.
  // =============================================================================
    always @(posedge clk) begin
      if (!resetn) begin
        halted <= 1'b0;
      end else if (halted) begin
        // ── Stay halted once set ────────────────────────────────────────────────
      end else begin
        halted <= StageVI_HALT;
      end
    end
  // =============================================================================
  // ─── STAGE VI: WRITE BACK (WB) ───────────────────────────────────────────────
  // =============================================================================


endmodule
