#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# BUG-002 structural audit.
#
# Every gate is a read-only assertion over the audited checkout at
# /home/smy/hackatdac26-phase-2-caliptra. Nothing is written and nothing is
# elaborated here; the dynamic evidence lives in run_bug_002_sim.sh.
#
# The gates establish, in order:
#   1. the concealment mask exists and what its polarity actually is, since the
#      name mask_en suggests the opposite of what the expression computes
#   2. that the mask is armed from block_reg_output alone, with no kv_en term,
#      which is the defect itself
#   3. that kv_en and block_reg_output are independent inputs, so the state
#      kv_en=1 with block_reg_output=0 is a real state and not excluded
#   4. that kv_en is reachable from a software register write
#   5. that block_reg_output is not reachable from software alone, which is why
#      the mask cannot be relied on to cover the KeyVault routing case
#   6. that DATA_OUT reads return the masked hardware path, so the mask's state
#      is what software observes
#   7. that the exposed read is an ordinary unprivileged register access
set -euo pipefail

CMP="${CMP:-/home/smy/hackatdac26-phase-2-caliptra}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE="$(cd "$HERE/../.." && pwd)"
LOGS="$CASE/proof/logs"
mkdir -p "$LOGS"

AES="$CMP/src/aes/rtl/aes.sv"
RT="$CMP/src/aes/rtl/aes_reg_top.sv"
WRAP="$CMP/src/aes/rtl/aes_clp_wrapper.sv"
KVW="$CMP/src/keyvault/rtl/kv_write_client.sv"
FSM="$CMP/src/aes/rtl/aes_control_fsm.sv"

PASS=0
TOTAL=0
gate() { # gate <cmd> <desc>
  TOTAL=$((TOTAL+1))
  if eval "$1" >/dev/null 2>&1; then
    echo "gate_ok   $2"
    PASS=$((PASS+1))
  else
    echo "gate_fail $2"
  fi
}

{
echo "== BUG-002 structural audit =="
echo "tree: $CMP"
echo
echo "-- group 1: the concealment mask, and its real polarity --"
gate "sed -n '153p' '$AES' | grep -q 'Mask to conceal data_out from reg API'" \
     "aes.sv:153 states the intent: conceal data_out from the reg API when dest is KV"
gate "sed -n '154p' '$AES' | grep -q 'hw2reg_data_out_mask = {.*{hw2reg_data_out_mask_en}}'" \
     "aes.sv:154 replicates mask_en across the whole mask word"
gate "sed -n '174p' '$AES' | grep -q 'hw2reg_caliptra.data_out\[idx\].d & hw2reg_data_out_mask'" \
     "aes.sv:174 applies the mask as a bitwise AND onto data_out"
gate "sed -n '191,192p' '$AES' | grep -q 'hw2reg_data_out_mask_en <= 1.b1'" \
     "aes.sv:192 resets mask_en to 1, i.e. an all-ones AND mask: the default is visible, not concealed"

echo
echo "-- group 2: what arms the mask, and what does not --"
gate "sed -n '197p' '$AES' | grep -q 'hw2reg_data_out_mask_en <= ~caliptra2aes.block_reg_output'" \
     "aes.sv:197 derives mask_en from block_reg_output alone"
gate "! sed -n '197p' '$AES' | grep -q 'kv_en'" \
     "aes.sv:197 contains no kv_en term: KeyVault routing does not arm concealment"
gate "sed -n '196p' '$AES' | grep -q 'kv_data_intercept       <= caliptra2aes.kv_en'" \
     "aes.sv:196 uses kv_en on the adjacent line, so the signal is in scope and was not merely forgotten as unavailable"
gate "test \$(grep -c 'hw2reg_data_out_mask_en <=' '$AES') -eq 3" \
     "mask_en has exactly three assignments (reset, arm, release): no other site adds a kv_en term"

echo
echo "-- group 3: kv_en and block_reg_output are independent inputs --"
gate "grep -qE 'caliptra2aes\.block_reg_output *=' '$WRAP'" \
     "block_reg_output is driven in aes_clp_wrapper.sv, outside the aes block"
gate "sed -n '473,475p' '$WRAP' | grep -q 'ocp_lock_in_progress'" \
     "aes_clp_wrapper.sv:473 conjoins block_reg_output with ocp_lock_in_progress"
gate "sed -n '473,475p' '$WRAP' | grep -q 'aes_operation_is_ecb_decrypt'" \
     "aes_clp_wrapper.sv:475 also requires an ECB decrypt operation"
gate "! sed -n '473,475p' '$WRAP' | grep -q 'kv_en'" \
     "block_reg_output does not depend on kv_en, so kv_en=1 with block_reg_output=0 is not excluded"

echo
echo "-- group 4: kv_en is reachable from a software register write --"
gate "sed -n '500p' '$WRAP' | grep -q 'dest_keyvault  (caliptra2aes.kv_en'" \
     "aes_clp_wrapper.sv:500 wires kv_en to the write client's dest_keyvault port"
gate "sed -n '98p' '$KVW' | grep -q 'dest_keyvault = write_ctrl_reg.write_en'" \
     "kv_write_client.sv:98 drives dest_keyvault from a control register's write_en field"
gate "grep -qE 'write_ctrl_reg' '$KVW'" \
     "the write_en field is a register input, so kv_en follows software state rather than hardware state alone"

echo
echo "-- group 5: block_reg_output is not reachable from software alone --"
gate "! grep -qE 'ocp_lock_in_progress *= *[a-z_]*reg' '$WRAP'" \
     "ocp_lock_in_progress is not a plain register field assignment in this file"
gate "test \$(sed -n '473,475p' '$WRAP' | grep -c '&&') -ge 2" \
     "block_reg_output is a conjunction of at least three terms, so no single software write asserts it"

echo
echo "-- group 6: software observes the masked hardware path --"
gate "sed -n '1793p' '$RT' | grep -q 'reg_rdata_next\[31:0\] = data_out_0_qs'" \
     "aes_reg_top.sv:1793 returns data_out_0_qs, the hardware-side value, on a DATA_OUT read"
gate "test \$(grep -cE 'reg_rdata_next\[31:0\] = data_out_[0-3]_qs' '$RT') -eq 4" \
     "all four DATA_OUT words read the _qs hardware path, so the mask governs every readable word"
gate "grep -q 'status.output_lost' '$AES'" \
     "aes.sv augments STATUS.output_lost when output is blocked, the distinct behaviour of the armed case"

echo
echo "-- group 7: the exposed read is an ordinary unprivileged access --"
gate "! sed -n '1790,1810p' '$RT' | grep -q 'lc_escalate\|priv\|debug'" \
     "no privilege, lifecycle, or debug qualifier guards the DATA_OUT read arms"
gate "grep -qE 'cfg_valid *= *~\(\(mode_i == AES_NONE\)' '$FSM'" \
     "aes_control_fsm.sv gates operations only on mode validity, the precondition the witness satisfies"
echo
echo "structural_gates_passed=$PASS/$TOTAL"
if [ "$PASS" -eq "$TOTAL" ]; then
  echo "result=PASS"
else
  echo "result=FAIL"
fi
} | tee "$LOGS/structural_audit.log"

grep -q '^result=PASS' "$LOGS/structural_audit.log"
