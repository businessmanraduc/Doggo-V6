`include "isa.vh"
// =============================================================================
// PHANTOM-32  ──  M-Mode CSR Register File
// =============================================================================
// Implements the mandatory Machine-mode Control and Status Registers required
// by the RISC-V privileged specification for a minimal M-mode-only core.
//
// Access model:
//   All CSR reads and writes happen in the MA stage (Stage V).
//   Reads  are combinational: rd_data is valid the same cycle rd_addr is set.
//   Writes are synchronous:   the new value is latched on the rising edge.
//   The read-modify-write (CSRRS / CSRRC) is handled externally by the MA
//   stage: it reads rd_data, computes the modified value, then drives it back
//   on wr_data with wr_en asserted in the same cycle.  Because the read is
//   combinational and the write is synchronous, there is no conflict.
//
// CSR categories implemented:
//
//   Read-Write (stored in flip-flops):
//     mstatus   0x300  — MIE, MPIE, MPP (other bits reserved/hardwired)
//     mie       0x304  — MSIE, MTIE, MEIE
//     mtvec     0x305  — base[31:2] + mode[1:0]  (mode: 00=direct, 01=vectored)
//     mscratch  0x340  — scratch register for trap handlers
//     mepc      0x341  — exception PC (bits [1:0] always read as 00 — halfword aligned)
//     mcause    0x342  — interrupt bit [31] + exception code [30:0]
//     mtval     0x343  — faulting address or instruction word
//     mip       0x344  — interrupt pending (MSIP/MTIP/MEIP; mostly read-only
//                        in Phase 1 since we have no interrupt sources yet;
//                        kept writable for future CLINT integration)
//
//   Read-Only (hardwired constants, no flip-flops consumed):
//     mvendorid 0xF11  — 0x00000000  (non-commercial)
//     marchid   0xF12  — 0x00000000
//     mimpid    0xF13  — 0x00000001  (PHANTOM-32 revision 1)
//     mhartid   0xF14  — 0x00000000  (single hart)
//     misa      0x301  — 0x40000104  (MXL=01, extensions I+C)
//
// Trap entry / MRET:
//   The MA stage drives separate trap_en and mret_en strobes to update the
//   CSR state that the pipeline cannot compute through the normal
//   read-modify-write path (because it happens atomically with the pipeline
//   flush, not as a visible instruction result):
//     trap_en  → mepc, mcause, mtval written; mstatus.MPIE←MIE, MIE←0
//     mret_en  → mstatus.MIE←MPIE, MPIE←1
//
// Reserved-bit masking:
//   Bits that are defined as WARL (Write Any, Read Legal) or hardwired zero
//   in the spec are masked on write so they always read back as zero,
//   regardless of what the programmer writes to them.  The masks are defined
//   as local parameters below, adjacent to each register.
// =============================================================================
module csr_regfile (
  input  wire        clk,
  input  wire        resetn,         // active-low synchronous reset

  // ── Normal CSR read/write port (from MA stage, CSRRW/CSRRS/CSRRC*) ───────
  input  wire [11:0] rd_addr,        // CSR address to read
  output reg  [31:0] rd_data,        // value at rd_addr (combinational)

  input  wire [11:0] wr_addr,        // CSR address to write (may differ from rd_addr
                                     // only in theory; in practice they are always equal
                                     // for a single CSR instruction)
  input  wire [31:0] wr_data,        // new value to write (after RMW by MA stage)
  input  wire        wr_en,          // write enable (0 for CSRRS/CSRRC with rs1=x0)

  // ── Trap entry strobe (from MA stage when StageV_isTrap = 1) ─────────────
  input  wire        trap_en,        // 1 = latch trap state this cycle
  input  wire [31:0] trap_mepc,      // PC of the trapping instruction → mepc
  input  wire [31:0] trap_mcause,    // {1'b0, 27'h0, cause[3:0]}      → mcause
  input  wire [31:0] trap_mtval,     // faulting address or instr word → mtval

  // ── MRET strobe (from MA stage when StageV_isMRET = 1) ───────────────────
  input  wire        mret_en,        // 1 = restore mstatus from saved fields

  // ── Direct CSR outputs consumed by the pipeline (not via rd_data) ─────────
  // These are wired directly from the flip-flops so the pipeline can read
  // them combinationally without going through the address-decode mux.
  output wire [31:0] out_mstatus,    // full mstatus word (pipeline checks MIE)
  output wire [31:0] out_mtvec,      // trap vector base + mode
  output wire [31:0] out_mepc        // saved exception PC (for MRET)
);

  // =============================================================================
  // ── LOCAL PARAMETERS: WARL MASKS ─────────────────────────────────────────────
  // =============================================================================
  // Each mask defines which bits of a CSR are actually writable.
  // Bits outside the mask are forced to zero on every write and reset.
  //
  // mstatus (RV32 M-only subset):
  //   bit  3  MIE   — Machine Interrupt Enable
  //   bit  7  MPIE  — Machine Previous Interrupt Enable
  //   bits 12:11 MPP — Previous Privilege Mode
  //   All other bits are reserved and read as zero.
  // =============================================================================
  localparam MSTATUS_MASK  = 32'h0000_1888;  // bits 12:11 (MPP) + 7 (MPIE) + 3 (MIE)
  localparam MIE_MASK      = 32'h0000_0888;  // bits 11 (MEIE) + 7 (MTIE) + 3 (MSIE)
  localparam MTVEC_MASK    = 32'hFFFF_FFFD;  // all bits writable EXCEPT bit 1
                                              // (mode field: only 00 and 01 are legal;
                                              //  bit 1 forced to 0 enforces this)
  localparam MEPC_MASK     = 32'hFFFF_FFFE;  // bit 0 always 0 (halfword alignment)
  localparam MCAUSE_MASK   = 32'h8000_000F;  // bit 31 (interrupt) + bits 3:0 (code)
  localparam MTVAL_MASK    = 32'hFFFF_FFFF;  // fully writable
  localparam MSCRATCH_MASK = 32'hFFFF_FFFF;  // fully writable
  localparam MIP_MASK      = 32'h0000_0888;  // same writable bits as MIE


  // =============================================================================
  // ── CSR FLIP-FLOP STORAGE ────────────────────────────────────────────────────
  // =============================================================================
  reg [31:0] r_mstatus;
  reg [31:0] r_mie;
  reg [31:0] r_mtvec;
  reg [31:0] r_mscratch;
  reg [31:0] r_mepc;
  reg [31:0] r_mcause;
  reg [31:0] r_mtval;
  reg [31:0] r_mip;


  // =============================================================================
  // ── DIRECT OUTPUTS (combinational, wired straight from flip-flops) ───────────
  // =============================================================================
  assign out_mstatus = r_mstatus;
  assign out_mtvec   = r_mtvec;
  assign out_mepc    = r_mepc;


  // =============================================================================
  // ── SYNCHRONOUS WRITE / RESET / TRAP-ENTRY / MRET ────────────────────────────
  // =============================================================================
  // Priority (high to low) within a single rising edge:
  //   1. Reset:      all CSRs return to their defined reset values
  //   2. Trap entry: mepc, mcause, mtval, and mstatus are updated atomically
  //   3. MRET:       mstatus MIE/MPIE fields are restored
  //   4. Normal write: a CSRRW/CSRRS/CSRRC instruction updates one CSR
  // =============================================================================
  always @(posedge clk) begin
    if (!resetn) begin
      // ── Reset: all writable CSRs to their architecturally defined reset values
      // mstatus: MIE=0 on reset (interrupts disabled), MPIE=0, MPP=11 (M-mode)
      r_mstatus  <= 32'h0000_1800;   // MPP = 2'b11, all interrupt enables off
      r_mie      <= 32'h0;
      r_mtvec    <= 32'h0;           // default trap vector = 0x00000000, direct mode
      r_mscratch <= 32'h0;
      r_mepc     <= 32'h0;
      r_mcause   <= 32'h0;
      r_mtval    <= 32'h0;
      r_mip      <= 32'h0;

    end else if (trap_en) begin
      // ── Trap entry: update mepc, mcause, mtval, and mstatus atomically ────────
      // commit the trap state so the handler can read it via CSR instructions.
      r_mepc    <= trap_mepc   & MEPC_MASK;    // save faulting PC (halfword-align)
      r_mcause  <= trap_mcause & MCAUSE_MASK;  // save cause code
      r_mtval   <= trap_mtval  & MTVAL_MASK;   // save faulting address / instr word
      // mstatus: MPIE ← MIE,  MIE ← 0  (disable interrupts during handler)
      r_mstatus <= (r_mstatus & ~MSTATUS_MASK) // clear all writable bits
                 | ((r_mstatus & 32'h8) << 4)  // MPIE ← old MIE  (bit3→bit7)
                 | 32'h0000_1800;              // MPP = 11, MIE = 0

    end else if (mret_en) begin
      // ── MRET: restore mstatus MIE ← MPIE, MPIE ← 1 ───────────────────────────
      r_mstatus <= (r_mstatus & ~MSTATUS_MASK) // clear all writable bits
                 | ((r_mstatus & 32'h80) >> 4) // MIE  ← old MPIE (bit7→bit3)
                 | 32'h0000_1880;              // MPP = 11, MPIE = 1

    end else if (wr_en) begin
      // ── Normal CSR write: one register updated by a CSR* instruction ──────────
      // We apply the WARL mask here so reserved bits can never be set.
      case (wr_addr)
        `CSR_MSTATUS:  r_mstatus  <= wr_data & MSTATUS_MASK;
        `CSR_MIE:      r_mie      <= wr_data & MIE_MASK;
        `CSR_MTVEC:    r_mtvec    <= wr_data & MTVEC_MASK;
        `CSR_MSCRATCH: r_mscratch <= wr_data & MSCRATCH_MASK;
        `CSR_MEPC:     r_mepc     <= wr_data & MEPC_MASK;
        `CSR_MCAUSE:   r_mcause   <= wr_data & MCAUSE_MASK;
        `CSR_MTVAL:    r_mtval    <= wr_data & MTVAL_MASK;
        `CSR_MIP:      r_mip      <= wr_data & MIP_MASK;
        // Writes to read-only CSRs (misa, mvendorid, marchid, mimpid, mhartid)
        // are silently ignored — the spec defines these as read-only and
        // writing them must not cause an illegal instruction exception.
        default: ; // no-op
      endcase
    end
  end


  // =============================================================================
  // ── COMBINATIONAL READ (address decode mux) ──────────────────────────────────
  // =============================================================================
  // The read happens in the same cycle as the MA stage presents rd_addr.
  // Note: the read returns the value BEFORE any write that happens this same
  // cycle (since the write is synchronous).  This is exactly the RISC-V
  // specification's required behaviour for CSR instructions: the old value
  // is written to rd, and the new value is written to the CSR register.
  // =============================================================================
  always @(*) begin
    case (rd_addr)
      // ── Read-write CSRs ──────────────────────────────────────────────────────
      `CSR_MSTATUS:  rd_data = r_mstatus;
      `CSR_MIE:      rd_data = r_mie;
      `CSR_MTVEC:    rd_data = r_mtvec;
      `CSR_MSCRATCH: rd_data = r_mscratch;
      `CSR_MEPC:     rd_data = r_mepc;
      `CSR_MCAUSE:   rd_data = r_mcause;
      `CSR_MTVAL:    rd_data = r_mtval;
      `CSR_MIP:      rd_data = r_mip;
      // ── Read-only CSRs (hardwired constants, zero flip-flops) ────────────────
      `CSR_MISA:     rd_data = `CSR_VAL_MISA;
      `CSR_MVENDORID:rd_data = `CSR_VAL_MVENDORID;
      `CSR_MARCHID:  rd_data = `CSR_VAL_MARCHID;
      `CSR_MIMPID:   rd_data = `CSR_VAL_MIMPID;
      `CSR_MHARTID:  rd_data = `CSR_VAL_MHARTID;
      // ── Unimplemented CSR address ────────────────────────────────────────────
      // The spec says accessing an unimplemented CSR should raise an illegal
      // instruction exception.  We return 0 here; the decoder in ID is
      // responsible for flagging unrecognised CSR addresses as illegal before
      // the access reaches this module.
      default:       rd_data = 32'h0;
    endcase
  end
endmodule
