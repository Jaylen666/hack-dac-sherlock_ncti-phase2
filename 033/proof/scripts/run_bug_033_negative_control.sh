#!/usr/bin/env bash
# BUG-033 negative control.
#
# Purpose: show the testbench DISCRIMINATES, i.e. it fails on corrected RTL
# rather than always passing.
#
# Method: copy sha512.sv to a scratch file and make the DIGEST hwclr use the same
# strobe as every other zeroize-driven clear in this tree, i.e. collapse the two-strobe
# formation to the single zeroize_reg = ZEROIZE | debug_or_scan that already drives the
# GEN_PCR_HASH_DIGEST hwclr on the next line, the BLOCK hwclr, the write-enable
# suppression, the internal clear branch, and all four submodule .zeroize ports.
# The patch is therefore derived from the file's own surviving convention, not from an
# external answer. Then compile the IDENTICAL testbench against the patched copy and
# require it to FAIL with cover_no_clear_on_debug = 0 while its control check passes.
set -euo pipefail

CMP="${CMP_ROOT:-/home/smy/hackatdac26-phase-2-caliptra}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS="$(cd "$HERE/../logs" && pwd)"
SCRATCH="$LOGS/../scratch"
NC_LOG="$LOGS/negative_control.log"

: > "$NC_LOG"
rm -rf "$SCRATCH"
mkdir -p "$SCRATCH"

SRC="$CMP/src/sha512/rtl/sha512.sv"
PATCHED="$SCRATCH/sha512.sv"
cp "$SRC" "$PATCHED"

echo "BUG-033 negative control" >> "$NC_LOG"
echo "date=$(date -Is)" >> "$NC_LOG"
echo "original=$SRC" >> "$NC_LOG"
echo "patched_copy=$PATCHED" >> "$NC_LOG"
echo "" >> "$NC_LOG"
echo "--- patch: drive the DIGEST hwclr from the file's own surviving strobe ---" >> "$NC_LOG"

python3 - "$PATCHED" <<'PY'
import sys
path = sys.argv[1]
src = open(path).read()

# 1. Collapse the two-strobe formation to the single correct strobe.
old_form = """    {zeroize_reg, zeroize_reg2} = {
      hwif_out.SHA512_CTRL.ZEROIZE.value || debugUnlock_or_scan_mode_switch,
      ~(&{~hwif_out.SHA512_CTRL.ZEROIZE.value, debugUnlock_or_scan_mode_switch})
    };"""
new_form = "    zeroize_reg = hwif_out.SHA512_CTRL.ZEROIZE.value || debugUnlock_or_scan_mode_switch;"
assert src.count(old_form) == 1, "strobe formation not found verbatim"
src = src.replace(old_form, new_form)

# 2. Point the DIGEST hwclr at that single strobe, as its neighbours already are.
old_use = "hwif_in.SHA512_DIGEST[dword].DIGEST.hwclr = zeroize_reg2;"
new_use = "hwif_in.SHA512_DIGEST[dword].DIGEST.hwclr = zeroize_reg;"
assert src.count(old_use) == 1, "DIGEST hwclr assignment not found verbatim"
src = src.replace(old_use, new_use)

# 3. Drop the now-unused declaration so the patched file has no trace of it.
old_decl = "  logic zeroize_reg2;\n"
assert src.count(old_decl) == 1, "zeroize_reg2 declaration not found verbatim"
src = src.replace(old_decl, "")

open(path, "w").write(src)
print("  patch applied: 3 edits (formation, DIGEST hwclr, declaration)")
PY

python3 - "$PATCHED" >> "$NC_LOG" <<'PY'
import sys
print("  formation -> zeroize_reg = ZEROIZE || debugUnlock_or_scan_mode_switch")
print("  DIGEST hwclr -> zeroize_reg")
print("  zeroize_reg2 declaration removed")
PY

echo "" >> "$NC_LOG"
echo "--- verification that the patch took effect ---" >> "$NC_LOG"
REMAIN=$(grep -c "zeroize_reg2" "$PATCHED" || true)
echo "remaining_zeroize_reg2_sites_in_patched_copy=$REMAIN (expect 0)" >> "$NC_LOG"
if [ "$REMAIN" -ne 0 ]; then
  echo "negative_control=INVALID (patch did not apply cleanly)" >> "$NC_LOG"
  echo "result=FAIL" >> "$NC_LOG"
  exit 1
fi
grep -n "zeroize_reg = hwif_out\|DIGEST.hwclr = zeroize_reg;" "$PATCHED" >> "$NC_LOG"

echo "" >> "$NC_LOG"
echo "--- running the IDENTICAL testbench against the patched copy ---" >> "$NC_LOG"

set +e
DUT_SHA512="$PATCHED" \
SIM_LOG="$LOGS/negative_control_sim.log" \
CMP_LOG="$LOGS/negative_control_compile.log" \
  "$HERE/run_bug_033_sim.sh" > "$LOGS/negative_control_stdout.log" 2>&1
RC=$?
set -e

echo "sim_exit_code=$RC (nonzero is the expected outcome here)" >> "$NC_LOG"
echo "" >> "$NC_LOG"
echo "--- patched-DUT observations ---" >> "$NC_LOG"
grep -E "^--- |seeded DIGEST|with debug_or_scan|after software ZEROIZE|cover_|checks=|PROOF_RESULT|OBSERVED" \
     "$LOGS/negative_control_sim.log" >> "$NC_LOG" || true

NOCLR=$(grep -oP 'cover_no_clear_on_debug=\K[0-9]+' "$LOGS/negative_control_sim.log" | head -1 || true)
SEEN=$(grep -oP 'cover_seed_visible=\K[0-9]+' "$LOGS/negative_control_sim.log" | head -1 || true)
CTRL=$(grep -c 'ok: control: software ZEROIZE does clear the DIGEST window' "$LOGS/negative_control_sim.log" || true)
FAILED=$(grep -c 'BUG-033-TBFAIL' "$LOGS/negative_control_sim.log" || true)

echo "" >> "$NC_LOG"
echo "cover_no_clear_on_debug_on_patched_rtl=${NOCLR:-unset} (expect 0)" >> "$NC_LOG"
echo "cover_seed_visible_on_patched_rtl=${SEEN:-unset} (expect 0: the seed is now wiped)" >> "$NC_LOG"
echo "control_check_still_passes=$CTRL (expect 1)" >> "$NC_LOG"
echo "tbfail_lines=$FAILED (expect >0)" >> "$NC_LOG"

# Valid control: the debug/scan survival disappears, the TB reports failures,
# and the software-ZEROIZE control check still passes so the failure is
# attributable to the fix rather than to a broken harness.
ok=1
[ "${NOCLR:-x}" = "0" ] || ok=0
[ "$CTRL" -ge 1 ]       || ok=0
[ "$FAILED" -gt 0 ]     || ok=0
[ "$RC" -ne 0 ]         || ok=0

echo "" >> "$NC_LOG"
if [ "$ok" -eq 1 ]; then
  cat >> "$NC_LOG" <<'EOF'
CONCLUSION: the testbench discriminates.
On the audited RTL the seeded digest survives debug-unlock/scan-mode entry.
With the DIGEST hwclr driven from the file's own surviving strobe in a scratch
copy, the identical testbench
finds the digest wiped instead, its cover_no_clear_on_debug counter drops to 0,
and its self-checks fail. The software-ZEROIZE control check still passes on the
patched copy, so the failure is caused by the RTL fix and not by a broken
harness. Note also that on the patched copy the quiescent case no longer holds
the window cleared, which is the second half of the same inversion.
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
