// Directed unit-level testbench for BUG-017 in hmac_core.
//
// The block reseeds its masking PRNGs from a hash of its own entropy block. The
// intended chain is: during CTRL_IPAD the H2 core is handed entropy_block
// (hmac_core.sv:282) and hashes it; at the IPAD -> OPAD transition set_entropy
// fires (hmac_core.sv:362) and latches entropy_digest <= H2_digest[383:0]
// (hmac_core.sv:229-231); entropy_digest then feeds the 12 masking LFSRs via
// lfsr_entropy = entropy_digest ^ lfsr_seed (hmac_core.sv:242).
//
// BUG-017: the CTRL_IPAD branch presents entropy_block on H2_block but never
// asserts H2_init or H2_next (hmac_core.sv:274-283). H2 is therefore never
// started, so it produces no digest for that block. set_entropy still fires and
// latches whatever H2_digest happens to be. Out of reset that is zero, so
// entropy_digest stays zero and lfsr_entropy collapses to the software-written
// LFSR_SEED register value alone: the masking seed loses its hardware-derived
// component and becomes fully software-determined.
//
// Every other block presentation in this same always_comb block is accompanied
// by a start strobe (H1_init at :275, H1_next/H2_init at :290-291, H2_next at
// :304). The entropy presentation at :282 is the only one that is not.
`timescale 1ns/1ps

module hmac_core_bug_017_tb;

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

  int  errors = 0;
  int  checks = 0;
  int  cover_h2_never_started = 0;
  int  cover_entropy_zero     = 0;
  int  cover_seed_is_sw       = 0;

  // Observation state gathered while the FSM sits in CTRL_IPAD.
  int  ipad_cycles      = 0;
  bit  h2_started_ipad  = 1'b0;
  bit  h1_started_ipad  = 1'b0;
  bit  saw_entropy_blk  = 1'b0;

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

  // Sample the H2 start strobes and the block presentation every cycle that the
  // FSM is in CTRL_IPAD. This is the whole window in which H2 could have been
  // launched on the entropy block.
  always @(posedge clk) begin
    if (reset_n && dut.hmac_ctrl_reg == CTRL_IPAD) begin
      ipad_cycles++;
      if (dut.H2_init || dut.H2_next) h2_started_ipad = 1'b1;
      if (dut.H1_init || dut.H1_next) h1_started_ipad = 1'b1;
      if (dut.H2_block === dut.entropy_block) saw_entropy_blk = 1'b1;
    end
  end

  initial begin
    clk       = 1'b0;
    mode_cmd  = 1'b1;
    // A recognisable, software-written LFSR seed. In the real block this is the
    // HMAC512_LFSR_SEED register (hmac.sv:159-160, :311), so its value is
    // whatever software last wrote.
    lfsr_seed = {12{32'hC0DE_5EED}};
    key       = {8{64'h0123_4567_89AB_CDEF}};
    block_msg = {16{64'h1111_2222_3333_4444}};

    reset_n  = 1'b0;
    zeroize  = 1'b0;
    init_cmd = 1'b0;
    next_cmd = 1'b0;
    repeat (4) @(posedge clk);
    reset_n = 1'b1;
    repeat (2) @(posedge clk);

    $display("===== BUG-017 directed simulation on hmac_core =====");
    check(dut.entropy_digest === '0, "precondition: entropy_digest is zero out of reset");

    // Issue a plain INIT so the FSM walks IDLE -> IPAD and the entropy window opens.
    @(negedge clk);
    init_cmd = 1'b1;
    @(posedge clk);
    @(negedge clk);
    init_cmd = 1'b0;

    // Wait for the FSM to enter CTRL_IPAD.
    while (dut.hmac_ctrl_reg !== CTRL_IPAD) @(posedge clk);
    $display("[phase] FSM entered CTRL_IPAD; watching the entropy window");

    // Wait for the IPAD -> OPAD transition, which is where set_entropy fires.
    while (dut.hmac_ctrl_reg === CTRL_IPAD) @(posedge clk);
    $display("[phase] FSM left CTRL_IPAD after %0d cycles", ipad_cycles);

    // ---- what happened inside the entropy window ----
    check(ipad_cycles > 0, "the FSM did spend time in CTRL_IPAD");
    check(saw_entropy_blk === 1'b1,
          "entropy_block was presented on H2_block during CTRL_IPAD");
    check(h1_started_ipad === 1'b1,
          "control: H1 was started in the same window, so start strobes do reach the cores");
    $display("  OBSERVED: over %0d CTRL_IPAD cycles, H2_init|H2_next was ever high: %0b",
             ipad_cycles, h2_started_ipad);
    if (h2_started_ipad === 1'b0) cover_h2_never_started++;
    check(h2_started_ipad === 1'b0,
          "BUG-017 OBSERVED: H2 was never started, so the entropy block was never hashed");

    // ---- the consequence: what set_entropy actually latched ----
    repeat (2) @(posedge clk);
    $display("  OBSERVED: entropy_digest[63:0]=%h after the IPAD->OPAD transition",
             dut.entropy_digest[63:0]);
    if (dut.entropy_digest === '0) cover_entropy_zero++;
    check(dut.entropy_digest === '0,
          "BUG-017 OBSERVED: entropy_digest latched zero, the unstarted core's output");
    if (dut.lfsr_entropy === lfsr_seed) cover_seed_is_sw++;
    check(dut.lfsr_entropy === lfsr_seed,
          "BUG-017 OBSERVED: lfsr_entropy collapses to the software-written LFSR_SEED alone");
    check(dut.lfsr_entropy !== '0,
          "the seed is not zero, so the LFSRs still run: the defect is predictability, not a stall");

    // ---------------- verdict ------------------------------------------------
    $display("cover_h2_never_started=%0d", cover_h2_never_started);
    $display("cover_entropy_zero=%0d",     cover_entropy_zero);
    $display("cover_seed_is_sw=%0d",       cover_seed_is_sw);
    $display("checks=%0d errors=%0d", checks, errors);

    if (errors == 0 && cover_h2_never_started == 1 && cover_entropy_zero == 1
        && cover_seed_is_sw == 1)
      $display("PROOF_RESULT: PASS");
    else
      $display("PROOF_RESULT: FAIL");

    $finish;
  end

  initial begin
    #2000000;
    $display("TBFAIL: watchdog expired");
    $display("PROOF_RESULT: FAIL");
    $finish;
  end

endmodule
