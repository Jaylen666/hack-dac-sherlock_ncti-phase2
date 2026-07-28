#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# BUG-N-002 negative control (non-vacuity).
#
# Applies the mitigation this submission proposes to a scratch copy of sha512.sv
# and re-runs the identical witness testbench against it. The audited checkout is
# never modified.
#
# The mitigation adds the two missing assignments to the zeroize branch, so the
# PCR hash-extend routing state is cleared on a security erase exactly as the
# asynchronous reset branch already clears it at sha512.sv:224-225.
#
# Expected outcome: the witness testbench FAILS. GEN_PCR_HASH_STATUS.READY reads
# high after the zeroize, so the witness no longer reproduces.
#
# This run is also what establishes that the zeroize reached the DUT at all in
# the unmodified run: the stimulus is byte-identical between the two runs and the
# only difference is the two added assignments in the zeroize branch, so the
# observation flipping proves that branch was taken.
set -euo pipefail

CMP="${CMP:-/home/smy/hackatdac26-phase-2-caliptra}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE="$(cd "$HERE/../.." && pwd)"
LOGS="$CASE/proof/logs"

mkdir -p "$LOGS"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/bugn002_nc.XXXXXX")"
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT

PATCHED="$SCRATCH/sha512.sv"
cp "$CMP/src/sha512/rtl/sha512.sv" "$PATCHED"

python3 - "$PATCHED" <<'PY'
import sys
p = sys.argv[1]
text = open(p).read()

# The last line of the zeroize branch. Append the two missing clears after it.
old = ("      digest_we            <= '0;\n"
       "      block_reg_lock       <= '0;\n"
       "    end\n")
new = ("      digest_we            <= '0;\n"
       "      block_reg_lock       <= '0;\n"
       "      pcr_hash_extend_ip   <= '0;\n"
       "      hash_extend_entry    <= '0;\n"
       "    end\n")

assert text.count(old) == 1, "zeroize branch tail not found exactly once"
text = text.replace(old, new)
open(p, "w").write(text)
print("negative control patch applied: zeroize branch now clears the extend routing state")
PY

# Show the patched zeroize branch, read straight out of the scratch copy, so the
# applied edit is recorded without invoking any comparison tool.
{
  echo "== negative control: patched DUT =="
  echo "scratch copy: $PATCHED"
  echo "zeroize branch as patched:"
  grep -n "pcr_hash_extend_ip   <= '0;\|hash_extend_entry    <= '0;" "$PATCHED"
} | tee "$LOGS/negative_control.log"

set +e
DUT_SHA512="$PATCHED" "$HERE/run_bug_n002_sim.sh" >"$SCRATCH/nc_run.txt" 2>&1
RC=$?
set -e
cat "$SCRATCH/nc_run.txt" | tee -a "$LOGS/negative_control.log"

NC_WITNESS=$(grep -c "WITNESS extend_routing_state_survives_zeroize" "$SCRATCH/nc_run.txt" || true)
NC_CLEARED=$(grep -c "CHECK_PASS witness_zeroize_clears_extend_routing_state" "$SCRATCH/nc_run.txt" || true)
NC_SETUP=$(grep -c "CHECK_PASS witness_setup_extend_took_effect" "$SCRATCH/nc_run.txt" || true)
NC_BASELINE=$(grep -c "CHECK_PASS control_quiescent_pcr_hash_status_ready" "$SCRATCH/nc_run.txt" || true)
NC_NOERR=$(grep -c "CHECK_PASS containment_no_bus_error" "$SCRATCH/nc_run.txt" || true)
NC_TIMEOUT=$(grep -c "TBFAIL global timeout" "$SCRATCH/nc_run.txt" || true)

FAILED=0
chk() { # chk <desc> <actual> <expected>
  if [ "$2" = "$3" ]; then echo "nc_ok   $1 ($2)"; else echo "nc_fail $1 (got $2, want $3)"; FAILED=1; fi
}

{
  echo "== negative control assertions =="
  chk "witness testbench no longer passes"          "$RC"          "1"
  chk "residual-state witness no longer reproduces" "$NC_WITNESS"  "0"
  chk "zeroize now clears the extend routing state" "$NC_CLEARED"  "1"
  chk "the extend still took effect before zeroize" "$NC_SETUP"    "1"
  chk "quiescent baseline unchanged"                "$NC_BASELINE" "1"
  chk "still no bus error"                          "$NC_NOERR"    "1"
  chk "no simulation timeout"                       "$NC_TIMEOUT"  "0"
} | tee -a "$LOGS/negative_control.log"

if [ "$FAILED" -ne 0 ]; then
  echo "NEGATIVE_CONTROL: FAIL" | tee -a "$LOGS/negative_control.log"
  exit 1
fi
echo "NEGATIVE_CONTROL: PASS" | tee -a "$LOGS/negative_control.log"
