module CSBC_CALIPTRA_AES_BUG006_checker #(
  parameter bit SecAllowForcingMasks = 1'b0
) (
  input logic clk_i,
  input logic rst_ni,
  input logic force_masks_i,
  input logic bivium_allow_lockup
);

  // Security intent:
  // When SecAllowForcingMasks is disabled, force_masks_i is documented as an
  // inactive SCA-only control. It must not assert the Bivium lockup override.

  CSBC_CALIPTRA_AES_BUG006_FORCE_MASKS_DISABLED_BLOCKS_LOCKUP:
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      (!SecAllowForcingMasks && force_masks_i) |->
        (bivium_allow_lockup == 1'b0));

  CSBC_CALIPTRA_AES_BUG006_DISABLED_LOCKUP_INVARIANT:
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      (!SecAllowForcingMasks) |->
        (bivium_allow_lockup == 1'b0));

  CSBC_CALIPTRA_AES_BUG006_TRIGGER:
    cover property (@(posedge clk_i) disable iff (!rst_ni)
      (!SecAllowForcingMasks && force_masks_i));

  CSBC_CALIPTRA_AES_BUG006_VIOLATION:
    cover property (@(posedge clk_i) disable iff (!rst_ni)
      (!SecAllowForcingMasks && force_masks_i && bivium_allow_lockup));

endmodule
