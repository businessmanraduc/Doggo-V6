# RISC-V RV32I ISA — Complete Beginner's Reference

> **How to use this document:**
> Every section in the Table of Contents is a clickable link.
> Every instruction in the index links directly to its full entry.
> Use your Markdown viewer's back-navigation to return after following a link.

---

## Table of Contents

1. [Philosophy and Design Goals](#1-philosophy-and-design-goals)
2. [The Register File](#2-the-register-file)
   - [The 32 Registers](#21-the-32-registers)
   - [ABI Names and Calling Conventions](#22-abi-names-and-calling-conventions)
   - [The Zero Register (x0)](#23-the-zero-register-x0)
3. [Instruction Formats](#3-instruction-formats)
   - [R-type](#31-r-type)
   - [I-type](#32-i-type)
   - [S-type](#33-s-type)
   - [B-type](#34-b-type)
   - [U-type](#35-u-type)
   - [J-type](#36-j-type)
4. [Immediate Encoding — The Quirks Explained](#4-immediate-encoding--the-quirks-explained)
   - [Why the Sign Bit is Always at Bit 31](#41-why-the-sign-bit-is-always-at-bit-31)
   - [Why B-type Scrambles the Immediate](#42-why-b-type-scrambles-the-immediate)
   - [Why J-type Scrambles the Immediate](#43-why-j-type-scrambles-the-immediate)
   - [Why U-type Immediate is Pre-Shifted](#44-why-u-type-immediate-is-pre-shifted)
5. [Opcode Map](#5-opcode-map)
6. [Instruction Reference](#6-instruction-reference)
   - [Integer Register-Register Operations (R-type)](#61-integer-register-register-operations-r-type)
     - [ADD](#add) | [SUB](#sub) | [AND](#and) | [OR](#or) | [XOR](#xor)
     - [SLL](#sll) | [SRL](#srl) | [SRA](#sra)
     - [SLT](#slt) | [SLTU](#sltu)
   - [Integer Register-Immediate Operations (I-type)](#62-integer-register-immediate-operations-i-type)
     - [ADDI](#addi) | [ANDI](#andi) | [ORI](#ori) | [XORI](#xori)
     - [SLLI](#slli) | [SRLI](#srli) | [SRAI](#srai)
     - [SLTI](#slti) | [SLTIU](#sltiu)
   - [Load Instructions (I-type)](#63-load-instructions-i-type)
     - [LW](#lw) | [LH](#lh) | [LHU](#lhu) | [LB](#lb) | [LBU](#lbu)
   - [Store Instructions (S-type)](#64-store-instructions-s-type)
     - [SW](#sw) | [SH](#sh) | [SB](#sb)
   - [Branch Instructions (B-type)](#65-branch-instructions-b-type)
     - [BEQ](#beq) | [BNE](#bne)
     - [BLT](#blt) | [BLTU](#bltu)
     - [BGE](#bge) | [BGEU](#bgeu)
   - [Upper Immediate Instructions (U-type)](#66-upper-immediate-instructions-u-type)
     - [LUI](#lui) | [AUIPC](#auipc)
   - [Jump Instructions (J-type and I-type)](#67-jump-instructions-j-type-and-i-type)
     - [JAL](#jal) | [JALR](#jalr)
   - [System Instructions](#68-system-instructions)
     - [ECALL](#ecall) | [EBREAK](#ebreak)
     - [FENCE](#fence)
     - [CSR Instructions](#csr-instructions)
7. [Pseudo-Instructions](#7-pseudo-instructions)
8. [Worked Examples — Full Programs](#8-worked-examples--full-programs)
   - [Example 1: Sum of 1 to N](#81-example-1-sum-of-1-to-n)
   - [Example 2: Absolute Value](#82-example-2-absolute-value)
   - [Example 3: Function Call and Return](#83-example-3-function-call-and-return)
   - [Example 4: Loading a 32-bit Constant](#84-example-4-loading-a-32-bit-constant)
9. [Common Quirks and Gotchas](#9-common-quirks-and-gotchas)
10. [Quick Reference Card](#10-quick-reference-card)

---

## 1. Philosophy and Design Goals

RISC-V (pronounced "risk five") was designed at UC Berkeley starting in 2010. It is the fifth RISC instruction set designed there, hence the V. Unlike every other mainstream ISA, it is **completely open** — no license, no royalties, no company owns it. The spec is frozen for the base ISA, meaning software compiled for RV32I today will run on any RV32I machine forever.

The design principles, in order of priority as stated by the designers:

**1. Small, clean base ISA.**
The base integer ISA (RV32I) has exactly 47 instructions. That is all you need to run real software. Everything else is an optional extension.

**2. Fixed-width 32-bit instructions** (for the base ISA).
Every instruction is exactly 4 bytes. The decoder always knows where the next instruction starts. No length prefix, no variable-length encoding (that is what the C extension adds on top, but the base is fixed).

**3. Register fields at fixed positions.**
`rs1` is always at bits `[19:15]`. `rs2` is always at bits `[24:20]`. `rd` is always at bits `[11:7]`. This means the register file read ports can be driven **before** the opcode is fully decoded — the hardware does not have to wait.

**4. Sign bit always at bit 31.**
For every instruction format that has an immediate, the sign bit of that immediate lives at bit 31 of the instruction. Sign extension is a single wire tapped from bit 31, with no mux required.

**5. Explicit over implicit.**
There are no condition codes (FLAGS register). There are no implicit register uses (no instruction secretly reads or writes a register you did not name). Every dependency is visible in the instruction encoding.

---

## 2. The Register File

### 2.1 The 32 Registers

RV32I has **32 general-purpose registers**, each exactly **32 bits wide**. They are named `x0` through `x31` in the hardware specification. There are no special-purpose registers hidden from the programmer — every register is accessible to every instruction (with the one exception of `x0` described below).

```
Register    Width    Notes
─────────────────────────────────────────────────────
x0          32-bit   Hardwired ZERO. Reads always return 0. Writes are ignored.
x1          32-bit   By convention: Return Address (ra)
x2          32-bit   By convention: Stack Pointer (sp)
x3          32-bit   By convention: Global Pointer (gp)
x4          32-bit   By convention: Thread Pointer (tp)
x5          32-bit   By convention: Temporary / Alternate Link Register (t0)
x6          32-bit   By convention: Temporary (t1)
x7          32-bit   By convention: Temporary (t2)
x8          32-bit   By convention: Saved register / Frame Pointer (s0 / fp)
x9          32-bit   By convention: Saved register (s1)
x10         32-bit   By convention: Function argument / return value (a0)
x11         32-bit   By convention: Function argument / return value (a1)
x12         32-bit   By convention: Function argument (a2)
x13         32-bit   By convention: Function argument (a3)
x14         32-bit   By convention: Function argument (a4)
x15         32-bit   By convention: Function argument (a5)
x16         32-bit   By convention: Function argument (a6)
x17         32-bit   By convention: Function argument (a7)
x18         32-bit   By convention: Saved register (s2)
x19         32-bit   By convention: Saved register (s3)
x20         32-bit   By convention: Saved register (s4)
x21         32-bit   By convention: Saved register (s5)
x22         32-bit   By convention: Saved register (s6)
x23         32-bit   By convention: Saved register (s7)
x24         32-bit   By convention: Saved register (s8)
x25         32-bit   By convention: Saved register (s9)
x26         32-bit   By convention: Saved register (s10)
x27         32-bit   By convention: Saved register (s11)
x28         32-bit   By convention: Temporary (t3)
x29         32-bit   By convention: Temporary (t4)
x30         32-bit   By convention: Temporary (t5)
x31         32-bit   By convention: Temporary (t6)
```

### 2.2 ABI Names and Calling Conventions

The hardware only knows `x0`–`x31`. The ABI (Application Binary Interface) assigns human-readable **alias names** used by the assembler. You can use either name — `x10` and `a0` refer to exactly the same register.

```
ABI Name    x-name    Role                          Saved by
──────────────────────────────────────────────────────────────
zero        x0        Hardwired zero                —
ra          x1        Return address                Caller
sp          x2        Stack pointer                 Callee
gp          x3        Global pointer                —
tp          x4        Thread pointer                —
t0          x5        Temporary / alt link reg      Caller
t1          x6        Temporary                     Caller
t2          x7        Temporary                     Caller
s0 / fp     x8        Saved reg / frame pointer     Callee
s1          x9        Saved register                Callee
a0          x10       Arg 0 / return value 0        Caller
a1          x11       Arg 1 / return value 1        Caller
a2          x12       Argument 2                    Caller
a3          x13       Argument 3                    Caller
a4          x14       Argument 4                    Caller
a5          x15       Argument 5                    Caller
a6          x16       Argument 6                    Caller
a7          x17       Argument 7 / syscall number   Caller
s2          x18       Saved register                Callee
s3          x19       Saved register                Callee
s4          x20       Saved register                Callee
s5          x21       Saved register                Callee
s6          x22       Saved register                Callee
s7          x23       Saved register                Callee
s8          x24       Saved register                Callee
s9          x25       Saved register                Callee
s10         x26       Saved register                Callee
s11         x27       Saved register                Callee
t3          x28       Temporary                     Caller
t4          x29       Temporary                     Caller
t5          x30       Temporary                     Caller
t6          x31       Temporary                     Caller
```

**"Saved by Caller"** means: if a function (callee) uses this register, it does NOT need to restore it. The caller is responsible for saving it before the call if it cares about the value.

**"Saved by Callee"** means: if a function uses this register, it MUST save it to the stack at the beginning and restore it before returning. The caller can rely on these being unchanged across a function call.

### 2.3 The Zero Register (x0)

`x0` is not just initialized to zero — it is **hardwired** to zero at the hardware level. No instruction can change it. Writes to `x0` are silently discarded. Reads from `x0` always return `0x00000000`.

This sounds like wasted register space, but it is one of the most useful design decisions in the ISA. It enables a huge range of useful operations without dedicated instructions:

```asm
add  a0, x0, a1      ; copy: a0 = 0 + a1 = a1
sub  a0, x0, a1      ; negate: a0 = 0 - a1 = -a1
add  x0, a0, a1      ; discard: compute a0+a1 but throw the result away
beq  a0, x0, label   ; branch if a0 == 0
sltu a0, x0, a1      ; a0 = (x0 < a1) = (0 < a1) = (a1 != 0) → convert to bool
```

---

## 3. Instruction Formats

All RV32I instructions are **exactly 32 bits wide**. There are six formats. The opcode field is always at bits `[6:0]`. Register fields `rs1`, `rs2`, and `rd` are always at the same positions when present. The `func3` field at `[14:12]` and `func7` field at `[31:25]` further disambiguate instructions that share an opcode.

Reading the diagrams below: bit 31 is on the LEFT (most significant), bit 0 is on the RIGHT (least significant). Numbers in brackets like `[11:7]` mean "bits 11 down to 7 inclusive".

---

### 3.1 R-type

Used by: register-to-register arithmetic and logic operations.

```
 31      25 24   20 19   15 14  12 11    7 6      0
┌──────────┬───────┬───────┬──────┬───────┬────────┐
│  func7   │  rs2  │  rs1  │ func3│  rd   │ opcode │
│  [31:25] │[24:20]│[19:15]│[14:12│[11:7] │ [6:0]  │
└──────────┴───────┴───────┴──────┴───────┴────────┘
   7 bits    5 bits  5 bits  3 bits  5 bits  7 bits
```

**Fields:**
- `opcode` [6:0] — always `0110011` (0x33) for integer R-type
- `rd` [11:7] — destination register
- `func3` [14:12] — selects operation (ADD vs SUB vs AND etc.)
- `rs1` [19:15] — first source register
- `rs2` [24:20] — second source register
- `func7` [31:25] — further qualifies the operation (e.g., ADD vs SUB differ only here)

**Operation:** `rd = rs1 OP rs2`

No immediate field at all. The entire instruction encodes two register sources, one destination, and the operation.

---

### 3.2 I-type

Used by: immediate arithmetic, loads, JALR, system instructions.

```
 31          20 19   15 14  12 11    7 6      0
┌──────────────┬───────┬──────┬───────┬────────┐
│   imm[11:0]  │  rs1  │ func3│  rd   │ opcode │
│   [31:20]    │[19:15]│[14:12│[11:7] │ [6:0]  │
└──────────────┴───────┴──────┴───────┴────────┘
    12 bits      5 bits  3 bits  5 bits  7 bits
```

**Fields:**
- `opcode` [6:0] — varies by instruction class
- `rd` [11:7] — destination register
- `func3` [14:12] — selects operation
- `rs1` [19:15] — source register (base address for loads, first operand for arithmetic)
- `imm[11:0]` [31:20] — 12-bit signed immediate, **sign-extended to 32 bits** before use

**Operation:** `rd = rs1 OP sext(imm[11:0])`

The immediate is sign-extended, meaning bit 11 of the immediate (which is bit 31 of the instruction) is replicated into bits [31:12] of the 32-bit value. Range: **−2048 to +2047**.

**Quirk — Shifts use a modified I-type:**
For `SLLI`, `SRLI`, `SRAI`, the shift amount only needs 5 bits (you cannot shift a 32-bit value by more than 31). The immediate field is split:
```
 31      25 24      20
┌──────────┬──────────┐
│  func7   │  shamt   │  ← only [24:20] are the shift amount (5 bits)
│  [31:25] │  [24:20] │    [31:25] is func7, distinguishing SRL from SRA
└──────────┴──────────┘
```
The upper 7 bits become a `func7`-like qualifier. This is still technically an I-type encoding — it just uses the top 7 bits of the immediate field as an opcode extension.

---

### 3.3 S-type

Used by: store instructions (SW, SH, SB).

```
 31      25 24   20 19   15 14  12 11    7 6      0
┌──────────┬───────┬───────┬──────┬───────┬────────┐
│ imm[11:5]│  rs2  │  rs1  │ func3│imm[4:0│ opcode │
│  [31:25] │[24:20]│[19:15]│[14:12│[11:7] │ [6:0]  │
└──────────┴───────┴───────┴──────┴───────┴────────┘
   7 bits    5 bits  5 bits  3 bits  5 bits  7 bits
```

**Fields:**
- `opcode` [6:0] — `0100011` (0x23) for all stores
- `imm[4:0]` [11:7] — lower 5 bits of the 12-bit signed offset
- `func3` [14:12] — selects byte/halfword/word (SB/SH/SW)
- `rs1` [19:15] — base address register
- `rs2` [24:20] — the register whose value is being stored
- `imm[11:5]` [31:25] — upper 7 bits of the 12-bit signed offset

**Why is the immediate split?** Because `rs2` needs to occupy bits [24:20]. If the immediate were contiguous, it would have to displace `rs2`. By splitting the immediate around `rs2`, the register fields stay at their fixed positions — the hardware can read `rs1` and `rs2` before knowing the offset.

To reconstruct the full immediate: `sext({ imm[11:5], imm[4:0] })` — concatenate the two pieces and sign-extend. Range: **−2048 to +2047**.

**Operation:** `memory[rs1 + sext(imm)] = rs2`

---

### 3.4 B-type

Used by: conditional branches (BEQ, BNE, BLT, BGE, BLTU, BGEU).

```
 31  30    25 24   20 19   15 14  12 11  8  7  6      0
┌───┬────────┬───────┬───────┬──────┬─────┬───┬────────┐
│ 12│imm[10:5│  rs2  │  rs1  │ func3│im[4:│ 11│ opcode │
│[31│ [30:25]│[24:20]│[19:15]│[14:12│[11:8│[7]│ [6:0]  │
└───┴────────┴───────┴───────┴──────┴─────┴───┴────────┘
 1b   6 bits   5 bits  5 bits  3 bits 4bits 1b  7 bits
```

**The immediate is scrambled.** To reconstruct it:

```
imm[12]   = instruction[31]
imm[11]   = instruction[7]
imm[10:5] = instruction[30:25]
imm[4:1]  = instruction[11:8]
imm[0]    = implicitly 0  (branch targets are always halfword-aligned)
```

Full immediate: `sext({ imm[12], imm[11], imm[10:5], imm[4:1], 1'b0 })` — a 13-bit signed offset with the low bit always zero. Range: **−4096 to +4094** in steps of 2.

**Why no imm[0]?** Branch targets must be at least halfword-aligned (2-byte aligned). The lowest bit of a valid target is always 0. Rather than waste an encoding bit on something that is always 0, it is implicit. This gives branches **double the range** for free.

**Operation:** `if (rs1 COND rs2): PC = PC + sext(imm)`

The offset is relative to the **address of the branch instruction itself**, not PC+4.

---

### 3.5 U-type

Used by: LUI, AUIPC.

```
 31                      12 11    7 6      0
┌──────────────────────────┬───────┬────────┐
│        imm[31:12]        │  rd   │ opcode │
│         [31:12]          │[11:7] │ [6:0]  │
└──────────────────────────┴───────┴────────┘
          20 bits            5 bits  7 bits
```

**Fields:**
- `opcode` [6:0] — `0110111` for LUI, `0010111` for AUIPC
- `rd` [11:7] — destination register
- `imm[31:12]` [31:12] — 20-bit upper immediate

**The immediate IS already in the right bit positions.** When the hardware uses this value, it takes `imm[31:12]` as-is and appends 12 zero bits below it. So the 20-bit field in the instruction represents bits 31 down to 12 of a 32-bit value, with bits [11:0] forced to zero.

**Operation (LUI):** `rd = { imm[31:12], 12'b0 }`
**Operation (AUIPC):** `rd = PC + { imm[31:12], 12'b0 }`

---

### 3.6 J-type

Used by: JAL only.

```
 31  30       21  20  19      12 11    7 6      0
┌───┬──────────┬───┬───────────┬───────┬────────┐
│ 20│ imm[10:1]│ 11│ imm[19:12]│  rd   │ opcode │
│[31│  [30:21] │[20│  [19:12]  │[11:7] │ [6:0]  │
└───┴──────────┴───┴───────────┴───────┴────────┘
 1b   10 bits   1b    8 bits    5 bits  7 bits
```

**The immediate is scrambled.** To reconstruct:

```
imm[20]   = instruction[31]
imm[19:12]= instruction[19:12]   ← same positions as U-type imm[19:12]!
imm[11]   = instruction[20]
imm[10:1] = instruction[30:21]
imm[0]    = implicitly 0  (jump targets must be halfword-aligned)
```

Full immediate: `sext({ imm[20], imm[19:12], imm[11], imm[10:1], 1'b0 })` — a 21-bit signed offset. Range: **−1,048,576 to +1,048,574** in steps of 2.

**The key overlap with U-type:** `imm[19:12]` sits at bits `[19:12]` in both J-type and U-type. Hardware that extracts those 8 bits does not need a mux — the same wires feed both instruction types.

**Operation:** `rd = PC + 4 ; PC = PC + sext(imm)`

JAL always saves the return address (PC+4) into `rd`. Use `rd = x0` to discard it (plain unconditional jump).

---

## 4. Immediate Encoding — The Quirks Explained

### 4.1 Why the Sign Bit is Always at Bit 31

Sign extension is one of the most common operations the decode stage performs. To sign-extend a 12-bit immediate to 32 bits, you replicate bit 11 of the immediate into positions 31 down to 12. That is 20 wires all driven by the same source bit.

In every RISC-V format, the sign bit of the immediate is **always at instruction bit 31**. This means those 20 wires are always connected to `instruction[31]`, with no multiplexer in the path. The hardware does not need to select "which bit is the sign bit" — it is always the same one.

In contrast, a hypothetical clean-field encoding where the immediate always occupies bits [31:20] would also achieve this for I-type, but once you need to split the immediate (as in S-type and B-type, to keep rs2 in its fixed position), the sign bit would have to move. RISC-V's choice ensures it never does.

### 4.2 Why B-type Scrambles the Immediate

The specific scramble in B-type (branches) exists because:

1. `rs1` and `rs2` must stay at their fixed positions [19:15] and [24:20].
2. After placing `func3`, `rs1`, `rs2`, `opcode`, you have bits [11:8] and [31:25] left for the offset.
3. The offset bit 0 is always zero (halfword alignment), so you do not encode it.
4. Bit 11 of the offset (`imm[11]`) is placed at position 7 — the one spot that in S-type holds `imm[0]`, which branches do not need.
5. This means almost all bits between S-type (stores) and B-type (branches) are either shared or only one step removed from each other.

The net result: a unified decoder can handle stores and branches with almost no conditional logic, because the register fields and most immediate bits are at identical positions.

### 4.3 Why J-type Scrambles the Immediate

The J-type scramble looks even worse but follows the same logic:

1. `rd` must stay at [11:7].
2. `imm[19:12]` is placed at [19:12] — exactly where it sits in U-type.
3. This means the hardware that extracts the upper 8 bits of both `JAL` and `LUI`/`AUIPC` immediates reads from the **same 8 wires**, with no mux.
4. `LUI` followed by `JALR` is the standard way to jump to an arbitrary 32-bit address. Their shared bit positions minimize the hardware needed for this extremely common sequence.

### 4.4 Why U-type Immediate is Pre-Shifted

`LUI rd, 0x12345` loads `0x12345000` into `rd` — not `0x00012345`. The 20-bit immediate represents the **upper 20 bits** of a 32-bit value, with the bottom 12 bits zeroed.

This exists because the typical use case is building a 32-bit constant in two instructions:

```asm
LUI   a0, 0x12345      ; a0 = 0x12345000
ADDI  a0, a0, 0x678    ; a0 = 0x12345678
```

If `LUI` stored `imm[19:0]` in the bottom 20 bits, you would need an explicit shift instruction between LUI and ADDI, costing an extra instruction. Pre-shifting by 12 makes the two-instruction sequence work directly.

**The sign extension trap:** If the lower 12 bits you want to add with ADDI are ≥ 0x800 (i.e., bit 11 is set), then ADDI will **sign-extend** a negative value. This means you must add 1 to the LUI immediate to compensate:

```asm
; Goal: load 0x12345800
LUI   a0, 0x12346      ; NOT 0x12345 — because ADDI's 0x800 sign-extends to -0x800
ADDI  a0, a0, -0x800   ; a0 = 0x12346000 + (-0x800) = 0x12345800
```

The assembler pseudo-instruction `li rd, value` handles this automatically.

---

## 5. Opcode Map

The bottom 7 bits of every instruction are the primary opcode. Bits [1:0] are always `11` for 32-bit instructions (this is how the CPU distinguishes 32-bit from 16-bit compressed instructions).

```
opcode [6:0]   Binary          Instruction class
─────────────────────────────────────────────────────────
0110011        011 0011        R-type: integer register-register
0010011        001 0011        I-type: integer register-immediate
0000011        000 0011        I-type: loads (LW, LH, LB, LHU, LBU)
0100011        010 0011        S-type: stores (SW, SH, SB)
1100011        110 0011        B-type: branches (BEQ, BNE, BLT, BGE, ...)
0110111        011 0111        U-type: LUI
0010111        001 0111        U-type: AUIPC
1101111        110 1111        J-type: JAL
1100111        110 0111        I-type: JALR
1110011        111 0011        System: ECALL, EBREAK, CSR instructions
0001111        000 1111        FENCE
```

Within each opcode, `func3` and `func7` further select the specific instruction.

---

## 6. Instruction Reference

For each instruction, the entry contains:
- The operation in pseudocode
- The full 32-bit encoding diagram
- How an assembly line maps to bit fields
- A worked example showing the complete bit pattern
- Important quirks

---

### 6.1 Integer Register-Register Operations (R-type)

All share opcode `0110011`. Distinguished by `func3` and `func7`.

---

#### ADD

**Operation:** `rd = rs1 + rs2`

Adds the 32-bit values in `rs1` and `rs2`. The result wraps around on overflow (no exception). Overflow is silently ignored.

**Encoding:**
```
 31      25 24   20 19   15 14  12 11    7 6      0
┌──────────┬───────┬───────┬──────┬───────┬────────┐
│ 0000000  │  rs2  │  rs1  │ 000  │  rd   │0110011 │
└──────────┴───────┴───────┴──────┴───────┴────────┘
```
`func7 = 0000000`, `func3 = 000`, `opcode = 0110011`

**Assembly example:**
```asm
add  x3, x1, x2      ; x3 = x1 + x2
```

**Bit-by-bit mapping** for `add x3, x1, x2`:
```
rd  = x3  = 00011
rs1 = x1  = 00001
rs2 = x2  = 00010

31   25   24-20   19-15   14-12   11-7     6-0
0000000 | 00010 | 00001 |  000  | 00011 | 0110011

Binary: 0000000 00010 00001 000 00011 0110011
Hex:    0x00208133
```

**Quirk:** ADD and SUB share the same `func3 = 000` and `opcode`. They are distinguished **only** by `func7`:
- ADD: `func7 = 0000000`
- SUB: `func7 = 0100000`

---

#### SUB

**Operation:** `rd = rs1 - rs2`

Subtracts `rs2` from `rs1`. Result wraps on overflow, no exception.

**Encoding:**
```
 31      25 24   20 19   15 14  12 11    7 6      0
┌──────────┬───────┬───────┬──────┬───────┬────────┐
│ 0100000  │  rs2  │  rs1  │ 000  │  rd   │0110011 │
└──────────┴───────┴───────┴──────┴───────┴────────┘
```
`func7 = 0100000`, `func3 = 000`, `opcode = 0110011`

**Assembly example:**
```asm
sub  a0, a0, a1      ; a0 = a0 - a1
```

**Bit-by-bit mapping** for `sub a0, a0, a1` (a0=x10, a1=x11):
```
rd  = x10 = 01010
rs1 = x10 = 01010
rs2 = x11 = 01011

31   25   24-20   19-15   14-12   11-7     6-0
0100000 | 01011 | 01010 |  000  | 01010 | 0110011

Binary: 0100000 01011 01010 000 01010 0110011
Hex:    0x40B50533
```

---

#### AND

**Operation:** `rd = rs1 & rs2`

Bitwise AND of all 32 bits.

**Encoding:**
```
┌──────────┬───────┬───────┬──────┬───────┬────────┐
│ 0000000  │  rs2  │  rs1  │ 111  │  rd   │0110011 │
└──────────┴───────┴───────┴──────┴───────┴────────┘
```
`func7 = 0000000`, `func3 = 111`

**Assembly example:**
```asm
and  t0, t0, t1      ; t0 = t0 & t1   (mask out bits)
```

**Common use:** Masking. To keep only the lower 8 bits of a register:
```asm
andi t0, t0, 0xFF    ; use the immediate version instead
```

---

#### OR

**Operation:** `rd = rs1 | rs2`

Bitwise OR of all 32 bits.

**Encoding:**
```
┌──────────┬───────┬───────┬──────┬───────┬────────┐
│ 0000000  │  rs2  │  rs1  │ 110  │  rd   │0110011 │
└──────────┴───────┴───────┴──────┴───────┴────────┘
```
`func7 = 0000000`, `func3 = 110`

**Assembly example:**
```asm
or   t0, t0, t1      ; set bits in t0 wherever t1 has 1s
```

**Common use:** Setting individual bits:
```asm
li   t1, 0x80        ; t1 = bit 7 mask
or   t0, t0, t1      ; set bit 7 of t0, leave others unchanged
```

---

#### XOR

**Operation:** `rd = rs1 ^ rs2`

Bitwise exclusive-OR of all 32 bits.

**Encoding:**
```
┌──────────┬───────┬───────┬──────┬───────┬────────┐
│ 0000000  │  rs2  │  rs1  │ 100  │  rd   │0110011 │
└──────────┴───────┴───────┴──────┴───────┴────────┘
```
`func7 = 0000000`, `func3 = 100`

**Assembly example:**
```asm
xor  t0, t0, t1      ; flip bits in t0 wherever t1 has 1s
```

**Quirk — NOT using XOR:**
There is no dedicated NOT instruction. To bitwise invert a register, XOR it with all-ones (`-1`):
```asm
xori t0, t0, -1      ; t0 = ~t0   (bitwise NOT, using immediate version)
```
`-1` in a 12-bit signed immediate is `0xFFF`, which when sign-extended gives `0xFFFFFFFF`.

**Quirk — conditional NOT pattern:**
XOR is also used to compare for equality without a comparison instruction:
```asm
xor  t0, a0, a1      ; t0 = 0 if a0 == a1, nonzero otherwise
seqz t1, t0          ; t1 = 1 if t0 == 0  (pseudo-instruction)
```

---

#### SLL

**Operation:** `rd = rs1 << rs2[4:0]`

Logical left shift. Shifts `rs1` left by the amount in the **low 5 bits** of `rs2`. Vacated bits on the right are filled with zeros. The upper 27 bits of `rs2` are **ignored**.

**Encoding:**
```
┌──────────┬───────┬───────┬──────┬───────┬────────┐
│ 0000000  │  rs2  │  rs1  │ 001  │  rd   │0110011 │
└──────────┴───────┴───────┴──────┴───────┴────────┘
```
`func7 = 0000000`, `func3 = 001`

**Assembly example:**
```asm
sll  a0, a0, a1      ; a0 = a0 << a1[4:0]
```

**Common use:** Multiply by powers of two:
```asm
li   t0, 3
sll  a0, a0, t0      ; a0 = a0 * 8 (shift left 3 = multiply by 2^3)
```

**Quirk:** Only `rs2[4:0]` is used as the shift amount. If `rs2 = 33`, the actual shift is `33 & 31 = 1`. This is consistent with x86 behavior but can surprise beginners.

---

#### SRL

**Operation:** `rd = rs1 >> rs2[4:0]`  (logical, zero-fill)

Logical right shift. Shifts `rs1` right, filling vacated bits on the left with **zeros** regardless of the sign of `rs1`. This is the **unsigned** right shift.

**Encoding:**
```
┌──────────┬───────┬───────┬──────┬───────┬────────┐
│ 0000000  │  rs2  │  rs1  │ 101  │  rd   │0110011 │
└──────────┴───────┴───────┴──────┴───────┴────────┘
```
`func7 = 0000000`, `func3 = 101`

**Assembly example:**
```asm
srl  a0, a0, a1      ; a0 = a0 >> a1[4:0]  (unsigned / logical)
```

---

#### SRA

**Operation:** `rd = rs1 >>> rs2[4:0]`  (arithmetic, sign-fill)

Arithmetic right shift. Shifts `rs1` right, filling vacated bits on the left with **copies of the sign bit** (bit 31 of `rs1`). This is the **signed** right shift — it preserves the sign of negative numbers.

**Encoding:**
```
┌──────────┬───────┬───────┬──────┬───────┬────────┐
│ 0100000  │  rs2  │  rs1  │ 101  │  rd   │0110011 │
└──────────┴───────┴───────┴──────┴───────┴────────┘
```
`func7 = 0100000`, `func3 = 101`

Notice: SRL and SRA share `func3 = 101` and differ **only** in `func7`, just like ADD and SUB.

**Assembly example:**
```asm
sra  a0, a0, a1      ; a0 = a0 >> a1[4:0]  (signed / arithmetic)
```

**Example of the difference:**
```
a0 = 0x80000000   (-2147483648 as signed int)
a1 = 1

SRL result: 0x40000000   (fills with 0: now positive)
SRA result: 0xC0000000   (fills with 1: stays negative, = -1073741824)
```

Dividing a signed integer by a power of two should use SRA, not SRL.

---

#### SLT

**Operation:** `rd = (rs1 < rs2) ? 1 : 0`  (signed comparison)

Set if Less Than (signed). Treats both operands as **signed 32-bit integers**. Writes 1 to `rd` if `rs1` is strictly less than `rs2`, else writes 0. All other bits of `rd` are cleared.

**Encoding:**
```
┌──────────┬───────┬───────┬──────┬───────┬────────┐
│ 0000000  │  rs2  │  rs1  │ 010  │  rd   │0110011 │
└──────────┴───────┴───────┴──────┴───────┴────────┘
```
`func7 = 0000000`, `func3 = 010`

**Assembly example:**
```asm
slt  t0, a0, a1      ; t0 = (a0 < a1) signed ? 1 : 0
```

**Common use:** Implementing signed comparisons for branches when you need to store the result:
```asm
slt  t0, a0, a1      ; t0 = 1 if a0 < a1
bne  t0, zero, less  ; if t0 != 0, jump to "less"
```

---

#### SLTU

**Operation:** `rd = (rs1 < rs2) ? 1 : 0`  (unsigned comparison)

Set if Less Than Unsigned. Same as SLT but treats both operands as **unsigned 32-bit integers**.

**Encoding:**
```
┌──────────┬───────┬───────┬──────┬───────┬────────┐
│ 0000000  │  rs2  │  rs1  │ 011  │  rd   │0110011 │
└──────────┴───────┴───────┴──────┴───────┴────────┘
```
`func7 = 0000000`, `func3 = 011`

**Assembly example:**
```asm
sltu t0, a0, a1      ; t0 = (a0 < a1) unsigned ? 1 : 0
```

**Quirk — SNEZ (Set if Not Equal to Zero) using SLTU:**
```asm
sltu t0, x0, a0      ; t0 = (0 < a0) unsigned = (a0 != 0) ? 1 : 0
```
Since `x0` is always 0, and 0 is unsigned-less-than any nonzero value, this converts any nonzero value to 1 and leaves zero as 0. This is how the `snez` pseudo-instruction is implemented.

---

### 6.2 Integer Register-Immediate Operations (I-type)

All share opcode `0010011`. Distinguished by `func3` (and for shifts, also `func7`).

---

#### ADDI

**Operation:** `rd = rs1 + sext(imm[11:0])`

Add Immediate. Adds a 12-bit signed immediate to `rs1`. The most frequently used instruction in typical programs.

**Encoding:**
```
 31          20 19   15 14  12 11    7 6      0
┌──────────────┬───────┬──────┬───────┬────────┐
│   imm[11:0]  │  rs1  │ 000  │  rd   │0010011 │
└──────────────┴───────┴──────┴───────┴────────┘
```
`func3 = 000`, `opcode = 0010011`

**Assembly example:**
```asm
addi a0, a0, 4       ; a0 = a0 + 4    (advance a pointer by 4 bytes)
addi a0, a0, -1      ; a0 = a0 - 1   (decrement — there is no SUBI)
```

**Bit-by-bit mapping** for `addi a0, a0, -1` (a0=x10, imm=-1=0xFFF):
```
rd  = x10   = 01010
rs1 = x10   = 01010
imm = -1    = 111111111111 (12 bits, two's complement)

31        20   19-15   14-12   11-7     6-0
111111111111 | 01010 |  000  | 01010 | 0010011

Binary: 111111111111 01010 000 01010 0010011
Hex:    0xFFF50513
```

**Critical quirk — NOP is ADDI x0, x0, 0:**
The canonical NOP in RISC-V is:
```asm
addi x0, x0, 0      ; encodes as 0x00000013
```
Writing to `x0` discards the result. Adding 0 to 0 does nothing. This is an ADDI with all fields zero (except the opcode bits).

**Critical quirk — MV (Move) is ADDI rd, rs1, 0:**
```asm
addi a0, a1, 0      ; a0 = a1   (copy register)
```
The `mv` pseudo-instruction expands to exactly this.

**Critical quirk — No SUBI:**
There is no Subtract Immediate instruction. Subtraction by a constant is done with `addi` using a negative immediate:
```asm
addi t0, t0, -5     ; t0 = t0 - 5
```

---

#### ANDI

**Operation:** `rd = rs1 & sext(imm[11:0])`

Bitwise AND with a sign-extended 12-bit immediate.

**Encoding:**
```
┌──────────────┬───────┬──────┬───────┬────────┐
│   imm[11:0]  │  rs1  │ 111  │  rd   │0010011 │
└──────────────┴───────┴──────┴───────┴────────┘
```
`func3 = 111`

**Assembly example:**
```asm
andi a0, a0, 0xFF    ; keep only low 8 bits of a0 (byte mask)
andi a0, a0, 3       ; keep only low 2 bits (word alignment check)
```

**Quirk — sign extension interacts with masking:**
Positive immediates (bit 11 = 0) zero-extend naturally — `andi a0, a0, 0x7FF` masks to 11 bits.
Negative immediates (bit 11 = 1) sign-extend to `0xFFFFF???`, which effectively only masks the lower bits:
```asm
andi a0, a0, -1      ; -1 sign-extends to 0xFFFFFFFF, AND has no effect
andi a0, a0, -4      ; -4 = 0xFFFFFFFC, clears low 2 bits (align down to word)
```

---

#### ORI

**Operation:** `rd = rs1 | sext(imm[11:0])`

Bitwise OR with a sign-extended 12-bit immediate.

**Encoding:**
```
┌──────────────┬───────┬──────┬───────┬────────┐
│   imm[11:0]  │  rs1  │ 110  │  rd   │0010011 │
└──────────────┴───────┴──────┴───────┴────────┘
```
`func3 = 110`

**Assembly example:**
```asm
ori  a0, a0, 1       ; set bit 0 of a0
```

---

#### XORI

**Operation:** `rd = rs1 ^ sext(imm[11:0])`

Bitwise XOR with a sign-extended 12-bit immediate.

**Encoding:**
```
┌──────────────┬───────┬──────┬───────┬────────┐
│   imm[11:0]  │  rs1  │ 100  │  rd   │0010011 │
└──────────────┴───────┴──────┴───────┴────────┘
```
`func3 = 100`

**Assembly example:**
```asm
xori a0, a0, -1      ; a0 = ~a0   (bitwise NOT — the canonical way)
xori a0, a0, 1       ; flip bit 0 of a0
```

**Quirk — the canonical NOT:**
`xori rd, rs1, -1` is how NOT is implemented, because `-1` sign-extends to `0xFFFFFFFF`. The `not` pseudo-instruction expands to exactly this.

---

#### SLLI

**Operation:** `rd = rs1 << shamt`

Shift Left Logical Immediate. Shift amount `shamt` is a 5-bit unsigned literal encoded in bits [24:20] of the instruction.

**Encoding:**
```
 31      25 24   20 19   15 14  12 11    7 6      0
┌──────────┬───────┬───────┬──────┬───────┬────────┐
│ 0000000  │ shamt │  rs1  │ 001  │  rd   │0010011 │
└──────────┴───────┴───────┴──────┴───────┴────────┘
```
`func7 = 0000000`, `func3 = 001`, shamt in [24:20]

**Assembly example:**
```asm
slli a0, a0, 2       ; a0 = a0 << 2   (multiply by 4)
slli a0, a0, 16      ; a0 = a0 << 16  (move low halfword to upper halfword)
```

**Bit-by-bit mapping** for `slli a0, a0, 2` (a0=x10, shamt=2):
```
rd    = x10  = 01010
rs1   = x10  = 01010
shamt = 2    = 00010

31   25    24-20   19-15   14-12   11-7     6-0
0000000  | 00010 | 01010 |  001  | 01010 | 0010011

Binary: 0000000 00010 01010 001 01010 0010011
Hex:    0x00251513
```

---

#### SRLI

**Operation:** `rd = rs1 >> shamt`  (logical, zero-fill)

Shift Right Logical Immediate. Unsigned right shift by 5-bit literal amount.

**Encoding:**
```
┌──────────┬───────┬───────┬──────┬───────┬────────┐
│ 0000000  │ shamt │  rs1  │ 101  │  rd   │0010011 │
└──────────┴───────┴───────┴──────┴───────┴────────┘
```
`func7 = 0000000`, `func3 = 101`

**Assembly example:**
```asm
srli a0, a0, 24      ; a0 = a0 >> 24  (extract byte 3 into byte 0 position)
srli a0, a0, 1       ; a0 = a0 / 2    (unsigned integer divide by 2)
```

---

#### SRAI

**Operation:** `rd = rs1 >>> shamt`  (arithmetic, sign-fill)

Shift Right Arithmetic Immediate. Signed right shift by 5-bit literal amount.

**Encoding:**
```
┌──────────┬───────┬───────┬──────┬───────┬────────┐
│ 0100000  │ shamt │  rs1  │ 101  │  rd   │0010011 │
└──────────┴───────┴───────┴──────┴───────┴────────┘
```
`func7 = 0100000`, `func3 = 101`

SRLI and SRAI differ **only** in bit 30 of the instruction (the `func7` field).

**Assembly example:**
```asm
srai a0, a0, 1       ; a0 = a0 / 2    (signed integer divide by 2, round toward negative infinity)
srai a0, a0, 31      ; a0 = 0xFFFFFFFF if a0 was negative, else 0x00000000 (sign mask)
```

---

#### SLTI

**Operation:** `rd = (rs1 < sext(imm)) ? 1 : 0`  (signed)

Set if Less Than Immediate (signed). Compares `rs1` against a sign-extended 12-bit immediate as signed integers.

**Encoding:**
```
┌──────────────┬───────┬──────┬───────┬────────┐
│   imm[11:0]  │  rs1  │ 010  │  rd   │0010011 │
└──────────────┴───────┴──────┴───────┴────────┘
```
`func3 = 010`

**Assembly example:**
```asm
slti t0, a0, 100     ; t0 = (a0 < 100) signed ? 1 : 0
```

---

#### SLTIU

**Operation:** `rd = (rs1 < sext(imm)) ? 1 : 0`  (unsigned)

Set if Less Than Immediate Unsigned. The immediate is still sign-extended to 32 bits first, but then the comparison is **unsigned**.

**Encoding:**
```
┌──────────────┬───────┬──────┬───────┬────────┐
│   imm[11:0]  │  rs1  │ 011  │  rd   │0010011 │
└──────────────┴───────┴──────┴───────┴────────┘
```
`func3 = 011`

**Assembly example:**
```asm
sltiu t0, a0, 10     ; t0 = (a0 < 10) unsigned ? 1 : 0
```

**Critical quirk — SEQZ (Set if Equal to Zero) using SLTIU:**
```asm
sltiu t0, a0, 1      ; t0 = (a0 < 1) unsigned = (a0 == 0) ? 1 : 0
```
Since `a0` is a 32-bit unsigned value, it is less than 1 if and only if it equals 0. This is how the `seqz` pseudo-instruction is implemented.

---

### 6.3 Load Instructions (I-type)

All share opcode `0000011`. Distinguish by `func3`.

The effective address is `rs1 + sext(imm[11:0])`. The result is written to `rd`.

**Alignment requirement:** The address must be naturally aligned:
- LW: address must be divisible by 4 (bits [1:0] = 00)
- LH/LHU: address must be divisible by 2 (bit [0] = 0)
- LB/LBU: no alignment constraint

Violation causes an alignment exception (trap).

---

#### LW

**Operation:** `rd = memory[rs1 + sext(imm)][31:0]`

Load Word. Loads a full 32-bit word from memory. The address must be 4-byte aligned.

**Encoding:**
```
 31          20 19   15 14  12 11    7 6      0
┌──────────────┬───────┬──────┬───────┬────────┐
│   imm[11:0]  │  rs1  │ 010  │  rd   │0000011 │
└──────────────┴───────┴──────┴───────┴────────┘
```
`func3 = 010`

**Assembly example:**
```asm
lw   a0, 0(sp)       ; a0 = memory[sp + 0]   (load word from stack top)
lw   t0, 8(a1)       ; t0 = memory[a1 + 8]   (load word at offset 8)
lw   a0, -4(s0)      ; a0 = memory[s0 + (-4)] (negative offset)
```

**Bit-by-bit mapping** for `lw a0, 8(a1)` (a0=x10, a1=x11, imm=8=0x008):
```
rd  = x10  = 01010
rs1 = x11  = 01011
imm = 8    = 000000001000

31        20   19-15   14-12   11-7     6-0
000000001000 | 01011 |  010  | 01010 | 0000011

Binary: 000000001000 01011 010 01010 0000011
Hex:    0x00858503
```

---

#### LH

**Operation:** `rd = sext(memory[rs1 + sext(imm)][15:0])`

Load Halfword (signed). Loads 16 bits from memory and **sign-extends** to 32 bits. Address must be 2-byte aligned.

**Encoding:**
```
┌──────────────┬───────┬──────┬───────┬────────┐
│   imm[11:0]  │  rs1  │ 001  │  rd   │0000011 │
└──────────────┴───────┴──────┴───────┴────────┘
```
`func3 = 001`

**Assembly example:**
```asm
lh   a0, 2(a1)       ; a0 = sign_extend(memory[a1+2][15:0])
```

If the halfword in memory is `0x8042`, the result in `a0` is `0xFFFF8042` (the high bit was 1, so it sign-extends with 1s).

---

#### LHU

**Operation:** `rd = zext(memory[rs1 + sext(imm)][15:0])`

Load Halfword Unsigned. Loads 16 bits and **zero-extends** to 32 bits. Address must be 2-byte aligned.

**Encoding:**
```
┌──────────────┬───────┬──────┬───────┬────────┐
│   imm[11:0]  │  rs1  │ 101  │  rd   │0000011 │
└──────────────┴───────┴──────┴───────┴────────┘
```
`func3 = 101`

**Assembly example:**
```asm
lhu  a0, 2(a1)       ; a0 = zero_extend(memory[a1+2][15:0])
```

If the halfword in memory is `0x8042`, the result in `a0` is `0x00008042`.

---

#### LB

**Operation:** `rd = sext(memory[rs1 + sext(imm)][7:0])`

Load Byte (signed). Loads 8 bits and **sign-extends** to 32 bits.

**Encoding:**
```
┌──────────────┬───────┬──────┬───────┬────────┐
│   imm[11:0]  │  rs1  │ 000  │  rd   │0000011 │
└──────────────┴───────┴──────┴───────┴────────┘
```
`func3 = 000`

**Assembly example:**
```asm
lb   a0, 0(a1)       ; load signed byte: -128 to +127
```

If the byte in memory is `0x80`, the result is `0xFFFFFF80` (= -128).
If the byte in memory is `0x7F`, the result is `0x0000007F` (= 127).

---

#### LBU

**Operation:** `rd = zext(memory[rs1 + sext(imm)][7:0])`

Load Byte Unsigned. Loads 8 bits and **zero-extends** to 32 bits.

**Encoding:**
```
┌──────────────┬───────┬──────┬───────┬────────┐
│   imm[11:0]  │  rs1  │ 100  │  rd   │0000011 │
└──────────────┴───────┴──────┴───────┴────────┘
```
`func3 = 100`

**Assembly example:**
```asm
lbu  a0, 0(a1)       ; load unsigned byte: 0 to 255
```

If the byte in memory is `0x80`, the result is `0x00000080` (= 128, not -128).

**When to use LB vs LBU:** If you are working with `signed char` data (e.g., processing ASCII where values can be negative in some encodings), use `LB`. If you are working with `unsigned char` (most common for raw bytes, pixel data, etc.), use `LBU`.

---

### 6.4 Store Instructions (S-type)

All share opcode `0100011`. Distinguished by `func3`.

**There is no destination register.** Stores compute the address from `rs1 + sext(imm)` and write the value from `rs2` to that address. The immediate is split between bits [31:25] and [11:7].

---

#### SW

**Operation:** `memory[rs1 + sext(imm)] = rs2[31:0]`

Store Word. Writes all 32 bits of `rs2` to memory. Address must be 4-byte aligned.

**Encoding:**
```
 31      25 24   20 19   15 14  12 11    7 6      0
┌──────────┬───────┬───────┬──────┬───────┬────────┐
│ imm[11:5]│  rs2  │  rs1  │ 010  │imm[4:0│0100011 │
└──────────┴───────┴───────┴──────┴───────┴────────┘
```
`func3 = 010`, `opcode = 0100011`

**Assembly example:**
```asm
sw   a0, 0(sp)       ; memory[sp] = a0
sw   t0, 8(a1)       ; memory[a1 + 8] = t0
```

**Bit-by-bit mapping** for `sw a0, 8(sp)` (a0=x10, sp=x2, imm=8=0b000000001000):
```
rs2     = x10  = 01010
rs1     = x2   = 00010
imm[11:5] = 0000000
imm[4:0]  = 01000

31   25    24-20   19-15   14-12   11-7     6-0
0000000  | 01010 | 00010 |  010  | 01000 | 0100011

Binary: 0000000 01010 00010 010 01000 0100011
Hex:    0x00A12423
```

---

#### SH

**Operation:** `memory[rs1 + sext(imm)] = rs2[15:0]`

Store Halfword. Writes the **low 16 bits** of `rs2` to memory. The upper 16 bits of `rs2` are ignored. Address must be 2-byte aligned.

**Encoding:**
```
┌──────────┬───────┬───────┬──────┬───────┬────────┐
│ imm[11:5]│  rs2  │  rs1  │ 001  │imm[4:0│0100011 │
└──────────┴───────┴───────┴──────┴───────┴────────┘
```
`func3 = 001`

**Assembly example:**
```asm
sh   a0, 2(a1)       ; memory[a1+2] = a0[15:0]
```

---

#### SB

**Operation:** `memory[rs1 + sext(imm)] = rs2[7:0]`

Store Byte. Writes the **low 8 bits** of `rs2` to memory. The upper 24 bits of `rs2` are ignored. No alignment requirement.

**Encoding:**
```
┌──────────┬───────┬───────┬──────┬───────┬────────┐
│ imm[11:5]│  rs2  │  rs1  │ 000  │imm[4:0│0100011 │
└──────────┴───────┴───────┴──────┴───────┴────────┘
```
`func3 = 000`

**Assembly example:**
```asm
sb   a0, 0(a1)       ; memory[a1] = a0[7:0]    (write one byte)
```

---

### 6.5 Branch Instructions (B-type)

All share opcode `1100011`. Distinguished by `func3`.

**No destination register.** Branches compute `PC_new = PC + sext(imm)` when the condition is true, otherwise `PC_new = PC + 4`. The offset is relative to the **current instruction's address**.

The 13-bit signed immediate (with bit 0 implicitly 0) gives a range of ±4096 bytes from the branch instruction. For longer jumps, use `JAL`.

---

#### BEQ

**Operation:** `if (rs1 == rs2): PC = PC + sext(imm)`

Branch if Equal. Branches when `rs1` equals `rs2` (both treated as 32-bit values, signed or unsigned — equality is the same either way).

**Encoding:**
```
 31  30    25 24   20 19   15 14  12 11  8  7  6      0
┌───┬────────┬───────┬───────┬──────┬─────┬───┬────────┐
│ 12│imm[10:5│  rs2  │  rs1  │ 000  │im4:1│ 11│1100011 │
└───┴────────┴───────┴───────┴──────┴─────┴───┴────────┘
```
`func3 = 000`

**Assembly example:**
```asm
beq  a0, a1, equal   ; if a0 == a1, jump to label "equal"
beq  t0, x0, zero    ; if t0 == 0, jump to "zero"
```

**Bit-by-bit mapping** for `beq a0, a1, 8` (a0=x10, a1=x11, offset=+8=0b0000000001000):
```
rs1 = x10  = 01010
rs2 = x11  = 01011
offset = 8 → imm[12]=0, imm[11]=0, imm[10:5]=000000, imm[4:1]=0100

31   30-25    24-20   19-15   14-12   11-8   7    6-0
 0 | 000000 | 01011 | 01010 |  000  | 0100 | 0 | 1100011

Binary: 0 000000 01011 01010 000 0100 0 1100011
Hex:    0x00B50463
```

---

#### BNE

**Operation:** `if (rs1 != rs2): PC = PC + sext(imm)`

Branch if Not Equal.

**Encoding:**
```
┌───┬────────┬───────┬───────┬──────┬─────┬───┬────────┐
│ 12│imm[10:5│  rs2  │  rs1  │ 001  │im4:1│ 11│1100011 │
└───┴────────┴───────┴───────┴──────┴─────┴───┴────────┘
```
`func3 = 001`

**Assembly example:**
```asm
bne  t0, x0, loop    ; loop while t0 != 0  (the classic countdown loop)
```

---

#### BLT

**Operation:** `if (rs1 < rs2) signed: PC = PC + sext(imm)`

Branch if Less Than (signed). Both operands treated as signed 32-bit integers.

**Encoding:**
```
┌───┬────────┬───────┬───────┬──────┬─────┬───┬────────┐
│ 12│imm[10:5│  rs2  │  rs1  │ 100  │im4:1│ 11│1100011 │
└───┴────────┴───────┴───────┴──────┴─────┴───┴────────┘
```
`func3 = 100`

**Assembly example:**
```asm
blt  a0, a1, less    ; if a0 < a1 (signed), jump to "less"
```

**Quirk — BGT is not a real instruction:**
There is no Branch if Greater Than instruction. To branch if `a0 > a1`, you reverse the operands:
```asm
blt  a1, a0, greater ; if a1 < a0 (signed), i.e., a0 > a1
```
The `bgt` pseudo-instruction expands to this.

---

#### BLTU

**Operation:** `if (rs1 < rs2) unsigned: PC = PC + sext(imm)`

Branch if Less Than Unsigned.

**Encoding:**
```
┌───┬────────┬───────┬───────┬──────┬─────┬───┬────────┐
│ 12│imm[10:5│  rs2  │  rs1  │ 110  │im4:1│ 11│1100011 │
└───┴────────┴───────┴───────┴──────┴─────┴───┴────────┘
```
`func3 = 110`

**Assembly example:**
```asm
bltu a0, a1, below   ; if a0 < a1 (unsigned), jump to "below"
```

**When to use BLTU vs BLT:**
```
a0 = 0xFFFFFFFF, a1 = 0x00000001

BLT:  0xFFFFFFFF < 0x00000001 as signed? YES: -1 < 1 = true  → branch taken
BLTU: 0xFFFFFFFF < 0x00000001 as unsigned? NO: 4294967295 > 1 = false → not taken
```

---

#### BGE

**Operation:** `if (rs1 >= rs2) signed: PC = PC + sext(imm)`

Branch if Greater or Equal (signed).

**Encoding:**
```
┌───┬────────┬───────┬───────┬──────┬─────┬───┬────────┐
│ 12│imm[10:5│  rs2  │  rs1  │ 101  │im4:1│ 11│1100011 │
└───┴────────┴───────┴───────┴──────┴─────┴───┴────────┘
```
`func3 = 101`

**Assembly example:**
```asm
bge  a0, x0, positive  ; if a0 >= 0 (signed), jump to "positive"
```

**Quirk — BLE is not a real instruction:**
To branch if `a0 <= a1`, reverse operands:
```asm
bge  a1, a0, not_greater  ; if a1 >= a0, i.e., a0 <= a1
```
The `ble` pseudo-instruction expands to this.

---

#### BGEU

**Operation:** `if (rs1 >= rs2) unsigned: PC = PC + sext(imm)`

Branch if Greater or Equal Unsigned.

**Encoding:**
```
┌───┬────────┬───────┬───────┬──────┬─────┬───┬────────┐
│ 12│imm[10:5│  rs2  │  rs1  │ 111  │im4:1│ 11│1100011 │
└───┴────────┴───────┴───────┴──────┴─────┴───┴────────┘
```
`func3 = 111`

**Assembly example:**
```asm
bgeu a0, a1, ok      ; if a0 >= a1 (unsigned), jump to "ok"
```

---

### 6.6 Upper Immediate Instructions (U-type)

---

#### LUI

**Operation:** `rd = { imm[31:12], 12'b0 }`

Load Upper Immediate. Places a 20-bit immediate into the **upper 20 bits** of `rd`, clearing the lower 12 bits to zero.

**Encoding:**
```
 31                      12 11    7 6      0
┌──────────────────────────┬───────┬────────┐
│        imm[31:12]        │  rd   │0110111 │
└──────────────────────────┴───────┴────────┘
```
`opcode = 0110111`

**Assembly example:**
```asm
lui  a0, 0x12345     ; a0 = 0x12345000
lui  a0, 1           ; a0 = 0x00001000
```

**Bit-by-bit mapping** for `lui a0, 0x12345` (a0=x10):
```
rd      = x10      = 01010
imm[31:12] = 0x12345 = 00010010001101000101

31                12   11-7     6-0
00010010001101000101 | 01010 | 0110111

Binary: 00010010001101000101 01010 0110111
Hex:    0x123452B7
```

**Primary use — building 32-bit constants:**
```asm
lui  a0, 0x12345     ; a0 = 0x12345000
addi a0, a0, 0x678   ; a0 = 0x12345678
```

**The sign-extension trap (revisited):**
```asm
; Goal: load 0xDEADBEEF into a0
; Naive (WRONG):
lui  a0, 0xDEADB      ; a0 = 0xDEADB000
addi a0, a0, 0xEEF    ; ADDI sign-extends 0xEEF: bit 11 is 1, so it's treated as -273!
                      ; result: 0xDEADB000 + (-273) = 0xDEADAEEF  ← WRONG

; Correct:
lui  a0, 0xDEADC      ; add 1 to upper immediate (0xDEADB + 1 = 0xDEADC)
addi a0, a0, -273     ; -273 in 12-bit two's complement = 0xEEF sign-extended = 0xFFFFFEEF
                      ; 0xDEADC000 + 0xFFFFFEEF = 0xDEADBEEF  ← correct
```

The assembler `li` pseudo-instruction does this automatically.

---

#### AUIPC

**Operation:** `rd = PC + { imm[31:12], 12'b0 }`

Add Upper Immediate to PC. Adds a shifted 20-bit immediate to the **current instruction's PC** and stores the result in `rd`.

**Encoding:**
```
┌──────────────────────────┬───────┬────────┐
│        imm[31:12]        │  rd   │0010111 │
└──────────────────────────┴───────┴────────┘
```
`opcode = 0010111`

**Assembly example:**
```asm
auipc a0, 0          ; a0 = PC + 0   (get current PC value)
auipc a0, 16         ; a0 = PC + 0x10000
```

**Primary use — position-independent addressing:**
`AUIPC` followed by `JALR` or a load gives you a 32-bit PC-relative address. This is how compilers generate position-independent code (PIC) and how the global offset table (GOT) is accessed:

```asm
auipc t0, %hi(symbol)       ; t0 = PC + upper bits of offset to symbol
lw    a0, %lo(symbol)(t0)   ; a0 = memory[t0 + lower bits of offset]
```

The assembler's `%hi()` and `%lo()` relocations handle the sign-correction automatically.

---

### 6.7 Jump Instructions (J-type and I-type)

---

#### JAL

**Operation:** `rd = PC + 4 ; PC = PC + sext(imm)`

Jump And Link. Unconditional PC-relative jump. Saves return address (PC+4) in `rd`. The 21-bit signed offset (with bit 0 always 0) gives a range of ±1MB from the jump instruction.

**Encoding:**
```
 31  30       21  20  19      12 11    7 6      0
┌───┬──────────┬───┬───────────┬───────┬────────┐
│ 20│ imm[10:1]│ 11│ imm[19:12]│  rd   │1101111 │
└───┴──────────┴───┴───────────┴───────┴────────┘
```
`opcode = 1101111`

**Assembly example:**
```asm
jal  ra, my_function   ; call my_function, save return address in ra
jal  x0, target        ; unconditional jump (discard return address into x0)
```

**Bit-by-bit mapping** for `jal ra, 256` (ra=x1, offset=256=0x100):
```
rd  = x1  = 00001
offset = 256 → imm[20]=0, imm[19:12]=00000000, imm[11]=0, imm[10:1]=0010000000

31   30      21  20   19    12   11-7     6-0
 0 | 0010000000 | 0 | 00000000 | 00001 | 1101111

Binary: 0 0010000000 0 00000000 00001 1101111
Hex:    0x100000EF
```

**Range:** ±1,048,576 bytes (±1MB). For longer jumps, use `LUI` + `JALR` together.

---

#### JALR

**Operation:** `rd = PC + 4 ; PC = (rs1 + sext(imm)) & ~1`

Jump And Link Register. Indirect jump to an address computed from a register plus an immediate. The lowest bit of the target is **forced to zero** (the `& ~1` part), ensuring the target is halfword-aligned.

**Encoding (I-type):**
```
 31          20 19   15 14  12 11    7 6      0
┌──────────────┬───────┬──────┬───────┬────────┐
│   imm[11:0]  │  rs1  │ 000  │  rd   │1100111 │
└──────────────┴───────┴──────┴───────┴────────┘
```
`func3 = 000`, `opcode = 1100111`

**Assembly example:**
```asm
jalr x0, ra, 0       ; return from function (jump to address in ra)
jalr ra, t0, 0       ; indirect call through function pointer in t0
jalr x0, t1, 0       ; indirect jump (tail call) to address in t1
```

**Quirk — why `& ~1`?**
If someone stores an odd address in a register and jumps to it, the low bit is silently cleared rather than causing an alignment fault. The ISA spec does this to support future 16-bit compressed instructions at halfword boundaries, and because clearing the low bit makes JALR idempotent with respect to the return address saved by JAL (which always has bit 0 = 0).

**The canonical function return:**
```asm
jalr x0, ra, 0       ; PC = ra, discard "return address" (there is no caller above us)
```
The `ret` pseudo-instruction expands to exactly this.

---

### 6.8 System Instructions

---

#### ECALL

**Operation:** Transfer control to the operating system / execution environment.

Used to request services from the OS (file I/O, memory allocation, etc.) or to switch privilege levels. In bare-metal RISC-V, this typically triggers the machine-mode trap handler.

**Encoding:**
```
 31          20 19   15 14  12 11    7 6      0
┌──────────────┬───────┬──────┬───────┬────────┐
│ 000000000000 │ 00000 │ 000  │ 00000 │1110011 │
└──────────────┴───────┴──────┴───────┴────────┘
```
Fixed encoding: `0x00000073`

**Assembly example:**
```asm
; Linux syscall: write(1, buffer, length)
li   a7, 64          ; syscall number 64 = write (in Linux on RISC-V)
li   a0, 1           ; file descriptor 1 = stdout
la   a1, my_string   ; pointer to string
li   a2, 12          ; length in bytes
ecall                ; invoke the kernel
```

By convention, the syscall number goes in `a7`, and arguments in `a0`–`a6`. Return value comes back in `a0`.

---

#### EBREAK

**Operation:** Transfer control to the debugger.

Triggers a breakpoint trap. Used by debuggers (`gdb`) to implement software breakpoints by replacing instructions with EBREAK.

**Encoding:**
```
┌──────────────┬───────┬──────┬───────┬────────┐
│ 000000000001 │ 00000 │ 000  │ 00000 │1110011 │
└──────────────┴───────┴──────┴───────┴────────┘
```
Fixed encoding: `0x00100073`

**Assembly example:**
```asm
ebreak               ; drop into debugger
```

---

#### FENCE

**Operation:** Order memory accesses.

`FENCE` ensures all memory operations issued before it complete before any issued after it are performed. Used in multi-core or memory-mapped I/O scenarios to prevent the CPU from reordering memory accesses in ways that break correctness.

**Encoding:**
```
 31  28 27  24 23  20 19   15 14  12 11    7 6      0
┌──────┬──────┬──────┬───────┬──────┬───────┬────────┐
│ 0000 │ pred │ succ │ 00000 │ 000  │ 00000 │0001111 │
└──────┴──────┴──────┴───────┴──────┴───────┴────────┘
```

`pred` and `succ` are 4-bit fields selecting which preceding/succeeding operations are ordered:
```
Bit 3: I — device Input
Bit 2: O — device Output
Bit 1: R — memory Reads
Bit 0: W — memory Writes
```

**Assembly example:**
```asm
fence rw, rw         ; full read/write memory fence (pred=0011, succ=0011)
fence.i              ; instruction fence — used before executing newly written code
```

On simple in-order single-core designs like the one we are building, FENCE is essentially a NOP — there is no reordering to prevent.

---

#### CSR Instructions

Control and Status Register instructions. These access the 4096-entry CSR space — a set of special-purpose registers for machine configuration, performance counters, interrupt control, and privilege management.

**CSRRW** (CSR Read-Write): `rd = CSR ; CSR = rs1`
**CSRRS** (CSR Read-Set): `rd = CSR ; CSR = CSR | rs1`
**CSRRC** (CSR Read-Clear): `rd = CSR ; CSR = CSR & ~rs1`
**CSRRWI/CSRRSI/CSRRCI**: Same but use a 5-bit unsigned immediate instead of `rs1`.

**Encoding (all CSR instructions):**
```
 31          20 19   15 14  12 11    7 6      0
┌──────────────┬───────┬──────┬───────┬────────┐
│  csr [11:0]  │ rs1   │ func3│  rd   │1110011 │
└──────────────┴───────┴──────┴───────┴────────┘
```
`func3 = 001 (CSRRW), 010 (CSRRS), 011 (CSRRC), 101 (CSRRWI), 110 (CSRRSI), 111 (CSRRCI)`

**Important CSRs in RV32I:**
```
0xC00   cycle       Low 32 bits of clock cycle counter
0xC01   time        Low 32 bits of real-time clock
0xC02   instret     Low 32 bits of instructions retired counter
0xC80   cycleh      High 32 bits of cycle counter
0xC81   timeh       High 32 bits of real-time clock
0xC82   instreth    High 32 bits of instret counter
```

**Assembly example:**
```asm
csrr  t0, cycle      ; t0 = cycle counter (pseudo: csrrs t0, cycle, x0)
csrrw x0, mstatus, t0 ; write t0 to mstatus, discard old value
```

---

## 7. Pseudo-Instructions

The RISC-V assembler provides pseudo-instructions — convenience mnemonics that expand to one or more real instructions. The hardware never sees them; they exist purely for programmer ergonomics.

```
Pseudo          Expands to                     Notes
─────────────────────────────────────────────────────────────────────────────
nop             addi x0, x0, 0                No operation
li rd, imm      lui+addi or just addi         Load any 32-bit constant
la rd, symbol   auipc+addi                    Load address (PC-relative)
mv rd, rs       addi rd, rs, 0                Copy register
not rd, rs      xori rd, rs, -1               Bitwise NOT
neg rd, rs      sub  rd, x0, rs               Arithmetic negation
seqz rd, rs     sltiu rd, rs, 1               rd = (rs == 0)
snez rd, rs     sltu  rd, x0, rs              rd = (rs != 0)
sltz rd, rs     slt   rd, rs, x0              rd = (rs < 0) signed
sgtz rd, rs     slt   rd, x0, rs              rd = (rs > 0) signed
beqz rs, label  beq   rs, x0, label           Branch if rs == 0
bnez rs, label  bne   rs, x0, label           Branch if rs != 0
blez rs, label  bge   x0, rs, label           Branch if rs <= 0 signed
bgez rs, label  bge   rs, x0, label           Branch if rs >= 0 signed
bltz rs, label  blt   rs, x0, label           Branch if rs < 0 signed
bgtz rs, label  blt   x0, rs, label           Branch if rs > 0 signed
bgt  rs,rt,lbl  blt   rt, rs, label           Branch if rs > rt signed
ble  rs,rt,lbl  bge   rt, rs, label           Branch if rs <= rt signed
bgtu rs,rt,lbl  bltu  rt, rs, label           Branch if rs > rt unsigned
bleu rs,rt,lbl  bgeu  rt, rs, label           Branch if rs <= rt unsigned
j    label      jal   x0, label               Unconditional jump (discard ra)
jal  label      jal   ra, label               Call (save return in ra)
jr   rs         jalr  x0, rs, 0               Jump to address in register
jalr rs         jalr  ra, rs, 0               Indirect call through register
ret             jalr  x0, ra, 0               Return from function
call label      auipc+jalr                    Long-range call (>±1MB)
tail label      auipc+jalr (x0)               Long-range tail call
fence           fence iorw, iorw              Full memory fence
csrr rd, csr    csrrs rd, csr, x0             Read CSR
csrw csr, rs    csrrw x0, csr, rs             Write CSR, discard old
csrs csr, rs    csrrs x0, csr, rs             Set bits in CSR
csrc csr, rs    csrrc x0, csr, rs             Clear bits in CSR
csrwi csr, imm  csrrwi x0, csr, imm           Write CSR immediate
csrsi csr, imm  csrrsi x0, csr, imm           Set CSR bits immediate
csrci csr, imm  csrrci x0, csr, imm           Clear CSR bits immediate
```

---

## 8. Worked Examples — Full Programs

### 8.1 Example 1: Sum of 1 to N

Compute the sum 1 + 2 + 3 + ... + N, where N is in `a0` on entry. Result in `a0` on exit.

```asm
; int sum_to_n(int n) {
;     int result = 0;
;     int i = 1;
;     while (i <= n) { result += i; i++; }
;     return result;
; }

; a0 = n (input / output)
; t0 = i (loop counter, starts at 1)
; t1 = result (accumulator, starts at 0)

sum_to_n:
    li   t1, 0          ; result = 0       → addi t1, x0, 0
    li   t0, 1          ; i = 1            → addi t0, x0, 1
loop:
    bgt  t0, a0, done   ; if i > n: exit   → blt a0, t0, done
    add  t1, t1, t0     ; result += i
    addi t0, t0, 1      ; i++
    j    loop           ; go back           → jal x0, loop
done:
    mv   a0, t1         ; return result    → addi a0, t1, 0
    ret                 ;                  → jalr x0, ra, 0
```

The comment annotations show each pseudo-instruction's real expansion.

---

### 8.2 Example 2: Absolute Value

Compute |x|, where x is in `a0`. Result in `a0`.

```asm
; int abs_val(int x) {
;     if (x < 0) return -x;
;     return x;
; }

abs_val:
    bge  a0, x0, positive   ; if a0 >= 0, skip negation
    neg  a0, a0             ; a0 = -a0  → sub a0, x0, a0
positive:
    ret
```

No branches to worry about for the happy path. The `bge` either skips one instruction or does not — on a predicted-not-taken predictor, the common case (positive input) pays no branch penalty.

---

### 8.3 Example 3: Function Call and Return

Shows the calling convention: saving `ra`, using the stack frame.

```asm
; void caller() {
;     int x = 10;
;     int result = square(x);
;     ...
; }
;
; int square(int n) {
;     return n * n;    (pretend we have MUL — using ADD loop for RV32I)
; }

caller:
    addi sp, sp, -8      ; allocate 8 bytes on stack
    sw   ra, 4(sp)       ; save return address (caller-saved by convention for ra)
    sw   s0, 0(sp)       ; save s0 (callee-saved)
    
    li   a0, 10          ; argument: n = 10
    jal  ra, square      ; call square(10), result in a0
    
    mv   s0, a0          ; save result in s0 (callee-saved, survives further calls)
    
    lw   s0, 0(sp)       ; restore s0
    lw   ra, 4(sp)       ; restore return address
    addi sp, sp, 8       ; deallocate stack frame
    ret

; square: a0 = n * n  (implemented as n additions since no MUL in RV32I base)
; Input: a0 = n
; Output: a0 = n * n
square:
    beqz a0, sq_zero     ; if n == 0, result is 0
    mv   t0, a0          ; t0 = n (counter)
    mv   t1, a0          ; t1 = accumulator, starting at n
    addi t0, t0, -1      ; loop n-1 times
sq_loop:
    beqz t0, sq_done
    add  t1, t1, a0      ; accumulator += n
    addi t0, t0, -1
    j    sq_loop
sq_done:
    mv   a0, t1
    ret
sq_zero:
    li   a0, 0
    ret
```

---

### 8.4 Example 4: Loading a 32-bit Constant

Demonstrates LUI + ADDI and the sign-correction rule.

```asm
; Case 1: upper bits only (lower 12 bits = 0)
lui  a0, 0xABCDE          ; a0 = 0xABCDE000  ← exact, no ADDI needed

; Case 2: lower 12 bits have bit 11 = 0 (positive, no correction needed)
lui  a0, 0x12345          ; a0 = 0x12345000
addi a0, a0, 0x678        ; a0 = 0x12345678  ← bit 11 of 0x678 is 0, correct

; Case 3: lower 12 bits have bit 11 = 1 (negative ADDI, needs correction)
; Goal: 0xDEADBEEF
; 0xBEEF lower 12 bits = 0xEEF = 0b111011101111 → bit 11 = 1 → negative
; Correct upper = 0xDEADB + 1 = 0xDEADC
lui  a0, 0xDEADC           ; a0 = 0xDEADC000
addi a0, a0, -273          ; -273 = 0xFFFFFEEF in 32-bit
                            ; 0xDEADC000 + 0xFFFFFEEF = 0xDEADBEEF ✓

; The assembler handles this automatically:
li   a0, 0xDEADBEEF        ; assembler generates the corrected LUI+ADDI
```

---

## 9. Common Quirks and Gotchas

### No SUBI — use ADDI with negative immediate
```asm
; Wrong idea:        subi t0, t0, 5   ; does not exist
; Correct:           addi t0, t0, -5
```

### No BGT, BLE, BGTU, BLEU — swap operands
```asm
; bgt a0, a1, lbl  →  blt a1, a0, lbl   (swap rs1 and rs2)
; ble a0, a1, lbl  →  bge a1, a0, lbl
```

### No NOT — use XORI with -1
```asm
; not t0, t0  →  xori t0, t0, -1
; -1 sign-extends to 0xFFFFFFFF, XOR with all-1s inverts every bit
```

### No NEG — use SUB from zero
```asm
; neg t0, t0  →  sub t0, x0, t0
; 0 - t0 = two's complement negation
```

### Branch offsets are from the branch instruction, not from PC+4
```asm
; On most other architectures, offsets are from PC+4 (after fetch).
; In RISC-V, the offset in BEQ/BNE/etc. is added to the address OF the branch.
; The assembler handles label resolution correctly, but be careful with manual offsets.
```

### JALR clears the low bit of the target
```asm
; PC = (rs1 + imm) & ~1
; If rs1 = 0x10000001, JALR jumps to 0x10000000, not 0x10000001.
; This is intentional (halfword alignment guarantee), but can surprise you.
```

### AUIPC adds to the address of AUIPC itself, not the next instruction
```asm
auipc t0, 1       ; t0 = address_of_this_instruction + 0x1000
; NOT: address_of_next_instruction + 0x1000
```

### SRA vs SRL on negative numbers
```asm
; li t0, -4        ; t0 = 0xFFFFFFFC
; srai t1, t0, 1   ; t1 = 0xFFFFFFFE = -2  ← arithmetic: sign fills from left
; srli t2, t0, 1   ; t2 = 0x7FFFFFFE = +2147483646  ← logical: 0 fills from left
```

### Shift amount is only the low 5 bits of the source register
```asm
; li t0, 33
; sll a0, a0, t0    ; shift amount = 33 & 31 = 1, NOT 33
; sll a0, a0, t0    ; does NOT zero out a0
```

### SLTU with x0 implements "not equal to zero"
```asm
; sltu t0, x0, a0   ; t0 = (0 < a0) unsigned = (a0 != 0) ? 1 : 0
; This works because 0 is unsigned-less-than any nonzero value.
; The snez pseudo-instruction uses exactly this.
```

### SLTIU with immediate 1 implements "equal to zero"
```asm
; sltiu t0, a0, 1   ; t0 = (a0 < 1) unsigned = (a0 == 0) ? 1 : 0
; A 32-bit value is unsigned-less-than 1 only if it equals 0.
; The seqz pseudo-instruction uses exactly this.
```

### LUI + ADDI sign correction for upper half bit 11
When the lower 12 bits of your target constant have bit 11 set (i.e., the lower 12 bits are ≥ 0x800):
- ADDI will sign-extend that value as a **negative** number
- You must add 1 to the LUI immediate to compensate
- The `li` pseudo-instruction handles this automatically

### LW/LH/LHU requires alignment; trap otherwise
```
; Address 0x00000001: LW → alignment fault (bits [1:0] != 00)
; Address 0x00000002: LW → alignment fault (bits [1:0] != 00)
; Address 0x00000002: LH → OK (bit [0] == 0)
; Address 0x00000003: LH → alignment fault (bit [0] != 0)
; Address 0x????????: LB/LBU → always OK
```

---

## 10. Quick Reference Card

### R-type instructions (opcode = 0110011)
```
Mnemonic  func7    func3   Operation
ADD       0000000  000     rd = rs1 + rs2
SUB       0100000  000     rd = rs1 - rs2
SLL       0000000  001     rd = rs1 << rs2[4:0]
SLT       0000000  010     rd = (rs1 < rs2) signed ? 1 : 0
SLTU      0000000  011     rd = (rs1 < rs2) unsigned ? 1 : 0
XOR       0000000  100     rd = rs1 ^ rs2
SRL       0000000  101     rd = rs1 >> rs2[4:0] (logical)
SRA       0100000  101     rd = rs1 >> rs2[4:0] (arithmetic)
OR        0000000  110     rd = rs1 | rs2
AND       0000000  111     rd = rs1 & rs2
```

### I-type arithmetic (opcode = 0010011)
```
Mnemonic  func3   Operation
ADDI      000     rd = rs1 + sext(imm12)
SLLI      001     rd = rs1 << shamt5  (func7=0000000)
SLTI      010     rd = (rs1 < sext(imm12)) signed
SLTIU     011     rd = (rs1 < sext(imm12)) unsigned
XORI      100     rd = rs1 ^ sext(imm12)
SRLI      101     rd = rs1 >> shamt5 logical   (func7=0000000)
SRAI      101     rd = rs1 >> shamt5 arith     (func7=0100000)
ORI       110     rd = rs1 | sext(imm12)
ANDI      111     rd = rs1 & sext(imm12)
```

### Loads (opcode = 0000011)
```
Mnemonic  func3   Width   Sign
LB        000     8-bit   sign-extend
LH        001     16-bit  sign-extend
LW        010     32-bit  —
LBU       100     8-bit   zero-extend
LHU       101     16-bit  zero-extend
```

### Stores (opcode = 0100011)
```
Mnemonic  func3   Width
SB        000     8-bit
SH        001     16-bit
SW        010     32-bit
```

### Branches (opcode = 1100011)
```
Mnemonic  func3   Condition
BEQ       000     rs1 == rs2
BNE       001     rs1 != rs2
BLT       100     rs1 < rs2  (signed)
BGE       101     rs1 >= rs2 (signed)
BLTU      110     rs1 < rs2  (unsigned)
BGEU      111     rs1 >= rs2 (unsigned)
```

### Other
```
LUI     opcode=0110111  rd = {imm[31:12], 12'b0}
AUIPC   opcode=0010111  rd = PC + {imm[31:12], 12'b0}
JAL     opcode=1101111  rd = PC+4 ; PC = PC + sext(imm21)
JALR    opcode=1100111  rd = PC+4 ; PC = (rs1 + sext(imm12)) & ~1
ECALL   0x00000073      Invoke OS / execution environment
EBREAK  0x00100073      Invoke debugger
FENCE   opcode=0001111  Memory ordering
```

---

*This document covers the RV32I base integer ISA as specified in the RISC-V Unprivileged ISA Specification version 20240411. The Zicsr extension (CSR instructions) is included as it is required by any practical implementation.*
