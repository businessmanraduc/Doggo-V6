`ifndef SOC_MAP_VH
`define SOC_MAP_VH
// =============================================================================
// PHANTOM-32  ──  SoC Memory Map & Peripheral Parameters
// =============================================================================
// SoC-level constants: the peripheral address map and clock / baud parameters.
// Deliberately kept OUT of the core's isa.vh ─ these describe the system
// AROUND the CPU, not the instruction set. Included by soc.sv and cpu.sv.
// =============================================================================

// ── Address decode ───────────────────────────────────────────────────────────
// A load/store with bit 31 set targets the peripheral bus instead of DMEM.
// A load/store with bit 30 set (and bit 31 clear) targets external SDRAM.
// An instruction FETCH with bit 29 set targets the boot ROM (fetch-side only:
// data accesses ignore bit 29 and fall through to SDRAM).
//   0x0000_0000 .. 0x01FF_FFFF  SDRAM (32 MB, program + data; phys = addr[24:0])
//   0x2000_0000 .. 0x2000_00FF  boot ROM (64 words, UART bootloader, fetch-only)
//   0x4000_0000 .. 0x41FF_FFFF  SDRAM (32 MB, multi-cycle via sdram_adapter)
//   0x8000_0000 ..              peripheral bus (UART, CLINT, LEDs)
`define SOC_PERIPH_SEL_BIT      31
`define SOC_SDRAM_SEL_BIT       30
`define SOC_SDRAM_BASE          32'h4000_0000   // 32 MB external SDRAM window
`define SOC_BOOTROM_SEL_BIT     29
`define SOC_BOOTROM_BASE        32'h2000_0000   // UART bootloader ROM (fetch-side)

// ── Peripheral base addresses ─────────────────────────────────────────────────
`define SOC_UART_DATA_ADDR      32'h8000_2000   // UART data: write = TX byte, read = RX byte
`define SOC_UART_STATUS_ADDR    32'h8000_2004   // UART status register (read-only)
`define SOC_CLINT_SEL_HI        16'h8001        // CLINT occupies 0x8001_xxxx (64 KB)
`define SOC_ONBOARD_LEDS        32'h8000_3000   // onboard LEDs (0 to 7)

// ── Clocking / baud ───────────────────────────────────────────────────────────
`define SOC_CPU_CLK_HZ          60_000_000      // cpu_clk after the PLL
`define SOC_CLINT_TICK_HZ        1_000_000      // CLINT mtime tick rate
`define SOC_UART_CLKS_PER_BIT   (`SOC_CPU_CLK_HZ / 115_200) // 115200 8-N-1

`endif // SOC_MAP_VH
