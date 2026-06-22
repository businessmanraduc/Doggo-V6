ROOT    = ../..
RTL     = $(ROOT)/rtl
CORE_SV = $(shell find $(RTL)/core -name '*.sv')
TB      = $(ROOT)/tests/common/tb_core.sv

VERILATOR = verilator
VFLAGS    = --cc --trace -Wall -Wno-DECLFILENAME -I$(RTL)/core
GCC       = riscv32-none-elf-gcc
OBJCOPY   = riscv32-none-elf-objcopy
GFLAGS    = -march=rv32imc_zicsr -mabi=ilp32 -nostdlib -Ttext 0x0

PROGRAM ?= program.S

all: run

compile:
	$(GCC) $(GFLAGS) -o program.elf $(PROGRAM)
	$(OBJCOPY) -O verilog program.elf program.hex
	$(VERILATOR) $(VFLAGS) --top-module tb_core $(CORE_SV) $(TB) \
	  --exe sim_main.cpp -o Vsim
	$(MAKE) -C obj_dir -f Vtb_core.mk

run: compile
	./obj_dir/Vsim

wave:
	gtkwave waveform.vcd

clean:
	rm -rf obj_dir program.elf program.hex waveform.vcd
