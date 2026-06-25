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
  input  logic       uart_rx,  // UART serial input  pin (host -> FPGA)
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
  always_ff @(posedge cpu_clk) sdram_resetn <= resetn_seq;
  logic preload_done;   // 1 = load & read-back verify complete
  logic verify_ok;      // 1 = SDRAM read-back matches the source

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
    logic        resetn_seq;
    logic        cpu_resetn;

    always_ff @(posedge cpu_clk) begin
      if (!pll_lock || !resetn) begin
        rst_cnt      <= 27'd0;
        resetn_seq   <= 1'b0;
      end else if (!resetn_seq) begin
        if (rst_cnt == RESET_HOLD)
          resetn_seq <= 1'b1;
        else
          rst_cnt    <= rst_cnt + 27'd1;
      end
    end

    logic cpu_release;
    always_ff @(posedge cpu_clk) cpu_release <= resetn_seq && preload_done && verify_ok;
    DCCA u_resetn_gbuf (.CLKI(cpu_release), .CLKO(cpu_resetn), .CE(1'b1));
  // ===========================================================================
  // RESET SEQUENCER
  // ===========================================================================
 

  // ===========================================================================
  // CPU
  // ===========================================================================
    logic [31:0] periph_addr;
    logic [31:0] periph_wdata;
    logic        periph_we;
    logic        periph_re;
    logic [3:0]  periph_be;
    logic [31:0] periph_rdata;

    logic        clint_sel;
    logic [31:0] clint_rdata;
    logic        clint_mtip;
    logic        clint_msip;

    // ── SDRAM memory bus (cpu <-> sdram_adapter) ─────────────────────────────
    logic [31:0] mem_addr, mem_wdata, mem_rdata;
    logic        mem_req, mem_we, mem_burst, mem_rvalid, mem_ready;
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
      .periph_re    (periph_re),
      .periph_be    (periph_be),
      .periph_rdata (periph_rdata),
      .mem_addr     (mem_addr),
      .mem_req      (mem_req),
      .mem_we       (mem_we),
      .mem_burst    (mem_burst),
      .mem_wdata    (mem_wdata),
      .mem_be       (mem_be),
      .mem_rdata    (mem_rdata),
      .mem_rvalid   (mem_rvalid),
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
    logic        u_we, u_dbl, u_req, u_ready, u_rvalid, u_wstrobe;
    logic [15:0] u_rdata, u_wdata;
    logic [2:0]  u_wbeat;
    logic [1:0]  u_wdqm;

    // bidirectional DQ: merge the controller's split bus onto the real inout pin
    logic [15:0] dq_out, dq_in;
    logic        dq_oe;
    assign sdram_d = dq_oe ? dq_out : 16'bz;
    assign dq_in   = sdram_d;

    // ── Boot preloader (BRAM payload -> SDRAM) + adapter mux ──────────────────
    logic [31:0] ld_addr, ld_wdata;
    logic        ld_req, ld_we, ld_active;
    logic [3:0]  ld_be;

    sdram_preloader #(
      .INIT_FILE ("payload.hex"),
      .N_WORDS   (512)
    ) u_preload (
      .clk(cpu_clk), .resetn(sdram_resetn),
      .ld_addr(ld_addr), .ld_req(ld_req), .ld_we(ld_we),
      .ld_wdata(ld_wdata), .ld_be(ld_be), .ld_rdata(mem_rdata), .ld_ready(mem_ready),
      .active(ld_active), .done(preload_done), .verify_ok(verify_ok)
    );

    logic [31:0] a_addr, a_wdata;
    logic        a_req, a_we, a_burst;
    logic [3:0]  a_be;
    assign a_addr  = ld_active ? ld_addr   : mem_addr;
    assign a_req   = ld_active ? ld_req    : mem_req;
    assign a_we    = ld_active ? ld_we     : mem_we;
    assign a_burst = ld_active ? 1'b0      : mem_burst;
    assign a_wdata = ld_active ? ld_wdata  : mem_wdata;
    assign a_be    = ld_active ? ld_be     : mem_be;

    sdram_adapter u_adapter (
      .clk(cpu_clk), .resetn(sdram_resetn),
      .cpu_addr(a_addr), .cpu_req(a_req), .cpu_we(a_we), .cpu_burst(a_burst),
      .cpu_wdata(a_wdata), .cpu_be(a_be),
      .cpu_rdata(mem_rdata), .cpu_rvalid(mem_rvalid), .cpu_ready(mem_ready),
      .u_addr(u_addr), .u_we(u_we), .u_dbl(u_dbl), .u_req(u_req), .u_ready(u_ready),
      .u_rdata(u_rdata), .u_rvalid(u_rvalid),
      .u_wbeat(u_wbeat), .u_wstrobe(u_wstrobe), .u_wdata(u_wdata), .u_wdqm(u_wdqm)
    );

    sdram_ctrl #(
      .BURST_LEN   (8),
      .INIT_CYCLES (12000),
      .CAS_LATENCY (2),
      .REFRESH_CYC (420)
    ) u_sdram (
      .clk(cpu_clk), .resetn(sdram_resetn),
      .u_addr(u_addr), .u_we(u_we), .u_dbl(u_dbl), .u_req(u_req), .u_ready(u_ready),
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

    // ── UART  @  0x8000_2000 (data) / 0x8000_2004 (status) ───────────────────
    logic        uart_dataSel, uart_statusSel;
    logic        uart_txWrite, uart_rxRead;
    logic [7:0]  uart_txByte, uart_rxData;
    logic [31:0] uart_statusWord;

    assign uart_dataSel   = (periph_addr == `SOC_UART_DATA_ADDR);
    assign uart_statusSel = (periph_addr == `SOC_UART_STATUS_ADDR);
    assign uart_txWrite   = periph_we && uart_dataSel;
    assign uart_rxRead    = periph_re && uart_dataSel;

    always_comb begin
      uart_txByte = periph_wdata[7:0];
      if      (periph_be[0]) uart_txByte = periph_wdata[7:0];
      else if (periph_be[1]) uart_txByte = periph_wdata[15:8];
      else if (periph_be[2]) uart_txByte = periph_wdata[23:16];
      else if (periph_be[3]) uart_txByte = periph_wdata[31:24];
    end

    uart #(
      .CLKS_PER_BIT (`SOC_UART_CLKS_PER_BIT),
      .FIFO_DEPTH   (16)
    ) u_uart (
      .clk        (cpu_clk),
      .resetn     (cpu_resetn),
      .tx_write   (uart_txWrite),
      .tx_data    (uart_txByte),
      .rx_read    (uart_rxRead),
      .rx_data    (uart_rxData),
      .status     (uart_statusWord),
      .uart_tx    (uart_tx),
      .uart_rx    (uart_rx)
    );

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

    // ── Peripheral read data mux ─────────────────────────────────────────────
    always_comb begin
      if      (clint_sel)       periph_rdata = clint_rdata;
      else if (uart_dataSel)    periph_rdata = {24'd0, uart_rxData};
      else if (uart_statusSel)  periph_rdata = uart_statusWord;
      else                      periph_rdata = 32'h00000000;
    end

  // ===========================================================================
  // PERIPHERAL ADDRESS DECODE
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
