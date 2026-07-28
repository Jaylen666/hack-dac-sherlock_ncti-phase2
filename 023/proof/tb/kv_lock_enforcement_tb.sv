// SPDX-License-Identifier: Apache-2.0
//
// Directed simulation of KeyVault lock enforcement and lock stickiness.
//
// Purpose
// -------
// The candidate under test alleges that the hardware set path for the KeyVault
// lock bits is absent, so a slot that a boot-stage policy designates as locked
// can only be locked by software. Before that absence can be called a defect,
// two things have to be established by measurement rather than by inspection:
//
//   1. whether the lock enforcement the in-tree specification does describe
//      actually works, and
//   2. whether a set lock bit is sticky against software, which is the property
//      docs/CaliptraHardwareSpecification.md:2459-2460 states.
//
// If both hold, what remains is only the absence of a hardware set path, and
// whether that is required is a question for the structural audit.
//
// The lock bits are software-writable registers, so this testbench drives real
// AHB writes and reads to KEY_CTRL rather than forcing internal state. The read
// and write results are observed through the module's own kv_rd_resp and
// kv_wr_resp ports, so what is measured is what a crypto engine would see.
//
//   CONTROL_A  an unlocked provisioned entry is readable by its granted client
//              (non-vacuity gate: without this nothing below is meaningful)
//   CONTROL_B  after an AHB write setting lock_use, the same read is suppressed
//   CONTROL_C  an AHB write of zero to KEY_CTRL does NOT clear the set lock_use
//   CONTROL_D  with lock_wr set on a second entry, a write client is suppressed
//              and its write error is raised
//   PROBE_A    the state of a set lock bit while fw_update_rst_window is
//              asserted, and whether the entry becomes readable during it
//   PROBE_B    the state of a set lock bit after a core_only_rst_b pulse, and
//              whether the key data survives that same pulse
//
// The CONTROLs are asserted because they are the properties the in-tree
// specification states. The PROBEs are measured and reported without an
// expectation, because whether their outcome is a violation depends on which
// in-tree sentence governs them, which the audit settles.
//
// Exactly one DUT is compiled, driven at its ports only: no forced internals and
// no hierarchical references into the register block.

