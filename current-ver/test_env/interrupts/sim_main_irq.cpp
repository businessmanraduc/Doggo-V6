#include "Vtb_irq.h"
#include "verilated.h"
#include "verilated_vcd_c.h"
#include <cstdio>

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vtb_irq* top = new Vtb_irq;

    Verilated::traceEverOn(true);
    VerilatedVcdC* tfp = new VerilatedVcdC;
    top->trace(tfp, 99);
    tfp->open("irq_waveform.vcd");

    top->clk    = 0;
    top->resetn = 0;

    for (int i = 0; i < 50000; i++) {
        if (i > 5) top->resetn = 1;
        top->clk = !top->clk;
        top->eval();
        tfp->dump(i);
        if (Verilated::gotFinish()) break;
    }

    if (!Verilated::gotFinish()) {
        printf("TIMEOUT: IRQ test did not complete within iteration limit\n");
    }

    tfp->close();
    delete top;
    return 0;
}
