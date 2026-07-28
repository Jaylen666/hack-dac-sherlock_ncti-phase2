#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Structural audit for pv_bug_905: is the PCR lock's reset domain reachable from
# firmware, and does the in-tree specification forbid the lock clearing there?
#
# The simulation shows a set PCR lock cleared by a core_only_rst_b pulse. That is
# only a security finding if two further things hold, and this audit decides both:
#
#   1. the signal connected to the pv module's core_only_rst_b input is asserted
#      by something FIRMWARE can trigger, not only by an external reset pin. A
#      reset domain that only an SoC pin can enter is not an attacker capability.
#   2. an in-tree statement says the lock must survive it.
#
# A port name is not a contract here either: reading resetsignal = core_only_rst_b
# in the register description says nothing about who can assert it. Gate 2 traces
# the module input to the top-level signal and that signal's producer, and gate 3
# traces that producer back to a software-writable register field.
#
# Gates:
#   1  the declared reset signals of the lock field and of the entry data field
#   2  the signal connected to the pv core_only_rst_b port, and its producer
#   3  whether that producer is reachable from a firmware-writable register
#   4  what the lock protects: the swwel feedback and the data clear path
#   5  in-tree statements on PCR lock stickiness, plus the KeyVault contrast
#
# Read-only. Prints one key=value line per measurement plus an overall result.

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

if [[ -z "${REPO_ROOT}" || ! -d "${REPO_ROOT}/src/pcrvault/rtl" ]]; then
  echo "gate_fail: cannot locate the Caliptra tree; set CALIPTRA_ROOT"
  echo "audit_result=FAIL"
  exit 1
fi

cd "${REPO_ROOT}"

PV="src/pcrvault/rtl/pv.sv"
PV_RDL="src/pcrvault/rtl/pv_reg.rdl"
PV_REG="src/pcrvault/rtl/pv_reg.sv"
TOP="src/integration/rtl/caliptra_top.sv"
BOOT_FSM="src/soc_ifc/rtl/soc_ifc_boot_fsm.sv"
SOC="src/soc_ifc/rtl/soc_ifc_top.sv"
INT_RDL="src/soc_ifc/rtl/soc_ifc_internal_reg.rdl"
PV_DOC="src/pcrvault/config/pcrvault.md"
KV_RDL="src/keyvault/rtl/kv_reg.rdl"
HW_SPEC="docs/CaliptraHardwareSpecification.md"

gate_failed=0
gate_fail() { echo "gate_fail: $*"; gate_failed=1; }

for f in "${PV}" "${PV_RDL}" "${PV_REG}" "${TOP}" "${BOOT_FSM}" "${SOC}" \
         "${INT_RDL}" "${PV_DOC}" "${KV_RDL}" "${HW_SPEC}"; do
  [[ -f "${f}" ]] || gate_fail "missing input ${f}"
done
if (( gate_failed )); then
  echo "audit_result=FAIL"
  exit 1
fi

echo "=== pv_bug_905 structural audit: PCR lock reset domain reachability ==="
echo "tree_relative_paths_only=yes"

# ---------------------------------------------------------------------------
# Gate 1: the declared reset signals.
# ---------------------------------------------------------------------------
echo "--- gate 1: declared reset signals of the lock field and the entry data ---"
echo "  the lock field declaration in ${PV_RDL}:"
lock_decl="$(grep -n -A1 'field {desc="Lock the PCR' "${PV_RDL}" || true)"
if [[ -z "${lock_decl}" ]]; then
  gate_fail "could not find the PCR lock field declaration in ${PV_RDL}"
else
  sed -e 's/^/    /' <<<"${lock_decl}"
fi
lock_reset_core_only=$(grep -c "core_only_rst_b" <<<"${lock_decl}" || true)
echo "pcr_lock_resetsignal_is_core_only=${lock_reset_core_only}"
if (( lock_reset_core_only == 0 )); then
  gate_fail "the PCR lock field does not declare core_only_rst_b as its reset; the premise of this case does not hold"
fi

echo "  the entry data field declaration in ${PV_RDL}:"
data_decl="$(grep -n 'field pcr {' "${PV_RDL}" || true)"
sed -e 's/^/    /' <<<"${data_decl}"
data_reset_hard=$(grep -c "hard_reset_b" <<<"${data_decl}" || true)
echo "pcr_data_resetsignal_is_hard_reset=${data_reset_hard}"
if (( data_reset_hard == 0 )); then
  gate_fail "the PCR entry data does not declare hard_reset_b as its reset; the asymmetry this case rests on does not hold"
