#!/usr/bin/env bash
# BUG-008 negative control.
#
# Patches the strict MuBi4 true test into the exact-equality form the same
# package already uses for its other three widths, on a scratch copy, then runs
# the identical testbench. The testbench MUST fail: if it passes on corrected
# RTL it is not measuring the defect.
#
# The control check is the pair of observations that do not depend on the defect
# (the function still accepting the legitimate True encoding, and the wider
# widths still rejecting their 1-bit errors). Those must keep passing, so the
# failure is attributable to the patched function and not to a broken harness.
set -euo pipefail

CMP="${CMP_ROOT:-/home/smy/hackatdac26-phase-2-caliptra}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS="$(cd "$HERE/../logs" && pwd)"
SCRATCH="$(cd "$HERE/../scratch" && pwd)"
NC_LOG="$LOGS/negative_control.log"

PKG_SRC="$CMP/src/caliptra_prim/rtl/caliptra_prim_mubi_pkg.sv"
PKG_FIX="$SCRATCH/caliptra_prim_mubi_pkg.sv"

{
  echo "BUG-008 negative control"
  echo "audit_root=$CMP"
  echo "date=$(date -Is)"
} > "$NC_LOG"

cp "$PKG_SRC" "$PKG_FIX"

python3 - "$PKG_FIX" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read()

# Replace the delta form with the exact equality the package's other three
# widths already use. Asserting the count keeps a silent no-op from passing as a
# negative control.
old = """  function automatic logic mubi4_test_true_strict(mubi4_t val);
    mubi4_t delta;
    delta = val ^ MuBi4True;
    return delta inside {4'h0, 4'h1};
  endfunction : mubi4_test_true_strict"""
new = """  function automatic logic mubi4_test_true_strict(mubi4_t val);
    return MuBi4True == val;
  endfunction : mubi4_test_true_strict"""
assert t.count(old) == 1, f"expected exactly 1 delta-form site, found {t.count(old)}"
t = t.replace(old, new, 1)
open(p, "w").write(t)
print("patched: mubi4_test_true_strict -> exact equality")
PY

echo "patch applied to $PKG_FIX" >> "$NC_LOG"

set +e
DUT_MUBI_PKG="$PKG_FIX" \
SIM_LOG="$LOGS/negative_control_sim.log" \
CMP_LOG="$LOGS/negative_control_compile.log" \
  bash "$HERE/run_bug_008_sim.sh" > "$LOGS/negative_control_stdout.log" 2>&1
RC=$?
set -e

NCS="$LOGS/negative_control_sim.log"
echo "sim_exit_code=$RC" >> "$NC_LOG"

FAILS=$(grep -c 'TBFAIL' "$NCS" || true)
ACCEPTS=$(grep -o 'accepts [0-9]* of 16 encodings' "$NCS" | grep -o '[0-9]*' | head -1 || echo "?")
C1=$(grep -o 'cover_strict_accepts_nontrue=[0-9]*' "$NCS" | tail -1 || echo "cover_strict_accepts_nontrue=?")
C2=$(grep -o 'cover_accepted_is_invalid=[0-9]*'    "$NCS" | tail -1 || echo "cover_accepted_is_invalid=?")
C3=$(grep -o 'cover_wider_widths_reject=[0-9]*'    "$NCS" | tail -1 || echo "cover_wider_widths_reject=?")
CTRL_TRUE=$(grep -c 'CONTROL: mubi4_test_true_strict(MuBi4True) is true' "$NCS" || true)

{
  echo "negative_control_tbfail_count=$FAILS"
  echo "encodings_accepted_after_patch=$ACCEPTS"
  echo "$C1"
  echo "$C2"
  echo "$C3"
  echo "control_true_encoding_still_accepted=$CTRL_TRUE"
} >> "$NC_LOG"

echo "----- negative control summary -----"
echo "  sim exit code                        : $RC (expected non-zero)"
echo "  TBFAIL count                         : $FAILS (expected >=1)"
echo "  encodings accepted after patch       : $ACCEPTS (expected 1)"
echo "  $C1 (expected 0)"
echo "  $C2 (expected 0)"
echo "  $C3 (expected 1: unrelated to the patch, must keep firing)"
echo "  control: True encoding still accepted: $CTRL_TRUE (expected 1)"

PASS=1
[ "$RC" -ne 0 ]     || { echo "  NC FAIL: the sim passed on corrected RTL"; PASS=0; }
[ "$FAILS" -ge 1 ]  || { echo "  NC FAIL: no self-check tripped on corrected RTL"; PASS=0; }
[ "$ACCEPTS" = "1" ] || { echo "  NC FAIL: patched function does not accept exactly 1 encoding"; PASS=0; }
[ "$C1" = "cover_strict_accepts_nontrue=0" ] || { echo "  NC FAIL: the anti-vacuity cover did not drop to 0"; PASS=0; }
[ "$C2" = "cover_accepted_is_invalid=0" ]    || { echo "  NC FAIL: the invalid-encoding cover did not drop to 0"; PASS=0; }
[ "$C3" = "cover_wider_widths_reject=1" ]    || { echo "  NC FAIL: the harness control cover stopped firing, so the harness is suspect"; PASS=0; }
[ "$CTRL_TRUE" -eq 1 ] || { echo "  NC FAIL: the control observation stopped passing, so the harness is suspect"; PASS=0; }

if [ "$PASS" -eq 1 ]; then
  echo "NEGATIVE CONTROL: PASS - the testbench discriminates the defect from its fix"
  echo "result=PASS" >> "$NC_LOG"
else
  echo "NEGATIVE CONTROL: FAIL"
  echo "result=FAIL" >> "$NC_LOG"
  exit 1
fi
