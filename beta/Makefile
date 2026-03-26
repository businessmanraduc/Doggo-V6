# =============================================================================
# Doggo-CPU V6 -> PHANTOM-16  ──  Makefile
# =============================================================================
# Targets:
#   make icarus      — simulate with Icarus Verilog
#   make verilator   — simulate with Verilator
#   make all         — run both
#   make wave        — open dump.vcd in GTKWave
#   make clean       — remove all build artefacts
# =============================================================================

SOURCES    = alu.v cpu.v soc.v
TB_ICARUS  = tb_icarus.v
TB_VER     = tb_verilator.cpp
TOP        = soc

.PHONY: all icarus verilator wave clean

all: icarus verilator

# ── Icarus Verilog ─────────────────────────────────────────────────────────────
icarus:
	@echo ""
	@echo ">>> Icarus Verilog ─────────────────────────────────────────────"
	iverilog -g2012 -Wall -o sim_icarus $(TB_ICARUS) $(SOURCES)
	vvp sim_icarus
	@echo ""

# ── Verilator ─────────────────────────────────────────────────────────────────
verilator:
	@echo ""
	@echo ">>> Verilator ──────────────────────────────────────────────────"
	verilator --cc --exe --build --trace -Wall \
	          --top-module $(TOP) \
	          $(SOURCES) $(TB_VER)
	./obj_dir/V$(TOP)
	@echo ""

# ── GTKWave ───────────────────────────────────────────────────────────────────
wave:
	gtkwave dump.vcd &

# ── Clean ─────────────────────────────────────────────────────────────────────
clean:
	rm -f sim_icarus dump.vcd
	rm -rf obj_dir
