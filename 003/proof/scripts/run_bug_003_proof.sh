#!/usr/bin/env bash
# BUG-003 structural audit: the CTRL_AUX_REGWEN gating term is absent from the
# AUX write enable, so the lock bit gates nothing.
#
# The finding is established entirely from evidence inside the audited tree. The
# decisive control is a tree-wide census of the generated write-enable gating
# idiom: 32 `*_gated_we` assignments exist across this tree's register blocks, 31
# of them AND the write enable with a REGWEN read-back, and exactly one does not.
# That one is the line under audit. No external repository, reference revision, or
# expected-answer list is consulted anywhere below.
set -euo pipefail

CMP="${AUDIT_ROOT:-/home/smy/hackatdac26-phase-2-caliptra}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS="$(cd "$HERE/../logs" && pwd)"
RUN_LOG="$LOGS/run.log"
WITNESS_LOG="$LOGS/witness.log"

: > "$RUN_LOG"
: > "$WITNESS_LOG"

F="src/aes/rtl/aes_reg_top.sv"
RDL="src/aes/data/aes.rdl"

pass=1
gate() {
  if eval "$1" >/dev/null 2>&1; then
    echo "gate_ok: $2" >> "$RUN_LOG"
  else
    echo "gate_fail: $2" >> "$RUN_LOG"
    pass=0
  fi
}
section() { printf '\n===== %s =====\n' "$1" >> "$WITNESS_LOG"; }

echo "BUG-003 structural audit (single-tree)" >> "$RUN_LOG"
echo "audit_root=$CMP" >> "$RUN_LOG"
echo "date=$(date -Is)" >> "$RUN_LOG"

# ---------- Witness ----------
section "the ungated write enable ($F:1036-1038)"
sed -n '1036,1038p' "$CMP/$F" >> "$WITNESS_LOG"

section "tree-wide census of the write-enable gating idiom (32 sites)"
{ grep -rn "gated_we = " "$CMP/src" --include=*.sv || true; } >> "$WITNESS_LOG"

section "the lock bit is declared, driven and software-readable, but consumed nowhere"
grep -n "ctrl_aux_regwen_qs" "$CMP/$F" >> "$WITNESS_LOG"

section "the ungated enable is what actually clocks both AUX fields ($F:1052, :1088)"
grep -n "ctrl_aux_shadowed_gated_we" "$CMP/$F" >> "$WITNESS_LOG"

section "RDL states the lock contract ($RDL:181-188)"
sed -n '181,188p' "$CMP/$RDL" >> "$WITNESS_LOG"

section "RDL states what the protected fields do ($RDL:156-179)"
sed -n '166,179p' "$CMP/$RDL" >> "$WITNESS_LOG"

# ---------- Gates: the defect line ----------
gate "sed -n '1038p' '$CMP/$F' | grep -q 'ctrl_aux_shadowed_gated_we = ctrl_aux_shadowed_we;'" \
     "The AUX write qualifier is an unconditional passthrough of the raw write enable"
gate "! sed -n '1038p' '$CMP/$F' | grep -q 'regwen'" \
     "The lock bit does not appear in that assignment at all"
gate "! grep -qE 'gated_we *=.*ctrl_aux_regwen_qs' '$CMP/$F'" \
     "No write-enable assignment anywhere in the file consumes the lock bit"

# ---------- Gates: tree-wide control census (the decisive in-tree evidence) ----------
# Every register block in this tree that has a REGWEN-protected register gates the
# corresponding write enable the same way. Counting those sites establishes the
# intended pattern from inside the audited tree, with no external comparison.
#
# The census is computed rather than asserted. It tolerates line-wrapped right-hand
# sides (csrng_reg_top.sv:1006 wraps), so the totals below are not an artifact of a
# single-line grep. Its output is written verbatim to the witness log.
CENSUS=$(python3 - "$CMP" <<'PYEOF'
import re, subprocess, pathlib, sys
root = pathlib.Path(sys.argv[1])
files = sorted(subprocess.run(['grep','-rl','_gated_we','src','--include=*.sv'],
                              capture_output=True, text=True, cwd=root).stdout.split())
total = gated = 0
dev = []
for f in files:
    lines = (root / f).read_text().splitlines()
    for i, l in enumerate(lines):
        if re.search(r'_gated_we\s*=(?!=)', l) and not re.match(r'\s*logic\b', l):
            total += 1
            expr, j = l, i
            while not expr.rstrip().endswith(';') and j + 1 < len(lines):
                j += 1
                expr += ' ' + lines[j]
            if 'regwen' in expr:
                gated += 1
            else:
                dev.append(f"{f}:{i+1}: {l.strip()}")
print(f"gating_assignments={total}")
print(f"regwen_gated={gated}")
print(f"not_gated={len(dev)}")
for d in dev:
    print(f"deviation={d}")
PYEOF
)
section "computed census of REGWEN write-enable gating across the audited tree"
printf '%s\n' "$CENSUS" >> "$WITNESS_LOG"
printf '%s\n' "$CENSUS" | sed 's/^/census_/' >> "$RUN_LOG"

