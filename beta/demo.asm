; =============================================================================
; PHANTOM-16  ──  Demo Program
; =============================================================================
; Computes sum = 1 + 2 + 3 + 4 + 5 = 15, stores it to memory, loads it back.
;
; Assemble:  python3 assembler.py demo.asm -v
; =============================================================================

; ── Initialise ────────────────────────────────────────────────────────────────
        LI   R1, 5          ; R1 = loop counter (counts down 5→0)
        LI   R2, 0          ; R2 = accumulator (sum)
        LI   R3, 1          ; R3 = constant 1 (decrement step)

; ── Loop: sum += i;  i-- ──────────────────────────────────────────────────────
LOOP:
        ADD  R2, R2, R1     ; sum += i
        SUB  R1, R1, R3     ; i -= 1
        BNE  R1, R0, LOOP   ; if i ≠ 0, go back  (R0 is hardwired zero)

; ── After loop: R2 == 15 ──────────────────────────────────────────────────────
        LI   R4, 0          ; R4 = memory address 0
        SW   R2, R4, 0      ; mem[0] = 15        (store result)
        LW   R5, R4, 0      ; R5 = mem[0]        (load back → load-use stall)

        HALT
