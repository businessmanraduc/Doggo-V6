`include "isa.vh"
// =============================================================================
// PHANTOM-32  ──  Forwarding Unit
// =============================================================================
// Resolves data hazards by selecting the most recently computed value for each
// ALU operand, bypassing stale register-file values that have not yet been
// written back.
//
//   Instruction in MA  (1 cycle ahead):  result in EX/MA pipeline register
//                                        → forward with sel = 2'b10
//   Instruction in WB  (2 cycles ahead): result in MA/WB pipeline register
//                                        → forward with sel = 2'b01
//
// ── Forwarding priority ──────────────────────────────────────────────────────
//   MA result  >  WB result  >  regfile output
//   (most recent wins - MA is fresher than WB)
//
// ── fwd_*_sel encoding ───────────────────────────────────────────────────────
//   2'b00 → use regfile output    (no hazard, or hazard covered by regfile)
//   2'b10 → use EX/MA result      (forward from MA stage - 1 cycle old)
//   2'b01 → use MA/WB result      (forward from WB stage - 2 cycles old)
// =============================================================================
module forward_unit (
  // ── Source indices of the instruction currently in EX ─────────────────────
  input  logic [4:0]  ex_rs1_index,   // rs1 index (from ID/EX pipeline register)
  input  logic [4:0]  ex_rs2_index,   // rs2 index (from ID/EX pipeline register)
 
  // ── Destination info for the instruction currently in MA ──────────────────
  input  logic [4:0]  ma_rd_index,    // rd index   (from EX/MA pipeline register)
  input  logic        ma_reg_write,   // 1 = this instruction writes a register
 
  // ── Destination info for the instruction currently in WB ──────────────────
  input  logic [4:0]  wb_rd_index,    // rd index   (from MA/WB pipeline register)
  input  logic        wb_reg_write,   // 1 = this instruction writes a register
 
  // ── Mux select outputs ────────────────────────────────────────────────────
  output logic [1:0]  fwd_A_sel,      // select for ALU operand A  (rs1 path)
  output logic [1:0]  fwd_B_sel       // select for ALU operand B  (rs2 path)
);

  // ===========================================================================
  // FORWARDING SELECT  ──  operand forwarding (rs1 & rs2)
  // ===========================================================================
  // The x0 guard (rd_index != 0) prevents forwarding when the producing
  // instruction discards its result - writes to x0 are always silent.
  // MA takes priority over WB because it holds the more recent result.
  // ===========================================================================
    logic fwd_rs1_ma  = (ma_reg_write)
                     && (ma_rd_index != 5'd0)
                     && (ma_rd_index == ex_rs1_index);
    logic fwd_rs1_wb  = (wb_reg_write)
                     && (wb_rd_index != 5'd0)
                     && (wb_rd_index == ex_rs1_index);
    assign fwd_A_sel  = fwd_rs1_ma ? 2'b10
                      : fwd_rs1_wb ? 2'b01
                      : 2'b00;

    logic fwd_rs2_ma  = (ma_reg_write)
                     && (ma_rd_index != 5'd0)
                     && (ma_rd_index == ex_rs2_index);
    logic fwd_rs2_wb  = (wb_reg_write)
                     && (wb_rd_index != 5'd0)
                     && (wb_rd_index == ex_rs2_index);
    assign fwd_B_sel  = fwd_rs2_ma ? 2'b10
                      : fwd_rs2_wb ? 2'b01
                      : 2'b00;
  // ===========================================================================
  // FORWARDING SELECT  ──  operand forwarding
  // ===========================================================================

endmodule
