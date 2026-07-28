// SPDX-License-Identifier: Apache-2.0
//
// Directed witness for contest bug 001.
//
// Property under test (secret clearing on entry to an insecure state):
//   aes_clp_wrapper drives caliptra2aes.clear_secrets from
//   debugUnlock_or_scan_mode_switch, i.e. the signal asserts when the device
//   enters debug-unlocked or scan mode. CaliptraHardwareSpecification.md
//   requires that entering debug triggers a hardware clear of device secrets.
//   The AES KeyVault export buffer aes2caliptra.kv_data_out and its valid bit
//   aes2caliptra.kv_data_out_valid hold an AES result destined for KeyVault,
//   which is exactly such a secret. Therefore asserting clear_secrets must
//   clear both.
//
// Method:
//   One real `aes` DUT is compiled and instantiated. The KeyVault export
//   buffer is loaded through the module's own capture path, which is reached
//   in normal operation by an AES-with-KeyVault-destination flow. To keep the
//   witness short and deterministic, the internal capture controls on that
//   same path are driven directly for the load phase only. All such drives are
//   released before the observation phase, so every clear decision that this
//   testbench reports is produced solely by the DUT's own logic.
//
// Cases:
//   control_data_out_clear : the firmware clear trigger must empty the buffer
//   control_kv_write_done  : consumption by KeyVault must empty the buffer
//   violating_clear_secrets: entering the insecure state must empty the buffer
//                            but does not

