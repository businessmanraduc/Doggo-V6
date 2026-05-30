# =============================================================================
# PHANTOM-32  ──  Test: CSR Instructions
# =============================================================================
# Tests covered:
#   1. CSRRWI - write via 5-bit zero-extended immediate, capture old value
#   2. CSRRSI - set bits via immediate, capture old value
#   3. CSRRCI - clear bits via immediate, capture old value
#   4. CSRR   - plain read (alias: CSRRS rd, csr, x0)
#   5. CSRRW  - write via register, capture old value
#   6. CSRRS  - set bits via register, capture old value
#   7. CSRRC  - clear bits via register, capture old value
#   8. Read-only CSR: misa - low byte must be 0x04 (C=bit2, I=bit8 → 0x104)
#
# Uses mscratch (CSR 0x340) - freely writable, no hardware side effects.
#
# Step-by-step state (mscratch starts at 0 after reset):
#   1. csrrwi t0, mscratch, 7    t0=0,    mscratch=7
#   2. csrrsi t0, mscratch, 24   t0=7,    mscratch=7|24=31
#   3. csrrci t0, mscratch, 30   t0=31,   mscratch=31&~30=1
#   4. csrr   t0, mscratch       t0=1,    mscratch=1
#   5. csrrw  t0, mscratch, t1   t0=1,    mscratch=0xAB   (t1=0xAB)
#   6. csrrs  t0, mscratch, t1   t0=0xAB, mscratch=0xFF   (t1=0x54, 0xAB|0x54)
#   7. csrrc  t0, mscratch, t1   t0=0xFF, mscratch=0x55   (t1=0xAA, 0xFF&~0xAA)
#   8. andi(csrr(misa), 0xFF)    t0=0x04
#
# Sum of all captured t0 values added to accumulator a0:
#   0 + 7 + 31 + 1 + 1 + 171 + 255 + 4 = 470 = 0x1D6
#
# Expected final result in a0: 0x1D6  (470)
# =============================================================================
.option norvc
.section .text
.global _start

_start:
  li    a0, 0                      # accumulator

  # ── 1. CSRRWI ─────────────────────────────────────────────────────────────
  csrrwi t0, mscratch, 7           # t0 = 0 (old),    mscratch = 7
  add    a0, a0, t0                # a0 = 0

  # ── 2. CSRRSI ─────────────────────────────────────────────────────────────
  csrrsi t0, mscratch, 24          # t0 = 7 (old),    mscratch = 31
  add    a0, a0, t0                # a0 = 7

  # ── 3. CSRRCI ─────────────────────────────────────────────────────────────
  csrrci t0, mscratch, 30          # t0 = 31 (old),   mscratch = 1
  add    a0, a0, t0                # a0 = 38

  # ── 4. CSRR (plain read) ──────────────────────────────────────────────────
  csrr   t0, mscratch              # t0 = 1 (current, no write)
  add    a0, a0, t0                # a0 = 39

  # ── 5. CSRRW ──────────────────────────────────────────────────────────────
  li     t1, 0xAB
  csrrw  t0, mscratch, t1          # t0 = 1 (old),    mscratch = 0xAB
  add    a0, a0, t0                # a0 = 40

  # ── 6. CSRRS ──────────────────────────────────────────────────────────────
  li     t1, 0x54
  csrrs  t0, mscratch, t1          # t0 = 0xAB (old), mscratch = 0xFF
  add    a0, a0, t0                # a0 = 211

  # ── 7. CSRRC ──────────────────────────────────────────────────────────────
  li     t1, 0xAA
  csrrc  t0, mscratch, t1          # t0 = 0xFF (old), mscratch = 0x55
  add    a0, a0, t0                # a0 = 466

  # ── 8. Read-only: misa low byte = 0x04 ───────────────────────────────────
  csrr   t0, misa
  andi   t0, t0, 0xFF              # isolate byte → 0x04
  add    a0, a0, t0                # a0 = 470  (0x1D6)

  # ── Exit ──────────────────────────────────────────────────────────────────
  li     t0, 0x80001000
  sw     a0, 0(t0)                 # expected: 0x1D6 → triggers $finish

loop: j loop
