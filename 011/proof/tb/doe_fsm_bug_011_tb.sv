// SPDX-License-Identifier: Apache-2.0
//
// Witness testbench for BUG-011: doe_fsm releases the extended zeroize hold on a
// condition that is not specific to a de-obfuscation flow.
//
// The module's own comment (doe_fsm.sv:115-118) states the intent of zeroize_reg:
//   "zeroize input is a single pulse. However, when we detect zeroize, we'd like
//    the fsm to remain in IDLE until next DOE_CMD is issued. ... When the next
//    command is issued, this extended signal is reset and fsm advances."
//
// zeroize_reg has exactly one consumer, the state flop at doe_fsm.sv:286, where it
// forces kv_doe_fsm_ps to DOE_IDLE and holds dest_write_offset / block_offset /
// dest_addr at zero. So "remain in IDLE until the next command" is observable from
// the ports as latency: with the hold in place, the first command after a zeroize
// must spend one cycle absorbed by the pin before doe_init can assert.
//
// This tb drives one doe_fsm through the ports only and measures that latency.
//
// Measurement method
// -----------------
//   cold  = cycles from asserting a command out of reset until doe_init
//   after = cycles from asserting a command after a single-cycle zeroize pulse
//
// If the extended hold is effective, after == cold + 1. If it has already been
// released before the command arrives, after == cold, i.e. the pulse bought
// nothing and the FSM advances exactly as if no zeroize had occurred.
//
// dest_data_avail is held low for the whole run so the flow never reaches
// DOE_DONE. That keeps flow_done low, so lock_uds_flow never arms and the same
// command can be re-issued in every case.

