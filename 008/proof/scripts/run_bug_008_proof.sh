#!/usr/bin/env bash
# BUG-008 structural audit: the strict MuBi4 "true" test accepts a 1-bit error.
#
# The finding is established entirely from evidence inside the audited tree. The
# argument is that the package contradicts itself three ways over: its other
# three widths implement the same strict test as an exact equality, its own
# mubi4_test_false_strict is an exact equality, and its own mubi4_test_invalid
# classifies the very encoding that mubi4_test_true_strict accepts as invalid.
# No external repository, reference revision, or expected-answer list is
# consulted anywhere below.
set -euo pipefail

CMP="${CMP_ROOT:-/home/smy/hackatdac26-phase-2-caliptra}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS="$(cd "$HERE/../logs" && pwd)"
W="$LOGS/witness.log"
RUN_LOG="$LOGS/run.log"
PKG="$CMP/src/caliptra_prim/rtl/caliptra_prim_mubi_pkg.sv"
ABR="$CMP/submodules/adams-bridge/src/abr_prim/rtl/abr_prim_mubi_pkg.sv"
CSRNG="$CMP/src/csrng/rtl/csrng_core.sv"

PASS=0; FAIL=0
: > "$W"
{
  echo "BUG-008 structural audit (single-tree)"
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

show "===== BUG-008 structural audit (single-tree, audited RTL only) ====="
show "audit_root=$CMP"
show ""

show "----- 1. the defect: the strict test admits a delta, not an equality -----"

gate "sed -n '46p' '$PKG' | grep -q 'function automatic logic mubi4_test_true_strict'" \
     "caliptra_prim_mubi_pkg.sv:46 declares mubi4_test_true_strict"
gate "sed -n '48p' '$PKG' | grep -q 'delta = val ^ MuBi4True'" \
     "caliptra_prim_mubi_pkg.sv:48 computes a delta against MuBi4True instead of comparing for equality"
gate "sed -n \"49p\" '$PKG' | grep -q \"delta inside {4'h0, 4'h1}\"" \
     "caliptra_prim_mubi_pkg.sv:49 returns true for delta 4'h0 AND delta 4'h1, so one specific bit may differ"
gate "sed -n '29p' '$PKG' | grep -q \"MuBi4True = 4'h6\"" \
     "MuBi4True is 4'h6 (caliptra_prim_mubi_pkg.sv:29), so the extra accepted encoding is 4'h7"
gate "sed -n '30p' '$PKG' | grep -q \"MuBi4False = 4'h9\"" \
     "MuBi4False is 4'h9 (caliptra_prim_mubi_pkg.sv:30), the bitwise complement, which is what makes single-bit faults detectable"

show ""
show "----- 2. in-file control: the same package's other three widths -----"

gate "sed -n '181p' '$PKG' | grep -q 'return MuBi8True == val'" \
     "mubi8_test_true_strict is an exact equality (caliptra_prim_mubi_pkg.sv:181)"
gate "sed -n '313p' '$PKG' | grep -q 'return MuBi12True == val'" \
     "mubi12_test_true_strict is an exact equality (caliptra_prim_mubi_pkg.sv:313)"
gate "sed -n '445p' '$PKG' | grep -q 'return MuBi16True == val'" \
     "mubi16_test_true_strict is an exact equality (caliptra_prim_mubi_pkg.sv:445)"
gate "sed -n '56p' '$PKG' | grep -q 'return MuBi4False == val'" \
     "even mubi4's own false_strict is an exact equality (caliptra_prim_mubi_pkg.sv:56)"

# Census: count strict-true functions and how many are exact equalities. Counting
# declarations independently of bodies means a regex miss fails loudly.
STRICT_DECLS=$(grep -c 'function automatic logic mubi[0-9]*_test_true_strict' "$PKG")
STRICT_EQ=$(grep -cE 'return MuBi[0-9]+True == val;' "$PKG")
STRICT_DELTA=$(grep -cE 'delta inside \{' "$PKG")
echo "strict_true_declarations=$STRICT_DECLS" | tee -a "$W" >> "$RUN_LOG"
echo "strict_true_exact_equality=$STRICT_EQ" | tee -a "$W" >> "$RUN_LOG"
echo "strict_true_delta_form=$STRICT_DELTA" | tee -a "$W" >> "$RUN_LOG"
show "strict_true_declarations=$STRICT_DECLS exact_equality=$STRICT_EQ delta_form=$STRICT_DELTA"

gate "[ \"$STRICT_DECLS\" = '4' ]" \
     "the package declares exactly 4 strict-true tests, one per MuBi width, a self-validating control population"
gate "[ \"$STRICT_EQ\" = '3' ]" \
     "3 of the 4 are exact equalities"
gate "[ \"$STRICT_DELTA\" = '1' ]" \
     "exactly 1 uses the delta form, so the defect is a unique outlier within its own package"
gate "[ \$(( STRICT_EQ + STRICT_DELTA )) = \"$STRICT_DECLS\" ]" \
     "the two forms account for every declaration, so no strict-true site was missed by the census"

show ""
show "----- 3. in-file control: the comment the outlier lost -----"

gate "sed -n '177,179p' '$PKG' | grep -q 'requires'" \
     "mubi8's strict test carries the package's standard 3-line contract comment (\"requires the multibit value to equal True\")"
gate "sed -n '309,311p' '$PKG' | grep -q 'requires'" \
     "mubi12's does too (caliptra_prim_mubi_pkg.sv:309-311)"
gate "sed -n '441,443p' '$PKG' | grep -q 'requires'" \
     "mubi16's does too (caliptra_prim_mubi_pkg.sv:441-443)"
gate "sed -n '45p' '$PKG' | grep -q 'Decode the asserted multibit state'" \
     "mubi4's contract comment has been replaced with a one-line description (caliptra_prim_mubi_pkg.sv:45), so the stated requirement is absent exactly where the code violates it"
gate "! sed -n '44,46p' '$PKG' | grep -q 'equal True'" \
     "no surviving comment near mubi4_test_true_strict claims the equality contract, so the deviation is silent"

show ""
show "----- 4. tree control: the second MuBi package in the same tree -----"

gate "sed -n '44p' '$ABR' | grep -q 'return MuBi4True == val'" \
     "abr_prim_mubi_pkg.sv:44 implements the same mubi4_test_true_strict as an exact equality"
gate "grep -q \"MuBi4True = 4'h6\" '$ABR'" \
     "it uses the same 4'h6 encoding, so the two packages are directly comparable"
gate "! grep -q 'delta inside' '$ABR'" \
     "the second package contains no delta form at all, so the tree carries both an idiom and its violation"

show ""
show "----- 5. the accepted encoding is classified invalid by the same file -----"

gate "sed -n '37p' '$PKG' | grep -q 'val inside {MuBi4True, MuBi4False}'" \
     "mubi4_test_invalid admits only 4'h6 and 4'h9 (caliptra_prim_mubi_pkg.sv:37), so 4'h7 is an invalid encoding by the package's own definition"
gate "sed -n '33p' '$PKG' | grep -q 'CheckMuBi4ValsComplementary_A'" \
     "the package asserts statically that True and False are bitwise complements (caliptra_prim_mubi_pkg.sv:33), the property the strict tests exist to enforce"

show ""
show "----- 6. security consumers: the strict test gates SEC_CM countermeasures -----"

CONSUMERS=$(grep -rn 'mubi4_test_true_strict' --include=*.sv "$CMP/src" | grep -vc 'caliptra_prim_mubi_pkg.sv')
echo "strict_true_consumer_sites=$CONSUMERS" | tee -a "$W" >> "$RUN_LOG"
show "strict_true_consumer_sites=$CONSUMERS"
gate "[ \"$CONSUMERS\" -ge 50 ]" \
     "the weakened function has $CONSUMERS call sites across the audited tree, so the defect is not confined to one block"

gate "sed -n '794p' '$CSRNG' | grep -q 'cs_enable_fo\[i\] = mubi4_test_true_strict'" \
     "csrng_core.sv:794 derives the CSRNG enable from the weakened strict test"
gate "sed -n '830p' '$CSRNG' | grep -q 'read_int_state_pfe = mubi4_test_true_strict'" \
     "csrng_core.sv:830 derives read_int_state_pfe, which permits reading CSRNG internal state, from it"
gate "sed -n '811p' '$CSRNG' | grep -q 'sw_app_enable_pfe = mubi4_test_true_strict'" \
     "csrng_core.sv:811 derives the software application enable from it"
gate "sed -n '1148p' '$CSRNG' | grep -q 'flag0_fo\[i\] = mubi4_test_true_strict'" \
     "csrng_core.sv:1148 derives flag0, the deterministic-mode flag, from it"
gate "sed -n '786p' '$CSRNG' | grep -q 'SEC_CM: CONFIG.MUBI'" \
     "csrng_core.sv:786 marks these as a SEC_CM countermeasure, so the tree itself designates them security-critical"
gate "[ \"\$(grep -c 'SEC_CM: CONFIG.MUBI' '$CSRNG')\" = '4' ]" \
     "csrng_core.sv carries 4 such SEC_CM CONFIG.MUBI sites, all of them reading through the weakened test"

show ""
show "----- 7. software reachability of the accepted encoding -----"

gate "sed -n '788p' '$CSRNG' | grep -q 'mubi_cs_enable = mubi4_t.(reg2hw.ctrl.enable.q)'" \
     "csrng_core.sv:788 takes the enable encoding straight from a software register field, so software chooses the 4-bit value"
gate "sed -n '829p' '$CSRNG' | grep -q 'mubi_read_int_state = mubi4_t.(reg2hw.ctrl.read_int_state.q)'" \
     "csrng_core.sv:829 does the same for read_int_state, so a software write of 4'h7 reaches the strict test directly"
gate "sed -n '831p' '$CSRNG' | grep -q 'read_int_state_pfa = mubi4_test_invalid'" \
     "csrng_core.sv:831 routes the same field to mubi4_test_invalid, so 4'h7 raises the field alert AND is accepted as true in the same cycle"
gate "sed -n '832,833p' '$CSRNG' | grep -q 'recov_alert_sts'" \
     "csrng_core.sv:832-833 reports it as a recoverable alert, which does not gate the function, so the permission is granted despite detection"

show ""
show "--- src/caliptra_prim/rtl/caliptra_prim_mubi_pkg.sv:32-57 (the defect and its in-file controls) ---"
sed -n '32,57p' "$PKG" | tee -a "$W"

show ""
show "--- src/caliptra_prim/rtl/caliptra_prim_mubi_pkg.sv:176,190 (the idiom, at MuBi8) ---"
sed -n '176,190p' "$PKG" | tee -a "$W"

show ""
show "structural_gates_passed=$PASS/$((PASS+FAIL))"
echo "structural_gates_passed=$PASS/$((PASS+FAIL))" >> "$RUN_LOG"
if [ "$FAIL" -eq 0 ]; then
  show "RESULT: PASS"
  echo "RESULT: PASS - all structural gates confirm BUG-008" >> "$RUN_LOG"
  echo "result=PASS" >> "$RUN_LOG"
else
  show "RESULT: FAIL"
  echo "RESULT: FAIL - at least one structural gate did not hold" >> "$RUN_LOG"
  echo "result=FAIL" >> "$RUN_LOG"
  exit 1
fi
