#!/usr/bin/env bash
# BUG-033 structural audit: the SHA-512 DIGEST hardware-clear strobe is driven by
# a second, inverted zeroize signal.
#
# The finding is established entirely from evidence inside the audited tree. Two
# in-tree controls carry it:
#
#   1. A tree-wide census of zeroize-driven hwclr sites. 22 exist across 6 crypto
#      blocks. 20 are driven by the plain strobe zeroize_reg = ZEROIZE | debug_or_scan.
#      Exactly 2 are driven by an inverted second strobe, and both are DIGEST
#      output windows.
#   2. An intra-file control. In sha512.sv itself, the GEN_PCR_HASH_DIGEST hwclr on
#      the very next line, the BLOCK hwclr, the DIGEST write-enable suppression on
#      the line above, the internal register-clear branch and all four submodule
#      .zeroize ports still use the correct strobe. The deviation is one line.
#
# No external repository, reference revision, or expected-answer list is consulted
# anywhere below.
set -euo pipefail

CMP="${AUDIT_ROOT:-/home/smy/hackatdac26-phase-2-caliptra}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS="$(cd "$HERE/../logs" && pwd)"
RUN_LOG="$LOGS/run.log"
WITNESS_LOG="$LOGS/witness.log"

: > "$RUN_LOG"
: > "$WITNESS_LOG"

F="src/sha512/rtl/sha512.sv"
RDL="src/sha512/rtl/sha512_reg.rdl"
REGF="src/sha512/rtl/sha512_reg.sv"
S256="src/sha256/rtl/sha256.sv"
TOP="src/integration/rtl/caliptra_top.sv"
HDR="src/integration/rtl/caliptra_reg/caliptra_reg.h"

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

echo "BUG-033 structural audit (single-tree)" >> "$RUN_LOG"
echo "audit_root=$CMP" >> "$RUN_LOG"
echo "date=$(date -Is)" >> "$RUN_LOG"

# ---------- Witness ----------
section "the two-strobe formation ($F:283-287)"
sed -n '283,287p' "$CMP/$F" >> "$WITNESS_LOG"

section "DIGEST hwclr vs its immediate neighbours in the same file ($F:296-315)"
sed -n '296,315p' "$CMP/$F" >> "$WITNESS_LOG"

section "every site of the two strobes in this file"
grep -n 'zeroize_reg2\|zeroize_reg\b' "$CMP/$F" >> "$WITNESS_LOG"

section "every zeroize_reg2 site in the whole audited tree"
{ grep -rn 'zeroize_reg2' "$CMP/src" --include=*.sv || true; } >> "$WITNESS_LOG"

section "RDL security contract for ZEROIZE ($RDL:83-85)"
sed -n '83,85p' "$CMP/$RDL" >> "$WITNESS_LOG"

section "generated register-file hwclr precedence for DIGEST ($REGF:905-922)"
sed -n '905,922p' "$CMP/$REGF" >> "$WITNESS_LOG"

# ---------- Gates: the rewiring ----------
gate "grep -q 'hwif_in.SHA512_DIGEST\[dword\].DIGEST.hwclr = zeroize_reg2;' '$CMP/$F'" \
     "The DIGEST hwclr is driven by the second strobe zeroize_reg2"
gate "grep -q '~(&{~hwif_out.SHA512_CTRL.ZEROIZE.value, debugUnlock_or_scan_mode_switch})' '$CMP/$F'" \
     "zeroize_reg2 = ~((~ZEROIZE) & debug_or_scan), which reduces to ZEROIZE | ~debug_or_scan"
gate "sed -n '284,287p' '$CMP/$F' | grep -q 'hwif_out.SHA512_CTRL.ZEROIZE.value || debugUnlock_or_scan_mode_switch'" \
     "The correct strobe zeroize_reg = ZEROIZE || debug_or_scan is formed on the same concatenation"
gate "grep -q 'logic zeroize_reg2;' '$CMP/$F'" \
     "The second strobe is declared as an ordinary local signal, so its introduction is silent"
