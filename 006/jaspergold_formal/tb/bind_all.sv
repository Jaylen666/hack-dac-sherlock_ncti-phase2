bind aes_prng_masking CSBC_CALIPTRA_AES_BUG006_checker #(
  .SecAllowForcingMasks(SecAllowForcingMasks)
) u_CSBC_CALIPTRA_AES_BUG006_checker (
  .clk_i               (clk_i),
  .rst_ni              (rst_ni),
  .force_masks_i       (force_masks_i),
  .bivium_allow_lockup (bivium_allow_lockup)
);
