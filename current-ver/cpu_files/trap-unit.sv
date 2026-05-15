`include "isa.vh"
// =============================================================================
// PHANTOM-32  ──  Trap Unit  (MA Stage)
// =============================================================================
// Purely combinational exception detector and cause encoder.  Sits in the MA
// stage where all required data (effective address, decoded flags) is finally
// available.  Produces four outputs fed directly into csr_regfile's trap
// interface, plus trap_en and mret_en which cpu.v also uses for PC redirection.
//
// ── Exceptions handled ───────────────────────────────────────────────────────
//   EBREAK             mcause = 3   mtval = faulting PC
//   Illegal instr      mcause = 2   mtval = raw instruction word
//   ECALL (M-mode)     mcause = 11  mtval = 0
//   Load misalignment  mcause = 4   mtval = effective address
//   Store misalignment mcause = 6   mtval = effective address
//
// ── Exception priority (highest → lowest) ────────────────────────────────────
//   1. EBREAK          - highest; debug takes precedence over decode errors
//   2. Illegal instr   - before ECALL so a malformed ECALL is flagged correctly
//   3. ECALL           - environment call
//   4. Load misalign   - address fault after decode is clean
//   5. Store misalign  - same
// =============================================================================
module trap_unit (
  // ── MA-stage pipeline register contents ───────────────────────────────────
  input  logic [31:0] ma_pc,          // PC of instruction in MA                (→ mepc)
  input  logic [31:0] ma_instr,       // raw instruction word                   (→ mtval for illegal)
  input  logic [31:0] ma_alu_result,  // effective address from ALU             (→ mtval for misalign)
  input  logic        ma_mem_read,    // 1 = instruction is a load
  input  logic        ma_mem_write,   // 1 = instruction is a store
  input  logic [2:0]  ma_mem_width,   // load / store width (`WIDTH_* constants)

  // ── Decoded exception flags (from control_unit, pipelined to MA) ──────────
  input  logic        ma_is_ecall,    // ECALL instruction
  input  logic        ma_is_ebreak,   // EBREAK / C.EBREAK instruction
  input  logic        ma_is_illegal,  // unrecognised or reserved encoding
  input  logic        ma_is_mret,     // MRET return-from-trap instruction

  // ── Outputs to csr_regfile ─────────────────────────────────────────────────
  output logic        trap_en,        // 1 = latch mepc/mcause/mtval, update mstatus
  output logic [31:0] trap_mepc,      // PC to save in mepc
  output logic [31:0] trap_mcause,    // exception cause word (bit31=0, lower=code)
  output logic [31:0] trap_mtval,     // auxiliary trap value

  // ── Return-from-trap ──────────────────────────────────────────────────────
  output logic        mret_en         // 1 = restore mstatus.MIE from MPIE, redirect to mepc
);

  // ===========================================================================
  // MISALIGNMENT DETECTION
  // ===========================================================================
  // Loads: LH/LHU require addr[0]=0; LW requires addr[1:0]=00.  LB/LBU are
  //        always aligned (byte granularity).
  // Stores: SH requires addr[0]=0; SW requires addr[1:0]=00.  SB always OK.
  //         There is no unsigned store, so WIDTH_HU cannot appear on the write
  //         path - WIDTH_H covers both SH cases.
  // ===========================================================================
  logic load_misalign;
  assign load_misalign  = ma_mem_read && (
    ((ma_mem_width == `WIDTH_H || ma_mem_width == `WIDTH_HU) && ma_alu_result[0]) ||
     (ma_mem_width == `WIDTH_W && |ma_alu_result[1:0])
  );
  logic store_misalign;
  assign store_misalign = ma_mem_write && (
     (ma_mem_width == `WIDTH_H && ma_alu_result[0]) ||
     (ma_mem_width == `WIDTH_W && |ma_alu_result[1:0])
  );


  // ===========================================================================
  // TRAP ENABLE
  // ===========================================================================
  assign trap_en = ma_is_ebreak  | ma_is_illegal  | ma_is_ecall 
                 | load_misalign | store_misalign ;
  assign mret_en = ma_is_mret;


  // ===========================================================================
  // TRAP PC  (mepc)
  // ===========================================================================
  // Always the PC of the offending instruction itself - the synchronous
  // exceptions handled here are all "precise" per the RISC-V spec.
  // ===========================================================================
  assign trap_mepc = ma_pc;


  // ===========================================================================
  // CAUSE ENCODING  (mcause)
  // ===========================================================================
  // Bit 31 = 0 for synchronous exceptions (no interrupts in Phase 1).
  // Lower 4 bits carry the `TRAP_* code from isa.vh; upper 27 bits are zero.
  // ===========================================================================
  assign trap_mcause =
    ma_is_ebreak     ? {28'd0, `TRAP_BREAKPOINT}     :
    ma_is_illegal    ? {28'd0, `TRAP_ILLEGAL_INSTR}  :
    ma_is_ecall      ? {28'd0, `TRAP_ECALL_M}        :
    load_misalign    ? {28'd0, `TRAP_LOAD_MISALIGN}  :
    store_misalign   ? {28'd0, `TRAP_STORE_MISALIGN} :
    /*no cause*/        32'd0;


  // ===========================================================================
  // AUXILIARY TRAP VALUE  (mtval)
  // ===========================================================================
  // EBREAK:   faulting PC - more useful than 0 for a debugger
  // Illegal:  raw instruction word - lets the trap handler identify the encoding
  // ECALL:    0 (spec says zero or unspecified; we choose zero)
  // Misalign: offending effective address - required by spec for precise traps
  // ===========================================================================
  assign trap_mtval =
    ma_is_ebreak   ? ma_pc         :
    ma_is_illegal  ? ma_instr      :
    load_misalign  ? ma_alu_result :
    store_misalign ? ma_alu_result :
    /*no cause*/     32'd0;

endmodule
