#!/usr/bin/env bash
# BUG-017 structural audit: the HMAC masking-entropy core is never started.
#
# The finding is established entirely from evidence inside the audited tree. The
# argument is that the file contradicts itself: it presents a block to the H2
# core and latches H2's digest, but never starts H2 for that block, while every
# other block presentation in the same always_comb block is accompanied by a
# start strobe. No external repository, reference revision, or expected-answer
# list is consulted anywhere below.
set -euo pipefail

CMP="${CMP_ROOT:-/home/smy/hackatdac26-phase-2-caliptra}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS="$(cd "$HERE/../logs" && pwd)"
W="$LOGS/witness.log"
CORE="$CMP/src/hmac/rtl/hmac_core.sv"

PASS=0; FAIL=0
: > "$W"

gate() {
  local cmd="$1" desc="$2"
  if eval "$cmd" >/dev/null 2>&1; then
    PASS=$((PASS+1)); echo "  PASS: $desc" | tee -a "$W"
  else
    FAIL=$((FAIL+1)); echo "  FAIL: $desc" | tee -a "$W"
  fi
}

show() { echo "$1" | tee -a "$W"; }

show "===== BUG-017 structural audit (single-tree, audited RTL only) ====="
show ""
show "----- 1. the intended reseed chain exists in the file -----"

gate "sed -n '243p' '$CORE' | grep -q 'entropy_block = {entropy_digest, lfsr_seed, counter_reg, ENTROPY_PAD}'" \
     "hmac_core.sv:243 builds entropy_block from entropy_digest, lfsr_seed and a counter"
gate "sed -n '282p' '$CORE' | grep -q 'H2_block = entropy_block'" \
     "hmac_core.sv:282 presents entropy_block to the H2 core inside CTRL_IPAD"
gate "sed -n '229,231p' '$CORE' | grep -q 'entropy_digest <= H2_digest\[383:0\]'" \
     "hmac_core.sv:229-231 latches entropy_digest from H2_digest when set_entropy fires"
gate "sed -n '362p' '$CORE' | grep -q 'set_entropy = 1'" \
     "hmac_core.sv:362 fires set_entropy at the IPAD -> OPAD transition"
gate "sed -n '242p' '$CORE' | grep -q 'lfsr_entropy = entropy_digest ^ lfsr_seed'" \
     "hmac_core.sv:242 feeds the masking LFSRs from entropy_digest XOR lfsr_seed"
gate "sed -n '167p' '$CORE' | grep -q 'seed_i(lfsr_entropy'" \
     "hmac_core.sv:167 seeds all 12 caliptra_prim_lfsr instances from lfsr_entropy"

show ""
show "----- 2. the chain is broken: H2 is never started for that block -----"

# The CTRL_IPAD first_round arm is the only place H2 could be launched for the
# entropy block, and it explicitly holds both H2 strobes low.
gate "sed -n '274,283p' '$CORE' | grep -q \"H2_init    = 1'b0\"" \
     "the CTRL_IPAD first_round arm drives H2_init to 0 (hmac_core.sv:277)"
gate "sed -n '274,283p' '$CORE' | grep -q \"H2_next    = 1'b0\"" \
     "the CTRL_IPAD first_round arm drives H2_next to 0 (hmac_core.sv:278)"
gate "! sed -n '273,284p' '$CORE' | grep -qE \"H2_(init|next) *= *1'b1\"" \
     "no assignment anywhere in the CTRL_IPAD branch ever raises an H2 start strobe"

show ""
show "----- 3. in-file control: every other block presentation has a start strobe -----"

gate "sed -n '275p' '$CORE' | grep -q \"H1_init    = 1'b1\"" \
     "control: CTRL_IPAD starts H1 on key_ipadded (hmac_core.sv:275)"
gate "sed -n '291p' '$CORE' | grep -q 'H2_init = 1'" \
     "control: CTRL_OPAD starts H2 on key_opadded (hmac_core.sv:291)"
gate "sed -n '290p' '$CORE' | grep -q 'H1_next = 1'" \
     "control: CTRL_OPAD starts H1 on block_msg (hmac_core.sv:290)"
gate "sed -n '304p' '$CORE' | grep -q 'H2_next = 1'" \
     "control: CTRL_HMAC starts H2 on HMAC_padded (hmac_core.sv:304)"

# Computed census: count block presentations against start strobes in the file.
CENSUS=$(python3 - "$CORE" <<'PYEOF'
import re, sys
lines = open(sys.argv[1]).read().splitlines()
starts = sum(1 for l in lines if re.search(r"H[12]_(init|next)\s*=\s*1('b1)?\s*;", l))
print(f"start_strobe_assertions={starts}")
PYEOF
)
show "$CENSUS"
STARTS=$(echo "$CENSUS" | grep -o 'start_strobe_assertions=[0-9]*' | cut -d= -f2)
gate "[ '$STARTS' = '4' ]" \
     "census: the file asserts a start strobe exactly 4 times, one per real block presentation, none of them for the entropy block"

show ""
show "----- 4. the entropy is security-relevant, not decorative -----"

gate "grep -q 'sha512_masked_core u_sha512_core_h2' '$CORE'" \
     "H2 is a masked SHA-512 core, so its entropy input is a side-channel countermeasure"
gate "sed -n '145p' '$CORE' | grep -q 'entropy(entropy\[383 : 192\])'" \
     "hmac_core.sv:145 wires the LFSR output into H2's masking entropy port"
gate "sed -n '126p' '$CORE' | grep -q 'entropy(entropy\[191 : 0\])'" \
     "hmac_core.sv:126 wires the same LFSR output into H1's masking entropy port"
gate "grep -q 'lfsr_seed_reg\[dword\] = hwif_out.HMAC512_LFSR_SEED\[dword\].LFSR_SEED.value' '$CMP/src/hmac/rtl/hmac.sv'" \
     "hmac.sv:311 sources lfsr_seed from the software-writable HMAC512_LFSR_SEED register"
gate "grep -q 'core_lfsr_seed = {lfsr_seed_reg' '$CMP/src/hmac/rtl/hmac.sv'" \
     "hmac.sv:159-160 passes that register value straight through to the core"

show ""
show "----- 5. scope: the defect is predictability, not a stall -----"

# entropy_digest stays at its reset value, so lfsr_entropy == lfsr_seed. The
# LFSRs still run; the seed is simply software-determined.
gate "sed -n '225,231p' '$CORE' | grep -q \"entropy_digest <= '0\"" \
     "entropy_digest resets to zero (hmac_core.sv:227), which is what set_entropy then latches"
gate "sed -n '166p' '$CORE' | grep -q 'seed_en_i(init_cmd)' " \
     "the LFSRs are reseeded on every init_cmd (hmac_core.sv:166), so the weak seed is applied per HMAC"

show ""
show "===== relevant source, quoted from the audited tree ====="
show ""
show "--- src/hmac/rtl/hmac_core.sv:273-284 (the CTRL_IPAD branch) ---"
sed -n '273,284p' "$CORE" | tee -a "$W"
show ""
show "--- src/hmac/rtl/hmac_core.sv:285-306 (in-file controls: every other presentation) ---"
sed -n '285,306p' "$CORE" | tee -a "$W"
show ""
show "--- src/hmac/rtl/hmac_core.sv:224-243 (the latch and the LFSR seed) ---"
sed -n '224,243p' "$CORE" | tee -a "$W"

show ""
show "structural_gates_passed=$PASS/$((PASS+FAIL))"
if [ "$FAIL" -eq 0 ]; then
  show "RESULT: PASS"
else
  show "RESULT: FAIL"
  exit 1
fi
