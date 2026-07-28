// SPDX-License-Identifier: Apache-2.0
//
// Directed simulation of KeyVault entry retention across every stage-like input
// the kv module actually exposes.
//
// Purpose
// -------
// The candidate under test alleges that the KeyVault must clear entries that do
// not belong to the next boot stage's retained set when the boot flow advances,
// and that this per-entry transition clear is absent. This testbench measures
// what the module does, so the claim rests on observation rather than on the
// absence of a signal name.
//
// The kv port list (src/keyvault/rtl/kv.sv:27-56) exposes no boot-stage input.
// The only stage-like inputs are the reset and window signals, so those are what
// this testbench exercises:
//
//   PROBE_A   provision an unlocked entry, then assert fw_update_rst_window
//             (the firmware-update reset window) and re-read.
//   PROBE_B   deassert core_only_rst_b (the microcontroller-only reset, which a
//             firmware-update reset asserts) and re-read.
//   CONTROL   assert debugUnlock_or_scan_mode_switch and confirm the entry IS
//             overwritten with the debug value.
//
// PROBE_A and PROBE_B are measurements, not violations: whether retention across
// them is a defect depends on whether an in-tree requirement demands a clear
// there, which the structural audit settles. CONTROL is asserted, because the
// in-tree integration specification does state that a debug or scan mode
// transition clears key vault assets; if CONTROL failed, the clearing path would
// be broken and every other measurement would be suspect.
//
// Exactly one DUT is compiled and it is driven at its ports only: no forced
// internals and no hierarchical references. Entry data is observed through the
// module's own read response port, so what is measured is what a crypto engine
// would actually receive.

