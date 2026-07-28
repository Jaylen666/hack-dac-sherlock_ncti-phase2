// SPDX-License-Identifier: Apache-2.0
//
// Directed simulation of the KeyVault read-side release-slot rule.
//
// Purpose
// -------
// The rule under test (src/keyvault/rtl/kv_read_rule_check.sv) is intended to
// deny any non-DMA consumer a read of the OCP Lock release slot while OCP Lock
// provisioning is in progress. The implemented destination classification at
// src/keyvault/rtl/kv_read_rule_check.sv:64 is a reduction-OR over a bitwise
// AND against the DMA one-hot mask:
//
//     assign dest_selects_dma = |(read_metrics.kv_read_dest & DMA_DEST_ONEHOT);
//
// This testbench measures read_allow for three release-slot read requests that
// differ only in the destination vector, so that the classification behavior is
// observed directly at the module boundary rather than inferred:
//
//   CONTROL_A  dest = HMAC-key one-hot          expect read_allow = 0 (denied)
//   CONTROL_B  dest = DMA-data one-hot          expect read_allow = 1 (granted)
//   PROBE      dest = DMA-data | HMAC-key       measured, not asserted
//
// PROBE is a probe, not a witness. It establishes what the expression does for
// a multi-hot destination vector. Whether any instantiated read client in the
// submitted tree can present such a vector is a separate question, settled by
// the structural audit in proof/scripts/audit_kv_read_dest_producers.sh. This
// testbench deliberately makes no reachability claim.
//
// Exactly one DUT is compiled. Stimulus is applied at the module ports only;
// no internal signal is forced and no hierarchical reference is used, so the
// measured grant is the module's own port-level behavior.

module kv_read_rule_check_release_slot_tb;
  import kv_defines_pkg::*;

  logic                      clk;
  logic                      rst_b;
  logic                      read_en_i;
  logic                      read_done;
  logic                      read_en_o;
  kv_read_filter_metrics_t   read_metrics;
  logic                      read_allow;

  int unsigned checks_run    = 0;
  int unsigned checks_failed = 0;

  kv_read_rule_check dut (
    .clk         (clk         ),
    .rst_b       (rst_b       ),
    .read_en_i   (read_en_i   ),
    .read_done   (read_done   ),
    .read_en_o   (read_en_o   ),
    .read_metrics(read_metrics),
    .read_allow  (read_allow  )
  );

  // One full clock period. read_allow is registered on the read_en_i edge
  // (src/keyvault/rtl/kv_read_rule_check.sv:95-107), so the grant is sampled
  // after the rising edge that consumes the request.
  task automatic tick;
    begin
      clk = 1'b0; #5;
      clk = 1'b1; #5;
      clk = 1'b0; #5;
    end
  endtask

  task automatic reset_dut;
    begin
      clk          = 1'b0;
      rst_b        = 1'b0;
      read_en_i    = 1'b0;
      read_done    = 1'b0;
      read_metrics = '0;
      repeat (2) tick();
      rst_b = 1'b1;
      tick();
    end
  endtask

  // Issue one release-slot read with the given destination vector and return
  // the granted/denied decision. read_done is pulsed afterwards so the grant
  // window closes and the next request starts from a clean state.
  task automatic issue_release_slot_read(input  logic [KV_NUM_READ-1:0] dest,
                                         output logic                   allow_o);
    begin
      read_metrics.ocp_lock_in_progress = 1'b1;
      read_metrics.kv_key_entry         = OCP_LOCK_KEY_RELEASE_KV_SLOT;
      read_metrics.kv_read_dest         = dest;
      read_en_i                         = 1'b1;
      tick();
      read_en_i                         = 1'b0;
      #1;
      allow_o                           = read_allow;
      read_done                         = 1'b1;
      tick();
      read_done                         = 1'b0;
      read_metrics                      = '0;
      tick();
    end
  endtask

  task automatic expect_allow(input string        tag,
                              input logic         observed,
                              input logic         expected);
    begin
      checks_run++;
      if (observed !== expected) begin
        checks_failed++;
        $display("FAIL: %s observed read_allow=%0b expected=%0b", tag, observed, expected);
      end
      else begin
        $display("ok:   %s read_allow=%0b as expected", tag, observed);
      end
    end
  endtask

  localparam logic [KV_NUM_READ-1:0] DEST_HMAC_KEY =
      KV_NUM_READ'(1) << KV_DEST_IDX_HMAC_KEY;
  localparam logic [KV_NUM_READ-1:0] DEST_DMA_DATA =
      KV_NUM_READ'(1) << KV_DEST_IDX_DMA_DATA;

  initial begin
    logic allow_hmac_only;
    logic allow_dma_only;
    logic allow_dma_plus_hmac;

    $display("=== kv_bug_025 release-slot destination classification ===");
    $display("release_slot=%0d dma_dest_idx=%0d hmac_key_dest_idx=%0d kv_num_read=%0d",
             OCP_LOCK_KEY_RELEASE_KV_SLOT, KV_DEST_IDX_DMA_DATA,
             KV_DEST_IDX_HMAC_KEY, KV_NUM_READ);

    reset_dut();

    // CONTROL_A: the rule must deny a pure non-DMA consumer. If this were to
    // pass unexpectedly the rule would be inert and every later measurement
    // would be vacuous, so this control also serves as the non-vacuity gate.
    issue_release_slot_read(DEST_HMAC_KEY, allow_hmac_only);
    $display("CONTROL_A dest=HMAC_KEY_onehot(0x%0h) read_allow=%0b",
             DEST_HMAC_KEY, allow_hmac_only);
    expect_allow("CONTROL_A non-DMA release-slot read is denied", allow_hmac_only, 1'b0);

    // CONTROL_B: the rule must permit the sanctioned DMA data path.
    issue_release_slot_read(DEST_DMA_DATA, allow_dma_only);
    $display("CONTROL_B dest=DMA_DATA_onehot(0x%0h) read_allow=%0b",
             DEST_DMA_DATA, allow_dma_only);
    expect_allow("CONTROL_B DMA release-slot read is granted", allow_dma_only, 1'b1);

    // PROBE: measured behavior for a multi-hot destination vector. Recorded,
    // not asserted, because the reachability of this input is decided by the
    // structural audit rather than by this simulation.
    issue_release_slot_read(DEST_DMA_DATA | DEST_HMAC_KEY, allow_dma_plus_hmac);
    $display("PROBE     dest=DMA_DATA|HMAC_KEY(0x%0h) read_allow=%0b",
             DEST_DMA_DATA | DEST_HMAC_KEY, allow_dma_plus_hmac);
    $display("probe_multihot_classified_as_dma=%0b", allow_dma_plus_hmac);

    // Zero-destination case. Recorded so the withdrawal stated in the plan is
    // backed by a measurement: a reduction-OR and an equality comparison agree
    // here, both denying the read.
    begin
      logic allow_zero_dest;
      issue_release_slot_read('0, allow_zero_dest);
      $display("PROBE     dest=all_zero(0x0) read_allow=%0b", allow_zero_dest);
      expect_allow("PROBE zero-destination release-slot read is denied", allow_zero_dest, 1'b0);
    end

    $display("checks_run=%0d checks_failed=%0d", checks_run, checks_failed);
    if (checks_failed != 0) begin
      $display("result=FAIL");
      $fatal(1, "kv_bug_025 directed simulation controls did not hold");
    end
    $display("result=PASS");
    $finish;
  end
endmodule
