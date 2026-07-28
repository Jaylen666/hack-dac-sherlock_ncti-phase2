#!/usr/bin/env bash
# BUG-031 negative control (non-vacuity proof).
#
# Applies the author's own proposed fix to a scratch copy of the DUT and re-runs the
# IDENTICAL testbench. The proof is only meaningful if the harness stops reporting the
# defect once the pointer is cleared, so this script REQUIRES the simulation to fail.
#
# The fix adds the two omitted assignments to the zeroize branch of the api_regs
# sequential block, matching the reset branch four lines above it. Nothing else is
# touched: the reset branch, the FSM and the pointer's next-state logic are unchanged.
set -euo pipefail

CMP="${CMP_ROOT:-/home/smy/hackatdac26-phase-2-caliptra}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS="$(cd "$HERE/../logs" && pwd)"
SCRATCH="$HERE/../scratch"
LOG="$LOGS/negative_control.log"

rm -rf "$SCRATCH"
mkdir -p "$SCRATCH"
cp "$CMP/src/pcrvault/rtl/pv_gen_hash.sv" "$SCRATCH/pv_gen_hash.sv"

{
  echo "BUG-031 negative control"
  echo "source DUT : $CMP/src/pcrvault/rtl/pv_gen_hash.sv"
  echo "patched DUT: $SCRATCH/pv_gen_hash.sv"
  echo "date=$(date -Is)"
} > "$LOG"

python3 - "$SCRATCH/pv_gen_hash.sv" <<'PY'
import sys
p = sys.argv[1]
text = open(p).read()
old = """    else if (zeroize) begin
      gen_hash_fsm_ps <= GEN_HASH_IDLE;
      block_offset_i  <= '0;
      nonce_offset_i  <= '0;
    end
"""
new = """    else if (zeroize) begin
      gen_hash_fsm_ps <= GEN_HASH_IDLE;
      block_offset_i  <= '0;
      nonce_offset_i  <= '0;
      read_entry      <= '0;
      read_offset     <= '0;
    end
"""
assert text.count(old) == 1, f"expected exactly one zeroize branch, found {text.count(old)}"
open(p, "w").write(text.replace(old, new))
print("negative control patch applied: read_entry and read_offset cleared on zeroize")
PY

echo "patch applied: read_entry and read_offset cleared in the zeroize branch" >> "$LOG"
echo "" >> "$LOG"

echo "--- re-running the identical testbench against the patched copy ---"
set +e
DUT_PVGH="$SCRATCH/pv_gen_hash.sv" \
  SIM_LOG="$LOGS/negative_control_sim.log" \
  CMP_LOG="$LOGS/negative_control_compile.log" \
  "$HERE/run_bug_031_sim.sh" > "$LOGS/negative_control_stdout.log" 2>&1
rc=$?
set -e
tail -30 "$LOGS/negative_control_stdout.log" || true

NSIM="$LOGS/negative_control_sim.log"
wit=$(grep -c 'BUG_031_WITNESS_OBSERVED' "$NSIM" || true)
after=$(grep -c 'case=violating_walk_after_mid_run_zeroize PASS' "$NSIM" || true)
reset_ok=$(grep -c 'case=control_full_walk_from_reset PASS' "$NSIM" || true)
contain=$(grep -c 'case=containment_idle_zeroize_then_full_walk PASS' "$NSIM" || true)
tbf=$(grep -c 'TBFAIL' "$NSIM" || true)

{
  echo "sim exit code                     : $rc (nonzero expected)"
  echo "BUG_031 witness lines             : $wit (must be 0)"
  echo "post-zeroize walk now complete    : $after (must be 1)"
  echo "reset walk still complete         : $reset_ok (must stay 1)"
  echo "idle-zeroize walk still complete  : $contain (must stay 1)"
  echo "TBFAIL lines total                : $tbf (must be 0)"
  echo ""
} >> "$LOG"

status=0
[ "$rc" -eq 0 ] && status=1
[ "$after" -eq 1 ] || status=1
[ "$wit" -eq 0 ] || status=1
[ "$reset_ok" -eq 1 ] || status=1
[ "$contain" -eq 1 ] || status=1
[ "$tbf" -eq 0 ] || status=1

if [ "$status" -ne 0 ]; then
  {
    echo "CONCLUSION: the negative control did not behave as required, so the"
    echo "harness cannot be shown to be non-vacuous."
    echo "NEGATIVE CONTROL: FAIL"
  } | tee -a "$LOG"
  exit 1
fi

{
  echo "CONCLUSION: On the audited RTL a quote started after a mid-run zeroize"
  echo "covers only the tail of the PCR bank, beginning at whichever entry the"
  echo "interrupted run had reached. With the two omitted pointer assignments"
  echo "added to the zeroize branch in a scratch copy, the same sequence covers"
  echo "all thirty-two entries and the witness stops firing, while the run from"
  echo "reset and the idle-zeroize run pass both before and after the change."
  echo "The observation is a property of the audited RTL, not of the testbench."
  echo "NEGATIVE CONTROL: PASS"
} | tee -a "$LOG"
