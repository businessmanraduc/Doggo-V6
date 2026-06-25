.section .text
.globl _start

# =============================================================================
# ENTRY / MAIN LOOP
# =============================================================================
_start:
    li   sp,  0x00100000        # stack high in SDRAM (bit31 = 0 -> SDRAM)
    li   s11, 0x80002000        # UART DATA
    li   s10, 0x80002004        # UART STATUS
    li   s9,  10                # start in decimal

main:
    call select_op              # draw menu, return chosen op (1..9) in a0
    mv   s4, a0                 # s4 = op

    la   a0, s_a                # "A = "
    call puts
    call read_number            # a0 = first number
    mv   s2, a0                 # s2 = A

    la   a0, s_b                # "B = "
    call puts
    call read_number            # a0 = second number
    mv   s3, a0                 # s3 = B

    mv   a0, s4                 # compute(op) using A=s2, B=s3
    call compute
    mv   s5, a0                 # s5 = result

    la   a0, s_res              # "Result: "
    call puts
    mv   a0, s5
    call print_number           # print result in current base
    la   a0, s_again            # "\r\nPress Enter for menu..."
    call puts
    call wait_enter             # block until Enter
    j    main                   # loop: select_op clears the screen


# =============================================================================
# MENU  --  draw it, toggle base on 'm', return a chosen op number (1..9)
# =============================================================================
select_op:
    addi sp, sp, -16
    sw   ra, 12(sp)
    sw   s0, 8(sp)
menu_top:
    call clear_screen
    call draw_menu
mc_key:
    call getc                   # a0 = one keypress
    li   t0, 'm'
    beq  a0, t0, mc_toggle      # 'm' -> switch base, redraw
    li   t0, '1'
    blt  a0, t0, mc_key         # below '1' -> ignore
    li   t0, '9'
    bgt  a0, t0, mc_key         # above '9' -> ignore
    mv   s0, a0                 # remember the digit
    call putc                   # echo it
    call crlf
    addi a0, s0, -'0'           # op number 1..9
    lw   s0, 8(sp)
    lw   ra, 12(sp)
    addi sp, sp, 16
    ret
mc_toggle:
    li   t0, 10
    bne  s9, t0, mt_to_dec      # currently hex -> go decimal
    li   s9, 16                 # currently dec -> go hex
    j    menu_top
mt_to_dec:
    li   s9, 10
    j    menu_top


# =============================================================================
# DRAW MENU  --  title + current base + the option list
# =============================================================================
draw_menu:
    addi sp, sp, -16
    sw   ra, 12(sp)
    la   a0, s_title
    call puts
    li   t0, 16
    bne  s9, t0, dm_dec
    la   a0, s_hex              # base label
    call puts
    j    dm_list
dm_dec:
    la   a0, s_dec
    call puts
dm_list:
    la   a0, s_menu
    call puts
    lw   ra, 12(sp)
    addi sp, sp, 16
    ret


# =============================================================================
# COMPUTE  --  a0 = op (1..9), operands A=s2 B=s3, result returned in a0
#              (leaf routine: no calls, touches only t0/a0)
# =============================================================================
compute:
    li   t0, 1
    beq  a0, t0, co_add
    li   t0, 2
    beq  a0, t0, co_sub
    li   t0, 3
    beq  a0, t0, co_mul
    li   t0, 4
    beq  a0, t0, co_div
    li   t0, 5
    beq  a0, t0, co_mod
    li   t0, 6
    beq  a0, t0, co_and
    li   t0, 7
    beq  a0, t0, co_or
    li   t0, 8
    beq  a0, t0, co_xor
co_shl: sll a0, s2, s3          # 9 = shift left
    ret
co_add: add a0, s2, s3
    ret
co_sub: sub a0, s2, s3
    ret
co_mul: mul a0, s2, s3
    ret
co_div: div a0, s2, s3          # signed divide (div-by-0 -> -1 per RISC-V)
    ret
co_mod: rem a0, s2, s3          # signed remainder
    ret
co_and: and a0, s2, s3
    ret
