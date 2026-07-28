#!/usr/bin/env bash
# BUG-029 negative control.
#
# Rewires one port in sha3.sv: the Keccak round's clear_i is fed the same
# done_i-derived signal that the pad's done_i already gets. That is not an
# externally supplied answer: it is exactly how the twin SHA3 implementation
# inside the same tree, src/sha3/rtl/ot_sha3.sv, wires the same two ports
# (ot_sha3.sv:289 assigns keccak_done = done_i, :450 and :492 wire that one
# signal to both), and that twin contains no second signal at all.
#
# The keccak_done2 declaration and its constant-False assignment are left in
# place, untouched, so the testbench's hierarchical reads of that signal still
# elaborate and the only behavioural difference is the one port connection.
#
# The identical testbench is then run against the patched scratch copy and is
# REQUIRED to fail. If it passed, the testbench would not be measuring the
# defect. The harness's own control counter (cover_fsm_did_advance, which watches
# the FSM leave the squeeze window on the same done_i) must keep firing, so the
# failure is attributable to the RTL change and not to a broken harness.
set -euo pipefail

CMP="${CMP_ROOT:-/home/smy/hackatdac26-phase-2-caliptra}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS="$(cd "$HERE/../logs" && pwd)"
SCRATCH="$(cd "$HERE/../scratch" && pwd)"
NC_LOG="$LOGS/negative_control.log"

SRC="$CMP/src/kmac/rtl/sha3.sv"
PATCHED="$SCRATCH/sha3.sv"

: > "$NC_LOG"
{
  echo "===== BUG-029 negative control ====="
  echo "source DUT : $SRC"
  echo "patched DUT: $PATCHED"
} | tee -a "$NC_LOG"

python3 - "$SRC" "$PATCHED" <<'PY' | tee -a "$NC_LOG"
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()

# The single port connection: clear_i is fed the same signal as the pad's done_i,
# matching ot_sha3.sv:492. Nothing else in the file is altered - the keccak_done2
# declaration and its constant-False assignment stay exactly as the audited tree
# has them, so this is a one-line change and the testbench's reads of that signal
# still elaborate.
old_clear = """    .clear_i    (keccak_done2)"""
new_clear = """    .clear_i    (keccak_done)"""
assert text.count(old_clear) == 1, "expected exactly one clear_i connection"
assert text.count(new_clear) == 0, "clear_i is not already wired to keccak_done"
text = text.replace(old_clear, new_clear, 1)

open(dst, "w").write(text)
print("patch applied: clear_i now driven by the same done_i-derived signal as the pad's done_i")
PY

export PATH="/data0/tools/Synopsys/vcs/vcs/W-2024.09-SP1/bin:$PATH"

set +e
DUT_SHA3="$PATCHED" \
SIM_LOG="$LOGS/negative_control_sim.log" \
CMP_LOG="$LOGS/negative_control_compile.log" \
  "$HERE/run_bug_029_sim.sh" > "$LOGS/negative_control_stdout.log" 2>&1
RC=$?
set -e

NCSIM="$LOGS/negative_control_sim.log"
FAILED=$(grep -c 'TBFAIL' "$NCSIM" || true)
B29=$(grep -c 'TBFAIL: BUG-029' "$NCSIM" || true)
SURVIVE=$(grep -o 'cover_state_survives_done=[0-9]*' "$NCSIM" | tail -1 | cut -d= -f2)
NOCLEAR=$(grep -o 'cover_clear_never_strict=[0-9]*' "$NCSIM" | tail -1 | cut -d= -f2)
CARRY=$(grep -o 'cover_cross_run_carryover=[0-9]*' "$NCSIM" | tail -1 | cut -d= -f2)
FSMCOV=$(grep -o 'cover_fsm_did_advance=[0-9]*' "$NCSIM" | tail -1 | cut -d= -f2)
RESETCTL=$(grep -c 'ok: control: reset zeroes the storage' "$NCSIM" || true)

{
  echo
  echo "----- negative control results -----"
  echo "sim exit code                     : $RC (nonzero expected)"
  echo "TBFAIL lines total                : $FAILED (must be > 0)"
  echo "  of which BUG-029 checks         : $B29 (must be > 0)"
  echo "cover_state_survives_done         : $SURVIVE (must be 0)"
  echo "cover_clear_never_strict          : $NOCLEAR (must be 0)"
  echo "cover_cross_run_carryover         : $CARRY (must be 0)"
  echo "cover_fsm_did_advance (harness)   : $FSMCOV (must stay 1)"
  echo "reset control still passing       : $RESETCTL (must be > 0)"
} | tee -a "$NC_LOG"

VALID=1
[ "$RC" -ne 0 ]       || { echo "INVALID: patched RTL still passed" | tee -a "$NC_LOG"; VALID=0; }
[ "$FAILED" -gt 0 ]   || { echo "INVALID: no self-check tripped" | tee -a "$NC_LOG"; VALID=0; }
[ "$B29" -gt 0 ]      || { echo "INVALID: no BUG-029 check tripped" | tee -a "$NC_LOG"; VALID=0; }
[ "$SURVIVE" = "0" ]  || { echo "INVALID: the state-survives cover did not drop to 0" | tee -a "$NC_LOG"; VALID=0; }
[ "$NOCLEAR" = "0" ]  || { echo "INVALID: the never-cleared cover did not drop to 0" | tee -a "$NC_LOG"; VALID=0; }
[ "$CARRY" = "0" ]    || { echo "INVALID: the cross-run carryover cover did not drop to 0, so the two runs still differ" | tee -a "$NC_LOG"; VALID=0; }
[ "$FSMCOV" = "1" ]   || { echo "INVALID: harness control also broke, harness is suspect" | tee -a "$NC_LOG"; VALID=0; }
[ "$RESETCTL" -gt 0 ] || { echo "INVALID: the reset control check stopped passing" | tee -a "$NC_LOG"; VALID=0; }

{
  echo
  if [ "$VALID" = "1" ]; then
    echo "CONCLUSION: On the audited RTL a strictly-valid done_i moves the SHA3 FSM out of"
    echo "the squeeze window but leaves the 1600-bit Keccak state storage bit-for-bit intact,"
    echo "because the clear_i port is fed a constant MuBi4False that can never pass the"
    echo "strict test the child requires, so rst_storage never fires. A second absorb of the"
    echo "byte-identical message therefore XORs into that residue and yields a different"
    echo "sponge state, so consecutive hashes are not independent. With clear_i rewired to"
    echo "the same done_i-derived signal the twin SHA3 in this tree uses, the same stimulus"
    echo "clears the state, the second run reproduces the first run's state exactly, all"
    echo "three defect covers fall to 0 and the BUG-029 self-checks fail, while the harness's"
    echo "own control observations still pass. The observation is a property of the audited"
    echo "RTL."
    echo "NEGATIVE CONTROL: PASS"
  else
    echo "NEGATIVE CONTROL: FAIL"
  fi
} | tee -a "$NC_LOG"

# The nested sim run rebuilds the build tree after its own cleanup, so drop it
# again here: it is rebuildable and must not ship inside the case.
rm -rf "$HERE/../build"

[ "$VALID" = "1" ]
