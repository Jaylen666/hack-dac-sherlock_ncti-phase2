// SPDX-License-Identifier: Apache-2.0
//
// BUG-028 directed witness: the standard-region destination bound is short by one
// slot, so KV15 is misclassified as being outside the standard region.
//
// Property under test: the standard KeyVault region is slots 0 through
// KV_STANDARD_SLOT_HI inclusive, which src/keyvault/rtl/kv_defines_pkg.sv:36 fixes
// at 15. A write whose source is a standard slot and whose destination is also a
// standard slot stays inside the region and must not be rejected by the std_to_std
// rule.
//
// The implemented destination classifier at src/keyvault/rtl/kv_write_rule_check.sv
// :87-88 uses the range [KV_STANDARD_SLOT_LOW:KV_STANDARD_SLOT_HI-1], excluding the
// top slot, while the two source classifiers at :69-74 use the full bound. Because
// the destination signal is consumed only under negation at :116, the asymmetry can
// only add rejections; this testbench establishes both halves of that claim, the
// wrongly rejected legal write and the absence of any new grant.
//
// One DUT instance, driven only through its module ports. No internal force is
// used anywhere in this testbench.
//
`timescale 1ns/1ps

module kv_write_rule_check_bug_028_tb;
  import kv_defines_pkg::*;

  localparam int unsigned CLK_HALF = 5;
  localparam int unsigned STD_TOP  = KV_STANDARD_SLOT_HI;      // 15
  localparam int unsigned STD_MID  = KV_STANDARD_SLOT_HI - 1;  // 14

  logic clk;
  logic rst_b;
  kv_write_filter_metrics_t m;
  logic write_allow;

  int unsigned checks;
  int unsigned fails;
  int unsigned witness_hits;
  int unsigned cover_std_top_blocked;
  int unsigned cover_std_mid_allowed;
  int unsigned cover_lock_src_to_std_top_blocked;

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

  // write_allow is a registered output, so present the metrics and let the
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

  // A standard-region write by a non-AES engine: source slot in STD, destination
  // chosen by the caller. Nothing here touches the LOCK region.
  task automatic drive_std_to_std(input int unsigned dst_slot,
                                  input int unsigned src_slot);
    clear_metrics();
    m.ocp_lock_in_progress = 1'b1;
    m.kv_write_src         = (KV_NUM_WRITE'(1) << KV_WRITE_IDX_HMAC);
    m.kv_write_entry       = dst_slot[KV_ENTRY_ADDR_W-1:0];
    m.kv_data0_present     = 1'b1;
    m.kv_data0_entry       = src_slot[KV_ENTRY_ADDR_W-1:0];
    $display("      metrics: ocp_lock=1 src=HMAC data0_entry=KV%0d dst=KV%0d",
             src_slot, dst_slot);
  endtask

  initial begin
    logic allowed;

    checks       = 0;
    fails        = 0;
    witness_hits = 0;
    cover_std_top_blocked             = 0;
    cover_std_mid_allowed             = 0;
    cover_lock_src_to_std_top_blocked = 0;

    $display("===== BUG-028 directed witness: standard-region destination bound =====");
    $display("KV_STANDARD_SLOT_LOW=%0d KV_STANDARD_SLOT_HI=%0d",
             KV_STANDARD_SLOT_LOW, KV_STANDARD_SLOT_HI);
    $display("destination classifier upper bound as implemented: %0d",
             KV_STANDARD_SLOT_HI - 1);

    apply_reset();

    // ---- control 1: STD source -> STD slot 14, well inside the bound.
    // This must be allowed, and it shows the harness can produce a grant at all.
    $display("--- control_std_to_std_mid_slot ---");
    drive_std_to_std(STD_MID, 5);
    drive_and_sample(allowed);
    report("control_std_to_std_mid_slot", 1'b1, allowed);
    if (allowed) cover_std_mid_allowed++;

    // ---- control 2: STD source -> STD slot 0, the low bound.
    $display("--- control_std_to_std_low_slot ---");
    drive_std_to_std(KV_STANDARD_SLOT_LOW, 5);
    drive_and_sample(allowed);
    report("control_std_to_std_low_slot", 1'b1, allowed);

    // ---- violating case: STD source -> STD slot 15, the top of the region.
    // Both endpoints are standard slots, so std_to_std has no reason to fire.
    $display("--- violating_std_to_std_top_slot ---");
    drive_std_to_std(STD_TOP, 5);
    drive_and_sample(allowed);
    report("violating_std_to_std_top_slot", 1'b1, allowed);
    if (!allowed) begin
      witness_hits++;
      cover_std_top_blocked++;
      $display("  OBSERVED: BUG_028_WITNESS_OBSERVED write_allow=0 for a legal standard-to-standard write into KV%0d", STD_TOP);
    end

    // ---- discriminator: same stimulus with the destination moved down by one.
    // The only changed input is kv_write_entry, 15 -> 14.
    $display("--- discriminator: same stimulus, dst=KV%0d ---", STD_MID);
    drive_std_to_std(STD_MID, 5);
    drive_and_sample(allowed);
    if (allowed)
      $display("      write_allow=1 with the only changed input being kv_write_entry");

    // ---- containment check: a LOCK-region source writing the same KV15 must
    // still be rejected. This is what decides whether the off-by-one opens a
    // cross-region path, and it must stay blocked by the lock_to_lock rule.
    $display("--- containment_lock_src_to_std_top_slot ---");
    clear_metrics();
    m.ocp_lock_in_progress = 1'b1;
    m.kv_write_src         = (KV_NUM_WRITE'(1) << KV_WRITE_IDX_HMAC);
    m.kv_write_entry       = STD_TOP[KV_ENTRY_ADDR_W-1:0];
    m.kv_data0_present     = 1'b1;
    m.kv_data0_entry       = OCP_LOCK_RT_OBF_KEY_KV_SLOT;  // KV16, a LOCK slot
    $display("      metrics: ocp_lock=1 src=HMAC data0_entry=KV%0d (LOCK) dst=KV%0d",
             OCP_LOCK_RT_OBF_KEY_KV_SLOT, STD_TOP);
    drive_and_sample(allowed);
    report("containment_lock_src_to_std_top_slot", 1'b0, allowed);
    if (!allowed) begin
      cover_lock_src_to_std_top_blocked++;
      $display("      LOCK-region data is still refused entry to KV%0d, so the off-by-one does not open a cross-region path", STD_TOP);
    end

    $display("");
    $display("cover_std_mid_allowed=%0d", cover_std_mid_allowed);
    $display("cover_std_top_blocked=%0d", cover_std_top_blocked);
    $display("cover_lock_src_to_std_top_blocked=%0d", cover_lock_src_to_std_top_blocked);
    $display("checks=%0d fails=%0d witness_hits=%0d", checks, fails, witness_hits);

    // Four checks. Three controls must hold; the violating case must miss its
    // expectation exactly once, so fails==1 is the expected outcome.
    if (checks == 4 && fails == 1 && witness_hits == 1 &&
        cover_std_mid_allowed == 1 && cover_std_top_blocked == 1 &&
        cover_lock_src_to_std_top_blocked == 1) begin
      $display("result=PASS");
      $display("PROOF_RESULT: PASS");
    end
    else begin
      // Deliberately no "result=" line here; see the note in the BUG-027 harness.
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
