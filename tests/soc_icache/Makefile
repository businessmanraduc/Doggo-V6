# =============================================================================
# PHANTOM-32  ──  I-cache SoC test  (tb_soc_icache)
# =============================================================================
# cpu (core + I-cache + arbiter + BRAM DMEM) -> sdram_adapter -> sdram_ctrl ->
# sdram_model (preloaded with the program). Instructions are fetched from SDRAM
# through the I-cache; data stays in BRAM. "Result: 00001356" => PASS.
#
#   make                  build + run program.S
#   make PROGRAM=foo.S    run a different program
#   make clean
# =============================================================================

ROOT    = ../..
RTL     = $(ROOT)/rtl
CORE_SV = $(shell find $(RTL)/core -name '*.sv')
SOC_SV  = $(RTL)/soc/cpu.sv $(RTL)/soc/mem/icache.sv \
          $(RTL)/soc/mem/sdram-ctrl.sv $(RTL)/soc/mem/sdram-adapter.sv
MODEL   = $(ROOT)/tests/sdram/sdram-model.sv
TB      = tb_soc_icache.sv $(MODEL)
MAIN    = sim_main.cpp
TOP     = tb_soc_icache

VERILATOR = verilator
VFLAGS    = --cc --exe --build -Wall -Wno-fatal -Wno-DECLFILENAME \
            -I$(RTL)/core -I$(RTL)/soc --top-module $(TOP) -o V$(TOP)
GCC       = riscv32-none-elf-gcc
OBJCOPY   = riscv32-none-elf-objcopy
GFLAGS    = -march=rv32imc_zicsr -mabi=ilp32 -nostdlib -Ttext 0x0

PROGRAM ?= program.S

.PHONY: all build run clean

all: run

prog.hex: $(PROGRAM)
	$(GCC) $(GFLAGS) -o program.elf $(PROGRAM)
	$(OBJCOPY) -O verilog --verilog-data-width 2 program.elf prog.hex

build: prog.hex
	$(VERILATOR) $(VFLAGS) $(MAIN) $(CORE_SV) $(SOC_SV) $(TB)

run: build
	@./obj_dir/V$(TOP)

clean:
	rm -rf obj_dir program.elf prog.hex
