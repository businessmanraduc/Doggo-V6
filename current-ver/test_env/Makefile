TOP_MODULE = tb_core

CORE = ../cpu_files/core
SIM  = ../cpu_files/sim

CORE_SV = \
  $(CORE)/phantom-core.sv    \
	$(CORE)/pht.sv 						 \
	$(CORE)/btb.sv						 \
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

VERILATOR = verilator
V_FLAGS = --cc --trace -Wall -Wno-DECLFILENAME \
          --top-module $(TOP_MODULE)           \
          -I../cpu_files

all: run

compile:
	riscv32-none-elf-gcc -march=rv32ic_zicsr -mabi=ilp32 -nostdlib -Ttext 0x0 -o program.elf program.S
	riscv32-none-elf-objcopy -O verilog program.elf program.hex
	$(VERILATOR) $(V_FLAGS) $(CORE_SV) $(SIM)/tb_core.sv --exe sim_main.cpp -o Vsim
	$(MAKE) -C obj_dir -f Vtb_core.mk

run: compile
	./obj_dir/Vsim

wave:
	gtkwave waveform.vcd

clean:
	rm -rf obj_dir waveform.vcd program.elf program.hex


