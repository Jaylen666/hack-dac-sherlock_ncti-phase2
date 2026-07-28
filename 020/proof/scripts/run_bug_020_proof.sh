#!/usr/bin/env bash
# BUG-020 structural audit: no hardware-derived boot-phase event exists in the
# design. The transition detector that produced FMC/RT/error phase signals from
# ICCM access is absent, together with every reference to it, and the only
# phase-adjacent signal reaching the crypto blocks is a software-written
# register bit.
#
# Audit-only by construction. There is no dangling port, no tied-off signal and
# no stub to drive: the module and all references are gone, so nothing in the
# elaborated design can be stimulated to witness the omission. What the audit
# establishes is the completeness of the absence plus the software origin of
# every remaining phase signal.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROOF="$(cd "$HERE/.." && pwd)"
CMP="${CMP:-$(cd "$PROOF/../../.." && pwd)}"
SRC="${DUT_SRC_DIR:-$CMP/src}"
LOGS="$PROOF/logs"
mkdir -p "$LOGS"
AUDIT_LOG="$LOGS/structural_audit.log"
: >"$AUDIT_LOG"

TOP="$SRC/integration/rtl/caliptra_top.sv"
SOCIFC="$SRC/soc_ifc/rtl/soc_ifc_top.sv"
KV="$SRC/keyvault/rtl/kv.sv"

gates_ok=0; gates_total=0
gate() {
  local cmd="$1" desc="$2"
  gates_total=$((gates_total + 1))
  if eval "$cmd" >/dev/null 2>&1; then
    gates_ok=$((gates_ok + 1))
    printf 'gate_ok   [%02d] %s\n' "$gates_total" "$desc" | tee -a "$AUDIT_LOG"
  else
    printf 'gate_fail [%02d] %s\n' "$gates_total" "$desc" | tee -a "$AUDIT_LOG"
  fi
}

{ echo "BUG-020 structural audit"; echo "src=$SRC"; echo; } | tee -a "$AUDIT_LOG"

# --- group 1: the detector and every reference to it are absent -------------
gate "! test -f '$SRC/integration/rtl/boot_flow_monitor.sv'" \
     "the boot-flow transition detector source file does not exist"
gate "test \"\$(grep -rl 'boot_flow' '$SRC' 2>/dev/null | wc -l)\" -eq 0" \
     "no file under src references boot_flow at all"
gate "test \"\$(grep -rn 'boot_flow_fmc\|boot_flow_rt\|boot_flow_error' '$SRC' 2>/dev/null | wc -l)\" -eq 0" \
     "none of the three phase outputs is referenced anywhere"
gate "! grep -q 'boot_flow_monitor' '$TOP'" \
     "the integration top does not instantiate the detector"

# The absence is complete rather than a half-removal: a dangling instance or an
# unconnected port would be a different defect with a different fix.
gate "! grep -rn 'boot_flow' '$SRC' 2>/dev/null | grep -q 'input\|output'" \
     "no dangling port declaration survives the removal"

# --- group 2: the census anchors are live code, not a stale tree ------------
gate "test -f '$TOP'" "the integration top is present"
gate "grep -q 'cptra_core_dmi_enable' '$TOP'" \
     "anchor: debug gating exists in the integration top"
gate "grep -q 'el2_veer_wrapper rvtop' '$TOP'" \
     "anchor: the CPU wrapper is instantiated, so fetch-side logic is present"
gate "grep -qE '^kv +#\\(' '$TOP' && grep -qE '^key_vault1' '$TOP'" \
     "anchor: the key vault is instantiated in the integration top"

# --- group 3: the key vault has no boot-phase input ------------------------
gate "test -f '$KV'" "the key vault source is present"
gate "! grep -q 'boot_flow' '$KV'" \
     "the key vault module references no boot-flow signal"
# Enumerate the reset and mode inputs it does have, so the absence is scoped.
gate "grep -q 'fw_update_rst_window' '$KV'" \
     "contrast: the key vault does take a firmware-update reset window input"
gate "grep -q 'debugUnlock_or_scan_mode_switch' '$KV'" \
     "contrast: the key vault does take a debug-unlock or scan mode input"

# --- group 4: the surviving phase signal is software-written ---------------
gate "grep -q 'assign ss_ocp_lock_in_progress = soc_ifc_reg_hwif_out.SS_OCP_LOCK_CTRL.LOCK_IN_PROGRESS.value;' '$SOCIFC'" \
     "the OCP lock phase signal is driven straight from a software register field"
gate "! grep -q 'assign ss_ocp_lock_in_progress = .*iccm\|assign ss_ocp_lock_in_progress = .*fetch' '$SOCIFC'" \
     "that signal is not derived from any fetch or ICCM observation"
gate "grep -q 'output logic         ss_ocp_lock_in_progress' '$SOCIFC'" \
     "the software-written phase signal is exported from soc_ifc_top"
gate "test \"\$(grep -c 'ss_ocp_lock_in_progress' '$TOP')\" -ge 5" \
     "the software-written phase signal is distributed to multiple consumers"

# --- group 5: the second lock is software-written too ----------------------
gate "grep -qE 'assign iccm_lock +=  *soc_ifc_reg_hwif_out\\.internal_iccm_lock\\.lock\\.value;' '$SOCIFC'" \
     "the ICCM lock is also driven from a software register field"

# --- group 6: the documented obligation rests on software ------------------
gate "grep -q 'OCP_LOCK_IN_PROGRESS' '$SRC/keyvault/config/keyvault.md'" \
     "the key vault description names the software bit as the phase indicator"
gate "grep -qi 'MUST set' '$SRC/keyvault/config/keyvault.md'" \
     "the description states the obligation as a software requirement"

{ echo; echo "structural_gates_passed=${gates_ok}/${gates_total}"; } | tee -a "$AUDIT_LOG"

if [ "$gates_ok" -eq "$gates_total" ]; then
  echo "result=PASS" | tee -a "$AUDIT_LOG"; rc=0
else
  echo "STRUCTURAL_AUDIT: FAIL" | tee -a "$AUDIT_LOG"; rc=1
fi

# This case ships no simulation. run.log is the transcript of the audit run
# itself and witness.log is the extract of the gates carrying the claim.
cp "$AUDIT_LOG" "$LOGS/run.log"
{
  echo "BUG-020 witness extract: the gates establishing that no hardware-derived"
  echo "boot-phase event exists and that every surviving phase signal is"
  echo "written by software."
  echo
  grep -E 'does not exist|references boot_flow|phase outputs|does not instantiate|dangling port|references no boot-flow' "$AUDIT_LOG"
  echo
  echo "software origin of the surviving phase signals:"
  grep -E 'software register field|not derived from any fetch|distributed to multiple consumers' "$AUDIT_LOG"
  echo
  echo "structural_gates_passed=${gates_ok}/${gates_total}"
} >"$LOGS/witness.log"

exit "$rc"
