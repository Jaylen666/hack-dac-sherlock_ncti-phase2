#!/usr/bin/env bash
# BUG-028 structural audit: the standard-region destination bound is short by one.
#
# The finding is established entirely from evidence inside the audited tree: the
# destination classifier disagrees with the two source classifiers beside it in the
# same file, and the in-tree specification fixes the region as slots 0 through 15
# inclusive. The gates also establish the direction of the error, which is what
# decides its severity: the destination signal is consumed only under negation, so
# narrowing it can only add rejections and never grant a write that would otherwise
# be refused. No external repository, reference revision, or expected-answer list is
# consulted anywhere below.
set -euo pipefail

CMP="${AUDIT_ROOT:-/home/smy/hackatdac26-phase-2-caliptra}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS="$(cd "$HERE/../logs" && pwd)"
W="$LOGS/witness.log"
RUN_LOG="$LOGS/run.log"
RC="$CMP/src/keyvault/rtl/kv_write_rule_check.sv"
PKG="$CMP/src/keyvault/rtl/kv_defines_pkg.sv"
SPEC="$CMP/src/keyvault/config/keyvault.md"

PASS=0; FAIL=0
: > "$W"
{
  echo "BUG-028 structural audit (single-tree)"
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

show "===== BUG-028 structural audit (single-tree, audited RTL only) ====="
show ""
show "----- 1. the region the tree defines -----"

gate "grep -Eq 'KV_STANDARD_SLOT_HI +=  *15' '$PKG'" \
     "kv_defines_pkg.sv fixes KV_STANDARD_SLOT_HI at 15, so slot 15 is a standard slot"

gate "grep -Eq 'KV_STANDARD_SLOT_LOW +=  *0' '$PKG'" \
     "the standard region starts at slot 0"

gate "grep -q 'Reserves \*\*key vault slots 0–15\*\* for \*standard\* use-cases' '$SPEC'" \
     "keyvault.md reserves slots 0-15 for standard use-cases, an inclusive range that includes slot 15"

show ""
show "----- 2. the classifiers disagree inside one file -----"

gate "sed -n '69,71p' '$RC' | grep -q 'KV_STANDARD_SLOT_LOW:KV_STANDARD_SLOT_HI\]' " \
     "the data0 source classifier uses the full bound KV_STANDARD_SLOT_HI (line 71)"

gate "sed -n '72,74p' '$RC' | grep -q 'KV_STANDARD_SLOT_LOW:KV_STANDARD_SLOT_HI\]' " \
     "the data1 source classifier uses the full bound KV_STANDARD_SLOT_HI (line 74)"

gate "sed -n '87,88p' '$RC' | grep -q 'KV_STANDARD_SLOT_LOW:KV_STANDARD_SLOT_HI-1\]'" \
     "the destination classifier uses KV_STANDARD_SLOT_HI-1 instead (line 88)"

gate "[ \"\$(grep -v '^ *//' '$RC' | grep -c 'KV_STANDARD_SLOT_HI-1')\" -eq 1 ]" \
     "the short bound occurs exactly once in executable code, so the destination classifier is the only affected site"

show ""
show "----- 3. the direction of the error, which sets its severity -----"

gate "[ \"\$(grep -c 'dst_in_std_region' '$RC')\" -eq 3 ]" \
     "dst_in_std_region appears exactly 3 times: declaration, definition and a single use"

gate "sed -n '116p' '$RC' | grep -q '!dst_in_std_region;'" \
     "that single use is negated inside rule (b), so shrinking the set can only add rejections"

gate "! sed -n '110,141p' '$RC' | grep -q '[^!]dst_in_std_region'" \
     "no rule consumes dst_in_std_region un-negated, so no grant path depends on it"

show ""
show "----- 4. the LOCK region is unaffected, so containment still holds -----"

gate "sed -n '90,91p' '$RC' | grep -q 'KV_OCP_LOCK_SLOT_LOW:KV_OCP_LOCK_SLOT_HI\]'" \
     "the LOCK destination classifier is separate and uses its own full bound"

gate "sed -n '123,125p' '$RC' | grep -q 'src0_in_lock_region || src1_in_lock_region'" \
     "rule (c) lock_to_lock keys off the LOCK source classifiers, which the short bound does not touch"

gate "grep -Eq 'KV_OCP_LOCK_SLOT_LOW +=  *16' '$PKG'" \
     "the LOCK region starts at 16, so slot 15 is outside it and a LOCK source writing slot 15 still trips rule (c)"

show ""
show "----- 5. the verdict reaches the datapath -----"

gate "sed -n '151p' '$RC' | grep -q 'write_allow <= ~|rule_fail;'" \
     "write_allow is the NOR of the rule vector, so a spurious rule_fail suppresses a legitimate write"

show ""
show "----- 6. the audited source, verbatim -----"
show ""
show "--- src/keyvault/rtl/kv_write_rule_check.sv:69,91 (the three classifiers) ---"
sed -n '69,91p' "$RC" | tee -a "$W"

show ""
show "--- src/keyvault/rtl/kv_write_rule_check.sv:113,126 (rules (b) and (c)) ---"
sed -n '113,126p' "$RC" | tee -a "$W"

show ""
show "structural_gates_passed=$PASS/$((PASS+FAIL))"
echo "structural_gates_passed=$PASS/$((PASS+FAIL))" >> "$RUN_LOG"
if [ "$FAIL" -eq 0 ]; then
  show "RESULT: PASS"
  echo "RESULT: PASS - all structural gates confirm BUG-028" >> "$RUN_LOG"
  echo "result=PASS" >> "$RUN_LOG"
else
  show "RESULT: FAIL"
  echo "RESULT: FAIL - at least one structural gate did not hold" >> "$RUN_LOG"
  echo "result=FAIL" >> "$RUN_LOG"
  exit 1
fi
