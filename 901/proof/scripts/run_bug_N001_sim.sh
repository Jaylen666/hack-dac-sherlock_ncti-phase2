#!/usr/bin/env bash
# BUG-N-001 directed simulation: soc_ifc_top SS_DEBUG_INTENT write qualifier.
#
# Uses the project's own filelist (src/soc_ifc/config/soc_ifc_top.vf) rather than
# a hand-curated closure, so the compile matches how the audited tree builds the
# block. Every file is taken verbatim from the tree except the DUT, which the
# negative control may point at a patched scratch copy.
#
# CALIPTRA_MODE_SUBSYSTEM is defined because src/soc_ifc/rtl/soc_ifc_top.sv:890
# guards the debug_intent data source with it: without the define, :893 ties the
# next value to 0 and the register cannot be written from DMI at all. Subsystem
# mode is the configuration in which this register is populated, per the comment
# at :888-889, so it is the configuration the defect lives in.
set -euo pipefail

CMP="${CMP_ROOT:-/home/smy/hackatdac26-phase-2-caliptra}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TB="$(cd "$HERE/../tb" && pwd)"
LOGS="$(cd "$HERE/../logs" && pwd)"
BUILD="$LOGS/../build"

DUT_SOC_IFC_TOP="${DUT_SOC_IFC_TOP:-$CMP/src/soc_ifc/rtl/soc_ifc_top.sv}"
SIM_LOG="${SIM_LOG:-$LOGS/sim.log}"
CMP_LOG="${CMP_LOG:-$LOGS/compile.log}"
TB_FILE="${TB_FILE:-$TB/soc_ifc_top_bug_N001_tb.sv}"
TB_TOP="${TB_TOP:-soc_ifc_top_bug_N001_tb}"

export CALIPTRA_ROOT="$CMP"
export CALIPTRA_PRIM_ROOT="${CALIPTRA_PRIM_ROOT:-$CMP/src/caliptra_prim_generic}"
export CALIPTRA_PRIM_MODULE_PREFIX="${CALIPTRA_PRIM_MODULE_PREFIX:-caliptra_prim_generic}"

rm -rf "$BUILD"
mkdir -p "$BUILD"
cd "$BUILD"

python3 - "$CMP/src/soc_ifc/config/soc_ifc_top.vf" "$DUT_SOC_IFC_TOP" > filelist.f <<'PY'
import os, sys
vf, dut = sys.argv[1], sys.argv[2]
root  = os.environ["CALIPTRA_ROOT"]
proot = os.environ["CALIPTRA_PRIM_ROOT"]
pfx   = os.environ["CALIPTRA_PRIM_MODULE_PREFIX"]
canonical_dut = os.path.join(root, "src/soc_ifc/rtl/soc_ifc_top.sv")
seen = set()
for line in open(vf):
    line = line.strip()
    if not line or line.startswith("//"):
        continue
    line = (line.replace("${CALIPTRA_ROOT}", root)
                .replace("${CALIPTRA_PRIM_ROOT}", proot)
                .replace("${CALIPTRA_PRIM_MODULE_PREFIX}", pfx))
    if os.path.normpath(line) == os.path.normpath(canonical_dut):
        line = dut
    if line in seen:
        continue
    seen.add(line)
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
    +define+CALIPTRA_MODE_SUBSYSTEM \
    -f filelist.f \
    -top "$TB_TOP" \
    -l "$CMP_LOG" -o simv 2>&1 | tail -25

./simv -l "$SIM_LOG" 2>&1 | tail -80

# ---- verdicts ----
# The defect itself is reported by the TB as TBFAIL lines on the violating
# checks, so a TBFAIL is expected here and is not a script failure. Only a
# global timeout indicates the harness itself did not run to completion.
if grep -q 'TBFAIL global timeout' "$SIM_LOG"; then
  echo "SIM RESULT: FAIL (harness timed out)" | tee -a "$SIM_LOG"
  exit 1
fi
if ! grep -q 'PROOF_RESULT: PASS' "$SIM_LOG"; then
  echo "SIM RESULT: FAIL (no PASS verdict)" | tee -a "$SIM_LOG"
  exit 1
fi

grep -E 'cov_|OBSERVED:|checks=' "$SIM_LOG" || true
echo "SIM RESULT: PASS"
