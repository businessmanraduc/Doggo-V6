#!/usr/bin/env bash
# =============================================================================
# run_compliance.sh  -  RISC-V architecture compliance runner for Phantom-32
# =============================================================================
#
# Expects the Verilator simulation binary to already be built:
#   cd test_env && make && cd ..
#
# Directory layout:
#   current-ver/
#   ├── test_env/
#   │   ├── program.hex          ← overwritten for each test
#   │   └── obj_dir/Vsim         ← pre-built Verilator simulation binary
#   ├── phantom32-env/
#   │   ├── riscv_test.h
#   │   └── phantom32_link.ld
#   ├── riscv-tests/             ← cloned from riscv-software-src/riscv-tests
#   │   ├── isa/rv32ui/*.S
#   │   ├── isa/rv32uc/*.S
#   │   └── isa/macros/scalar/test_macros.h
#   └── run_compliance.sh        ← this script
# =============================================================================

set -euo pipefail

# ── Paths ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RISCV_TESTS="$SCRIPT_DIR/riscv-tests"
PHANTOM_ENV="$SCRIPT_DIR/phantom32-env"
TEST_ENV="$SCRIPT_DIR/test_env"
SIM="$TEST_ENV/obj_dir/Vsim"
HEX_TARGET="$TEST_ENV/program.hex"
BUILD_DIR="$SCRIPT_DIR/compliance-build"

GCC="riscv32-none-elf-gcc"
OBJCOPY="riscv32-none-elf-objcopy"

MARCH="-march=rv32ic_zicsr"
MABI="-mabi=ilp32"

# ── Tests to run ─────────────────────────────────────────────────────────────
# rv32ui: all base integer instructions
RV32UI_TESTS=(
  add addi and andi auipc
  beq bge bgeu blt bltu bne
  jal jalr
  lb lbu lh lhu lui lw
  or ori
  sb sh simple
  sll slli slt slti sltiu sltu sra srai srl srli
  sub sw
  xor xori
)

# rv32uc: compressed instructions
RV32UC_TESTS=(
  rvc
)

# Skipped tests and reasons:
#   fence_i - tests FENCE.I (I-cache flush); Phantom-32 has no I-cache.
#              Behaviour depends on how control_unit decodes the FENCE.I
#              opcode (NOP-like or illegal).

# ── Argument handling ─────────────────────────────────────────────────────────
if [[ "${1:-}" == "--clean" ]]; then
  echo "Cleaning build directory..."
  rm -rf "$BUILD_DIR"
  cd "$TEST_ENV" && make && cd ..
  exit 0
fi

if [[ "${1:-}" == "--recompile-cpu" ]]; then
  echo "Recompiling Verilator CPU..."
  cd "$TEST_ENV" && make && cd ..
fi

# ── Pre-flight checks ─────────────────────────────────────────────────────────
if [ ! -f "$SIM" ]; then
  echo "ERROR: Verilator sim not found at $SIM"
  echo "Runing:  cd test_env && make && cd .."
  cd "$TEST_ENV" && make && cd ..
fi

if [ ! -d "$RISCV_TESTS/isa/rv32ui" ]; then
  echo "ERROR: riscv-tests not found at $RISCV_TESTS"
  echo "  Run: git clone https://github.com/riscv-software-src/riscv-tests"
  echo "       cd riscv-tests && git submodule update --init --recursive"
  exit 1
fi

mkdir -p "$BUILD_DIR"

# ── Counters ─────────────────────────────────────────────────────────────────
PASS=0
FAIL=0
COMPILE_FAIL=0
TIMEOUT=0

FAILED_TESTS=()

# ── Per-test function ─────────────────────────────────────────────────────────
run_test() {
  local suite="$1" # rv32ui or rv32uc
  local name="$2"  # e.g. add, rvc
  local src="$RISCV_TESTS/isa/${suite}/${name}.S"
  local elf="$BUILD_DIR/${suite}-${name}.elf"
  local hex="$BUILD_DIR/${suite}-${name}.hex"

  printf "  %-20s " "$suite/$name"

  # ── Compile ──────────────────────────────────────────────────────────────
  if ! $GCC \
    $MARCH $MABI \
    -nostdlib \
    -I "$PHANTOM_ENV" \
    -I "$RISCV_TESTS/isa/macros/scalar" \
    -T "$PHANTOM_ENV/phantom32_link.ld" \
    "$src" -o "$elf" 2>/dev/null; then
    echo "COMPILE FAIL"
    COMPILE_FAIL=$((COMPILE_FAIL + 1))
    FAILED_TESTS+=("$suite/$name  [compile error]")
    return
  fi

  # ── Convert to hex ───────────────────────────────────────────────────────
  $OBJCOPY -O verilog "$elf" "$hex"
  cp "$hex" "$HEX_TARGET"

  # ── Run simulation ───────────────────────────────────────────────────────
  # timeout 10s kills the sim if it exceeds the cycle limit without $finish.
  local output
  output=$(cd "$TEST_ENV" && timeout 10s ./obj_dir/Vsim 2>/dev/null) || true

  local result
  result=$(echo "$output" | grep -oP '(?<=Result: )[0-9a-fA-F]+' || echo "")

  if [ -z "$result" ]; then
    echo "TIMEOUT / NO OUTPUT"
    TIMEOUT=$((TIMEOUT + 1))
    FAILED_TESTS+=("$suite/$name  [no output - possible infinite loop or crash]")
    return
  fi

  result=$(echo "$result" | tr '[:upper:]' '[:lower:]' | sed 's/^0*//')
  result="${result:-0}"

  if [ "$result" = "1" ]; then
    echo "PASS"
    PASS=$((PASS + 1))
  else
    local testnum=$(((16#$result - 1) / 2))
    printf "FAIL  (result=0x%s → sub-test %d failed)\n" "$result" "$testnum"
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("$suite/$name  [sub-test $testnum, raw=0x$result]")
  fi
}

# ── Main loop ─────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo " Phantom-32  RISC-V Architecture Compliance Run"
echo "============================================================"
echo ""
echo "[ rv32ui - base integer instruction tests ]"
for t in "${RV32UI_TESTS[@]}"; do
  run_test "rv32ui" "$t"
done

echo ""
echo "[ rv32uc - compressed instruction tests ]"
for t in "${RV32UC_TESTS[@]}"; do
  run_test "rv32uc" "$t"
done

# ── Summary ───────────────────────────────────────────────────────────────────
TOTAL=$((PASS + FAIL + COMPILE_FAIL + TIMEOUT))
echo ""
echo "============================================================"
echo " Results: $PASS passed,  $FAIL failed,  $COMPILE_FAIL compile errors,  $TIMEOUT timeouts"
echo " Total:   $TOTAL tests"
echo "============================================================"

if [ ${#FAILED_TESTS[@]} -gt 0 ]; then
  echo ""
  echo "Failed tests:"
  for t in "${FAILED_TESTS[@]}"; do
    echo "  ✗  $t"
  done
  echo ""
  exit 1
else
  echo ""
  echo "All tests passed! :D"
  echo ""
  exit 0
fi