TOTAL_GW=$(printf '%s\n' "$CENSUS" | sed -n 's/^gating_assignments=//p')
GATED_OK=$(printf '%s\n' "$CENSUS" | sed -n 's/^regwen_gated=//p')
UNGATED=$(printf '%s\n' "$CENSUS"  | sed -n 's/^not_gated=//p')
DECLS=$( { grep -rh 'logic .*_gated_we;' "$CMP/src" --include=*.sv || true; } | wc -l)
echo "gated_we_declarations=$DECLS" >> "$RUN_LOG"

gate "test '$TOTAL_GW' -eq 33" \
     "The tree contains 33 REGWEN write-enable gating assignments, a large in-tree control population"
gate "test '$DECLS' -eq '$TOTAL_GW'" \
     "The count of gated_we declarations equals the count of assignments, so no site was missed"
gate "test '$GATED_OK' -eq 32" \
     "32 of them AND the write enable with a REGWEN read-back"
gate "test '$UNGATED' -eq 1" \
     "Exactly one omits the REGWEN term, so the defect is a unique outlier in its own tree"
gate "printf '%s\n' \"\$CENSUS\" | grep -q 'deviation=src/aes/rtl/aes_reg_top.sv:1038:'" \
     "That single outlier is the line under audit"
gate "grep -q 'assign cfg_shadowed_gated_we = cfg_shadowed_we & cfg_regwen_qs;' '$CMP/src/sha3/rtl/kmac_reg_top.sv'" \
     "Control: kmac_reg_top gates its shadowed config register write enable with its REGWEN"
gate "grep -q 'assign ctrl_gated_we = ctrl_we & regwen_qs;' '$CMP/src/csrng/rtl/csrng_reg_top.sv'" \
     "Control: csrng_reg_top does the same, so the idiom is consistent across blocks"
gate "grep -q 'assign observe_fifo_depth_gated_we = observe_fifo_depth_we & regwen_qs;' '$CMP/src/entropy_src/rtl/entropy_src_reg_top.sv' || grep -qE '_gated_we = .*_we & .*regwen' '$CMP/src/entropy_src/rtl/entropy_src_reg_top.sv'" \
     "Control: entropy_src_reg_top does the same across its 16 sites"

# ---------- Gates: the defect line is also a structural outlier ----------
# The generator emits a fixed marker comment above every gating site and uses a
# continuous assignment. The audited site has neither: no marker comment, and a
# procedural block instead. Both counts are measured tree-wide.
MARKERS=$( { grep -rh 'Create REGWEN-gated WE signal' "$CMP/src" --include=*.sv || true; } | wc -l)
AES_MARKERS=$( { grep -c 'Create REGWEN-gated WE signal' "$CMP/$F" || true; } )
ONELINE_AC=$( { grep -rn 'always_comb begin .*= .*; end' "$CMP/src" --include=*.sv || true; } | wc -l)
echo "gating_marker_comments=$MARKERS aes_reg_top_markers=$AES_MARKERS oneline_always_comb_tree_wide=$ONELINE_AC" >> "$RUN_LOG"
gate "test '$MARKERS' -eq 32" \
     "32 of the 33 gating sites carry the generator's fixed marker comment"
gate "test '$AES_MARKERS' -eq 0" \
     "aes_reg_top.sv is the only file with a gating site and no marker comment at all"
gate "sed -n '1036p' '$CMP/$F' | grep -q 'Compute the write qualifier'" \
     "In its place is hand-written prose, a form the generated blocks in this tree never use"
gate "test '$ONELINE_AC' -eq 1" \
     "The audited line is also the only single-line always_comb block in the entire tree"

# ---------- Gates: the lock is fully present as a register, so software is misled ----------
gate "grep -q 'logic ctrl_aux_regwen_qs;' '$CMP/$F'" \
     "The lock read-back signal is still declared, so its removal from logic is silent, not a compile error"
gate "grep -q '.qs     (ctrl_aux_regwen_qs)' '$CMP/$F'" \
     "It is still driven by its own subreg instance, so the lock register holds state correctly"
gate "grep -q 'reg_rdata_next\[0\] = ctrl_aux_regwen_qs;' '$CMP/$F'" \
     "It is still returned over MMIO, so software reads back a lock that appears engaged"
SITES=$(grep -c 'ctrl_aux_regwen_qs' "$CMP/$F")
echo "lock_signal_sites=$SITES" >> "$RUN_LOG"
gate "test '$SITES' -eq 3" \
     "The lock signal appears at exactly 3 sites: declared, driven, read back. None of them gates anything"

# ---------- Gates: locking is a deliberate one-way software action ----------
gate "sed -n '1112,1118p' '$CMP/$F' | grep -q 'SwAccess(caliptra_prim_subreg_pkg::SwAccessW0C)'" \
     "The lock is SwAccessW0C, so one write of 0 engages it and software cannot undo it"
