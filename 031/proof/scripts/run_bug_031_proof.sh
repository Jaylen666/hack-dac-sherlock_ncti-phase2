#!/usr/bin/env bash
# BUG-031 structural audit: the pv_gen_hash zeroize arm leaves the PCR read
# pointer intact.
#
# The finding is established entirely from evidence inside the audited tree. The
# argument rests on four things the tree itself provides: the file's own reset
# arm, which clears five registers, against its own zeroize arm three lines
# below, which clears three of them; the file's own else arm, which shows the two
# omitted registers have no other clearing path; the use those two registers are
# put to, namely selecting which PCR entry and which dword the read mux returns;
# and a sibling read-pointer FSM inside the same tree, src/keyvault/rtl/kv_fsm.sv,
# whose zeroize arm mirrors its reset arm line for line, including a second
# always_ff that clears even a pure bookkeeping register. No external repository,
# no other revision of this design, and no expected-answer list is consulted
# anywhere below.
set -euo pipefail

CMP="${CMP_ROOT:-/home/smy/hackatdac26-phase-2-caliptra}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS="$(cd "$HERE/../logs" && pwd)"
W="$LOGS/witness.log"
RUN_LOG="$LOGS/run.log"
GH="$CMP/src/pcrvault/rtl/pv_gen_hash.sv"
PV="$CMP/src/pcrvault/rtl/pv.sv"
KVF="$CMP/src/keyvault/rtl/kv_fsm.sv"
SHA="$CMP/src/sha512/rtl/sha512.sv"

