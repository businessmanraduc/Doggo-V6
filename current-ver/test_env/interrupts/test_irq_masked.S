.section .text
.global _start

# Result @ 0x8000_1000:
#   1 = PASS
#   2 = interrupt fired while masked (gate is wrong)
#   3 = interrupt did NOT fire after enabling (pending was lost)
#
#   s0 = entry counter   s1 = result   s2 = mtimecmp value   s4 = wait counter

_start:
    la      t0, _trap_handler
    csrw    mtvec, t0

    li      s0, 0
    li      s1, 1

    li      t0, 0x80            # mie.MTIE = bit 7
    csrw    mie, t0
    csrw    mstatus, zero       # GLOBAL interrupts disabled

    li      t0, 0x80014004
    sw      zero, 0(t0)         # mtimecmp_hi = 0

    li      t0, 0x8001BFF8
    lw      t1, 0(t0)           # mtime_lo (current)
    addi    t1, t1, 5
    li      t0, 0x80014000
    sw      t1, 0(t0)           # mtimecmp_lo = now + 5
    mv      s2, t1              # remember compare value

    # spin until mtime >= mtimecmp (MTIP is now pending), plus a margin
_w1:
    li      t0, 0x8001BFF8
    lw      t2, 0(t0)
    blt     t2, s2, _w1
    addi    s2, s2, 5
_w2:
    li      t0, 0x8001BFF8
    lw      t2, 0(t0)
    blt     t2, s2, _w2

    # masked window: handler must NOT have run
    beqz    s0, _enable
    li      s1, 2               # fired while masked -> fail
    j       _report

_enable:
    li      t0, 0x8             # mstatus.MIE = 1  -> pending timer fires now
    csrw    mstatus, t0

    li      s4, 0               # give it a few cycles to be taken
_w3:
    addi    s4, s4, 1
    li      t2, 40
    blt     s4, t2, _w3

    li      t1, 1
    beq     s0, t1, _report
    li      t2, 1
    bne     s1, t2, _report
    li      s1, 3               # never fired after enable -> pending lost

_report:
    csrw    mstatus, zero
    li      t0, 0x80001000
    sw      s1, 0(t0)
halt:
    j       halt

    .align 2
_trap_handler:
    addi    s0, s0, 1
    li      t0, 0x80014000
    li      t1, -1
    sw      t1, 0(t0)           # mtimecmp_lo = 0xFFFFFFFF -> won't fire again
    mret


