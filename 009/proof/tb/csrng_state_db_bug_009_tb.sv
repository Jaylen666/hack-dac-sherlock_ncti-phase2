// SPDX-License-Identifier: Apache-2.0
//
// BUG-009 directed witness: the CSRNG internal-state dump is qualified by
// application 0's read-enable bit for every application, so the authorization of one
// application decides whether any application's DRBG state may be read.
//
// Property under test: int_state_read_enable_i is a per-application authorization
// vector (src/csrng/rtl/csrng_state_db.sv:50, one bit per app). The internal state it
// guards contains the DRBG key and V, so a read of application N's state must be
// permitted exactly when bit N of that vector is set.
//
// src/csrng/rtl/csrng_state_db.sv:115 forms the qualification as
//   int_st_dump_sel & {NApps{int_state_read_enable_i[0]}}
// replicating bit 0 across all lanes rather than indexing the selected application.
// The assignment sits outside the per-application generate loop at :117 that provides
// the index rd, so every lane is gated by application 0's bit.
//
// This testbench instantiates one real csrng_state_db and drives it only through its
// declared ports: states are loaded through the write interface and read back through
// the status/register interface, exactly as csrng_core drives them. There is no force,
// no deposit and no hierarchical assignment anywhere in this harness.
//
`timescale 1ns/1ps

module csrng_state_db_bug_009_tb
  import csrng_pkg::*;
();

  localparam int unsigned CLK_HALF = 5;
  localparam int unsigned NAPPS   = 4;
  localparam int unsigned STATEID = 4;
  localparam int unsigned KEYLEN  = 256;
  localparam int unsigned BLKLEN  = 128;
  localparam int unsigned CTRLEN  = 32;

  // Reg-read pointer positions within internal_state_diag. The concatenation at
  // src/csrng/rtl/csrng_state_db.sv:135-137 orders the state as
  // {fips, inst_st, key[255:0], v[127:0], res_ctr[31:0]}, so word 0 is the reseed
  // counter, words 1..4 are V and words 5..12 are the DRBG key.
  //
  // Every probe below reads a key word, not the counter word: line 180 exports the
  // reseed counter unconditionally through reseed_counter_o, so the counter is
  // readable by design and would be a weak witness. The key is not.
  localparam int unsigned PTR_IN_KEY = 5;

  logic clk, rst_ni;
  logic state_db_enable;
  logic [STATEID-1:0] rd_inst_id;
  logic [KEYLEN-1:0]  rd_key;
  logic [BLKLEN-1:0]  rd_v;
  logic [CTRLEN-1:0]  rd_res_ctr;
  logic rd_inst_st, rd_fips;

  logic wr_req, wr_req_rdy;
  logic [STATEID-1:0] wr_inst_id;
  logic wr_fips;
  logic [2:0] wr_ccmd;
  logic [KEYLEN-1:0] wr_key;
  logic [BLKLEN-1:0] wr_v;
  logic [CTRLEN-1:0] wr_res_ctr;
  csrng_cmd_sts_e wr_sts;

  logic is_dump_en, reg_rd_sel, reg_rd_id_pulse;
  logic [STATEID-1:0] reg_rd_id;
  logic [31:0] reg_rd_val;
  logic sts_ack;
  csrng_cmd_sts_e sts_sts;
  logic [STATEID-1:0] sts_id;
  logic [NAPPS-1:0] int_state_read_enable;
  logic [NAPPS-1:0][31:0] reseed_counter;

  int unsigned checks, fails;
  int unsigned cov_own_bit_grants;
  int unsigned cov_denied_app_readable_via_app0;
  int unsigned cov_authorized_app_denied_by_app0;
  int unsigned witness_hits;

  // Per-application marker values, so any word read back identifies its source.
  function automatic logic [31:0] key_word_of(input int unsigned app);
    key_word_of = 32'h6BE0_0000 + app;
  endfunction
  function automatic logic [CTRLEN-1:0] ctr_of(input int unsigned app);
    ctr_of = 32'hC0DE_0000 + app;
  endfunction
  function automatic logic [KEYLEN-1:0] key_of(input int unsigned app);
    key_of = {8{key_word_of(app)}};
  endfunction

  csrng_state_db #(
    .NApps  (NAPPS),
    .StateId(STATEID),
    .BlkLen (BLKLEN),
    .KeyLen (KEYLEN),
    .CtrLen (CTRLEN)
  ) dut (
    .clk_i (clk),
    .rst_ni(rst_ni),
    .state_db_enable_i     (state_db_enable),
    .state_db_rd_inst_id_i (rd_inst_id),
    .state_db_rd_key_o     (rd_key),
    .state_db_rd_v_o       (rd_v),
    .state_db_rd_res_ctr_o (rd_res_ctr),
    .state_db_rd_inst_st_o (rd_inst_st),
    .state_db_rd_fips_o    (rd_fips),
    .state_db_wr_req_i     (wr_req),
    .state_db_wr_req_rdy_o (wr_req_rdy),
    .state_db_wr_inst_id_i (wr_inst_id),
    .state_db_wr_fips_i    (wr_fips),
    .state_db_wr_ccmd_i    (wr_ccmd),
    .state_db_wr_key_i     (wr_key),
    .state_db_wr_v_i       (wr_v),
    .state_db_wr_res_ctr_i (wr_res_ctr),
    .state_db_wr_sts_i     (wr_sts),
    .state_db_is_dump_en_i (is_dump_en),
    .state_db_reg_rd_sel_i (reg_rd_sel),
    .state_db_reg_rd_id_pulse_i(reg_rd_id_pulse),
    .state_db_reg_rd_id_i  (reg_rd_id),
    .state_db_reg_rd_val_o (reg_rd_val),
    .state_db_sts_ack_o    (sts_ack),
    .state_db_sts_sts_o    (sts_sts),
    .state_db_sts_id_o     (sts_id),
    .int_state_read_enable_i(int_state_read_enable),
    .reseed_counter_o      (reseed_counter)
  );

  initial clk = 1'b0;
  always #CLK_HALF clk = ~clk;

  task automatic step(input int unsigned n);
    for (int unsigned i = 0; i < n; i++) @(posedge clk);
  endtask

  // Load one application's internal state through the write interface.
  task automatic load_state(input int unsigned app);
    @(negedge clk);
    wr_req     = 1'b1;
    wr_inst_id = app[STATEID-1:0];
    wr_fips    = 1'b1;
    wr_ccmd    = INS;
    wr_key     = key_of(app);
    wr_v       = {4{32'h5A5A_0000 | app}};
    wr_res_ctr = ctr_of(app);
    wr_sts     = CMD_STS_SUCCESS;
    @(negedge clk);
    wr_req = 1'b0;
    step(2);
  endtask

  // Read one 32-bit word of the selected application's state through the register
  // interface: pulse the id to latch the dump target and rewind the pointer, then
  // advance the pointer to the requested word.
  task automatic reg_read_word(input int unsigned app,
                               input int unsigned word,
                               output logic [31:0] val);
    @(negedge clk);
    reg_rd_id       = app[STATEID-1:0];
    reg_rd_id_pulse = 1'b1;
    @(negedge clk);
    reg_rd_id_pulse = 1'b0;
    step(2);
    for (int unsigned i = 0; i < word; i++) begin
      @(negedge clk); reg_rd_sel = 1'b1;
      @(negedge clk); reg_rd_sel = 1'b0;
      step(1);
    end
    step(1);
    val = reg_rd_val;
  endtask

  task automatic record(input string name, input bit ok, input string what);
    checks++;
    if (ok) $display("  case=%s PASS %s", name, what);
    else begin
      fails++;
      $display("  TBFAIL case=%s %s", name, what);
    end
  endtask

  logic [31:0] got_ctr, got_key;

  initial begin
    checks = 0; fails = 0;
    cov_own_bit_grants                = 0;
    cov_denied_app_readable_via_app0  = 0;
    cov_authorized_app_denied_by_app0 = 0;
    witness_hits                      = 0;

    state_db_enable = 1'b0;
    rd_inst_id = '0; wr_req = 1'b0; wr_inst_id = '0; wr_fips = 1'b0;
    wr_ccmd = INS; wr_key = '0; wr_v = '0; wr_res_ctr = '0; wr_sts = CMD_STS_SUCCESS;
    is_dump_en = 1'b1; reg_rd_sel = 1'b0; reg_rd_id_pulse = 1'b0; reg_rd_id = '0;
    int_state_read_enable = '0;
    rst_ni = 1'b0;
    step(5);
    rst_ni = 1'b1;
    state_db_enable = 1'b1;
    step(3);

    $display("===== BUG-009 directed witness: per-application int-state read authorization =====");

    // Give every application a distinguishable internal state.
    for (int unsigned a = 0; a < NAPPS; a++) load_state(a);
    $display("      loaded states for %0d applications", NAPPS);

    // ---- control: application 0 authorized, reading application 0. This must work,
    // and it shows the harness can produce a successful key dump at all.
    $display("--- control_app0_authorized_reads_app0 ---");
    int_state_read_enable = 4'b0001;
    reg_read_word(0, PTR_IN_KEY, got_key);
    $display("      app0 key word=%08x (expected %08x)", got_key, key_word_of(0));
    if (got_key == key_word_of(0)) cov_own_bit_grants++;
    record("control_app0_authorized_reads_app0", got_key == key_word_of(0),
           "an application authorized by its own bit must be readable");

    // ---- witness: only application 0 is authorized. Application 1's own bit is
    // clear, so its key must not be readable.
    $display("--- violating_app1_denied_but_readable ---");
    int_state_read_enable = 4'b0001;
    reg_read_word(1, PTR_IN_KEY, got_key);
    $display("      app1 key word=%08x (its own enable bit is 0, expected 00000000)", got_key);
    if (got_key == key_word_of(1)) begin
      cov_denied_app_readable_via_app0++;
      witness_hits++;
      $display("      OBSERVED: BUG_009_WITNESS_OBSERVED application 1 DRBG key word read out while int_state_read_enable=4'b0001 leaves bit 1 clear");
    end
    record("violating_app1_denied_but_readable", got_key === 32'h0,
           "an application whose own enable bit is clear must dump zeros");

    // ---- discriminator: flip only application 0's bit, leaving application 1
    // authorized. If bit 0 is the true gate, the authorized application is refused.
    $display("--- violating_app1_authorized_but_denied ---");
    int_state_read_enable = 4'b0010;
    reg_read_word(1, PTR_IN_KEY, got_key);
    $display("      app1 key word=%08x (its own enable bit is 1, expected %08x)",
             got_key, key_word_of(1));
    if (got_key === 32'h0) begin
      cov_authorized_app_denied_by_app0++;
      witness_hits++;
      $display("      OBSERVED: BUG_009_WITNESS_OBSERVED application 1 refused while int_state_read_enable=4'b0010 sets its own bit, so bit 0 is the effective gate");
    end
    record("violating_app1_authorized_but_denied", got_key == key_word_of(1),
           "an application authorized by its own bit must not be refused");

    // ---- containment: with the whole vector clear, nothing may be readable. This
    // separates a mis-indexed gate from an absent one.
    $display("--- containment_all_bits_clear_denies_all ---");
    int_state_read_enable = 4'b0000;
    begin
      bit all_zero = 1'b1;
      for (int unsigned a = 0; a < NAPPS; a++) begin
        reg_read_word(a, PTR_IN_KEY, got_key);
        $display("      app%0d key word=%08x", a, got_key);
        if (got_key !== 32'h0) all_zero = 1'b0;
      end
      record("containment_all_bits_clear_denies_all", all_zero,
             "with no application authorized, no internal state may be dumped");
    end

    $display("");
    $display("cov_own_bit_grants=%0d",                cov_own_bit_grants);
    $display("cov_denied_app_readable_via_app0=%0d",  cov_denied_app_readable_via_app0);
    $display("cov_authorized_app_denied_by_app0=%0d", cov_authorized_app_denied_by_app0);
    $display("witness_hits=%0d", witness_hits);
    $display("checks=%0d fails=%0d", checks, fails);

    // Expected on the audited RTL: both directions of the mis-index observed, the
    // control and the containment case passing.
    if (checks == 4 && fails == 2 && witness_hits == 2 &&
        cov_own_bit_grants == 1 &&
        cov_denied_app_readable_via_app0 == 1 &&
        cov_authorized_app_denied_by_app0 == 1) begin
      $display("result=PASS");
      $display("PROOF_RESULT: PASS");
    end
    else begin
      // No "result=" marker here; the negative control expects this branch.
      $display("PROOF_RESULT: FAIL");
    end
    $finish;
  end

  initial begin
    #2000000;
    $display("TBFAIL global timeout");
    $display("PROOF_RESULT: FAIL");
    $finish;
  end

endmodule
