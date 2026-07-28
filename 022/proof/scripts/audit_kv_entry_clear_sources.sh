#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Structural audit for kv_bug_022: does a boot-stage transition clear exist, and
# is one required of the hardware?
#
# The candidate claims the KeyVault must clear entries that are not part of the
# next boot stage's retained set when the boot flow advances. That claim has two
# independent legs, and this audit decides both:
#
#   leg 1 (capability)  is there any signal in the submitted tree that represents
#                       a boot-stage transition, and does it reach the kv module?
#   leg 2 (requirement) do the in-tree specifications assign the duty of clearing
#                       KeyVault entries on a stage transition to hardware, or to
#                       ROM / firmware?
#
# If leg 1 finds no such signal anywhere and leg 2 finds the duty assigned to
# firmware, the missing logic is not a required hardware feature of this design
# and the candidate is withdrawn.
#
# Gates:
#   1  enumerate every producer term of kv.sv's key_entry_clear
#   2  enumerate every producer term of kv.sv's flush_keyvault
#   3  enumerate the kv module port list and count boot-stage-like ports
#   4  search the whole tree for any boot-stage / stage-policy signal name
#   5  read the in-tree specifications for who is assigned the clearing duty
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
RDL="src/keyvault/rtl/kv_reg.rdl"
KV_DOC="src/keyvault/config/keyvault.md"
INT_SPEC="docs/CaliptraIntegrationSpecification.md"
HW_SPEC="docs/CaliptraHardwareSpecification.md"
TOP="src/integration/rtl/caliptra_top.sv"

gate_failed=0
gate_fail() { echo "gate_fail: $*"; gate_failed=1; }

for f in "${KV}" "${RDL}" "${KV_DOC}" "${INT_SPEC}" "${HW_SPEC}" "${TOP}"; do
  [[ -f "${f}" ]] || gate_fail "missing input ${f}"
done
if (( gate_failed )); then
  echo "audit_result=FAIL"
  exit 1
fi

echo "=== kv_bug_022 structural audit: boot-stage transition clear ==="
echo "tree_relative_paths_only=yes"

# ---------------------------------------------------------------------------
# Gate 1: every producer of key_entry_clear, the module's per-entry clear.
# ---------------------------------------------------------------------------
echo "--- gate 1: producers of key_entry_clear ---"
clear_block="$(awk '/key_entry_clear\[g_entry\] <=/,/;[[:space:]]*$/' "${KV}")"
if [[ -z "${clear_block}" ]]; then
  gate_fail "could not extract the key_entry_clear assignment from ${KV}"
else
  echo "${clear_block}" | sed -e 's/^[[:space:]]*/  /'
fi
grep -n "key_entry_clear\[g_entry\] <=" "${KV}" | sed -e 's/^/  at /'

# Each named term in that assignment, counted.
clear_terms=0
for term in kv_multi_write_err "KEY_CTRL\[g_entry\].clear.value" "key_entry_clear\[g_entry\] & key_entry_ctrl_we"; do
  if grep -q "${term}" <<<"${clear_block}"; then
    clear_terms=$((clear_terms + 1))
    echo "  term_present: ${term}"
  fi
done
echo "key_entry_clear_producer_terms=${clear_terms}"

# Does any term depend on a stage indication? The three terms are a multi-write
# error, a software-poked register bit, and a self-hold. None is a stage input.
stage_terms_in_clear=$(grep -c -i -E "stage|boot_flow|owner|lifecycle" <<<"${clear_block}" || true)
echo "key_entry_clear_stage_dependent_terms=${stage_terms_in_clear}"

# ---------------------------------------------------------------------------
# Gate 2: every producer of flush_keyvault, the module's bulk overwrite.
# ---------------------------------------------------------------------------
echo "--- gate 2: producers of flush_keyvault ---"
flush_block="$(awk '/always_comb flush_keyvault/,/;[[:space:]]*$/' "${KV}")"
if [[ -z "${flush_block}" ]]; then
  gate_fail "could not extract the flush_keyvault assignment from ${KV}"
else
  echo "${flush_block}" | sed -e 's/^[[:space:]]*/  /'
fi
grep -n "always_comb flush_keyvault" "${KV}" | sed -e 's/^/  at /'

