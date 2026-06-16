`include "isa.vh"
// =============================================================================
// PHANTOM-32  ──  Decoupled Fetch Unit  (fetch FIFO + RVC aligner)
// =============================================================================
// fetch advances by constant +4 (word-aligned), I-Cache output lands in the
// FIFO, and instruction-length alignment happens in dedicated aligner path.
//
//   req_pc (+4 / redirect) -> I-Cache (1-cycle word read) -> FIFO[{word, pc}] -> aligner
//
// Credit-based Fetch Issue: a new word is requested only when a FIFO slot is
// reserved for its result (count + outstanding < DEPTH)
module fetch_unit #(
  parameter int DEPTH = 4
) (
  input  logic        clk,
  input  logic        resetn,

  // ── Redirect (from backend branch-resolve / trap / mret) ───────────────────
  input  logic        redirect_en,
  input  logic [31:0] redirect_pc,

  // ── Backend handshake ──────────────────────────────────────────────────────
  input  logic        consume,      // 1 = ID accepted the head instruction

  // ── I-Cache port ───────────────────────────────────────────────────────────
  output logic [31:0] imem_addr_a,  // req_pc
  output logic [31:0] imem_addr_b,  // req_pc + 2
  input  logic [15:0] imem_data_a,
  input  logic [15:0] imem_data_b,
  input  logic        imem_ready,   // 1 = word valid (I-Cache hit)

  // ── Aligned instruction stream out (to ID) ─────────────────────────────────
  output logic [31:0] instr,
  output logic [31:0] pc,
  output logic        is_comp,
  output logic        valid
);

  localparam int IW = (DEPTH <= 1) ? 1 : $clog2(DEPTH);

  // ===========================================================================
  // FETCH SIDE: one request in flight; credit-gated issue; hold on miss
  // ===========================================================================
  logic [31:0] fetch_pc;            // next word address to fetch
  logic [31:0] flight_pc;           // address of the in-flight request
  logic        inFlight;            // a request is currently in flight
  logic        stalling;            // re-sending flight_pc while I-Cache fills

  logic [31:0]   fifo_word [0:DEPTH-1];
  logic [IW-1:0] head, tail;
  logic [IW:0]   count;

  logic [31:0] respWord;   assign respWord   = {imem_data_b, imem_data_a};
  logic        resultHit;  assign resultHit  = inFlight  &&  imem_ready && !redirect_en;
  logic        resultMiss; assign resultMiss = inFlight  && !imem_ready && !redirect_en;
  logic        pushResp;   assign pushResp   = resultHit && (count < (IW+1)'(DEPTH)); 
  logic        pop;

  logic [IW:0] occupancyNext; // issue only if current cycle push/pop leaves free slot
  assign occupancyNext = count + (pushResp ? (IW+1)'(1) : '0) - (pop ? (IW+1)'(1) : '0);
  logic can_issue; assign can_issue = !redirect_en && !stalling && !resultMiss
    && (occupancyNext < (IW+1)'(DEPTH))
    && (resultHit || !inFlight);

  assign imem_addr_a = stalling ? flight_pc : fetch_pc;
  assign imem_addr_b = imem_addr_a + 32'd2;


  // ===========================================================================
  // ALIGNER: extract a 16/32-bit instruction at a_pc from the head word(s)
  // ===========================================================================
  logic [31:0]   align_pc; // New Architectural Program Counter
  logic [IW-1:0] nextHead; assign nextHead = head + IW'(1);

  logic h0_ok; assign h0_ok = (count >= (IW+1)'(1));
  logic h1_ok; assign h1_ok = (count >= (IW+1)'(2));

  logic head_isComp; assign head_isComp = (lowerHalfWord[1:0] != 2'b11);
  logic straddle;    assign straddle    = !head_isComp && align_pc[1];

  logic [15:0] lowerHalfWord; assign lowerHalfWord =
    align_pc[1] ? fifo_word[head][31:16]    : fifo_word[head][15:0];
  logic [15:0] upperHalfWord; assign upperHalfWord =
    straddle    ? fifo_word[nextHead][15:0] : fifo_word[head][31:16];

  assign instr   = head_isComp ? {16'd0, lowerHalfWord} : {upperHalfWord, lowerHalfWord};
  assign pc      = align_pc;
  assign is_comp = head_isComp;
  assign valid   = h0_ok && (head_isComp || !straddle || h1_ok);

  logic [31:0] nextpc; assign nextpc = align_pc + (head_isComp ? 32'd2 : 32'd4);
  assign pop = consume && valid && (nextpc[31:2] != align_pc[31:2]);


  // ===========================================================================
  // SEQUENTIAL
  // ===========================================================================
  always_ff @(posedge clk) begin
    if (!resetn) begin
      fetch_pc <= `RESET_VECTOR; flight_pc <= 32'd0; inFlight <= 1'b0;
      head <= '0; tail <= '0; count <= '0; align_pc <= `RESET_VECTOR;
      stalling <= 1'b0;
    end else if (redirect_en) begin
      fetch_pc <= {redirect_pc[31:2], 2'b00}; inFlight <= 1'b0;
      head <= '0; tail <= '0; count <= '0; align_pc <= redirect_pc;
      stalling <= 1'b0; flight_pc <= 32'd0;
    end else begin
      if (pushResp) begin
        fifo_word[tail] <= respWord;
        tail            <= tail + IW'(1);
      end

      if (pop) head <= head + IW'(1);
      count <= occupancyNext;

      // ── Fetch engine ───────────────────────────────────────────────────────
      if (resultMiss) begin
        stalling  <= 1'b1;
        inFlight  <= 1'b1;
      end else if (stalling) begin
        stalling  <= 1'b0;
        inFlight  <= 1'b0;
      end else if (can_issue) begin
        flight_pc <= fetch_pc;
        fetch_pc  <= fetch_pc + 32'd4;
        inFlight  <= 1'b1;
      end else begin
        inFlight  <= 1'b0;
      end

      if (consume && valid) align_pc <= nextpc;
    end
  end

endmodule

