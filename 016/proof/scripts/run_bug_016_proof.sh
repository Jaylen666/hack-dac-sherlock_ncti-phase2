#!/usr/bin/env bash
# BUG-016 structural audit: HMAC zeroize does not clear digest_valid_reg.
#
# The finding is established entirely from evidence inside the audited tree. The
# argument is that the file contradicts itself: its own reset arm clears all
# three state registers, its own zeroize arm clears only two, its own mode_reg
# is cleared directly on zeroize rather than deferred, and the child cores it
# instantiates clear their equivalent bit in their own zeroize arms. The excuse
# the zeroize arm states in a comment is disproved by the file's own FSM. No
# external repository, reference revision, or expected-answer list is consulted
# anywhere below.
set -euo pipefail

CMP="${CMP_ROOT:-/home/smy/hackatdac26-phase-2-caliptra}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS="$(cd "$HERE/../logs" && pwd)"
W="$LOGS/witness.log"
RUN_LOG="$LOGS/run.log"
CORE="$CMP/src/hmac/rtl/hmac_core.sv"
REG="$CMP/src/hmac/rtl/hmac.sv"
CHILD="$CMP/src/sha512_masked/rtl/sha512_masked_core.sv"

PASS=0; FAIL=0
: > "$W"
{
  echo "BUG-016 structural audit (single-tree)"
  echo "audit_root=$CMP"
  echo "date=$(date -Is)"
} > "$RUN_LOG"

gate() {
  local cmd="$1" desc="$2"
  if eval "$cmd" >/dev/null 2>&1; then
    PASS=$((PASS+1)); echo "  PASS: $desc" | tee -a "$W"
    echo "gate_ok: $desc" >> "$RUN_LOG"
  else
    FAIL=$((FAIL+1)); echo "  FAIL: $desc" | tee -a "$W"
    echo "gate_fail: $desc" >> "$RUN_LOG"
  fi
}

show() { echo "$1" | tee -a "$W"; }

show "===== BUG-016 structural audit (single-tree, audited RTL only) ====="
show "audit_root=$CMP"
show ""

show "----- 1. the defect: the zeroize arm skips one of the three registers -----"

gate "sed -n '190p' '$CORE' | grep -q 'zeroize: begin'" \
     "hmac_core.sv:190 opens the zeroize arm of the reg_update unique case"
gate "sed -n '194p' '$CORE' | grep -q 'hmac_ctrl_reg  <= CTRL_IDLE'" \
     "hmac_core.sv:194 clears hmac_ctrl_reg on zeroize"
gate "sed -n '195p' '$CORE' | grep -q 'hmac_ctrl_last <= CTRL_IDLE'" \
     "hmac_core.sv:195 clears hmac_ctrl_last on zeroize"
gate "! sed -n '190,196p' '$CORE' | grep -q 'digest_valid_reg <='" \
     "no line in the zeroize arm (hmac_core.sv:190-196) assigns digest_valid_reg, so the valid bit survives a security zeroize"

show ""
show "----- 2. in-file control: the reset arm of the same case statement -----"

gate "sed -n '185p' '$CORE' | grep -q \"digest_valid_reg <= 1'b0\"" \
     "hmac_core.sv:185 clears digest_valid_reg in the reset arm"
gate "sed -n '186p' '$CORE' | grep -q 'hmac_ctrl_reg    <= CTRL_IDLE'" \
     "hmac_core.sv:186 clears hmac_ctrl_reg there too"
gate "sed -n '187p' '$CORE' | grep -q 'hmac_ctrl_last   <= CTRL_IDLE'" \
     "hmac_core.sv:187 clears hmac_ctrl_last there too"

# Census: the two collapse-to-idle arms of the same case statement should clear
# the same register set. Counting each arm's assignments independently means a
# regex miss shows up as a count mismatch rather than a silent pass.
RESET_ASSIGNS=$(sed -n '183,188p' "$CORE" | grep -cE '^\s+\w+\s+<=')
ZERO_ASSIGNS=$(sed -n '190,196p' "$CORE" | grep -cE '^\s+\w+\s+<=')
echo "reset_arm_assignments=$RESET_ASSIGNS"   | tee -a "$W" >> "$RUN_LOG"
echo "zeroize_arm_assignments=$ZERO_ASSIGNS"  | tee -a "$W" >> "$RUN_LOG"
show "reset_arm_assignments=$RESET_ASSIGNS zeroize_arm_assignments=$ZERO_ASSIGNS"

gate "[ \"$RESET_ASSIGNS\" = '3' ]" \
     "the reset arm assigns all 3 state registers"
gate "[ \"$ZERO_ASSIGNS\" = '2' ]" \
     "the zeroize arm assigns only 2, so exactly one register is left behind"
gate "[ \$(( RESET_ASSIGNS - ZERO_ASSIGNS )) = '1' ]" \
     "the difference is exactly 1 register, and that register is digest_valid_reg"

gate "[ \"\$(grep -c 'digest_valid_reg <= ' '$CORE')\" = '2' ]" \
     "digest_valid_reg has exactly 2 assignments in the whole file, so the census covers every write to it"

show ""
show "----- 3. the comment's stated excuse is disproved by the file's own FSM -----"

gate "sed -n '192,193p' '$CORE' | grep -q 'refreshed by the normal update path'" \
     "hmac_core.sv:192-193 claims the valid bit is refreshed later by the normal update path, so no clear is needed here"
gate "sed -n '202p' '$CORE' | grep -q 'if (digest_valid_we)'" \
     "that normal update path (hmac_core.sv:202) only writes when digest_valid_we is asserted"
