// SPDX-License-Identifier: Apache-2.0
//
// Witness testbench for BUG-N-002: the sha512 zeroize branch does not clear the
// PCR hash-extend routing state.
//
// sha512.sv:216-260 is one reg_update block with three branches. The
// asynchronous reset branch clears pcr_hash_extend_ip and hash_extend_entry
// (sha512.sv:224-225). The zeroize branch (sha512.sv:229-238) clears eight other
// registers but not those two, and their only updates live in the else branch
// (sha512.sv:255-257), which zeroize does not take. So both hold their value
// across a zeroize event.
//
// pcr_hash_extend_ip is not a status bit. While it is set it rewrites the block's
// vault routing:
//   sha512.sv:459-462  gates every pv_write field
//   sha512.sv:470      forces kv_write_ctrl_reg_q.write_en to '1
//   sha512.sv:471      overrides write_entry with hash_extend_entry
//   sha512.sv:335      holds GEN_PCR_HASH_STATUS.READY low
//
// Its only clear outside reset is pcr_hash_extend_reset at sha512.sv:372, which
// is (pcr_hash_extend_ip & kv_dest_done). A residual bit therefore needs a vault
// destination completion to retire, and until then the block reports itself not
// ready through an ordinary MMIO status register.
//
// Witness method
// -------------
// The observation is made entirely through the module's own register bus. Setting
// VAULT_RD_CTRL with PCR_HASH_EXTEND raises pcr_hash_extend_ip, then ZEROIZE is
// written, then GEN_PCR_HASH_STATUS.READY is polled. If the zeroize branch
// cleared the bit, READY would return high, because zeroize also clears
// gen_hash_ip's companion state and ready_reg follows core_ready. Observing READY
// still low after zeroize, while the plain SHA512_STATUS.READY reports the core
// itself as ready, isolates the residual routing bit as the cause.
//
// Single DUT, single tree, bus-driven only: no force, no deposit, no hierarchical
// assignment, no second checkout.

