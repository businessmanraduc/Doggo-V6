.section .text
.global _start

_start:
  li    s0, 0x80003000
  li    a0, 0     # dir
  li    a1, 1     # val
  li    a2, 1     # lo_limit
  li    a3, 128   # hi_limit

main_loop:
test_max_val:
  bne   a1, a3, test_min_val
  li    a0, 0
  j     test_dir_1

test_min_val:
  bne   a1, a2, test_dir_1
  li    a0, 1

test_dir_1:
  bne   a0, a2, test_dir_0
  slli  a1, a1, 1
  j     after_tests

test_dir_0:
  srli  a1, a1, 1

after_tests:
  sw    a1, 0(s0)
  li    t0, 3000000
1:
  addi t0, t0, -1
  bnez t0, 1b

  j     main_loop


