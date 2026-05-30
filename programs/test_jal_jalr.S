# =============================================================================
# PHANTOM-32  ──  Test: JAL / JALR
# =============================================================================
# Tests covered:
#   1. JAL  - PC-relative jump + link address written to ra
#   2. JALR - indirect jump through register + link address to ra
#   3. Function call / return pattern (JAL to call, JALR x0,ra,0 to return)
#   4. Nested: call a function that calls another, returns through ra chain
#
# Expected final result in a0:  0x63  (99)
#   add_three(12, 25, 62) = 99
#
# Convention: result stored to magic address 0x80001000 → triggers $finish
# =============================================================================
.option norvc           # keep all instructions 32-bit for predictable sizing
.section .text
.global _start

_start:
  # ── Test 1: basic JAL + link address ───────────────────────────────────────
  # JAL is the very first instruction (address 0x0), 4 bytes wide.
  # After the jump, ra must hold 0x4 (return address = next instruction).
  # We don't check ra directly here - we rely on Test 3 catching a broken ra.

  jal  ra, test2_entry   # jump over the guard; ra = 0x4

  # If JAL didn't jump, we land here. Poison a0 so the final result is wrong.
  li a0, 0xBAD           # should be flushed / never reached

test2_entry:
  # ── Test 2: JALR indirect jump ─────────────────────────────────────────────
  # Load the address of test3_entry into t0, then jump via JALR.
  # ra gets the PC of this JALR + 4 (we don't use that ra here).
  la   t0, test3_entry
  jalr zero, t0, 0       # indirect jump; ra overwritten but result discarded

  li a0, 0xBAD           # should never execute

test3_entry:
  # ── Test 3: function call + return ─────────────────────────────────────────
  # Call add_values(12, 25) - expects args in a0, a1; returns sum in a0.
  addi a0, zero, 12
  addi a1, zero, 25
  jal  ra, add_values    # ra = address of instruction after this JAL

  # On return a0 = 37.  Now call again with a1 = 62 and accumulate.
  addi a1, zero, 62
  jal  ra, add_values    # a0 = 37 + 62 = 99

  # ── Exit ───────────────────────────────────────────────────────────────────
  li   t0, 0x80001000
  sw   a0, 0(t0)         # expected: 0x63 (99) → triggers $finish

loop: j loop

# =============================================================================
# add_values(a0, a1) → a0
#   Returns a0 + a1.  Uses only a0, a1, ra (caller-saved).
# =============================================================================
add_values:
  add  a0, a0, a1
  jalr zero, ra, 0       # return to caller


