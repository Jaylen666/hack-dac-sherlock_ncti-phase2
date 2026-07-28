#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# BUG-004 structural audit.
#
# Every gate is a read-only assertion over the audited checkout at
# /home/smy/hackatdac26-phase-2-caliptra. Nothing is written and nothing is
# elaborated here; the dynamic evidence lives in run_bug_004_sim.sh.
#
# The gates establish, in order:
#   1. what the audited tree's own RDL declares for the key-share registers
#   2. that the read multiplexer returns register-path content on those addresses
#   3. that the same case statement contains both correct idioms, so the
#      defective arms are not the only shape this generator emits
#   4. which subreg_ext port the defective arms read, and therefore what the
#      returned value actually is
#   5. that the returned value is the requester's own A-channel data, traced
#      end to end through named signals
#   6. that the stored key shares are on a path this multiplexer does not read,
#      which is what bounds the claim away from key disclosure
#   7. that the exposed read is an ordinary unprivileged register access
set -euo pipefail

CMP="${CMP:-/home/smy/hackatdac26-phase-2-caliptra}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE="$(cd "$HERE/../.." && pwd)"
LOGS="$CASE/proof/logs"
mkdir -p "$LOGS"

RT="$CMP/src/aes/rtl/aes_reg_top.sv"
RDL="$CMP/src/aes/data/aes.rdl"
SUB="$CMP/src/caliptra_prim/rtl/caliptra_prim_subreg_ext.sv"
CORE="$CMP/src/aes/rtl/aes_core.sv"
ADP="$CMP/src/caliptra_tlul/rtl/caliptra_tlul_adapter_reg.sv"
PKG="$CMP/src/aes/rtl/aes_reg_pkg.sv"

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
echo "== BUG-004 structural audit =="
echo "tree: $CMP"
echo

echo "-- group 1: the audited tree's own RDL declares the key shares write-only --"
gate "sed -n '8p' '$RDL' | grep -q 'sw = w;'" \
     "aes.rdl:8 declares KEY_SHARE0 fields sw = w (write-only)"
gate "sed -n '27p' '$RDL' | grep -q 'sw = w;'" \
     "aes.rdl:27 declares KEY_SHARE1 fields sw = w (write-only)"
gate "sed -n '24p' '$RDL' | grep -q 'KEY_SHARE0\[8\] @ 0x04'" \
     "aes.rdl:24 places KEY_SHARE0[8] at offset 0x04"
gate "sed -n '43p' '$RDL' | grep -q 'KEY_SHARE1\[8\] @ 0x24'" \
     "aes.rdl:43 places KEY_SHARE1[8] at offset 0x24"
gate "sed -n '46p' '$RDL' | grep -q 'sw = rw;'" \
     "aes.rdl:46 declares IV fields sw = rw, the adjacent readable control"

echo
echo "-- group 2: the read multiplexer returns register-path content on all 16 --"
gate "sed -n '1727p' '$RT' | grep -q 'always_comb'" \
     "aes_reg_top.sv:1727 opens the read-response multiplexer"
gate "sed -n '1735p' '$RT' | grep -q 'addr_hit\[1\]:  reg_rdata_next\[31:0\] = reg2hw.key_share0\[0\].q;'" \
     "aes_reg_top.sv:1735 returns reg2hw.key_share0[0].q on the first share-0 address"
gate "sed -n '1765p' '$RT' | grep -q 'addr_hit\[16\]: reg_rdata_next\[31:0\] = reg2hw.key_share1\[7\].q;'" \
     "aes_reg_top.sv:1765 returns reg2hw.key_share1[7].q on the last share-1 address"
gate "[ \"\$(grep -cE 'reg_rdata_next\[31:0\] = reg2hw\.key_share' '$RT')\" -eq 16 ]" \
     "all 16 key-share arms read a register path: exactly 16 such assignments exist"
gate "sed -n '125p' '$RT' | grep -q 'assign reg_rdata = reg_rdata_next'" \
     "aes_reg_top.sv:125 drives the bus read data straight from reg_rdata_next"

echo
echo "-- group 3: the same case statement carries both correct idioms --"
gate "sed -n '1731,1733p' '$RT' | grep -q \"reg_rdata_next\[0\] = '0;\"" \
     "aes_reg_top.sv:1731-1733 shows the explicit-zero idiom on addr_hit[0]"
gate "sed -n '1768p' '$RT' | grep -q 'reg_rdata_next\[31:0\] = iv_0_qs;'" \
     "aes_reg_top.sv:1768 shows the hardware-value idiom (_qs) on the IV address"
