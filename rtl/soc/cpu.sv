`include "soc_map.vh"
// =============================================================================
// PHANTOM-32  ──  CPU  (Core + I-Cache + direct SDRAM data + Peripheral Bus)
// =============================================================================
// Wraps phantom_core with the I-Cache (instructions served from SDRAM behind a
// direct-mapped BRAM cache)
//
//  Address decode (MSB of MA address):
//    addr[31] == 1 -> peripheral bus (UART, CLINT, LEDs)
//    addr[31] == 0 -> external SDRAM (uncached; phys addr = addr[24:0])
//
//  The data access uses registered-completion handshake (dmem_multi / dmem_ready)
// =============================================================================
module cpu (
  input  logic clk,
  input  logic resetn,

  // ── Interrupt request lines (from soc: CLINT / external) ───────────────────
  input  logic        irq_timer,
  input  logic        irq_soft,
  input  logic        irq_ext,

  // ── Peripheral bus ─────────────────────────────────────────────────────────
  output logic [31:0] periph_addr,  // MA address
  output logic [31:0] periph_wdata, // store data
  output logic        periph_we,    // write enable
  output logic        periph_re,    // read strobe
  output logic [3:0]  periph_be,    // byte enables
  input  logic [31:0] periph_rdata, // read data from soc peripheral decode

  // ── SDRAM memory bus ───────────────────────────────────────────────────────
  output logic [31:0] mem_addr,
  output logic        mem_req,      // 1 = SDRAM load/store in MA this cycle
  output logic        mem_we,       // 1 = store
  output logic        mem_burst,    // 1 = 4-word read burst
  output logic [31:0] mem_wdata,    // store data (byte-lane shifted)
  output logic [3:0]  mem_be,       // byte enables
  input  logic [31:0] mem_rdata,    // load/burst word (valid with mem_rvalid/mem_ready)
  input  logic        mem_rvalid,   // 1 = mem_rdata is a valid burst word
  input  logic        mem_ready     // 1 = SDRAM access complete this cycle
);

  // ===========================================================================
  // INTERNAL MEMORY BUS SIGNALS
  // ===========================================================================

    // ── Instruction Fetch (core <-> I-Cache) ─────────────────────────────────
    logic [31:0] imem_addr;     // fetch address (word-aligned)
    logic [31:0] imem_data;     // instruction word
    logic        imem_ready;    // driven by the I-Cache

    // ── I-Cache SDRAM fill master ────────────────────────────────────────────
    logic [31:0] icache_fillAddr;
    logic        icache_fillReq;
    logic [31:0] icache_fillRData;
    logic        icache_fillRValid;

    // ── Core data port ───────────────────────────────────────────────────────
    /* verilator lint_off UNUSEDSIGNAL */
    logic [31:0] dmem_rdAddr;  // EX read address (ex_dmem_addr,   unused)
    logic [31:0] dmem_wrAddr;  // MA address (ex_ma_dmemAddr, decode + SDRAM/periph access)
    /* verilator lint_on  UNUSEDSIGNAL */
    logic [31:0] dmem_wdata;    // Write data
    logic [31:0] dmem_rdata;    // Read data
    logic [3:0]  dmem_be;       // Byte enables
    logic        dmem_we;       // Write enable
    logic        dmem_req;      // MA load/store strobe


    // ── Address decode ───────────────────────────────────────────────────────
    logic  addr_isPeriph;
    logic  addr_isSDRAM;
    assign addr_isPeriph = dmem_wrAddr[`SOC_PERIPH_SEL_BIT];
    assign addr_isSDRAM  = !addr_isPeriph;

    // ── Peripheral bus outputs ───────────────────────────────────────────────
    assign periph_addr  = dmem_wrAddr;
    assign periph_wdata = dmem_wdata;
    assign periph_we    = dmem_we && addr_isPeriph;
    assign periph_re    = dmem_req && !dmem_we && addr_isPeriph;
    assign periph_be    = dmem_be;
 
    // ── Load data mux: SDRAM or peripheral ───────────────────────────────────
    assign dmem_rdata = addr_isPeriph ? periph_rdata : mem_rdata;
    logic sdram_dReady;

  // ===========================================================================
  // INTERNAL MEMORY BUS SIGNALS
  // ===========================================================================


  // ===========================================================================
  // PHANTOM CORE
  // ===========================================================================
    phantom_core u_core (
      .clk        (clk),
      .resetn     (resetn),
      // ── IMEM ───────────────────────────────────────────────────────────────
      .imem_addr  (imem_addr),
      .imem_data  (imem_data),
      .imem_ready (imem_ready),
      // ── DMEM ───────────────────────────────────────────────────────────────
      .dmem_raddr (dmem_rdAddr),
      .dmem_waddr (dmem_wrAddr),
      .dmem_we    (dmem_we),
      .dmem_be    (dmem_be),
      .dmem_wdata (dmem_wdata),
      .dmem_rdata (dmem_rdata),
      .dmem_req   (dmem_req),
      .dmem_ready (addr_isPeriph ? 1'b1 : sdram_dReady),
      .dmem_multi (addr_isSDRAM),
      .irq_timer  (irq_timer),
      .irq_soft   (irq_soft),
      .irq_ext    (irq_ext)
    );
  // ===========================================================================
  // PHANTOM CORE
  // ===========================================================================


  // ===========================================================================
  // I-CACHE  ──  instructions served from SDRAM behind a 4-way BRAM cache
  // ===========================================================================
    icache #(
      .LINES      (512),
      .LINE_BYTES (32),
      .ADDR_W     (25)
    ) u_icache (
      .clk         (clk),
      .resetn      (resetn),
      .addr        (imem_addr),
      .data        (imem_data),
      .ready       (imem_ready),
      .fill_addr   (icache_fillAddr),
      .fill_req    (icache_fillReq),
      .fill_rdata  (icache_fillRData),
      .fill_rvalid (icache_fillRValid)
    );
  // ===========================================================================
  // I-CACHE
  // ===========================================================================
 

  // ===========================================================================
  // SDRAM ARBITER  ──  one SDRAM port, two masters: data load/store + I-Cache fill
  // ===========================================================================
    logic d_req; assign d_req = dmem_req && addr_isSDRAM;
    logic arb_locked;   // a transaction is committed to one master
    logic arb_fill;     // 1 = the committed master is the I-Cache fill

    always_ff @(posedge clk) begin
      if (!resetn) begin
        arb_locked   <= 1'b0;
        arb_fill     <= 1'b0;
      end else if (!arb_locked) begin
        if (d_req || icache_fillReq) begin
          arb_locked <= 1'b1;
          arb_fill   <= icache_fillReq && !d_req;
        end
      end else if (mem_ready) begin
        arb_locked   <= 1'b0;
      end
    end

    assign mem_req   = arb_locked && (arb_fill ? icache_fillReq : d_req);
    assign mem_addr  = arb_fill ? icache_fillAddr : dmem_wrAddr;
    assign mem_we    = arb_fill ? 1'b0      : dmem_we;
    assign mem_burst = arb_fill;
    assign mem_wdata = dmem_wdata;                      // I-Cache fill is read-only
    assign mem_be    = arb_fill ? 4'hF      : dmem_be;

    assign sdram_dReady      = arb_locked && !arb_fill && mem_ready;
    assign icache_fillRValid = arb_locked &&  arb_fill && mem_rvalid;
    assign icache_fillRData  = mem_rdata;

  // ===========================================================================
  // SDRAM ARBITER
  // ===========================================================================


endmodule