`include "caliptra_macros.svh"

module kv_lock_enforcement_tb;
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

  // KEY_CTRL[entry] sits at offset 4*entry per the KeyVault register map.
  localparam logic [KV_ADDR_W-1:0] KEY_CTRL_BASE = '0;
  localparam logic [31:0] LOCK_WR_MASK  = 32'h0000_0001;
  localparam logic [31:0] LOCK_USE_MASK = 32'h0000_0002;

  localparam logic [31:0] USE_KEY_DWORD = 32'hDEAD_BE01;
  localparam logic [31:0] WR_KEY_DWORD  = 32'hDEAD_BE02;
  localparam logic [31:0] REWRITE_DWORD = 32'h1111_2222;
  localparam int USE_ENTRY = 1;  // exercised for lock_use
  localparam int WR_ENTRY  = 2;  // exercised for lock_wr

  int unsigned checks_run    = 0;
  int unsigned checks_failed = 0;

  kv #(
    .AHB_ADDR_WIDTH(KV_ADDR_W),
    .AHB_DATA_WIDTH(32)
  ) dut (.*);

  // Free-running clock; AHB tasks synchronise to its edges.
  initial clk = 1'b0;
  always #5 clk = ~clk;

  task automatic bring_up;
    begin
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
      repeat (3) @(posedge clk);
      cptra_pwrgood   = 1'b1;
      rst_b           = 1'b1;
      core_only_rst_b = 1'b1;
      repeat (3) @(posedge clk);
    end
  endtask

  // Single-beat AHB-Lite write: address phase then data phase.
  task automatic ahb_write(input logic [KV_ADDR_W-1:0] addr,
                           input logic [31:0]          data);
    begin
      @(negedge clk);
      hsel_i   = 1'b1;
      hwrite_i = 1'b1;
      htrans_i = 2'b10;      // NONSEQ
      hsize_i  = 3'b010;     // word
      haddr_i  = addr;
      @(negedge clk);
      htrans_i = 2'b00;      // IDLE
      hwdata_i = data;
      @(negedge clk);
      hsel_i   = 1'b0;
      hwrite_i = 1'b0;
      hwdata_i = '0;
      haddr_i  = '0;
      repeat (2) @(posedge clk);
    end
  endtask

  // Single-beat AHB-Lite read; the data is captured from hrdata_o.
  //
  // Sampling point matters here. The AHB shim registers the request into its
  // component-side dv on the clock edge after the address phase, and the
  // register block's read data is combinational off that dv. So the data is
  // valid only in the cycle immediately following the address-phase edge, and
  // sampling a cycle later reads back zero even when the register holds a one.
  // Stimulus is driven on negedge and data is sampled just after the posedge
  // that asserts dv.
  task automatic ahb_read(input  logic [KV_ADDR_W-1:0] addr,
                          output logic [31:0]          data);
    begin
      @(negedge clk);
      hsel_i   = 1'b1;
      hwrite_i = 1'b0;
      htrans_i = 2'b10;
      hsize_i  = 3'b010;
      haddr_i  = addr;
      @(posedge clk);
      #1;
      data     = hrdata_o;
      @(negedge clk);
      htrans_i = 2'b00;
      hsel_i   = 1'b0;
      haddr_i  = '0;
      repeat (2) @(posedge clk);
    end
  endtask

  function automatic logic [KV_ADDR_W-1:0] key_ctrl_addr(input int entry);
    key_ctrl_addr = KEY_CTRL_BASE + KV_ADDR_W'(4 * entry);
  endfunction

  // Provision an entry through a write client, granting read permission to the
  // HMAC-key destination. The entry is left unlocked.
  task automatic provision_entry(input int entry, input logic [31:0] data);
    begin
      @(negedge clk);
      kv_write[KV_WRITE_IDX_HMAC].write_en         = 1'b1;
      kv_write[KV_WRITE_IDX_HMAC].write_entry      = entry;
      kv_write[KV_WRITE_IDX_HMAC].write_offset     = '0;
      kv_write[KV_WRITE_IDX_HMAC].write_data       = data;
      kv_write[KV_WRITE_IDX_HMAC].write_dest_valid = KV_NUM_READ'(1) << KV_DEST_IDX_HMAC_KEY;
      @(posedge clk);
      @(negedge clk);
      kv_write[KV_WRITE_IDX_HMAC].write_en         = 1'b0;
      kv_write[KV_WRITE_IDX_HMAC].write_dest_valid = '0;
      repeat (2) @(posedge clk);
    end
  endtask

  // Attempt a write to an entry and capture the write client's error response
  // in the same cycle the write is presented.
  task automatic attempt_write(input  int           entry,
                               input  logic [31:0]  data,
                               output logic         wr_error);
    begin
      @(negedge clk);
      kv_write[KV_WRITE_IDX_HMAC].write_en         = 1'b1;
      kv_write[KV_WRITE_IDX_HMAC].write_entry      = entry;
      kv_write[KV_WRITE_IDX_HMAC].write_offset     = '0;
      kv_write[KV_WRITE_IDX_HMAC].write_data       = data;
      kv_write[KV_WRITE_IDX_HMAC].write_dest_valid = KV_NUM_READ'(1) << KV_DEST_IDX_HMAC_KEY;
      #1;
      wr_error = kv_wr_resp[KV_WRITE_IDX_HMAC].error;
      @(posedge clk);
      @(negedge clk);
      kv_write[KV_WRITE_IDX_HMAC].write_en         = 1'b0;
      kv_write[KV_WRITE_IDX_HMAC].write_dest_valid = '0;
      repeat (2) @(posedge clk);
    end
  endtask

  // Point the HMAC-key read client at an entry. The read path is combinational.
  task automatic select_read(input int entry);
    begin
      kv_read[KV_DEST_IDX_HMAC_KEY].read_entry  = entry;
      kv_read[KV_DEST_IDX_HMAC_KEY].read_offset = '0;
      #1;
    end
  endtask

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

  task automatic expect_bit(input string tag,
                            input logic observed,
                            input logic expected);
    begin
      checks_run++;
      if (observed !== expected) begin
        checks_failed++;
        $display("FAIL: %s observed=%0b expected=%0b", tag, observed, expected);
      end
      else begin
        $display("ok:   %s value=%0b as expected", tag, observed);
      end
    end
  endtask

  initial begin
    logic [31:0] ctrl_readback;
    logic [31:0] rd_unlocked;
    logic [31:0] rd_locked;
    logic [31:0] rd_after_clear_attempt;
    logic [31:0] rd_in_fw_window;
    logic [31:0] rd_after_uc_reset;
    logic [31:0] ctrl_in_fw_window;
    logic [31:0] ctrl_after_uc_reset;
    logic        wr_error_locked;
    logic        wr_error_unlocked;
    logic [31:0] wr_entry_data_after;

    $display("=== kv_bug_023 KeyVault lock enforcement and lock stickiness ===");
    $display("use_entry=%0d wr_entry=%0d read_dest=HMAC_KEY(idx %0d)",
             USE_ENTRY, WR_ENTRY, KV_DEST_IDX_HMAC_KEY);

    bring_up();

    // --- CONTROL_A: an unlocked provisioned entry is readable -------------
    provision_entry(USE_ENTRY, USE_KEY_DWORD);
    select_read(USE_ENTRY);
    rd_unlocked = kv_rd_resp[KV_DEST_IDX_HMAC_KEY].read_data;
    $display("CONTROL_A unlocked entry read_data=0x%08h rd_error=%0b",
             rd_unlocked, kv_rd_resp[KV_DEST_IDX_HMAC_KEY].error);
    expect_eq("CONTROL_A unlocked entry is readable by its granted client",
              rd_unlocked, USE_KEY_DWORD);

    // --- CONTROL_B: setting lock_use over AHB suppresses the read ---------
    ahb_write(key_ctrl_addr(USE_ENTRY), LOCK_USE_MASK);
    ahb_read(key_ctrl_addr(USE_ENTRY), ctrl_readback);
    $display("CONTROL_B KEY_CTRL[%0d] readback=0x%08h lock_use=%0b",
             USE_ENTRY, ctrl_readback, |(ctrl_readback & LOCK_USE_MASK));
    expect_bit("CONTROL_B software write set lock_use",
               |(ctrl_readback & LOCK_USE_MASK), 1'b1);
    select_read(USE_ENTRY);
    rd_locked = kv_rd_resp[KV_DEST_IDX_HMAC_KEY].read_data;
    $display("CONTROL_B locked entry read_data=0x%08h rd_error=%0b",
             rd_locked, kv_rd_resp[KV_DEST_IDX_HMAC_KEY].error);
    expect_eq("CONTROL_B lock_use suppresses the read to zero", rd_locked, 32'h0);
    expect_bit("CONTROL_B lock_use raises the client read error",
               kv_rd_resp[KV_DEST_IDX_HMAC_KEY].error, 1'b1);

    // --- CONTROL_C: the set lock is sticky against software --------------
    // docs/CaliptraHardwareSpecification.md:2459-2460 states a set lock cannot
    // be reset until the designated reset de-asserts. Write zero and check.
    ahb_write(key_ctrl_addr(USE_ENTRY), 32'h0);
    ahb_read(key_ctrl_addr(USE_ENTRY), ctrl_readback);
    $display("CONTROL_C after software write of zero KEY_CTRL[%0d]=0x%08h lock_use=%0b",
             USE_ENTRY, ctrl_readback, |(ctrl_readback & LOCK_USE_MASK));
    expect_bit("CONTROL_C software cannot clear a set lock_use",
               |(ctrl_readback & LOCK_USE_MASK), 1'b1);
    select_read(USE_ENTRY);
    rd_after_clear_attempt = kv_rd_resp[KV_DEST_IDX_HMAC_KEY].read_data;
    $display("CONTROL_C read after clear attempt read_data=0x%08h", rd_after_clear_attempt);
    expect_eq("CONTROL_C read stays suppressed after the clear attempt",
              rd_after_clear_attempt, 32'h0);

    // --- CONTROL_D: lock_wr suppresses a write client --------------------
    provision_entry(WR_ENTRY, WR_KEY_DWORD);
    attempt_write(WR_ENTRY, REWRITE_DWORD, wr_error_unlocked);
    $display("CONTROL_D unlocked write attempt wr_error=%0b", wr_error_unlocked);
    expect_bit("CONTROL_D an unlocked write raises no error", wr_error_unlocked, 1'b0);
    ahb_write(key_ctrl_addr(WR_ENTRY), LOCK_WR_MASK);
    ahb_read(key_ctrl_addr(WR_ENTRY), ctrl_readback);
    expect_bit("CONTROL_D software write set lock_wr",
               |(ctrl_readback & LOCK_WR_MASK), 1'b1);
    attempt_write(WR_ENTRY, 32'hFFFF_FFFF, wr_error_locked);
    $display("CONTROL_D locked write attempt wr_error=%0b", wr_error_locked);
    expect_bit("CONTROL_D lock_wr raises the client write error", wr_error_locked, 1'b1);
    // The write must also not land. WR_ENTRY was provisioned with dest_valid for
    // the HMAC-key client and lock_wr does not suppress reads, so read it back.
    select_read(WR_ENTRY);
    wr_entry_data_after = kv_rd_resp[KV_DEST_IDX_HMAC_KEY].read_data;
    $display("CONTROL_D locked entry data after the suppressed write=0x%08h",
             wr_entry_data_after);
    expect_eq("CONTROL_D the suppressed write did not change the entry",
              wr_entry_data_after, REWRITE_DWORD);

    // --- PROBE_A: the fw_update_rst_window --------------------------------
    // Measured, not asserted. src/keyvault/rtl/kv.sv:176-177 qualifies both
    // lock terms with ~fw_update_rst_window to avoid a reset-domain-crossing
    // violation, so this records what that qualification does to enforcement.
    fw_update_rst_window = 1'b1;
    repeat (2) @(posedge clk);
    select_read(USE_ENTRY);
    rd_in_fw_window = kv_rd_resp[KV_DEST_IDX_HMAC_KEY].read_data;
    ahb_read(key_ctrl_addr(USE_ENTRY), ctrl_in_fw_window);
    $display("PROBE_A   fw_update_rst_window=1 KEY_CTRL[%0d]=0x%08h lock_use_bit=%0b read_data=0x%08h",
             USE_ENTRY, ctrl_in_fw_window, |(ctrl_in_fw_window & LOCK_USE_MASK),
             rd_in_fw_window);
    $display("probe_locked_entry_readable_in_fw_window=%0b",
             (rd_in_fw_window === USE_KEY_DWORD));
    fw_update_rst_window = 1'b0;
    repeat (2) @(posedge clk);
    select_read(USE_ENTRY);
    $display("PROBE_A   after the window closes read_data=0x%08h",
             kv_rd_resp[KV_DEST_IDX_HMAC_KEY].read_data);

    // --- PROBE_B: a core_only_rst_b pulse ---------------------------------
    // Measured, not asserted. src/keyvault/rtl/kv_reg.rdl:28-31 names
    // core_only_rst_b as the lock fields' resetsignal, while the key data
    // fields at src/keyvault/rtl/kv_reg.rdl:22 reset on hard_reset_b.
    core_only_rst_b = 1'b0;
    repeat (3) @(posedge clk);
    core_only_rst_b = 1'b1;
    repeat (3) @(posedge clk);
    ahb_read(key_ctrl_addr(USE_ENTRY), ctrl_after_uc_reset);
    select_read(USE_ENTRY);
    rd_after_uc_reset = kv_rd_resp[KV_DEST_IDX_HMAC_KEY].read_data;
    $display("PROBE_B   after core_only_rst_b pulse KEY_CTRL[%0d]=0x%08h lock_use_bit=%0b read_data=0x%08h",
             USE_ENTRY, ctrl_after_uc_reset, |(ctrl_after_uc_reset & LOCK_USE_MASK),
             rd_after_uc_reset);
    $display("probe_lock_use_survives_core_only_reset=%0b",
             |(ctrl_after_uc_reset & LOCK_USE_MASK));
    $display("probe_key_data_survives_core_only_reset=%0b",
             (rd_after_uc_reset === USE_KEY_DWORD));

    $display("checks_run=%0d checks_failed=%0d", checks_run, checks_failed);
    if (checks_failed != 0) begin
      $display("result=FAIL");
      $fatal(1, "kv_bug_023 directed simulation controls did not hold");
    end
    $display("result=PASS");
    $finish;
  end
endmodule
