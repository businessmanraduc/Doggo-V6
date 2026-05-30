.section .text
.global _start

# Result is written to the sentinel 0x8000_1000 (harness prints it + $finish):
#   1 = PASS
#   2 = wrong mcause in handler
#   3 = wrong entry count (re-fired, or never fired)
#
# CLINT:  msip @ 0x8001_0000

_start:
    la      t0, _trap_handler
    csrw    mtvec, t0

    li      s0, 0               # entry counter
    li      s1, 1               # result = optimistic PASS

    li      t0, 0x8             # mie.MSIE = bit 3
    csrw    mie, t0
    li      t0, 0x8             # mstatus.MIE = bit 3 (global enable)
    csrw    mstatus, t0

    li      t0, 0x80010000
    li      t1, 1
    sw      t1, 0(t0)           # msip = 1  -> software interrupt now pending

    li      s4, 0
_wait:
    addi    s4, s4, 1
    li      t2, 40
    blt     s4, t2, _wait

    # exactly one entry expected (msip cleared in handler -> no re-fire)
    li      t1, 1
    beq     s0, t1, _report
    li      t2, 1
    bne     s1, t2, _report     # keep an earlier failure code if present
    li      s1, 3
_report:
    csrw    mstatus, zero
    li      t0, 0x80001000
    sw      s1, 0(t0)           # sentinel: ends sim, prints result
halt:
    j       halt

    .align 2
_trap_handler:
    addi    s0, s0, 1           # count this entry

    csrr    t3, mcause          # verify cause = 0x8000_0003 (MSI)
    li      t4, 0x80000003
    beq     t3, t4, _cause_ok
    li      s1, 2               # wrong mcause
_cause_ok:
    li      t0, 0x80010000
    sw      zero, 0(t0)         # msip = 0  -> clears MSIP pending bit
    mret

