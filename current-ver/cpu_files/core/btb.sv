`include "isa.vh"
// =============================================================================
// PHANTOM-32  ──  Branch Target Buffer (BTB)
// =============================================================================
// 512 × {valid, target} entries.  target lives in EBR (DP16KD on ECP5); valid
// is a resettable FF array so a cold/uninitialised entry can never be followed.
//
// ── Read path ────────────────────────────────────────────────────────────────
//   MAR ← next_pc[IDX_W:1] at every clock edge.  This is a speculative
//   look-ahead: next_pc is IF's output, so the MAR is loaded with the address
//   of the instruction that will become r_pc next cycle.  btb_rdata/btb_valid
//   are then combinational from the MAR and deliver the predicted target and
//   its valid bit for r_pc in the IF stage (1-cycle read latency, matching the
//   IMEM timing model).
//
//   Using next_pc (not r_pc) mirrors the IMEM MAR: both are driven by the
//   NextPC MUX output and latch at the same clock edge, keeping IMEM fetch
//   and BTB lookup in lockstep.
//
// ── Write path ───────────────────────────────────────────────────────────────
//   Written on any taken branch or unconditional jump resolved in MA stage.
//   The index is the branch's pipeline-predecessor PC (ma_wb_pc), which is the
//   same address the BTB read used when that PC was next_pc one cycle earlier -
//   consistent with the look-ahead read.  A cold entry (valid=0) is ignored on
//   first encounter; the MA correction then writes the real target and sets
//   valid, so subsequent loops cost zero cycles.
//
// target BRAM: no reset (gated by valid).  valid: reset to 0.
// =============================================================================
module btb #(
  parameter integer BTB_DEPTH = 512,  // = 2^BTB_IDX_W
  parameter integer BTB_IDX_W = 9
) (
  input  logic                  clk,
  input  logic                  resetn,
 
  // ── Read port (PreIF → IF, 1-cycle BSRAM latency) ──────────────────────────
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:0]           next_pc,       // IF's NextPC MUX output (MAR source)
  /* verilator lint_on  UNUSEDSIGNAL */
  output logic [31:0]           btb_rdata,     // predicted target (combinational from MAR)
  output logic                  btb_valid,     // entry valid      (combinational from MAR)

  // ── Write port (MA stage) ──────────────────────────────────────────────────
  input  logic                  update_en,     // 1 = taken branch/jump resolved in MA
  input  logic [BTB_IDX_W-1:0]  update_idx,    // branch-predecessor PC[IDX_W:1]
  input  logic [31:0]           update_target  // actual target address
);

  (* ram_style = "block" *) 
  logic [31:0] mem [0:BTB_DEPTH-1];
  logic  valid_mem [0:BTB_DEPTH-1];

  // ── Read ───────────────────────────────────────────────────────────────────
  logic [BTB_IDX_W-1:0] btb_mar;
  always_ff @(posedge clk) begin
    btb_mar <= next_pc[BTB_IDX_W:1];
  end
  assign btb_rdata = mem[btb_mar];
  assign btb_valid = valid_mem[btb_mar];

  // ── Write (udpate target BRAM) ─────────────────────────────────────────────
  always_ff @(posedge clk) begin
    if (update_en) mem[update_idx] <= update_target;
  end

  // ── Write (valid bit) ──────────────────────────────────────────────────────
  integer i;
  always_ff @(posedge clk) begin
    if (!resetn) begin
      for (i = 0; i < BTB_DEPTH; i = i + 1) valid_mem[i] <= 1'b0;
    end else if (update_en) begin
      valid_mem[update_idx] <= 1'b1;
    end
  end

endmodule

