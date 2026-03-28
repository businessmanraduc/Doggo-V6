`include "isa.vh"
// =============================================================================
// PHANTOM-16  ──  5-Stage Pipelined CPU
// =============================================================================
//
//  ┌────┐   ┌────┐   ┌────┐   ┌─────┐   ┌────┐
//  │ IF │──▶│ ID │──▶│ EX │──▶│ MEM │──▶│ WB │
//  └────┘   └────┘   └────┘   └─────┘   └────┘
//
//  Hazards handled automatically:
//
//  1. DATA HAZARD — full forwarding
//     EX/MEM result  forwarded to EX ALU inputs  (1-cycle-old result)
//     MEM/WB result  forwarded to EX ALU inputs  (2-cycle-old result)
//     Covers R-type, I-type, branch comparisons, and store data.
//
//  2. LOAD-USE HAZARD — 1 stall cycle inserted
//     LW followed immediately by a dependent instruction:
//     stall PC + IF/ID for 1 cycle, bubble inserted into EX.
//     After stall, the load value arrives via MEM/WB forwarding.
//
//  3. CONTROL HAZARD — 2 flush cycles on taken branch/jump
//     Branch resolved in EX. If taken: flush IF and ID (2 bubbles),
//     redirect PC to branch target.
//
// Memory interfaces are async (combinational read), FPGA-synthesisable.
// =============================================================================

module cpu (
  input  wire        clk,
  input  wire        resetn,              // active-low synchronous reset

  // ── Instruction memory (async/combinational read, word-addressed) ────────
  output wire [7:0]  imem_addr,           // word address to fetch from
  input  wire [15:0] imem_data,           // instruction word at that address

  // ── Data memory ──────────────────────────────────────────────────────────
  output wire [7:0]  dmem_addr,           // word address (read or write)
  output wire [15:0] dmem_wdata,          // write data (for SW)
  output wire        dmem_we,             // write enable
  input  wire [15:0] dmem_rdata,          // read data (for LW, combinational)

  output reg         halted               // goes high when HALT retires in WB
);

  // =============================================================================
  // PROGRAM COUNTER
  // =============================================================================
    reg [7:0] ProgramCounter;

    // ── Program Counter update ─────────────────────────────────────────────────
    //   flush  → redirect to branch/jump target (computed in StageIII)
    //   stall  → hold: PC keeps its current value (no assignment)
    //   normal → advance by one word
    always @(posedge clk) begin
      if (!resetn) begin
        ProgramCounter <= 8'h0;
      end else if (halted) begin
        // ── CPU halted: freeze PC ──────────────────────────────────────────────
      end else begin
        if (flush) begin
          // ── Branch/Jump taken: redirect to computed target ────────────────────
          ProgramCounter <= StageIII_branchTarget;
        end else if (!stall) begin
          // ── Normal advance: move to next word ─────────────────────────────────
          ProgramCounter <= ProgramCounter + 8'd1;
        end
        // stall (no flush): PC holds its value (no assignment)
      end
    end
  // =============================================================================
  // PROGRAM COUNTER
  // =============================================================================


  // =============================================================================
  // REGISTER FILE  (8 × 16-bit, R0 hardwired to zero)
  // =============================================================================
  // Reads are asynchronous (combinational) — values are immediately available
  // in the ID stage without adding latency.
  // Writes are synchronous (rising edge) — occur in the WB stage.
  // Write-before-read: if reading and writing the same address simultaneously,
  // the NEW (write) value is returned, eliminating the WB→ID forwarding path.
  // =============================================================================
    reg [15:0] regFile [0:7];
    integer regFileIndex;
    initial begin
      for (regFileIndex = 0; regFileIndex < 8; regFileIndex = regFileIndex + 1)
        regFile[regFileIndex] = 16'h0;
    end
  // =============================================================================
  // REGISTER FILE
  // =============================================================================


  // =============================================================================
  // ─── STAGE 1: INSTRUCTION FETCH (IF) ─────────────────────────────────────────
  // =============================================================================
  // The returned imem_data is latched into IF/ID on the next rising edge.
  // IF stage drives the instruction memory address (imem_addr) combinationally
  // =============================================================================
    assign imem_addr = ProgramCounter;

    // ── InstructionFetch => InstructionDecode pipeline registers ───────────────
    reg [7:0]  StageII_PC;
    reg [15:0] StageII_Instr;

    always @(posedge clk) begin
      if (!resetn) begin
        // ── Reset every pipeline register and the PC ───────────────────────────
        StageII_PC       <=  8'h0;
        StageII_Instr    <= `NOP_INSTR;
      end else if (halted) begin
        // ── CPU halted: freeze all state, assert halted output ─────────────────
      end else begin
        if (flush) begin
          // ── Branch/Jump taken: discard incorrectly fetched instruction ───────
          StageII_PC     <=  ProgramCounter;
          StageII_Instr  <= `NOP_INSTR;
        end else if (!stall) begin
          // ── Normal advancing through the program ───────────────────────────── 
          StageII_PC     <=  ProgramCounter;
          StageII_Instr  <=  imem_data;
        end
      end
    end
  // =============================================================================
  // ─── STAGE 1: INSTRUCTION FETCH (IF) ─────────────────────────────────────────
  // =============================================================================


  // =============================================================================
  // ─── STAGE 2: INSTRUCTION DECODE (ID) ────────────────────────────────────────
  // =============================================================================
  // Decode the instruction in inter-stage instruction register,
  // read the register file, generate the immediate value,
  // and produce control signals.  Also: hazard detection.
  // =============================================================================
    wire [3:0] StageII_Opcode = StageII_Instr[15:12];

    // ── Instruction-class flags (combinational) ───────────────────────────────────
    wire StageII_isRegType = (StageII_Opcode <=  4'h6);
    wire StageII_isBranch  = (StageII_Opcode == `OP_BEQ || StageII_Opcode == `OP_BNE);
    wire StageII_isStore   = (StageII_Opcode == `OP_SW);
    wire StageII_isJump    = (StageII_Opcode == `OP_JMP || StageII_Opcode == `OP_JALR);
    wire StageII_isJmp     = (StageII_Opcode == `OP_JMP);
    wire StageII_isLoadImm = (StageII_Opcode == `OP_LI);
    wire StageII_isSys     = (StageII_Opcode == `OP_SYS);

    // ── Register address decode ───────────────────────────────────────────────────
    //  Encoding quirks that differ from the default [rd|rs1|rs2] layout:
    //    S-type  (SW):      rs2=[11:9], rs1=[8:6]   (data register in the rd slot)
    //    J-type  (JMP):     rd =[11:9], imm9=[8:0]  (no source registers)
    wire [2:0] StageII_destRegIndex = StageII_Instr[11:9];
    wire [2:0] StageII_srcReg1Index = StageII_Instr[8:6];
    wire [2:0] StageII_srcReg2Index = 
      StageII_isRegType ? StageII_Instr[5:3]  :   // In Reg-to-Reg, rs2 is in bits 5 to 3
      StageII_isStore   ? StageII_Instr[11:9] :   // In Store-type, rs2 is in bits 11 to 9
      StageII_isBranch  ? StageII_Instr[11:9] :   // In Branches, rs2 is in bits 11 to 9
      3'd0;                                       // Anywhere else, there's no rs2

    // ── Immediate value generation ──────────────────────────────────────────────── 
    wire [15:0] StageII_immValue =
      StageII_isJmp ? {{7{StageII_Instr[8]}},  StageII_Instr[8:0]} :
      StageII_isLoadImm ? {7'h0,               StageII_Instr[8:0]} :
      {{10{StageII_Instr[5]}}, StageII_Instr[5:0]};

    // ── Register file read (async, with write-before-read forwarding) ─────────────
    // For the write-before-read trick, we need to know what WB is writing right now.
    // There are three cases left to treat:
    // 1 - if the searched for register is R0, then we simply return the value 0
    // 2 - if StageV (WB) needs to write to the same register we need to access
    // in StageII (ID), then we simply forward the new value coming from StageV
    // 3 - otherwise, simply return the value inside the desired register
    wire        StageV_writeEnable;
    wire [2:0]  StageV_writeRegIndex;
    wire [15:0] StageV_writeData;
    wire forwardSrcReg1 = StageV_writeEnable && (StageV_writeRegIndex == StageII_srcReg1Index);
    wire forwardSrcReg2 = StageV_writeEnable && (StageV_writeRegIndex == StageII_srcReg2Index);

    wire [15:0] StageII_srcReg1Data =
      (StageII_srcReg1Index == 3'd0) ? 16'h0 :
      (forwardSrcReg1) ? StageV_writeData :
      regFile[StageII_srcReg1Index];

    wire [15:0] StageII_srcReg2Data =
      (StageII_srcReg2Index == 3'd0) ? 16'h0 :
      (forwardSrcReg2) ? StageV_writeData :
      regFile[StageII_srcReg2Index];

    // ── Control signal decode ─────────────────────────────────────────────────────
    // These travel through the pipeline alongside the data.
    // Safe defaults = NOP (no register write, no memory, no branch).
    reg        CTRL_destRegWrite;   // write result to destReg in StageV (WriteBack)
    reg        CTRL_memRead;        // load from data memory (LW)
    reg        CTRL_memWrite;       // store to data memory (SW)
    reg        CTRL_Branch;         // conditional branch (BEQ or BNE)
    reg        CTRL_Jump;           // unconditional jump (JMP or JALR)
    reg        CTRL_ALUBSel;        // (0 = srcReg2, 1 = immediate) => ALU B-operand
    reg        CTRL_memToReg;       // (0 = ALU result, 1 = memory data) => WriteBack
    reg [2:0]  CTRL_ALUOpcode;      // ALU operation code
    reg        CTRL_linkDestReg;    // write PC+1 to destReg (JMP with link, JALR)
    reg        CTRL_branchFlag;     // 0 = branch-if-zero (BEQ), 1 = branch-if-nonzero (BNE)
    reg        CTRL_jumpLink;       // JALR: jump target = srcReg1 + imm (not PC + imm)
    reg        CTRL_HALT;           // HALT instruction

    always @(*) begin
      // Safe default: NOP
      CTRL_destRegWrite = 1'b0;
      CTRL_memRead      = 1'b0;
      CTRL_memWrite     = 1'b0;
      CTRL_Branch       = 1'b0;
      CTRL_Jump         = 1'b0;
      CTRL_ALUBSel      = 1'b0;
      CTRL_memToReg     = 1'b0;
      CTRL_ALUOpcode    = `ALU_ADD;
      CTRL_linkDestReg  = 1'b0;
      CTRL_branchFlag   = 1'b0;
      CTRL_jumpLink     = 1'b0;
      CTRL_HALT         = 1'b0;

      case (StageII_Opcode)
        `OP_ADD:  begin CTRL_destRegWrite=1;                    CTRL_ALUOpcode=`ALU_ADD;                                                        end
        `OP_SUB:  begin CTRL_destRegWrite=1;                    CTRL_ALUOpcode=`ALU_SUB;                                                        end
        `OP_AND:  begin CTRL_destRegWrite=1;                    CTRL_ALUOpcode=`ALU_AND;                                                        end
        `OP_OR:   begin CTRL_destRegWrite=1;                    CTRL_ALUOpcode=`ALU_OR;                                                         end
        `OP_XOR:  begin CTRL_destRegWrite=1;                    CTRL_ALUOpcode=`ALU_XOR;                                                        end
        `OP_SHL:  begin CTRL_destRegWrite=1;                    CTRL_ALUOpcode=`ALU_SHL;                                                        end
        `OP_SHR:  begin CTRL_destRegWrite=1;                    CTRL_ALUOpcode=`ALU_SHR;                                                        end
        `OP_ADDI: begin CTRL_destRegWrite=1; CTRL_ALUBSel=1;    CTRL_ALUOpcode=`ALU_ADD;                                                        end
        `OP_LW:   begin CTRL_destRegWrite=1; CTRL_ALUBSel=1;    CTRL_ALUOpcode=`ALU_ADD;  CTRL_memRead=1;  CTRL_memToReg=1;                     end
        `OP_SW:   begin                      CTRL_ALUBSel=1;    CTRL_ALUOpcode=`ALU_ADD;  CTRL_memWrite=1;                                      end
        `OP_BEQ:  begin CTRL_Branch=1;                          CTRL_ALUOpcode=`ALU_SUB;                                                        end
        `OP_BNE:  begin CTRL_Branch=1;       CTRL_branchFlag=1; CTRL_ALUOpcode=`ALU_SUB;                                                        end
        `OP_JMP:  begin CTRL_destRegWrite=1;                                              CTRL_Jump=1;     CTRL_linkDestReg=1;                  end
        `OP_LI:   begin CTRL_destRegWrite=1; CTRL_ALUBSel=1;    CTRL_ALUOpcode=`ALU_PASS;                                                       end
        `OP_JALR: begin CTRL_destRegWrite=1; CTRL_ALUBSel=1;    CTRL_ALUOpcode=`ALU_ADD;  CTRL_Jump=1;     CTRL_linkDestReg=1; CTRL_jumpLink=1; end
        `OP_SYS:  begin if (StageII_Instr[11:0] == 12'd1)   CTRL_HALT = 1'b1;                                                               end
        default: ; // unknown opcode → NOP (safe)
      endcase
    end

    // ── InstructionDecode => ExecuteUnit pipeline registers ────────────────────
    reg [7:0]  StageIII_PC;
    reg [2:0]  StageIII_destRegIndex;
    reg [2:0]  StageIII_srcReg1Index;
    reg [2:0]  StageIII_srcReg2Index;
    reg [15:0] StageIII_srcReg1Data;
    reg [15:0] StageIII_srcReg2Data;
    reg [15:0] StageIII_immValue;
    // ── Control signal decode ──────────────────────────────────────────────────
    reg        StageIII_destRegWrite;
    reg        StageIII_memRead;
    reg        StageIII_memWrite;
    reg        StageIII_Branch;
    reg        StageIII_Jump;
    reg        StageIII_ALUBSel;
    reg        StageIII_memToReg;
    reg [2:0]  StageIII_ALUOpcode;
    reg        StageIII_linkDestReg;
    reg        StageIII_branchFlag;
    reg        StageIII_jumpLink;
    reg        StageIII_HALT;

    always @(posedge clk) begin
      if (!resetn) begin
        // ── Reset every pipeline register and the PC ───────────────────────────
        StageIII_PC           <= 8'h0;
        StageIII_destRegIndex <= 3'd0;  StageIII_srcReg1Index <= 3'd0;
        StageIII_srcReg2Index <= 3'd0;  StageIII_srcReg1Data  <= 16'd0;
        StageIII_srcReg2Data  <= 16'd0; StageIII_immValue     <= 16'h0;
        StageIII_destRegWrite <= 1'b0;  StageIII_memRead      <= 1'b0;
        StageIII_memWrite     <= 1'b0;  StageIII_Branch       <= 1'b0;
        StageIII_Jump         <= 1'b0;  StageIII_ALUBSel      <= 1'b0;
        StageIII_memToReg     <= 1'b0;  StageIII_ALUOpcode    <= `ALU_ADD;
        StageIII_linkDestReg  <= 1'b0;  StageIII_branchFlag   <= 1'b0;
        StageIII_jumpLink     <= 1'b0;  StageIII_HALT         <= 1'b0;
      end else if (halted) begin
        // ── CPU halted: freeze all state, assert halted output ─────────────────
      end else begin
        if (flush || stall) begin
          // ── Flush OR Stall -> Insert NOP bubble in StageIII (Execute)
          // ── Bubble: preserve addresses for debugging but zero all control ────
          StageIII_PC           <= StageII_PC;
          StageIII_destRegIndex <= 3'd0;  StageIII_srcReg1Index <= 3'd0;
          StageIII_srcReg2Index <= 3'd0;  StageIII_srcReg1Data  <= 16'd0;
          StageIII_srcReg2Data  <= 16'd0; StageIII_immValue     <= 16'h0;
          StageIII_destRegWrite <= 1'b0;  StageIII_memRead      <= 1'b0;
          StageIII_memWrite     <= 1'b0;  StageIII_Branch       <= 1'b0;
          StageIII_Jump         <= 1'b0;  StageIII_ALUBSel      <= 1'b0;
          StageIII_memToReg     <= 1'b0;  StageIII_ALUOpcode    <= `ALU_ADD;
          StageIII_linkDestReg  <= 1'b0;  StageIII_branchFlag   <= 1'b0;
          StageIII_jumpLink     <= 1'b0;  StageIII_HALT         <= 1'b0;
        end else begin
          // ── Normal advancing through the program ─────────────────────────────
          StageIII_PC           <= StageII_PC;
          StageIII_destRegIndex <= StageII_destRegIndex;
          StageIII_srcReg1Index <= StageII_srcReg1Index;
          StageIII_srcReg2Index <= StageII_srcReg2Index;
          StageIII_srcReg1Data  <= StageII_srcReg1Data;
          StageIII_srcReg2Data  <= StageII_srcReg2Data;
          StageIII_immValue     <= StageII_immValue;
          StageIII_destRegWrite <= CTRL_destRegWrite;
          StageIII_memRead      <= CTRL_memRead;
          StageIII_memWrite     <= CTRL_memWrite;
          StageIII_Branch       <= CTRL_Branch;
          StageIII_Jump         <= CTRL_Jump;
          StageIII_ALUBSel      <= CTRL_ALUBSel;
          StageIII_memToReg     <= CTRL_memToReg;
          StageIII_ALUOpcode    <= CTRL_ALUOpcode;
          StageIII_linkDestReg  <= CTRL_linkDestReg;
          StageIII_branchFlag   <= CTRL_branchFlag;
          StageIII_jumpLink     <= CTRL_jumpLink;
          StageIII_HALT         <= CTRL_HALT;
        end
      end
    end

    // ── HAZARD DETECTION  (load-use stall) ─────────────────────────────────────
    // Triggered when the instruction currently in StageIII (Execute) is a LOAD and
    // the instruction currently in StageII (InstructionDecode) reads the loaded register.
    // Effect: stall PC and IF/ID for 1 cycle, insert NOP bubble into EX.
    // After the stall, the loaded value arrives via StageV (WriteBack) forwarding.
    wire stall = StageIII_memRead && (StageIII_destRegIndex != 3'd0)
              && (StageIII_destRegIndex == StageII_srcReg1Index
              || StageIII_destRegIndex == StageII_srcReg2Index);

    // ── ExecuteUnit => MemoryFetch pipeline registers ──────────────────────────
    // (needed early such that forwarding unit can see it)
    reg [2:0]  StageIV_destRegIndex;
    reg [15:0] StageIV_ALUResult;
    reg [15:0] StageIV_srcReg2Data;
    reg        StageIV_destRegWrite;
    reg        StageIV_memRead;
    reg        StageIV_memWrite;
    reg        StageIV_memToReg;
    reg        StageIV_HALT;

    // ── MemoryFetch => WriteBack pipeline registers ────────────────────────────
    // (needed early such that forwarding unit can see it)
    reg [2:0]  StageV_destRegIndex;
    reg [15:0] StageV_ALUResult;
    reg [15:0] StageV_memDataFromDMEM;
    reg        StageV_destRegWrite;
    reg        StageV_memToReg;
    reg        StageV_HALT;
  // =============================================================================
  // ─── STAGE 2: INSTRUCTION DECODE (ID) ────────────────────────────────────────
  // =============================================================================


  // =============================================================================
  // ─── STAGE 3: EXECUTE (EX) ───────────────────────────────────────────────────
  // =============================================================================
  // Forwarding → operand selection → ALU → branch/jump decision.

    // ── WB result (for forwarding) ─────────────────────────────────────────────
    wire [15:0] StageV_Result = StageV_memToReg ? StageV_memDataFromDMEM : StageV_ALUResult;

    // ── Forwarding unit ────────────────────────────────────────────────────────
    //   forward_x encoding:
    //     2'b00  no forwarding         →  use value from StageIII (Execute) pipeline register
    //     2'b01  StageV (WriteBack)    →  use StageV_memDataFromDMEM   (2 cycles back)
    //     2'b10  StageIV (MemoryFetch) →  use StageIV_ALUResult        (1 cycle back)
    //   StageIV takes priority over StageV when both match (closer = fresher).

    wire [1:0] forward_a =
      (StageIV_destRegWrite && StageIV_destRegIndex != 3'd0 && StageIV_destRegIndex == StageIII_srcReg1Index) ? 2'b10 :
      (StageV_destRegWrite  && StageV_destRegIndex  != 3'd0 && StageV_destRegIndex  == StageIII_srcReg1Index) ? 2'b01 :
      2'b00;

    wire [1:0] forward_b =
      (StageIV_destRegWrite && StageIV_destRegIndex != 3'd0 && StageIV_destRegIndex == StageIII_srcReg2Index) ? 2'b10 :
      (StageV_destRegWrite  && StageV_destRegIndex  != 3'd0 && StageV_destRegIndex  == StageIII_srcReg2Index) ? 2'b01 :
      2'b00;

    // ── Forwarded operand values ───────────────────────────────────────────────
    wire [15:0] StageIV_forwardedSrcReg1Data =
      (forward_a == 2'b10) ? StageIV_ALUResult :
      (forward_a == 2'b01) ? StageV_Result :
      StageIII_srcReg1Data;

    wire [15:0] StageIV_forwardedSrcReg2Data =
      (forward_b == 2'b10) ? StageIV_ALUResult :
      (forward_b == 2'b01) ? StageV_Result :
      StageIII_srcReg2Data;

    // ── ALU inputs ─────────────────────────────────────────────────────────────
    wire [15:0] ALU_A = StageIV_forwardedSrcReg1Data;
    wire [15:0] ALU_B = StageIII_ALUBSel ? StageIII_immValue : StageIV_forwardedSrcReg2Data;

    // ── ALU instantiation ──────────────────────────────────────────────────────
    wire [15:0] ALUResult;
    wire        ALUZeroFlag;

    alu exec_alu (
      .a      (ALU_A),
      .b      (ALU_B),
      .op     (StageIII_ALUOpcode),
      .result (ALUResult),
      .zero   (ALUZeroFlag)
    );

    // ── Branch / jump decision ─────────────────────────────────────────────────
    //   For branches (BEQ/BNE): the ALU computes srcReg1 - srcReg2.
    //     BEQ → branch if result == 0  (!StageIII_branchFlag && ALUZeroFlag)
    //     BNE → branch if result != 0  ( StageIII_branchFlag && !ALUZeroFlag)
    //   For unconditional jumps (JMP, JALR): always taken.
    wire branchTaken = StageIII_Branch && (StageIII_branchFlag ? !ALUZeroFlag : ALUZeroFlag);
    wire doJump      = StageIII_Jump || branchTaken;
    wire flush       = doJump;

    // ── Branch / jump target address & StageIII_Result value ───────────────────
    //   BEQ / BNE / JMP  →  (PC_of_branch + 1) + sext(imm)
    //   JALR             →  srcReg1 + sext(imm6)
    // All targets are 8-bit (word address into 256-word memory).
    // PC+1 zero-extended to 16 bits (word address of instruction after the jump).
    wire [7:0] StageIII_branchTarget = StageIII_jumpLink ?
      (StageIV_forwardedSrcReg1Data[7:0] + StageIII_immValue[7:0]) :
      (StageIII_PC + 8'd1                + StageIII_immValue[7:0]);
    wire [15:0] StageIII_linkValue = {8'h0, StageIII_PC + 8'd1};
    wire [15:0] StageIII_Result    = StageIII_linkDestReg ? StageIII_linkValue : ALUResult;

    always @(posedge clk) begin
      if (!resetn) begin
        StageIV_destRegIndex <= 3'd0;   StageIV_ALUResult    <= 16'h0;
        StageIV_srcReg2Data  <= 16'h0;  StageIV_destRegWrite <= 1'b0;
        StageIV_memRead      <= 1'b0;   StageIV_memWrite     <= 1'b0;
        StageIV_memToReg     <= 1'b0;   StageIV_HALT         <= 1'b0;
      end else if (halted) begin
        // ── CPU halted: freeze all state ───────────────────────────────────────
      end else begin
        StageIV_destRegIndex <= StageIII_destRegIndex;
        StageIV_ALUResult    <= StageIII_Result;
        StageIV_srcReg2Data  <= StageIV_forwardedSrcReg2Data;
        StageIV_destRegWrite <= StageIII_destRegWrite;
        StageIV_memRead      <= StageIII_memRead;
        StageIV_memWrite     <= StageIII_memWrite;
        StageIV_memToReg     <= StageIII_memToReg;
        StageIV_HALT         <= StageIII_HALT;
      end
    end
  // =============================================================================
  // ─── STAGE 3: EXECUTE (EX) ───────────────────────────────────────────────────
  // =============================================================================


  // =============================================================================
  // ─── STAGE 4: MEMORY ACCESS (MEM) ────────────────────────────────────────────
  // =============================================================================
  // Data memory is accessed combinationally (async read).
  // Write (SW) is controlled by dmem_we; memory latches on rising edge.
  // Read data (LW) is available combinationally and latched into StageV.
  // =============================================================================
    assign dmem_addr           = StageIV_ALUResult[7:0];  // effective address from ALU
    assign dmem_wdata          = StageIV_srcReg2Data;     // forwarded store data
    assign dmem_we             = StageIV_memWrite;
 
    // ── MemoryFetch => WriteBack pipeline register always block ────────────────
    always @(posedge clk) begin
      if (!resetn) begin
        StageV_destRegIndex    <= 3'd0;   StageV_ALUResult        <= 16'h0;
        StageV_memDataFromDMEM <= 16'h0;  StageV_destRegWrite     <= 1'b0;
        StageV_memToReg        <= 1'b0;   StageV_HALT             <= 1'b0;
      end else if (halted) begin
        // ── CPU halted: freeze all state ──────────────────────────────────────
      end else begin
        StageV_destRegIndex    <= StageIV_destRegIndex;
        StageV_ALUResult       <= StageIV_ALUResult;
        StageV_memDataFromDMEM <= dmem_rdata;               // combinational read from dmem
        StageV_destRegWrite    <= StageIV_destRegWrite;
        StageV_memToReg        <= StageIV_memToReg;
        StageV_HALT            <= StageIV_HALT;
      end
    end
  // =============================================================================
  // ─── STAGE 4: MEMORY ACCESS (MEM) ────────────────────────────────────────────
  // =============================================================================
 
 
  // =============================================================================
  // ─── STAGE 5: WRITE BACK (WB) ────────────────────────────────────────────────
  // =============================================================================
  // Select between ALU result and memory read data, then write to the register file.
  // Also drives the StageV_write* wires used for write-before-read forwarding in ID.
  // =============================================================================
 
    // ── WB write signals — drive the forward-declared wires from Stage 2 ───────
    assign StageV_writeEnable   = StageV_destRegWrite && (StageV_destRegIndex != 3'd0) && !halted;
    assign StageV_writeRegIndex = StageV_destRegIndex;
    assign StageV_writeData     = StageV_Result;         // StageV_Result declared in Stage 3
 
    // ── Register file write + halted latch ─────────────────────────────────────
    always @(posedge clk) begin
      if (!resetn) begin
        halted <= 1'b0;
      end else if (halted) begin
        // ── CPU halted: stay halted ────────────────────────────────────────────
      end else begin
        if (StageV_writeEnable)
          regFile[StageV_writeRegIndex] <= StageV_writeData;
        halted <= StageV_HALT;         // becomes 1 when HALT retires
      end
    end
  // =============================================================================
  // ─── STAGE 5: WRITE BACK (WB) ────────────────────────────────────────────────
  // =============================================================================


endmodule
