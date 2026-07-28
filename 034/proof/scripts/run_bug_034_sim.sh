#!/usr/bin/env bash
# BUG-034 witness simulation: drive one unmodified sha512_masked_core over its
# module ports and sample the digest port on every invalid cycle.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROOF="$(cd "$HERE/.." && pwd)"
CMP="${CMP:-$(cd "$PROOF/../../.." && pwd)}"
LOGS="$PROOF/logs"
TB="${TB:-$PROOF/tb/sha512_masked_bug_034_tb.sv}"
mkdir -p "$LOGS"

export CALIPTRA_ROOT="${CALIPTRA_ROOT:-$CMP}"
export CALIPTRA_PRIM_ROOT="${CALIPTRA_PRIM_ROOT:-$CMP/src/caliptra_prim_generic}"
export CALIPTRA_PRIM_MODULE_PREFIX="${CALIPTRA_PRIM_MODULE_PREFIX:-caliptra_prim_generic}"

if [ -z "${VCS_HOME:-}" ] && [ -d /data0/tools/Synopsys/vcs/vcs/W-2024.09-SP1 ]; then
  export VCS_HOME=/data0/tools/Synopsys/vcs/vcs/W-2024.09-SP1
fi
[ -n "${VCS_HOME:-}" ] && export PATH="$VCS_HOME/bin:$PATH"

# The DUT source may be overridden so the negative control can elaborate a
# patched scratch copy through this same script.
DUT_CORE="${DUT_CORE_SV:-$CMP/src/sha512_masked/rtl/sha512_masked_core.sv}"

{
  echo "dut_core=$DUT_CORE"
  echo "tb=$TB"
  echo "caliptra_root=$CALIPTRA_ROOT"
} >"$LOGS/dut_selection.log"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FL="$WORK/files.f"

# Minimal closure for sha512_masked_core: its own package, the two shared
# constant tables from sha512, and the masked w_mem. The DUT source itself is
# listed from DUT_CORE rather than from the tree, so the override takes effect.
{
  echo "+incdir+$CALIPTRA_ROOT/src/sha512/rtl"
  echo "+incdir+$CALIPTRA_ROOT/src/sha512_masked/rtl"
  echo "+incdir+$CALIPTRA_ROOT/src/libs/rtl"
  echo "$CALIPTRA_ROOT/src/sha512_masked/rtl/sha512_masked_defines_pkg.sv"
  echo "$CALIPTRA_ROOT/src/sha512/rtl/sha512_k_constants.v"
  echo "$CALIPTRA_ROOT/src/sha512/rtl/sha512_h_constants.v"
  echo "$CALIPTRA_ROOT/src/sha512_masked/rtl/sha512_masked_w_mem.sv"
  echo "$DUT_CORE"
  echo "$TB"
} >"$FL"

cd "$WORK"
vcs -full64 -sverilog -timescale=1ns/1ps \
    -f "$FL" -top sha512_masked_bug_034_tb \
    +define+CALIPTRA_MODE_SUBSYSTEM \
    -o "$WORK/simv" >"$LOGS/compile.log" 2>&1
rc=$?
if [ $rc -ne 0 ]; then
  echo "COMPILE FAILED (see logs/compile.log)"
  tail -30 "$LOGS/compile.log"
  exit 1
fi

"$WORK/simv" >"$LOGS/run.log" 2>&1
grep -E 'PROOF:|CHECK_|WITNESS|SUMMARY|TRACE|result=|PROOF_RESULT' \
  "$LOGS/run.log" >"$LOGS/witness.log" || true
cat "$LOGS/witness.log"

if grep -q 'TBFAIL global timeout' "$LOGS/run.log"; then
  echo "SIM: watchdog timeout"
  exit 1
fi
if grep -q 'PROOF_RESULT: PASS' "$LOGS/run.log"; then
  exit 0
fi
exit 1
