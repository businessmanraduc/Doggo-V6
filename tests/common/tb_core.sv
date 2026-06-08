`include "isa.vh"

module tb_core (
  input logic clk,
  input logic resetn
);
  logic [31:0] imem_addr_a, imem_addr_b, dmem_rdata, dmem_wdata;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] dmem_raddr;
  logic [31:0] dmem_waddr;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [15:0] imem_data_a, imem_data_b;
  logic [3:0]  dmem_be;
  logic        dmem_we;
  /* verilator lint_off UNUSEDSIGNAL */
  logic        dmem_req;
  /* verilator lint_on  UNUSEDSIGNAL */
 
  logic [7:0] mem [0:65535];
  initial begin
    $readmemh("program.hex", mem);
  end

  phantom_core dut (
    .clk     (clk),
    .resetn  (resetn),
    .imem_addr_a (imem_addr_a),
    .imem_addr_b (imem_addr_b),
    .imem_data_a (imem_data_a),
    .imem_data_b (imem_data_b),
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
    imem_data_a <= {mem[imem_addr_a + 1], mem[imem_addr_a]};
    imem_data_b <= {mem[imem_addr_b + 1], mem[imem_addr_b]};
  end

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
        $finish;
      end
    end
  end
endmodule

