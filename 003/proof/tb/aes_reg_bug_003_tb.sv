// BUG-003 / BUG-005 unit-level TB for aes_reg_top over TL-UL.
//
// BUG-003: after software clears CTRL_AUX_REGWEN (W0C), writes to
//          CTRL_AUX_SHADOWED must be rejected. This TB shows the shadow
//          register still commits a new value, i.e. the lock does nothing.
// BUG-005: DATA_IN registers must read back as zero. This TB shows they
//          return the software-written plaintext.
//
// Deliberately self-checking: any claim that does not hold prints [BUG-xxx-TBFAIL]
// and the driver script treats that as a hard failure.
`default_nettype none

module aes_reg_bug_003_tb;
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

  // ---- cover counters (anti-vacuity: proof must actually exercise the path) ----
  int cov_aux_committed_while_locked = 0;
  int cov_data_in_readback           = 0;

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
  // ECC and the write-data ECC, so a request with a correct cmd_intg but a zero
  // data_intg is still rejected (reg_error -> DataWhenError = all ones on reads).
  // The encoder is a module, not a function, so it is instantiated here and
  // driven combinationally from whatever the current request carries.
  logic [31:0]                 di_data;
  logic [38:0]                 di_enc;
  caliptra_prim_secded_inv_39_32_enc u_data_intg_gen (
    .data_i (di_data),
    .data_o (di_enc)
  );
  // Upper 7 bits are the integrity nibble that belongs in a_user.data_intg.
  wire [6:0] di_intg = di_enc[38:32];

  function automatic void chk(input string what, input logic cond);
    checks++;
    if (!cond) begin
      errors++;
      $display("[BUG-003-TBFAIL] %s", what);
    end else begin
      $display("  ok: %s", what);
    end
  endfunction

  // Build a legal TL-UL A-channel request with correct command integrity.
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

    // Data ECC first: drive the helper and let it settle, then capture.
    di_data = wdata;
    #0;
    req.a_user.data_intg = di_intg;

    // Command ECC is computed over addr/opcode/mask/instr_type, all set above.
    req.a_user.cmd_intg   = get_cmd_intg(req);
    req.d_ready   = 1'b1;
    tl_i = req;
  endtask

  // TL-UL host. Timing discipline: drive on the negedge, and sample handshake
  // signals on the negedge too (after a delta). That is the combinational value
  // the DUT will latch on the coming posedge. Sampling *after* the posedge is
  // wrong here: a_ready = ~(outstanding_q | ...) and outstanding_q is set by
  // that same edge, so a successful handshake makes a_ready read back low.
  task automatic tl_xact(input logic [7:0] addr, input logic write,
                         input logic [31:0] wdata, output logic [31:0] rdata);
    int guard;

    @(negedge clk);
    tl_req(addr, write, wdata);

    // Wait until the cycle in which the request will be accepted.
    guard = 0;
    #1;
    while (!tl_o.a_ready && guard < 1000) begin
      @(negedge clk); #1; guard++;
    end
    if (guard >= 1000) begin
      errors++;
      $display("[BUG-003-TBFAIL] timeout waiting for a_ready @ addr 0x%02h", addr);
      return;
    end
    @(posedge clk);          // request is accepted here

    @(negedge clk);
    tl_i.a_valid = 1'b0;
    tl_i.d_ready = 1'b1;

    // Response: d_valid is outstanding_q, already high after the accepting edge.
    guard = 0;
    #1;
    while (!tl_o.d_valid && guard < 1000) begin
      @(negedge clk); #1; guard++;
    end
    if (guard >= 1000) begin
      errors++;
      $display("[BUG-003-TBFAIL] timeout waiting for d_valid @ addr 0x%02h", addr);
      return;
    end
    rdata = tl_o.d_data;
    @(posedge clk);          // response is consumed here (d_ack)
    @(negedge clk);
  endtask

  task automatic tl_write(input logic [7:0] addr, input logic [31:0] wdata);
    logic [31:0] dummy;
    tl_xact(addr, 1'b1, wdata, dummy);
  endtask

  task automatic tl_read(input logic [7:0] addr, output logic [31:0] rdata);
    tl_xact(addr, 1'b0, 32'h0, rdata);
  endtask

  localparam logic [7:0] AUX_ADDR    = AES_CTRL_AUX_SHADOWED_OFFSET;
  localparam logic [7:0] REGWEN_ADDR = AES_CTRL_AUX_REGWEN_OFFSET;
  localparam logic [7:0] DIN0_ADDR   = AES_DATA_IN_0_OFFSET;
  localparam logic [7:0] DIN3_ADDR   = AES_DATA_IN_3_OFFSET;

  logic [31:0] rd;
  logic        aux_before, aux_after;
  logic [31:0] regwen_rd;

  initial begin
    tl_i = '0;
    tl_i.d_ready = 1'b1;   // host is always ready to accept the response
    rst_n = 1'b0; rst_shadowed_n = 1'b0;
    hw2reg = '0;
    repeat (5) @(posedge clk);
    rst_n = 1'b1; rst_shadowed_n = 1'b1;
    repeat (5) @(posedge clk);

    $display("===== BUG-003: CTRL_AUX_REGWEN does not gate CTRL_AUX_SHADOWED =====");
    // Target field is bit 0, KEY_TOUCH_FORCES_RESEED. It resets to 1 (the secure
    // default: loading a new key reseeds the masking/clearing PRNGs) and is the
    // field with a live effect in this build. Bit 1, FORCE_MASKS, is inert here
    // because aes_clp_wrapper instantiates aes with SecAllowForcingMasks = 0,
    // so this proof deliberately does not rest on it.

    // Baseline: lock is open after reset (RESVAL=1).
    tl_read(REGWEN_ADDR, regwen_rd);
    $display("  REGWEN after reset      = 0x%0h (expect 0x1 = unlocked)", regwen_rd);
    chk("REGWEN reads 1 after reset", regwen_rd[0] === 1'b1);

    // Secure default is already in place; confirm it before touching anything.
    aux_before = reg2hw.ctrl_aux_shadowed.key_touch_forces_reseed.q;
    $display("  AUX.key_touch_forces_reseed after reset = %0b (expect 1)", aux_before);
    chk("KEY_TOUCH_FORCES_RESEED resets to 1 (secure default)", aux_before === 1'b1);

    // Software locks the AUX configuration. W0C: writing 0 clears REGWEN to 0
    // and there is no way to set it back short of a reset.
    tl_write(REGWEN_ADDR, 32'h0000_0000);
    tl_read(REGWEN_ADDR, regwen_rd);
    $display("  REGWEN after lock      = 0x%0h (expect 0x0 = locked)", regwen_rd);
    chk("REGWEN reads 0 after software lock", regwen_rd[0] === 1'b0);

    // THE ATTACK: two shadow writes clearing bit 0 while the lock is engaged.
    // A correct implementation rejects both, leaving the field at 1.
    tl_write(AUX_ADDR, 32'h0000_0000);
    tl_write(AUX_ADDR, 32'h0000_0000);
    aux_after = reg2hw.ctrl_aux_shadowed.key_touch_forces_reseed.q;
    $display("  AUX.key_touch_forces_reseed after LOCKED write of 0 = %0b", aux_after);

    // If the lock were honoured, aux_after would stay 1 (the write is rejected).
    // On the audited RTL it becomes 0: the config changed despite the lock.
    if (aux_after !== aux_before) begin
      cov_aux_committed_while_locked++;
      $display("  >> BUG-003 OBSERVED: AUX changed %0b -> %0b with REGWEN=0",
               aux_before, aux_after);
    end
    chk("AUX value changed while locked (lock is ineffective)",
        aux_after !== aux_before);
    chk("no shadow update error was raised for the locked write",
        shadowed_update_err === 1'b0);

    $display("===== BUG-005: DATA_IN registers read back plaintext =====");
    tl_write(DIN0_ADDR, 32'h1111_1111);
    tl_read (DIN0_ADDR, rd);
    $display("  DATA_IN[0] wrote 0x11111111, read 0x%08h (must be 0x0)", rd);
    if (rd == 32'h1111_1111) cov_data_in_readback++;
    chk("DATA_IN[0] leaks the written value", rd === 32'h1111_1111);

    tl_write(DIN3_ADDR, 32'h4444_4444);
    tl_read (DIN3_ADDR, rd);
    $display("  DATA_IN[3] wrote 0x44444444, read 0x%08h (must be 0x0)", rd);
    if (rd == 32'h4444_4444) cov_data_in_readback++;
    chk("DATA_IN[3] leaks the written value", rd === 32'h4444_4444);

    $display("===== summary =====");
    $display("  checks=%0d errors=%0d", checks, errors);
    $display("  cover_aux_committed_while_locked=%0d", cov_aux_committed_while_locked);
    $display("  cover_data_in_readback=%0d", cov_data_in_readback);
    if (cov_aux_committed_while_locked == 0)
      $display("[BUG-003-TBFAIL] vacuous: attack path never exercised");
    if (cov_data_in_readback != 2)
      $display("[BUG-003-TBFAIL] vacuous: data_in readback not observed twice");
    if (errors == 0) $display("PROOF_RESULT: PASS");
    else             $display("PROOF_RESULT: FAIL");
    $finish;
  end

  initial begin
    #200000;
    $display("[BUG-003-TBFAIL] timeout");
    $finish;
  end
endmodule
`default_nettype wire
