#!/usr/bin/env bash
# BUG-015 structural audit: the hmac_core zeroize arm leaves digest_valid_reg set.
#
# The finding is established entirely from evidence inside the audited tree. Four
# things the tree itself provides carry the argument: the file's own reset arm,
# which clears three registers including digest_valid_reg, against its own
# zeroize arm four lines below, which clears two of them; the comment inside that
# zeroize arm, which explicitly justifies the omission by claiming the normal
# update path refreshes the register later, against the file's own FSM, whose
# idle arm does not raise the write enable that claim depends on; the use the
# register is put to, namely gating the whole 512-bit tag output; and the child
# masked SHA-512 core in the same tree, whose zeroize arm mirrors its reset arm
# register for register including its own identically-named digest_valid_reg.
# No external repository, no other revision of this design, and no
# expected-answer list is consulted anywhere below.
set -euo pipefail

CMP="${CMP_ROOT:-/home/smy/hackatdac26-phase-2-caliptra}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS="$(cd "$HERE/../logs" && pwd)"
W="$LOGS/witness.log"
RUN_LOG="$LOGS/run.log"
HC="$CMP/src/hmac/rtl/hmac_core.sv"
HM="$CMP/src/hmac/rtl/hmac.sv"
SMC="$CMP/src/sha512_masked/rtl/sha512_masked_core.sv"

