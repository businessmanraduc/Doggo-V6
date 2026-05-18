`include "isa.vh"
// =============================================================================
// PHANTOM-32  ──  CPU  (Core + L1 Cache + Memory Bus)
// =============================================================================
// Wraps phantom_core with the L1 instruction and data memories/caches and
// exposes a clean external memory bus for the SoC (soc.sv) to connect to
// SDRAM and peripherals.
//
// Phase III bring-up: IMEM and DMEM are Gowin BSRAM primitives.
//   IMEM: DPB  - true dual-port, both ports read, 16-bit × 4096
//   DMEM: SDPB - semi-dual-port, 4 × 8-bit banks for byte-enable writes
//               Port B (read)  ← dmem_rd_addr = ex_dmem_addr (EX combinational)
//               Port A (write) ← dmem_wr_addr = ex_ma_dmemAddr (EX/MA register)
//
// Future phases (III+):
//   - SDRAM AXI/AHB bus port (replaces direct BSRAM once cache is added)
//   - Interrupt inputs (mtime_irq, msip from CLINT)
//   - D-Cache and I-Cache wrappers around the BSRAM primitives
//   - MMU / TLB
// =============================================================================

module cpu (
  input  logic clk,
  input  logic resetn

  // ── Phase III+: external bus and interrupt ports go here ──────────────────
  // e.g. AXI4 master for SDRAM, mtime_irq from CLINT, etc.
);

  // ===========================================================================
  // INTERNAL MEMORY BUS SIGNALS
  // ===========================================================================

  // ── IMEM ─────────────────────────────────────────────────────────────────
  logic [31:0] imem_addr_a;   // Port A address (next_pc,  combinational from IF)
  logic [31:0] imem_addr_b;   // Port B address (next_pc2, combinational from IF)
  logic [15:0] imem_data_a;   // Port A read data (valid 1 cycle after address)
  logic [15:0] imem_data_b;   // Port B read data

  // ── DMEM ─────────────────────────────────────────────────────────────────
  logic [31:0] dmem_rd_addr;  // Read  address (ex_dmem_addr,   combinational EX)
  logic [31:0] dmem_wr_addr;  // Write address (ex_ma_dmemAddr, registered EX/MA)
  logic [31:0] dmem_wdata;    // Write data    (store_data,     combinational MA)
  logic [31:0] dmem_rdata;    // Read data     (valid in MA, 1 cycle after rd_addr)
  logic [3:0]  dmem_be;       // Byte enables  (store_be,       combinational MA)
  logic        dmem_we;       // Write enable  (gated by !trap_en, combinational MA)

  logic [31:0] dmem_addr_rd;  // routed from phantom_core.dmem_addr → SDPB Port B
  logic [31:0] dmem_addr_wr;  // routed from phantom_core.dmem_wr_addr → SDPB Port A
  assign dmem_rd_addr = dmem_addr_rd;
  assign dmem_wr_addr = dmem_addr_wr;

  // ===========================================================================
  // PHANTOM CORE
  // ===========================================================================
  phantom_core u_core (
    .clk          (clk),
    .resetn       (resetn),
    // ── IMEM ────────────────────────────────────────────────────────────────
    .imem_addr_a  (imem_addr_a),
    .imem_addr_b  (imem_addr_b),
    .imem_data_a  (imem_data_a),
    .imem_data_b  (imem_data_b),
    // ── DMEM ────────────────────────────────────────────────────────────────
    .dmem_raddr   (dmem_addr_rd),
    .dmem_waddr   (dmem_addr_wr),
    .dmem_we      (dmem_we),
    .dmem_be      (dmem_be),
    .dmem_wdata   (dmem_wdata),
    .dmem_rdata   (dmem_rdata)
  );

  // ===========================================================================
  // IMEM  ──  Gowin DPB, true dual-port read, 16-bit × 4096
  // ===========================================================================
  // Both ports are read-only (WREA=0, WREB=0).
  // READ_MODE=0 (bypass) → 1-cycle latency: address presented in IF,
  // MAR latches at PreIF/IF clock edge, data valid combinationally in IF+1.
  // Initialised from program.hex at synthesis time via INIT_FILE parameter.
  // ===========================================================================

  // [Phase III] Prepared for when targeting Gowin FPGA
  //
  // DPB #(
  //   .READ_MODE0  (1'b0),
  //   .READ_MODE1  (1'b0),
  //   .WRITE_MODE0 (2'b00),
  //   .WRITE_MODE1 (2'b00),
  //   .BIT_WIDTH_0 (16),
  //   .BIT_WIDTH_1 (16),
  //   .DEPTH_0     (4096),
  //   .DEPTH_1     (4096),
  //   .RESET_MODE  ("SYNC"),
  //   .INIT_FILE   ("program.mif")   // convert hex → mif for Gowin tools
  // ) u_imem (
  //   .CLKA  (clk), .CEA  (1'b1), .OCEA  (1'b1), .RESETA(1'b0), .WREA(1'b0),
  //   .ADA   (imem_addr_a[12:1]),
  //   .DIA   (16'd0),
  //   .DOA   (imem_data_a),
  //   .CLKB  (clk), .CEB  (1'b1), .OCEB  (1'b1), .RESETB(1'b0), .WREB(1'b0),
  //   .ADB   (imem_addr_b[12:1]),
  //   .DIB   (16'd0),
  //   .DOB   (imem_data_b)
  // );

  // ===========================================================================
  // DMEM  ──  4 × Gowin SDPB, semi-dual-port, 8-bit × 1024 per lane
  // ===========================================================================
  // Port B (read):  ADB = dmem_rd_addr (ex_dmem_addr, EX combinational)
  //   MAR latches at EX→MA clock edge. DOB valid combinationally in MA.
  //
  // Port A (write): ADA = dmem_wr_addr (ex_ma_dmemAddr, EX/MA register)
  //   Stable throughout MA. Write committed at MA→WB clock edge.
  //   WEA[i] = dmem_be[i] && dmem_we (per-byte-lane write enable from MA).
  //
  // Four 8-bit SDPB instances give full byte-enable granularity:
  //   lane 0 → dmem_rdata[7:0]   / dmem_wdata[7:0]   / dmem_be[0]
  //   lane 1 → dmem_rdata[15:8]  / dmem_wdata[15:8]  / dmem_be[1]
  //   lane 2 → dmem_rdata[23:16] / dmem_wdata[23:16] / dmem_be[2]
  //   lane 3 → dmem_rdata[31:24] / dmem_wdata[31:24] / dmem_be[3]
  //
  // READ_MODE=0 (bypass, no output register) → 1-cycle read latency.
  // ===========================================================================

  // [Phase III] Prepared for when targeting Gowin FPGA
  //
  // genvar i;
  // generate
  //   for (i = 0; i < 4; i++) begin : dmem_lane
  //     SDPB #(
  //       .READ_MODE   (1'b0),
  //       .BIT_WIDTH_0 (8),
  //       .BIT_WIDTH_1 (8),
  //       .DEPTH       (1024),
  //       .RESET_MODE  ("SYNC")
  //     ) u_dmem_byte (
  //       // ── Port A - write ────────────────────────────────────────────────
  //       .CLKA   (clk),
  //       .CEA    (1'b1),
  //       .RESETA (1'b0),
  //       .WREA   (dmem_be[i] && dmem_we),
  //       .ADA    (dmem_wr_addr[11:2]),
  //       .DIA    (dmem_wdata[i*8 +: 8]),
  //       // ── Port B - read ─────────────────────────────────────────────────
  //       .CLKB   (clk),
  //       .CEB    (1'b1),
  //       .OCEB   (1'b1),
  //       .RESETB (1'b0),
  //       .ADB    (dmem_rd_addr[11:2]),
  //       .DOB    (dmem_rdata[i*8 +: 8])
  //     );
  //   end
  // endgenerate

endmodule
