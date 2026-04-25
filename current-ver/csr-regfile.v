`include "isa.vh"
// =============================================================================
// PHANTOM-32  ──  M-Mode CSR Register File
// =============================================================================
// Implements mandatory Machine-mode Control and Status Registers for an
// M-mode-only core.
//
// Access model:
//   Reads:  combinational (rd_data valid same cycle as rd_addr)
//   Writes: synchronous   (latched on rising edge)
//   Read-modify-write (CSRRS/CSRRC) handled by MA stage externally
//
// Write-before-read forwarding:
//   If wr_en=1 and wr_addr matches rd_addr in same cycle, the incoming
//   wr_data is returned immediately on rd_data (before next clock edge).
//   This eliminates MA→ID forwarding hazards for CSR accesses.
//
// CSR categories:
//   Read-Write (flip-flops):  mstatus, mie, mtvec, mscratch, mepc, mcause, mtval, mip
//   Read-Only (hardwired):    mvendorid, marchid, mimpid, mhartid, misa
//
// Trap handling:
//   trap_en → mepc/mcause/mtval written; mstatus.MPIE←MIE, MIE←0
//   mret_en → mstatus.MIE←MPIE, MPIE←1
//
// Reserved bits masked via WARL (Write Any, Read Legal) masks.
// =============================================================================
module csr_regfile (
  input  wire        clk,
  input  wire        resetn,         // active-low synchronous reset

  // ── Normal CSR read/write (from MA stage) ────────────────────────────────
  input  wire [11:0] rd_addr,        // CSR address to read
  output reg  [31:0] rd_data,        // value at rd_addr (combinational)

  input  wire [11:0] wr_addr,        // CSR address to write
  input  wire [31:0] wr_data,        // new value (after RMW by MA stage)
  input  wire        wr_en,          // write enable

  // ── Trap entry (from MA stage when trap occurs) ──────────────────────────
  input  wire        trap_en,        // 1 = latch trap state this cycle
  input  wire [31:0] trap_mepc,      // PC of trapping instruction → mepc
  input  wire [31:0] trap_mcause,    // exception code → mcause
  input  wire [31:0] trap_mtval,     // faulting address or instruction → mtval

  // ── MRET (from MA stage) ─────────────────────────────────────────────────
  input  wire        mret_en,        // 1 = restore mstatus from saved fields

  // ── Direct outputs (wired from flip-flops, bypassing rd_data mux) ────────
  output wire [31:0] out_mstatus,    // full mstatus word (pipeline checks MIE)
  output wire [31:0] out_mtvec,      // trap vector base + mode
  output wire [31:0] out_mepc        // saved exception PC (for MRET target)
);

  // =============================================================================
  // WARL MASKS
  // =============================================================================
  // Define which bits of each CSR are writable. Reserved bits forced to zero.
  // =============================================================================
  localparam MSTATUS_MASK  = 32'h0000_1888;  // bits 12:11 (MPP) + 7 (MPIE) + 3 (MIE)
  localparam MIE_MASK      = 32'h0000_0888;  // bits 11 (MEIE) + 7 (MTIE) + 3 (MSIE)
  localparam MTVEC_MASK    = 32'hFFFF_FFFD;  // all except bit 1 (enforces mode ∈ {00,01})
  localparam MEPC_MASK     = 32'hFFFF_FFFE;  // bit 0 always 0 (halfword alignment)
  localparam MCAUSE_MASK   = 32'h8000_000F;  // bit 31 (interrupt) + bits 3:0 (code)
  localparam MTVAL_MASK    = 32'hFFFF_FFFF;  // fully writable
  localparam MSCRATCH_MASK = 32'hFFFF_FFFF;  // fully writable
  localparam MIP_MASK      = 32'h0000_0888;  // same writable bits as MIE


  // =============================================================================
  // CSR FLIP-FLOP STORAGE
  // =============================================================================
  reg [31:0] r_mstatus;   // Machine status: MIE, MPIE, MPP
  reg [31:0] r_mie;       // Machine interrupt enable: MEIE, MTIE, MSIE
  reg [31:0] r_mtvec;     // Trap vector base address + mode
  reg [31:0] r_mscratch;  // Scratch register for trap handler
  reg [31:0] r_mepc;      // Exception program counter (saved PC)
  reg [31:0] r_mcause;    // Exception cause code
  reg [31:0] r_mtval;     // Trap value: faulting address or instruction
  reg [31:0] r_mip;       // Interrupt pending: MEIP, MTIP, MSIP


  // =============================================================================
  // DIRECT OUTPUTS
  // =============================================================================
  assign out_mstatus = r_mstatus;
  assign out_mtvec   = r_mtvec;
  assign out_mepc    = r_mepc;


  // =============================================================================
  // SYNCHRONOUS WRITE / RESET / TRAP / MRET
  // =============================================================================
  // Priority (high to low):
  //   1. Reset      → all CSRs to architecturally defined values
  //   2. Trap entry → mepc, mcause, mtval, mstatus updated atomically
  //   3. MRET       → mstatus MIE/MPIE fields restored
  //   4. Normal CSR write
  // =============================================================================
  always @(posedge clk) begin
    if (!resetn) begin
      r_mstatus  <= 32'h0000_1800;   // MPP=11 (M-mode), MIE=0, MPIE=0
      r_mie      <= 32'h0;
      r_mtvec    <= 32'h0;           // trap vector = 0x00000000, direct mode
      r_mscratch <= 32'h0;
      r_mepc     <= 32'h0;
      r_mcause   <= 32'h0;
      r_mtval    <= 32'h0;
      r_mip      <= 32'h0;

    end else if (trap_en) begin
      // ── Trap entry ─────────────────────────────────────────────────────────
      r_mepc    <= trap_mepc   & MEPC_MASK;
      r_mcause  <= trap_mcause & MCAUSE_MASK;
      r_mtval   <= trap_mtval  & MTVAL_MASK;
      r_mstatus <= (r_mstatus & ~MSTATUS_MASK)      // clear writable bits
                 | ((r_mstatus & 32'h8) << 4)       // MPIE ← MIE (bit3→bit7)
                 | 32'h0000_1800;                   // MPP=11, MIE=0

    end else if (mret_en) begin
      // ── MRET ──────────────────────────────────────────────────────────────
      r_mstatus <= (r_mstatus & ~MSTATUS_MASK)      // clear writable bits
                 | ((r_mstatus & 32'h80) >> 4)      // MIE ← MPIE (bit7→bit3)
                 | 32'h0000_1880;                   // MPP=11, MPIE=1

    end else if (wr_en) begin
      // ── Normal CSR write ───────────────────────────────────────────────────
      case (wr_addr)
        `CSR_MSTATUS:  r_mstatus  <= wr_data & MSTATUS_MASK;
        `CSR_MIE:      r_mie      <= wr_data & MIE_MASK;
        `CSR_MTVEC:    r_mtvec    <= wr_data & MTVEC_MASK;
        `CSR_MSCRATCH: r_mscratch <= wr_data & MSCRATCH_MASK;
        `CSR_MEPC:     r_mepc     <= wr_data & MEPC_MASK;
        `CSR_MCAUSE:   r_mcause   <= wr_data & MCAUSE_MASK;
        `CSR_MTVAL:    r_mtval    <= wr_data & MTVAL_MASK;
        `CSR_MIP:      r_mip      <= wr_data & MIP_MASK;
        default: ;  // writes to read-only CSRs silently ignored
      endcase
    end
  end


  // =============================================================================
  // COMBINATIONAL READ
  // =============================================================================
  // If a CSR write is happening this cycle to the same address we're reading,
  // return the incoming wr_data immediately (before it latches on next edge).
  // This eliminates MA→ID forwarding hazards for back-to-back CSR instructions.
  // =============================================================================
  always @(*) begin
    case (rd_addr)
      // ── Read-Write CSRs (with forwarding) ──────────────────────────────────
      `CSR_MSTATUS:   rd_data = (wr_en && wr_addr == `CSR_MSTATUS)  ? wr_data : r_mstatus;
      `CSR_MIE:       rd_data = (wr_en && wr_addr == `CSR_MIE)      ? wr_data : r_mie;
      `CSR_MTVEC:     rd_data = (wr_en && wr_addr == `CSR_MTVEC)    ? wr_data : r_mtvec;
      `CSR_MSCRATCH:  rd_data = (wr_en && wr_addr == `CSR_MSCRATCH) ? wr_data : r_mscratch;
      `CSR_MEPC:      rd_data = (wr_en && wr_addr == `CSR_MEPC)     ? wr_data : r_mepc;
      `CSR_MCAUSE:    rd_data = (wr_en && wr_addr == `CSR_MCAUSE)   ? wr_data : r_mcause;
      `CSR_MTVAL:     rd_data = (wr_en && wr_addr == `CSR_MTVAL)    ? wr_data : r_mtval;
      `CSR_MIP:       rd_data = (wr_en && wr_addr == `CSR_MIP)      ? wr_data : r_mip;

      // ── Read-Only CSRs (no forwarding needed) ───────────────────────────────
      `CSR_MISA:      rd_data = `CSR_VAL_MISA;
      `CSR_MVENDORID: rd_data = `CSR_VAL_MVENDORID;
      `CSR_MARCHID:   rd_data = `CSR_VAL_MARCHID;
      `CSR_MIMPID:    rd_data = `CSR_VAL_MIMPID;
      `CSR_MHARTID:   rd_data = `CSR_VAL_MHARTID;

      default:        rd_data = 32'h0;
    endcase
  end

endmodule
