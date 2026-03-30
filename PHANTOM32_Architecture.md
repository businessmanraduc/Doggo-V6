# PHANTOM-32 — RV32IC Soft Processor
## Architecture Reference Document
### Version 0.1 — Pre-Implementation Draft

---

## Table of Contents

1. [Overview and Design Goals](#1-overview-and-design-goals)
2. [Top-Level Block Diagram](#2-top-level-block-diagram)
3. [Memory Architecture — Phase 1 (BRAM-only)](#3-memory-architecture--phase-1-bram-only)
4. [Pipeline Overview](#4-pipeline-overview)
5. [The Fetch Unit](#5-the-fetch-unit)
6. [The Parallel Decoder Architecture](#6-the-parallel-decoder-architecture)
7. [Stage-by-Stage Description](#7-stage-by-stage-description)
8. [Complete Pipeline Register Reference](#8-complete-pipeline-register-reference)
9. [Hazard Handling](#9-hazard-handling)
10. [M-Mode Trap Handling](#10-m-mode-trap-handling)
11. [Register File](#11-register-file)
12. [ALU](#12-alu)
13. [Instruction Coverage](#13-instruction-coverage)
14. [Branch Prediction — Phase 1](#14-branch-prediction--phase-1)
15. [Memory Interface Specification](#15-memory-interface-specification)
16. [Control Signal Reference](#16-control-signal-reference)
17. [Naming Conventions and Style Guide](#17-naming-conventions-and-style-guide)
18. [Implementation Phases and Roadmap](#18-implementation-phases-and-roadmap)

---

## 1. Overview and Design Goals

**PHANTOM-32** is a 32-bit soft processor targeting the Gowin GW2AR-18 FPGA (as found on the
Sipeed Tang Nano 20K). It implements the **RV32IC** ISA — the RISC-V base integer ISA (RV32I) plus
the compressed instruction extension (RV32C) — and is designed to be extended with the M extension
(multiply/divide) and an MMU/cache hierarchy in later phases.

### Primary Design Goals (Phase 1)

| Goal | Decision |
|------|----------|
| ISA | RV32IC — full base integer set plus all RV32C compressed instructions |
| Pipeline | 6-stage in-order pipeline: PreIF → IF → ID → EX → MA → WB |
| Fetch unit | Dual-port BRAM approach (after RVCoreP-32IC) — no stall on unaligned 32-bit fetch |
| Decoder | Parallel decode of 16-bit and 32-bit formats — no decompressor on the critical path |
| Data hazards | Full forwarding: EX→EX and MA→EX paths, no stall for back-to-back ALU |
| Load-use hazard | 1 stall cycle inserted automatically by hazard detection unit |
| Control hazards | Always-not-taken predictor; 2-cycle flush penalty on taken branch/jump |
| Exception handling | M-mode only (mtvec, mepc, mcause, mstatus, mie, mip); ECALL, EBREAK, illegal instruction, misaligned address |
| Register file | 32 × 32-bit, LUT-RAM, two async read ports, one sync write port |
| Memory | Separate instruction BRAM (16-bit wide, dual-port) and data BRAM (32-bit wide, byte enables) |
| Target FPGA | Gowin GW2AR-18 (Tang Nano 20K): 20,736 LUT4, 828 Kbit BRAM, 64 Mbit embedded SDRAM |

### Out-of-Scope for Phase 1

- M extension (multiply/divide) — to be added as Phase 3
- SDRAM controller — to be added as Phase 2
- MMU and virtual memory — to be added as Phase 2
- Supervisor mode (S-mode) — to be added alongside MMU
- Interrupts (CLINT/PLIC) — to be added as Phase 2
- Gshare branch predictor (BTB + PHT) — to be added as Phase 2
- Peripherals (UART, HDMI, PS/2) — to be added as Phase 2 / Phase 3

---

## 2. Top-Level Block Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│                            SoC (soc.v)                                  │
│                                                                         │
│  ┌────────────────────────────────────────────────────────────────────┐ │
│  │                        CPU Core (cpu.v)                            │ │
│  │                                                                    │ │
│  │   ┌───────┐  ┌───────┐  ┌───────┐  ┌───────┐  ┌───────┐  ┌──────┐  │ │
│  │   │ PreIF │→ │  IF   │→ │  ID   │→ │  EX   │→ │  MA   │→ │  WB  │  │ │
│  │   │  (I)  │  │ (II)  │  │ (III) │  │ (IV)  │  │  (V)  │  │ (VI) │  │ │
│  │   └───────┘  └───────┘  └───────┘  └───────┘  └───────┘  └──────┘  │ │
│  │       │          │                     │          │          │     │ │
│  │ imem_addr_a  imem_data_a           flush      dmem_addr   regfile  │ │
│  │ imem_addr_b  imem_data_b           TruePC     dmem_we     write    │ │
│  │                                    TruePC_2   dmem_wdata           │ │
│  │                                               dmem_rdata           │ │
│  └────────────────────────────────────────────────────────────────────┘ │
│         │         │                                    │                │
│  ┌──────┴───────┐ │                           ┌────────┴──────┐         │
│  │  IMEM (BRAM) │ │                           │  DMEM (BRAM)  │         │
│  │  16-bit wide │ │                           │  32-bit wide  │         │
│  │  Dual-port   │ │                           │  Byte enables │         │
│  │  (Phase 1)   │ │                           │  (Phase 1)    │         │
│  └──────────────┘ │                           └───────────────┘         │
│                   │  (Phase 2 additions below this line)                │
│            ┌──────┴───────┐                                             │
│            │  I-Cache /   │                                             │
│            │  D-Cache     │   ←─ replaces direct BRAM in Phase 2        │
│            └──────┬───────┘                                             │
│                   │                                                     │
│            ┌──────┴───────┐                                             │
│            │   SDRAM Ctrl │                                             │
│            │  (64Mbit)    │                                             │
│            └──────────────┘                                             │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Memory Architecture — Phase 1 (BRAM-only)

Phase 1 uses only the on-chip BRAM of the GW2AR-18. No SDRAM, no cache, no MMU.
The CPU talks directly to two BRAM blocks: one for instructions, one for data.

### 3.1 Instruction Memory (IMEM)

| Property | Value |
|----------|-------|
| Width | 16 bits per entry |
| Organisation | Halfword-addressed (each address selects one 16-bit halfword) |
| Ports | Dual-port (both ports read simultaneously, no write from CPU) |
| Port A address | `PC[IMEM_ADDR_W:1]` — the halfword at PC |
| Port B address | `PC[IMEM_ADDR_W:1] + 1` — the halfword immediately after |
| Read latency | 1 cycle (synchronous BRAM read — address registered, data next cycle) |
| Initial size | 4096 entries = 8 KB (parameterised: `IMEM_DEPTH`) |
| Init | `$readmemh("program.hex", imem)` |

**Why 16-bit width?** The RVCoreP-32IC paper demonstrates that switching to 16-bit wide IMEM
and using both BRAM ports simultaneously is the key to fetching any instruction (compressed or not,
aligned or misaligned across a 32-bit boundary) in a single cycle. With a 32-bit wide IMEM,
a 32-bit instruction straddling a 32-bit boundary requires two separate accesses — killing IPC.

**Why dual-port simultaneous access?** The Gowin GW2AR-18 BSRAM blocks support true dual-port
(TDP) mode. Port A and Port B can read different addresses in the same cycle. By reading address
`PC>>1` on Port A and `(PC>>1)+1` on Port B, we always capture both halves of any instruction
in one clock cycle regardless of its alignment.

### 3.2 Data Memory (DMEM)

| Property | Value |
|----------|-------|
| Width | 32 bits per entry |
| Organisation | Word-addressed (each address selects one 32-bit word) |
| Ports | Single-port (one read or write per cycle; read is combinational for timing) |
| Read | Asynchronous (combinational) to avoid adding a pipeline stage for loads |
| Write | Synchronous, controlled by `dmem_we[3:0]` (4 byte-enables) |
| Initial size | 1024 entries = 4 KB (parameterised: `DMEM_DEPTH`) |

**Byte enables:** The four individual byte-write-enable bits allow SB/SH/SW to write 1, 2, or 4
bytes respectively without a read-modify-write cycle. The byte enable pattern is derived from the
effective address `[1:0]` and the store width (SB/SH/SW) in the MA stage.

| Instruction | addr[1:0] | dmem_we[3:0] | Bytes written |
|-------------|-----------|--------------|---------------|
| SW          | 00        | 1111         | All 4 |
| SH          | 00        | 0011         | bytes 1:0 |
| SH          | 10        | 1100         | bytes 3:2 |
| SB          | 00        | 0001         | byte 0 |
| SB          | 01        | 0010         | byte 1 |
| SB          | 10        | 0100         | byte 2 |
| SB          | 11        | 1000         | byte 3 |

**Load sign extension** is handled in the MA or WB stage based on the load width (LB/LH/LW) and
signedness (LBU/LHU), using the same `addr[1:0]` to select which byte/halfword to extract from
the 32-bit DMEM word.

### 3.3 BRAM Budget (Phase 1)

The GW2AR-18 provides 828 Kbit ≈ 103.5 KB of BRAM.

| Block | Size | BRAM cost |
|-------|------|-----------|
| IMEM (8 KB) | 4096 × 16-bit | 65,536 bits |
| DMEM (4 KB) | 1024 × 32-bit | 32,768 bits |
| Register file | 32 × 32-bit (LUT-RAM, NOT BRAM) | 0 bits |
| **Phase 1 total** | | **98,304 bits ≈ 12 KB ≈ 12% of BRAM** |

This leaves the vast majority of BRAM free for Phase 2 (I-cache, D-cache, BTB, PHT).

---

## 4. Pipeline Overview

### 4.1 Stage List

```
┌──────────┐  ┌──────────┐  ┌────────────┐  ┌───────────┐  ┌──────────┐  ┌──────────┐
│  Stage I │  │ Stage II │  │ Stage III  │  │ Stage IV  │  │  Stage V │  │ Stage VI │
│          │  │          │  │            │  │           │  │          │  │          │
│  PreIF   │─▶│    IF    │─▶│    ID      │─▶│    EX     │─▶│    MA    │─▶│    WB    │
│          │  │          │  │            │  │           │  │          │  │          │
│ Pre-Fetch│  │ Fetch    │  │ Decode     │  │ Execute   │  │ Memory   │  │ WriteBack│
└──────────┘  └──────────┘  └────────────┘  └───────────┘  └──────────┘  └──────────┘
     │              │             │               │             │             │
  Compute     Receive BRAM   Decode instr,   ALU, branch   Data memory   Write result
  next PC,    data, form     read regfile,   resolution,   read/write,   to regfile,
  drive BRAM  32-bit instr   gen immediate,  forwarding    load extend   handle HALT
  addresses   window,        hazard detect,
              detect         control signals
              size (16/32)
```

### 4.2 Pipeline Register Naming Convention

Following the PHANTOM-16 convention: **`StageN_`** signals are the pipeline registers that
**feed Stage N**. They are written at the end of Stage N-1 and read throughout Stage N.

| Register Prefix | Between Stages | Written by | Read by |
|----------------|----------------|------------|---------|
| `StageII_`     | PreIF → IF     | PreIF      | IF      |
| `StageIII_`    | IF → ID        | IF         | ID      |
| `StageIV_`     | ID → EX        | ID         | EX      |
| `StageV_`      | EX → MA        | EX         | MA      |
| `StageVI_`     | MA → WB        | MA         | WB      |

Stage I (PreIF) does not have an input pipeline register — it is driven by the PC register directly.

### 4.3 Pipeline Timing Example (single ADD instruction)

```
Cycle:    1       2       3       4       5       6       7
         ─────── ─────── ─────── ─────── ─────── ─────── ───────
ADD:      PreIF   IF      ID      EX      MA      WB
NOP:              PreIF   IF      ID      EX      MA      WB
NOP:                      PreIF   IF      ID      EX      MA
```

A result written in EX (end of cycle 4) is available for forwarding into EX of the next instruction
(beginning of cycle 4 for the dependent instruction — i.e., it must be ready by the end of cycle 3
to be muxed in). The forwarding paths handle this correctly.

---

## 5. The Fetch Unit

This is the most novel part of the design, following the RVCoreP-32IC paper. Understanding it
thoroughly before writing any code is critical.

### 5.1 The Core Problem

In RV32IC, the instruction stream contains a mix of 16-bit and 32-bit instructions. The only rule
is halfword alignment: every instruction starts on a 2-byte boundary. There is no 4-byte alignment
guarantee.

This means a 32-bit instruction can straddle a 32-bit memory boundary:

```
Byte address:   0x00  0x02  0x04  0x06  0x08  0x0A
                ─────────────────────────────────────
Instruction:    [   32-bit A  ] [16b B] [   32-bit C  ]
                                              ↑
                           This instruction starts at 0x06, and its upper 16 bits
                           are at 0x08 — in the NEXT 32-bit-aligned word.
```

If IMEM is 32-bit wide, fetching instruction C requires two separate memory accesses: one for
the word at `0x04` (to get C's lower 16 bits) and one for the word at `0x08` (to get C's upper
16 bits). This is a stall every time this situation occurs — and it occurs frequently.

### 5.2 The Solution: 16-bit IMEM + Dual-Port Simultaneous Access

We use a 16-bit wide IMEM. Every entry holds exactly one 16-bit halfword. We access two
consecutive entries simultaneously using both BRAM ports:

- **Port A**: reads entry at address `PC[N:1]` → provides halfword at `PC`
- **Port B**: reads entry at address `PC[N:1] + 1` → provides halfword at `PC+2`

The IF stage receives `{PortB_data, PortA_data}` — a 32-bit window starting exactly at PC.

```
PC = 0x06:

  Port A reads entry 3 (address 0x06): lower 16 bits of instruction C
  Port B reads entry 4 (address 0x08): upper 16 bits of instruction C

  {PortB, PortA} = {upper_C, lower_C} = complete instruction C ✓
```

This works for every case:
- **16-bit instruction at PC**: PortA contains the full instruction; PortB is ignored
- **32-bit instruction, 4-byte aligned**: PortA has lower half, PortB has upper half
- **32-bit instruction, NOT 4-byte aligned**: PortA has lower half, PortB has upper half (same thing!)

There is **never a stall due to alignment**. Every instruction is always fully available in one cycle.

### 5.3 Instruction Size Detection

The size of the instruction at PC is determined by bits [1:0] of `PortA_data` (the halfword at PC):

```
PortA_data[1:0] == 2'b11  →  32-bit instruction  →  consume {PortB, PortA}, advance PC by 4
PortA_data[1:0] != 2'b11  →  16-bit instruction  →  consume PortA only,    advance PC by 2
```

This flag (`is_compressed`) is computed combinationally in the IF stage from the raw BRAM output.

### 5.4 PC and PC_2 Management

Because BRAM reads are synchronous (address is registered, data arrives next cycle), the BRAM
address must be driven **one cycle ahead** of when the data is needed. The PreIF stage handles this.

At any given moment, PreIF must select the correct **NextPC** to drive into the BRAM address
registers. There are five candidates:

| Candidate | When used |
|-----------|-----------|
| `PC + 2` | Current instruction is 16-bit, no stall, no flush |
| `PC + 4` | Current instruction is 32-bit, no stall, no flush |
| `PC`     | Stall (load-use hazard) — hold the current address |
| `PredPC` | Branch prediction says taken (Phase 1: never used; always not-taken) |
| `TruePC` | Branch misprediction correction from EX stage |

The dual-port nature requires that **both** `NextPC` and `NextPC + 2` are driven to the BRAM
simultaneously. Therefore, each of the five PC candidates also has a corresponding `+2` version:

| PC candidate | PC_2 companion | How PC_2 is computed |
|-------------|----------------|----------------------|
| `PC + 2`    | `PC + 4`       | Pre-computed in adder tree |
| `PC + 4`    | `PC + 6`       | Pre-computed in adder tree |
| `PC`        | `PC + 2`       | Pre-computed in adder tree |
| `PredPC`    | `PredPC + 2`   | Adder after BTB (Phase 2) |
| `TruePC`    | `TruePC + 2`   | Computed in EX stage, both sent to PreIF |

**Critical insight from the paper**: `PC+2, PC+4, PC+6` can all be pre-computed by replicating
the adder logic for PC. `TruePC_2 = TruePC + 2` is computed in the EX stage pipeline alongside
the normal `TruePC` calculation. This means **no extra adder lands on the critical path** — all
PC_2 candidates are ready in parallel with their corresponding PC candidates.

### 5.5 PC Update Rules (priority order)

```
if (flush)            NextPC = TruePC;    NextPC_2 = TruePC_2;
else if (stall)       NextPC = PC;        NextPC_2 = PC_2;
else if (is_compressed) NextPC = PC + 2; NextPC_2 = PC + 4;
else                  NextPC = PC + 4;   NextPC_2 = PC + 6;
```

`flush` has highest priority: a branch correction overrides everything including a stall.

### 5.6 TruePC_2 Calculation (in EX stage)

When a branch is resolved as taken in the EX stage, we need to provide both `TruePC` and
`TruePC_2` to the PreIF stage for the dual-port fetch.

The branch target (TruePC) is:
- For conditional branches (BEQ, BNE, BLT, etc.): `StageIV_PC + sext(imm)`
- For JAL: `StageIV_PC + sext(imm)`
- For JALR: `(rs1 + sext(imm)) & ~1`

`TruePC_2 = TruePC + 2` always. Both are computed in the EX stage and registered into
`StageV_TruePC` and `StageV_TruePC_2` for forwarding back to PreIF.

Wait — we resolve in EX and flush immediately. The TruePC drives the PC update directly from EX
(not from MA as in the paper). So in our design, TruePC and TruePC_2 are computed combinationally
in EX and registered into StageV_ for reference, but the **flush and redirect happen in the same
cycle EX resolves the branch** (i.e., TruePC drives NextPC combinationally, not through a register).

---

## 6. The Parallel Decoder Architecture

### 6.1 Why Not a Decompressor?

The naive approach for handling compressed instructions is:

```
PortA data → Decompressor → 32-bit equivalent → Decoder → control signals
```

The problem: the Decompressor adds gate delay before the Decoder, lengthening the critical path
and reducing the maximum operating frequency. VexRiscv uses this approach and achieves only 130 MHz
on Artix-7. RVCoreP-32IC achieves 165 MHz by avoiding it.

### 6.2 The Parallel Decode Approach

Instead of sequentializing, we decode both formats **simultaneously**:

```
                 ┌──────────────────────┐
                 │  32-bit decoder path │ → 32-bit control signals
PortA + PortB ──▶│                      │
                 │  16-bit decoder path │ → 16-bit control signals
                 └──────────────────────┘
                              │
                         is_compressed MUX
                              │
                        Final control signals
```

Both decoders run in parallel on the same input bits. The MUX at the output selects which set of
decoded control signals to use, based on `is_compressed`. A MUX is a single LUT delay, far cheaper
than putting the decompressor in the combinational chain.

### 6.3 ParallelDecoderIF (in the IF stage)

The IF stage needs to do a **lightweight decode** to support the load-use hazard detection that
happens in the ID stage. The hazard detector needs to see the register indices of the instruction
currently in ID (`StageIV_destRegIndex`) and the instruction currently in IF (`StageIII_`) before
full decode is complete.

ParallelDecoderIF extracts, for both the 32-bit and 16-bit interpretations:
- `rs1_index [4:0]`: first source register index
- `rs2_index [4:0]`: second source register index
- `rd_index  [4:0]`: destination register index
- `is_load`: whether this instruction is a load (for load-use detection)
- `is_compressed`: whether this is a 16-bit instruction

For compressed instructions, register indices may use the "compressed register" encoding (CL/CS/CB
formats use a 3-bit field that maps to registers x8–x15: `{2'b01, field[2:0]}`).

### 6.4 ParallelDecoderID (in the ID stage)

Full decode happens in ID. Both paths run simultaneously:

**32-bit decode path** (standard RV32I):
- Extracts opcode `[6:0]`, func3 `[14:12]`, func7 `[31:25]`
- Generates 32-bit immediate (I/S/B/U/J types)
- Produces all control signals (see Section 16)

**16-bit decode path** (RV32C):
- Extracts the 2-bit quadrant `[1:0]` and 3-bit funct3 `[15:13]`
- Translates to equivalent control signals directly, without constructing the 32-bit form
- Generates the immediate specific to each C format (CI, CSS, CIW, CL, CS, CB, CJ, CR)

The MUX selects based on `StageIII_IsCompressed` (the size flag propagated from IF).

---

## 7. Stage-by-Stage Description

### 7.1 Stage I — PreIF (Pre-Instruction-Fetch)

**Inputs**: Current PC register, `flush` signal from EX, `stall` signal from ID hazard unit,
`TruePC` and `TruePC_2` from EX, `is_compressed` from IF (StageIII_IsCompressed).

**Work done this stage**:
1. Select `NextPC` from the five candidates using the priority mux (Section 5.5)
2. Compute `NextPC_2 = NextPC + 2` in parallel
3. Register the PC: `PC <= NextPC` on posedge clk
4. Drive both BRAM port addresses: `imem_addr_a = NextPC[N:1]`, `imem_addr_b = NextPC[N:1] + 1`

**Output to IF** (StageII_ registers, loaded on posedge clk):
- `StageII_PC`: the PC whose data will arrive from BRAM next cycle

**Note on reset**: On reset, PC is set to `RESET_VECTOR` (default: `32'h0000_0000`). The first
valid instruction arrives in IF two cycles later (one cycle for PC to be driven to BRAM, one for
BRAM read latency). The pipeline starts with NOP bubbles filling the early stages.

---

### 7.2 Stage II — IF (Instruction Fetch)

**Inputs**: `imem_data_a [15:0]` and `imem_data_b [15:0]` from BRAM (now valid, based on
address driven last cycle by PreIF), `StageII_PC`.

**Work done this stage**:
1. Form the 32-bit window: `raw_window = {imem_data_b, imem_data_a}`
2. Detect instruction size: `is_compressed = (imem_data_a[1:0] != 2'b11)`
3. Run ParallelDecoderIF: extract rs1, rs2, rd indices and is_load flag for both interpretations
4. Select the correct index values based on `is_compressed`
5. Compute `PC_plus_2 = StageII_PC + 2` and `PC_plus_4 = StageII_PC + 4` for branch target
   calculation downstream

**Output to ID** (StageIII_ registers):
- `StageIII_PC [31:0]`: PC of this instruction
- `StageIII_Instr [31:0]`: the 32-bit window (raw, NOT decompressed)
- `StageIII_IsCompressed`: 1 if 16-bit instruction, 0 if 32-bit
- `StageIII_rs1_index [4:0]`: from ParallelDecoderIF (for hazard detection)
- `StageIII_rs2_index [4:0]`: from ParallelDecoderIF (for hazard detection)
- `StageIII_rd_index [4:0]`:  from ParallelDecoderIF (for hazard detection)
- `StageIII_isLoad`: from ParallelDecoderIF (for load-use hazard detection)

**Flush behaviour**: If `flush` is asserted, StageIII_ is loaded with all-zeros/NOP values.
The instruction currently being fetched is discarded.

---

### 7.3 Stage III — ID (Instruction Decode)

**Inputs**: StageIII_ registers, register file read data.

**Work done this stage**:
1. Run ParallelDecoderID: full decode of both 32-bit and 16-bit paths in parallel, MUX on
   `StageIII_IsCompressed`
2. Generate the 32-bit sign-extended immediate (5 types for RV32I + C-format immediates)
3. Compute `IMM_2 = immediate + 2` (for TruePC_2 calculation in EX — see Section 5.6)
4. Read register file: async read of rs1 and rs2
5. Apply WB write-before-read forwarding (if WB is writing to the same register we are reading,
   forward the new value immediately — eliminates the WB→ID forwarding distance as a hazard case)
6. Hazard detection: check for load-use hazard (see Section 9.2)
7. Produce all control signals

**Register file read with write-before-read**:
```
rs1_data = (StageVI_writeEnable && StageVI_writeRegIndex == StageIII_rs1_index) ?
               StageVI_writeData :
           (StageIII_rs1_index == 5'd0) ? 32'h0 :
           regFile[StageIII_rs1_index];
```
(and similarly for rs2_data). This eliminates the WB→ID forwarding path from the EX forwarding
unit — WB→ID is handled here for free by the write-before-read logic.

**Output to EX** (StageIV_ registers):
- `StageIV_PC [31:0]`
- `StageIV_IsCompressed`: needed for TruePC_2 calculation
- `StageIV_rs1_index [4:0]`, `StageIV_rs2_index [4:0]`, `StageIV_rd_index [4:0]`
- `StageIV_rs1_data [31:0]`, `StageIV_rs2_data [31:0]`
- `StageIV_Imm [31:0]`: sign-extended immediate
- `StageIV_Imm2 [31:0]`: immediate + 2 (for TruePC_2)
- All control signals: `StageIV_destRegWrite`, `StageIV_memRead`, `StageIV_memWrite`,
  `StageIV_Branch`, `StageIV_Jump`, `StageIV_ALUBSel`, `StageIV_memToReg`,
  `StageIV_ALUOpcode [3:0]`, `StageIV_BranchCond [2:0]`, `StageIV_isJALR`,
  `StageIV_isLinkReg`, `StageIV_loadWidth [2:0]`, `StageIV_storeWidth [1:0]`,
  `StageIV_isCSR`, `StageIV_CSR_addr [11:0]`, `StageIV_CSR_op [1:0]`,
  `StageIV_isECALL`, `StageIV_isEBREAK`, `StageIV_isIllegal`, `StageIV_HALT`

**Flush/stall behaviour**:
- `flush`: load StageIV_ with NOP bubble (all control signals = 0)
- `stall`: also load StageIV_ with NOP bubble; additionally, PC and StageIII_ are frozen

---

### 7.4 Stage IV — EX (Execute)

**Inputs**: StageIV_ registers, forwarded values from StageV_ (EX/MA) and StageVI_ (MA/WB).

**Work done this stage**:
1. Forwarding mux: select correct rs1 and rs2 values (see Section 9.1)
2. ALU B-operand select: register value or immediate
3. ALU: compute result
4. Branch resolution:
   - Compare rs1 and rs2 using `BranchCond` (EQ/NE/LT/GE/LTU/GEU)
   - Set `branchTaken` flag
   - Compute `TruePC` and `TruePC_2`
5. Jump (JAL/JALR) always sets `doJump = 1`
6. `flush = branchTaken || doJump`
7. Link register value: `PC + 2` (if compressed) or `PC + 4` (if 32-bit), written to rd for
   JAL/JALR
8. M-mode trap detection: ECALL, EBREAK, illegal instruction (see Section 10)

**TruePC computation**:
```
For JAL, branches:
    TruePC   = StageIV_PC + StageIV_Imm[31:0]
    TruePC_2 = StageIV_PC + StageIV_Imm2[31:0]   (= TruePC + 2, using pre-computed IMM_2)

For JALR:
    TruePC   = (StageIV_rs1_data_forwarded + StageIV_Imm) & ~32'h1
    TruePC_2 = TruePC + 2
```

**Output to MA** (StageV_ registers):
- `StageV_PC [31:0]`
- `StageV_ALUResult [31:0]`
- `StageV_rs2_data [31:0]` (forwarded, for store data)
- `StageV_rd_index [4:0]`
- `StageV_destRegWrite`
- `StageV_memRead`, `StageV_memWrite`
- `StageV_memToReg`
- `StageV_loadWidth [2:0]`, `StageV_storeWidth [1:0]`
- `StageV_isCSR`, `StageV_CSR_addr [11:0]`, `StageV_CSR_op [1:0]`, `StageV_CSR_wdata [31:0]`
- `StageV_isTrap`, `StageV_trapCause [3:0]`, `StageV_trapPC [31:0]`
- `StageV_isMRET`
- `StageV_HALT`
- `StageV_LinkValue [31:0]` (PC+2 or PC+4, the return address for JAL/JALR)
- `StageV_isLink` (1 if JAL/JALR — select LinkValue over ALUResult for register write)

Also driven combinationally (NOT via StageV_ registers, used directly by PreIF this same cycle):
- `flush [1]`: asserted when a branch is taken or a jump occurs
- `TruePC [31:0]`: branch/jump target
- `TruePC_2 [31:0]`: branch/jump target + 2

---

### 7.5 Stage V — MA (Memory Access)

**Inputs**: StageV_ registers, DMEM read data.

**Work done this stage**:
1. Drive DMEM interface:
   - `dmem_addr = StageV_ALUResult[DMEM_ADDR_W+1:2]` (word address, drop byte offset bits)
   - `dmem_we[3:0]`: byte enables derived from store width and `StageV_ALUResult[1:0]`
   - `dmem_wdata`: store data, byte/halfword replicated to all lanes as needed
2. Receive `dmem_rdata [31:0]` (combinational read, based on dmem_addr)
3. Load data extraction and sign/zero extension:
   - Select the correct byte or halfword from `dmem_rdata` using `StageV_ALUResult[1:0]`
   - Sign-extend or zero-extend based on `loadWidth`
4. CSR read/write: if the instruction is a CSR operation, perform the read-modify-write on the
   CSR register file (see Section 10.1)
5. Trap entry: if `StageV_isTrap`, begin trap entry sequence (see Section 10.2)
6. MRET: if `StageV_isMRET`, restore PC from mepc (see Section 10.3)

**Output to WB** (StageVI_ registers):
- `StageVI_rd_index [4:0]`
- `StageVI_destRegWrite`
- `StageVI_ALUResult [31:0]`
- `StageVI_loadData [31:0]` (sign/zero extended load result)
- `StageVI_memToReg`
- `StageVI_isLink`
- `StageVI_LinkValue [31:0]`
- `StageVI_HALT`

---

### 7.6 Stage VI — WB (Write Back)

**Inputs**: StageVI_ registers.

**Work done this stage**:
1. Select write data:
   - If `StageVI_isLink`: write `StageVI_LinkValue` (JAL/JALR return address)
   - Else if `StageVI_memToReg`: write `StageVI_loadData` (loaded value)
   - Else: write `StageVI_ALUResult`
2. Write to register file if `StageVI_destRegWrite && StageVI_rd_index != 5'd0`
3. Drive write-before-read forwarding signals (StageVI_writeEnable, StageVI_writeRegIndex,
   StageVI_writeData) for use in ID stage
4. Assert `halted` if `StageVI_HALT`

---

## 8. Complete Pipeline Register Reference

### 8.1 StageII_ Registers (PreIF → IF)

| Signal | Width | Description |
|--------|-------|-------------|
| `StageII_PC` | 32 | Byte address of the instruction being fetched this cycle |

### 8.2 StageIII_ Registers (IF → ID)

| Signal | Width | Description |
|--------|-------|-------------|
| `StageIII_PC` | 32 | Byte address of this instruction |
| `StageIII_Instr` | 32 | Raw 32-bit window `{imem_b, imem_a}` from BRAM |
| `StageIII_IsCompressed` | 1 | 1 = 16-bit C instruction; 0 = 32-bit instruction |
| `StageIII_rs1_index` | 5 | Source register 1 index (from ParallelDecoderIF) |
| `StageIII_rs2_index` | 5 | Source register 2 index (from ParallelDecoderIF) |
| `StageIII_rd_index` | 5 | Destination register index (from ParallelDecoderIF) |
| `StageIII_isLoad` | 1 | 1 = this is a load instruction (for load-use hazard) |

### 8.3 StageIV_ Registers (ID → EX)

| Signal | Width | Description |
|--------|-------|-------------|
| `StageIV_PC` | 32 | Byte address of this instruction |
| `StageIV_IsCompressed` | 1 | 1 = 16-bit instruction (for link address and TruePC_2) |
| `StageIV_rs1_index` | 5 | Source register 1 index |
| `StageIV_rs2_index` | 5 | Source register 2 index |
| `StageIV_rd_index` | 5 | Destination register index |
| `StageIV_rs1_data` | 32 | Value of rs1 (after write-before-read forwarding from WB) |
| `StageIV_rs2_data` | 32 | Value of rs2 (after write-before-read forwarding from WB) |
| `StageIV_Imm` | 32 | Sign-extended immediate |
| `StageIV_Imm2` | 32 | `Imm + 2` (pre-computed for TruePC_2) |
| `StageIV_destRegWrite` | 1 | 1 = write ALU/load/link result to rd in WB |
| `StageIV_memRead` | 1 | 1 = load instruction (LB/LBU/LH/LHU/LW) |
| `StageIV_memWrite` | 1 | 1 = store instruction (SB/SH/SW) |
| `StageIV_Branch` | 1 | 1 = conditional branch |
| `StageIV_Jump` | 1 | 1 = unconditional jump (JAL/JALR) |
| `StageIV_ALUBSel` | 1 | 0 = ALU B is rs2; 1 = ALU B is immediate |
| `StageIV_memToReg` | 1 | 0 = write ALU result; 1 = write loaded data |
| `StageIV_ALUOpcode` | 4 | ALU operation (see Section 12) |
| `StageIV_BranchCond` | 3 | Branch condition: EQ/NE/LT/GE/LTU/GEU (func3 value) |
| `StageIV_isJALR` | 1 | 1 = JALR (target from register, not PC-relative) |
| `StageIV_isLink` | 1 | 1 = JAL or JALR (write PC+2/4 to rd) |
| `StageIV_loadWidth` | 3 | 000=LB, 001=LH, 010=LW, 100=LBU, 101=LHU |
| `StageIV_storeWidth` | 2 | 00=SB, 01=SH, 10=SW |
| `StageIV_isCSR` | 1 | 1 = CSR instruction |
| `StageIV_CSR_addr` | 12 | CSR address field |
| `StageIV_CSR_op` | 2 | 00=RW, 01=RS, 10=RC (maps to func3[1:0]) |
| `StageIV_CSR_useImm` | 1 | 1 = CSRRWI/CSRRSI/CSRRCI (use zimm[4:0] not rs1) |
| `StageIV_isECALL` | 1 | ECALL instruction |
| `StageIV_isEBREAK` | 1 | EBREAK instruction |
| `StageIV_isIllegal` | 1 | Illegal/unrecognized instruction |
| `StageIV_HALT` | 1 | HALT (custom) — stop CPU when this retires |

### 8.4 StageV_ Registers (EX → MA)

| Signal | Width | Description |
|--------|-------|-------------|
| `StageV_PC` | 32 | Byte address of this instruction (for mepc on trap) |
| `StageV_rd_index` | 5 | Destination register index |
| `StageV_destRegWrite` | 1 | 1 = write to rd |
| `StageV_ALUResult` | 32 | ALU output (or link value if isLink) |
| `StageV_rs2_data` | 32 | Forwarded rs2 value (store data) |
| `StageV_memRead` | 1 | 1 = load |
| `StageV_memWrite` | 1 | 1 = store |
| `StageV_memToReg` | 1 | 0 = ALU result; 1 = load data |
| `StageV_isLink` | 1 | 1 = write link address to rd |
| `StageV_LinkValue` | 32 | Return address (PC + 2 or PC + 4) |
| `StageV_loadWidth` | 3 | Load width and signedness |
| `StageV_storeWidth` | 2 | Store width |
| `StageV_isCSR` | 1 | 1 = CSR operation |
| `StageV_CSR_addr` | 12 | CSR address |
| `StageV_CSR_op` | 2 | CSR operation type |
| `StageV_CSR_useImm` | 1 | 1 = use zimm |
| `StageV_CSR_wdata` | 32 | Write data for CSR (forwarded rs1 value or zimm extended) |
| `StageV_isTrap` | 1 | 1 = exception detected in EX stage |
| `StageV_trapCause` | 4 | mcause exception code (see Section 10) |
| `StageV_trapPC` | 32 | PC to save in mepc |
| `StageV_isMRET` | 1 | 1 = MRET instruction |
| `StageV_HALT` | 1 | HALT |

### 8.5 StageVI_ Registers (MA → WB)

| Signal | Width | Description |
|--------|-------|-------------|
| `StageVI_rd_index` | 5 | Destination register index |
| `StageVI_destRegWrite` | 1 | 1 = write to rd |
| `StageVI_ALUResult` | 32 | ALU result (passed through from MA) |
| `StageVI_loadData` | 32 | Sign/zero-extended load result from DMEM |
| `StageVI_memToReg` | 1 | 0 = ALU result; 1 = load data |
| `StageVI_isLink` | 1 | 1 = write link address |
| `StageVI_LinkValue` | 32 | Return address for JAL/JALR |
| `StageVI_HALT` | 1 | HALT |

---

## 9. Hazard Handling

### 9.1 Data Hazards — Full Forwarding

A data hazard occurs when an instruction in EX needs a value that a newer-in-time instruction
(further along the pipeline) has not yet written back to the register file.

We forward from two points: EX/MA (1 cycle old result) and MA/WB (2 cycles old result).

**Forwarding unit** (located in the EX stage, computes `forward_a` and `forward_b`):

```
// For rs1 (forward_a):
if   (StageV_destRegWrite && StageV_rd_index != 0 && StageV_rd_index == StageIV_rs1_index)
     forward_a = 2'b10   // forward from EX/MA (StageV_ALUResult or StageV_LinkValue)
elif (StageVI_destRegWrite && StageVI_rd_index != 0 && StageVI_rd_index == StageIV_rs1_index)
     forward_a = 2'b01   // forward from MA/WB (StageVI result)
else
     forward_a = 2'b00   // no forwarding, use StageIV_rs1_data from regfile

// Same logic applies for forward_b / rs2
```

Priority: EX/MA (StageV_) wins over MA/WB (StageVI_) since it is fresher.

**Forwarded operand values**:
```
rs1_forwarded =
    (forward_a == 2'b10) ? (StageV_isLink  ? StageV_LinkValue  : StageV_ALUResult)  :
    (forward_a == 2'b01) ? StageVI_writeData                                         :
    StageIV_rs1_data;
```

`StageVI_writeData` is the final WB mux output: `isLink ? LinkValue : memToReg ? loadData : ALUResult`.

**Forwarding also applies to store data (rs2)**. For a store instruction in EX, the data being
stored (rs2) may also need to be forwarded from the MA/WB stage. This is handled identically
with `forward_b`.

### 9.2 Load-Use Hazard — 1 Stall Cycle

A load-use hazard occurs when a load instruction is in EX (Stage IV) and the immediately
following instruction in ID (Stage III) reads the register that the load is writing.

The load result is not available until the end of MA (Stage V). By that time, the dependent
instruction would already be in EX — too late for the normal EX/MA forward path to help.
The solution is to stall for one cycle: the load completes MA, and the result is forwarded
via the MA/WB (StageVI_) path into EX on the next cycle.

**Stall condition**:
```verilog
wire stall = StageIV_memRead
          && (StageIV_rd_index != 5'd0)
          && (   StageIV_rd_index == StageIII_rs1_index
              || StageIV_rd_index == StageIII_rs2_index);
```

**Stall effect**:
- PC: held (not updated)
- StageII_ (PreIF→IF register): held
- StageIII_ (IF→ID register): held
- StageIV_ (ID→EX register): loaded with NOP bubble (all control signals zeroed)

One bubble is inserted into EX. The load moves from EX to MA. The dependent instruction
stays in ID for one more cycle. On the next cycle, the load is in MA/WB and its result can
be forwarded via `StageVI_writeData` into EX.

**Example**:
```
Cycle:   1     2     3     4     5     6     7
LW r1:   Pre   IF    ID    EX    MA    WB
ADD r2:        Pre   IF    ID    --    EX    MA   (-- = 1 stall cycle with NOP bubble in EX)
               ↑     ↑
           stall=1 detected here, NOP inserted into EX at cycle 4
```

### 9.3 Control Hazards — 2-Cycle Flush on Taken Branch/Jump

Branches are resolved at the end of the EX stage (Stage IV). With the always-not-taken
predictor, we always speculatively fetch the fall-through instructions. If the branch is
taken, the two instructions that entered IF and ID behind the branch are wrong and must
be discarded.

**Flush condition**:
```verilog
wire flush = branchTaken || StageIV_Jump;
```

**Flush effect**:
- PC: redirected to `TruePC`
- StageII_ (PreIF→IF register): replaced with NOP
- StageIII_ (IF→ID register): replaced with NOP

Two NOP bubbles propagate through the pipeline. The correct instruction arrives in IF
two cycles after the flush.

**Branch penalty**: 2 cycles for every taken branch or jump.

**Not-taken prediction**: For not-taken branches, the fall-through instruction was
already correctly fetched — no penalty at all.

**JAL/JALR**: These always flush (unconditional, `doJump = 1` always). The only way to
reduce the penalty would be to resolve the jump target earlier (e.g., in ID), which we
may explore in a future phase.

---

## 10. M-Mode Trap Handling

M-mode (Machine Mode) is the mandatory lowest-level privilege mode in RISC-V. All
exceptions and traps enter M-mode. There is no U-mode or S-mode in Phase 1.

### 10.1 CSR Register File

A small dedicated register file holds the M-mode CSRs. It lives in the MA stage.
Access is via CSRRW/CSRRS/CSRRC/CSRRWI/CSRRSI/CSRRCI instructions decoded in ID.

**Implemented CSRs (Phase 1)**:

| CSR Address | Name | Width | Description |
|-------------|------|-------|-------------|
| 0x300 | `mstatus` | 32 | Machine status: MIE (bit 3), MPIE (bit 7), MPP (bits 12:11 = 11 always in M-only) |
| 0x304 | `mie` | 32 | Machine interrupt enable (MSIE bit 3, MTIE bit 7, MEIE bit 11) |
| 0x305 | `mtvec` | 32 | Trap vector: base address [31:2], mode [1:0] (00=direct, 01=vectored) |
| 0x340 | `mscratch` | 32 | Scratch register for trap handlers |
| 0x341 | `mepc` | 32 | Exception PC — address of the instruction that caused the trap |
| 0x342 | `mcause` | 32 | Exception cause: bit31=interrupt, bits[30:0]=cause code |
| 0x343 | `mtval` | 32 | Trap value: faulting address (misaligned) or instruction word (illegal) |
| 0x344 | `mip` | 32 | Machine interrupt pending (read-mostly; MSIP/MTIP/MEIP) |
| 0xF11 | `mvendorid` | 32 | Vendor ID: 0x00000000 (non-commercial) |
| 0xF12 | `marchid` | 32 | Architecture ID: 0x00000000 |
| 0xF13 | `mimpid` | 32 | Implementation ID: 0x00000001 (PHANTOM-32 v1) |
| 0xF14 | `mhartid` | 32 | Hardware thread ID: 0x00000000 (single core) |
| 0x301 | `misa` | 32 | ISA and extensions: MXL=01 (32-bit), Extensions=IC (bits 8,2) = 0x40000104 |

**`mstatus` field layout (relevant bits)**:

```
Bit  3: MIE   — Machine Interrupt Enable (global)
Bit  7: MPIE  — Machine Previous Interrupt Enable (saved MIE on trap entry)
Bits 12:11: MPP — Previous privilege mode (always 11 = M-mode in Phase 1, so fixed)
```

### 10.2 Trap Causes (mcause values)

| Value | Name | Trigger |
|-------|------|---------|
| 0 | Instruction address misaligned | JAL/JALR target not halfword-aligned |
| 1 | Instruction access fault | (reserved for Phase 2 with MMU) |
| 2 | Illegal instruction | Unrecognized opcode or invalid encoding |
| 3 | Breakpoint | EBREAK instruction |
| 4 | Load address misaligned | LW to non-word-aligned, LH to non-halfword-aligned addr |
| 5 | Load access fault | (reserved for Phase 2) |
| 6 | Store/AMO address misaligned | SW to non-word-aligned, SH to non-halfword-aligned addr |
| 7 | Store/AMO access fault | (reserved for Phase 2) |
| 11 | Environment call from M-mode | ECALL instruction |

Interrupt causes (bit 31 = 1) are reserved for Phase 2 when CLINT is added.

### 10.3 Trap Detection Points

| Trap | Detected in stage | Notes |
|------|------------------|-------|
| ECALL | EX (StageIV_isECALL) | Set by decoder in ID |
| EBREAK | EX (StageIV_isEBREAK) | Set by decoder in ID |
| Illegal instruction | EX (StageIV_isIllegal) | Set by decoder in ID |
| Instruction misaligned | EX | JAL/JALR target alignment check |
| Load/store misaligned | MA | Effective address alignment check |

### 10.4 Trap Entry Sequence

When `StageV_isTrap = 1` is seen in MA:

1. **Flush the pipeline**: assert flush, discard StageII_ through StageV_ (replace with NOPs)
2. **Save state to CSRs**:
   - `mepc   <= StageV_trapPC` (the PC of the trapping instruction)
   - `mcause <= {1'b0, 27'h0, StageV_trapCause}` (exception, not interrupt)
   - `mtval  <= StageV_trapVal` (faulting address or instruction word)
   - `mstatus.MPIE <= mstatus.MIE`
   - `mstatus.MIE  <= 1'b0` (disable interrupts during trap handler)
3. **Redirect PC**: `TruePC = mtvec[31:2] + (mtvec[1:0]==2'b01 ? {mcause[3:0], 2'b00} : 2'b00)`
   In direct mode (mtvec[1:0]=00): all traps go to `mtvec & ~3`
   In vectored mode (mtvec[1:0]=01): interrupts go to `mtvec + 4*cause` (exceptions still go to base)

### 10.5 MRET Instruction

MRET (Machine Return from Trap) restores execution to the interrupted PC.

When `StageV_isMRET = 1` in MA:

1. **Flush the pipeline**: same as trap entry
2. **Restore state**:
   - `mstatus.MIE  <= mstatus.MPIE`
   - `mstatus.MPIE <= 1'b1`
3. **Redirect PC**: `TruePC = mepc`

### 10.6 CSR Read-Modify-Write Operation

CSR instructions perform an atomic read-then-write in the MA stage:

```
old_value = csr_reg[StageV_CSR_addr]   // read

case StageV_CSR_op:
    2'b00 (RW): new_value = StageV_CSR_wdata
    2'b01 (RS): new_value = old_value | StageV_CSR_wdata
    2'b10 (RC): new_value = old_value & ~StageV_CSR_wdata

csr_reg[StageV_CSR_addr] = new_value   // write (if not CSRR* with rs1=x0)
result = old_value                      // the read value goes to the WB register write
```

The result (old CSR value) is written back to `rd` in WB via the normal register write path
(it is placed in `StageVI_ALUResult` with `memToReg=0` and `isLink=0`).

---

## 11. Register File

### 11.1 Specification

| Property | Value |
|----------|-------|
| Entries | 32 registers (x0–x31) |
| Width | 32 bits per register |
| x0 | Hardwired to zero: reads always return 0, writes discarded |
| Read ports | 2 asynchronous (combinational) — for rs1 and rs2 in ID |
| Write port | 1 synchronous (rising edge) — from WB |
| Technology | LUT-RAM (distributed RAM on GW2AR-18) |
| Write-before-read | Implemented in the read mux: if WB is writing the same index we are reading, the new value is returned immediately (no need to wait for posedge) |

### 11.2 LUT-RAM Notes

On Gowin GW2AR-18, distributed LUT-RAM (using Slice LUT cells in RAM mode) provides:
- Asynchronous read: the output changes combinationally with the address input
- Synchronous write: data is latched on the rising clock edge

A 32-entry × 32-bit register file requires approximately **64 LUT4 cells** in 4-bit wide
single-port RAM mode (8 RAM16SDP2 primitives, each 16×2-bit). This is a negligible fraction
of the 20,736 available LUT4s.

---

## 12. ALU

### 12.1 Operations

The ALU is purely combinational. The `ALUOpcode [3:0]` field selects the operation.

| ALUOpcode | Name | Operation | Used by |
|-----------|------|-----------|---------|
| 4'h0 | ADD | `a + b` | ADD, ADDI, LW/SW addr, AUIPC |
| 4'h1 | SUB | `a - b` | SUB; branch comparison (BEQ/BNE uses SUB then checks zero) |
| 4'h2 | AND | `a & b` | AND, ANDI |
| 4'h3 | OR | `a \| b` | OR, ORI |
| 4'h4 | XOR | `a ^ b` | XOR, XORI |
| 4'h5 | SLL | `a << b[4:0]` | SLL, SLLI |
| 4'h6 | SRL | `a >> b[4:0]` (logical) | SRL, SRLI |
| 4'h7 | SRA | `a >>> b[4:0]` (arithmetic) | SRA, SRAI |
| 4'h8 | SLT | `($signed(a) < $signed(b)) ? 1 : 0` | SLT, SLTI |
| 4'h9 | SLTU | `(a < b) ? 1 : 0` (unsigned) | SLTU, SLTIU |
| 4'hA | PASS_B | `b` | LUI (pass upper immediate through; rs1 is not used) |
| 4'hB | BEQ_CMP | `(a == b) ? 0 : 1` → zero flag for branch | BEQ, BNE |
| 4'hC | BLT_CMP | `($signed(a) < $signed(b))` → negative flag | BLT, BGE |
| 4'hD | BLTU_CMP | `(a < b)` → carry flag (unsigned) | BLTU, BGEU |

**Note on branch conditions**: Branches use the ALU to compute a comparison result. The EX stage
reads the `BranchCond [2:0]` field (which is the func3 field of the branch instruction) and
interprets the ALU output accordingly:

```
func3 = 000 (BEQ):  branchTaken = (a == b)
func3 = 001 (BNE):  branchTaken = (a != b)
func3 = 100 (BLT):  branchTaken = ($signed(a) < $signed(b))
func3 = 101 (BGE):  branchTaken = ($signed(a) >= $signed(b))
func3 = 110 (BLTU): branchTaken = (a < b)            // unsigned
func3 = 111 (BGEU): branchTaken = (a >= b)           // unsigned
```

In practice, the branch comparison is computed directly in the EX stage using Verilog comparison
operators, with `StageIV_BranchCond` selecting which comparison to use. The ALU runs in parallel
for instructions that also need ALU output (though branches don't write to a register, so the ALU
output for branches is unused). We may choose to compute branches separately from the ALU to
keep the ALU clean.

### 12.2 Zero Flag

The `zero` wire (`result == 32'h0`) is still useful for NOP detection and debug purposes.

---

## 13. Instruction Coverage

### 13.1 RV32I Base Instructions

All 47 base instructions are supported.

**R-type (opcode 0110011)**

| Instruction | func7 | func3 | Operation |
|-------------|-------|-------|-----------|
| ADD | 0000000 | 000 | rd = rs1 + rs2 |
| SUB | 0100000 | 000 | rd = rs1 - rs2 |
| SLL | 0000000 | 001 | rd = rs1 << rs2[4:0] |
| SLT | 0000000 | 010 | rd = (rs1 < rs2) signed |
| SLTU | 0000000 | 011 | rd = (rs1 < rs2) unsigned |
| XOR | 0000000 | 100 | rd = rs1 ^ rs2 |
| SRL | 0000000 | 101 | rd = rs1 >> rs2[4:0] logical |
| SRA | 0100000 | 101 | rd = rs1 >> rs2[4:0] arithmetic |
| OR | 0000000 | 110 | rd = rs1 \| rs2 |
| AND | 0000000 | 111 | rd = rs1 & rs2 |

**I-type arithmetic (opcode 0010011)**

| Instruction | func3 | Operation |
|-------------|-------|-----------|
| ADDI | 000 | rd = rs1 + sext(imm12) |
| SLTI | 010 | rd = (rs1 < sext(imm12)) signed |
| SLTIU | 011 | rd = (rs1 < sext(imm12)) unsigned |
| XORI | 100 | rd = rs1 ^ sext(imm12) |
| ORI | 110 | rd = rs1 \| sext(imm12) |
| ANDI | 111 | rd = rs1 & sext(imm12) |
| SLLI | 001 | rd = rs1 << shamt (func7=0000000) |
| SRLI | 101 | rd = rs1 >> shamt logical (func7=0000000) |
| SRAI | 101 | rd = rs1 >> shamt arithmetic (func7=0100000) |

**Loads (opcode 0000011)**

| Instruction | func3 | Operation |
|-------------|-------|-----------|
| LB | 000 | rd = sext(mem[rs1+imm][7:0]) |
| LH | 001 | rd = sext(mem[rs1+imm][15:0]) |
| LW | 010 | rd = mem[rs1+imm][31:0] |
| LBU | 100 | rd = zext(mem[rs1+imm][7:0]) |
| LHU | 101 | rd = zext(mem[rs1+imm][15:0]) |

**Stores (opcode 0100011)**

| Instruction | func3 | Operation |
|-------------|-------|-----------|
| SB | 000 | mem[rs1+imm][7:0] = rs2[7:0] |
| SH | 001 | mem[rs1+imm][15:0] = rs2[15:0] |
| SW | 010 | mem[rs1+imm][31:0] = rs2[31:0] |

**Branches (opcode 1100011)**

| Instruction | func3 | Condition |
|-------------|-------|-----------|
| BEQ | 000 | rs1 == rs2 |
| BNE | 001 | rs1 != rs2 |
| BLT | 100 | rs1 < rs2 signed |
| BGE | 101 | rs1 >= rs2 signed |
| BLTU | 110 | rs1 < rs2 unsigned |
| BGEU | 111 | rs1 >= rs2 unsigned |

**Upper immediate and jumps**

| Instruction | Opcode | Operation |
|-------------|--------|-----------|
| LUI | 0110111 | rd = {imm[31:12], 12'b0} |
| AUIPC | 0010111 | rd = PC + {imm[31:12], 12'b0} |
| JAL | 1101111 | rd = PC+4; PC = PC + sext(imm21) |
| JALR | 1100111 | rd = PC+4; PC = (rs1 + sext(imm12)) & ~1 |

**System**

| Instruction | Encoding | Operation |
|-------------|----------|-----------|
| ECALL | 0x00000073 | Environment call trap |
| EBREAK | 0x00100073 | Breakpoint trap |
| MRET | 0x30200073 | Return from M-mode trap |
| FENCE | opcode=0001111 | Memory ordering (NOP for single-core Phase 1) |
| FENCE.I | 0x0000100F | Instruction fence (NOP for Phase 1) |
| CSRRW | func3=001 | CSR Read-Write |
| CSRRS | func3=010 | CSR Read-Set |
| CSRRC | func3=011 | CSR Read-Clear |
| CSRRWI | func3=101 | CSR Read-Write Immediate |
| CSRRSI | func3=110 | CSR Read-Set Immediate |
| CSRRCI | func3=111 | CSR Read-Clear Immediate |

**Custom**

| Instruction | Encoding | Operation |
|-------------|----------|-----------|
| HALT | TBD (use 0x00100073 EBREAK with special handler, or a custom opcode) | Stop CPU, assert `halted` |

### 13.2 RV32C Compressed Instructions

All RV32C instructions are supported. They are 16-bit and recognised by bits [1:0] ≠ 2'b11.

**Quadrant 0 (bits [1:0] = 00)**

| Instruction | funct3 | Operation | 32-bit equivalent |
|-------------|--------|-----------|-------------------|
| C.ADDI4SPN | 000 | rd' = sp + nzuimm[9:2] | ADDI rd, x2, nzuimm |
| C.LW | 010 | rd' = mem[rs1' + uimm[6:2]] | LW rd', uimm(rs1') |
| C.SW | 110 | mem[rs1' + uimm[6:2]] = rs2' | SW rs2', uimm(rs1') |

Note: rd', rs1', rs2' use 3-bit compressed register encoding → actual register = {2'b01, field[2:0]}
(maps to x8–x15).

**Quadrant 1 (bits [1:0] = 01)**

| Instruction | funct3 | Operation | Notes |
|-------------|--------|-----------|-------|
| C.NOP | 000 | no-op | ADDI x0, x0, 0 |
| C.ADDI | 000 | rd = rd + nzimm[5:0] | ADDI rd, rd, nzimm |
| C.JAL | 001 | x1 = PC+2; PC = PC + sext(imm11) | RV32C only; absent in RV64C |
| C.LI | 010 | rd = sext(imm[5:0]) | ADDI rd, x0, imm |
| C.ADDI16SP | 011 | sp = sp + nzimm[9:4] | rd must be x2 |
| C.LUI | 011 | rd = {nzimm[17:12], 12'b0} | rd ≠ x0, x2 |
| C.SRLI | 100 | rd' = rd' >> shamt[5:0] | logical right shift |
| C.SRAI | 100 | rd' = rd' >>> shamt[5:0] | arithmetic right shift |
| C.ANDI | 100 | rd' = rd' & sext(imm[5:0]) | bitwise AND immediate |
| C.SUB | 100 | rd' = rd' - rs2' | |
| C.XOR | 100 | rd' = rd' ^ rs2' | |
| C.OR | 100 | rd' = rd' \| rs2' | |
| C.AND | 100 | rd' = rd' & rs2' | |
| C.J | 101 | PC = PC + sext(imm11) | unconditional jump, no link |
| C.BEQZ | 110 | if (rs1' == 0): PC = PC + sext(imm8) | |
| C.BNEZ | 111 | if (rs1' != 0): PC = PC + sext(imm8) | |

**Quadrant 2 (bits [1:0] = 10)**

| Instruction | funct3 | Operation | Notes |
|-------------|--------|-----------|-------|
| C.SLLI | 000 | rd = rd << shamt[5:0] | uses full 5-bit register |
| C.LWSP | 010 | rd = mem[sp + uimm[7:2]] | rd ≠ x0 |
| C.JR | 100 | PC = rs1 | rs2 = 0 |
| C.MV | 100 | rd = rs2 | rs1 = 0 |
| C.EBREAK | 100 | breakpoint | rs1=rs2=0, rd=0 |
| C.JALR | 100 | x1 = PC+2; PC = rs1 | rs2 = 0, rd = 0, rs1 ≠ 0 |
| C.ADD | 100 | rd = rd + rs2 | |
| C.SWSP | 110 | mem[sp + uimm[7:2]] = rs2 | |

---

## 14. Branch Prediction — Phase 1

**Policy**: Always Not-Taken.

The fetch unit always speculatively fetches the sequential next instruction (PC+2 or PC+4).
No BTB, no PHT, no history.

**Taken branch penalty**: 2 cycles (the two instructions fetched behind the branch are flushed).
**Not-taken branch cost**: 0 cycles (sequential fetch was correct).

This is intentionally simple. The infrastructure for the always-not-taken predictor is exactly
what a gshare predictor needs — the only additions for Phase 2 are the BTB (maps PC to target)
and PHT (maps history hash to predicted direction). The `PredPC` candidate in the PC mux is
already a placeholder for this.

**Estimated performance impact**: For typical code, roughly 10-15% of dynamic instructions are
taken branches. With a 2-cycle penalty each and ~50% average taken rate, the IPC loss is roughly
`0.15 * 0.5 * 2 / (1 + 0.15 * 0.5 * 2) ≈ 13%` versus perfect prediction. This is acceptable
for Phase 1.

---

## 15. Memory Interface Specification

### 15.1 IMEM Interface (CPU ↔ BRAM)

```
// From CPU to IMEM (driven by PreIF, combinational)
output wire [IMEM_ADDR_W-1:0]  imem_addr_a,   // Port A address (halfword index = PC[N:1])
output wire [IMEM_ADDR_W-1:0]  imem_addr_b,   // Port B address (= imem_addr_a + 1)

// From IMEM to CPU (synchronous read, available in IF)
input  wire [15:0]              imem_data_a,   // halfword at addr_a
input  wire [15:0]              imem_data_b,   // halfword at addr_b
```

`IMEM_ADDR_W = $clog2(IMEM_DEPTH)` where `IMEM_DEPTH` is the number of 16-bit entries.
Default: `IMEM_DEPTH = 4096`, `IMEM_ADDR_W = 12`.

The PC used to compute `imem_addr_a` is `PC[12:1]` (drops bit 0, which is always 0 for halfword
alignment; drops bits above 12 since we address 4096 entries). In the final version, PC width
must match IMEM depth — this will be parameterised.

### 15.2 DMEM Interface (CPU ↔ BRAM)

```
// From CPU to DMEM (driven by MA stage, combinational address)
output wire [DMEM_ADDR_W-1:0]  dmem_addr,     // word address = effective_addr[N:2]
output wire [31:0]              dmem_wdata,    // write data (byte-replicated for SB/SH)
output wire [3:0]               dmem_we,       // byte enables (see Section 3.2)

// From DMEM to CPU (combinational read)
input  wire [31:0]              dmem_rdata,    // 32-bit word at dmem_addr
```

`DMEM_ADDR_W = $clog2(DMEM_DEPTH)` where `DMEM_DEPTH` is the number of 32-bit words.
Default: `DMEM_DEPTH = 1024`, `DMEM_ADDR_W = 10`.

**Store data byte replication**: To correctly implement SB and SH with byte enables, the store
data must be replicated across all byte lanes:
```
SB: dmem_wdata = {4{rs2[7:0]}}          // replicate byte to all lanes
SH: dmem_wdata = {2{rs2[15:0]}}         // replicate halfword to both halfword lanes
SW: dmem_wdata = rs2                     // no replication needed
```
The byte enables then ensure only the correct lane(s) are actually written.

**Load data extraction**: After reading a 32-bit word from DMEM, the correct byte or halfword
must be extracted and extended:
```
effective_addr[1:0] selects the byte offset within the 32-bit word:
LB/LBU:
    byte_sel = dmem_rdata >> (effective_addr[1:0] * 8)  [7:0]
    result = LBU ? {24'h0, byte_sel} : {{24{byte_sel[7]}}, byte_sel}

LH/LHU:
    half_sel = effective_addr[1] ? dmem_rdata[31:16] : dmem_rdata[15:0]
    result = LHU ? {16'h0, half_sel} : {{16{half_sel[15]}}, half_sel}

LW:
    result = dmem_rdata
```

---

## 16. Control Signal Reference

This table maps instruction class to control signal values. All unlisted signals default to 0.

| Instruction class | destRegWrite | memRead | memWrite | Branch | Jump | ALUBSel | memToReg | isLink | ALUOpcode |
|-------------------|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| R-type (ADD/SUB/…) | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | varies |
| I-type arith (ADDI/…) | 1 | 0 | 0 | 0 | 0 | 1 | 0 | 0 | varies |
| LUI | 1 | 0 | 0 | 0 | 0 | 1 | 0 | 0 | PASS_B |
| AUIPC | 1 | 0 | 0 | 0 | 0 | 1 | 0 | 0 | ADD |
| Load (LW/LH/…) | 1 | 1 | 0 | 0 | 0 | 1 | 1 | 0 | ADD |
| Store (SW/SH/…) | 0 | 0 | 1 | 0 | 0 | 1 | 0 | 0 | ADD |
| Branch (BEQ/BNE/…) | 0 | 0 | 0 | 1 | 0 | 0 | 0 | 0 | varies |
| JAL | 1 | 0 | 0 | 0 | 1 | 0 | 0 | 1 | — |
| JALR | 1 | 0 | 0 | 0 | 1 | 1 | 0 | 1 | ADD |
| ECALL/EBREAK | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | — |
| CSR* | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | — |
| FENCE/FENCE.I | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | — (NOP) |

**Notes**:
- For AUIPC, `ALU_A` is PC (not rs1); the decoder sets a special `isAUIPC` flag so EX feeds
  `StageIV_PC` into ALU port A instead of the register value
- For JAL, no ALU result is used; the link value (PC+2 or PC+4) is produced separately in EX
- For CSR instructions, `destRegWrite=1` because the old CSR value is written to rd; actual CSR
  read/write happens in MA with the `isCSR` flag

**ALUOpcode assignment**:

| Instruction | ALUOpcode |
|-------------|-----------|
| ADD, ADDI, LW/SW/LH/etc. addr, JALR, AUIPC | ADD (0x0) |
| SUB | SUB (0x1) |
| AND, ANDI | AND (0x2) |
| OR, ORI | OR (0x3) |
| XOR, XORI | XOR (0x4) |
| SLL, SLLI | SLL (0x5) |
| SRL, SRLI | SRL (0x6) |
| SRA, SRAI | SRA (0x7) |
| SLT, SLTI | SLT (0x8) |
| SLTU, SLTIU | SLTU (0x9) |
| LUI | PASS_B (0xA) |

---

## 17. Naming Conventions and Style Guide

### 17.1 Signal Naming Rules

| Pattern | Meaning | Examples |
|---------|---------|---------|
| `StageN_XxxYyy` | Pipeline register between stages N-1 and N; data that Stage N is working on | `StageIV_rs1_data`, `StageVI_loadData` |
| `CTRL_XxxYyy` | Combinational control signal decoded in ID before it is registered | `CTRL_destRegWrite`, `CTRL_ALUOpcode` |
| `StageN_CTRL_XxxYyy` | Registered control signal propagated into stage N | `StageIV_destRegWrite` |
| `forward_a`, `forward_b` | Forwarding mux select (2 bits) | `forward_a == 2'b10` means EX/MA forward |
| `flush` | 1-bit combinational: asserted by EX when branch taken or jump | |
| `stall` | 1-bit combinational: asserted by hazard unit when load-use detected | |
| `imem_*` | Instruction memory interface signals | `imem_addr_a`, `imem_data_b` |
| `dmem_*` | Data memory interface signals | `dmem_addr`, `dmem_we`, `dmem_rdata` |
| `mXxx` | M-mode CSR register | `mtvec`, `mepc`, `mcause` |
| `isXxx` | Boolean flag | `isCompressed`, `isTrap`, `isLoad` |

### 17.2 Module Structure

| File | Module | Description |
|------|--------|-------------|
| `isa.vh` | (header) | All `define constants: opcodes, ALU codes, CSR addresses, trap codes |
| `alu.v` | `alu` | Combinational ALU, purely functional |
| `regfile.v` | `regfile` | 32×32 LUT-RAM register file |
| `csr_regfile.v` | `csr_regfile` | M-mode CSR register file |
| `decoder_if.v` | `decoder_if` | ParallelDecoderIF: lightweight decode in IF stage |
| `decoder_id.v` | `decoder_id` | ParallelDecoderID: full decode in ID stage |
| `cpu.v` | `cpu` | 6-stage pipeline, hazard unit, forwarding unit |
| `soc.v` | `soc` | SoC: CPU + IMEM + DMEM |
| `tb_icarus.v` | `tb_icarus` | Icarus Verilog testbench |

### 17.3 `isa.vh` Constants to Define

```verilog
// RV32I Opcodes [6:0]
`define OP_LUI     7'b0110111
`define OP_AUIPC   7'b0010111
`define OP_JAL     7'b1101111
`define OP_JALR    7'b1100111
`define OP_BRANCH  7'b1100011
`define OP_LOAD    7'b0000011
`define OP_STORE   7'b0100011
`define OP_ARITH_I 7'b0010011   // I-type arithmetic
`define OP_ARITH_R 7'b0110011   // R-type arithmetic
`define OP_SYSTEM  7'b1110011
`define OP_FENCE   7'b0001111

// ALU operation codes [3:0]
`define ALU_ADD    4'h0
`define ALU_SUB    4'h1
`define ALU_AND    4'h2
`define ALU_OR     4'h3
`define ALU_XOR    4'h4
`define ALU_SLL    4'h5
`define ALU_SRL    4'h6
`define ALU_SRA    4'h7
`define ALU_SLT    4'h8
`define ALU_SLTU   4'h9
`define ALU_PASS_B 4'hA

// Load/store widths
`define WIDTH_B    3'b000   // byte, signed
`define WIDTH_H    3'b001   // halfword, signed
`define WIDTH_W    3'b010   // word
`define WIDTH_BU   3'b100   // byte, unsigned
`define WIDTH_HU   3'b101   // halfword, unsigned

// Trap/exception codes (mcause[3:0])
`define TRAP_INSTR_MISALIGN  4'd0
`define TRAP_INSTR_FAULT     4'd1
`define TRAP_ILLEGAL_INSTR   4'd2
`define TRAP_BREAKPOINT      4'd3
`define TRAP_LOAD_MISALIGN   4'd4
`define TRAP_LOAD_FAULT      4'd5
`define TRAP_STORE_MISALIGN  4'd6
`define TRAP_STORE_FAULT     4'd7
`define TRAP_ECALL_M         4'd11

// CSR addresses
`define CSR_MSTATUS   12'h300
`define CSR_MIE       12'h304
`define CSR_MTVEC     12'h305
`define CSR_MSCRATCH  12'h340
`define CSR_MEPC      12'h341
`define CSR_MCAUSE    12'h342
`define CSR_MTVAL     12'h343
`define CSR_MIP       12'h344
`define CSR_MVENDORID 12'hF11
`define CSR_MARCHID   12'hF12
`define CSR_MIMPID    12'hF13
`define CSR_MHARTID   12'hF14
`define CSR_MISA      12'h301

// NOP instruction (ADDI x0, x0, 0)
`define NOP_INSTR  32'h0000_0013

// Reset vector
`define RESET_VECTOR 32'h0000_0000
```

### 17.4 Code Style Rules

1. **Section banners**: Use `// ====...====` banners to delimit each stage, matching PHANTOM-16
2. **Comment intent, not mechanics**: Explain *why* the code does something, not just what it does
3. **Default-safe always blocks**: Every `always @(*)` decoder must have a `default:` that
   produces NOP-safe signals, to avoid latches
4. **Explicit resets**: Every pipeline register must have a synchronous active-low reset
   (`if (!resetn)`) that loads safe/NOP values
5. **No `#delay` statements** in synthesisable files (testbench only)
6. **Parameterise memory sizes**: Use `parameter IMEM_DEPTH` and `parameter DMEM_DEPTH` so
   sizes can be changed without editing RTL
7. **`include guards`** in `isa.vh` to prevent double-inclusion

---

## 18. Implementation Phases and Roadmap

### Phase 1 — Base RV32IC CPU with BRAM (Current)

**Goal**: A fully functional, synthesisable RV32IC CPU that passes a self-checking testbench.

Deliverables in order of implementation:
1. `isa.vh` — all constants
2. `alu.v` — combinational ALU
3. `regfile.v` — LUT-RAM register file
4. `decoder_if.v` — ParallelDecoderIF (lightweight, hazard-focused)
5. `decoder_id.v` — ParallelDecoderID (full decode, both 32-bit and 16-bit paths)
6. `csr_regfile.v` — M-mode CSR register file
7. `cpu.v` — 6-stage pipeline (all stages, all hazard paths, M-mode traps)
8. `soc.v` — SoC wrapper with dual-port IMEM and DMEM
9. `tb_icarus.v` — testbench with self-checking assertions
10. `assembler.py` / test programs — RISC-V assembly programs for verification
11. FPGA synthesis and timing closure on Tang Nano 20K

**Verification milestones**:
- ALU: all 11 operations correct
- Register file: x0 always zero, write-before-read works
- Single instruction execution: each RV32I instruction produces correct result
- Pipeline: back-to-back instructions with forwarding (no stall for ALU chains)
- Load-use stall: LW followed by dependent instruction produces correct result
- Branch: taken and not-taken both correct, 2-cycle flush on taken
- Compressed instructions: all RV32C instructions decode and execute correctly
- M-mode: ECALL, EBREAK, illegal instruction, misaligned access, MRET all work
- Dhrystone / CoreMark on BRAM (future milestone once programs fit in BRAM)

### Phase 2 — SDRAM, Cache, MMU, Interrupts, Branch Predictor, UART

Prerequisites: Phase 1 complete and fully verified.

- SDRAM controller for the GW2AR-18 embedded 64 Mbit SDRAM (8 MB)
- I-cache and D-cache backed by SDRAM (BRAM becomes cache, not primary storage)
- MMU with page tables (Sv32 mode — 2-level page table, 32-bit virtual addresses)
- CLINT (Core-Local Interruptor) for machine timer and software interrupts
- UART peripheral for serial I/O
- Gshare branch predictor (BTB in BRAM, PHT in BRAM)
- Upgrade to full S-mode for OS support

### Phase 3 — M Extension, HDMI, PS/2, User Programs

Prerequisites: Phase 2 complete.

- M extension: hardware multiplier (using DSP blocks on GW2AR-18), divider
- HDMI output controller
- PS/2 keyboard controller
- GPIO peripheral
- Port a small C library (newlib) and run user programs

---

*Document version 0.1. All design decisions in this document are subject to revision during
implementation — if a better approach is discovered while writing RTL, update this document
first and then the code.*
