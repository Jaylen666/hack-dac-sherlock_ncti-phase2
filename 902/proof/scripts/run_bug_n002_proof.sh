#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# BUG-N-002 structural audit.
#
# Every gate is a read-only assertion over the audited checkout at
# /home/smy/hackatdac26-phase-2-caliptra. Nothing is written and nothing is
# elaborated here; the dynamic evidence lives in run_bug_n002_sim.sh.
#
# The gates establish, in order:
#   1. the three-branch shape of the reg_update block
#   2. that the asynchronous reset branch clears both routing registers
#   3. that the zeroize branch clears eight registers but not those two
#   4. that their only updates live in the branch zeroize does not take
#   5. what the residual bits control downstream
#   6. that the residual state cannot retire without a vault completion
#   7. software reachability of every input the witness needs
set -euo pipefail

CMP="${CMP:-/home/smy/hackatdac26-phase-2-caliptra}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE="$(cd "$HERE/../.." && pwd)"
LOGS="$CASE/proof/logs"
mkdir -p "$LOGS"

S="$CMP/src/sha512/rtl/sha512.sv"
H="$CMP/src/integration/rtl/caliptra_reg/caliptra_reg.h"
FD="$CMP/src/integration/rtl/caliptra_reg/caliptra_reg_field_defines.svh"

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
echo "== BUG-N-002 structural audit =="
echo "tree: $CMP"
echo

echo "-- group 1: the reg_update block has three branches --"
gate "sed -n '216p' '$S' | grep -q 'always @ (posedge clk or negedge reset_n)'" \
     "sha512.sv:216 opens the reg_update block"
gate "sed -n '217p' '$S' | grep -q 'if (!reset_n)'" \
     "sha512.sv:217 is the asynchronous reset branch"
gate "sed -n '229p' '$S' | grep -q 'else if (zeroize_reg)'" \
     "sha512.sv:229 is the zeroize branch"
gate "sed -n '239p' '$S' | grep -q 'else begin'" \
     "sha512.sv:239 is the normal-operation branch"

echo
echo "-- group 2: the reset branch clears both routing registers --"
gate "sed -n '224p' '$S' | grep -q \"pcr_hash_extend_ip   <= '0\"" \
     "sha512.sv:224 clears pcr_hash_extend_ip on asynchronous reset"
gate "sed -n '225p' '$S' | grep -q \"hash_extend_entry    <= '0\"" \
     "sha512.sv:225 clears hash_extend_entry on asynchronous reset"

echo
echo "-- group 3: the zeroize branch omits exactly those two --"
gate "[ \"\$(sed -n '230,237p' '$S' | grep -c '<=')\" -eq 8 ]" \
     "the zeroize branch performs 8 assignments"
gate "! sed -n '230,237p' '$S' | grep -q 'pcr_hash_extend_ip'" \
     "pcr_hash_extend_ip is absent from the zeroize branch"
gate "! sed -n '230,237p' '$S' | grep -q 'hash_extend_entry'" \
     "hash_extend_entry is absent from the zeroize branch"
gate "sed -n '230,237p' '$S' | grep -q 'digest_reg'" \
     "the zeroize branch does clear digest_reg, so it is not a stub"
gate "sed -n '230,237p' '$S' | grep -q 'kv_reg'" \
     "the zeroize branch does clear kv_reg"
gate "sed -n '230,237p' '$S' | grep -q 'pcr_sign_reg'" \
     "the zeroize branch does clear pcr_sign_reg"

echo
echo "-- group 4: their only updates are in the branch zeroize skips --"
gate "sed -n '255,256p' '$S' | grep -q 'pcr_hash_extend_ip <= pcr_hash_extend_set'" \
     "sha512.sv:255-256 updates pcr_hash_extend_ip inside the normal branch"
gate "sed -n '257p' '$S' | grep -q 'hash_extend_entry <= pcr_hash_extend_set'" \
     "sha512.sv:257 updates hash_extend_entry inside the normal branch"
gate "[ \"\$(grep -cE 'pcr_hash_extend_ip[[:space:]]+<=' '$S')\" -eq 2 ]" \
     "pcr_hash_extend_ip has exactly 2 assignment sites: reset and normal operation"
