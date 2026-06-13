# =============================================================================
# PHANTOM-32  ──  SDRAM controller self-test
# =============================================================================
# Self-contained: drives the relocated controller (rtl/soc/mem/sdram-ctrl.sv)
# against a behavioural SDRAM model under Verilator.
#
#   make        - build + run the self-test (expect "Result: 1")
#   make build  - build only
#   make clean  - remove build artifacts
# =============================================================================

ROOT   = ../..
RTL    = $(ROOT)/rtl/soc/mem/sdram-ctrl.sv
SIM    = sdram-model.sv tb_sdram.sv
MAIN   = sim_main.cpp
TOP    = tb_sdram

ADAPT_RTL  = $(ROOT)/rtl/soc/mem/sdram-ctrl.sv $(ROOT)/rtl/soc/mem/sdram-adapter.sv
ADAPT_SIM  = sdram-model.sv tb_adapter.sv
ADAPT_MAIN = sim_main_adapter.cpp

VERILATOR = verilator
VFLAGS    = --cc --exe --build -Wall -Wno-fatal -Wno-DECLFILENAME --top-module $(TOP) -o V$(TOP)
VFLAGS_A  = --cc --exe --build -Wall -Wno-fatal -Wno-DECLFILENAME --top-module tb_adapter -o Vtb_adapter

.PHONY: all build run adapter clean

all: run

build: obj_dir/V$(TOP)

obj_dir/V$(TOP): $(RTL) $(SIM) $(MAIN)
	$(VERILATOR) $(VFLAGS) $(MAIN) $(RTL) $(SIM)

run: build
	@echo "============================================================"
	@echo " SDRAM controller self-test"
	@echo "============================================================"
	@./obj_dir/V$(TOP)

adapter:
	$(VERILATOR) $(VFLAGS_A) $(ADAPT_MAIN) $(ADAPT_RTL) $(ADAPT_SIM)
	@echo "============================================================"
	@echo " SDRAM adapter self-test"
	@echo "============================================================"
	@./obj_dir/Vtb_adapter

clean:
	rm -rf obj_dir
