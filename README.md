# PHANTOM-32

A 32-bit RISC-V soft processor (RV32IMC) written in SystemVerilog for the Lattice
ECP5, targeting the ULX3S 85K board.

PHANTOM-32 is an in-order, six-stage pipelined core built from scratch. It runs the
full RV32I base integer set plus the M (multiply/divide) and C (compressed) extensions, handles machine-mode
traps and interrupts, and is designed to grow - caches, SDRAM, and supervisor mode
are on the roadmap. The microarchitecture takes after the RVCoreP-32IC design, with
a number of changes of its own along the way.

## What it does

- Full RV32IMC: every base integer, multiply/divide, and compressed instruction
- Six-stage in-order pipeline - PreIF, IF, ID, EX, MA, WB
- Dual-port fetch with two program counters, so a 32-bit instruction that straddles
  a fetch boundary costs nothing extra
- Parallel 16/32-bit decode: compressed instructions are decoded directly, not
  expanded on the critical path
- Operand-ready scoreboard in the regfile: a dependent instruction stalls in ID
  until its producer commits (no forwarding network - a deliberate trade of IPC for
  a shorter critical path / higher Fmax)
- Gshare branch predictor - 8192-entry PHT plus a 512-entry BTB
- Machine-mode CSRs, precise traps, and a CLINT for timer and software interrupts

## Status

The core is complete in simulation and passes all 52 RISC-V architectural compliance
tests (39 rv32ui/rv32uc, 8 rv32um, and 5 rv32mi). Synthesis through Yosys is clean. On-board
bring-up - place-and-route, bitstream, and UART output on real hardware - is the next
step, waiting on the board itself.

## Building and testing

The toolchain is entirely open source: Verilator for simulation, and Yosys,
nextpnr-ecp5, prjtrellis, and openFPGALoader for hardware. A Nix shell (`shell.nix`)
pins all of it.

```sh
# directed pipeline test
cd tests/pipeline && make

# full RISC-V compliance suite
./run_compliance.sh

# synthesise for the ECP5
cd synth && make synth
```

## Documentation

The full microarchitecture - pipeline stages, hazard handling, the branch predictor,
and every module and pipeline register - is written up in
[`PHANTOM32_Architecture.md`](./docs/PHANTOM32_Architecture.md).

---

© 2026 Radu Arseni. All Rights Reserved.

This project is source-available for viewing only. Cloning, forking, modification,
use, or redistribution is prohibited without written permission - see
[`LICENSE`](./LICENSE).
