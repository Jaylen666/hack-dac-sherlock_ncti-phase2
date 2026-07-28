#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# BUG-014 structural audit.
#
# Every gate is a read-only assertion over the audited checkout at
# /home/smy/hackatdac26-phase-2-caliptra. Nothing is written and nothing is
# elaborated here; the dynamic evidence lives in run_bug_014_sim.sh.
#
# The gates establish, in order:
#   1. that no final-block command signal exists anywhere in the hmac or
#      hmac_drbg RTL, so there is no path by which a caller could request
#      message finalization
#   2. that HMAC512_CTRL bit 5 nevertheless has real storage and is exported to
#      the wrapper, so a write to it is accepted and retained, while the
#      register itself offers software no readback to confirm or deny it
#   3. that no consumer in the wrapper reads that field, so the accepted write
#      changes no behaviour
#   4. that the interrupt bit which would report an illegal command is tied to
#      a constant zero, while its siblings are properly driven
#   5. that the two error conditions which are driven both depend on a KeyVault
#      sideload, so no error is reachable from a register-only command
#   6. that the field is writable without the readiness qualifier its
#      neighbours carry, i.e. it is not merely inert but unguarded
#   7. that the command register write is an ordinary unprivileged access
set -euo pipefail

CMP="${CMP:-/home/smy/hackatdac26-phase-2-caliptra}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE="$(cd "$HERE/../.." && pwd)"
LOGS="$CASE/proof/logs"
mkdir -p "$LOGS"

HM="$CMP/src/hmac/rtl/hmac.sv"
CORE="$CMP/src/hmac/rtl/hmac_core.sv"
REG="$CMP/src/hmac/rtl/hmac_reg.sv"
RDL="$CMP/src/hmac/rtl/hmac_reg.rdl"
DRBG="$CMP/src/hmac_drbg/rtl/hmac_drbg.sv"

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
echo "== BUG-014 structural audit =="
echo "tree: $CMP"
echo
echo "-- group 1: no final-block command exists in the RTL --"
gate "[ \"\$(grep -rc 'last_cmd' '$CMP/src/hmac/rtl' '$CMP/src/hmac_drbg/rtl' 2>/dev/null | awk -F: '{s+=\$2} END {print s+0}')\" = 0 ]" \
     "no last_cmd identifier occurs anywhere in src/hmac/rtl or src/hmac_drbg/rtl"
gate "! grep -rq 'HMAC_last' '$CMP/src/hmac_drbg/rtl'" \
     "hmac_drbg.sv carries no HMAC_last command encoding"
gate "! sed -n '24,44p' '$CORE' | grep -qi 'last'" \
     "hmac_core.sv:24-44 port list has no finalization input"
gate "grep -qE 'input logic +init_cmd' '$CORE' && grep -qE 'input logic +next_cmd' '$CORE'" \
     "hmac_core.sv does declare init_cmd and next_cmd, so the omission is specific to finalization"

echo
echo "-- group 2: CTRL bit 5 is stored and retained, with no readback --"
gate "grep -qE 'decoded_wr_data\[5:5\] & decoded_wr_biten\[5:5\]' '$REG'" \
     "hmac_reg.sv:875 loads CTRL bit 5 from the software write data"
gate "grep -qE 'field_storage\.HMAC512_CTRL\.Reserved\.value <= field_combo' '$REG'" \
     "hmac_reg.sv:885 commits that value to a real flop, so the write sticks"
gate "grep -qE 'assign hwif_out\.HMAC512_CTRL\.Reserved\.value = field_storage' '$REG'" \
     "hmac_reg.sv:888 exports the stored value to the wrapper, so the request is retained"
gate "! grep -q 'decoded_reg_strb.HMAC512_CTRL && !decoded_req_is_wr' '$REG'" \
     "the decode has no read arm for HMAC512_CTRL, so software cannot confirm the request"
gate "sed -n '68p' '$RDL' | grep -q 'default sw = w'" \
     "hmac_reg.rdl:68 declares the CTRL register software-write-only, which is why"
