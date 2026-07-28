`timescale 1ns/1ps

// Witness for BUG-034: while digest_valid is low, sha512_masked_core drives the
// unmasked compression working state onto the digest port.
//
// The sampling point is the whole argument. The working registers equal the
// SHA-512 initial hash value for the first cycles after init_cmd, so a witness
// that stops at the first non-zero sample captures nothing but a published
// constant and proves no exposure. This testbench therefore samples the digest
// port on every cycle of the operation, records the trace, and asserts three
// separable things: that samples taken during compression differ from the IV,
// that they differ from one another across rounds, and that they differ when
// the same round index is reached with a different message block. Only the
// third rules out the reading that the port carries a message-independent
// constant sequence.
//
// Marker convention: result=PASS is printed only on success. The failure branch
// prints PROOF_RESULT: FAIL alone, with no result= line, so that a log from a
// run that is supposed to fail cannot be mistaken for a real failure verdict.

module sha512_masked_bug_034_tb;
  localparam int CLK_HALF = 5;
  localparam int TIMEOUT  = 20000;
  localparam int MAXSAMP  = 128;
  localparam logic [1:0] MODE_SHA512 = 2'b11;

  // Padded single-block SHA-512 message for the empty string.
  localparam logic [1023:0] BLOCK_EMPTY =
      {64'h8000_0000_0000_0000, 896'h0, 64'h0};
  // A second single-block message: "abc" padded, length 24 bits.
  localparam logic [1023:0] BLOCK_ABC =
      {64'h6162_6380_0000_0000, 896'h0, 64'd24};

  // SHA-512 initial hash value, as published. Held as a literal here so the
  // comparison does not depend on reading the design's own constant table.
  localparam logic [511:0] SHA512_IV =
      {64'h6a09e667f3bcc908, 64'hbb67ae8584caa73b,
       64'h3c6ef372fe94f82b, 64'ha54ff53a5f1d36f1,
       64'h510e527fade682d1, 64'h9b05688c2b3e6c1f,
       64'h1f83d9abfb41bd6b, 64'h5be0cd19137e2179};

  // Published test vectors, used only as controls that the engine computed a
  // correct hash and that the leak claim is not an artefact of a broken DUT.
  localparam logic [511:0] VECTOR_EMPTY =
      512'hcf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e;

  logic clk, reset_n, zeroize, init_cmd, next_cmd;
  logic [1:0]    mode;
  logic [191:0]  entropy;
  logic [1023:0] block_msg;
  logic          ready, digest_valid;
  logic [511:0]  digest;

  int checks, fails, witness_hits;
  int n_a, n_b;
  logic [511:0] samp_a [0:MAXSAMP-1];
  logic [511:0] samp_b [0:MAXSAMP-1];
  logic [511:0] final_a;

  logic cov_engine_ran, cov_kat_ok, cov_iv_phase_seen;

  sha512_masked_core dut (
    .clk(clk), .reset_n(reset_n), .zeroize(zeroize),
    .init_cmd(init_cmd), .next_cmd(next_cmd), .mode(mode),
    .entropy(entropy), .block_msg(block_msg),
    .ready(ready), .digest(digest), .digest_valid(digest_valid)
  );

  always #CLK_HALF clk = ~clk;

  task automatic check(input string name, input bit cond, input string detail);
    begin
      checks++;
      if (cond) $display("CHECK_PASS %s %s", name, detail);
      else begin
        fails++;
        $display("CHECK_FAIL %s %s", name, detail);
      end
    end
  endtask

  task automatic witness(input string name, input bit cond, input string detail);
    begin
      checks++;
      if (cond) begin
        fails++;
        witness_hits++;
        $display("WITNESS %s %s", name, detail);
        $display("CHECK_FAIL %s %s", name, detail);
      end else begin
        $display("CHECK_PASS %s %s", name, detail);
      end
    end
  endtask

  // Run one operation from its own reset, capturing the digest port on every
  // cycle while the result is not yet valid.
  task automatic run_op(input logic [1023:0] blk,
                        output int n,
                        output logic [511:0] final_digest,
                        output bit ok);
    int c;
    begin
      n = 0;
      final_digest = '0;
      ok = 1'b0;

      reset_n = 1'b0;
      block_msg = blk;
      repeat (4) @(negedge clk);
      reset_n = 1'b1;
      repeat (2) @(negedge clk);

      for (c = 0; c < TIMEOUT && !ready; c++) @(posedge clk);

      @(negedge clk); init_cmd = 1'b1;
      @(negedge clk); init_cmd = 1'b0;

      for (c = 0; c < TIMEOUT; c++) begin
        @(posedge clk);
        #1;
        if (digest_valid) begin
          final_digest = digest;
          ok = 1'b1;
          break;
        end
        if (!ready && n < MAXSAMP) begin
          if (n < MAXSAMP) begin
            if (blk === BLOCK_EMPTY) samp_a[n] = digest;
            else                     samp_b[n] = digest;
            n++;
          end
        end
      end
    end
  endtask

  // Count samples that are neither the published IV nor a constant
  // placeholder. Excluding zero matters: a remediation that drives a constant
  // on invalid cycles also produces samples that are "not the IV", so a
  // predicate testing only against the IV would keep holding after the fix.
  function automatic int count_non_iv(input bit use_a, input int n);
    int i, k;
    begin
      k = 0;
      for (i = 0; i < n; i++) begin
        if (use_a) begin
          if (samp_a[i] !== SHA512_IV && samp_a[i] !== 512'h0) k++;
        end else begin
          if (samp_b[i] !== SHA512_IV && samp_b[i] !== 512'h0) k++;
        end
      end
      count_non_iv = k;
    end
  endfunction

  // Does the published IV appear anywhere in the captured trace? This is the
  // sample a witness that stops at the first non-zero value would land on.
  function automatic int count_iv_hits(input int n);
    int i, k;
    begin
      k = 0;
      for (i = 0; i < n; i++) if (samp_a[i] === SHA512_IV) k++;
      count_iv_hits = k;
    end
  endfunction

  // Count distinct adjacent transitions in the sample trace.
  function automatic int count_changes(input bit use_a, input int n);
    int i, k;
    begin
      k = 0;
      for (i = 1; i < n; i++) begin
        if (use_a) begin if (samp_a[i] !== samp_a[i-1]) k++; end
        else       begin if (samp_b[i] !== samp_b[i-1]) k++; end
      end
      count_changes = k;
    end
  endfunction

  // Count positions where the two message traces disagree.
  function automatic int count_msg_divergence(input int n);
    int i, k;
    begin
      k = 0;
      for (i = 0; i < n; i++) if (samp_a[i] !== samp_b[i]) k++;
      count_msg_divergence = k;
    end
  endfunction

  initial begin
    clk = 1'b0; reset_n = 1'b0; zeroize = 1'b0;
    init_cmd = 1'b0; next_cmd = 1'b0;
    mode = MODE_SHA512;
    entropy = 192'h0123_4567_89AB_CDEF_FEDC_BA98_7654_3210_A5A5_A5A5_5A5A_5A5A;
    block_msg = BLOCK_EMPTY;
    checks = 0; fails = 0; witness_hits = 0;
    n_a = 0; n_b = 0;
    cov_engine_ran = 1'b0; cov_kat_ok = 1'b0; cov_iv_phase_seen = 1'b0;
    $display("PROOF: BUG-034 sha512_masked_core invalid-cycle digest exposure");
    #0;
  end

  int nsamp, nchg, ndiv, min_n, n_iv;
  logic [511:0] final_b;
  bit ok_a, ok_b;

  initial begin
    #1;

    // ---- configuration A: the empty-string block -------------------------
    run_op(BLOCK_EMPTY, n_a, final_a, ok_a);
    if (ok_a) cov_engine_ran = 1'b1;

    check("control_engine_reaches_a_valid_digest", ok_a,
          $sformatf("digest_valid=%0b samples=%0d", ok_a, n_a));
    check("control_digest_matches_published_vector", final_a === VECTOR_EMPTY,
          $sformatf("digest[63:0]=0x%016x", final_a[63:0]));
    if (final_a === VECTOR_EMPTY) cov_kat_ok = 1'b1;

    check("control_captured_enough_invalid_cycle_samples", n_a >= 8,
          $sformatf("samples=%0d", n_a));

    // The IV phase is what a naive witness would stop at. Record that it
    // exists, so the bound below is not mistaken for an absence of leakage.
    n_iv = count_iv_hits(n_a);
    cov_iv_phase_seen = (n_iv > 0);
    check("bound_trace_contains_an_iv_phase_a_naive_witness_would_stop_at",
          cov_iv_phase_seen,
          $sformatf("iv_samples=%0d of %0d", n_iv, n_a));

    nsamp = count_non_iv(1'b1, n_a);
    nchg  = count_changes(1'b1, n_a);

    // ---- configuration B: the "abc" block, from its own reset ------------
    run_op(BLOCK_ABC, n_b, final_b, ok_b);
    check("control_second_message_also_completes", ok_b,
          $sformatf("digest_valid=%0b samples=%0d", ok_b, n_b));
    check("control_two_messages_produce_different_digests",
          final_a !== final_b,
          $sformatf("a[63:0]=0x%016x b[63:0]=0x%016x",
                    final_a[63:0], final_b[63:0]));

    min_n = (n_a < n_b) ? n_a : n_b;
    ndiv  = count_msg_divergence(min_n);

    // ---- witness statements ---------------------------------------------
    // Each is expected to hold on the submitted checkout and to stop holding
    // once the invalid-cycle output is replaced by a constant or by the
    // retained final digest.
    witness("witness_invalid_cycles_expose_live_working_state",
            nsamp > 0,
            $sformatf("samples_that_are_neither_iv_nor_constant=%0d of %0d",
                      nsamp, n_a));
    witness("witness_exposed_value_advances_across_compression_rounds",
            nchg >= 4,
            $sformatf("adjacent_changes=%0d", nchg));
    witness("witness_exposed_value_depends_on_the_message_block",
            ndiv > 0,
            $sformatf("diverging_positions=%0d of %0d compared", ndiv, min_n));

    // ---- containment ----------------------------------------------------
    check("containment_final_digest_unaffected_by_sampling",
          final_a === VECTOR_EMPTY,
          "published test vector still matches after the full sample sweep");

    $display("SUMMARY checks=%0d fails=%0d witness_hits=%0d", checks, fails,
             witness_hits);
    $display("TRACE n_a=%0d iv=%0d non_iv=%0d changes=%0d msg_divergence=%0d",
             n_a, n_iv, nsamp, nchg, ndiv);

    if (checks == 10 && fails == 3 && witness_hits == 3 &&
        cov_engine_ran === 1'b1 && cov_kat_ok === 1'b1 &&
        cov_iv_phase_seen === 1'b1) begin
      $display("result=PASS");
      $display("PROOF_RESULT: PASS");
    end else begin
      $display("PROOF_RESULT: FAIL");
    end
    $finish;
  end

  initial begin
    #(TIMEOUT * 40);
    $display("TBFAIL global timeout");
    $display("PROOF_RESULT: FAIL");
    $finish;
  end

endmodule