`default_nettype none

module sha512_bug_n002_tb
  import sha512_reg_pkg::*;
  import sha512_params_pkg::*;
  import kv_defines_pkg::*;
  import pv_defines_pkg::*;
();

  localparam int unsigned AW = 32;
  localparam int unsigned DW = 32;   // the tree instantiates sha512 with DATA_WIDTH(32)

  // Register offsets within the SHA-512 aperture, from the generated header
  // (caliptra_reg.h) minus CLP_SHA512_REG_BASE_ADDR = 0x10020000.
  localparam logic [31:0] OFF_CTRL                 = 32'h0000_0010;
  localparam logic [31:0] OFF_STATUS               = 32'h0000_0018;
  localparam logic [31:0] OFF_VAULT_RD_CTRL        = 32'h0000_0600;
  localparam logic [31:0] OFF_VAULT_RD_STATUS      = 32'h0000_0604;
  localparam logic [31:0] OFF_KV_WR_CTRL           = 32'h0000_0608;
  localparam logic [31:0] OFF_GEN_PCR_HASH_CTRL    = 32'h0000_0630;
  localparam logic [31:0] OFF_GEN_PCR_HASH_STATUS  = 32'h0000_0634;

  // Field positions, from caliptra_reg_field_defines.svh.
  localparam int unsigned CTRL_ZEROIZE_BIT       = 4;   // SHA512_CTRL.ZEROIZE
  localparam int unsigned RD_CTRL_READ_EN_BIT    = 0;   // VAULT_RD_CTRL.read_en
  localparam int unsigned RD_CTRL_ENTRY_LSB      = 1;   // VAULT_RD_CTRL.read_entry [5:1]
  localparam int unsigned RD_CTRL_PCR_EXTEND_BIT = 6;   // VAULT_RD_CTRL.pcr_hash_extend
  localparam int unsigned STATUS_READY_BIT       = 0;   // SHA512_STATUS.READY
  localparam int unsigned GEN_STATUS_READY_BIT   = 0;   // GEN_PCR_HASH_STATUS.READY

  localparam logic [4:0] EXTEND_ENTRY = 5'd7;  // marker PCR entry for the extend

  logic clk, reset_n, cptra_pwrgood;
  logic cs, we;
  logic [AW-1:0] address;
  logic [DW-1:0] write_data;
  wire  [DW-1:0] read_data;
  wire           err;

  pv_read_t     pv_read;
  pv_write_t    pv_write;
  pv_rd_resp_t  pv_rd_resp;
  pv_wr_resp_t  pv_wr_resp;
  wire [PCR_HASH_NUM_DWORDS-1:0][DW-1:0] pcr_signing_hash;
  wire error_intr, notif_intr;
  logic debugUnlock_or_scan_mode_switch;

  int unsigned checks, fails, witness_hits;
  int unsigned cov_extend_ip_set;
  int unsigned cov_ip_survives_zeroize;
  int unsigned cov_core_reports_ready;
  int unsigned cov_no_extend_no_stall;

  logic [31:0] rd;
  logic [31:0] gen_ready_before, gen_ready_after_zeroize, gen_ready_baseline;
  logic [31:0] core_ready_after_zeroize;

  sha512 #(
    .ADDR_WIDTH(AW),
    .DATA_WIDTH(DW)
  ) dut (
    .clk             (clk),
    .reset_n         (reset_n),
    .cptra_pwrgood   (cptra_pwrgood),
    .cs              (cs),
    .we              (we),
    .address         (address),
    .write_data      (write_data),
    .read_data       (read_data),
    .err             (err),
    .pv_read         (pv_read),
    .pv_write        (pv_write),
    .pv_rd_resp      (pv_rd_resp),
    .pv_wr_resp      (pv_wr_resp),
    .pcr_signing_hash(pcr_signing_hash),
    .error_intr      (error_intr),
    .notif_intr      (notif_intr),
    .debugUnlock_or_scan_mode_switch(debugUnlock_or_scan_mode_switch)
  );

  initial clk = 1'b0;
  always #5 clk = ~clk;

  initial begin : global_timeout
    #500000;
    $display("TBFAIL global timeout");
    $finish;
  end

  // The PCR vault is not modelled: responses are held quiescent so no vault
  // completion is ever returned. That is deliberate. kv_dest_done is what would
  // retire pcr_hash_extend_ip through sha512.sv:372, and the claim is precisely
  // that zeroize does not retire it on its own.
  always_comb begin
    pv_rd_resp.error     = 1'b0;
    pv_rd_resp.last      = 1'b0;
    pv_rd_resp.read_data = '0;
    pv_wr_resp.error     = 1'b0;
  end

  task automatic step(input int unsigned n);
    for (int unsigned i = 0; i < n; i++) @(posedge clk);
  endtask

  task automatic bus_write(input logic [31:0] a, input logic [31:0] d);
    @(negedge clk);
    cs = 1'b1; we = 1'b1; address = a; write_data = d;
    @(negedge clk);
    cs = 1'b0; we = 1'b0; address = '0; write_data = '0;
  endtask

  task automatic bus_read(input logic [31:0] a, output logic [31:0] d);
    @(negedge clk);
    cs = 1'b1; we = 1'b0; address = a;
    @(posedge clk);
    #1 d = read_data;
    @(negedge clk);
    cs = 1'b0; address = '0;
  endtask

  task automatic do_reset();
    reset_n       = 1'b0;
    cptra_pwrgood = 1'b0;
    cs = 1'b0; we = 1'b0; address = '0; write_data = '0;
    debugUnlock_or_scan_mode_switch = 1'b0;
    step(4);
    cptra_pwrgood = 1'b1;
    step(2);
    reset_n = 1'b1;
    step(6);
  endtask

  // Raise pcr_hash_extend_ip. sha512.sv:371 sets it from
  // (kv_read_ctrl_reg.read_en & kv_read_ctrl_reg.pcr_hash_extend), both of which
  // are fields of one software-writable register.
  task automatic start_pcr_hash_extend(input logic [4:0] entry);
    logic [31:0] v;
    v = '0;
    v[RD_CTRL_READ_EN_BIT]    = 1'b1;
    v[RD_CTRL_ENTRY_LSB+4 -: 5] = entry;
    v[RD_CTRL_PCR_EXTEND_BIT] = 1'b1;
    bus_write(OFF_VAULT_RD_CTRL, v);
    step(4);
  endtask

  task automatic assert_zeroize();
    logic [31:0] v;
    v = '0;
    v[CTRL_ZEROIZE_BIT] = 1'b1;
    bus_write(OFF_CTRL, v);
    step(6);
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
    cov_extend_ip_set       = 0;
    cov_ip_survives_zeroize = 0;
    cov_core_reports_ready  = 0;
    cov_no_extend_no_stall  = 0;

    // -------------------------------------------------------------------
    // Case A - baseline. With no hash extend ever started, the PCR hash
    // status must report ready. This establishes that the register reads
    // high in the quiescent block, so a low read later means something.
    // -------------------------------------------------------------------
    do_reset();
    bus_read(OFF_GEN_PCR_HASH_STATUS, gen_ready_baseline);
    $display("COV baseline_gen_ready=%0d", gen_ready_baseline[GEN_STATUS_READY_BIT]);
    record("control_quiescent_pcr_hash_status_ready",
           (gen_ready_baseline[GEN_STATUS_READY_BIT] === 1'b1));

    // -------------------------------------------------------------------
    // Case B - control. A zeroize with no hash extend in flight must leave
    // the block ready. This separates "zeroize stalls the block" from
    // "the residual routing bit stalls the block".
    // -------------------------------------------------------------------
    do_reset();
    assert_zeroize();
    bus_read(OFF_GEN_PCR_HASH_STATUS, rd);
    $display("COV gen_ready_after_bare_zeroize=%0d", rd[GEN_STATUS_READY_BIT]);
    record("control_zeroize_alone_leaves_block_ready",
           (rd[GEN_STATUS_READY_BIT] === 1'b1));
    if (rd[GEN_STATUS_READY_BIT] === 1'b1) cov_no_extend_no_stall = 1;

    // -------------------------------------------------------------------
    // Case C - witness. Start a PCR hash extend, confirm the block reports
    // itself busy, then zeroize and re-read. The invariant under test is
    // that a security erase returns the block to its ready state.
    // -------------------------------------------------------------------
    do_reset();
    start_pcr_hash_extend(EXTEND_ENTRY);
    bus_read(OFF_GEN_PCR_HASH_STATUS, gen_ready_before);
    $display("COV gen_ready_during_extend=%0d", gen_ready_before[GEN_STATUS_READY_BIT]);
    record("witness_setup_extend_took_effect",
           (gen_ready_before[GEN_STATUS_READY_BIT] === 1'b0));
    if (gen_ready_before[GEN_STATUS_READY_BIT] === 1'b0) cov_extend_ip_set = 1;

    assert_zeroize();
    bus_read(OFF_GEN_PCR_HASH_STATUS, gen_ready_after_zeroize);
    bus_read(OFF_STATUS, core_ready_after_zeroize);
    $display("COV gen_ready_after_zeroize=%0d core_ready_after_zeroize=%0d",
             gen_ready_after_zeroize[GEN_STATUS_READY_BIT],
             core_ready_after_zeroize[STATUS_READY_BIT]);

    // The invariant. A zeroize must clear the hash-extend routing state, so
    // the PCR hash status must read ready again afterwards.
    record("witness_zeroize_clears_extend_routing_state",
           (gen_ready_after_zeroize[GEN_STATUS_READY_BIT] === 1'b1));

    if (gen_ready_after_zeroize[GEN_STATUS_READY_BIT] === 1'b0) begin
      witness_hits++;
      cov_ip_survives_zeroize = 1;
      $display("WITNESS extend_routing_state_survives_zeroize gen_ready=%0d",
               gen_ready_after_zeroize[GEN_STATUS_READY_BIT]);
    end

    // Discriminator: the SHA-512 core itself must report ready after the
    // zeroize. If it did not, the low PCR hash status could be blamed on
    // ready_reg rather than on the residual routing bit, since
    // sha512.sv:335 ANDs both.
    record("discriminator_core_status_ready_after_zeroize",
           (core_ready_after_zeroize[STATUS_READY_BIT] === 1'b1));
    if (core_ready_after_zeroize[STATUS_READY_BIT] === 1'b1) begin
      witness_hits++;
      cov_core_reports_ready = 1;
      $display("WITNESS core_reports_ready_so_stall_is_routing_state core_ready=%0d",
               core_ready_after_zeroize[STATUS_READY_BIT]);
    end

    // Containment: the residual state must not be retiring on its own over
    // time. Poll again after a long idle window with no vault completion.
    step(200);
    bus_read(OFF_GEN_PCR_HASH_STATUS, rd);
    $display("COV gen_ready_after_idle=%0d", rd[GEN_STATUS_READY_BIT]);
    record("containment_residual_state_does_not_self_retire",
           (rd[GEN_STATUS_READY_BIT] === 1'b0));

    // Containment: no bus error was raised by any access in the sequence, so
    // the observation is an ordinary register read rather than a fault path.
    record("containment_no_bus_error", (err === 1'b0));

    $display("SUMMARY checks=%0d fails=%0d witness_hits=%0d", checks, fails, witness_hits);
    $display("COV extend_set=%0d ip_survives=%0d core_ready=%0d no_extend_no_stall=%0d",
             cov_extend_ip_set, cov_ip_survives_zeroize,
             cov_core_reports_ready, cov_no_extend_no_stall);

    // PASS means: the block is ready when quiescent and after a bare zeroize,
    // a hash extend makes it busy, and after a zeroize it is still busy while
    // the core itself reports ready. The single expected failure is the
    // invariant check that zeroize clears the routing state.
    if (checks == 7 && fails == 1 && witness_hits == 2 &&
        cov_extend_ip_set       == 1 &&
        cov_ip_survives_zeroize == 1 &&
        cov_core_reports_ready  == 1 &&
        cov_no_extend_no_stall  == 1) begin
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
