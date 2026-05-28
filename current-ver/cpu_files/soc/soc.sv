// =============================================================================
// PHANTOM-32  ──  SoC Top-Level  (Lattice ECP5, ULX3S 85K)
// =============================================================================
// FPGA top-level. Instantiates the EHXPLLL PLL, reset sequencer, cpu, and the
// first peripheral: a minimal UART TX stub for Phase III bring-up.
//
// Peripheral memory map (0x8000_xxxx space):
//   0x8000_2000  UART TX data register (write byte → transmit, 115200 8-N-1)
//
// Phase III+ extensions:
//   0x8000_3000  CLINT (mtime/mtimecmp, machine timer interrupt)
//   0x8000_2000  UART with TX FIFO + status / RX path
//   SDRAM controller   (AXI4 → ULX3S 32 MB external SDRAM)
// =============================================================================

module soc (
  input  logic clk_25,   // 25 MHz board crystal oscillator (ULX3S)
  input  logic resetn,   // active-low board reset button
  output logic uart_tx   // UART serial output pin (115200 8-N-1)
);
 
  // ===========================================================================
  // EHXPLLL  ──  25 MHz → 50 MHz
  // ===========================================================================
  // Target: 50 MHz cpu_clk from 25 MHz board crystal.
  // ===========================================================================
    logic cpu_clk;
    logic pll_lock;

    /* verilator lint_off PINCONNECTEMPTY */
    EHXPLLL #(
      .PLLRST_ENA      ("DISABLED"),
      .INTFB_WAKE      ("DISABLED"),
      .STDBY_ENABLE    ("DISABLED"),
      .DPHASE_SOURCE   ("DISABLED"),
      .OUTDIVIDER_MUXA ("DIVA"),
      .OUTDIVIDER_MUXB ("DIVB"),
      .OUTDIVIDER_MUXC ("DIVC"),
      .OUTDIVIDER_MUXD ("DIVD"),
      .CLKI_DIV        (1),
      .CLKOP_ENABLE    ("ENABLED"),
      .CLKOP_DIV       (12),
      .CLKOP_CPHASE    (5),
      .CLKOP_FPHASE    (0),
      .CLKOS_ENABLE    ("DISABLED"),
      .CLKOS2_ENABLE   ("DISABLED"),
      .CLKOS3_ENABLE   ("DISABLED"),
      .FEEDBK_PATH     ("CLKOP"),
      .CLKFB_DIV       (24)
    ) u_pll (
      .CLKI        (clk_25),
      .CLKFB       (cpu_clk),   // internal feedback from CLKOP output
      .CLKOP       (cpu_clk),
      .LOCK        (pll_lock),
      // ── Unused secondary clock outputs ─────────────────────────────────────
      .CLKOS       (),
      .CLKOS2      (),
      .CLKOS3      (),
      .INTLOCK     (),
      .REFCLK      (),
      .CLKINTFB    (),
      // ── Static tie-offs for unused control ports ───────────────────────────
      .RST         (1'b0),
      .STDBY       (1'b0),
      .PHASESEL0   (1'b0),
      .PHASESEL1   (1'b0),
      .PHASEDIR    (1'b1),
      .PHASESTEP   (1'b1),
      .PHASELOADREG(1'b1),
      .PLLWAKESYNC (1'b0),
      .ENCLKOP     (1'b0),
      .ENCLKOS     (1'b0),
      .ENCLKOS2    (1'b0),
      .ENCLKOS3    (1'b0)
    );
    /* verilator lint_on  PINCONNECTEMPTY */
  // ===========================================================================
  // EHXPLLL
  // ===========================================================================
 

  // ===========================================================================
  // RESET SEQUENCER
  // ===========================================================================
  // cpu_resetn is held low until both conditions are true:
  //   (a) pll_lock has asserted (PLL output is stable)
  //   (b) 32 cpu_clk cycles have elapsed (pipeline flush margin)
  // Asserting the board reset button (resetn=0) re-triggers the sequencer.
  // ===========================================================================
    logic [4:0] rst_cnt;
    logic cpu_resetn;

    always_ff @(posedge cpu_clk) begin
      if (!pll_lock || !resetn) begin
        rst_cnt      <= 5'd0;
        cpu_resetn   <= 1'b0;
      end else if (!cpu_resetn) begin
        if (rst_cnt == 5'd31)
          cpu_resetn <= 1'b1;
        else
          rst_cnt    <= rst_cnt + 5'd1;
      end
    end
  // ===========================================================================
  // RESET SEQUENCER
  // ===========================================================================
 

  // ===========================================================================
  // CPU
  // ===========================================================================
    logic [31:0] periph_addr;
    logic [31:0] periph_wdata;
    logic        periph_we;
    logic [3:0]  periph_be;
    logic [31:0] periph_rdata;

    logic        clint_sel;
    logic [31:0] clint_rdata;
    logic        clint_mtip;
    logic        clint_msip;

    cpu u_cpu (
      .clk          (cpu_clk),
      .resetn       (cpu_resetn),
      .irq_timer    (clint_mtip),
      .irq_soft     (clint_msip),
      .irq_ext      (1'b0),
      .periph_addr  (periph_addr),
      .periph_wdata (periph_wdata),
      .periph_we    (periph_we),
      .periph_be    (periph_be),
      .periph_rdata (periph_rdata)
    );
  // ===========================================================================
  // CPU
  // ===========================================================================
 

  // ===========================================================================
  // PERIPHERAL ADDRESS DECODE
  // ===========================================================================

    // ── UART TX  @  0x8000_2000  ─────────────────────────────────────────────
    logic       uart_tx_valid;
    logic [7:0] uart_tx_byte;

    always_comb begin
      uart_tx_valid = 1'b0;
      uart_tx_byte  = 8'd0;
      if (periph_we && (periph_addr == 32'h80002000)) begin
        uart_tx_valid = 1'b1;
        // Route the lowest active byte lane to the UART shift register.
        if      (periph_be[0]) uart_tx_byte = periph_wdata[7:0];
        else if (periph_be[1]) uart_tx_byte = periph_wdata[15:8];
        else if (periph_be[2]) uart_tx_byte = periph_wdata[23:16];
        else if (periph_be[3]) uart_tx_byte = periph_wdata[31:24];
      end
    end

    // ── CLINT  @  0x8001_0000  (64 KB region, SiFive-standard offsets) ───────
    assign clint_sel = (periph_addr[31:16] == 16'h8001);

    clint #(
      .CLK_HZ  (50_000_000),
      .TICK_HZ (1_000_000)
    ) u_clint (
      .clk     (cpu_clk),
      .resetn  (cpu_resetn),
      .sel     (clint_sel),
      .offset  (periph_addr[15:0]),
      .we      (periph_we),
      .be      (periph_be),
      .wdata   (periph_wdata),
      .rdata   (clint_rdata),
      .mtip    (clint_mtip),
      .msip    (clint_msip)
    );

    // ── Peripheral read data mux ─────────────────────────────────────────────
    always_comb begin
      if (clint_sel) periph_rdata = clint_rdata;
      else           periph_rdata = 32'h00000000;
    end

  // ===========================================================================
  // PERIPHERAL ADDRESS DECODE
  // ===========================================================================


  // ===========================================================================
  // UART TX  ──  115200 8-N-1 transmitter
  // ===========================================================================
  // CLKS_PER_BIT = round(cpu_clk / 115200).
  // At 50.0 MHz: 50_000_000 / 115_200 ≈ 434.
  // ===========================================================================
    /* verilator lint_off UNUSEDSIGNAL */
    logic uart_tx_busy;   // reserved: future UART driver / flow control
    /* verilator lint_on  UNUSEDSIGNAL */

    uart_tx #(
      .CLKS_PER_BIT (434)
    ) u_uart_tx (
      .clk      (cpu_clk),
      .resetn   (cpu_resetn),
      .tx_byte  (uart_tx_byte),
      .tx_valid (uart_tx_valid),
      .tx_out   (uart_tx),
      .tx_busy  (uart_tx_busy)
    );
  // ===========================================================================
  // UART TX
  // ===========================================================================
 
endmodule
