// SPDX-License-Identifier: Apache-2.0
//
// Directed simulation of the KeyVault flush path and its internal error response.
//
// Purpose
// -------
// The candidate under test alleges two things: that the KeyVault flush responds
// only to a debug or scan mode transition and so does not destroy secrets when a
// fatal error is latched, and that no KeyVault error condition is reported as a
// Caliptra fatal error. Neither can be settled by this testbench alone, because
// both are questions about what reaches the module and what the specifications
// require. Those are the structural audit's job.
//
// What this testbench settles is the question the audit cannot: whether the flush
// path is a working containment mechanism at all. That matters because it decides
// the weight of the alleged absence. If the flush genuinely wipes every entry
// including a locked one, then whether a fatal error reaches it is a real security
// question. If the flush did nothing, wiring anything into it would be pointless
// and the candidate would collapse for a different reason.
//
//   CONTROL_A  two entries are provisioned and readable by their granted client
//              (non-vacuity gate: without this nothing below is meaningful)
//   CONTROL_B  one entry is locked for use over AHB, and its read is suppressed
//   CONTROL_C  a debugUnlock_or_scan_mode_switch pulse overwrites the unlocked
//              entry with the selected debug value
//   CONTROL_D  the same pulse also overwrites the LOCKED entry, so the flush is
//              not stoppable by the per-entry lock bits
//   CONTROL_E  a simultaneous two-client write to one entry raises that client's
//              write error and destroys the entry, which is the KeyVault's own
//              internal error response
//   PROBE_A    whether cptra_in_debug_scan_mode alone, with no software poke of
//              CLEAR_SECRETS, flushes anything
//
// The CONTROLs are asserted. PROBE_A is measured and reported without an
// expectation, because whether the software poke ought to be required is a
// specification question the audit settles.
//
// The lock bit is set through a real AHB write to KEY_CTRL rather than by forcing
// internal state, and every result is observed through the module's own
// kv_rd_resp and kv_wr_resp ports, so what is measured is what a crypto engine
// would see.
//
// Exactly one DUT is compiled, driven at its ports only: no forced internals and
// no hierarchical references into the register block.

