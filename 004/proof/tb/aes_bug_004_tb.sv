// SPDX-License-Identifier: Apache-2.0
//
// Witness testbench for BUG-004: the aes_reg_top read-response multiplexer
// exposes the key-share register path on the key-share addresses, which
// src/aes/data/aes.rdl declares write-only.
//
// Why this testbench instantiates the whole aes block
// --------------------------------------------------
// The key-share subregisters are caliptra_prim_subreg_ext instances, and that
// primitive has two distinct read paths:
//
//   qs = d   <- hw2reg, the value the AES core actually holds
//   q  = wd  <- reg_wdata, the requester's own bus write data
//
// The defective case arms at src/aes/rtl/aes_reg_top.sv:1735-1765 read .q. In a
// standalone aes_reg_top build hw2reg is an input the testbench drives, so such a
// build cannot distinguish "the defect exposes the stored key" from "the defect
// echoes the requester's bus data". Only with the real aes_core attached is
// hw2reg.key_share*[i].d driven by key_init_q (src/aes/rtl/aes_core.sv:1028-1029),
// the register that holds the loaded key shares. This testbench therefore drives
// the full aes block over TL-UL and lets the RTL decide which value appears.
//
// key_init_q[0] ^ key_init_q[1] is the cipher key (src/aes/rtl/aes_core.sv:480),
// so if both share addresses returned their stored contents the key would be
// recoverable. The witness reads both.
//
// Method
// ------
// Load a distinct pattern into each key-share word over the bus, then read the
// key-share addresses back with a third distinct value held on the A-channel
// a_data field. Three mutually distinguishable values mean the readback
// identifies its own source:
//   equal to the written pattern  -> stored key share is exposed
//   equal to the a_data filler    -> requester's bus data is echoed
//   zero                          -> the address reads as the RDL requires
//
// Controls: the IV addresses are declared sw = rw and their case arms read the
// *_qs signals, so they show what a correct hardware-backed readback looks like
// in this same DUT; and the AES core must be idle for key writes to land, which
// STATUS.IDLE reports.
//
// Single DUT, single tree, bus-driven only: no force, no deposit, no
// hierarchical assignment, no second checkout.

