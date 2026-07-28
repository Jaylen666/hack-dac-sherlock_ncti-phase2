#!/usr/bin/env bash
# BUG-019 structural audit: HMAC INIT drops the digest_valid clear.
#
# The finding is established entirely from evidence inside the audited tree. The
# argument is that the file contradicts itself twice: the init_cmd arm drives a
# new value onto digest_valid_new without the write enable that its own
# reg_update block requires, and the next_cmd arm four lines below does assert
# that enable for the same variable. No external repository, reference revision,
# or expected-answer list is consulted anywhere below.
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

show "===== BUG-019 structural audit (single-tree, audited RTL only) ====="
show ""
show "----- 1. the file's own write protocol for digest_valid_reg -----"

gate "sed -n '201,202p' '$CORE' | grep -q 'if (digest_valid_we)'" \
     "hmac_core.sv:201 gates the digest_valid_reg write on digest_valid_we"
gate "sed -n '203p' '$CORE' | grep -q 'digest_valid_reg <= digest_valid_new'" \
     "hmac_core.sv:203 is the only place digest_valid_reg takes digest_valid_new"
gate "[ \"\$(grep -c 'digest_valid_reg <= ' '$CORE')\" = '2' ]" \
     "digest_valid_reg has exactly 2 assignments in the file: the reset arm and the enable-gated update"
gate "sed -n '185p' '$CORE' | grep -q \"digest_valid_reg <= 1'b0\"" \
     "the reset arm clears it directly (hmac_core.sv:185), bypassing the enable"

show ""
show "----- 2. the defect: init_cmd drives the value but not the enable -----"

gate "sed -n '340p' '$CORE' | grep -q \"digest_valid_new = 1'b0\"" \
     "hmac_core.sv:340 the init_cmd arm does drive digest_valid_new to 0"
gate "! sed -n '339,343p' '$CORE' | grep -q 'digest_valid_we'" \
     "hmac_core.sv:339-343 the whole init_cmd arm never mentions digest_valid_we"
gate "sed -n '347p' '$CORE' | grep -q \"digest_valid_we  = 1'b1\"" \
     "in-file control: the next_cmd arm four lines below does assert it (hmac_core.sv:347)"
gate "sed -n '346p' '$CORE' | grep -q \"digest_valid_new = 1'b0\"" \
     "the next_cmd arm drives the same value, so the two arms differ only in the enable"

show ""
show "----- 3. in-file control: every other state asserts the enable -----"

# Census over the FSM: count arms that drive digest_valid_new against arms that
# also assert digest_valid_we. The init_cmd arm is the only mismatch.
CENSUS=$(python3 - "$CORE" <<'PYEOF'
import re, sys
lines = open(sys.argv[1]).read().splitlines()
start = next(i for i, l in enumerate(lines) if 'always_comb begin : hmac_ctrl_fsm' in l)
end   = next(i for i, l in enumerate(lines) if i > start and 'endcase' in l)
body  = lines[start:end]
# Skip the default-assignment prologue: the first occurrence of each signal.
new_sites = [i for i, l in enumerate(body) if re.search(r"digest_valid_new\s*=", l)][1:]
we_sites  = [i for i, l in enumerate(body) if re.search(r"digest_valid_we\s*=", l)][1:]
print(f"digest_valid_new_drives={len(new_sites)}")
print(f"digest_valid_we_asserts={len(we_sites)}")
# An arm is paired if a we-assert appears within 3 lines of the new-drive.
paired = sum(1 for n in new_sites if any(abs(n - w) <= 3 for w in we_sites))
print(f"paired={paired}")
print(f"unpaired={len(new_sites) - paired}")
for n in new_sites:
    if not any(abs(n - w) <= 3 for w in we_sites):
        print(f"unpaired_site={start + n + 1}: {body[n].strip()}")
PYEOF
)
show "$CENSUS"
NDRV=$(echo "$CENSUS" | grep -o 'digest_valid_new_drives=[0-9]*' | cut -d= -f2)
PAIR=$(echo "$CENSUS" | grep -o '^paired=[0-9]*'                 | cut -d= -f2)
UNPAIR=$(echo "$CENSUS" | grep -o 'unpaired=[0-9]*'              | cut -d= -f2)

gate "[ '$NDRV' = '7' ]" \
     "census: 7 FSM arms drive digest_valid_new (IDLE init, IDLE next, IPAD, OPAD, HMAC, DONE, default)"
gate "[ '$PAIR' = '6' ]" \
     "census: 6 of the 7 also assert digest_valid_we within the same arm, so the pairing is the file's own convention"
gate "[ '$UNPAIR' = '1' ]" \
     "census: exactly 1 arm drives the value without the enable"
gate "printf '%s' \"$CENSUS\" | grep -q 'unpaired_site=340'" \
     "census: that one unpaired arm is the init_cmd arm at hmac_core.sv:340"
gate "sed -n '356,357p' '$CORE' | grep -q 'digest_valid_we  = 1'" \
     "control: CTRL_IPAD asserts the enable (hmac_core.sv:357)"
gate "sed -n '369,370p' '$CORE' | grep -q 'digest_valid_we  = 1'" \
     "control: CTRL_OPAD asserts the enable (hmac_core.sv:370)"

show ""
show "----- 4. the stale bit is software-visible and gates the tag -----"

gate "grep -q 'assign tag_valid  = digest_valid_reg' '$CORE'" \
     "hmac_core.sv:115 exports digest_valid_reg directly as tag_valid"
gate "grep -q 'assign tag        = digest_valid_reg? H2_digest : 512.b0' '$CORE'" \
     "hmac_core.sv:114 also gates the tag output on the same bit, so a stale 1 exposes the old H2 digest"
gate "grep -qE 'tag_valid|VALID' '$CMP/src/hmac/rtl/hmac.sv'" \
     "hmac.sv carries that valid bit up into the register block software polls"

show ""
show "===== relevant source, quoted from the audited tree ====="
show ""
show "--- src/hmac/rtl/hmac_core.sv:196-210 (the reg_update write protocol) ---"
sed -n '196,210p' "$CORE" | tee -a "$W"
show ""
show "--- src/hmac/rtl/hmac_core.sv:336-351 (the two CTRL_IDLE arms) ---"
sed -n '336,351p' "$CORE" | tee -a "$W"
show ""
show "--- src/hmac/rtl/hmac_core.sv:353-370 (in-file controls: IPAD and OPAD) ---"
sed -n '353,370p' "$CORE" | tee -a "$W"

show ""
show "structural_gates_passed=$PASS/$((PASS+FAIL))"
if [ "$FAIL" -eq 0 ]; then
  show "RESULT: PASS"
else
  show "RESULT: FAIL"
  exit 1
fi
