// SPDX-License-Identifier: Apache-2.0
//
// BUG-032 directed witness: the SHA-256 DIGEST hardware-clear strobe is driven
// from an inverted signal, so the window is pinned to zero in the normal
// debug-locked state and is NOT cleared on a debug-unlock or scan-mode transition.
//
// Property under test: src/sha256/rtl/sha256_reg.rdl:135 gives the DIGEST field a
// hwclr, and the tree fans debugUnlock_or_scan_mode_switch into nine crypto blocks
// so that a result left in a register window is wiped when the device transitions
// into a state where that window becomes observable. The Caliptra Hardware
// Specification additionally requires the digest to be readable once all message
// chunks are processed.
//
// src/sha256/rtl/sha256.sv:388-391 forms two strobes, and the second reduces to
// ZEROIZE | ~debugUnlock_or_scan_mode_switch. Line 403 drives the DIGEST hwclr from
// that second strobe. src/sha256/rtl/sha256_reg.sv:726-731 gives hwclr priority over
// the unconditional hardware write, so the polarity of that one term decides whether
// the window tracks digest_reg or is held at zero.
//
// This testbench drives the real sha256 block with its own generated register file
// through the module's own cs/we/address bus. It seeds a genuine digest by running a
// hash, then reports what the window reads in each state. There is no force, no
// deposit and no hierarchical assignment anywhere in this harness.
//
`timescale 1ns/1ps

module sha256_bug_032_tb;

  localparam int unsigned CLK_HALF = 5;

  // Register offsets, from src/sha256/rtl/sha256_reg.rdl.
  localparam logic [31:0] ADDR_CTRL   = 32'h0000_0010;
  localparam logic [31:0] ADDR_STATUS = 32'h0000_0018;
  localparam logic [31:0] ADDR_BLOCK0 = 32'h0000_0080;
  localparam logic [31:0] ADDR_DIG0   = 32'h0000_0100;

  // CTRL bit positions, from caliptra_reg_field_defines.svh:6053-6060.
  localparam int unsigned CTRL_INIT    = 0;
  localparam int unsigned CTRL_NEXT    = 1;
  localparam int unsigned CTRL_MODE    = 2;
  localparam int unsigned CTRL_ZEROIZE = 3;
  // STATUS bits, from the same header at :6070-6073.
  localparam int unsigned ST_READY = 0;
  localparam int unsigned ST_VALID = 1;

  logic clk, reset_n, cptra_pwrgood;
  logic cs, we;
  logic [31:0] address, write_data, read_data;
  logic err, error_intr, notif_intr;
  logic debug_or_scan;

  int unsigned checks, fails;
  int unsigned cov_digest_readable_when_quiet;
  int unsigned cov_digest_survives_debug_entry;
  int unsigned cov_digest_exposed_under_wipe;
  int unsigned cov_sw_zeroize_clears;
  logic [31:0] dig_quiet   [0:7];
  logic [31:0] dig_debug   [0:7];
  logic [31:0] dig_exposed [0:7];
  logic [31:0] dig_zeroize [0:7];

  sha256 dut (
    .clk    (clk),
    .reset_n(reset_n),
    .cptra_pwrgood(cptra_pwrgood),
    .cs     (cs),
    .we     (we),
    .address(address),
    .write_data(write_data),
    .read_data(read_data),
    .err    (err),
    .error_intr(error_intr),
    .notif_intr(notif_intr),
    .debugUnlock_or_scan_mode_switch(debug_or_scan)
  );

  initial clk = 1'b0;
  always #CLK_HALF clk = ~clk;

  task automatic step(input int unsigned n);
    for (int unsigned i = 0; i < n; i++) @(posedge clk);
  endtask

  task automatic bus_write(input logic [31:0] a, input logic [31:0] d);
    @(negedge clk);
    cs = 1'b1; we = 1'b1; address = a; write_data = d;
    @(negedge clk);
    cs = 1'b0; we = 1'b0; address = '0; write_data = '0;
  endtask

  task automatic bus_read(input logic [31:0] a, output logic [31:0] d);
    @(negedge clk);
    cs = 1'b1; we = 1'b0; address = a;
    @(posedge clk);
    #1 d = read_data;
    @(negedge clk);
    cs = 1'b0; address = '0;
  endtask

  task automatic read_digest(output logic [31:0] w [0:7]);
    logic [31:0] d;
    for (int i = 0; i < 8; i++) begin
      bus_read(ADDR_DIG0 + i*4, d);
      w[i] = d;
    end
  endtask

  function automatic bit any_nonzero(input logic [31:0] w [0:7]);
    any_nonzero = 1'b0;
    for (int i = 0; i < 8; i++) if (w[i] !== 32'h0) any_nonzero = 1'b1;
  endfunction

  task automatic show(input string tag, input logic [31:0] w [0:7]);
    $display("      %s: %08x %08x %08x %08x %08x %08x %08x %08x",
             tag, w[0], w[1], w[2], w[3], w[4], w[5], w[6], w[7]);
  endtask

  task automatic record(input string name, input bit ok, input string what);
    checks++;
    if (ok) $display("  case=%s PASS %s", name, what);
    else begin
      fails++;
      $display("  TBFAIL case=%s %s", name, what);
    end
  endtask

  // Load a fixed one-block message and run a SHA-256 hash to completion.
  task automatic run_hash();
    logic [31:0] st;
    // "abc" with SHA-256 padding, the standard one-block vector.
    bus_write(ADDR_BLOCK0 + 0*4, 32'h6162_6380);
    for (int i = 1; i < 15; i++) bus_write(ADDR_BLOCK0 + i*4, 32'h0000_0000);
    bus_write(ADDR_BLOCK0 + 15*4, 32'h0000_0018);
    // MODE=1 selects SHA-256; INIT starts a fresh hash.
    bus_write(ADDR_CTRL, (32'h1 << CTRL_MODE) | (32'h1 << CTRL_INIT));
    for (int unsigned i = 0; i < 500; i++) begin
      bus_read(ADDR_STATUS, st);
      if (st[ST_VALID]) break;
    end
    $display("      status after hash: READY=%0b VALID=%0b", st[ST_READY], st[ST_VALID]);
  endtask

  initial begin
    checks = 0; fails = 0;
    cov_digest_readable_when_quiet   = 0;
    cov_digest_survives_debug_entry  = 0;
    cov_digest_exposed_under_wipe    = 0;
    cov_sw_zeroize_clears            = 0;

    cs = 0; we = 0; address = '0; write_data = '0;
    debug_or_scan = 1'b0;
    reset_n = 1'b0; cptra_pwrgood = 1'b0;
    step(5);
    cptra_pwrgood = 1'b1;
    reset_n = 1'b1;
    step(5);

    $display("===== BUG-032 directed witness: SHA-256 DIGEST hwclr polarity =====");

    // ---- case 1: normal debug-locked operation. debug_or_scan is a transition
    // pulse (caliptra_top.sv:763-770), so 0 is its steady-state value. After a
    // completed hash the specification requires the digest to be readable.
    $display("--- quiescent_digest_readable (debug_or_scan=0, no software zeroize) ---");
    debug_or_scan = 1'b0;
    run_hash();
    read_digest(dig_quiet);
    show("digest", dig_quiet);
    if (any_nonzero(dig_quiet)) cov_digest_readable_when_quiet++;
    else
      $display("      OBSERVED: BUG_032_WITNESS_OBSERVED digest window reads all-zero after a completed hash in the normal debug-locked state");
    record("quiescent_digest_readable", any_nonzero(dig_quiet),
           "a completed digest must be readable while no cleanup is requested");

    // ---- case 2: assert the debug/scan transition with no software zeroize.
    // This is the case the wipe exists to cover.
    $display("--- debug_entry_wipe (debug_or_scan=1, no software zeroize) ---");
    debug_or_scan = 1'b1;
    step(4);
    read_digest(dig_debug);
    show("digest", dig_debug);
    if (any_nonzero(dig_debug)) begin
      cov_digest_survives_debug_entry++;
      $display("      OBSERVED: BUG_032_WITNESS_OBSERVED digest window still non-zero while the debug/scan transition is asserted");
    end
    debug_or_scan = 1'b0;
    step(2);

    // ---- case 3: containment. Releasing hwclr on the transition could in
    // principle let the window latch digest_reg, so probe for that directly
    // instead of assuming it away. Run a real hash with the switch low, then
    // pulse the switch for one cycle (its real shape: caliptra_top.sv:763-770
    // edge-detects it) and read the window afterwards.
    $display("--- containment_transition_pulse_not_readable (1-cycle debug_or_scan pulse) ---");
    run_hash();
    @(negedge clk);
    debug_or_scan = 1'b1;
    @(negedge clk);
    debug_or_scan = 1'b0;
    read_digest(dig_exposed);
    show("digest", dig_exposed);
    if (any_nonzero(dig_exposed)) begin
      cov_digest_exposed_under_wipe++;
      $display("      OBSERVED: digest window read non-zero after the transition pulse");
    end
    record("containment_transition_pulse_not_readable", !any_nonzero(dig_exposed),
           "no digest material is left readable after the transition pulse");
    step(4);

    // ---- case 4: software ZEROIZE with debug_or_scan low. This must clear.
    $display("--- sw_zeroize_clears (debug_or_scan=0, ZEROIZE written) ---");
    run_hash();
    bus_write(ADDR_CTRL, (32'h1 << CTRL_ZEROIZE));
    step(4);
    read_digest(dig_zeroize);
    show("digest", dig_zeroize);
    if (!any_nonzero(dig_zeroize)) cov_sw_zeroize_clears++;
    record("sw_zeroize_clears", !any_nonzero(dig_zeroize),
           "a software ZEROIZE must leave the digest window clear");

    $display("");
    $display("cov_digest_readable_when_quiet=%0d",  cov_digest_readable_when_quiet);
    $display("cov_digest_survives_debug_entry=%0d", cov_digest_survives_debug_entry);
    $display("cov_digest_exposed_under_wipe=%0d",   cov_digest_exposed_under_wipe);
    $display("cov_sw_zeroize_clears=%0d",           cov_sw_zeroize_clears);
    $display("checks=%0d fails=%0d", checks, fails);

    // On the audited RTL the expected outcome is one failing check: the digest
    // window is unreadable after a completed hash in the normal operating state.
    // The containment probe and the software-ZEROIZE path both pass, which is
    // what confines this to an availability defect rather than a disclosure.
    if (checks == 3 && fails == 1 &&
        cov_digest_readable_when_quiet == 0 &&
        cov_digest_exposed_under_wipe == 0 &&
        cov_sw_zeroize_clears == 1) begin
      $display("result=PASS");
      $display("PROOF_RESULT: PASS");
    end
    else begin
      // No "result=" marker on this branch; the negative control expects it.
      $display("PROOF_RESULT: FAIL");
    end
    $finish;
  end

  initial begin
    #2000000;
    $display("TBFAIL global timeout");
    $display("PROOF_RESULT: FAIL");
    $finish;
  end

endmodule
