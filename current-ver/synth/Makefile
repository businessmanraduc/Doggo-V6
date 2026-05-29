# =============================================================================
# PHANTOM-32  ──  ECP5 Synthesis Makefile
# =============================================================================
# Target board : ULX3S 85K  (Lattice ECP5 LFE5U-85F-6BG381C)
# Toolchain    : Yosys + nextpnr-ecp5 + prjtrellis + openFPGALoader
# Top module   : soc  (soc/soc.sv)
#
# Usage:
#   make               - compile program, synthesise, place-and-route
#   make prog          - compile + synth + P&R + flash to board
#   make imem          - compile program only → imem.hex  (no synth)
#   make clean         - remove all generated files
#
# PROGRAM: path to the .S source to load into IMEM.
# =============================================================================

PROGRAM ?= ../programs/iWasTheFirst.S

# ── Toolchain ─────────────────────────────────────────────────────────────────
GCC      = riscv32-none-elf-gcc
OBJCOPY  = riscv32-none-elf-objcopy
YOSYS    = yosys
NEXTPNR  = nextpnr-ecp5
LOADER   = openFPGALoader

# ── GCC flags ─────────────────────────────────────────────────────────────────
GCC_FLAGS = -march=rv32ic_zicsr -mabi=ilp32 -nostdlib -Ttext 0x0

# ── Source files ──────────────────────────────────────────────────────────────
CPU_FILES = ../cpu_files
CORE      = $(CPU_FILES)/core
SOC       = $(CPU_FILES)/soc

# Listed in dependency order (no top-level `include ordering issues)
SV_SOURCES = \
  $(CORE)/alu.sv             \
  $(CORE)/regfile.sv         \
  $(CORE)/csr-regfile.sv     \
  $(CORE)/fast-decode.sv     \
  $(CORE)/control-unit.sv    \
  $(CORE)/imm-generator.sv   \
  $(CORE)/forwarding-unit.sv \
  $(CORE)/hazard-unit.sv     \
  $(CORE)/branch-eval.sv     \
  $(CORE)/branch-target.sv   \
  $(CORE)/trap-unit.sv       \
	$(CORE)/interrupt-unit.sv  \
  $(CORE)/pht.sv             \
  $(CORE)/btb.sv             \
  $(CORE)/phantom-core.sv    \
  $(SOC)/periph/uart-tx.sv   \
	$(SOC)/periph/clint.sv		 \
  $(SOC)/cpu.sv              \
  $(SOC)/soc.sv

# ── ECP5 target ───────────────────────────────────────────────────────────────
DEVICE   = --85k
PACKAGE  = --package CABGA381
LPF      = ulx3s_v20.lpf

# ── Output artefacts ──────────────────────────────────────────────────────────
PROG_ELF = program.elf
IMEM_HEX = imem.hex
SYNTH_JSON = soc.json
BITSTREAM  = soc.bit

# =============================================================================
# TARGETS
# =============================================================================

.PHONY: all imem synth pnr prog clean

all: $(BITSTREAM)

# ── Step 1: Compile .S → imem.hex (16-bit halfword Verilog hex) ───────────────
imem: $(IMEM_HEX)

$(IMEM_HEX): $(PROGRAM)
	$(GCC) $(GCC_FLAGS) -o $(PROG_ELF) $<
	$(OBJCOPY) -O verilog --verilog-data-width 2 $(PROG_ELF) $(IMEM_HEX)
	@echo "Generated $(IMEM_HEX) from $<"

# ── Step 2: Yosys synthesis ───────────────────────────────────────────────────
synth: $(SYNTH_JSON)

synth.ys: $(SV_SOURCES) $(IMEM_HEX)
	@echo "read_verilog -sv -I$(CPU_FILES) $(SV_SOURCES)" >  synth.ys
	@echo "synth_ecp5 -top soc -json $(SYNTH_JSON)"        >> synth.ys
 
$(SYNTH_JSON): synth.ys
	$(YOSYS) synth.ys

# ── Step 3: Place and route ───────────────────────────────────────────────────
pnr: $(BITSTREAM)

$(BITSTREAM): $(SYNTH_JSON) $(LPF)
	$(NEXTPNR) $(DEVICE) $(PACKAGE) \
	           --json $(SYNTH_JSON)  \
	           --lpf  $(LPF)         \
	           --bitstream $(BITSTREAM)

# ── Flash to board ────────────────────────────────────────────────────────────
prog: $(BITSTREAM)
	$(LOADER) -b ulx3s $(BITSTREAM)

# ── Cleanup ───────────────────────────────────────────────────────────────────
clean:
	rm -f $(PROG_ELF) $(IMEM_HEX) $(SYNTH_JSON) $(BITSTREAM)
