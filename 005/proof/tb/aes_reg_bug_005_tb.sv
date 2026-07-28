// BUG-005 unit-level TB for aes_reg_top over TL-UL.
//
// Claim under test: the AES DATA_IN registers are declared write-only
// (aes.rdl:68 "sw = w", and the generated subreg carries SwAccessWO), so a
// software read must not return their contents. This same file already does
// that correctly for TRIGGER, its other SwAccessWO register, whose read arm
// (aes_reg_top.sv:1826-1831) returns a constant zero. This TB shows the
// audited register block returns the software-written plaintext for all four
// DATA_IN words instead.
//
// Self-checking: any claim that does not hold prints [BUG-005-TBFAIL] and the
// driver script treats that as a hard failure. Cover counters guard against a
// vacuous pass in which the read path was never actually exercised.
`default_nettype none

module aes_reg_bug_005_tb;
  import caliptra_tlul_pkg::*;
  import aes_reg_pkg::*;

  logic clk, rst_n, rst_shadowed_n;

  tl_h2d_t tl_i;
  tl_d2h_t tl_o;

  aes_reg2hw_t reg2hw;
  aes_hw2reg_t hw2reg;

  logic input_ready, output_valid;
  logic shadowed_storage_err, shadowed_update_err, intg_err;

  int errors = 0;
  int checks = 0;

  // ---- cover counters (anti-vacuity) ----
  int cov_data_in_leak    = 0;   // a DATA_IN word read back its plaintext
  int cov_key_share_read  = 0;   // control observation, see below

  aes_reg_top dut (
    .clk_i(clk), .rst_ni(rst_n), .rst_shadowed_ni(rst_shadowed_n),
    .tl_i(tl_i), .tl_o(tl_o),
    .reg2hw(reg2hw), .hw2reg(hw2reg),
    .input_ready_o(input_ready), .output_valid_o(output_valid),
    .shadowed_storage_err_o(shadowed_storage_err),
    .shadowed_update_err_o(shadowed_update_err),
    .intg_err_o(intg_err)
  );

  initial clk = 0;
  always #5 clk = ~clk;

  // Data-integrity helper. caliptra_tlul_cmd_intg_chk validates BOTH the command
  // ECC and the write-data ECC, so a request with correct cmd_intg but zero
  // data_intg is rejected and reads return DataWhenError (all ones). The encoder
  // is a module, not a function, so instantiate it and drive it combinationally.
  logic [31:0]                 di_data;
  logic [38:0]                 di_enc;
  caliptra_prim_secded_inv_39_32_enc u_data_intg_gen (
    .data_i (di_data),
    .data_o (di_enc)
  );
  wire [6:0] di_intg = di_enc[38:32];

  function automatic void chk(input string what, input logic cond);
    checks++;
    if (!cond) begin
      errors++;
      $display("[BUG-005-TBFAIL] %s", what);
    end else begin
      $display("  ok: %s", what);
    end
  endfunction

  task automatic tl_req(input logic [7:0] addr, input logic write,
                        input logic [31:0] wdata);
    tl_h2d_t req;
    req = '0;
    req.a_valid   = 1'b1;
    req.a_opcode  = write ? PutFullData : Get;
    req.a_param   = '0;
    req.a_size    = 2'h2;          // 4 bytes
    req.a_source  = '0;
    req.a_address = {24'h0, addr};
    req.a_mask    = write ? 4'hF : 4'h0;
    req.a_data    = wdata;
    req.a_user    = '0;
    req.a_user.instr_type = caliptra_prim_mubi_pkg::MuBi4False;

    di_data = wdata;
    #0;
    req.a_user.data_intg = di_intg;
    req.a_user.cmd_intg  = get_cmd_intg(req);
    req.d_ready = 1'b1;
    tl_i = req;
  endtask

  // TL-UL host. Drive on the negedge and sample handshake signals on the
  // negedge too: a_ready = ~(outstanding_q | ...) and outstanding_q is set by
  // the same posedge, so sampling after that edge makes a *successful*
  // handshake read back as not-ready.
  task automatic tl_xact(input logic [7:0] addr, input logic write,
                         input logic [31:0] wdata, output logic [31:0] rdata);
    int guard;

    @(negedge clk);
    tl_req(addr, write, wdata);

    guard = 0;
    #1;
    while (!tl_o.a_ready && guard < 1000) begin
      @(negedge clk); #1; guard++;
    end
    if (guard >= 1000) begin
      errors++;
      $display("[BUG-005-TBFAIL] timeout waiting for a_ready @ addr 0x%02h", addr);
      return;
    end
    @(posedge clk);          // request accepted here

    @(negedge clk);
    tl_i.a_valid = 1'b0;
    tl_i.d_ready = 1'b1;

    guard = 0;
    #1;
    while (!tl_o.d_valid && guard < 1000) begin
      @(negedge clk); #1; guard++;
    end
    if (guard >= 1000) begin
      errors++;
      $display("[BUG-005-TBFAIL] timeout waiting for d_valid @ addr 0x%02h", addr);
      return;
    end
    rdata = tl_o.d_data;
    @(posedge clk);          // response consumed
    @(negedge clk);
  endtask

  task automatic tl_write(input logic [7:0] addr, input logic [31:0] wdata);
    logic [31:0] dummy;
    tl_xact(addr, 1'b1, wdata, dummy);
  endtask

  task automatic tl_read(input logic [7:0] addr, output logic [31:0] rdata);
    tl_xact(addr, 1'b0, 32'h0, rdata);
  endtask

  // A recognisable 128-bit plaintext block. Distinct per word so a leak cannot
  // be confused with a stuck bus, and not all-ones so it cannot be confused
  // with the TL-UL DataWhenError pattern.
  localparam logic [31:0] PT [4] = '{32'h4f_50_45_4e,   // "OPEN"
                                     32'h53_45_43_52,   // "SECR"
                                     32'h45_54_5f_50,   // "ET_P"
                                     32'h4c_41_49_4e};  // "LAIN"

  logic [7:0] din_addr [4];
  logic [31:0] rd;
  logic [31:0] rd_after_op;
  int i;

  initial begin
    din_addr[0] = AES_DATA_IN_0_OFFSET;
    din_addr[1] = AES_DATA_IN_1_OFFSET;
    din_addr[2] = AES_DATA_IN_2_OFFSET;
    din_addr[3] = AES_DATA_IN_3_OFFSET;

    tl_i = '0;
    tl_i.d_ready = 1'b1;
    rst_n = 1'b0; rst_shadowed_n = 1'b0;
    hw2reg = '0;
    repeat (5) @(posedge clk);
    rst_n = 1'b1; rst_shadowed_n = 1'b1;
    repeat (5) @(posedge clk);

    $display("===== BUG-005: write-only AES DATA_IN registers read back plaintext =====");
    $display("  aes.rdl:68 declares DATA_IN as 'sw = w' and the subreg is");
    $display("  instantiated SwAccessWO, so every read below must return 0x00000000.");

    // ---- Part 1: each of the four input words leaks independently ----
    for (i = 0; i < 4; i++) begin
      tl_write(din_addr[i], PT[i]);
      tl_read (din_addr[i], rd);
      $display("  DATA_IN[%0d] @0x%02h: wrote 0x%08h, read 0x%08h (spec: 0x00000000)",
               i, din_addr[i], PT[i], rd);
      if (rd === PT[i]) cov_data_in_leak++;
      chk($sformatf("DATA_IN[%0d] returns the written plaintext on a read", i),
          rd === PT[i]);
      chk($sformatf("DATA_IN[%0d] read is not the TL-UL error pattern", i),
          rd !== 32'hffff_ffff);
    end

    // ---- Part 2: the whole 128-bit block is recoverable in one pass ----
    // Re-read all four words without rewriting them: the leak is stateful, not
    // an artefact of the immediately preceding write.
    begin
      logic [127:0] recovered;
      recovered = '0;
      for (i = 0; i < 4; i++) begin
        tl_read(din_addr[i], rd);
        recovered = {recovered[95:0], rd};
      end
      $display("  recovered 128-bit block = 0x%032h", recovered);
      chk("the full 128-bit input block is recoverable by four MMIO reads",
          recovered === {PT[0], PT[1], PT[2], PT[3]});
    end

    // ---- Part 3: the leak survives the register block's own read-clear ----
    // DATA_IN is declared 'onwrite = woclr' but that qualifier concerns writes.
    // Nothing in the read path clears the register, so a second read returns the
    // same plaintext. This matters for the impact claim: the window is not
    // single-shot, so an attacker does not have to win a race to read it twice.
    tl_read(din_addr[0], rd);
    tl_read(din_addr[0], rd_after_op);
    $display("  DATA_IN[0] read twice: 0x%08h then 0x%08h", rd, rd_after_op);
    chk("reading DATA_IN does not clear it (leak is repeatable)",
        (rd === PT[0]) && (rd_after_op === PT[0]));

    // ---- Control observation: reads that the spec DOES permit still work ----
    // Confirms the harness is not simply returning whatever it last wrote:
    // CTRL_AUX_REGWEN is a genuinely readable register and returns its reset
    // value of 1, so the read path is functioning normally overall.
    tl_read(AES_CTRL_AUX_REGWEN_OFFSET, rd);
    $display("  control: CTRL_AUX_REGWEN reads 0x%08h (expect 0x1, a legal read)", rd);
    if (rd[0] === 1'b1) cov_key_share_read++;
    chk("control: a legitimately readable register still reads correctly",
        rd[0] === 1'b1);

    $display("===== summary =====");
    $display("  checks=%0d errors=%0d", checks, errors);
    $display("  cover_data_in_leak=%0d (expect 4)", cov_data_in_leak);
    $display("  cover_legal_read=%0d (expect 1)", cov_key_share_read);
    if (cov_data_in_leak != 4)
      $display("[BUG-005-TBFAIL] vacuous: not all four DATA_IN words were observed leaking");
    if (cov_key_share_read != 1)
      $display("[BUG-005-TBFAIL] vacuous: control read never succeeded, harness suspect");
    if (errors == 0) $display("PROOF_RESULT: PASS");
    else             $display("PROOF_RESULT: FAIL");
    $finish;
  end

  initial begin
    #200000;
    $display("[BUG-005-TBFAIL] timeout");
    $finish;
  end
endmodule
`default_nettype wire