gate "[ \"\$(grep -cE '(^|[^_])hash_extend_entry[[:space:]]+<=' '$S')\" -eq 2 ]" \
     "hash_extend_entry has exactly 2 assignment sites: reset and normal operation"

echo
echo "-- group 5: what the residual bits control --"
gate "sed -n '459,462p' '$S' | grep -c 'pcr_hash_extend_ip ?' | grep -q '^4$'" \
     "sha512.sv:459-462 gates all four pv_write fields on pcr_hash_extend_ip"
gate "sed -n '470p' '$S' | grep -q \"kv_write_ctrl_reg_q.write_en = ~pcr_hash_extend_ip ? kv_write_ctrl_reg.write_en : '1\"" \
     "sha512.sv:470 forces the vault write enable to 1 while the bit is set"
gate "sed -n '471p' '$S' | grep -q 'kv_write_ctrl_reg_q.write_entry = ~pcr_hash_extend_ip ? kv_write_ctrl_reg.write_entry : hash_extend_entry'" \
     "sha512.sv:471 overrides the destination entry with hash_extend_entry"
gate "sed -n '425p' '$S' | grep -q 'pcr_hash_extend_ip ? vault_read'" \
     "sha512.sv:425 also routes the vault read on the same bit"
gate "sed -n '335p' '$S' | grep -q 'GEN_PCR_HASH_STATUS.READY.next = ~gen_hash_ip & ~pcr_hash_extend_ip & ready_reg'" \
     "sha512.sv:335 holds the PCR hash status not-ready while the bit is set"

echo
echo "-- group 6: the residual state cannot retire on its own --"
gate "sed -n '372p' '$S' | grep -q 'pcr_hash_extend_reset = pcr_hash_extend_ip & kv_dest_done'" \
     "sha512.sv:372 is the only non-reset clear, and it needs a vault completion"
gate "sed -n '371p' '$S' | grep -q 'pcr_hash_extend_set = kv_read_ctrl_reg.read_en & kv_read_ctrl_reg.pcr_hash_extend'" \
     "sha512.sv:371 sets the bit from two software-writable register fields"
gate "sed -n '284,286p' '$S' | grep -q 'debugUnlock_or_scan_mode_switch'" \
     "the zeroize source at sha512.sv:284-286 includes the debug-unlock/scan switch"
gate "sed -n '192p' '$S' | grep -q '.zeroize(zeroize_reg)'" \
     "the same zeroize_reg is what the SHA-512 core itself is erased with"

echo
echo "-- group 7: software reachability of the witness inputs --"
gate "grep -q 'CLP_SHA512_REG_BASE_ADDR .*(0x10020000)' '$H'" \
     "the SHA-512 block sits at 0x10020000 in the MMIO map"
gate "grep -q 'CLP_SHA512_REG_SHA512_VAULT_RD_CTRL .*(0x10020600)' '$H'" \
     "VAULT_RD_CTRL, the register that raises the bit, is software-addressable"
gate "grep -q 'SHA512_REG_SHA512_VAULT_RD_CTRL_PCR_HASH_EXTEND_LOW .*(6)' '$FD'" \
     "pcr_hash_extend is bit 6 of that register"
gate "grep -q 'SHA512_REG_SHA512_VAULT_RD_CTRL_READ_ENTRY_LOW .*(1)' '$FD'" \
     "read_entry, which becomes hash_extend_entry, starts at bit 1"
gate "grep -q 'CLP_SHA512_REG_SHA512_CTRL .*(0x10020010)' '$H'" \
     "SHA512_CTRL, which carries ZEROIZE, is software-addressable"
gate "grep -q 'SHA512_REG_SHA512_CTRL_ZEROIZE_LOW .*(4)' '$FD'" \
     "ZEROIZE is bit 4 of SHA512_CTRL"
gate "grep -q 'CLP_SHA512_REG_SHA512_GEN_PCR_HASH_STATUS .*(0x10020634)' '$H'" \
     "GEN_PCR_HASH_STATUS, the register the witness observes, is software-readable"

echo
echo "structural_gates_passed=$PASS/$TOTAL"
if [ "$PASS" -eq "$TOTAL" ]; then
  echo "result=PASS"
else
  echo "result=FAIL"
  exit 1
fi
} 2>&1 | tee "$LOGS/structural_audit.log"