co_or:  or  a0, s2, s3
    ret
co_xor: xor a0, s2, s3
    ret


# =============================================================================
# READ_NUMBER  --  read one number from UART (echoed), terminated by Enter.
#                  Parses in the current base (s9). Decimal allows a leading '-'.
#                  Returns the value in a0.
# =============================================================================
read_number:
    addi sp, sp, -16
    sw   ra, 12(sp)
    sw   s0, 8(sp)
    sw   s1, 4(sp)
    li   s0, 0                  # accumulated value
    li   s1, 0                  # negative flag
    li   t4, 1                  # 1 = next char is the first one
rn_loop:
    call getc                   # a0 = char
    li   t0, 13
    beq  a0, t0, rn_done        # CR  -> done
    li   t0, 10
    beq  a0, t0, rn_done        # LF  -> done
    li   t0, '-'
    bne  a0, t0, rn_digit
    # ---- minus sign: only valid as the first char in decimal mode ----
    li   t0, 10
    bne  s9, t0, rn_loop        # hex mode -> ignore '-'
    beqz t4, rn_loop            # not first char -> ignore
    li   s1, 1                  # remember negative
    call putc                   # echo '-'
    li   t4, 0
    j    rn_loop
rn_digit:
    # ---- convert char in a0 to a digit in t1 (invalid -> ignore) ----
    li   t0, '0'
    blt  a0, t0, rn_loop
    li   t0, '9'
    bgt  a0, t0, rn_alpha       # above '9' -> maybe a hex letter
    addi t1, a0, -'0'           # 0..9
    j    rn_accept
rn_alpha:
    li   t0, 16
    bne  s9, t0, rn_loop        # letters only allowed in hex
    li   t0, 'a'
    blt  a0, t0, rn_upper
    li   t0, 'f'
    bgt  a0, t0, rn_loop
    addi t1, a0, -'a'+10        # a..f
    j    rn_accept
rn_upper:
    li   t0, 'A'
    blt  a0, t0, rn_loop
    li   t0, 'F'
    bgt  a0, t0, rn_loop
    addi t1, a0, -'A'+10        # A..F
rn_accept:
    mul  s0, s0, s9             # value = value*base + digit
    add  s0, s0, t1
    call putc                   # echo the digit (a0 still holds it)
    li   t4, 0
    j    rn_loop
rn_done:
    call crlf                   # move to a fresh line
    beqz s1, rn_ret
    neg  s0, s0                 # apply sign
rn_ret:
    mv   a0, s0
    lw   s1, 4(sp)
    lw   s0, 8(sp)
    lw   ra, 12(sp)
    addi sp, sp, 16
    ret


# =============================================================================
# PRINT_NUMBER  --  print a0 in the current base (DEC signed, or "0x" + HEX)
# =============================================================================
print_number:
    addi sp, sp, -16
    sw   ra, 12(sp)
    li   t0, 16
    beq  s9, t0, pn_hex
    call print_dec
    j    pn_ret
pn_hex:
    mv   t1, a0                 # keep value (putc only clobbers t0)
    li   a0, '0'
    call putc
    li   a0, 'x'
    call putc
    mv   a0, t1
    call print_hex
pn_ret:
    lw   ra, 12(sp)
    addi sp, sp, 16
    ret


# =============================================================================
# PRINT_DEC  --  print a0 as a signed decimal number
# =============================================================================
print_dec:
    addi sp, sp, -32
    sw   ra, 28(sp)
    sw   s0, 24(sp)
    sw   s1, 20(sp)
    mv   s0, a0
    bgez s0, pd_pos
    li   a0, '-'
    call putc
    neg  s0, s0                 # magnitude
pd_pos:
    li   s1, 0                  # digit count
    li   t2, 10
pd_gen:
    remu t0, s0, t2             # next least-significant digit
    divu s0, s0, t2
    addi t0, t0, '0'
    add  t1, sp, s1
    sb   t0, 0(t1)              # stash digit in the stack buffer (0..9)
    addi s1, s1, 1
    bnez s0, pd_gen             # value 0 -> still wrote one '0'
    addi s1, s1, -1             # top index