flush_terms=0
for term in debugUnlock_or_scan_mode_switch "cptra_in_debug_scan_mode" "wr_debug_values"; do
  if grep -q "${term}" <<<"${flush_block}"; then
    flush_terms=$((flush_terms + 1))
    echo "  term_present: ${term}"
  fi
done
echo "flush_keyvault_producer_terms=${flush_terms}"
stage_terms_in_flush=$(grep -c -i -E "stage|boot_flow|owner|lifecycle" <<<"${flush_block}" || true)
# cptra_in_debug_scan_mode legitimately contains no stage word; this counts only
# stage-policy words, so 0 is the expected reading.
echo "flush_keyvault_stage_dependent_terms=${stage_terms_in_flush}"

# ---------------------------------------------------------------------------
# Gate 3: the kv module port list. A hardware transition clear needs an input
# that says a transition happened; if no such port exists, none can be driven.
# ---------------------------------------------------------------------------
echo "--- gate 3: kv module port list ---"
port_block="$(awk '/^module kv $|^module kv$|^module kv /,/^\);/' "${KV}" | awk '/^    \(/,/^\);/')"
if [[ -z "${port_block}" ]]; then
  gate_fail "could not extract the kv port list from ${KV}"
fi
kv_input_ports="$(grep -o -E "^[[:space:]]*(input|output)[^,]*" <<<"${port_block}" \
                  | awk '{print $NF}' | tr -d ',' | sort -u)"
kv_port_count=$(wc -l <<<"${kv_input_ports}")
echo "kv_port_count=${kv_port_count}"
echo "${kv_input_ports}" | sed -e 's/^/  port: /'
kv_stage_ports=$(grep -c -i -E "stage|boot|owner|lifecycle|policy" <<<"${kv_input_ports}" || true)
# cptra_in_debug_scan_mode and debugUnlock_or_scan_mode_switch are debug/scan
# ports, not stage ports, and contain none of the words above.
echo "kv_boot_stage_ports=${kv_stage_ports}"

# The top-level instantiation cannot supply what the port list does not accept;
# record its port count for the same reason. The top-level file uses CRLF line
# endings, so the range end pattern must not be anchored past the carriage return.
inst_block="$(awk '/^key_vault1/,/^\)/' "${TOP}")"
inst_ports=$(grep -c -E "^[[:space:]]*\.[a-zA-Z_]" <<<"${inst_block}" || true)
if (( inst_ports == 0 )); then
  gate_fail "extracted zero connected ports for the kv instantiation in ${TOP}"
fi
echo "kv_instantiation_connected_ports=${inst_ports}"
inst_stage_ports=$(grep -c -i -E "^[[:space:]]*\.[a-zA-Z_]*(stage|boot|owner|lifecycle|policy)" <<<"${inst_block}" || true)
echo "kv_instantiation_stage_ports=${inst_stage_ports}"

# ---------------------------------------------------------------------------
# Gate 4: does ANY boot-stage / stage-policy signal exist in the tree? If one
# existed and merely failed to reach the KeyVault, that would be a routing gap
# worth reporting. This gate decides whether such a signal exists at all.
# ---------------------------------------------------------------------------
echo "--- gate 4: boot-stage signal names anywhere in the tree ---"
stage_names=(boot_stage boot_flow stable_owner stable_owner_key_en
             boot_flow_key_clear boot_flow_error rt_stage fmc_stage
             rom_stage stage_transition kv_monitor_alert)
stage_hits_total=0
for s in "${stage_names[@]}"; do
  # Case-insensitive on purpose: RTL in this tree mixes cases within one
  # identifier, and a case-sensitive sweep would report a false zero.
  hits=$(grep -rI -i --include=*.sv --include=*.svh --include=*.v --include=*.rdl \
              -c -w "${s}" src/ 2>/dev/null | awk -F: '{t+=$2} END{print t+0}')
  echo "  stage_name ${s}: rtl_hits=${hits}"
  stage_hits_total=$((stage_hits_total + hits))
done
echo "boot_stage_signal_hits_in_rtl=${stage_hits_total}"

