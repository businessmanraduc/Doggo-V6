# =============================================================================
# PHANTOM-32  ──  interrupt / minimal-SoC tests  (tb_irq)
# =============================================================================
# Self-contained: references the shared RTL + CLINT, owns its own tb harness
# (tb_irq.sv, sim_main_irq.cpp) and the interrupt test programs.
#
#   make                 run the default IRQ test (test_timer_irq)
#   make IRQ_TEST=foo    run a specific test  (name without .S)
#   make run-all         run every IRQ test in sequence
#   make wave / clean
# =============================================================================

ROOT    = ../..
RTL     = $(ROOT)/rtl
CORE_SV = $(shell find $(RTL)/core -name '*.sv')
CLINT   = $(RTL)/soc/periph/clint.sv
TB      = tb_irq.sv

VERILATOR = verilator
VFLAGS    = --cc --trace -Wall -Wno-DECLFILENAME -I$(RTL)/core
GCC       = riscv32-none-elf-gcc
OBJCOPY   = riscv32-none-elf-objcopy
GFLAGS    = -march=rv32imc_zicsr -mabi=ilp32 -nostdlib -Ttext 0x0

IRQ_TEST ?= test_timer_irq

all: run

compile:
	$(GCC) $(GFLAGS) -o irq.elf $(IRQ_TEST).S
	$(OBJCOPY) -O verilog irq.elf irq.hex
	$(VERILATOR) $(VFLAGS) --top-module tb_irq $(CORE_SV) $(CLINT) $(TB) \
	  --exe sim_main_irq.cpp -o Vsim_irq
	$(MAKE) -C obj_dir -f Vtb_irq.mk

run: compile
	./obj_dir/Vsim_irq

run-all:
	@for t in test_timer_irq test_soft_irq test_irq_masked test_irq_nested; do \
	  $(MAKE) --no-print-directory run IRQ_TEST=$$t; \
	done

wave:
	gtkwave irq_waveform.vcd

clean:
	rm -rf obj_dir irq.elf irq.hex irq_waveform.vcd
