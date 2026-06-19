`include "isa.vh"

module tb_core #(
  parameter int IMEM_WAIT = 0 // 0 = BRAM-like always-ready; >0 = inject N fetch-stall cycles
) (
  input logic clk,
  input logic resetn
);
  logic [31:0] imem_addr, dmem_rdata, dmem_wdata;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] dmem_raddr;
  logic [31:0] dmem_waddr;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [31:0] imem_data;
  logic [3:0]  dmem_be;
  logic        dmem_we;
  /* verilator lint_off UNUSEDSIGNAL */
  logic        dmem_req;
  /* verilator lint_on  UNUSEDSIGNAL */
 
  logic [7:0] mem [0:65535];
  initial begin
    $readmemh("program.hex", mem);
  end

  // cycle counter (for IPC measurement; harmless extra $display at $finish)
  logic [31:0] cycle_count;
  always_ff @(posedge clk) cycle_count <= resetn ? cycle_count + 1 : 32'd0;

  phantom_core dut (
    .clk     (clk),
    .resetn  (resetn),
    .imem_addr   (imem_addr),
    .imem_data   (imem_data),
    .imem_ready  (imem_ready),
    .dmem_raddr  (dmem_raddr),
    .dmem_waddr  (dmem_waddr),
    .dmem_wdata  (dmem_wdata),
    .dmem_we     (dmem_we),
    .dmem_be     (dmem_be),
    .dmem_rdata  (dmem_rdata),
    .dmem_req    (dmem_req),
    .dmem_ready  (1'b1),
    .irq_timer   (1'b0),
    .irq_soft    (1'b0),
    .irq_ext     (1'b0)
  );

  always_ff @(posedge clk) begin
    imem_data <= {
      mem[imem_addr + 3], mem[imem_addr + 2],
      mem[imem_addr + 1], mem[imem_addr]
    };
  end

  // ── Fetch-ready model ──────────────────────────────────────────────────────
  logic       imem_ready;
  logic [7:0] wctr;
  logic       ready_pulse;
  always_ff @(posedge clk) begin
    if (!resetn) begin
      wctr        <= IMEM_WAIT[7:0];
      ready_pulse <= 1'b0;
    end else if (ready_pulse) begin
      ready_pulse <= 1'b0;
      wctr        <= IMEM_WAIT[7:0];
    end else if (wctr == 8'd0) begin
      ready_pulse <= 1'b1;
    end else begin
      wctr        <= wctr - 8'd1;
    end
  end
  assign imem_ready = (IMEM_WAIT == 0) ? 1'b1 : ready_pulse;

  logic [31:0] dmem_raddr_aligned;
  always_ff @(posedge clk) begin
    dmem_raddr_aligned      <= {dmem_raddr[31:2], 2'b00};
  end

  assign dmem_rdata = {mem[dmem_raddr_aligned + 3],   mem[dmem_raddr_aligned + 2],
                       mem[dmem_raddr_aligned + 1],   mem[dmem_raddr_aligned]};

  logic [31:0] dmem_waddr_aligned;
  assign dmem_waddr_aligned = {dmem_waddr[31:2], 2'b00};

  always_ff @(posedge clk) begin
    if (dmem_we) begin
      if (dmem_be[0]) mem[dmem_waddr_aligned]     <= dmem_wdata[7:0];
      if (dmem_be[1]) mem[dmem_waddr_aligned + 1] <= dmem_wdata[15:8];
      if (dmem_be[2]) mem[dmem_waddr_aligned + 2] <= dmem_wdata[23:16];
      if (dmem_be[3]) mem[dmem_waddr_aligned + 3] <= dmem_wdata[31:24];

      if (dmem_waddr_aligned == 32'h80001000) begin
        $display("Simulation Finished. Result: %h", dmem_wdata);
        $display("Cycles: %0d", cycle_count);
        $finish;
      end
    end
  end
endmodule

