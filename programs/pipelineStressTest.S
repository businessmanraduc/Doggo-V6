.section .text
.global _start

_start:
  # --- TEST 1: Forwarding & Load-Use Stall ---
  # We write 42 to memory, then try to load it and use it immediately.
  li   t0, 0x100          # Memory address
  li   t1, 42             # Value to store
  sw   t1, 0(t0)          # Store 42 at address 0x100

  # Exit and report (temporary)
  # li   t0, 0x80001000
  # sw   t1, 0(t0)        # -> Correctly outputs the value 42

  lw   t2, 0(t0)          # Load it back into t2
  addi t3, t2, 8          # HAZARD: Uses t2 immediately after load.
                          # If stall/forwarding fails, t3 will be 8, not 50.

  # Exit and report (temporary)
  # li   t0, 0x80001000
  # sw   t3, 0(t0)        # -> Correctly outputs the value 50

  # --- TEST 2: Branch Taken & Flush ---
  # If flushes work, x10 will be 0. If flushes fail, the 'addi' after
  # the branch will execute before the branch takes effect, making x10 = 100.
  li   x10, 0
  li   t4, 1
  beq  t4, t4, target     # Always taken
  addi x10, x10, 100      # SHOULD BE FLUSHED/KILLED
target:

  # Exit and report (temporary)
  # li   t0, 0x80001000
  # sw   x10, 0(t0)       # -> Correctly outputs the value 0

  addi x10, x10, 1        # x10 should be 1 here

  # Exit and report (temporary)
  # li   t0, 0x80001000
  # sw   x10, 0(t0)         # -> Correctly outputs the value 1

  # --- TEST 3: Compressed Instructions (RV32C) ---
  # These are 16-bit instructions. They test your alignment logic.
  .option rvc             # Enable compressed instructions
  c.li   a1, 7            # a0 = 7
  c.addi a1, 3            # a0 = a0 + 3 (Total 10)
  .option norvc

  # Exit and report (temporary)
  # li   t0, 0x80001000
  # sw   a1, 0(t0)         # -> Correctly outputs the value 10

  # --- FINAL CALCULATION ---
  # Result = t3 (50) + x10 (1) + a0 (10) = 61 (0x3D)
  add  s0, t3, x10
  add  s0, s0, a1

  # Exit and report
  li   t0, 0x80001000
  sw   s0, 0(t0)          # Write final result to magic address

loop: j loop
