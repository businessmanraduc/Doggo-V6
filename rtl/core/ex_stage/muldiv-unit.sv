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
    S_MUL1 = 3'd1,              // multiply: DSP partial products
    S_MUL2 = 3'd2,              // multiply: shift-add
    S_MUL3 = 3'd3,              // multiply: result ready this cycle
    S_ITER = 3'd4,              // divide:   shift-subtract iteration
    S_DONE = 3'd5;              // divide:   result ready this cycle
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

    logic a_isSigned; assign a_isSigned = (r_opcode[1:0] == 2'b01) || (r_opcode[1:0] == 2'b10);
    logic b_isSigned; assign b_isSigned = (r_opcode[1:0] == 2'b01);

    logic signed [32:0] a_ext;   assign a_ext = signed'({a_isSigned & r_a[31], r_a});
    logic signed [32:0] b_ext;   assign b_ext = signed'({b_isSigned & r_b[31], r_b});

    logic signed [17:0] a_lo;    assign a_lo = $signed({1'b0, a_ext[16:0]});
    logic signed [17:0] b_lo;    assign b_lo = $signed({1'b0, b_ext[16:0]});
    logic signed [17:0] a_hi;    assign a_hi = {{2{a_ext[32]}}, a_ext[32:17]};
    logic signed [17:0] b_hi;    assign b_hi = {{2{b_ext[32]}}, b_ext[32:17]};

    logic signed [35:0] pp_lolo; assign pp_lolo = a_lo * b_lo;
    logic signed [35:0] pp_lohi; assign pp_lohi = a_lo * b_hi;
    logic signed [35:0] pp_hilo; assign pp_hilo = a_hi * b_lo;
    logic signed [35:0] pp_hihi; assign pp_hihi = a_hi * b_hi;
    logic signed [35:0] r_lolo, r_lohi, r_hilo, r_hihi;

    /* verilator lint_off UNUSEDSIGNAL */
    logic signed [65:0] product; assign product = (
      (66'(r_hihi)          <<< 34) +
      (66'(r_lohi + r_hilo) <<< 17) +
      (66'(r_lolo))
    );
    /* verilator lint_on  UNUSEDSIGNAL */

    logic [63:0] r_product;
    logic [31:0] mul_result;
    assign mul_result = (r_opcode[1:0] == 2'b00)
      ? r_product[31:0]           // MUL
      : r_product[63:32];         // MULH

  // ===========================================================================
  // MULTIPLIER
  // ===========================================================================


  // ===========================================================================
  // DIVIDER START-CYCLE HELPERS  (combinational, from the live inputs a/b/opcode)
  // ===========================================================================

    logic        in_divSigned;  assign in_divSigned = opcode[2] & ~opcode[0];
    logic        in_aSign;      assign in_aSign = in_divSigned & a[31];
    logic        in_bSign;      assign in_bSign = in_divSigned & b[31];
    logic [31:0] in_aMag;       assign in_aMag  = in_aSign ? (~a + 32'd1) : a;
    logic [31:0] in_bMag;       assign in_bMag  = in_bSign ? (~b + 32'd1) : b;
    logic        in_bZero;      assign in_bZero = (b == 32'd0);
    logic        in_aIntmin;    assign in_aIntmin  = (a == 32'h8000_0000);
    logic        in_bNeg1;      assign in_bNeg1    = (b == 32'hFFFF_FFFF);
    logic        in_overflow;   assign in_overflow = in_divSigned & in_aIntmin & in_bNeg1;

    logic [31:0] in_specialRes;
    assign in_specialRes = in_bZero
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

    always_ff @(posedge clk) begin
      if (!resetn || flush) begin
        state <= S_IDLE;
      end else begin
        case (state)
          S_IDLE: if (valid_in) state <=
            (!opcode[2])              ? S_MUL1 :
            (in_bZero | in_overflow)  ? S_DONE :
            S_ITER;
          S_MUL1: state <= S_MUL2;
          S_MUL2: state <= S_MUL3;
          S_MUL3: if (consume)      state <= S_IDLE;
          S_ITER: if (cnt == 5'd31) state <= S_DONE;
          S_DONE: if (consume)      state <= S_IDLE;
          default:                  state <= S_IDLE;
      end
    end

    always_ff @(posedge clk) begin
      case (state)
        // ── Idle: latch a new M instruction and dispatch ───────────────────
        S_IDLE: if (valid_in) begin
          r_a      <= a;
          r_b      <= b;
          r_opcode <= opcode[1:0];
          if (opcode[2]) begin
            want_rem       <= opcode[1];
            quot_sign      <= in_aSign ^ in_bSign;
            rem_sign       <= in_aSign;
            is_specialCase <= in_bZero | in_overflow;
            special_res    <= in_specialRes;
            divP  <= in_aMag;
            divC  <= in_bMag;
            rem   <= 33'd0;
            quot  <= 32'd0;
            cnt   <= 5'd0;
          end
        end

        // ── Multiply - 3 Stage: DSP partials -> fabric sum -> output ──────
        S_MUL1: begin
          r_lolo <= pp_lolo;
          r_lohi <= pp_lohi;
          r_hilo <= pp_hilo;
          r_hihi <= pp_hihi; // :3
        end

        S_MUL2: begin
          r_product <= product[63:0];
        end

        // ── One quotient bit per cycle ────────────────────────────────────
        S_ITER: begin
          rem  <= sub_ge ? (rem_shift - {1'b0, divC}) : rem_shift;
          quot <= {quot[30:0], sub_ge};
          divP <= {divP[30:0], 1'b0};
          cnt  <= cnt + 5'd1;
        end

        default: ;
      endcase
    end

  // ===========================================================================
  // FSM + DATAPATH
  // ===========================================================================
 


  // ===========================================================================
  // OUTPUTS
  // ===========================================================================

    assign done = (state == S_MUL3) || (state == S_DONE);

    always_comb begin
      case (state)
        S_MUL3:  result = mul_result;
        S_DONE:  result = div_result;
        default: result = 32'hDEADBEEF;
      endcase
    end

  // ===========================================================================
  // OUTPUTS
  // ===========================================================================
 

endmodule

