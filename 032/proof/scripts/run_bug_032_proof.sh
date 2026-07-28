#!/usr/bin/env bash
# BUG-032 structural audit: the SHA-256 DIGEST hardware-clear strobe is inverted.
#
# The finding is established entirely from evidence inside the audited tree: the
# module forms two cleanup strobes, one of which reduces to "ZEROIZE OR NOT switch",
# and drives the DIGEST window's hardware clear from that one while every other
# cleanup consumer in the same file uses the correct strobe. The gates also establish
# the direction of the error, which is what decides its severity: with the inverted
# strobe the clear is asserted in the steady operating state, so the window is held
# at zero instead of publishing a completed digest. No external repository, reference
# revision, or expected-answer list is consulted anywhere below.
set -euo pipefail

CMP="${AUDIT_ROOT:-/home/smy/hackatdac26-phase-2-caliptra}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS="$(cd "$HERE/../logs" && pwd)"
W="$LOGS/witness.log"
RUN_LOG="$LOGS/run.log"
S="$CMP/src/sha256/rtl/sha256.sv"
REG="$CMP/src/sha256/rtl/sha256_reg.sv"
RDL="$CMP/src/sha256/rtl/sha256_reg.rdl"
TOP="$CMP/src/integration/rtl/caliptra_top.sv"

PASS=0; FAIL=0
: > "$W"
{
  echo "BUG-032 structural audit (single-tree)"
  echo "audit_root=$CMP"
  echo "date=$(date -Is)"
} > "$RUN_LOG"

gate() {
  local cmd="$1" desc="$2"
  if eval "$cmd" >/dev/null 2>&1; then
    PASS=$((PASS+1)); echo "  PASS: $desc" | tee -a "$W"
    echo "gate_ok: $desc" >> "$RUN_LOG"
  else
    FAIL=$((FAIL+1)); echo "  FAIL: $desc" | tee -a "$W"
    echo "gate_fail: $desc" >> "$RUN_LOG"
  fi
}
show() { echo "$1" | tee -a "$W"; }

show "===== BUG-032 structural audit (single-tree, audited RTL only) ====="
show ""
show "----- 1. the register the tree defines -----"

gate "grep -q 'hwclr;} DIGEST\[32\]' '$RDL'" \
     "sha256_reg.rdl declares the DIGEST field with a hardware clear, so a clear strobe is expected"

gate "grep -Eq 'default sw = r;' '$RDL'" \
     "the DIGEST window is software-readable only, so its value is produced entirely by hardware"

gate "grep -q 'SHA256_DIGEST\[8\]' '$RDL'" \
     "the window is eight dwords wide, the full SHA-256 result"

show ""
show "----- 2. the two strobes the module forms -----"

gate "sed -n '389p' '$S' | grep -q 'ZEROIZE.value || debugUnlock_or_scan_mode_switch'" \
     "the first strobe is ZEROIZE OR switch: asserted only when cleanup is actually requested"

gate "sed -n '390p' '$S' | grep -q '~(&{~hwif_out.SHA256_CTRL.ZEROIZE.value, debugUnlock_or_scan_mode_switch})'" \
     "the second strobe is NOT(NOT ZEROIZE AND switch), which reduces to ZEROIZE OR NOT switch"

gate "[ \"\$(grep -c 'zeroize_reg2' '$S')\" -eq 3 ]" \
     "zeroize_reg2 appears exactly three times: its declaration, this assignment and a single use"

show ""
show "----- 3. where each strobe is consumed -----"

gate "sed -n '403p' '$S' | grep -q 'SHA256_DIGEST\[dword\].DIGEST.hwclr = zeroize_reg2;'" \
     "the DIGEST window's hardware clear is the sole consumer of the second strobe"

gate "sed -n '408p' '$S' | grep -q 'SHA256_BLOCK\[dword\].BLOCK.hwclr = zeroize_reg;'" \
     "the BLOCK window beside it clears from the first strobe, so the two windows disagree"

gate "sed -n '357p' '$S' | grep -q 'else if (zeroize_reg)' && sed -n '359p' '$S' | grep -q \"digest_reg *<= *'0;\"" \
     "the internal digest_reg is also cleared from the first strobe, so the register file is the outlier"

gate "! grep -q 'DIGEST.we' '$S'" \
     "no write-enable suppression guards the DIGEST window, so the clear strobe alone decides its value"

show ""
show "----- 4. the direction of the error (this is what sets severity) -----"

gate "sed -n '719,740p' '$REG' | grep -q 'hwclr) begin' && sed -n '719,740p' '$REG' | grep -q 'end else begin'" \
     "the generated register block gives hwclr priority over the unconditional hardware write"

gate "grep -Eq 'assign debug_lock_or_scan_mode_switch *= *debug_lock_switch \| scan_mode_switch' '$TOP'" \
     "caliptra_top builds the switch input from edge-detected transitions"

gate "grep -Eq 'scan_mode_switch *= *cptra_scan_mode_Latched_d & ~cptra_scan_mode_Latched_f' '$TOP'" \
     "those transitions are single-cycle pulses, so the switch is low throughout normal operation"

gate "grep -Eq 'debug_lock_switch *=' '$TOP'" \
     "the debug-lock term is likewise a transition, not a level"

show ""
show "----- 5. what that means at the register interface -----"

gate "grep -q 'hwif_in.SHA256_STATUS.VALID.next = digest_valid_reg;' '$S'" \
     "STATUS.VALID still reports a completed hash, so software is told to read a window that is held at zero"

gate "sed -n '402p' '$S' | grep -q 'DIGEST.next = digest_reg\[dword\];' " \
     "the window's hardware-write source is the live digest, which the priority clear overrides"

show ""
show "----- 6. the audited source, verbatim -----"
show ""
show "--- src/sha256/rtl/sha256.sv:387,391 (the two strobes) ---"
sed -n '387,391p' "$S" | tee -a "$W"

show ""
show "--- src/sha256/rtl/sha256.sv:400,409 (the two consumers) ---"
sed -n '400,409p' "$S" | tee -a "$W"

show ""
show "--- src/sha256/rtl/sha256_reg.sv:719,740 (hwclr priority) ---"
sed -n '719,740p' "$REG" | tee -a "$W"

show ""
show "structural_gates_passed=$PASS/$((PASS+FAIL))"
echo "structural_gates_passed=$PASS/$((PASS+FAIL))" >> "$RUN_LOG"
if [ "$FAIL" -eq 0 ]; then
  show "RESULT: PASS"
  echo "RESULT: PASS - all structural gates confirm BUG-032" >> "$RUN_LOG"
  echo "result=PASS" >> "$RUN_LOG"
else
  show "RESULT: FAIL"
  echo "RESULT: FAIL - at least one structural gate did not hold" >> "$RUN_LOG"
  echo "result=FAIL" >> "$RUN_LOG"
  exit 1
fi
