#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# BUG-004 negative control.
#
# Proves the witness is not vacuous: apply the proposed remediation to a scratch
# copy of aes_reg_top.sv and require the *unmodified* testbench to stop reporting
# the witness. The audited tree is never written.
#
# The remediation is the file's own idiom for a write-only address, taken from
# addr_hit[0] in the same case statement: drive reg_rdata_next to constant zero
# rather than reading a register path. The sixteen key-share arms are rewritten
# to `reg_rdata_next[31:0] = '0;`.
#
# Expected outcome: the write-only addresses read zero, so the four invariant
# checks pass, the echo discriminator no longer fires, and the testbench's PASS
# predicate (which requires the exposure to be present) is not met. That is a
# NEGATIVE_CONTROL: PASS.
set -euo pipefail

CMP="${CMP:-/home/smy/hackatdac26-phase-2-caliptra}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE="$(cd "$HERE/../.." && pwd)"
LOGS="$CASE/proof/logs"
mkdir -p "$LOGS"

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/bug004_nc.XXXXXX")"
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT

PATCHED="$SCRATCH/aes_reg_top.sv"
cp "$CMP/src/aes/rtl/aes_reg_top.sv" "$PATCHED"

# Rewrite only the sixteen defective arms. Anchored on the exact assignment text
# so nothing else in the file can be caught by accident.
python3 - "$PATCHED" <<'PY'
import re, sys
p = sys.argv[1]
src = open(p).read()
pat = re.compile(r"(reg_rdata_next\[31:0\] = )reg2hw\.key_share[01]\[[0-7]\]\.q;")
src, n = pat.subn(r"\1'0;", src)
if n != 16:
    sys.exit("expected 16 rewrites, made %d" % n)
open(p, "w").write(src)
print("negative_control_rewrites=%d" % n)
PY

echo "-- remediation applied to scratch copy --" | tee "$LOGS/negative_control.log"
diff_count="$(grep -cE "reg_rdata_next\[31:0\] = '0;" "$PATCHED")"
echo "arms_now_constant_zero=$diff_count" | tee -a "$LOGS/negative_control.log"

# Confirm the audited tree is untouched.
if ! grep -qE 'reg_rdata_next\[31:0\] = reg2hw\.key_share0\[0\]\.q;' "$CMP/src/aes/rtl/aes_reg_top.sv"; then
  echo "NEGATIVE_CONTROL: FAIL audited tree was modified" | tee -a "$LOGS/negative_control.log"
  exit 1
fi

set +e
DUT_AES_REG_TOP="$PATCHED" bash "$HERE/run_bug_004_sim.sh" >"$SCRATCH/nc_sim.out" 2>&1
NC_RC=$?
set -e

{
  echo "-- witness output under the remediated copy --"
  grep -E "CHECK_|WITNESS |COV |SUMMARY |PROOF_RESULT" "$SCRATCH/nc_sim.out" || true
  echo "sim_exit_rc=$NC_RC"
} | tee -a "$LOGS/negative_control.log"

if grep -q "COMPILE FAILED" "$SCRATCH/nc_sim.out"; then
  echo "NEGATIVE_CONTROL: FAIL remediated copy did not elaborate" | tee -a "$LOGS/negative_control.log"
  exit 1
fi

# The control is only meaningful if the remediation actually moved the readback
# to zero. Assert that positively, not just that the verdict flipped.
if ! grep -qE "COV s0_0=0x00000000" "$SCRATCH/nc_sim.out"; then
  echo "NEGATIVE_CONTROL: FAIL readback did not become zero under the remediation" \
    | tee -a "$LOGS/negative_control.log"
  exit 1
fi

if grep -q "PROOF_RESULT: PASS" "$SCRATCH/nc_sim.out"; then
  echo "NEGATIVE_CONTROL: FAIL witness still reports the exposure after remediation" \
    | tee -a "$LOGS/negative_control.log"
  exit 1
fi

echo "NEGATIVE_CONTROL: PASS" | tee -a "$LOGS/negative_control.log"
echo "The witness depends on the defective read arms, not on the testbench setup." \
  | tee -a "$LOGS/negative_control.log"
