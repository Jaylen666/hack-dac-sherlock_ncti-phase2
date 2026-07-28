#!/usr/bin/env bash
# BUG-018 negative control.
#
# Applies the correct treatment for two mutually exclusive commands in a single
# FSM state to the CTRL_IDLE branch of hmac_core.sv: make the next_cmd test an
# `else if` so init_cmd wins. That is not an externally supplied answer, it is
# the standard reading of a priority-encoded command decode, and it is the only
# form under which the state variable is not double-assigned in one cycle.
#
# The identical testbench is then run against the patched scratch copy and is
# REQUIRED to fail. If it passed, the testbench would not be measuring the
# defect. Test 3 of the testbench (the next_cmd control) must keep passing, so
# the failure is attributable to the RTL change and not to a broken harness.
#
# Only the BUG-018 construct is patched here. The testbench also checks BUG-019,
# a separate defect in the same always_comb block, which this copy leaves in
# place, so the BUG-019 checks are expected to keep PASSING on this copy. They
# are counted separately below to make that explicit.
set -euo pipefail

CMP="${CMP_ROOT:-/home/smy/hackatdac26-phase-2-caliptra}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS="$(cd "$HERE/../logs" && pwd)"
SCRATCH="$(cd "$HERE/../scratch" && pwd)"
NC_LOG="$LOGS/negative_control.log"

SRC="$CMP/src/hmac/rtl/hmac_core.sv"
PATCHED="$SCRATCH/hmac_core.sv"

: > "$NC_LOG"
{
  echo "===== BUG-018 negative control ====="
  echo "source DUT : $SRC"
  echo "patched DUT: $PATCHED"
} | tee -a "$NC_LOG"

python3 - "$SRC" "$PATCHED" <<'PY' | tee -a "$NC_LOG"
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()

# Replace the whole two-if region in CTRL_IDLE with the same code written as a
# single if/else if chain. Nothing else about either branch is altered.
old = """        if (init_cmd) begin
          digest_valid_new = 1'b0;
          hmac_ctrl_new    = CTRL_IPAD;
          hmac_ctrl_we     = 1'b1;
        end

        if (next_cmd) begin"""
new = """        if (init_cmd) begin
          digest_valid_new = 1'b0;
          hmac_ctrl_new    = CTRL_IPAD;
          hmac_ctrl_we     = 1'b1;
        end
        else if (next_cmd) begin"""
assert text.count(old) == 1, "expected exactly one CTRL_IDLE two-if region"
text = text.replace(old, new, 1)
open(dst, "w").write(text)
print("patch applied: CTRL_IDLE next_cmd test is now `else if`, giving INIT priority")
PY

export PATH="/data0/tools/Synopsys/vcs/vcs/W-2024.09-SP1/bin:$PATH"

set +e
DUT_HMAC_CORE="$PATCHED" \
SIM_LOG="$LOGS/negative_control_sim.log" \
CMP_LOG="$LOGS/negative_control_compile.log" \
  "$HERE/run_bug_018_019_sim.sh" > "$LOGS/negative_control_stdout.log" 2>&1
RC=$?
set -e

NCSIM="$LOGS/negative_control_sim.log"
FAILED=$(grep -c 'TBFAIL' "$NCSIM" || true)
IPADCOV=$(grep -o 'cover_ipad_skipped=[0-9]*' "$NCSIM" | tail -1 | cut -d= -f2)
NEXTCOV=$(grep -o 'cover_next_clears=[0-9]*' "$NCSIM" | tail -1 | cut -d= -f2)
STATE=$(grep -o 'OBSERVED: hmac_ctrl_reg=[0-9]*' "$NCSIM" | head -1 | cut -d= -f2)
B18=$(grep -c 'TBFAIL: .*CTRL_IPAD\|TBFAIL: BUG-018' "$NCSIM" || true)
B19=$(grep -c 'TBFAIL: BUG-019' "$NCSIM" || true)

{
  echo
  echo "----- negative control results -----"
  echo "sim exit code                : $RC (nonzero expected)"
  echo "TBFAIL lines total           : $FAILED (must be > 0)"
  echo "  of which CTRL_IDLE-transition: $B18 (must be > 0)"
  echo "  of which BUG-019 checks    : $B19 (expected 0: BUG-019 is unpatched here, so its checks still hold)"
  echo "cover_ipad_skipped           : $IPADCOV (must be 0)"
  echo "cover_next_clears (control)  : $NEXTCOV (must stay 1)"
  echo "hmac_ctrl_reg after INIT+NEXT: $STATE (1 = CTRL_IPAD, the corrected behaviour)"
} | tee -a "$NC_LOG"

VALID=1
[ "$RC" -ne 0 ]            || { echo "INVALID: patched RTL still passed" | tee -a "$NC_LOG"; VALID=0; }
[ "$FAILED" -gt 0 ]        || { echo "INVALID: no self-check tripped"    | tee -a "$NC_LOG"; VALID=0; }
[ "$B18" -gt 0 ]           || { echo "INVALID: no BUG-018 check tripped" | tee -a "$NC_LOG"; VALID=0; }
[ "$IPADCOV" = "0" ]       || { echo "INVALID: IPAD-skip cover did not drop to 0" | tee -a "$NC_LOG"; VALID=0; }
[ "$NEXTCOV" = "1" ]       || { echo "INVALID: control check also broke, harness is suspect" | tee -a "$NC_LOG"; VALID=0; }
[ "$STATE" = "1" ]         || { echo "INVALID: patched FSM did not land in CTRL_IPAD" | tee -a "$NC_LOG"; VALID=0; }

{
  echo
  if [ "$VALID" = "1" ]; then
    echo "CONCLUSION: On the audited RTL the FSM lands in CTRL_OPAD when INIT and NEXT"
    echo "arrive together, silently skipping the IPAD phase. With the next_cmd test made"
    echo "an else if in a scratch copy, the same stimulus lands in CTRL_IPAD, the"
    echo "IPAD-skip cover falls to 0 and the BUG-018 self-checks fail, while the harness's"
    echo "own control check still passes. The observation is a property of the audited RTL."
    echo "NEGATIVE CONTROL: PASS"
  else
    echo "NEGATIVE CONTROL: FAIL"
  fi
} | tee -a "$NC_LOG"

[ "$VALID" = "1" ]
