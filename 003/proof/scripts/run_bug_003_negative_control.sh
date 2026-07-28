#!/usr/bin/env bash
# BUG-003 negative control.
#
# Purpose: show the testbench DISCRIMINATES, i.e. it fails on corrected RTL rather
# than always passing. A proof that passes on both the defective and the fixed
# design proves nothing.
#
# Method: copy aes_reg_top.sv to a scratch file and apply this tree's own REGWEN
# gating idiom to the AUX write qualifier, i.e. AND it with the lock read-back.
# That patch is not an externally supplied answer: 32 of the 33 write-enable gating
# sites in this tree already have exactly that form (see the census in
# run_bug_003_proof.sh), including kmac_reg_top.sv:554 for an equally shadowed
# register. Then compile the IDENTICAL testbench against the patched copy and
# require it to FAIL with cover_aux_committed_while_locked = 0.
#
# The testbench also covers BUG-005 (the DATA_IN read path). To keep this control
# attributable to the BUG-003 fix alone, only the gating line is patched here; the
# BUG-005 checks are expected to keep failing on the patched copy and are reported
# separately below rather than being treated as part of this verdict.
set -euo pipefail

CMP="${CMP_ROOT:-/home/smy/hackatdac26-phase-2-caliptra}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS="$(cd "$HERE/../logs" && pwd)"
SCRATCH="$LOGS/../scratch"
NC_LOG="$LOGS/negative_control.log"

: > "$NC_LOG"
rm -rf "$SCRATCH"
mkdir -p "$SCRATCH"

SRC="$CMP/src/aes/rtl/aes_reg_top.sv"
PATCHED="$SCRATCH/aes_reg_top.sv"
cp "$SRC" "$PATCHED"

echo "BUG-003 negative control" >> "$NC_LOG"
echo "date=$(date -Is)" >> "$NC_LOG"
echo "original=$SRC" >> "$NC_LOG"
echo "patched_copy=$PATCHED" >> "$NC_LOG"
echo "" >> "$NC_LOG"
echo "--- patch: apply this tree's own REGWEN gating idiom to the AUX write enable ---" >> "$NC_LOG"
echo "    (the form used by 32 of the 33 gating sites, e.g. kmac_reg_top.sv:554)" >> "$NC_LOG"

python3 - "$PATCHED" >> "$NC_LOG" <<'PY'
import sys
path = sys.argv[1]
src = open(path).read()

old = "  always_comb begin ctrl_aux_shadowed_gated_we = ctrl_aux_shadowed_we; end"
new = "  assign ctrl_aux_shadowed_gated_we = ctrl_aux_shadowed_we & ctrl_aux_regwen_qs;"
assert src.count(old) == 1, "gating line not found verbatim"
open(path, "w").write(src.replace(old, new))
print("  before: %s" % old.strip())
print("  after:  %s" % new.strip())
PY

echo "" >> "$NC_LOG"
echo "--- verification that the patch took effect ---" >> "$NC_LOG"
GATED=$(grep -c 'ctrl_aux_shadowed_gated_we = ctrl_aux_shadowed_we & ctrl_aux_regwen_qs;' "$PATCHED" || true)
UNGATED=$(grep -c 'ctrl_aux_shadowed_gated_we = ctrl_aux_shadowed_we;' "$PATCHED" || true)
echo "gated_assignments_in_patched_copy=$GATED (expect 1)" >> "$NC_LOG"
echo "ungated_assignments_in_patched_copy=$UNGATED (expect 0)" >> "$NC_LOG"
if [ "$GATED" -ne 1 ] || [ "$UNGATED" -ne 0 ]; then
  echo "negative_control=INVALID (patch did not apply cleanly)" >> "$NC_LOG"
  echo "result=FAIL" >> "$NC_LOG"
  exit 1
fi
grep -n 'ctrl_aux_shadowed_gated_we' "$PATCHED" >> "$NC_LOG"

echo "" >> "$NC_LOG"
echo "--- running the IDENTICAL testbench against the patched copy ---" >> "$NC_LOG"

