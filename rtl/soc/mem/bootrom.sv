// =============================================================================
// PHANTOM-32  ──  Boot ROM  (UART bootloader, fetch-side)
// =============================================================================
// Small single-EBR instruction ROM holding UART bootloader
// (programs/bootloader.S, assembled to INIT_FILE at build time).
//
// The CPU comes out of reset here, receives the program over UART into SDRAM,
// then jumps to address 0.
module bootrom #(
  parameter         INIT_FILE = "bootrom.hex",
  parameter integer N_WORDS   = 64
) (
  input  logic        clk,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:0] addr,
  /* verilator lint_on  UNUSEDSIGNAL */
  output logic [31:0] data
);

  localparam integer AW = (N_WORDS <= 1) ? 1 : $clog2(N_WORDS);

  (* ram_style = "block" *) logic [31:0] rom [0:N_WORDS-1];
  initial if (INIT_FILE != "") $readmemh(INIT_FILE, rom);

  // ── 2-cycle pipelined read (EBR sync read -> output reg) ───────────────────
  logic [31:0] rom_data;
  always_ff @(posedge clk) begin
    rom_data <= rom[addr[AW+1:2]];
    data     <= rom_data;
  end

endmodule

