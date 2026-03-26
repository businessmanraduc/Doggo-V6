// =============================================================================
// PHANTOM-16  ──  System-on-Chip
// =============================================================================
// Connects the CPU to instruction memory (ROM) and data memory (RAM).
//
// Memory map (word-addressed, 16-bit words):
//   IMEM  0x00–0xFF   256 words = 512 bytes  (instruction ROM)
//   DMEM  0x00–0xFF   256 words = 512 bytes  (data RAM, separate address space)
//
// Memories use async (combinational) reads for simplicity.  On a Gowin FPGA
// these will be synthesised as LUT-RAM or BRAM depending on the tool version;
// for production use add (* ram_style = "block" *) pragmas if needed.
//
// The instruction ROM is initialised from "program.hex" via $readmemh — this
// is supported both in simulation and by Gowin synthesis (BRAM init).
// =============================================================================

module soc (
    input  wire clk,
    input  wire resetn,
    output wire halted    // high when the HALT instruction retires
);

// ── CPU ───────────────────────────────────────────────────────────────────────
wire [7:0]  imem_addr;
wire [15:0] imem_data;
wire [7:0]  DataMem_Addr;
wire [15:0] DataMem_WriteData;
wire        DataMem_WriteEnable;
wire [15:0] dmem_rdata;

cpu u_cpu (
    .clk        (clk),
    .resetn     (resetn),
    .imem_addr  (imem_addr),
    .imem_data  (imem_data),
    .DataMem_Addr  (DataMem_Addr),
    .DataMem_WriteData (DataMem_WriteData),
    .DataMem_WriteEnable    (DataMem_WriteEnable),
    .dmem_rdata (dmem_rdata),
    .halted     (halted)
);

// ── Instruction Memory (ROM, 256 × 16-bit) ────────────────────────────────────
// Initialised from program.hex at simulation start and synthesis time.
// The `initial` block with $readmemh is the standard way to initialise
// BRAM on Gowin and other FPGA families.
reg [15:0] imem [0:255];
initial $readmemh("program.hex", imem);
assign imem_data = imem[imem_addr];   // combinational (async) read

// ── Data Memory (RAM, 256 × 16-bit) ───────────────────────────────────────────
// Async read, synchronous write (standard FPGA RAM pattern).
reg [15:0] dmem [0:255];
integer i;
initial begin
    for (i = 0; i < 256; i = i + 1)
        dmem[i] = 16'h0;
end

assign dmem_rdata = dmem[DataMem_Addr];                 // async read

always @(posedge clk) begin
    if (DataMem_WriteEnable)
        dmem[DataMem_Addr] <= DataMem_WriteData;               // sync write (SW)
end

endmodule
