`include "isa.vh"
// =============================================================================
// PHANTOM-32  ──  Branch Target Buffer (BTB)
// =============================================================================
// 512 × 32-bit target addresses in a single EBR block (DP16KD on ECP5).
//
// ── Read path ────────────────────────────────────────────────────────────────
//   MAR ← next_pc[IDX_W:1] at every clock edge.  This is a speculative
//   look-ahead: next_pc is IF's output, so the MAR is loaded with the address
//   of the instruction that will become r_pc next cycle.  btb_rdata is then
//   combinational from the MAR and delivers the predicted target for r_pc in
//   the IF stage (1-cycle read latency, matching the IMEM timing model).
//
//   Using next_pc (not r_pc) mirrors the IMEM MAR: both are driven by the
//   NextPC MUX output and latch at the same clock edge, keeping IMEM fetch
//   and BTB lookup in lockstep.
//
// ── Write path ───────────────────────────────────────────────────────────────
//   Written on any taken branch or unconditional jump resolved in MA stage.
//   The index is the branch instruction's own PC[IDX_W:1], which is the same
//   slot the BTB read used when that PC was next_pc one cycle earlier.
//   A cold BTB entry (all-zeros at power-up) causes a miss on first encounter;
//   the MA correction then writes the real target and the PHT trains taken,
//   so subsequent loops cost zero cycles.
//
// Pure synchronous.  No reset - BTB initialises to 0 at FPGA power-up.
// =============================================================================
module btb #(
  parameter integer BTB_DEPTH = 512,  // = 2^BTB_IDX_W
  parameter integer BTB_IDX_W = 9
) (
  input  logic                  clk,
 
  // ── Read port (PreIF → IF, 1-cycle BSRAM latency) ──────────────────────────
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:0]           next_pc,       // IF's NextPC MUX output (MAR source)
  /* verilator lint_on  UNUSEDSIGNAL */
  output logic [31:0]           btb_rdata,     // predicted target (combinational from MAR)
 
  // ── Write port (MA stage) ──────────────────────────────────────────────────
  input  logic                  update_en,     // 1 = taken branch/jump resolved in MA
  input  logic [BTB_IDX_W-1:0]  update_idx,    // branch PC[IDX_W:1]
  input  logic [31:0]           update_target  // actual target address
);

  (* ram_style = "block" *) logic [31:0] mem [0:BTB_DEPTH-1];

  // ── Read ───────────────────────────────────────────────────────────────────
  logic [BTB_IDX_W-1:0] btb_mar;
  always_ff @(posedge clk) begin
    btb_mar <= next_pc[BTB_IDX_W:1];
  end
  assign btb_rdata = mem[btb_mar];

  // ── Write ──────────────────────────────────────────────────────────────────
  always_ff @(posedge clk) begin
    if (update_en) mem[update_idx] <= update_target;
  end

endmodule

