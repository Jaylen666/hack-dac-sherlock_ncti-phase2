#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Build and run the kv_bug_025 directed simulation, then the structural audit.
#
# Compiles exactly one DUT (src/keyvault/rtl/kv_read_rule_check.sv) together with
# its package, and drives it from proof/tb/kv_read_rule_check_release_slot_tb.sv.
# Logs land in proof/logs/. Exits nonzero if the simulation controls do not hold
# or the audit cannot be evaluated.

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REPO_ROOT="$(cd "${CASE_DIR}/../.." && pwd)"
LOG_DIR="${CASE_DIR}/proof/logs"
TB_DIR="${CASE_DIR}/proof/tb"
WORK_DIR="${CASE_DIR}/proof/work"

mkdir -p "${LOG_DIR}"
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"

PKG="${REPO_ROOT}/src/keyvault/rtl/kv_defines_pkg.sv"
DUT="${REPO_ROOT}/src/keyvault/rtl/kv_read_rule_check.sv"
TB="${TB_DIR}/kv_read_rule_check_release_slot_tb.sv"

for f in "${PKG}" "${DUT}" "${TB}"; do
  if [[ ! -f "${f}" ]]; then
    echo "gate_fail: missing source ${f#${REPO_ROOT}/}" | tee "${LOG_DIR}/run.log"
    echo "result=FAIL" | tee -a "${LOG_DIR}/run.log"
    exit 1
  fi
done

echo "=== kv_bug_025 proof run ===" > "${LOG_DIR}/run.log"
echo "dut=src/keyvault/rtl/kv_read_rule_check.sv" >> "${LOG_DIR}/run.log"
echo "tb=proof/tb/kv_read_rule_check_release_slot_tb.sv" >> "${LOG_DIR}/run.log"
echo "dut_instances_compiled=1" >> "${LOG_DIR}/run.log"

# ---------------------------------------------------------------------------
# Simulation. The testbench is procedural with explicit delays, so it is built
# with VCS. Exactly three sources are compiled: the KeyVault package, the single
# DUT, and the testbench.
# ---------------------------------------------------------------------------
VCS_BIN="${VCS_BIN:-vcs}"
if ! command -v "${VCS_BIN}" >/dev/null 2>&1; then
  echo "gate_fail: simulator '${VCS_BIN}' not on PATH; set VCS_BIN" >> "${LOG_DIR}/run.log"
  echo "result=FAIL" >> "${LOG_DIR}/run.log"
  exit 1
fi

cd "${WORK_DIR}"

echo "--- compile ---" > "${LOG_DIR}/compile.log"
if ! "${VCS_BIN}" -full64 -sverilog -q -timescale=1ns/1ps \
       -o kv_bug_025_sim \
       "${PKG}" "${DUT}" "${TB}" >> "${LOG_DIR}/compile.log" 2>&1; then
  echo "gate_fail: compile failed, see proof/logs/compile.log" >> "${LOG_DIR}/run.log"
  echo "result=FAIL" >> "${LOG_DIR}/compile.log"
  echo "result=FAIL" >> "${LOG_DIR}/run.log"
  exit 1
fi
echo "result=PASS" >> "${LOG_DIR}/compile.log"

echo "--- simulate ---" > "${LOG_DIR}/sim.log"
sim_rc=0
./kv_bug_025_sim -no_save >> "${LOG_DIR}/sim.log" 2>&1 || sim_rc=$?

# Rewrite absolute build paths in the captured logs to tree-relative form. The
# simulator reports source locations with the full filesystem path it was invoked
# with; the logs are more portable and more readable relative to the tree root.
sanitize_log() {
  local f="$1"
  [[ -f "${f}" ]] || return 0
  sed -i -e "s|${REPO_ROOT}/||g" -e "s|${REPO_ROOT}|.|g" "${f}"
}
sanitize_log "${LOG_DIR}/compile.log"
sanitize_log "${LOG_DIR}/sim.log"

# Extract the measured decisions into a compact witness log.
{
  echo "=== kv_bug_025 measured decisions ==="
  grep -E '^(CONTROL_A|CONTROL_B|PROBE|ok:|FAIL:|checks_run|probe_multihot|release_slot)' \
       "${LOG_DIR}/sim.log" || true
} > "${LOG_DIR}/witness.log"

if (( sim_rc != 0 )); then
  echo "gate_fail: simulation exited ${sim_rc}, see proof/logs/sim.log" >> "${LOG_DIR}/run.log"
  echo "result=FAIL" >> "${LOG_DIR}/run.log"
  echo "result=FAIL" >> "${LOG_DIR}/witness.log"
  exit 1
fi

if ! grep -q '^result=PASS' "${LOG_DIR}/sim.log"; then
  echo "gate_fail: simulation did not report result=PASS" >> "${LOG_DIR}/run.log"
  echo "result=FAIL" >> "${LOG_DIR}/run.log"
  exit 1
fi
echo "result=PASS" >> "${LOG_DIR}/witness.log"

# ---------------------------------------------------------------------------
# Structural audit. Appended to run.log; this gate decides reachability.
# ---------------------------------------------------------------------------
audit_rc=0
"${SCRIPT_DIR}/audit_kv_read_dest_producers.sh" >> "${LOG_DIR}/run.log" 2>&1 || audit_rc=$?

cd "${CASE_DIR}"
# Build trees are reproducible from the sources above; keep the case directory to
# logs, scripts and testbench only.
rm -rf "${WORK_DIR}" "${CASE_DIR}/csrc" "${CASE_DIR}/simv.daidir" \
       "${CASE_DIR}/obj_dir" "${CASE_DIR}/work"

if (( audit_rc != 0 )); then
  echo "gate_fail: structural audit exited ${audit_rc}" >> "${LOG_DIR}/run.log"
  echo "result=FAIL" >> "${LOG_DIR}/run.log"
  exit 1
fi

echo "=== proof run complete ===" >> "${LOG_DIR}/run.log"
echo "result=PASS" >> "${LOG_DIR}/run.log"
exit 0
