// Directed unit-level testbench for BUG-018 and BUG-019 in hmac_core.
//
// BUG-018: in CTRL_IDLE the FSM has two independent `if` blocks, one for
// init_cmd and one for next_cmd (hmac_core.sv:339-350). Because the second is
// not an `else if`, a cycle in which both commands are present leaves
// hmac_ctrl_new at CTRL_OPAD: the IPAD phase is skipped and the INIT is lost
// silently, with no error and with ready still having been high.
//
// BUG-019: the init_cmd branch drives digest_valid_new = 0 but never asserts
// digest_valid_we (hmac_core.sv:339-343), so the reg_update block never writes
// digest_valid_reg. The next_cmd branch two lines below does assert it
// (hmac_core.sv:347), so this same always_comb block already demonstrates the
// correct treatment it withholds from init_cmd.
//
// Both checks read the DUT's own state hierarchically; nothing is forced except
// the one deposit noted in test 2, which stands in for "a previous HMAC left a
// valid tag behind".
`timescale 1ns/1ps

module hmac_core_bug_018_019_tb;

  localparam [2:0] CTRL_IDLE = 3'd0;
  localparam [2:0] CTRL_IPAD = 3'd1;
  localparam [2:0] CTRL_OPAD = 3'd2;

  logic            clk, reset_n, zeroize;
  logic            init_cmd, next_cmd, mode_cmd;
  logic            ready, tag_valid;
  logic [383:0]    lfsr_seed;
  logic [511:0]    key;
  logic [1023:0]   block_msg;
  logic [511:0]    tag;

  int errors  = 0;
  int checks  = 0;
  int cover_ipad_skipped   = 0;
  int cover_stale_valid    = 0;
  int cover_next_clears    = 0;

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

  initial begin
    clk       = 1'b0;
    mode_cmd  = 1'b1;
    lfsr_seed = {12{32'hA5A5_0F0F}};
    key       = {8{64'h0123_4567_89AB_CDEF}};
    block_msg = {16{64'h1111_2222_3333_4444}};

    $display("===== BUG-018 / BUG-019 directed simulation on hmac_core =====");

    // ---------------- test 1: BUG-018, INIT+NEXT in the same cycle ----------
    do_reset();
    $display("[test 1] assert init_cmd and next_cmd together in CTRL_IDLE");
    check(dut.hmac_ctrl_reg === CTRL_IDLE, "precondition: FSM is in CTRL_IDLE");
    check(ready === 1'b1, "precondition: ready is high, so the command is accepted");

    @(negedge clk);
    init_cmd = 1'b1;
    next_cmd = 1'b1;
    @(posedge clk);            // the cycle in which both commands are sampled
    $display("  combinational: hmac_ctrl_new=%0d hmac_ctrl_we=%0b",
             dut.hmac_ctrl_new, dut.hmac_ctrl_we);
    check(dut.hmac_ctrl_new === CTRL_OPAD,
          "the second if overwrites hmac_ctrl_new: CTRL_OPAD, not CTRL_IPAD");
    @(negedge clk);
    init_cmd = 1'b0;
    next_cmd = 1'b0;
    @(posedge clk);
    $display("  OBSERVED: hmac_ctrl_reg=%0d after the command cycle",
             dut.hmac_ctrl_reg);
    if (dut.hmac_ctrl_reg === CTRL_OPAD) cover_ipad_skipped++;
    check(dut.hmac_ctrl_reg === CTRL_OPAD,
          "BUG-018 OBSERVED: FSM landed in CTRL_OPAD, the IPAD phase is skipped");
    check(dut.hmac_ctrl_reg !== CTRL_IPAD,
          "the INIT was lost: the FSM never entered CTRL_IPAD");

    // ---------------- test 2: BUG-019, INIT does not clear stale valid -------
    do_reset();
    $display("[test 2] a previous HMAC left digest_valid_reg set; issue INIT");
    // Deposit the state a completed HMAC would have left behind. Only this one
    // bit is forced, and it is released immediately so the DUT owns it again.
    force dut.digest_valid_reg = 1'b1;
    @(posedge clk);
    release dut.digest_valid_reg;
    @(negedge clk);
    check(tag_valid === 1'b1, "precondition: tag_valid is high from the previous run");

    init_cmd = 1'b1;
    next_cmd = 1'b0;
    @(posedge clk);
    $display("  combinational: digest_valid_new=%0b digest_valid_we=%0b",
             dut.digest_valid_new, dut.digest_valid_we);
    check(dut.digest_valid_new === 1'b0,
          "the init_cmd branch does drive digest_valid_new to 0");
    check(dut.digest_valid_we === 1'b0,
          "BUG-019 OBSERVED: but digest_valid_we is never asserted, so the write is dropped");
    if (dut.digest_valid_we === 1'b0 && tag_valid === 1'b1) cover_stale_valid++;
    $display("  OBSERVED: tag_valid=%0b during the INIT command cycle, tag[63:0]=%h",
             tag_valid, tag[63:0]);
    check(tag_valid === 1'b1,
          "BUG-019 OBSERVED: stale VALID survives the INIT command cycle");
    @(negedge clk);
    init_cmd = 1'b0;

    // ---------------- test 3: in-file control, NEXT does clear it ------------
    do_reset();
    $display("[test 3] in-file control: the next_cmd branch asserts digest_valid_we");
    force dut.digest_valid_reg = 1'b1;
    @(posedge clk);
    release dut.digest_valid_reg;
    @(negedge clk);
    check(tag_valid === 1'b1, "precondition: tag_valid is high again");

    init_cmd = 1'b0;
    next_cmd = 1'b1;
    @(posedge clk);
    $display("  combinational: digest_valid_new=%0b digest_valid_we=%0b",
             dut.digest_valid_new, dut.digest_valid_we);
    check(dut.digest_valid_we === 1'b1,
          "control: next_cmd asserts digest_valid_we, the treatment init_cmd omits");
    @(negedge clk);
    next_cmd = 1'b0;
    @(posedge clk);
    $display("  OBSERVED: tag_valid=%0b one cycle after the NEXT command", tag_valid);
    if (dut.digest_valid_we === 1'b1 || tag_valid === 1'b0) cover_next_clears++;
    check(tag_valid === 1'b0,
          "control: the stale VALID is cleared, so the harness can observe clearing");

    // ---------------- verdict ------------------------------------------------
    $display("cover_ipad_skipped=%0d", cover_ipad_skipped);
    $display("cover_stale_valid=%0d",  cover_stale_valid);
    $display("cover_next_clears=%0d",  cover_next_clears);
    $display("checks=%0d errors=%0d", checks, errors);

    if (errors == 0 && cover_ipad_skipped == 1 && cover_stale_valid == 1
        && cover_next_clears == 1)
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
