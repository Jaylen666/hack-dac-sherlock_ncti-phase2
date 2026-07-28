#!/usr/bin/env bash
# BUG-009 structural audit: the CSRNG internal-state dump is gated by application 0's
# read-enable bit for every application.
#
# The finding is established entirely from evidence inside the audited tree. The tree's
# own register description states that the enable is per instance and that the bit of
# the SELECTED instance is what must be set; the module declares the vector one bit per
# application and provides a per-application generate loop; but the qualification that
# consumes that vector sits OUTSIDE the loop and replicates bit 0 across every lane.
# The gates below also establish that the qualified value reaches a software-readable
# register window, which is what makes the mis-index a confidentiality issue rather
# than a cosmetic one. Every gate below reads only the submitted checkout; no outside
# source of expected behaviour is consulted anywhere.
set -euo pipefail

CMP="${AUDIT_ROOT:-/home/smy/hackatdac26-phase-2-caliptra}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS="$(cd "$HERE/../logs" && pwd)"
W="$LOGS/witness.log"
RUN_LOG="$LOGS/run.log"
S="$CMP/src/csrng/rtl/csrng_state_db.sv"
CORE="$CMP/src/csrng/rtl/csrng_core.sv"
RTOP="$CMP/src/csrng/rtl/csrng_reg_top.sv"
RDL="$CMP/src/csrng/data/csrng.rdl"
HJ="$CMP/src/csrng/data/csrng.hjson"

PASS=0; FAIL=0
: > "$W"
{
  echo "BUG-009 structural audit (single-tree)"
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

show "===== BUG-009 structural audit (single-tree, audited RTL only) ====="
show ""
show "----- 1. the rule the tree states for itself -----"

gate "grep -q 'Per-instance internal state read enable' '$RDL'" \
     "csrng.rdl describes INT_STATE_READ_ENABLE as a PER-INSTANCE enable"

gate "grep -q 'internal state of the corresponding instance is readable' '$RDL'" \
     "the rdl binds each bit to the internal state of the CORRESPONDING instance"

gate "grep -q 'INT_STATE_READ_ENABLE bit of the selected instance needs to be set' '$HJ'" \
     "csrng.hjson states the bit of the SELECTED instance is what must be set"

gate "grep -q 'INT_STATE_READ_ENABLE\[2:0\]' '$RDL'" \
     "the field is a three-bit vector, one bit per instance, not a single global enable"

show ""
show "----- 2. the port the module declares -----"

gate "grep -Eq 'input logic \[NApps-1:0\] +int_state_read_enable_i' '$S'" \
     "csrng_state_db declares the authorization input one bit per application"

gate "grep -Eq 'parameter logic \[31:0\] NApps' '$S'" \
     "NApps is the application count, so the vector is indexed by application"

gate "[ \"\$(sed -n '70,72p' '$S' | grep -c 'NApps-1:0')\" -eq 3 ]" \
     "the select, dump-select and qualified vectors are all one bit per application"

show ""
show "----- 3. how the vector is actually consumed -----"

gate "sed -n '115p' '$S' | grep -q 'int_st_dump_qualified = int_st_dump_sel & {NApps{int_state_read_enable_i\[0\]}}'" \
     "line 115 replicates bit 0 of the authorization vector across all NApps lanes"

gate "! sed -n '115p' '$S' | grep -q 'rd'" \
     "line 115 carries no per-application index at all"

gate "sed -n '117p' '$S' | grep -q 'for (genvar rd = 0; rd < NApps; rd = rd+1)'" \
     "a per-application generate loop providing the index rd begins on the NEXT line"

gate "[ \"\$(grep -c 'int_state_read_enable_i' '$S')\" -eq 2 ]" \
     "int_state_read_enable_i is referenced exactly twice: its declaration and line 115"

gate "! grep -q 'int_state_read_enable_i\[rd\]' '$S'" \
     "the authorization vector is never indexed by the application being read"

show ""
show "----- 4. the sibling lane in the same loop indexes correctly -----"

gate "sed -n '119p' '$S' | grep -q 'int_st_dump_sel\[rd\] = (int_st_dump_id_q == rd)'" \
     "the dump SELECT in the same loop is indexed per application, so rd is in scope there"

gate "sed -n '118p' '$S' | grep -q 'int_st_out_sel\[rd\] = (state_db_rd_inst_id_i == rd)'" \
     "the hardware read select is likewise per application, establishing the intended idiom"

gate "sed -n '121p' '$S' | grep -q 'internal_states_dump\[rd\] = int_st_dump_qualified\[rd\]'" \
     "the qualified vector is consumed per application, so lane rd carries application rd's state"

show ""
show "----- 5. the qualified value reaches software -----"

gate "sed -n '140p' '$S' | grep -q \"internal_state_diag = {30'b0,internal_state_pl_dump}\"" \
     "the dumped state becomes internal_state_diag"

gate "sed -n '144p' '$S' | grep -q 'state_db_reg_rd_val_o'" \
     "internal_state_diag is windowed into the 32-bit register read output"

gate "grep -Eq 'assign \{state_db_rd_fips_o,state_db_rd_inst_st_o,' '$S'" \
     "the same internal-state layout carries the DRBG key and V, so the window exposes key material"

gate "sed -n '180p' '$S' | grep -q 'reseed_counter_o\[i\] = internal_states_q\[i\]\[31:0\]'" \
     "the reseed counter is separately and unconditionally exported, so it is NOT the sensitive part of the window"

show ""
show "----- 6. software reachability of the authorization vector -----"

gate "sed -n '1247p' '$CORE' | grep -q 'int_state_read_enable = reg2hw.int_state_read_enable.q'" \
     "the vector is driven straight from a software-writable register field"

gate "sed -n '1285p' '$CORE' | grep -q 'int_state_read_enable_i(int_state_read_enable)'" \
     "csrng_core wires that register field into the state database"

gate "sed -n '2317p' '$RTOP' | grep -q 'int_state_read_enable_wd = reg_wdata\[2:0\]'" \
     "the field is written from the register bus, so the mask is under software control"

show ""
show "----- evidence excerpts -----"
show ""
show "--- src/csrng/rtl/csrng_state_db.sv:112,123 (the mis-indexed qualification and the loop) ---"
sed -n '112,123p' "$S" | tee -a "$W"

show ""
show "--- src/csrng/rtl/csrng_state_db.sv:135,145 (the path from dump to the software window) ---"
sed -n '135,145p' "$S" | tee -a "$W"

show ""
show "--- src/csrng/data/csrng.rdl:220,228 (the per-instance rule the tree states) ---"
sed -n '220,228p' "$RDL" | tee -a "$W"

show ""
show "structural_gates_passed=$PASS/$((PASS+FAIL))"
echo "structural_gates_passed=$PASS/$((PASS+FAIL))" >> "$RUN_LOG"
if [ "$FAIL" -eq 0 ]; then
  show "RESULT: PASS"
  echo "RESULT: PASS - all structural gates confirm BUG-009" >> "$RUN_LOG"
  echo "result=PASS" >> "$RUN_LOG"
else
  show "RESULT: FAIL"
  echo "RESULT: FAIL - at least one structural gate did not hold" >> "$RUN_LOG"
  echo "result=FAIL" >> "$RUN_LOG"
  exit 1
fi
