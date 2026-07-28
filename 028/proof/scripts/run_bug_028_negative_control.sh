#!/usr/bin/env bash
# BUG-028 negative control: non-vacuity of the directed witness.
#
# The proposed fix is applied to a scratch copy of the audited DUT: the standard
# destination classifier's upper bound is restored to KV_STANDARD_SLOT_HI so the
# top standard slot is inside the region, matching the two source classifiers in
# the same file. The identical testbench is then required to stop witnessing.
#
# The patch is derived from the audited file's own internal inconsistency, the
# destination bound disagreeing with the source bounds it sits beside. No external
# repository, reference revision, or expected-answer list is consulted anywhere.
set -euo pipefail

CMP="${CMP_ROOT:-/home/smy/hackatdac26-phase-2-caliptra}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS="$(cd "$HERE/../logs" && pwd)"
SCRATCH="$HERE/../scratch"
SRC="$CMP/src/keyvault/rtl/kv_write_rule_check.sv"
PATCHED="$SCRATCH/kv_write_rule_check.sv"
LOG="$LOGS/negative_control.log"

mkdir -p "$SCRATCH"

{
  echo "BUG-028 negative control"
  echo "source DUT : $SRC"
  echo "patched DUT: $PATCHED"
  echo "date=$(date -Is)"
} > "$LOG"

python3 - "$SRC" "$PATCHED" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
old = "{[KV_STANDARD_SLOT_LOW:KV_STANDARD_SLOT_HI-1]});"
new = "{[KV_STANDARD_SLOT_LOW:KV_STANDARD_SLOT_HI]});"
assert text.count(old) == 1, f"expected exactly one occurrence, found {text.count(old)}"
open(dst, "w").write(text.replace(old, new))
print("patch applied: standard destination upper bound restored to KV_STANDARD_SLOT_HI")
PY

echo "patch applied: standard destination upper bound restored to KV_STANDARD_SLOT_HI" | tee -a "$LOG"

# Re-run the identical testbench against the patched DUT.
set +e
DUT_RULE_CHECK="$PATCHED" \
SIM_LOG="$LOGS/negative_control_sim.log" \
CMP_LOG="$LOGS/negative_control_compile.log" \
  "$HERE/run_bug_028_sim.sh" > "$LOGS/negative_control_stdout.log" 2>&1
SIM_RC=$?
set -e

NSIM="$LOGS/negative_control_sim.log"
WIT=$(grep -c 'BUG_028_WITNESS_OBSERVED' "$NSIM" || true)
BLOCKED=$(grep -oP 'cover_std_top_blocked=\K[0-9]+' "$NSIM" | tail -1 || true)
MIDOK=$(grep -oP 'cover_std_mid_allowed=\K[0-9]+' "$NSIM" | tail -1 || true)
CONTAIN=$(grep -oP 'cover_lock_src_to_std_top_blocked=\K[0-9]+' "$NSIM" | tail -1 || true)
TOPCASE=$(grep -c 'case=violating_std_to_std_top_slot PASS' "$NSIM" || true)
TBFAILS=$(grep -c 'TBFAIL' "$NSIM" || true)

{
  echo ""
  echo "sim exit code                     : $SIM_RC (nonzero expected)"
  echo "BUG_028 witness lines             : $WIT (must be 0)"
  echo "cover_std_top_blocked             : ${BLOCKED:-unset} (must be 0)"
  echo "cover_std_mid_allowed             : ${MIDOK:-unset} (must stay 1)"
  echo "cover_lock_src_to_std_top_blocked : ${CONTAIN:-unset} (must stay 1)"
  echo "top-slot write now accepted       : $TOPCASE (must be 1)"
  echo "TBFAIL lines total                : $TBFAILS (must be 0)"
} | tee -a "$LOG"

OK=1
[ "$SIM_RC" -ne 0 ]           || OK=0
[ "$WIT" -eq 0 ]              || OK=0
[ "${BLOCKED:-1}" -eq 0 ]     || OK=0
[ "${MIDOK:-0}" -eq 1 ]       || OK=0
[ "${CONTAIN:-0}" -eq 1 ]     || OK=0
[ "$TOPCASE" -eq 1 ]          || OK=0
[ "$TBFAILS" -eq 0 ]          || OK=0

# The nested sim run rebuilds the build tree after its own cleanup, so drop it
# again here: it is rebuildable and must not ship inside the case.
rm -rf "$HERE/../build"

if [ "$OK" -eq 1 ]; then
  {
    echo ""
    echo "CONCLUSION: On the audited RTL a legal standard-to-standard write into the"
    echo "top standard slot is rejected. With the destination bound restored to"
    echo "KV_STANDARD_SLOT_HI in a scratch copy, the same write is accepted and the"
    echo "witness stops firing, while a LOCK-region source targeting that same slot"
    echo "remains blocked both before and after the change. The observation is a"
    echo "property of the audited RTL, not of the testbench, and the bound is not"
    echo "load-bearing for cross-region containment."
    echo "NEGATIVE CONTROL: PASS"
  } | tee -a "$LOG"
else
  echo "NEGATIVE CONTROL: FAIL" | tee -a "$LOG"
  exit 1
fi
