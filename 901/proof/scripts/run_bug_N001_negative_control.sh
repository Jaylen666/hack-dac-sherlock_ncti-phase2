#!/usr/bin/env bash
# BUG-N-001 negative control.
#
# Restores the sibling form of the write qualifier in a scratch copy of
# soc_ifc_top.sv, then runs the IDENTICAL testbench against it. The witness must
# stop firing, both defect covers must drop to zero for anti-vacuity, the two
# violating checks must flip to passing, and both harness controls plus the
# containment case must still pass.
#
# Both sides of the size gate below are the audited file and my own patched
# scratch copy of it; no other tree is involved.
set -uo pipefail

CMP="${CMP_ROOT:-/home/smy/hackatdac26-phase-2-caliptra}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS="$(cd "$HERE/../logs" && pwd)"
SCRATCH="$HERE/../scratch"
NC_LOG="${NC_LOG:-$LOGS/negative_control.log}"

# Raw transcripts from the patched scratch copy live outside proof/logs/. That
# run is EXPECTED to end in result=FAIL, because the bench demands the two
# violating checks fail and on the corrected qualifier they pass; keeping the
# transcripts here stops that intended flip from being read as a failing proof
# log. The authoritative verdict for this control is NC_LOG.
NC_RUN="$HERE/../negative_control_run"
mkdir -p "$NC_RUN"

rm -rf "$SCRATCH"; mkdir -p "$SCRATCH"
PATCHED="$SCRATCH/soc_ifc_top.sv"

python3 - "$CMP/src/soc_ifc/rtl/soc_ifc_top.sv" "$PATCHED" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()

old = """    soc_ifc_reg_hwif_in.SS_DEBUG_INTENT.debug_intent.we       = strap_we_pre_fuse_done |
                                                                           ~(|{cptra_uncore_dmi_unlocked_reg_wr_en,
                                                                               (cptra_uncore_dmi_reg_addr != DMI_REG_SS_DEBUG_INTENT)});"""

assert text.count(old) == 1, "expected exactly one audited qualifier to patch"
# Confirm we are patching the inverted form, not an already-correct one.
assert "~(|{" in old, "the text being replaced is not the negated-reduction form"

new = """    soc_ifc_reg_hwif_in.SS_DEBUG_INTENT.debug_intent.we       = strap_we_pre_fuse_done |
                                                                           (cptra_uncore_dmi_unlocked_reg_wr_en &
                                                                            (cptra_uncore_dmi_reg_addr == DMI_REG_SS_DEBUG_INTENT));"""

open(dst, "w").write(text.replace(old, new, 1))
print("patched: write qualifier restored to the sibling positive form", file=sys.stderr)
PY
[ $? -eq 0 ] || { echo "gate_fail: could not patch the scratch copy"; exit 1; }

# The patch must replace three lines with three lines and touch nothing else.
read -r DIFF_ADDED DIFF_REMOVED <<EOF
$(python3 - "$CMP/src/soc_ifc/rtl/soc_ifc_top.sv" "$PATCHED" <<'PY'
import sys, difflib
def code(p):
    return [l for l in open(p).read().splitlines()
            if not l.strip().startswith("//")]
a, b = code(sys.argv[1]), code(sys.argv[2])
d = list(difflib.ndiff(a, b))
print(sum(1 for l in d if l.startswith("+ ")),
      sum(1 for l in d if l.startswith("- ")))
PY
)
EOF

export TMPDIR="${TMPDIR:-/home/smy/.cache/vcstmp}"
mkdir -p "$TMPDIR"

DUT_SOC_IFC_TOP="$PATCHED" \
SIM_LOG="$NC_RUN/negative_control_sim.log" \
CMP_LOG="$NC_RUN/negative_control_compile.log" \
  bash "$HERE/run_bug_N001_sim.sh" > "$NC_RUN/negative_control_stdout.log" 2>&1
NC_RC=$?

SIM="$NC_RUN/negative_control_sim.log"
val() { grep -oP "(?<=^$1=)[0-9]+" "$SIM" | tail -1; }
# fails= shares a line with checks=, so it is not anchored at line start.
val_inline() { grep -oP "(?<=\b$1=)[0-9]+" "$SIM" | tail -1; }

WIT=$(val witness_hits);       TBF=$(val_inline fails)
C_SURV=$(val cov_no_write_sets_intent)
C_LEGIT=$(val cov_legit_write_ignored)
C_RST=$(val cov_reset_clear)
C_MISM=$(val cov_addr_mismatch_no_write)
NOWRITE_OK=$(grep -c 'case=violating_no_dmi_write_sets_debug_intent PASS' "$SIM")
LEGIT_OK=$(grep -c 'case=violating_legitimate_dmi_write_is_ignored PASS' "$SIM")
RST_OK=$(grep -c 'case=control_reset_leaves_debug_intent_clear PASS' "$SIM")
MISM_OK=$(grep -c 'case=control_addr_mismatch_no_write PASS' "$SIM")
CONT_OK=$(grep -c 'case=containment_pwrgood_reset_clears PASS' "$SIM")

pass=0; fail=0
gate() {
  if [ "$1" = "$2" ]; then pass=$((pass+1)); echo "  ok   $3"
  else fail=$((fail+1)); echo "gate_fail: $3 (expected $2, got $1)"; fi
}

{
echo "===== BUG-N-001 negative control ====="
echo "patch=write qualifier at soc_ifc_top.sv:828-830 restored to the sibling positive form"
echo "scratch_code_lines_added=$DIFF_ADDED scratch_code_lines_removed=$DIFF_REMOVED"
echo "sim_script_rc=$NC_RC"
echo "witness_hits=${WIT:-unset}"
echo "cov_no_write_sets_intent=${C_SURV:-unset}"
echo "cov_legit_write_ignored=${C_LEGIT:-unset}"
echo "cov_reset_clear=${C_RST:-unset}"
echo "cov_addr_mismatch_no_write=${C_MISM:-unset}"
echo "tb_fails=${TBF:-unset}"
echo "--- gates ---"
# The first of the three lines is identical in both forms, so only the two
# lines carrying the qualifier terms change.
gate "$DIFF_ADDED" "2" "the patch replaces exactly two code lines"
gate "$DIFF_REMOVED" "2" "and removes exactly two, so nothing else moved"
gate "${WIT:-unset}" "0" "the witness no longer fires on the patched copy"
gate "${C_SURV:-unset}" "0" "cov_no_write_sets_intent drops to 0 (anti-vacuity)"
gate "${C_LEGIT:-unset}" "0" "cov_legit_write_ignored drops to 0 (anti-vacuity)"
gate "${TBF:-unset}" "0" "no TB check fails once the polarity is correct"
gate "$NOWRITE_OK" "1" "the no-DMI-write check now passes"
gate "$LEGIT_OK" "1" "the legitimate-write check now passes"
gate "$RST_OK" "1" "harness control intact: reset still leaves the flag clear"
gate "$MISM_OK" "1" "harness control intact: a mismatched address still writes nothing"
gate "$CONT_OK" "1" "containment case still passes"
if [ "$fail" -eq 0 ]; then
  echo "NEGATIVE CONTROL: PASS"
else
  echo "NEGATIVE CONTROL: FAIL"
fi
} 2>&1 | tee "$NC_LOG"

[ "$fail" -eq 0 ]