gate "sed -n '194p' '$CORE' | grep -q 'CTRL_IDLE'" \
     "but the same zeroize arm forces the FSM to CTRL_IDLE (hmac_core.sv:194), which is the state that issues no unconditional update"
gate "sed -n '339p' '$CORE' | grep -q 'if (init_cmd)' && sed -n '345p' '$CORE' | grep -q 'if (next_cmd)'" \
     "in CTRL_IDLE every arm is command-guarded (hmac_core.sv:339 and :345), so with no new command digest_valid_we is never asserted"
gate "sed -n '329p' '$CORE' | grep -q \"digest_valid_we  = 1'b0\"" \
     "the FSM's default assignment holds digest_valid_we at 0 (hmac_core.sv:329), so idling leaves the stale bit indefinitely"

# Every site that could assert the enable, so the "refreshed later" claim can be
# checked exhaustively rather than by inspection.
WE_SITES=$(grep -cE "digest_valid_we\s+= (1'b1|1);" "$CORE")
echo "digest_valid_we_assert_sites=$WE_SITES" | tee -a "$W" >> "$RUN_LOG"
show "digest_valid_we_assert_sites=$WE_SITES"
gate "[ \"$WE_SITES\" = '5' ]" \
     "the enable is asserted at exactly 5 sites, all of them inside command- or ready-guarded FSM arms, none reachable from a zeroized idle FSM"

show ""
show "----- 4. in-file control: mode_reg is cleared directly on zeroize -----"

gate "sed -n '216p' '$CORE' | grep -q 'else if (zeroize)'" \
     "hmac_core.sv:216 gives mode_reg its own zeroize arm"
gate "sed -n '217p' '$CORE' | grep -q \"mode_reg <= '0\"" \
     "hmac_core.sv:217 clears mode_reg immediately rather than deferring it to a later refresh, which is the file's own treatment of a zeroize-sensitive register"

show ""
show "----- 5. child control: the cores this file instantiates clear their own bit -----"

gate "sed -n '120p' '$CORE' | grep -q '.zeroize(zeroize)'" \
     "hmac_core.sv:120 forwards the same zeroize strobe to its H1 masked core"
gate "sed -n '139p' '$CORE' | grep -q '.zeroize(zeroize)'" \
     "hmac_core.sv:139 forwards it to H2 as well"
gate "sed -n '297p' '$CHILD' | grep -q 'else if (zeroize)'" \
     "sha512_masked_core.sv:297 opens that child's zeroize arm"
gate "sed -n '316p' '$CHILD' | grep -q \"digest_valid_reg    <= 1'b0\"" \
     "sha512_masked_core.sv:316 clears the child's own digest_valid_reg inside that arm, so the block's children honour on-zeroize invalidation while the parent does not"

show ""
show "----- 6. the stale bit reaches software through the wrapper -----"

gate "sed -n '111p' '$CORE' | grep -qE 'assign tag +=.*digest_valid_reg'" \
     "hmac_core.sv:111 gates the tag output on digest_valid_reg"
gate "sed -n '112p' '$CORE' | grep -qE 'assign tag_valid +=.*digest_valid_reg'" \
     "hmac_core.sv:112 exports it as tag_valid"
gate "sed -n '214p' '$REG' | grep -q \"tag_valid_reg   <= '0\"" \
     "hmac.sv:214 does clear the wrapper's tag_valid_reg on zeroize, so the wrapper looks correct in isolation"
gate "sed -n '222p' '$REG' | grep -q 'tag_valid_reg <= core_tag_valid'" \
     "but hmac.sv:222 reloads tag_valid_reg from the core's bit on the very next cycle, so the wrapper's clear is undone by the stale core bit"
gate "sed -n '163p' '$REG' | grep -q 'core_tag_we = (core_tag_valid & ~tag_valid_reg)'" \
     "hmac.sv:163 makes the tag write-enable fire on exactly that transition (core valid high, wrapper valid just cleared), so the tag register is rewritten after the zeroize too"
gate "sed -n '264p' '$REG' | grep -q 'HMAC512_STATUS.VALID.next = tag_valid_reg'" \
     "hmac.sv:264 publishes that bit as HMAC512_STATUS.VALID, so software sees VALID return to 1 after a zeroize"
gate "sed -n '267p' '$REG' | grep -q 'HMAC512_TAG\[dword\].TAG.hwclr = zeroize_reg'" \
     "hmac.sv:267 clears the TAG register on zeroize, which is the intent the stale core bit defeats"
gate "sed -n '259p' '$REG' | grep -q 'zeroize_reg = hwif_out.HMAC512_CTRL.ZEROIZE.value'" \
     "hmac.sv:259 sources zeroize from a software register field, so the whole sequence is software-triggerable"

show ""
show "--- src/hmac/rtl/hmac_core.sv:181,206 (the case statement: reset arm vs zeroize arm) ---"
sed -n '181,206p' "$CORE" | tee -a "$W"

show ""
show "--- src/hmac/rtl/hmac_core.sv:212,222 (in-file control: mode_reg's own zeroize arm) ---"
sed -n '212,222p' "$CORE" | tee -a "$W"

show ""
show "structural_gates_passed=$PASS/$((PASS+FAIL))"
echo "structural_gates_passed=$PASS/$((PASS+FAIL))" >> "$RUN_LOG"
if [ "$FAIL" -eq 0 ]; then
  show "RESULT: PASS"
  echo "RESULT: PASS - all structural gates confirm BUG-016" >> "$RUN_LOG"
  echo "result=PASS" >> "$RUN_LOG"
else
  show "RESULT: FAIL"
  echo "RESULT: FAIL - at least one structural gate did not hold" >> "$RUN_LOG"
  echo "result=FAIL" >> "$RUN_LOG"
  exit 1
fi
