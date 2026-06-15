// =============================================================================
// PHANTOM-32  ──  Instruction Cache  (direct-mapped, dual fetch port)
// =============================================================================
// Dual-serve at PC and PC+2, filling missed lines from SDRAM behind 32-bit
// word fill master
//
// Cache Geometry: 8KB, direct-mapped, 16-byte lines, 512 lines.
//    byte addr | tag[24:13] | index[12:4] | word-in-line[3:2] | hw[1] | [0]
//
// Dual fetch port: data + tag arrays are duplicated so both halfwords read in
// one cycle with simple single-port BRAM inference. A 32-bit instruction that
// straddles a line boundary makes copy B miss on the next line; the fill FSM
// brings whichever line(s) miss.
module icache #(
  parameter int LINES       = 512,  // direct-mapped lines
  parameter int LINE_BYTES  = 16,   // bytes per line
  parameter int ADDR_W      = 25    // instruction address space (32MB SDRAM)
) (
  input  logic        clk,
  input  logic        resetn,

  // ── Core fetch ports ───────────────────────────────────────────────────────
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:0] addr_a,       // PC   (next_pc)
  input  logic [31:0] addr_b,       // PC+2 (next_pc2)
  /* verilator lint_on  UNUSEDSIGNAL */
  output logic [15:0] data_a,       // halfword @ PC
  output logic [15:0] data_b,       // halfword @ PC+2
  output logic        ready,        // 1 = data valid (both ports hit)

  // ── SDRAM word-fill master ─────────────────────────────────────────────────
  output logic [31:0] fill_addr,    // word-aligned byte address
  output logic        fill_req,     // request a 32-bit word read
  input  logic [31:0] fill_rdata,   // returned word
  input  logic        fill_ready    // 1 = fill_rdata valid this cycle
);

  // ── Derived geometry ───────────────────────────────────────────────────────
  localparam int LINE_WORDS = LINE_BYTES / 4;
  localparam int WORDS      = LINES * LINE_WORDS;
  localparam int IDX_W      = $clog2(LINES);
  localparam int WIL_W      = $clog2(LINE_WORDS);
  localparam int WORDIDX_W  = IDX_W + WIL_W;
  localparam int OFF_W      = $clog2(LINE_BYTES);
  localparam int TAG_W      = ADDR_W - OFF_W - IDX_W;

  // ── Address field extractors ───────────────────────────────────────────────
  logic [WORDIDX_W-1:0] wordidx_a,  wordidx_b;
  logic [IDX_W-1:0]     idx_a,      idx_b;
  logic [TAG_W-1:0]     tag_a,      tag_b;
  logic                 hwsel_a,    hwsel_b;

  assign wordidx_a = addr_a[2 +: WORDIDX_W];
  assign wordidx_b = addr_b[2 +: WORDIDX_W];
  assign idx_a     = addr_a[OFF_W +: IDX_W];
  assign idx_b     = addr_b[OFF_W +: IDX_W];
  assign tag_a     = addr_a[OFF_W+IDX_W +: TAG_W];
  assign tag_b     = addr_b[OFF_W+IDX_W +: TAG_W];
  assign hwsel_a   = addr_a[1];
  assign hwsel_b   = addr_b[1];

  // ── Storage: dup 32-bit data RAMs + tag RAMs, shared valid FF array ────────
  (* ram_style = "block" *) logic [31:0]    data_a_ram [0:WORDS-1];
  (* ram_style = "block" *) logic [31:0]    data_b_ram [0:WORDS-1];
  (* ram_style = "block" *) logic [TAG_W:0] tag_a_ram  [0:LINES-1];
  (* ram_style = "block" *) logic [TAG_W:0] tag_b_ram  [0:LINES-1];

  // ── 1-cycle registered lookup ──────────────────────────────────────────────
  logic [31:0]      word_a_q,   word_b_q;   // data RAM outputs
  logic [TAG_W:0]   tagrd_a_q,  tagrd_b_q;  // tag  RAM outputs
  logic [TAG_W-1:0] tagcmp_a_q, tagcmp_b_q; // tag to compare
  logic [IDX_W-1:0] idx_a_q,    idx_b_q;    // index of the looked-up line
  logic             hwsel_a_q,  hwsel_b_q;

  always_ff @(posedge clk) begin
    word_a_q   <= data_a_ram[wordidx_a];
    word_b_q   <= data_b_ram[wordidx_b];
    tagrd_a_q  <= tag_a_ram[idx_a];
    tagrd_b_q  <= tag_b_ram[idx_b];
    tagcmp_a_q <= tag_a;
    tagcmp_b_q <= tag_b;
    idx_a_q    <= idx_a;
    idx_b_q    <= idx_b;
    hwsel_a_q  <= hwsel_a;
    hwsel_b_q  <= hwsel_b;
  end

  logic hit_a; assign hit_a = tagrd_a_q[TAG_W] && (tagrd_a_q[TAG_W-1:0] == tagcmp_a_q);
  logic hit_b; assign hit_b = tagrd_b_q[TAG_W] && (tagrd_b_q[TAG_W-1:0] == tagcmp_b_q);
  assign data_a = hwsel_a_q ? word_a_q[31:16] : word_a_q[15:0];
  assign data_b = hwsel_b_q ? word_b_q[31:16] : word_b_q[15:0];

  // ── Miss-fill FSM ───────────────────────────────────────────────────────────
  typedef enum logic[1:0] { S_CLEAR, S_CHECK, S_FILL, S_WAIT } state_t;
  state_t           state;
  logic [IDX_W-1:0] clear_cnt;
  logic [IDX_W-1:0] fill_line;
  logic [TAG_W-1:0] fill_tag;
  logic [WIL_W-1:0] fill_wcnt;

  assign ready = (state == S_CHECK) && hit_a && hit_b;
  
  assign fill_req  = (state == S_FILL);
  assign fill_addr = {{(32-ADDR_W){1'b0}}, fill_tag, fill_line, fill_wcnt, 2'b00};

  always_ff @(posedge clk) begin
    if (!resetn) begin
      state     <= S_CLEAR;
      clear_cnt <= '0;
      fill_wcnt <= '0;
    end else begin
      case (state)
        S_CLEAR: begin
          tag_a_ram[clear_cnt] <= '0;
          tag_b_ram[clear_cnt] <= '0;
          if (clear_cnt == IDX_W'(LINES-1)) state <= S_CHECK;
          clear_cnt <= clear_cnt + 1'b1;
        end

        S_CHECK: begin
          if (!hit_a) begin
            fill_line <= idx_a_q; fill_tag <= tagcmp_a_q; fill_wcnt <= '0;
            state     <= S_FILL;
          end else if (!hit_b) begin
            fill_line <= idx_b_q; fill_tag <= tagcmp_b_q; fill_wcnt <= '0;
            state     <= S_FILL;
          end
        end

        S_FILL: begin
          if (fill_ready) begin
            data_a_ram[{fill_line, fill_wcnt}] <= fill_rdata;
            data_b_ram[{fill_line, fill_wcnt}] <= fill_rdata;
            if (fill_wcnt == WIL_W'(LINE_WORDS-1)) begin
              tag_a_ram[fill_line] <= {1'b1, fill_tag};
              tag_b_ram[fill_line] <= {1'b1, fill_tag};
              state                <= S_WAIT;
            end else begin
              fill_wcnt <= fill_wcnt + 1'b1;
            end
          end
        end

        S_WAIT:  state <= S_CHECK;
        default: state <= S_CHECK;
      endcase
    end
  end

endmodule

