# =============================================================================
# PHANTOM-32  --  UART bootloader  (boot ROM @ 0x2000_0000, fetch-side)
# =============================================================================
# The CPU comes out of reset here. The loader receives a program over UART,
# writes it into SDRAM at address 0, verifies a checksum, then jumps to 0.
#
# Protocol (115200 8-N-1, all words little-endian, host -> board):
#   board : sends '>' on entry and re-sends it about twice a second while
#           waiting, so the host can sync no matter who started first
#   host  : [4-byte length N] [N payload bytes, N % 4 == 0] [4-byte checksum]
#           checksum = 32-bit sum of the N/4 payload words
#   board : 'K' + jump to 0 on match; 'E' + LED 0xAA + back to waiting on fail
#
# LED codes: 0x01 waiting for header, 0x03 receiving, 0xAA checksum mismatch.
#
# Register use: s0 = UART data, s1 = UART status, s2 = LEDs,
#               s3 = bytes left, s4 = SDRAM write ptr, s5 = running checksum
# =============================================================================
  .section .text
  .globl _start
_start:
  lui  s0, 0x80002            # s0 = UART data register   (0x8000_2000)
  addi s1, s0, 4              # s1 = UART status register (0x8000_2004)
  lui  s2, 0x80003            # s2 = onboard LEDs         (0x8000_3000)

boot_wait:
  li   t0, 0x01
  sw   t0, 0(s2)              # LED: waiting for header

prompt:
  li   t0, '>'
  sw   t0, 0(s0)              # (re)send the ready prompt
  lui  t4, 0x400              # ~4M poll iterations = about half a second
prompt_poll:
  lw   t1, 0(s1)
  andi t1, t1, 2              # status bit1 = rx_valid
  bnez t1, header
  addi t4, t4, -1
  bnez t4, prompt_poll
  j    prompt

header:
  jal  ra, rx_word            # a0 = payload length in bytes
  mv   s3, a0
  li   t0, 0x03
  sw   t0, 0(s2)              # LED: receiving
  li   s4, 0                  # SDRAM write pointer
  li   s5, 0                  # running checksum

rx_payload:
  beqz s3, rx_check
  jal  ra, rx_word
  sw   a0, 0(s4)
  add  s5, s5, a0
  addi s4, s4, 4
  addi s3, s3, -4
  j    rx_payload

rx_check:
  jal  ra, rx_word            # a0 = expected checksum
  bne  a0, s5, boot_fail
  li   t0, 'K'
  sw   t0, 0(s0)              # ACK
  jr   zero                   # jump to the program at SDRAM address 0

boot_fail:
  li   t0, 'E'
  sw   t0, 0(s0)
  li   t0, 0xAA
  sw   t0, 0(s2)              # LED: checksum mismatch
  j    boot_wait

# -----------------------------------------------------------------------------
# rx_word: receive 4 bytes LSB-first -> a0   (clobbers t1, t2, t3)
# -----------------------------------------------------------------------------
rx_word:
  li   t3, 4
  li   a0, 0
rxw_poll:
  lw   t1, 0(s1)
  andi t1, t1, 2              # rx_valid
  beqz t1, rxw_poll
  lw   t2, 0(s0)              # pop the RX byte (upper 24 bits read as 0)
  slli t2, t2, 24
  srli a0, a0, 8
  or   a0, a0, t2
  addi t3, t3, -1
  bnez t3, rxw_poll
  ret
