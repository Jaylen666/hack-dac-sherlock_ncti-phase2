#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# BUG-011 negative control (non-vacuity).
#
# Applies the mitigation this submission proposes to a scratch copy of
# doe_fsm.sv and re-runs the identical witness testbench against it. The
# audited checkout is never modified.
#
# The mitigation keeps only the flow-specific release terms and drops the
# (init_done && kv_doe_fsm_ps != DOE_IDLE) disjunct, so the extended hold stays
# asserted until a de-obfuscation command is actually issued, which is what the
# module's own comment at doe_fsm.sv:115-118 describes.
#
# Expected outcome: the witness testbench FAILS. The pulse-case latency rises
# above the cold-start reference, so the witness no longer reproduces and the
# testbench's PASS predicate is not met. A tb that still passed here would mean
# it was not measuring the defect at all.
set -euo pipefail

CMP="${CMP:-/home/smy/hackatdac26-phase-2-caliptra}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE="$(cd "$HERE/../.." && pwd)"
LOGS="$CASE/proof/logs"

mkdir -p "$LOGS"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/bug011_nc.XXXXXX")"
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT

PATCHED="$SCRATCH/doe_fsm.sv"
cp "$CMP/src/doe/rtl/doe_fsm.sv" "$PATCHED"

python3 - "$PATCHED" <<'PY'
import sys
p = sys.argv[1]
text = open(p).read()

old = ("    else if ((running_uds || running_fe || running_hek) || "
       "(init_done && (kv_doe_fsm_ps != DOE_IDLE))) begin\n")
new = ("    else if (running_uds || running_fe || running_hek) begin\n")

assert text.count(old) == 1, "release condition not found exactly once"
text = text.replace(old, new)
open(p, "w").write(text)
print("negative control patch applied: release condition is now flow-specific only")
PY

# Show the single line the mitigation changes, read straight out of the scratch
# copy, so the applied edit is recorded without invoking any comparison tool.
{
  echo "== negative control: patched DUT =="
  echo "scratch copy: $PATCHED"
  echo "release condition as patched:"
  grep -n "running_uds || running_fe || running_hek" "$PATCHED"
} | tee "$LOGS/negative_control.log"

set +e
DUT_DOE_FSM="$PATCHED" "$HERE/run_bug_011_sim.sh" >"$SCRATCH/nc_run.txt" 2>&1
RC=$?
set -e
cat "$SCRATCH/nc_run.txt" | tee -a "$LOGS/negative_control.log"

NC_WITNESS_PULSE=$(grep -c "WITNESS pulse_hold_released_early" "$SCRATCH/nc_run.txt" || true)
NC_WITNESS_LEVEL=$(grep -c "WITNESS level_hold_still_effective" "$SCRATCH/nc_run.txt" || true)
NC_DELAYED=$(grep -c "CHECK_PASS witness_next_cmd_delayed_by_extended_hold" "$SCRATCH/nc_run.txt" || true)
NC_CONTAIN=$(grep -c "CHECK_PASS containment_no_kv_write_after_zeroize" "$SCRATCH/nc_run.txt" || true)
NC_TIMEOUT=$(grep -c "TBFAIL global timeout" "$SCRATCH/nc_run.txt" || true)

FAILED=0
chk() { # chk <desc> <actual> <expected>
  if [ "$2" = "$3" ]; then echo "nc_ok   $1 ($2)"; else echo "nc_fail $1 (got $2, want $3)"; FAILED=1; fi
}

{
  echo "== negative control assertions =="
  chk "witness testbench no longer passes"        "$RC"                "1"
  chk "pulse-hold witness no longer reproduces"   "$NC_WITNESS_PULSE"  "0"
  chk "level-hold behaviour unchanged"            "$NC_WITNESS_LEVEL"  "1"
  chk "next command is now delayed by the hold"   "$NC_DELAYED"        "1"
  chk "containment still holds after the fix"     "$NC_CONTAIN"        "1"
  chk "no simulation timeout"                     "$NC_TIMEOUT"        "0"
} | tee -a "$LOGS/negative_control.log"

if [ "$FAILED" -ne 0 ]; then
  echo "NEGATIVE_CONTROL: FAIL" | tee -a "$LOGS/negative_control.log"
  exit 1
fi
echo "NEGATIVE_CONTROL: PASS" | tee -a "$LOGS/negative_control.log"
