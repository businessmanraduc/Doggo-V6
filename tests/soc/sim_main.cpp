#include "Vtb_soc.h"
#include "verilated.h"

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vtb_soc* top = new Vtb_soc;

    top->clk = 0;
    top->resetn = 0;

    for (int i = 0; i < 200000; i++) {
        if (i > 5) top->resetn = 1;
        top->clk = !top->clk;
        top->eval();
        if (Verilated::gotFinish()) break;
    }

    delete top;
    return 0;
}
