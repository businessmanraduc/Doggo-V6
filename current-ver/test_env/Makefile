TOP_MODULE = tb_cpu
SV_FILES = phantom32.sv branch-eval.sv fast-decode.sv trap-unit.sv \
           csr-regfile.sv control-unit.sv imm-generator.sv \
           forwarding-unit.sv hazard-unit.sv regfile.sv \
           alu.sv branch-target.sv

VERILATOR = verilator
V_FLAGS = --cc --trace -Wall -Wno-DECLFILENAME --top-module $(TOP_MODULE)

all: run

compile:
	riscv32-none-elf-gcc -march=rv32ic_zicsr -mabi=ilp32 -nostdlib -Ttext 0x0 -o program.elf program.S
	riscv32-none-elf-objcopy -O verilog program.elf program.hex
	cp ./../cpu_files/*.sv   ./
	cp ./../cpu_files/isa.vh ./
	$(VERILATOR) $(V_FLAGS) $(SV_FILES) tb_cpu.sv --exe sim_main.cpp -o Vsim
	$(MAKE) -C obj_dir -f Vtb_cpu.mk

run: compile
	./obj_dir/Vsim

wave:
	gtkwave waveform.vcd

clean:
	rm -rf obj_dir waveform.vcd isa.vh *.sv program.elf program.hex
