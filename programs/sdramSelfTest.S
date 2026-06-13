.section .text
.globl _start

_start:
    li   s0, 0x40000000          # SDRAM window base
    li   s1, 0x80003000          # onboard LED register
    li   s2, 0x40040000          # window end (exclusive): 256 KB sweep
    li   s3, 0                   # failcount (saturating, 7-bit)
    li   s4, 0                   # heartbeat tick counter

    li   t6, 0x0F                # boot indicator (frozen here => SDRAM hang)
    sw   t6, 0(s1)

pass:
    mv   t0, s0                  # addr = base
loop:
    sw   t0, 0(t0)              # mem[addr] = addr
    lw   t2, 0(t0)             # read it back
    beq  t2, t0, ok            # data == address ?

    li   t3, 127               # mismatch: saturating-increment failcount
    bge  s3, t3, ok
    addi s3, s3, 1
ok:
    addi s4, s4, 1             # heartbeat / LED update
    srli t4, s4, 19            # ~1 Hz blink (shift bit if too fast/slow)
    andi t4, t4, 1
    slli t4, t4, 7             # -> LED7
    or   t5, t4, s3            # LED7 = heartbeat, LED6:0 = failcount
    sw   t5, 0(s1)

    addi t0, t0, 4
    blt  t0, s2, loop
    j    pass
