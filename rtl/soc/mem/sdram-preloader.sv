// =============================================================================
// PHANTOM-32  ──  SDRAM Preloader + read-back verify  (FPGA boot)
// =============================================================================
// FSM that copies a payload (config-initialised BRAM) into SDRAM while the CPU
// is held in reset, then reads it back and checks it against the source.
// `done` releases the CPU; `verify_ok` says the round trip matched
// (so a failure points straight at the SDRAM read path on silicon).
//
// Drives a single-word read/write port muxed in front of the SDRAM adapter.
// Word i lives at SDRAM byte offset i*4 (= where PC i*4 is fetched).
// =============================================================================
module sdram_preloader #(
  parameter          INIT_FILE = "",
  parameter integer  N_WORDS   = 256
) (
  input  logic        clk,
  input  logic        resetn,

  // ── Read/write port to the SDRAM adapter (valid while `active`) ────────────
  output logic [31:0] ld_addr,
  output logic        ld_req,
  output logic        ld_we,             // 1 = copy (write), 0 = verify (read)
  output logic [31:0] ld_wdata,
  output logic [3:0]  ld_be,
  input  logic [31:0] ld_rdata,          // adapter cpu_rdata (verify reads)
  input  logic        ld_ready,          // adapter cpu_ready

  // ── Boot control / status ──────────────────────────────────────────────────
  output logic        active,            // 1 = mux the adapter to the loader
  output logic        done,              // 1 = load + verify complete
  output logic        verify_ok          // 1 = every read-back matched the source
);

  localparam integer AW = (N_WORDS <= 1) ? 1 : $clog2(N_WORDS);

  (* ram_style = "block" *) logic [31:0] rom [0:N_WORDS-1];
  initial if (INIT_FILE != "") $readmemh(INIT_FILE, rom);

  typedef enum logic[1:0] {LD_COPY, LD_VERIFY, LD_DONE } ls_t;
  ls_t         state;
  logic [AW:0] idx;

  // ── Pipelined ROM read ──────────────────────────────────────────────────────
  logic [31:0] rom_data;    // EBR synchronous read
  logic [31:0] rom_word;    // EBR output register (feeds ld_wdata + verify)
  logic [1:0]  warm;        // request warm-up shifter (cleared on idx step)

  always_ff @(posedge clk) begin
    rom_data <= rom[idx[AW-1:0]];
    rom_word <= rom_data;
  end

  // ── Registered verify compare ───────────────────────────────────────────────
  logic        vf_pending;  // 1 = captured read-back awaits compare
  logic [31:0] vf_rdata;    // captured read-back word

  // done is delayed 2 cycles so the last registered compare settles into
  // verify_ok before the reset sequencer samples done && verify_ok.
  logic [1:0]  done_q;

  assign active   = (state == LD_COPY) || (state == LD_VERIFY);
  assign done     = done_q[1];
  assign ld_req   = active && warm[1];
  assign ld_we    = (state == LD_COPY);
  assign ld_be    = 4'hF;
  assign ld_addr  = {{(30-AW){1'b0}}, idx[AW-1:0], 2'b00};
  assign ld_wdata = rom_word;

  always_ff @(posedge clk) begin
    if (!resetn) begin
      state      <= LD_COPY; idx <= '0; verify_ok <= 1'b1;
      warm       <= 2'b00;
      vf_pending <= 1'b0;
      done_q     <= 2'b00;
    end else begin
      warm       <= {warm[0], 1'b1};
      vf_pending <= 1'b0;
      done_q     <= {done_q[0], (state == LD_DONE)};

      if (vf_pending && (vf_rdata != rom_word)) verify_ok <= 1'b0;

      if (ld_ready && active) begin
        if (state == LD_VERIFY) begin
          vf_rdata   <= ld_rdata;
          vf_pending <= 1'b1;
        end
        warm <= 2'b00;                     // idx steps -> rom_word goes stale
        if (idx == (AW+1)'(N_WORDS-1)) begin
          idx   <= '0;
          state <= (state == LD_COPY) ? LD_VERIFY : LD_DONE;
        end else begin
          idx   <= idx + (AW+1)'(1);
        end
      end
    end
  end

endmodule
