`include "isa.vh"

module tb_cpu (
  input logic clk,
  input logic resetn
);
  logic [31:0] imem_addr_a, imem_addr_b, dmem_wdata, dmem_rdata;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] dmem_addr;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [15:0] imem_data_a, imem_data_b;
  logic [3:0]  dmem_be;
  logic        dmem_we;

  logic [7:0] mem [0:65535];
  initial begin
    $readmemh("program.hex", mem);
  end

  cpu dut (
    .clk     (clk),
    .resetn  (resetn),
    .imem_addr_a (imem_addr_a),
    .imem_addr_b (imem_addr_b),
    .imem_data_a (imem_data_a),
    .imem_data_b (imem_data_b),
    .dmem_addr   (dmem_addr),
    .dmem_wdata  (dmem_wdata),
    .dmem_we     (dmem_we),
    .dmem_be     (dmem_be),
    .dmem_rdata  (dmem_rdata)
  );

  always_ff @(posedge clk) begin
    imem_data_a <= {mem[imem_addr_a + 1], mem[imem_addr_a]};
    imem_data_b <= {mem[imem_addr_b + 1], mem[imem_addr_b]};
  end

  logic [31:0] dmem_raddr;
  always_ff @(posedge clk) begin
    dmem_raddr <= {dmem_addr[31:2], 2'b00};
  end

  assign dmem_rdata  = {mem[dmem_raddr + 3],   mem[dmem_raddr + 2],
                        mem[dmem_raddr + 1],   mem[dmem_raddr]};

  always_ff @(posedge clk) begin
    if (dmem_we) begin
      if (dmem_be[0]) mem[dmem_raddr]     <= dmem_wdata[7:0];
      if (dmem_be[1]) mem[dmem_raddr + 1] <= dmem_wdata[15:8];
      if (dmem_be[2]) mem[dmem_raddr + 2] <= dmem_wdata[23:16];
      if (dmem_be[3]) mem[dmem_raddr + 3] <= dmem_wdata[31:24];

      if (dmem_raddr == 32'h80001000) begin
        $display("Simulation Finished. Result: %h", dmem_wdata);
        $finish;
      end
    end
  end
endmodule

