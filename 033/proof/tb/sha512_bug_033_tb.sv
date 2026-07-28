// BUG-033 unit-level TB for the SHA-512 DIGEST hardware-clear strobe.
//
// Claim under test: sha512.sv drives the SHA512_DIGEST hwclr from a second,
// separately formed strobe
//
//   zeroize_reg2 = ~( (~ZEROIZE) & debugUnlock_or_scan_mode_switch )
//
// whereas the reference (and every other consumer in the same file, including
// the GEN_PCR_HASH_DIGEST hwclr on the very next line) uses
//
//   zeroize_reg  = ZEROIZE | debugUnlock_or_scan_mode_switch.
//
// This TB does NOT assume what the rewired expression does. It drives both
// values of debugUnlock_or_scan_mode_switch, seeds the DIGEST registers through
// the software write path (sha512_reg.rdl:130 sets 'default sw = rw', so the
// digest window is software-writable and can be used as a probe), and reports
// what the hardware actually does in each case. The self-checks then assert the
// two security-relevant conclusions.
//
// Any claim that does not hold prints [BUG-033-TBFAIL] and the driver script
// treats that as a hard failure.
`default_nettype none

module sha512_bug_033_tb;
  import sha512_reg_pkg::*;
  import sha512_params_pkg::*;
  import kv_defines_pkg::*;
  import pv_defines_pkg::*;

  localparam int ADDR_W = 32;
  localparam int DATA_W = 64;

  // Register offsets (sha512_reg.rdl / caliptra_reg.h).
  localparam logic [31:0] ADDR_CTRL     = 32'h0000_0010;
  localparam logic [31:0] ADDR_STATUS   = 32'h0000_0018;
  localparam logic [31:0] ADDR_DIGEST_0 = 32'h0000_0100;

  localparam logic [63:0] CTRL_ZEROIZE  = 64'h0000_0010;  // bit 4

  // A recognisable digest-shaped payload. Not all-zero (that is the cleared
  // state we are testing for) and not all-ones (avoids confusion with an error
  // or undriven bus).
  localparam logic [31:0] SEED_W0 = 32'hA5A5_A5A5;
  localparam logic [31:0] SEED_W1 = 32'h5A5A_5A5A;

  logic clk, reset_n, cptra_pwrgood;
  logic cs, we;
  logic [ADDR_W-1:0] address;
  logic [DATA_W-1:0] write_data;
  wire  [DATA_W-1:0] read_data;
  wire               err;

  logic debug_or_scan;

  pv_read_t  pv_read;
  pv_write_t pv_write;
  pv_rd_resp_t pv_rd_resp;
  pv_wr_resp_t pv_wr_resp;
  wire [PCR_HASH_NUM_DWORDS-1:0][DATA_W-1:0] pcr_signing_hash;
  wire error_intr, notif_intr;

  int errors = 0;
  int checks = 0;

  // ---- cover counters (anti-vacuity) ----
  int cov_seed_visible        = 0;  // the probe value was actually observable
  int cov_no_clear_on_debug   = 0;  // digest survived debug/scan assertion
  int cov_clear_when_quiet    = 0;  // digest was cleared with no zeroize request

  sha512 #(.ADDR_WIDTH(ADDR_W), .DATA_WIDTH(DATA_W)) dut (
    .clk(clk), .reset_n(reset_n), .cptra_pwrgood(cptra_pwrgood),
    .cs(cs), .we(we),
    .address(address), .write_data(write_data), .read_data(read_data), .err(err),
    .pv_read(pv_read), .pv_write(pv_write),
    .pv_rd_resp(pv_rd_resp), .pv_wr_resp(pv_wr_resp),
    .pcr_signing_hash(pcr_signing_hash),
    .error_intr(error_intr), .notif_intr(notif_intr),
    .debugUnlock_or_scan_mode_switch(debug_or_scan)
  );

  initial clk = 0;
  always #5 clk = ~clk;

  function automatic void chk(input string what, input logic cond);
    checks++;
    if (!cond) begin
      errors++;
      $display("[BUG-033-TBFAIL] %s", what);
    end else begin
      $display("  ok: %s", what);
    end
  endfunction

  // Single-cycle register-interface write.
  //
  // Although the sha512 wrapper carries a 64-bit write_data/read_data port, the
  // generated register block underneath is a flat 32-bit interface
  // (sha512_reg_pkg.sv:6 SHA512_REG_DATA_WIDTH = 32, and sha512_reg.sv:11/:17
  // declare 32-bit cpuif data ports), and sha512.sv passes write_data straight
  // through. Each DIGEST dword therefore has its own 4-byte offset
  // (sha512_reg.sv:124 decodes 12'h100 + i0*12'h4) and the payload always sits
  // in the low 32 bits. No address[2] half-selection is involved.
  task automatic reg_write(input logic [31:0] addr, input logic [31:0] wdata);
    @(negedge clk);
    cs         = 1'b1;
    we         = 1'b1;
    address    = addr;
    write_data = {32'h0, wdata};
    @(negedge clk);
    cs = 1'b0;
    we = 1'b0;
    write_data = '0;
  endtask

  task automatic reg_read(input logic [31:0] addr, output logic [31:0] rdata);
    @(negedge clk);
    cs      = 1'b1;
    we      = 1'b0;
    address = addr;
    @(negedge clk);
    rdata = read_data[31:0];
    cs = 1'b0;
  endtask

  // Seed the DIGEST window through the software write path and confirm it took.
  task automatic seed_digest(output logic ok);
    logic [31:0] r0, r1;
    reg_write(ADDR_DIGEST_0,        SEED_W0);
    reg_write(ADDR_DIGEST_0 + 32'h4, SEED_W1);
    reg_read (ADDR_DIGEST_0,        r0);
    reg_read (ADDR_DIGEST_0 + 32'h4, r1);
    ok = (r0 === SEED_W0) && (r1 === SEED_W1);
    $display("    seeded DIGEST[0]=0x%08h DIGEST[1]=0x%08h (wrote 0x%08h / 0x%08h)",
             r0, r1, SEED_W0, SEED_W1);
  endtask

  logic [31:0] d0, d1;
  logic        seeded;

  initial begin
    cs = 0; we = 0; address = '0; write_data = '0;
    debug_or_scan = 1'b0;
    pv_rd_resp = '0;
    pv_wr_resp = '0;
    reset_n = 1'b0; cptra_pwrgood = 1'b0;
    repeat (5) @(posedge clk);
    cptra_pwrgood = 1'b1;
    repeat (3) @(posedge clk);
    reset_n = 1'b1;
    repeat (10) @(posedge clk);

    $display("===== BUG-033: SHA-512 DIGEST hwclr driven by a rewired strobe =====");
    $display("  sha512_reg.rdl:83-85 states ZEROIZE exists to 'Zeroize all internal");
    $display("  registers after SHA process, to avoid SCA leakage'.");
    $display("  sha512.sv:300 drives the DIGEST hwclr from zeroize_reg2, while");
    $display("  sha512.sv:305 still drives GEN_PCR_HASH_DIGEST from zeroize_reg.");
    $display("");

    // ---------------------------------------------------------------------
    // Observation A: with no zeroize requested and no debug/scan asserted,
    // can a value survive in the DIGEST window at all?
    // A correct strobe (ZEROIZE | debug_or_scan) is 0 here, so the digest must
    // persist. This case is an observation, not the security claim.
    // ---------------------------------------------------------------------
    $display("--- A: quiescent (ZEROIZE=0, debug_or_scan=0) ---");
    debug_or_scan = 1'b0;
    seed_digest(seeded);
    reg_read(ADDR_DIGEST_0,         d0);
    reg_read(ADDR_DIGEST_0 + 32'h4, d1);
    $display("    after 2 further read cycles: DIGEST[0]=0x%08h DIGEST[1]=0x%08h", d0, d1);

    if (d0 === 32'h0 && d1 === 32'h0) begin
      cov_clear_when_quiet++;
      $display("    >> OBSERVED: the DIGEST window is held cleared even though no");
      $display("       zeroize was requested and debug/scan is deasserted.");
    end

    // ---------------------------------------------------------------------
    // Observation B: assert debug-unlock / scan-mode entry. This is the case
    // the strobe exists to cover: entering debug or scan must wipe the digest
    // so that a hash result cannot be lifted out through the debug path.
    // ---------------------------------------------------------------------
    $display("--- B: debug-unlock / scan-mode asserted (ZEROIZE=0, debug_or_scan=1) ---");
    debug_or_scan = 1'b1;
    repeat (4) @(posedge clk);
    seed_digest(seeded);
    if (seeded) cov_seed_visible++;
    repeat (4) @(posedge clk);
    reg_read(ADDR_DIGEST_0,         d0);
    reg_read(ADDR_DIGEST_0 + 32'h4, d1);
    $display("    with debug_or_scan held high: DIGEST[0]=0x%08h DIGEST[1]=0x%08h", d0, d1);

    if (d0 === SEED_W0 && d1 === SEED_W1) begin
      cov_no_clear_on_debug++;
      $display("    >> BUG-033 OBSERVED: the digest SURVIVES debug-unlock/scan-mode");
      $display("       entry. A correct strobe (ZEROIZE | debug_or_scan) would have");
      $display("       cleared it, as it does for every other zeroize-driven hwclr");
      $display("       in this tree.");
    end

    // The two security-relevant assertions.
    chk("a value is observable in the DIGEST window while debug/scan is asserted (probe works)",
        cov_seed_visible == 1);
    chk("the DIGEST window is NOT cleared on debug-unlock/scan-mode entry",
        (d0 === SEED_W0) && (d1 === SEED_W1));

    // ---------------------------------------------------------------------
    // Observation C: software ZEROIZE with debug/scan deasserted. Both the
    // reference and the rewired expression evaluate to 1 here, so this is a
    // control: it must still clear. If it did not, the defect would be a plain
    // functional break rather than a selective one, and the finding would need
    // to be characterised differently.
    // ---------------------------------------------------------------------
    $display("--- C: software ZEROIZE (ZEROIZE=1, debug_or_scan=0) ---");
    debug_or_scan = 1'b0;
    repeat (4) @(posedge clk);
    seed_digest(seeded);
    reg_write(ADDR_CTRL, CTRL_ZEROIZE[31:0]);
    repeat (4) @(posedge clk);
    reg_read(ADDR_DIGEST_0,         d0);
    reg_read(ADDR_DIGEST_0 + 32'h4, d1);
    $display("    after software ZEROIZE: DIGEST[0]=0x%08h DIGEST[1]=0x%08h", d0, d1);
    chk("control: software ZEROIZE does clear the DIGEST window",
        (d0 === 32'h0) && (d1 === 32'h0));

    $display("");
    $display("===== summary =====");
    $display("  checks=%0d errors=%0d", checks, errors);
    $display("  cover_seed_visible=%0d (expect 1)", cov_seed_visible);
    $display("  cover_no_clear_on_debug=%0d (expect 1)", cov_no_clear_on_debug);
    $display("  cover_clear_when_quiet=%0d (0 or 1; reported, not asserted)",
             cov_clear_when_quiet);
    if (cov_no_clear_on_debug != 1)
      $display("[BUG-033-TBFAIL] vacuous: the debug/scan non-clear was never observed");
    if (cov_seed_visible != 1)
      $display("[BUG-033-TBFAIL] vacuous: the probe value was never observable, harness suspect");
    if (errors == 0) $display("PROOF_RESULT: PASS");
    else             $display("PROOF_RESULT: FAIL");
    $finish;
  end

  initial begin
    #500000;
    $display("[BUG-033-TBFAIL] timeout");
    $finish;
  end
endmodule
`default_nettype wire
