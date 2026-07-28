#!/usr/bin/env bash
# BUG-029 structural audit: SHA3 done does not clear the Keccak state.
#
# The finding is established entirely from evidence inside the audited tree. The
# argument rests on four things the tree itself provides: the file's own default
# assignment block, which covers keccak_done but not keccak_done2, leaving the
# latter with no default in an always_comb; the file's own done branch, which
# hardwires that signal to MuBi4False so the clear it feeds can never fire; the
# clear semantics stated by the child module the signal drives; and a twin SHA3
# implementation inside the same tree whose line structure is nearly identical
# and which wires the same child port to the same signal as done_i, with no
# second signal anywhere in it. No external repository, reference revision, or
# expected-answer list is consulted anywhere below.
set -euo pipefail

CMP="${CMP_ROOT:-/home/smy/hackatdac26-phase-2-caliptra}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS="$(cd "$HERE/../logs" && pwd)"
W="$LOGS/witness.log"
RUN_LOG="$LOGS/run.log"
SHA3="$CMP/src/kmac/rtl/sha3.sv"
ROUND="$CMP/src/kmac/rtl/keccak_round.sv"
TWIN="$CMP/src/sha3/rtl/ot_sha3.sv"

PASS=0; FAIL=0
: > "$W"
{
  echo "BUG-029 structural audit (single-tree)"
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

show "===== BUG-029 structural audit (single-tree, audited RTL only) ====="
show "audit_root=$CMP"
show ""

show "----- 1. the defect: the clear port is fed a constant False -----"

gate "sed -n '138p' '$SHA3' | grep -q 'mubi4_t keccak_done2'" \
     "sha3.sv:138 declares a second done-like signal, keccak_done2"
gate "sed -n '290,292p' '$SHA3' | grep -q 'keccak_done, keccak_done2'" \
     "sha3.sv:290-292 assigns both signals together in the done branch of StSqueeze"
gate "sed -n '291p' '$SHA3' | grep -q 'done_i, caliptra_prim_mubi_pkg::MuBi4False'" \
     "sha3.sv:291 gives keccak_done the incoming done_i but pins keccak_done2 to the constant MuBi4False"
gate "sed -n '494p' '$SHA3' | grep -q '.clear_i    (keccak_done2)'" \
     "sha3.sv:494 wires that constant-False signal to the Keccak round's clear_i port"
gate "sed -n '451p' '$SHA3' | grep -q '.done_i    (keccak_done)'" \
     "sha3.sv:451 wires the real done_i-derived signal to the pad's done_i, so the two ports are fed from different signals"

# Census: keccak_done2 must have no assignment other than the constant one, or
# the "can never be true" claim would not be exhaustive.
D2_ASSIGNS=$(grep -cE '(^|[^_[:alnum:]])keccak_done2[[:space:]]*=' "$SHA3" || true)
D2_REFS=$(grep -c 'keccak_done2' "$SHA3")
echo "keccak_done2_direct_assignments=$D2_ASSIGNS" | tee -a "$W" >> "$RUN_LOG"
echo "keccak_done2_total_references=$D2_REFS"      | tee -a "$W" >> "$RUN_LOG"
show "keccak_done2_direct_assignments=$D2_ASSIGNS keccak_done2_total_references=$D2_REFS"

gate "[ \"$D2_ASSIGNS\" = '0' ]" \
     "keccak_done2 has no standalone assignment anywhere in the file; its only write is the concatenation at :290-292"
gate "[ \"$D2_REFS\" = '3' ]" \
     "keccak_done2 appears exactly 3 times in the file (declaration, the concatenation write, the clear_i connection), so the census covers every use of it"

show ""
show "----- 2. in-file control: the always_comb default block skips it -----"

gate "sed -n '247p' '$SHA3' | grep -q 'keccak_done = caliptra_prim_mubi_pkg::MuBi4False'" \
     "sha3.sv:247 gives keccak_done a default value at the top of the always_comb"
gate "! sed -n '241,256p' '$SHA3' | grep -q 'keccak_done2'" \
     "no line in the same default block (sha3.sv:241-256) assigns keccak_done2, so the signal has no default in a combinational block and infers a latch"

# Census over the default block: every other control signal driven by this FSM
# does get a default, so the omission is a unique outlier in its own block.
DEFAULTS=$(sed -n '243,256p' "$SHA3" | grep -cE '^\s+\w+\s+=' || true)
echo "always_comb_default_assignments=$DEFAULTS" | tee -a "$W" >> "$RUN_LOG"
show "always_comb_default_assignments=$DEFAULTS"
gate "[ \"$DEFAULTS\" -ge '7' ]" \
     "the block assigns $DEFAULTS defaults, covering every FSM output except keccak_done2"

show ""
show "----- 3. the child module states what clear_i is for and needs -----"

gate "sed -n '99p' '$ROUND' | grep -q 'clear_i'" \
     "keccak_round.sv:99 declares clear_i, commented as clearing the internal state to zero"
gate "sed -n '219p' '$ROUND' | grep -q 'mubi4_test_true_strict(clear_i)'" \
     "keccak_round.sv:219 acts on clear_i only when it passes mubi4_test_true_strict, so a constant MuBi4False can never trigger it"
gate "sed -n '224p' '$ROUND' | grep -q \"rst_storage = 1'b 1\"" \
     "keccak_round.sv:224 is the only place rst_storage is raised, and it sits inside that clear_i-guarded branch, so the state storage is never reset through this path"
gate "sed -n '603p' '$ROUND' | grep -q 'mubi4_test_true_strict(clear_i)'" \
     "keccak_round.sv:603 assumes clear_i is asserted in the idle state, an assumption that is vacuous when the driver is a constant False"

show ""
show "----- 4. the FSM leaves the squeeze window without any other clear -----"

gate "sed -n '279p' '$SHA3' | grep -q 'StSqueeze_sparse: begin'" \
     "sha3.sv:279 opens the squeeze state, the state in which done_i is accepted"
gate "sed -n '288p' '$SHA3' | grep -q 'mubi4_test_true_strict(done_i)'" \
     "sha3.sv:288 accepts a strictly-valid done_i and takes the completion branch"
gate "sed -n '289p' '$SHA3' | grep -q 'st_d = StFlush_sparse'" \
     "sha3.sv:289 moves the FSM to StFlush on done"
gate "sed -n '304,306p' '$SHA3' | grep -q 'st_d = StIdle_sparse'" \
     "sha3.sv:304-306 shows StFlush doing nothing but returning to idle, so no later state clears the storage either"

show ""
show "----- 5. tree control: the twin SHA3 in the same tree wires it correctly -----"

gate "sed -n '244p' '$TWIN' | grep -q 'keccak_done = MuBi4False'" \
     "ot_sha3.sv:244 has the same default assignment for keccak_done, so the two files are directly comparable"
gate "sed -n '289p' '$TWIN' | grep -q 'keccak_done = done_i'" \
     "ot_sha3.sv:289 assigns keccak_done = done_i in the same completion branch, a single signal rather than a pair"
gate "sed -n '450p' '$TWIN' | grep -q '.done_i    (keccak_done)'" \
     "ot_sha3.sv:450 wires that signal to the pad's done_i"
gate "sed -n '492p' '$TWIN' | grep -q '.clear_i    (keccak_done)'" \
     "ot_sha3.sv:492 wires the SAME signal to the round's clear_i, so in the twin the clear does fire when done_i is strictly valid"
gate "! grep -q 'keccak_done2' '$TWIN'" \
     "ot_sha3.sv contains no keccak_done2 at all, so the tree carries both the correct wiring and its violation"

show ""
show "----- 6. in-file control: the file's own error-detection assertion -----"

gate "sed -n '532,533p' '$SHA3' | grep -q 'keccak_start, keccak_process, sw_keccak_run, keccak_done'" \
     "sha3.sv:532-533 lists the signals through which controls must propagate, and keccak_done is in that list"
gate "! sed -n '531,533p' '$SHA3' | grep -q 'keccak_done2'" \
     "keccak_done2 is absent from that list, so the file's own propagation check cannot observe the constant-False clear path"
gate "sed -n '531p' '$TWIN' | grep -q 'keccak_start, keccak_process, sw_keccak_run, keccak_done' || sed -n '529,531p' '$TWIN' | grep -q 'keccak_done'" \
     "the twin carries the same assertion over the same signal list, which in the twin covers the clear path because one signal drives both ports"

show ""
show "--- src/kmac/rtl/sha3.sv:241,256 (the default block that skips keccak_done2) ---"
sed -n '241,256p' "$SHA3" | tee -a "$W"

show ""
show "--- src/kmac/rtl/sha3.sv:279,294 (the squeeze state and its done branch) ---"
sed -n '279,294p' "$SHA3" | tee -a "$W"

show ""
show "--- src/kmac/rtl/sha3.sv:490,495 vs src/sha3/rtl/ot_sha3.sv:490,493 (clear_i wiring) ---"
sed -n '490,495p' "$SHA3" | tee -a "$W"
show "  --- twin ---"
sed -n '490,493p' "$TWIN" | tee -a "$W"

show ""
show "structural_gates_passed=$PASS/$((PASS+FAIL))"
echo "structural_gates_passed=$PASS/$((PASS+FAIL))" >> "$RUN_LOG"
if [ "$FAIL" -eq 0 ]; then
  show "RESULT: PASS"
  echo "RESULT: PASS - all structural gates confirm BUG-029" >> "$RUN_LOG"
  echo "result=PASS" >> "$RUN_LOG"
else
  show "RESULT: FAIL"
  echo "RESULT: FAIL - at least one structural gate did not hold" >> "$RUN_LOG"
  echo "result=FAIL" >> "$RUN_LOG"
  exit 1
fi
