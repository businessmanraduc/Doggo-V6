// =============================================================================
// PHANTOM-32  ──  SDRAM self-test Verilator harness
// =============================================================================
// Toggles the clock, holds resetn low for a few cycles, then runs until the
// testbench calls $finish (or a safety cycle cap is hit).
// =============================================================================
#include "Vtb_sdram.h"
#include "verilated.h"
#include <cstdio>

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vtb_sdram* dut = new Vtb_sdram;

    const long MAX_CYCLES = 200000;
    dut->resetn = 0;
    dut->clk    = 0;

    for (long cycle = 0; cycle < MAX_CYCLES && !Verilated::gotFinish(); cycle++) {
        if (cycle == 8) dut->resetn = 1;

        dut->clk = 0; dut->eval();
        dut->clk = 1; dut->eval();
    }

    if (!Verilated::gotFinish()) {
        printf("TIMEOUT: testbench never finished. Result: 0\n");
    }

    dut->final();
    delete dut;
    return 0;
}