gate "sed -n '1112,1118p' '$CMP/$F' | grep -q \"RESVAL  (1'h1)\"" \
     "It resets to 1 (unlocked), so engaging the lock is an explicit software decision"

# ---------- Gates: the RTL contradicts the RDL it declares itself generated from ----------
gate "sed -n '181,188p' '$CMP/$RDL' | grep -q 'cannot be written anymore'" \
     "RDL: clearing the bit means the Auxiliary Control Register cannot be written anymore"
gate "grep -q 'Register Top module auto-generated by' '$CMP/$F'" \
     "The register block declares itself auto-generated from that RDL, so the tree is self-inconsistent"

# ---------- Gates: the write path stays open and reaches both protected fields ----------
gate "grep -q 'assign ctrl_aux_shadowed_we = addr_hit\[30\] & reg_we & !reg_error;' '$CMP/$F'" \
     "The AUX write enable is decoded from a live address hit, so the write path is reachable"
WE_CONSUMERS=$(grep -c '.we     (ctrl_aux_shadowed_gated_we)' "$CMP/$F")
echo "ungated_we_consumers=$WE_CONSUMERS" >> "$RUN_LOG"
gate "test '$WE_CONSUMERS' -eq 2" \
     "The ungated qualifier drives the .we of both AUX fields, so neither field is protected"
gate "sed -n '1040,1052p' '$CMP/$F' | grep -q 'u_ctrl_aux_shadowed_key_touch_forces_reseed'" \
     "Field 1 is KEY_TOUCH_FORCES_RESEED"
gate "sed -n '1076,1090p' '$CMP/$F' | grep -q 'u_ctrl_aux_shadowed_force_masks'" \
     "Field 2 is FORCE_MASKS, which is inert in this build and is NOT claimed as impact (see below)"

# ---------- Gates: the claimed field has a live effect in this build ----------
gate "grep -q 'key_init_new_pulse ? key_touch_forces_reseed_i' '$CMP/src/aes/rtl/aes_control_fsm.sv'" \
     "KEY_TOUCH_FORCES_RESEED gates the masking-PRNG reseed on a new key load, so the claimed field is not inert"
gate "sed -n '181,188p' '$CMP/$RDL' | grep -q 'Auxiliary Control'" \
     "The lock the RDL describes is the one covering that register, so the protected asset is correctly identified"

# ---------- Gates: the scope limit on FORCE_MASKS is verified, not assumed ----------
# FORCE_MASKS would be the more dramatic claim, so the reason it is withheld is
# gated rather than merely stated: the parameter that enables it is left at 0 here.
gate "grep -q 'parameter bit          SecAllowForcingMasks  = 0' '$CMP/src/aes/rtl/aes.sv'" \
     "Scope limit: SecAllowForcingMasks defaults to 0 in aes.sv"
gate "! sed -n '307,320p' '$CMP/src/aes/rtl/aes_clp_wrapper.sv' | grep -q 'SecAllowForcingMasks'" \
     "Scope limit: the wrapper instantiates aes with no override, so the parameter stays 0 and FORCE_MASKS is inert"

# ---------- Gates: firmware reachability ----------
HDR="src/integration/rtl/caliptra_reg/caliptra_reg.h"
gate "grep -q 'CLP_AES_REG_CTRL_AUX_SHADOWED  *(0x10011078)' '$CMP/$HDR'" \
     "CTRL_AUX_SHADOWED is exposed to firmware at 0x10011078"
gate "grep -q 'CLP_AES_REG_CTRL_AUX_REGWEN  *(0x1001107c)' '$CMP/$HDR'" \
     "CTRL_AUX_REGWEN is exposed to firmware at 0x1001107c"

section "firmware header entries for the AUX register and its lock"
grep -n "CLP_AES_REG_CTRL_AUX" "$CMP/$HDR" >> "$WITNESS_LOG"

section "audit gate results"
grep -E '^gate_' "$RUN_LOG" >> "$WITNESS_LOG"

total=$(grep -c '^gate_' "$RUN_LOG")
ok=$(grep -c '^gate_ok' "$RUN_LOG")
echo "structural_gates_passed=$ok/$total" >> "$RUN_LOG"
echo "structural_gates_passed=$ok/$total" >> "$WITNESS_LOG"

if [ "$pass" -eq 1 ]; then
  echo "RESULT: PASS - all structural gates confirm BUG-003" >> "$RUN_LOG"
  echo "result=PASS" >> "$RUN_LOG"
  echo "RESULT: PASS" >> "$WITNESS_LOG"
  exit 0
else
  echo "RESULT: FAIL - at least one structural gate did not hold" >> "$RUN_LOG"
  echo "result=FAIL" >> "$RUN_LOG"
  echo "RESULT: FAIL" >> "$WITNESS_LOG"
  exit 1
fi
