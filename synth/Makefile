# =============================================================================
# PHANTOM-32  ──  ECP5 Synthesis Makefile
# =============================================================================
# Target board : ULX3S 85K  (Lattice ECP5 LFE5U-85F-6BG381C)
# Toolchain    : Yosys + nextpnr-ecp5 + prjtrellis + openFPGALoader
# Top module   : soc  (rtl/soc/soc.sv)
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
GCC_FLAGS = -march=rv32imc_zicsr -mabi=ilp32 -nostdlib -Ttext 0x0

# ── Source files ──────────────────────────────────────────────────────────────
RTL  = ../rtl
CORE = $(RTL)/core
SOC  = $(RTL)/soc

SV_SOURCES = \
  $(CORE)/ex_stage/alu.sv             \
  $(CORE)/id_stage/regfile.sv         \
  $(CORE)/ma_stage/csr-regfile.sv     \
  $(CORE)/if_stage/fast-decode.sv     \
  $(CORE)/id_stage/control-unit.sv    \
  $(CORE)/if_stage/imm-generator.sv   \
  $(CORE)/ex_stage/forwarding-unit.sv \
  $(CORE)/id_stage/hazard-unit.sv     \
  $(CORE)/ex_stage/branch-eval.sv     \
  $(CORE)/ex_stage/branch-target.sv   \
  $(CORE)/ma_stage/trap-unit.sv       \
  $(CORE)/ma_stage/interrupt-unit.sv  \
  $(CORE)/ex_stage/muldiv-unit.sv     \
  $(CORE)/if_stage/pht.sv             \
  $(CORE)/preif_stage/btb.sv          \
  $(CORE)/phantom-core.sv             \
  $(SOC)/periph/uart-tx.sv            \
  $(SOC)/periph/clint.sv              \
  $(SOC)/cpu.sv                       \
  $(SOC)/soc.sv

# ── ECP5 target ───────────────────────────────────────────────────────────────
DEVICE   = --85k
PACKAGE  = --package CABGA381
LPF      = ulx3s_v20.lpf

# ── Output artefacts ──────────────────────────────────────────────────────────
PROG_ELF   = program.elf
IMEM_HEX   = imem.hex
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
	@echo "read_verilog -sv -I$(CORE) -I$(SOC) $(SV_SOURCES)" >  synth.ys
	@echo "synth_ecp5 -top soc -json $(SYNTH_JSON)"           >> synth.ys

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
