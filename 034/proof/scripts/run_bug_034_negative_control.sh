#!/usr/bin/env bash
# BUG-034 negative control (non-vacuity proof).
#
# Replaces the invalid-cycle arm of the digest select with a constant on a
# scratch copy of the core, then re-runs both the structural audit and the
# identical witness testbench against it. Requirements:
#   - the audit must fail on the gates that describe the unmasking arm
#   - the witness sim must stop reporting all three witness statements
#   - the engine must still compute the correct digest for the published test vector, so the fix
#     is shown to be targeted rather than a break of the hash itself
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROOF="$(cd "$HERE/.." && pwd)"
CMP="${CMP:-$(cd "$PROOF/../../.." && pwd)}"
LOGS="$PROOF/logs"
mkdir -p "$LOGS"
NC_LOG="$LOGS/negative_control.log"
: >"$NC_LOG"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
cp "$CMP/src/sha512_masked/rtl/sha512_masked_core.sv" "$SCRATCH/sha512_masked_core.sv"

python3 - "$SCRATCH/sha512_masked_core.sv" <<'PY'
import io, sys
p = sys.argv[1]
src = io.open(p, encoding="utf-8").read()

old = """  assign digest =
      ({512{digest_valid_reg}} &
       {H0_reg, H1_reg, H2_reg, H3_reg, H4_reg, H5_reg, H6_reg, H7_reg}) |
      ({512{~digest_valid_reg}} &
       ({a_reg.masked, b_reg.masked, c_reg.masked, d_reg.masked,
         e_reg.masked, f_reg.masked, g_reg.masked, h_reg.masked} ^
        {a_reg.random, b_reg.random, c_reg.random, d_reg.random,
         e_reg.random, f_reg.random, g_reg.random, h_reg.random}));"""

if src.count(old) != 1:
    sys.exit("expected exactly 1 digest select site, found %d" % src.count(old))

new = """  assign digest =
      ({512{digest_valid_reg}} &
       {H0_reg, H1_reg, H2_reg, H3_reg, H4_reg, H5_reg, H6_reg, H7_reg});"""

io.open(p, "w", encoding="utf-8").write(src.replace(old, new, 1))
print("negative control: invalid-cycle digest arm replaced with a constant zero")
PY
[ $? -eq 0 ] || { echo "NEGATIVE_CONTROL: FAIL (patch step failed)" | tee -a "$NC_LOG"; exit 1; }

fails=0

# ---- part 1: the structural audit must fail on the unmasking gates ---------
# Note: the "invalid arm is not a constant" gate is deliberately absent from the
# flip list below. This control removes the invalid arm outright rather than
# replacing it with a literal, so that gate stays green on the fixed copy and is
# meaningful only against the submitted checkout.
NC_AUDIT="$LOGS/negative_control_audit.log"
DUT_CORE_SV="$SCRATCH/sha512_masked_core.sv" \
  "$HERE/run_bug_034_proof.sh" >"$NC_AUDIT" 2>&1
arc=$?
cp "$LOGS/structural_audit.log" "$LOGS/structural_audit_negative_control.log" 2>/dev/null || true

if [ "$arc" -eq 0 ]; then
  echo "NC_CHECK_FAIL audit_still_passes_after_fix" | tee -a "$NC_LOG"
  fails=$((fails + 1))
else
  echo "NC_CHECK_PASS audit_fails_on_fixed_copy" | tee -a "$NC_LOG"
fi

for desc in \
  "the invalid arm reads the masked shares of the working registers" \
  "the invalid arm also reads the random shares of the same registers" \
  "arm 2 of the select is qualified by the inverse of digest_valid_reg"
do
  if grep -F "$desc" "$NC_AUDIT" | grep -q 'gate_fail'; then
    echo "NC_CHECK_PASS flipped: $desc" | tee -a "$NC_LOG"
  else
    echo "NC_CHECK_FAIL did_not_flip: $desc" | tee -a "$NC_LOG"
    fails=$((fails + 1))
  fi
done

for desc in \
  "the valid arm drives the eight H hash registers" \
  "digest_valid is exported, so an observer can tell valid from invalid cycles" \
  "the core carries both working registers and a round counter"
do
  if grep -F "$desc" "$NC_AUDIT" | grep -q 'gate_ok'; then
    echo "NC_CHECK_PASS unaffected: $desc" | tee -a "$NC_LOG"
  else
    echo "NC_CHECK_FAIL unexpectedly_changed: $desc" | tee -a "$NC_LOG"
    fails=$((fails + 1))
  fi
done

# ---- part 2: the identical witness sim must stop witnessing ----------------
NC_SIM="$LOGS/negative_control_sim.log"
DUT_CORE_SV="$SCRATCH/sha512_masked_core.sv" \
  "$HERE/run_bug_034_sim.sh" >"$NC_SIM" 2>&1
src=$?

if [ "$src" -eq 0 ]; then
  echo "NC_CHECK_FAIL witness_sim_still_passes_after_fix" | tee -a "$NC_LOG"
  fails=$((fails + 1))
else
  echo "NC_CHECK_PASS witness_sim_fails_on_fixed_copy" | tee -a "$NC_LOG"
fi

if grep -q 'witness_hits=0' "$NC_SIM"; then
  echo "NC_CHECK_PASS all_three_witness_statements_stopped_holding" | tee -a "$NC_LOG"
else
  echo "NC_CHECK_FAIL witness_statements_still_hold: $(grep -o 'witness_hits=[0-9]*' "$NC_SIM" | tail -1)" | tee -a "$NC_LOG"
  fails=$((fails + 1))
fi

# The hash itself must survive the fix. This is what separates a real
# remediation from simply breaking the engine.
if grep -q 'CHECK_PASS control_digest_matches_published_vector' "$NC_SIM"; then
  echo "NC_CHECK_PASS published_vector_still_correct_after_fix" | tee -a "$NC_LOG"
else
  echo "NC_CHECK_FAIL fix_broke_the_hash" | tee -a "$NC_LOG"
  fails=$((fails + 1))
fi

if grep -q 'CHECK_PASS control_engine_reaches_a_valid_digest' "$NC_SIM"; then
  echo "NC_CHECK_PASS engine_still_completes_after_fix" | tee -a "$NC_LOG"
else
  echo "NC_CHECK_FAIL engine_no_longer_completes" | tee -a "$NC_LOG"
  fails=$((fails + 1))
fi

{
  echo
  echo "=== negative control audit transcript ==="; cat "$NC_AUDIT"
  echo
  echo "=== negative control sim transcript ==="; cat "$NC_SIM"
} >>"$NC_LOG"

echo "nc_checks_failed=$fails" | tee -a "$NC_LOG"
if [ "$fails" -eq 0 ]; then
  echo "NEGATIVE_CONTROL: PASS" | tee -a "$NC_LOG"; exit 0
else
  echo "NEGATIVE_CONTROL: FAIL" | tee -a "$NC_LOG"; exit 1
fi
