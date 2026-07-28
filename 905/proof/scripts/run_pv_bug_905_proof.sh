#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Build and run the pv_bug_905 directed simulation, then the structural audit.
#
# Compiles exactly one DUT (src/pcrvault/rtl/pv.sv, with its register block and
# AHB shim) and drives it from proof/tb/pv_lock_reset_domain_tb.sv. Logs land in
# proof/logs/. Exits nonzero if the simulation does not reach its expected
# verdict or the audit cannot be evaluated.
#
# Note on the verdict marker: this case proves a defect, so the testbench's
# expectations against the in-tree stickiness requirement are EXPECTED to fail.
# The script therefore keys on the testbench's own PROOF_RESULT line rather than
# on a check-failure count.

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

REPO_ROOT="${CALIPTRA_ROOT:-}"
if [[ -z "${REPO_ROOT}" ]]; then
  probe="${CASE_DIR}"
  while [[ "${probe}" != "/" ]]; do
    if [[ -d "${probe}/src/pcrvault/rtl" ]]; then
      REPO_ROOT="${probe}"
      break
    fi
    probe="$(dirname "${probe}")"
  done
fi

LOG_DIR="${CASE_DIR}/proof/logs"
TB_DIR="${CASE_DIR}/proof/tb"
WORK_DIR="${CASE_DIR}/proof/work"

mkdir -p "${LOG_DIR}"
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"

if [[ -z "${REPO_ROOT}" || ! -d "${REPO_ROOT}/src/pcrvault/rtl" ]]; then
  echo "gate_fail: cannot locate the Caliptra tree; set CALIPTRA_ROOT" | tee "${LOG_DIR}/run.log"
  echo "result=FAIL" | tee -a "${LOG_DIR}/run.log"
  exit 1
fi

# Sources. Exactly one pv DUT; the register block and the AHB shim are the DUT's
# own submodules, not a second design under test.
SRCS=(
  "${REPO_ROOT}/src/libs/rtl/caliptra_sva.svh"
  "${REPO_ROOT}/src/libs/rtl/caliptra_macros.svh"
  "${REPO_ROOT}/src/libs/rtl/ahb_defines_pkg.sv"
  "${REPO_ROOT}/src/pcrvault/rtl/pv_defines_pkg.sv"
  "${REPO_ROOT}/src/pcrvault/rtl/pv_reg_pkg.sv"
  "${REPO_ROOT}/src/pcrvault/rtl/pv_reg.sv"
  "${REPO_ROOT}/src/pcrvault/rtl/pv_gen_hash.sv"
  "${REPO_ROOT}/src/libs/rtl/ahb_slv_sif.sv"
  "${REPO_ROOT}/src/pcrvault/rtl/pv.sv"
  "${TB_DIR}/pv_lock_reset_domain_tb.sv"
)
INCDIRS=(
  "+incdir+${REPO_ROOT}/src/pcrvault/rtl"
  "+incdir+${REPO_ROOT}/src/libs/rtl"
  "+incdir+${REPO_ROOT}/src/integration/rtl"
)

for f in "${SRCS[@]}"; do
  if [[ ! -f "${f}" ]]; then
    echo "gate_fail: missing source ${f#${REPO_ROOT}/}" | tee "${LOG_DIR}/run.log"
    echo "result=FAIL" | tee -a "${LOG_DIR}/run.log"
    exit 1
  fi
done

echo "=== pv_bug_905 proof run ===" > "${LOG_DIR}/run.log"
echo "dut=src/pcrvault/rtl/pv.sv" >> "${LOG_DIR}/run.log"
echo "tb=proof/tb/pv_lock_reset_domain_tb.sv" >> "${LOG_DIR}/run.log"
echo "dut_instances_compiled=1" >> "${LOG_DIR}/run.log"

