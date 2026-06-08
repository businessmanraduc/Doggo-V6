`include "soc_map.vh"
// =============================================================================
// PHANTOM-32  ──  CPU  (Core + IMEM/DMEM BSRAMs + Peripheral Bus)
// =============================================================================
// Wraps phantom_core with behavioral BSRAM models that Yosys infers into ECP5
// EBR blocks, and exposes a peripheral bus for soc.sv to attach peripherals.
//
//   IMEM: two independent 16-bit × 4096 arrays, one per read port.
//         Splitting avoids the Yosys same-clock dual-port DP16KD inference
//         limitation. Each array infers as 4 × DP16KD = 8 blocks total.
//         Initialized from imem.hex (16-bit halfword hex, see programs/).
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
  input  logic [31:0] periph_rdata  // read data from soc peripheral decode
);

  // ===========================================================================
  // INTERNAL MEMORY BUS SIGNALS
  // ===========================================================================

    // ── IMEM ─────────────────────────────────────────────────────────────────
    // Only bits [12:1] reach the DPB address port. Bit [0] is the halfword offset
    // (IMEM is halfword-addressed); bits [31:13] are above the 8 KB IMEM window.
    /* verilator lint_off UNUSEDSIGNAL */
    logic [31:0] imem_addr_a;   // Port A address (next_pc,  combinational from IF)
    logic [31:0] imem_addr_b;   // Port B address (next_pc2, combinational from IF)
    /* verilator lint_on  UNUSEDSIGNAL */
    logic [15:0] imem_data_a;   // Port A read data (valid 1 cycle after address)
    logic [15:0] imem_data_b;   // Port B read data

    // ── DMEM ───────────────────────────────────────────────────────────────────
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
    logic [3:0]  dmem_be;       // Byte enables  (store_be,          combinational MA)
    logic        dmem_we;       // Write enable  (gated by !trap_en, combinational MA)
    /* verilator lint_off UNUSEDSIGNAL */
    logic        dmem_req;      // MA load/store strobe
    /* verilator lint_on  UNUSEDSIGNAL */


    // ── Address decode ───────────────────────────────────────────────────────
    // bit [31] == 1 → peripheral space. Gates BSRAM write and selects read data.
    logic  addr_is_periph;
    assign addr_is_periph = dmem_wr_addr[`SOC_PERIPH_SEL_BIT];
 
    // ── Peripheral bus outputs ───────────────────────────────────────────────
    assign periph_addr  = dmem_wr_addr;
    assign periph_wdata = dmem_wdata;
    assign periph_we    = dmem_we && addr_is_periph;
    assign periph_be    = dmem_be;
 
    // ── Read data mux: BSRAM or peripheral ───────────────────────────────────
    assign dmem_rdata = addr_is_periph ? periph_rdata : bsram_rdata;

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
      .imem_addr_a  (imem_addr_a),
      .imem_addr_b  (imem_addr_b),
      .imem_data_a  (imem_data_a),
      .imem_data_b  (imem_data_b),
      // ── DMEM ───────────────────────────────────────────────────────────────
      .dmem_raddr   (dmem_rd_addr),
      .dmem_waddr   (dmem_wr_addr),
      .dmem_we      (dmem_we),
      .dmem_be      (dmem_be),
      .dmem_wdata   (dmem_wdata),
      .dmem_rdata   (dmem_rdata),
      .dmem_req     (dmem_req),
      .dmem_ready   (1'b1),           // BRAM path is single-cycle
      .irq_timer    (irq_timer),
      .irq_soft     (irq_soft),
      .irq_ext      (irq_ext)
    );
  // ===========================================================================
  // PHANTOM CORE
  // ===========================================================================
 

  // ===========================================================================
  // IMEM  ──  ECP5 EBR, dual read port, 16-bit × 4096 (8 KB total)
  // ===========================================================================
  // Two independent 16-bit × 4096 arrays so each read port infers its own
  // group of 4 × DP16KD blocks. This avoids the Yosys inference limitation
  // where same-clock dual-port reads from a single array may fall back to
  // flip-flop / LUT-RAM instead of EBR.
  //
  // READ timing: address presented in IF → registered at IF→ID clock edge →
  //   data valid from start of ID stage (1-cycle latency).
  //
  // INITIALIZATION: $readmemh reads imem.hex, a 16-bit halfword hex file where
  //   each line holds one 16-bit entry (little-endian halfword).
  //   Generate from a compiled ELF using programs/bin2imem_hex.py.
  // ===========================================================================
    (* ram_style = "block" *) logic [15:0] imem_a [0:4095];
    (* ram_style = "block" *) logic [15:0] imem_b [0:4095];

    initial begin
      $readmemh("imem.hex", imem_a);
      $readmemh("imem.hex", imem_b);
    end

    always_ff @(posedge clk) begin
      imem_data_a <= imem_a[imem_addr_a[12:1]];
      imem_data_b <= imem_b[imem_addr_b[12:1]];
    end
  // ===========================================================================
  // IMEM
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
  //
  // Known limitation: a store immediately followed by a load to the same
  // address reads the pre-write value (read-before-write). Insert at least
  // one instruction between a store and a dependent load to the same address.
  // ===========================================================================
    (* ram_style = "block" *) logic [31:0] dmem_mem [0:1023];

    always_ff @(posedge clk) begin
      if (dmem_we && !addr_is_periph) begin
        if (dmem_be[0]) dmem_mem[dmem_wr_addr[11:2]][7:0]   <= dmem_wdata[7:0];
        if (dmem_be[1]) dmem_mem[dmem_wr_addr[11:2]][15:8]  <= dmem_wdata[15:8];
        if (dmem_be[2]) dmem_mem[dmem_wr_addr[11:2]][23:16] <= dmem_wdata[23:16];
        if (dmem_be[3]) dmem_mem[dmem_wr_addr[11:2]][31:24] <= dmem_wdata[31:24];
      end
    end

    always_ff @(posedge clk) begin
      bsram_rdata <= dmem_mem[dmem_rd_addr[11:2]];
    end
  // ===========================================================================
  // DMEM
  // ===========================================================================


endmodule


