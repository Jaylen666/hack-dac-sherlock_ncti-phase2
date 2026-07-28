#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# BUG-011 witness simulation. Elaborates one doe_fsm inside the project's own
# doe_ctrl filelist and runs the port-driven witness testbench.
#
# Single tree, single DUT. The testbench drives ports only: no force, no
# deposit, no hierarchical assignment into the DUT.
#
# DUT_DOE_FSM lets the negative control substitute a patched scratch copy of
# doe_fsm.sv. Unset, it resolves to the in-tree file, so this script is the
# unmodified-tree run.
set -euo pipefail

CMP="${CMP:-/home/smy/hackatdac26-phase-2-caliptra}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE="$(cd "$HERE/../.." && pwd)"
LOGS="$CASE/proof/logs"
TB="$CASE/proof/tb/doe_fsm_bug_011_tb.sv"

DUT_DOE_FSM="${DUT_DOE_FSM:-$CMP/src/doe/rtl/doe_fsm.sv}"

export CALIPTRA_ROOT="$CMP"
export CALIPTRA_PRIM_ROOT="$CMP/src/caliptra_prim_generic"
export CALIPTRA_PRIM_MODULE_PREFIX="caliptra_prim_generic"

export PATH="/data0/tools/Synopsys/vcs/vcs/W-2024.09-SP1/bin:$PATH"
export VCS_HOME="/data0/tools/Synopsys/vcs/vcs/W-2024.09-SP1"

mkdir -p "$LOGS"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/bug011_sim.XXXXXX")"
cleanup() { rm -rf "$BUILD"; }
trap cleanup EXIT

FLIST="$BUILD/doe_ctrl.expanded.vf"

# Expand the project's own filelist. Two documented adjustments, neither of
# which changes the set of files compiled or their contents:
#
#  1. doe_ctrl.vf ships no +incdir for the generated register headers, but
#     files reachable from it include caliptra_reg_field_defines.svh. Other
#     in-tree filelists (src/axi/config/axi_dma.vf) carry that include path, so
#     it is appended here.
#  2. The list places some modules ahead of the packages they import. VCS needs
#     packages analyzed first, so the expanded list is emitted as
#     incdirs, then *_pkg.sv, then everything else. Order only.
python3 - "$CMP/src/doe/config/doe_ctrl.vf" "$FLIST" "$CMP" "$DUT_DOE_FSM" <<'PY'
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
    if os.path.basename(line) == "doe_fsm.sv":
        line = dut_fsm
    (pkgs if line.endswith("_pkg.sv") else rest).append(line)

incdirs.append("+incdir+" + os.path.join(cmp_root, "src/integration/rtl/caliptra_reg"))

with open(out, "w") as f:
    for line in incdirs + pkgs + rest:
        f.write(line + "\n")
PY

echo "DUT_DOE_FSM=$DUT_DOE_FSM" | tee "$LOGS/dut_selection.log"

cd "$BUILD"
set +e
vcs -full64 -sverilog -timescale=1ns/1ps \
    -f "$FLIST" "$TB" \
    -top doe_fsm_bug_011_tb \
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
  echo "BUG-011 witness: PASS"
  exit 0
fi
echo "BUG-011 witness: FAIL (sim rc=$SRC_RC)"
exit 1
