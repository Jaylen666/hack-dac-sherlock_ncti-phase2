// BUG-041 directed proof bench.
//
// One unmodified `uart` top, driven only through its ports: real serial frames
// into cio_rx_i, and all software observation over the AHB-Lite slave port. No
// hierarchical reference into the DUT, no force, no assertion inside the DUT
// relied upon for any verdict.
//
// Check polarity: every check below states the behaviour the design is supposed
// to have. A check that FAILS is the defect speaking. The pass gate at the end
// demands an exact triple of (checks, fails, witness_hits) plus every cover, so
// a bench that silently stopped exercising something cannot report a pass.

`timescale 1ns/1ps

module uart_bug_041_tb;

  localparam int AW = 32;
  localparam int DW = 32;

  // Register offsets, from src/uart/rtl/uart_reg_pkg.sv.
  localparam logic [5:0] OFF_CTRL      = 6'h10;
  localparam logic [5:0] OFF_STATUS    = 6'h14;
  localparam logic [5:0] OFF_RDATA     = 6'h18;
  localparam logic [5:0] OFF_FIFO_CTRL = 6'h20;

  localparam int STATUS_RXEMPTY_BIT = 5;   // uart.hjson STATUS.RXEMPTY

  // CTRL: RX enable (bit 1) with NCO = 0x8000 (bits 31:16). NCO 0x8000 carries
  // every 2 clocks, so tick_baud_x16 is every 2 clocks and one serial bit is
  // 32 clocks.
  localparam logic [31:0] CTRL_RX_EN = 32'h8000_0002;
  localparam int BIT_CLKS = 32;

  // The two bytes driven in over the serial pin. They are distinct from each
  // other and from 8'h00, so "the residual equals the last byte read" cannot be
  // confused with "the FIFO output is zero" or with the earlier byte.
  localparam logic [7:0] BYTE_A = 8'h5A;
  localparam logic [7:0] BYTE_B = 8'hC3;
  localparam logic [7:0] BYTE_C = 8'h96;

  logic clk, rst_n;

  logic [AW-1:0] haddr;
  logic [DW-1:0] hwdata;
  logic          hsel, hwrite, hready;
  logic [1:0]    htrans;
  logic [2:0]    hsize;
  logic          hresp, hreadyout;
  logic [DW-1:0] hrdata;

  logic cio_rx, cio_tx, cio_tx_en;

  caliptra_prim_alert_pkg::alert_rx_t [uart_reg_pkg::NumAlerts-1:0] alert_rx;
  caliptra_prim_alert_pkg::alert_tx_t [uart_reg_pkg::NumAlerts-1:0] alert_tx;

  logic intr_tx_wm, intr_rx_wm, intr_tx_empty, intr_rx_ovf;
  logic intr_rx_frame, intr_rx_break, intr_rx_timeout, intr_rx_parity;

  uart #(
    .AHBDataWidth(DW),
    .AHBAddrWidth(AW)
  ) dut (
    .clk_i   (clk),
    .rst_ni  (rst_n),
    .haddr_i (haddr),
    .hwdata_i(hwdata),
    .hsel_i  (hsel),
    .hwrite_i(hwrite),
    .hready_i(hready),
    .htrans_i(htrans),
    .hsize_i (hsize),
    .hresp_o (hresp),
    .hreadyout_o(hreadyout),
    .hrdata_o(hrdata),
    .alert_rx_i(alert_rx),
    .alert_tx_o(alert_tx),
    .cio_rx_i(cio_rx),
    .cio_tx_o(cio_tx),
    .cio_tx_en_o(cio_tx_en),
    .intr_tx_watermark_o(intr_tx_wm),
    .intr_rx_watermark_o(intr_rx_wm),
    .intr_tx_empty_o(intr_tx_empty),
    .intr_rx_overflow_o(intr_rx_ovf),
    .intr_rx_frame_err_o(intr_rx_frame),
    .intr_rx_break_err_o(intr_rx_break),
    .intr_rx_timeout_o(intr_rx_timeout),
    .intr_rx_parity_err_o(intr_rx_parity)
  );

  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  int checks, fails, witness_hits;
  bit cov_byte_a_received, cov_byte_b_received, cov_status_reports_empty;
  bit cov_residual_seen, cov_displaced_by_new_traffic;

  task automatic check(input string name, input bit ok, input string detail);
    checks++;
    if (ok) begin
      $display("case=%s PASS %s", name, detail);
    end else begin
      fails++;
      $display("TBFAIL case=%s %s", name, detail);
    end
  endtask

  // ---------------- AHB-Lite driver ----------------

  task automatic bus_idle();
    hsel   <= 1'b0;
    htrans <= 2'b00;
    hwrite <= 1'b0;
    @(posedge clk);
  endtask

  // Stimulus is driven on the negedge and the response is sampled after the
  // posedge, so drive and sample never race on the same edge. `dv` inside
  // ahb_slv_sif registers on the posedge that ends the address phase, and both
  // hrdata_o and hreadyout_o are combinational from it, so the read data is
  // valid during that same cycle -- sampling a cycle later returns the next
  // transaction's value, which is how a stale byte can be mistaken for a
  // residual.
  task automatic bus_write(input logic [5:0] off, input logic [31:0] data);
    // Address phase.
    @(negedge clk);
    haddr  = {26'h0, off};
    hwrite = 1'b1;
    hsel   = 1'b1;
    htrans = 2'b10;
    hsize  = 3'b010;
    // Data phase.
    @(negedge clk);
    hwdata = data;
    htrans = 2'b00;
    hsel   = 1'b0;
    hwrite = 1'b0;
    @(posedge clk);
    #1;
    while (!hreadyout) begin
      @(posedge clk);
      #1;
    end
    @(negedge clk);
  endtask

  task automatic bus_read(input logic [5:0] off, output logic [31:0] data);
    // Address phase.
    @(negedge clk);
    haddr  = {26'h0, off};
    hwrite = 1'b0;
    hsel   = 1'b1;
    htrans = 2'b10;
    hsize  = 3'b010;
    // Data phase. `dv` is set by the posedge that ended the address phase, and
    // hrdata_o is combinational from it, so the data is valid *during* this
    // cycle. The FIFO read pointer advances at the posedge that ends it, so
    // sampling any later returns the next location instead of the one read.
    @(negedge clk);
    while (!hreadyout) @(negedge clk);
    data   = hrdata[31:0];
    htrans = 2'b00;
    hsel   = 1'b0;
    @(negedge clk);
  endtask

  // ---------------- serial driver ----------------

  // Drive one 8N1 frame LSB-first on the rx pin at the configured baud.
  task automatic serial_send(input logic [7:0] b);
    int i;
    cio_rx <= 1'b0;                      // start bit
    repeat (BIT_CLKS) @(posedge clk);
    for (i = 0; i < 8; i++) begin
      cio_rx <= b[i];
      repeat (BIT_CLKS) @(posedge clk);
    end
    cio_rx <= 1'b1;                      // stop bit
    repeat (BIT_CLKS) @(posedge clk);
    repeat (BIT_CLKS) @(posedge clk);    // inter-frame idle
  endtask

  logic [31:0] rd, st;

  initial begin
    alert_rx = '{default: caliptra_prim_alert_pkg::ALERT_RX_DEFAULT};
    haddr = '0; hwdata = '0; hsel = 1'b0; hwrite = 1'b0;
    hready = 1'b1; htrans = 2'b00; hsize = 3'b010;
    cio_rx = 1'b1;                       // idle line is high
    checks = 0; fails = 0; witness_hits = 0;
    cov_byte_a_received = 0; cov_byte_b_received = 0;
    cov_status_reports_empty = 0; cov_residual_seen = 0;
    cov_displaced_by_new_traffic = 0;

    rst_n = 1'b0;
    repeat (8) @(posedge clk);
    rst_n = 1'b1;
    repeat (8) @(posedge clk);
    bus_idle();

    // Enable the receiver.
    bus_write(OFF_CTRL, CTRL_RX_EN);

    // ---- control: a real serial byte is received and readable ----
    serial_send(BYTE_A);
    repeat (64) @(posedge clk);
    bus_read(OFF_RDATA, rd);
    if (rd[7:0] == BYTE_A) cov_byte_a_received = 1;
    check("control_serial_byte_is_received_and_readable",
          rd[7:0] == BYTE_A,
          $sformatf("rdata=%02x expected=%02x", rd[7:0], BYTE_A));

    // ---- control: a second, different byte reads back as itself ----
    // This is the anti-vacuity control. Without it, a bench where RDATA always
    // returned BYTE_A would pass the residual check for the wrong reason.
    serial_send(BYTE_B);
    repeat (64) @(posedge clk);
    bus_read(OFF_RDATA, rd);
    if (rd[7:0] == BYTE_B) cov_byte_b_received = 1;
    check("control_second_byte_reads_back_as_itself",
          rd[7:0] == BYTE_B,
          $sformatf("rdata=%02x expected=%02x", rd[7:0], BYTE_B));

    // ---- control: the FIFO now reports itself empty to software ----
    bus_read(OFF_STATUS, st);
    if (st[STATUS_RXEMPTY_BIT]) cov_status_reports_empty = 1;
    check("control_status_reports_rxempty_after_drain",
          st[STATUS_RXEMPTY_BIT] === 1'b1,
          $sformatf("status=%08x rxempty=%0b", st, st[STATUS_RXEMPTY_BIT]));

    // ---- violating: the documented RX-FIFO clear must clear the data ----
    // FIFO_CTRL.RXRST is the mechanism software is given to clear the receive
    // FIFO. After using it, a read of RDATA must not hand back received
    // payload. It returns the first byte of the session.
    bus_write(OFF_FIFO_CTRL, 32'h0000_0001);   // RXRST
    repeat (8) @(posedge clk);
    bus_read(OFF_STATUS, st);
    bus_read(OFF_RDATA, rd);
    if (rd[7:0] == BYTE_A && st[STATUS_RXEMPTY_BIT] === 1'b1) begin
      witness_hits++;
      cov_residual_seen = 1;
    end
    check("violating_rdata_after_documented_rxrst_must_not_return_payload",
          rd[7:0] != BYTE_A,
          $sformatf("rdata=%02x received_earlier=%02x rxempty=%0b",
                    rd[7:0], BYTE_A, st[STATUS_RXEMPTY_BIT]));

    // ---- violating: the residual must not survive repeated empty reads ----
    bus_read(OFF_RDATA, rd);
    bus_read(OFF_STATUS, st);
    check("violating_residual_must_not_persist_across_repeated_empty_reads",
          !(rd[7:0] == BYTE_A && st[STATUS_RXEMPTY_BIT] === 1'b1),
          $sformatf("rdata=%02x rxempty=%0b", rd[7:0], st[STATUS_RXEMPTY_BIT]));

    // ---- violating: a block reset must clear received payload ----
    // The storage flops carry no reset at all, so rst_ni does not clear them
    // either. Both software-visible clears are therefore ineffective.
    rst_n = 1'b0;
    repeat (8) @(posedge clk);
    rst_n = 1'b1;
    repeat (8) @(posedge clk);
    bus_idle();
    bus_read(OFF_STATUS, st);
    bus_read(OFF_RDATA, rd);
    check("violating_block_reset_must_clear_received_payload",
          rd[7:0] != BYTE_A,
          $sformatf("rdata=%02x after rst_ni rxempty=%0b",
                    rd[7:0], st[STATUS_RXEMPTY_BIT]));

    // ---- control: new traffic displaces the residual ----
    // The anti-vacuity control on the three checks above. It establishes that
    // the location being read is a real storage slot that tracks what arrives,
    // so "RDATA returns BYTE_A" is not some constant the bench would see
    // regardless of what the serial line carried.
    bus_write(OFF_CTRL, CTRL_RX_EN);
    serial_send(BYTE_C);
    repeat (64) @(posedge clk);
    bus_read(OFF_RDATA, rd);
    if (rd[7:0] == BYTE_C) cov_displaced_by_new_traffic = 1;
    check("control_new_traffic_displaces_the_residual",
          rd[7:0] == BYTE_C,
          $sformatf("rdata=%02x expected=%02x", rd[7:0], BYTE_C));

    $display("cov_byte_a=%0b cov_byte_b=%0b cov_status_empty=%0b cov_residual=%0b cov_displaced=%0b",
             cov_byte_a_received, cov_byte_b_received, cov_status_reports_empty,
             cov_residual_seen, cov_displaced_by_new_traffic);
    $display("witness_hits=%0d", witness_hits);
    $display("checks=%0d fails=%0d", checks, fails);

    if (checks == 7 && fails == 3 && witness_hits == 1 &&
        cov_byte_a_received && cov_byte_b_received && cov_status_reports_empty &&
        cov_residual_seen && cov_displaced_by_new_traffic) begin
      $display("result=PASS");
      $display("PROOF_RESULT: PASS");
    end else if (checks == 7 && fails == 0 && witness_hits == 0) begin
      $display("result=NOT_THE_AUDITED_SIGNATURE");
      $display("PROOF_RESULT: SIGNATURE_MISMATCH");
    end else begin
      $display("result=FAIL");
      $display("PROOF_RESULT: FAIL");
    end
    $finish;
  end

  initial begin
    #2000000;
    $display("TBFAIL global timeout");
    $display("result=FAIL");
    $display("PROOF_RESULT: FAIL");
    $finish;
  end

endmodule
