#!/usr/bin/env bash
# BUG-040 negative control.
#
# Takes a scratch copy of spi_host_reg_top, rewrites CONTROL's write-enable into
# the single-address form that its twelve siblings in the same file already use,
# and runs the SAME unmodified bench against it. If the bench still reported the
# violating checks as failing, the bench would be measuring something other than
# this qualifier; the point of this script is that it stops doing so.
#
# Nothing in the audited tree is written. The patch is applied to a copy under
# proof/scratch and is size-gated, so it cannot quietly grow into a rewrite.
set -euo pipefail

CMP="${CMP_ROOT:-/home/smy/hackatdac26-phase-2-caliptra}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS="$(cd "$HERE/../logs" && pwd)"
SCRATCH="$HERE/../scratch"
NC_LOG="$LOGS/negative_control.log"

# Raw transcripts from the patched copy live outside proof/logs/. That run is
# EXPECTED to end in a non-pass verdict, because the bench demands the three
# violating checks fail and on the corrected qualifier they pass; keeping the
# transcripts here stops that intended flip from being read as a failing proof
# log. The authoritative verdict for this control is NC_LOG.
NC_RUN="$HERE/../negative_control_run"

SRC_TOP="$CMP/src/spi_host/rtl/spi_host_reg_top.sv"

rm -rf "$SCRATCH" "$NC_RUN"
mkdir -p "$SCRATCH" "$NC_RUN"

: > "$NC_LOG"
log() { echo "$@" | tee -a "$NC_LOG"; }

log "=== BUG-040 negative control ==="
log "claim: CONTROL's write-enable is qualified with two address hits, so a"
log "       write to the read-only STATUS register also commits into CONTROL."
log "method: correct the qualifier in a scratch copy, rerun the same bench."
log ""

gates_ok=0
gates_bad=0
gate() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    log "  ok   $desc"; gates_ok=$((gates_ok+1))
  else
    log "  BAD  $desc"; gates_bad=$((gates_bad+1))
  fi
}

# ---- 1. patch the qualifier in a scratch copy ----
log "--- 1. patch ---"
cp "$SRC_TOP" "$SCRATCH/spi_host_reg_top.sv"

python3 - "$SCRATCH/spi_host_reg_top.sv" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
t = p.read_text()

# The defect, verbatim. Two address hits OR-ed together via a NAND of inversions.
old = """  assign control_we = (~&{~addr_hit[4], ~addr_hit[5]}) &
                      reg_we & !reg_error;"""
# The form every sibling write-enable in this same file uses.
new = """  assign control_we = addr_hit[4] & reg_we & !reg_error;"""

assert t.count(old) == 1, f"expected exactly one qualifier, found {t.count(old)}"
assert "addr_hit[5]" in old, "guard: the patched text must be the two-hit form"
t = t.replace(old, new)
p.write_text(t)
print("patched")
PY

gate "scratch copy has the corrected single-address qualifier" \
     grep -q 'assign control_we = addr_hit\[4\] & reg_we & !reg_error;' "$SCRATCH/spi_host_reg_top.sv"
gate "scratch copy no longer contains the two-hit qualifier" \
     bash -c "! grep -q '~&{~addr_hit\[4\], ~addr_hit\[5\]}' '$SCRATCH/spi_host_reg_top.sv'"
gate "audited source is untouched (still has the two-hit qualifier)" \
     grep -q '~&{~addr_hit\[4\], ~addr_hit\[5\]}' "$SRC_TOP"

# Size gate: this must be a two-line-for-one-line substitution and nothing else.
python3 - "$SRC_TOP" "$SCRATCH/spi_host_reg_top.sv" <<'PY'
import sys, difflib, pathlib
a = pathlib.Path(sys.argv[1]).read_text().splitlines()
b = pathlib.Path(sys.argv[2]).read_text().splitlines()
add = rem = 0
for line in difflib.unified_diff(a, b, n=0, lineterm=""):
    if line.startswith("+++") or line.startswith("---") or line.startswith("@@"):
        continue
    if line.startswith("+"): add += 1
    elif line.startswith("-"): rem += 1
