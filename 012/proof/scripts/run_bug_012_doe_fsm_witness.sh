#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROOF_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TB_DIR="${PROOF_ROOT}/tb"
LOG_DIR="logs"
BUILD_DIR="build/doe_fsm_witness"
TMP_WORK="tmp"

if [[ -z "${CALIPTRA_ROOT:-}" ]]; then
  echo "FAIL CALIPTRA_ROOT must point to the Caliptra RTL checkout"
  exit 2
fi

CALIPTRA_ROOT="$(cd "${CALIPTRA_ROOT}" && pwd)"
export TMPDIR="${PROOF_ROOT}/${TMP_WORK}"
cd "${PROOF_ROOT}"
mkdir -p "${LOG_DIR}" "${BUILD_DIR}" "${TMP_WORK}"

VERILATOR_BIN="${VERILATOR:-verilator}"
CXX_BIN="${CXX:-g++-10}"
if ! command -v "${CXX_BIN}" >/dev/null 2>&1; then
  CXX_BIN="g++"
fi

SRC_DOE="${CALIPTRA_ROOT}/src/doe/rtl"
SRC_KV="${CALIPTRA_ROOT}/src/keyvault/rtl"
SRC_LIBS="${CALIPTRA_ROOT}/src/libs/rtl"

for required in \
  "${SRC_LIBS}/caliptra_macros.svh" \
  "${SRC_KV}/kv_defines_pkg.sv" \
  "${SRC_DOE}/doe_defines_pkg.sv" \
  "${SRC_KV}/kv_write_rule_check.sv" \
  "${SRC_DOE}/doe_fsm.sv" \
  "${TB_DIR}/BUG-012_doe_fsm_real_dut_tb.sv"; do
  if [[ ! -f "${required}" ]]; then
    echo "FAIL missing required source: ${required}"
    exit 2
  fi
done

set +e
{
  echo "INFO verilator=$(${VERILATOR_BIN} --version)"
  echo "INFO cxx=${CXX_BIN}"
  CXX="${CXX_BIN}" "${VERILATOR_BIN}" --binary --timing \
    --build-jobs 1 \
    -MAKEFLAGS "CXX=${CXX_BIN}" \
    -CFLAGS "-std=c++2a -fcoroutines" \
    -Wno-WIDTH -Wno-UNOPTFLAT -Wno-LITENDIAN -Wno-CMPCONST -Wno-MULTIDRIVEN -Wno-UNPACKED -Wno-LATCH \
    -DCLP_OBF_FE_DWORDS=8 \
    -DCLP_OBF_UDS_DWORDS=16 \
    -I"${SRC_DOE}" \
    -I"${SRC_KV}" \
    -I"${SRC_LIBS}" \
    -Mdir "${BUILD_DIR}" \
    --top-module BUG_012_doe_fsm_real_dut_tb \
    "${SRC_KV}/kv_defines_pkg.sv" \
    "${SRC_DOE}/doe_defines_pkg.sv" \
    "${SRC_KV}/kv_write_rule_check.sv" \
    "${SRC_DOE}/doe_fsm.sv" \
    "${TB_DIR}/BUG-012_doe_fsm_real_dut_tb.sv"
} 2>&1 | sed -e "s#${PROOF_ROOT}#.#g" -e "s#${CALIPTRA_ROOT}#<CALIPTRA_ROOT>#g" >"${LOG_DIR}/compile.log"
compile_rc=${PIPESTATUS[0]}
set -e
if [[ ${compile_rc} -ne 0 ]]; then
  exit "${compile_rc}"
fi

"${BUILD_DIR}/VBUG_012_doe_fsm_real_dut_tb" 2>&1 \
  | sed -e "s#${PROOF_ROOT}#.#g" -e "s#${CALIPTRA_ROOT}#<CALIPTRA_ROOT>#g" >"${LOG_DIR}/run.log"

grep -q "BUG012_CONTROL_FE cmd=DOE_FE observed_write_dest_valid=0x003 expected=0x003" "${LOG_DIR}/run.log"
grep -q "BUG012_WITNESS cmd=DOE_UDS observed_write_dest_valid=0x023 secure_expected=0x003 expanded_bit5=1" "${LOG_DIR}/run.log"
grep -q "BUG012_WITNESS_PASS" "${LOG_DIR}/run.log"

echo "BUG012_WITNESS_PASS"
