.section .text
.globl _start

_start:
    li   t0, 0            // accumulator (sum)
    li   t1, 0            // i
    li   t2, 100          // count

loop:
    add  t0, t0, t1       // sum += i
    addi t1, t1, 1
    blt  t1, t2, loop     // 100 taken branches -> loop body stays cache-hot

    li   t3, 0x40         // BRAM data address (Harvard dmem port -> BRAM)
    sw   t0, 0(t3)        // store the result to BRAM
    lw   t4, 0(t3)        // read it back

    li   t5, 0x80001000   // tohost
    sw   t4, 0(t5)        // Result should be 0x00001356 (4950)

hang:
    j    hang
