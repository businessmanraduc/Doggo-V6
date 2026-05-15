# =============================================================================
# PHANTOM-32  ──  Test: ECALL trap entry + MRET return
# =============================================================================
# What this tests:
#   • mtvec write via CSRRW
#   • ECALL triggers trap_en, PC → mtvec, mepc ← PC of ECALL
#   • Trap handler reads mcause (must be 11 = ECALL_M)
#   • Trap handler reads mepc, advances it by 4 (skip ECALL), writes mepc back
#   • MRET restores PC ← mepc, mstatus.MIE ← MPIE, pipeline flushes cleanly
#   • Execution resumes correctly after ECALL in main code
#   • Second ECALL tests that the mechanism works more than once
#
# Expected final result in a0: 0x02
#   Main sets a0=0, handler increments it each time it runs (×2 calls = 2).
# =============================================================================
.option norvc
.section .text
.global _start

_start:
  # ── Install trap handler ──────────────────────────────────────────────────
  la   t0, trap_handler
  csrw mtvec, t0           # mtvec ← address of trap_handler (direct mode)

  li   a0, 0               # a0 = call counter; handler increments this

  # ── First ECALL ──────────────────────────────────────────────────────────
  ecall                    # triggers trap; mepc ← PC of this instruction
                           # after MRET, execution resumes at the instruction
                           # AFTER this ecall (handler advances mepc by 4)

  # ── Second ECALL ─────────────────────────────────────────────────────────
  ecall                    # a0 should become 2 after this

  # ── Exit ─────────────────────────────────────────────────────────────────
  li   t0, 0x80001000
  sw   a0, 0(t0)           # expected: 0x02 → triggers $finish

loop: j loop


# =============================================================================
# trap_handler
# =============================================================================
# Entered whenever trap_en fires (any exception).
# For this test we only expect ECALL (mcause = 11).
#
# Actions:
#   1. Verify mcause == 11; if not, write 0xDEAD and halt (something went wrong)
#   2. Increment a0 (signals handler was reached)
#   3. Advance mepc by 4 (skip the 4-byte ECALL instruction)
#   4. MRET
#
# Note: MRET itself flushes 3 pipeline stages just like a trap, so the
# 3 instructions after MRET in the handler never execute - they are flushed.
# =============================================================================
trap_handler:
  csrr  t1, mcause         # read exception cause
  li    t2, 11             # expected: ECALL from M-mode
  bne   t1, t2, bad_trap   # if cause != 11, something is broken

  addi  a0, a0, 1          # increment call counter

  csrr  t1, mepc           # read saved PC (address of ECALL instruction)
  addi  t1, t1, 4          # advance past the 4-byte ECALL
  csrw  mepc, t1           # write updated return address

  mret                     # return: PC ← mepc, MIE ← MPIE


# =============================================================================
# bad_trap - reached if mcause was something unexpected
# =============================================================================
bad_trap:
  li   a0, 0xDEAD
  li   t0, 0x80001000
  sw   a0, 0(t0)           # write poison value and halt
loop2: j loop2
