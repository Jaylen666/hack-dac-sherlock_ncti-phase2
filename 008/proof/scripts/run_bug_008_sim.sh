#!/usr/bin/env bash
# BUG-008 directed simulation: the audited MuBi package's own functions.
#
# The DUT here is a package, not a module, so the compile closure is just the
# package and the assert header it includes. Both are taken verbatim from the
# audited tree; the negative control may point at a patched scratch copy of the
# package instead.
set -euo pipefail

CMP="${CMP_ROOT:-/home/smy/hackatdac26-phase-2-caliptra}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TB="$(cd "$HERE/../tb" && pwd)"
LOGS="$(cd "$HERE/../logs" && pwd)"
BUILD="$LOGS/../build"

DUT_MUBI_PKG="${DUT_MUBI_PKG:-$CMP/src/caliptra_prim/rtl/caliptra_prim_mubi_pkg.sv}"
SIM_LOG="${SIM_LOG:-$LOGS/sim.log}"
CMP_LOG="${CMP_LOG:-$LOGS/compile.log}"
TB_FILE="${TB_FILE:-$TB/mubi4_strict_bug_008_tb.sv}"
TB_TOP="${TB_TOP:-mubi4_strict_bug_008_tb}"

rm -rf "$BUILD"
mkdir -p "$BUILD"
cd "$BUILD"

# CLP_ASSERT_ON is left undefined. caliptra_prim_assert.sv:114 defines
# CALIPTRA_INC_ASSERT unconditionally on non-Verilator tools, so the package's
# static assertion may compile in regardless; that is harmless here and is not a
# proof signal. The verdict below looks only at TBFAIL and PROOF_RESULT.
vcs -full64 -sverilog -timescale=1ns/1ps \
    -assert svaext \
    +lint=none \
    +incdir+"$CMP/src/caliptra_prim/rtl" \
    +incdir+"$CMP/src/libs/rtl" \
    "$DUT_MUBI_PKG" \
    "$TB_FILE" \
    -top "$TB_TOP" \
    -l "$CMP_LOG" -o simv 2>&1 | tail -20

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

grep -E 'cover_|OBSERVED:|checks=' "$SIM_LOG" || true
echo "SIM RESULT: PASS"
