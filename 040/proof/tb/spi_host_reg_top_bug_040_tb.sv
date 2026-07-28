// BUG-040 directed witness.
//
// spi_host_reg_top qualifies CONTROL's write-enable with two address hits
// instead of one, so a write aimed at the read-only STATUS register also
// commits new values into every CONTROL field. The onehot write-enable checker
// does not see it, because the vector bit for the STATUS index is tied low, so
// the out-of-bounds update is silent.
//
// One unmodified spi_host_reg_top is instantiated, ports only, no hierarchical
// reference into the DUT and no force. Every check below states the behaviour
// the design is supposed to have, so a check that FAILS is the defect speaking.
// The three violating checks are expected to fail on the audited RTL; the
// negative control patches the qualifier in a scratch copy and they pass.

`timescale 1ns/1ps

module spi_host_reg_top_bug_040_tb;
  import spi_host_reg_pkg::*;

  localparam int unsigned AHB_DW = 32;
  localparam int unsigned AHB_AW = 32;
  localparam logic [1:0]  HTRANS_IDLE   = 2'b00;
  localparam logic [1:0]  HTRANS_NONSEQ = 2'b10;

  // Distinguishable payloads. The STATUS write carries a pattern that no
  // earlier write used, so a CONTROL field holding it afterwards can only have
  // come from the STATUS transaction.
  localparam logic [31:0] CONTROL_PAYLOAD = 32'h8000_11AA; // spien=1 tx=11 rx=AA
  localparam logic [31:0] STATUS_PAYLOAD  = 32'h4000_22BB; // sw_rst=1 spien=0 tx=22 rx=BB

  logic clk;
  logic rst_n;

  logic [AHB_AW-1:0] haddr;
  logic [AHB_DW-1:0] hwdata;
  logic              hsel;
  logic              hwrite;
  logic              hready;
  logic [1:0]        htrans;
  logic [2:0]        hsize;
  logic              hresp;
  logic              hreadyout;
  logic [AHB_DW-1:0] hrdata;
  logic              fifo_rx_re;
  logic              intg_err;

  spi_host_reg2hw_t reg2hw;
  spi_host_hw2reg_t hw2reg;

  int unsigned checks;
  int unsigned fails;
  int unsigned witness_hits;

  // Covers, so a check that never ran cannot be mistaken for a check that passed.
  bit cov_reset_seen;
  bit cov_control_write_takes_effect;
  bit cov_unrelated_write_is_inert;
  bit cov_status_write_reaches_control;
  bit cov_status_readback_seen;

  // Snapshots taken before each probing write.
  logic [7:0] rx_before, tx_before;
  logic       spien_before, swrst_before, outen_before;
  logic [31:0] status_rdata;

  spi_host_reg_top #(
    .AHBDataWidth(AHB_DW),
    .AHBAddrWidth(AHB_AW)
  ) dut (
    .clk_i      (clk),
    .rst_ni     (rst_n),
    .haddr_i    (haddr),
    .hwdata_i   (hwdata),
    .hsel_i     (hsel),
    .hwrite_i   (hwrite),
    .hready_i   (hready),
    .htrans_i   (htrans),
    .hsize_i    (hsize),
    .hresp_o    (hresp),
    .hreadyout_o(hreadyout),
    .hrdata_o   (hrdata),
    .fifo_rx_re (fifo_rx_re),
    .reg2hw     (reg2hw),
    .hw2reg     (hw2reg),
    .intg_err_o (intg_err),
    .devmode_i  (1'b1)
  );

  always #5 clk = ~clk;

  // Hardware-side inputs are held quiet. The claim is entirely about what a bus
  // write does to CONTROL, so leaving hw2reg at zero removes any hardware path
  // that could otherwise be blamed for a CONTROL field changing.
  always_comb hw2reg = '0;

  task automatic bus_idle;
    hsel   = 1'b0;
    hwrite = 1'b0;
    hready = 1'b1;
    htrans = HTRANS_IDLE;
    hsize  = 3'b010;
    haddr  = '0;
    hwdata = '0;
  endtask

  // AHB-Lite: address in the address phase, data in the following data phase.
  task automatic bus_write(input logic [31:0] addr, input logic [31:0] data);
    @(negedge clk);
    hsel   = 1'b1;
    hwrite = 1'b1;
    hready = 1'b1;
    htrans = HTRANS_NONSEQ;
    hsize  = 3'b010;
    haddr  = addr;
    hwdata = '0;
    @(negedge clk);
    haddr  = '0;
    hwrite = 1'b0;
    htrans = HTRANS_IDLE;
    hwdata = data;
    while (!hreadyout) @(negedge clk);
    @(negedge clk);
    bus_idle();
    @(posedge clk);
    #1;
  endtask

  task automatic bus_read(input logic [31:0] addr, output logic [31:0] data);
    @(negedge clk);
    hsel   = 1'b1;
    hwrite = 1'b0;
    hready = 1'b1;
    htrans = HTRANS_NONSEQ;
    hsize  = 3'b010;
    haddr  = addr;
    @(negedge clk);
    haddr  = '0;
    htrans = HTRANS_IDLE;
    while (!hreadyout) @(negedge clk);
    data = hrdata;
    @(negedge clk);
    bus_idle();
    @(posedge clk);
    #1;
  endtask

  task automatic snapshot_control;
    rx_before    = reg2hw.control.rx_watermark.q;
    tx_before    = reg2hw.control.tx_watermark.q;
    spien_before = reg2hw.control.spien.q;
    swrst_before = reg2hw.control.sw_rst.q;
    outen_before = reg2hw.control.output_en.q;
  endtask

  function automatic bit control_unchanged;
    return (reg2hw.control.rx_watermark.q === rx_before) &&
           (reg2hw.control.tx_watermark.q === tx_before) &&
           (reg2hw.control.spien.q        === spien_before) &&
           (reg2hw.control.sw_rst.q       === swrst_before) &&
           (reg2hw.control.output_en.q    === outen_before);
  endfunction

  task automatic check(input string name, input bit ok, input string detail);
    checks++;
    if (ok) begin
      $display("case=%0s PASS %0s", name, detail);
    end else begin
      fails++;
      $display("TBFAIL case=%0s %0s", name, detail);
    end
  endtask

  initial begin
    clk   = 1'b0;
    rst_n = 1'b0;
    checks = 0;
    fails  = 0;
    witness_hits = 0;
    cov_reset_seen = 0;
    cov_control_write_takes_effect = 0;
    cov_unrelated_write_is_inert = 0;
    cov_status_write_reaches_control = 0;
    cov_status_readback_seen = 0;
    bus_idle();

    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    // ---- control 1: the bus interface is alive and CONTROL starts at reset ----
    cov_reset_seen = 1;
    check("control_reset_values_present",
          (reg2hw.control.rx_watermark.q === 8'h7f) &&
          (reg2hw.control.spien.q === 1'b0) &&
          (reg2hw.control.sw_rst.q === 1'b0) &&
          (intg_err === 1'b0),
          $sformatf("rx=%02x spien=%0d sw_rst=%0d intg_err=%0d",
                    reg2hw.control.rx_watermark.q, reg2hw.control.spien.q,
                    reg2hw.control.sw_rst.q, intg_err));

    // ---- control 2: a write to CONTROL's own address does land ----
    // Anti-vacuity. Without this, a CONTROL register that never updates at all
    // would make every "CONTROL unchanged" check below pass for the wrong reason.
    bus_write(32'(SPI_HOST_CONTROL_OFFSET), CONTROL_PAYLOAD);
    cov_control_write_takes_effect = (reg2hw.control.rx_watermark.q === 8'hAA);
    check("control_direct_control_write_takes_effect",
          (reg2hw.control.rx_watermark.q === 8'hAA) &&
          (reg2hw.control.tx_watermark.q === 8'h11) &&
          (reg2hw.control.spien.q === 1'b1),
          $sformatf("rx=%02x tx=%02x spien=%0d",
                    reg2hw.control.rx_watermark.q, reg2hw.control.tx_watermark.q,
                    reg2hw.control.spien.q));

    // ---- control 3: an unrelated register write leaves CONTROL alone ----
    // Establishes that address decoding is otherwise sound, so the STATUS result
    // below cannot be dismissed as "every write hits every register".
    snapshot_control();
    bus_write(32'(SPI_HOST_CONFIGOPTS_0_OFFSET), 32'hFFFF_FFFF);
    cov_unrelated_write_is_inert = control_unchanged();
    check("control_configopts_write_leaves_control_alone",
          control_unchanged(),
          $sformatf("rx=%02x tx=%02x spien=%0d",
                    reg2hw.control.rx_watermark.q, reg2hw.control.tx_watermark.q,
                    reg2hw.control.spien.q));

    // ---- control 4: STATUS is readable, so the address is genuinely mapped ----
    bus_read(32'(SPI_HOST_STATUS_OFFSET), status_rdata);
    cov_status_readback_seen = 1;
    check("control_status_address_is_mapped_and_readable",
          (hresp === 1'b0) && (status_rdata !== 32'hxxxx_xxxx),
          $sformatf("hresp=%0d rdata=%08x", hresp, status_rdata));

    // ---- violating 1: a write to read-only STATUS must not alter CONTROL ----
    snapshot_control();
    bus_write(32'(SPI_HOST_STATUS_OFFSET), STATUS_PAYLOAD);
    if ((reg2hw.control.rx_watermark.q === 8'hBB) &&
        (reg2hw.control.tx_watermark.q === 8'h22)) begin
      witness_hits++;
      cov_status_write_reaches_control = 1;
    end
    check("violating_status_write_must_not_modify_control",
          control_unchanged(),
          $sformatf("rx=%02x(was %02x) tx=%02x(was %02x) spien=%0d(was %0d)",
                    reg2hw.control.rx_watermark.q, rx_before,
                    reg2hw.control.tx_watermark.q, tx_before,
                    reg2hw.control.spien.q, spien_before));

    // ---- violating 2: security-relevant CONTROL bits must not be settable
    //      from another register's address ----
    // sw_rst and spien are the fields that matter: one resets the block, the
    // other takes the SPI host offline. The STATUS payload sets bit 30 and
    // clears bit 31, so a successful out-of-bounds commit asserts sw_rst and
    // deasserts spien in the same transaction.
    check("violating_status_write_must_not_set_sw_rst_or_clear_spien",
          (reg2hw.control.sw_rst.q === swrst_before) &&
          (reg2hw.control.spien.q === spien_before),
          $sformatf("sw_rst=%0d(was %0d) spien=%0d(was %0d)",
                    reg2hw.control.sw_rst.q, swrst_before,
                    reg2hw.control.spien.q, spien_before));

    // ---- violating 3: if a write does commit outside its own register, the
    //      spurious write-enable checker must raise the integrity error ----
    // This is what makes the update silent rather than merely wrong.
    check("violating_out_of_bounds_update_must_raise_intg_err",
          !(witness_hits > 0) || (intg_err === 1'b1),
          $sformatf("witness_hits=%0d intg_err=%0d", witness_hits, intg_err));

    // ---- containment: the residue is a register state, a reset clears it ----
    rst_n = 1'b0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);
    check("containment_reset_clears_the_injected_control_state",
          (reg2hw.control.rx_watermark.q === 8'h7f) &&
          (reg2hw.control.sw_rst.q === 1'b0) &&
          (reg2hw.control.spien.q === 1'b0),
          $sformatf("rx=%02x sw_rst=%0d spien=%0d",
                    reg2hw.control.rx_watermark.q, reg2hw.control.sw_rst.q,
                    reg2hw.control.spien.q));

    $display("cov_reset=%0d cov_control_write=%0d cov_unrelated_inert=%0d cov_status_reaches_control=%0d cov_status_read=%0d",
             cov_reset_seen, cov_control_write_takes_effect,
             cov_unrelated_write_is_inert, cov_status_write_reaches_control,
             cov_status_readback_seen);
    $display("witness_hits=%0d", witness_hits);
    $display("checks=%0d fails=%0d", checks, fails);

    // On the audited RTL the three violating checks must fail and the four
    // controls plus the containment case must pass. Any other combination means
    // the bench did not exercise what it claims, so it is reported as a failure
    // rather than quietly accepted.
    if (checks == 8 && fails == 3 && witness_hits == 1 &&
        cov_reset_seen && cov_control_write_takes_effect &&
        cov_unrelated_write_is_inert && cov_status_write_reaches_control &&
        cov_status_readback_seen) begin
      $display("result=PASS");
      $display("PROOF_RESULT: PASS");
    end else if (checks == 8 && fails == 0 && witness_hits == 0) begin
      // The qualifier has been corrected: nothing violates, nothing witnessed.
      $display("result=NOT_THE_AUDITED_SIGNATURE");
      $display("PROOF_RESULT: SIGNATURE_MISMATCH");
    end else begin
      $display("result=FAIL");
      $display("PROOF_RESULT: FAIL");
    end
    $finish;
  end

  // Global timeout, so a hung bus transaction cannot look like a clean pass.
  initial begin
    #200000;
    $display("TBFAIL global timeout");
    $display("result=FAIL");
    $finish;
  end
endmodule
