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
  output wire [7:0]  DataMem_Addr,        // word address (read or write)
  output wire [15:0] DataMem_WriteData,   // write data (for SW)
  output wire        DataMem_WriteEnable, // write enable
  input  wire [15:0] dmem_rdata,          // read data (for LW, combinational)

  output reg         halted               // goes high when HALT retires in WB
);

  // =============================================================================
  // PROGRAM COUNTER
  // =============================================================================
  reg [7:0] programCounter;

  // IF stage drives the instruction memory address combinationally
  assign imem_addr = programCounter;

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
  // ─── STAGE 1: INSTRUCTION FETCH (IF) ─────────────────────────────────────────
  // =============================================================================
  // imem_addr = programCounter (combinational, above).
  // The returned imem_data is latched into IF/ID on the next rising edge.

  // ── IF/ID pipeline register ───────────────────────────────────────────────────
  reg [7:0]  FetchDecode_ProgramCounter;
  reg [15:0] FetchDecode_Instr;

  // =============================================================================
  // ─── STAGE 2: INSTRUCTION DECODE (ID) ────────────────────────────────────────
  // =============================================================================
  // Decode the instruction in FetchDecode_Instr, read the register file, generate
  // the immediate value, and produce control signals.  Also: hazard detection.

  wire [3:0] Decode_Opcode = FetchDecode_Instr[15:12];

  // ── Instruction-class flags (combinational) ───────────────────────────────────
  wire Decode_isRType  = (Decode_Opcode <= 4'h6);
  wire Decode_isBranch = (Decode_Opcode == `OP_BEQ || Decode_Opcode == `OP_BNE);
  wire Decode_isStore  = (Decode_Opcode == `OP_SW);
  wire Decode_isJump   = (Decode_Opcode == `OP_JMP || Decode_Opcode == `OP_JALR);
  wire Decode_isLI     = (Decode_Opcode == `OP_LI);
  wire Decode_isJmp    = (Decode_Opcode == `OP_JMP);
  wire Decode_isSys    = (Decode_Opcode == `OP_SYS);

  // ── Register address decode ───────────────────────────────────────────────────
  //
  //  Encoding quirks that differ from the default [rd|rs1|rs2] layout:
  //    B-type  (BEQ/BNE): rs1=[11:9], rs2=[8:6]   (no rd, two sources)
  //    S-type  (SW):      rs2=[11:9], rs1=[8:6]   (data register in the rd slot)
  //    J-type  (JMP):     rd =[11:9], imm9=[8:0]  (no source registers)
  //
  //  We normalise here so that Decode_SrcReg1 and Decode_SrcReg2 always point to
  //  the correct logical source, regardless of encoding type.

  wire [2:0] Decode_DestReg  = FetchDecode_Instr[11:9]; // destination (all formats)

  wire [2:0] Decode_SrcReg1 =
    Decode_isBranch ? FetchDecode_Instr[11:9] :         // B-type: rs1 is in [11:9]
                      FetchDecode_Instr[8:6];           // everything else: rs1 in [8:6]

  wire [2:0] Decode_SrcReg2 =
    Decode_isBranch ? FetchDecode_Instr[8:6]  :         // B-type: rs2 in [8:6]
    Decode_isRType  ? FetchDecode_Instr[5:3]  :         // R-type: rs2 in [5:3]
    Decode_isStore  ? FetchDecode_Instr[11:9] :         // S-type: data reg in [11:9]
                      3'd0;                             // I/J/U/SYS: no rs2

  // ── Immediate generation ──────────────────────────────────────────────────────
  wire [15:0] Decode_imm6bit         = {{10{FetchDecode_Instr[5]}}, FetchDecode_Instr[5:0]}; // sext
  wire [15:0] Decode_imm9bit_signExt = {{7{FetchDecode_Instr[8]}},  FetchDecode_Instr[8:0]}; // sext (JMP)
  wire [15:0] Decode_imm9bit_zeroExt = {7'h0,                       FetchDecode_Instr[8:0]}; // zext (LI)

  wire [15:0] Decode_imm =
    Decode_isJmp ? Decode_imm9bit_signExt :
    Decode_isLI  ? Decode_imm9bit_zeroExt :
                   Decode_imm6bit;                      // I, S, B types all use imm6

  // ── Register file read (async, with write-before-read forwarding) ─────────────
  // WB writes regFile[] and also drives WriteBack_Result (declared later in WB section).
  // For the write-before-read trick, we need to know what WB is writing right now.
  // That's captured via: WriteBack_WriteEnable, WriteBack_WriteRegAddr, WriteBack_WriteData — wired in the WB section.
  wire        WriteBack_WriteEnable;       // declared at bottom; forward-referenced here
  wire [2:0]  WriteBack_WriteRegAddr;
  wire [15:0] WriteBack_WriteData;

  wire [15:0] Decode_SrcReg1_Data =
    (Decode_SrcReg1 == 3'd0)                                              ? 16'h0 :
    (WriteBack_WriteEnable && WriteBack_WriteRegAddr == Decode_SrcReg1)   ? WriteBack_WriteData :
                                                                            regFile[Decode_SrcReg1];

  wire [15:0] Decode_SrcReg2_Data =
    (Decode_SrcReg2 == 3'd0)                                              ? 16'h0 :
    (WriteBack_WriteEnable && WriteBack_WriteRegAddr == Decode_SrcReg2)   ? WriteBack_WriteData :
                                                                            regFile[Decode_SrcReg2];

  // ── Control signal decode ─────────────────────────────────────────────────────
  // These travel through the pipeline alongside the data.
  // Safe defaults = NOP (no register write, no memory, no branch).
  reg        CTRL_DestRegWrite;   // write result to DestReg in WB
  reg        CTRL_MemRead;        // load from data memory (LW)
  reg        CTRL_MemWrite;       // store to data memory (SW)
  reg        CTRL_Branch;         // conditional branch
  reg        CTRL_Jump;           // unconditional jump (JMP or JALR)
  reg        CTRL_ALU_B;          // 0 = SrcReg2, 1 = immediate as ALU B-operand
  reg        CTRL_MemToReg;       // 0 = ALU result to WB, 1 = memory data to WB
  reg [2:0]  CTRL_ALUOpcode;      // ALU operation code
  reg        CTRL_LinkDestReg;    // write PC+1 to DestReg (JMP with link, JALR)
  reg        CTRL_BranchFlag;     // 0 = branch-if-zero (BEQ), 1 = branch-if-nonzero (BNE)
  reg        CTRL_JumpLink;       // JALR: jump target = SrcReg1 + imm (not PC + imm)
  reg        CTRL_HALT;           // HALT instruction

  always @(*) begin
    // Safe default: NOP
    CTRL_DestRegWrite = 1'b0;
    CTRL_MemRead      = 1'b0;
    CTRL_MemWrite     = 1'b0;
    CTRL_Branch       = 1'b0;
    CTRL_Jump         = 1'b0;
    CTRL_ALU_B        = 1'b0;
    CTRL_MemToReg     = 1'b0;
    CTRL_ALUOpcode    = `ALU_ADD;
    CTRL_LinkDestReg  = 1'b0;
    CTRL_BranchFlag   = 1'b0;
    CTRL_JumpLink     = 1'b0;
    CTRL_HALT         = 1'b0;

    case (Decode_Opcode)
      `OP_ADD:  begin CTRL_DestRegWrite=1;                    CTRL_ALUOpcode=`ALU_ADD;                                                        end
      `OP_SUB:  begin CTRL_DestRegWrite=1;                    CTRL_ALUOpcode=`ALU_SUB;                                                        end
      `OP_AND:  begin CTRL_DestRegWrite=1;                    CTRL_ALUOpcode=`ALU_AND;                                                        end
      `OP_OR:   begin CTRL_DestRegWrite=1;                    CTRL_ALUOpcode=`ALU_OR;                                                         end
      `OP_XOR:  begin CTRL_DestRegWrite=1;                    CTRL_ALUOpcode=`ALU_XOR;                                                        end
      `OP_SHL:  begin CTRL_DestRegWrite=1;                    CTRL_ALUOpcode=`ALU_SHL;                                                        end
      `OP_SHR:  begin CTRL_DestRegWrite=1;                    CTRL_ALUOpcode=`ALU_SHR;                                                        end
      `OP_ADDI: begin CTRL_DestRegWrite=1; CTRL_ALU_B=1;      CTRL_ALUOpcode=`ALU_ADD;                                                        end
      `OP_LW:   begin CTRL_DestRegWrite=1; CTRL_ALU_B=1;      CTRL_ALUOpcode=`ALU_ADD;  CTRL_MemRead=1;  CTRL_MemToReg=1;                     end
      `OP_SW:   begin                      CTRL_ALU_B=1;      CTRL_ALUOpcode=`ALU_ADD;  CTRL_MemWrite=1;                                      end
      `OP_BEQ:  begin CTRL_Branch=1;                          CTRL_ALUOpcode=`ALU_SUB;                                                        end
      `OP_BNE:  begin CTRL_Branch=1;       CTRL_BranchFlag=1; CTRL_ALUOpcode=`ALU_SUB;                                                        end
      `OP_JMP:  begin CTRL_DestRegWrite=1;                                              CTRL_Jump=1;     CTRL_LinkDestReg=1;                  end
      `OP_LI:   begin CTRL_DestRegWrite=1; CTRL_ALU_B=1;      CTRL_ALUOpcode=`ALU_PASS;                                                       end
      `OP_JALR: begin CTRL_DestRegWrite=1; CTRL_ALU_B=1;      CTRL_ALUOpcode=`ALU_ADD;  CTRL_Jump=1;     CTRL_LinkDestReg=1; CTRL_JumpLink=1; end
      `OP_SYS:  begin if (FetchDecode_Instr[11:0] == 12'd1)   CTRL_HALT = 1'b1;                                                               end
      default: ; // unknown opcode → NOP (safe)
    endcase
  end

  // =============================================================================
  // ID/EX PIPELINE REGISTER  (declared here; hazard unit reads DecodeExec_MemRead)
  // =============================================================================
  reg [7:0]  DecodeExec_ProgramCounter;
  reg [2:0]  DecodeExec_DestRegAddr;
  reg [2:0]  DecodeExec_SrcReg1;
  reg [2:0]  DecodeExec_SrcReg2;
  reg [15:0] DecodeExec_SrcReg1_Data;
  reg [15:0] DecodeExec_SrcReg2_Data;
  reg [15:0] DecodeExec_Immediate;
  // control signals carried into EX
  reg        DecodeExec_DestRegWrite;
  reg        DecodeExec_MemRead;
  reg        DecodeExec_MemWrite;
  reg        DecodeExec_Branch;
  reg        DecodeExec_Jump;
  reg        DecodeExec_ALUSrc;
  reg        DecodeExec_MemToReg;
  reg [2:0]  DecodeExec_ALUOpcode;
  reg        DecodeExec_LinkDestReg;
  reg        DecodeExec_NEQBranch;
  reg        DecodeExec_JumpLink;
  reg        DecodeExec_HALT;

  // =============================================================================
  // HAZARD DETECTION  (load-use stall)
  // =============================================================================
  // Triggered when the instruction currently in EX (id_ex) is a LOAD and
  // the instruction currently in ID (if_id) reads the loaded register.
  // Effect: stall PC and IF/ID for 1 cycle, insert NOP bubble into EX.
  // After the stall, the loaded value arrives via MEM/WB forwarding.
  // =============================================================================
  wire stall = DecodeExec_MemRead
            && (DecodeExec_DestRegAddr != 3'd0)
            && (DecodeExec_DestRegAddr == Decode_SrcReg1 || DecodeExec_DestRegAddr == Decode_SrcReg2);

  // =============================================================================
  // EX/MEM PIPELINE REGISTER  (declared early so forwarding unit can see it)
  // =============================================================================
  reg [2:0]  ExecMem_DestReg;
  reg [15:0] ExecMem_ALUResult;
  reg [15:0] ExecMem_SrcReg2_Data;    // forwarded store data (for SW in MEM)
  reg        ExecMem_RegWrite;
  reg        ExecMem_MemRead;
  reg        ExecMem_MemWrite;
  reg        ExecMem_MemToReg;
  reg        ExecMem_HALT;

  // =============================================================================
  // MEM/WB PIPELINE REGISTER
  // =============================================================================
  reg [2:0]  MemWB_DestReg;
  reg [15:0] MemWB_ALUResult;
  reg [15:0] MemWB_MemData;
  reg        MemWB_RegWrite;
  reg        MemWB_MemToReg;
  reg        MemWB_HALT;

  // =============================================================================
  // ─── STAGE 3: EXECUTE (EX) ───────────────────────────────────────────────────
  // =============================================================================
  // Forwarding → operand selection → ALU → branch/jump decision.

  // ── WB result (for forwarding) ────────────────────────────────────────────────
  wire [15:0] WriteBack_Result = MemWB_MemToReg ? MemWB_MemData : MemWB_ALUResult;

  // ── Forwarding unit ───────────────────────────────────────────────────────────
  //
  //   forward_x encoding:
  //     2'b00  no forwarding  →  use value from ID/EX pipeline register
  //     2'b01  MEM/WB stage   →  WriteBack_Result    (2 cycles back)
  //     2'b10  EX/MEM stage   →  ExecMem_ALUResult  (1 cycle back)
  //
  //   EX/MEM takes priority over MEM/WB when both match (closer = fresher).

  wire [1:0] forward_a =
    (ExecMem_RegWrite && ExecMem_DestReg != 3'd0 && ExecMem_DestReg == DecodeExec_SrcReg1) ? 2'b10 :
    (MemWB_RegWrite   && MemWB_DestReg   != 3'd0 && MemWB_DestReg   == DecodeExec_SrcReg1) ? 2'b01 :
    2'b00;

  wire [1:0] forward_b =
    (ExecMem_RegWrite && ExecMem_DestReg != 3'd0 && ExecMem_DestReg == DecodeExec_SrcReg2) ? 2'b10 :
    (MemWB_RegWrite   && MemWB_DestReg   != 3'd0 && MemWB_DestReg   == DecodeExec_SrcReg2) ? 2'b01 :
    2'b00;

  // ── Forwarded operand values ──────────────────────────────────────────────────
  wire [15:0] Exec_Forward_SrcReg1 =
    (forward_a == 2'b10) ? ExecMem_ALUResult :
    (forward_a == 2'b01) ? WriteBack_Result  :
                           DecodeExec_SrcReg1_Data;

  wire [15:0] Exec_Forward_SrcReg2 =
    (forward_b == 2'b10) ? ExecMem_ALUResult :
    (forward_b == 2'b01) ? WriteBack_Result  :
                           DecodeExec_SrcReg2_Data;

  // ── ALU inputs ────────────────────────────────────────────────────────────────
  wire [15:0] ALU_A = Exec_Forward_SrcReg1;
  wire [15:0] ALU_B = DecodeExec_ALUSrc ? DecodeExec_Immediate : Exec_Forward_SrcReg2;
  //                                      ^immediate             ^register

  // ── ALU ───────────────────────────────────────────────────────────────────────
  wire [15:0] ALU_Result;
  wire        ALU_ZeroFlag;

  alu u_alu (
    .a      (ALU_A),
    .b      (ALU_B),
    .op     (DecodeExec_ALUOpcode),
    .result (ALU_Result),
    .zero   (ALU_ZeroFlag)
  );

  // ── Branch / jump decision ────────────────────────────────────────────────────
  //
  //   For branches (BEQ/BNE): the ALU computes rs1 - rs2.
  //     BEQ → branch if result == 0  (ALU_ZeroFlag && !DecodeExec_NEQBranch)
  //     BNE → branch if result != 0  (!ALU_ZeroFlag && DecodeExec_NEQBranch)
  //
  //   For unconditional jumps (JMP, JALR): always taken.

  wire branch_taken = DecodeExec_Branch && (DecodeExec_NEQBranch ? !ALU_ZeroFlag : ALU_ZeroFlag);
  wire do_jump      = DecodeExec_Jump || branch_taken;

  // When a branch or jump resolves in EX, we must flush the 2 instructions
  // that were incorrectly fetched into IF and ID behind the branch.
  wire flush = do_jump;

  // ── Branch/jump target address ────────────────────────────────────────────────
  //
  //   BEQ / BNE / JMP  →  (PC_of_branch + 1) + sext(imm)
  //   JALR             →  rs1 + sext(imm6)
  //
  // All targets are 8-bit (word address into 256-word memory).
  wire [7:0] Exec_BranchTarget =
    DecodeExec_JumpLink ? (Exec_Forward_SrcReg1[7:0] + DecodeExec_Immediate[7:0]) :
                          (DecodeExec_ProgramCounter + 8'd1  + DecodeExec_Immediate[7:0]);

  // ── Link value: return address for JMP/JALR ───────────────────────────────────
  // PC+1 zero-extended to 16 bits (word address of instruction after the jump).
  wire [15:0] Exec_LinkVal = {8'h0, DecodeExec_ProgramCounter + 8'd1};

  // ── Result sent to EX/MEM ─────────────────────────────────────────────────────
  // For link instructions (JMP/JALR): write PC+1 to rd.
  // For all others: write ALU result.
  wire [15:0] Exec_Result = DecodeExec_LinkDestReg ? Exec_LinkVal : ALU_Result;

  // =============================================================================
  // ─── STAGE 4: MEMORY ACCESS (MEM) ────────────────────────────────────────────
  // =============================================================================
  // Data memory is accessed combinationally (async read).
  // Write (SW) is controlled by DataMem_WriteEnable; the memory latches on the rising edge.
  // Read data (LW) is available combinationally and latched into MEM/WB.

  assign DataMem_Addr         = ExecMem_ALUResult[7:0];   // effective address from ALU
  assign DataMem_WriteData    = ExecMem_SrcReg2_Data;     // forwarded store data
  assign DataMem_WriteEnable  = ExecMem_MemWrite;

  // =============================================================================
  // ─── STAGE 5: WRITE BACK (WB) — wired outputs for register file & ID fwd ────
  // =============================================================================
  assign WriteBack_WriteEnable  = MemWB_RegWrite && (MemWB_DestReg != 3'd0) && !halted;
  assign WriteBack_WriteRegAddr = MemWB_DestReg;
  assign WriteBack_WriteData    = WriteBack_Result;    // WriteBack_Result defined earlier

  // =============================================================================
  // ALL PIPELINE REGISTERS — single synchronous always block
  // =============================================================================
  // Writing all registers in one always block ensures a single source of truth
  // for the reset condition and makes the priority of stall/flush explicit.
  // =============================================================================
  always @(posedge clk) begin
    if (!resetn) begin
      // ── Reset every pipeline register and the PC ──────────────────────
      programCounter              <= 8'h00;
      halted                      <= 1'b0;

      FetchDecode_ProgramCounter  <= 8'h00;
      FetchDecode_Instr           <= `NOP_INSTR;

      DecodeExec_ProgramCounter   <= 8'h00;
      DecodeExec_DestRegAddr      <= 3'd0;   DecodeExec_SrcReg1       <= 3'd0;
      DecodeExec_SrcReg2          <= 3'd0;   DecodeExec_SrcReg1_Data  <= 16'h0;
      DecodeExec_SrcReg2_Data     <= 16'h0;  DecodeExec_Immediate     <= 16'h0;
      DecodeExec_DestRegWrite     <= 1'b0;   DecodeExec_MemRead       <= 1'b0;
      DecodeExec_MemWrite         <= 1'b0;   DecodeExec_Branch        <= 1'b0;
      DecodeExec_Jump             <= 1'b0;   DecodeExec_ALUSrc        <= 1'b0;
      DecodeExec_MemToReg         <= 1'b0;   DecodeExec_ALUOpcode     <= `ALU_ADD;
      DecodeExec_LinkDestReg      <= 1'b0;   DecodeExec_NEQBranch     <= 1'b0;
      DecodeExec_JumpLink         <= 1'b0;   DecodeExec_HALT          <= 1'b0;

      ExecMem_DestReg             <= 3'd0;   ExecMem_ALUResult        <= 16'h0;
      ExecMem_SrcReg2_Data        <= 16'h0;  ExecMem_RegWrite         <= 1'b0;
      ExecMem_MemRead             <= 1'b0;   ExecMem_MemWrite         <= 1'b0;
      ExecMem_MemToReg            <= 1'b0;   ExecMem_HALT             <= 1'b0;

      MemWB_DestReg               <= 3'd0;   MemWB_ALUResult          <= 16'h0;
      MemWB_MemData               <= 16'h0;  MemWB_RegWrite           <= 1'b0;
      MemWB_MemToReg              <= 1'b0;   MemWB_HALT               <= 1'b0;

    end else if (halted) begin
      // ── CPU halted: freeze all state, assert halted output ─────────────
      // Nothing changes. The testbench will see halted=1 and stop.

    end else begin
      // ══════════════════════════════════════════════════════════════════
      // WRITE BACK (stage 5)
      // ══════════════════════════════════════════════════════════════════
      if (WriteBack_WriteEnable)
        regFile[WriteBack_WriteRegAddr] <= WriteBack_WriteData;

      halted <= MemWB_HALT;   // becomes 1 when HALT retires

      // ══════════════════════════════════════════════════════════════════
      // MEM/WB update  (captures MEM-stage outputs)
      // ══════════════════════════════════════════════════════════════════
      MemWB_DestReg               <= ExecMem_DestReg;
      MemWB_ALUResult             <= ExecMem_ALUResult;
      MemWB_MemData               <= dmem_rdata;        // combinational read from dmem
      MemWB_RegWrite              <= ExecMem_RegWrite;
      MemWB_MemToReg              <= ExecMem_MemToReg;
      MemWB_HALT                  <= ExecMem_HALT;

      // ══════════════════════════════════════════════════════════════════
      // EX/MEM update  (captures EX-stage outputs)
      // ══════════════════════════════════════════════════════════════════
      ExecMem_DestReg             <= DecodeExec_DestRegAddr;
      ExecMem_ALUResult           <= Exec_Result;
      ExecMem_SrcReg2_Data        <= Exec_Forward_SrcReg2;        // forwarded store data
      ExecMem_RegWrite            <= DecodeExec_DestRegWrite;
      ExecMem_MemRead             <= DecodeExec_MemRead;
      ExecMem_MemWrite            <= DecodeExec_MemWrite;
      ExecMem_MemToReg            <= DecodeExec_MemToReg;
      ExecMem_HALT                <= DecodeExec_HALT;

      // ══════════════════════════════════════════════════════════════════
      // ID/EX update  (captures ID-stage decoded values)
      // flush OR stall → insert NOP bubble (zero all control signals)
      // ══════════════════════════════════════════════════════════════════
      if (flush || stall) begin
        // Bubble: preserve addresses for debugging but zero all control
        DecodeExec_ProgramCounter <= FetchDecode_ProgramCounter;
        DecodeExec_DestRegAddr    <= 3'd0;     DecodeExec_SrcReg1       <= 3'd0;
        DecodeExec_SrcReg2        <= 3'd0;     DecodeExec_SrcReg1_Data  <= 16'h0;
        DecodeExec_SrcReg2_Data   <= 16'h0;    DecodeExec_Immediate     <= 16'h0;
        DecodeExec_DestRegWrite   <= 1'b0;     DecodeExec_MemRead       <= 1'b0;
        DecodeExec_MemWrite       <= 1'b0;     DecodeExec_Branch        <= 1'b0;
        DecodeExec_Jump           <= 1'b0;     DecodeExec_ALUSrc        <= 1'b0;
        DecodeExec_MemToReg       <= 1'b0;     DecodeExec_ALUOpcode     <= `ALU_ADD;
        DecodeExec_LinkDestReg    <= 1'b0;     DecodeExec_NEQBranch     <= 1'b0;
        DecodeExec_JumpLink       <= 1'b0;     DecodeExec_HALT          <= 1'b0;
      end else begin
        DecodeExec_ProgramCounter <= FetchDecode_ProgramCounter;
        DecodeExec_DestRegAddr    <= Decode_DestReg;
        DecodeExec_SrcReg1        <= Decode_SrcReg1;
        DecodeExec_SrcReg2        <= Decode_SrcReg2;
        DecodeExec_SrcReg1_Data   <= Decode_SrcReg1_Data;
        DecodeExec_SrcReg2_Data   <= Decode_SrcReg2_Data;
        DecodeExec_Immediate      <= Decode_imm;
        DecodeExec_DestRegWrite   <= CTRL_DestRegWrite;
        DecodeExec_MemRead        <= CTRL_MemRead;
        DecodeExec_MemWrite       <= CTRL_MemWrite;
        DecodeExec_Branch         <= CTRL_Branch;
        DecodeExec_Jump           <= CTRL_Jump;
        DecodeExec_ALUSrc         <= CTRL_ALU_B;
        DecodeExec_MemToReg       <= CTRL_MemToReg;
        DecodeExec_ALUOpcode      <= CTRL_ALUOpcode;
        DecodeExec_LinkDestReg    <= CTRL_LinkDestReg;
        DecodeExec_NEQBranch      <= CTRL_BranchFlag;
        DecodeExec_JumpLink       <= CTRL_JumpLink;
        DecodeExec_HALT           <= CTRL_HALT;
      end

      // ══════════════════════════════════════════════════════════════════
      // IF/ID update + PC advance
      // ══════════════════════════════════════════════════════════════════
      if (flush) begin
        // Branch/jump taken: discard incorrectly-fetched instruction
        FetchDecode_ProgramCounter <= programCounter;
        FetchDecode_Instr          <= `NOP_INSTR;
        // Redirect PC to branch target
        programCounter             <= Exec_BranchTarget;
      end else if (!stall) begin
        // Normal advance
        FetchDecode_ProgramCounter <= programCounter;
        FetchDecode_Instr          <= imem_data;
        programCounter             <= programCounter + 8'd1;
      end
      // stall (no flush): IF/ID and PC hold their values (no assignment)
    end // else (not reset, not halted)
  end
endmodule