print(f"scratch_code_lines_added={add} removed={rem}")
PY
NC_ADD=$(python3 - "$SRC_TOP" "$SCRATCH/spi_host_reg_top.sv" <<'PY'
import sys, difflib, pathlib
a = pathlib.Path(sys.argv[1]).read_text().splitlines()
b = pathlib.Path(sys.argv[2]).read_text().splitlines()
add = sum(1 for l in difflib.unified_diff(a, b, n=0, lineterm="")
          if l.startswith("+") and not l.startswith("+++"))
print(add)
PY
)
NC_REM=$(python3 - "$SRC_TOP" "$SCRATCH/spi_host_reg_top.sv" <<'PY'
import sys, difflib, pathlib
a = pathlib.Path(sys.argv[1]).read_text().splitlines()
b = pathlib.Path(sys.argv[2]).read_text().splitlines()
rem = sum(1 for l in difflib.unified_diff(a, b, n=0, lineterm="")
          if l.startswith("-") and not l.startswith("---"))
print(rem)
PY
)
log "  scratch_code_lines_added=$NC_ADD removed=$NC_REM"
gate "the patch adds exactly 1 line" test "$NC_ADD" -eq 1
gate "the patch removes exactly 2 lines" test "$NC_REM" -eq 2
log ""

# ---- 2. rerun the same bench against the patched copy ----
log "--- 2. rerun the same bench, unmodified ---"
set +e
DUT_SPI_HOST_REG_TOP="$SCRATCH/spi_host_reg_top.sv" \
SIM_LOG="$NC_RUN/negative_control_sim.log" \
CMP_LOG="$NC_RUN/negative_control_compile.log" \
  bash "$HERE/run_bug_040_sim.sh" > "$NC_RUN/negative_control_stdout.log" 2>&1
SIM_RC=$?
set -e
log "  sim_script_rc=$SIM_RC (2 = SIGNATURE_MISMATCH, which is what this control wants)"

NC_SIM="$NC_RUN/negative_control_sim.log"
gate "the patched build compiled and ran" test -s "$NC_SIM"
gate "the corrected qualifier yields no witness (witness_hits=0)" \
     grep -q '^witness_hits=0' "$NC_SIM"
gate "no check fails on the corrected qualifier (fails=0)" \
     grep -q '^checks=8 fails=0' "$NC_SIM"
gate "the bench reports the signature as absent, not as a pass" \
     grep -q '^result=NOT_THE_AUDITED_SIGNATURE' "$NC_SIM"
gate "the STATUS write no longer modifies CONTROL" \
     grep -q 'case=violating_status_write_must_not_modify_control PASS' "$NC_SIM"
gate "the STATUS write no longer sets sw_rst or clears spien" \
     grep -q 'case=violating_status_write_must_not_set_sw_rst_or_clear_spien PASS' "$NC_SIM"
gate "the anti-vacuity control still holds: a direct CONTROL write still lands" \
     grep -q 'case=control_direct_control_write_takes_effect PASS' "$NC_SIM"
gate "the bench still reached the STATUS read, so it ran to the same depth" \
     grep -q 'case=control_status_address_is_mapped_and_readable PASS' "$NC_SIM"
log ""

# ---- 3. the audited run still shows the defect ----
log "--- 3. the audited run is unaffected ---"
gate "the audited simulation log still records the defect signature" \
     grep -q '^result=PASS' "$LOGS/sim.log"
gate "the audited run still witnesses the out-of-bounds update" \
     grep -q '^witness_hits=1' "$LOGS/sim.log"
gate "the audited run still shows the update is silent (intg_err stays low)" \
     grep -q 'TBFAIL case=violating_out_of_bounds_update_must_raise_intg_err' "$LOGS/sim.log"
log ""

log "gates_ok=$gates_ok gates_bad=$gates_bad"
if [ "$gates_bad" -eq 0 ]; then
  log "NEGATIVE CONTROL: PASS"
  log "result=PASS"
  exit 0
fi
log "NEGATIVE CONTROL: FAIL"
log "result=FAIL"
exit 1