R2=$(grep -c 'zeroize_reg2' "$CMP/$F")
echo "zeroize_reg2_sites_in_file=$R2" >> "$RUN_LOG"
gate "test '$R2' -eq 3" \
     "zeroize_reg2 appears at exactly 3 sites in this file: declaration, assignment target, and one consumer"

# ---------- Gates: tree-wide hwclr census (the decisive in-tree evidence) ----------
# Every crypto block in this tree wipes its secret-bearing registers from the
# zeroize strobe. Counting those sites establishes the intended convention from
# inside the audited tree, with no external comparison. The census is computed and
# written verbatim to the witness log.
CENSUS=$(python3 - "$CMP" <<'PYEOF'
import re, subprocess, pathlib, sys
root = pathlib.Path(sys.argv[1])
out = subprocess.run(['grep','-rn','hwclr = .*zeroize','src','--include=*.sv'],
                     capture_output=True, text=True, cwd=root).stdout.splitlines()
plain, inverted = [], []
for line in out:
    loc, _, body = line.partition(':')
    rest = line.split(':', 2)[2]
    # classify by which strobe drives the clear
    if re.search(r'\bzeroize_reg2\b', rest):
        inverted.append(line.split(':')[0] + ':' + line.split(':')[1])
    else:
        plain.append(line.split(':')[0] + ':' + line.split(':')[1])
print(f"zeroize_driven_hwclr_total={len(plain)+len(inverted)}")
print(f"driven_by_correct_strobe={len(plain)}")
print(f"driven_by_inverted_strobe={len(inverted)}")
for s in inverted:
    print(f"inverted_site={s}")
blocks = sorted({p.split('/')[1] for p in plain + inverted})
print(f"crypto_blocks_using_the_convention={len(blocks)} ({','.join(blocks)})")
PYEOF
)
section "computed census of zeroize-driven hwclr sites across the audited tree"
printf '%s\n' "$CENSUS" >> "$WITNESS_LOG"
printf '%s\n' "$CENSUS" | sed 's/^/census_/' >> "$RUN_LOG"

TOTAL_HC=$(printf '%s\n' "$CENSUS" | sed -n 's/^zeroize_driven_hwclr_total=//p')
CORRECT_HC=$(printf '%s\n' "$CENSUS" | sed -n 's/^driven_by_correct_strobe=//p')
INVERTED_HC=$(printf '%s\n' "$CENSUS" | sed -n 's/^driven_by_inverted_strobe=//p')

gate "test '$TOTAL_HC' -eq 22" \
     "The tree contains 22 zeroize-driven hwclr sites, a large in-tree control population"
gate "test '$CORRECT_HC' -eq 20" \
     "20 of them are driven by the correct, non-inverted strobe"
gate "test '$INVERTED_HC' -eq 2" \
     "Only 2 are driven by an inverted second strobe"
gate "printf '%s\n' \"\$CENSUS\" | grep -q 'inverted_site=src/sha512/rtl/sha512.sv:300'" \
     "One of those two is the line under audit"
gate "printf '%s\n' \"\$CENSUS\" | grep -q 'crypto_blocks_using_the_convention=6'" \
     "The wipe convention spans 6 crypto blocks, so it is design-wide rather than local to one file"
ECC_SITES=$( { grep -c 'hwclr = zeroize_reg' "$CMP/src/ecc/rtl/ecc_dsa_ctrl.sv" || true; } )
echo "ecc_zeroize_hwclr_sites=$ECC_SITES" >> "$RUN_LOG"
gate "test '$ECC_SITES' -eq 12" \
     "Control: ECC wipes 12 secret registers, including PRIVKEY_OUT and SIGN_S, from the correct strobe"
gate "grep -q 'hwif_in.HMAC512_TAG\[dword\].TAG.hwclr = zeroize_reg;' '$CMP/src/hmac/rtl/hmac.sv'" \
     "Control: HMAC wipes its TAG output register from the correct strobe"
