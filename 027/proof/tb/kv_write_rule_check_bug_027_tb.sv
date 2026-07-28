// SPDX-License-Identifier: Apache-2.0
//
// BUG-027 directed witness: the "only AES may write the key release slot" rule
// is silently disabled whenever the write carries a KeyVault-forwarded source.
//
// Property under test: while OCP Lock is in progress, a write to the key release
// slot (KV23) whose source is any engine other than AES must be rejected. The
// in-tree specification is explicit at src/keyvault/config/keyvault.md:260,
// "Never attempt to write anything to KV23 except MEK (produced by AES)", and the
// module's own header at src/keyvault/rtl/kv_write_rule_check.sv:20 states rule
// (a) as "non-AES engines are blocked from release slot".
//
// The implemented rule ANDs that check with release_slot_source_from_raw, which
// is defined at line 97 as !kv_data0_present. A non-AES engine whose operation
// consumed a KeyVault slot as input therefore passes the rule unconditionally.
//
// One DUT instance, driven only through its module ports. No internal force is
// used anywhere in this testbench.
//
`timescale 1ns/1ps

module kv_write_rule_check_bug_027_tb;
  import kv_defines_pkg::*;

  localparam int unsigned CLK_HALF = 5;

  logic clk;
  logic rst_b;
  kv_write_filter_metrics_t m;
  logic write_allow;

  int unsigned checks;
  int unsigned fails;
  int unsigned witness_hits;
  int unsigned cover_non_aes_release_allowed;
  int unsigned cover_non_aes_release_blocked;

  kv_write_rule_check dut (
    .clk          (clk),
    .rst_b        (rst_b),
    .write_metrics(m),
    .write_allow  (write_allow)
  );

  initial clk = 1'b0;
  always #CLK_HALF clk = ~clk;

  task automatic step(input int unsigned n);
    for (int unsigned i = 0; i < n; i++) @(posedge clk);
  endtask

  task automatic clear_metrics();
    m.ocp_lock_in_progress = 1'b0;
    m.kv_data0_present     = 1'b0;
    m.kv_data0_entry       = '0;
    m.kv_data1_present     = 1'b0;
    m.kv_data1_entry       = '0;
    m.kv_write_src         = '0;
    m.kv_write_entry       = '0;
    m.aes_decrypt_ecb_op   = 1'b0;
  endtask

  task automatic apply_reset();
    rst_b = 1'b0;
    clear_metrics();
    step(3);
    rst_b = 1'b1;
    step(2);
  endtask

  // write_allow is a registered output, so present the metrics and let two
  // clock edges pass before sampling.
  task automatic drive_and_sample(output logic allowed);
    step(3);
    allowed = write_allow;
  endtask

  task automatic report(input string  name,
                        input bit     expect_allowed,
                        input logic   observed_allowed);
    checks++;
    if (expect_allowed === observed_allowed) begin
      $display("  case=%s PASS expect_allowed=%0b write_allow=%0b",
               name, expect_allowed, observed_allowed);
    end
    else begin
      fails++;
      $display("  TBFAIL case=%s expect_allowed=%0b write_allow=%0b",
               name, expect_allowed, observed_allowed);
    end
  endtask

  initial begin
    logic allowed;

    checks       = 0;
    fails        = 0;
    witness_hits = 0;
    cover_non_aes_release_allowed = 0;
    cover_non_aes_release_blocked = 0;

    $display("===== BUG-027 directed witness: non-AES write to the key release slot =====");
    $display("release slot under test: KV%0d (OCP_LOCK_KEY_RELEASE_KV_SLOT)",
             OCP_LOCK_KEY_RELEASE_KV_SLOT);

    apply_reset();

    // ---- control 1: non-AES source, no forwarded KV input -> must be blocked
    $display("--- control_non_aes_release_no_forward ---");
    clear_metrics();
    m.ocp_lock_in_progress = 1'b1;
    m.kv_write_src         = (KV_NUM_WRITE'(1) << KV_WRITE_IDX_HMAC);
    m.kv_write_entry       = OCP_LOCK_KEY_RELEASE_KV_SLOT;
    m.kv_data0_present     = 1'b0;
    drive_and_sample(allowed);
    report("control_non_aes_release_no_forward", 1'b0, allowed);
    if (allowed === 1'b0) cover_non_aes_release_blocked++;

    // ---- control 2: AES source meeting every release precondition -> allowed
    $display("--- control_aes_release_legal ---");
    clear_metrics();
    m.ocp_lock_in_progress = 1'b1;
    m.kv_write_src         = (KV_NUM_WRITE'(1) << KV_WRITE_IDX_AES);
    m.kv_write_entry       = OCP_LOCK_KEY_RELEASE_KV_SLOT;
    m.aes_decrypt_ecb_op   = 1'b1;
    m.kv_data0_present     = 1'b1;
    m.kv_data0_entry       = OCP_LOCK_RT_OBF_KEY_KV_SLOT;
    drive_and_sample(allowed);
    report("control_aes_release_legal", 1'b1, allowed);

    // ---- control 3: non-AES source, forwarded input, but NOT the release slot
    //      -> the lock_to_lock rule must still catch a LOCK-source write that
    //      leaves the LOCK region, proving the harness sees rejections at all.
    $display("--- control_non_aes_lock_source_leaves_region ---");
    clear_metrics();
    m.ocp_lock_in_progress = 1'b1;
    m.kv_write_src         = (KV_NUM_WRITE'(1) << KV_WRITE_IDX_HMAC);
    m.kv_write_entry       = 5;                       // a STD slot
    m.kv_data0_present     = 1'b1;
    m.kv_data0_entry       = OCP_LOCK_RT_OBF_KEY_KV_SLOT;  // a LOCK slot
    drive_and_sample(allowed);
    report("control_non_aes_lock_source_leaves_region", 1'b0, allowed);

    // ---- violating case: non-AES source writing the release slot, with a
    //      forwarded KV source in the LOCK region so no other rule fires.
    //      kv_data0_entry is the release slot itself, so lock_to_lock is
    //      satisfied (LOCK source, LOCK destination) and rule (a) is the only
    //      rule that should reject this write.
    $display("--- violating_non_aes_release_with_forward ---");
    clear_metrics();
    m.ocp_lock_in_progress = 1'b1;
    m.kv_write_src         = (KV_NUM_WRITE'(1) << KV_WRITE_IDX_HMAC);
    m.kv_write_entry       = OCP_LOCK_KEY_RELEASE_KV_SLOT;
    m.kv_data0_present     = 1'b1;
    m.kv_data0_entry       = OCP_LOCK_KEY_RELEASE_KV_SLOT;
    m.aes_decrypt_ecb_op   = 1'b0;
    drive_and_sample(allowed);
    $display("    metrics: ocp_lock=1 src=HMAC(bit%0d) dst=KV%0d data0_present=1 data0_entry=KV%0d aes_ecb=0",
             KV_WRITE_IDX_HMAC, OCP_LOCK_KEY_RELEASE_KV_SLOT,
             OCP_LOCK_KEY_RELEASE_KV_SLOT);
    report("violating_non_aes_release_with_forward", 1'b0, allowed);
    if (allowed === 1'b1) begin
      witness_hits++;
      cover_non_aes_release_allowed++;
      $display("  OBSERVED: BUG_027_WITNESS_OBSERVED write_allow=1 for a non-AES engine writing KV%0d under OCP lock",
               OCP_LOCK_KEY_RELEASE_KV_SLOT);
    end

    // ---- the same violating stimulus with the forward flag cleared, to show
    //      the single input that flips the verdict.
    $display("--- discriminator: same stimulus, kv_data0_present=0 ---");
    clear_metrics();
    m.ocp_lock_in_progress = 1'b1;
    m.kv_write_src         = (KV_NUM_WRITE'(1) << KV_WRITE_IDX_HMAC);
    m.kv_write_entry       = OCP_LOCK_KEY_RELEASE_KV_SLOT;
    m.kv_data0_present     = 1'b0;
    drive_and_sample(allowed);
    $display("    write_allow=%0b with the only changed input being kv_data0_present", allowed);
    if (allowed === 1'b0) cover_non_aes_release_blocked++;

    $display("cover_non_aes_release_allowed=%0d", cover_non_aes_release_allowed);
    $display("cover_non_aes_release_blocked=%0d", cover_non_aes_release_blocked);
    $display("checks=%0d fails=%0d witness_hits=%0d", checks, fails, witness_hits);

    // Three controls must hold and the violating case must miss its expectation
    // exactly once, so fails==1 is the expected outcome.
    if (checks == 4 && fails == 1 && witness_hits == 1 &&
        cover_non_aes_release_allowed == 1 && cover_non_aes_release_blocked == 2) begin
      $display("result=PASS");
      $display("PROOF_RESULT: PASS");
    end
    else begin
      // Deliberately no "result=" line here. The negative control expects this
      // branch, and a result=FAIL marker in its log is indistinguishable from a
      // genuinely broken proof run to anything scanning the logs. PROOF_RESULT
      // is the verdict the scripts key on.
      $display("PROOF_RESULT: FAIL");
    end
    $finish;
  end

  initial begin
    #200000;
    $display("TBFAIL global timeout");
    $display("PROOF_RESULT: FAIL");
    $finish;
  end

endmodule