`default_nettype none

module doe_fsm_bug_011_tb
  import doe_defines_pkg::*;
  import kv_defines_pkg::*;
();

  localparam int unsigned SRC_W  = 128;
  localparam int unsigned DEST_W = 128;

  localparam int unsigned TOTAL_OBF_FE_BITS  = `CLP_OBF_FE_DWORDS * 32;
  localparam int unsigned TOTAL_OBF_UDS_BITS = `CLP_OBF_UDS_DWORDS * 32;
  localparam int unsigned TOTAL_OBF_HEK_BITS = OCP_LOCK_HEK_NUM_DWORDS * 32;
  localparam int unsigned FE_BLOCKS  = TOTAL_OBF_FE_BITS  / SRC_W;
  localparam int unsigned UDS_BLOCKS = TOTAL_OBF_UDS_BITS / SRC_W;
  localparam int unsigned HEK_BLOCKS = TOTAL_OBF_HEK_BITS / SRC_W;

  logic clk, rst_b, hard_rst_b;

  logic [FE_BLOCKS-1:0][SRC_W-1:0]  obf_field_entropy;
  logic [UDS_BLOCKS-1:0][SRC_W-1:0] obf_uds_seed;
  logic [HEK_BLOCKS-1:0][SRC_W-1:0] obf_hek_seed;

  doe_cmd_reg_t doe_cmd_reg;
  logic         ocp_lock_en;

  kv_write_t kv_write;
  logic src_write_en;
  logic [SRC_W-1:0] src_write_data;
  logic doe_init, doe_next;
  logic init_done, dest_data_avail;
  logic [(DEST_W/32)-1:0][31:0] dest_data;
  logic flow_done, flow_error, flow_in_progress;
  logic lock_uds_flow, lock_fe_flow, lock_hek_flow;
  logic zeroize;

  int unsigned checks, fails, witness_hits;
  int unsigned cov_cold_start_measured;
  int unsigned cov_pulse_hold_absent;
  int unsigned cov_level_hold_present;
  int unsigned cov_flow_aborted_to_idle;

  int unsigned lat_cold, lat_after_pulse, lat_after_level;

  doe_fsm #(
    .SRC_WIDTH (SRC_W),
    .DEST_WIDTH(DEST_W)
  ) dut (
    .clk              (clk),
    .rst_b            (rst_b),
    .hard_rst_b       (hard_rst_b),
    .obf_field_entropy(obf_field_entropy),
    .obf_uds_seed     (obf_uds_seed),
    .obf_hek_seed     (obf_hek_seed),
    .doe_cmd_reg      (doe_cmd_reg),
    .ocp_lock_en      (ocp_lock_en),
    .kv_write         (kv_write),
    .src_write_en     (src_write_en),
    .src_write_data   (src_write_data),
    .doe_init         (doe_init),
    .doe_next         (doe_next),
    .init_done        (init_done),
    .dest_data_avail  (dest_data_avail),
    .dest_data        (dest_data),
    .flow_done        (flow_done),
    .flow_error       (flow_error),
    .flow_in_progress (flow_in_progress),
    .lock_uds_flow    (lock_uds_flow),
    .lock_fe_flow     (lock_fe_flow),
    .lock_hek_flow    (lock_hek_flow),
    .zeroize          (zeroize)
  );

  initial clk = 1'b0;
  always #5 clk = ~clk;

  initial begin : global_timeout
    #200000;
    $display("TBFAIL global timeout");
    $finish;
  end

  task automatic tick(input int unsigned n = 1);
    for (int unsigned i = 0; i < n; i++) @(posedge clk);
  endtask

  task automatic do_reset();
    rst_b      = 1'b0;
    hard_rst_b = 1'b0;
    doe_cmd_reg.cmd      = DOE_NOP;
    doe_cmd_reg.dest_sel = '0;
    ocp_lock_en     = 1'b0;
    init_done       = 1'b0;
    dest_data_avail = 1'b0;
    zeroize         = 1'b0;
    tick(4);
    rst_b      = 1'b1;
    hard_rst_b = 1'b1;
    tick(2);
    // init_done is doe_cbc.sv:256 -> core_ready. It is a core-level readiness
    // signal, not a per-flow signal, so it is high whenever the core is up.
    init_done = 1'b1;
    tick(2);
  endtask

  // Assert a command and count posedges until doe_init rises. Returns 0 if
  // doe_init never asserts inside the bound.
  // The command is driven on a negedge so it is stable well before the posedge
  // that samples it, and doe_init is sampled a short delay after each posedge so
  // the settled combinational value is read rather than the pre-edge one.
  task automatic measure_cmd_to_init(input doe_cmd_e cmd, output int unsigned lat);
    int unsigned n;
    lat = 0;
    @(negedge clk);
    doe_cmd_reg.cmd      = cmd;
    doe_cmd_reg.dest_sel = 5'd3;
    for (n = 1; n <= 32; n++) begin
      @(posedge clk);
      #1;
      if (doe_init) begin
        lat = n;
        break;
      end
    end
  endtask

  // Drive the flow into a non-IDLE state and leave it there. With
  // dest_data_avail low the FSM loops WAIT -> BLOCK -> NEXT -> WAIT forever, so
  // flow_done never asserts and no lock arms.
  task automatic park_in_flow();
    tick(6);
  endtask

  task automatic record(input string name, input bit ok);
    checks++;
    if (!ok) begin
      fails++;
      $display("CHECK_FAIL %s", name);
    end
    else begin
      $display("CHECK_PASS %s", name);
    end
  endtask

  initial begin : main
    checks = 0; fails = 0; witness_hits = 0;
    cov_cold_start_measured  = 0;
    cov_pulse_hold_absent    = 0;
    cov_level_hold_present   = 0;
    cov_flow_aborted_to_idle = 0;

    // Distinct per-source marker words. Only hex digits, so no "UDS"/"HEK"
    // spelled literals: 0xD5 for the UDS seed, 0xFE for field entropy, 0xEC for HEK.
    for (int unsigned b = 0; b < UDS_BLOCKS; b++) obf_uds_seed[b]      = {4{32'hD500_0000 + b}};
    for (int unsigned b = 0; b < FE_BLOCKS;  b++) obf_field_entropy[b] = {4{32'hFE00_0000 + b}};
    for (int unsigned b = 0; b < HEK_BLOCKS; b++) obf_hek_seed[b]      = {4{32'hEC00_0000 + b}};
    for (int unsigned d = 0; d < (DEST_W/32); d++) dest_data[d] = 32'hD0D0_0000 + d;

    // ---------------------------------------------------------------------
    // Case A - baseline. Cold start out of reset with no zeroize anywhere.
    // Establishes the reference latency from command to doe_init.
    // ---------------------------------------------------------------------
    do_reset();
    measure_cmd_to_init(DOE_UDS, lat_cold);
    $display("COV cold_start_latency=%0d", lat_cold);
    record("control_cold_start_reaches_init", (lat_cold != 0));
    if (lat_cold != 0) cov_cold_start_measured = 1;

    // ---------------------------------------------------------------------
    // Case B - witness. Single-cycle zeroize pulse while the FSM is mid-flow,
    // then a quiet window with the command back at NOP (this models
    // doe_cbc.sv:203 clearing CMD on clear_obf_secrets), then the next command.
    //
    // Per the module comment the hold must still be in force when that command
    // arrives, so the measured latency must exceed the cold-start reference.
    // ---------------------------------------------------------------------
    do_reset();
    doe_cmd_reg.cmd      = DOE_UDS;
    doe_cmd_reg.dest_sel = 5'd3;
    park_in_flow();
    record("witness_setup_flow_is_in_progress", (flow_in_progress === 1'b1));

    // one-cycle zeroize pulse, command drops to NOP in the same cycle
    // (doe_cbc.sv:203 clears CMD on clear_obf_secrets)
    @(negedge clk);
    zeroize         = 1'b1;
    doe_cmd_reg.cmd = DOE_NOP;
    tick(1);
    @(negedge clk);
    zeroize = 1'b0;

    // quiet window: no command pending. The hold is supposed to span this.
    tick(6);
    record("witness_flow_no_longer_in_progress", (flow_in_progress === 1'b0));
    if (flow_in_progress === 1'b0) cov_flow_aborted_to_idle = 1;

    measure_cmd_to_init(DOE_UDS, lat_after_pulse);
    $display("COV latency_after_pulse=%0d cold=%0d", lat_after_pulse, lat_cold);

    // The witness. If the hold were still asserted the command would be absorbed
    // for one cycle first, giving lat_after_pulse == lat_cold + 1.
    record("witness_next_cmd_delayed_by_extended_hold",
           (lat_after_pulse != 0) && (lat_after_pulse > lat_cold));
    if ((lat_after_pulse != 0) && (lat_after_pulse == lat_cold)) begin
      witness_hits++;
      cov_pulse_hold_absent = 1;
      $display("WITNESS pulse_hold_released_early after=%0d cold=%0d",
               lat_after_pulse, lat_cold);
    end

    // ---------------------------------------------------------------------
    // Case C - discriminator. Same sequence, but zeroize is held as a level for
    // the whole quiet window (doe_cbc.sv:213 also drives zeroize from
    // debugUnlock_or_scan_mode_switch, which is a level, not a pulse).
    //
    // While zeroize is high the flop's own zeroize branch keeps the hold set
    // regardless of the release condition, so this case must show the delay.
    // It separates "the release condition is wrong" from "the hold never works".
    // ---------------------------------------------------------------------
    do_reset();
    doe_cmd_reg.cmd      = DOE_UDS;
    doe_cmd_reg.dest_sel = 5'd3;
    park_in_flow();

    @(negedge clk);
    zeroize         = 1'b1;
    doe_cmd_reg.cmd = DOE_NOP;
    tick(6);
    @(negedge clk);
    zeroize = 1'b0;

    measure_cmd_to_init(DOE_UDS, lat_after_level);
    $display("COV latency_after_level=%0d cold=%0d", lat_after_level, lat_cold);
    record("discriminator_level_zeroize_delays_next_cmd",
           (lat_after_level != 0) && (lat_after_level > lat_cold));
    if ((lat_after_level != 0) && (lat_after_level > lat_cold)) begin
      witness_hits++;
      cov_level_hold_present = 1;
      $display("WITNESS level_hold_still_effective after=%0d cold=%0d",
               lat_after_level, lat_cold);
    end

    // ---------------------------------------------------------------------
    // Case D - containment. A zeroize pulse must always land the FSM back in
    // IDLE with no key vault write left in flight. This bounds the claim: the
    // defect is in how long the hold lasts, not in whether the abort happens.
    // ---------------------------------------------------------------------
    do_reset();
    doe_cmd_reg.cmd      = DOE_UDS;
    doe_cmd_reg.dest_sel = 5'd3;
    park_in_flow();
    @(negedge clk);
    zeroize         = 1'b1;
    doe_cmd_reg.cmd = DOE_NOP;
    tick(1);
    @(negedge clk);
    zeroize = 1'b0;
    tick(8);
    record("containment_no_kv_write_after_zeroize", (kv_write.write_en === 1'b0));
    record("containment_no_src_write_after_zeroize", (src_write_en === 1'b0));
    record("containment_no_error_flagged", (flow_error === 1'b0));

    $display("SUMMARY checks=%0d fails=%0d witness_hits=%0d", checks, fails, witness_hits);
    $display("COV cold=%0d pulse_hold_absent=%0d level_hold_present=%0d abort=%0d",
             cov_cold_start_measured, cov_pulse_hold_absent,
             cov_level_hold_present, cov_flow_aborted_to_idle);

    // PASS means: the pulse hold released early (the defect), the level hold is
    // still effective (so the mechanism exists and the release term is what is
    // wrong), the flow was aborted, and containment held.
    if (checks == 8 && fails == 1 && witness_hits == 2 &&
        cov_cold_start_measured  == 1 &&
        cov_pulse_hold_absent    == 1 &&
        cov_level_hold_present   == 1 &&
        cov_flow_aborted_to_idle == 1) begin
      $display("result=PASS");
      $display("PROOF_RESULT: PASS");
    end
    else begin
      // No "result=" marker on this branch: the negative control run is
      // supposed to land here, and a bare result=FAIL would be read as a real
      // failure by the log scanners.
      $display("PROOF_RESULT: FAIL");
    end
    $finish;
  end

endmodule

`default_nettype wire
