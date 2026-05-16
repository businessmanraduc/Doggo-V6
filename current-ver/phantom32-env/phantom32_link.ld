/* 
=============================================================================
phantom32-env/phantom32_link.ld
=============================================================================
Linker script for the riscv-tests compliance suite on Phantom-32.

Memory map:
  0x00000000  .text   - instruction fetch starts here (RESET_VECTOR)
  after .text .data   - read/write data immediately follows code
  0x80001000  (magic) - testbench $finish trigger; NOT a real section here,
                        the PASS/FAIL macros store directly to this address

The original riscv-tests link.ld puts code at 0x80000000 and uses a .tohost
section for pass/fail signalling.  Neither applies to Phantom-32:
  • Code must start at 0x0  (hardware reset vector)
  • Pass/fail is a direct SW to 0x80001000  (no tohost symbol needed)
============================================================================= */

OUTPUT_ARCH( "riscv" )
ENTRY( _start )

SECTIONS
{
  /* ── Instruction memory ────────────────────────────────────────────────── */
  . = 0x00000000;

  .text : {
    *(.text)
    *(.text.*)
  }

  . = ALIGN(4);

  /* ── Read-only data (string literals, const arrays used by some tests) ─── */
  .rodata : {
    *(.rodata)
    *(.rodata.*)
  }

  . = ALIGN(4);

  /* ── Data memory ───────────────────────────────────────────────────────── */
  .data : {
    *(.data)
    *(.data.*)
  }

  . = ALIGN(4);

  .bss : {
    *(.bss)
    *(.bss.*)
    *(COMMON)
  }

  . = ALIGN(4);

  /* ── Discard everything else (no tohost, no htif, no sdata) ────────────── */
  /DISCARD/ : {
    *(.tohost)
    *(.htif)
    *(.sdata)
    *(.comment)
    *(.eh_frame)
    *(.riscv.attributes)
  }
}
