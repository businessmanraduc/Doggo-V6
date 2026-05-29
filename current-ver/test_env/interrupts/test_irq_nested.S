.section .text
.global _start

# Result @ 0x8000_1000:
#   1 = PASS
#   2 = wrong mstatus inside handler (MIE!=0 or MPIE!=1)
#   3 = handler was re-entered (preemption leaked through MIE==0)
#
#   s0 = entry counter   s1 = result   s3 = in-handler tripwire   s4 = loop limit

_start:
    la      t0, _trap_handler
    csrw    mtvec, t0

    li      s0, 0               # interrupts handled
    li      s1, 1               # result
    li      s3, 0               # in-handler flag

    li      t0, 0x80            # mie.MTIE
    csrw    mie, t0
    li      t0, 0x80014004
    sw      zero, 0(t0)         # mtimecmp_hi = 0

    li      t0, 0x8001BFF8
    lw      t1, 0(t0)
    addi    t1, t1, 5
    li      t0, 0x80014000
    sw      t1, 0(t0)           # arm: mtimecmp_lo = now + 5

    li      t0, 0x8
    csrw    mstatus, t0         # MIE = 1

_spin:
    li      s4, 3
    blt     s0, s4, _spin       # wait for 3 interrupts

    csrw    mstatus, zero
    li      t0, 0x80001000
    sw      s1, 0(t0)
halt:
    j       halt

    .align 2
_trap_handler:
    bnez    s3, _nested_fail
    li      s3, 1               # mark: now inside handler

    csrr    t3, mstatus
    andi    t4, t3, 0x8         # MIE
    bnez    t4, _status_fail
    andi    t4, t3, 0x80        # MPIE
    beqz    t4, _status_fail
    j       _status_ok
_status_fail:
    li      s1, 2
_status_ok:
    addi    s0, s0, 1

    li      t0, 0x8001BFF8
    lw      t1, 0(t0)
    li      t0, 0x80014000
    sw      t1, 0(t0)           # mtimecmp = current mtime -> MTIP asserts now
    li      t2, 0               # busy work: a self-preemption would re-enter
_busy:
    addi    t2, t2, 1
    li      t5, 15
    blt     t2, t5, _busy

    li      t0, 0x8001BFF8
    lw      t1, 0(t0)
    addi    t1, t1, 5
    li      t0, 0x80014000
    sw      t1, 0(t0)

    li      s3, 0               # leaving handler
    mret

_nested_fail:
    li      s1, 3
    li      s3, 0
    mret


