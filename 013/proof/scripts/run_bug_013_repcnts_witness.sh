#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ATTACHMENT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TB_DIR="${ATTACHMENT_ROOT}/tb"
LOG_DIR="logs"
BUILD_DIR="build/repcnts_witness"
TMP_WORK="tmp"

if [[ -z "${CALIPTRA_ROOT:-}" ]]; then
  echo "FAIL CALIPTRA_ROOT must point to the Caliptra RTL checkout"
  exit 2
fi

CALIPTRA_ROOT="$(cd "${CALIPTRA_ROOT}" && pwd)"
export TMPDIR="${ATTACHMENT_ROOT}/${TMP_WORK}"
cd "${ATTACHMENT_ROOT}"
mkdir -p "${LOG_DIR}" "${BUILD_DIR}" "${TMP_WORK}"

VERILATOR_BIN="${VERILATOR:-verilator}"
CXX_BIN="${CXX:-g++-10}"
if ! command -v "${CXX_BIN}" >/dev/null 2>&1; then
  CXX_BIN="g++"
fi

SRC_PRIM="${CALIPTRA_ROOT}/src/caliptra_prim/rtl"
SRC_PRIM_GENERIC="${CALIPTRA_ROOT}/src/caliptra_prim_generic/rtl"
SRC_ENTROPY="${CALIPTRA_ROOT}/src/entropy_src/rtl"
SRC_LIBS="${CALIPTRA_ROOT}/src/libs/rtl"

for required in \
  "${SRC_PRIM}/caliptra_prim_pkg.sv" \
  "${SRC_PRIM}/caliptra_prim_count_pkg.sv" \
  "${SRC_PRIM_GENERIC}/caliptra_prim_generic_flop.sv" \
  "${SRC_PRIM}/caliptra_prim_flop.sv" \
  "${SRC_PRIM}/caliptra_prim_count.sv" \
  "${SRC_ENTROPY}/entropy_src_repcnts_ht.sv" \
  "${SRC_LIBS}/caliptra_sva.svh" \
  "${TB_DIR}/entropy_src_bug_013_repcnts_harness.cpp"; do
  if [[ ! -f "${required}" ]]; then
    echo "FAIL missing required source: ${required}"
    exit 2
  fi
done

set +e
{
  echo "INFO verilator=$(${VERILATOR_BIN} --version)"
  echo "INFO cxx=${CXX_BIN}"
  CXX="${CXX_BIN}" "${VERILATOR_BIN}" --cc --exe --build \
    --top-module entropy_src_repcnts_ht \
    --build-jobs 1 \
    -Mdir "${BUILD_DIR}" \
    -I"${SRC_PRIM}" \
    -I"${SRC_PRIM_GENERIC}" \
    -I"${SRC_LIBS}" \
    -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-LATCH \
    "${SRC_PRIM}/caliptra_prim_pkg.sv" \
    "${SRC_PRIM}/caliptra_prim_count_pkg.sv" \
    "${SRC_PRIM_GENERIC}/caliptra_prim_generic_flop.sv" \
    "${SRC_PRIM}/caliptra_prim_flop.sv" \
    "${SRC_PRIM}/caliptra_prim_count.sv" \
    "${SRC_ENTROPY}/entropy_src_repcnts_ht.sv" \
    "${TB_DIR}/entropy_src_bug_013_repcnts_harness.cpp"
} 2>&1 | sed -e "s#${ATTACHMENT_ROOT}#.#g" -e "s#${CALIPTRA_ROOT}#<CALIPTRA_ROOT>#g" >"${LOG_DIR}/compile.log"
compile_rc=${PIPESTATUS[0]}
set -e
if [[ ${compile_rc} -ne 0 ]]; then
  exit "${compile_rc}"
fi

"${BUILD_DIR}/Ventropy_src_repcnts_ht" >"${LOG_DIR}/run.log" 2>&1

grep -q "PASS control_alternating_symbols_no_fail" "${LOG_DIR}/run.log"
grep -q "PASS control_below_threshold_no_fail" "${LOG_DIR}/run.log"
grep -q "OBSERVE boundary_count=3 threshold=3 boundary_fail=0" "${LOG_DIR}/run.log"
grep -q "OBSERVE next_count=4 threshold=3 next_fail=1" "${LOG_DIR}/run.log"
grep -q "PASS BUG013_REPCNTS_OFF_BY_ONE_WITNESS" "${LOG_DIR}/run.log"

echo "PASS BUG013_REPCNTS_OFF_BY_ONE_WITNESS"
