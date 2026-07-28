#!/usr/bin/env bash
# BUG-019 negative control.
#
# Adds `digest_valid_we = 1'b1;` to the init_cmd branch of the CTRL_IDLE state in
# hmac_core.sv. That is not an externally supplied answer: it is exactly what the
# next_cmd branch two lines below already does (hmac_core.sv:347), and it is what
# the reg_update block requires before it will write digest_valid_reg at all
# (hmac_core.sv:201-202).
#
# The identical testbench is then run against the patched scratch copy and is
# REQUIRED to fail. If it passed, the testbench would not be measuring the
# defect. Test 3 (the next_cmd control) must keep passing so the failure is
# attributable to the RTL change rather than to a broken harness.
#
# Only the BUG-019 line is added here. The testbench also checks BUG-018, a
# separate defect in the same always_comb block, which this copy leaves in place,
# so the BUG-018 checks are expected to keep PASSING. They are counted separately.
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
  echo "===== BUG-019 negative control ====="
  echo "source DUT : $SRC"
  echo "patched DUT: $PATCHED"
} | tee -a "$NC_LOG"

python3 - "$SRC" "$PATCHED" <<'PY' | tee -a "$NC_LOG"
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()

old = """        if (init_cmd) begin
          digest_valid_new = 1'b0;
          hmac_ctrl_new    = CTRL_IPAD;
          hmac_ctrl_we     = 1'b1;
        end"""
new = """        if (init_cmd) begin
          digest_valid_new = 1'b0;
          digest_valid_we  = 1'b1;
          hmac_ctrl_new    = CTRL_IPAD;
          hmac_ctrl_we     = 1'b1;
        end"""
assert text.count(old) == 1, "expected exactly one CTRL_IDLE init_cmd branch"
text = text.replace(old, new, 1)
open(dst, "w").write(text)
print("patch applied: init_cmd branch now asserts digest_valid_we, as next_cmd does")
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
STALECOV=$(grep -o 'cover_stale_valid=[0-9]*' "$NCSIM" | tail -1 | cut -d= -f2)
NEXTCOV=$(grep -o 'cover_next_clears=[0-9]*' "$NCSIM" | tail -1 | cut -d= -f2)
IPADCOV=$(grep -o 'cover_ipad_skipped=[0-9]*' "$NCSIM" | tail -1 | cut -d= -f2)
B19=$(grep -c 'TBFAIL: BUG-019\|TBFAIL: .*digest_valid_we is never' "$NCSIM" || true)
WE=$(grep -o 'digest_valid_we=[01]' "$NCSIM" | head -1 | cut -d= -f2)

{
  echo
  echo "----- negative control results -----"
  echo "sim exit code                : $RC (nonzero expected)"
  echo "TBFAIL lines total           : $FAILED (must be > 0)"
  echo "  of which BUG-019 checks    : $B19 (must be > 0)"
  echo "digest_valid_we during INIT   : $WE (1 = the write now happens)"
  echo "cover_stale_valid            : $STALECOV (must be 0)"
  echo "cover_next_clears (control)  : $NEXTCOV (must stay 1)"
  echo "cover_ipad_skipped           : $IPADCOV (expected 1: BUG-018 is unpatched here)"
} | tee -a "$NC_LOG"

VALID=1
[ "$RC" -ne 0 ]      || { echo "INVALID: patched RTL still passed" | tee -a "$NC_LOG"; VALID=0; }
[ "$FAILED" -gt 0 ]  || { echo "INVALID: no self-check tripped" | tee -a "$NC_LOG"; VALID=0; }
[ "$B19" -gt 0 ]     || { echo "INVALID: no BUG-019 check tripped" | tee -a "$NC_LOG"; VALID=0; }
[ "$STALECOV" = "0" ]|| { echo "INVALID: stale-valid cover did not drop to 0" | tee -a "$NC_LOG"; VALID=0; }
[ "$NEXTCOV" = "1" ] || { echo "INVALID: control check also broke, harness is suspect" | tee -a "$NC_LOG"; VALID=0; }
[ "$WE" = "1" ]      || { echo "INVALID: patched RTL did not assert digest_valid_we" | tee -a "$NC_LOG"; VALID=0; }

{
  echo
  if [ "$VALID" = "1" ]; then
    echo "CONCLUSION: On the audited RTL an INIT command leaves a previous run's VALID bit"
    echo "standing, because the init_cmd branch drives digest_valid_new to 0 without ever"
    echo "asserting the write enable the reg_update block needs. With the file's own"
    echo "next_cmd treatment applied to the init_cmd branch in a scratch copy, the write"
    echo "does happen, the stale-valid cover falls to 0 and the BUG-019 self-checks fail,"
    echo "while the harness's own control check still passes. The observation is a"
    echo "property of the audited RTL."
    echo "NEGATIVE CONTROL: PASS"
  else
    echo "NEGATIVE CONTROL: FAIL"
  fi
} | tee -a "$NC_LOG"

[ "$VALID" = "1" ]
