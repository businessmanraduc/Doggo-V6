`include "isa.vh"

module tb_irq (
  input logic clk,
  input logic resetn
);

  logic [7:0] mem [0:65535];
  initial begin
    $readmemh("irq.hex", mem);
  end

  logic [31:0] imem_addr_a, imem_addr_b;
  logic [15:0] imem_data_a, imem_data_b;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] dmem_raddr;   // low 2 bits unused (word-aligned BSRAM access)
  logic [31:0] dmem_waddr;   // low 2 bits unused (word-aligned writes)
  /* verilator lint_on  UNUSEDSIGNAL */
  logic [31:0] dmem_wdata;
  logic [31:0] dmem_rdata;
  logic [3:0]  dmem_be;
  logic        dmem_we;
  logic        irq_timer, irq_soft;

  logic addr_is_periph; assign addr_is_periph = dmem_waddr[31];
  logic clint_sel;      assign clint_sel      = (dmem_waddr[31:16] == 16'h8001);
  logic [31:0] clint_rdata;

  logic [31:0] dmem_raddr_aligned;
  always_ff @(posedge clk) begin
    dmem_raddr_aligned <= {dmem_raddr[31:2], 2'b00};
  end

  logic [31:0] bsram_rdata;
  assign bsram_rdata = {mem[dmem_raddr_aligned + 3], mem[dmem_raddr_aligned + 2],
                        mem[dmem_raddr_aligned + 1], mem[dmem_raddr_aligned]};

  assign dmem_rdata = addr_is_periph ? clint_rdata : bsram_rdata;

  logic [31:0] dmem_waddr_aligned; assign dmem_waddr_aligned = {dmem_waddr[31:2], 2'b00};

  always_ff @(posedge clk) begin
    if (dmem_we && !addr_is_periph) begin
      if (dmem_be[0]) mem[dmem_waddr_aligned]     <= dmem_wdata[7:0];
      if (dmem_be[1]) mem[dmem_waddr_aligned + 1] <= dmem_wdata[15:8];
      if (dmem_be[2]) mem[dmem_waddr_aligned + 2] <= dmem_wdata[23:16];
      if (dmem_be[3]) mem[dmem_waddr_aligned + 3] <= dmem_wdata[31:24];
    end

    if (resetn && dut.irq_take)
      $display("[IRQ] timer interrupt taken: mepc=%08h mcause=%08h (mtime=%0d mtimecmp=%0d)",
               dut.ex_ma_pc, dut.trap_mcause, u_clint.r_mtime[31:0], u_clint.r_mtimecmp[31:0]);
    if (dmem_we && (dmem_waddr_aligned == 32'h80001000)) begin
      $display("IRQ Test Finished. Result: %0d", dmem_wdata);
      $finish;
    end
  end

  phantom_core dut (
    .clk         (clk),
    .resetn      (resetn),
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
    .irq_timer   (irq_timer),
    .irq_soft    (irq_soft),
    .irq_ext     (1'b0)
  );

  always_ff @(posedge clk) begin
    imem_data_a <= {mem[imem_addr_a + 1], mem[imem_addr_a]};
    imem_data_b <= {mem[imem_addr_b + 1], mem[imem_addr_b]};
  end

  clint #(
    .CLK_HZ  (50),
    .TICK_HZ (1)
  ) u_clint (
    .clk     (clk),
    .resetn  (resetn),
    .sel     (clint_sel),
    .offset  (dmem_waddr[15:0]),
    .we      (dmem_we && addr_is_periph),
    .be      (dmem_be),
    .wdata   (dmem_wdata),
    .rdata   (clint_rdata),
    .mtip    (irq_timer),
    .msip    (irq_soft)
  );

endmodule
