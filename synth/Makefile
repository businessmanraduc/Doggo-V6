# =============================================================================
# PHANTOM-32  ──  ECP5 Synthesis Makefile
# =============================================================================
# Target board : ULX3S 85K  (Lattice ECP5 LFE5U-85F-6BG381C)
# Toolchain    : Yosys + nextpnr-ecp5 + prjtrellis + openFPGALoader
# Top module   : soc  (rtl/soc/soc.sv)
#
# Usage:
#   make                 - build bootrom, synthesise, place-and-route
#   make diagnostic      - synthesize + place-and-route + Fmax & critpath
#   make benchmark       - run SWEEP_SEEDS placements in parallel + report best seed
#   make prog            - build + load to FPGA SRAM
#   make flash           - build + write to SPI flash
#   make bin             - compile PROGRAM -> program.bin  (no synth)
#   make send            - compile PROGRAM + send it over UART to the bootloader
#   make clean           - remove all generated files
#
# PROGRAM: path to the .S source to send.  TTY: serial port for 'make send'.
# =============================================================================

PROGRAM ?= ../programs/sdramCounter.S
TTY     ?= /dev/ttyUSB0

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
	$(CORE)/if_stage/bj-target.sv       \
	$(CORE)/ex_stage/branch-eval.sv     \
  $(CORE)/ex_stage/branch-target.sv   \
  $(CORE)/ma_stage/trap-unit.sv       \
  $(CORE)/ma_stage/interrupt-unit.sv  \
  $(CORE)/ex_stage/muldiv-unit.sv     \
  $(CORE)/if_stage/fetch-unit.sv      \
	$(CORE)/if_stage/pht.sv             \
  $(CORE)/phantom-core.sv             \
  $(SOC)/periph/uart.sv               \
  $(SOC)/periph/clint.sv              \
  $(SOC)/mem/sdram-ctrl.sv            \
	$(SOC)/mem/sdram-adapter.sv         \
	$(SOC)/mem/bootrom.sv               \
	$(SOC)/mem/icache.sv                \
	$(SOC)/cpu.sv                       \
  $(SOC)/soc.sv

# ── ECP5 target ───────────────────────────────────────────────────────────────
DEVICE   = --85k
PACKAGE  = --package CABGA381
LPF      = ulx3s_v20.lpf

# ── Placer tuning ─────────────────────────────────────────────────────────────
PLACER_OPTS = --placer-heap-timingweight 90

# ── Output artefacts ──────────────────────────────────────────────────────────
PROG_ELF    = program.elf
PROG_BIN    = program.bin
BOOT_SRC    = ../programs/bootloader.S
BOOT_ELF    = bootrom.elf
BOOTROM_HEX = bootrom.hex
SYNTH_JSON  = soc.json
SYNTH_CFG   = soc.config
BITSTREAM   = soc.bit
DIAG_LOG    = soc.timing.log
DIAG_CFG    = soc.diag.config

# ── Seed sweep settings ───────────────────────────────────────────────────────
SWEEP_SEEDS ?= 25
SWEEP_JOBS  ?= $(shell nproc)
SEED        ?=

# =============================================================================
# TARGETS
# =============================================================================

.PHONY: all bootrom bin send synth pnr diagnostic benchmark prog flash clean

all: $(BITSTREAM)

# ── Step 1: Assemble the bootloader → bootrom.hex (32-bit Verilog hex) ───────
bootrom: $(BOOTROM_HEX)

$(BOOTROM_HEX): $(BOOT_SRC)
	$(GCC) -march=rv32i -mabi=ilp32 -nostdlib -Ttext 0x20000000 -o $(BOOT_ELF) $<
	$(OBJCOPY) -O verilog --verilog-data-width 4 --change-addresses -0x20000000 $(BOOT_ELF) $(BOOTROM_HEX)
	@echo "Generated $(BOOTROM_HEX) from $<"

bin: $(PROG_BIN)

