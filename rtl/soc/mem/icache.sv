// =============================================================================
// PHANTOM-32  ──  Instruction Cache  (direct-mapped, dual fetch port)
// =============================================================================
// Serves one 32-bit word per lookup; halfwords are split in fabric. (addr_b is
// kept for interface compatibility but is no longer used for addressing.)
//
// Cache Geometry: direct-mapped, parameterised. With LINES=512, LINE_BYTES=32:
//    byte addr | tag[24:14] | index[13:5] | word-in-line[4:2] | hw[1] | b[0]
//
// Fill: a missed line is brought in from SDRAM as burst
module icache #(
  parameter int LINES       = 512,  // direct-mapped lines
  parameter int LINE_BYTES  = 16,   // bytes per line
  parameter int ADDR_W      = 25    // instruction address space (32MB SDRAM)
) (
  input  logic        clk,
  input  logic        resetn,

  // ── Core fetch ports ───────────────────────────────────────────────────────
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:0] addr_a,       // word-aligned PC
  input  logic [31:0] addr_b,       // PC+2
  /* verilator lint_on  UNUSEDSIGNAL */
  output logic [15:0] data_a,       // halfword @ PC   = word[15:0]
  output logic [15:0] data_b,       // halfword @ PC+2 = word[31:16]
  output logic        ready,        // 1 = data valid (hit)

  // ── SDRAM burst-fill master ────────────────────────────────────────────────
  output logic [31:0] fill_addr,    // line-base byte address
  output logic        fill_req,     // request line-fill burst
  input  logic [31:0] fill_rdata,   // current burst word
  input  logic        fill_rvalid   // 1 = fill_rdata has valid burst word
);

  // ── Derived geometry ───────────────────────────────────────────────────────
  localparam int LINE_WORDS = LINE_BYTES / 4;
  localparam int WORDS      = LINES * LINE_WORDS;
  localparam int IDX_W      = $clog2(LINES);
  localparam int WIL_W      = $clog2(LINE_WORDS);
  localparam int WORDIDX_W  = IDX_W + WIL_W;
  localparam int OFF_W      = $clog2(LINE_BYTES);
  localparam int TAG_W      = ADDR_W - OFF_W - IDX_W;

  // ── Address field extractors (lookup uses addr_a only) ──────────────────────
  logic [WORDIDX_W-1:0] wordidx;
  logic [IDX_W-1:0]     idx;
  logic [TAG_W-1:0]     tag;
  assign wordidx = addr_a[2 +: WORDIDX_W];
  assign idx     = addr_a[OFF_W +: IDX_W];
  assign tag     = addr_a[OFF_W+IDX_W +: TAG_W];

  // ── Storage: one 32-bit data RAM + one tag RAM (valid bit in MSB) ───────────
  (* ram_style = "block" *) logic [31:0]    data_ram [0:WORDS-1];
  (* ram_style = "block" *) logic [TAG_W:0] tag_ram  [0:LINES-1];

  // ── Miss-fill FSM ───────────────────────────────────────────────────────────
  typedef enum logic[1:0] { S_CLEAR, S_CHECK, S_FILL, S_WAIT } state_t;
  state_t           state;
  logic [IDX_W-1:0] clear_cnt;
  logic [IDX_W-1:0] fill_line;
  logic [TAG_W-1:0] fill_tag;
  logic [WIL_W-1:0] fill_wcnt;

  // ── Combinational write-port controls ───────────────────────────────────────
  logic                 dwe;  // data write enable
  logic [WORDIDX_W-1:0] dwa;  // data write address
  logic                 twe;  // tag  write enable
  logic [IDX_W-1:0]     twa;  // tag  write address
  logic [TAG_W:0]       twd;  // tag  write data {valid, tag}
  always_comb begin
    dwe = (state == S_FILL) && fill_rvalid;
    dwa = {fill_line, fill_wcnt};
    twe = 1'b0;
    twa = clear_cnt;
    twd = '0;
    if (state == S_CLEAR) begin
      twe = 1'b1; twa = clear_cnt; twd = '0;                 // invalidate at boot
    end else if ((state == S_FILL) && fill_rvalid &&
                 (fill_wcnt == WIL_W'(LINE_WORDS-1))) begin
      twe = 1'b1; twa = fill_line; twd = {1'b1, fill_tag};   // validate filled line
    end
  end

  // ── Dedicated 1-cycle registered lookup + write ─────────────────────────────
  logic [31:0]    word_q;
  logic [TAG_W:0] tagrd_q;
  always_ff @(posedge clk) begin
    if (dwe) data_ram[dwa] <= fill_rdata;
    word_q <= data_ram[wordidx];
  end
  always_ff @(posedge clk) begin
    if (twe) tag_ram[twa] <= twd;
    tagrd_q <= tag_ram[idx];
  end

  logic [TAG_W-1:0] tagcmp_q;
  logic [IDX_W-1:0] idx_q;
  always_ff @(posedge clk) begin
    tagcmp_q <= tag;
    idx_q    <= idx;
  end

  logic hit; assign hit = tagrd_q[TAG_W] && (tagrd_q[TAG_W-1:0] == tagcmp_q);
  assign data_a = word_q[15:0];
  assign data_b = word_q[31:16];

  assign ready     = (state == S_CHECK) && hit;
  assign fill_req  = (state == S_FILL);
  assign fill_addr = {{(32-ADDR_W){1'b0}}, fill_tag, fill_line, {WIL_W{1'b0}}, 2'b00};

  always_ff @(posedge clk) begin
    if (!resetn) begin
      state     <= S_CLEAR;
      clear_cnt <= '0;
      fill_wcnt <= '0;
    end else begin
      case (state)
        S_CLEAR: begin
          if (clear_cnt == IDX_W'(LINES-1)) state <= S_CHECK;
          clear_cnt <= clear_cnt + 1'b1;
        end

        S_CHECK: begin
          if (!hit) begin
            fill_line <= idx_q; fill_tag <= tagcmp_q; fill_wcnt <= '0;
            state     <= S_FILL;
          end
        end

        S_FILL: begin
          if (fill_rvalid) begin
            if (fill_wcnt == WIL_W'(LINE_WORDS-1)) state <= S_WAIT;
            else                                   fill_wcnt <= fill_wcnt + 1'b1;
          end
        end

        S_WAIT:  state <= S_CHECK;
        default: state <= S_CHECK;
      endcase
    end
  end

endmodule

