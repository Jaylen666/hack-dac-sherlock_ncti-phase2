#!/usr/bin/env bash
# BUG-016 negative control.
#
# Adds the one missing statement to the zeroize arm of hmac_core.sv: clear
# digest_valid_reg alongside the two control registers the arm already clears.
# That is not an externally supplied answer, it is the treatment the arm three
# lines above uses for the same register, the treatment mode_reg gets from its
# own zeroize arm in this file, and the treatment the child masked cores give
# their own digest_valid_reg.
#
# The identical testbench is then run against the patched scratch copy and is
# REQUIRED to fail. If it passed, the testbench would not be measuring the
# defect. The harness's own control counter (cover_ctrl_cleared, which watches
# hmac_ctrl_reg and mode_reg clearing) must keep firing, so the failure is
# attributable to the RTL change and not to a broken harness.
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
  echo "===== BUG-016 negative control ====="
  echo "source DUT : $SRC"
  echo "patched DUT: $PATCHED"
} | tee -a "$NC_LOG"

python3 - "$SRC" "$PATCHED" <<'PY' | tee -a "$NC_LOG"
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()

# Add the single missing assignment to the zeroize arm. The comment that claimed
# a later refresh goes with it, since the patch is exactly what that comment
# argued was unnecessary. Nothing else in the file is altered.
old = """      zeroize: begin
        // Security zeroize request: collapse control FSM back to idle.
        // digest_valid_reg is refreshed by the normal update path below
        // on a later cycle, so it does not need to be touched here.
        hmac_ctrl_reg  <= CTRL_IDLE;
        hmac_ctrl_last <= CTRL_IDLE;
      end"""
new = """      zeroize: begin
        // Security zeroize request: collapse control FSM back to idle and
        // invalidate the tag, matching the reset arm above.
        digest_valid_reg <= 1'b0;
        hmac_ctrl_reg  <= CTRL_IDLE;
        hmac_ctrl_last <= CTRL_IDLE;
      end"""
assert text.count(old) == 1, "expected exactly one zeroize arm in reg_update"
text = text.replace(old, new, 1)
open(dst, "w").write(text)
print("patch applied: zeroize arm now clears digest_valid_reg, as the reset arm does")
PY

export PATH="/data0/tools/Synopsys/vcs/vcs/W-2024.09-SP1/bin:$PATH"

set +e
DUT_HMAC_CORE="$PATCHED" \
SIM_LOG="$LOGS/negative_control_sim.log" \
CMP_LOG="$LOGS/negative_control_compile.log" \
  "$HERE/run_bug_016_sim.sh" > "$LOGS/negative_control_stdout.log" 2>&1
RC=$?
set -e

NCSIM="$LOGS/negative_control_sim.log"
FAILED=$(grep -c 'TBFAIL' "$NCSIM" || true)
B16=$(grep -c 'TBFAIL: BUG-016' "$NCSIM" || true)
SURVIVE=$(grep -o 'cover_valid_survives_zeroize=[0-9]*' "$NCSIM" | tail -1 | cut -d= -f2)
NOREFRESH=$(grep -o 'cover_valid_never_refreshed=[0-9]*' "$NCSIM" | tail -1 | cut -d= -f2)
CTRLCOV=$(grep -o 'cover_ctrl_cleared=[0-9]*' "$NCSIM" | tail -1 | cut -d= -f2)
AFTER=$(grep -o 'OBSERVED after zeroize deasserts: tag_valid=[0-9]*' "$NCSIM" | head -1 | cut -d= -f2)
RESETCTL=$(grep -c 'ok: control: reset clears digest_valid_reg' "$NCSIM" || true)

{
  echo
  echo "----- negative control results -----"
  echo "sim exit code                    : $RC (nonzero expected)"
  echo "TBFAIL lines total               : $FAILED (must be > 0)"
  echo "  of which BUG-016 checks        : $B16 (must be > 0)"
  echo "cover_valid_survives_zeroize     : $SURVIVE (must be 0)"
  echo "cover_valid_never_refreshed      : $NOREFRESH (must be 0)"
  echo "cover_ctrl_cleared (harness ctrl): $CTRLCOV (must stay 1)"
  echo "tag_valid after zeroize deasserts: $AFTER (0 = the corrected behaviour)"
  echo "reset control still passing      : $RESETCTL (must be > 0)"
} | tee -a "$NC_LOG"

VALID=1
[ "$RC" -ne 0 ]        || { echo "INVALID: patched RTL still passed" | tee -a "$NC_LOG"; VALID=0; }
[ "$FAILED" -gt 0 ]    || { echo "INVALID: no self-check tripped" | tee -a "$NC_LOG"; VALID=0; }
[ "$B16" -gt 0 ]       || { echo "INVALID: no BUG-016 check tripped" | tee -a "$NC_LOG"; VALID=0; }
[ "$SURVIVE" = "0" ]   || { echo "INVALID: the survives-zeroize cover did not drop to 0" | tee -a "$NC_LOG"; VALID=0; }
[ "$NOREFRESH" = "0" ] || { echo "INVALID: the never-refreshed cover did not drop to 0" | tee -a "$NC_LOG"; VALID=0; }
[ "$CTRLCOV" = "1" ]   || { echo "INVALID: harness control also broke, harness is suspect" | tee -a "$NC_LOG"; VALID=0; }
[ "$AFTER" = "0" ]     || { echo "INVALID: patched RTL still reports tag_valid after zeroize" | tee -a "$NC_LOG"; VALID=0; }
[ "$RESETCTL" -gt 0 ]  || { echo "INVALID: the reset control check stopped passing" | tee -a "$NC_LOG"; VALID=0; }

{
  echo
  if [ "$VALID" = "1" ]; then
    echo "CONCLUSION: On the audited RTL a security zeroize collapses the control FSM but"
    echo "leaves digest_valid_reg set, and no later refresh ever clears it, so tag_valid"
    echo "stays asserted indefinitely. With the single missing assignment added to the"
    echo "zeroize arm in a scratch copy, the same stimulus drives tag_valid to 0, both"
    echo "defect covers fall to 0 and the BUG-016 self-checks fail, while the harness's own"
    echo "control observations still pass. The observation is a property of the audited RTL."
    echo "NEGATIVE CONTROL: PASS"
  else
    echo "NEGATIVE CONTROL: FAIL"
  fi
} | tee -a "$NC_LOG"

# The nested sim run rebuilds the build tree after its own cleanup, so drop it
# again here: it is rebuildable and must not ship inside the case.
rm -rf "$HERE/../build"

[ "$VALID" = "1" ]