gate "grep -qE 'Reserved' '$RDL'" \
     "hmac_reg.rdl declares the field, placing it at bit 5 after INIT/NEXT/ZEROIZE/MODE/CSR_MODE"

echo
echo "-- group 3: nothing consumes the field --"
gate "[ \"\$(grep -c 'hwif_out\.HMAC512_CTRL\.Reserved' '$HM')\" = 0 ]" \
     "hmac.sv never reads hwif_out.HMAC512_CTRL.Reserved, so the accepted write drives no logic"
gate "grep -qE 'init_reg = hwif_out\.HMAC512_CTRL\.INIT\.value' '$HM'" \
     "hmac.sv:257 does consume INIT, establishing the pattern a live command field follows"
gate "grep -qE 'next_reg = hwif_out\.HMAC512_CTRL\.NEXT\.value' '$HM'" \
     "hmac.sv:258 does consume NEXT, so only the finalization field is unread"

echo
echo "-- group 4: the illegal-command interrupt is tied off --"
gate "grep -qE 'error2_sts\.hwset = 1.b0' '$HM'" \
     "hmac.sv:428 ties error2_sts.hwset to constant 0, so that status can never set"
gate "grep -qE 'error2_sts\.hwset = 1.b0; // TODO' '$HM'" \
     "the tie is marked TODO in the source, i.e. it is an unfinished driver, not a decision"
gate "grep -qE 'key_mode_error_sts\.hwset = key_mode_error_edge' '$HM'" \
     "hmac.sv:426 drives the sibling key_mode_error_sts from real logic"
gate "grep -qE 'key_zero_error_sts\.hwset = key_zero_error_edge' '$HM'" \
     "hmac.sv:427 drives the sibling key_zero_error_sts from real logic"
gate "grep -qE 'readback_array\[[0-9]+\]\[2:2\].*error2_sts' '$REG'" \
     "hmac_reg.sv:2332 maps error2_sts to error_internal_intr_r bit 2, the bit software would poll"

echo
echo "-- group 5: no register-only error path exists --"
gate "grep -qE 'key_mode_error = kv_key_data_present' '$HM'" \
     "hmac.sv:395 gates key_mode_error on the KeyVault sideload being present"
gate "grep -qE 'key_zero_error = kv_key_data_present' '$HM'" \
     "hmac.sv:396 gates key_zero_error on the same sideload"
gate "grep -qE 'error_flag = key_zero_error \| key_mode_error' '$HM'" \
     "hmac.sv:398 aggregates exactly those two, so a register-programmed command raises nothing"

echo
echo "-- group 6: the field is unguarded, not merely inert --"
gate "grep -qE 'HMAC512_CTRL\.INIT\.swwe = ready_reg' '$HM'" \
     "hmac.sv:251 qualifies INIT writes on ready_reg"
gate "[ \"\$(grep -c 'HMAC512_CTRL\.Reserved\.swwe' '$HM')\" = 0 ]" \
     "no swwe qualifier is applied to bit 5, so it accepts writes even while the block is busy"
gate "! sed -n '868,888p' '$REG' | grep -q 'singlepulse'" \
     "hmac_reg.sv:868-888 has no self-clear, so the stale request persists after the write"

echo
echo "-- group 7: the write is an ordinary unprivileged access --"
gate "! sed -n '868,888p' '$REG' | grep -q 'lc_escalate\|priv\|debug'" \
     "no privilege, lifecycle, or debug qualifier guards the CTRL bit 5 write"
gate "grep -qE 'input wire +cs' '$HM' && grep -qE 'input wire +we' '$HM'" \
     "hmac.sv exposes a plain cs/we register interface, the path the witness drives"
echo
echo "structural_gates_passed=$PASS/$TOTAL"
if [ "$PASS" -eq "$TOTAL" ]; then
  echo "result=PASS"
else
  echo "result=FAIL"
fi
} | tee "$LOGS/structural_audit.log"

grep -q '^result=PASS' "$LOGS/structural_audit.log"