fi
# The asymmetry itself, stated as one number: the protected asset and the lock
# protecting it sit in different reset domains.
if (( lock_reset_core_only > 0 && data_reset_hard > 0 )); then
  echo "lock_and_data_reset_domains_differ=1"
else
  echo "lock_and_data_reset_domains_differ=0"
fi

# Confirm the generated register block implements what the description declares,
# so the finding is about real flops rather than about an .rdl comment.
lock_ff="$(grep -n -A3 'always_ff @(posedge clk or negedge hwif_in.core_only_rst_b)' "${PV_REG}" \
           | grep -c "PCR_CTRL\[i0\].lock.value <= 1'h0" || true)"
echo "generated_lock_flop_reset_by_core_only=${lock_ff}"
if (( lock_ff == 0 )); then
  gate_fail "the generated register block does not reset the lock flop on core_only_rst_b; the declaration and the implementation disagree"
fi

# ---------------------------------------------------------------------------
# Gate 2: the signal connected to the pv core_only_rst_b port, and its producer.
# ---------------------------------------------------------------------------
echo "--- gate 2: the signal connected to the pv core_only_rst_b port ---"
# caliptra_top.sv uses CRLF line endings, so the extracted text is stripped.
pv_inst="$(awk '/^pcr_vault1/,/^\);/' "${TOP}" | tr -d '\r')"
if [[ -z "${pv_inst}" ]]; then
  gate_fail "could not extract the pv instantiation from ${TOP}"
fi
core_conn="$(grep "core_only_rst_b" <<<"${pv_inst}" || true)"
if [[ -z "${core_conn}" ]]; then
  gate_fail "the pv instantiation does not connect core_only_rst_b"
  core_signal=""
else
  echo "  the reset port connection at the pv instantiation:"
  sed -e 's/^/    /' <<<"${core_conn}"
  core_signal="$(sed -e 's/.*core_only_rst_b[[:space:]]*(//' -e 's/).*//' \
                     -e 's/[[:space:]]//g' <<<"${core_conn}")"
fi
echo "pv_core_only_rst_connected_signal=${core_signal:-none}"
if [[ -z "${core_signal}" ]]; then
  gate_fail "could not extract the connected reset signal name"
fi

# Is that signal an internal signal driven by the design, or a top-level input
# pin? An internal signal can be asserted by firmware; a pin cannot.
core_is_top_input=0
if [[ -n "${core_signal}" ]]; then
  core_is_top_input=$(grep -c -E "input[[:space:]]+(logic[[:space:]]+)?${core_signal}\b" "${TOP}" || true)
fi
echo "pv_reset_signal_is_top_level_input_pin=${core_is_top_input}"

# Contrast: the same extraction applied to the module's cptra_pwrgood port, which
# the in-tree sentence names as the ONLY thing allowed to clear the lock. If that
# one resolves to a top-level input pin while the lock's reset does not, the
# distinction this case rests on is a real one rather than an artefact of how the
# extraction was written.
pwrgood_conn="$(grep "cptra_pwrgood" <<<"${pv_inst}" || true)"
pwrgood_signal="$(sed -e 's/.*cptra_pwrgood[[:space:]]*(//' -e 's/).*//' \
                      -e 's/[[:space:]]//g' <<<"${pwrgood_conn}")"
pwrgood_is_top_input=0
if [[ -n "${pwrgood_signal}" ]]; then
  pwrgood_is_top_input=$(grep -c -E "input[[:space:]]+(logic[[:space:]]+)?${pwrgood_signal}\b" "${TOP}" || true)
fi
echo "  contrast: the port the in-tree sentence names as the only permitted clear"
echo "    connected signal: ${pwrgood_signal:-none}"
echo "contrast_pwrgood_signal_is_top_level_input_pin=${pwrgood_is_top_input}"
if (( pwrgood_is_top_input == 0 )); then
  gate_fail "cptra_pwrgood did not resolve to a top-level input pin; the pin-vs-internal detector is unverified and its reading on the lock reset cannot be trusted"
fi

