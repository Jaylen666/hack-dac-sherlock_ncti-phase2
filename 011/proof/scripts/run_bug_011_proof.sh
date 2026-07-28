#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# BUG-011 structural audit.
#
# Every gate is a read-only assertion over the audited checkout at
# /home/smy/hackatdac26-phase-2-caliptra. Nothing is written and nothing is
# elaborated here; the dynamic evidence lives in run_bug_011_sim.sh.
#
# The gates establish, in order:
#   1. the intent the module documents for the extended zeroize hold
#   2. the release condition that contradicts it
#   3. that zeroize_reg's only consumer is the FSM state flop
#   4. that init_done is a core-readiness input, not a per-flow signal
#   5. what the hold actually protects, and what it does not
#   6. the specification text describing the clear-obf-secrets step
set -euo pipefail

CMP="${CMP:-/home/smy/hackatdac26-phase-2-caliptra}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE="$(cd "$HERE/../.." && pwd)"
LOGS="$CASE/proof/logs"
mkdir -p "$LOGS"

F="$CMP/src/doe/rtl/doe_fsm.sv"
C="$CMP/src/doe/rtl/doe_cbc.sv"
SPEC="$CMP/docs/CaliptraHardwareSpecification.md"

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
echo "== BUG-011 structural audit =="
echo "tree: $CMP"
echo

echo "-- group 1: the documented intent of the extended hold --"
gate "sed -n '112,118p' '$F' | grep -q 'zeroize input is a single pulse'" \
     "doe_fsm.sv:112-118 states zeroize arrives as a single pulse"
gate "sed -n '112,118p' '$F' | grep -q 'remain in IDLE until next DOE_CMD is issued'" \
     "the same comment requires the fsm to remain in IDLE until the next DOE_CMD"
gate "sed -n '112,118p' '$F' | grep -q 'extending zeroize to a level so we can keep the fsm in IDLE'" \
     "the comment names the mechanism: extend zeroize to a level"
# the sentence wraps across lines 117-118, so match it after folding newlines out
gate "sed -n '112,118p' '$F' | tr '\n' ' ' | grep -q 'When the.*next command is issued, this extended signal is reset'" \
     "the comment names the intended release event: the next command"

echo
echo "-- group 2: the release condition that contradicts it --"
gate "sed -n '119,129p' '$F' | grep -q 'always_ff @(posedge clk or negedge rst_b)'" \
     "the hold is a reset-clocked flop at doe_fsm.sv:119-129"
gate "sed -n '119,129p' '$F' | grep -q 'else if (zeroize) begin'" \
     "zeroize sets the hold and takes priority over the release"
gate "sed -n '126p' '$F' | grep -q 'running_uds || running_fe || running_hek'" \
     "doe_fsm.sv:126 releases on the running UDS/FE/HEK flow terms"
gate "sed -n '126p' '$F' | grep -q 'init_done && (kv_doe_fsm_ps != DOE_IDLE)'" \
     "doe_fsm.sv:126 additionally releases on init_done && state != DOE_IDLE"
gate "[ \"\$(grep -c 'init_done && (kv_doe_fsm_ps != DOE_IDLE)' '$F')\" -eq 1 ]" \
     "that extra disjunct appears exactly once in the module"

echo
echo "-- group 3: zeroize_reg has exactly one consumer --"
gate "[ \"\$(grep -c 'zeroize_reg' '$F')\" -eq 5 ]" \
     "zeroize_reg census in doe_fsm.sv is 5 occurrences (1 decl, 3 in the flop, 1 use)"
gate "grep -q 'logic zeroize_reg;' '$F'" \
     "zeroize_reg is a module-local signal, not a port"
gate "sed -n '286p' '$F' | grep -q 'else if (zeroize_reg) begin'" \
     "doe_fsm.sv:286 is the sole consumer, the state flop's hold branch"
gate "sed -n '287,291p' '$F' | grep -q 'kv_doe_fsm_ps <= DOE_IDLE'" \
     "the hold branch forces kv_doe_fsm_ps to DOE_IDLE"
gate "sed -n '287,291p' '$F' | grep -q 'dest_addr <= .0'" \
     "the hold branch also clears dest_addr"

echo
echo "-- group 4: init_done is core readiness, not a per-flow signal --"
gate "grep -q 'input logic init_done' '$F'" \
     "init_done is an input port of doe_fsm"
gate "grep -q '\.init_done(core_ready)' '$C'" \
     "doe_cbc.sv wires init_done to core_ready"
gate "[ \"\$(grep -c 'init_done' '$F')\" -eq 4 ]" \
     "init_done census in doe_fsm.sv is 4 occurrences"
gate "sed -n '147p' '$F' | grep -q 'arc_DOE_WAIT_DOE_WRITE = init_done'" \
     "doe_fsm.sv:147 is one of the two legitimate init_done uses"
gate "sed -n '149p' '$F' | grep -q 'arc_DOE_WAIT_DOE_BLOCK = init_done'" \
     "doe_fsm.sv:149 is the other"

echo
echo "-- group 5: what the hold protects, and what it does not --"
gate "sed -n '234p' '$F' | grep -q 'dest_addr_en = ((kv_doe_fsm_ps == DOE_IDLE) & arc_DOE_IDLE_DOE_INIT)'" \
     "doe_fsm.sv:234 captures dest_addr only on the IDLE->INIT arc, which the hold blocks"
gate "sed -n '213,214p' '$C' | grep -q 'clear_obf_secrets = (doe_cmd_reg.cmd == DOE_CLEAR) || debugUnlock_or_scan_mode_switch'" \
     "doe_cbc.sv:213 derives clear_obf_secrets from DOE_CLEAR or debug-unlock/scan"
gate "sed -n '214p' '$C' | grep -q 'zeroize = clear_obf_secrets'" \
     "doe_cbc.sv:214 drives zeroize from clear_obf_secrets"
gate "sed -n '227p' '$C' | grep -q 'DOE_IV\[dword\].IV.hwclr = zeroize'" \
     "the IV wipe is driven by zeroize itself, not by the extended hold"
gate "sed -n '203,204p' '$C' | grep -q 'hwclr = flow_done | clear_obf_secrets'" \
     "doe_cbc.sv:203-204 clears CMD on clear_obf_secrets, which is why the command drops to NOP"
gate "! sed -n '286,291p' '$F' | grep -q 'kv_write\|src_write\|key'" \
     "the hold branch performs no key or key-vault wipe of its own"

echo
echo "-- group 6: specification text for the clear step --"
gate "sed -n '2588,2600p' '$SPEC' | grep -q 'clear obf secrets command flushes the obfuscation key'" \
     "the specification describes the clear-obf-secrets flush"
gate "sed -n '2588,2600p' '$SPEC' | grep -q 'after both de-obfuscation flows are complete'" \
     "the specification expects the clear after the de-obfuscation flows complete"

echo
echo "structural_gates_passed=$PASS/$TOTAL"
if [ "$PASS" -eq "$TOTAL" ]; then
  echo "result=PASS"
else
  echo "result=FAIL"
  exit 1
fi
} 2>&1 | tee "$LOGS/structural_audit.log"
