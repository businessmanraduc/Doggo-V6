// =============================================================================
// PHANTOM-32  ──  CLINT  (Core-Local Interruptor)
// =============================================================================
// Machine timer + software interrupt, SiFive-compatible register offsets
// relative to the CLINT base:
//   +0x0000  msip      (bit 0 = machine software interrupt pending)
//   +0x4000  mtimecmp  low 32   +0x4004  mtimecmp high 32
//   +0xBFF8  mtime     low 32   +0xBFFC  mtime    high 32   (read-only)
//
// mtime is free-running at TICK_HZ (prescaled from clk). mtimecmp + msip are
// software-writable. The comparator drives mtip; r_msip drives msip; 
// both feed the core's mip bits.
// =============================================================================
module clint #(
  parameter integer CLK_HZ  = 50_000_000,
  parameter integer TICK_HZ =  1_000_000
) (
  input  logic        clk,
  input  logic        resetn,

  // ── Register access (already address-decoded to this CLINT) ────────────────
  input  logic        sel,          // 1 = access targets the CLINT
  input  logic [15:0] offset,       // byte offset within the CLINT window
  input  logic        we,           // write enable
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [3:0]  be,           // byte enables (only be[0] used, for msip)
  /* verilator lint_on  UNUSEDSIGNAL */
  input  logic [31:0] wdata,
  output logic [31:0] rdata,        // combinational read data

  // ── Interrupt outputs to the core ──────────────────────────────────────────
  output logic        mtip,         // timer    interrupt pending (mtime >= mtimecmp)
  output logic        msip          // software interrupt pending
);

  localparam integer PRESCALE = CLK_HZ / TICK_HZ;
  localparam integer PRESC_W  = (PRESCALE <= 1) ? 1 : $clog2(PRESCALE);

  logic [PRESC_W-1:0] r_presc;
  logic [63:0]        r_mtime;
  logic [63:0]        r_mtimecmp;
  logic               r_msip;
  logic               r_mtip;

  // ── mtime: free-running counter at TICK_HZ, read-only to software ────────────
  always_ff @(posedge clk) begin
    if (!resetn) begin
      r_presc <= '0;
      r_mtime <= 64'd0;
    end else if (r_presc == PRESC_W'(PRESCALE-1)) begin
      r_presc <= '0;
      r_mtime <= r_mtime + 64'd1;
    end else begin
      r_presc <= r_presc + 1'b1;
    end
  end

  // ── mtimecmp + msip: software-writable (word-granular) ───────────────────────
  always_ff @(posedge clk) begin
    if (!resetn) begin
      r_mtimecmp <= 64'hFFFF_FFFF_FFFF_FFFF;
      r_msip     <= 1'b0;
    end else if (sel && we) begin
      case (offset)
        16'h0000: if (be[0]) r_msip <= wdata[0];
        16'h4000: r_mtimecmp[31:0]  <= wdata;
        16'h4004: r_mtimecmp[63:32] <= wdata;
        default: ;
      endcase
    end
  end

  // ── Combinational read ───────────────────────────────────────────────────────
  always_comb begin
    rdata = 32'd0;
    if (sel) begin
      case (offset)
        16'h0000: rdata = {31'b0, r_msip};
        16'h4000: rdata = r_mtimecmp[31:0];
        16'h4004: rdata = r_mtimecmp[63:32];
        16'hBFF8: rdata = r_mtime[31:0];
        16'hBFFC: rdata = r_mtime[63:32];
        default:  rdata = 32'd0;
      endcase
    end
  end

  // ── Interrupt outputs ─────────────────────────────────────────────────────────
  always_ff @(posedge clk) begin
    if (!resetn) r_mtip <= 1'b0;
    else         r_mtip <= (r_mtime >= r_mtimecmp);
  end
  assign mtip = r_mtip;
  assign msip = r_msip;

endmodule

