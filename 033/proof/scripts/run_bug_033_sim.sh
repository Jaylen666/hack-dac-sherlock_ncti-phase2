#!/usr/bin/env bash
# BUG-033 directed simulation: unit-level sha512 with its own register block.
#
# Drives both values of debugUnlock_or_scan_mode_switch and reports what the
# SHA512_DIGEST window actually does in each case, then asserts the two
# security-relevant conclusions.
#
# Uses the project's own filelist (src/sha512/config/sha512_ctrl.vf) rather than a
# hand-curated closure, so the compile matches how the audited tree builds the block.
set -euo pipefail

CMP="${CMP_ROOT:-/home/smy/hackatdac26-phase-2-caliptra}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TB="$(cd "$HERE/../tb" && pwd)"
LOGS="$(cd "$HERE/../logs" && pwd)"
BUILD="$LOGS/../build"

# Allow the negative control to point the compile at a patched copy of the DUT.
DUT_SHA512="${DUT_SHA512:-$CMP/src/sha512/rtl/sha512.sv}"
SIM_LOG="${SIM_LOG:-$LOGS/sim.log}"
CMP_LOG="${CMP_LOG:-$LOGS/compile.log}"

export CALIPTRA_ROOT="$CMP"
export CALIPTRA_PRIM_ROOT="${CALIPTRA_PRIM_ROOT:-$CMP/src/caliptra_prim_generic}"
export CALIPTRA_PRIM_MODULE_PREFIX="${CALIPTRA_PRIM_MODULE_PREFIX:-caliptra_prim_generic}"

rm -rf "$BUILD"
mkdir -p "$BUILD"
cd "$BUILD"

# Expand the project filelist, substituting the DUT file so the negative control
# can swap in a patched copy. Every other file is taken verbatim from the tree.
python3 - "$CMP/src/sha512/config/sha512_ctrl.vf" "$DUT_SHA512" > filelist.f <<'PY'
import os, sys
vf, dut = sys.argv[1], sys.argv[2]
root  = os.environ["CALIPTRA_ROOT"]
proot = os.environ["CALIPTRA_PRIM_ROOT"]
pfx   = os.environ["CALIPTRA_PRIM_MODULE_PREFIX"]
canonical_dut = os.path.join(root, "src/sha512/rtl/sha512.sv")
for line in open(vf):
    line = line.strip()
    if not line or line.startswith("//"):
        continue
    line = (line.replace("${CALIPTRA_ROOT}", root)
                .replace("${CALIPTRA_PRIM_ROOT}", proot)
                .replace("${CALIPTRA_PRIM_MODULE_PREFIX}", pfx))
    # Swap the DUT for the copy under test (identity when not patched).
    if os.path.normpath(line) == os.path.normpath(canonical_dut):
        line = dut
    print(line)
PY

echo "$TB/sha512_bug_033_tb.sv" >> filelist.f

# NOTE on assertion configuration.
#
# CLP_ASSERT_ON is left undefined here. Note that caliptra_prim_assert.sv:114
# defines CALIPTRA_INC_ASSERT unconditionally on any non-Verilator/Synthesis/Yosys
# tool, so some init-time integrator-binding checks may still compile in and
# report on harness structure rather than on DUT behaviour. Any such report is
# not treated as a proof signal: the verdict grep below looks only for TBFAIL and
# PROOF_RESULT, both produced by this testbench's own self-checks.
vcs -full64 -sverilog -timescale=1ns/1ps \
    -assert svaext \
    +lint=none \
    -f filelist.f \
    -top sha512_bug_033_tb \
    -l "$CMP_LOG" -o simv 2>&1 | tail -20

./simv -l "$SIM_LOG" 2>&1 | tail -60

# ---- verdicts ----
if grep -q 'TBFAIL' "$SIM_LOG"; then
  echo "SIM RESULT: FAIL (self-check tripped)" | tee -a "$SIM_LOG"
  exit 1
fi
if ! grep -q 'PROOF_RESULT: PASS' "$SIM_LOG"; then
  echo "SIM RESULT: FAIL (no PASS verdict)" | tee -a "$SIM_LOG"
  exit 1
fi

grep -E 'cover_|BUG-033 OBSERVED|OBSERVED:' "$SIM_LOG" || true
echo "SIM RESULT: PASS"
