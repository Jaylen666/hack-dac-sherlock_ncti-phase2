#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# BUG-002 negative control.
#
# Proves the witness is not vacuous: apply the proposed remediation to a scratch
# copy of aes.sv and require the *unmodified* testbench to stop reporting the
# exposure. The audited tree is never written.
#
# The remediation adds the missing KeyVault term to the mask arming expression at
# aes.sv:197, so concealment engages when the result is routed to the KeyVault as
# well as when block_reg_output is asserted:
#
#   hw2reg_data_out_mask_en <= ~caliptra2aes.block_reg_output;
#   ->
#   hw2reg_data_out_mask_en <= ~(caliptra2aes.block_reg_output | caliptra2aes.kv_en);
#
# Expected outcome: the KeyVault-routed run's DATA_OUT reads zero, the invariant
# check that currently fails now passes, the witness no longer fires, and the
# testbench's PASS predicate (which requires the exposure to be present) is not
# met. That is a NEGATIVE_CONTROL: PASS.
set -euo pipefail

CMP="${CMP:-/home/smy/hackatdac26-phase-2-caliptra}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE="$(cd "$HERE/../.." && pwd)"
LOGS="$CASE/proof/logs"
mkdir -p "$LOGS"

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/bug002_nc.XXXXXX")"
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT

PATCHED="$SCRATCH/aes.sv"
cp "$CMP/src/aes/rtl/aes.sv" "$PATCHED"

# Rewrite only the mask arming assignment. Anchored on the exact expression text
# so nothing else in the file can be caught by accident.
python3 - "$PATCHED" <<'PY'
import sys
p = sys.argv[1]
src = open(p).read()
old = "hw2reg_data_out_mask_en <= ~caliptra2aes.block_reg_output;"
new = "hw2reg_data_out_mask_en <= ~(caliptra2aes.block_reg_output | caliptra2aes.kv_en);"
n = src.count(old)
if n != 1:
    sys.exit("expected exactly 1 arming site, found %d" % n)
open(p, "w").write(src.replace(old, new))
print("negative_control_rewrites=%d" % n)
PY

echo "-- remediation applied to scratch copy --" | tee "$LOGS/negative_control.log"
grep -n 'hw2reg_data_out_mask_en <= ~' "$PATCHED" | tee -a "$LOGS/negative_control.log"

# Confirm the audited tree is untouched.
if ! grep -q 'hw2reg_data_out_mask_en <= ~caliptra2aes.block_reg_output;' \
     "$CMP/src/aes/rtl/aes.sv"; then
  echo "NEGATIVE_CONTROL: FAIL audited tree was modified" | tee -a "$LOGS/negative_control.log"
  exit 1
fi

set +e
DUT_AES_SV="$PATCHED" bash "$HERE/run_bug_002_sim.sh" >"$SCRATCH/nc_sim.out" 2>&1
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

# The control is only meaningful if the remediation actually concealed the
# KeyVault-routed readback. Assert that positively, not just that the verdict
# flipped: the invariant check must now pass on its own name.
if ! grep -q "CHECK_PASS witness_kv_routed_output_is_concealed" "$SCRATCH/nc_sim.out"; then
  echo "NEGATIVE_CONTROL: FAIL kv-routed readback was not concealed by the remediation" \
    | tee -a "$LOGS/negative_control.log"
  exit 1
fi

# The plain control must still work. If the remediation concealed everything then
# it would be a regression, not a fix, and the control would prove nothing.
if ! grep -q "CHECK_PASS control_plain_output_is_readable" "$SCRATCH/nc_sim.out"; then
  echo "NEGATIVE_CONTROL: FAIL remediation also concealed the plain, non-routed result" \
    | tee -a "$LOGS/negative_control.log"
  exit 1
fi

if grep -q "PROOF_RESULT: PASS" "$SCRATCH/nc_sim.out"; then
  echo "NEGATIVE_CONTROL: FAIL witness still reports the exposure after remediation" \
    | tee -a "$LOGS/negative_control.log"
  exit 1
fi

echo "NEGATIVE_CONTROL: PASS" | tee -a "$LOGS/negative_control.log"
echo "The witness depends on the missing kv_en term in the mask arming expression, not on the testbench setup." \
  | tee -a "$LOGS/negative_control.log"
