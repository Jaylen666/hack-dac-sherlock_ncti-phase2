// SPDX-License-Identifier: Apache-2.0
//
// Directed simulation of PCR vault lock stickiness across a microcontroller-only
// reset.
//
// Purpose
// -------
// src/pcrvault/config/pcrvault.md:6 states that the PCR lock bit "is sticky and
// only resets on a powergood cycle". src/pcrvault/rtl/pv_reg.rdl:30 declares the
// field with resetsignal = core_only_rst_b, which src/pcrvault/rtl/pv.sv:176
// connects to the module's core_only_rst_b input and which
// src/integration/rtl/caliptra_top.sv:1226 connects to the microcontroller-only
// reset. A firmware-update reset asserts that reset and is not a powergood cycle.
//
// Reading the declaration is not enough to call this a defect. Three things have
// to be measured, and the third is what decides whether it is a security finding
// or only a reset-domain curiosity:
//
//   1. is the lock actually protecting anything before the reset,
//   2. does the lock survive a core_only_rst_b pulse, and
//   3. does the PCR entry data survive that same pulse.
//
// If the lock clears and the data clears with it, there is no measurement left to
// protect and no finding. If the lock clears while the data survives, the entry
// is left holding a measurement with its protection gone, and the clear that was
// refused before the reset is accepted after it.
//
// Groups
// ------
//   CONTROL_A  a provisioned entry reads back its measurement over AHB
//              (non-vacuity gate: without this nothing below is meaningful)
//   CONTROL_B  after an AHB write setting PCR_CTRL.lock, the lock reads back set
//   CONTROL_C  with the lock set, an AHB write of PCR_CTRL.clear is refused and
//              the entry data survives -- the protection is live
//   WITNESS_D  the state of the lock bit and of the entry data after a
//              core_only_rst_b pulse
//   WITNESS_E  whether the clear refused in CONTROL_C is accepted after the
//              pulse, and whether it zeroes the measurement, with the
//              fw_update_rst_window swwel mask measured de-asserted so it
//              cannot be the reason the clear landed
//
// CONTROL_A through CONTROL_C are asserted with expect_eq and must hold: they are
// the properties the in-tree document states about the pre-reset state, and if any
// of them fails the case is mis-framed rather than proven, which is why their
// failures are reported as FAIL:. The two post-reset expectations quoted from the
// in-tree stickiness sentence are asserted with expect_eq_per_spec and are
// measured NOT to hold; those report TBFAIL, because a specification violation the
// case exists to demonstrate is not the same event as a broken run.
//
// Exactly one DUT is compiled, driven at its ports only: no forced internals and
// no hierarchical references into the register block. The lock and clear bits are
// software-writable registers, so real AHB transactions are used rather than
// poking internal state, and the entry data is observed the way firmware would
// observe it -- by reading PCR_ENTRY over the same bus.

