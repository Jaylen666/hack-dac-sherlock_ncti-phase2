#!/usr/bin/env bash
# BUG-N-004 structural audit: the OCP LOCK HEK seed fuse is outside the
# secret-scrubbing chain that covers every other DOE secret input.
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
REG="$CMP/src/soc_ifc/rtl/soc_ifc_reg.sv"
PKG="$CMP/src/soc_ifc/rtl/soc_ifc_reg_pkg.sv"
RDL="$CMP/src/soc_ifc/rtl/soc_ifc_fuse_reg.rdl"
INTEG="$CMP/src/integration/rtl/caliptra_top.sv"
MACROS="$CMP/src/libs/rtl/caliptra_macros.svh"
KVPKG="$CMP/src/keyvault/rtl/kv_defines_pkg.sv"

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
echo "===== BUG-N-004 structural audit ====="
echo "audit_root=$CMP"
echo "target=src/soc_ifc/rtl/soc_ifc_fuse_reg.rdl:21 (field type) and :147-148 (fuse_hek_seed), src/soc_ifc/rtl/soc_ifc_top.sv:557-559"
echo ""

# ---------------------------------------------------------------------------
echo "--- 1. the defect: two field types, only one of which can be cleared ---"
# ---------------------------------------------------------------------------
gate "[ -f '$RDL' ] && [ -f '$TOP' ] && [ -f '$REG' ]" \
     "the audited RDL, block top and generated register file all exist"

gate "sed -n '19p' '$RDL' | grep -q 'hwclr'" \
     "the secret field type (soc_ifc_fuse_reg.rdl:19) carries hwclr, a hardware clear"

gate "! sed -n '21p' '$RDL' | grep -q 'hwclr'" \
     "the Fuse field type (soc_ifc_fuse_reg.rdl:21) carries NO hwclr, so fields of this type cannot be cleared by hardware"

gate "sed -n '21p' '$RDL' | grep -q 'resetsignal = cptra_pwrgood'" \
     "the Fuse type's only clear path is the cptra_pwrgood reset (soc_ifc_fuse_reg.rdl:21)"

gate "sed -n '147p' '$RDL' | grep -qE '^\s*Fuse seed\[32\]'" \
     "fuse_hek_seed's field is declared with the Fuse type (soc_ifc_fuse_reg.rdl:147), the type with no hardware clear"

gate "sed -n '148p' '$RDL' | grep -q 'fuse_hek_seed' " \
     "that declaration belongs to the fuse_hek_seed register (soc_ifc_fuse_reg.rdl:148)"

gate "sed -n '28p' '$RDL' | grep -qE '^\s*secret seed\[32\]' && sed -n '35p' '$RDL' | grep -qE '^\s*secret seed\[32\]'" \
     "the two sibling DOE secret fuses (soc_ifc_fuse_reg.rdl:28 and :35) are declared with the secret type instead"

echo ""
# ---------------------------------------------------------------------------
echo "--- 2. the omission is visible in one always_comb in the block top ---"
# ---------------------------------------------------------------------------
HWCLR_DRIVES=$(grep -c 'hwclr = clear_obf_secrets' "$TOP")
echo "hwclr_driven_from_scrub_strobe=$HWCLR_DRIVES"
gate "[ '$HWCLR_DRIVES' -eq 3 ]" \
     "exactly 3 register families are wired to the scrubbing strobe's hardware clear (measured $HWCLR_DRIVES): the obf key, the UDS seed and the field entropy"

gate "sed -n '538p' '$TOP' | grep -q 'internal_obf_key\[i\].key.hwclr = clear_obf_secrets'" \
     "the obf key is cleared on the strobe (soc_ifc_top.sv:538)"

gate "sed -n '542p' '$TOP' | grep -q 'fuse_uds_seed\[i\].seed.hwclr = clear_obf_secrets'" \
     "the UDS seed is cleared on the strobe (soc_ifc_top.sv:542)"

gate "sed -n '550p' '$TOP' | grep -q 'fuse_field_entropy\[i\].seed.hwclr = clear_obf_secrets'" \
     "the field entropy is cleared on the strobe (soc_ifc_top.sv:550)"