PASS=0; FAIL=0
: > "$W"
{
  echo "BUG-015 structural audit (single-tree)"
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

show "===== BUG-015 structural audit (single-tree, audited RTL only) ====="
show "audit_root=$CMP"
show ""

show "----- 1. the defect: the zeroize arm keeps digest_valid_reg set -----"

gate "sed -n '181p' '$HC' | grep -q 'always_ff @(posedge clk or negedge reset_n) begin : reg_update'" \
     "hmac_core.sv:181 opens the always_ff that holds this FSM's control and validity state, named reg_update"
gate "sed -n '183p' '$HC' | grep -q 'reset_n: begin'" \
     "hmac_core.sv:183 opens the reset arm"
gate "sed -n '185p' '$HC' | grep -q \"digest_valid_reg <= 1'b0\"" \
     "hmac_core.sv:185 shows the reset arm clearing digest_valid_reg, so the file treats it as state a full clear must zero"
gate "sed -n '190p' '$HC' | grep -q 'zeroize: begin'" \
     "hmac_core.sv:190 opens the zeroize arm, five lines below, on the same registers"
# Comment lines are stripped first: the zeroize arm mentions digest_valid_reg in
# its justifying comment but never assigns it, and that distinction is the whole
# finding, so the gate must look at code only.
gate "! sed -n '190,196p' '$HC' | grep -v '^\s*//' | grep -q 'digest_valid_reg'" \
     "no CODE line in the zeroize arm (hmac_core.sv:190-196) clears digest_valid_reg; the register is named there only inside the comment that justifies the omission, so a security zeroize leaves the tag-validity flag asserted"

# Census over the three arms of the same always_ff. Counting assignments
# independently of which registers they name means a regex miss shows up as a
# wrong count rather than passing silently.
RESET_N=$(sed -n '184,188p' "$HC" | grep -cE '^\s+\w+\s+<=' || true)
ZERO_N=$(sed -n '191,196p' "$HC" | grep -cE '^\s+\w+\s+<=' || true)
echo "reset_arm_assignments=$RESET_N"  | tee -a "$W" >> "$RUN_LOG"
echo "zeroize_arm_assignments=$ZERO_N" | tee -a "$W" >> "$RUN_LOG"
show "reset_arm_assignments=$RESET_N zeroize_arm_assignments=$ZERO_N"

gate "[ \"$RESET_N\" = '3' ]" \
     "the reset arm assigns all 3 registers this always_ff holds"
gate "[ \"$ZERO_N\" = '2' ]" \
     "the zeroize arm assigns only 2 of them"
gate "[ \$(( RESET_N - ZERO_N )) = '1' ]" \
     "the difference is exactly 1 register, matching the digest_valid_reg named above, so the omission is complete and not a partial clear"

show ""
show "----- 2. the file's own comment claims a refresh the file does not provide -----"

gate "sed -n '192,193p' '$HC' | grep -q 'digest_valid_reg is refreshed by the normal update path below'" \
     "hmac_core.sv:192-193 carries a comment justifying the omission, claiming the normal update path refreshes digest_valid_reg on a later cycle"
gate "sed -n '202,203p' '$HC' | grep -q 'if (digest_valid_we)'" \
     "hmac_core.sv:202-203 is that normal update path, and it writes digest_valid_reg only when digest_valid_we is raised, so the comment's claim depends entirely on that enable"
gate "sed -n '329p' '$HC' | grep -qE \"digest_valid_we\s+= 1'b0\"" \
     "hmac_core.sv:329 defaults digest_valid_we to zero at the top of the FSM always_comb"
gate "sed -n '336,343p' '$HC' | grep -q 'CTRL_IDLE'" \
     "hmac_core.sv:336 opens the CTRL_IDLE arm, which is the state the zeroize arm forces the FSM into"
gate "! sed -n '339,343p' '$HC' | grep -q 'digest_valid_we'" \
     "the init_cmd branch of CTRL_IDLE (hmac_core.sv:339-343) sets digest_valid_new but never raises digest_valid_we, so even starting a new operation does not perform the refresh the comment promises"
gate "sed -n '337p' '$HC' | grep -qE \"ready_flag = 1'b1\"" \
     "hmac_core.sv:337 shows CTRL_IDLE reporting ready, so the engine advertises itself as idle and available while the stale validity flag is still set"

# The claim "no write happens while idle" requires that CTRL_IDLE's only
# digest_valid_we assertion is the next_cmd one, and that the default arm does
# not assert it either.
IDLE_WE=$(sed -n '336,351p' "$HC" | grep -cE "digest_valid_we\s+= 1'b1" || true)
DFLT_WE=$(sed -n '400,407p' "$HC" | grep -cE "digest_valid_we\s+= 0" || true)
echo "ctrl_idle_write_enable_assertions=$IDLE_WE" | tee -a "$W" >> "$RUN_LOG"
echo "default_arm_write_enable_clears=$DFLT_WE"   | tee -a "$W" >> "$RUN_LOG"
show "ctrl_idle_write_enable_assertions=$IDLE_WE default_arm_write_enable_clears=$DFLT_WE"
gate "[ \"$IDLE_WE\" = '1' ]" \
     "CTRL_IDLE raises digest_valid_we exactly once, in the next_cmd branch only, so an idle engine that receives no command never refreshes the flag"
gate "[ \"$DFLT_WE\" = '1' ]" \
     "the FSM default arm explicitly clears digest_valid_we, confirming no unlisted path performs the refresh either"

show ""
show "----- 3. what the stale flag gates: the whole tag output -----"

gate "sed -n '111p' '$HC' | grep -q \"assign tag        = digest_valid_reg? H2_digest : 512'b0\"" \
     "hmac_core.sv:111 makes the entire 512-bit tag output conditional on digest_valid_reg, so this single uncleared bit decides whether the tag is presented or forced to zero"
gate "sed -n '112p' '$HC' | grep -q 'assign tag_valid  = digest_valid_reg'" \
     "hmac_core.sv:112 exports the same register as the module's tag_valid output, so the stale flag is visible to the parent as a completion claim"
gate "sed -n '185p' '$HM' | grep -q '.tag_valid(core_tag_valid)'" \
     "hmac.sv:185 receives that output as core_tag_valid"
gate "sed -n '163p' '$HM' | grep -q 'assign core_tag_we = (core_tag_valid & ~tag_valid_reg) & ~error_flag_reg'" \
     "hmac.sv:163 derives the tag capture enable from a RISING EDGE of core_tag_valid against the parent's own tag_valid_reg, so the pair of flags must agree for the parent to behave correctly"
gate "sed -n '214p' '$HM' | grep -qE \"tag_valid_reg   <= '0\"" \
     "hmac.sv:214 shows the parent's zeroize arm clearing tag_valid_reg, so after a zeroize the parent believes no tag is valid while the child still asserts one, which is exactly the disagreement core_tag_we is built to detect as a new completion"
gate "sed -n '227p' '$HM' | grep -q 'tag_reg <= core_tag & get_mask'" \
     "hmac.sv:227 is what that enable gates: the write of the child's tag into the software-readable tag register"
gate "sed -n '267p' '$HM' | grep -q 'hwif_in.HMAC512_TAG\[dword\].TAG.hwclr = zeroize_reg'" \
     "hmac.sv:267 clears the software-visible TAG register on zeroize, showing the design's intent is that no tag survives a zeroize"

show ""
show "----- 4. tree control: the child masked core mirrors its arms -----"

gate "sed -n '269p' '$SMC' | grep -q 'always @ (posedge clk or negedge reset_n)'" \
     "sha512_masked_core.sv:269 opens the state-holding always block of the child core that hmac_core instantiates twice"
gate "sed -n '271p' '$SMC' | grep -q 'if (!reset_n)'" \
     "sha512_masked_core.sv:271 opens that child's reset arm"
gate "sed -n '290p' '$SMC' | grep -qE \"digest_valid_reg    <= 1'b0\"" \
     "sha512_masked_core.sv:290 shows that reset arm clearing its own digest_valid_reg"
gate "sed -n '297p' '$SMC' | grep -q 'else if (zeroize)'" \
     "sha512_masked_core.sv:297 opens its zeroize arm, on the same zeroize signal hmac_core passes down"
gate "sed -n '316p' '$SMC' | grep -qE \"digest_valid_reg    <= 1'b0\"" \
     "sha512_masked_core.sv:316 shows the child's zeroize arm clearing digest_valid_reg too, so the child does on zeroize exactly what its parent omits"

# Census on the child: its zeroize arm must not be smaller than its reset arm,
# which is the property hmac_core violates.
SMC_RESET=$(sed -n '272,295p' "$SMC" | grep -cE '^\s+\w+\s+<=' || true)
SMC_ZERO=$(sed -n '298,321p' "$SMC" | grep -cE '^\s+\w+\s+<=' || true)
echo "masked_core_reset_arm_assignments=$SMC_RESET"  | tee -a "$W" >> "$RUN_LOG"
echo "masked_core_zeroize_arm_assignments=$SMC_ZERO" | tee -a "$W" >> "$RUN_LOG"
show "masked_core_reset_arm_assignments=$SMC_RESET masked_core_zeroize_arm_assignments=$SMC_ZERO"
gate "[ \"$SMC_RESET\" = \"$SMC_ZERO\" ]" \
     "in the child the two arms assign the same number of registers ($SMC_RESET each), which is exactly the relation hmac_core breaks"
gate "sed -n '120p' '$HC' | grep -q '.zeroize(zeroize)'" \
     "hmac_core.sv:120 passes its own zeroize straight into the first child instance, so parent and child act on the identical strobe"
gate "sed -n '139p' '$HC' | grep -q '.zeroize(zeroize)'" \
     "hmac_core.sv:139 does the same for the second child instance"

show ""
show "----- 5. tree control: the parent's own zeroize arm is exhaustive too -----"

gate "sed -n '171p' '$HM' | grep -q '.zeroize(zeroize_reg)'" \
     "hmac.sv:171 wires the parent's zeroize_reg into hmac_core's zeroize port, so the parent below is the block that owns the strobe"
gate "sed -n '259p' '$HM' | grep -q 'hwif_out.HMAC512_CTRL.ZEROIZE.value'" \
     "hmac.sv:259 sources that strobe from the software-writable HMAC512_CTRL.ZEROIZE field, so a software write reaches the incomplete arm"
gate "sed -n '210p' '$HM' | grep -q 'else if (zeroize_reg)'" \
     "hmac.sv:210 opens the parent's own zeroize arm, on the same strobe it passes down"

HM_RESET=$(sed -n '201,208p' "$HM" | grep -cE '^\s+\w+\s+<=' || true)
HM_ZERO=$(sed -n '211,218p' "$HM" | grep -cE '^\s+\w+\s+<=' || true)
echo "hmac_reset_arm_assignments=$HM_RESET"  | tee -a "$W" >> "$RUN_LOG"
echo "hmac_zeroize_arm_assignments=$HM_ZERO" | tee -a "$W" >> "$RUN_LOG"
show "hmac_reset_arm_assignments=$HM_RESET hmac_zeroize_arm_assignments=$HM_ZERO"
gate "[ \"$HM_RESET\" = \"$HM_ZERO\" ]" \
     "the parent's two arms assign the same number of registers ($HM_RESET each), so the convention on this very strobe is to mirror the reset arm exhaustively"

show ""
show "--- src/hmac/rtl/hmac_core.sv:181,209 (the always_ff and its three arms) ---"
sed -n '181,209p' "$HC" | tee -a "$W"

show ""
show "--- src/sha512_masked/rtl/sha512_masked_core.sv:288,321 (the child, whose arms match) ---"
sed -n '288,321p' "$SMC" | tee -a "$W"

show ""
show "--- src/hmac/rtl/hmac_core.sv:326,351 (the FSM idle arm the comment relies on) ---"
sed -n '326,351p' "$HC" | tee -a "$W"

show ""
show "structural_gates_passed=$PASS/$((PASS+FAIL))"
echo "structural_gates_passed=$PASS/$((PASS+FAIL))" >> "$RUN_LOG"
if [ "$FAIL" -eq 0 ]; then
  show "RESULT: PASS"
  echo "RESULT: PASS - all structural gates confirm BUG-015" >> "$RUN_LOG"
  echo "result=PASS" >> "$RUN_LOG"
else
  show "RESULT: FAIL"
  echo "RESULT: FAIL - at least one structural gate did not hold" >> "$RUN_LOG"
  echo "result=FAIL" >> "$RUN_LOG"
  exit 1
fi