`timescale 1ns/1ps

module aes_bug_001_tb
  import aes_pkg::*;
  import caliptra_prim_mubi_pkg::*;
  import caliptra_prim_alert_pkg::*;
  import caliptra_tlul_pkg::*;
  import lc_ctrl_pkg::*;
  import keymgr_pkg::*;
  import edn_pkg::*;
  import aes_reg_pkg::*;
;

  localparam int KV_DW    = CLP_AES_KV_WR_DW;          // 512
  localparam int CHUNK    = 128;                       // NumRegsData*32
  localparam int NCHUNK   = KV_DW / CHUNK;             // 4

  // Distinctive per-chunk payload so a stale buffer is unmistakable.
  function automatic logic [31:0] secret_word(int chunk, int word);
    return 32'h5EC00000 | (chunk << 8) | word;
  endfunction

  logic clk = 1'b0;
  logic rst_ni, rst_shadowed_ni;

  caliptra2aes_t caliptra2aes;
  aes2caliptra_t aes2caliptra;

  mubi4_t          idle_o;
  lc_tx_t          lc_escalate_en_i;
  edn_req_t        edn_o;
  edn_rsp_t        edn_i;
  logic            input_ready_o, output_valid_o;
  hw_key_req_t     keymgr_key_i;
  tl_h2d_t         tl_i;
  tl_d2h_t         tl_o;
  alert_rx_t [aes_reg_pkg::NumAlerts-1:0] alert_rx_i;
  alert_tx_t [aes_reg_pkg::NumAlerts-1:0] alert_tx_o;

  int unsigned checks = 0;
  int unsigned fails = 0;
  int unsigned witness_hits = 0;

  // Static staging registers. `force` may not reference automatic variables,
  // so the load payload and chunk index live at module scope.
  logic [31:0] stage_word [4];
  logic [$clog2(KV_DW/CHUNK)-1:0] stage_idx;

  // TRIGGER.DATA_OUT_CLEAR resets asserted and is deasserted by the AES
  // control FSM once a clear has completed, so 0 is its normal state while a
  // result is being exported. This testbench holds that normal state rather
  // than running a full AES operation to reach it.
  logic tb_data_out_clear;

  always #5 clk = ~clk;

  aes #(
    .SecMasking(1),
    .SecAllowForcingMasks(0)
  ) dut (
    .clk_i           (clk             ),
    .rst_ni          (rst_ni          ),
    .rst_shadowed_ni (rst_shadowed_ni ),
    .idle_o          (idle_o          ),
    .lc_escalate_en_i(lc_escalate_en_i),
    .clk_edn_i       (clk             ),
    .rst_edn_ni      (rst_ni          ),
    .edn_o           (edn_o           ),
    .edn_i           (edn_i           ),
    .input_ready_o   (input_ready_o   ),
    .output_valid_o  (output_valid_o  ),
    .caliptra2aes    (caliptra2aes    ),
    .aes2caliptra    (aes2caliptra    ),
    .keymgr_key_i    (keymgr_key_i    ),
    .tl_i            (tl_i            ),
    .tl_o            (tl_o            ),
    .alert_rx_i      (alert_rx_i      ),
    .alert_tx_o      (alert_tx_o      )
  );

  // ---------------------------------------------------------------------
  // Load the KeyVault export buffer over the DUT's own capture path.
  // Drives are released at the end, before any clear is evaluated.
  // ---------------------------------------------------------------------
  task automatic load_kv_buffer();
    begin
      tb_data_out_clear = 1'b0;
      force dut.reg2hw_caliptra.trigger.data_out_clear.q = tb_data_out_clear;
      force dut.hw2reg_caliptra.data_out[0].d = stage_word[0];
      force dut.hw2reg_caliptra.data_out[1].d = stage_word[1];
      force dut.hw2reg_caliptra.data_out[2].d = stage_word[2];
      force dut.hw2reg_caliptra.data_out[3].d = stage_word[3];
      force dut.incr_kv_data_counter = 1'b1;
      force dut.kv_data_counter      = stage_idx;
      for (int c = 0; c < NCHUNK; c++) begin
        stage_idx     = c[$clog2(KV_DW/CHUNK)-1:0];
        stage_word[0] = secret_word(c, 0);
        stage_word[1] = secret_word(c, 1);
        stage_word[2] = secret_word(c, 2);
        stage_word[3] = secret_word(c, 3);
        @(posedge clk); #1;
        $display("  stage chunk=%0d counter=%0d threshold=%0d data_out_clear=%0b chunk0=0x%032x",
                 c, dut.kv_data_counter, dut.kv_data_thresh,
                 dut.reg2hw_caliptra.trigger.data_out_clear.q,
                 dut.aes2caliptra_kv_data_out[127:0]);
      end
      // Assert the capture-complete condition so the valid bit latches.
      force dut.incr_kv_data_counter   = 1'b0;
      force dut.kv_data_intercept_end  = 1'b1;
      @(posedge clk); #1;
      force dut.kv_data_intercept_end  = 1'b0;
      @(posedge clk); #1;

      // Hand every capture control back to the DUT. Only
      // TRIGGER.DATA_OUT_CLEAR stays driven, held at the deasserted value that
      // a completed AES flow produces; that is the non-clearing state, so it
      // cannot manufacture the retention this testbench looks for.
      release dut.hw2reg_caliptra.data_out[0].d;
      release dut.hw2reg_caliptra.data_out[1].d;
      release dut.hw2reg_caliptra.data_out[2].d;
      release dut.hw2reg_caliptra.data_out[3].d;
      release dut.incr_kv_data_counter;
      release dut.kv_data_counter;
      release dut.kv_data_intercept_end;
      @(posedge clk); #1;
    end
  endtask

  function automatic bit buffer_holds_secret();
    return (aes2caliptra.kv_data_out != '0);
  endfunction

  task automatic report_state(string tag);
    $display("%s: kv_data_out_valid=%0b kv_data_out[127:0]=0x%032x kv_data_out[511:384]=0x%032x",
             tag, aes2caliptra.kv_data_out_valid,
             aes2caliptra.kv_data_out[127:0],
             aes2caliptra.kv_data_out[511:384]);
  endtask

  // Load, then apply one clear stimulus, then judge.
  // kind: 0 = data_out_clear, 1 = kv_write_done, 2 = clear_secrets
  task automatic run_case(string label, int kind, bit expect_retained);
    bit data_retained;
    bit valid_retained;
    begin
      checks++;

      // Fresh load for every case.
      load_kv_buffer();
      report_state({label, " loaded"});
      if (!buffer_holds_secret() || !aes2caliptra.kv_data_out_valid) begin
        fails++;
        $display("FAIL: %s could not stage the KeyVault export buffer", label);
        return;
      end

      case (kind)
        0: tb_data_out_clear         = 1'b1; // firmware clear trigger
        1: caliptra2aes.kv_write_done = 1'b1; // KeyVault consumed the result
        2: caliptra2aes.clear_secrets = 1'b1; // entry into the insecure state
        default: ;
      endcase

      // Two clocks is ample: both buffers are single-stage registers.
      @(posedge clk); #1;
      @(posedge clk); #1;

      data_retained  = buffer_holds_secret();
      valid_retained = aes2caliptra.kv_data_out_valid;
      report_state({label, " after stimulus"});

      case (kind)
        0: tb_data_out_clear         = 1'b0;
        1: caliptra2aes.kv_write_done = 1'b0;
        2: caliptra2aes.clear_secrets = 1'b0;
        default: ;
      endcase
      release dut.reg2hw_caliptra.trigger.data_out_clear.q;
      @(posedge clk); #1;

      if (expect_retained) begin
        if (data_retained || valid_retained) begin
          witness_hits++;
          $display("WITNESS: %s asserted while the KeyVault export buffer held a secret, and the buffer survived (data_retained=%0b valid_retained=%0b)",
                   label, data_retained, valid_retained);
          $display("PASS: %s reproduced the missing secret clear", label);
        end else begin
          fails++;
          $display("FAIL: %s expected the buffer to survive, but it was cleared", label);
        end
      end else begin
        if (!data_retained && !valid_retained) begin
          $display("PASS: %s cleared both the data buffer and its valid bit", label);
        end else begin
          fails++;
          $display("FAIL: %s control did not clear the buffer (data_retained=%0b valid_retained=%0b)",
                   label, data_retained, valid_retained);
        end
      end
    end
  endtask

  initial begin
    rst_ni           = 1'b0;
    rst_shadowed_ni  = 1'b0;
    lc_escalate_en_i = lc_ctrl_pkg::Off;
    edn_i            = '{edn_ack: 1'b0, edn_fips: 1'b0, edn_bus: '0};
    keymgr_key_i     = '0;
    tl_i             = '0;
    alert_rx_i       = '{default: '{ack_p: 1'b0, ack_n: 1'b1, ping_p: 1'b0, ping_n: 1'b1}};
    caliptra2aes     = '{kv_en: 1'b0, kv_write_done: 1'b0, block_reg_output: 1'b0,
                         clear_secrets: 1'b0, key_release_key_size: 16'd64};

    repeat (5) @(posedge clk);
    rst_ni          = 1'b1;
    rst_shadowed_ni = 1'b1;
    repeat (5) @(posedge clk); #1;

    // Controls: the two clear sources the RTL does honor.
    run_case("control_data_out_clear", 0, 0);
    run_case("control_kv_write_done",  1, 0);

    // Violating case: entry into the insecure state.
    run_case("violating_clear_secrets", 2, 1);

    repeat (2) @(posedge clk);
    $display("checks=%0d fails=%0d witness_hits=%0d", checks, fails, witness_hits);
    if (fails == 0 && witness_hits == 1) begin
      $display("result=PASS");
      $display("BUG_001_WITNESS_OBSERVED");
    end else begin
      $display("result=FAIL");
    end
    $finish;
  end

endmodule
