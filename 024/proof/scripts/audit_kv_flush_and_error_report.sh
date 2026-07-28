#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Structural audit for kv_bug_024. Two separable propositions are decided here,
# and they are kept apart on purpose because they point in opposite directions:
#
#   proposition A  does a Caliptra fatal error fail to reach the KeyVault flush?
#   proposition B  is a KeyVault error condition required to be reported through
#                  CPTRA_HW_ERROR_FATAL, and is it not?
#
# Proposition A cannot be decided by reading src/keyvault/rtl/kv.sv:122-123. That
# expression names its input debugUnlock_or_scan_mode_switch, but a port name is
# not a contract: what matters is the signal actually connected to that port at
# the kv instantiation, and every producer term of that signal. Gate 2 traces it.
#
# Gates:
#   1  the flush expression inside the module, and what it consumes
#   2  the signal connected to the kv flush port, and every producer term of it
#   3  the fields and write-enables of the SoC-facing fatal error register
#   4  KeyVault error observability paths available to software
#   5  in-tree specification statements on fatal errors and KeyVault errors
#
# Read-only. Prints one key=value line per measurement plus an overall result.

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REPO_ROOT="${CALIPTRA_ROOT:-}"

if [[ -z "${REPO_ROOT}" ]]; then
  probe="${CASE_DIR}"
  while [[ "${probe}" != "/" ]]; do
    if [[ -d "${probe}/src/keyvault/rtl" ]]; then
      REPO_ROOT="${probe}"
      break
    fi
    probe="$(dirname "${probe}")"
  done
fi

if [[ -z "${REPO_ROOT}" || ! -d "${REPO_ROOT}/src/keyvault/rtl" ]]; then
  echo "gate_fail: cannot locate the Caliptra tree; set CALIPTRA_ROOT"
  echo "audit_result=FAIL"
  exit 1
fi

cd "${REPO_ROOT}"

KV="src/keyvault/rtl/kv.sv"
TOP="src/integration/rtl/caliptra_top.sv"
SOC="src/soc_ifc/rtl/soc_ifc_top.sv"
EXT_RDL="src/soc_ifc/rtl/soc_ifc_external_reg.rdl"
KV_DEF="src/keyvault/rtl/kv_def.rdl"
KV_DOC="src/keyvault/config/keyvault.md"
INT_SPEC="docs/CaliptraIntegrationSpecification.md"
HW_SPEC="docs/CaliptraHardwareSpecification.md"

gate_failed=0
gate_fail() { echo "gate_fail: $*"; gate_failed=1; }

for f in "${KV}" "${TOP}" "${SOC}" "${EXT_RDL}" "${KV_DEF}" "${KV_DOC}" \
         "${INT_SPEC}" "${HW_SPEC}"; do
  [[ -f "${f}" ]] || gate_fail "missing input ${f}"
done
if (( gate_failed )); then
  echo "audit_result=FAIL"
  exit 1
fi

echo "=== kv_bug_024 structural audit: KV flush coverage and KV error reporting ==="
echo "tree_relative_paths_only=yes"

# ---------------------------------------------------------------------------
# Gate 1: the flush expression inside the module.
# ---------------------------------------------------------------------------
echo "--- gate 1: the flush expression inside the kv module ---"
flush_expr="$(grep -n -A2 "always_comb flush_keyvault" "${KV}")"
if [[ -z "${flush_expr}" ]]; then
  gate_fail "could not find the flush_keyvault assignment in ${KV}"
else
  sed -e 's/^/  /' <<<"${flush_expr}"
fi
# The module-internal terms. Two are expected: the switch input, and the debug
# scan mode signal qualified by the software-poked CLEAR_SECRETS field.
flush_switch_terms=$(grep -c "debugUnlock_or_scan_mode_switch" <<<"${flush_expr}" || true)
flush_scan_terms=$(grep -c "cptra_in_debug_scan_mode" <<<"${flush_expr}" || true)
echo "flush_expression_switch_terms=${flush_switch_terms}"
echo "flush_expression_debug_scan_terms=${flush_scan_terms}"
if (( flush_switch_terms == 0 )); then
  gate_fail "the flush expression does not reference the switch input; the trace below would be meaningless"
