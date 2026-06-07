`include "isa.vh"
// =============================================================================
// PHANTOM-32  ──  Register File
// =============================================================================
// 32 × 32-bit general-purpose registers (x0–x31).
// Infers distributed LUT-RAM on Gowin GW2AR-18.
//
// Interface:
//   Two asynchronous read ports   (rs1, rs2 - used simultaneously in ID)
//   One synchronous  write port   (rd - driven by WB on rising edge)
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
  input  logic        clk,
  input  logic        resetn,

  // ── Read Port A  (rs1) ─────────────────────────────────────────────────────
  input  logic [4:0]  rd_index_a,     // register index to read
  output logic [31:0] rd_data_a,      // value (combinational)

  // ── Read Port B  (rs2) ─────────────────────────────────────────────────────
  input  logic [4:0]  rd_index_b,     // register index to read
  output logic [31:0] rd_data_b,      // value (combinational)

  // ── Write Port  (rd, from WB) ──────────────────────────────────────────────
  input  logic [4:0]  wr_index,       // destination register (from WB stage)
  input  logic [31:0] wr_data,        // value to write
  input  logic        wr_en,          // write enable (high for one cycle in WB)

  // ── Scoreboard Read Ports ──────────────────────────────────────────────────
  output logic        rs1_ready,      // 1 = rd_index_a is available/valid
  output logic        rs2_ready,      // 1 = rd_index_b is available/valid

  // ── Scoreboard Write Ports ─────────────────────────────────────────────────
  input  logic        id_wr_en,       // 1 = instruction in ID will write a reg
  input  logic [4:0]  id_wr_index,    // its destination register
  input  logic        ma_wr_en,       // 1 = instruction in MA will write a reg
  input  logic [4:0]  ma_wr_index,    // its destination register

  // ── Scoreboard Flush-Undo Port ─────────────────────────────────────────────
  input  logic        ex_undo_en,     // 1 = a squashed EX writer to be undone
  input  logic [4:0]  ex_undo_index   // its destination register
);

  // ===========================================================================
  // REGISTER STORAGE ARRAY
  // ===========================================================================
    logic [31:0] regFile [0:31];
    initial begin
      for (int i = 0; i < 32; i++) begin
        regFile[i] = 32'h0;
      end
    end
  // ===========================================================================
  // REGISTER STORAGE ARRAY
  // ===========================================================================
 

  // ===========================================================================
  // SYNCHRONOUS WRITE
  // ===========================================================================
  // Writes occur on rising edge.  Caller should gate wr_en for x0, but we
  // guard it here anyway to make the module self-contained.
  // ===========================================================================
    always_ff @(posedge clk) begin
      if (wr_en && (wr_index != 5'd0)) begin
        regFile[wr_index] <= wr_data;
      end
    end
  // ===========================================================================
  // SYNCHRONOUS WRITE
  // ===========================================================================
 

  // ===========================================================================
  // ASYNCHRONOUS READ
  // ===========================================================================
  // Priority:
  //   1. x0 → always 32'h0
  //   2. WB forwarding → return incoming wr_data if indices match
  //   3. Normal read → return stored value
  // ===========================================================================
    assign rd_data_a =
      (rd_index_a == 5'd0)                ? 32'h0   :
      (wr_en && (wr_index == rd_index_a)) ? wr_data :
      regFile[rd_index_a];

    assign rd_data_b =
      (rd_index_b == 5'd0)                ? 32'h0   :
      (wr_en && (wr_index == rd_index_b)) ? wr_data :
      regFile[rd_index_b];
  // ===========================================================================
  // ASYNCHRONOUS READ
  // ===========================================================================
 

  // ===========================================================================
  // OPERAND-READY SCOREBOARD  ──  pending-writer counter per register
  // ===========================================================================
    logic [1:0] cnt [0:31];
    initial begin
      for (int i = 0; i < 32; i++) begin
        cnt[i] = 2'd0;
      end
    end

    always_ff @(posedge clk) begin
      if (!resetn) begin
        for (int i = 0; i < 32; i++) begin
          cnt[i] <= 2'd0;
        end
      end else begin
        for (int i = 1; i < 32; i++) begin              // i = 0 is x0
          cnt[i] <= cnt[i]
            + 2'((id_wr_en   && (id_wr_index   == 5'(i))))
            - 2'((ma_wr_en   && (ma_wr_index   == 5'(i))))
            - 2'((ex_undo_en && (ex_undo_index == 5'(i))));
        end
      end
    end

    assign rs1_ready = (cnt[rd_index_a] == 2'd0);
    assign rs2_ready = (cnt[rd_index_b] == 2'd0);

  // ===========================================================================
  // OPERAND-READY SCOREBOARD
  // ===========================================================================

endmodule
