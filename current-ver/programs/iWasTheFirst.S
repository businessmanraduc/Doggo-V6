.section .text
.global _start
_start:
  addi x1, x0, 5
  addi x2, x1, 10
  li t0, 0x80001000
  sw x2, 0(t0)
loop: j loop
