// =============================================================================
// PHANTOM-32  ──  Instruction Cache  (4-way set-associative, pipelined hit)
// =============================================================================
// Serves one 32-bit word per lookup;
// 1 word/cycle throughput, 2-cycle hit latency:
//   stage A (addr -> regs): BRAM data read + distributed tag/valid read
//   stage B (regs -> out):  registered hit vector + registered data words
// Hit/Miss resolved at stage A's compare (cycle N+1)
//
// Cache Geometry: parameterised. With LINES=512, WAYS=4, LINE_BYTES=32:
//    byte addr | tag[24:14] | index[13:5] | word-in-line[4:2] | hw[1] | b[0]
//
// Fill: a missed line is brought in from SDRAM as burst
module icache #(
  parameter int LINES       = 512,  // direct-mapped lines
  parameter int WAYS        = 4,    // associativity
  parameter int LINE_BYTES  = 16,   // bytes per line
  parameter int ADDR_W      = 25    // instruction address space (32MB SDRAM)
) (
  input  logic        clk,
  input  logic        resetn,

  // ── Core fetch port ────────────────────────────────────────────────────────
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:0] addr,         // word-aligned fetch address
  /* verilator lint_on  UNUSEDSIGNAL */
  input logic         sel,          // 1 = addr is cacheable
  output logic [31:0] data,         // instruction word @ addr
  output logic        ready,        // 1 = data valid (hit)

  // ── SDRAM burst-fill master ────────────────────────────────────────────────
  output logic [31:0] fill_addr,    // line-base byte address
  output logic        fill_req,     // request line-fill burst
  input  logic [31:0] fill_rdata,   // current burst word
  input  logic        fill_rvalid   // 1 = fill_rdata has valid burst word
);

  // ── Derived geometry ───────────────────────────────────────────────────────
  localparam int LINE_WORDS = LINE_BYTES / 4;
  localparam int SETS       = LINES / WAYS;
  localparam int WAY_WORDS  = SETS * LINE_WORDS;
  localparam int SET_IDX_W  = $clog2(SETS);
  localparam int WIL_W      = $clog2(LINE_WORDS);
  localparam int WORDIDX_W  = SET_IDX_W + WIL_W;
  localparam int OFF_W      = $clog2(LINE_BYTES);
  localparam int TAG_W      = ADDR_W - OFF_W - SET_IDX_W;
  localparam int WAY_W      = $clog2(WAYS);

  // ── Address field extractors ───────────────────────────────────────────────
  logic [WORDIDX_W-1:0] wordidx;
  logic [SET_IDX_W-1:0] set_idx;
  logic [TAG_W-1:0]     tag;
  assign wordidx = addr[2 +: WORDIDX_W];
  assign set_idx = addr[OFF_W +: SET_IDX_W];
  assign tag     = addr[OFF_W+SET_IDX_W +: TAG_W];

  // ── Miss-fill FSM ───────────────────────────────────────────────────────────
  typedef enum logic[1:0] { S_CHECK, S_FILL, S_WAIT, S_WAIT2 } state_t;
  state_t               state;
  logic [SET_IDX_W-1:0] fill_set;
  logic [TAG_W-1:0]     fill_tag;
  logic [WIL_W-1:0]     fill_wcnt;
  logic [WAY_W-1:0]     victim_way;

  // ── Stage A - Per-way registered lookup results──────────────────────────────
  logic [31:0]      icacheWord  [0:WAYS-1];   // data storage
  logic [TAG_W-1:0] icacheTags  [0:WAYS-1];   // tag  storage
  logic             icacheValid [0:WAYS-1];   // valid bit
  logic [TAG_W-1:0] compTag;
  logic [SET_IDX_W-1:0] set;

  // ── Stage B - Registered data words + hit vector ────────────────────────────
  logic [31:0]      icacheWordQ [0:WAYS-1];
  logic [WAYS-1:0]  hitVecQ;
  logic             readyQ;

  // ── Write-port controls ─────────────────────────────────────────────────────
  logic [WAYS-1:0]      dataWriteEnable;  // per-way data write enable
  logic [WORDIDX_W-1:0] dataWriteAddress; // data write address
  logic [WAYS-1:0]      tagWriteEnable;   // per-way tag/valid strobe
  logic [WAYS-1:0]      tagWriteQ;        // registered copy -> write decode
  always_comb begin
    integer w;
    dataWriteAddress = {fill_set, fill_wcnt};
    for (w = 0; w < WAYS; w = w + 1) begin
      dataWriteEnable[w] = (state == S_FILL) && fill_rvalid && (victim_way == WAY_W'(w));
      tagWriteEnable[w]  = (state == S_FILL) && fill_rvalid && (victim_way == WAY_W'(w)) &&
        (fill_wcnt == WIL_W'(LINE_WORDS-1));
    end
  end
  always_ff @(posedge clk) begin
    if (!resetn) tagWriteQ <= '0;
    else         tagWriteQ <= tagWriteEnable;
  end

  // ── Storage: WAYS × (BRAM data) + (distributed tags + FF valids) ────────────
  genvar genWay;
  generate
    for (genWay = 0; genWay < WAYS; genWay = genWay + 1) begin: way
      (* ram_style = "block" *)       logic [31:0]      data_ram  [0:WAY_WORDS-1];
      (* ram_style = "distributed" *) logic [TAG_W-1:0] tag_mem   [0:SETS-1];
      logic                                             valid_mem [0:SETS-1];

      always_ff @(posedge clk) begin
        if (dataWriteEnable[genWay]) data_ram[dataWriteAddress] <= fill_rdata;
        icacheWord[genWay]  <= data_ram[wordidx];
        icacheWordQ[genWay] <= icacheWord[genWay];
      end

      always_ff @(posedge clk) begin
        if (tagWriteQ[genWay]) tag_mem[fill_set] <= fill_tag;
        icacheTags[genWay] <= tag_mem[set_idx];
      end

      integer i;
      always_ff @(posedge clk) begin
        if (!resetn)
          for (i = 0; i < SETS; i = i + 1) valid_mem[i] <= 1'b0;
        else if (tagWriteQ[genWay])
          valid_mem[fill_set] <= 1'b1;
        icacheValid[genWay] <= valid_mem[set_idx];
      end
    end
  endgenerate

  logic selQ;
  always_ff @(posedge clk) begin
    compTag <= tag;
    set     <= set_idx;
    selQ    <= sel;
  end

  // ── Hit detection + way select (stage A compare; at most one way hits) ──────
  logic [WAYS-1:0]  hit_vec;
  logic             hit;
  logic [WAY_W-1:0] hit_way;
  always_comb begin
    integer w;
    hit_vec = '0;
    hit_way = '0;
    for (w = 0; w < WAYS; w = w + 1) begin
      hit_vec[w] = icacheValid[w] && (icacheTags[w] == compTag);
      if (hit_vec[w]) hit_way = WAY_W'(w);
    end
  end
  assign hit = |hit_vec;

  // ── Stage B: register the hit verdict, select data from flops ───────────────
  always_ff @(posedge clk) begin
    if (!resetn) begin
      readyQ  <= 1'b0;
      hitVecQ <= '0;
    end else begin
      readyQ  <= (state == S_CHECK) && hit;
      hitVecQ <= hit_vec;
    end
  end

  always_comb begin
    integer w;
    data = '0;
    for (w = 0; w < WAYS; w = w + 1) begin
      if (hitVecQ[w]) data = icacheWordQ[w];
    end
  end

  assign ready     = readyQ;
  assign fill_req  = (state == S_FILL);
  assign fill_addr = {{(32-ADDR_W){1'b0}}, fill_tag, fill_set, {WIL_W{1'b0}}, 2'b00};

  // ── Tree-PLRU (4-way): 3 bits/set. bit0=top, bit1=left node, bit2=right node ──
  // bit=0 points at the LRU/victim side. Update points the tree AWAY from `acc`.
  logic [2:0] plru [0:SETS-1];
  
  function automatic [WAY_W-1:0] plru_victim(input logic [2:0] s);
    if (s[0] == 1'b0) plru_victim = s[1] ? WAY_W'(1) : WAY_W'(0);
    else              plru_victim = s[2] ? WAY_W'(3) : WAY_W'(2);
  endfunction

  function automatic [2:0] plru_next(input logic [2:0] s, input logic [WAY_W-1:0] acc);
    logic [2:0] n;
    n = s;
    if (acc[1] == 1'b0) begin // accessed left side
      n[0] = 1'b1;
      n[1] = (acc[0] == 1'b0) ? 1'b1 : 1'b0;
    end else begin            // accessed right side
      n[0] = 1'b0;
      n[2] = (acc[0] == 1'b0) ? 1'b1 : 1'b0;
    end
    plru_next = n;
  endfunction

  logic                 touch_en;
  logic [SET_IDX_W-1:0] touch_set;
  logic [WAY_W-1:0]     touch_way;

  always_ff @(posedge clk) begin
    if (!resetn) begin
      state     <= S_CHECK;
      fill_wcnt <= '0;
      touch_en  <= 1'b0;
    end else begin
      touch_en  <= 1'b0;
      case (state)
        S_CHECK: begin
          if (!hit && selQ) begin
            fill_set   <= set;
            fill_tag   <= compTag;
            fill_wcnt  <= '0;
            victim_way <= plru_victim(plru[set]);
            state      <= S_FILL;
          end else if (hit && selQ) begin
            touch_en   <= 1'b1;
            touch_set  <= set;
            touch_way  <= hit_way;
          end
        end

        S_FILL: begin
          if (fill_rvalid) begin
            if (fill_wcnt == WIL_W'(LINE_WORDS-1)) begin
              touch_en  <= 1'b1;
              touch_set <= fill_set;
              touch_way <= victim_way;
              state     <= S_WAIT;
            end else begin
              fill_wcnt <= fill_wcnt + 1'b1;
            end
          end
        end

        S_WAIT:  state <= S_WAIT2;
        S_WAIT2: state <= S_CHECK;
        default: state <= S_CHECK;
      endcase
    end
  end

  integer j;
  always_ff @(posedge clk) begin
    if (!resetn) begin
      for (j = 0; j < SETS; j = j + 1) plru[j] <= 3'b000;
    end else if (touch_en) begin
      plru[touch_set] <= plru_next(plru[touch_set], touch_way);
    end
  end

endmodule