# ---------------------------------------------------------------------------
# Gate 3: is that reset reachable from a firmware-writable register?
# This gate decides whether the finding is an attacker capability.
# ---------------------------------------------------------------------------
echo "--- gate 3: firmware reachability of the reset ---"
echo "  the boot FSM output that carries it:"
grep -n -E "output logic cptra_uc_rst_b" "${BOOT_FSM}" | sed -e 's/^/    /'
echo "  the arc that enters the firmware-update reset state:"
fwrst_arc="$(grep -n "arc_BOOT_DONE_BOOT_FWRST =" "${BOOT_FSM}" || true)"
if [[ -z "${fwrst_arc}" ]]; then
  gate_fail "could not find the firmware-update reset arc in ${BOOT_FSM}"
else
  sed -e 's/^/    /' <<<"${fwrst_arc}"
fi
fw_update_rst_term=$(grep -c "fw_update_rst" <<<"${fwrst_arc}" || true)
echo "boot_fsm_fwrst_arc_uses_fw_update_rst=${fw_update_rst_term}"

echo "  where fw_update_rst comes from:"
fwrst_src="$(grep -n "\.fw_update_rst " "${SOC}" || true)"
sed -e 's/^/    /' <<<"${fwrst_src}"
fwrst_from_reg=$(grep -c "internal_fw_update_reset" <<<"${fwrst_src}" || true)
echo "fw_update_rst_driven_by_register=${fwrst_from_reg}"

echo "  the software access of that register field:"
fwrst_field="$(grep -n -A1 'field {desc = "FW Update reset to reset core"' "${INT_RDL}" || true)"
sed -e 's/^/    /' <<<"${fwrst_field}"
# sw = rw means firmware writes it. swwel = soc_req means the SoC is excluded,
# which makes this specifically a firmware capability rather than an SoC one.
fwrst_sw_writable=$(grep -c -E "sw *= *rw" <<<"${fwrst_field}" || true)
echo "fw_update_reset_field_software_writable=${fwrst_sw_writable}"
if (( fwrst_sw_writable == 0 )); then
  gate_fail "the firmware-update reset field is not software-writable; the attack precondition does not hold"
fi
if (( fw_update_rst_term > 0 && fwrst_from_reg > 0 && fwrst_sw_writable > 0 )); then
  echo "pcr_lock_reset_reachable_from_firmware=1"
else
  echo "pcr_lock_reset_reachable_from_firmware=0"
fi

# ---------------------------------------------------------------------------
# Gate 4: what the lock protects, so the loss has a stated consequence.
# ---------------------------------------------------------------------------
echo "--- gate 4: what the lock protects ---"
echo "  the lock feeding the write-enable-low of the lock and clear fields:"
swwel="$(grep -n "swwel" "${PV}" || true)"
sed -e 's/^/    /' <<<"${swwel}"
swwel_sites=0
if [[ -n "${swwel}" ]]; then
  swwel_sites=$(grep -c . <<<"${swwel}")
fi
echo "pv_lock_swwel_feedback_sites=${swwel_sites}"
if (( swwel_sites == 0 )); then
  gate_fail "found no swwel feedback in ${PV}; the lock would protect nothing even when set and the case is mis-framed"
fi
echo "  the clear field driving the entry data hardware clear:"
hwclr="$(grep -n "data.hwclr" "${PV}" || true)"
sed -e 's/^/    /' <<<"${hwclr}"
hwclr_sites=0
if [[ -n "${hwclr}" ]]; then
  hwclr_sites=$(grep -c . <<<"${hwclr}")
fi
echo "pv_clear_to_data_hwclr_sites=${hwclr_sites}"
if (( hwclr_sites == 0 )); then
  gate_fail "the clear field does not reach the entry data; the consequence claimed by this case is not present"
fi

# The swwel terms are also masked by ~fw_update_rst_window. That mask is an
# alternative explanation for a clear write landing, so its scope is recorded
# here: the boot FSM drives it combinationally from two boot states, meaning it
# is asserted only around the reset edge and de-asserted once the FSM is back in
# BOOT_DONE and firmware is running. The lock flop, by contrast, stays cleared
# indefinitely. The simulation measures the window de-asserted at the point the
# post-reset clear is issued, so the two are separated by measurement and not
# only by argument.
echo "  the boot FSM expression that produces the swwel mask:"
window_expr="$(grep -n -A1 "always_comb fw_update_rst_window =" "${BOOT_FSM}" || true)"
sed -e 's/^/    /' <<<"${window_expr}"
window_is_state_function=$(grep -c "boot_fsm_ps ==" <<<"${window_expr}" || true)
echo "swwel_mask_is_a_function_of_boot_fsm_state=${window_is_state_function}"
if (( window_is_state_function == 0 )); then
  gate_fail "fw_update_rst_window is not a function of the boot FSM state; its scope is not bounded to the reset edge and the confound cannot be dismissed"