gate "grep -q 'hwif_in.DIGEST\[dword\].DIGEST.hwclr = zeroize_pulse;' '$CMP/src/soc_ifc/rtl/sha512_acc_top.sv'" \
     "Control: the SHA-512 accelerator in soc_ifc wipes its own DIGEST window from an uninverted pulse"

# ---------- Gates: the deviation is local, so it is not a deliberate redefinition ----------
gate "grep -q 'hwif_in.SHA512_GEN_PCR_HASH_DIGEST\[dword\].DIGEST.hwclr = zeroize_reg;' '$CMP/$F'" \
     "In-file control: the next hwclr line clears GEN_PCR_HASH_DIGEST with the correct strobe"
gate "grep -q 'hwif_in.SHA512_BLOCK\[dword\].BLOCK.hwclr = zeroize_reg | kv_read_data_present_reset;' '$CMP/$F'" \
     "In-file control: the BLOCK hwclr also uses the correct strobe"
gate "grep -q 'hwif_in.SHA512_DIGEST\[dword\].DIGEST.we = zeroize_reg? 0 : digest_we;' '$CMP/$F'" \
     "In-file control: the DIGEST write-enable suppression on the line above uses the correct strobe"
gate "grep -q 'else if (zeroize_reg) begin' '$CMP/$F'" \
     "In-file control: the internal register-clear branch keys off the correct strobe"
CORE=$(grep -c '\.zeroize(zeroize_reg),' "$CMP/$F")
echo "submodule_zeroize_ports=$CORE" >> "$RUN_LOG"
gate "test '$CORE' -eq 4" \
     "In-file control: all 4 submodule .zeroize ports are fed the correct strobe"
R2_HWCLR=$(grep -c 'hwclr = zeroize_reg2' "$CMP/$F")
gate "test '$R2_HWCLR' -eq 1" \
     "Exactly one consumer in the file was moved to the inverted strobe, namely the DIGEST window"

# ---------- Gates: the specification states the security purpose ----------
gate "sed -n '83,85p' '$CMP/$RDL' | grep -q 'to avoid SCA leakage'" \
     "RDL: ZEROIZE exists to clear internal registers after a SHA process to avoid SCA leakage"
gate "sed -n '83,85p' '$CMP/$RDL' | grep -q 'singlepulse'" \
     "RDL: ZEROIZE is a single-pulse field, so the strobe is momentary by design"

# ---------- Gates: hwclr genuinely reaches the storage element ----------
gate "sed -n '905,922p' '$CMP/$REGF' | grep -q 'hwif_in.SHA512_DIGEST\[i0\].DIGEST.hwclr) begin // HW Clear'" \
     "The generated register file wires the DIGEST hwclr to a zeroing branch, so the strobe is live"
gate "sed -n '905,922p' '$CMP/$REGF' | grep -q 'next_c = .0;'" \
     "That branch drives the field to zero"

# ---------- Gates: the companion site in the sibling block ----------
# Recorded because it bears on the mitigation: both blocks must be fixed.
FILES_R2=$( { grep -rl 'zeroize_reg2' "$CMP/src" --include=*.sv --include=*.v || true; } | wc -l)
echo "files_with_zeroize_reg2=$FILES_R2" >> "$RUN_LOG"
gate "test '$FILES_R2' -eq 2" \
     "Exactly 2 files in the whole tree carry a zeroize_reg2, sha512.sv and sha256.sv"
gate "grep -q '~(&{~hwif_out.SHA256_CTRL.ZEROIZE.value, debugUnlock_or_scan_mode_switch})' '$CMP/$S256'" \
     "sha256.sv carries the structurally identical construct, so the mitigation must cover both blocks"
gate "grep -q 'hwif_in.SHA256_DIGEST\[dword\].DIGEST.hwclr = zeroize_reg2;' '$CMP/$S256'" \
     "Its DIGEST hwclr is driven by that strobe in the same way"