fi
# Does the flush bypass the per-entry lock bits? This decides whether the flush is
# a containment mechanism worth wiring anything into.
lock_bypass="$(grep -n "debugUnlock_or_scan_mode_switch" "${KV}" | grep -v "always_comb flush_keyvault" || true)"
echo "  sites where the switch input is used outside the flush expression:"
sed -e 's/^/    /' <<<"${lock_bypass}"
lock_bypass_sites=0
if [[ -n "${lock_bypass}" ]]; then
  lock_bypass_sites=$(grep -c . <<<"${lock_bypass}")
fi
echo "flush_switch_lock_bypass_sites=${lock_bypass_sites}"

# ---------------------------------------------------------------------------
# Gate 2: the signal actually connected to the kv flush port, and its producers.
# This gate decides proposition A.
# ---------------------------------------------------------------------------
echo "--- gate 2: the signal connected to the kv flush port, and its producers ---"
# The instantiation block. This file uses CRLF line endings, so the range regex
# must not anchor on a bare end-of-line, and the extracted text is stripped.
kv_inst="$(awk '/^key_vault1/,/^\)/' "${TOP}" | tr -d '\r')"
if [[ -z "${kv_inst}" ]]; then
  gate_fail "could not extract the kv instantiation from ${TOP}"
fi
flush_conn_line="$(grep "debugUnlock_or_scan_mode_switch" <<<"${kv_inst}" || true)"
if [[ -z "${flush_conn_line}" ]]; then
  gate_fail "the kv instantiation does not connect the flush port"
  flush_signal=""
else
  echo "  the flush port connection at the kv instantiation:"
  sed -e 's/^/    /' <<<"${flush_conn_line}"
  # .port (signal) -> extract the signal inside the outer parentheses.
  flush_signal="$(sed -e 's/.*debugUnlock_or_scan_mode_switch[[:space:]]*(//' \
                      -e 's/).*//' -e 's/[[:space:]]//g' <<<"${flush_conn_line}")"
fi
echo "kv_flush_port_connected_signal=${flush_signal:-none}"
if [[ -z "${flush_signal}" ]]; then
  gate_fail "could not extract the connected signal name"
fi

# Every producer term of that signal. A continuous assignment to it in the top.
flush_drivers=""
flush_driver_count=0
if [[ -n "${flush_signal}" ]]; then
  flush_drivers="$(grep -n -E "(assign|always_comb)[[:space:]]+${flush_signal}[[:space:]]*=" "${TOP}" \
                   | tr -d '\r' || true)"
  if [[ -z "${flush_drivers}" ]]; then
    gate_fail "found no driver for ${flush_signal} in ${TOP}"
  else
    echo "  driver of ${flush_signal}:"
    sed -e 's/^/    /' <<<"${flush_drivers}"
    flush_driver_count=$(grep -c . <<<"${flush_drivers}")
  fi
fi
echo "kv_flush_signal_driver_sites=${flush_driver_count}"

# Split the right-hand side on '|' and count the terms, then look for a fatal
# error term among them. This is the measurement that decides proposition A.
flush_rhs="$(sed -e 's/^[^=]*=//' -e 's/;.*//' <<<"${flush_drivers}")"
flush_term_count=0
if [[ -n "${flush_rhs}" ]]; then
  flush_term_count=$(tr '|' '\n' <<<"${flush_rhs}" | sed -e 's/[[:space:]]//g' \
                     | grep -c . || true)
fi
echo "kv_flush_signal_producer_terms=${flush_term_count}"
echo "  producer terms of ${flush_signal}:"
tr '|' '\n' <<<"${flush_rhs}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
  | grep -v '^$' | sed -e 's/^/    term: /'
fatal_in_flush=$(tr '|' '\n' <<<"${flush_rhs}" | grep -c -i "error_fatal" || true)
echo "kv_flush_signal_fatal_error_terms=${fatal_in_flush}"

# Contrast for the term detector. The same extract-and-split applied to a signal
# in the same file that is known NOT to carry a fatal error term must report zero,
# so a nonzero reading above is known to be discrimination rather than a pattern
# that matches anything. cptra_in_debug_scan_mode is the natural control: the kv
# module consumes it alongside the flush signal and it is not fatal-derived.
contrast_sig="cptra_in_debug_scan_mode"
contrast_drv="$(grep -n -E "(assign|always_comb)[[:space:]]+${contrast_sig}[[:space:]]*=" "${TOP}" \
                | tr -d '\r' || true)"
