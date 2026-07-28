module BUG_006_aes_prng_masking_real_dut_tb;
  logic clk_i;
  logic rst_ni;
  logic force_masks_i;
  logic data_update_i;
  logic [159:0] data_o;
  logic reseed_req_i;
  logic reseed_ack_o;
  logic entropy_req_o;
  logic entropy_ack_i;
  logic [31:0] entropy_i;

  aes_prng_masking #(
    .SecAllowForcingMasks(1'b0),
    .SecSkipPRNGReseeding(1'b0)
  ) dut (.*);

  task automatic tick;
    begin
      clk_i = 1'b0;
      #1;
      clk_i = 1'b1;
      #1;
      clk_i = 1'b0;
      #1;
    end
  endtask

  initial begin
    clk_i = 1'b0;
    rst_ni = 1'b0;
    force_masks_i = 1'b0;
    data_update_i = 1'b0;
    reseed_req_i = 1'b0;
    entropy_ack_i = 1'b0;
    entropy_i = 32'h6006_6006;
    repeat (2) tick();
    rst_ni = 1'b1;
    tick();

    force_masks_i = 1'b0;
    #1;
    $display("BUG006_CONTROL force_masks_i=0 sec_allow_forcing_masks=0 observed_allow_lockup=%0b observed_primitive_allow=%0b",
             dut.bivium_allow_lockup, dut.u_caliptra_prim_bivium.allow_lockup_i);
    if (dut.bivium_allow_lockup !== 1'b0) $fatal(1, "BUG006_CONTROL_FAIL wrapper asserted lockup override without a force request");
    if (dut.u_caliptra_prim_bivium.allow_lockup_i !== 1'b0) $fatal(1, "BUG006_CONTROL_FAIL primitive lockup override without a force request");

    force_masks_i = 1'b1;
    #1;
    $display("BUG006_WITNESS_GATE force_masks_i=1 sec_allow_forcing_masks=0 observed_allow_lockup=%0b observed_primitive_allow=%0b secure_expected=0",
             dut.bivium_allow_lockup, dut.u_caliptra_prim_bivium.allow_lockup_i);
    if (dut.bivium_allow_lockup !== 1'b1) $fatal(1, "BUG006_WITNESS_NOT_OBSERVED wrapper did not expose the override");
    if (dut.u_caliptra_prim_bivium.allow_lockup_i !== 1'b1) $fatal(1, "BUG006_WITNESS_NOT_OBSERVED primitive did not receive the override");

    $display("BUG006_WITNESS_PASS");
    $finish;
  end
endmodule