fi

# ---------------------------------------------------------------------------
# Gate 5: the in-tree requirement, and the KeyVault contrast.
# ---------------------------------------------------------------------------
echo "--- gate 5: in-tree statements on PCR lock stickiness ---"
echo "  what ${PV_DOC} requires of the lock:"
pv_sticky="$(grep -n -i "lock bit.*sticky\|sticky.*powergood" "${PV_DOC}" || true)"
if [[ -z "${pv_sticky}" ]]; then
  gate_fail "found no in-tree PCR lock stickiness statement; there would be no requirement to violate"
else
  sed -e 's/^/    /' <<<"${pv_sticky}"
fi
pv_sticky_reqs=0
if [[ -n "${pv_sticky}" ]]; then
  pv_sticky_reqs=$(grep -c . <<<"${pv_sticky}")
fi
echo "spec_pcr_lock_stickiness_statements=${pv_sticky_reqs}"
# The same sentence appears in the hardware specification; count it separately so
# the requirement is not resting on a single file.
hw_sticky=$(grep -c -i "lock bit.*sticky\|sticky.*powergood" "${HW_SPEC}" || true)
echo "spec_pcr_lock_stickiness_statements_in_hw_spec=${hw_sticky}"

# Does any in-tree statement name a reset column for the PCR control register the
# way the KeyVault table does? If one existed and named core_only_rst_b, the
# requirement would be ambiguous and this case could not be decided on documents.
echo "  in-tree reset-column statements for the PCR control register:"
pv_reset_col=$(grep -c -i -E "^\| *Lock *\|" "${HW_SPEC}" || true)
echo "spec_pcr_control_reset_column_rows=${pv_reset_col}"

# The KeyVault contrast, recorded and deliberately kept OUT of the verdict: the
# KeyVault lock fields carry the same resetsignal, but the KeyVault has its own
# in-tree table naming core_only_rst_b in the reset column, so its declaration
# matches at least one of its own statements. The PCR vault has only the prose
# stickiness sentence and no such column, which is why this case is decidable and
# the KeyVault equivalent is not.
echo "  contrast, not part of this verdict: the KeyVault lock declarations"
kv_lock_core_only=$(grep -c "core_only_rst_b" "${KV_RDL}" || true)
echo "keyvault_lock_declarations_with_core_only_reset=${kv_lock_core_only}"
kv_reset_col=$(grep -c -i -E "^\| *Lock (wr|use)" "${HW_SPEC}" || true)
echo "keyvault_lock_reset_column_rows_in_hw_spec=${kv_reset_col}"

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------
echo "--- audit summary ---"
echo "pcr_lock_resetsignal_is_core_only=${lock_reset_core_only}"
echo "pcr_data_resetsignal_is_hard_reset=${data_reset_hard}"
echo "generated_lock_flop_reset_by_core_only=${lock_ff}"
echo "pv_core_only_rst_connected_signal=${core_signal:-none}"
echo "pv_reset_signal_is_top_level_input_pin=${core_is_top_input}"
echo "contrast_pwrgood_signal_is_top_level_input_pin=${pwrgood_is_top_input}"
echo "fw_update_reset_field_software_writable=${fwrst_sw_writable}"
echo "pv_lock_swwel_feedback_sites=${swwel_sites}"
echo "pv_clear_to_data_hwclr_sites=${hwclr_sites}"
echo "swwel_mask_is_a_function_of_boot_fsm_state=${window_is_state_function}"
echo "spec_pcr_lock_stickiness_statements=${pv_sticky_reqs}"
echo "spec_pcr_control_reset_column_rows=${pv_reset_col}"

if (( gate_failed )); then
  echo "audit_result=FAIL"
  exit 1
fi

# The finding is upheld only if the lock's reset is firmware-reachable AND an
# in-tree statement forbids the lock clearing on anything but a powergood cycle
# AND the entry data sits in a different reset domain so a measurement survives
# to be exposed.
if (( lock_reset_core_only > 0 && data_reset_hard > 0 && core_is_top_input == 0 \
      && fwrst_sw_writable > 0 && pv_sticky_reqs > 0 && hwclr_sites > 0 )); then
  echo "audit_conclusion=pcr_lock_reset_is_firmware_reachable_and_contradicts_the_in_tree_stickiness_requirement"
else
  echo "audit_conclusion=one_or_more_legs_absent_finding_not_upheld"
fi
echo "audit_result=PASS"
exit 0
