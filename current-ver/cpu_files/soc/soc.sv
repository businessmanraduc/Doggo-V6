// =============================================================================
// PHANTOM-32  ──  SoC Top-Level  (Gowin GW2AR-18, Tang Nano 20K)
// =============================================================================
// FPGA top-level. Instantiates the rPLL, reset sequencer, cpu, and the first
// peripheral: a minimal UART TX stub for Phase III bring-up.
//
// Peripheral memory map (0x8000_xxxx space):
//   0x8000_2000  UART TX data register (write byte → transmit, 115200 8-N-1)
//
// Phase III+ extensions:
//   0x8000_3000  CLINT (mtime/mtimecmp, machine timer interrupt)
//   0x8000_2000  UART  with TX FIFO + status / RX path
//   SDRAM controller   (AXI4 → GW2AR-18 embedded 64 Mbit SDRAM)
// =============================================================================

module soc (
  input  logic clk_27,   // 27 MHz board crystal oscillator (Tang Nano 20K)
  input  logic resetn,   // active-low board reset button
  output logic uart_tx   // UART serial output pin (115200 8-N-1)
);

  // ===========================================================================
  // rPLL  ──  27 MHz → ~50.625 MHz
  // ===========================================================================
    logic cpu_clk;
    logic pll_lock;

    rPLL #(
      .FCLKIN    ("27"),
      .IDIV_SEL  (0),
      .FBDIV_SEL (14),
      .ODIV_SEL  (16),
      .DEVICE    ("GW2AR-18C")
    ) u_pll (
      .CLKIN   (clk_27),
      .CLKOUT  (cpu_clk),
      .LOCK    (pll_lock),
      // ── Static tie-offs for unused PLL control ports ───────────────────────
      .RESET   (1'b0),
      .RESET_P (1'b0),
      .CLKFB   (1'b0),
      .FBDSEL  (6'd0),
      .IDSEL   (6'd0),
      .ODSEL   (6'd0),
      .PSDA    (4'd0),
      .DUTYDA  (4'd0),
      .FDLY    (4'd0)
    );
  // ===========================================================================
  // rPLL  ──  27 MHz → ~50.625 MHz
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

    cpu u_cpu (
      .clk          (cpu_clk),
      .resetn       (cpu_resetn),
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

    // ── Peripheral read data ─────────────────────────────────────────────────
    // No readable peripherals in Phase III.
    // Extended to a mux when CLINT / UART status registers are added.
    assign periph_rdata = 32'h00000000;
  // ===========================================================================
  // PERIPHERAL ADDRESS DECODE
  // ===========================================================================


  // ===========================================================================
  // UART TX  ──  115200 8-N-1 transmitter
  // ===========================================================================
  // CLKS_PER_BIT = round(cpu_clk / 115200).
  // At 50.625 MHz: 50_625_000 / 115_200 ≈ 440. Adjust after PLL is verified.
  // ===========================================================================
    /* verilator lint_off UNUSEDSIGNAL */
    logic uart_tx_busy;   // reserved: future UART driver / flow control
    /* verilator lint_on  UNUSEDSIGNAL */

    uart_tx #(
      .CLKS_PER_BIT (440)
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
