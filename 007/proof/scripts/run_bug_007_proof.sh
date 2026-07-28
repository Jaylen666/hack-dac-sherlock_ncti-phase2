#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Deterministic witness for contest bug 007 (axi_sub_arb attribute coherence).
#
# Usage:
#   CALIPTRA_ROOT=/path/to/caliptra ./run_bug_007_proof.sh
#
# Optional overrides: VERILATOR, CXX
#
# Compiles exactly one axi_sub_arb DUT out of the given checkout, runs a
# directed testbench with three control cases and one violating case, and
# additionally applies scripted structural gates over the same checkout.
# Exits nonzero if any control fails or the witness is not observed.

set -euo pipefail

: "${CALIPTRA_ROOT:?set CALIPTRA_ROOT to the Caliptra checkout under test}"
VERILATOR="${VERILATOR:-verilator}"
CXX_BIN="${CXX:-g++-10}"

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

ARB_RTL="${CALIPTRA_ROOT}/src/axi/rtl/axi_sub_arb.sv"
SUB_RTL="${CALIPTRA_ROOT}/src/axi/rtl/axi_sub.sv"
IFC_RTL="${CALIPTRA_ROOT}/src/soc_ifc/rtl/soc_ifc_top.sv"

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

# The USER select term differs from every other read-side select term.
gate "grep -qE 'assign[[:space:]]+user_from_read[[:space:]]*=[[:space:]]*~\\(~r_win[[:space:]]*\\|[[:space:]]*w_dv\\)' '${ARB_RTL}'" \
     "axi_sub_arb derives the USER select as a function of both r_win and w_dv"
gate "grep -qE 'user[[:space:]]*=[[:space:]]*user_from_read[[:space:]]*\\?' '${ARB_RTL}'" \
     "component-facing user is driven by that separate select term"
gate "grep -qE 'addr[[:space:]]*=[[:space:]]*r_win[[:space:]]*\\?' '${ARB_RTL}'" \
     "component-facing addr is selected by r_win alone"
gate "grep -qE 'id[[:space:]]*=[[:space:]]*r_win[[:space:]]*\\?' '${ARB_RTL}'" \
     "component-facing id is selected by r_win alone"
gate "grep -qE 'write[[:space:]]*=[[:space:]]*r_win[[:space:]]*\\?' '${ARB_RTL}'" \
     "component-facing write is selected by r_win alone"
# r_win=1 together with w_dv=1 is reachable: the r_pri branch grants the read
# channel even when a write is valid in the same cycle.
gate "grep -qE 'if[[:space:]]*\\(r_pri\\)[[:space:]]*r_win[[:space:]]*=[[:space:]]*r_dv[[:space:]]*\\|\\|[[:space:]]*!w_dv' '${ARB_RTL}'" \
     "read grant is reachable while a write request is valid in the same cycle"
# The affected USER field is live security state, not dead wiring.
gate "grep -q 'user  (soc_req.user' '${IFC_RTL}' || grep -qE '\\.user[[:space:]]*\\([[:space:]]*soc_req\\.user' '${IFC_RTL}'" \
     "arbiter USER output reaches soc_req.user"
gate "grep -qE 'soc_req\\.user[[:space:]]*==' '${IFC_RTL}'" \
     "soc_req.user is compared against AXI_USER allowlists"
gate "grep -qE '\\.user[[:space:]]*\\([[:space:]]*user[[:space:]]*\\)' '${SUB_RTL}'" \
     "axi_sub forwards the arbiter USER output unmodified"

section "axi_sub_arb select terms"
grep -nE 'user_from_read|addr    =|write   =|user    =|id      =|r_win =' "${ARB_RTL}" >> "${WITNESS_LOG}" || true
section "AXI_USER access-control consumers"
grep -nE 'soc_req\.user[[:space:]]*==|soc_req_data\.user[[:space:]]*==' "${IFC_RTL}" \
     "${CALIPTRA_ROOT}/src/soc_ifc/rtl/soc_ifc_arb.sv" >> "${WITNESS_LOG}" || true

echo "=== compile ===" | tee -a "${RUN_LOG}"
"${VERILATOR}" --binary --timing -j 0 \
  -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-LATCH -Wno-UNOPTFLAT \
  -Wno-DECLFILENAME -Wno-VARHIDDEN -Wno-CASEINCOMPLETE -Wno-fatal \
  --Mdir "${BUILD_DIR}" \
  -CFLAGS "-std=c++20 -fcoroutines" \
  -MAKEFLAGS "CXX=${CXX_BIN}" \
  +incdir+"${CALIPTRA_ROOT}/src/axi/rtl" \
  +incdir+"${CALIPTRA_ROOT}/src/libs/rtl" \
  +incdir+"${CALIPTRA_ROOT}/src/caliptra_prim/rtl" \
  +incdir+"${CALIPTRA_ROOT}/src/integration/rtl" \
  "${CALIPTRA_ROOT}/src/axi/rtl/axi_pkg.sv" \
  "${ARB_RTL}" \
  "${TB_DIR}/axi_sub_arb_bug_007_tb.sv" \
  --top-module axi_sub_arb_bug_007_tb \
  > "${COMPILE_LOG}" 2>&1 || { echo "compile_fail: see logs/compile.log" | tee -a "${RUN_LOG}"; exit 1; }
echo "compile_ok" | tee -a "${RUN_LOG}"

echo "=== simulate ===" | tee -a "${RUN_LOG}"
"${BUILD_DIR}/Vaxi_sub_arb_bug_007_tb" > "${SIM_LOG}" 2>&1 || true
cat "${SIM_LOG}" | tee -a "${RUN_LOG}"

if ! grep -q '^result=PASS' "${SIM_LOG}"; then
  echo "sim_fail: testbench did not report result=PASS" | tee -a "${RUN_LOG}"
  pass=0
fi
if ! grep -q 'BUG_007_WITNESS_OBSERVED' "${SIM_LOG}"; then
  echo "sim_fail: witness marker absent" | tee -a "${RUN_LOG}"
  pass=0
fi
grep -E '^WITNESS:|^case=' "${SIM_LOG}" >> "${WITNESS_LOG}" || true

rm -rf "${BUILD_DIR}"

# Replace the local checkout and case paths with neutral placeholders so the
# packaged logs stay portable and carry no workstation-specific path.
for f in "${RUN_LOG}" "${COMPILE_LOG}" "${SIM_LOG}" "${WITNESS_LOG}"; do
  [ -f "$f" ] || continue
  sed -i -e "s|${CASE_DIR}|<case>|g" -e "s|${CALIPTRA_ROOT}|\${CALIPTRA_ROOT}|g" "$f"
done

if [ "${pass}" -eq 1 ]; then
  echo "result=PASS" | tee -a "${RUN_LOG}"
  echo "BUG_007_PROOF_COMPLETE" | tee -a "${RUN_LOG}"
  exit 0
fi
echo "result=FAIL" | tee -a "${RUN_LOG}"
exit 1
