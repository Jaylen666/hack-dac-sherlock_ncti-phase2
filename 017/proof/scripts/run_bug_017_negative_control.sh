#!/usr/bin/env bash
# BUG-017 negative control.
#
# Adds `H2_init = 1'b1;` to the first_round arm of the CTRL_IPAD state in
# hmac_core.sv, so the H2 core is actually started on the entropy block that the
# very next line already presents to it. That is not an externally supplied
# answer: every other block presentation in this same always_comb block is
# accompanied by a start strobe (H1_init at :275, H1_next/H2_init at :290-291,
# H2_next at :304), and the set_entropy latch at :229-231 is written to capture
# H2_digest, which only exists if H2 was started.
#
# The identical testbench is then run against the patched scratch copy and is
# REQUIRED to fail. If it passed, the testbench would not be measuring the
# defect. The H1 control check must keep passing so the failure is attributable
# to the RTL change rather than to a broken harness.
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
  echo "===== BUG-017 negative control ====="
  echo "source DUT : $SRC"
  echo "patched DUT: $PATCHED"
} | tee -a "$NC_LOG"

python3 - "$SRC" "$PATCHED" <<'PY' | tee -a "$NC_LOG"
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()

old = """        if (first_round) begin
          H1_init    = 1'b1;
          H1_next    = 1'b0;
          H2_init    = 1'b0;
          H2_next    = 1'b0;
          IPAD_ready = 1'b0;
        end"""
new = """        if (first_round) begin
          H1_init    = 1'b1;
          H1_next    = 1'b0;
          H2_init    = 1'b1;
          H2_next    = 1'b0;
          IPAD_ready = 1'b0;
        end"""
assert text.count(old) == 1, "expected exactly one CTRL_IPAD first_round arm"
text = text.replace(old, new, 1)
open(dst, "w").write(text)
print("patch applied: CTRL_IPAD first_round now starts H2 on the entropy block")
PY

export PATH="/data0/tools/Synopsys/vcs/vcs/W-2024.09-SP1/bin:$PATH"

set +e
DUT_HMAC_CORE="$PATCHED" \
SIM_LOG="$LOGS/negative_control_sim.log" \
CMP_LOG="$LOGS/negative_control_compile.log" \
  "$HERE/run_bug_017_sim.sh" > "$LOGS/negative_control_stdout.log" 2>&1
RC=$?
set -e

NCSIM="$LOGS/negative_control_sim.log"
FAILED=$(grep -c 'TBFAIL' "$NCSIM" || true)
H2COV=$(grep -o 'cover_h2_never_started=[0-9]*' "$NCSIM" | tail -1 | cut -d= -f2)
EZCOV=$(grep -o 'cover_entropy_zero=[0-9]*'     "$NCSIM" | tail -1 | cut -d= -f2)
SWCOV=$(grep -o 'cover_seed_is_sw=[0-9]*'       "$NCSIM" | tail -1 | cut -d= -f2)
H2SEEN=$(grep -o 'H2_init|H2_next was ever high: [01]' "$NCSIM" | tail -1 | awk '{print $NF}')
H1CTRL=$(grep -c 'ok: control: H1 was started' "$NCSIM" || true)
EDIG=$(grep -o 'entropy_digest\[63:0\]=[0-9a-f]*' "$NCSIM" | tail -1 | cut -d= -f2)

{
  echo
  echo "----- negative control results -----"
  echo "sim exit code                     : $RC (nonzero expected)"
  echo "TBFAIL lines total                : $FAILED (must be > 0)"
  echo "H2 start strobe seen in CTRL_IPAD  : $H2SEEN (must be 1)"
  echo "entropy_digest[63:0] after IPAD    : $EDIG (must be nonzero)"
  echo "cover_h2_never_started            : $H2COV (must be 0)"
  echo "cover_entropy_zero                : $EZCOV (must be 0)"
  echo "cover_seed_is_sw                  : $SWCOV (must be 0)"
  echo "H1 control check still ok          : $H1CTRL (must be 1)"
} | tee -a "$NC_LOG"

VALID=1
[ "$RC" -ne 0 ]      || { echo "INVALID: patched RTL still passed" | tee -a "$NC_LOG"; VALID=0; }
[ "$FAILED" -gt 0 ]  || { echo "INVALID: no self-check tripped" | tee -a "$NC_LOG"; VALID=0; }
[ "$H2SEEN" = "1" ]  || { echo "INVALID: patched RTL still never started H2" | tee -a "$NC_LOG"; VALID=0; }
[ "$H2COV" = "0" ]   || { echo "INVALID: H2-never-started cover did not drop to 0" | tee -a "$NC_LOG"; VALID=0; }
[ "$EZCOV" = "0" ]   || { echo "INVALID: entropy-zero cover did not drop to 0" | tee -a "$NC_LOG"; VALID=0; }
[ "$SWCOV" = "0" ]   || { echo "INVALID: seed still equals the software value" | tee -a "$NC_LOG"; VALID=0; }
[ "$H1CTRL" = "1" ]  || { echo "INVALID: H1 control check also broke, harness is suspect" | tee -a "$NC_LOG"; VALID=0; }
[ -n "$EDIG" ] && [ "$EDIG" != "0000000000000000" ] \
                     || { echo "INVALID: entropy_digest is still zero" | tee -a "$NC_LOG"; VALID=0; }

{
  echo
  if [ "$VALID" = "1" ]; then
    echo "CONCLUSION: On the audited RTL the entropy block is presented to H2 during"
    echo "CTRL_IPAD but H2 is never started, so set_entropy latches the unstarted core's"
    echo "output and the masking seed collapses to the software-written LFSR_SEED alone."
    echo "With H2 started from the same first_round arm in a scratch copy, matching the"
    echo "start-strobe form used by every other block presentation in this file, H2"
    echo "produces a real digest, entropy_digest latches a nonzero value, all three covers"
    echo "fall to 0 and the self-checks fail, while the H1 control check still passes."
    echo "The observation is a property of the audited RTL."
    echo "NEGATIVE CONTROL: PASS"
  else
    echo "NEGATIVE CONTROL: FAIL"
  fi
} | tee -a "$NC_LOG"

[ "$VALID" = "1" ]
