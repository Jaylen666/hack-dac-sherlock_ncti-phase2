#!/usr/bin/env bash
# BUG-009 directed simulation: unit-level csrng_state_db driven only through its ports.
#
# Loads a distinct internal state into each of the four applications, then reads the
# software dump window under three authorization masks and reports which application's
# DRBG key each mask actually exposes.
#
# Uses the project's own filelist (src/csrng/config/csrng.vf) rather than a
# hand-curated closure, so the compile matches how the audited tree builds the block.
set -euo pipefail

CMP="${CMP_ROOT:-/home/smy/hackatdac26-phase-2-caliptra}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TB="$(cd "$HERE/../tb" && pwd)"
LOGS="$(cd "$HERE/../logs" && pwd)"
BUILD="$LOGS/../build"

# Allow the negative control to point the compile at a patched copy of the DUT.
DUT_CSRNG_STATE_DB="${DUT_CSRNG_STATE_DB:-$CMP/src/csrng/rtl/csrng_state_db.sv}"
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
python3 - "$CMP/src/csrng/config/csrng.vf" "$DUT_CSRNG_STATE_DB" > filelist.f <<'PY'
import os, sys
vf, dut = sys.argv[1], sys.argv[2]
root  = os.environ["CALIPTRA_ROOT"]
proot = os.environ["CALIPTRA_PRIM_ROOT"]
pfx   = os.environ["CALIPTRA_PRIM_MODULE_PREFIX"]
canonical_dut = os.path.join(root, "src/csrng/rtl/csrng_state_db.sv")
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

echo "$TB/csrng_state_db_bug_009_tb.sv" >> filelist.f

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
    -top csrng_state_db_bug_009_tb \
    -l "$CMP_LOG" -o simv 2>&1 | tail -20

./simv -l "$SIM_LOG" 2>&1 | tail -60

# ---- verdicts ----
if grep -q 'TBFAIL global timeout' "$SIM_LOG"; then
  echo "SIM RESULT: FAIL (harness timeout)" | tee -a "$SIM_LOG"
  rm -rf "$BUILD"
  exit 1
fi
if ! grep -q 'PROOF_RESULT: PASS' "$SIM_LOG"; then
  echo "SIM RESULT: FAIL (no PASS verdict)" | tee -a "$SIM_LOG"
  rm -rf "$BUILD"
  exit 1
fi

grep -E 'cov_|OBSERVED:' "$SIM_LOG" || true
echo "SIM RESULT: PASS"

# Leave no build tree behind; the logs are the artifact.
rm -rf "$BUILD"
