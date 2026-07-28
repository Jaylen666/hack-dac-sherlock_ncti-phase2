#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Structural audit for kv_bug_023: is a hardware set path for the KeyVault lock
# bits required, and does anything in the tree try to use one?
#
# The candidate claims hardware must set lock_wr and lock_use on a boot-stage
# transition through an hwset interface, with the hardware set taking priority
# over the software register value, and that this interface is absent. The
# absence is trivially confirmable. What decides the case is whether the absence
# breaks anything:
#
#   leg 1 (attempted)  does any RTL in the tree drive a lock set that the
#                      register description silently discards? A dropped
#                      connection would be a real defect.
#   leg 2 (keyable)    is there any boot-stage transition to key such a set from?
#   leg 3 (required)   do the in-tree specifications assign lock setting to
#                      hardware, or to the microcontroller?
#
# Gates:
#   1  field properties of lock_wr and lock_use in the register description
#   2  every driver of the lock fields in the RTL, and the generated register block
#   3  every boot-stage-like signal name in the tree that could key a set
#   4  in-tree specification statements on who sets the locks and when they clear
#   5  the enforcement consumers of the lock terms, so a passing simulation is
#      known to have exercised live logic rather than dead signals
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
REG="src/keyvault/rtl/kv_reg.sv"
KV_DOC="src/keyvault/config/keyvault.md"
HW_SPEC="docs/CaliptraHardwareSpecification.md"

gate_failed=0
gate_fail() { echo "gate_fail: $*"; gate_failed=1; }

for f in "${KV}" "${RDL}" "${REG}" "${KV_DOC}" "${HW_SPEC}"; do
  [[ -f "${f}" ]] || gate_fail "missing input ${f}"
done
if (( gate_failed )); then
  echo "audit_result=FAIL"
  exit 1
fi

echo "=== kv_bug_023 structural audit: hardware set path for the KV lock bits ==="
echo "tree_relative_paths_only=yes"

# ---------------------------------------------------------------------------
# Gate 1: the declared capability of the lock fields.
# ---------------------------------------------------------------------------
echo "--- gate 1: lock field properties in the register description ---"
lock_decls="$(grep -n -B1 "lock_wr=0\|lock_use=0" "${RDL}")"
if [[ -z "${lock_decls}" ]]; then
  gate_fail "could not find the lock field declarations in ${RDL}"
else
  sed -e 's/^/  /' <<<"${lock_decls}"
fi
lock_lines="$(grep "lock_wr=0\|lock_use=0" "${RDL}")"
lock_field_count=$(grep -c . <<<"${lock_lines}" || true)
echo "lock_field_declarations=${lock_field_count}"
if (( lock_field_count != 2 )); then
  gate_fail "expected 2 lock field declarations, found ${lock_field_count}"
fi
# A hardware set needs one of hwset, hw=w or a we/wel write enable on the field.
hwset_props=$(grep -c "hwset" <<<"${lock_lines}" || true)
hww_props=$(grep -c -E "hw=w|hw=rw" <<<"${lock_lines}" || true)
we_props=$(grep -c -E "[^s]we=|[^s]we;|we=true" <<<"${lock_lines}" || true)
echo "lock_fields_with_hwset=${hwset_props}"
echo "lock_fields_with_hw_write_access=${hww_props}"
echo "lock_fields_with_hardware_write_enable=${we_props}"
lock_hw_settable=$((hwset_props + hww_props + we_props))
echo "lock_fields_hardware_settable=${lock_hw_settable}"
# For contrast, a field in the same file that IS hardware-writable, so the gate
# is known to be able to detect the properties it is looking for.
echo "  contrast: a hardware-writable field in the same description"
grep -n "dest_valid\[9\]=0" "${RDL}" | sed -e 's/^/    /'
contrast_hw=$(grep "dest_valid\[9\]=0" "${RDL}" | grep -c -E "hw=rw|hw=w" || true)
echo "contrast_field_hardware_writable=${contrast_hw}"
if (( contrast_hw == 0 )); then
  gate_fail "the property detector found no hardware write access on a field known to have it"
fi

# ---------------------------------------------------------------------------
# Gate 2: every driver of the lock fields, in the hand-written RTL and in the
# generated register block. A dropped hardware set would show up here.
# ---------------------------------------------------------------------------
echo "--- gate 2: drivers of the lock fields ---"
echo "  assignments to the lock hwif inputs in ${KV}:"
kv_lock_drivers="$(grep -n "hwif_in.*lock_wr\|hwif_in.*lock_use" "${KV}")"
if [[ -z "${kv_lock_drivers}" ]]; then
  gate_fail "found no lock hwif input assignment in ${KV}; expected the swwel feedback"