set +e
DUT_AES_REG_TOP="$PATCHED" \
SIM_LOG="$LOGS/negative_control_sim.log" \
CMP_LOG="$LOGS/negative_control_compile.log" \
  "$HERE/run_bug_003_sim.sh" > "$LOGS/negative_control_stdout.log" 2>&1
RC=$?
set -e

echo "sim_exit_code=$RC (nonzero is the expected outcome here)" >> "$NC_LOG"
echo "" >> "$NC_LOG"
echo "--- patched-DUT observations ---" >> "$NC_LOG"
grep -E "REGWEN reads|key_touch_forces_reseed|shadow update error|cover_|checks=|PROOF_RESULT|TBFAIL" \
     "$LOGS/negative_control_sim.log" >> "$NC_LOG" || true

AUXCOV=$(grep -oP 'cover_aux_committed_while_locked=\K[0-9]+' "$LOGS/negative_control_sim.log" | head -1 || true)
REGWEN_OK=$(grep -c 'ok: REGWEN reads 0 after software lock' "$LOGS/negative_control_sim.log" || true)
RESET_OK=$(grep -c 'ok: KEY_TOUCH_FORCES_RESEED resets to 1' "$LOGS/negative_control_sim.log" || true)
FAILED=$(grep -c 'TBFAIL' "$LOGS/negative_control_sim.log" || true)
DINCOV=$(grep -oP 'cover_data_in_readback=\K[0-9]+' "$LOGS/negative_control_sim.log" | head -1 || true)

echo "" >> "$NC_LOG"
echo "cover_aux_committed_while_locked_on_patched_rtl=${AUXCOV:-unset} (expect 0)" >> "$NC_LOG"
echo "control_lock_engages=$REGWEN_OK (expect 1: the lock register itself still works)" >> "$NC_LOG"
echo "control_secure_default=$RESET_OK (expect 1: the harness still drives and observes the field)" >> "$NC_LOG"
echo "tbfail_lines=$FAILED (expect >0)" >> "$NC_LOG"
echo "cover_data_in_readback_on_patched_rtl=${DINCOV:-unset} (BUG-005 is unpatched here, so this stays nonzero)" >> "$NC_LOG"

# The control is valid only if the BUG-003 observation disappears, the TB reports
# failures, and the harness itself still functions: the lock still engages and the
# field is still observable, so the failure is attributable to the RTL fix rather
# than to a broken testbench.
ok=1
[ "${AUXCOV:-x}" = "0" ] || ok=0
[ "$REGWEN_OK" -ge 1 ]   || ok=0
[ "$RESET_OK" -ge 1 ]    || ok=0
[ "$FAILED" -gt 0 ]      || ok=0
[ "$RC" -ne 0 ]          || ok=0

echo "" >> "$NC_LOG"
if [ "$ok" -eq 1 ]; then
  cat >> "$NC_LOG" <<'EOF'
CONCLUSION: the testbench discriminates.
On the audited RTL a write to CTRL_AUX_SHADOWED commits while CTRL_AUX_REGWEN reads
0, so the engaged lock does not prevent the reconfiguration. With this tree's own
REGWEN gating idiom applied to that one line in a scratch copy, the identical
testbench finds the locked write rejected: the field keeps its value, the
cover_aux_committed_while_locked counter drops to 0, and the self-check fails.

The harness itself is unaffected by the patch: the lock still reads back 0 after
being engaged and the protected field is still observable, so the failure is caused
by the RTL fix and not by a broken testbench. The BUG-005 checks in the same
testbench continue to fail on this copy, as expected, because only the BUG-003
gating line was patched.
negative_control=PASS
EOF
  echo "result=PASS" >> "$NC_LOG"
  echo "negative control: PASS (TB fails on corrected RTL, as required)"
  exit 0
else
  echo "negative_control=FAIL (TB did not discriminate as required)" >> "$NC_LOG"
  echo "result=FAIL" >> "$NC_LOG"
  echo "negative control: FAIL"
  exit 1
fi
