#!/usr/bin/env python3
# =============================================================================
# PHANTOM-16  ──  Assembler
# =============================================================================
# Usage:
#   python3 assembler.py program.asm          → writes program.hex
#   python3 assembler.py program.asm -v       → verbose: also prints listing
#
# Syntax:
#   Labels:       LOOP:
#   Instructions: ADD R2, R2, R1
#   Comments:     ; anything after semicolon is ignored
#   Blank lines:  ignored
#
# Registers: R0 – R7   (case-insensitive)
#   R0 is hardwired zero — writing it has no effect.
#
# Supported instructions:
#   R-type:  ADD  SUB  AND  OR  XOR  SHL  SHR
#   I-type:  ADDI  LW  JALR
#   S-type:  SW
#   B-type:  BEQ  BNE          (label or numeric offset)
#   J-type:  JMP               (label or numeric offset)
#   U-type:  LI
#   SYS:     NOP  HALT
# =============================================================================

import sys
import re

# ── Opcode table ──────────────────────────────────────────────────────────────
OPCODES = {
    'ADD': 0x0, 'SUB': 0x1, 'AND': 0x2, 'OR':  0x3,
    'XOR': 0x4, 'SHL': 0x5, 'SHR': 0x6,
    'ADDI': 0x7, 'LW':  0x8, 'SW':  0x9,
    'BEQ':  0xA, 'BNE':  0xB,
    'JMP':  0xC, 'LI':   0xD, 'JALR': 0xE,
    'NOP':  0xF, 'HALT': 0xF,
}

def parse_reg(tok):
    """Parse 'Rn' → integer 0-7.  Raises ValueError on bad input."""
    tok = tok.strip().upper().lstrip('R')
    n = int(tok)
    if not (0 <= n <= 7):
        raise ValueError(f"Register out of range: R{n}")
    return n

def sext_check(value, bits, name):
    """Verify value fits in a signed <bits>-bit field."""
    lo = -(1 << (bits - 1))
    hi =  (1 << (bits - 1)) - 1
    if not (lo <= value <= hi):
        raise ValueError(f"{name} = {value} out of signed {bits}-bit range [{lo},{hi}]")
    return value & ((1 << bits) - 1)   # return as unsigned bitmask

def zext_check(value, bits, name):
    """Verify value fits in an unsigned <bits>-bit field."""
    if not (0 <= value < (1 << bits)):
        raise ValueError(f"{name} = {value} out of unsigned {bits}-bit range [0,{(1<<bits)-1}]")
    return value

