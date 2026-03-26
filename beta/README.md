# PHANTOM-16

A complete 16-bit pipelined CPU implemented in synthesisable Verilog,
with a custom ISA, Python assembler, and self-checking testbenches.

---

## Files

```
phantom16/
├── isa.vh          ISA constants (opcodes, ALU codes) — included by all modules
├── alu.v           Combinational ALU
├── cpu.v           5-stage pipelined CPU core
├── soc.v           System-on-Chip (CPU + instruction ROM + data RAM)
├── tb_icarus.v     Icarus Verilog testbench
├── tb_verilator.cpp Verilator C++ testbench
├── assembler.py    Python assembler: .asm → .hex
├── demo.asm        Demo program in assembly
├── program.hex     Pre-assembled demo (used by soc.v at simulation time)
└── Makefile
```

---

## Quick start

```bash
# Simulate with Icarus (fastest to get started)
make icarus

# Simulate with Verilator (faster for large test runs)
make verilator

# View waveforms
make wave

# Assemble your own program
python3 assembler.py demo.asm -v
# → writes demo.hex, prints listing with addresses, hex, binary, and labels
# Copy the output to program.hex, then re-run make icarus
```

---

## Architecture

### Pipeline stages

```
IF  →  ID  →  EX  →  MEM  →  WB
```

| Stage | Work done |
|-------|-----------|
| IF    | Fetch instruction word from IMEM using PC |
| ID    | Decode opcode, read register file, generate immediate |
| EX    | ALU operation, branch/jump decision, forwarding |
| MEM   | Data memory read (LW) or write (SW) |
| WB    | Write result back to register file |

### Hazards

**Data hazard — full forwarding**
EX/MEM and MEM/WB results are forwarded back to the EX stage operand
muxes. No stall is needed for back-to-back ALU instructions.

```
ADD R1, R2, R3   ← produces R1 in EX
ADD R4, R1, R5   ← needs R1: forwarded from EX/MEM register, no stall
```

**Load-use hazard — 1 stall cycle**
A load (LW) followed immediately by an instruction that uses the loaded
register cannot be forwarded in time. The hazard unit stalls the PC and
IF/ID register for one cycle, then the value arrives via MEM/WB forwarding.

```
LW  R1, R2, 0    ← result available after MEM
ADD R3, R1, R4   ← 1 bubble inserted automatically; no change needed in your code
```

**Control hazard — 2 flush cycles**
Branches and jumps are resolved in EX. If taken, the two instructions
that entered IF and ID behind the branch are wrong — they are flushed
(replaced with NOPs) and the PC is redirected to the target.

### Register file

| Register | Purpose |
|----------|---------|
| R0 | Hardwired zero — reads always return 0, writes are discarded |
| R1–R7 | General purpose |

### ISA quick reference

```
; Arithmetic / logic
ADD  rd, rs1, rs2        rd = rs1 + rs2
SUB  rd, rs1, rs2        rd = rs1 - rs2
AND  rd, rs1, rs2        rd = rs1 & rs2
OR   rd, rs1, rs2        rd = rs1 | rs2
XOR  rd, rs1, rs2        rd = rs1 ^ rs2
SHL  rd, rs1, rs2        rd = rs1 << rs2[3:0]
SHR  rd, rs1, rs2        rd = rs1 >> rs2[3:0]
ADDI rd, rs1, imm6       rd = rs1 + sext(imm6)
LI   rd, imm9            rd = zext(imm9)          (load 9-bit constant)

; Memory  (word-addressed)
LW   rd,  rs1, imm6      rd = mem[rs1 + sext(imm6)]
SW   rs2, rs1, imm6      mem[rs1 + sext(imm6)] = rs2

; Branches  (offset relative to PC+1)
BEQ  rs1, rs2, label     if rs1 == rs2: PC = (PC+1) + sext(imm6)
BNE  rs1, rs2, label     if rs1 != rs2: PC = (PC+1) + sext(imm6)

; Jumps
JMP  rd, label           rd = PC+1 ; PC = (PC+1) + sext(imm9)
JALR rd, rs1, imm6       rd = PC+1 ; PC = rs1 + sext(imm6)

; System
NOP                      no operation
HALT                     stop the CPU (halted output goes high)
```

### Immediate ranges

| Field | Bits | Signed range | Used by |
|-------|------|-------------|---------|
| imm6  | 6    | −32 … +31   | ADDI, LW, SW, BEQ, BNE, JALR |
| imm9  | 9    | −256 … +255 (signed, JMP) | JMP |
| imm9  | 9    | 0 … 511 (unsigned, LI)   | LI |

---

## Writing your own programs

1. Write `yourprogram.asm` following the syntax in `demo.asm`
2. Assemble it:
   ```bash
   python3 assembler.py yourprogram.asm -v
   ```
3. Copy the output hex file over program.hex:
   ```bash
   cp yourprogram.hex program.hex
   ```
4. Update the assertions in `tb_icarus.v` / `tb_verilator.cpp` to match
   your expected register and memory values
5. Run `make icarus` or `make verilator`

---

## FPGA deployment (Gowin / Tang Console)

The design is written to Gowin synthesis constraints:

- All registers use synchronous active-low reset
- No `#delay` statements in synthesisable files
- Memory arrays (`imem`, `dmem`) use the standard `$readmemh` init pattern
  which Gowin synthesis maps to initialised BRAM
- `isa.vh` uses `` `include `` guards so it is safe to include from multiple files
- The `initial` blocks in the register file and dmem are testbench-compatible
  zero-init; on FPGA these are handled by the BRAM power-on reset

To target the Tang Console 138K specifically:

1. Create a new Gowin project, add all `.v` files
2. Set `soc` as the top-level module
3. Add a constraint file mapping `clk` and `resetn` to your board's oscillator
   and a button respectively
4. Replace the `$readmemh` line in `soc.v` with a BRAM primitive init if the
   synthesiser does not handle it automatically (GowinEDA does support it)
5. Synthesise, place & route, generate bitstream, flash
