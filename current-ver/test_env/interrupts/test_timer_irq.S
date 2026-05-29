.section .text
.global _start

# CLINT register addresses (base 0x8001_0000, SiFive-standard offsets)
# msip:         0x8001_0000
# mtimecmp_lo:  0x8001_4000
# mtimecmp_hi:  0x8001_4004
# mtime_lo:     0x8001_BFF8
# mtime_hi:     0x8001_BFFC

_start:
    la      t0, _trap_handler
    csrw    mtvec, t0           # direct mode: trap → _trap_handler

    li      s0, 0               # s0 = IRQ counter

    li      t0, 0x80            # mie.MTIE = bit 7
    csrw    mie, t0

    li      t0, 0x80014004
    sw      zero, 0(t0)         # mtimecmp_hi = 0

    li      t0, 0x8001BFF8
    lw      t1, 0(t0)           # t1 = mtime_lo (current)
    addi    t1, t1, 5
    li      t0, 0x80014000
    sw      t1, 0(t0)           # mtimecmp_lo = mtime_lo + 5

    li      t0, 0x8             # mstatus.MIE = bit 3
    csrw    mstatus, t0         # global interrupt enable - timer IRQs can now fire

_spin:
    li      t1, 3
    blt     s0, t1, _spin       # loop until 3 interrupts have been handled

    csrw    mstatus, zero       # disable interrupts before writing result
    li      t0, 0x80001000
    sw      s0, 0(t0)           # sentinel write: ends simulation, prints IRQ count
halt:
    j       halt

    .align 2                    # mtvec direct-mode requires 4-byte alignment
_trap_handler:
    addi    s0, s0, 1           # count this interrupt

    li      t0, 0x8001BFF8
    lw      t1, 0(t0)           # mtime_lo (current, post-interrupt)
    addi    t1, t1, 5
    li      t0, 0x80014000
    sw      t1, 0(t0)           # mtimecmp_lo = mtime_lo + 5

    mret