if [[ -z "${contrast_drv}" ]]; then
  gate_fail "could not find a driver for the contrast signal ${contrast_sig}; the term detector is unverified"
  contrast_fatal=-1
else
  echo "  contrast: a signal in the same file that should carry no fatal term"
  sed -e 's/^/    /' <<<"${contrast_drv}"
  contrast_rhs="$(sed -e 's/^[^=]*=//' -e 's/;.*//' <<<"${contrast_drv}")"
  contrast_fatal=$(tr '|' '\n' <<<"${contrast_rhs}" | grep -c -i "error_fatal" || true)
fi
echo "contrast_signal_fatal_error_terms=${contrast_fatal}"
if (( contrast_fatal != 0 )); then
  gate_fail "the term detector reports a fatal term on a signal that should have none; its readings are not trustworthy"
fi

# The fatal error signal itself: is it an output of the design, and is it the same
# signal the SoC sees? A term that is only an internal alias would not count.
echo "  the fatal error signal at the top level:"
grep -n -E "output logic[[:space:]]+cptra_error_fatal|\.cptra_error_fatal" "${TOP}" \
  | tr -d '\r' | sed -e 's/^/    /'
fatal_is_top_output=$(grep -c -E "output logic[[:space:]]+cptra_error_fatal" "${TOP}" || true)
echo "cptra_error_fatal_is_top_level_output=${fatal_is_top_output}"
if (( fatal_is_top_output == 0 )); then
  gate_fail "cptra_error_fatal is not a top-level output; the flush trace would not mean what it appears to"
fi