pd_pr:
    add  t1, sp, s1
    lbu  a0, 0(t1)
    call putc                   # print most-significant first
    addi s1, s1, -1
    bgez s1, pd_pr
    lw   s1, 20(sp)
    lw   s0, 24(sp)
    lw   ra, 28(sp)
    addi sp, sp, 32
    ret


# =============================================================================
# PRINT_HEX  --  print a0 as 8 hex digits
# =============================================================================
print_hex:
    addi sp, sp, -16
    sw   ra, 12(sp)
    sw   s0, 8(sp)
    sw   s1, 4(sp)
    mv   s0, a0
    li   s1, 8
ph_loop:
    srli a0, s0, 28
    andi a0, a0, 0xF
    li   t0, 9
    bgtu a0, t0, ph_alpha
    addi a0, a0, '0'
    j    ph_emit
ph_alpha:
    addi a0, a0, 'a'-10
ph_emit:
    call putc
    slli s0, s0, 4
    addi s1, s1, -1
    bnez s1, ph_loop
    lw   s1, 4(sp)
    lw   s0, 8(sp)
    lw   ra, 12(sp)
    addi sp, sp, 16
    ret


# =============================================================================
# LOW-LEVEL UART + SCREEN HELPERS
# =============================================================================

# putc(a0): send one byte (blocks while TX FIFO full). Leaf, only uses t0.
putc:
1:  lw   t0, 0(s10)
    andi t0, t0, 1              # tx_full?
    bnez t0, 1b
    sw   a0, 0(s11)
    ret

# getc -> a0: receive one byte (blocks until one arrives). Leaf, only uses t0.
getc:
1:  lw   t0, 0(s10)
    andi t0, t0, 2              # rx_valid?
    beqz t0, 1b
    lbu  a0, 0(s11)            # read DATA pops the RX FIFO
    ret

# puts(a0=ptr): print a NUL-terminated string.
puts:
    addi sp, sp, -16
    sw   ra, 12(sp)
    sw   s0, 8(sp)
    mv   s0, a0
1:  lbu  a0, 0(s0)
    beqz a0, 2f
    call putc
    addi s0, s0, 1
    j    1b
2:  lw   s0, 8(sp)
    lw   ra, 12(sp)
    addi sp, sp, 16
    ret

# crlf: print carriage-return + line-feed.
crlf:
    addi sp, sp, -16
    sw   ra, 12(sp)
    li   a0, 13
    call putc
    li   a0, 10
    call putc
    lw   ra, 12(sp)
    addi sp, sp, 16
    ret

# clear_screen: ANSI erase + cursor home.
clear_screen:
    addi sp, sp, -16
    sw   ra, 12(sp)
    la   a0, s_clear
    call puts
    lw   ra, 12(sp)
    addi sp, sp, 16
    ret

# wait_enter: block until the user presses Enter (CR or LF). Discards other keys.
wait_enter:
    addi sp, sp, -16
    sw   ra, 12(sp)
1:  call getc
    li   t0, 13
    beq  a0, t0, 2f
    li   t0, 10
    beq  a0, t0, 2f
    j    1b
2:  lw   ra, 12(sp)
    addi sp, sp, 16
    ret


# =============================================================================
# READ-ONLY STRINGS
# =============================================================================
.section .rodata
.balign 4
s_clear: .asciz "\033[2J\033[H"
s_title: .asciz "=== PHANTOM-32 CALCULATOR ===\r\nBase: "
s_dec:   .asciz "DEC\r\n"
s_hex:   .asciz "HEX\r\n"
s_menu:  .asciz "1)ADD 2)SUB 3)MUL 4)DIV 5)MOD\r\n6)AND 7)OR 8)XOR 9)SHL  m)base\r\nSelect: "
s_a:     .asciz "\r\nA = "
s_b:     .asciz "B = "
s_res:   .asciz "Result: "
s_again: .asciz "\r\nPress Enter for menu..."
