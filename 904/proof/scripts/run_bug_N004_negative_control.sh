#!/usr/bin/env bash
# BUG-N-004 negative control.
#
# Gives the HEK seed family the hardware clear its sibling DOE secrets already
# have, in a scratch copy of soc_ifc_reg.sv, then runs the IDENTICAL testbench
# against it. The witness must stop firing, the defect cover must drop to zero
# for anti-vacuity, the three violating checks must flip to passing, and all
# three harness controls plus the containment case must still pass.
#
# The patch mirrors the sibling arm exactly. src/soc_ifc/rtl/soc_ifc_reg.sv:3712
# gives fuse_uds_seed a HW Clear branch; the same three lines are inserted into
# the fuse_hek_seed field logic, and the hwclr member is added to the Fuse_w32
# input struct so there is something to drive. Both sides of the size gate below
# are the audited file and my own patched scratch copy of it; no other tree is
# involved.
#
# Note on scope: the real fix belongs in the RDL (declare fuse_hek_seed with the
# secret field type, or a type carrying hwclr) and would be re-generated into
# this block. Patching the generated output is the faithful way to test that fix
# here, because the generator is not part of the audited tree.
set -uo pipefail

CMP="${CMP_ROOT:-/home/smy/hackatdac26-phase-2-caliptra}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS="$(cd "$HERE/../logs" && pwd)"
SCRATCH="$HERE/../scratch"
NC_LOG="${NC_LOG:-$LOGS/negative_control.log}"

# Raw transcripts from the patched scratch copy live outside proof/logs/. That
# run is EXPECTED to end without the audited signature, because the bench demands
# the three violating checks fail and on the corrected field they pass; keeping
# the transcripts here stops that intended flip from being read as a failing
# proof log. The authoritative verdict for this control is NC_LOG.
NC_RUN="$HERE/../negative_control_run"
mkdir -p "$NC_RUN"

rm -rf "$SCRATCH"; mkdir -p "$SCRATCH"
PATCHED_PKG="$SCRATCH/soc_ifc_reg_pkg.sv"
PATCHED_REG="$SCRATCH/soc_ifc_reg.sv"

python3 - "$CMP/src/soc_ifc/rtl/soc_ifc_reg_pkg.sv" "$PATCHED_PKG" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()

# The Fuse_w32 input struct carries only swwel, which is why soc_ifc_top has no
# hwclr member to drive for this family. Add one, matching secret_w32.
old = """    typedef struct packed{
        logic swwel;
    } soc_ifc_reg__Fuse_w32__in_t;"""
assert text.count(old) == 1, "expected exactly one Fuse_w32 input struct"
assert "hwclr" not in old, "the struct being patched already has a clear member"

new = """    typedef struct packed{
        logic swwel;
        logic hwclr;
    } soc_ifc_reg__Fuse_w32__in_t;"""

open(dst, "w").write(text.replace(old, new, 1))
print("patched pkg: Fuse_w32 input struct gained an hwclr member", file=sys.stderr)
PY
[ $? -eq 0 ] || { echo "gate_fail: could not patch the scratch package"; exit 1; }

python3 - "$CMP/src/soc_ifc/rtl/soc_ifc_reg.sv" "$PATCHED_REG" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()

# The audited HEK field logic: a SW write arm and nothing else.
old = """            if(decoded_reg_strb.fuse_hek_seed[i0] && decoded_req_is_wr && !(hwif_in.fuse_hek_seed[i0].seed.swwel)) begin // SW write
                next_c = (field_storage.fuse_hek_seed[i0].seed.value & ~decoded_wr_biten[31:0]) | (decoded_wr_data[31:0] & decoded_wr_biten[31:0]);
                load_next_c = '1;
            end"""
assert text.count(old) == 1, "expected exactly one fuse_hek_seed field arm"
assert "hwclr" not in old, "the arm being patched already has a clear branch"

# The sibling form, transcribed from the fuse_uds_seed arm at :3712-3714.
new = """            if(hwif_in.fuse_hek_seed[i0].seed.hwclr) begin // HW Clear
                next_c = '0;
                load_next_c = '1;
            end else if(decoded_reg_strb.fuse_hek_seed[i0] && decoded_req_is_wr && !(hwif_in.fuse_hek_seed[i0].seed.swwel)) begin // SW write
                next_c = (field_storage.fuse_hek_seed[i0].seed.value & ~decoded_wr_biten[31:0]) | (decoded_wr_data[31:0] & decoded_wr_biten[31:0]);
                load_next_c = '1;
            end"""

open(dst, "w").write(text.replace(old, new, 1))
print("patched reg: fuse_hek_seed gained the sibling HW Clear branch", file=sys.stderr)
PY
[ $? -eq 0 ] || { echo "gate_fail: could not patch the scratch register block"; exit 1; }

