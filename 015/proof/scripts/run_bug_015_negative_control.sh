#!/usr/bin/env bash
# BUG-015 negative control.
#
# Builds a scratch copy of hmac_core.sv whose ONLY change is adding the omitted
# assignment to the zeroize arm of the reg_update always_ff, so that arm clears
# the same three registers its own reset arm clears. The identical testbench is
# then required to flip its verdict: the three violating checks must pass, the
# witness must stop firing, and the two controls plus the containment case must
# keep passing so the flip is attributable to the RTL change and not to a broken
# harness.
set -euo pipefail

CMP="${CMP_ROOT:-/home/smy/hackatdac26-phase-2-caliptra}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS="$(cd "$HERE/../logs" && pwd)"
SCRATCH="$HERE/../scratch"
NC_LOG="$LOGS/negative_control.log"

mkdir -p "$SCRATCH"
PATCHED="$SCRATCH/hmac_core.sv"

python3 - "$CMP/src/hmac/rtl/hmac_core.sv" "$PATCHED" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()

# The zeroize arm as it stands, comment and all. Anchoring on the whole arm
# guarantees the patch lands in the right always_ff and fails loudly otherwise.
old = """      zeroize: begin
        // Security zeroize request: collapse control FSM back to idle.
        // digest_valid_reg is refreshed by the normal update path below
        // on a later cycle, so it does not need to be touched here.
        hmac_ctrl_reg  <= CTRL_IDLE;
        hmac_ctrl_last <= CTRL_IDLE;
      end"""

new = """      zeroize: begin
        // Negative control: the zeroize arm now clears the same three registers
        // the reset arm clears. This is the only change in this file.
        digest_valid_reg <= 1'b0;
        hmac_ctrl_reg  <= CTRL_IDLE;
        hmac_ctrl_last <= CTRL_IDLE;
      end"""

assert text.count(old) == 1, "expected exactly one zeroize arm to patch"
# Guard: the arm being replaced must not already assign the register. Only code
# lines count, since the arm names it in its comment.
arm_code = [l for l in old.splitlines() if not l.strip().startswith("//")]
assert not any("digest_valid_reg" in l for l in arm_code), \
    "zeroize arm already clears digest_valid_reg"
text = text.replace(old, new, 1)
open(dst, "w").write(text)
print("patched: zeroize arm now clears digest_valid_reg", file=sys.stderr)
PY

# Confirm the patch is a single-line addition and nothing else moved. Both sides
# here are the audited file and my own patched scratch copy of it; no other tree
# is involved. Counted in Python so the size gate needs no external tool.
read -r DIFF_ADDED DIFF_REMOVED <<EOF
$(python3 - "$CMP/src/hmac/rtl/hmac_core.sv" "$PATCHED" <<'PY'
import sys, difflib
def code(p):
    return [l for l in open(p).read().splitlines()
            if not l.strip().startswith("//")]
a, b = code(sys.argv[1]), code(sys.argv[2])
d = list(difflib.ndiff(a, b))
print(sum(1 for l in d if l.startswith("+ ")),
      sum(1 for l in d if l.startswith("- ")))
PY
)
EOF
echo "scratch_code_lines_added=$DIFF_ADDED scratch_code_lines_removed=$DIFF_REMOVED"
if [ "$DIFF_ADDED" != "1" ] || [ "$DIFF_REMOVED" != "0" ]; then
  echo "gate_fail: the scratch copy differs by more than the single added assignment"
  exit 1
fi

export TMPDIR="${TMPDIR:-$SCRATCH/tmp}"
mkdir -p "$TMPDIR"

set +e
DUT_HMAC_CORE="$PATCHED" \
SIM_LOG="$LOGS/negative_control_sim.log" \
CMP_LOG="$LOGS/negative_control_compile.log" \
  "$HERE/run_bug_015_sim.sh" > "$LOGS/negative_control_stdout.log" 2>&1
RC=$?
set -e

SIMLOG="$LOGS/negative_control_sim.log"

