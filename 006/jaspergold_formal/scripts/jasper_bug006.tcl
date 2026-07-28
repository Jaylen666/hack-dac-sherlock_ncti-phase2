# Fixed JasperGold script for Caliptra bug 006
set module_root $::env(CSBC_FORMAL_ROOT)
set caliptra_root $::env(CALIPTRA_ROOT)
set prim_generic_root "$caliptra_root/src/caliptra_prim_generic"

# Include directories
set incdirs [list \
  "+incdir+$caliptra_root/src/entropy_src/rtl" \
  "+incdir+$caliptra_root/src/csrng/rtl" \
  "+incdir+$caliptra_root/src/edn/rtl" \
  "+incdir+$caliptra_root/src/integration/rtl" \
  "+incdir+$caliptra_root/src/libs/rtl" \
  "+incdir+$caliptra_root/src/caliptra_prim/rtl" \
  "+incdir+$caliptra_root/src/lc_ctrl/rtl" \
  "+incdir+$caliptra_root/src/caliptra_prim_generic/rtl" \
  "+incdir+$caliptra_root/src/aes/rtl" \
]

# Package files (from aes_pkg.vf minus generic prim RTL)
set pkg_files [list \
  "$caliptra_root/src/integration/rtl/config_defines.svh" \
  "$caliptra_root/src/libs/rtl/caliptra_sva.svh" \
  "$caliptra_root/src/libs/rtl/caliptra_macros.svh" \
  "$caliptra_root/src/libs/rtl/caliptra_sram.sv" \
  "$caliptra_root/src/libs/rtl/ahb_defines_pkg.sv" \
  "$caliptra_root/src/libs/rtl/caliptra_ahb_srom.sv" \
  "$caliptra_root/src/libs/rtl/ahb_slv_sif.sv" \
  "$caliptra_root/src/libs/rtl/caliptra_icg.sv" \
  "$caliptra_root/src/libs/rtl/clk_gate.sv" \
  "$caliptra_root/src/libs/rtl/caliptra_2ff_sync.sv" \
  "$caliptra_root/src/libs/rtl/ahb_to_reg_adapter.sv" \
  "$caliptra_root/src/libs/rtl/skidbuffer.v" \
  "$caliptra_root/src/caliptra_prim/rtl/caliptra_prim_util_pkg.sv" \
  "$caliptra_root/src/caliptra_prim/rtl/caliptra_prim_alert_pkg.sv" \
  "$caliptra_root/src/caliptra_prim/rtl/caliptra_prim_subreg_pkg.sv" \
  "$caliptra_root/src/caliptra_prim/rtl/caliptra_prim_mubi_pkg.sv" \
  "$caliptra_root/src/caliptra_prim/rtl/caliptra_prim_cipher_pkg.sv" \
  "$caliptra_root/src/caliptra_prim/rtl/caliptra_prim_pkg.sv" \
  "$caliptra_root/src/caliptra_prim/rtl/caliptra_prim_sparse_fsm_pkg.sv" \
  "$caliptra_root/src/caliptra_prim/rtl/caliptra_prim_trivium_pkg.sv" \
  "$caliptra_root/src/caliptra_prim/rtl/caliptra_prim_secded_pkg.sv" \
  "$caliptra_root/src/caliptra_prim/rtl/caliptra_prim_otp_pkg.sv" \
  "$caliptra_root/src/caliptra_prim/rtl/caliptra_prim_ram_1p_pkg.sv" \
  "$caliptra_root/src/caliptra_prim/rtl/caliptra_prim_esc_pkg.sv" \
  "$caliptra_root/src/caliptra_prim/rtl/caliptra_prim_count_pkg.sv" \
  "$caliptra_root/src/caliptra_prim/rtl/keymgr_pkg.sv" \
  "$caliptra_root/src/entropy_src/rtl/entropy_src_main_sm_pkg.sv" \
  "$caliptra_root/src/entropy_src/rtl/entropy_src_ack_sm_pkg.sv" \
  "$caliptra_root/src/entropy_src/rtl/entropy_src_reg_pkg.sv" \
  "$caliptra_root/src/entropy_src/rtl/entropy_src_pkg.sv" \
  "$caliptra_root/src/csrng/rtl/csrng_reg_pkg.sv" \
  "$caliptra_root/src/csrng/rtl/csrng_pkg.sv" \
  "$caliptra_root/src/edn/rtl/edn_pkg.sv" \
  "$caliptra_root/src/lc_ctrl/rtl/lc_ctrl_reg_pkg.sv" \
  "$caliptra_root/src/lc_ctrl/rtl/lc_ctrl_state_pkg.sv" \
  "$caliptra_root/src/lc_ctrl/rtl/lc_ctrl_pkg.sv" \
  "$caliptra_root/src/aes/rtl/aes_reg_pkg.sv" \
  "$caliptra_root/src/aes/rtl/aes_pkg.sv" \
  "$caliptra_root/src/aes/rtl/aes_sbox_canright_pkg.sv" \
  "$caliptra_root/src/aes/rtl/aes_clp_reg_pkg.sv" \
]

# RTL files needed for aes_prng_masking
set rtl_files [list \
  "$caliptra_root/src/caliptra_prim/rtl/caliptra_prim_trivium.sv" \
  "$caliptra_root/src/aes/rtl/aes_prng_masking.sv" \
]

# Checker files
set checker_files [list \
  "$module_root/tb/checker.sv" \
  "$module_root/tb/bind_all.sv" \
]

# Analyze
analyze -sv {*}$incdirs {*}$pkg_files
analyze -sv {*}$incdirs {*}$rtl_files
analyze -sv {*}$incdirs {*}$checker_files

elaborate -top aes_prng_masking
clock clk_i
reset -expression {!rst_ni}

prove -all -engine_mode {H B F N} -per_property_time_limit 120s
report -summary -results -file "$module_root/logs/bug006_property_summary.txt"
save -jdb -force "$module_root/logs/bug006.jdb"
exit
