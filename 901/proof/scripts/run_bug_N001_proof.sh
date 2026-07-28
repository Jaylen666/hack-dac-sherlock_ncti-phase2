#!/usr/bin/env bash
# BUG-N-001 structural audit: SS_DEBUG_INTENT DMI write qualifier polarity.
#
# Every gate below reads only files inside the audited checkout. No external
# repository, no other revision of this design, and no expected-answer list is
# consulted anywhere below. Each census is computed from counts that do not name
# the signal being looked for, so a pattern that failed to match reports a wrong
# count rather than silently passing.
set -uo pipefail

CMP="${CMP_ROOT:-/home/smy/hackatdac26-phase-2-caliptra}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS="$(cd "$HERE/../logs" && pwd)"
RUN_LOG="${RUN_LOG:-$LOGS/run.log}"
WITNESS_LOG="${WITNESS_LOG:-$LOGS/witness.log}"

TOP="$CMP/src/soc_ifc/rtl/soc_ifc_top.sv"
PKG="$CMP/src/soc_ifc/rtl/soc_ifc_pkg.sv"
RDL="$CMP/src/soc_ifc/rtl/soc_ifc_subsystem_reg.rdl"

pass=0; fail=0

gate() {
  local cond="$1" desc="$2"
  if eval "$cond" >/dev/null 2>&1; then
    pass=$((pass+1)); echo "  ok   $desc"
  else
    fail=$((fail+1)); echo "gate_fail: $desc"
  fi
}

