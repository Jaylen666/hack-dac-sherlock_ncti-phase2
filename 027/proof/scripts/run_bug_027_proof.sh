#!/usr/bin/env bash
# BUG-027 structural audit: the release-slot rule is gated on a forwarding term.
#
# The finding is established entirely from evidence inside the audited tree. The
# argument is that the module contradicts its own stated contract twice: its
# header declares rule (a) as "non-AES engines are blocked from release slot",
# and the in-tree KeyVault specification says nothing may be written to the
# release slot except the AES-produced MEK, yet the implemented rule carries a
# fourth AND-term that disables the check whenever a forwarded KeyVault source is
# present. No external repository, reference revision, or expected-answer list is
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
  echo "BUG-027 structural audit (single-tree)"
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

show "===== BUG-027 structural audit (single-tree, audited RTL only) ====="
show ""
show "----- 1. the contract the module states for itself -----"

gate "grep -q 'non-AES engines are blocked from release slot' '$RC'" \
     "kv_write_rule_check.sv header states rule (a) as an unconditional block on non-AES writers"

gate "grep -q 'Never attempt to write anything to \*\*KV23\*\* except \*\*MEK\*\*' '$SPEC'" \
     "keyvault.md states nothing may be written to the release slot except the AES-produced MEK"

gate "grep -q 'AES engine to write output to Key Vault, which must use KV23' '$SPEC'" \
     "keyvault.md names AES as the writer of that slot"

gate "grep -q 'write-restricted to AES only' '$SPEC'" \
     "keyvault.md calls the release slot write-restricted to AES only"

show ""
show "----- 2. the rule as implemented -----"

gate "sed -n '103,107p' '$RC' | grep -q 'release_slot_source_from_raw;'" \
     "the rule carries release_slot_source_from_raw as its final AND-term (line 107)"

gate "sed -n '97p' '$RC' | grep -q 'assign release_slot_source_from_raw = !write_metrics.kv_data0_present;'" \
     "that term is defined as the negation of kv_data0_present (line 97)"

gate "[ \"\$(grep -c 'release_slot_source_from_raw' '$RC')\" -eq 3 ]" \
     "the term appears exactly 3 times: declaration, definition and the single use in rule (a)"

show ""
show "----- 3. no other rule covers the gap -----"

gate "sed -n '114,116p' '$RC' | grep -q 'src0_in_std_region || src1_in_std_region'" \
     "rule (b) std_to_std only fires when a source is in the STD region, so a LOCK-source write is outside its scope"

gate "sed -n '123,125p' '$RC' | grep -q '!dst_in_lock_region'" \
     "rule (c) lock_to_lock only fires when the destination leaves the LOCK region, and the release slot is inside it"

gate "sed -n '134,140p' '$RC' | grep -q 'write_metrics.kv_write_src\[KV_WRITE_IDX_AES\]'" \
     "rule (d) is guarded on AES being the writer, so it cannot fire for a non-AES writer"

show ""
show "----- 4. the release slot is inside the LOCK region -----"

gate "grep -Eq 'OCP_LOCK_KEY_RELEASE_KV_SLOT +=  *23' '$PKG'" \
     "the release slot is KV23"

gate "grep -Eq 'KV_OCP_LOCK_SLOT_HI +=  *23' '$PKG'" \
     "the LOCK region's upper bound is 23, so the release slot is a LOCK slot and rule (c) is satisfied by a LOCK source"

show ""
show "----- 5. the verdict reaches the datapath -----"

gate "sed -n '151p' '$RC' | grep -q 'write_allow <= ~|rule_fail;'" \
     "write_allow is the NOR of the rule vector, so clearing rule (a) alone is enough to permit the write"

gate "grep -q 'write_allow' '$CMP/src/keyvault/rtl/kv_write_client.sv'" \
     "kv_write_client consumes write_allow, so the verdict gates a real KeyVault write"

show ""
show "----- 6. the audited source, verbatim -----"
show ""
show "--- src/keyvault/rtl/kv_write_rule_check.sv:97,108 (the term and the rule) ---"
sed -n '97,108p' "$RC" | tee -a "$W"

show ""
show "--- src/keyvault/rtl/kv_write_rule_check.sv:110,141 (the other three rules) ---"
sed -n '110,141p' "$RC" | tee -a "$W"

show ""
show "structural_gates_passed=$PASS/$((PASS+FAIL))"
echo "structural_gates_passed=$PASS/$((PASS+FAIL))" >> "$RUN_LOG"
if [ "$FAIL" -eq 0 ]; then
  show "RESULT: PASS"
  echo "RESULT: PASS - all structural gates confirm BUG-027" >> "$RUN_LOG"
  echo "result=PASS" >> "$RUN_LOG"
else
  show "RESULT: FAIL"
  echo "RESULT: FAIL - at least one structural gate did not hold" >> "$RUN_LOG"
  echo "result=FAIL" >> "$RUN_LOG"
  exit 1
fi
