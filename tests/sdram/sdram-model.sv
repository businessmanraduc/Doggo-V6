// =============================================================================
// PHANTOM-32  ──  Behavioral SDR SDRAM Model  (sim only, burst-capable)
// =============================================================================
// Functional stand-in for the chip so the controller can be checked under
// simulation. Not a datasheet timing model: it decodes commands, honours CAS
// latency, and streams/accepts BURST_LEN words per READ/WRITE, which is what
// the controller's correctness depends on.
// =============================================================================
module sdram_model #(
  parameter int CAS_LATENCY = 2,
  parameter int BURST_LEN   = 8,
  parameter int MODEL_AW    = 16
) (
  input  logic        clk,
  input  logic        cke,
  input  logic        cs_n,
  input  logic        ras_n,
  input  logic        cas_n,
  input  logic        we_n,
  input  logic [1:0]  ba,
  input  logic [12:0] a,
  input  logic [1:0]  dqm,
  input  logic [15:0] dq_in,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic        dq_oe,
  /* verilator lint_on  UNUSEDSIGNAL */
  output logic [15:0] dq_out
);

  logic [3:0] cmd;
  assign cmd = {cs_n, ras_n, cas_n, we_n};
  localparam logic [3:0] CMD_ACTIVE = 4'b0011;
  localparam logic [3:0] CMD_READ   = 4'b0101;
  localparam logic [3:0] CMD_WRITE  = 4'b0100;

  logic is_active; assign is_active = cke && (cmd == CMD_ACTIVE);
  logic is_read;   assign is_read   = cke && (cmd == CMD_READ);
  logic is_write;  assign is_write  = cke && (cmd == CMD_WRITE);

  logic [15:0] mem [0:(1<<MODEL_AW)-1];
  logic [12:0] open_row [0:3];

  // Linear base address for the current command's first word.
  logic [23:0] lin_base;
  assign lin_base = {ba, open_row[ba], a[8:0]};

  localparam logic [3:0] LAST_I = 4'(BURST_LEN-1);

  // ── Write burst capture ─────────────────────────────────────────────────────
  logic        wr_busy;
  logic [23:0] wr_base;
  logic [3:0]  wr_i;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [23:0] wr_lin;
  /* verilator lint_on  UNUSEDSIGNAL */
  assign       wr_lin = wr_base + 24'(wr_i);

  // ── Read burst injection into the CAS-latency pipeline ──────────────────────
  logic        rd_busy;
  logic [23:0] rd_base;
  logic [3:0]  rd_i;

  localparam int RD_STAGES = CAS_LATENCY;
  logic [15:0] rd_dat [0:RD_STAGES-1];
  logic        rd_vld [0:RD_STAGES-1];

  // what to inject into pipeline stage 0 this cycle
  logic        inj_vld;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [23:0] inj_addr;
  /* verilator lint_on  UNUSEDSIGNAL */
  always_comb begin
    inj_vld  = 1'b0;
    inj_addr = 24'd0;
    if (is_read)      begin inj_vld = 1'b1; inj_addr = lin_base; end
    else if (rd_busy) begin inj_vld = 1'b1; inj_addr = rd_base + 24'(rd_i); end
  end

  integer i;
  always_ff @(posedge clk) begin
    if (is_active) open_row[ba] <= a[12:0];

    // ── writes ────────────────────────────────────────────────────────────────
    if (is_write) begin
      if (!dqm[0]) mem[lin_base[MODEL_AW-1:0]][7:0]  <= dq_in[7:0];
      if (!dqm[1]) mem[lin_base[MODEL_AW-1:0]][15:8] <= dq_in[15:8];
      wr_busy <= (BURST_LEN > 1);
      wr_base <= lin_base;
      wr_i    <= 4'd1;
    end else if (wr_busy) begin
      if (!dqm[0]) mem[wr_lin[MODEL_AW-1:0]][7:0]  <= dq_in[7:0];
      if (!dqm[1]) mem[wr_lin[MODEL_AW-1:0]][15:8] <= dq_in[15:8];
      if (wr_i == LAST_I) wr_busy <= 1'b0;
      wr_i <= wr_i + 4'd1;
    end

    // ── read burst bookkeeping ────────────────────────────────────────────────
    if (is_read) begin
      rd_busy <= (BURST_LEN > 1);
      rd_base <= lin_base;
      rd_i    <= 4'd1;
    end else if (rd_busy) begin
      if (rd_i == LAST_I) rd_busy <= 1'b0;
      rd_i <= rd_i + 4'd1;
    end

    // ── CAS-latency pipeline (stage 0 = newest) ───────────────────────────────
    rd_vld[0] <= inj_vld;
    rd_dat[0] <= mem[inj_addr[MODEL_AW-1:0]];
    for (i = 1; i < RD_STAGES; i = i + 1) begin
      rd_vld[i] <= rd_vld[i-1];
      rd_dat[i] <= rd_dat[i-1];
    end
  end

  assign dq_out = rd_vld[RD_STAGES-1] ? rd_dat[RD_STAGES-1] : 16'h0000;

  initial begin
    for (i = 0; i < (1<<MODEL_AW); i = i + 1) mem[i] = 16'h0000;
    for (i = 0; i < 4; i = i + 1) open_row[i] = 13'd0;
    for (i = 0; i < RD_STAGES; i = i + 1) rd_vld[i] = 1'b0;
    wr_busy = 1'b0;
    rd_busy = 1'b0;
  end

endmodule
