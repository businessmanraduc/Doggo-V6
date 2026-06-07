# =============================================================================
# PHANTOM-32  ──  ECP5 Synthesis Makefile
# =============================================================================
# Target board : ULX3S 85K  (Lattice ECP5 LFE5U-85F-6BG381C)
# Toolchain    : Yosys + nextpnr-ecp5 + prjtrellis + openFPGALoader
# Top module   : soc  (rtl/soc/soc.sv)
#
# Usage:
#   make               - compile program, synthesise, place-and-route
#   make diagnostic    - synthesize + place-and-route + Fmax & critpath
#   make prog          - build + load to FPGA SRAM
#   make flash         - build + write to SPI flash
#   make imem          - compile program only → imem.hex  (no synth)
#   make clean         - remove all generated files
#
# PROGRAM: path to the .S source to load into IMEM.
# =============================================================================

PROGRAM ?= ../programs/firstFPGAProgram.S

# ── Toolchain ─────────────────────────────────────────────────────────────────
GCC      = riscv32-none-elf-gcc
OBJCOPY  = riscv32-none-elf-objcopy
YOSYS    = yosys
NEXTPNR  = nextpnr-ecp5
ECPPACK  = ecppack
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
SYNTH_CFG  = soc.config
BITSTREAM  = soc.bit
DIAG_LOG   = soc.timing.log
DIAG_CFG   = soc.diag.config

# =============================================================================
# TARGETS
# =============================================================================

.PHONY: all imem synth pnr diagnostic prog flash clean

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
	$(NEXTPNR) $(DEVICE) $(PACKAGE)  \
	           --json $(SYNTH_JSON)  \
	           --lpf  $(LPF)         \
             --timing-allow-fail   \
             --textcfg $(SYNTH_CFG)
	$(ECPPACK) $(SYNTH_CFG) $(BITSTREAM)

diagnostic: $(SYNTH_JSON) $(LPF)
	@echo "Running synthesis + place-and-route timing analysis..."
	@$(NEXTPNR) $(DEVICE) $(PACKAGE) --json $(SYNTH_JSON) --lpf $(LPF) \
              --timing-allow-fail --textcfg $(DIAG_CFG) > $(DIAG_LOG) 2>&1 || true
	@echo ""
	@python3 critpath.py $(DIAG_LOG)
	@echo ""
	@echo "(full nextpnr log saved to: synth/$(DIAG_LOG))"

prog: $(BITSTREAM)
	$(LOADER) -b ulx3s $(BITSTREAM)

flash: $(BITSTREAM)
	$(LOADER) -b ulx3s -f --unprotect-flash $(BITSTREAM)

# ── Cleanup ───────────────────────────────────────────────────────────────────
clean:
	rm -f $(PROG_ELF) $(IMEM_HEX) $(SYNTH_JSON) $(SYNTH_CFG) $(BITSTREAM) \
        $(DIAG_LOG) $(DIAG_CFG) synth.ys

