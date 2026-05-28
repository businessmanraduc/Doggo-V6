`include "isa.vh"
// =============================================================================
// PHANTOM-32  ──  Interrupt Unit  (MA Stage)
// =============================================================================
// Purely combinational. Decides whether an enabled, pending M-mode interrupt
// should be taken at the instruction currently in MA, and priority-encodes its
// cause. The interrupt is injected as a trap (combined with trap_unit's output
// in phantom_core), so it reuses the existing flush + mtvec redirect + mstatus
// update machinery - the interrupted MA instruction simply does not commit.
//
// Priority (RISC-V privileged spec): MEI > MSI > MTI.
// A synchronous exception on the same MA instruction always wins, so irq_take
// is suppressed while sync_trap is asserted.
// =============================================================================
module interrupt_unit (
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:0] mie,          // machine interrupt-enable  CSR (only bits 3/7/11 used)
  input  logic [31:0] mip,          // machine interrupt-pending CSR (only bits 3/7/11 used)
  /* verilator lint_on  UNUSEDSIGNAL */
  input  logic        mstatus_mie,  // mstatus.MIE global enable (bit 3)
  input  logic        ma_valid,     // 1 = MA holds a real, committing instruction
  input  logic        sync_trap,    // 1 = a synchronous exception is firing now

  output logic        irq_take,     // 1 = take an interrupt at the MA instruction
  output logic [3:0]  irq_cause     // MEI=11 / MSI=3 / MTI=7
);

  // ── Per-source enabled-and-pending ──────────────────────────────────────────
  logic meip; assign meip = mie[`IRQ_MEI] && mip[`IRQ_MEI];
  logic msip; assign msip = mie[`IRQ_MSI] && mip[`IRQ_MSI];
  logic mtip; assign mtip = mie[`IRQ_MTI] && mip[`IRQ_MTI];

  // ── Global gate ─────────────────────────────────────────────────────────────
  assign irq_take = mstatus_mie && (meip || msip || mtip) && ma_valid && !sync_trap;

  // ── Priority encode: MEI > MSI > MTI ────────────────────────────────────────
  always_comb begin
    if      (meip) irq_cause = 4'(`IRQ_MEI);
    else if (msip) irq_cause = 4'(`IRQ_MSI);
    else           irq_cause = 4'(`IRQ_MTI);
  end

endmodule

