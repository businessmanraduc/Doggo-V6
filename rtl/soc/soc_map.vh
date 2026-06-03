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
`define SOC_PERIPH_SEL_BIT      31

// ── Peripheral base addresses ─────────────────────────────────────────────────
`define SOC_UART_TX_ADDR        32'h8000_2000   // UART TX data register (write byte)
`define SOC_CLINT_SEL_HI        16'h8001        // CLINT occupies 0x8001_xxxx (64 KB)
`define SOC_ONBOARD_LEDS        32'h8000_3000   // onboard LEDs (0 to 7)

// ── Clocking / baud ───────────────────────────────────────────────────────────
`define SOC_CPU_CLK_HZ          50_000_000      // cpu_clk after the PLL
`define SOC_CLINT_TICK_HZ        1_000_000      // CLINT mtime tick rate
`define SOC_UART_CLKS_PER_BIT    434            // round(50e6 / 115200), 115200 8-N-1

`endif // SOC_MAP_VH
