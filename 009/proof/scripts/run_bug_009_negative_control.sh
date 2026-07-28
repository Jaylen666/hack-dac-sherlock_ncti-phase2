#!/usr/bin/env bash
# BUG-009 negative control (non-vacuity proof).
#
# Applies the author's own proposed fix to a scratch copy of the DUT and re-runs the
# IDENTICAL testbench. The proof is only meaningful if the harness stops reporting the
# defect once the qualification is indexed per application, so this script REQUIRES the
# simulation to fail (the testbench's PASS verdict encodes "the defect is present").
#
# The fix moves the dump qualification inside the existing per-application generate
# loop at src/csrng/rtl/csrng_state_db.sv:117-122, so each lane is gated by its own
# authorization bit int_state_read_enable_i[rd] instead of by bit 0 replicated across
# all lanes. Nothing else is touched.
set -euo pipefail

CMP="${CMP_ROOT:-/home/smy/hackatdac26-phase-2-caliptra}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS="$(cd "$HERE/../logs" && pwd)"
SCRATCH="$HERE/../scratch"
LOG="$LOGS/negative_control.log"

rm -rf "$SCRATCH"
mkdir -p "$SCRATCH"
cp "$CMP/src/csrng/rtl/csrng_state_db.sv" "$SCRATCH/csrng_state_db.sv"

{
  echo "BUG-009 negative control"
  echo "source DUT : $CMP/src/csrng/rtl/csrng_state_db.sv"
  echo "patched DUT: $SCRATCH/csrng_state_db.sv"
  echo "date=$(date -Is)"
} > "$LOG"

python3 - "$SCRATCH/csrng_state_db.sv" <<'PY'
import sys
p = sys.argv[1]
text = open(p).read()

# 1. Drop the out-of-loop qualification that replicates bit 0 across every lane.
old_q = "  assign int_st_dump_qualified = int_st_dump_sel & {NApps{int_state_read_enable_i[0]}};\n"
assert text.count(old_q) == 1, f"expected exactly one qualification assign, found {text.count(old_q)}"
text = text.replace(old_q, "")

# 2. Qualify each lane with its own authorization bit, inside the generate loop where
#    the per-application index rd is in scope.
old_l = "    assign int_st_dump_sel[rd] = (int_st_dump_id_q == rd);\n"
new_l = ("    assign int_st_dump_sel[rd] = (int_st_dump_id_q == rd);\n"
         "    assign int_st_dump_qualified[rd] = int_st_dump_sel[rd] & int_state_read_enable_i[rd];\n")
assert text.count(old_l) == 1, f"expected exactly one dump_sel assign, found {text.count(old_l)}"
text = text.replace(old_l, new_l)

open(p, "w").write(text)
print("negative control patch applied: int_st_dump_qualified[rd] <- int_state_read_enable_i[rd]")
PY

echo "patch applied: dump qualification indexed per application inside the generate loop" >> "$LOG"
echo "" >> "$LOG"

echo "--- re-running the identical testbench against the patched copy ---"
set +e
DUT_CSRNG_STATE_DB="$SCRATCH/csrng_state_db.sv" \
  SIM_LOG="$LOGS/negative_control_sim.log" \
  CMP_LOG="$LOGS/negative_control_compile.log" \
  "$HERE/run_bug_009_sim.sh" > "$LOGS/negative_control_stdout.log" 2>&1
rc=$?
set -e
tail -30 "$LOGS/negative_control_stdout.log" || true

NSIM="$LOGS/negative_control_sim.log"
wit=$(grep -c 'BUG_009_WITNESS_OBSERVED' "$NSIM" || true)
control=$(grep -c 'case=control_app0_authorized_reads_app0 PASS' "$NSIM" || true)
denied=$(grep -c 'case=violating_app1_denied_but_readable PASS' "$NSIM" || true)
authzd=$(grep -c 'case=violating_app1_authorized_but_denied PASS' "$NSIM" || true)
contain=$(grep -c 'case=containment_all_bits_clear_denies_all PASS' "$NSIM" || true)
tbf=$(grep -c 'TBFAIL' "$NSIM" || true)

{
  echo "sim exit code                       : $rc (nonzero expected)"
  echo "BUG_009 witness lines               : $wit (must be 0)"
  echo "control read still granted          : $control (must stay 1)"
  echo "unauthorized app now denied         : $denied (must be 1)"
  echo "authorized app now granted          : $authzd (must be 1)"
  echo "containment case still passing      : $contain (must stay 1)"
  echo "TBFAIL lines total                  : $tbf (must be 0)"
  echo ""
} >> "$LOG"

status=0
[ "$rc" -eq 0 ] && status=1
[ "$wit" -eq 0 ]     || status=1
[ "$control" -eq 1 ] || status=1
[ "$denied" -eq 1 ]  || status=1
[ "$authzd" -eq 1 ]  || status=1
[ "$contain" -eq 1 ] || status=1
[ "$tbf" -eq 0 ]     || status=1

if [ "$status" -ne 0 ]; then
  {
    echo "CONCLUSION: the negative control did not behave as required, so the"
    echo "harness cannot be shown to be non-vacuous."
    echo "NEGATIVE CONTROL: FAIL"
  } | tee -a "$LOG"
  exit 1
fi

{
  echo "CONCLUSION: On the audited RTL, application 1's DRBG key word is readable"
  echo "through the software dump window while application 1's own authorization bit"
  echo "is clear, and is withheld while that bit is set -- application 0's bit is the"
  echo "effective gate in both directions. With the qualification indexed per"
  echo "application in a scratch copy, both violations disappear: the unauthorized"
  echo "application dumps zeros and the authorized one is served, while the control"
  echo "read and the all-bits-clear containment case pass before and after the"
  echo "change. The observation is a property of the audited RTL, not of the"
  echo "testbench."
  echo "NEGATIVE CONTROL: PASS"
} | tee -a "$LOG"
