.section .text
.globl _start

_start:
    li   t0, 0x40000040          # SDRAM byte address A

    li   t1, 0xAABBCCDD
    sw   t1, 0(t0)               # A      <- 0xAABBCCDD
    li   t2, 0x11223344
    sw   t2, 4(t0)               # A+4    <- 0x11223344

    lw   a0, 0(t0)               # read A      (stalls until burst done)
    li   t3, 0xAABBCCDD
    bne  a0, t3, fail

    lw   a1, 4(t0)               # read A+4
    li   t4, 0x11223344
    bne  a1, t4, fail

    li   t5, 0x33
    sb   t5, 1(t0)               # byte 1 of A -> 0x33  (dqm masks one byte)
    lw   a2, 0(t0)
    li   t6, 0xAABB33DD
    bne  a2, t6, fail

    li   t5, 0x9988
    sh   t5, 6(t0)               # upper half of A+4 -> 0x9988 (dqm masks half)
    lw   a3, 4(t0)
    li   t6, 0x99883344
    bne  a3, t6, fail

    lw   a4, 0(t0)               # = 0xAABB33DD
    li   t5, 3
    mul  a5, a4, t5              # muldiv runs while/after the load stall
    li   t3, 0xAABB33DD
    bne  a4, t3, fail            # a4 must still equal 0xAABB33DD

pass:
    li   t0, 0x80001000
    li   t1, 1
    sw   t1, 0(t0)              # Result: 1
halt_p:
    j    halt_p

fail:
    li   t0, 0x80001000
    li   t1, 0
    sw   t1, 0(t0)             # Result: 0
halt_f:
    j    halt_f
