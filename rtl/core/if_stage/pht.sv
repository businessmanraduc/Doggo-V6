`include "isa.vh"
// =============================================================================
// PHANTOM-32  ──  Gshare Pattern History Table (PHT)
// =============================================================================
//
// ── Read path ────────────────────────────────────────────────────────────────
//   Driven from PreIF stage.  The gshare index XOR(r_bhr, r_pc[IDX_W:1]) is
//   computed combinationally and latched into the BSRAM MAR at the clock edge.
//   pht_rdata is then combinational from the MAR → data valid in IF stage
//   (1-cycle read latency, matching the IMEM timing model).
//
//   pre_pc is the PrePC register (one of the IF/PreIF pipeline registers in
//   RVCoreP-32IC terminology).  It holds next_pc delayed by one clock cycle,
//   registered at the IF→PreIF boundary.  Using this registered value keeps
//   the XOR off the NextPC MUX critical path while still indexing the PHT
//   with the correct instruction address - one cycle is exactly what the
//   BSRAM read latency consumes anyway.
//
//   pht_mar is exposed so phantom_core can save it into the IF/ID pipeline
//   register as phtIdx, which is the address needed for the MA write-back.
//
// ── Write path ───────────────────────────────────────────────────────────────
//   Called from MA stage on every resolved conditional branch (not jumps).
//   update_old carries the counter value sampled at prediction time through
//   the IF/ID → ID/EX → EX/MA pipeline chain, avoiding a second read port.
//   Saturating: 00 clamps at 00 on not-taken, 11 clamps at 11 on taken.
//
// Pure synchronous.  Initialises to all-zeros (strongly not-taken) at power-up.
// =============================================================================
module pht #(
  parameter integer PHT_DEPTH = 8192,  // = 2^PHT_IDX_W
  parameter integer PHT_IDX_W = 13,
  parameter integer BHR_W     = 13
) (
  input  logic                  clk,
 
  // ── Read port (PreIF → IF, 1-cycle BSRAM latency) ──────────────────────────
  input  logic [BHR_W-1:0]      r_bhr,         // Branch History Register
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:0]           pre_pc,        // PrePC register (IF/PreIF, = next_pc delayed 1 cycle)
  /* verilator lint_on  UNUSEDSIGNAL */
  output logic [1:0]            pht_rdata,     // 2-bit counter (combinational from MAR)
  output logic [PHT_IDX_W-1:0]  pht_mar,       // MAR value - captured in IF/ID for write-back
 
  // ── Write port (MA stage) ──────────────────────────────────────────────────
  input  logic                  update_en,     // 1 = conditional branch resolved in MA
  input  logic [PHT_IDX_W-1:0]  update_idx,    // entry to update (from IF/PreIF pipeline carry)
  input  logic [1:0]            update_old,    // counter value at prediction time
  input  logic                  update_taken   // actual branch outcome
);

  (* ram_style = "block" *) logic [1:0] mem [0:PHT_DEPTH-1];

  // ── Read ───────────────────────────────────────────────────────────────────
  always_ff @(posedge clk) begin
    pht_mar <= r_bhr ^ pre_pc[PHT_IDX_W:1];
  end
  assign pht_rdata = mem[pht_mar];

  // ── Write ──────────────────────────────────────────────────────────────────
  logic [1:0] new_val;
  always_comb begin
    if (update_taken) begin
      new_val = (update_old == 2'b11) ? 2'b11 : update_old + 2'b01;
    end else begin
      new_val = (update_old == 2'b00) ? 2'b00 : update_old - 2'b01;
    end
  end

  always_ff @(posedge clk) begin
    if (update_en) mem[update_idx] <= new_val;
  end

endmodule