# An OCP LOCK mode indication does exist, and it is deliberately excluded from the
# stage-name sweep above: CPTRA_HW_CONFIG.OCP_LOCK_MODE_en is driven from the
# ss_ocp_lock_en integration strap (src/soc_ifc/rtl/soc_ifc_top.sv:521), so it is
# a static capability bit for the whole power cycle, not a transition event that
# a per-stage clear could be edge-triggered from. Record where it is declared and
# whether it is an input to the KeyVault, so the negative result is precise
# rather than broad. Matched case-insensitively: the field is spelled
# OCP_LOCK_MODE_en, which a case-sensitive lowercase search would miss.
echo "  ocp lock mode declaration sites (rtl + rdl, excluding testbench and uvm):"
ocp_mode_sites="$(grep -rn -i --include=*.rdl --include=*.sv "ocp_lock_mode" src/ 2>/dev/null \
                  | grep -v -E "/tb/|_uvm|uvmf" || true)"
if [[ -z "${ocp_mode_sites}" ]]; then
  gate_fail "found no ocp lock mode declaration; expected at least the soc_ifc status field"
else
  sed -e 's/^/    /' <<<"${ocp_mode_sites}"
fi
ocp_mode_site_count=$(grep -c . <<<"${ocp_mode_sites}" || true)
echo "ocp_lock_mode_declaration_sites=${ocp_mode_site_count}"
ocp_mode_in_kv=$(grep -c -i "ocp_lock_mode" "${KV}" || true)
echo "ocp_lock_mode_references_in_kv_sv=${ocp_mode_in_kv}"

# ---------------------------------------------------------------------------
# Gate 5: who does the in-tree specification assign the clearing duty to?
# ---------------------------------------------------------------------------
echo "--- gate 5: in-tree specification assignment of the clearing duty ---"
echo "  ${KV_DOC}: enumerated clearing mechanisms"
grep -n "must be cleared" "${KV_DOC}" | sed -e 's/^/    /'
echo "  ${KV_DOC}: who sets the locks"
grep -n -E "ROM (shall|requirement|MUST)|ROM requirement" "${KV_DOC}" | head -10 | sed -e 's/^/    /'
echo "  ${INT_SPEC}: hardware-initiated key vault clearing"
grep -n -i "key vault are cleared\|flush any assets or secrets present in key vault" "${INT_SPEC}" \
  | sed -e 's/^/    /'
echo "  ${HW_SPEC}: register state across a firmware-update reset"
grep -n -i "intact after the reset" "${HW_SPEC}" | sed -e 's/^/    /'

hw_clear_conditions=$(grep -c -i "key vault are cleared\|flush any assets or secrets present in key vault" "${INT_SPEC}" || true)
echo "spec_hardware_clear_conditions=${hw_clear_conditions}"
spec_stage_clear=$(grep -c -i -E "boot stage.*(clear|wipe)|(clear|wipe).*boot stage" "${KV_DOC}" "${INT_SPEC}" "${HW_SPEC}" 2>/dev/null | awk -F: '{t+=$2} END{print t+0}')
echo "spec_boot_stage_clear_requirements=${spec_stage_clear}"

# The RDL decides whether hardware could even set the lock bits that a retention
# policy would have to use, independent of any stage signal.
echo "  ${RDL}: lock field properties"
grep -n "lock_wr=0\|lock_use=0" "${RDL}" | sed -e 's/^/    /'
lock_hw_writable=$(grep -E "lock_wr=0|lock_use=0" "${RDL}" | grep -c -E "hwset|hw=w|hw=rw" || true)
echo "lock_fields_hardware_settable=${lock_hw_writable}"

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------
echo "--- audit summary ---"
echo "kv_boot_stage_ports=${kv_stage_ports}"
echo "boot_stage_signal_hits_in_rtl=${stage_hits_total}"
echo "spec_boot_stage_clear_requirements=${spec_stage_clear}"
echo "spec_hardware_clear_conditions=${hw_clear_conditions}"
echo "lock_fields_hardware_settable=${lock_hw_writable}"

if (( gate_failed )); then
  echo "audit_result=FAIL"
  exit 1
fi

if (( kv_stage_ports == 0 && stage_hits_total == 0 && spec_stage_clear == 0 )); then
  echo "audit_conclusion=no_boot_stage_transition_exists_and_none_is_required"
else
  echo "audit_conclusion=a_boot_stage_indication_or_requirement_was_found_review_needed"
fi
echo "audit_result=PASS"
exit 0
