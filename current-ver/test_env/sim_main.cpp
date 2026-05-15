#include "Vtb_cpu.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vtb_cpu* top = new Vtb_cpu;

    Verilated::traceEverOn(true);
    VerilatedVcdC* tfp = new VerilatedVcdC;
    top->trace(tfp, 99);
    tfp->open("waveform.vcd");

    top->clk = 0;
    top->resetn = 0;

    for (int i = 0; i < 10000; i++) {
        if (i > 5) top->resetn = 1;
        top->clk = !top->clk;
        top->eval();
        tfp->dump(i);
        if (Verilated::gotFinish()) break;
    }

    tfp->close();
    delete top;
    return 0;
}
