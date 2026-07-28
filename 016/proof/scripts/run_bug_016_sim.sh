#!/usr/bin/env bash
# BUG-016 directed simulation: unit-level hmac_core.
#
# Uses the project's own filelist (src/hmac/config/hmac_ctrl.vf) rather than a
# hand-curated closure, so the compile matches how the audited tree builds the
# block. Every file is taken verbatim from the tree except the DUT, which the
# negative control may point at a patched scratch copy.
set -euo pipefail

CMP="${CMP_ROOT:-/home/smy/hackatdac26-phase-2-caliptra}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TB="$(cd "$HERE/../tb" && pwd)"
LOGS="$(cd "$HERE/../logs" && pwd)"
BUILD="$LOGS/../build"

DUT_HMAC_CORE="${DUT_HMAC_CORE:-$CMP/src/hmac/rtl/hmac_core.sv}"
SIM_LOG="${SIM_LOG:-$LOGS/sim.log}"
CMP_LOG="${CMP_LOG:-$LOGS/compile.log}"
TB_FILE="${TB_FILE:-$TB/hmac_core_bug_016_tb.sv}"
TB_TOP="${TB_TOP:-hmac_core_bug_016_tb}"

export CALIPTRA_ROOT="$CMP"
export CALIPTRA_PRIM_ROOT="${CALIPTRA_PRIM_ROOT:-$CMP/src/caliptra_prim_generic}"
export CALIPTRA_PRIM_MODULE_PREFIX="${CALIPTRA_PRIM_MODULE_PREFIX:-caliptra_prim_generic}"

rm -rf "$BUILD"
mkdir -p "$BUILD"
cd "$BUILD"

python3 - "$CMP/src/hmac/config/hmac_ctrl.vf" "$DUT_HMAC_CORE" > filelist.f <<'PY'
import os, sys
vf, dut = sys.argv[1], sys.argv[2]
root  = os.environ["CALIPTRA_ROOT"]
proot = os.environ["CALIPTRA_PRIM_ROOT"]
pfx   = os.environ["CALIPTRA_PRIM_MODULE_PREFIX"]
canonical_dut = os.path.join(root, "src/hmac/rtl/hmac_core.sv")
for line in open(vf):
    line = line.strip()
    if not line or line.startswith("//"):
        continue
    line = (line.replace("${CALIPTRA_ROOT}", root)
                .replace("${CALIPTRA_PRIM_ROOT}", proot)
                .replace("${CALIPTRA_PRIM_MODULE_PREFIX}", pfx))
    if os.path.normpath(line) == os.path.normpath(canonical_dut):
        line = dut
    print(line)
PY

echo "$TB_FILE" >> filelist.f

# CLP_ASSERT_ON is left undefined. caliptra_prim_assert.sv:114 defines
# CALIPTRA_INC_ASSERT unconditionally on non-Verilator tools, so integrator
# binding checks may still compile in and report on harness structure rather
# than DUT behaviour. Such reports are not proof signals: the verdict below
# looks only at TBFAIL and PROOF_RESULT, both emitted by the TB self-checks.
vcs -full64 -sverilog -timescale=1ns/1ps \
    -assert svaext \
    +lint=none \
    -f filelist.f \
    -top "$TB_TOP" \
    -l "$CMP_LOG" -o simv 2>&1 | tail -20

./simv -l "$SIM_LOG" 2>&1 | tail -70

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

# Drop the simulator build tree: it is a rebuildable intermediate, and shipping
# it would put compiler-generated absolute paths and a symlink into the case.
cd "$HERE"
rm -rf "$BUILD"

echo "SIM RESULT: PASS"
