// Directed unit-level testbench for BUG-029 in sha3.
//
// BUG-029: the completion branch of StSqueeze (sha3.sv:288-293) assigns
// keccak_done from the incoming done_i but pins a second signal, keccak_done2,
// to the constant MuBi4False. That second signal is what sha3.sv:494 wires to
// the Keccak round's clear_i port. Because keccak_round.sv:219 acts on clear_i
// only when it passes mubi4_test_true_strict, a constant MuBi4False can never
// trigger it, so rst_storage (keccak_round.sv:226, the only site that raises it)
// never fires and the 1600-bit Keccak state survives the done that was supposed
// to clear it.
//
// The testbench absorbs a message so the state storage becomes non-zero, walks
// the FSM to the squeeze window, issues a strictly-valid done_i, and then reads
// the child's storage register and its rst_storage signal hierarchically. It
// then absorbs the byte-identical message a second time. Because the sponge
// absorbs by XORing the incoming block into the surviving storage
// (keccak_round.sv:487-497), the second run's state differs from the first,
// which is the consequence the missing clear produces: consecutive hashes are
// not independent. Two in-module controls run in the same simulation so a DUT
// that clears nothing at all would show up as a broken harness rather than as
// evidence: the FSM must still leave the squeeze window on that same done_i,
// and an actual reset must still clear the same storage register.
//
// Nothing is forced. The only hierarchical accesses are reads.
`timescale 1ns/1ps

module sha3_bug_029_tb;

  import sha3_pkg::*;
  import caliptra_prim_mubi_pkg::*;

  localparam int Share = 1;

  logic                clk_i, rst_ni;
  logic                msg_valid_i;
  logic [MsgWidth-1:0] msg_data_i [Share];
  logic [MsgStrbW-1:0] msg_strb_i;
  logic                msg_ready_o;

  logic                rand_valid_i, rand_early_i, rand_aux_i;
  logic [StateW/2-1:0] rand_data_i;
  logic                rand_update_o, rand_consumed_o;

  logic [NSRegisterSize*8-1:0] ns_data_i;

  sha3_mode_e       mode_i;
  keccak_strength_e strength_i;

  logic   start_i, process_i, run_i;
  mubi4_t done_i;

  mubi4_t          absorbed_o;
  logic            squeezing_o, block_processed_o;
  sha3_st_e        sha3_fsm_o;
  logic            state_valid_o;
  logic [StateW-1:0] state_o [Share];
  logic            run_req_o, run_ack_i;

  lc_ctrl_pkg::lc_tx_t lc_escalate_en_i;

  err_t error_o;
  logic sparse_fsm_error_o, count_error_o, keccak_storage_rst_error_o;

  int errors = 0;
  int checks = 0;
  int cover_state_survives_done = 0;  // the defect itself
  int cover_clear_never_strict  = 0;  // the constant-False clear, observed
  int cover_cross_run_carryover = 0;  // the consequence: run 2 inherits run 1
  int cover_fsm_did_advance     = 0;  // harness control, must keep firing

  // Sampled observations, so the verdict does not depend on when it is read.
  bit rst_storage_seen_any;
  bit clear_strict_seen_any;

  sha3 #(
    .EnMasking (0)
  ) dut (
    .clk_i, .rst_ni,
    .msg_valid_i, .msg_data_i, .msg_strb_i, .msg_ready_o,
    .rand_valid_i, .rand_early_i, .rand_data_i, .rand_aux_i,
    .rand_update_o, .rand_consumed_o,
    .ns_data_i,
    .mode_i, .strength_i,
    .start_i, .process_i, .run_i, .done_i,
    .absorbed_o, .squeezing_o, .block_processed_o, .sha3_fsm_o,
    .state_valid_o, .state_o,
    .run_req_o, .run_ack_i,
    .lc_escalate_en_i,
    .error_o,
    .sparse_fsm_error_o, .count_error_o, .keccak_storage_rst_error_o
  );

  always #5 clk_i = ~clk_i;

  // Continuous monitors. rst_storage is the only signal that can zero the
  // Keccak storage, so watching it for the whole run makes the "never cleared"
  // claim exhaustive rather than a single-cycle sample.
  always @(posedge clk_i) begin
    if (rst_ni) begin
      if (dut.u_keccak.rst_storage) rst_storage_seen_any = 1'b1;
      if (mubi4_test_true_strict(dut.u_keccak.clear_i)) clear_strict_seen_any = 1'b1;
    end
  end

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
    rst_ni      = 1'b0;
    start_i     = 1'b0;
    process_i   = 1'b0;
    run_i       = 1'b0;
    done_i      = MuBi4False;
    msg_valid_i = 1'b0;
    msg_strb_i  = '0;
    msg_data_i[0] = '0;
    rst_storage_seen_any  = 1'b0;
    clear_strict_seen_any = 1'b0;
    repeat (4) @(posedge clk_i);
    rst_ni = 1'b1;
    repeat (2) @(posedge clk_i);
  endtask

  // Push one 64-bit word into the message interface, respecting msg_ready_o.
  task automatic push_word(input logic [MsgWidth-1:0] w);
    @(negedge clk_i);
    msg_data_i[0] = w;
    msg_strb_i    = '1;
    msg_valid_i   = 1'b1;
    // Wait for the accepting edge, then return to the negedge so the next
    // stimulus change cannot land in the same timestep as a clock edge.
    do @(posedge clk_i); while (!msg_ready_o);
    @(negedge clk_i);
    msg_valid_i = 1'b0;
    msg_strb_i  = '0;
  endtask

  // Wait for a condition with a bounded number of cycles, so a hang inside a
  // wait becomes a reported failure rather than a watchdog kill.
  task automatic wait_for(input string what, input int max_cycles, ref bit done_flag);
    int n;
    n = 0;
    while (!done_flag && n < max_cycles) begin
      @(posedge clk_i);
      n++;
    end
    if (!done_flag) begin
      errors++;
      $display("TBFAIL: timed out waiting for %s after %0d cycles", what, max_cycles);
    end
  endtask

  bit f_absorbed, f_squeezing;
  always @(posedge clk_i) begin
    if (mubi4_test_true_strict(absorbed_o))       f_absorbed  = 1'b1;
    if (sha3_fsm_o == StSqueeze)                  f_squeezing = 1'b1;
  end

  // Absorb one fixed two-word message and walk the FSM to the squeeze window.
  // Used twice with identical stimulus, so any difference between the two
  // squeeze-window states can only come from what the first run left behind.
  task automatic absorb_fixed_message();
    f_absorbed  = 1'b0;
    f_squeezing = 1'b0;

    // Every command is a one-cycle pulse driven from the negedge, which is what
    // the block's own assumptions require (sha3pad.sv:752 assumes process_i is
    // a pulse) and which keeps the stimulus stable across the sampling edge.
    @(negedge clk_i);
    start_i = 1'b1;
    @(posedge clk_i);
    @(negedge clk_i);
    start_i = 1'b0;

    push_word(64'h0123_4567_89AB_CDEF);
    push_word(64'hFEDC_BA98_7654_3210);

    @(negedge clk_i);
    process_i = 1'b1;
    @(posedge clk_i);
    @(negedge clk_i);
    process_i = 1'b0;

    wait_for("absorbed_o", 2000, f_absorbed);
    wait_for("the squeeze window", 200, f_squeezing);
  endtask

  // Issue one strictly-valid done pulse and let the FSM settle back to idle.
  task automatic pulse_done();
    @(negedge clk_i);
    done_i = MuBi4True;
    @(posedge clk_i);
    @(negedge clk_i);
    done_i = MuBi4False;
    repeat (10) @(posedge clk_i);
  endtask

  initial begin
    automatic logic [StateW-1:0] state_after_done;
    automatic logic [StateW-1:0] state_before_done;
    automatic logic [StateW-1:0] state_run2;

    clk_i            = 1'b0;
    mode_i           = Sha3;
    strength_i       = L256;
    ns_data_i        = '0;
    rand_valid_i     = 1'b1;
    rand_early_i     = 1'b1;
    rand_data_i      = '0;
    rand_aux_i       = 1'b0;
    run_ack_i        = 1'b1;
    lc_escalate_en_i = lc_ctrl_pkg::Off;
    f_absorbed       = 1'b0;
    f_squeezing      = 1'b0;

    $display("===== BUG-029 directed simulation on sha3 =====");
    $display("MuBi4True=0x%01h MuBi4False=0x%01h", MuBi4True, MuBi4False);

    do_reset();

    // ---- absorb a message so the Keccak state storage becomes non-zero -----
    $display("[test 1] absorb a message, squeeze, then issue a strictly-valid done");
    check(dut.u_keccak.storage[0] === '0,
          "precondition: the Keccak state storage is zero out of reset");

    absorb_fixed_message();

    @(negedge clk_i);
    state_before_done = dut.u_keccak.storage[0];
    $display("  OBSERVED: fsm=%s state[63:0]=%h state_nonzero=%0b",
             sha3_fsm_o.name(), state_before_done[63:0], (state_before_done !== '0));
    check(state_before_done !== '0,
          "precondition: absorbing left a non-zero Keccak state, so a clear would be observable");
    check(sha3_fsm_o === StSqueeze,
          "precondition: the FSM is in the squeeze window, where done_i is accepted");

    // ---- issue done and observe the clear that does not happen ------------
    $display("  driving done_i = MuBi4True (strictly valid)");
    // Before the first done, keccak_done2 has never been assigned: sha3.sv:247
    // gives keccak_done a default in this always_comb but nothing gives one to
    // keccak_done2, so the signal is uninitialised here. That is reported as an
    // observation in its own right; the check below asserts only the property
    // that matters, namely that the clear does not fire.
    $display("  OBSERVED before done: keccak_done2=0x%01h clear_i=0x%01h (uninitialised: no default assignment)",
             dut.keccak_done2, dut.u_keccak.clear_i);
    check(mubi4_test_true_strict(dut.u_keccak.clear_i) !== 1'b1,
          "BUG-029 OBSERVED: the Keccak clear_i does not pass the strict true test before done either");
    check($isunknown(dut.keccak_done2) === 1'b1,
          "BUG-029 OBSERVED: keccak_done2 is X before the first done, confirming it has no default in the always_comb");

    @(negedge clk_i);
    done_i = MuBi4True;
    @(posedge clk_i);
    $display("  OBSERVED in the done branch: keccak_done=0x%01h keccak_done2=0x%01h clear_i=0x%01h",
             dut.keccak_done, dut.keccak_done2, dut.u_keccak.clear_i);
    check(mubi4_test_true_strict(dut.keccak_done) === 1'b1,
          "the done branch does propagate done_i into keccak_done, so the command was accepted");
    check(mubi4_test_true_strict(dut.keccak_done2) === 1'b0,
          "BUG-029 OBSERVED: keccak_done2 is not strictly true in the same branch, so the clear it drives cannot fire");
    @(negedge clk_i);
    done_i = MuBi4False;

    // Let the FSM run through StFlush back to idle, then read the storage.
    repeat (10) @(posedge clk_i);
    @(negedge clk_i);
    // (the pulse above is what pulse_done() performs for the second run)
    state_after_done = dut.u_keccak.storage[0];
    $display("  OBSERVED after done: fsm=%s state[63:0]=%h state_nonzero=%0b",
             sha3_fsm_o.name(), state_after_done[63:0], (state_after_done !== '0));

    // In-module control: the FSM must have left the squeeze window on that same
    // done_i. If it had not, the DUT never saw the command and nothing below
    // would be attributable to the clear wiring.
    check(sha3_fsm_o === StIdle,
          "control: the FSM returned to idle on that done_i, so the command reached the DUT");
    if (sha3_fsm_o === StIdle) cover_fsm_did_advance++;

    check(state_after_done !== '0,
          "BUG-029 OBSERVED: the Keccak state storage is still non-zero after done completed");
    check(state_after_done === state_before_done,
          "BUG-029 OBSERVED: the state is not merely non-zero, it is bit-for-bit the pre-done value");
    if (state_after_done !== '0 && state_after_done === state_before_done)
      cover_state_survives_done++;

    check(rst_storage_seen_any === 1'b0,
          "BUG-029 OBSERVED: rst_storage never asserted at any point in the run, so no path cleared the state");
    check(clear_strict_seen_any === 1'b0,
          "BUG-029 OBSERVED: clear_i never passed the strict true test at any point in the run");
    if (clear_strict_seen_any === 1'b0) cover_clear_never_strict++;

    // ---- consequence: the next run starts from the stale sponge -------------
    // The Keccak sponge absorbs by XORing the incoming block into the existing
    // storage (keccak_round.sv:487-497). Because done left the storage intact,
    // a second start/absorb/process with byte-identical stimulus produces a
    // different squeeze-window state: run 2 is a function of run 1's residue.
    // The consumer of this exact module states the intent it is being denied.
    // entropy_src_main_sm.sv:246 comments that the done it issues is there to
    // "clear the internal state of the SHA3 engine to start from scratch for
    // the next seed", and entropy_src_core.sv:2734 feeds the squeezed state
    // straight into the conditioned-entropy path.
    $display("[test 2] the same message absorbed again after done, to show what the stale state does");
    absorb_fixed_message();
    @(negedge clk_i);
    state_run2 = dut.u_keccak.storage[0];
    $display("  OBSERVED run 2: fsm=%s state[63:0]=%h", sha3_fsm_o.name(), state_run2[63:0]);
    $display("  run1 state[63:0]=%h  run2 state[63:0]=%h", state_before_done[63:0], state_run2[63:0]);

    check(sha3_fsm_o === StSqueeze,
          "control: the second run reached the squeeze window too, so both runs are directly comparable");
    check(state_run2 !== state_before_done,
          "BUG-029 OBSERVED: byte-identical input produced a different sponge state on the second run, because run 2 absorbed into run 1's residue");
    if (sha3_fsm_o === StSqueeze && state_run2 !== state_before_done)
      cover_cross_run_carryover++;

    pulse_done();

    // ---- in-module control: an actual reset does clear the same storage ----
    $display("[test 3] control: a reset clears the same storage register");
    check(dut.u_keccak.storage[0] !== '0,
          "precondition: the storage is still non-zero going into the reset");
    rst_ni = 1'b0;
    repeat (3) @(posedge clk_i);
    @(negedge clk_i);
    $display("  OBSERVED under reset: state[63:0]=%h", dut.u_keccak.storage[0][63:0]);
    check(dut.u_keccak.storage[0] === '0,
          "control: reset zeroes the storage, so the register is clearable and the harness can observe clearing");
    rst_ni = 1'b1;

    // ---- verdict ----------------------------------------------------------
    $display("cover_state_survives_done=%0d", cover_state_survives_done);
    $display("cover_clear_never_strict=%0d",  cover_clear_never_strict);
    $display("cover_cross_run_carryover=%0d", cover_cross_run_carryover);
    $display("cover_fsm_did_advance=%0d",     cover_fsm_did_advance);
    $display("checks=%0d errors=%0d", checks, errors);

    if (errors == 0 && cover_state_survives_done == 1
        && cover_clear_never_strict == 1 && cover_cross_run_carryover == 1
        && cover_fsm_did_advance == 1)
      $display("PROOF_RESULT: PASS");
    else
      $display("PROOF_RESULT: FAIL");

    $finish;
  end

  // Watchdog so a hang is a failure rather than a timeout with no verdict.
  initial begin
    #500000;
    $display("TBFAIL: watchdog expired");
    $display("PROOF_RESULT: FAIL");
    $finish;
  end

endmodule
