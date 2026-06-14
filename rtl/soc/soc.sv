`include "soc_map.vh"
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
  input  logic       clk_25,   // 25 MHz board crystal oscillator (ULX3S)
  input  logic       resetn,   // active-low board reset button
  output logic       uart_tx,  // UART serial output pin (115200 8-N-1)
  output logic [7:0] led,      // 8 onboard LEDs

  // ── External SDR SDRAM (W9825G6KH, 32 MB, 16-bit) ──────────────────────────
  output logic        sdram_clk,   // phase-shifted chip clock (CLKOS, ~180 deg)
  output logic        sdram_cke,
  output logic        sdram_csn,
  output logic        sdram_rasn,
  output logic        sdram_casn,
  output logic        sdram_wen,
  output logic [1:0]  sdram_ba,
  output logic [12:0] sdram_a,
  output logic [1:0]  sdram_dqm,
  inout  logic [15:0] sdram_d
);
 
  // ===========================================================================
  // EHXPLLL  ──  25 MHz → 60 MHz
  // ===========================================================================
  // Target: 60 MHz cpu_clk from 25 MHz board crystal.
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
      .CLKI_DIV        (5),
      .CLKOP_ENABLE    ("ENABLED"),
      .CLKOP_DIV       (10),
      .CLKOP_CPHASE    (4),
      .CLKOP_FPHASE    (0),
      .CLKOS_ENABLE    ("ENABLED"),
      .CLKOS_DIV       (10),
      .CLKOS_CPHASE    (9),
      .CLKOS_FPHASE    (0),
      .CLKOS2_ENABLE   ("DISABLED"),
      .CLKOS3_ENABLE   ("DISABLED"),
      .FEEDBK_PATH     ("CLKOP"),
      .CLKFB_DIV       (12)
    ) u_pll (
      .CLKI        (clk_25),
      .CLKFB       (cpu_clk),   // internal feedback from CLKOP output
      .CLKOP       (cpu_clk),
      .LOCK        (pll_lock),
      .CLKOS       (sdram_clk), // phase-shifted SDRAM chip clock
      // ── Unused secondary clock outputs ─────────────────────────────────────
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
 

  (* keep *) logic sdram_resetn;
  always_ff @(posedge cpu_clk) sdram_resetn <= cpu_resetn;

  // ===========================================================================
  // RESET SEQUENCER
  // ===========================================================================
  // cpu_resetn is held low until both conditions are true:
  //   (a) pll_lock has asserted (PLL output is stable)
  //   (b) 32 cpu_clk cycles have elapsed (pipeline flush margin)
  // Asserting the board reset button (resetn=0) re-triggers the sequencer.
  // ===========================================================================
    localparam logic [26:0] RESET_HOLD = 27'd120_000_000;
    logic [26:0] rst_cnt;
    logic cpu_resetn;

    always_ff @(posedge cpu_clk) begin
      if (!pll_lock || !resetn) begin
        rst_cnt      <= 27'd0;
        cpu_resetn   <= 1'b0;
      end else if (!cpu_resetn) begin
        if (rst_cnt == RESET_HOLD)
          cpu_resetn <= 1'b1;
        else
          rst_cnt    <= rst_cnt + 27'd1;
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

    // ── SDRAM memory bus (cpu <-> sdram_adapter) ─────────────────────────────
    logic [31:0] mem_addr, mem_wdata, mem_rdata;
    logic        mem_req, mem_we, mem_ready;
    logic [3:0]  mem_be;

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
      .periph_rdata (periph_rdata),
      .mem_addr     (mem_addr),
      .mem_req      (mem_req),
      .mem_we       (mem_we),
      .mem_wdata    (mem_wdata),
      .mem_be       (mem_be),
      .mem_rdata    (mem_rdata),
      .mem_ready    (mem_ready)
    );
  // ===========================================================================
  // CPU
  // ===========================================================================


  // ===========================================================================
  // SDRAM  ──  adapter (32-bit single access) + controller + bidir DQ
  // ===========================================================================
  // The CPU's SDRAM-region load/store (mem bus, valid in MA) is turned into a
  // 2-beat 16-bit burst by sdram_adapter and served by sdram_ctrl. mem_ready
  // stays low for the whole burst, which the core turns into a mem_stall.
  //
  // Controller timing is scaled to the 60 MHz cpu_clk:
  //   INIT_CYCLES  12000  ~= 200 us power-up wait
  //   REFRESH_CYC    420  <  tREFI (~468 cycles at 60 MHz)
  // The SDRAM chip clock (sdram_clk) is the PLL's 180-deg CLKOS output.
  // ===========================================================================
    logic [23:0] u_addr;
    logic        u_we, u_req, u_ready, u_rvalid, u_wstrobe;
    logic [15:0] u_rdata, u_wdata;
    logic [2:0]  u_wbeat;
    logic [1:0]  u_wdqm;

    // bidirectional DQ: merge the controller's split bus onto the real inout pin
    logic [15:0] dq_out, dq_in;
    logic        dq_oe;
    assign sdram_d = dq_oe ? dq_out : 16'bz;
    assign dq_in   = sdram_d;

    sdram_adapter u_adapter (
      .clk(cpu_clk), .resetn(sdram_resetn),
      .cpu_addr(mem_addr), .cpu_req(mem_req), .cpu_we(mem_we),
      .cpu_wdata(mem_wdata), .cpu_be(mem_be),
      .cpu_rdata(mem_rdata), .cpu_ready(mem_ready),
      .u_addr(u_addr), .u_we(u_we), .u_req(u_req), .u_ready(u_ready),
      .u_rdata(u_rdata), .u_rvalid(u_rvalid),
      .u_wbeat(u_wbeat), .u_wstrobe(u_wstrobe), .u_wdata(u_wdata), .u_wdqm(u_wdqm)
    );

    sdram_ctrl #(
      .BURST_LEN   (2),
      .INIT_CYCLES (12000),
      .CAS_LATENCY (2),
      .REFRESH_CYC (420)
    ) u_sdram (
      .clk(cpu_clk), .resetn(sdram_resetn),
      .u_addr(u_addr), .u_we(u_we), .u_req(u_req), .u_ready(u_ready),
      .u_rdata(u_rdata), .u_rvalid(u_rvalid),
      .u_wbeat(u_wbeat), .u_wstrobe(u_wstrobe), .u_wdata(u_wdata), .u_wdqm(u_wdqm),
      .sdram_cke(sdram_cke), .sdram_cs_n(sdram_csn), .sdram_ras_n(sdram_rasn),
      .sdram_cas_n(sdram_casn), .sdram_we_n(sdram_wen), .sdram_ba(sdram_ba),
      .sdram_a(sdram_a), .sdram_dqm(sdram_dqm),
      .sdram_dq_out(dq_out), .sdram_dq_oe(dq_oe), .sdram_dq_in(dq_in)
    );
  // ===========================================================================
  // SDRAM
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
      if (periph_we && (periph_addr == `SOC_UART_TX_ADDR)) begin
        uart_tx_valid = 1'b1;
        // Route the lowest active byte lane to the UART shift register.
        if      (periph_be[0]) uart_tx_byte = periph_wdata[7:0];
        else if (periph_be[1]) uart_tx_byte = periph_wdata[15:8];
        else if (periph_be[2]) uart_tx_byte = periph_wdata[23:16];
        else if (periph_be[3]) uart_tx_byte = periph_wdata[31:24];
      end
    end

    // ── CLINT  @  0x8001_0000  (64 KB region, SiFive-standard offsets) ───────
    assign clint_sel = (periph_addr[31:16] == `SOC_CLINT_SEL_HI);

    clint #(
      .CLK_HZ  (`SOC_CPU_CLK_HZ),
      .TICK_HZ (`SOC_CLINT_TICK_HZ)
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

    logic uart_status_sel;
    assign uart_status_sel = (periph_addr == `SOC_UART_STATUS_ADDR);

    // ── Peripheral read data mux ─────────────────────────────────────────────
    always_comb begin
      if (clint_sel)            periph_rdata = clint_rdata;
      else if (uart_status_sel) periph_rdata = {31'b0, uart_tx_busy};
      else                      periph_rdata = 32'h00000000;
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
    logic uart_tx_busy;

    uart_tx #(
      .CLKS_PER_BIT (`SOC_UART_CLKS_PER_BIT)
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


  // ===========================================================================
  // ONBOARD LEDS
  // ===========================================================================

    logic  led_sel;
    assign led_sel = (periph_addr == `SOC_ONBOARD_LEDS);

    logic [7:0] r_led_status;
    always_ff @(posedge cpu_clk) begin
      if (!cpu_resetn)
        r_led_status <= 8'd0;
      else if (periph_we && led_sel && periph_be[0])
        r_led_status <= periph_wdata[7:0];
    end

    assign led = r_led_status;

  // ===========================================================================
  // ONBOARD LEDS
  // ===========================================================================


endmodule
