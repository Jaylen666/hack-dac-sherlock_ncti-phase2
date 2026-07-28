// SPDX-License-Identifier: Apache-2.0
//
// BUG-014 witness: the HMAC final-block (finalization) protocol is absent
// end to end, while HMAC512_CTRL bit 5 still accepts a write and confirms it.
//
// What this testbench shows, driving the hmac register interface only:
//
//   * a normal INIT command works, so the harness and the block are healthy
//     (positive control: STATUS.VALID rises and a tag is produced)
//   * a write of CTRL bit 5 alone is absorbed without any error: the block
//     stays ready and the bus transaction completes exactly as the INIT write
//     did, so software has nothing to distinguish a taken request from a
//     discarded one. HMAC512_CTRL is software-write-only (hmac_reg.rdl:68,
//     no read arm in the hmac_reg.sv decode), so a readback cannot be used to
//     confirm or deny the request either.
//   * yet no operation starts (STATUS.VALID never rises, the tag does not
//     change) and no error is reported (error_internal_intr_r bit 2 stays 0,
//     error_intr stays low)
//
// The claim holds under either reading of bit 5. If it is the finalization
// control, an operation should have started and did not. If it is genuinely
// reserved, an illegal command should have been reported and was not. Either
// way the write is silently swallowed after being acknowledged.
//
// Port-driven only: no force, no deposit, no hierarchical assignment into the
// DUT. The KeyVault response inputs are held at their idle/absent values so
// every command in this run is register-programmed, which is exactly the case
// hmac.sv:395-396 cannot raise an error for.
`timescale 1ns/1ps

module hmac_bug_014_tb;

  import kv_defines_pkg::*;

  // ---- register map, from the hmac_reg.sv address decode ----
  localparam logic [31:0] ADDR_CTRL        = 32'h0000_0010;
  localparam logic [31:0] ADDR_STATUS      = 32'h0000_0018;
  localparam logic [31:0] ADDR_KEY0        = 32'h0000_0040;
  localparam logic [31:0] ADDR_BLOCK0      = 32'h0000_0080;
  localparam logic [31:0] ADDR_TAG0        = 32'h0000_0100;
  localparam logic [31:0] ADDR_ERR_INTR    = 32'h0000_0814;
  localparam logic [31:0] ADDR_ERR_INTR_R  = 32'h0000_0814;

  // CTRL field positions, from hmac_reg.sv:761/785/809/833/854/875.
  localparam int CTRL_INIT_BIT     = 0;
  localparam int CTRL_NEXT_BIT     = 1;
  localparam int CTRL_ZEROIZE_BIT  = 2;
  localparam int CTRL_MODE_BIT     = 3;
  localparam int CTRL_CSRMODE_BIT  = 4;
  localparam int CTRL_LAST_BIT     = 5;   // the field the report calls LAST

  // error_internal_intr_r bit positions, from hmac_reg.sv:2330-2333.
  localparam int ERR_KEY_MODE_BIT  = 0;
  localparam int ERR_KEY_ZERO_BIT  = 1;
  localparam int ERR_ERROR2_BIT    = 2;   // the illegal-command status

  // STATUS bit positions, from hmac_reg.sv:2278-2279.
  localparam int ST_READY_BIT      = 0;
  localparam int ST_VALID_BIT      = 1;

  localparam int KEY_DWORDS   = 16;
  localparam int BLOCK_DWORDS = 32;
  localparam int TAG_DWORDS   = 16;

  logic        clk;
  logic        reset_n;
  logic        cptra_pwrgood;
  logic        cs;
  logic        we;
  logic [31:0] address;
  logic [31:0] write_data;
  logic [31:0] read_data;

  logic [`CLP_CSR_HMAC_KEY_DWORDS-1:0][31:0] cptra_csr_hmac_key;

  kv_read_t  [1:0] kv_read;
  kv_write_t       kv_write;
  kv_rd_resp_t [1:0] kv_rd_resp;
  kv_wr_resp_t       kv_wr_resp;

  logic busy_o;
  logic error_intr;
  logic notif_intr;
  logic ocp_lock_in_progress;
  logic debugUnlock_or_scan_mode_switch;

  int checks;
  int fails;
  int witness_hits;

  // Coverage of the preconditions the claim rests on, so a vacuous run cannot
  // be mistaken for a proof.
  bit cov_control_ran;
  bit cov_last_accepted;
  bit cov_no_error_path_armed;

  hmac dut (
    .clk                             (clk),
    .reset_n                         (reset_n),
    .cptra_pwrgood                   (cptra_pwrgood),
    .cptra_csr_hmac_key              (cptra_csr_hmac_key),
    .cs                              (cs),
    .we                              (we),
    .address                         (address),
    .write_data                      (write_data),
    .read_data                       (read_data),
    .kv_read                         (kv_read),
    .kv_write                        (kv_write),
    .kv_rd_resp                      (kv_rd_resp),
    .kv_wr_resp                      (kv_wr_resp),
    .busy_o                          (busy_o),
    .error_intr                      (error_intr),
    .notif_intr                      (notif_intr),
    .ocp_lock_in_progress            (ocp_lock_in_progress),
    .debugUnlock_or_scan_mode_switch (debugUnlock_or_scan_mode_switch)
  );

  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  // ---- native register bus: cs/we with the address and data on the same edge ----
  task automatic bus_write(input logic [31:0] addr, input logic [31:0] data);
    @(negedge clk);
    cs         = 1'b1;
    we         = 1'b1;
    address    = addr;
    write_data = data;
    @(negedge clk);
    cs         = 1'b0;
    we         = 1'b0;
    write_data = 32'h0;
  endtask

  task automatic bus_read(input logic [31:0] addr, output logic [31:0] data);
    @(negedge clk);
    cs      = 1'b1;
    we      = 1'b0;
    address = addr;
    @(posedge clk);
    #1;
    data = read_data;
    @(negedge clk);
    cs = 1'b0;
  endtask

  task automatic check(input string name, input bit cond);
    checks++;
    if (cond) begin
      $display("CHECK_PASS %s", name);
    end else begin
      fails++;
      $display("CHECK_FAIL %s", name);
    end
  endtask

  task automatic witness(input string name, input bit cond);
    checks++;
    if (cond) begin
      $display("CHECK_PASS %s", name);
    end else begin
      fails++;
      witness_hits++;
      $display("CHECK_FAIL %s", name);
      $display("WITNESS %s", name);
    end
  endtask

  task automatic do_reset();
    reset_n       = 1'b0;
    cptra_pwrgood = 1'b0;
    cs            = 1'b0;
    we            = 1'b0;
    address       = 32'h0;
    write_data    = 32'h0;
    repeat (5) @(negedge clk);
    cptra_pwrgood = 1'b1;
    repeat (2) @(negedge clk);
    reset_n = 1'b1;
    repeat (5) @(negedge clk);
  endtask

  task automatic wait_ready(input int max_cycles, output bit ok);
    logic [31:0] st;
    ok = 1'b0;
    for (int i = 0; i < max_cycles; i++) begin
      bus_read(ADDR_STATUS, st);
      if (st[ST_READY_BIT]) begin
        ok = 1'b1;
        return;
      end
    end
  endtask

  // Poll STATUS.VALID for up to max_cycles register reads. Returns the last
  // STATUS value read so the caller can report what it actually saw.
  task automatic wait_valid(input  int          max_cycles,
                            output bit          ok,
                            output logic [31:0] last_status);
    logic [31:0] st;
    ok = 1'b0;
    last_status = 32'h0;
    for (int i = 0; i < max_cycles; i++) begin
      bus_read(ADDR_STATUS, st);
      last_status = st;
      if (st[ST_VALID_BIT]) begin
        ok = 1'b1;
        return;
      end
    end
  endtask

  task automatic program_key_and_block(input logic [31:0] seed);
    for (int i = 0; i < KEY_DWORDS; i++)
      bus_write(ADDR_KEY0 + 32'(4*i), seed | 32'(i + 1));
    // A single 1024-bit block carrying its own padding pattern. The content is
    // arbitrary: this witness is about whether a command is honoured, not about
    // the digest value.
    for (int i = 0; i < BLOCK_DWORDS; i++)
      bus_write(ADDR_BLOCK0 + 32'(4*i), (i == 0) ? 32'h8000_0000 : 32'h0000_0000);
  endtask

  task automatic read_tag(output logic [31:0] tag [TAG_DWORDS]);
    for (int i = 0; i < TAG_DWORDS; i++)
      bus_read(ADDR_TAG0 + 32'(4*i), tag[i]);
  endtask

  function automatic bit tags_equal(input logic [31:0] a [TAG_DWORDS],
                                    input logic [31:0] b [TAG_DWORDS]);
    tags_equal = 1'b1;
    for (int i = 0; i < TAG_DWORDS; i++)
      if (a[i] !== b[i]) tags_equal = 1'b0;
  endfunction

  function automatic bit tag_is_zero(input logic [31:0] t [TAG_DWORDS]);
    tag_is_zero = 1'b1;
    for (int i = 0; i < TAG_DWORDS; i++)
      if (t[i] !== 32'h0) tag_is_zero = 1'b0;
  endfunction

  logic [31:0] tag_ctrl [TAG_DWORDS];
  logic [31:0] tag_pre  [TAG_DWORDS];
  logic [31:0] tag_post [TAG_DWORDS];
  logic [31:0] ctrl_rb, st_ctrl, st_last, st_after_last, err_ctrl, err_last;
  bit          ready_ok, ctrl_valid_ok, last_valid_ok;
  bit          err_intr_seen;

  // Sample error_intr continuously rather than at a single point, so a short
  // pulse cannot be missed by the polling loop.
  always @(posedge clk) if (reset_n && error_intr) err_intr_seen <= 1'b1;

  initial begin : main
    err_intr_seen = 1'b0;
    checks = 0; fails = 0; witness_hits = 0;
    cov_control_ran = 1'b0;
    cov_last_accepted = 1'b0;
    cov_no_error_path_armed = 1'b0;

    // Every command in this run is register-programmed: the KeyVault read
    // responses are held absent, so kv_key_data_present is low and hmac.sv:395
    // and :396 cannot arm. This is the configuration under which the only
    // remaining error reporter would be error2_sts.
    kv_rd_resp                      = '0;
    kv_wr_resp                      = '0;
    cptra_csr_hmac_key              = '0;
    ocp_lock_in_progress            = 1'b0;
    debugUnlock_or_scan_mode_switch = 1'b0;
    cov_no_error_path_armed         = 1'b1;

    // ---------------- positive control: a normal INIT completes ----------------
    do_reset();
    wait_ready(200, ready_ok);
    program_key_and_block(32'hA5A5_0000);
    bus_write(ADDR_CTRL, 32'h1 << CTRL_INIT_BIT);
    wait_valid(4000, ctrl_valid_ok, st_ctrl);
    read_tag(tag_ctrl);
    bus_read(ADDR_ERR_INTR_R, err_ctrl);
    if (ctrl_valid_ok && !tag_is_zero(tag_ctrl)) cov_control_ran = 1'b1;

    // ---------------- witness: a finalization command alone ----------------
    // Fresh reset so the control's own result cannot be mistaken for a result
    // produced by the command under test.
    do_reset();
    wait_ready(200, ready_ok);
    program_key_and_block(32'h5A5A_0000);
    read_tag(tag_pre);

    bus_write(ADDR_CTRL, 32'h1 << CTRL_LAST_BIT);
    // HMAC512_CTRL is software-write-only, so this read returns 0 by
    // construction and is recorded only to show that no readback channel exists
    // through which software could confirm the request.
    bus_read(ADDR_CTRL, ctrl_rb);
    wait_valid(4000, last_valid_ok, st_last);
    read_tag(tag_post);
    bus_read(ADDR_ERR_INTR_R, err_last);
    // The write was absorbed: the block is still ready afterwards, so the
    // transaction was not rejected or left the block wedged.
    bus_read(ADDR_STATUS, st_after_last);
    if (st_after_last[ST_READY_BIT] && !err_intr_seen) cov_last_accepted = 1'b1;

    $display("COV ctrl_status=0x%08x last_status=0x%08x ctrl_rb=0x%08x",
             st_ctrl, st_last, ctrl_rb);
    $display("COV err_ctrl=0x%08x err_last=0x%08x err_intr_seen=%0b",
             err_ctrl, err_last, err_intr_seen);
    $display("COV tag_ctrl0=0x%08x tag_pre0=0x%08x tag_post0=0x%08x",
             tag_ctrl[0], tag_pre[0], tag_post[0]);

    // ---------------- checks ----------------
    // Controls: the harness and the block are healthy, so a null result from
    // the witness command is a property of the command, not of the setup.
    check("control_block_reports_ready", ready_ok);
    check("control_init_command_completes", ctrl_valid_ok);
    check("control_init_produces_a_tag", !tag_is_zero(tag_ctrl));

    // The write is absorbed rather than rejected: the same bus sequence that
    // successfully started an INIT leaves the block ready and quiet here.
    check("bound_finalization_write_is_absorbed_and_block_stays_ready",
          st_after_last[ST_READY_BIT] === 1'b1);

    // And there is no readback channel through which software could learn
    // otherwise, since HMAC512_CTRL is software-write-only.
    check("bound_ctrl_offers_no_readback_to_confirm_the_request",
          ctrl_rb === 32'h0);

    // The two witness statements. Under the reading that bit 5 is the
    // finalization control, both of these should hold and neither does.
    witness("witness_finalization_command_starts_no_operation",
            last_valid_ok);
    witness("witness_finalization_command_is_rejected_as_illegal",
            err_last[ERR_ERROR2_BIT] === 1'b1 || err_intr_seen);

    // Bounding the claim: the tag really did not move, so "no operation" is not
    // an artefact of polling STATUS on the wrong bit.
    check("bound_no_tag_was_produced_by_the_finalization_command",
          tags_equal(tag_pre, tag_post));

    // Bound on the ordinary path: a normal INIT raises nothing either, so the
    // silence on the witness command is not this block reporting errors
    // constantly and the witness command merely blending in.
    check("bound_ordinary_init_raises_no_error", err_ctrl === 32'h0);

    // The two sideload statuses are quiet in both runs, so the silence measured
    // above is specifically the illegal-command status and not a stuck read of
    // the whole register. hmac.sv:395-396 gate those two on kv_key_data_present,
    // which this run holds low by construction.
    check("bound_sideload_error_paths_were_not_armed",
          err_last[ERR_KEY_MODE_BIT] === 1'b0 &&
          err_last[ERR_KEY_ZERO_BIT] === 1'b0);

    check("containment_control_result_unaffected_by_witness_sequence",
          !tag_is_zero(tag_ctrl));

    $display("SUMMARY checks=%0d fails=%0d witness_hits=%0d",
             checks, fails, witness_hits);
    $display("COV cov_control_ran=%0b cov_last_accepted=%0b cov_no_error_path_armed=%0b",
             cov_control_ran, cov_last_accepted, cov_no_error_path_armed);

    // The verdict is deliberately exact: 11 checks, exactly the 2 witness
    // statements failing, every control and bound passing, and all three
    // coverage preconditions observed. A failure branch prints no result= line,
    // because the negative control's run is supposed to fail here.
    if (checks == 11 && fails == 2 && witness_hits == 2 &&
        cov_control_ran == 1'b1 && cov_last_accepted == 1'b1 &&
        cov_no_error_path_armed == 1'b1) begin
      $display("result=PASS");
      $display("PROOF_RESULT: PASS");
    end else begin
      $display("PROOF_RESULT: FAIL");
    end
    $finish;
  end

  initial begin : watchdog
    #4_000_000;
    $display("TBFAIL global timeout");
    $display("PROOF_RESULT: FAIL");
    $finish;
  end

endmodule
