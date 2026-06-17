`include "isa.vh"
// =============================================================================
// PHANTOM-32  ──  Bimodal Pattern History Table (PHT)
// =============================================================================
// Direction predictor for conditional branches in the decoupled front end.
// 2^IDX_W entries of 2-bit saturating counters (bimodal, PC-indexed; no global
// history). counter[1] is the taken/not-taken prediction.
//
// ── Read port (synchronous, 1-cycle latency) ─────────────────────────────────
//   The caller presents rd_idx (the aligner-PC index) with rd_en asserted as the
//   instruction is latched into IF/ID; the counter appears in rd_counter the next
//   cycle, lining up with the instruction in ID.
//
// ── Write port (MA stage) ────────────────────────────────────────────────────
//   Updated on every resolved conditional branch. wr_old carries the counter
//   value sampled at prediction time through the ID/EX -> EX/MA pipeline, so no
//   second read port is needed. Saturating: clamps at 00 (strong NT) / 11 (strong T).
module pht #(
  parameter logic [1:0]  INIT = 2'b10,
  parameter integer PHT_IDX_W = 9
) (
  input  logic                  clk,

  // ── Read port (presented at the aligner, consumed in ID) ───────────────────
  input  logic                  rd_en,      // 1 = latch new counter
  input  logic [PHT_IDX_W-1:0]  rd_idx,     // index = instruction PC slice
  output logic [1:0]            rd_counter, // registered 2-bit counter

  // ── Write/update port (MA stage) ───────────────────────────────────────────
  input  logic                  wr_en,      // 1 = conditional branch resolved in MA
  input  logic [PHT_IDX_W-1:0]  wr_idx,     // entry to update (branch PC slice)
  input  logic [1:0]            wr_old,     // counter value sampled at predict time
  input  logic                  wr_taken    // actual branch outcome
);

  (* ram_style = "block" *) logic [1:0] mem [0:(1 << PHT_IDX_W)-1];

  initial begin
    for (int i = 0; i < (1 << PHT_IDX_W); i++) mem[i] = INIT;
  end

  // ── Read ───────────────────────────────────────────────────────────────────
  always_ff @(posedge clk) begin
    if (rd_en) rd_counter <= mem[rd_idx];
  end

  // ── Write ──────────────────────────────────────────────────────────────────
  logic [1:0] new_val;
  assign new_val = (wr_taken
    ? ((wr_old == 2'b11) ? 2'b11 : wr_old + 2'b01)
    : ((wr_old == 2'b00) ? 2'b00 : wr_old - 2'b01)
  );

  always_ff @(posedge clk) begin
    if (wr_en) mem[wr_idx] <= new_val;
  end

endmodule