gate "[ \"\$(grep -cE 'reg_rdata_next\[31:0\] = [a-z0-9_]+_qs' '$RT')\" -eq 8 ]" \
     "8 arms in the same file read a _qs hardware value, so the defective shape is not forced"

echo
echo "-- group 4: which subreg_ext port the defective arms read --"
gate "sed -n '28p' '$SUB' | grep -q 'assign q = wd;'" \
     "caliptra_prim_subreg_ext.sv:28 drives q from wd, the bus write data"
gate "sed -n '27p' '$SUB' | grep -q 'assign qs = d;'" \
     "caliptra_prim_subreg_ext.sv:27 drives qs from d, the hardware-side value"
gate "! grep -q 'always_ff' '$SUB'" \
     "caliptra_prim_subreg_ext.sv has no sequential element: q is combinational, not stored"
gate "sed -n '292p' '$RT' | grep -q '\.wd     (key_share0_0_wd)'" \
     "aes_reg_top.sv:292 feeds u_key_share0_0.wd from key_share0_0_wd"
gate "sed -n '296p' '$RT' | grep -q '\.q      (reg2hw.key_share0\[0\].q)'" \
     "aes_reg_top.sv:296 takes reg2hw.key_share0[0].q from that instance's q port"

echo
echo "-- group 5: the returned value is the requester's own A-channel data --"
gate "sed -n '1569p' '$RT' | grep -q 'assign key_share0_0_wd = reg_wdata\[31:0\];'" \
     "aes_reg_top.sv:1569 assigns key_share0_0_wd from reg_wdata"
gate "sed -n '84p' '$ADP' | grep -q 'assign wdata_o = tl_i.a_data;'" \
     "caliptra_tlul_adapter_reg.sv:84 drives wdata_o from tl_i.a_data"
gate "grep -q 'reg_wdata' '$RT'" \
     "aes_reg_top.sv carries reg_wdata, the adapter output the wd chain starts from"

echo
echo "-- group 6: the stored key shares are on a path this multiplexer never reads --"
gate "sed -n '1028p' '$CORE' | grep -q 'hw2reg.key_share0\[i\].d = key_init_q\[0\]\[i\];'" \
     "aes_core.sv:1028 drives hw2reg.key_share0[].d from key_init_q, the stored share"
gate "sed -n '1029p' '$CORE' | grep -q 'hw2reg.key_share1\[i\].d = key_init_q\[1\]\[i\];'" \
     "aes_core.sv:1029 drives hw2reg.key_share1[].d from the second stored share"
gate "sed -n '480p' '$CORE' | grep -q \"key_init_cipher\[0\] = key_init_q\[0\] \^ key_init_q\[1\]\"" \
     "aes_core.sv:480 forms the cipher key as the XOR of the two stored shares"
gate "sed -n '298p' '$RT' | grep -qE '\.qs +\(\)'" \
     "aes_reg_top.sv:298 leaves u_key_share0_0.qs unconnected: the stored value has no wire out"
gate "[ \"\$(grep -c 'key_share[01]_[0-7]_qs' '$RT')\" -eq 0 ]" \
     "no key_share*_qs signal exists in the file, so no arm could return the stored share"
gate "sed -n '634p' '$RT' | grep -q '\.qs     (iv_0_qs)'" \
     "aes_reg_top.sv:634 by contrast wires u_iv_0.qs out, which is why IV reads hardware state"

echo
echo "-- group 7: the exposed read is an ordinary unprivileged register access --"
gate "grep -q 'AES_KEY_SHARE0_0_OFFSET' '$PKG'" \
     "aes_reg_pkg.sv exposes the share-0 offset as a software-visible address"
gate "grep -q 'AES_KEY_SHARE1_0_OFFSET' '$PKG'" \
     "aes_reg_pkg.sv exposes the share-1 offset as a software-visible address"
gate "sed -n '268p' '$PKG' | grep -qE \"AES_KEY_SHARE0_0_OFFSET = 8'h 4;\"" \
     "aes_reg_pkg.sv:268 places the share-0 offset at 4, matching the RDL placement at 0x04"
gate "grep -q 'AES_STATUS_OFFSET' '$PKG'" \
     "aes_reg_pkg.sv exposes STATUS, the idle precondition the witness reads"
gate "! sed -n '1735,1765p' '$RT' | grep -q 'lc_escalate\|priv\|debug'" \
     "no privilege, lifecycle, or debug qualifier guards the 16 defective arms"

echo
echo "structural_gates_passed=$PASS/$TOTAL"
if [ "$PASS" -eq "$TOTAL" ]; then
  echo "result=PASS"
else
  echo "result=FAIL"
fi
} | tee "$LOGS/structural_audit.log"

grep -q '^result=PASS' "$LOGS/structural_audit.log"
