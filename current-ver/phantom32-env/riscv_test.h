// ============================================================================
// phantom32-env/riscv_test.h
// ============================================================================
// Drop-in replacement for riscv-tests/env/p/riscv_test.h tailored for the
// Phantom-32 testbench convention:
//
//   PASS  →  SW 1        to 0x80001000  →  testbench prints result and $finish
//   FAIL  →  SW (N<<1)|1 to 0x80001000  →  non-1 value flags which test failed
//
// TESTNUM (gp / x3) holds the currently executing sub-test number.
// On failure the value stored is (TESTNUM << 1) | 1, so:
//   0x00000001  all tests passed
//   0x00000003  test case 1 failed
//   0x00000005  test case 2 failed  ... etc.
// ============================================================================
#ifndef _PHANTOM32_RISCV_TEST_H
#define _PHANTOM32_RISCV_TEST_H

#include "encoding.h"

// ── Register that holds the current sub-test number ─────────────────────────
#define TESTNUM gp

#define RVTEST_RV32U                                                    \
  .option norvc;                                                        \

#define RVTEST_RV32M                                                    \
  .option norvc;                                                        \

// ── Test code section begin ─────────────────────────────────────────────────
#define RVTEST_CODE_BEGIN                                               \
  .text;                                                                \
  .align 2;                                                             \
  .weak mtvec_handler;                                                  \
  .weak stvec_handler;                                                  \
  .global _start;                                                       \
  _start:                                                               \
    j     _test_begin;                                                  \
    .align 2;                                                           \
  _mtvec_entry:                                                         \
    la    t0, mtvec_handler;                                            \
    jr    t0;                                                           \
  _test_begin:                                                          \
  la      t0, _mtvec_entry;                                             \
  csrw    mtvec, t0;                                                    \
    li TESTNUM, 0;                                                      \

// ── Test code section end ───────────────────────────────────────────────────
#define RVTEST_CODE_END                                                 \
  .text;                                                                \

// ── Test data section ───────────────────────────────────────────────────────
#define RVTEST_DATA_BEGIN                                               \
  .data;                                                                \
  .align 4;                                                             \

#define RVTEST_DATA_END                                                 \

// ── PASS sequence ───────────────────────────────────────────────────────────
// Stores 1 to the magic address.  The testbench sees the write, prints
// "Result: 00000001" and calls $finish.
#define RVTEST_PASS                                                     \
  li   a0, 1;                                                           \
  li   t0, 0x80001000;                                                  \
  sw   a0, 0(t0);                                                       \
99: j  99b;                                                             \

// ── FAIL sequence ───────────────────────────────────────────────────────────
// Encodes the failing test number as (TESTNUM << 1) | 1 and stores it.
// Any result value other than 1 is treated as a failure by run_compliance.sh.
#define RVTEST_FAIL                                                     \
  slli TESTNUM, TESTNUM, 1;                                             \
  ori  TESTNUM, TESTNUM,  1;                                            \
  mv   a0, TESTNUM;                                                     \
  li   t0, 0x80001000;                                                  \
  sw   a0, 0(t0);                                                       \
99: j  99b;                                                             \

#endif

