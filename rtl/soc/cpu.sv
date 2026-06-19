`include "soc_map.vh"
// =============================================================================
// PHANTOM-32  ──  CPU  (Core + I-Cache + DMEM BSRAM + Peripheral Bus)
// =============================================================================
// Wraps phantom_core with the I-Cache (instructions served from SDRAM behind a
// direct-mapped BRAM cache), a behavioral DMEM BSRAM model that Yosys infers
// into ECP5 EBR, and a peripheral bus for soc.sv to attach peripherals.
//
//   IMEM: The core fetches a 32-bit instruction word per cycle from the
//         I-Cache (u_icache), which fills missed lines from SDRAM. One fetch
//         address, one word back (1-cycle hit latency).
//
//   DMEM: one 32-bit × 1024 array with byte-enable write granularity.
//         Infers as PDPW16KD (pseudo dual-port: one write, one read port).
//         Not initialized - DMEM starts undefined (program must initialize).
//
// Read timing (both IMEM and DMEM):
//   Address presented in stage N → registered at clock edge → data valid in
//   stage N+1. 1-cycle latency
//
// Address decode (MSB):
//   dmem_wr_addr[31] == 0  →  BSRAM (DMEM 0x0000–0x0FFF)
//   dmem_wr_addr[31] == 1  →  peripheral bus (UART @ 0x80002000, CLINT, ...)
//
// The gate on DMEM write enable is necessary for correctness: without it, a
// store to 0x80002000 would alias onto DMEM word 0 (both share addr[11:2]=0).
//
// Future phases (III+):
//   - SDRAM AXI/AHB bus port (replaces BSRAM once D-cache is added)
//   - Interrupt inputs (mtime_irq, msip from CLINT)
//   - I-Cache and D-Cache wrappers around the inferred BSRAM arrays
//   - MMU / TLB
// =============================================================================


module cpu (
  input  logic clk,
  input  logic resetn,

  // ── Interrupt request lines (from soc: CLINT / external) ───────────────────
  input  logic        irq_timer,
  input  logic        irq_soft,
  input  logic        irq_ext,

  // ── Peripheral bus ─────────────────────────────────────────────────────────
  // Signals are valid in MA stage. periph_rdata must be stable by end of MA.
  // soc.sv drives periph_rdata combinationally from periph_addr.
  output logic [31:0] periph_addr,  // registered store address (ex_ma_dmemAddr)
  output logic [31:0] periph_wdata, // store data
  output logic        periph_we,    // write enable
  output logic [3:0]  periph_be,    // byte enables
  input  logic [31:0] periph_rdata, // read data from soc peripheral decode

  // ── SDRAM memory bus ───────────────────────────────────────────────────────
  output logic [31:0] mem_addr,     // MA byte address (ex_ma_dmemAddr)
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
    logic [31:0] fill_addr;
    logic        fill_req;
    logic [31:0] fill_rdata;
    logic        fill_rvalid;

    // ── DMEM ─────────────────────────────────────────────────────────────────
    // dmem_rd_addr bits [31:12] and [1:0] are not forwarded to the BSRAM address
    // ([11:2] only). Upper bits exceed the 4 KB DMEM window; bits [1:0] are
    // byte-offset bits that the word-addressed BSRAM ignores.
    /* verilator lint_off UNUSEDSIGNAL */
    logic [31:0] dmem_rd_addr;  // Read  address (ex_dmem_addr,      combinational EX)
    logic [31:0] dmem_wr_addr;  // Write address (ex_ma_dmemAddr,    registered EX/MA)
    /* verilator lint_on  UNUSEDSIGNAL */
    logic [31:0] dmem_wdata;    // Write data    (store_data,        combinational MA)
    logic [31:0] dmem_rdata;    // Read data     (valid in MA,       1 cycle after rd_addr)
    logic [31:0] bsram_rdata;   // Raw SDPB read data (4 byte lanes combined)
    logic [31:0] bsram_bypassed;// bsram_rdata after the store->load bypass merge
    logic [3:0]  dmem_be;       // Byte enables  (store_be,          combinational MA)
    logic        dmem_we;       // Write enable  (gated by !trap_en, combinational MA)
    logic        dmem_req;      // MA load/store strobe


    // ── Address decode ───────────────────────────────────────────────────────
    // bit [31] == 1 → peripheral space. Gates BSRAM write and selects read data.
    logic  addr_is_periph;
    logic  addr_is_sdram;
    assign addr_is_periph = dmem_wr_addr[`SOC_PERIPH_SEL_BIT];
    assign addr_is_sdram  = dmem_wr_addr[`SOC_SDRAM_SEL_BIT] && !addr_is_periph;

    // ── Peripheral bus outputs ───────────────────────────────────────────────
    assign periph_addr  = dmem_wr_addr;
    assign periph_wdata = dmem_wdata;
    assign periph_we    = dmem_we && addr_is_periph;
    assign periph_be    = dmem_be;
 
    // ── SDRAM bus outputs (to soc.sv's adapter) ──────────────────────────────
    logic  sdram_d_ready;

    // ── Read data mux: SDRAM, peripheral, or BSRAM ───────────────────────────
    assign dmem_rdata = addr_is_periph ? periph_rdata
                      : addr_is_sdram  ? mem_rdata
                      :                  bsram_bypassed;

  // ===========================================================================
  // INTERNAL MEMORY BUS SIGNALS
  // ===========================================================================


  // ===========================================================================
  // PHANTOM CORE
  // ===========================================================================
    phantom_core u_core (
      .clk          (clk),
      .resetn       (resetn),
      // ── IMEM ───────────────────────────────────────────────────────────────
      .imem_addr    (imem_addr),
      .imem_data    (imem_data),
      .imem_ready   (imem_ready),
      // ── DMEM ───────────────────────────────────────────────────────────────
      .dmem_raddr   (dmem_rd_addr),
      .dmem_waddr   (dmem_wr_addr),
      .dmem_we      (dmem_we),
      .dmem_be      (dmem_be),
      .dmem_wdata   (dmem_wdata),
      .dmem_rdata   (dmem_rdata),
      .dmem_req     (dmem_req),
      .dmem_ready   (addr_is_sdram ? sdram_d_ready : 1'b1),
      .irq_timer    (irq_timer),
      .irq_soft     (irq_soft),
      .irq_ext      (irq_ext)
    );
  // ===========================================================================
  // PHANTOM CORE
  // ===========================================================================


  // ===========================================================================
  // I-CACHE  ──  instructions served from SDRAM behind a direct-mapped BRAM cache
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
      .fill_addr   (fill_addr),
      .fill_req    (fill_req),
      .fill_rdata  (fill_rdata),
      .fill_rvalid (fill_rvalid)
    );
  // ===========================================================================
  // I-CACHE
  // ===========================================================================
 

  // ===========================================================================
  // SDRAM ARBITER  ──  shares mem_* between the data path and the I-cache fill
  // ===========================================================================
  // One SDRAM (one adapter port in soc.sv), two masters:
  //   - data: an SDRAM-region load/store from the core (the core waits via mem_stall)
  //   - fill: the I-cache pulling a line (read-only stream of word reads)
  // ===========================================================================
    logic d_req; assign d_req = dmem_req && addr_is_sdram;
    logic arb_locked;   // a transaction is committed to one master
    logic arb_fill;     // 1 = the committed master is the I-Cache fill

    always_ff @(posedge clk) begin
      if (!resetn) begin
        arb_locked   <= 1'b0;
        arb_fill     <= 1'b0;
      end else if (!arb_locked) begin
        if (d_req || fill_req) begin
          arb_locked <= 1'b1;
          arb_fill   <= fill_req && !d_req;
        end
      end else if (mem_ready) begin
        arb_locked   <= 1'b0;
      end
    end

    assign mem_req   = arb_locked && (arb_fill ? fill_req : d_req);
    assign mem_addr  = arb_fill ? fill_addr : dmem_wr_addr;
    assign mem_we    = arb_fill ? 1'b0      : dmem_we;
    assign mem_burst = arb_fill;
    assign mem_wdata = dmem_wdata;                      // I-Cache fill is read-only
    assign mem_be    = arb_fill ? 4'hF      : dmem_be;

    assign sdram_d_ready = arb_locked && !arb_fill && mem_ready;
    assign fill_rvalid   = arb_locked &&  arb_fill && mem_rvalid;
    assign fill_rdata    = mem_rdata;

  // ===========================================================================
  // SDRAM ARBITER
  // ===========================================================================


  // ===========================================================================
  // DMEM  ──  ECP5 EBR, pseudo-dual-port, 32-bit × 1024 (4 KB)
  // ===========================================================================
  // Separate write and read ports with different addresses infer cleanly as
  // PDPW16KD (Pseudo Dual-Port Wide 16K) in Yosys synth_ecp5.
  //
  // Write port (Port A): address = dmem_wr_addr (ex_ma_dmemAddr, EX/MA register)
  //   Stable throughout MA stage. Write committed at MA→WB clock edge.
  //   Byte-enable granularity via four conditional writes to 8-bit slices.
  //
  // Read port (Port B): address = dmem_rd_addr (ex_dmem_addr, EX combinational)
  //   Registered at EX→MA clock edge. bsram_rdata valid from start of MA.
  // ===========================================================================
    (* ram_style = "block" *) logic [31:0] dmem_mem [0:1023];

    always_ff @(posedge clk) begin
      if (dmem_we && !addr_is_periph && !addr_is_sdram) begin
        if (dmem_be[0]) dmem_mem[dmem_wr_addr[11:2]][7:0]   <= dmem_wdata[7:0];
        if (dmem_be[1]) dmem_mem[dmem_wr_addr[11:2]][15:8]  <= dmem_wdata[15:8];
        if (dmem_be[2]) dmem_mem[dmem_wr_addr[11:2]][23:16] <= dmem_wdata[23:16];
        if (dmem_be[3]) dmem_mem[dmem_wr_addr[11:2]][31:24] <= dmem_wdata[31:24];
      end
    end

    always_ff @(posedge clk) begin
      bsram_rdata <= dmem_mem[dmem_rd_addr[11:2]];
    end
 
    // ── Store->load bypass ───────────────────────────────────────────────────
    logic        wbp_en;       // a BRAM store committed last cycle
    logic [9:0]  wbp_word;     // its word index
    logic [9:0]  rd_word_q;    // the load's read word index (aligned to bsram_rdata)
    logic [31:0] wbp_data;
    logic [3:0]  wbp_be;
    always_ff @(posedge clk) begin
      wbp_en    <= dmem_we && !addr_is_periph && !addr_is_sdram;
      wbp_word  <= dmem_wr_addr[11:2];
      wbp_data  <= dmem_wdata;
      wbp_be    <= dmem_be;
      rd_word_q <= dmem_rd_addr[11:2];
    end

    always_comb begin
      bsram_bypassed = bsram_rdata;
      if (wbp_en && (wbp_word == rd_word_q)) begin
        if (wbp_be[0]) bsram_bypassed[7:0]   = wbp_data[7:0];
        if (wbp_be[1]) bsram_bypassed[15:8]  = wbp_data[15:8];
        if (wbp_be[2]) bsram_bypassed[23:16] = wbp_data[23:16];
        if (wbp_be[3]) bsram_bypassed[31:24] = wbp_data[31:24];
      end
    end
  // ===========================================================================
  // DMEM
  // ===========================================================================


endmodule