def assemble(src_path, verbose=False):
    # ── Pass 1: collect labels ────────────────────────────────────────────────
    labels = {}
    addr   = 0
    lines  = []     # (line_number, address, stripped_text)

    with open(src_path) as f:
        raw = f.readlines()

    for lineno, line in enumerate(raw, 1):
        # Strip comment and whitespace
        code = re.sub(r';.*', '', line).strip()
        if not code:
            continue
        # Label definition: "LOOP:" or "LOOP :"
        m = re.match(r'^([A-Za-z_]\w*)\s*:', code)
        if m:
            lbl = m.group(1).upper()
            if lbl in labels:
                raise SyntaxError(f"Line {lineno}: duplicate label '{lbl}'")
            labels[lbl] = addr
            code = code[m.end():].strip()   # may have instruction on same line
            if not code:
                continue
        lines.append((lineno, addr, code))
        addr += 1

    # ── Pass 2: assemble ──────────────────────────────────────────────────────
    words   = []
    listing = []

    for lineno, iaddr, code in lines:
        toks = re.split(r'[\s,]+', code)
        mnemonic = toks[0].upper()

        try:
            if mnemonic in ('ADD','SUB','AND','OR','XOR','SHL','SHR'):
                # R-type:  OP rd, rs1, rs2
                rd, rs1, rs2 = parse_reg(toks[1]), parse_reg(toks[2]), parse_reg(toks[3])
                w = (OPCODES[mnemonic] << 12) | (rd << 9) | (rs1 << 6) | (rs2 << 3)

            elif mnemonic in ('ADDI', 'LW', 'JALR'):
                # I-type:  OP rd, rs1, imm6
                rd, rs1 = parse_reg(toks[1]), parse_reg(toks[2])
                imm = int(toks[3], 0)
                imm6 = sext_check(imm, 6, 'imm6')
                w = (OPCODES[mnemonic] << 12) | (rd << 9) | (rs1 << 6) | imm6

            elif mnemonic == 'SW':
                # S-type:  SW rs2, rs1, imm6   (mem[rs1+imm] = rs2)
                rs2, rs1 = parse_reg(toks[1]), parse_reg(toks[2])
                imm = int(toks[3], 0)
                imm6 = sext_check(imm, 6, 'imm6')
                w = (OPCODES['SW'] << 12) | (rs2 << 9) | (rs1 << 6) | imm6

            elif mnemonic in ('BEQ', 'BNE'):
                # B-type:  BEQ rs1, rs2, label_or_offset
                rs1, rs2 = parse_reg(toks[1]), parse_reg(toks[2])
                target = toks[3].upper()
                if target in labels:
                    # offset = target_addr - (current_addr + 1)
                    imm = labels[target] - (iaddr + 1)
                else:
                    imm = int(toks[3], 0)
                imm6 = sext_check(imm, 6, 'imm6')
                w = (OPCODES[mnemonic] << 12) | (rs1 << 9) | (rs2 << 6) | imm6

            elif mnemonic == 'JMP':
                # J-type:  JMP rd, label_or_offset
                rd = parse_reg(toks[1])
                target = toks[2].upper()
                if target in labels:
                    imm = labels[target] - (iaddr + 1)
                else:
                    imm = int(toks[2], 0)
                imm9 = sext_check(imm, 9, 'imm9')
                w = (OPCODES['JMP'] << 12) | (rd << 9) | imm9

            elif mnemonic == 'LI':
                # U-type:  LI rd, imm9   (zero-extended)
                rd = parse_reg(toks[1])
                imm = int(toks[2], 0)
                imm9 = zext_check(imm, 9, 'imm9')
                w = (OPCODES['LI'] << 12) | (rd << 9) | imm9

            elif mnemonic == 'NOP':
                w = 0xF000

            elif mnemonic == 'HALT':
                w = 0xF001

            else:
                raise ValueError(f"Unknown mnemonic '{mnemonic}'")

        except (IndexError, ValueError) as e:
            raise SyntaxError(f"Line {lineno}: {e}  →  '{code}'") from None

        words.append(w)
        listing.append((iaddr, w, code))

    # ── Output ────────────────────────────────────────────────────────────────
    out_path = src_path.rsplit('.', 1)[0] + '.hex'
    with open(out_path, 'w') as f:
        for w in words:
            f.write(f"{w:04X}\n")

    if verbose:
        print(f"\nPHANTOM-16 assembler  →  {out_path}  ({len(words)} words)\n")
        print(f"{'addr':>4}  {'hex':>4}  {'bin':>16}   assembly")
        print("─" * 60)
        for iaddr, w, src in listing:
            print(f" {iaddr:02X}   {w:04X}   {w:016b}   {src}")
        print()
        # Show labels
        if labels:
            print("Labels:")
            for lbl, a in sorted(labels.items(), key=lambda x: x[1]):
                print(f"  {lbl:20s}  →  0x{a:02X}")
            print()

    print(f"Assembled {len(words)} instruction(s)  →  {out_path}")
    return words


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Usage: python3 assembler.py <source.asm> [-v]")
        sys.exit(1)
    verbose = '-v' in sys.argv
    try:
        assemble(sys.argv[1], verbose=verbose)
    except (SyntaxError, FileNotFoundError) as e:
        print(f"Error: {e}")
        sys.exit(1)

