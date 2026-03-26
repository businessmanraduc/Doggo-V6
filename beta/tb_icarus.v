`timescale 1ns / 1ps
// =============================================================================
// PHANTOM-16  ──  Icarus Verilog Testbench
// =============================================================================
// Instantiates the full SoC, runs it to HALT, then checks register/memory
// state against known-good values from the demo program.
//
// Run:
//   iverilog -g2012 -o sim tb_icarus.v soc.v cpu.v alu.v
//   vvp sim
//   gtkwave dump.vcd
// =============================================================================

module tb_icarus;

    // ── Clock ─────────────────────────────────────────────────────────────────
    localparam CLK_HALF = 5;   // 5 ns half-period → 100 MHz
    reg clk = 0;
    always #CLK_HALF clk = ~clk;

    // ── Reset ─────────────────────────────────────────────────────────────────
    reg resetn;

    // ── DUT ───────────────────────────────────────────────────────────────────
    wire halted;
    soc dut (
        .clk    (clk),
        .resetn (resetn),
        .halted (halted)
    );

    // ── Waveform capture ──────────────────────────────────────────────────────
    initial begin
        $dumpfile("dump.vcd");
        $dumpvars(0, tb_icarus);
    end

    // ── Assertion helper ──────────────────────────────────────────────────────
    integer pass_cnt = 0;
    integer fail_cnt = 0;

    task check16;
        input [15:0] actual;
        input [15:0] expected;
        input [127:0] name;
        begin
            if (actual === expected) begin
                $display("  PASS  %-16s  got 0x%04h", name, actual);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL  %-16s  got 0x%04h  expected 0x%04h  <---",
                         name, actual, expected);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    // ── Main test sequence ────────────────────────────────────────────────────
    integer timeout;

    initial begin
        // Apply reset for 4 cycles
        resetn = 0;
        repeat (4) @(posedge clk);
        resetn = 1;

        // Run until HALT (or timeout)
        timeout = 0;
        while (!halted && timeout < 2000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end

        // One extra cycle so WB completes
        @(posedge clk);
        #1; // let combinational outputs settle

        // ── Assertions ───────────────────────────────────────────────────────
        $display("");
        $display("=== PHANTOM-16 Post-halt register check ===");

        // R0 must always be zero (hardwired)
        check16(dut.u_cpu.regFile[0], 16'd0,  "R0 = 0");

        // R1 = 0 (loop counter ran down to zero)
        check16(dut.u_cpu.regFile[1], 16'd0,  "R1 = 0 (counter)");

        // R2 = 15 = 1+2+3+4+5 (sum accumulator)
        check16(dut.u_cpu.regFile[2], 16'd15, "R2 = 15 (sum)");

        // R3 = 1 (constant, must be unchanged)
        check16(dut.u_cpu.regFile[3], 16'd1,  "R3 = 1 (const)");

        // R4 = 0 (memory base address)
        check16(dut.u_cpu.regFile[4], 16'd0,  "R4 = 0 (membase)");

        // R5 = 15 (loaded back from dmem[0] — tests SW + LW round-trip)
        check16(dut.u_cpu.regFile[5], 16'd15, "R5 = 15 (load)");

        // dmem[0] = 15 (stored by SW)
        check16(dut.dmem[0],       16'd15, "dmem[0] = 15");

        // Halted flag must be set
        if (halted)
            $display("  PASS  %-16s  CPU halted cleanly", "halted");
        else begin
            $display("  FAIL  %-16s  CPU did not halt within timeout!", "halted");
            fail_cnt = fail_cnt + 1;
        end

        // ── Summary ──────────────────────────────────────────────────────────
        $display("");
        $display("=== Results: %0d passed, %0d failed  (in %0d cycles) ===",
                 pass_cnt, fail_cnt, timeout);
        if (fail_cnt == 0)
            $display("    ALL TESTS PASSED  \\o/");
        else
            $display("    *** FAILURES DETECTED ***");
        $display("");

        $finish;
    end

    // ── Timeout watchdog ──────────────────────────────────────────────────────
    initial begin
        #(CLK_HALF * 2 * 5000);
        $display("TIMEOUT: simulation exceeded 5000 cycles without HALT");
        $finish;
    end

endmodule