else
  sed -e 's/^/    /' <<<"${kv_lock_drivers}"
fi
kv_lock_driver_count=$(grep -c . <<<"${kv_lock_drivers}" || true)
echo "kv_lock_hwif_in_assignments=${kv_lock_driver_count}"
# Which sub-property is driven? Only swwel is expected. Anything driving .next or
# .hwset would be an attempted hardware set.
swwel_drivers=$(grep -c "swwel" <<<"${kv_lock_drivers}" || true)
set_drivers=$(grep -c -E "\.next|\.hwset|\.we[[:space:]]*=" <<<"${kv_lock_drivers}" || true)
echo "kv_lock_swwel_assignments=${swwel_drivers}"
echo "kv_lock_attempted_hardware_set_assignments=${set_drivers}"

# A hardware set attempt means a hwif_in path into the field: hwif_in.*.lock_*
# with .next, .hwset or .we. The generated register block's own
# field_combo/field_storage plumbing is internal state, not a hardware set, so it
# must not be counted here; counting it would report an attempted set that does
# not exist and invert this gate's conclusion.
echo "  hardware set attempts on the lock fields anywhere in the tree:"
other_writers="$(grep -rn --include=*.sv --include=*.svh \
                 -E "hwif_in\..*lock_(wr|use)\.(next|hwset|we)[[:space:]]*=" \
                 src/ 2>/dev/null | grep -v -E "/tb/|_uvm|uvmf" || true)"
if [[ -z "${other_writers}" ]]; then
  echo "    none"
  other_writer_count=0
else
  sed -e 's/^/    /' <<<"${other_writers}"
  other_writer_count=$(grep -c . <<<"${other_writers}")
fi
echo "lock_field_hardware_set_attempts_in_tree=${other_writer_count}"

# For contrast, the same pattern against a field that IS hardware-written, so the
# detector is known to be able to find such an assignment when one exists.
contrast_hw_writes="$(grep -rn --include=*.sv \
                      -E "hwif_in\..*dest_valid\.(next|we)[[:space:]]*=" \
                      src/keyvault/rtl/ 2>/dev/null || true)"
if [[ -z "${contrast_hw_writes}" ]]; then
  contrast_hw_write_count=0
else
  contrast_hw_write_count=$(grep -c . <<<"${contrast_hw_writes}")
fi
echo "  contrast: hardware writes to a field that does accept them"
sed -e 's/^/    /' <<<"${contrast_hw_writes}"
echo "contrast_field_hardware_write_attempts=${contrast_hw_write_count}"
if (( contrast_hw_write_count == 0 )); then
  gate_fail "the hardware-set detector found no assignment on a field known to receive them"
fi

echo "  how the generated register block updates the lock fields:"
reg_lock="$(grep -n "lock_wr\|lock_use" "${REG}" | grep -i -E "next|swwel|swmod|_we|assign" | head -20)"
if [[ -z "${reg_lock}" ]]; then
  gate_fail "found no lock field update logic in ${REG}"
else
  sed -e 's/^/    /' <<<"${reg_lock}"
fi
reg_hwset_paths=$(grep -c -E "lock_wr.*hwset|lock_use.*hwset" "${REG}" || true)
echo "generated_register_block_lock_hwset_paths=${reg_hwset_paths}"

# ---------------------------------------------------------------------------
# Gate 3: is there a boot-stage transition to key a hardware set from?
# ---------------------------------------------------------------------------
echo "--- gate 3: boot-stage signal names anywhere in the tree ---"
stage_names=(boot_stage boot_flow stable_owner stable_owner_key_en
             boot_flow_key_clear rt_stage fmc_stage rom_stage stage_transition
             transition_lock lock_policy)
stage_hits_total=0
for s in "${stage_names[@]}"; do
  # Case-insensitive: identifiers in this tree mix cases, and a case-sensitive
  # sweep would report a false zero.
  hits=$(grep -rI -i --include=*.sv --include=*.svh --include=*.v --include=*.rdl \
              -c -w "${s}" src/ 2>/dev/null | awk -F: '{t+=$2} END{print t+0}')
  echo "  stage_name ${s}: rtl_hits=${hits}"
  stage_hits_total=$((stage_hits_total + hits))
done
echo "boot_stage_signal_hits_in_rtl=${stage_hits_total}"
kv_ports="$(awk '/^module kv $|^module kv$|^module kv /,/^\);/' "${KV}" \
            | grep -o -E "^[[:space:]]*(input|output)[^,]*" | awk '{print $NF}' | tr -d ',' | sort -u)"
