`include "isa.vh"
// =============================================================================
// PHANTOM-32  ──  Register File
// =============================================================================
// 32 × 32-bit general-purpose registers (x0–x31), implemented in distributed
// LUT-RAM on the Gowin GW2AR-18.
//
// Interface summary:
//   Two asynchronous read ports  (rs1 and rs2, used simultaneously in ID)
//   One synchronous  write port  (rd, driven by WB on the rising clock edge)
//
// x0 is hardwired to zero:
//   Reads  from x0 always return 32'h0, regardless of what is stored.
//   Writes to  x0 are silently discarded (write enable is gated internally).
//
// Write-before-read:
//   If WB is writing to the same index that ID is reading in the same cycle,
//   the NEW (incoming) write value is returned on the read port immediately —
//   no need to wait until the next clock edge.  This is implemented as a
//   forwarding mux on each read port and eliminates the WB→ID forwarding
//   distance from the EX forwarding unit entirely.
//
//   The mux is driven by the same wr_en / wr_index / wr_data signals that
//   control the synchronous write, so there is no extra logic path.
// =============================================================================
module regfile (
  input  wire        clk,

  // ── Read port A  (rs1) ────────────────────────────────────────────────────
  input  wire [4:0]  rd_index_a,    // register index to read (from ID stage)
  output wire [31:0] rd_data_a,     // value of register rs1  (combinational)

  // ── Read port B  (rs2) ────────────────────────────────────────────────────
  input  wire [4:0]  rd_index_b,    // register index to read (from ID stage)
  output wire [31:0] rd_data_b,     // value of register rs2  (combinational)

  // ── Write port   (rd, from WB) ────────────────────────────────────────────
  input  wire [4:0]  wr_index,      // destination register index
  input  wire [31:0] wr_data,       // value to write
  input  wire        wr_en          // write enable (high for one cycle in WB)
                                    // must already be gated to 0 for x0 by caller
);

  // =============================================================================
  // STORAGE ARRAY
  // =============================================================================
  // Verilog reg array — GowinEDA will infer distributed LUT-RAM for this
  // pattern (async read, sync write with explicit always @(posedge clk)).
  // =============================================================================
  reg [31:0] mem [0:31];

  integer i;
  initial begin
    for (i = 0; i < 32; i = i + 1)
      mem[i] = 32'h0;
  end


  // =============================================================================
  // SYNCHRONOUS WRITE
  // =============================================================================
  // Writes happen on the rising clock edge, exactly one cycle after the WB
  // stage asserts wr_en.  The caller (cpu.v WB stage) is responsible for
  // gating wr_en to 0 when wr_index == 5'd0, so we do not need a second
  // x0 guard here — but the condition costs nothing and makes this module
  // self-contained and safe regardless of how it is instantiated.
  // =============================================================================
  always @(posedge clk) begin
    if (wr_en && (wr_index != 5'd0))
      mem[wr_index] <= wr_data;
  end


  // =============================================================================
  // ASYNCHRONOUS READ  ──  Port A  (rs1)
  // =============================================================================
  // Priority (high to low):
  //   1. x0:          always return 32'h0
  //   2. WBR forward: if WB is writing the same index we are reading this
  //                   cycle, return the incoming wr_data immediately so the
  //                   ID stage sees the up-to-date value without stalling
  //   3. Normal:      return the stored value from the LUT-RAM array
  // =============================================================================
  assign rd_data_a = (rd_index_a == 5'd0)                 ? 32'h0   :
                     (wr_en && (wr_index == rd_index_a))  ? wr_data :
                     mem[rd_index_a];


  // =============================================================================
  // ASYNCHRONOUS READ  ──  Port B  (rs2)
  // =============================================================================
  // Identical priority logic to Port A, applied independently to rd_index_b.
  // Both ports can forward simultaneously if (unlikely) WB is writing a
  // register that happens to be both rs1 and rs2 of the same instruction.
  // =============================================================================
  assign rd_data_b = (rd_index_b == 5'd0)                 ? 32'h0   :
                     (wr_en && (wr_index == rd_index_b))  ? wr_data :
                     mem[rd_index_b];


endmodule
