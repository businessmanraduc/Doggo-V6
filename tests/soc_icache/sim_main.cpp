#include "Vtb_soc_icache.h"
#include "verilated.h"

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vtb_soc_icache* top = new Vtb_soc_icache;

    top->clk = 0;
    top->resetn = 0;

    for (long i = 0; i < 1000000; i++) {
        if (i > 8) top->resetn = 1;
        top->clk = !top->clk;
        top->eval();
        if (Verilated::gotFinish()) break;
    }

    delete top;
    return 0;
}