gate "grep -q 'hwif_in.SHA256_BLOCK\[dword\].BLOCK.hwclr = zeroize_reg;' '$CMP/$S256'" \
     "While its own BLOCK hwclr still uses the correct strobe, the same local pattern as sha512"

section "sibling SHA-256 formation ($S256:387-392)"
sed -n '387,392p' "$CMP/$S256" >> "$WITNESS_LOG"

# ---------- Gates: the strobe is a shared convention fanned out from the top ----------
CONSUMERS=$(grep -c 'debugUnlock_or_scan_mode_switch(debug_lock_or_scan_mode_switch)' "$CMP/$TOP")
echo "top_level_switch_consumers=$CONSUMERS" >> "$RUN_LOG"
gate "test '$CONSUMERS' -ge 8" \
     "The same debug/scan switch is fanned out to 8 or more blocks at the top level"
gate "grep -q 'assign debug_lock_or_scan_mode_switch = debug_lock_switch | scan_mode_switch | device_lifecycle_switch | cptra_error_fatal;' '$CMP/$TOP'" \
     "It is asserted on a debug-lock change, a scan-mode entry, a lifecycle change, or a fatal error"
gate "sed -n '763,767p' '$CMP/$TOP' | grep -q 'debug_locked'" \
     "It is formed from edge terms on latched security state, so it is a transition pulse not a steady level"

section "top-level formation of the debug/scan switch ($TOP:763-770)"
sed -n '763,770p' "$CMP/$TOP" >> "$WITNESS_LOG"

# ---------- Gates: DIGEST is software-readable, so the asset is observable ----------
gate "grep -q 'CLP_SHA512_REG_SHA512_DIGEST_0  *(0x10020100)' '$CMP/$HDR'" \
     "SHA512_DIGEST_0 is exposed to firmware at 0x10020100"
gate "grep -q 'CLP_SHA512_REG_SHA512_CTRL  *(0x10020010)' '$CMP/$HDR'" \
     "SHA512_CTRL is exposed to firmware at 0x10020010 (ZEROIZE is bit 4, mask 0x10)"

section "audit gate results"
grep -E '^gate_' "$RUN_LOG" >> "$WITNESS_LOG"

section "truth table for the two strobes (Z = ZEROIZE, D = debugUnlock_or_scan_mode_switch)"
cat >> "$WITNESS_LOG" <<'EOF'
  Z D | zeroize_reg (Z|D) | zeroize_reg2 = ~((~Z)&D) | consequence for the DIGEST window
  ----+-------------------+-------------------------+-----------------------------------
  0 0 |         0         |            1            | cleared while nothing is requested
  0 1 |         1         |            0            | NOT cleared on debug-unlock / scan entry
  1 0 |         1         |            1            | agrees
  1 1 |         1         |            1            | agrees

  Row 0/1 is the security failure: it is exactly the transition the wipe exists for.
  Rows 1/0 and 1/1 show the software ZEROIZE path still works, so the defect is a
  selective inversion rather than a wholesale break. This table is derived from the
  expression; the simulation measures the same behaviour independently.
EOF

total=$(grep -c '^gate_' "$RUN_LOG")
ok=$(grep -c '^gate_ok' "$RUN_LOG")
echo "structural_gates_passed=$ok/$total" >> "$RUN_LOG"
echo "structural_gates_passed=$ok/$total" >> "$WITNESS_LOG"

if [ "$pass" -eq 1 ]; then
  echo "RESULT: PASS - all structural gates confirm BUG-033" >> "$RUN_LOG"
  echo "result=PASS" >> "$RUN_LOG"
  echo "RESULT: PASS" >> "$WITNESS_LOG"
  exit 0
else
  echo "RESULT: FAIL - at least one structural gate did not hold" >> "$RUN_LOG"
  echo "result=FAIL" >> "$RUN_LOG"
  echo "RESULT: FAIL" >> "$WITNESS_LOG"
  exit 1
fi