# On the patched copy the TB's own PASS condition (which encodes the audited
# RTL's numbers) must NOT be met, so the script is expected to exit non-zero
# with no "result=" marker. The gates below check the individual observations.
WIT=$(grep -c 'BUG_015_WITNESS_OBSERVED' "$SIMLOG" || true)
COV_SURVIVE=$(grep -oE 'cov_tag_valid_survives_zeroize=[0-9]+' "$SIMLOG" | tail -1 | cut -d= -f2)
COV_EDGE=$(grep -oE 'cov_spurious_parent_capture_edge=[0-9]+' "$SIMLOG" | tail -1 | cut -d= -f2)
COV_RESET=$(grep -oE 'cov_reset_clears_tag_valid=[0-9]+' "$SIMLOG" | tail -1 | cut -d= -f2)
COV_RUN=$(grep -oE 'cov_tag_valid_after_normal_run=[0-9]+' "$SIMLOG" | tail -1 | cut -d= -f2)
FAILS=$(grep -oE 'fails=[0-9]+' "$SIMLOG" | tail -1 | cut -d= -f2)
SURVIVE_PASS=$(grep -c 'case=violating_tag_valid_survives_zeroize PASS' "$SIMLOG" || true)
REFRESH_PASS=$(grep -c 'case=violating_idle_refresh_never_happens PASS' "$SIMLOG" || true)
EDGE_PASS=$(grep -c 'case=violating_no_spurious_parent_capture PASS' "$SIMLOG" || true)
CONTAIN_PASS=$(grep -c 'case=containment_reset_still_clears PASS' "$SIMLOG" || true)

{
  echo "===== BUG-015 negative control ====="
  echo "patch=zeroize arm of hmac_core.sv reg_update now clears digest_valid_reg"
  echo "scratch_code_lines_added=$DIFF_ADDED"
  echo "sim_script_rc=$RC"
  echo "witness_hits=$WIT"
  echo "cov_tag_valid_survives_zeroize=$COV_SURVIVE"
  echo "cov_spurious_parent_capture_edge=$COV_EDGE"
  echo "cov_reset_clears_tag_valid=$COV_RESET"
  echo "cov_tag_valid_after_normal_run=$COV_RUN"
  echo "tb_fails=$FAILS"
  echo "violating_tag_valid_survives_zeroize_now_passes=$SURVIVE_PASS"
  echo "violating_idle_refresh_never_happens_now_passes=$REFRESH_PASS"
  echo "violating_no_spurious_parent_capture_now_passes=$EDGE_PASS"
  echo "containment_reset_still_clears_still_passes=$CONTAIN_PASS"
} > "$NC_LOG"

OK=1
chk() { if [ "$1" = "$2" ]; then echo "  ok   $3" | tee -a "$NC_LOG"; else echo "  BAD  $3 (got '$1', want '$2')" | tee -a "$NC_LOG"; OK=0; fi; }

echo "--- gates ---" | tee -a "$NC_LOG"
chk "$WIT"          "0" "the witness no longer fires on the patched copy"
chk "$COV_SURVIVE"  "0" "cov_tag_valid_survives_zeroize drops to 0 (anti-vacuity)"
chk "$COV_EDGE"     "0" "cov_spurious_parent_capture_edge drops to 0 (anti-vacuity)"
chk "$FAILS"        "0" "no TB check fails once the assignment is present"
chk "$SURVIVE_PASS" "1" "the zeroize-clears-tag-valid check now passes"
chk "$REFRESH_PASS" "1" "the idle-refresh check now passes"
chk "$EDGE_PASS"    "1" "the spurious-parent-capture check now passes"
chk "$COV_RESET"    "1" "harness control intact: reset still observed to clear the flag"
chk "$COV_RUN"      "1" "harness control intact: a normal run still reaches tag_valid"
chk "$CONTAIN_PASS" "1" "containment case still passes"

if [ "$OK" = "1" ]; then
  echo "NEGATIVE CONTROL: PASS" | tee -a "$NC_LOG"
else
  echo "NEGATIVE CONTROL: FAIL" | tee -a "$NC_LOG"
  exit 1
fi