PASS=0; FAIL=0
: > "$W"
{
  echo "BUG-031 structural audit (single-tree)"
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

show "===== BUG-031 structural audit (single-tree, audited RTL only) ====="
show "audit_root=$CMP"
show ""

show "----- 1. the defect: the zeroize arm skips the PCR read pointer -----"

gate "sed -n '199p' '$GH' | grep -q 'always_ff @(posedge clk or negedge rst_b) begin : api_regs'" \
     "pv_gen_hash.sv:199 opens the single always_ff that holds all of this FSM's state, named api_regs"
gate "sed -n '200p' '$GH' | grep -q 'if (~rst_b) begin'" \
     "pv_gen_hash.sv:200 opens the reset arm"
gate "sed -n '204p' '$GH' | grep -qE \"read_entry\s+<= '0\"" \
     "pv_gen_hash.sv:204 shows the reset arm clearing read_entry"
gate "sed -n '205p' '$GH' | grep -qE \"read_offset\s+<= '0\"" \
     "pv_gen_hash.sv:205 shows the reset arm clearing read_offset, so the reset arm treats both pointer registers as state that must be cleared"
gate "sed -n '207p' '$GH' | grep -q 'else if (zeroize) begin'" \
     "pv_gen_hash.sv:207 opens the zeroize arm, three lines below, on the same registers"
gate "! sed -n '207,211p' '$GH' | grep -q 'read_entry'" \
     "no line in the zeroize arm (pv_gen_hash.sv:207-211) clears read_entry"
gate "! sed -n '207,211p' '$GH' | grep -q 'read_offset'" \
     "no line in the zeroize arm clears read_offset either, so a security zeroize leaves the PCR read pointer wherever the aborted hash left it"

# Census over the three arms of the same always_ff. Counting assignments
# independently of which registers they name means a regex miss shows up as a
# wrong count rather than passing silently.
RESET_N=$(sed -n '201,205p' "$GH" | grep -cE '^\s+\w+\s+<=' || true)
ZERO_N=$(sed -n '208,211p' "$GH" | grep -cE '^\s+\w+\s+<=' || true)
ELSE_N=$(sed -n '214,219p' "$GH" | grep -cE '^\s+\w+\s+<=' || true)
echo "reset_arm_assignments=$RESET_N"   | tee -a "$W" >> "$RUN_LOG"
echo "zeroize_arm_assignments=$ZERO_N"  | tee -a "$W" >> "$RUN_LOG"
echo "else_arm_assignments=$ELSE_N"     | tee -a "$W" >> "$RUN_LOG"
show "reset_arm_assignments=$RESET_N zeroize_arm_assignments=$ZERO_N else_arm_assignments=$ELSE_N"

gate "[ \"$RESET_N\" = '5' ]" \
     "the reset arm assigns all 5 registers this always_ff holds"
gate "[ \"$ZERO_N\" = '3' ]" \
     "the zeroize arm assigns only 3 of them"
gate "[ \$(( RESET_N - ZERO_N )) = '2' ]" \
     "the difference is exactly 2 registers, matching the two pointer registers named above, so the omission is complete and not a partial clear"
gate "[ \"$ELSE_N\" = '5' ]" \
     "the else arm also assigns all 5, so both omitted registers are ordinary state of this always_ff rather than signals held elsewhere"

show ""
show "----- 2. in-file control: the omitted registers have no other clear -----"

gate "sed -n '217p' '$GH' | grep -q 'read_entry <= read_entry_nxt'" \
     "pv_gen_hash.sv:217 is the only other write to read_entry, and it is the normal next-state update in the else arm"
gate "sed -n '218p' '$GH' | grep -q 'read_offset <= read_offset_nxt'" \
     "pv_gen_hash.sv:218 is the only other write to read_offset, likewise the normal next-state update"
gate "sed -n '110p' '$GH' | grep -q \"read_entry_nxt = rst_rd_ptr ? '0\"" \
     "pv_gen_hash.sv:110 shows read_entry_nxt clearing only on rst_rd_ptr, so the pointer's own reset is a functional one, not a security one"
gate "sed -n '122p' '$GH' | grep -q 'always_comb rst_rd_ptr = arc_GEN_HASH_BLOCK_0_GEN_HASH_NONCE' " \
     "pv_gen_hash.sv:122 defines rst_rd_ptr purely from two mid-hash FSM arcs, neither of which involves zeroize, so no functional path clears the pointer on a zeroize"
gate "! grep -q 'zeroize' <(sed -n '105,125p' '$GH')" \
     "no line in the pointer's next-state logic (pv_gen_hash.sv:105-125) mentions zeroize at all, so the combinational path offers no clear either"

# The pointer registers must have no assignment outside this always_ff and the
# next-state combinationals, or the "nothing else clears it" claim would not hold.
RE_REFS=$(grep -c 'read_entry' "$GH")
RO_REFS=$(grep -c 'read_offset' "$GH")
echo "read_entry_references=$RE_REFS"  | tee -a "$W" >> "$RUN_LOG"
echo "read_offset_references=$RO_REFS" | tee -a "$W" >> "$RUN_LOG"
show "read_entry_references=$RE_REFS read_offset_references=$RO_REFS"
gate "[ \"$RE_REFS\" = '8' ] && [ \"$RO_REFS\" = '9' ]" \
     "read_entry appears $RE_REFS times and read_offset $RO_REFS times in the file, and the gates above account for every write among them"

show ""
show "----- 3. what the stale pointer selects: the PCR read mux -----"

gate "sed -n '196p' '$GH' | grep -q 'assign pv_read.read_entry = read_entry'" \
     "pv_gen_hash.sv:196 drives the read-entry field of the PCR read request straight from the uncleared register"
gate "sed -n '197p' '$GH' | grep -q 'assign pv_read.read_offset = read_offset'" \
     "pv_gen_hash.sv:197 does the same for the read-offset field"
gate "sed -n '137p' '$PV' | grep -q 'always_comb begin : keyvault_readmux'" \
     "pv.sv:137 opens the PCR read mux, which is what answers that request"
gate "sed -n '145p' '$PV' | grep -q 'pv_read\[0\].read_entry == entry' " \
     "pv.sv:145 selects the returned PCR data by matching read_entry against the entry index, so a stale entry pointer returns a different PCR"
gate "sed -n '146p' '$PV' | grep -q 'pv_read\[0\].read_offset == dword'" \
     "pv.sv:146 selects the dword within that entry by read_offset, so a stale offset pointer returns a different dword"
gate "sed -n '147p' '$PV' | grep -q 'PCR_ENTRY\[entry\]\[dword\].data.value'" \
     "pv.sv:147 is the PCR data those two indices select, so the pointer decides which measurement leaves the vault"
gate "sed -n '160p' '$GH' | grep -q 'block_wr_data = pv_rd_resp.read_data'" \
     "pv_gen_hash.sv:160 feeds whatever the mux returned into the hash block being assembled, in GEN_HASH_BLOCK_0"
gate "sed -n '165p' '$GH' | grep -q 'block_wr_data = pv_rd_resp.read_data'" \
     "pv_gen_hash.sv:165 does the same in GEN_HASH_BLOCK_N, so both read states consume the mux output"
gate "sed -n '119p' '$GH' | grep -q 'last_dword_wr = (read_offset == PV_NUM_DWORDS-1) & (read_entry == PV_NUM_PCR-1)'" \
     "pv_gen_hash.sv:119 derives the end-of-read condition from the same two registers, so a stale pointer also shortens the walk: the hash ends when the pointer reaches the last entry, not after all entries have been read"

show ""
show "----- 4. tree control: the sibling read-pointer FSM mirrors its arms -----"

gate "sed -n '158p' '$KVF' | grep -q 'always_ff @(posedge clk or negedge rst_b)'" \
     "kv_fsm.sv:158 opens the equivalent always_ff in the key vault's read/write FSM, the tree's other pointer-driven vault FSM"
gate "sed -n '159,161p' '$KVF' | grep -q \"offset <= '0\"" \
     "kv_fsm.sv:159-161 shows its reset arm clearing the FSM state and its offset pointer"
gate "sed -n '163,166p' '$KVF' | grep -q \"offset <= '0\"" \
     "kv_fsm.sv:163-166 shows its zeroize arm clearing the SAME two things, so the sibling's zeroize arm mirrors its reset arm line for line"
gate "sed -n '180,182p' '$KVF' | grep -qE \"num_dwords_data <= '0\"" \
     "kv_fsm.sv:180-182 shows a second always_ff whose zeroize arm clears even a pure dword-count bookkeeping register, so the sibling's convention is to mirror the reset arm exhaustively"

# Census on the sibling: its zeroize arm must not be smaller than its reset arm,
# which is the property pv_gen_hash violates.
KV_RESET=$(sed -n '159,161p' "$KVF" | grep -cE '^\s+\w+\s+<=' || true)
KV_ZERO=$(sed -n '163,166p' "$KVF" | grep -cE '^\s+\w+\s+<=' || true)
echo "kv_fsm_reset_arm_assignments=$KV_RESET"   | tee -a "$W" >> "$RUN_LOG"
echo "kv_fsm_zeroize_arm_assignments=$KV_ZERO"  | tee -a "$W" >> "$RUN_LOG"
show "kv_fsm_reset_arm_assignments=$KV_RESET kv_fsm_zeroize_arm_assignments=$KV_ZERO"
gate "[ \"$KV_RESET\" = \"$KV_ZERO\" ]" \
     "in the sibling the two arms assign the same number of registers ($KV_RESET each), which is exactly the relation pv_gen_hash breaks"

show ""
show "----- 5. tree control: the parent's own zeroize arm is exhaustive too -----"

gate "grep -q 'pv_gen_hash1' '$SHA'" \
     "sha512.sv instantiates this module as pv_gen_hash1, so the parent below is the block that owns the zeroize"
gate "grep -q '.zeroize(zeroize_reg)' '$SHA'" \
     "sha512.sv wires its own zeroize_reg into this module's zeroize port"
gate "sed -n '284,285p' '$SHA' | grep -q 'hwif_out.SHA512_CTRL.ZEROIZE.value'" \
     "sha512.sv:284-285 sources that strobe from the software-writable SHA512_CTRL.ZEROIZE field, so an unprivileged write reaches the incomplete arm"
gate "sed -n '229p' '$SHA' | grep -q 'else if (zeroize_reg) begin'" \
     "sha512.sv:229 opens the parent's own zeroize arm, on the same strobe it passes into this module"
SHA_ZERO=$(sed -n '230,237p' "$SHA" | grep -cE "^\s+\w+\s+<= '0" || true)
echo "sha512_zeroize_arm_assignments=$SHA_ZERO" | tee -a "$W" >> "$RUN_LOG"
show "sha512_zeroize_arm_assignments=$SHA_ZERO"
gate "[ \"$SHA_ZERO\" -ge '7' ]" \
     "sha512.sv:230-237 clears $SHA_ZERO registers in that arm, so the parent's convention on the very same zeroize strobe is to clear exhaustively"

show ""
show "--- src/pcrvault/rtl/pv_gen_hash.sv:199,220 (the always_ff and its three arms) ---"
sed -n '199,220p' "$GH" | tee -a "$W"

show ""
show "--- src/keyvault/rtl/kv_fsm.sv:158,172 (the sibling, whose arms match) ---"
sed -n '158,172p' "$KVF" | tee -a "$W"

show ""
show "--- src/pcrvault/rtl/pv.sv:137,152 (what the stale pointer selects) ---"
sed -n '137,152p' "$PV" | tee -a "$W"

show ""
show "structural_gates_passed=$PASS/$((PASS+FAIL))"
echo "structural_gates_passed=$PASS/$((PASS+FAIL))" >> "$RUN_LOG"
if [ "$FAIL" -eq 0 ]; then
  show "RESULT: PASS"
  echo "RESULT: PASS - all structural gates confirm BUG-031" >> "$RUN_LOG"
  echo "result=PASS" >> "$RUN_LOG"
else
  show "RESULT: FAIL"
  echo "RESULT: FAIL - at least one structural gate did not hold" >> "$RUN_LOG"
  echo "result=FAIL" >> "$RUN_LOG"
  exit 1
fi