`include "caliptra_macros.svh"

module pv_lock_reset_domain_tb;
  import pv_defines_pkg::*;

  logic clk;
  logic rst_b;
  logic core_only_rst_b;
  logic cptra_pwrgood;
  logic fw_update_rst_window;

  logic [PV_ADDR_W-1:0] haddr_i;
  logic [31:0]          hwdata_i;
  logic                 hsel_i;
  logic                 hwrite_i;
  logic                 hready_i;
  logic [1:0]           htrans_i;
  logic [2:0]           hsize_i;
  logic                 hresp_o;
  logic                 hreadyout_o;
  logic [31:0]          hrdata_o;

  pv_read_t    [PV_NUM_READ-1:0]  pv_read;
  pv_write_t   [PV_NUM_WRITE-1:0] pv_write;
  pv_rd_resp_t [PV_NUM_READ-1:0]  pv_rd_resp;
  pv_wr_resp_t [PV_NUM_WRITE-1:0] pv_wr_resp;

  // Register map per src/pcrvault/rtl/pv_reg.rdl:40-41: PCR_CTRL[32] at 0x0,
  // one 32-bit register per entry; PCR_ENTRY[32][12] at 0x600, twelve dwords
  // per entry.
  localparam logic [PV_ADDR_W-1:0] PCR_CTRL_BASE  = 'h000;
  localparam logic [PV_ADDR_W-1:0] PCR_ENTRY_BASE = 'h600;
  localparam logic [31:0] LOCK_MASK  = 32'h0000_0001;
  localparam logic [31:0] CLEAR_MASK = 32'h0000_0002;

  localparam int          TARGET_ENTRY  = 7;
  localparam logic [31:0] MEASUREMENT   = 32'h5EC0_0007;

  int unsigned checks_run    = 0;
  int unsigned checks_failed = 0;
  int unsigned witness_hits  = 0;

  // Coverage of the two halves of the discrimination: the lock refusing a clear
  // while set, and the same clear being accepted once the lock has been lost.
  int unsigned cover_locked_clear_refused  = 0;
  int unsigned cover_unlocked_clear_landed = 0;

  pv #(
    .AHB_ADDR_WIDTH(PV_ADDR_W),
    .AHB_DATA_WIDTH(32)
  ) dut (.*);

  initial clk = 1'b0;
  always #5 clk = ~clk;

  task automatic bring_up;
    begin
      rst_b                = 1'b0;
      core_only_rst_b      = 1'b0;
      cptra_pwrgood        = 1'b0;
      fw_update_rst_window = 1'b0;
      haddr_i              = '0;
      hwdata_i             = '0;
      hsel_i               = 1'b0;
      hwrite_i             = 1'b0;
      hready_i             = 1'b1;
      htrans_i             = 2'b00;
      hsize_i              = 3'b010;
      pv_read              = '{default: '0};
      pv_write             = '{default: '0};
      repeat (3) @(posedge clk);
      cptra_pwrgood   = 1'b1;
      rst_b           = 1'b1;
      core_only_rst_b = 1'b1;
      repeat (3) @(posedge clk);
    end
  endtask

  // Single-beat AHB-Lite write: address phase then data phase.
  task automatic ahb_write(input logic [PV_ADDR_W-1:0] addr,
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
  // Stimulus is driven on negedge and data sampled just after the posedge that
  // asserts dv.
  task automatic ahb_read(input  logic [PV_ADDR_W-1:0] addr,
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

  function automatic logic [PV_ADDR_W-1:0] pcr_ctrl_addr(input int entry);
    pcr_ctrl_addr = PCR_CTRL_BASE + PV_ADDR_W'(4 * entry);
  endfunction

  function automatic logic [PV_ADDR_W-1:0] pcr_entry_addr(input int entry,
                                                          input int dword);
    pcr_entry_addr = PCR_ENTRY_BASE +
                     PV_ADDR_W'(4 * (entry * PV_NUM_DWORDS + dword));
  endfunction

  // Provision a PCR entry through the hardware write client. PCR entries are
  // sw=r (src/pcrvault/rtl/pv_reg.rdl:22), so software cannot write them; the
  // only path in is the vault write port, which is what the SHA-512 hash-extend
  // path drives in the integrated design.
  task automatic provision_entry(input int entry, input logic [31:0] data);
    begin
      @(negedge clk);
      pv_write[0].write_en     = 1'b1;
      pv_write[0].write_entry  = entry;
      pv_write[0].write_offset = '0;
      pv_write[0].write_data   = data;
      @(negedge clk);
      pv_write[0].write_en     = 1'b0;
      pv_write[0].write_entry  = '0;
      pv_write[0].write_offset = '0;
      pv_write[0].write_data   = '0;
      repeat (2) @(posedge clk);
    end
  endtask

  // Pulse the microcontroller-only reset. This models what the boot FSM does to
  // cptra_uc_rst_b when firmware writes INTERNAL_FW_UPDATE_RESET.core_rst: the
  // module's rst_b and cptra_pwrgood stay asserted, because a firmware-update
  // reset resets the microcontroller only, not the whole design and certainly
  // not power.
  task automatic pulse_core_only_reset;
    begin
      @(negedge clk);
      fw_update_rst_window = 1'b1;
      repeat (2) @(posedge clk);
      core_only_rst_b = 1'b0;
      repeat (5) @(posedge clk);
      core_only_rst_b = 1'b1;
      repeat (2) @(posedge clk);
      fw_update_rst_window = 1'b0;
      repeat (3) @(posedge clk);
    end
  endtask

  // Two failure markers, deliberately different. FAIL: means an expectation that
  // must hold did not, which makes the case mis-framed and the run untrustworthy.
  // TBFAIL marks an expectation stated from the in-tree requirement that the
  // design is measured NOT to meet -- that is the finding, not a broken run, and
  // a log scanner needs to be able to tell the two apart.
  task automatic expect_eq(input string      label,
                           input logic [31:0] observed,
                           input logic [31:0] expected);
    begin
      checks_run++;
      if (observed === expected) begin
        $display("ok:   %s value=0x%08h as expected", label, observed);
      end
      else begin
        checks_failed++;
        $display("FAIL: %s observed=0x%08h expected=0x%08h",
                 label, observed, expected);
      end
    end
  endtask

  // Same comparison, reported as a specification violation rather than a
  // testbench failure. Used only where the expected value is quoted from an
  // in-tree statement the design is being measured against.
  task automatic expect_eq_per_spec(input string      label,
                                    input logic [31:0] observed,
                                    input logic [31:0] expected);
    begin
      checks_run++;
      if (observed === expected) begin
        $display("ok:   %s value=0x%08h as expected", label, observed);
      end
      else begin
        checks_failed++;
        $display("TBFAIL %s observed=0x%08h required=0x%08h",
                 label, observed, expected);
      end
    end
  endtask

  logic [31:0] rd;
  logic [31:0] ctrl_before_reset;
  logic [31:0] ctrl_after_reset;
  logic [31:0] data_after_reset;
  logic [31:0] data_after_clear;
  logic [31:0] ctrl_after_clear_attempt;
  logic [31:0] data_after_locked_clear;

  initial begin
    bring_up();

    // ---------------------------------------------------------------------
    // CONTROL_A: the entry holds a measurement, readable over AHB.
    // ---------------------------------------------------------------------
    provision_entry(TARGET_ENTRY, MEASUREMENT);
    ahb_read(pcr_entry_addr(TARGET_ENTRY, 0), rd);
    $display("CONTROL_A provisioned entry %0d read_data=0x%08h",
             TARGET_ENTRY, rd);
    expect_eq("CONTROL_A the PCR entry holds its measurement", rd, MEASUREMENT);

    // ---------------------------------------------------------------------
    // CONTROL_B: software sets the lock; it reads back set.
    // ---------------------------------------------------------------------
    ahb_write(pcr_ctrl_addr(TARGET_ENTRY), LOCK_MASK);
    ahb_read(pcr_ctrl_addr(TARGET_ENTRY), ctrl_before_reset);
    $display("CONTROL_B PCR_CTRL[%0d]=0x%08h lock=%0b",
             TARGET_ENTRY, ctrl_before_reset, ctrl_before_reset[0]);
    expect_eq("CONTROL_B software write set the PCR lock",
              {31'b0, ctrl_before_reset[0]}, 32'h1);

    // ---------------------------------------------------------------------
    // CONTROL_C: with the lock set, a clear write is refused. This is the
    // protection the specification promises, measured live rather than assumed
    // -- if this failed, the lock would be protecting nothing even before the
    // reset and the case would be about a different defect.
    // ---------------------------------------------------------------------
    ahb_write(pcr_ctrl_addr(TARGET_ENTRY), LOCK_MASK | CLEAR_MASK);
    ahb_read(pcr_ctrl_addr(TARGET_ENTRY), ctrl_after_clear_attempt);
    ahb_read(pcr_entry_addr(TARGET_ENTRY, 0), data_after_locked_clear);
    $display("CONTROL_C locked clear attempt PCR_CTRL[%0d]=0x%08h clear_bit=%0b entry_read_data=0x%08h",
             TARGET_ENTRY, ctrl_after_clear_attempt,
             ctrl_after_clear_attempt[1], data_after_locked_clear);
    expect_eq("CONTROL_C the clear write was refused while locked",
              {31'b0, ctrl_after_clear_attempt[1]}, 32'h0);
    expect_eq("CONTROL_C the measurement survived the refused clear",
              data_after_locked_clear, MEASUREMENT);
    if (data_after_locked_clear === MEASUREMENT) cover_locked_clear_refused++;

    // ---------------------------------------------------------------------
    // WITNESS_D: pulse the microcontroller-only reset. Per
    // src/pcrvault/config/pcrvault.md:6 the lock survives everything short of a
    // powergood cycle, so the expected readings are lock=1 and the measurement
    // intact. A lock of 0 here is the violation.
    // ---------------------------------------------------------------------
    pulse_core_only_reset();
    ahb_read(pcr_ctrl_addr(TARGET_ENTRY), ctrl_after_reset);
    ahb_read(pcr_entry_addr(TARGET_ENTRY, 0), data_after_reset);
    $display("WITNESS_D after core_only_rst_b pulse PCR_CTRL[%0d]=0x%08h lock=%0b entry_read_data=0x%08h",
             TARGET_ENTRY, ctrl_after_reset, ctrl_after_reset[0],
             data_after_reset);
    $display("witness_pcr_lock_survives_core_only_reset=%0d",
             ctrl_after_reset[0]);
    $display("witness_pcr_measurement_survives_core_only_reset=%0d",
             (data_after_reset === MEASUREMENT) ? 1 : 0);
    // Asserted against the in-tree stickiness sentence: the lock is required to
    // still be set here. This expectation is the one the design misses, so its
    // failure is the witness.
    expect_eq_per_spec("WITNESS_D the lock is still set after the pulse, per pcrvault.md:6",
                       {31'b0, ctrl_after_reset[0]}, 32'h1);
    if (ctrl_after_reset[0] === 1'b0) begin
      witness_hits++;
      $display("  OBSERVED: PV_905_WITNESS_OBSERVED a set PCR_CTRL[%0d].lock was cleared by a microcontroller-only reset, which is not a powergood cycle",
               TARGET_ENTRY);
    end
    // Asserted and required to hold: an entry that lost its data too would have
    // nothing left to protect, and the finding would collapse.
    expect_eq("WITNESS_D the measurement survived the pulse",
              data_after_reset, MEASUREMENT);

    // ---------------------------------------------------------------------
    // WITNESS_E: repeat the clear that CONTROL_C proved was refused. If the
    // lock is gone the write is now accepted and the measurement is zeroed.
    // ---------------------------------------------------------------------
    // One alternative explanation has to be ruled out before the accepted clear
    // can be attributed to the lost lock. src/pcrvault/rtl/pv.sv:110-111
    // qualifies both swwel terms with ~fw_update_rst_window, so a clear write
    // also lands while that window is asserted -- and there the mask is doing
    // its documented job (src/soc_ifc/rtl/soc_ifc_boot_fsm.sv:89-91 introduces
    // it to keep combinational paths out of other reset domains) rather than
    // showing a lock failure. The window is a combinational function of the boot
    // FSM state, so it is de-asserted again by the time firmware runs. Measured
    // here rather than assumed, because if it were still asserted this whole
    // group would be reading the mask instead of the lock.
    expect_eq("WITNESS_E fw_update_rst_window is de-asserted, so the swwel mask does not explain the clear",
              {31'b0, fw_update_rst_window}, 32'h0);
    ahb_write(pcr_ctrl_addr(TARGET_ENTRY), CLEAR_MASK);
    ahb_read(pcr_entry_addr(TARGET_ENTRY, 0), data_after_clear);
    $display("WITNESS_E post-reset clear attempt entry_read_data=0x%08h",
             data_after_clear);
    $display("witness_measurement_cleared_after_reset=%0d",
             (data_after_clear === 32'h0) ? 1 : 0);
    // Asserted the same way: the specification's lock should still be refusing
    // this write, so the measurement is required to be intact. Its failure is
    // the consequence of the lost lock.
    expect_eq_per_spec("WITNESS_E the measurement survived the post-reset clear",
                       data_after_clear, MEASUREMENT);
    if (data_after_clear === 32'h0) begin
      witness_hits++;
      cover_unlocked_clear_landed++;
      $display("  OBSERVED: PV_905_WITNESS_OBSERVED the clear refused in CONTROL_C was accepted after the reset and zeroed the measurement");
    end

    $display("cover_locked_clear_refused=%0d", cover_locked_clear_refused);
    $display("cover_unlocked_clear_landed=%0d", cover_unlocked_clear_landed);
    $display("checks_run=%0d checks_failed=%0d witness_hits=%0d",
             checks_run, checks_failed, witness_hits);

    // Eight expectations in total, of which exactly two are required to fail:
    // WITNESS_D's lock-still-set check and WITNESS_E's
    // measurement-survived-the-clear check. The other six must hold, and each of
    // them closes off a way the case could be mis-framed: the four controls
    // establish that a measurement is present and that the lock really was
    // refusing the clear beforehand, WITNESS_D's data check establishes that
    // there was still something left to protect after the reset, and WITNESS_E's
    // window check rules out the swwel mask as an alternative explanation for
    // the accepted clear.
    //
    // Requiring the exact counts rather than "at least one failure" is what
    // makes this a discriminating measurement: it pins which expectations fail
    // and which hold, so a future change that breaks the case in a different
    // way does not silently keep reporting PASS.
    if (checks_run == 8 && checks_failed == 2 && witness_hits == 2 &&
        cover_locked_clear_refused == 1 && cover_unlocked_clear_landed == 1) begin
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
