# PHANTOM-32 - RV32IMC Soft Processor
## Architecture Reference Document
### Version 1.2 - Phase III In Progress

---

## Table of Contents

1. [Overview and Design Goals](#1-overview-and-design-goals)
2. [Top-Level Block Diagram](#2-top-level-block-diagram)
3. [Memory Architecture](#3-memory-architecture)
4. [Pipeline Overview](#4-pipeline-overview)
5. [The Fetch Unit and Branch Predictor](#5-the-fetch-unit-and-branch-predictor)
6. [The Parallel Decoder Architecture](#6-the-parallel-decoder-architecture)
7. [Stage-by-Stage Description](#7-stage-by-stage-description)
8. [Pipeline Register Reference](#8-pipeline-register-reference)
9. [Hazard Handling](#9-hazard-handling)
10. [M-Mode Trap Handling](#10-m-mode-trap-handling)
11. [Register File](#11-register-file)
12. [ALU](#12-alu)
13. [Instruction Coverage](#13-instruction-coverage)
14. [Branch Prediction - Gshare Pipelined](#14-branch-prediction--gshare-pipelined)
15. [Memory Interface Specification](#15-memory-interface-specification)
16. [Module Reference](#16-module-reference)
17. [Naming Conventions and Style Guide](#17-naming-conventions-and-style-guide)
18. [Implementation Phases and Roadmap](#18-implementation-phases-and-roadmap)

---

## 1. Overview and Design Goals

**PHANTOM-32** is a 32-bit soft processor targeting the **Lattice ECP5 LFE5U-85F** FPGA
(ULX3S 85K board). It implements **RV32IMC** - the RISC-V base integer ISA plus the integer
multiply/divide (M) and compressed (C) extensions - and is designed for extension with S-mode
and a cache hierarchy in later phases.

### Design Parameters

| Parameter | Value |
|-----------|-------|
| ISA | RV32IMC - full RV32I + M (multiply/divide) + all RV32C compressed instructions |
| Pipeline | 6-stage in-order: PreIF → IF → ID → EX → MA → WB |
| Fetch unit | Dual-port 16-bit-wide EBR, dual-PC fetch (after RVCoreP-32IC) |
| Decoder | Parallel 16-bit and 32-bit decode - no decompressor on critical path |
| Forwarding | Full: MA→EX and WB→EX paths, zero stalls for back-to-back ALU |
| Load-use hazard | 1 stall cycle |
| Control hazards | Gshare predictor: 0 cycles on hit; misprediction flush 1 cycle (resolved in ID) or 2 cycles (resolved in EX) |
| Traps | M-mode only: ECALL, EBREAK, illegal instruction, misaligned address, MRET |
| CSR | mstatus, mie, mip, mtvec, mepc, mcause, mtval, mscratch, misa, mvendorid, marchid, mimpid, mhartid |
| Register file | 32 × 32-bit, LUT-RAM, two async read ports, one sync write port |
| IMEM | 16-bit wide, dual EBR arrays, synchronous read |
| DMEM | 32-bit wide, single EBR array, synchronous read, byte-enable write |
| Branch predictor | Gshare: PHT (8192 × 2-bit, 1 EBR) + BTB (512 × 32-bit, 1 EBR) |
| Target FPGA | Lattice ECP5 LFE5U-85F (ULX3S 85K): 84K LUT4, 208 EBR, 156 DSP |
| Toolchain | Yosys + nextpnr-ecp5 + prjtrellis + openFPGALoader (fully open-source) |
| Verification | 52/52 official RISC-V compliance tests passing (39 rv32ui+uc + 8 rv32um + 5 rv32mi) |

### Phase Roadmap Summary

| Phase | Status | Scope |
|-------|--------|-------|
| I | **COMPLETE** | RV32IC base CPU, M-mode traps, 39/39 compliance |
| II | **COMPLETE** | Fmax optimisations, BSRAM adaptation, structural cleanup |
| III | **IN PROGRESS** | gshare predictor, M extension, CLINT, FPGA bring-up, SDRAM, cache, UART, S-mode |
| IV | Pending | HDMI, PS/2, newlib |
| V | Pending | Superscalar + limited OoO, ROB, reservation stations, LSQ |

---

## 2. Top-Level Block Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        phantom-core.sv (CPU core)                       │
│                                                                         │
│                                                                         │
│                        (→ EBR MAR)                                      │
│   u_btb    u_pht       ex_dmem_addr                                     │
│     │        │                 │                                        │
│  ┌─────┐  ┌─────┐  ┌─────┐  ┌─────┐  ┌─────┐  ┌─────┐                   │
│  │PreIF│→ │ IF  │→ │ ID  │→ │ EX  │→ │ MA  │→ │ WB  │                   │
│  └─────┘  └─────┘  └─────┘  └─────┘  └─────┘  └─────┘                   │
│             │                           │                               │
│           imem_addr_a/b              dmem_rdata (from EBR)              │
│           imem_data_a/b              dmem_we/be/wdata                   │
│                                         │                               │
│                                         │                               │
│           branch_miss ◄─────────────────┘                               │
└─────────────────────────────────────────────────────────────────────────┘
         ↕ IMEM ports ↕             ↕ DMEM ports ↕
┌────────────────────────────────────────────────────────────────────────────┐
│                           cpu.sv (wrapper)                                 │
│  ECP5 EBR imem_a/imem_b (16-bit × 4096)  ECP5 EBR dmem_mem (32-bit × 1024) │
│  (* ram_style = "block" *) Yosys inference                                 │
│  Peripheral bus: periph_addr/wdata/we/be/rdata                             │
└────────────────────────────────────────────────────────────────────────────┘
         ↕ periph_* ports
┌─────────────────────────────────────────────────────────────────────────┐
│                     soc.sv (FPGA top-level)                             │
│  EHXPLLL (25→50 MHz)  reset sequencer  UART TX @ 0x8000_2000            │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Memory Architecture

### Address Map

| Range | Size | Description |
|-------|------|-------------|
| 0x0000_0000 – 0x0000_0FFF | 4 KB | IMEM (instruction fetch only) |
| 0x0000_0000 – 0x0000_0FFF | 4 KB | DMEM (data read/write) |
| 0x8000_0000 – 0xFFFF_FFFF | 2 GB | Peripheral space (addr[31]==1) |
| 0x8000_1000 | - | Simulation finish trigger (tb_core only) |
| 0x8000_2000 | - | UART TX data register |
| 0x8001_0000 – 0x8001_FFFF | 64 KB | CLINT: msip (+0x0), mtimecmp (+0x4000), mtime (+0xBFF8) - timer + software interrupt (SiFive offsets) |

IMEM and DMEM share the same physical address space - IMEM is accessed only via the
`imem_addr_a/b` ports and never through the data bus. They are separate EBR arrays.

### EBR Usage (ECP5 LFE5U-85F - 208 EBR blocks available)

| Resource | EBR blocks | Notes |
|----------|-----------|-------|
| IMEM (imem_a) | 4 | 16-bit × 4096 → DP16KD |
| IMEM (imem_b) | 4 | 16-bit × 4096 → DP16KD |
| DMEM | 4 | 32-bit × 1024 → DP16KD |
| PHT (u_pht) | 1 | 2-bit × 8192 → DP16KD |
| BTB (u_btb) | 1 | 32-bit × 512 → DP16KD (target store; valid bits in resettable FFs, not EBR) |
| **Total** | **14** | of 208 available |

---

## 4. Pipeline Overview

```
PreIF       IF          ID          EX           MA          WB
─────────   ─────────   ─────────   ──────────   ─────────   ─────
PC regs     IMEM data   Decode      Forward      Trap det.   Regfile
BHR         Instr asm   Regfile rd  ALU          CSR RMW     writeback
u_pht read  fast_decode ImmGen      BranchEval   DMEM rd     ↓
u_btb read  NextPC MUX  hazard_unit BranchTgt    Load ext.   wb_fwdValue
PredPC reg  "comb"      LoadUse     ex_dmem_addr branch_miss
                        stall       TakenPC      TruePC
                                                 PHT update
                                                 BTB update
```

---

## 5. The Fetch Unit and Branch Predictor

### Dual-Port 16-bit Fetch

PHANTOM-32 maintains two program counters (PC and PC+2) and fetches both halfwords
simultaneously every cycle. This allows any 32-bit instruction to be fetched in one
cycle regardless of 32-bit boundary alignment. The IMEM is 16-bit wide; `imem_data_a`
and `imem_data_b` are concatenated for 32-bit instructions.

### Gshare Branch Predictor Pipeline

The predictor is modelled after the RVCoreP-32IC paper. PHT and BTB are separate
submodule files (`pht.sv`, `btb.sv`) instantiated in phantom_core as `u_pht` and `u_btb`.

There are **two** register boundaries around the PreIF stage:

**IF/PreIF pipeline registers** (updated at IF→PreIF clock edge):
- `r_bhr [12:0]` - Branch History Register (speculative; shift-in pred_taken each cycle)
- `r_predpc [31:0]` - PredPC (BTB output registered here; predicted target for r_pc)
- `r_predpc2 [31:0]` - PredPC + 2 (companion for IMEM port B)
- `r_predvalid` - BTB valid bit for the r_predpc entry (registered alongside r_predpc; gates pred_taken). `pred_taken` itself is combinational, not a register.

**PreIF/IF pipeline registers** (inside submodules, updated at PreIF→IF clock edge):
- `pht_mar` (inside `pht.sv`, exposed as output) - latches `XOR(r_bhr, r_pc[13:1])`
- BTB MAR (inside `btb.sv`, internal) - latches `next_pc[9:1]`

### Submodule Roles

**`pht.sv` (u_pht)**: Pattern History Table.
- 8192 × 2-bit saturating counters. 1 EBR block (DP16KD, Yosys `ram_style = "block"`).
- PrePC input (`pre_pc` port) = `r_pc` in phantom_core (= next_pc delayed one cycle).
- XOR(r_bhr, r_pc[13:1]) → PHT MAR → `pht_rdata` combinational in IF.
- Exposes `pht_mar` so phantom_core can latch it into `if_id_phtIdx`.
- Write port: MA stage updates counter on resolved conditional branches (not jumps).
  Uses pipeline-carried `update_old` (phtOld) to avoid needing a second read port.

**`btb.sv` (u_btb)**: Branch Target Buffer.
- 512 × {valid, 32-bit target}. Targets in 1 EBR block (DP16KD); `valid_mem` is a
  resettable FF array (cleared on `resetn`) so a cold/uninitialised entry can never hit.
- BTB MAR ← `next_pc[9:1]` each clock edge. `btb_rdata`/`btb_valid` combinational in IF.
- `btb_rdata`/`btb_valid` → `r_predpc`/`r_predvalid` (registered at IF/PreIF boundary).
- Write port: MA stage writes target + sets valid on any taken branch or unconditional jump.

**"comb" unit**: `assign pred_taken = pht_rdata[1] && fd_isBranchJump && r_predvalid;`
The PHT MSB gives the direction, but a taken-prediction is only honoured when the fetched
instruction is genuinely a branch/jump (`fd_isBranchJump`, from fast_decoder, same-cycle
aligned with the prediction) **and** its BTB entry is valid. This stops the tagless predictor
from redirecting a non-branch (cold/aliased slot) to a stale target and spraying flushes.

**"join" unit**: `r_bhr <= {r_bhr[BHR_W-2:0], pred_taken};` - speculative BHR shift each
non-stall cycle. On `branch_miss`, BHR resets to 0 (simple recovery strategy).

### NextPC MUX - 7 Candidates

The NextPC MUX and its companion NextPC_2 MUX live in the **IF stage**:

```
Priority 0 (highest): !resetn      → RESET_VECTOR
Priority 1:            trap_en      → csr_mtvec
Priority 2:            mret_en      → csr_mepc
Priority 3:            branch_miss  → truepc           (2-cycle EX misprediction correction)
Priority 4:            stall        → r_pc             (load-use hold)
Priority 5:            pred_taken   → r_predpc         (follow BTB prediction, 0 cycles)
Priority 6 (lowest):   default      → pc_inc_seq       (+2 compressed, +4 32-bit)
```

The one-hot `nextpc_sel[6:0]` vector ensures exactly one candidate is selected.

---

## 6. The Parallel Decoder Architecture

Two decoders operate in parallel on the same instruction:

**`fast_decoder` (IF stage)**: Lightweight combinational decode. Extracts rs1/rs2/rd
indices, an `isLoad` flag (for hazard_unit), and an `is_branch_jump` flag that gates the
branch predictor (see §5 / §14). Feeds hazard_unit and the IF/ID pipeline register. Does not
need full instruction semantics - just field extraction and opcode/quadrant classification.

**`imm_generator` (IF stage)**: Extracts immediates for all 32-bit and 16-bit formats.
Also computes `immediate_2 = immediate + 2` (used by `branch_target` for TakenPC_2).

**`control_unit` (ID stage)**: Full parallel decode for all instruction formats.
Generates ALU op, source pre-selects, branch/jump/mem/CSR/trap control signals.
`alu_src_a` and `alu_src_b` select PC or rs1, and immediate or rs2, at the ID/EX
register boundary - the EX stage sees a clean single mux layer.


---

## 7. Stage-by-Stage Description

### PreIF Stage

Holds the PC register bank (r_pc, r_pc2, r_pc4, r_pc6) and the branch predictor's
IF/PreIF pipeline registers (r_bhr, r_predpc, r_predpc2, r_predTaken). Instantiates
`u_pht` and `u_btb` - their read MARs latch at the PreIF/IF boundary, making data
available combinationally in IF. The "join" BHR shift and PredPC register capture
happen at the same clock edge as r_pc updates.

### IF Stage

Assembles the instruction from `imem_data_a` and `imem_data_b`. Determines compression
from `imem_data_a[1:0]`. Runs `fast_decoder` on the assembled word. Immediate extraction via `imm_generator`. Computes `next_pc`
and `next_pc2` via the 7-candidate one-hot MUX. The "comb" prediction decision
(`pred_taken = pht_rdata[1]`) directly gates NextPC priority slot 5.

### ID Stage

Full decode via `control_unit`, regfile read
via `regfile` (async read ports). Load-use stall detection via `hazard_unit`. PC/imm
pre-selection applied at ID/EX register boundary.

### EX Stage

Three-way forwarding muxes (MA→EX and WB→EX) on rs1 and rs2. Dedicated DMEM address
adder (`ex_dmem_addr = rs1_fwd + imm`) separate from ALU. ALU computes arithmetic/logic
result. `branch_eval` evaluates conditional branch condition. `branch_target` computes
TakenPC (`target_addr`) and TakenPC_2 (`target_addr_2 = target_addr + 2`).
**Branch misprediction detection**: compares actual outcome against predicted. Generates
`branch_miss`, `truepc`, PHT and BTB update.

### MA Stage

Trap detection by `trap_unit` (combinational). CSR read-modify-write via `csr_regfile`
(uses `csr_rdDataRaw` - no forwarding - to avoid RMW combinational loop). DMEM load
extraction (flat `unique case` on width + address[1:0]). DMEM store byte-lane placement.
**Branch misprediction causes**: 
PHT and BTB update.

### WB Stage

`wb_fwdValue` is a combinational mux over `ma_wb_wbSel`. It simultaneously drives
`regfile.wr_data` (architectural commit) and the WB→EX forwarding path.

---

## 8. Pipeline Register Reference

### PreIF/IF Registers (r_ prefix)

| Signal | Width | Description |
|--------|-------|-------------|
| `r_pc` | 32 | Main Program Counter (= next_pc delayed 1 cycle = PrePC) |
| `r_pc2` | 32 | r_pc + 2 |
| `r_pc4` | 32 | r_pc + 4 |
| `r_pc6` | 32 | r_pc + 6 |
| `r_bhr` | 13 | Branch History Register (speculative) |
| `r_predTaken` | 1 | Prediction decision for r_pc's instruction |
| `r_predpc` | 32 | BTB predicted target (PredPC) |
| `r_predpc2` | 32 | PredPC + 2 |

### IF/ID Registers

| Signal | Width | Description |
|--------|-------|-------------|
| `if_id_instr` | 32 | Assembled instruction word |
| `if_id_pc` | 32 | PC of current instruction |
| `if_id_pc2` | 32 | PC + 2 |
| `if_id_pc4` | 32 | PC + 4 |
| `if_id_isComp` | 1 | 1 = 16-bit compressed instruction |
| `if_id_rs1Index` | 5 | rs1 index from fast_decoder |
| `if_id_rs2Index` | 5 | rs2 index from fast_decoder |
| `if_id_rdIndex` | 5 | rd index from fast_decoder |
| `if_id_isLoad` | 1 | Load flag from fast_decoder |
| `if_id_predTaken` | 1 | Prediction bit (pipeline carry to MA) |
| `if_id_predpc` | 32 | Predicted target (pipeline carry to MA) |
| `if_id_phtIdx` | 13 | PHT index used (= pht_mar; for MA write-back) |
| `if_id_phtOld` | 2 | PHT counter at prediction time (for saturating ±1) |

### ID/EX Registers

| Signal | Width | Description |
|--------|-------|-------------|
| `id_ex_aluOp` | 4 | ALU opcode |
| `id_ex_isBranch` | 1 | Conditional branch flag |
| `id_ex_branchType` | 3 | Branch comparison type |
| `id_ex_isJump` | 1 | Unconditional jump flag |
| `id_ex_isJalr` | 1 | JALR flag |
| `id_ex_memRead` | 1 | Load flag |
| `id_ex_memWrite` | 1 | Store flag |
| `id_ex_memWidth` | 3 | Access width (B/H/W/BU/HU) |
| `id_ex_csrEnable` | 1 | CSR instruction flag |
| `id_ex_csrOp` | 2 | CSR operation (RW/RS/RC) |
| `id_ex_csrUseImm` | 1 | CSR use zimm flag |
| `id_ex_csrIndex` | 12 | CSR address |
| `id_ex_isECALL` | 1 | ECALL flag |
| `id_ex_isEBREAK` | 1 | EBREAK flag |
| `id_ex_isMRET` | 1 | MRET flag |
| `id_ex_isIllegal` | 1 | Illegal instruction flag |
| `id_ex_regWrite` | 1 | Register writeback enable |
| `id_ex_wbSel` | 2 | Writeback source select |
| `id_ex_rs1Data` | 32 | Pre-selected rs1 (PC or regfile rs1) |
| `id_ex_rs2Data` | 32 | Pre-selected rs2 (imm or regfile rs2) |
| `id_ex_rs1Index` | 5 | rs1 index (forwarding unit) |
| `id_ex_rs2Index` | 5 | rs2 index (forwarding unit) |
| `id_ex_rdIndex` | 5 | rd index |
| `id_ex_pc` | 32 | PC of current instruction |
| `id_ex_pc2` | 32 | PC + 2 |
| `id_ex_pc4` | 32 | PC + 4 |
| `id_ex_isComp` | 1 | Compressed flag |
| `id_ex_imm` | 32 | Immediate value |
| `id_ex_imm2` | 32 | Immediate + 2 (for TakenPC_2 via branch_target) |
| `id_ex_instr` | 32 | Raw instruction word |
| `id_ex_predTaken` | 1 | Prediction bit (pipeline carry) |
| `id_ex_predpc` | 32 | Predicted target (pipeline carry) |
| `id_ex_phtIdx` | 13 | PHT index (pipeline carry) |
| `id_ex_phtOld` | 2 | PHT counter (pipeline carry) |

### EX/MA Registers

| Signal | Width | Description |
|--------|-------|-------------|
| `ex_ma_aluResult` | 32 | ALU output |
| `ex_ma_dmemAddr` | 32 | DMEM byte address (rs1_fwd + imm) |
| `ex_ma_rs1Fwd` | 32 | Forwarded rs1 (CSR RMW source) |
| `ex_ma_rs2Fwd` | 32 | Forwarded rs2 (store data) |
| `ex_ma_rdIndex` | 5 | rd index |
| `ex_ma_regWrite` | 1 | Register writeback enable |
| `ex_ma_wbSel` | 2 | Writeback source select |
| `ex_ma_memRead` | 1 | Load flag |
| `ex_ma_memWrite` | 1 | Store flag |
| `ex_ma_memWidth` | 3 | Access width |
| `ex_ma_csrEnable` | 1 | CSR instruction flag |
| `ex_ma_csrOp` | 2 | CSR operation |
| `ex_ma_csrUseImm` | 1 | CSR use zimm flag |
| `ex_ma_csrIndex` | 12 | CSR address |
| `ex_ma_isECALL` | 1 | ECALL flag |
| `ex_ma_isEBREAK` | 1 | EBREAK flag |
| `ex_ma_isMRET` | 1 | MRET flag |
| `ex_ma_isIllegal` | 1 | Illegal instruction flag |
| `ex_ma_pc` | 32 | PC of current instruction |
| `ex_ma_pc2` | 32 | PC + 2 (BelowPC if compressed branch) |
| `ex_ma_pc4` | 32 | PC + 4 (BelowPC if 32-bit branch) |
| `ex_ma_isComp` | 1 | Compressed flag (BelowPC selector) |
| `ex_ma_instr` | 32 | Raw instruction word |
| `ex_ma_linkAddr` | 32 | JAL/JALR link: PC+2 or PC+4 |
| `ex_ma_rdNonZero` | 1 | rd ≠ x0 flag |
| `ex_ma_csrWrGuard` | 1 | CSR write allowed flag |
| `ex_ma_predTaken` | 1 | Was prediction taken for this instruction? |
| `ex_ma_predpc` | 32 | Predicted target (for miss comparison) |
| `ex_ma_phtIdx` | 13 | PHT write-back index |
| `ex_ma_phtOld` | 2 | Old PHT counter (for saturating ±1 update) |
| `ex_ma_targetAddr` | 32 | Actual branch/jump target (TakenPC) |
| `ex_ma_branchTaken` | 1 | Actual taken result |
| `ex_ma_isBranch` | 1 | Conditional branch instruction |
| `ex_ma_isJump` | 1 | Unconditional jump instruction |

### MA/WB Registers

| Signal | Width | Description |
|--------|-------|-------------|
| `ma_wb_aluResult` | 32 | ALU output |
| `ma_wb_loadData` | 32 | Sign/zero-extended load result |
| `ma_wb_csrOldData` | 32 | Old CSR value (returned to rd) |
| `ma_wb_linkAddr` | 32 | JAL/JALR link address |
| `ma_wb_rdIndex` | 5 | rd index |
| `ma_wb_regWrite` | 1 | Writeback enable (suppressed on trap) |
| `ma_wb_wbSel` | 2 | Writeback source select |
| `ma_wb_rdNonZero` | 1 | rd ≠ x0 flag |
| `ma_wb_pc` | 32 | PC of instruction (= ex_ma_pc delayed 1 cycle; used as BTB write index base) |

---

## 9. Hazard Handling

### Load-Use Stall

`hazard_unit` detects when IF's rs1/rs2 indices match the load rd in ID. Generates
`stall` → NOP written to IF/ID, PC held, load advances normally to ID/EX. 1-cycle penalty.

### Branch Misprediction - Two Levels

**Level 1 (EX stage, 2-cycle penalty)** - always fires unless Level 2 already resolved it:
```
branch_miss = !trap_en && !mret_en && !id_ex_earlySolve && ex_predMiss
ex_predMiss = (ex_branchTaken != id_ex_predTaken) || (ex_branchTaken && ex_targetMiss)
```
`ex_predMiss` is honoured for **any** instruction, not just decoded branches/jumps: if the
predictor ever predicts a non-branch taken, `ex_branchTaken(0) != predTaken(1)` flags it and
recovery redirects to the sequential PC. The §5/§14 prediction gate makes this rare, but it
remains the correctness backstop for direct-mapped BTB alias eviction.

**Level 2 (ID stage, 1-cycle penalty)** - fires when branch operands are clean
(not written by any instruction currently in EX or MA):
```
id_branch_miss = !trap_en && !mret_en && !branch_miss
              && id_branchOpsReady && id_predMiss
```
`id_ex_earlySolve` (ID/EX register carrying `id_branch_miss`) suppresses Level 1 re-check.
Mispredicted branches still flow to MA for PHT/BTB write-back regardless of which level fires.

### Flush Rules

| Register | Flush Condition |
|----------|----------------|
| IF/ID | `branch_miss \|\| id_branch_miss \|\| trap_en \|\| mret_en` |
| ID/EX | `branch_miss \|\| trap_en \|\| mret_en` |
| EX/MA | `trap_en \|\| mret_en` (**NOT** branch_miss - branch must reach MA for PHT/BTB update) |

All three registers flush on `trap_en`/`mret_en` (3-cycle penalty). `branch_miss` (EX) flushes
IF/ID and ID/EX only (2-cycle penalty). `id_branch_miss` (ID) flushes IF/ID only (1-cycle penalty).
`stall` inserts a NOP into IF/ID separately - it does not use `flush_if_id`.

### TruePC Computation

```
below_pc  = ex_ma_isComp ? ex_ma_pc2 : ex_ma_pc4   (instruction after branch)
truepc    = ex_ma_branchTaken ? ex_ma_targetAddr : below_pc
truepc2   = truepc + 32'd2
```

---

## 10. M-Mode Trap Handling

`trap_unit` is combinational, operating in the MA stage. It inspects `ex_ma_*` pipeline
register fields and the DMEM address to detect:

| Cause | Code | Condition |
|-------|------|-----------|
| Instruction address misalign | 0 | - (handled in IF; currently NOP) |
| Illegal instruction | 2 | `ex_ma_isIllegal` |
| Breakpoint | 3 | `ex_ma_isEBREAK` |
| Load address misalign | 4 | `ex_ma_memRead && addr[1:0] != 2'b00` (word), etc. |
| Store address misalign | 6 | `ex_ma_memWrite && addr[1:0] != 2'b00` (word), etc. |
| ECALL from M-mode | 11 | `ex_ma_isECALL` |

On `trap_en`: flush IF/ID, ID/EX, EX/MA; NextPC ← csr_mtvec; CSR written by `csr_regfile`.
On `mret_en`: same flush; NextPC ← csr_mepc.
`ma_wb_regWrite` is suppressed when `trap_en` fires (prevents writeback of garbage data).

### Interrupts (asynchronous traps)

`interrupt_unit` (MA stage, combinational) raises `irq_take` when `mstatus.MIE` is set, an enabled
pending interrupt exists (`mie & mip`), the MA instruction is valid, and no synchronous exception
is firing. Priority is MEI > MSI > MTI. It is folded into `trap_en` in phantom_core, so an interrupt
reuses the entire synchronous-trap path: flush IF/ID, ID/EX, EX/MA; redirect to `csr_mtvec`; save
`mepc` = the interrupted instruction's PC (it re-executes after `mret`); `mcause = {1'b1, code}`.
`mip.MTIP/MSIP/MEIP` are read-only, driven by the hardware lines `irq_timer`/`irq_soft`/`irq_ext`
(from the CLINT / external sources), never by CSR writes.

Verified end-to-end in simulation by `sim/tb_irq.sv` (a phantom_core + clint minimal SoC): three
CLINT timer interrupts fire, each taken with `mcause = 0x8000_0007` (MTI) at the interrupted
instruction's PC; the handler re-arms `mtimecmp` and `mret` resumes execution correctly.

---

## 11. Register File

`regfile.sv` - 32 × 32-bit register file built from LUT-RAM.
- Two **asynchronous** read ports (rs1, rs2) - used in ID stage.
- One **synchronous** write port - written at WB clock edge (`wr_data = wb_fwdValue`).
- x0 is not special-cased in hardware; `regWrite` is always 0 when `rd = x0`.

---

## 12. ALU

`alu.sv` - 11 operations selected by 4-bit `alu_op`:

| Code | Operation | Code | Operation |
|------|-----------|------|-----------|
| 0 | ADD | 6 | SRL |
| 1 | SUB | 7 | SRA |
| 2 | AND | 8 | SLT (signed) |
| 3 | OR  | 9 | SLTU (unsigned) |
| 4 | XOR | A | PASS_B (LUI: pass imm unchanged) |
| 5 | SLL |   | |

---

## 13. Instruction Coverage

### RV32I Base (all 47 instructions)

LUI, AUIPC, JAL, JALR, BEQ, BNE, BLT, BGE, BLTU, BGEU, LB, LH, LW, LBU, LHU,
SB, SH, SW, ADDI, SLTI, SLTIU, XORI, ORI, ANDI, SLLI, SRLI, SRAI, ADD, SUB, SLL,
SLT, SLTU, XOR, SRL, SRA, OR, AND, FENCE (NOP), ECALL, EBREAK, CSRRW, CSRRS, CSRRC,
CSRRWI, CSRRSI, CSRRCI, MRET.

### RV32C Compressed (all 36 instructions)

Full set of RV32C: C.LWSP, C.SWSP, C.LW, C.SW, C.J, C.JAL, C.JR, C.JALR, C.BEQZ,
C.BNEZ, C.LI, C.LUI, C.ADDI, C.ADDI16SP, C.ADDI4SPN, C.SLLI, C.SRLI, C.SRAI,
C.ANDI, C.MV, C.ADD, C.AND, C.OR, C.XOR, C.SUB, C.NOP, C.EBREAK.

### RV32M (all 8 instructions)

MUL, MULH, MULHSU, MULHU, DIV, DIVU, REM, REMU. Executed by `muldiv_unit` as a
multi-cycle fork in EX (DSP-inferred 2-cycle multiplier, radix-2 divider); the
front-end stalls via `ex_busy` until the result is ready.

---

## 14. Branch Prediction - Gshare Pipelined

### Architecture (after RVCoreP-32IC)

The predictor is pipelined to maintain the critical path: PHT and BTB each occupy one
BSRAM read latency stage, with their MARs on opposite sides of the PreIF stage.

**PHT (pht.sv)**: 8192 two-bit saturating counters.
- Index = `XOR(BHR[12:0], PC[13:1])` - gshare hash.
- 2-bit encoding: `00` = strongly not-taken … `11` = strongly taken.
- MSB = prediction direction. Two consecutive anomalous outcomes needed to flip.
- Written in MA on resolved conditional branches using pipeline-carried `phtOld`.

**BTB (btb.sv)**: 512 × {valid, target} entries.
- Targets in 1 EBR; `valid_mem` is a resettable FF array so cold entries never hit.
- Indexed by `ma_wb_pc[9:1]` on writes - the PC of the **instruction before** the branch.
  This compensates for r_predpc's 1-cycle latency: when the preceding instruction is fetched,
  btb_rdata already holds the branch target, so r_predpc loads correctly one cycle early.
- Read index: `next_pc[9:1]` (inside btb.sv, MAR-registered each clock edge).
- Written in MA on any taken branch or unconditional jump (sets valid).
- Cold entry (valid=0) causes first-encounter miss; trained + validated after 1 execution.

**Prediction gate**: `pred_taken = pht_rdata[1] && fd_isBranchJump && r_predvalid`. The BTB is
tagless, so it cannot itself tell a real branch from a non-branch sharing an index. The
`fd_isBranchJump` flag (fast_decoder, same-cycle aligned with the prediction) makes the check
exact - a non-branch can never redirect - and `r_predvalid` blocks cold-slot redirects. Without
this gate, gshare PHT aliasing could predict a non-branch taken toward a stale/zero target,
jumping the PC and flooding the pipeline with flushes (the bug this gate closes).

**BHR**: 13-bit global history register. Records taken/not-taken for last 13 branches
across all instruction types. Shift-in at IF stage ("join"). Reset to 0 on miss.

### Prediction Flow (per cycle)

```
Cycle N   (PreIF): pht_mar ← XOR(r_bhr, r_pc[13:1])
                   btb_mar ← next_pc[9:1]   (inside btb.sv)

Cycle N+1 (IF):    pht_rdata = pht[pht_mar]    (combinational)
                   btb_rdata = btb[btb_mar]    (combinational → r_predpc latched)
                   pred_taken = pht_rdata[1] && fd_isBranchJump && r_predvalid
                   if pred_taken → next_pc = r_predpc (0-cycle branch)
                   else          → next_pc = sequential

Cycle N+4 (MA):    Compare actual vs predicted
                   if mismatch → branch_miss, flush 3 stages, redirect to truepc
                   PHT counter updated ±1 (saturating)
                   BTB target updated if taken
```

### PHT Write (saturating ±1 using phtOld)

```
if taken:     new = (phtOld == 2'b11) ? 2'b11 : phtOld + 1
if not taken: new = (phtOld == 2'b00) ? 2'b00 : phtOld - 1
```

`phtOld` was read in IF and propagated through IF/ID → ID/EX → EX/MA to avoid a second
BSRAM read port. This is the key implementation trick enabling single-port EBR inference.

---

## 15. Memory Interface Specification

### IMEM Ports (phantom_core outputs)

| Signal | Width | Direction | Description |
|--------|-------|-----------|-------------|
| `imem_addr_a` | 32 | out | Port A address: `next_pc` (combinational from IF) |
| `imem_addr_b` | 32 | out | Port B address: `next_pc2` (combinational from IF) |
| `imem_data_a` | 16 | in | Port A read data (valid 1 cycle after address) |
| `imem_data_b` | 16 | in | Port B read data |

### DMEM Ports (phantom_core outputs)

| Signal | Width | Direction | Description |
|--------|-------|-----------|-------------|
| `dmem_raddr` | 32 | out | Read address (`ex_dmem_addr`, EX combinational → EBR read port) |
| `dmem_waddr` | 32 | out | Write address (`ex_ma_dmemAddr`, registered EX/MA → EBR write port) |
| `dmem_we` | 1 | out | Write enable (gated by `!trap_en`) |
| `dmem_be` | 4 | out | Byte enables |
| `dmem_wdata` | 32 | out | Write data |
| `dmem_rdata` | 32 | in | Read data (valid in MA, 1 cycle after address) |

### Peripheral Bus (cpu module - soc.sv interface)

| Signal | Width | Direction | Description |
|--------|-------|-----------|-------------|
| `periph_addr` | 32 | out | Registered byte address (`ex_ma_dmemAddr`) |
| `periph_wdata` | 32 | out | Store data (MA stage) |
| `periph_we` | 1 | out | Write enable (gated by `!trap_en && addr[31]`) |
| `periph_be` | 4 | out | Byte enables |
| `periph_rdata` | 32 | in | Read data from soc peripheral decode |

Address decode in cpu.sv: `addr_is_periph = dmem_waddr[31]`

---

## 16. Module Reference

| File | Module | Stage(s) | Description |
|------|--------|---------|-------------|
| `isa.vh` | - | - | All `` `define `` constants: opcodes, ALU ops, CSR addresses, trap codes, widths |
| `core/alu.sv` | `alu` | EX | Combinational ALU, 11 operations |
| `core/regfile.sv` | `regfile` | ID/WB | 32×32 LUT-RAM, 2 async read ports, 1 sync write port |
| `core/csr-regfile.sv` | `csr_regfile` | MA | M-mode CSR file, write-before-read forwarding, dual read ports |
| `core/fast-decode.sv` | `fast_decoder` | IF | Lightweight parallel decode: rs1/rs2/rd indices, isLoad, and is_branch_jump (gates branch prediction) |
| `core/control-unit.sv` | `control_unit` | ID | Full parallel decode: ALU op, source pre-select, branch/jump/mem/CSR/trap signals |
| `core/imm-generator.sv` | `imm_generator` | ID | Parallel immediate extraction; immediate + immediate_2 (imm+2) |
| `core/forwarding-unit.sv` | `forward_unit` | EX | 2-bit selector generation for rs1/rs2 forwarding muxes |
| `core/hazard-unit.sv` | `hazard_unit` | ID | Load-use stall detection |
| `core/branch-eval.sv` | `branch_eval` | EX | Conditional branch comparison (BEQ/BNE/BLT/BGE/BLTU/BGEU) |
| `core/branch-target.sv` | `branch_target` | EX | TakenPC = `(isJALR ? rs1 : pc) + imm`; TakenPC_2 = same + imm2 |
| `core/muldiv-unit.sv` | `muldiv_unit` | EX | RV32M multiply/divide: multi-cycle FSM, DSP 2-cycle multiplier + radix-2 divider; asserts `ex_busy` to stall the front-end |
| `core/trap-unit.sv` | `trap_unit` | MA | Combinational: misalignment detection, trap cause/mepc/mtval, MRET |
| `core/interrupt-unit.sv` | `interrupt_unit` | MA | Combinational: evaluate enabled+pending M-mode interrupts, priority-encode cause, inject as trap |
| `core/pht.sv` | `pht` | PreIF/IF | Gshare PHT: 8192×2-bit EBR, XOR(BHR, PrePC) index, MA write port |
| `core/btb.sv` | `btb` | PreIF/IF | Branch Target Buffer: 512 × {valid, 32-bit target}; targets in EBR, valid in resettable FFs; next_pc MAR, MA write port |
| `core/phantom-core.sv` | `phantom_core` | All | Top-level pipeline: all stages, registers, wiring, submodule instantiation |
| `soc/cpu.sv` | `cpu` | - | CPU wrapper: phantom_core + ECP5 EBR behavioral BSRAM + peripheral bus |
| `soc/soc.sv` | `soc` | - | FPGA top-level: EHXPLLL (25→50 MHz), reset seq, cpu, UART TX stub |
| `soc/periph/uart-tx.sv` | `uart_tx` | - | UART TX stub, 115200 8-N-1, no FIFO (Phase III bring-up) |
| `soc/periph/clint.sv` | `clint` | - | CLINT: mtime/mtimecmp (timer IRQ) + msip (software IRQ), SiFive offsets @ 0x8001_0000 |
| `sim/tb_core.sv` | `tb_core` | - | Verilator testbench: behavioural IMEM/DMEM, compliance harness |
| `sim/tb_irq.sv` | `tb_irq` | - | Verilator testbench: phantom_core + clint minimal SoC; verifies timer interrupts end-to-end |
| `sim/ecp5-pll-model.sv` | `EHXPLLL` | - | ECP5 EHXPLLL behavioral stub for Verilator (sim only) |

---

## 17. Naming Conventions and Style Guide

### 17.1 Signal Naming

| Pattern | Meaning | Examples |
|---------|---------|---------|
| `stage1_stage2_signalName` | Pipeline register between stage1 and stage2 | `if_id_pc`, `ex_ma_aluResult` |
| `r_signalName` | Flip-flop in the PreIF/IF register bank | `r_pc`, `r_bhr`, `r_predpc` |
| `id_signalName` | Combinational control output from control_unit in ID | `id_aluOp`, `id_memRead` |
| `fd_signalName` | Combinational output from fast_decoder in IF | `fd_rs1Index`, `fd_isLoad` |
| `ex_signalName` | Combinational signal computed in EX | `ex_dmem_addr`, `ex_targetAddr` |
| `fwd_signalName` | Forwarding mux output | `fwd_rs1Value`, `fwd_rs2Sel` |
| `flush_X_Y` | Dedicated flush signal for X/Y pipeline register | `flush_if_id`, `flush_ex_ma` |
| `csr_signalName` | CSR-related combinational signal in MA | `csr_wrData`, `csr_zimm` |
| `store_signalName` | Store byte-lane combinational signal | `store_be`, `store_data` |
| `load_signalName` | Load extraction combinational signal | `load_data` |
| `periph_signalName` | Peripheral bus signal (cpu.sv ↔ soc.sv) | `periph_addr`, `periph_we` |

### 17.2 File Conventions

- All RTL files use `.sv` (SystemVerilog)
- Module names match file names (minus extension and directory prefix)
- **One module per file** - never inline submodule logic into phantom-core.sv
- `always_comb` with `unique case` throughout - no implicit latches, no priority encoding where not needed
- `always_ff @(posedge clk)` for all pipeline registers
- `(* ram_style = "block" *)` on all BSRAM arrays - Yosys infers EBR on ECP5
- `/* verilator lint_off UNUSEDSIGNAL */` / `lint_on` used sparingly with mandatory justification comments
- Stage sections delimited with `// ====...====` banners
- Sub-sections delimited with `// ── description ─────` lines
- Verilator `-I` flag requires no space: `-I../cpu_files`

### 17.3 Code Style Rules

1. Every `always_comb` block has a `default:` or assigns all outputs unconditionally at the top
2. Every pipeline register has synchronous active-low reset loading NOP-safe values
3. `unique case` used wherever exactly one case fires
4. **Never `logic x = expr` at module scope** (synthesises as a constant; Verilator freezes at t=0)
5. No `#delay` statements in synthesisable files
6. Comments explain *why*, not *what*
7. `logic x; assign x = expr;` - always two separate statements

---

## 18. Implementation Phases and Roadmap

### Phase I - Complete (39/39 compliance)

Full RV32IC CPU in simulation: all base integer instructions, all compressed instructions,
M-mode traps (ECALL, EBREAK, illegal, misaligned, MRET), full CSR set.

### Phase II - Complete

Fmax improvements and structural alignment with RVCoreP-32IC:
- DMEM BSRAM adaptation, dedicated address adder in EX
- Single-layer forwarding MUX
- NextPC/NextPC_2 MUXes moved from PreIF into IF stage
- CSR write guard pre-computed in EX
- Load/store flat `unique case` byte-lane logic
- Dedicated flush signals per pipeline register

### Phase III - In Progress

**Completed:**
- ECP5/ULX3S migration (from Gowin GW2AR-18/Tang Nano 20K)
- ECP5 EBR behavioral BSRAM in cpu.sv (`* ram_style = "block" *`)
- EHXPLLL PLL (25→50 MHz), reset sequencer, UART TX stub in soc.sv
- Directory reorganisation: core/, soc/periph/, sim/
- ECP5 simulation stub (ecp5-pll-model.sv)
- Gshare branch predictor: pht.sv + btb.sv, **44/44 passing** (includes rv32mi)
- BTB false-prediction bug fixed: update_idx now `ma_wb_pc[BTB_IDX_W:1]`
- rv32mi compliance infrastructure: RVTEST_RV32M, RVTEST_CODE_BEGIN mtvec setup
- C.ADDI4SPN nzuimm=0 now correctly trapped as illegal
- MPP WARL restricted to M-mode only in csr-regfile.sv
- Directed verification test (6 sections: forwarding, load-use, branches, JALR, CSR) → 0x01
- M-mode interrupts: interrupt_unit + CLINT (mtime/mtimecmp timer, msip software), verified
  end-to-end by sim/tb_irq.sv (3 timer IRQs, mcause=0x8000_0007, handler re-arm + mret)
- Interrupt verification suite expanded: tb_irq + 4 directed tests under test_env/interrupts/
  (timer, software/MSI, masking-while-disabled, nested-trap-safety MIE/MPIE) - all PASS.
  Run via `make run-irq IRQ_TEST=<name>` or `make run-irq-all`
- Branch predictor robustness: fast_decoder `is_branch_jump` + BTB valid bit gate `pred_taken`
  so non-branches can never be predicted taken; `branch_miss` now honours `ex_predMiss` for any
  instruction (backstop for direct-mapped alias eviction)
- Synthesis flow complete and verified: synth/Makefile drives ELF→imem.hex (objcopy -O verilog,
  no separate converter script needed) → Yosys synth_ecp5 → nextpnr-ecp5 P&R → openFPGALoader.
  `make synth` builds soc.json clean (0 problems, no latches) - ~4% LUT, ~2% FF, 10/208 EBR, 1 PLL
- shell.nix provides the full open-source ECP5 chain (yosys, nextpnr, trellis, openFPGALoader)
  plus verilator, gtkwave, riscv32 gcc - reproducible dev environment
- test_env reorganised into core/ and interrupts/ subdirectories
- RV32M (M extension) complete: muldiv-unit.sv - DSP-inferred 2-cycle multiplier + radix-2
  restoring divider with spec-exact divide-by-zero / INT_MIN÷-1 handling, wired as a multi-cycle
  `ex_busy` fork-join in EX (front-end + ID/EX hold, EX/MA bubble, operands latched at start).
  Core is now **RV32IMC**; rv32um suite added → **52/52 compliance** (39 rv32ui+uc + 8 rv32um + 5 rv32mi)

**Remaining (gated on ULX3S 85K board - currently in delivery):**
- `make synth` is the verified ceiling until the board arrives; place-and-route, bitstream
  generation, flashing, and on-hardware UART "Hello World" are ready but untested on silicon
- SDRAM controller (32 MB on ULX3S)
- I-cache and D-cache (EBR as cache, SDRAM as backing store)
- Full UART with TX FIFO + RX path
- Supervisor mode (S-mode)

### Phase IV

HDMI, PS/2, newlib port.

### Phase V

Superscalar + limited OoO: register renaming, ROB, reservation stations, LSQ,
multiple execution units, 2-wide fetch/decode, ROB-based bypass network.

---

*Version 1.3. Reflects Phase I + Phase II complete, Phase III in progress (gshare done and debugged, M extension done (52/52 compliance), interrupts verified, synthesis flow clean - on-board bring-up pending hardware delivery).
Update this document before modifying RTL - accurate architecture documentation is a Phase V prerequisite.*
