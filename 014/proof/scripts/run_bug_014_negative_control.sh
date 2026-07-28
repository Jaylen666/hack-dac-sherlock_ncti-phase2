#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# BUG-014 negative control.
#
# Proves the witness is not vacuous: apply a remediation to a scratch copy of
# hmac.sv and require the *unmodified* testbench to stop reporting one of the two
# gaps it currently reports. The audited tree is never written.
#
# A complete remediation restores the finalization protocol across the register
# block, the wrapper, the core FSM and the DRBG call chain, which is far more
# than a single-site edit. The control therefore applies only the reporting half
# of it: un-tie the illegal-command status at hmac.sv:428 and drive it from a
# locally derivable condition, namely a finalization request standing while
# neither INIT nor NEXT is asserted.
#
#   error2_sts.hwset = 1'b0; // TODO
#   ->
#   error2_sts.hwset = hwif_out.HMAC512_CTRL.Reserved.value & ~(init_reg | next_reg);
#
# That is enough to discriminate, because it is exactly the observation the
# audited tree cannot make: group 5 of the structural audit shows both driven
# error paths conjoin the KeyVault sideload, so no register-programmed command
# can raise anything at all.
#
# Expected outcome: witness_finalization_command_is_rejected_as_illegal now
# passes, witness_finalization_command_starts_no_operation still fails (this
# control adds reporting, not finalization), the controls are untouched, and the
# testbench's PASS predicate, which requires both gaps to be present, is not met.
# That is a NEGATIVE_CONTROL: PASS.
set -euo pipefail

CMP="${CMP:-/home/smy/hackatdac26-phase-2-caliptra}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE="$(cd "$HERE/../.." && pwd)"
LOGS="$CASE/proof/logs"
mkdir -p "$LOGS"

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/bug014_nc.XXXXXX")"
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT

PATCHED="$SCRATCH/hmac.sv"
cp "$CMP/src/hmac/rtl/hmac.sv" "$PATCHED"

# Rewrite only the error2_sts tie-off. Anchored on the exact assignment text,
# including its TODO, so the sibling error3_sts tie cannot be caught by accident.
python3 - "$PATCHED" <<'PY'
import sys
p = sys.argv[1]
src = open(p).read()
old = ("assign hwif_in.intr_block_rf.error_internal_intr_r.error2_sts.hwset = "
       "1'b0; // TODO")
new = ("assign hwif_in.intr_block_rf.error_internal_intr_r.error2_sts.hwset = "
       "hwif_out.HMAC512_CTRL.Reserved.value & ~(init_reg | next_reg);")
n = src.count(old)
if n != 1:
    sys.exit("expected exactly 1 error2_sts tie-off site, found %d" % n)
open(p, "w").write(src.replace(old, new))
print("negative_control_rewrites=%d" % n)
PY

echo "-- remediation applied to scratch copy --" | tee "$LOGS/negative_control.log"
grep -n 'error2_sts.hwset\|error3_sts.hwset' "$PATCHED" | tee -a "$LOGS/negative_control.log"

# Confirm the audited tree is untouched.
if ! grep -q "error2_sts.hwset = 1'b0; // TODO" "$CMP/src/hmac/rtl/hmac.sv"; then
  echo "NEGATIVE_CONTROL: FAIL audited tree was modified" | tee -a "$LOGS/negative_control.log"
  exit 1
fi

set +e
DUT_HMAC_SV="$PATCHED" bash "$HERE/run_bug_014_sim.sh" >"$SCRATCH/nc_sim.out" 2>&1
NC_RC=$?
set -e

{
  echo "-- witness output under the remediated copy --"
  grep -E "CHECK_|WITNESS |COV |SUMMARY |PROOF_RESULT" "$SCRATCH/nc_sim.out" || true
  echo "sim_exit_rc=$NC_RC"
} | tee -a "$LOGS/negative_control.log"

if grep -q "COMPILE FAILED" "$SCRATCH/nc_sim.out"; then
  echo "NEGATIVE_CONTROL: FAIL remediated copy did not elaborate" \
    | tee -a "$LOGS/negative_control.log"
  exit 1
fi

# The control is only meaningful if the remediation actually produced the missing
# rejection. Assert that positively, on the check's own name, rather than only
# observing that the verdict flipped.
if ! grep -q "CHECK_PASS witness_finalization_command_is_rejected_as_illegal" \
     "$SCRATCH/nc_sim.out"; then
  echo "NEGATIVE_CONTROL: FAIL the finalization command was still not reported as illegal" \
    | tee -a "$LOGS/negative_control.log"
  exit 1
fi

# The normal command path must still work. If the remediation raised an error on
# ordinary traffic it would be a regression, not a fix, and would prove nothing.
if ! grep -q "CHECK_PASS control_init_command_completes" "$SCRATCH/nc_sim.out"; then
  echo "NEGATIVE_CONTROL: FAIL remediation broke the ordinary INIT command" \
    | tee -a "$LOGS/negative_control.log"
  exit 1
fi
if ! grep -q "CHECK_PASS control_init_produces_a_tag" "$SCRATCH/nc_sim.out"; then
  echo "NEGATIVE_CONTROL: FAIL remediation suppressed the ordinary INIT result" \
    | tee -a "$LOGS/negative_control.log"
  exit 1
fi

# The remaining gap must still be reported: this control restores reporting only,
# so finalization itself is still not performed. If that check also flipped, the
# testbench would not be measuring what it claims to measure.
if ! grep -q "WITNESS witness_finalization_command_starts_no_operation" \
     "$SCRATCH/nc_sim.out"; then
  echo "NEGATIVE_CONTROL: FAIL reporting-only remediation unexpectedly started an operation" \
    | tee -a "$LOGS/negative_control.log"
  exit 1
fi

if grep -q "PROOF_RESULT: PASS" "$SCRATCH/nc_sim.out"; then
  echo "NEGATIVE_CONTROL: FAIL witness still reports both gaps after remediation" \
    | tee -a "$LOGS/negative_control.log"
  exit 1
fi

echo "NEGATIVE_CONTROL: PASS" | tee -a "$LOGS/negative_control.log"
echo "The illegal-command witness depends on the error2_sts tie-off at hmac.sv:428, not on the testbench setup." \
  | tee -a "$LOGS/negative_control.log"
