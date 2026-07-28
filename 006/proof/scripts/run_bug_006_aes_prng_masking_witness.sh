#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROOF_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TB_DIR="${PROOF_ROOT}/tb"
LOG_DIR="logs"
BUILD_DIR="build/aes_prng_masking_witness"
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

SRC_AES="${CALIPTRA_ROOT}/src/aes/rtl"
SRC_CSRNG="${CALIPTRA_ROOT}/src/csrng/rtl"
SRC_EDN="${CALIPTRA_ROOT}/src/edn/rtl"
SRC_ENTROPY="${CALIPTRA_ROOT}/src/entropy_src/rtl"
SRC_PRIM="${CALIPTRA_ROOT}/src/caliptra_prim/rtl"
SRC_LIBS="${CALIPTRA_ROOT}/src/libs/rtl"

for required in \
  "${SRC_ENTROPY}/entropy_src_pkg.sv" \
  "${SRC_CSRNG}/csrng_pkg.sv" \
  "${SRC_EDN}/edn_pkg.sv" \
  "${SRC_PRIM}/caliptra_prim_util_pkg.sv" \
  "${SRC_PRIM}/caliptra_prim_trivium_pkg.sv" \
  "${SRC_AES}/aes_reg_pkg.sv" \
  "${SRC_AES}/aes_pkg.sv" \
  "${SRC_PRIM}/caliptra_prim_trivium.sv" \
  "${SRC_AES}/aes_prng_masking.sv" \
  "${SRC_LIBS}/caliptra_sva.svh" \
  "${TB_DIR}/BUG-006_aes_prng_masking_real_dut_tb.sv"; do
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
    -I"${SRC_AES}" \
    -I"${SRC_CSRNG}" \
    -I"${SRC_EDN}" \
    -I"${SRC_ENTROPY}" \
    -I"${SRC_PRIM}" \
    -I"${SRC_LIBS}" \
    -Mdir "${BUILD_DIR}" \
    --top-module BUG_006_aes_prng_masking_real_dut_tb \
    "${SRC_ENTROPY}/entropy_src_pkg.sv" \
    "${SRC_CSRNG}/csrng_pkg.sv" \
    "${SRC_EDN}/edn_pkg.sv" \
    "${SRC_PRIM}/caliptra_prim_util_pkg.sv" \
    "${SRC_PRIM}/caliptra_prim_trivium_pkg.sv" \
    "${SRC_AES}/aes_reg_pkg.sv" \
    "${SRC_AES}/aes_pkg.sv" \
    "${SRC_PRIM}/caliptra_prim_trivium.sv" \
    "${SRC_AES}/aes_prng_masking.sv" \
    "${TB_DIR}/BUG-006_aes_prng_masking_real_dut_tb.sv"
} 2>&1 | sed -e "s#${PROOF_ROOT}#.#g" -e "s#${CALIPTRA_ROOT}#<CALIPTRA_ROOT>#g" >"${LOG_DIR}/compile.log"
compile_rc=${PIPESTATUS[0]}
set -e
if [[ ${compile_rc} -ne 0 ]]; then
  exit "${compile_rc}"
fi

"${BUILD_DIR}/VBUG_006_aes_prng_masking_real_dut_tb" 2>&1 \
  | sed -e "s#${PROOF_ROOT}#.#g" -e "s#${CALIPTRA_ROOT}#<CALIPTRA_ROOT>#g" >"${LOG_DIR}/run.log"

grep -q "BUG006_CONTROL force_masks_i=0" "${LOG_DIR}/run.log"
grep -q "BUG006_WITNESS_GATE force_masks_i=1" "${LOG_DIR}/run.log"
grep -q "observed_primitive_allow=1 secure_expected=0" "${LOG_DIR}/run.log"
grep -q "BUG006_WITNESS_PASS" "${LOG_DIR}/run.log"

echo "BUG006_WITNESS_PASS"
