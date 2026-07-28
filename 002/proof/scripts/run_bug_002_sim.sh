#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# BUG-002 witness simulation. Elaborates one whole aes block from the project's
# own aes filelist and runs the register-bus witness testbench, which performs
# complete AES-128 ECB encryptions under three routing configurations.
#
# Single tree, single DUT. The testbench drives ports only: no force, no
# deposit, no hierarchical assignment into the DUT. The register interface is
# TileLink Uncached Lightweight, so the testbench implements the A/D channel
# handshake rather than a simple chip-select bus.
#
# DUT_AES_SV lets the negative control substitute a patched scratch copy of
# aes.sv. Unset, it resolves to the in-tree file, so this script is the
# unmodified-tree run.
set -euo pipefail

CMP="${CMP:-/home/smy/hackatdac26-phase-2-caliptra}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE="$(cd "$HERE/../.." && pwd)"
LOGS="$CASE/proof/logs"
TB="$CASE/proof/tb/aes_bug_002_tb.sv"

DUT_AES_SV="${DUT_AES_SV:-$CMP/src/aes/rtl/aes.sv}"

export CALIPTRA_ROOT="$CMP"
export CALIPTRA_PRIM_ROOT="$CMP/src/caliptra_prim_generic"
export CALIPTRA_PRIM_MODULE_PREFIX="caliptra_prim_generic"

export PATH="/data0/tools/Synopsys/vcs/vcs/W-2024.09-SP1/bin:$PATH"
export VCS_HOME="/data0/tools/Synopsys/vcs/vcs/W-2024.09-SP1"

mkdir -p "$LOGS"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/bug002_sim.XXXXXX")"
cleanup() { rm -rf "$BUILD"; }
trap cleanup EXIT

FLIST="$BUILD/aes.expanded.vf"

# Expand the project's own filelist. Two documented adjustments, neither of
# which changes the set of files compiled or their contents:
#
#  1. aes.vf ships no +incdir for the generated register headers, but
#     aes_clp_wrapper.sv, reachable from that list, includes
#     caliptra_reg_field_defines.svh. Other in-tree filelists
#     (src/axi/config/axi_dma.vf) carry that include path, so it is appended here.
#  2. The list places some modules ahead of the packages they import. VCS needs
#     packages analyzed first, so the expanded list is emitted as incdirs, then
#     *_pkg.sv, then everything else. Order only.
python3 - "$CMP/src/aes/config/aes.vf" "$FLIST" "$CMP" "$DUT_AES_SV" <<'PY'
import os, sys
src, out, cmp_root, dut = sys.argv[1:5]
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
    if os.path.basename(line) == "aes.sv":
        line = dut
    (pkgs if line.endswith("_pkg.sv") else rest).append(line)

incdirs.append("+incdir+" + os.path.join(cmp_root, "src/integration/rtl/caliptra_reg"))

with open(out, "w") as f:
    for line in incdirs + pkgs + rest:
        f.write(line + "\n")
PY

echo "DUT_AES_SV=$DUT_AES_SV" | tee "$LOGS/dut_selection.log"

cd "$BUILD"
set +e
vcs -full64 -sverilog -timescale=1ns/1ps \
    -f "$FLIST" "$TB" \
    -top aes_bug_002_tb \
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
  echo "BUG-002 witness: PASS"
  exit 0
fi
echo "BUG-002 witness: FAIL (sim rc=$SRC_RC)"
exit 1