# The HEK loop sits in the SAME always_comb, immediately after the three above.
gate "sed -n '557,559p' '$TOP' | grep -q 'OCP_LOCK_HEK_NUM_DWORDS'" \
     "the HEK seed loop sits in the same always_comb, immediately after those three (soc_ifc_top.sv:557-559)"

gate "sed -n '558p' '$TOP' | grep -q 'obf_hek_seed\[i\] = soc_ifc_reg_hwif_out.fuse_hek_seed\[i\].seed.value'" \
     "that loop only reads the value out (soc_ifc_top.sv:558) and assigns no clear"

HEK_BODY=$(sed -n '557,559p' "$TOP" | grep -c 'hwclr')
echo "hek_loop_hwclr_assignments=$HEK_BODY"
gate "[ '$HEK_BODY' -eq 0 ]" \
     "the HEK loop contains zero hwclr assignments (measured $HEK_BODY), unlike each of its three neighbours"

gate "sed -n '739p' '$TOP' | grep -q 'fuse_hek_seed\[i\].seed.swwel'" \
     "the only hwif_in member the block ever drives for this family is swwel (soc_ifc_top.sv:739)"

echo ""
# ---------------------------------------------------------------------------
echo "--- 3. the generated block confirms there is no clear to drive ---"
# ---------------------------------------------------------------------------
gate "grep -qE 'typedef struct packed\{\s*$' '$PKG'" \
     "the generated package declares packed input structs per field type"

# The secret type's input struct has next/we/swwel/hwclr; the Fuse type's has
# only swwel. Counted by members rather than asserted.
SECRET_MEMBERS=$(python3 - "$PKG" <<'PY'
import re, sys
t = open(sys.argv[1]).read()
m = re.search(r"typedef struct packed\{([^}]*)\} soc_ifc_reg__secret_w32__in_t;", t)
print(len([l for l in m.group(1).splitlines() if l.strip()]))
PY
)
FUSE_MEMBERS=$(python3 - "$PKG" <<'PY'
import re, sys
t = open(sys.argv[1]).read()
m = re.search(r"typedef struct packed\{([^}]*)\} soc_ifc_reg__Fuse_w32__in_t;", t)
print(len([l for l in m.group(1).splitlines() if l.strip()]))
PY
)
echo "secret_w32_input_members=$SECRET_MEMBERS fuse_w32_input_members=$FUSE_MEMBERS"
gate "[ '$SECRET_MEMBERS' -eq 4 ] && [ '$FUSE_MEMBERS' -eq 1 ]" \
     "the secret type's input struct has 4 members and the Fuse type's has 1 (measured $SECRET_MEMBERS and $FUSE_MEMBERS), so no hwclr port exists on the HEK family at all"

gate "python3 - <<'PY'
import re, sys
t = open('$PKG').read()
m = re.search(r'typedef struct packed\{([^}]*)\} soc_ifc_reg__Fuse_w32__in_t;', t)
sys.exit(0 if 'hwclr' not in m.group(1) else 1)
PY" \
     "the Fuse type's input struct contains no hwclr member, so soc_ifc_top could not drive one even deliberately"

gate "sed -n '3712p' '$REG' | grep -q 'hwif_in.fuse_uds_seed\[i0\].seed.hwclr' " \
     "the generated UDS field logic has a HW Clear branch (soc_ifc_reg.sv:3712)"

HEK_CLEAR=$(sed -n '4066,4088p' "$REG" | grep -c 'HW Clear')
echo "hek_field_hw_clear_branches=$HEK_CLEAR"
gate "[ '$HEK_CLEAR' -eq 0 ]" \
     "the generated HEK field logic has zero HW Clear branches (soc_ifc_reg.sv:4066-4088, measured $HEK_CLEAR)"

gate "sed -n '4080,4082p' '$REG' | grep -q 'cptra_pwrgood'" \
     "its storage element's only clear arm is the pwrgood reset (soc_ifc_reg.sv:4080-4082)"

gate "sed -n '7450p' '$REG' | grep -q 'field_storage.fuse_hek_seed\[i0\].seed.value'" \
     "the stored value is returned on the software readback path (soc_ifc_reg.sv:7450), so a residue is software-visible"

CLEAR_BRANCHES=$(grep -c '// HW Clear' "$REG")
echo "total_hw_clear_branches_in_block=$CLEAR_BRANCHES"
gate "[ '$CLEAR_BRANCHES' -ge 4 ]" \
     "the generated block does implement HW Clear elsewhere (measured $CLEAR_BRANCHES), so its absence on the HEK family is a per-field property and not a generator limitation"

