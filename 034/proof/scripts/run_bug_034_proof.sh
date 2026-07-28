#!/usr/bin/env bash
# BUG-034 structural audit: the sha512_masked_core digest port selects the
# unmasked compression working state during invalid cycles.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROOF="$(cd "$HERE/.." && pwd)"
CMP="${CMP:-$(cd "$PROOF/../../.." && pwd)}"
LOGS="$PROOF/logs"
mkdir -p "$LOGS"
AUDIT_LOG="$LOGS/structural_audit.log"
: >"$AUDIT_LOG"

CORE="${DUT_CORE_SV:-$CMP/src/sha512_masked/rtl/sha512_masked_core.sv}"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
DBLOCK="$SCRATCH/digest_assign.txt"
# Extract the digest continuous assignment by content, so the audit survives a
# remediation that shifts line numbering.
# Terminate on the statement's own semicolon rather than on a token that the
# remediation removes; otherwise the extraction runs to end of file and
# re-matches working-register names from unrelated code.
awk '/^  assign digest =/{f=1} f{print; if (/;[[:space:]]*$/) exit}' \
  "$CORE" >"$DBLOCK"

gates_ok=0; gates_total=0
gate() {
  local cmd="$1" desc="$2"
  gates_total=$((gates_total + 1))
  if eval "$cmd" >/dev/null 2>&1; then
    gates_ok=$((gates_ok + 1))
    printf 'gate_ok   [%02d] %s\n' "$gates_total" "$desc" | tee -a "$AUDIT_LOG"
  else
    printf 'gate_fail [%02d] %s\n' "$gates_total" "$desc" | tee -a "$AUDIT_LOG"
  fi
}

{ echo "BUG-034 structural audit"; echo "core=$CORE"; echo; } | tee -a "$AUDIT_LOG"

# --- group 1: the digest port is a two-way select on digest_valid_reg -------
gate "test -f '$CORE'" "masked core source is present"
gate "test -s '$DBLOCK'" "the digest continuous assignment was located by content"
gate "grep -q '{512{digest_valid_reg}}' '$DBLOCK'" \
     "arm 1 of the select is qualified by digest_valid_reg"
gate "grep -q '{512{~digest_valid_reg}}' '$DBLOCK'" \
     "arm 2 of the select is qualified by the inverse of digest_valid_reg"

# --- group 2: the valid arm carries the real hash state ---------------------
gate "grep -q 'H0_reg, H1_reg, H2_reg, H3_reg, H4_reg, H5_reg, H6_reg, H7_reg' '$DBLOCK'" \
     "the valid arm drives the eight H hash registers"

# --- group 3: the invalid arm unmasks the working registers -----------------
gate "grep -q 'a_reg.masked' '$DBLOCK' && grep -q 'h_reg.masked' '$DBLOCK'" \
     "the invalid arm reads the masked shares of the working registers"
gate "grep -q 'a_reg.random' '$DBLOCK' && grep -q 'h_reg.random' '$DBLOCK'" \
     "the invalid arm also reads the random shares of the same registers"
gate "grep -q '\^' '$DBLOCK'" \
     "the two shares are combined with xor, which reconstructs the unmasked value"
gate "! grep -qE \"512'h0|512'b0|'0\\s*\\)\" '$DBLOCK'" \
     "the invalid arm is not a constant, so no safe placeholder is driven"

# --- group 4: the working registers are per-round compression state ---------
gate "grep -q 'a_reg' '$CORE' && grep -q 'rnd_ctr_reg' '$CORE'" \
     "the core carries both working registers and a round counter"
gate "grep -qE 'a_reg *<=|a_new' '$CORE'" \
     "the working registers are updated during the compression rounds"

# --- group 5: digest_valid is a separate output, so software can see both ---
gate "grep -q 'assign digest_valid = digest_valid_reg;' '$CORE'" \
     "digest_valid is exported, so an observer can tell valid from invalid cycles"
gate "grep -qE 'output +wire +\[511 *: *0\] +digest' '$CORE'" \
     "digest is a module output rather than an internal signal"

# --- group 6: no gating exists on the exposed path --------------------------
gate "! grep -qE 'lc_escalate|debug_mode|scan_mode' '$DBLOCK'" \
     "the digest select carries no debug or lifecycle qualifier"
gate "! grep -q 'zeroize' '$DBLOCK'" \
     "the digest select is not qualified by zeroize either"

{ echo; echo "structural_gates_passed=${gates_ok}/${gates_total}"; } | tee -a "$AUDIT_LOG"

if [ "$gates_ok" -eq "$gates_total" ]; then
  echo "result=PASS" | tee -a "$AUDIT_LOG"; exit 0
else
  echo "STRUCTURAL_AUDIT: FAIL" | tee -a "$AUDIT_LOG"; exit 1
fi