`include "caliptra_macros.svh"

module kv_flush_and_error_tb;
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

  // The flush writes the value selected by CLEAR_SECRETS.sel_debug_value, which
  // resets to 0, so the expected post-flush contents are debug value 0. Taken
  // from the macro definition rather than read out of the DUT hierarchy.
  localparam logic [31:0] EXPECTED_DEBUG_VALUE = CLP_DEBUG_MODE_KV_0;

  localparam logic [31:0] OPEN_KEY_DWORD   = 32'hC0DE_0001;
  localparam logic [31:0] LOCKED_KEY_DWORD = 32'hC0DE_0002;
  localparam logic [31:0] WRLOCK_KEY_DWORD = 32'hC0DE_0004;
  localparam logic [31:0] RACE_KEY_DWORD   = 32'hC0DE_0003;
  localparam logic [31:0] RACE_A_DWORD     = 32'h5555_0001;
  localparam logic [31:0] RACE_B_DWORD     = 32'h5555_0002;

  localparam int OPEN_ENTRY   = 3;  // left unlocked
  localparam int LOCKED_ENTRY = 4;  // locked for use before the flush
  localparam int RACE_ENTRY   = 5;  // target of the simultaneous two-client write
  // Locked for WRITES only. lock_wr does not suppress the read mux
  // (src/keyvault/rtl/kv.sv:234 qualifies reads with lock_use alone), so this
  // entry is the one that can prove the flush WROTE the debug value into a locked
  // slot rather than merely that the slot stopped returning its key material.
  localparam int WRLOCK_ENTRY = 6;

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

  // Single-beat AHB-Lite read.
  //
  // Sampling point matters. The AHB shim registers the request into its
  // component-side dv on the clock edge after the address phase, and the
  // register block's read data is combinational off that dv, so the data is
  // valid only in the cycle immediately following the address-phase edge.
  // Sampling a cycle later reads back zero even when the register holds a one.
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

  // Drive two different write clients at the SAME entry in the same cycle, which
  // is the condition src/keyvault/rtl/kv.sv:147 calls kv_multi_write_err. Both
  // clients' write errors are captured in that cycle.
  task automatic simultaneous_write(input  int          entry,
                                    output logic        wr_error_a,
                                    output logic        wr_error_b);
    begin
      @(negedge clk);
      kv_write[KV_WRITE_IDX_HMAC].write_en         = 1'b1;
      kv_write[KV_WRITE_IDX_HMAC].write_entry      = entry;
      kv_write[KV_WRITE_IDX_HMAC].write_offset     = '0;
      kv_write[KV_WRITE_IDX_HMAC].write_data       = RACE_A_DWORD;
      kv_write[KV_WRITE_IDX_HMAC].write_dest_valid = KV_NUM_READ'(1) << KV_DEST_IDX_HMAC_KEY;
      kv_write[KV_WRITE_IDX_ECC].write_en         = 1'b1;
      kv_write[KV_WRITE_IDX_ECC].write_entry      = entry;
      kv_write[KV_WRITE_IDX_ECC].write_offset     = '0;
      kv_write[KV_WRITE_IDX_ECC].write_data       = RACE_B_DWORD;
      kv_write[KV_WRITE_IDX_ECC].write_dest_valid = KV_NUM_READ'(1) << KV_DEST_IDX_HMAC_KEY;
      #1;
      wr_error_a = kv_wr_resp[KV_WRITE_IDX_HMAC].error;
      wr_error_b = kv_wr_resp[KV_WRITE_IDX_ECC].error;
      @(posedge clk);
      @(negedge clk);
      kv_write[KV_WRITE_IDX_HMAC].write_en           = 1'b0;
      kv_write[KV_WRITE_IDX_HMAC].write_dest_valid   = '0;
      kv_write[KV_WRITE_IDX_ECC].write_en         = 1'b0;
      kv_write[KV_WRITE_IDX_ECC].write_dest_valid = '0;
      repeat (3) @(posedge clk);
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

  // Point the read client at an entry and return what it observes.
  //
  // This must be a task, not a function. The read path is combinational off
  // kv_read, so the response needs a settle delay before it is sampled; a
  // function cannot consume time and would return the value left over from the
  // previous selection, which reads as a plausible-looking wrong number rather
  // than as an obvious failure.
  task automatic read_entry(input int entry, output logic [31:0] data);
    begin
      kv_read[KV_DEST_IDX_HMAC_KEY].read_entry  = entry;
      kv_read[KV_DEST_IDX_HMAC_KEY].read_offset = '0;
      #1;
      data = kv_rd_resp[KV_DEST_IDX_HMAC_KEY].read_data;
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
    logic [31:0] rd_open_before;
    logic [31:0] rd_locked_before;
    logic [31:0] rd_locked_suppressed;
    logic [31:0] rd_open_after_flush;
    logic [31:0] rd_locked_after_flush;
    logic [31:0] rd_race_before;
    logic [31:0] rd_race_after;
    logic [31:0] rd_open_in_debug_scan;
    logic [31:0] rd_wrlock_before;
    logic [31:0] rd_wrlock_after_flush;
    logic        wr_error_a;
    logic        wr_error_b;

    $display("=== kv_bug_024 KeyVault flush coverage and internal error response ===");
    $display("open_entry=%0d use_locked_entry=%0d wr_locked_entry=%0d race_entry=%0d read_dest=HMAC_KEY(idx %0d)",
             OPEN_ENTRY, LOCKED_ENTRY, WRLOCK_ENTRY, RACE_ENTRY, KV_DEST_IDX_HMAC_KEY);
    $display("expected_debug_value=0x%08h", EXPECTED_DEBUG_VALUE);

    bring_up();

    // --- CONTROL_A: both entries are provisioned and readable ---------------
    provision_entry(OPEN_ENTRY,   OPEN_KEY_DWORD);
    provision_entry(LOCKED_ENTRY, LOCKED_KEY_DWORD);
    provision_entry(WRLOCK_ENTRY, WRLOCK_KEY_DWORD);
    select_read(OPEN_ENTRY);
    rd_open_before = kv_rd_resp[KV_DEST_IDX_HMAC_KEY].read_data;
    $display("CONTROL_A open entry read_data=0x%08h rd_error=%0b",
             rd_open_before, kv_rd_resp[KV_DEST_IDX_HMAC_KEY].error);
    expect_eq("CONTROL_A open entry is readable by its granted client",
              rd_open_before, OPEN_KEY_DWORD);
    select_read(LOCKED_ENTRY);
    rd_locked_before = kv_rd_resp[KV_DEST_IDX_HMAC_KEY].read_data;
    $display("CONTROL_A to-be-locked entry read_data=0x%08h", rd_locked_before);
    expect_eq("CONTROL_A to-be-locked entry is readable before locking",
              rd_locked_before, LOCKED_KEY_DWORD);

    // --- CONTROL_B: lock one entry for use over AHB -------------------------
    ahb_write(key_ctrl_addr(LOCKED_ENTRY), LOCK_USE_MASK);
    ahb_read(key_ctrl_addr(LOCKED_ENTRY), ctrl_readback);
    $display("CONTROL_B KEY_CTRL[%0d] readback=0x%08h lock_use=%0b",
             LOCKED_ENTRY, ctrl_readback, |(ctrl_readback & LOCK_USE_MASK));
    expect_bit("CONTROL_B software write set lock_use",
               |(ctrl_readback & LOCK_USE_MASK), 1'b1);
    select_read(LOCKED_ENTRY);
    rd_locked_suppressed = kv_rd_resp[KV_DEST_IDX_HMAC_KEY].read_data;
    $display("CONTROL_B locked entry read_data=0x%08h rd_error=%0b",
             rd_locked_suppressed, kv_rd_resp[KV_DEST_IDX_HMAC_KEY].error);
    expect_eq("CONTROL_B lock_use suppresses the read to zero",
              rd_locked_suppressed, 32'h0);

    // Also lock a second entry for WRITES only. lock_wr leaves the read mux open,
    // so after the flush this entry can show what was actually written into a
    // locked slot, which a lock_use entry cannot.
    ahb_write(key_ctrl_addr(WRLOCK_ENTRY), LOCK_WR_MASK);
    ahb_read(key_ctrl_addr(WRLOCK_ENTRY), ctrl_readback);
    $display("CONTROL_B KEY_CTRL[%0d] readback=0x%08h lock_wr=%0b",
             WRLOCK_ENTRY, ctrl_readback, |(ctrl_readback & LOCK_WR_MASK));
    expect_bit("CONTROL_B software write set lock_wr on the write-locked entry",
               |(ctrl_readback & LOCK_WR_MASK), 1'b1);
    read_entry(WRLOCK_ENTRY, rd_wrlock_before);
    $display("CONTROL_B write-locked entry read_data=0x%08h", rd_wrlock_before);
    expect_eq("CONTROL_B lock_wr does not suppress the read",
              rd_wrlock_before, WRLOCK_KEY_DWORD);

    // --- PROBE_A: debug scan mode alone, with no software poke -------------
    // Measured, not asserted. src/keyvault/rtl/kv.sv:123 qualifies the
    // cptra_in_debug_scan_mode term with CLEAR_SECRETS.wr_debug_values, which is
    // software-written and resets to zero, so this records what the mode signal
    // does on its own.
    cptra_in_debug_scan_mode = 1'b1;
    repeat (3) @(posedge clk);
    read_entry(OPEN_ENTRY, rd_open_in_debug_scan);
    $display("PROBE_A   cptra_in_debug_scan_mode=1 with no CLEAR_SECRETS poke open entry read_data=0x%08h",
             rd_open_in_debug_scan);
    $display("probe_entry_flushed_by_debug_scan_mode_alone=%0b",
             (rd_open_in_debug_scan === EXPECTED_DEBUG_VALUE));
    cptra_in_debug_scan_mode = 1'b0;
    repeat (2) @(posedge clk);

    // --- CONTROL_C and CONTROL_D: the flush pulse --------------------------
    // One pulse, then both entries are examined. The locked entry is the point:
    // src/keyvault/rtl/kv.sv:211 admits debugUnlock_or_scan_mode_switch as an
    // alternative to the lock qualifier, so a locked entry should be flushed too.
    debugUnlock_or_scan_mode_switch = 1'b1;
    repeat (3) @(posedge clk);
    debugUnlock_or_scan_mode_switch = 1'b0;
    repeat (3) @(posedge clk);

    read_entry(OPEN_ENTRY, rd_open_after_flush);
    $display("CONTROL_C after the flush pulse open entry read_data=0x%08h", rd_open_after_flush);
    expect_eq("CONTROL_C the flush overwrote the unlocked entry with the debug value",
              rd_open_after_flush, EXPECTED_DEBUG_VALUE);

    // The locked entry's lock_use still suppresses the client read path, so its
    // contents cannot be observed through this client while locked. Read the
    // control register to confirm the lock is still set, then observe the entry
    // through the read client and report both facts.
    ahb_read(key_ctrl_addr(LOCKED_ENTRY), ctrl_readback);
    read_entry(LOCKED_ENTRY, rd_locked_after_flush);
    $display("CONTROL_D after the flush pulse KEY_CTRL[%0d]=0x%08h lock_use=%0b locked entry read_data=0x%08h",
             LOCKED_ENTRY, ctrl_readback, |(ctrl_readback & LOCK_USE_MASK),
             rd_locked_after_flush);
    // Whatever the lock does to the read path, the entry must not still hold its
    // original key material. Assert the negative, which holds under either
    // reading: a suppressed read returns zero, and a flushed entry returns the
    // debug value; only surviving key material returns LOCKED_KEY_DWORD.
    expect_bit("CONTROL_D the use-locked entry no longer returns its original key material",
               (rd_locked_after_flush === LOCKED_KEY_DWORD), 1'b0);

    // The write-locked entry settles what the use-locked one cannot. lock_wr
    // leaves the read mux open, so a zero here would mean the entry was merely
    // suppressed while the debug value means the flush actually wrote through the
    // lock. This is the positive form of the lock-bypass measurement.
    ahb_read(key_ctrl_addr(WRLOCK_ENTRY), ctrl_readback);
    read_entry(WRLOCK_ENTRY, rd_wrlock_after_flush);
    $display("CONTROL_D after the flush pulse KEY_CTRL[%0d]=0x%08h lock_wr=%0b write-locked entry read_data=0x%08h",
             WRLOCK_ENTRY, ctrl_readback, |(ctrl_readback & LOCK_WR_MASK),
             rd_wrlock_after_flush);
    expect_bit("CONTROL_D the write lock is still set after the flush",
               |(ctrl_readback & LOCK_WR_MASK), 1'b1);
    expect_eq("CONTROL_D the flush wrote the debug value through a set write lock",
              rd_wrlock_after_flush, EXPECTED_DEBUG_VALUE);

    // --- CONTROL_E: the KeyVault's own internal error response -------------
    provision_entry(RACE_ENTRY, RACE_KEY_DWORD);
    read_entry(RACE_ENTRY, rd_race_before);
    $display("CONTROL_E race entry before the simultaneous write read_data=0x%08h", rd_race_before);
    expect_eq("CONTROL_E race entry is provisioned before the simultaneous write",
              rd_race_before, RACE_KEY_DWORD);
    simultaneous_write(RACE_ENTRY, wr_error_a, wr_error_b);
    $display("CONTROL_E simultaneous two-client write wr_error_a=%0b wr_error_b=%0b",
             wr_error_a, wr_error_b);
    read_entry(RACE_ENTRY, rd_race_after);
    $display("CONTROL_E race entry after the simultaneous write read_data=0x%08h", rd_race_after);
    expect_bit("CONTROL_E the multi-write error destroyed the entry contents",
               (rd_race_after === RACE_KEY_DWORD), 1'b0);
    expect_bit("CONTROL_E neither racing write landed as itself",
               ((rd_race_after === RACE_A_DWORD) | (rd_race_after === RACE_B_DWORD)), 1'b0);

    $display("checks_run=%0d checks_failed=%0d", checks_run, checks_failed);
    if (checks_failed != 0) begin
      $display("result=FAIL");
      $fatal(1, "kv_bug_024 directed simulation controls did not hold");
    end
    $display("result=PASS");
    $finish;
  end
endmodule
