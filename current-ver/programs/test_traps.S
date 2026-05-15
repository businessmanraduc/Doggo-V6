# =============================================================================
# PHANTOM-32  ──  Test: EBREAK, misaligned load, misaligned store, illegal instr
# =============================================================================
# Each sub-test deliberately causes a trap and verifies mcause via the handler.
# The handler stores the received mcause value into a result array in memory,
# then advances mepc by 4 and returns.  After all traps, the main code sums
# the expected causes and compares.
#
# Trap cause codes expected (from isa.vh / RISC-V spec):
#   EBREAK          → mcause = 3
#   Load misalign   → mcause = 4   (LH from odd address)
#   Store misalign  → mcause = 6   (SW to non-word-aligned address)
#   Illegal instr   → mcause = 2
#
# Expected final result: 3 + 4 + 6 + 2 = 15 = 0x0F
# =============================================================================
.option norvc
.section .text
.global _start

_start:
  # ── Install trap handler ──────────────────────────────────────────────────
  la   t0, trap_handler
  csrw mtvec, t0

  li   a0, 0               # accumulator for sum of mcause values

  # ── Sub-test 1: EBREAK (mcause should be 3) ───────────────────────────────
  ebreak                   # handler runs; a0 += mcause (3)

  # ── Sub-test 2: LH from odd address (mcause should be 4) ─────────────────
  li   t0, 0x101           # byte address 0x101 is odd → misaligned for LH
  lh   t1, 0(t0)           # load halfword: misalignment trap

  # ── Sub-test 3: SW to non-word-aligned address (mcause should be 6) ───────
  li   t0, 0x102           # address 0x102: aligned for HW but not for W
  li   t1, 0xCAFE
  sw   t1, 0(t0)           # store word: misalignment trap

  # ── Sub-test 4: illegal instruction (mcause should be 2) ─────────────────
  # Encode a reserved/illegal 32-bit word directly.
  # 0x0000007F has opcode 0b1111111 which is not a valid RV32I opcode
  # and will be flagged as illegal by control_unit's default case.
  .word 0x0000007F         # illegal encoding → illegal instruction trap

  # ── Verify and exit ───────────────────────────────────────────────────────
  # a0 should be 3 + 4 + 6 + 2 = 15 (0x0F)
  li   t0, 0x80001000
  sw   a0, 0(t0)           # expected: 0x0F → triggers $finish

loop: j loop


# =============================================================================
# trap_handler
# =============================================================================
# On every trap:
#   1. Read mcause and add it to a0 (accumulator in main)
#   2. Advance mepc by 4 to skip the faulting instruction
#   3. MRET
#
# For misaligned traps, mtval holds the faulting effective address (not used
# in this test, but you can inspect it in the waveform to double-check).
#
# Note on advancing mepc for misaligned traps:
#   The faulting instruction (LH/SW) is 4 bytes wide (.option norvc active),
#   so mepc + 4 correctly skips it and resumes after.
# =============================================================================
trap_handler:
  csrr  t2, mcause         # read cause code
  add   a0, a0, t2         # accumulate into a0 (uses caller-saved t2; a0 preserved across traps)

  csrr  t2, mepc           # read saved PC
  addi  t2, t2, 4          # skip faulting instruction (all 32-bit here)
  csrw  mepc, t2

  mret
