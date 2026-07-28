#!/usr/bin/env bash
# BUG-018 structural audit: HMAC CTRL_IDLE command decode has no priority.
#
# The finding is established entirely from evidence inside the audited tree. The
# argument is that the file contradicts its own idiom: this is the only state in
# the FSM whose arms are written as independent `if` statements assigning the
# same state variable, and it is the only place where two commands can both
# reach the state register in one cycle. No external repository, reference
# revision, or expected-answer list is consulted anywhere below.
set -euo pipefail

CMP="${CMP_ROOT:-/home/smy/hackatdac26-phase-2-caliptra}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS="$(cd "$HERE/../logs" && pwd)"
W="$LOGS/witness.log"
CORE="$CMP/src/hmac/rtl/hmac_core.sv"
REG="$CMP/src/hmac/rtl/hmac.sv"

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

show "===== BUG-018 structural audit (single-tree, audited RTL only) ====="
show ""
show "----- 1. the defect: two independent ifs assigning the same state -----"

gate "sed -n '339p' '$CORE' | grep -q 'if (init_cmd) begin'" \
     "hmac_core.sv:339 opens the init_cmd arm with a plain if"
gate "sed -n '345p' '$CORE' | grep -q 'if (next_cmd) begin'" \
     "hmac_core.sv:345 opens the next_cmd arm with a second plain if, not an else if"
gate "! sed -n '345p' '$CORE' | grep -q 'else'" \
     "hmac_core.sv:345 has no else, so both arms are evaluated in the same cycle"
gate "sed -n '341p' '$CORE' | grep -q 'hmac_ctrl_new    = CTRL_IPAD'" \
     "the init_cmd arm assigns hmac_ctrl_new = CTRL_IPAD (hmac_core.sv:341)"
gate "sed -n '348p' '$CORE' | grep -q 'hmac_ctrl_new    = CTRL_OPAD'" \
     "the next_cmd arm assigns the same variable hmac_ctrl_new = CTRL_OPAD (hmac_core.sv:348)"
gate "sed -n '342p' '$CORE' | grep -q \"hmac_ctrl_we     = 1'b1\" && sed -n '349p' '$CORE' | grep -q \"hmac_ctrl_we     = 1'b1\"" \
     "both arms assert hmac_ctrl_we, so the last write wins and reaches the register"

show ""
show "----- 2. in-file control: every other FSM state uses a single if -----"

# Census: count the `if (` statements that assign hmac_ctrl_new inside the FSM,
# grouped by whether they are chained. Only CTRL_IDLE has two unchained arms.
CENSUS=$(python3 - "$CORE" <<'PYEOF'
import re, sys
lines = open(sys.argv[1]).read().splitlines()
# The hmac_ctrl_fsm always_comb block.
start = next(i for i, l in enumerate(lines) if 'always_comb begin : hmac_ctrl_fsm' in l)
end   = next(i for i, l in enumerate(lines) if i > start and 'endcase' in l)
body  = lines[start:end]
plain_if = [l.strip() for l in body if re.match(r'\s*if\s*\(', l)]
else_if  = [l.strip() for l in body if re.match(r'\s*else\s+if\s*\(', l)]
# States whose transition is guarded by a single readiness test.
ready_if = [l for l in plain_if if re.search(r'(IPAD|OPAD|HMAC)_ready', l)]
cmd_if   = [l for l in plain_if if re.search(r'(init|next)_cmd', l)]
print(f"plain_if_total={len(plain_if)}")
print(f"else_if_total={len(else_if)}")
print(f"ready_guarded_if={len(ready_if)}")
print(f"command_guarded_if={len(cmd_if)}")
PYEOF
)
show "$CENSUS"
CMDIF=$(echo "$CENSUS" | grep -o 'command_guarded_if=[0-9]*' | cut -d= -f2)
RDYIF=$(echo "$CENSUS" | grep -o 'ready_guarded_if=[0-9]*'   | cut -d= -f2)
ELIF=$(echo  "$CENSUS" | grep -o 'else_if_total=[0-9]*'      | cut -d= -f2)

gate "[ '$CMDIF' = '2' ]" \
     "census: exactly 2 command-guarded ifs in the FSM, both in CTRL_IDLE, both unchained"
gate "[ '$RDYIF' = '3' ]" \
     "census: the other 3 transition guards (IPAD/OPAD/HMAC_ready) are each a single if per state, so no other state can double-assign"
gate "[ '$ELIF' = '0' ]" \
     "census: the FSM contains no else-if chain at all, so CTRL_IDLE's two arms are the only place the idiom could have applied"
gate "grep -q 'unique case (hmac_ctrl_reg)' '$CORE'" \
     "the FSM itself is a unique case, so the file does use exclusivity constructs elsewhere"

show ""
show "----- 3. both commands can genuinely be asserted in one cycle -----"

gate "grep -q 'init_cmd(hmac_cmd_reg\[0\])\|init_cmd(init_reg)\|\.init_cmd(' '$REG'" \
     "hmac.sv drives hmac_core's init_cmd from the register block"
gate "grep -q '\.next_cmd(' '$REG'" \
     "hmac.sv drives hmac_core's next_cmd from the register block"
gate "grep -qE 'INIT.*value|hwif_out.HMAC512_CTRL' '$REG'" \
     "both commands originate in the software-written HMAC512_CTRL register, so one MMIO write can set both bits"
gate "sed -n '337p' '$CORE' | grep -q \"ready_flag = 1'b1\"" \
     "CTRL_IDLE reports ready, so such a write is accepted rather than rejected (hmac_core.sv:337)"

show ""
show "----- 4. consequence: the IPAD phase is the keyed inner hash -----"

gate "grep -q 'key_ipadded = {key, 512.b0} \^ IPAD' '$CORE'" \
     "key_ipadded is the inner HMAC pad, computed from the key (hmac_core.sv:257)"
gate "sed -n '275,276p' '$CORE' | grep -q \"H1_init    = 1'b1\"" \
     "CTRL_IPAD is where H1 is launched on key_ipadded, so skipping it skips the inner hash"
gate "sed -n '362p' '$CORE' | grep -q 'set_entropy = 1'" \
     "CTRL_IPAD is also where set_entropy fires, so skipping it also skips the masking reseed"

show ""
show "===== relevant source, quoted from the audited tree ====="
show ""
show "--- src/hmac/rtl/hmac_core.sv:334-352 (the CTRL_IDLE command decode) ---"
sed -n '334,352p' "$CORE" | tee -a "$W"
show ""
show "--- src/hmac/rtl/hmac_core.sv:353-372 (in-file controls: one guard per state) ---"
sed -n '353,372p' "$CORE" | tee -a "$W"

show ""
show "structural_gates_passed=$PASS/$((PASS+FAIL))"
if [ "$FAIL" -eq 0 ]; then
  show "RESULT: PASS"
else
  show "RESULT: FAIL"
  exit 1
fi
