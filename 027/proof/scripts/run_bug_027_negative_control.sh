#!/usr/bin/env bash
# BUG-027 negative control.
#
# The audited rule ANDs the "non-AES writes to the release slot" check with a
# forwarding-source term. This control removes that one AND-term in a scratch
# copy, which is the fix the submission proposes, and requires the identical
# testbench to stop observing the defect. If the witness still fired, the
# testbench would not be measuring the term under audit.
#
# The patch is generated inline below from the audited file itself. No external
# repository, reference revision, or expected-answer list is consulted anywhere.
set -euo pipefail

CMP="${CMP_ROOT:-/home/smy/hackatdac26-phase-2-caliptra}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS="$(cd "$HERE/../logs" && pwd)"
SCRATCH="$HERE/../scratch"
mkdir -p "$SCRATCH"
SCRATCH="$(cd "$SCRATCH" && pwd)"
NC_LOG="$LOGS/negative_control.log"

SRC="$CMP/src/keyvault/rtl/kv_write_rule_check.sv"
PATCHED="$SCRATCH/kv_write_rule_check.sv"

: > "$NC_LOG"
{
  echo "===== BUG-027 negative control ====="
  echo "source DUT : $SRC"
  echo "patched DUT: $PATCHED"
} | tee -a "$NC_LOG"

python3 - "$SRC" "$PATCHED" <<'PY' | tee -a "$NC_LOG"
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()

old = """        rule_fail.aes_only_to_key_release =
            write_metrics.ocp_lock_in_progress &&
            |non_aes_src_active                &&
            dst_is_release_slot                &&
            release_slot_source_from_raw;"""
new = """        rule_fail.aes_only_to_key_release =
            write_metrics.ocp_lock_in_progress &&
            |non_aes_src_active                &&
            dst_is_release_slot;"""
assert text.count(old) == 1, "expected exactly one aes_only_to_key_release assignment"
text = text.replace(old, new, 1)
open(dst, "w").write(text)
print("patch applied: aes_only_to_key_release no longer gated on the forwarding-source term")
PY

set +e
DUT_RULE_CHECK="$PATCHED" \
SIM_LOG="$LOGS/negative_control_sim.log" \
CMP_LOG="$LOGS/negative_control_compile.log" \
  "$HERE/run_bug_027_sim.sh" > "$LOGS/negative_control_stdout.log" 2>&1
RC=$?
set -e

NCSIM="$LOGS/negative_control_sim.log"
TBFAIL_TOTAL=$(grep -c 'TBFAIL' "$NCSIM" || true)
ALLOWED=$(grep -oE 'cover_non_aes_release_allowed=[0-9]+' "$NCSIM" | tail -1 | cut -d= -f2)
BLOCKED=$(grep -oE 'cover_non_aes_release_blocked=[0-9]+' "$NCSIM" | tail -1 | cut -d= -f2)
AES_OK=$(grep -c 'case=control_aes_release_legal PASS' "$NCSIM" || true)
WITNESS=$(grep -c 'BUG_027_WITNESS_OBSERVED' "$NCSIM" || true)

VALID=1
{
  echo ""
  echo "----- negative control results -----"
  printf 'sim exit code                      : %s (nonzero expected)\n' "$RC"
  printf 'BUG_027 witness lines              : %s (must be 0)\n' "$WITNESS"
  printf 'cover_non_aes_release_allowed      : %s (must be 0)\n' "$ALLOWED"
  printf 'cover_non_aes_release_blocked      : %s (must stay 2)\n' "$BLOCKED"
  printf 'control_aes_release_legal still ok : %s (must be 1)\n' "$AES_OK"
  printf 'TBFAIL lines total                 : %s\n' "$TBFAIL_TOTAL"
} | tee -a "$NC_LOG"

[ "$RC" -ne 0 ]        || { echo "INVALID: patched RTL still produced a PASS verdict" | tee -a "$NC_LOG"; VALID=0; }
[ "$WITNESS" = "0" ]   || { echo "INVALID: patched RTL still allowed the write" | tee -a "$NC_LOG"; VALID=0; }
[ "$ALLOWED" = "0" ]   || { echo "INVALID: defect cover did not fall to 0" | tee -a "$NC_LOG"; VALID=0; }
[ "$BLOCKED" = "2" ]   || { echo "INVALID: control cover changed, harness is not stable" | tee -a "$NC_LOG"; VALID=0; }
[ "$AES_OK" = "1" ]    || { echo "INVALID: the legal AES write stopped being allowed" | tee -a "$NC_LOG"; VALID=0; }

{
  echo ""
  if [ "$VALID" = "1" ]; then
    echo "CONCLUSION: On the audited RTL a non-AES engine writing the key release slot"
    echo "under OCP lock is allowed whenever the write carries a KeyVault-forwarded"
    echo "source. With the single forwarding AND-term removed in a scratch copy, the"
    echo "same stimulus is rejected, the defect cover falls to 0 and the witness stops"
    echo "firing, while the legal AES release write is still allowed and the harness's"
    echo "own blocked-case observations are unchanged. The observation is a property of"
    echo "the audited RTL, not of the testbench."
    echo "NEGATIVE CONTROL: PASS"
  else
    echo "NEGATIVE CONTROL: FAIL"
  fi
} | tee -a "$NC_LOG"

rm -rf "$HERE/../build"

[ "$VALID" = "1" ]
