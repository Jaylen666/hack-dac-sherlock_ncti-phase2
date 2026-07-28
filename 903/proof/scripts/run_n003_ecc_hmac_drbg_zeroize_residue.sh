#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROOF_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TB_DIR="${PROOF_ROOT}/tb"
LOG_DIR="logs"
BUILD_DIR="build/ecc_hmac_drbg_zeroize_residue"
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

SRC_ECC="${CALIPTRA_ROOT}/src/ecc/rtl"

for required in \
  "${SRC_ECC}/ecc_hmac_drbg_interface.sv" \
  "${TB_DIR}/ecc_hmac_drbg_child_models.sv" \
  "${TB_DIR}/N003_ecc_hmac_drbg_zeroize_residue_tb.sv"; do
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
    -I"${SRC_ECC}" \
    -Mdir "${BUILD_DIR}" \
    --top-module N003_ecc_hmac_drbg_zeroize_residue_tb \
    "${TB_DIR}/ecc_hmac_drbg_child_models.sv" \
    "${SRC_ECC}/ecc_hmac_drbg_interface.sv" \
    "${TB_DIR}/N003_ecc_hmac_drbg_zeroize_residue_tb.sv"
} 2>&1 | sed -e "s#${PROOF_ROOT}#.#g" -e "s#${CALIPTRA_ROOT}#<CALIPTRA_ROOT>#g" >"${LOG_DIR}/compile.log"
compile_rc=${PIPESTATUS[0]}
set -e
if [[ ${compile_rc} -ne 0 ]]; then
  exit "${compile_rc}"
fi

"${BUILD_DIR}/VN003_ecc_hmac_drbg_zeroize_residue_tb" 2>&1 \
  | sed -e "s#${PROOF_ROOT}#.#g" -e "s#${CALIPTRA_ROOT}#<CALIPTRA_ROOT>#g" >"${LOG_DIR}/run.log"

grep -q "N003_CONTROL_RESET" "${LOG_DIR}/run.log"
grep -q "N003_SETUP_NONZERO" "${LOG_DIR}/run.log"
grep -q "N003_WITNESS_AFTER_ZEROIZE lfsr_seed_reg_nonzero=1 sca_entropy_reg_nonzero=1" "${LOG_DIR}/run.log"
grep -q "lambda_zero=1 scalar_zero=1 masking_zero=1 drbg_zero=1" "${LOG_DIR}/run.log"
grep -q "N003_RESTART_INPUT_RESIDUE" "${LOG_DIR}/run.log"
grep -q "N003_ZEROIZE_RESIDUE_WITNESS_PASS" "${LOG_DIR}/run.log"

echo "N003_ZEROIZE_RESIDUE_WITNESS_PASS"