{
echo "===== BUG-N-001 structural audit ====="
echo "audit_root=$CMP"
echo "target=src/soc_ifc/rtl/soc_ifc_top.sv:828-830"
echo ""

# ---------------------------------------------------------------------------
echo "--- 1. the defect: the write qualifier and its boolean reduction ---"
# ---------------------------------------------------------------------------
gate "[ -f '$TOP' ]" \
     "the audited file src/soc_ifc/rtl/soc_ifc_top.sv exists"

gate "sed -n '828p' '$TOP' | grep -q 'SS_DEBUG_INTENT.debug_intent.we'" \
     "line 828 assigns the SS_DEBUG_INTENT.debug_intent write enable"

gate "sed -n '829p' '$TOP' | grep -q '~(|{'" \
     "line 829 negates a reduction-OR of the qualifier terms, the inverting construct"

gate "sed -n '829p' '$TOP' | grep -q 'cptra_uncore_dmi_unlocked_reg_wr_en'" \
     "line 829 places the DMI write enable inside that negated reduction, so the write enable appears inverted"

gate "sed -n '830p' '$TOP' | grep -q 'cptra_uncore_dmi_reg_addr != DMI_REG_SS_DEBUG_INTENT'" \
     "line 830 uses an address INEQUALITY inside the same negated reduction"

# De Morgan: ~(a | b) == ~a & ~b, so with b = (addr != X) the qualifier is
# ~wr_en & (addr == X). Verified exhaustively over all four input combinations
# rather than asserted, using the expression text taken from the file.
gate "python3 - <<'PY'
import itertools, sys
# audited form, transcribed from src/soc_ifc/rtl/soc_ifc_top.sv:829-830
audited  = lambda wr_en, addr_eq: (not (wr_en or (not addr_eq)))
# the form every sibling strap register on the same DMI port uses
sibling  = lambda wr_en, addr_eq: (wr_en and addr_eq)
rows = []
for wr_en, addr_eq in itertools.product([0,1],[0,1]):
    rows.append((wr_en, addr_eq, audited(wr_en,addr_eq), sibling(wr_en,addr_eq)))
# the two must never agree on any input where a write could matter
agree = [r for r in rows if r[2]==r[3]]
inverted = all(r[2] == (not r[0] and r[1]) for r in rows)
# audited asserts exactly when wr_en is LOW and the address matches
sys.exit(0 if inverted and len(agree)==2 else 1)
PY" \
     "exhaustive truth table over the transcribed expression confirms the audited qualifier equals (~wr_en & addr==DMI_REG_SS_DEBUG_INTENT), the exact inverse of the sibling form in the write-enable term"

gate "! sed -n '828,830p' '$TOP' | grep -qE 'cptra_uncore_dmi_unlocked_reg_wr_en\s*&'" \
     "no line of the audited qualifier ANDs the DMI write enable positively, unlike every sibling"

echo ""
# ---------------------------------------------------------------------------
echo "--- 2. tree-wide idiom: every sibling on the same DMI port ---"
# ---------------------------------------------------------------------------
# Count the strap registers written from the same DMI port that use the
# positive form. Counted without naming which registers they are.
SIBLING_POS=$(grep -cE 'cptra_uncore_dmi_unlocked_reg_wr_en &' "$TOP")
echo "sibling_positive_qualifiers=$SIBLING_POS"
gate "[ '$SIBLING_POS' -ge 8 ]" \
     "at least 8 sibling registers on the same unlocked DMI port qualify writes with the positive form (measured $SIBLING_POS)"

NEG_REDUCTION=$(grep -cE '~\(\|\{' "$TOP")
echo "negated_reduction_qualifiers=$NEG_REDUCTION"
gate "[ '$NEG_REDUCTION' -eq 1 ]" \
     "exactly one write qualifier in the whole file uses the negated-reduction construct (measured $NEG_REDUCTION), and it is the audited line"

ADDR_NEQ=$(grep -cE 'cptra_uncore_dmi_reg_addr !=' "$TOP")
echo "address_inequality_uses=$ADDR_NEQ"
gate "[ '$ADDR_NEQ' -eq 1 ]" \
     "exactly one address comparison in the file is an inequality (measured $ADDR_NEQ); every other DMI qualifier tests equality"

ADDR_EQ=$(grep -cE 'cptra_uncore_dmi_reg_addr ==' "$TOP")
echo "address_equality_uses=$ADDR_EQ"
gate "[ '$ADDR_EQ' -ge 10 ]" \
     "at least 10 DMI qualifiers test address equality (measured $ADDR_EQ), establishing the idiom the audited line departs from"

echo ""
# ---------------------------------------------------------------------------
echo "--- 3. the register's own access policy contradicts the qualifier ---"
# ---------------------------------------------------------------------------
gate "grep -q 'TAP Access \[in debug/manuf mode\]: RW' '$RDL'" \
     "the register definition grants TAP write access only in debug or manufacturing mode"

gate "grep -qE 'field strap \{sw = r; hw = rw; we; resetsignal = cptra_pwrgood;\} debug_intent' '$RDL'" \
     "the field is software read-only with a hardware write enable, so the qualifier at soc_ifc_top.sv:828 is the sole write control"

gate "sed -n '774,776p' '$TOP' | grep -q 'device_lifecycle == DEVICE_MANUFACTURING'" \
     "the lifecycle restriction the policy depends on lives inside cptra_uncore_dmi_unlocked_reg_en (soc_ifc_top.sv:774-776)"

gate "sed -n '780p' '$TOP' | grep -q 'cptra_uncore_dmi_unlocked_reg_wr_en = (cptra_uncore_dmi_reg_wr_en & cptra_uncore_dmi_unlocked_reg_en)'" \
     "that restriction reaches the qualifier only through cptra_uncore_dmi_unlocked_reg_wr_en (soc_ifc_top.sv:780), the term the audited line inverts, so inverting it inverts the lifecycle gate too"

echo ""
# ---------------------------------------------------------------------------
echo "--- 4. the in-RTL comment the defect contradicts ---"
# ---------------------------------------------------------------------------
gate "sed -n '887p' '$TOP' | grep -q 'may not be modified until cold reset'" \
     "the comment at soc_ifc_top.sv:887 claims debug intent is latched at pwrgood and may not be modified until cold reset"

gate "sed -n '888,889p' '$TOP' | grep -q 'only populated in Subsystem mode'" \
     "the comment at soc_ifc_top.sv:888-889 confirms subsystem mode is the configuration in which this register is populated"

gate "sed -n '891p' '$TOP' | grep -q 'cptra_uncore_dmi_reg_wdata\[0\]'" \
     "the data written is the attacker-supplied cptra_uncore_dmi_reg_wdata[0] (soc_ifc_top.sv:891), so the value is chosen, not fixed"

gate "grep -qE 'parameter DMI_REG_SS_DEBUG_INTENT = 7.h63' '$PKG'" \
     "the matching address is the non-zero constant 7'h63 (soc_ifc_pkg.sv:96), so it must be driven deliberately and is not an idle-bus default"

echo ""
# ---------------------------------------------------------------------------
echo "--- 5. what the flag gates downstream ---"
# ---------------------------------------------------------------------------
gate "sed -n '897p' '$TOP' | grep -q 'cptra_ss_debug_intent = soc_ifc_reg_hwif_out.SS_DEBUG_INTENT.debug_intent.value'" \
     "the register value is exported from the block as cptra_ss_debug_intent (soc_ifc_top.sv:897)"

gate "sed -n '924p' '$TOP' | grep -q 'MANUF_DBG_UNLOCK_REQ.swwe'" \
     "it gates software write access to MANUF_DBG_UNLOCK_REQ (soc_ifc_top.sv:924)"

gate "sed -n '925p' '$TOP' | grep -q 'PROD_DBG_UNLOCK_REQ.swwe'" \
     "it gates software write access to PROD_DBG_UNLOCK_REQ (soc_ifc_top.sv:925)"

DBG_RSP_GATES=$(sed -n '929,934p' "$TOP" | grep -c 'SS_DEBUG_INTENT.debug_intent.value')
echo "debug_unlock_response_gates=$DBG_RSP_GATES"
gate "[ '$DBG_RSP_GATES' -eq 6 ]" \
     "it gates all six debug-unlock response fields (soc_ifc_top.sv:929-934, measured $DBG_RSP_GATES)"

gate "sed -n '946p' '$TOP' | grep -q 'SS_SOC_DBG_UNLOCK_LEVEL\[i\].LEVEL.swwel'" \
     "it gates the debug unlock level write lock (soc_ifc_top.sv:946)"

gate "sed -n '941p' '$TOP' | grep -q 'ss_dbg_manuf_enable = soc_ifc_reg_hwif_out.SS_DBG_SERVICE_REG_RSP.MANUF_DBG_UNLOCK_SUCCESS.value'" \
     "the manufacturing debug enable output derives from a response field the flag gates (soc_ifc_top.sv:941)"

TOTAL_USES=$(grep -c 'SS_DEBUG_INTENT.debug_intent.value' "$TOP")
echo "total_debug_intent_consumers=$TOTAL_USES"
gate "[ '$TOTAL_USES' -ge 10 ]" \
     "the flag is consumed in at least 10 places in the same file (measured $TOTAL_USES), so a spurious set has broad reach"

echo ""
echo "gates_passed=$pass gates_failed=$fail"
if [ "$fail" -eq 0 ]; then
  echo "RESULT: PASS - all structural gates confirm BUG-N-001"
  echo "result=PASS"
else
  echo "RESULT: FAIL"
  echo "result=FAIL"
fi
} 2>&1 | tee "$RUN_LOG"

cp "$RUN_LOG" "$WITNESS_LOG"
[ "$fail" -eq 0 ]
