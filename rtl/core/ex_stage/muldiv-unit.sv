`include "isa.vh"
// =============================================================================
// PHANTOM-32  ──  Multiply / Divide Unit  (EX stage, multi-cycle)
// =============================================================================
// Implements the RV32M instructions as a self-contained multi-cycle functional
// unit that sits beside the ALU in the execute stage
//
// Handshake:
//   valid_in  - asserted while an M-extension instruction occupies EX. The unit
//               self-starts when it is idle and valid_in is seen. Operands a/b
//               (post-forwarding rs1/rs2) are sampled on that start cycle.
//   done      - 1 for exactly the cycle the result is valid. The top level uses
//               ex_busy = valid_in && !done to freeze the front-end and bubble
//               EX/MA; on the done cycle the result is captured downstream.
//
// opcode = func3:
//   000 MUL    low 32 of product            (sign-agnostic)
//   001 MULH   high 32, signed   x signed
//   010 MULHSU high 32, signed   x unsigned
//   011 MULHU  high 32, unsigned x unsigned
//   100 DIV    signed   quotient
//   101 DIVU   unsigned quotient
//   110 REM    signed   remainder
//   111 REMU   unsigned remainder
// =============================================================================
module muldiv_unit (
  input  logic        clk,
  input  logic        resetn,

  input  logic        valid_in, // 1 = M-instruction inside EX
  input  logic        consume,  // 1 = EX releases the result to MA this cycle
  input  logic        flush,    // 1 = EX instruction squashed -> abort
  input  logic [2:0]  opcode,   // func3 selector
  input  logic [31:0] a,        // rs1 value (post-forwarding)
  input  logic [31:0] b,        // rs2 value (post-forwarding)

  output logic [31:0] result,   // valid while done = 1
  output logic        done      // 1 = result valid this cycle
);

  // ── FSM states ─────────────────────────────────────────────────────────────
  localparam logic [2:0]
    S_IDLE = 3'd0,              // waiting for M instruction
    S_MUL1 = 3'd1,              // multiply stage 1
    S_MUL2 = 3'd2,              // multiply stage 2
    S_ITER = 3'd3,              // divide:   shift-subtract iteration
    S_DONE = 3'd4;              // divide:   result ready this cycle
  logic [2:0] state;

  // ── Latched operands / op ─────────────────────────────────────────────────
  logic [31:0] r_a;
  logic [31:0] r_b;
  logic [1:0]  r_opcode;

  // ── Divider working registers ─────────────────────────────────────────────
  /* verilator lint_off UNUSEDSIGNAL */
  logic [32:0] rem;             // partial remainder (33-bit working width)
  /* verilator lint_on UNUSEDSIGNAL */
  logic [31:0] quot;            // quotient bits shifted LSB-first
  logic [31:0] divP;            // dividend magnitude, shifted left each cycle
  logic [31:0] divC;            // divisor magnitude
  logic [4:0]  cnt;             // iteration counter
  logic        want_rem;        // 1 = REM/REMU (remainder select)
  logic        quot_sign;       // 1 = quotient should be negated
  logic        rem_sign;        // 1 = remainder should be negated
  logic        is_specialCase;  // 1 = div-by-zero || signed-overflow
  logic [31:0] special_res;     // precomputed result for special case


  // ===========================================================================
  // MULTIPLIER  (combinational, from latched operands)
  // ===========================================================================

    logic a_is_signed; assign a_is_signed = (r_opcode[1:0] == 2'b01) || (r_opcode[1:0] == 2'b10);
    logic b_is_signed; assign b_is_signed = (r_opcode[1:0] == 2'b01);

    logic signed [32:0] a_ext;   assign a_ext = signed'({a_is_signed & r_a[31], r_a});
    logic signed [32:0] b_ext;   assign b_ext = signed'({b_is_signed & r_b[31], r_b});

    /* verilator lint_off UNUSEDSIGNAL */
    logic signed [65:0] product; assign product = a_ext * b_ext;
    /* verilator lint_on  UNUSEDSIGNAL */

    logic [63:0] product_q;
    logic [31:0] mul_result;
    assign mul_result = (r_opcode[1:0] == 2'b00)
      ? product_q[31:0]           // MUL
      : product_q[63:32];         // MULH

  // ===========================================================================
  // MULTIPLIER
  // ===========================================================================


  // ===========================================================================
  // DIVIDER START-CYCLE HELPERS  (combinational, from the live inputs a/b/opcode)
  // ===========================================================================

    logic        in_div_signed; assign in_div_signed = opcode[2] & ~opcode[0];
    logic        in_sign_a;     assign in_sign_a = in_div_signed & a[31];
    logic        in_sign_b;     assign in_sign_b = in_div_signed & b[31];
    logic [31:0] in_mag_a;      assign in_mag_a  = in_sign_a ? (~a + 32'd1) : a;
    logic [31:0] in_mag_b;      assign in_mag_b  = in_sign_b ? (~b + 32'd1) : b;
    logic        in_b_zero;     assign in_b_zero = (b == 32'd0);
    logic        in_a_intmin;   assign in_a_intmin = (a == 32'h8000_0000);
    logic        in_b_neg1;     assign in_b_neg1   = (b == 32'hFFFF_FFFF);
    logic        in_overflow;   assign in_overflow = in_div_signed & in_a_intmin & in_b_neg1;

    logic [31:0] in_special_res;
    assign in_special_res = in_b_zero
      ? (opcode[1] ? a     : 32'hFFFF_FFFF)
      : (opcode[1] ? 32'd0 : 32'h8000_0000);

    logic [32:0] rem_shift;     assign rem_shift = {rem[31:0], divP[31]};
    logic        sub_ge;        assign sub_ge    = (rem_shift >= {1'b0, divC});

    logic [31:0] quot_fixed;    assign quot_fixed = quot_sign ? (~quot      + 32'd1) : quot;
    logic [31:0] rem_fixed;     assign rem_fixed  = rem_sign  ? (~rem[31:0] + 32'd1) : rem[31:0];
    logic [31:0] div_result;
    assign div_result = !is_specialCase
      ? (want_rem ? rem_fixed : quot_fixed)
      : special_res;

  // ===========================================================================
  // DIVIDER START-CYCLE HELPERS
  // ===========================================================================


  // ===========================================================================
  // FSM + DATAPATH
  // ===========================================================================

    always_ff @(posedge clk)begin
      if (!resetn) begin
        state <= S_IDLE;
      end else if (flush) begin
        state <= S_IDLE;
      end else begin
        case (state)
          // ── Idle: latch a new M instruction and dispatch ───────────────────
          S_IDLE: begin
            if (valid_in) begin
              r_a      <= a;
              r_b      <= b;
              r_opcode <= opcode[1:0];
              if (!opcode[2]) begin
                state  <= S_MUL1;
              end else begin
                want_rem       <= opcode[1];
                quot_sign      <= in_sign_a ^ in_sign_b;
                rem_sign       <= in_sign_a;
                is_specialCase <= in_b_zero | in_overflow;
                special_res    <= in_special_res;
                divP  <= in_mag_a;
                divC  <= in_mag_b;
                rem   <= 33'd0;
                quot  <= 32'd0;
                cnt   <= 5'd0;
                state <= (in_b_zero | in_overflow) ? S_DONE : S_ITER;
              end
            end
          end

          // ── Multiply - 2 Stage compute + output ──────────────────────────────
          S_MUL1: begin
            product_q <= product[63:0];
            state     <= S_MUL2;
          end
          S_MUL2: if (consume) state <= S_IDLE;

          // ── One quotient bit per cycle ───────────────────────────────────────
          S_ITER: begin
            rem  <= sub_ge ? (rem_shift - {1'b0, divC}) : rem_shift;
            quot <= {quot[30:0], sub_ge};
            divP <= {divP[30:0], 1'b0};
            cnt  <= cnt + 5'd1;
            if (cnt == 5'd31) state <= S_DONE;
          end

          // ── Divide result consumed this cycle ──────────────────────────────
          S_DONE: if(consume) state <= S_IDLE;

          default: state <= S_IDLE;
        endcase
      end
    end

  // ===========================================================================
  // FSM + DATAPATH
  // ===========================================================================
 


  // ===========================================================================
  // OUTPUTS
  // ===========================================================================

    assign done = (state == S_MUL2) || (state == S_DONE);

    always_comb begin
      case (state)
        S_MUL2:  result = mul_result;
        S_DONE:  result = div_result;
        default: result = 32'hDEADBEEF;
      endcase
    end

  // ===========================================================================
  // OUTPUTS
  // ===========================================================================
 

endmodule

