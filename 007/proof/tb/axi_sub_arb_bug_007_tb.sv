// SPDX-License-Identifier: Apache-2.0
//
// Directed witness for contest bug 007.
//
// Property under test (attribute coherence):
//   axi_sub_arb multiplexes one read channel and one write channel onto a
//   single component-facing request. Whichever channel is granted, every
//   component-facing attribute must describe that same granted transaction.
//   The granted channel is observable on the `write` output, which the module
//   drives as `r_win ? 0 : 1`, so:
//       write == 0  =>  addr/id/user must come from the read channel
//       write == 1  =>  addr/id/user must come from the write channel
//   `user` is the AXI USER field, which soc_ifc_top compares against the
//   mailbox, fuse, TRNG and DMA AXI_USER allowlists, so an incoherent `user`
//   is an access-control decision made against the wrong requester identity.
//
// This testbench compiles exactly one DUT and drives safe and violating
// stimulus against it. No second implementation is involved.

`timescale 1ns/1ps

module axi_sub_arb_bug_007_tb;

  localparam int AW = 32;
  localparam int DW = 32;
  localparam int UW = 32;
  localparam int IW = 1;

  localparam logic [UW-1:0] R_USER = 32'hAAAA_1111; // read-channel identity
  localparam logic [UW-1:0] W_USER = 32'h5555_2222; // write-channel identity
  localparam logic [AW-1:0] R_ADDR = 32'h0000_1000;
  localparam logic [AW-1:0] W_ADDR = 32'h0000_2000;

  logic clk = 1'b0;
  logic rst_n;

  logic          r_dv, r_last, r_hld, r_err;
  logic [AW-1:0] r_addr;
  logic [UW-1:0] r_user;
  logic [IW-1:0] r_id;
  logic [2:0]    r_size;
  logic [DW-1:0] r_rdata;

  logic          w_dv, w_last, w_hld, w_err;
  logic [AW-1:0] w_addr;
  logic [UW-1:0] w_user;
  logic [IW-1:0] w_id;
  logic [DW-1:0] w_wdata;
  logic [DW/8-1:0] w_wstrb;
  logic [2:0]    w_size;

  logic          dv, write, last, hld;
  logic [AW-1:0] addr;
  logic [UW-1:0] user;
  logic [IW-1:0] id;
  logic [DW-1:0] wdata, rdata;
  logic [DW/8-1:0] wstrb;
  logic [2:0]    size;
  logic          rd_err, wr_err;

  int unsigned fails = 0;
  int unsigned checks = 0;
  int unsigned witness_hits = 0;

  always #5 clk = ~clk;

  axi_sub_arb #(.AW(AW), .DW(DW), .UW(UW), .IW(IW), .C_LAT(0)) dut (
    .clk(clk), .rst_n(rst_n),
    .r_dv(r_dv), .r_addr(r_addr), .r_user(r_user), .r_id(r_id),
    .r_size(r_size), .r_last(r_last), .r_hld(r_hld), .r_err(r_err),
    .r_rdata(r_rdata),
    .w_dv(w_dv), .w_addr(w_addr), .w_user(w_user), .w_id(w_id),
    .w_wdata(w_wdata), .w_wstrb(w_wstrb), .w_size(w_size), .w_last(w_last),
    .w_hld(w_hld), .w_err(w_err),
    .dv(dv), .addr(addr), .write(write), .user(user), .id(id),
    .wdata(wdata), .wstrb(wstrb), .size(size), .last(last),
    .hld(hld), .rd_err(rd_err), .wr_err(wr_err), .rdata(rdata)
  );

  // Check attribute coherence for the currently granted channel.
  task automatic check_case(string label, bit expect_incoherent);
    logic [UW-1:0] want_user;
    logic [AW-1:0] want_addr;
    bit             coherent;
    begin
      checks++;
      want_user = (write == 1'b0) ? R_USER : W_USER;
      want_addr = (write == 1'b0) ? R_ADDR : W_ADDR;
      coherent  = (user == want_user) && (addr == want_addr);

      $display("case=%s granted=%s dv=%0b addr=0x%08x id=%0b user=0x%08x expected_user=0x%08x",
               label, (write == 1'b0) ? "READ " : "WRITE", dv, addr, id, user, want_user);

      if (expect_incoherent) begin
        if (!coherent) begin
          witness_hits++;
          $display("WITNESS: %s granted the %s channel but exported user=0x%08x, which belongs to the %s channel",
                   label, (write == 1'b0) ? "read" : "write", user,
                   (write == 1'b0) ? "write" : "read");
          $display("PASS: %s reproduced the attribute-coherence violation", label);
        end else begin
          fails++;
          $display("FAIL: %s expected an attribute-coherence violation, observed a coherent grant", label);
        end
      end else begin
        if (coherent) begin
          $display("PASS: %s attributes are coherent with the granted channel", label);
        end else begin
          fails++;
          $display("FAIL: %s control case is incoherent (user=0x%08x want=0x%08x addr=0x%08x want=0x%08x)",
                   label, user, want_user, addr, want_addr);
        end
      end
    end
  endtask

  // Grant priority follows the previous burst, so drive a lone write burst to
  // hand priority to the read channel, then a lone read burst to hand it back.
  task automatic give_priority_to_read();
    begin
      r_dv = 0; w_dv = 1; w_last = 1;
      @(posedge clk); #1;
      w_dv = 0; w_last = 0; #1;
    end
  endtask

  task automatic give_priority_to_write();
    begin
      w_dv = 0; r_dv = 1; r_last = 1;
      @(posedge clk); #1;
      r_dv = 0; r_last = 0; #1;
    end
  endtask

  initial begin
    rst_n   = 0;
    r_dv    = 0; r_addr = R_ADDR; r_user = R_USER; r_id = 1'b0;
    r_size  = 3'd2; r_last = 0;
    w_dv    = 0; w_addr = W_ADDR; w_user = W_USER; w_id = 1'b1;
    w_size  = 3'd2; w_last = 0; w_wdata = 32'hDEAD_BEEF; w_wstrb = '1;
    hld     = 0; rd_err = 0; wr_err = 0; rdata = 32'h0;

    repeat (3) @(posedge clk);
    rst_n = 1;
    @(posedge clk); #1;

    // Control 1: lone read request. Read channel is granted and must export
    // the read identity.
    give_priority_to_read();
    r_dv = 1; w_dv = 0; #1;
    check_case("control_read_only", 0);
    r_dv = 0; #1;

    // Control 2: lone write request. Write channel is granted and must export
    // the write identity.
    give_priority_to_write();
    w_dv = 1; r_dv = 0; #1;
    check_case("control_write_only", 0);
    w_dv = 0; #1;

    // Control 3: concurrent request while priority sits with the write
    // channel. The write channel is granted, so its own identity is correct.
    give_priority_to_write();
    r_dv = 1; w_dv = 1; #1;
    check_case("control_concurrent_write_priority", 0);
    r_dv = 0; w_dv = 0; #1;

    // Violating case: concurrent request while priority sits with the read
    // channel. The read channel is granted on addr/id/write, but the USER
    // field is taken from the concurrent write request.
    give_priority_to_read();
    r_dv = 1; w_dv = 1; #1;
    check_case("violating_concurrent_read_priority", 1);
    r_dv = 0; w_dv = 0; #1;

    @(posedge clk);
    $display("checks=%0d fails=%0d witness_hits=%0d", checks, fails, witness_hits);
    if (fails == 0 && witness_hits == 1) begin
      $display("result=PASS");
      $display("BUG_007_WITNESS_OBSERVED");
    end else begin
      $display("result=FAIL");
    end
    $finish;
  end

endmodule
