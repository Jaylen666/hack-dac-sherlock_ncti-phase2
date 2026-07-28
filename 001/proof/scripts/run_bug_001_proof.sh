#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Deterministic witness for contest bug 001
# (AES KeyVault export buffer is not cleared on entry to the insecure state).
#
# Usage:
#   CALIPTRA_ROOT=/path/to/caliptra ./run_bug_001_proof.sh
#
# Optional overrides: VCS
#
# Compiles exactly one real `aes` DUT out of the given checkout, runs a directed
# testbench with two control cases and one violating case, and applies scripted
# structural gates over the same checkout. Exits nonzero if any control fails or
# the witness is not observed.

set -euo pipefail

: "${CALIPTRA_ROOT:?set CALIPTRA_ROOT to the Caliptra checkout under test}"
VCS_BIN="${VCS:-vcs}"
command -v "${VCS_BIN}" >/dev/null 2>&1 || {
  echo "VCS not on PATH; set VCS=/path/to/vcs" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TB_DIR="${CASE_DIR}/tb"
LOG_DIR="${CASE_DIR}/logs"
BUILD_DIR="${CASE_DIR}/build"

RUN_LOG="${LOG_DIR}/run.log"
COMPILE_LOG="${LOG_DIR}/compile.log"
SIM_LOG="${LOG_DIR}/sim.log"
WITNESS_LOG="${LOG_DIR}/witness.log"

mkdir -p "${LOG_DIR}"
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
: > "${RUN_LOG}"; : > "${WITNESS_LOG}"

AES_RTL="${CALIPTRA_ROOT}/src/aes/rtl/aes.sv"
WRAP_RTL="${CALIPTRA_ROOT}/src/aes/rtl/aes_clp_wrapper.sv"
SPEC_MD="${CALIPTRA_ROOT}/docs/CaliptraHardwareSpecification.md"

pass=1
gate() {
  if eval "$1" >/dev/null 2>&1; then
    echo "gate_ok: $2" | tee -a "${RUN_LOG}"
  else
    echo "gate_fail: $2" | tee -a "${RUN_LOG}"
    pass=0
  fi
}
section() { printf '\n===== %s =====\n' "$1" >> "${WITNESS_LOG}"; }

echo "=== structural gates ===" | tee -a "${RUN_LOG}"

# The clearing request exists and is driven by entry into the insecure state.
gate "grep -qE 'caliptra2aes\\.clear_secrets[[:space:]]*=[[:space:]]*debugUnlock_or_scan_mode_switch' '${WRAP_RTL}'" \
     "wrapper drives clear_secrets from the debug/scan state switch"
gate "grep -qE 'logic[[:space:]]+clear_secrets' '${CALIPTRA_ROOT}/src/aes/rtl/aes_pkg.sv'" \
     "clear_secrets is a live field of the caliptra2aes interface"
# The AES core never consumes it.
gate "[ \"\$(grep -c 'clear_secrets' '${AES_RTL}')\" -eq 0 ]" \
     "aes core contains no use of clear_secrets"
# The two buffers that hold the exported secret, and the clear sources they do honor.
gate "grep -qE 'aes2caliptra_kv_data_out_valid[[:space:]]*<=' '${AES_RTL}'" \
     "KeyVault export valid bit is a register inside the aes core"
gate "grep -qE 'reg2hw_caliptra\\.trigger\\.data_out_clear\\.q' '${AES_RTL}'" \
     "export buffers honor the firmware data_out_clear trigger"
gate "grep -qE 'caliptra2aes\\.kv_write_done' '${AES_RTL}'" \
     "export buffers honor consumption by KeyVault"
# The buffer is exported to the KeyVault write client, so retention is observable.
gate "grep -qE 'aes2caliptra\\.kv_data_out[[:space:]]*=[[:space:]]*aes2caliptra_kv_data_out' '${AES_RTL}'" \
     "buffer contents are exported on the KeyVault interface"
gate "grep -qE 'aes2caliptra\\.kv_data_out_valid[[:space:]]*=' '${AES_RTL}'" \
     "buffer valid bit is exported on the KeyVault interface"
# The specification requires secret clearing on entry to debug.
gate "grep -qE 'Transitions to debug mode trigger a hardware clear of all device secrets' '${SPEC_MD}'" \
     "in-tree specification requires a hardware clear of device secrets on debug entry"

section "clear_secrets production and its absence in the core"
grep -n "clear_secrets" "${WRAP_RTL}" >> "${WITNESS_LOG}" || true
echo "occurrences of clear_secrets in aes.sv: $(grep -c 'clear_secrets' "${AES_RTL}")" >> "${WITNESS_LOG}"
section "KeyVault export buffer clear conditions in aes.sv"
sed -n '240,282p' "${AES_RTL}" >> "${WITNESS_LOG}"
section "specification requirement for secret clearing on debug entry"
grep -n "Transitions to debug mode trigger a hardware clear" "${SPEC_MD}" >> "${WITNESS_LOG}" || true

echo "=== compile ===" | tee -a "${RUN_LOG}"
export CALIPTRA_ROOT
export CALIPTRA_PRIM_ROOT="${CALIPTRA_ROOT}/src/caliptra_prim_generic"
export CALIPTRA_PRIM_MODULE_PREFIX="caliptra_prim_generic"

pushd "${BUILD_DIR}" >/dev/null
"${VCS_BIN}" -full64 -sverilog -assert svaext -timescale=1ns/1ps \
  +incdir+"${CALIPTRA_ROOT}/src/integration/rtl/caliptra_reg" \
  -f "${CALIPTRA_ROOT}/src/aes/config/aes.vf" \
  "${TB_DIR}/aes_bug_001_tb.sv" \
  -top aes_bug_001_tb \
  -o simv_bug_001 \
  > "${COMPILE_LOG}" 2>&1 || { popd >/dev/null; \
    echo "compile_fail: see logs/compile.log" | tee -a "${RUN_LOG}"; exit 1; }
echo "compile_ok" | tee -a "${RUN_LOG}"

echo "=== simulate ===" | tee -a "${RUN_LOG}"
./simv_bug_001 -licqueue > "${SIM_LOG}" 2>&1 || true
popd >/dev/null

grep -vE '^\s*$' "${SIM_LOG}" | tee -a "${RUN_LOG}" >/dev/null
grep -E '^(WITNESS|PASS|FAIL|control_|violating_|checks=|result=)' "${SIM_LOG}" | tee -a "${RUN_LOG}"

if ! grep -q '^result=PASS' "${SIM_LOG}"; then
  echo "sim_fail: testbench did not report result=PASS" | tee -a "${RUN_LOG}"
  pass=0
fi
if ! grep -q 'BUG_001_WITNESS_OBSERVED' "${SIM_LOG}"; then
  echo "sim_fail: witness marker absent" | tee -a "${RUN_LOG}"
  pass=0
fi
grep -E '^WITNESS:|loaded:|after stimulus:' "${SIM_LOG}" >> "${WITNESS_LOG}" || true

rm -rf "${BUILD_DIR}"

# Replace the local checkout and case paths with neutral placeholders so the
# packaged logs stay portable and carry no workstation-specific path.
for f in "${RUN_LOG}" "${COMPILE_LOG}" "${SIM_LOG}" "${WITNESS_LOG}"; do
  [ -f "$f" ] || continue
  sed -i -e "s|${CASE_DIR}|<case>|g" -e "s|${CALIPTRA_ROOT}|\${CALIPTRA_ROOT}|g" "$f"
done

if [ "${pass}" -eq 1 ]; then
  echo "result=PASS" | tee -a "${RUN_LOG}"
  echo "BUG_001_PROOF_COMPLETE" | tee -a "${RUN_LOG}"
  exit 0
fi
echo "result=FAIL" | tee -a "${RUN_LOG}"
exit 1
