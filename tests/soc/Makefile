# =============================================================================
# PHANTOM-32  ──  SoC-level SDRAM integration test  (tb_soc)
# =============================================================================
# End-to-end: real cpu.sv (core + BRAM + region decode + SDRAM mem bus) driving
# the SDRAM adapter + controller + behavioural model. A program in IMEM hammers
# the SDRAM region; "Result: 1" means every load/store survived the multi-cycle
# mem_stall correctly (incl. sub-word dqm masking and a muldiv under a stall).
#
#   make                  build + run program.S
#   make PROGRAM=foo.S    run a different program
#   make clean
# =============================================================================

ROOT    = ../..
RTL     = $(ROOT)/rtl
CORE_SV = $(shell find $(RTL)/core -name '*.sv')
SOC_SV  = $(RTL)/soc/cpu.sv $(RTL)/soc/mem/sdram-ctrl.sv $(RTL)/soc/mem/sdram-adapter.sv
MODEL   = $(ROOT)/tests/sdram/sdram-model.sv
TB      = tb_soc.sv $(MODEL)
MAIN    = sim_main.cpp
TOP     = tb_soc

VERILATOR = verilator
VFLAGS    = --cc --exe --build -Wall -Wno-fatal -Wno-DECLFILENAME \
            -I$(RTL)/core -I$(RTL)/soc --top-module $(TOP) -o V$(TOP)
GCC       = riscv32-none-elf-gcc
OBJCOPY   = riscv32-none-elf-objcopy
GFLAGS    = -march=rv32imc_zicsr -mabi=ilp32 -nostdlib -Ttext 0x0

PROGRAM ?= program.S

.PHONY: all build run clean

all: run

imem.hex: $(PROGRAM)
	$(GCC) $(GFLAGS) -o program.elf $(PROGRAM)
	$(OBJCOPY) -O verilog --verilog-data-width 2 program.elf imem.hex

build: imem.hex
	$(VERILATOR) $(VFLAGS) $(MAIN) $(CORE_SV) $(SOC_SV) $(TB)

run: build
	@echo "============================================================"
	@echo " SoC SDRAM integration self-test"
	@echo "============================================================"
	@./obj_dir/V$(TOP)

clean:
	rm -rf obj_dir program.elf imem.hex
