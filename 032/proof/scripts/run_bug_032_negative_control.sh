#!/usr/bin/env bash
# BUG-032 negative control (non-vacuity proof).
#
# Applies the author's own proposed fix to a scratch copy of the DUT and re-runs the
# IDENTICAL testbench. The proof is only meaningful if the harness stops reporting the
# defect once the strobe is corrected, so this script REQUIRES the simulation to fail.
#
# The fix drives the DIGEST hardware-clear from zeroize_reg, the same strobe the
# module's other cleanup consumers already use (src/sha256/rtl/sha256.sv:408 for the
# BLOCK window, and :357 for the internal digest_reg). Nothing else is touched.
set -euo pipefail

CMP="${CMP_ROOT:-/home/smy/hackatdac26-phase-2-caliptra}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS="$(cd "$HERE/../logs" && pwd)"
SCRATCH="$HERE/../scratch"
LOG="$LOGS/negative_control.log"

rm -rf "$SCRATCH"
mkdir -p "$SCRATCH"
cp "$CMP/src/sha256/rtl/sha256.sv" "$SCRATCH/sha256.sv"

{
  echo "BUG-032 negative control"
  echo "source DUT : $CMP/src/sha256/rtl/sha256.sv"
  echo "patched DUT: $SCRATCH/sha256.sv"
  echo "date=$(date -Is)"
} > "$LOG"

python3 - "$SCRATCH/sha256.sv" <<'PY'
import sys
p = sys.argv[1]
text = open(p).read()
old = "hwif_in.SHA256_DIGEST[dword].DIGEST.hwclr = zeroize_reg2;"
new = "hwif_in.SHA256_DIGEST[dword].DIGEST.hwclr = zeroize_reg;"
assert text.count(old) == 1, f"expected exactly one hwclr assignment, found {text.count(old)}"
open(p, "w").write(text.replace(old, new))
print("negative control patch applied: DIGEST.hwclr <- zeroize_reg")
PY

echo "patch applied: DIGEST window hardware clear driven from zeroize_reg" >> "$LOG"
echo "" >> "$LOG"

echo "--- re-running the identical testbench against the patched copy ---"
set +e
DUT_SHA256="$SCRATCH/sha256.sv" \
  SIM_LOG="$LOGS/negative_control_sim.log" \
  CMP_LOG="$LOGS/negative_control_compile.log" \
  "$HERE/run_bug_032_sim.sh" > "$LOGS/negative_control_stdout.log" 2>&1
rc=$?
set -e
tail -30 "$LOGS/negative_control_stdout.log" || true

NSIM="$LOGS/negative_control_sim.log"
wit=$(grep -c 'BUG_032_WITNESS_OBSERVED' "$NSIM" || true)
readable=$(grep -c 'case=quiescent_digest_readable PASS' "$NSIM" || true)
contain=$(grep -c 'case=containment_transition_pulse_not_readable PASS' "$NSIM" || true)
zeroize=$(grep -c 'case=sw_zeroize_clears PASS' "$NSIM" || true)
tbf=$(grep -c 'TBFAIL' "$NSIM" || true)

{
  echo "sim exit code                     : $rc (nonzero expected)"
  echo "BUG_032 witness lines             : $wit (must be 0)"
  echo "digest now readable when quiet    : $readable (must be 1)"
  echo "containment case still passing    : $contain (must stay 1)"
  echo "software ZEROIZE still clears     : $zeroize (must stay 1)"
  echo "TBFAIL lines total                : $tbf (must be 0)"
  echo ""
} >> "$LOG"

status=0
[ "$rc" -eq 0 ] && status=1
[ "$readable" -eq 1 ] || status=1
[ "$wit" -eq 0 ] || status=1
[ "$contain" -eq 1 ] || status=1
[ "$zeroize" -eq 1 ] || status=1
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
  echo "CONCLUSION: On the audited RTL a completed SHA-256 hash leaves the DIGEST"
  echo "window reading all-zero. With the window's hardware clear driven from"
  echo "zeroize_reg in a scratch copy, the same hash becomes readable and the"
  echo "witness stops firing, while the containment probe and the software"
  echo "ZEROIZE case pass both before and after the change. The observation is a"
  echo "property of the audited RTL, not of the testbench, and the strobe is not"
  echo "load-bearing for the debug-unlock wipe."
  echo "NEGATIVE CONTROL: PASS"
} | tee -a "$LOG"
