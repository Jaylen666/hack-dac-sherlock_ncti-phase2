#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Run the JasperGold formal proof for bug 006 (aes_prng_masking force-mask gate).
#
# Point CALIPTRA_ROOT at the Caliptra checkout. The package root is derived from
# this script's own location, so no other environment variable is required.
#
# Logs land in logs/. Exits nonzero if JasperGold is unavailable or the proof
# does not reproduce the expected counterexamples.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

: "${CALIPTRA_ROOT:?Set CALIPTRA_ROOT to the Caliptra RTL checkout}"

if [[ ! -f "${CALIPTRA_ROOT}/src/aes/rtl/aes_prng_masking.sv" ]]; then
  echo "gate_fail: CALIPTRA_ROOT does not contain src/aes/rtl/aes_prng_masking.sv" >&2
  exit 1
fi

LOG_DIR="${PKG_ROOT}/logs"
mkdir -p "${LOG_DIR}"

JG="${JASPERGOLD_BIN:-jg}"
if ! command -v "${JG}" >/dev/null 2>&1; then
  echo "gate_fail: JasperGold binary '${JG}' not on PATH; set JASPERGOLD_BIN" >&2
  exit 1
fi

# Consumed by the tcl to locate the checker sources and write the summary.
# Derived from this script's location rather than demanded from the caller.
export CSBC_FORMAL_ROOT="${PKG_ROOT}"

rc=0
"${JG}" -batch -tcl "${SCRIPT_DIR}/jasper_bug006.tcl" \
  > "${LOG_DIR}/bug006_jasper.log" 2>&1 || rc=$?

# Rewrite the invoking absolute paths out of the captured transcript so the log
# stays portable and readable relative to the checkout root.
for f in "${LOG_DIR}/bug006_jasper.log" "${LOG_DIR}/bug006_property_summary.txt"; do
  [[ -f "${f}" ]] || continue
  sed -i -E -e "s#${CALIPTRA_ROOT}/#./#g" -e "s#${CALIPTRA_ROOT}#.#g" \
            -e "s#${PKG_ROOT}/#./#g" -e "s#${PKG_ROOT}#.#g" "${f}"
done

if (( rc != 0 )); then
  echo "gate_fail: JasperGold exited ${rc}, see logs/bug006_jasper.log" >&2
  exit "${rc}"
fi

# The expected outcome on the submitted RTL is a counterexample for both
# assertions. A clean proof would mean the reported behavior is not present.
cex_count=$(grep -c "A counterexample (cex) with .* was found" \
  "${LOG_DIR}/bug006_jasper.log" || true)
if (( cex_count < 2 )); then
  echo "gate_fail: expected 2 assertion counterexamples, found ${cex_count}" >&2
  echo "result=FAIL"
  exit 1
fi

echo "cex_assertions=${cex_count}"
echo "result=PASS"
