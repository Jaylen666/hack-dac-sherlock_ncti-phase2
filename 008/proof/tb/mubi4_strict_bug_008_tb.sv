// BUG-008 witness testbench: mubi4_test_true_strict accepts a 1-bit error.
//
// The testbench exhausts all 16 MuBi4 encodings against the audited package's
// own functions and shows three self-contradictions the package cannot both
// hold:
//   1. mubi4_test_true_strict accepts an encoding that is not MuBi4True.
//   2. That same encoding is classified invalid by mubi4_test_invalid in the
//      same package, so one function grants permission while the other reports
//      a fault.
//   3. The three other widths in the same package reject the corresponding
//      1-bit error, so the strict contract is enforced everywhere except MuBi4.
//
// Nothing outside the audited tree is consulted: the expected behaviour is taken
// from the package's own other widths, not from any external list.
`timescale 1ns/1ps

module mubi4_strict_bug_008_tb;

  import caliptra_prim_mubi_pkg::*;

  int checks  = 0;
  int errors  = 0;
  int cover_strict_accepts_nontrue = 0;
  int cover_accepted_is_invalid    = 0;
  int cover_wider_widths_reject    = 0;

  task automatic chk(string what, bit ok);
    checks++;
    if (ok) begin
      $display("  ok: %s", what);
    end else begin
      errors++;
      $display("TBFAIL: %s", what);
    end
  endtask

  // How many of the 16 MuBi4 encodings does the strict test accept?
  function automatic int count_strict_true_accepts();
    int n = 0;
    for (int v = 0; v < 16; v++)
      if (mubi4_test_true_strict(mubi4_t'(v))) n++;
    return n;
  endfunction

  initial begin
    automatic int    n_accept;
    automatic mubi4_t one_bit_err;

    $display("===== BUG-008 witness: strict MuBi4 true test accepts a 1-bit error =====");
    $display("MuBi4True=0x%01h MuBi4False=0x%01h", MuBi4True, MuBi4False);

    // ---- 1. the strict test must accept exactly one encoding ----------------
    n_accept = count_strict_true_accepts();
    $display("  OBSERVED: mubi4_test_true_strict accepts %0d of 16 encodings", n_accept);
    if (n_accept > 1) cover_strict_accepts_nontrue++;
    chk("BUG-008 OBSERVED: the strict test accepts more than the single True encoding",
        n_accept > 1);
    chk("BUG-008 OBSERVED: it accepts exactly 2, so precisely one bit of slack was introduced",
        n_accept == 2);

    // Control: it does still accept the legitimate True encoding, so the
    // function is over-permissive rather than simply broken.
    chk("CONTROL: mubi4_test_true_strict(MuBi4True) is true, so the function still works for the real value",
        mubi4_test_true_strict(MuBi4True) === 1'b1);

    // ---- 2. name the extra encoding and show it is a 1-bit error -----------
    one_bit_err = mubi4_t'(MuBi4True ^ 4'h1);
    $display("  OBSERVED: the extra accepted encoding is 0x%01h, Hamming distance %0d from True",
             one_bit_err, $countones(one_bit_err ^ MuBi4True));
    chk("BUG-008 OBSERVED: the extra accepted encoding differs from MuBi4True in exactly one bit",
        $countones(one_bit_err ^ MuBi4True) == 1);
    chk("BUG-008 OBSERVED: a single-bit fault on the True encoding still reads as True",
        mubi4_test_true_strict(one_bit_err) === 1'b1);

    // ---- 3. the same package calls that encoding invalid -------------------
    // The cover measures the contradiction itself, not either half of it: it
    // fires only when one function grants permission for an encoding the other
    // reports as a fault. Fixing the strict test removes the contradiction, so
    // this drops to 0 in the negative control.
    if (mubi4_test_invalid(one_bit_err) && mubi4_test_true_strict(one_bit_err))
      cover_accepted_is_invalid++;
    $display("  OBSERVED: mubi4_test_invalid(0x%01h)=%0b while mubi4_test_true_strict(0x%01h)=%0b",
             one_bit_err, mubi4_test_invalid(one_bit_err),
             one_bit_err, mubi4_test_true_strict(one_bit_err));
    chk("BUG-008 OBSERVED: the package classifies the accepted encoding as invalid, contradicting its own strict test",
        mubi4_test_invalid(one_bit_err) === 1'b1);

    // The loose test is expected to accept it; that is its documented contract,
    // so this is a control confirming the package's loose/strict split is intact
    // everywhere except the strict-true function.
    chk("CONTROL: the loose test accepts it too, which is its documented contract, so only the strict test is wrong",
        mubi4_test_true_loose(one_bit_err) === 1'b1);
    chk("CONTROL: mubi4_test_false_strict rejects it, so the false-side strict contract is intact",
        mubi4_test_false_strict(one_bit_err) === 1'b0);

    // ---- 4. in-package control: the other three widths -------------------
    chk("CONTROL: mubi8_test_true_strict rejects the corresponding 1-bit error",
        mubi8_test_true_strict(mubi8_t'(MuBi8True ^ 8'h01)) === 1'b0);
    chk("CONTROL: mubi12_test_true_strict rejects the corresponding 1-bit error",
        mubi12_test_true_strict(mubi12_t'(MuBi12True ^ 12'h001)) === 1'b0);
    chk("CONTROL: mubi16_test_true_strict rejects the corresponding 1-bit error",
        mubi16_test_true_strict(mubi16_t'(MuBi16True ^ 16'h0001)) === 1'b0);
    if (mubi8_test_true_strict(mubi8_t'(MuBi8True ^ 8'h01))  === 1'b0 &&
        mubi12_test_true_strict(mubi12_t'(MuBi12True ^ 12'h001)) === 1'b0 &&
        mubi16_test_true_strict(mubi16_t'(MuBi16True ^ 16'h0001)) === 1'b0)
      cover_wider_widths_reject++;

    // The wider widths accept exactly one encoding each, which is the count the
    // MuBi4 function should also have produced.
    chk("CONTROL: mubi8_test_true_strict accepts its True encoding, so the comparison is like-for-like",
        mubi8_test_true_strict(MuBi8True) === 1'b1);

    $display("cover_strict_accepts_nontrue=%0d", cover_strict_accepts_nontrue);
    $display("cover_accepted_is_invalid=%0d",    cover_accepted_is_invalid);
    $display("cover_wider_widths_reject=%0d",    cover_wider_widths_reject);
    $display("checks=%0d errors=%0d", checks, errors);
    if (errors == 0) $display("PROOF_RESULT: PASS");
    else             $display("PROOF_RESULT: FAIL");
    $finish;
  end

endmodule
