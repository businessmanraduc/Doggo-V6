// ==========================================================================
// PHANTOM-32 ── UART module (8-N-1, TX + RX, FIFO-buffered)
// ==========================================================================
// DATA   (write) : enqueue a byte for transmission (dropped if tx FIFO full)
// DATA   (read)  : pop and return the oldest received byte
// STATUS (read)  : bit0 tx_full     1 = TX FIFO full
//                  bit1 rx_valid    1 = a received byte is waiting
//                  bit2 tx_empty    1 = TX FIFO empty AND shifter idle
//                  bit3 rx_overrun  1 = an RX byte was dropped (cleared on DATA read)
// ==========================================================================
module uart #(
  parameter integer CLKS_PER_BIT = 434,   // cpu_clk / baud
  parameter integer FIFO_DEPTH   = 16
) (
  input  logic        clk,
  input  logic        resetn,

  // ── register interface (asserted during the peripheral's MA cycle) ──────
  input  logic        tx_write,   // strobe: enqueue tx_data
  input  logic [7:0]  tx_data,
  input  logic        rx_read,    // strobe: pop the RX FIFO
  output logic [7:0]  rx_data,    // oldest received byte
  output logic [31:0] status,     // UART status word

  // ── serial pins ─────────────────────────────────────────────────────────
  output logic        uart_tx,    // FPGA -> host (idle high)
  input  logic        uart_rx     // host -> FPGA (idle high)
);

  localparam integer PHASE_W = $clog2(CLKS_PER_BIT);
  logic tx_full, tx_empty, rx_valid, rx_overrun;
  assign status = {28'd0, rx_overrun, tx_empty, rx_valid, tx_full};

  // ========================================================================
  // TX path: FIFO -> shift FSM
  // ========================================================================
    logic [7:0] txfifo_head;
    logic       txfifo_empty;
    logic       txfifo_full;
    logic       txfifo_pop;

    uart_fifo #(.WIDTH(8), .DEPTH(FIFO_DEPTH)) u_txfifo (
      .clk(clk), .resetn(resetn),
      .wr_en(tx_write), .wr_data(tx_data),
      .rd_en(txfifo_pop), .rd_data(txfifo_head),
      .full(txfifo_full), .empty(txfifo_empty),
      .wr_dropped()
    );
    assign tx_full = txfifo_full;

    typedef enum logic [1:0] { TX_IDLE, TX_START, TX_DATA, TX_STOP } txstate_t;
    txstate_t           tx_state;
    logic [PHASE_W-1:0] tx_phase;
    logic [2:0]         tx_bitIdx;
    logic [7:0]         tx_shift;

    always_ff @(posedge clk) begin
      if (!resetn) begin
        tx_state   <= TX_IDLE;
        tx_phase   <= '0;
        tx_bitIdx  <= 3'd0;
        tx_shift   <= 8'd0;
        uart_tx    <= 1'b1;
        txfifo_pop <= 1'b0;
      end else begin
        txfifo_pop <= 1'b0;
        unique case (tx_state)
          TX_IDLE: begin
            uart_tx <= 1'b1;
            if (!txfifo_empty) begin
              tx_shift   <= txfifo_head;
              txfifo_pop <= 1'b1;
              tx_phase   <= '0;
              tx_state   <= TX_START;
            end
          end

          TX_START: begin
            uart_tx <= 1'b0;
            if (tx_phase == PHASE_W'(CLKS_PER_BIT - 1)) begin
              tx_phase  <= '0;
              tx_bitIdx <= 3'd0;
              tx_state  <= TX_DATA;
            end else tx_phase <= tx_phase + 1'b1;
          end

          TX_DATA: begin
            uart_tx <= tx_shift[0];
            if (tx_phase == PHASE_W'(CLKS_PER_BIT - 1)) begin
              tx_phase <= '0;
              tx_shift <= {1'b0, tx_shift[7:1]};
              if (tx_bitIdx == 3'd7) tx_state <= TX_STOP;
              else                   tx_bitIdx <= tx_bitIdx + 3'd1;
            end else tx_phase <= tx_phase + 1'b1;
          end

          TX_STOP: begin
            uart_tx <= 1'b1;
            if (tx_phase == PHASE_W'(CLKS_PER_BIT - 1)) begin
              tx_phase <= '0;
              tx_state <= TX_IDLE;
            end else tx_phase <= tx_phase + 1'b1;
          end
          default: tx_state <= TX_IDLE;
        endcase
      end
    end

    assign tx_empty = txfifo_empty && (tx_state == TX_IDLE);
  // ========================================================================
  // TX path
  // ========================================================================


  // ========================================================================
  // RX path: sampler -> FIFO
  // ========================================================================
    logic rx_sync0, rx_sync1;
    always_ff @(posedge clk) begin
      if (!resetn) begin rx_sync0 <= 1'b1;    rx_sync1 <= 1'b1;     end
      else         begin rx_sync0 <= uart_rx; rx_sync1 <= rx_sync0; end
    end
    wire rx_line = rx_sync1;

    typedef enum logic [1:0] { RX_IDLE, RX_START, RX_DATA, RX_STOP } rxstate_t;
    rxstate_t           rx_state;
    logic [PHASE_W-1:0] rx_phase;
    logic [2:0]         rx_bitIdx;
    logic [7:0]         rx_shift;
    logic               rx_push;

    always_ff @(posedge clk) begin
      if (!resetn) begin
        rx_state  <= RX_IDLE;
        rx_phase  <= '0;
        rx_bitIdx <= 3'd0;
        rx_shift  <= 8'd0;
        rx_push   <= 1'b0;
      end else begin
        rx_push   <= 1'b0;
        unique case (rx_state)
          RX_IDLE: begin
            if (!rx_line) begin
              rx_phase <= '0;
              rx_state <= RX_START;
            end
          end

          RX_START: begin
            if (rx_phase == PHASE_W'(CLKS_PER_BIT/2 - 1)) begin
              if (!rx_line) begin
                rx_phase  <= '0;
                rx_bitIdx <= 3'd0;
                rx_state  <= RX_DATA;
              end else begin
                rx_state  <= RX_IDLE;
              end
            end else begin
                rx_phase  <= rx_phase + 1'b1;
            end
          end

          RX_DATA: begin
            if (rx_phase == PHASE_W'(CLKS_PER_BIT - 1)) begin
              rx_phase <= '0;
              rx_shift <= {rx_line, rx_shift[7:1]};
              if (rx_bitIdx == 3'd7) rx_state  <= RX_STOP;
              else                   rx_bitIdx <= rx_bitIdx + 3'd1;
            end else begin
              rx_phase <= rx_phase + 1'b1;
            end
          end

          RX_STOP: begin
            if (rx_phase == PHASE_W'(CLKS_PER_BIT - 1)) begin
              rx_push  <= 1'b1;
              rx_state <= RX_IDLE;
            end else begin
              rx_phase <= rx_phase + 1'b1;
            end
          end

          default: rx_state <= RX_IDLE;
        endcase
      end
    end

    logic rxfifo_empty;
    logic rxfifo_full;
    logic rxfifo_dropped;
    uart_fifo #(.WIDTH(8), .DEPTH(FIFO_DEPTH)) u_rxfifo (
      .clk(clk), .resetn(resetn),
      .wr_en(rx_push), .wr_data(rx_shift),
      .rd_en(rx_read), .rd_data(rx_data),
      .full(rxfifo_full), .empty(rxfifo_empty),
      .wr_dropped(rxfifo_dropped)
    );
    assign rx_valid = !rxfifo_empty;

    always_ff @(posedge clk) begin
      if (!resetn)              rx_overrun <= 1'b0;
      else if (rxfifo_dropped)  rx_overrun <= 1'b1;
      else if (rx_read)         rx_overrun <= 1'b0;
    end
  // ========================================================================
  // RX path
  // ========================================================================

endmodule


// ==========================================================================
// uart_fifo ── small synchronous FIFO
// ==========================================================================
module uart_fifo #(
  parameter integer WIDTH = 8,
  parameter integer DEPTH = 16
) (
  input  logic             clk,
  input  logic             resetn,
  input  logic             wr_en,
  input  logic [WIDTH-1:0] wr_data,
  input  logic             rd_en,
  output logic [WIDTH-1:0] rd_data,
  output logic             full,
  output logic             empty,
  output logic             wr_dropped
);

  localparam integer AW = $clog2(DEPTH);

  (* ram_style = "distributed" *) logic [WIDTH-1:0] mem [0:DEPTH-1];
  logic [AW:0] wr_ptr, rd_ptr;

  assign empty      = (wr_ptr == rd_ptr);
  assign full       = (wr_ptr[AW] != rd_ptr[AW]) && (wr_ptr[AW-1:0] == rd_ptr[AW-1:0]);
  assign rd_data    = mem[rd_ptr[AW-1:0]];
  assign wr_dropped = wr_en && full;

  always_ff @(posedge clk) begin
    if (!resetn) begin
      wr_ptr <= '0;
      rd_ptr <= '0;
    end else begin
      if (wr_en && !full) begin
        mem[wr_ptr[AW-1:0]] <= wr_data;
        wr_ptr <= wr_ptr + 1'b1;
      end

      if (rd_en && !empty) rd_ptr <= rd_ptr + 1'b1;
    end
  end

endmodule
