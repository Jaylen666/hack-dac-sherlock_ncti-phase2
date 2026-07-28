// Directed unit-level testbench for BUG-016 in hmac_core.
//
// BUG-016: the zeroize arm of the reg_update case statement
// (hmac_core.sv:190-196) collapses hmac_ctrl_reg and hmac_ctrl_last to
// CTRL_IDLE but never touches digest_valid_reg, so the "tag is valid" status
// bit survives a security zeroize. The arm's own comment claims the bit is
// "refreshed by the normal update path below on a later cycle"; this testbench
// exercises exactly that claim by idling the block after the zeroize and
// showing the bit never changes, because every digest_valid_we assertion site
// is command- or ready-guarded and zeroize has just forced the FSM to idle.
//
// Two in-file controls run in the same simulation, so a failure of the DUT to
// clear anything at all would be visible as a broken harness rather than as
// evidence: hmac_ctrl_reg must be cleared by the same zeroize arm, and mode_reg
// must be cleared by its own zeroize arm at hmac_core.sv:216-217.
//
// The only forced signal is the one deposit noted in each test, standing in for
// "a completed HMAC left a valid tag behind"; it is released immediately so the
// DUT owns the register again before zeroize is applied.
`timescale 1ns/1ps

module hmac_core_bug_016_tb;

  localparam [2:0] CTRL_IDLE = 3'd0;

  logic            clk, reset_n, zeroize;
  logic            init_cmd, next_cmd, mode_cmd;
  logic            ready, tag_valid;
  logic [383:0]    lfsr_seed;
  logic [511:0]    key;
  logic [1023:0]   block_msg;
  logic [511:0]    tag;

  int errors = 0;
  int checks = 0;
  int cover_valid_survives_zeroize = 0;  // the defect itself
  int cover_valid_never_refreshed  = 0;  // the comment's excuse, disproved
  int cover_ctrl_cleared           = 0;  // harness control, must keep firing

  hmac_core dut (
    .clk(clk), .reset_n(reset_n), .zeroize(zeroize),
    .init_cmd(init_cmd), .next_cmd(next_cmd), .mode_cmd(mode_cmd),
    .ready(ready), .tag_valid(tag_valid),
    .lfsr_seed(lfsr_seed), .key(key), .block_msg(block_msg), .tag(tag)
  );

  always #5 clk = ~clk;

  task automatic check(input bit cond, input string what);
    checks++;
    if (!cond) begin
      errors++;
      $display("TBFAIL: %s", what);
    end else begin
      $display("  ok: %s", what);
    end
  endtask

  task automatic do_reset();
    reset_n  = 1'b0;
    zeroize  = 1'b0;
    init_cmd = 1'b0;
    next_cmd = 1'b0;
    repeat (4) @(posedge clk);
    reset_n = 1'b1;
    repeat (2) @(posedge clk);
  endtask

  // Deposit the state a completed HMAC would have left behind, then hand the
  // register straight back to the DUT.
  task automatic seed_stale_valid();
    force dut.digest_valid_reg = 1'b1;
    @(posedge clk);
    release dut.digest_valid_reg;
    @(negedge clk);
  endtask

  initial begin
    clk       = 1'b0;
    mode_cmd  = 1'b1;
    lfsr_seed = {12{32'hA5A5_0F0F}};
    key       = {8{64'h0123_4567_89AB_CDEF}};
    block_msg = {16{64'h1111_2222_3333_4444}};

    $display("===== BUG-016 directed simulation on hmac_core =====");

    // ------- test 1: zeroize leaves the valid bit set --------------------
    do_reset();
    $display("[test 1] stale tag_valid, then a security zeroize");
    seed_stale_valid();
    check(tag_valid === 1'b1,
          "precondition: tag_valid is high from the previous HMAC");
    check(dut.hmac_ctrl_reg === CTRL_IDLE,
          "precondition: FSM parked (the seeding did not disturb control state)");

    zeroize = 1'b1;
    repeat (2) @(posedge clk);
    @(negedge clk);
    $display("  OBSERVED during zeroize: digest_valid_reg=%0b hmac_ctrl_reg=%0d mode_reg=%h",
             dut.digest_valid_reg, dut.hmac_ctrl_reg, dut.mode_reg);
    check(dut.digest_valid_reg === 1'b1,
          "BUG-016 OBSERVED: digest_valid_reg still 1 while zeroize is asserted");

    // In-file control: the same arm does clear the control registers, and
    // mode_reg has its own zeroize arm. Both must hold, or the harness is not
    // actually driving zeroize into the DUT.
    check(dut.hmac_ctrl_reg === CTRL_IDLE,
          "control: the same zeroize arm did collapse hmac_ctrl_reg to CTRL_IDLE");
    check(dut.mode_reg === '0,
          "control: mode_reg was cleared by its own zeroize arm, so zeroize reached the DUT");
    if (dut.hmac_ctrl_reg === CTRL_IDLE && dut.mode_reg === '0) cover_ctrl_cleared++;

    zeroize = 1'b0;
    @(posedge clk);
    @(negedge clk);
    $display("  OBSERVED after zeroize deasserts: tag_valid=%0b", tag_valid);
    check(tag_valid === 1'b1,
          "BUG-016 OBSERVED: tag_valid is still asserted after the zeroize completes");
    if (tag_valid === 1'b1) cover_valid_survives_zeroize++;

    // ------- test 2: the comment's "refreshed later" claim ----------------
    $display("[test 2] idle the block: the comment claims a later refresh clears it");
    begin
      int idle_cycles;
      bit stayed_set;
      idle_cycles = 40;
      stayed_set  = 1'b1;
      for (int i = 0; i < idle_cycles; i++) begin
        @(posedge clk);
        if (dut.digest_valid_we !== 1'b0) stayed_set = 1'b0;
        if (dut.digest_valid_reg !== 1'b1) stayed_set = 1'b0;
      end
      @(negedge clk);
      $display("  OBSERVED: after %0d idle cycles digest_valid_we never asserted, digest_valid_reg=%0b",
               idle_cycles, dut.digest_valid_reg);
      check(stayed_set,
            "BUG-016 OBSERVED: no refresh occurs, so the stale valid bit persists indefinitely");
      check(ready === 1'b1,
            "the block reports itself ready while still advertising the stale tag as valid");
      if (stayed_set) cover_valid_never_refreshed++;
    end

    // ------- test 3: control, reset does clear the same register ----------
    $display("[test 3] control: the reset arm of the same case statement clears it");
    seed_stale_valid();
    check(tag_valid === 1'b1, "precondition: tag_valid high again");
    reset_n = 1'b0;
    repeat (2) @(posedge clk);
    @(negedge clk);
    $display("  OBSERVED: digest_valid_reg=%0b under reset", dut.digest_valid_reg);
    check(dut.digest_valid_reg === 1'b0,
          "control: reset clears digest_valid_reg, so the register is clearable and the harness can see it");
    reset_n = 1'b1;

    // ------- verdict ------------------------------------------------------
    $display("cover_valid_survives_zeroize=%0d", cover_valid_survives_zeroize);
    $display("cover_valid_never_refreshed=%0d",  cover_valid_never_refreshed);
    $display("cover_ctrl_cleared=%0d",           cover_ctrl_cleared);
    $display("checks=%0d errors=%0d", checks, errors);

    if (errors == 0 && cover_valid_survives_zeroize == 1
        && cover_valid_never_refreshed == 1 && cover_ctrl_cleared == 1)
      $display("PROOF_RESULT: PASS");
    else
      $display("PROOF_RESULT: FAIL");

    $finish;
  end

  // Watchdog so a hang is a failure rather than a timeout with no verdict.
  initial begin
    #200000;
    $display("TBFAIL: watchdog expired");
    $display("PROOF_RESULT: FAIL");
    $finish;
  end

endmodule
