#!/usr/bin/env bash
# BUG-005 negative control.
#
# Purpose: show the testbench DISCRIMINATES, i.e. it fails on corrected RTL
# rather than always passing. A proof that passes on both the defective and the
# fixed design proves nothing.
#
# Method: copy aes_reg_top.sv to a scratch file and apply the correct treatment for
# a write-only window to the four DATA_IN address hits, namely returning constant
# zero. That is not an externally supplied answer: it is exactly what this same file
# already does for TRIGGER, its other SwAccessWO register (aes_reg_top.sv:1826-1831).
# Then compile the IDENTICAL testbench against the patched copy and require it to
# FAIL with cover_data_in_leak = 0.
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

echo "BUG-005 negative control" >> "$NC_LOG"
echo "date=$(date -Is)" >> "$NC_LOG"
echo "original=$SRC" >> "$NC_LOG"
echo "patched_copy=$PATCHED" >> "$NC_LOG"
echo "" >> "$NC_LOG"
echo "--- patch: apply the file's own write-only read treatment to DATA_IN ---" >> "$NC_LOG"
echo "    (the same constant-zero arm this file already uses for TRIGGER at :1826-1831)" >> "$NC_LOG"

# Replace each leaking read arm with the correct write-only treatment: constant zero.
for i in 0 1 2 3; do
  hit=$((21 + i))
  python3 - "$PATCHED" "$hit" "$i" <<'PY'
import sys
path, hit, idx = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(path).read()
old = "addr_hit[%s]: reg_rdata_next[31:0] = reg2hw.data_in[%s].q;" % (hit, idx)
new = "addr_hit[%s]: reg_rdata_next[31:0] = '0;" % hit
assert src.count(old) == 1, "expected exactly one occurrence of: %s" % old
open(path, "w").write(src.replace(old, new))
PY
  echo "  addr_hit[$hit]: reg2hw.data_in[$i].q  ->  '0" >> "$NC_LOG"
done

echo "" >> "$NC_LOG"
echo "--- verification that the patch took effect ---" >> "$NC_LOG"
REMAIN=$(grep -c "reg2hw.data_in\[.*\].q;" "$PATCHED" || true)
echo "remaining_leaking_read_arms_in_patched_copy=$REMAIN (expect 0)" >> "$NC_LOG"
if [ "$REMAIN" -ne 0 ]; then
  echo "negative_control=INVALID (patch did not apply cleanly)" >> "$NC_LOG"
  echo "result=FAIL" >> "$NC_LOG"
  exit 1
fi
grep -n "addr_hit\[2[1-4]\]: reg_rdata_next" "$PATCHED" >> "$NC_LOG"

echo "" >> "$NC_LOG"
echo "--- running the IDENTICAL testbench against the patched copy ---" >> "$NC_LOG"

set +e
DUT_AES_REG_TOP="$PATCHED" \
SIM_LOG="$LOGS/negative_control_sim.log" \
CMP_LOG="$LOGS/negative_control_compile.log" \
  "$HERE/run_bug_005_sim.sh" > "$LOGS/negative_control_stdout.log" 2>&1
RC=$?
set -e

echo "sim_exit_code=$RC (nonzero is the expected outcome here)" >> "$NC_LOG"
echo "" >> "$NC_LOG"
echo "--- patched-DUT observations ---" >> "$NC_LOG"
grep -E "DATA_IN\[[0-3]\] @|recovered 128-bit|cover_data_in_leak|cover_legal_read|checks=|PROOF_RESULT" \
     "$LOGS/negative_control_sim.log" >> "$NC_LOG" || true

LEAK=$(grep -oP 'cover_data_in_leak=\K[0-9]+' "$LOGS/negative_control_sim.log" | head -1 || true)
LEGAL=$(grep -oP 'cover_legal_read=\K[0-9]+' "$LOGS/negative_control_sim.log" | head -1 || true)
FAILED=$(grep -c 'BUG-005-TBFAIL' "$LOGS/negative_control_sim.log" || true)

echo "" >> "$NC_LOG"
echo "cover_data_in_leak_on_patched_rtl=${LEAK:-unset} (expect 0)" >> "$NC_LOG"
echo "cover_legal_read_on_patched_rtl=${LEGAL:-unset} (expect 1: harness still works)" >> "$NC_LOG"
echo "tbfail_lines=$FAILED (expect >0)" >> "$NC_LOG"

# The control is valid only if: the leak disappears, the TB reports failures,
# and the harness itself still functions (the legal read still succeeds, proving
# the failure is due to the fix and not a broken testbench).
ok=1
[ "${LEAK:-x}" = "0" ]   || ok=0
[ "${LEGAL:-x}" = "1" ]  || ok=0
[ "$FAILED" -gt 0 ]      || ok=0
[ "$RC" -ne 0 ]          || ok=0

echo "" >> "$NC_LOG"
if [ "$ok" -eq 1 ]; then
  cat >> "$NC_LOG" <<'EOF'
CONCLUSION: the testbench discriminates.
On the audited RTL all four DATA_IN words return the written plaintext and the
128-bit block is recoverable. With the file's own write-only read treatment applied
to those four arms in a scratch copy, the identical testbench observes 0x00000000
for every word, its leak cover counter drops to 0, and its self-checks fail. The
control read still succeeds, so the failure is caused by the RTL fix and not by a
broken harness.
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