# ---------------------------------------------------------------------------
# Gate 3: the SoC-facing fatal error register. This gate bounds proposition B.
# ---------------------------------------------------------------------------
echo "--- gate 3: the fields and write-enables of the fatal error register ---"
echo "  declared fields of CPTRA_HW_ERROR_FATAL in ${EXT_RDL}:"
fatal_fields="$(awk '/name = "Hardware Error Fatal"/,/} CPTRA_HW_ERROR_FATAL;/' "${EXT_RDL}" \
                | grep -n -E "rw_rw_sticky_hw|field \{" || true)"
if [[ -z "${fatal_fields}" ]]; then
  gate_fail "could not extract the CPTRA_HW_ERROR_FATAL field list from ${EXT_RDL}"
else
  sed -e 's/^/    /' <<<"${fatal_fields}"
fi
fatal_field_count=$(grep -c "rw_rw_sticky_hw" <<<"${fatal_fields}" || true)
echo "fatal_register_error_fields=${fatal_field_count}"
fatal_kv_fields=$(grep -c -i "kv\|keyvault\|key_vault" <<<"${fatal_fields}" || true)
echo "fatal_register_keyvault_fields=${fatal_kv_fields}"

echo "  write-enables of CPTRA_HW_ERROR_FATAL in ${SOC}:"
fatal_wes="$(grep -n "CPTRA_HW_ERROR_FATAL\..*\.we[[:space:]]*=" "${SOC}")"
if [[ -z "${fatal_wes}" ]]; then
  gate_fail "found no CPTRA_HW_ERROR_FATAL write-enables in ${SOC}"
else
  sed -e 's/^/    /' <<<"${fatal_wes}"
fi
fatal_we_count=$(grep -c . <<<"${fatal_wes}" || true)
echo "fatal_register_write_enable_sites=${fatal_we_count}"
fatal_we_kv=$(grep -c -i "kv_\|keyvault" <<<"${fatal_wes}" || true)
echo "fatal_register_keyvault_write_enables=${fatal_we_kv}"
# Does the soc_ifc module even have a KeyVault error input it could have used? A
# port that existed and went unused would be a real routing gap.
soc_kv_ports="$(awk '/^module soc_ifc_top/,/^\);/' "${SOC}" \
                | grep -o -E "^[[:space:]]*(input|output)[^,]*" | awk '{print $NF}' \
                | tr -d ',' | grep -i -E "^kv|keyvault" || true)"
soc_kv_port_count=0
if [[ -n "${soc_kv_ports}" ]]; then
  soc_kv_port_count=$(grep -c . <<<"${soc_kv_ports}")
  echo "  KeyVault-related ports on soc_ifc_top:"
  sed -e 's/^/    /' <<<"${soc_kv_ports}"
fi
echo "soc_ifc_keyvault_ports=${soc_kv_port_count}"
soc_kv_error_ports=$(grep -c -i "error" <<<"${soc_kv_ports}" || true)
echo "soc_ifc_keyvault_error_ports=${soc_kv_error_ports}"

# ---------------------------------------------------------------------------
# Gate 4: how a KeyVault error is observable to software at all.
# ---------------------------------------------------------------------------
echo "--- gate 4: KeyVault error observability paths ---"
echo "  the KeyVault error status field in ${KV_DEF}:"
kv_err_field="$(grep -n -B2 -A2 "ERROR\[8\]" "${KV_DEF}" || true)"
if [[ -z "${kv_err_field}" ]]; then
  gate_fail "could not find the KeyVault error status field in ${KV_DEF}"
else
  sed -e 's/^/    /' <<<"${kv_err_field}"
fi
kv_err_encodings=$(grep -c -E "KV_READ_FAIL|KV_WRITE_FAIL" "${KV_DEF}" || true)
echo "keyvault_error_status_encodings=${kv_err_encodings}"
# Per-engine status registers carrying that field. Each engine that talks to the
# KeyVault gets one, which is the software-visible report path.
engine_status_regs="$(grep -rln "kv_status_reg__ERROR__kv_error_e" --include=*_reg_pkg.sv src/ \
                      | grep -v -E "/tb/|_uvm|uvmf" | sort || true)"
engine_status_count=0
if [[ -n "${engine_status_regs}" ]]; then
  engine_status_count=$(grep -c . <<<"${engine_status_regs}")
  echo "  engine register packages exposing a KeyVault error status field:"
  sed -e 's/^/    /' <<<"${engine_status_regs}"
fi
echo "engine_register_blocks_with_keyvault_error_status=${engine_status_count}"
if (( engine_status_count == 0 )); then
  gate_fail "found no engine-side KeyVault error status; the observability claim could not be evaluated"
fi
# The client-side error producers that feed those status fields.
kv_client_err=$(grep -c -E "KV_READ_FAIL|KV_WRITE_FAIL" \
                src/keyvault/rtl/kv_read_client.sv src/keyvault/rtl/kv_write_client.sv 2>/dev/null \
                | awk -F: '{t+=$2} END{print t+0}')
echo "keyvault_client_error_assignment_sites=${kv_client_err}"
# The interrupt lines, reported separately and deliberately NOT merged into
# proposition B: an interrupt tie-off is a different observability path from the
# SoC-facing fatal register, and letting one stand in for the other would
# overstate the finding.
echo "  the KeyVault interrupt lines at the top level:"
kv_intr="$(grep -n -E "kv_error_intr|kv_notif_intr" "${TOP}" | tr -d '\r' || true)"
sed -e 's/^/    /' <<<"${kv_intr}"
kv_intr_tieoffs=$(grep -c -E "assign (kv_error_intr|kv_notif_intr) *= *1'b0" <<<"${kv_intr}" || true)
echo "keyvault_interrupt_tieoff_sites=${kv_intr_tieoffs}"

# ---------------------------------------------------------------------------
# Gate 5: what do the in-tree specifications require?
# ---------------------------------------------------------------------------
echo "--- gate 5: in-tree specification statements ---"
echo "  what a fatal error requires, per ${INT_SPEC}:"
grep -n -i "recover Caliptra fatal errors\|fatal errors via SoC power-good" "${INT_SPEC}" \
  | head -4 | sed -e 's/^/    /'
fatal_recovery_reqs=$(grep -c -i "recover Caliptra fatal errors" "${INT_SPEC}" || true)
echo "spec_fatal_error_recovery_requirements=${fatal_recovery_reqs}"
if (( fatal_recovery_reqs == 0 )); then
  gate_fail "found no in-tree statement on fatal error recovery to evaluate against"
fi
echo "  what the fatal error register is specified to carry, per ${EXT_RDL}:"
awk '/name = "Hardware Error Fatal"/,/rw_rw_sticky_hw nmi_pin/' "${EXT_RDL}" \
  | grep -n -E "desc =|Only a Caliptra reset|Assertion of any bit" | sed -e 's/^/    /'
echo "  in-tree statements requiring KeyVault errors to be reported as fatal:"
kv_fatal_reqs=$(grep -c -i -E "(key ?vault|KV) [^.]{0,60}(fatal error|CPTRA_HW_ERROR_FATAL)" \
                "${INT_SPEC}" "${HW_SPEC}" "${KV_DOC}" 2>/dev/null \
                | awk -F: '{t+=$2} END{print t+0}')
echo "spec_statements_requiring_keyvault_errors_reported_fatal=${kv_fatal_reqs}"
if (( kv_fatal_reqs > 0 )); then
  grep -n -i -E "(key ?vault|KV) [^.]{0,60}(fatal error|CPTRA_HW_ERROR_FATAL)" \
    "${INT_SPEC}" "${HW_SPEC}" "${KV_DOC}" 2>/dev/null | head -6 | sed -e 's/^/    /'
fi
# The conditions on which the integration specification requires hardware to clear
# the KeyVault. The pattern has to tolerate either word order and must not stop at
# a comma, because these statements live in wide table cells; a narrower pattern
# reports zero here while the matching sentences are printed directly above it,
# which would invert the reading of this gate.
echo "  in-tree statements on hardware clearing of the KeyVault:"
SPEC_CLEAR_PAT="(key ?vault)[^|]{0,120}(cleared|flush)|(cleared|flush)[^|]{0,120}(key ?vault)"
spec_clear_hits="$(grep -n -i -E "${SPEC_CLEAR_PAT}" "${INT_SPEC}" || true)"
if [[ -z "${spec_clear_hits}" ]]; then
  spec_hw_clear=0
else
  spec_hw_clear=$(grep -c . <<<"${spec_clear_hits}")
  # Truncated: these are wide specification table rows.
  cut -c1-200 <<<"${spec_clear_hits}" | sed -e 's/^/    /'
fi
echo "spec_hardware_keyvault_clear_conditions=${spec_hw_clear}"
if (( spec_hw_clear == 0 )); then
  gate_fail "found no in-tree statement on hardware clearing of the KeyVault; the flush requirement could not be evaluated"
fi

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------
echo "--- audit summary ---"
echo "kv_flush_port_connected_signal=${flush_signal:-none}"
echo "kv_flush_signal_producer_terms=${flush_term_count}"
echo "kv_flush_signal_fatal_error_terms=${fatal_in_flush}"
echo "flush_switch_lock_bypass_sites=${lock_bypass_sites}"
echo "fatal_register_error_fields=${fatal_field_count}"
echo "fatal_register_keyvault_fields=${fatal_kv_fields}"
echo "fatal_register_write_enable_sites=${fatal_we_count}"
echo "soc_ifc_keyvault_error_ports=${soc_kv_error_ports}"
echo "engine_register_blocks_with_keyvault_error_status=${engine_status_count}"
echo "spec_statements_requiring_keyvault_errors_reported_fatal=${kv_fatal_reqs}"

if (( gate_failed )); then
  echo "audit_result=FAIL"
  exit 1
fi

# Proposition A: withdrawn if a fatal error term is already in the connected
# signal. Upheld only if it is absent.
if (( fatal_in_flush > 0 )); then
  echo "proposition_a_conclusion=a_fatal_error_already_reaches_the_keyvault_flush"
else
  echo "proposition_a_conclusion=no_fatal_error_term_reaches_the_flush_review_needed"
fi

# Proposition B: withdrawn if no in-tree statement requires the report AND the
# KeyVault error is observable elsewhere.
if (( kv_fatal_reqs == 0 && engine_status_count > 0 )); then
  echo "proposition_b_conclusion=no_in_tree_requirement_and_keyvault_errors_are_reported_per_engine"
else
  echo "proposition_b_conclusion=a_keyvault_fatal_report_requirement_was_found_review_needed"
fi
echo "audit_result=PASS"
exit 0
