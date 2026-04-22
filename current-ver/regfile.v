`include "isa.vh"
// =============================================================================
// PHANTOM-32  ──  Register File
// =============================================================================
// 32 × 32-bit general-purpose registers (x0–x31).
// Infers distributed LUT-RAM on Gowin GW2AR-18.
//
// Interface:
//   Two asynchronous read ports   (rs1, rs2 — used simultaneously in ID)
//   One synchronous  write port   (rd — driven by WB on rising edge)
//
// x0 hardwired to zero:
//   Reads  always return 32'h0.
//   Writes are silently discarded.
//
// Write-before-read forwarding:
//   If WB writes to the same index that ID reads in the same cycle, the
//   NEW value appears on the read port immediately -> no pipeline stall.
//   Implemented as a priority mux on each read port.
// =============================================================================
module regfile (
  input  wire        clk,

  // ── Read Port A  (rs1) ─────────────────────────────────────────────────────
  input  wire [4:0]  rd_index_a,    // register index to read
  output wire [31:0] rd_data_a,     // value (combinational)

  // ── Read Port B  (rs2) ─────────────────────────────────────────────────────
  input  wire [4:0]  rd_index_b,
  output wire [31:0] rd_data_b,

  // ── Write Port  (rd, from WB) ──────────────────────────────────────────────
  input  wire [4:0]  wr_index,      // destination register
  input  wire [31:0] wr_data,       // value to write
  input  wire        wr_en          // write enable (high for one cycle in WB)
);

  // ===========================================================================
  // STORAGE ARRAY
  // ===========================================================================
  reg [31:0] mem [0:31];

  integer i;
  initial begin
    for (i = 0; i < 32; i = i + 1)
      mem[i] = 32'h0;
  end


  // ===========================================================================
  // SYNCHRONOUS WRITE
  // ===========================================================================
  // Writes occur on rising edge.  Caller should gate wr_en for x0, but we
  // guard it here anyway to make the module self-contained.
  // ===========================================================================
  always @(posedge clk) begin
    if (wr_en && (wr_index != 5'd0))
      mem[wr_index] <= wr_data;
  end


  // ===========================================================================
  // ASYNCHRONOUS READ  ──  Port A  (rs1)
  // ===========================================================================
  // Priority:
  //   1. x0 → always 32'h0
  //   2. WB forwarding → return incoming wr_data if indices match
  //   3. Normal read → return stored value
  // ===========================================================================
  assign rd_data_a =
    (rd_index_a == 5'd0)                ? 32'h0   :
    (wr_en && (wr_index == rd_index_a)) ? wr_data :
    mem[rd_index_a];


  // ===========================================================================
  // ASYNCHRONOUS READ  ──  Port B  (rs2)
  // ===========================================================================
  assign rd_data_b =
    (rd_index_b == 5'd0)                ? 32'h0   :
    (wr_en && (wr_index == rd_index_b)) ? wr_data :
    mem[rd_index_b];

endmodule