kv_port_count=$(grep -c . <<<"${kv_ports}" || true)
if (( kv_port_count == 0 )); then
  gate_fail "could not extract the kv port list from ${KV}"
fi
kv_stage_ports=$(grep -c -i -E "stage|boot|owner|lifecycle|policy" <<<"${kv_ports}" || true)
echo "kv_port_count=${kv_port_count}"
echo "kv_boot_stage_ports=${kv_stage_ports}"

# ---------------------------------------------------------------------------
# Gate 4: who do the in-tree specifications say sets the locks?
# ---------------------------------------------------------------------------
echo "--- gate 4: in-tree specification statements on the lock bits ---"
echo "  ${HW_SPEC}: KV entry control field table"
grep -n -E "Lock wr|Lock use" "${HW_SPEC}" | sed -e 's/^/    /'
echo "  ${KV_DOC}: who sets the locks"
grep -n -E "ROM (shall|requirement|MUST)|ROM requirement|set the lock" "${KV_DOC}" | head -10 | sed -e 's/^/    /'
# Does any in-tree sentence say HARDWARE sets these bits?
hw_sets_lock=$(grep -c -i -E "(hardware|HW) (shall |must |will )?set(s)? .{0,40}lock (wr|use)" \
               "${HW_SPEC}" "${KV_DOC}" 2>/dev/null | awk -F: '{t+=$2} END{print t+0}')
echo "spec_statements_requiring_hardware_to_set_locks=${hw_sets_lock}"
# Does any in-tree sentence say the microcontroller / firmware sets them?
sw_sets_lock=$(grep -c -i -E "prevents the entry from being (written|used)|ROM shall lock|locked for writes" \
               "${HW_SPEC}" "${KV_DOC}" 2>/dev/null | awk -F: '{t+=$2} END{print t+0}')
echo "spec_statements_assigning_locks_to_firmware=${sw_sets_lock}"
# The stickiness requirement the simulation asserts against.
echo "  the stickiness requirement the simulation measures:"
grep -n -i "cannot be reset until" "${HW_SPEC}" | head -4 | sed -e 's/^/    /'
sticky_reqs=$(grep -c -i "cannot be reset until" "${HW_SPEC}" || true)
echo "spec_lock_stickiness_requirements=${sticky_reqs}"
if (( sticky_reqs == 0 )); then
  gate_fail "found no lock stickiness statement to check the simulation against"
fi

# ---------------------------------------------------------------------------
# Gate 5: are the lock terms actually consumed? A lock that enforces nothing
# would make the simulation's passing controls meaningless.
# ---------------------------------------------------------------------------
echo "--- gate 5: enforcement consumers of the lock terms ---"
lock_q_uses="$(grep -n "lock_wr_q\|lock_use_q" "${KV}")"
lock_q_use_count=$(grep -c . <<<"${lock_q_uses}" || true)
sed -e 's/^/  /' <<<"${lock_q_uses}"
echo "lock_term_reference_sites=${lock_q_use_count}"
read_enforce=$(grep -c "lock_use_q\[entry\]" <<<"$(sed -n '225,245p' "${KV}")" || true)
echo "lock_use_read_mux_enforcement_sites=${read_enforce}"
wr_enforce=$(grep -c -E "lock_wr_q\[entry\]" <<<"$(sed -n '165,260p' "${KV}")" || true)
echo "lock_wr_enforcement_sites=${wr_enforce}"
if (( lock_q_use_count == 0 )); then
  gate_fail "the lock terms are referenced nowhere; enforcement would be dead"
fi

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------
echo "--- audit summary ---"
echo "lock_fields_hardware_settable=${lock_hw_settable}"
echo "kv_lock_attempted_hardware_set_assignments=${set_drivers}"
echo "lock_field_hardware_set_attempts_in_tree=${other_writer_count}"
echo "boot_stage_signal_hits_in_rtl=${stage_hits_total}"
echo "kv_boot_stage_ports=${kv_stage_ports}"
echo "spec_statements_requiring_hardware_to_set_locks=${hw_sets_lock}"
echo "spec_lock_stickiness_requirements=${sticky_reqs}"
echo "lock_term_reference_sites=${lock_q_use_count}"

if (( gate_failed )); then
  echo "audit_result=FAIL"
  exit 1
fi

if (( set_drivers == 0 && other_writer_count == 0 && stage_hits_total == 0 \
      && kv_stage_ports == 0 && hw_sets_lock == 0 )); then
  echo "audit_conclusion=no_hardware_lock_set_is_attempted_keyable_or_required"
else
  echo "audit_conclusion=a_hardware_lock_set_attempt_or_requirement_was_found_review_needed"
fi
echo "audit_result=PASS"
exit 0
