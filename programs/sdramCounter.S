.section .text
.globl _start

_start:
  li    t0, 0x80003000    # onboard LED register
  li    t1, 0             # free-running counter
loop:
  srli  a0, t1, 19
  sw    a0, 0(t0)         # drive LEDs
  addi  t1, t1, 1
  j     loop              # predicted-taken jump

