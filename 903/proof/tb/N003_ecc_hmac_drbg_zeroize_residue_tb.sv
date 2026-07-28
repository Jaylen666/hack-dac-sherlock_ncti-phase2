module N003_ecc_hmac_drbg_zeroize_residue_tb;
  logic clk;
  logic reset_n;
  logic zeroize;
  logic [1:0] hmac_mode;
  logic en;
  logic ready;
  logic [383:0] keygen_seed;
  logic [383:0] keygen_nonce;
  logic [383:0] privKey;
  logic [383:0] hashed_msg;
  logic [383:0] IV;
  logic [383:0] lambda;
  logic [383:0] scalar_rnd;
  logic [383:0] masking_rnd;
  logic [383:0] drbg;

  localparam logic [1:0] SIGN_CMD = 2'b01;

  ecc_hmac_drbg_interface dut (
    .clk(clk),
    .reset_n(reset_n),
    .zeroize(zeroize),
    .hmac_mode(hmac_mode),
    .en(en),
    .ready(ready),
    .keygen_seed(keygen_seed),
    .keygen_nonce(keygen_nonce),
    .privKey(privKey),
    .hashed_msg(hashed_msg),
    .IV(IV),
    .lambda(lambda),
    .scalar_rnd(scalar_rnd),
    .masking_rnd(masking_rnd),
    .drbg(drbg)
  );

  task automatic tick;
    begin
      clk = 1'b0;
      #1;
      clk = 1'b1;
      #1;
      clk = 1'b0;
      #1;
    end
  endtask

  initial begin
    clk = 1'b0;
    reset_n = 1'b0;
    zeroize = 1'b0;
    hmac_mode = SIGN_CMD;
    en = 1'b0;
    keygen_seed = 384'h1111_2222_3333_4444_5555_6666_7777_8888_9999_aaaa_bbbb_cccc;
    keygen_nonce = 384'h2222_3333_4444_5555_6666_7777_8888_9999_aaaa_bbbb_cccc_dddd;
    privKey = 384'h3333_4444_5555_6666_7777_8888_9999_aaaa_bbbb_cccc_dddd_eeee;
    hashed_msg = 384'h4444_5555_6666_7777_8888_9999_aaaa_bbbb_cccc_dddd_eeee_ffff;
    IV = 384'h5a5a_6003_5a5a_6003_5a5a_6003_5a5a_6003_5a5a_6003_5a5a_6003;

    repeat (2) tick();
    reset_n = 1'b1;
    tick();

    if (dut.lfsr_seed_reg !== 384'h0) $fatal(1, "N003_CONTROL_FAIL reset did not clear lfsr_seed_reg");
    if (dut.sca_entropy_reg !== 384'h0) $fatal(1, "N003_CONTROL_FAIL reset did not clear sca_entropy_reg");
    $display("N003_CONTROL_RESET lfsr_seed_zero=%0b sca_entropy_zero=%0b",
             dut.lfsr_seed_reg == 384'h0, dut.sca_entropy_reg == 384'h0);

    en = 1'b1;
    tick();
    en = 1'b0;

    repeat (40) begin
      tick();
      if ((dut.lfsr_seed_reg != 384'h0) &&
          (dut.sca_entropy_reg != 384'h0) &&
          (lambda != 384'h0) &&
          (scalar_rnd != 384'h0) &&
          (masking_rnd != 384'h0) &&
          (drbg != 384'h0)) begin
        break;
      end
    end

    if (dut.lfsr_seed_reg == 384'h0) $fatal(1, "N003_SETUP_FAIL lfsr_seed_reg did not become nonzero");
    if (dut.sca_entropy_reg == 384'h0) $fatal(1, "N003_SETUP_FAIL sca_entropy_reg did not become nonzero");
    if (lambda == 384'h0 || scalar_rnd == 384'h0 || masking_rnd == 384'h0 || drbg == 384'h0) begin
      $fatal(1, "N003_SETUP_FAIL output registers did not become nonzero");
    end

    $display("N003_SETUP_NONZERO lfsr_seed_reg_nonzero=%0b sca_entropy_reg_nonzero=%0b lambda_nonzero=%0b scalar_nonzero=%0b masking_nonzero=%0b drbg_nonzero=%0b",
             dut.lfsr_seed_reg != 384'h0,
             dut.sca_entropy_reg != 384'h0,
             lambda != 384'h0,
             scalar_rnd != 384'h0,
             masking_rnd != 384'h0,
             drbg != 384'h0);

    zeroize = 1'b1;
    tick();
    zeroize = 1'b0;
    #1;

    $display("N003_WITNESS_AFTER_ZEROIZE lfsr_seed_reg_nonzero=%0b sca_entropy_reg_nonzero=%0b lambda_zero=%0b scalar_zero=%0b masking_zero=%0b drbg_zero=%0b",
             dut.lfsr_seed_reg != 384'h0,
             dut.sca_entropy_reg != 384'h0,
             lambda == 384'h0,
             scalar_rnd == 384'h0,
             masking_rnd == 384'h0,
             drbg == 384'h0);

    if (lambda !== 384'h0) $fatal(1, "N003_CONTROL_FAIL lambda did not clear");
    if (scalar_rnd !== 384'h0) $fatal(1, "N003_CONTROL_FAIL scalar_rnd did not clear");
    if (masking_rnd !== 384'h0) $fatal(1, "N003_CONTROL_FAIL masking_rnd did not clear");
    if (drbg !== 384'h0) $fatal(1, "N003_CONTROL_FAIL drbg did not clear");
    if (dut.lfsr_seed_reg === 384'h0) $fatal(1, "N003_WITNESS_NOT_OBSERVED lfsr_seed_reg cleared");
    if (dut.sca_entropy_reg === 384'h0) $fatal(1, "N003_WITNESS_NOT_OBSERVED sca_entropy_reg cleared");

    en = 1'b1;
    #1;
    $display("N003_RESTART_INPUT_RESIDUE ready=%0b hmac_entropy_uses_retained=%0b retained_sca_entropy_nonzero=%0b",
             ready,
             dut.hmac_drbg_entropy == dut.sca_entropy_reg,
             dut.sca_entropy_reg != 384'h0);
    en = 1'b0;

    $display("N003_ZEROIZE_RESIDUE_WITNESS_PASS");
    $finish;
  end
endmodule
