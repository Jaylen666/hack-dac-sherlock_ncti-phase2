// SPDX-License-Identifier: Apache-2.0
//
// BUG-015 directed witness: hmac_core's zeroize arm does not clear
// digest_valid_reg, so the block keeps claiming a valid tag after a security
// zeroize and keeps presenting tag data on its output.
//
// Property under test: after a zeroize is taken, hmac_core must not report
// tag_valid, and its tag output must not present digest data. src/hmac/rtl/
// hmac_core.sv:111-112 make both the 512-bit tag and the tag_valid output
// functions of the single register digest_valid_reg, so that register's value
// after a zeroize fully determines whether the block claims a result.
//
// src/hmac/rtl/hmac_core.sv:181-209 holds three registers in one always_ff. The
// reset arm at :184-187 clears all three including digest_valid_reg at :185; the
// zeroize arm at :190-196 clears only two, and carries a comment claiming the
// normal update path refreshes digest_valid_reg later. That claim is what this
// testbench checks: the FSM's CTRL_IDLE arm at :336-351 raises digest_valid_we
// only in its next_cmd branch, so an engine sitting idle after a zeroize never
// performs the promised refresh.
//
// The parent's consumption is what makes the stale flag reach software.
// src/hmac/rtl/hmac.sv:163 builds its tag-capture enable from a RISING EDGE of
// core_tag_valid measured against its own tag_valid_reg, and :214 clears that
// parent register on the same zeroize. This testbench reproduces that exact
// edge expression against the real DUT's output, so the reported consequence is
// computed from the parent's own formula rather than asserted.
//
// This testbench instantiates one real hmac_core and drives it only through its
// declared ports. There is no force, no deposit and no hierarchical assignment
// anywhere in this harness.
//
`timescale 1ns/1ps

module hmac_core_bug_015_tb ();

  localparam int unsigned CLK_HALF = 5;

  logic clk, reset_n, zeroize;
  logic init_cmd, next_cmd, mode_cmd;
  logic ready, tag_valid;
  logic [383 : 0]  lfsr_seed;
  logic [511 : 0]  key;
  logic [1023 : 0] block_msg;
  logic [511 : 0]  tag;

  int unsigned checks, fails;
  int unsigned cov_tag_valid_after_normal_run;
  int unsigned cov_tag_valid_survives_zeroize;
  int unsigned cov_spurious_parent_capture_edge;
  int unsigned cov_reset_clears_tag_valid;
  int unsigned witness_hits;

  // Reproduction of the parent's capture enable, src/hmac/rtl/hmac.sv:163:
  //   core_tag_we = (core_tag_valid & ~tag_valid_reg) & ~error_flag_reg
  // with tag_valid_reg modelled exactly as hmac.sv:196-231 does: cleared by
  // zeroize (:214), otherwise tracking core_tag_valid (:222). error_flag_reg is
  // held low, which is the benign case for this check.
  logic parent_tag_valid_reg;
  logic parent_capture_en;
  always_comb parent_capture_en = tag_valid & ~parent_tag_valid_reg;

  always_ff @(posedge clk or negedge reset_n) begin
    if (!reset_n)     parent_tag_valid_reg <= 1'b0;
    else if (zeroize) parent_tag_valid_reg <= 1'b0;
    else              parent_tag_valid_reg <= tag_valid;
  end

  // Latch any capture edge seen while tracking, so a single-cycle event cannot
  // be missed by sampling.
  // A plain always block, not always_ff: the stimulus process below also clears
  // this flag before each tracking window, and always_ff forbids a second
  // procedural driver.
  bit tracking_capture, saw_capture_edge;
  always @(posedge clk)
    if (tracking_capture && parent_capture_en) saw_capture_edge = 1'b1;

  hmac_core dut (
    .clk       (clk),
    .reset_n   (reset_n),
    .zeroize   (zeroize),
    .init_cmd  (init_cmd),
    .next_cmd  (next_cmd),
    .mode_cmd  (mode_cmd),
    .ready     (ready),
    .tag_valid (tag_valid),
    .lfsr_seed (lfsr_seed),
    .key       (key),
    .block_msg (block_msg),
    .tag       (tag)
  );

  initial clk = 1'b0;
  always #CLK_HALF clk = ~clk;

  task automatic step(input int unsigned n);
    for (int unsigned i = 0; i < n; i++) @(posedge clk);
  endtask

  task automatic record(input string name, input bit ok, input string what);
    checks++;
    if (ok) $display("  case=%s PASS %s", name, what);
    else begin
      fails++;
      $display("  TBFAIL case=%s %s", name, what);
    end
  endtask

  // Run one complete HMAC operation and wait for the block to report a tag.
  // All stimulus is negedge-aligned so no combinationally-derived enable sees a
  // zero-width glitch.
  task automatic run_to_tag_valid(output bit got_tag);
    got_tag = 1'b0;
    @(negedge clk); init_cmd = 1'b1;
    @(negedge clk); init_cmd = 1'b0;
    for (int unsigned i = 0; i < 40000; i++) begin
      @(posedge clk);
      if (tag_valid) begin
        got_tag = 1'b1;
        break;
      end
    end
  endtask

  task automatic pulse_zeroize();
    @(negedge clk); zeroize = 1'b1;
    @(negedge clk); zeroize = 1'b0;
  endtask

  initial begin
    checks = 0; fails = 0;
    cov_tag_valid_after_normal_run   = 0;
    cov_tag_valid_survives_zeroize   = 0;
    cov_spurious_parent_capture_edge = 0;
    cov_reset_clears_tag_valid       = 0;
    witness_hits                     = 0;
    tracking_capture = 1'b0;
    saw_capture_edge = 1'b0;

    init_cmd = 0; next_cmd = 0; mode_cmd = 1'b1; zeroize = 0;
    key       = {8{64'h0123_4567_89AB_CDEF}};
    block_msg = {16{64'hA5A5_5A5A_C3C3_3C3C}};
    for (int i = 0; i < 12; i++) lfsr_seed[i*32 +: 32] = 32'hDEAD_0000 + i;

    reset_n = 1'b0;
    step(5);
    reset_n = 1'b1;
    step(5);

    $display("===== BUG-015 directed witness: hmac_core tag validity across zeroize =====");

    // ---- control 1: reset must leave the block reporting no valid tag.
    record("control_reset_clears_tag_valid", tag_valid === 1'b0,
           "after reset the block must not claim a valid tag");
    if (tag_valid === 1'b0) cov_reset_clears_tag_valid++;

    // ---- run one real operation so digest_valid_reg is legitimately set.
    begin
      bit got;
      run_to_tag_valid(got);
      $display("      operation completed, tag_valid=%0b tag[63:0]=%h", tag_valid, tag[63:0]);
      record("control_normal_run_sets_tag_valid", got,
             "a completed operation must report a valid tag, showing the harness reaches the state under test");
      if (got) cov_tag_valid_after_normal_run++;
    end

    // ---- witness: take a zeroize while the tag is valid. The FSM is returned
    // to idle, so software sees an idle engine; the validity flag is not
    // returned with it, and the tag output stays gated open.
    begin
      logic [511:0] tag_before;
      tag_before = tag;
      $display("--- violating_tag_valid_survives_zeroize ---");
      $display("      before zeroize: tag_valid=%0b ready=%0b", tag_valid, ready);

      // Let the modelled parent register catch up first. It follows tag_valid
      // by one cycle, and the legitimate completion edge has just occurred, so
      // tracking must not open until parent_tag_valid_reg has reached 1 —
      // otherwise the legitimate edge would be counted as the spurious one.
      step(4);
      if (parent_tag_valid_reg !== 1'b1)
        $display("      TBFAIL parent model did not settle before tracking opened");
      $display("      tracking opens with tag_valid=%0b parent_tag_valid_reg=%0b",
               tag_valid, parent_tag_valid_reg);

      tracking_capture = 1'b1;
      saw_capture_edge = 1'b0;
      pulse_zeroize();
      step(6);

      $display("      after zeroize:  tag_valid=%0b ready=%0b tag[63:0]=%h",
               tag_valid, ready, tag[63:0]);

      if (tag_valid !== 1'b0) begin
        cov_tag_valid_survives_zeroize++;
        witness_hits++;
        $display("      OBSERVED: BUG_015_WITNESS_OBSERVED hmac_core still reports tag_valid=1 six cycles after a completed zeroize");
      end
      record("violating_tag_valid_survives_zeroize", tag_valid === 1'b0,
             "a zeroize must leave the block reporting no valid tag");

      // The comment inside the zeroize arm claims the normal update path
      // refreshes the flag on a later cycle. Give it a generous window with the
      // engine idle and no command issued, which is the situation the comment
      // describes, and check whether the refresh ever happens.
      step(200);
      $display("      200 idle cycles later: tag_valid=%0b (the in-RTL comment claims a later refresh)",
               tag_valid);
      record("violating_idle_refresh_never_happens", tag_valid === 1'b0,
             "the claimed later refresh by the normal update path must actually clear the flag while idle");

      // The parent computes its tag-capture enable from a rising edge of this
      // output against its own register, which the same zeroize cleared. With
      // the child's flag still high, that edge reappears.
      tracking_capture = 1'b0;
      $display("      parent capture edge seen after zeroize: %0b (hmac.sv:163 formula)",
               saw_capture_edge);
      if (saw_capture_edge) cov_spurious_parent_capture_edge++;
      record("violating_no_spurious_parent_capture", saw_capture_edge === 1'b0,
             "the parent's tag-capture enable must not re-assert after a zeroize");
    end

    // ---- containment: a real reset must clear what zeroize did not, which
    // separates this defect from any claim that the flag is unclearable.
    $display("--- containment_reset_still_clears ---");
    reset_n = 1'b0; step(4); reset_n = 1'b1; step(4);
    $display("      after reset: tag_valid=%0b", tag_valid);
    record("containment_reset_still_clears", tag_valid === 1'b0,
           "a real reset must still clear the flag, confining the defect to the zeroize arm");

    $display("");
    $display("cov_reset_clears_tag_valid=%0d",       cov_reset_clears_tag_valid);
    $display("cov_tag_valid_after_normal_run=%0d",   cov_tag_valid_after_normal_run);
    $display("cov_tag_valid_survives_zeroize=%0d",   cov_tag_valid_survives_zeroize);
    $display("cov_spurious_parent_capture_edge=%0d", cov_spurious_parent_capture_edge);
    $display("witness_hits=%0d", witness_hits);
    $display("checks=%0d fails=%0d", checks, fails);

    // Expected on the audited RTL: the two controls and the containment case
    // pass, and the three violating checks fail.
    if (checks == 6 && fails == 3 && witness_hits == 1 &&
        cov_reset_clears_tag_valid == 1 &&
        cov_tag_valid_after_normal_run == 1 &&
        cov_tag_valid_survives_zeroize == 1 &&
        cov_spurious_parent_capture_edge == 1) begin
      $display("result=PASS");
      $display("PROOF_RESULT: PASS");
    end
    else begin
      // No "result=" marker here; the negative control expects this branch.
      $display("PROOF_RESULT: FAIL");
    end
    $finish;
  end

  initial begin
    #40000000;
    $display("TBFAIL global timeout");
    $display("PROOF_RESULT: FAIL");
    $finish;
  end

endmodule