# The register patch must add exactly the three lines of the clear branch and
# remove none; the package patch must add exactly one line.
read -r REG_ADDED REG_REMOVED <<EOF
$(python3 - "$CMP/src/soc_ifc/rtl/soc_ifc_reg.sv" "$PATCHED_REG" <<'PY'
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

read -r PKG_ADDED PKG_REMOVED <<EOF
$(python3 - "$CMP/src/soc_ifc/rtl/soc_ifc_reg_pkg.sv" "$PATCHED_PKG" <<'PY'
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

# The TB drives hwclr on the HEK family only when the member exists. It is
# written to be compilable against both structs, so the same file is reused.
export TMPDIR="${TMPDIR:-/home/smy/.cache/vcstmp}"
mkdir -p "$TMPDIR"

DUT_SOC_IFC_REG="$PATCHED_REG" \
DUT_SOC_IFC_REG_PKG="$PATCHED_PKG" \
NC_MODE=1 \
SIM_LOG="$NC_RUN/negative_control_sim.log" \
CMP_LOG="$NC_RUN/negative_control_compile.log" \
  bash "$HERE/run_bug_N004_sim.sh" > "$NC_RUN/negative_control_stdout.log" 2>&1
NC_RC=$?

SIM="$NC_RUN/negative_control_sim.log"
val() { grep -oP "(?<=^$1=)[0-9]+" "$SIM" | tail -1; }
# fails= shares a line with checks=, so it is not anchored at line start.
val_inline() { grep -oP "(?<=\b$1=)[0-9]+" "$SIM" | tail -1; }

WIT=$(val witness_hits);       TBF=$(val_inline fails)
C_SURV=$(val cov_hek_survives_scrub)
C_RST=$(val cov_reset_clear)
C_WR=$(val cov_write_takes_effect)
C_SIB=$(val cov_siblings_scrubbed)
SCRUB_OK=$(grep -c 'case=violating_hek_seed_survives_secret_scrub PASS' "$SIM")
HOLD_OK=$(grep -c 'case=violating_hek_residue_persists_while_strobe_held PASS' "$SIM")
READ_OK=$(grep -c 'case=violating_surviving_hek_seed_is_readable_over_the_bus PASS' "$SIM")
RST_OK=$(grep -c 'case=control_reset_leaves_all_secrets_clear PASS' "$SIM")
WR_OK=$(grep -c 'case=control_fuse_programming_takes_effect PASS' "$SIM")
SIB_OK=$(grep -c 'case=control_sibling_secrets_are_scrubbed PASS' "$SIM")
CONT_OK=$(grep -c 'case=containment_pwrgood_reset_clears_hek PASS' "$SIM")

pass=0; fail=0
gate() {
  if [ "$1" = "$2" ]; then pass=$((pass+1)); echo "  ok   $3"
  else fail=$((fail+1)); echo "gate_fail: $3 (expected $2, got $1)"; fi
}

{
echo "===== BUG-N-004 negative control ====="
echo "patch=fuse_hek_seed given the sibling HW Clear branch, and Fuse_w32 given an hwclr member"
echo "scratch_reg_code_lines_added=$REG_ADDED scratch_reg_code_lines_removed=$REG_REMOVED"
echo "scratch_pkg_code_lines_added=$PKG_ADDED scratch_pkg_code_lines_removed=$PKG_REMOVED"
echo "sim_script_rc=$NC_RC"
echo "witness_hits=${WIT:-unset}"
echo "cov_hek_survives_scrub=${C_SURV:-unset}"
echo "cov_reset_clear=${C_RST:-unset}"
echo "cov_write_takes_effect=${C_WR:-unset}"
echo "cov_siblings_scrubbed=${C_SIB:-unset}"
echo "tb_fails=${TBF:-unset}"
echo "--- gates ---"
gate "$REG_ADDED" "4" "the register patch adds exactly the four lines of the clear branch"
gate "$REG_REMOVED" "1" "and rewrites only the one line the branch chains onto"
gate "$PKG_ADDED" "1" "the package patch adds exactly one line, the hwclr member"
gate "$PKG_REMOVED" "0" "and removes none, so nothing else moved"
gate "${WIT:-unset}" "0" "the witness no longer fires on the patched copy"
gate "${C_SURV:-unset}" "0" "cov_hek_survives_scrub drops to 0 (anti-vacuity)"
gate "${TBF:-unset}" "0" "no TB check fails once the HEK family has a clear"
gate "$SCRUB_OK" "1" "the scrub check now passes"
gate "$HOLD_OK" "1" "the held-strobe check now passes"
gate "$READ_OK" "1" "the bus-readback check now passes"
gate "$RST_OK" "1" "harness control intact: reset still leaves every secret clear"
gate "$WR_OK" "1" "harness control intact: fuse programming still takes effect"
gate "$SIB_OK" "1" "harness control intact: the sibling secrets still scrub"
gate "$CONT_OK" "1" "containment case still passes"
if [ "$fail" -eq 0 ]; then
  echo "NEGATIVE CONTROL: PASS"
else
  echo "NEGATIVE CONTROL: FAIL"
fi
} 2>&1 | tee "$NC_LOG"

[ "$fail" -eq 0 ]