$(PROG_BIN): $(PROGRAM) FORCE
	$(GCC) $(GCC_FLAGS) -o $(PROG_ELF) $<
	$(OBJCOPY) -O binary $(PROG_ELF) $(PROG_BIN)
	@echo "Generated $(PROG_BIN) from $<"

FORCE:
.PHONY: FORCE

send: $(PROG_BIN)
	python3 send.py $(PROG_BIN) $(TTY)

# ── Step 2: Yosys synthesis ──────────────────────────────────────────────────
synth: $(SYNTH_JSON)

synth.ys: $(SV_SOURCES) $(BOOTROM_HEX)
	@echo "read_verilog -sv -I$(CORE) -I$(SOC) $(SV_SOURCES)" >  synth.ys
	@echo "synth_ecp5 -top soc -json $(SYNTH_JSON)"           >> synth.ys

$(SYNTH_JSON): synth.ys
	$(YOSYS) synth.ys

# ── Step 3: Place and route ──────────────────────────────────────────────────
pnr: $(BITSTREAM)

$(BITSTREAM): $(SYNTH_JSON) $(LPF)
	$(NEXTPNR) $(DEVICE) $(PACKAGE)         \
	           --json $(SYNTH_JSON)         \
	           --lpf  $(LPF)                \
	           $(if $(SEED),--seed $(SEED)) \
             $(PLACER_OPTS)               \
             --timing-allow-fail          \
             --textcfg $(SYNTH_CFG)
	$(ECPPACK) $(SYNTH_CFG) $(BITSTREAM)

diagnostic: $(SYNTH_JSON) $(LPF)
	@echo "Running synthesis + place-and-route timing analysis..."
	@$(NEXTPNR) $(DEVICE) $(PACKAGE)        \
	           --json $(SYNTH_JSON)         \
	           --lpf $(LPF)                 \
             $(if $(SEED),--seed $(SEED)) \
             $(PLACER_OPTS)               \
             --timing-allow-fail          \
             --textcfg $(DIAG_CFG) > $(DIAG_LOG) 2>&1 || true
	@echo ""
	@python3 critpath.py $(DIAG_LOG)
	@echo ""
	@echo "(full nextpnr log saved to: synth/$(DIAG_LOG))"

benchmark: $(SYNTH_JSON) $(LPF)
	@echo "Sweeping seeds 1..$(SWEEP_SEEDS) on $(SWEEP_JOBS) parallel jobs ($(SWEEP_SEEDS) place-and-route passes)..."
	@rm -rf sweep_tmp && mkdir -p sweep_tmp
	@seq 1 $(SWEEP_SEEDS) | xargs -P $(SWEEP_JOBS) -I {} \
	  ./sweep.sh {} $(NEXTPNR) $(DEVICE) $(PACKAGE) --json $(SYNTH_JSON) --lpf $(LPF) $(PLACER_OPTS) \
	  > sweep_tmp/results.txt
	@echo ""
	@echo "=== Fmax by seed (best first) ==="
	@sort -rn sweep_tmp/results.txt | awk '{printf "  seed %2d : %6s MHz\n", $$2, $$1}'
	@echo ""
	@sort -rn sweep_tmp/results.txt | head -1 \
	  | awk '{printf "BEST: seed %d at %s MHz\n", $$2, $$1}'
	@echo "(per-seed logs in synth/sweep_tmp/log_<seed>)"

prog: $(BITSTREAM)
	$(LOADER) -b ulx3s $(BITSTREAM)

flash: $(BITSTREAM)
	$(LOADER) -b ulx3s -f --unprotect-flash $(BITSTREAM)

# ── Cleanup ───────────────────────────────────────────────────────────────────
clean:
	rm -f $(PROG_ELF) $(PROG_BIN) $(BOOT_ELF) $(BOOTROM_HEX) \
		    $(SYNTH_JSON) $(SYNTH_CFG) $(BITSTREAM) \
        $(DIAG_LOG) $(DIAG_CFG) synth.ys
	rm -rf sweep_tmp

