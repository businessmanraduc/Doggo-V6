.section .text
.global _start

_start:
  li    s0, 0x80002000

main_loop:
  li    a0, 'I'
  jal   send_char
  li    a0, ' '
  jal   send_char
  li    a0, 'A'
  jal   send_char
  li    a0, 'M'
  jal   send_char
  li    a0, ' '
  jal   send_char
  li    a0, 'A'
  jal   send_char
  li    a0, 'L'
  jal   send_char
  li    a0, 'I'
  jal   send_char
  li    a0, 'V'
  jal   send_char
  li    a0, 'E'
  jal   send_char
  li    a0, '\r'
  jal   send_char
  li    a0, '\n'
  jal   send_char
  j     main_loop

send_char:
  sw    a0, 0(s0)
  li    t0, 20000
1:
  addi t0, t0, -1
  bnez t0, 1b
  ret