`include "caliptra_macros.svh"

module kv_stage_transition_retention_tb;
  import kv_defines_pkg::*;

  logic clk;
  logic rst_b;
  logic core_only_rst_b;
  logic cptra_pwrgood;
  logic fw_update_rst_window;
  logic cptra_in_debug_scan_mode;
  logic debugUnlock_or_scan_mode_switch;

  logic [KV_ADDR_W-1:0] haddr_i;
  logic [31:0]          hwdata_i;
  logic                 hsel_i;
  logic                 hwrite_i;
  logic                 hready_i;
  logic [1:0]           htrans_i;
  logic [2:0]           hsize_i;
  logic                 hresp_o;
  logic                 hreadyout_o;
  logic [31:0]          hrdata_o;

  kv_read_t    [KV_NUM_READ-1:0]  kv_read;
  kv_write_t   [KV_NUM_WRITE-1:0] kv_write;
  kv_rd_resp_t [KV_NUM_READ-1:0]  kv_rd_resp;
  kv_wr_resp_t [KV_NUM_WRITE-1:0] kv_wr_resp;
  logic [ECC_NUM_DWORDS-1:0][31:0]   pcr_ecc_signing_key;
  logic [MLDSA_NUM_DWORDS-1:0][31:0] pcr_mldsa_signing_key;

  localparam logic [31:0] STAGE_KEY_DWORD = 32'hA5A5_1234;
  localparam int          TEST_ENTRY      = 0;
  // CLEAR_SECRETS.sel_debug_value resets to 0 and this testbench never writes
  // it, so the flush value the module writes is debug value 0.
  localparam logic [31:0] EXPECTED_DEBUG_VALUE = CLP_DEBUG_MODE_KV_0;

  int unsigned checks_run    = 0;
  int unsigned checks_failed = 0;

  kv #(
    .AHB_ADDR_WIDTH(KV_ADDR_W),
    .AHB_DATA_WIDTH(32)
  ) dut (.*);

  task automatic tick;
    begin
      clk = 1'b0; #5;
      clk = 1'b1; #5;
      clk = 1'b0; #5;
    end
  endtask

  task automatic bring_up;
    begin
      clk                             = 1'b0;
      rst_b                           = 1'b0;
      core_only_rst_b                 = 1'b0;
      cptra_pwrgood                   = 1'b0;
      fw_update_rst_window            = 1'b0;
      cptra_in_debug_scan_mode        = 1'b0;
      debugUnlock_or_scan_mode_switch = 1'b0;
      haddr_i                         = '0;
      hwdata_i                        = '0;
      hsel_i                          = 1'b0;
      hwrite_i                        = 1'b0;
      hready_i                        = 1'b1;
      htrans_i                        = 2'b00;
      hsize_i                         = 3'b010;
      kv_read                         = '{default: '0};
      kv_write                        = '{default: '0};
      repeat (3) tick();
      cptra_pwrgood   = 1'b1;
      rst_b           = 1'b1;
      core_only_rst_b = 1'b1;
      repeat (2) tick();
    end
  endtask

  // Provision one entry through a write client, granting read permission to the
  // HMAC-key destination so the entry is legitimately readable afterwards. The
  // entry is deliberately left unlocked, which is the precondition the candidate
  // describes: an earlier stage that wrote key material without locking it.
  task automatic provision_entry(input logic [31:0] data);
    begin
      kv_write[KV_WRITE_IDX_HMAC].write_en         = 1'b1;
      kv_write[KV_WRITE_IDX_HMAC].write_entry      = TEST_ENTRY;
      kv_write[KV_WRITE_IDX_HMAC].write_offset     = '0;
      kv_write[KV_WRITE_IDX_HMAC].write_data       = data;
      kv_write[KV_WRITE_IDX_HMAC].write_dest_valid = KV_NUM_READ'(1) << KV_DEST_IDX_HMAC_KEY;
      tick();
      kv_write[KV_WRITE_IDX_HMAC].write_en         = 1'b0;
      kv_write[KV_WRITE_IDX_HMAC].write_dest_valid = '0;
      tick();
    end
  endtask

  // Point the HMAC-key read client at the provisioned entry. The read path is
  // combinational, so the response settles without a clock edge.
  task automatic select_read;
    begin
      kv_read[KV_DEST_IDX_HMAC_KEY].read_entry  = TEST_ENTRY;
      kv_read[KV_DEST_IDX_HMAC_KEY].read_offset = '0;
      #1;
    end
  endtask

  function automatic logic [31:0] read_entry_as_hmac();
    read_entry_as_hmac = kv_rd_resp[KV_DEST_IDX_HMAC_KEY].read_data;
  endfunction

  task automatic expect_eq(input string tag,
                           input logic [31:0] observed,
                           input logic [31:0] expected);
    begin
      checks_run++;
      if (observed !== expected) begin
        checks_failed++;
        $display("FAIL: %s observed=0x%08h expected=0x%08h", tag, observed, expected);
      end
      else begin
        $display("ok:   %s value=0x%08h as expected", tag, observed);
      end
    end
  endtask

  initial begin
    logic [31:0] after_provision;
    logic [31:0] during_fw_window;
    logic [31:0] after_uc_reset;
    logic [31:0] after_debug_flush;

    $display("=== kv_bug_022 KeyVault retention across stage-like inputs ===");
    $display("test_entry=%0d read_dest=HMAC_KEY(idx %0d) kv_num_keys=%0d",
             TEST_ENTRY, KV_DEST_IDX_HMAC_KEY, KV_NUM_KEYS);

    bring_up();
    provision_entry(STAGE_KEY_DWORD);
    select_read();
    after_provision = read_entry_as_hmac();
    $display("SETUP     provisioned unlocked entry read_data=0x%08h rd_error=%0b",
             after_provision, kv_rd_resp[KV_DEST_IDX_HMAC_KEY].error);
    // Non-vacuity gate: if provisioning failed, nothing downstream means anything.
    expect_eq("SETUP entry is provisioned and readable", after_provision, STAGE_KEY_DWORD);

    // PROBE_A: the firmware-update reset window. Measured, not asserted.
    fw_update_rst_window = 1'b1;
    repeat (2) tick();
    select_read();
    during_fw_window = read_entry_as_hmac();
    $display("PROBE_A   fw_update_rst_window=1 read_data=0x%08h retained=%0b",
             during_fw_window, (during_fw_window === STAGE_KEY_DWORD));
    $display("probe_retained_in_fw_update_window=%0b",
             (during_fw_window === STAGE_KEY_DWORD));
    fw_update_rst_window = 1'b0;
    repeat (2) tick();

    // PROBE_B: the microcontroller-only reset, which a firmware-update reset
    // asserts. Measured, not asserted.
    core_only_rst_b = 1'b0;
    repeat (3) tick();
    core_only_rst_b = 1'b1;
    repeat (2) tick();
    select_read();
    after_uc_reset = read_entry_as_hmac();
    $display("PROBE_B   after core_only_rst_b pulse read_data=0x%08h retained=%0b",
             after_uc_reset, (after_uc_reset === STAGE_KEY_DWORD));
    $display("probe_retained_across_core_only_reset=%0b",
             (after_uc_reset === STAGE_KEY_DWORD));

    // CONTROL: the debug/scan clearing path the in-tree integration
    // specification does require. This must clear, or the module's only
    // asset-clearing path is broken and every measurement above is suspect.
    debugUnlock_or_scan_mode_switch = 1'b1;
    repeat (2) tick();
    debugUnlock_or_scan_mode_switch = 1'b0;
    repeat (2) tick();
    select_read();
    after_debug_flush = read_entry_as_hmac();
    $display("CONTROL   debug/scan switch read_data=0x%08h expected_debug_value=0x%08h",
             after_debug_flush, EXPECTED_DEBUG_VALUE);
    expect_eq("CONTROL debug/scan transition overwrites the entry",
              after_debug_flush, EXPECTED_DEBUG_VALUE);

    $display("checks_run=%0d checks_failed=%0d", checks_run, checks_failed);
    if (checks_failed != 0) begin
      $display("result=FAIL");
      $fatal(1, "kv_bug_022 directed simulation controls did not hold");
    end
    $display("result=PASS");
    $finish;
  end
endmodule
