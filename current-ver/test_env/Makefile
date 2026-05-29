# =============================================================================
# PHANTOM-32  ──  Simulation test environment
# =============================================================================
#   core/         pipeline / ISA tests         → tb_core (used by ../run_compliance.sh)
#   interrupts/   timer-IRQ / minimal-SoC test → tb_irq
#
# Targets:
#   make            (= run)   build + run the core pipeline test
#   make run-irq              build + run the interrupt test
#   make wave / wave-irq      open the matching waveform in gtkwave
#   make clean                remove every build artifact
# =============================================================================

# ── RTL source locations ─────────────────────────────────────────────────────
CORE = ../cpu_files/core
SIM  = ../cpu_files/sim
SOC  = ../cpu_files/soc

# ── Test source categories ───────────────────────────────────────────────────
CORE_DIR = core
IRQ_DIR  = interrupts

# ── Shared core RTL file list ────────────────────────────────────────────────
CORE_SV = 									 \
  $(CORE)/phantom-core.sv    \
  $(CORE)/pht.sv             \
  $(CORE)/btb.sv             \
  $(CORE)/branch-eval.sv     \
  $(CORE)/interrupt-unit.sv  \
  $(CORE)/fast-decode.sv     \
  $(CORE)/trap-unit.sv       \
  $(CORE)/csr-regfile.sv     \
  $(CORE)/control-unit.sv    \
  $(CORE)/imm-generator.sv   \
  $(CORE)/forwarding-unit.sv \
  $(CORE)/hazard-unit.sv     \
  $(CORE)/regfile.sv         \
  $(CORE)/alu.sv             \
  $(CORE)/branch-target.sv

VERILATOR     = verilator
VFLAGS_COMMON = --cc --trace -Wall -Wno-DECLFILENAME -I../cpu_files

GCC     = riscv32-none-elf-gcc
OBJCOPY = riscv32-none-elf-objcopy
GFLAGS  = -march=rv32ic_zicsr -mabi=ilp32 -nostdlib -Ttext 0x0

all: run

# ── core/ : pipeline + ISA test (tb_core) ─────────────────────────────────────
compile:
	$(GCC) $(GFLAGS) -o program.elf $(CORE_DIR)/program.S
	$(OBJCOPY) -O verilog program.elf program.hex
	$(VERILATOR) $(VFLAGS_COMMON) --top-module tb_core \
	  $(CORE_SV) $(SIM)/tb_core.sv --exe $(CORE_DIR)/sim_main.cpp -o Vsim
	$(MAKE) -C obj_dir -f Vtb_core.mk

run: compile
	./obj_dir/Vsim

wave:
	gtkwave waveform.vcd

# ── interrupts/ : timer-IRQ + minimal-SoC test (tb_irq) ───────────────────────
IRQ_SV = 								 \
  $(CORE_SV)             \
  $(SOC)/periph/clint.sv \
  $(SIM)/tb_irq.sv

IRQ_TEST ?= test_timer_irq

compile-irq:
	$(GCC) $(GFLAGS) -o irq.elf $(IRQ_DIR)/$(IRQ_TEST).S
	$(OBJCOPY) -O verilog irq.elf irq.hex
	$(VERILATOR) $(VFLAGS_COMMON) --top-module tb_irq \
	  $(IRQ_SV) --exe $(IRQ_DIR)/sim_main_irq.cpp -o Vsim_irq
	$(MAKE) -C obj_dir -f Vtb_irq.mk

run-irq: compile-irq
	./obj_dir/Vsim_irq

run-irq-all:
	@for t in test_timer_irq test_soft_irq test_irq_masked test_irq_nested; do \
		$(MAKE) --no-print-directory run-irq IRQ_TEST=$$t; \
	done

wave-irq:
	gtkwave irq_waveform.vcd

# ── housekeeping ──────────────────────────────────────────────────────────────
clean:
	rm -rf obj_dir program.elf program.hex irq.elf irq.hex waveform.vcd irq_waveform.vcd