VCS_BIN="${VCS_BIN:-vcs}"
if ! command -v "${VCS_BIN}" >/dev/null 2>&1; then
  echo "gate_fail: simulator '${VCS_BIN}' not on PATH; set VCS_BIN" >> "${LOG_DIR}/run.log"
  echo "result=FAIL" >> "${LOG_DIR}/run.log"
  exit 1
fi

cd "${WORK_DIR}"

echo "--- compile ---" > "${LOG_DIR}/compile.log"
if ! "${VCS_BIN}" -full64 -sverilog -q -timescale=1ns/1ps \
       "${INCDIRS[@]}" -o pv_bug_905_sim \
       "${SRCS[@]}" >> "${LOG_DIR}/compile.log" 2>&1; then
  echo "gate_fail: compile failed, see proof/logs/compile.log" >> "${LOG_DIR}/run.log"
  echo "result=FAIL" >> "${LOG_DIR}/compile.log"
  echo "result=FAIL" >> "${LOG_DIR}/run.log"
  exit 1
fi
echo "result=PASS" >> "${LOG_DIR}/compile.log"

echo "--- simulate ---" > "${LOG_DIR}/sim.log"
sim_rc=0
./pv_bug_905_sim -no_save >> "${LOG_DIR}/sim.log" 2>&1 || sim_rc=$?

# Rewrite absolute build paths in the captured logs to tree-relative form. The
# simulator reports source locations with the full filesystem path it was invoked
# with; the logs are more portable and more readable relative to the tree root.
# CASE_DIR is substituted first: it lives under the tree, so rewriting REPO_ROOT
# first would leave a half-rewritten case path behind.
sanitize_log() {
  local f="$1"
  [[ -f "${f}" ]] || return 0
  sed -i -e "s|${CASE_DIR}/|./|g" -e "s|${CASE_DIR}|.|g" \
         -e "s|${REPO_ROOT}/||g" -e "s|${REPO_ROOT}|.|g" "${f}"
}
sanitize_log "${LOG_DIR}/compile.log"
sanitize_log "${LOG_DIR}/sim.log"

{
  echo "=== pv_bug_905 measured decisions ==="
  grep -E '^(CONTROL_[A-C]|WITNESS_[DE]|ok:|FAIL:|TBFAIL|checks_run|witness_|cover_|  OBSERVED|PROOF_RESULT)' \
       "${LOG_DIR}/sim.log" || true
} > "${LOG_DIR}/witness.log"

if (( sim_rc != 0 )); then
  echo "gate_fail: simulation exited ${sim_rc}, see proof/logs/sim.log" >> "${LOG_DIR}/run.log"
  echo "result=FAIL" >> "${LOG_DIR}/run.log"
  echo "result=FAIL" >> "${LOG_DIR}/witness.log"
  exit 1
fi

# The testbench emits PROOF_RESULT: PASS only when the exact expected pattern is
# met: eight expectations run, exactly the two that encode the in-tree stickiness
# requirement fail, both witnesses observed, and both coverage counters hit. A
# design that failed in some other way, or that met the requirement, does not
# reach that line.
if ! grep -q '^PROOF_RESULT: PASS' "${LOG_DIR}/sim.log"; then
  echo "gate_fail: simulation did not report PROOF_RESULT: PASS" >> "${LOG_DIR}/run.log"
  echo "result=FAIL" >> "${LOG_DIR}/run.log"
  exit 1
fi
echo "result=PASS" >> "${LOG_DIR}/witness.log"

# ---------------------------------------------------------------------------
# Structural audit. The simulation shows the lock clearing; this gate decides
# whether that reset domain is something firmware can enter, and whether an
# in-tree statement forbids the lock clearing there.
# ---------------------------------------------------------------------------
audit_rc=0
CALIPTRA_ROOT="${REPO_ROOT}" "${SCRIPT_DIR}/audit_pv_lock_reset_domain.sh" \
  >> "${LOG_DIR}/run.log" 2>&1 || audit_rc=$?

cd "${CASE_DIR}"
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
