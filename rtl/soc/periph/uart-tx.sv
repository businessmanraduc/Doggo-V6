// =============================================================================
// PHANTOM-32  ──  UART TX  (Phase III stub, 115200 8-N-1)
// =============================================================================
// Minimal byte transmitter with no FIFO and no status register.
// Phase III only: the CPU must insert a delay loop between consecutive writes
// (~CLKS_PER_BIT × 10 cycles, i.e. ~4350 cycles at 50 MHz / 115200 baud)
// to avoid dropping bytes while the shift register is busy.
//
// tx_valid is a one-cycle strobe. tx_byte is sampled on the same edge.
// A byte arriving while tx_busy is high is silently dropped - the Phase III
// Hello-World program must respect the UART throughput limit.
//
// tx_busy is exposed for future use (flow control, FIFO, polling register).
// =============================================================================

module uart_tx #(
  parameter integer CLKS_PER_BIT = 434   // cpu_clk / baud_rate (50 MHz / 115200 ≈ 434)
) (
  input  logic       clk,
  input  logic       resetn,
  input  logic [7:0] tx_byte,    // byte to transmit (sampled when tx_valid high)
  input  logic       tx_valid,   // one-cycle strobe: begin transmitting tx_byte
  output logic       tx_out,     // UART serial output (idle-high)
  output logic       tx_busy     // high while a byte is in flight
);

  localparam integer PHASE_W = $clog2(CLKS_PER_BIT);

  typedef enum logic [1:0] {
    S_IDLE  = 2'b00,
    S_START = 2'b01,
    S_DATA  = 2'b10,
    S_STOP  = 2'b11
  } uart_state_t;

  uart_state_t        state;
  logic [PHASE_W-1:0] phase_cnt;  // counts 0..CLKS_PER_BIT-1 per bit period
  logic [2:0]         bit_idx;    // counts 0..7 across the eight data bits
  logic [7:0]         shift_reg;  // byte being shifted out, LSB first

  always_ff @(posedge clk) begin
    if (!resetn) begin
      state     <= S_IDLE;
      phase_cnt <= '0;
      bit_idx   <= 3'd0;
      shift_reg <= 8'd0;
      tx_out    <= 1'b1;
      tx_busy   <= 1'b0;
    end else begin
      unique case (state)

        // ── Idle: line high, waiting for a byte ────────────────────────────
        S_IDLE: begin
          tx_out <= 1'b1;
          if (tx_valid) begin
            shift_reg <= tx_byte;
            phase_cnt <= '0;
            tx_busy   <= 1'b1;
            state     <= S_START;
          end else begin
            tx_busy   <= 1'b0;
          end
        end

        // ── Start bit: drive line low for one full bit period ────────────
        S_START: begin
          tx_out <= 1'b0;
          if (phase_cnt == PHASE_W'(CLKS_PER_BIT - 1)) begin
            phase_cnt <= '0;
            bit_idx   <= 3'd0;
            state     <= S_DATA;
          end else begin
            phase_cnt <= phase_cnt + 1'b1;
          end
        end

        // ── Data bits: LSB first, one bit per CLKS_PER_BIT cycles ────────
        S_DATA: begin
          tx_out <= shift_reg[0];
          if (phase_cnt == PHASE_W'(CLKS_PER_BIT - 1)) begin
            phase_cnt <= '0;
            shift_reg <= {1'b0, shift_reg[7:1]};
            if (bit_idx == 3'd7) begin
              state   <= S_STOP;
            end else begin
              bit_idx <= bit_idx + 3'd1;
            end
          end else begin
            phase_cnt <= phase_cnt + 1'b1;
          end
        end

        // ── Stop bit: drive line high for one full bit period ────────────
        S_STOP: begin
          tx_out <= 1'b1;
          if (phase_cnt == PHASE_W'(CLKS_PER_BIT - 1)) begin
            phase_cnt <= '0;
            tx_busy   <= 1'b0;
            state     <= S_IDLE;
          end else begin
            phase_cnt <= phase_cnt + 1'b1;
          end
        end

      endcase
    end
  end

endmodule


