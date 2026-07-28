#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# BUG-N-002 witness simulation. Elaborates one sha512 inside the project's own
# sha512_ctrl filelist and runs the bus-driven witness testbench.
#
# Single tree, single DUT. The testbench drives ports only: no force, no
# deposit, no hierarchical assignment into the DUT.
#
# DUT_SHA512 lets the negative control substitute a patched scratch copy of
# sha512.sv. Unset, it resolves to the in-tree file, so this script is the
# unmodified-tree run.
set -euo pipefail

CMP="${CMP:-/home/smy/hackatdac26-phase-2-caliptra}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE="$(cd "$HERE/../.." && pwd)"
LOGS="$CASE/proof/logs"
TB="$CASE/proof/tb/sha512_bug_n002_tb.sv"

DUT_SHA512="${DUT_SHA512:-$CMP/src/sha512/rtl/sha512.sv}"

export CALIPTRA_ROOT="$CMP"
export CALIPTRA_PRIM_ROOT="$CMP/src/caliptra_prim_generic"
export CALIPTRA_PRIM_MODULE_PREFIX="caliptra_prim_generic"

export PATH="/data0/tools/Synopsys/vcs/vcs/W-2024.09-SP1/bin:$PATH"
export VCS_HOME="/data0/tools/Synopsys/vcs/vcs/W-2024.09-SP1"

mkdir -p "$LOGS"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/bugn002_sim.XXXXXX")"
cleanup() { rm -rf "$BUILD"; }
trap cleanup EXIT

FLIST="$BUILD/sha512_ctrl.expanded.vf"

# Expand the project's own filelist. Two documented adjustments, neither of
# which changes the set of files compiled or their contents:
#
#  1. sha512_ctrl.vf ships no +incdir for the generated register headers, but
#     files reachable from it include caliptra_reg_field_defines.svh. Other
#     in-tree filelists (src/axi/config/axi_dma.vf) carry that include path, so
#     it is appended here.
#  2. The list places some modules ahead of the packages they import. VCS needs
#     packages analyzed first, so the expanded list is emitted as
#     incdirs, then *_pkg.sv, then everything else. Order only.
python3 - "$CMP/src/sha512/config/sha512_ctrl.vf" "$FLIST" "$CMP" "$DUT_SHA512" <<'PY'
import os, sys
src, out, cmp_root, dut_fsm = sys.argv[1:5]
env = {
    "CALIPTRA_ROOT": cmp_root,
    "CALIPTRA_PRIM_ROOT": os.path.join(cmp_root, "src/caliptra_prim_generic"),
    "CALIPTRA_PRIM_MODULE_PREFIX": "caliptra_prim_generic",
}
def expand(s):
    for k, v in env.items():
        s = s.replace("${%s}" % k, v)
    return s

incdirs, pkgs, rest = [], [], []
for raw in open(src):
    line = expand(raw.strip())
    if not line or line.startswith("//"):
        continue
    if line.startswith("+incdir+"):
        incdirs.append(line)
        continue
    # Point the DUT at the copy under test (identity for the unmodified run).
    if os.path.basename(line) == "sha512.sv":
        line = dut_fsm
    (pkgs if line.endswith("_pkg.sv") else rest).append(line)

incdirs.append("+incdir+" + os.path.join(cmp_root, "src/integration/rtl/caliptra_reg"))

with open(out, "w") as f:
    for line in incdirs + pkgs + rest:
        f.write(line + "\n")
PY

echo "DUT_SHA512=$DUT_SHA512" | tee "$LOGS/dut_selection.log"

cd "$BUILD"
set +e
vcs -full64 -sverilog -timescale=1ns/1ps \
    -f "$FLIST" "$TB" \
    -top sha512_bug_n002_tb \
    -o "$BUILD/simv" \
    +define+CALIPTRA_MODE_SUBSYSTEM \
    -l "$LOGS/compile.log" >/dev/null 2>&1
CRC=$?
set -e
if [ "$CRC" -ne 0 ]; then
  echo "COMPILE FAILED (rc=$CRC), see $LOGS/compile.log"
  tail -40 "$LOGS/compile.log" || true
  exit "$CRC"
fi

set +e
"$BUILD/simv" -l "$LOGS/run.log" >/dev/null 2>&1
SRC_RC=$?
set -e

# The witness case itself prints TBFAIL-free output; only the watchdog emits a
# TBFAIL line, so grep for the timeout marker specifically.
if grep -q "TBFAIL global timeout" "$LOGS/run.log"; then
  echo "SIM TIMED OUT"
  exit 1
fi

grep -E "CHECK_|WITNESS |COV |SUMMARY |PROOF_RESULT" "$LOGS/run.log" | tee "$LOGS/witness.log"

if grep -q "PROOF_RESULT: PASS" "$LOGS/run.log"; then
  echo "BUG-N-002 witness: PASS"
  exit 0
fi
echo "BUG-N-002 witness: FAIL (sim rc=$SRC_RC)"
exit 1