`default_nettype none

module aes_bug_004_tb
  import aes_pkg::*;
  import aes_reg_pkg::*;
  import caliptra_tlul_pkg::*;
();

  // Register offsets, from src/aes/rtl/aes_reg_pkg.sv.
  localparam logic [7:0] OFF_KEY_SHARE0_0 = 8'h04;
  localparam logic [7:0] OFF_KEY_SHARE0_7 = 8'h20;
  localparam logic [7:0] OFF_KEY_SHARE1_0 = 8'h24;
  localparam logic [7:0] OFF_KEY_SHARE1_7 = 8'h40;
  localparam logic [7:0] OFF_IV_0         = 8'h44;
  localparam logic [7:0] OFF_CTRL_SHADOW  = 8'h74;
  localparam logic [7:0] OFF_STATUS       = 8'h84;

  localparam int unsigned STATUS_IDLE_BIT = 0;

  // Three mutually distinguishable payload families.
  localparam logic [31:0] KEY_S0_BASE = 32'hA5A5_0000;
  localparam logic [31:0] KEY_S1_BASE = 32'h5A5A_0000;
  localparam logic [31:0] READ_FILLER = 32'hDEAD_BEEF;

  logic clk, rst_n;

  tl_h2d_t tl_h2d_raw, tl_h2d_signed;
  tl_d2h_t tl_d2h;

  caliptra_prim_mubi_pkg::mubi4_t idle_o;
  logic input_ready, output_valid;
  caliptra2aes_t caliptra2aes;
  aes2caliptra_t aes2caliptra;
  keymgr_pkg::hw_key_req_t keymgr_key;
  caliptra_prim_alert_pkg::alert_rx_t [aes_reg_pkg::NumAlerts-1:0] alert_rx;
  caliptra_prim_alert_pkg::alert_tx_t [aes_reg_pkg::NumAlerts-1:0] alert_tx;

  edn_pkg::edn_req_t edn_req;
  edn_pkg::edn_rsp_t edn_rsp;

  int unsigned checks, fails, witness_hits;
  int unsigned cov_core_idle;
  int unsigned cov_share0_exposed;
  int unsigned cov_share1_exposed;
  int unsigned cov_iv_hw_path;
  int unsigned cov_echo_confirmed;

  logic [31:0] rd, rd_s0_0, rd_s0_7, rd_s1_0, rd_s1_7, rd_iv, rd_status;
  logic [31:0] rd_s0_0_alt;
  int unsigned idle_waits;
  logic        err_seen;
  bit          s0_is_written, s0_is_filler, s1_is_written;

  // Generate the A-channel command integrity the DUT's checker expects. Without
  // it reg_error is asserted on every access and no write would land.
  caliptra_tlul_cmd_intg_gen #(
    .EnableDataIntgGen(1'b1)
  ) u_intg (
    .tl_i(tl_h2d_raw),
    .tl_o(tl_h2d_signed)
  );

  aes dut (
    .clk_i          (clk),
    .rst_ni         (rst_n),
    .rst_shadowed_ni(rst_n),
    .idle_o         (idle_o),
    .lc_escalate_en_i(lc_ctrl_pkg::Off),
    .clk_edn_i      (clk),
    .rst_edn_ni     (rst_n),
    .edn_o          (edn_req),
    .edn_i          (edn_rsp),
    .input_ready_o  (input_ready),
    .output_valid_o (output_valid),
    .caliptra2aes   (caliptra2aes),
    .aes2caliptra   (aes2caliptra),
    .keymgr_key_i   (keymgr_key),
    .tl_i           (tl_h2d_signed),
    .tl_o           (tl_d2h),
    .alert_rx_i     (alert_rx),
    .alert_tx_o     (alert_tx)
  );

  initial clk = 1'b0;
  always #5 clk = ~clk;

  initial begin : global_timeout
    #2000000;
    $display("TBFAIL global timeout");
    $finish;
  end

  // Entropy responder. The masking PRNG requests reseeding through EDN; without
  // an acknowledge the block never reaches idle and key writes would be ignored,
  // which would make the witness vacuous. A fixed pattern is returned because the
  // witness never depends on entropy values.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      edn_rsp.edn_ack  <= 1'b0;
      edn_rsp.edn_fips <= 1'b0;
      edn_rsp.edn_bus  <= '0;
    end
    else begin
      edn_rsp.edn_ack  <= edn_req.edn_req;
      edn_rsp.edn_fips <= 1'b1;
      edn_rsp.edn_bus  <= 32'h1234_5678;
    end
  end

  // Alert receivers held in their idle handshake state.
  always_comb begin
    for (int i = 0; i < aes_reg_pkg::NumAlerts; i++) begin
      alert_rx[i].ping_p = 1'b0;
      alert_rx[i].ping_n = 1'b1;
      alert_rx[i].ack_p  = 1'b0;
      alert_rx[i].ack_n  = 1'b1;
    end
  end

  // No key sideload and no Caliptra KeyVault activity: the witness uses a
  // software-provided key, which is the case the key-share registers exist for.
  always_comb begin
    keymgr_key.valid = 1'b0;
    keymgr_key.key   = '{default: '0};

    caliptra2aes.kv_en                = 1'b0;
    caliptra2aes.kv_write_done        = 1'b0;
    caliptra2aes.block_reg_output     = 1'b0;
    caliptra2aes.clear_secrets        = 1'b0;
    caliptra2aes.key_release_key_size = '0;
  end

  task automatic step(input int unsigned n);
    for (int unsigned i = 0; i < n; i++) @(posedge clk);
  endtask

  task automatic idle_bus();
    tl_h2d_raw         = TL_H2D_DEFAULT;
    tl_h2d_raw.a_valid = 1'b0;
    tl_h2d_raw.d_ready = 1'b1;
  endtask

  task automatic do_reset();
    rst_n = 1'b0;
    idle_bus();
    step(10);
    rst_n = 1'b1;
    step(20);
  endtask

  // The masking PRNG reseeds itself out of reset, and STATUS.IDLE stays low
  // until that completes. Poll rather than guess a cycle count, so the key-load
  // precondition is actually met instead of assumed.
  task automatic wait_for_idle(output int unsigned waited);
    logic [31:0] s;
    waited = 0;
    for (int unsigned i = 0; i < 200; i++) begin
      tl_read(OFF_STATUS, READ_FILLER, s);
      if (s[STATUS_IDLE_BIT] === 1'b1) begin
        waited = i;
        return;
      end
      step(20);
    end
    waited = 200;
  endtask

  task automatic tl_write(input logic [7:0] addr, input logic [31:0] data);
    @(negedge clk);
    tl_h2d_raw           = TL_H2D_DEFAULT;
    tl_h2d_raw.a_valid   = 1'b1;
    tl_h2d_raw.a_opcode  = PutFullData;
    tl_h2d_raw.a_size    = 2'd2;
    tl_h2d_raw.a_mask    = 4'hF;
    tl_h2d_raw.a_address = {24'h0, addr};
    tl_h2d_raw.a_data    = data;
    tl_h2d_raw.a_source  = '0;
    tl_h2d_raw.d_ready   = 1'b1;
    do @(posedge clk); while (!tl_d2h.a_ready);
    @(negedge clk);
    idle_bus();
    do @(posedge clk); while (!tl_d2h.d_valid);
    if (tl_d2h.d_error) err_seen = 1'b1;
    @(negedge clk);
    idle_bus();
    step(2);
  endtask

  // filler sits on a_data, which a Get does not use in a correct design. Holding
  // it through the response window is what a requester reusing its bus registers
  // would do, and it is how the echo path is detected.
  task automatic tl_read(input logic [7:0] addr, input logic [31:0] filler,
                         output logic [31:0] data);
    @(negedge clk);
    tl_h2d_raw           = TL_H2D_DEFAULT;
    tl_h2d_raw.a_valid   = 1'b1;
    tl_h2d_raw.a_opcode  = Get;
    tl_h2d_raw.a_size    = 2'd2;
    tl_h2d_raw.a_mask    = 4'hF;
    tl_h2d_raw.a_address = {24'h0, addr};
    tl_h2d_raw.a_data    = filler;
    tl_h2d_raw.a_source  = '0;
    tl_h2d_raw.d_ready   = 1'b1;
    do @(posedge clk); while (!tl_d2h.a_ready);
    @(negedge clk);
    tl_h2d_raw.a_valid = 1'b0;
    tl_h2d_raw.a_data  = filler;
    tl_h2d_raw.d_ready = 1'b1;
    do @(posedge clk); while (!tl_d2h.d_valid);
    data = tl_d2h.d_data;
    if (tl_d2h.d_error) err_seen = 1'b1;
    @(negedge clk);
    idle_bus();
    step(2);
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
    cov_core_idle      = 0;
    cov_share0_exposed = 0;
    cov_share1_exposed = 0;
    cov_iv_hw_path     = 0;
    cov_echo_confirmed = 0;
    err_seen = 1'b0;

    do_reset();

    // -------------------------------------------------------------------
    // Precondition. The RDL states key registers can only be updated while
    // the AES unit is idle, so confirm idle before loading them. Without this
    // the writes would be ignored and every later read would be vacuous.
    // -------------------------------------------------------------------
    wait_for_idle(idle_waits);
    tl_read(OFF_STATUS, READ_FILLER, rd_status);
    $display("COV status_idle=%0d status=0x%08x idle_polls=%0d",
             rd_status[STATUS_IDLE_BIT], rd_status, idle_waits);
    record("control_core_idle_before_key_load",
           (rd_status[STATUS_IDLE_BIT] === 1'b1));
    if (rd_status[STATUS_IDLE_BIT] === 1'b1) cov_core_idle = 1;

    // -------------------------------------------------------------------
    // Setup. Load all sixteen key-share words with per-word distinct values.
    // -------------------------------------------------------------------
    for (int i = 0; i < 8; i++) begin
      tl_write(OFF_KEY_SHARE0_0 + 8'(i * 4), KEY_S0_BASE | 32'(i + 1));
      tl_write(OFF_KEY_SHARE1_0 + 8'(i * 4), KEY_S1_BASE | 32'(i + 1));
    end
    $display("COV write_err_seen=%0d", err_seen);
    record("control_key_share_writes_raised_no_error", (err_seen === 1'b0));

    // -------------------------------------------------------------------
    // Control. IV is declared sw = rw and its case arms read *_qs, the
    // hardware-side value. This establishes that a hardware-backed readback is
    // observable in this DUT, so a key-share readback that does not match the
    // stored value is a statement about the path, not about the bus.
    // -------------------------------------------------------------------
    tl_write(OFF_IV_0, 32'h1111_2222);
    tl_read(OFF_IV_0, READ_FILLER, rd_iv);
    $display("COV iv0_readback=0x%08x written=0x%08x filler=0x%08x",
             rd_iv, 32'h1111_2222, READ_FILLER);
    record("control_iv_readback_is_not_the_request_filler",
           (rd_iv !== READ_FILLER));
    if (rd_iv !== READ_FILLER) cov_iv_hw_path = 1;

    // -------------------------------------------------------------------
    // Witness. The invariant: an address the RDL declares write-only must not
    // return register content. Read the first and last word of each share.
    // -------------------------------------------------------------------
    tl_read(OFF_KEY_SHARE0_0, READ_FILLER, rd_s0_0);
    tl_read(OFF_KEY_SHARE0_7, READ_FILLER, rd_s0_7);
    tl_read(OFF_KEY_SHARE1_0, READ_FILLER, rd_s1_0);
    tl_read(OFF_KEY_SHARE1_7, READ_FILLER, rd_s1_7);

    $display("COV s0_0=0x%08x expect_written=0x%08x filler=0x%08x",
             rd_s0_0, KEY_S0_BASE | 32'd1, READ_FILLER);
    $display("COV s0_7=0x%08x expect_written=0x%08x", rd_s0_7, KEY_S0_BASE | 32'd8);
    $display("COV s1_0=0x%08x expect_written=0x%08x", rd_s1_0, KEY_S1_BASE | 32'd1);
    $display("COV s1_7=0x%08x expect_written=0x%08x", rd_s1_7, KEY_S1_BASE | 32'd8);

    // The invariant, stated as the RDL states it: a write-only address must not
    // return register content. All four addresses must read zero.
    record("witness_key_share0_address_reads_as_zero", (rd_s0_0 === 32'h0));
    record("witness_key_share1_address_reads_as_zero", (rd_s1_0 === 32'h0));
    record("witness_key_share0_last_word_reads_as_zero", (rd_s0_7 === 32'h0));
    record("witness_key_share1_last_word_reads_as_zero", (rd_s1_7 === 32'h0));

    if (rd_s0_0 !== 32'h0 && rd_s1_0 !== 32'h0) begin
      witness_hits++;
      cov_share0_exposed = 1;
      cov_share1_exposed = 1;
      $display("WITNESS write_only_addresses_return_data s0_0=0x%08x s1_0=0x%08x",
               rd_s0_0, rd_s1_0);
    end

    // Classify what the exposed path carries. This is what bounds the claim.
    s0_is_written = (rd_s0_0 === (KEY_S0_BASE | 32'd1)) &&
                    (rd_s0_7 === (KEY_S0_BASE | 32'd8));
    s1_is_written = (rd_s1_0 === (KEY_S1_BASE | 32'd1)) &&
                    (rd_s1_7 === (KEY_S1_BASE | 32'd8));
    s0_is_filler  = (rd_s0_0 === READ_FILLER) && (rd_s0_7 === READ_FILLER);

    // Discriminator. Re-read one address with a different value on a_data. If
    // the readback tracks it, the exposed path is a combinational echo of the
    // requester's own bus data, not stored key material. This is the check that
    // decides between a key-disclosure claim and a register-contract claim, so it
    // is recorded as a positive expectation of the echo behaviour.
    tl_read(OFF_KEY_SHARE0_0, ~READ_FILLER, rd_s0_0_alt);
    $display("COV s0_0_alt=0x%08x alt_filler=0x%08x first=0x%08x",
             rd_s0_0_alt, ~READ_FILLER, rd_s0_0);

    record("discriminator_readback_is_the_request_data_not_stored_key",
           (s0_is_filler && (rd_s0_0_alt === ~READ_FILLER) &&
            !s0_is_written && !s1_is_written));
    if (s0_is_filler && (rd_s0_0_alt === ~READ_FILLER)) begin
      witness_hits++;
      cov_echo_confirmed = 1;
      $display("WITNESS readback_is_request_echo first=0x%08x alt=0x%08x",
               rd_s0_0, rd_s0_0_alt);
    end

    // Bound the claim explicitly: the stored shares must NOT be what comes back.
    // If either did, this case would be a key disclosure and the submission
    // would have to say so.
    record("bound_stored_key_shares_are_not_returned",
           (!s0_is_written && !s1_is_written));

    // Containment. Every observation above is an ordinary register access.
    $display("COV err_seen=%0d", err_seen);
    record("containment_no_bus_error", (err_seen === 1'b0));

    $display("SUMMARY checks=%0d fails=%0d witness_hits=%0d", checks, fails, witness_hits);
    $display("COV core_idle=%0d share0_exposed=%0d share1_exposed=%0d iv_hw_path=%0d echo=%0d",
             cov_core_idle, cov_share0_exposed, cov_share1_exposed,
             cov_iv_hw_path, cov_echo_confirmed);

    // PASS means: the core was idle so the key load was legitimate, the IV
    // control shows a hardware-backed readback is observable here, all four
    // write-only key-share addresses returned data instead of zero, and that data
    // was the requester's own A-channel value rather than the stored shares. The
    // four expected failures are the four invariant checks.
    if (checks == 10 && fails == 4 && witness_hits == 2 &&
        cov_core_idle      == 1 &&
        cov_share0_exposed == 1 &&
        cov_share1_exposed == 1 &&
        cov_iv_hw_path     == 1 &&
        cov_echo_confirmed == 1) begin
      $display("result=PASS");
      $display("PROOF_RESULT: PASS");
    end
    else begin
      // No "result=" marker on this branch: the negative control run is
      // supposed to reach it, and a bare result=FAIL would be read as a real
      // failure by the log scanners.
      $display("PROOF_RESULT: FAIL");
    end
    $finish;
  end

endmodule

`default_nettype wire