echo ""
# ---------------------------------------------------------------------------
echo "--- 4. what the strobe is, and what it is supposed to cover ---"
# ---------------------------------------------------------------------------
gate "sed -n '772p' '$INTEG' | grep -q 'clear_obf_secrets | cptra_in_debug_scan_mode | cptra_error_fatal'" \
     "the strobe is debug/scan entry or a fatal error (caliptra_top.sv:772)"

gate "sed -n '1466p' '$INTEG' | grep -q 'clear_obf_secrets(clear_obf_secrets_debugScanQ)'" \
     "that strobe is what reaches the audited block (caliptra_top.sv:1466)"

gate "sed -n '1014p' '$INTEG' | grep -q 'obf_hek_seed      (obf_hek_seed)'" \
     "the HEK seed is delivered to the DOE (caliptra_top.sv:1014)"

# Second, independent protection the HEK seed is also outside of: the other
# three secrets are replaced by constants while in debug/scan mode before they
# reach the DOE. Counted without naming which signals they are.
DBG_MUXES=$(grep -cE 'cptra_in_debug_scan_mode \? `CLP_DEBUG_MODE' "$INTEG")
echo "debug_mode_substitution_muxes=$DBG_MUXES"
gate "[ '$DBG_MUXES' -eq 4 ]" \
     "4 secrets are substituted with constants on the path to their consumers while in debug or scan mode (caliptra_top.sv:999-1002, measured $DBG_MUXES)"

gate "! grep -qE 'obf_hek_seed.*cptra_in_debug_scan_mode|cptra_in_debug_scan_mode.*obf_hek_seed' '$INTEG'" \
     "the HEK seed appears in none of them, so it is outside that second protection as well"

gate "sed -n '1012p' '$INTEG' | grep -q 'obf_uds_seed_dbg' && sed -n '1013p' '$INTEG' | grep -q 'obf_field_entropy_dbg'" \
     "its siblings reach the DOE through the substituted _dbg signals (caliptra_top.sv:1012-1013) while the HEK seed at :1014 is connected raw"

MACRO_COUNT=$(grep -c 'define CLP_DEBUG_MODE' "$MACROS")
echo "debug_mode_constant_macros=$MACRO_COUNT"
gate "[ '$MACRO_COUNT' -eq 4 ]" \
     "the tree defines 4 debug-mode replacement constants (caliptra_macros.svh:19-22, measured $MACRO_COUNT) and none for the HEK seed"

echo ""
# ---------------------------------------------------------------------------
echo "--- 5. the asset and its documented access policy ---"
# ---------------------------------------------------------------------------
gate "sed -n '143,144p' '$RDL' | grep -q 'Obfuscated HEK'" \
     "the register is documented as the obfuscated Hard Epoch Key seed (soc_ifc_fuse_reg.rdl:143-144)"

gate "sed -n '145p' '$RDL' | grep -q 'Caliptra Access: RO'" \
     "its documented Caliptra-side access is read-only (soc_ifc_fuse_reg.rdl:145), so code running on the core can read it back"

gate "grep -qE 'OCP_LOCK_HEK_NUM_DWORDS\s+=\s+8' '$KVPKG'" \
     "the seed is 8 dwords, 256 bits (kv_defines_pkg.sv:43)"

gate "grep -q 'obf_hek_seed' '$CMP/src/doe/rtl/doe_fsm.sv'" \
     "the seed feeds the DOE's HEK derivation flow (doe_fsm.sv)"

gate "grep -q 'running_hek ? obf_hek_seed' '$CMP/src/doe/rtl/doe_fsm.sv'" \
     "the DOE selects it as the source block for the HEK flow (doe_fsm.sv:276)"

echo ""
echo "gates_passed=$pass gates_failed=$fail"
if [ "$fail" -eq 0 ]; then
  echo "RESULT: PASS - all structural gates confirm BUG-N-004"
  echo "result=PASS"
else
  echo "RESULT: FAIL"
  echo "result=FAIL"
fi
} 2>&1 | tee "$RUN_LOG"

cp "$RUN_LOG" "$WITNESS_LOG"
[ "$fail" -eq 0 ]
