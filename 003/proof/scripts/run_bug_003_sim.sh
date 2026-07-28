#!/usr/bin/env bash
# BUG-003 / BUG-005 directed simulation: unit-level aes_reg_top over TL-UL.
# Confirms the AUX shadow register commits a new value while REGWEN=0,
# and that DATA_IN reads back software-written plaintext.
set -euo pipefail

CMP="${CMP_ROOT:-/home/smy/hackatdac26-phase-2-caliptra}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TB="$(cd "$HERE/../tb" && pwd)"
LOGS="$(cd "$HERE/../logs" && pwd)"
BUILD="$LOGS/../build"

# Allow the negative control to point the compile at a patched copy of the DUT and
# to redirect the logs, so that it runs the IDENTICAL testbench and flow.
DUT_FILE="${DUT_AES_REG_TOP:-$CMP/src/aes/rtl/aes_reg_top.sv}"
SIM_LOG="${SIM_LOG:-$LOGS/sim.log}"
CMP_LOG="${CMP_LOG:-$LOGS/compile.log}"

rm -rf "$BUILD"
mkdir -p "$BUILD"
cd "$BUILD"

S="$CMP/src"
cat > filelist.f <<EOF
+incdir+$S/caliptra_prim/rtl
+incdir+$S/caliptra_tlul/rtl
+incdir+$S/aes/rtl
+incdir+$S/libs/rtl
$S/caliptra_prim/rtl/caliptra_prim_util_pkg.sv
$S/caliptra_prim/rtl/caliptra_prim_mubi_pkg.sv
$S/caliptra_prim/rtl/caliptra_prim_secded_pkg.sv
$S/caliptra_prim/rtl/caliptra_prim_pkg.sv
$S/caliptra_prim/rtl/caliptra_prim_subreg_pkg.sv
$S/caliptra_tlul/rtl/caliptra_tlul_pkg.sv
$S/aes/rtl/aes_reg_pkg.sv
EOF

# Exact transitive closure of what aes_reg_top instantiates. Derived by walking
# instantiations in aes_reg_top -> adapter_reg / cmd_intg_chk -> leaf cells.
# An explicit list (not a glob) keeps unrelated prim cells and their own package
# dependencies out of the compile.
cat >> filelist.f <<EOF
$S/caliptra_prim_generic/rtl/caliptra_prim_generic_buf.sv
$S/caliptra_prim_generic/rtl/caliptra_prim_generic_flop.sv
$S/caliptra_prim/rtl/caliptra_prim_buf.sv
$S/caliptra_prim/rtl/caliptra_prim_flop.sv
$S/caliptra_prim/rtl/caliptra_prim_onehot_check.sv
$S/caliptra_prim/rtl/caliptra_prim_reg_we_check.sv
$S/caliptra_prim/rtl/caliptra_prim_subreg_arb.sv
$S/caliptra_prim/rtl/caliptra_prim_subreg.sv
$S/caliptra_prim/rtl/caliptra_prim_subreg_ext.sv
$S/caliptra_prim/rtl/caliptra_prim_subreg_shadow.sv
$S/caliptra_prim/rtl/caliptra_prim_secded_inv_39_32_enc.sv
$S/caliptra_prim/rtl/caliptra_prim_secded_inv_39_32_dec.sv
$S/caliptra_prim/rtl/caliptra_prim_secded_inv_64_57_enc.sv
$S/caliptra_prim/rtl/caliptra_prim_secded_inv_64_57_dec.sv
$S/caliptra_tlul/rtl/caliptra_tlul_data_integ_enc.sv
$S/caliptra_tlul/rtl/caliptra_tlul_data_integ_dec.sv
$S/caliptra_tlul/rtl/caliptra_tlul_rsp_intg_gen.sv
$S/caliptra_tlul/rtl/caliptra_tlul_cmd_intg_chk.sv
$S/caliptra_tlul/rtl/caliptra_tlul_err.sv
$S/caliptra_tlul/rtl/caliptra_tlul_adapter_reg.sv
EOF

echo "$DUT_FILE" >> filelist.f
echo "$TB/aes_reg_bug_003_tb.sv" >> filelist.f

# NOTE on the expected AssertConnected_A failure at time 1ps.
#
# caliptra_prim_onehot_check instantiates an init-time check that the *integrator*
# has bound CALIPTRA_ASSERT_PRIM_COUNT_ERROR_TRIGGER_ALERT, which is what drives
# its local unused_assert_connected to 1. That macro belongs to the alert-handling
# wiring at the block/top level; a unit-level register harness does not instantiate
# it, so the check fires on harness structure, not on DUT behaviour.
#
# It fires even though CLP_ASSERT_ON is left undefined: caliptra_prim_assert.sv:114
# defines CALIPTRA_INC_ASSERT unconditionally on any non-Verilator/Synthesis/Yosys
# tool, and AssertConnected_A is guarded by CALIPTRA_INC_ASSERT rather than by
# CLP_ASSERT_ON. It is therefore reported here and deliberately not treated as a
# proof signal. This proof rests on the TB's own self-checks, which are
# independent of the DUT's SVA; the verdict grep below ignores VCS assertion
# output and looks only for TBFAIL / PROOF_RESULT.
vcs -full64 -sverilog -timescale=1ns/1ps \
    -assert svaext \
    -f filelist.f \
    -top aes_reg_bug_003_tb \
    -l "$CMP_LOG" -o simv 2>&1 | tail -5

./simv -l "$SIM_LOG" 2>&1 | tail -40

# ---- verdicts ----
if grep -q 'TBFAIL' "$SIM_LOG"; then
  echo "SIM RESULT: FAIL (self-check tripped)" | tee -a "$SIM_LOG"
  exit 1
fi
if ! grep -q 'PROOF_RESULT: PASS' "$SIM_LOG"; then
  echo "SIM RESULT: FAIL (no PASS verdict)" | tee -a "$SIM_LOG"
  exit 1
fi

grep -E 'cover_aux_committed_while_locked|cover_data_in_readback|BUG-003 OBSERVED' \
     "$SIM_LOG" || true
echo "SIM RESULT: PASS"
