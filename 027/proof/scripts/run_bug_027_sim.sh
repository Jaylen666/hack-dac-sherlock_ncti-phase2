#!/usr/bin/env bash
# BUG-027 directed simulation: unit-level kv_write_rule_check.
#
# Uses the project's own package filelist (src/keyvault/config/kv_defines_pkg.vf)
# so the parameters and the metrics struct come from the audited tree rather than
# from a hand-written copy. Every file is taken verbatim from the tree except the
# DUT, which the negative control may point at a patched scratch copy.
set -euo pipefail

CMP="${CMP_ROOT:-/home/smy/hackatdac26-phase-2-caliptra}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TB="$(cd "$HERE/../tb" && pwd)"
LOGS="$(cd "$HERE/../logs" && pwd)"
BUILD="$HERE/../build"

DUT_RULE_CHECK="${DUT_RULE_CHECK:-$CMP/src/keyvault/rtl/kv_write_rule_check.sv}"
SIM_LOG="${SIM_LOG:-$LOGS/sim.log}"
CMP_LOG="${CMP_LOG:-$LOGS/compile.log}"
TB_FILE="${TB_FILE:-$TB/kv_write_rule_check_bug_027_tb.sv}"
TB_TOP="${TB_TOP:-kv_write_rule_check_bug_027_tb}"

export CALIPTRA_ROOT="$CMP"

command -v vcs >/dev/null 2>&1 || export PATH="/data0/tools/Synopsys/vcs/vcs/W-2024.09-SP1/bin:$PATH"

rm -rf "$BUILD"
mkdir -p "$BUILD"
cd "$BUILD"

python3 - "$CMP/src/keyvault/config/kv_defines_pkg.vf" > filelist.f <<'PY'
import os, sys
root = os.environ["CALIPTRA_ROOT"]
for line in open(sys.argv[1]):
    line = line.strip()
    if not line or line.startswith("//"):
        continue
    line = line.replace("${CALIPTRA_ROOT}", root)
    # kv_macros.svh is an include file, not a compilation unit
    if line.endswith(".svh"):
        continue
    print(line)
PY

echo "$DUT_RULE_CHECK" >> filelist.f
echo "$TB_FILE" >> filelist.f

vcs -full64 -sverilog -timescale=1ns/1ps \
    -assert svaext \
    +lint=none \
    -f filelist.f \
    -top "$TB_TOP" \
    -l "$CMP_LOG" -o simv 2>&1 | tail -20

./simv -l "$SIM_LOG" 2>&1 | tail -60

# ---- verdicts ----
if ! grep -q 'PROOF_RESULT: PASS' "$SIM_LOG"; then
  echo "SIM RESULT: FAIL (no PASS verdict)" | tee -a "$SIM_LOG"
  cd "$HERE"; rm -rf "$BUILD"
  exit 1
fi

grep -E 'case=|cover_|OBSERVED:|checks=' "$SIM_LOG" || true

# Drop the simulator build tree: it is a rebuildable intermediate, and shipping
# it would put compiler-generated absolute paths and a symlink into the case.
cd "$HERE"
rm -rf "$BUILD"

echo "SIM RESULT: PASS"
