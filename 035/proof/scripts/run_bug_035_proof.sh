#!/usr/bin/env bash
# BUG-035 structural audit: the SHA accelerator LOCK field has no hardware
# set/clear path at all -- neither an update branch in the field's combinational
# block nor an input-struct member a hardware agent could drive.
#
# This case is audit-only by construction. A dynamic witness is impossible:
# proving "no hardware port exists" cannot be done by driving a port, because
# any observation of the form "LOCK did not move when I drove X" is explained
# away by "X was the wrong signal". The audit instead enumerates the field's
# complete update set and the module's complete input surface.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROOF="$(cd "$HERE/.." && pwd)"
CMP="${CMP:-$(cd "$PROOF/../../.." && pwd)}"
LOGS="$PROOF/logs"
mkdir -p "$LOGS"
AUDIT_LOG="$LOGS/structural_audit.log"
: >"$AUDIT_LOG"

CSR="${DUT_CSR_SV:-$CMP/src/soc_ifc/rtl/sha512_acc_csr.sv}"
PKG="${DUT_CSR_PKG_SV:-$CMP/src/soc_ifc/rtl/sha512_acc_csr_pkg.sv}"

# Extract the regions of interest by content rather than by line number, so the
# audit stays valid when a remediation shifts line numbering (the negative
# control depends on this).
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
LOCK_BLOCK="$SCRATCH/lock_block.txt"
IN_STRUCT="$SCRATCH/in_struct.txt"
LOCKSET_SITE="$SCRATCH/lockset_site.txt"

awk '/\/\/ Field: sha512_acc_csr\.LOCK\.LOCK/{f=1} f{print} /field_combo\.LOCK\.LOCK\.load_next/{if(f) exit}' \
  "$CSR" >"$LOCK_BLOCK"
# Anchor on the struct's own closing tag and walk back to its opening brace,
# so member order inside the struct cannot change what gets extracted.
awk '{buf[NR]=$0}
     /\} sha512_acc_csr__in_t;/{end=NR}
     END{for(i=end;i>=1;i--) if(buf[i] ~ /typedef struct packed\{/){start=i; break}
         for(i=start;i<=end;i++) print buf[i]}' \
  "$PKG" >"$IN_STRUCT"
grep -A 8 'if(hwif_in.lock_set)' "$CSR" >"$LOCKSET_SITE" 2>/dev/null || true

gates_ok=0
gates_total=0

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

{
  echo "BUG-035 structural audit"
  echo "csr=$CSR"
  echo "pkg=$PKG"
  echo
} | tee -a "$AUDIT_LOG"

# --- group 1: the LOCK field exists and is a real storage element -----------
gate "test -f '$CSR'" "csr implementation file is present"
gate "test -f '$PKG'" "csr package file is present"
gate "grep -q 'field_storage.LOCK.LOCK.value <= 1.h1;' '$CSR'" \
     "LOCK is a flop whose reset value is 1 (lock held out of reset)"
gate "grep -q 'assign hwif_out.LOCK.LOCK.value = field_storage.LOCK.LOCK.value;' '$CSR'" \
     "LOCK value is exported to the wrapper as hwif_out"

# --- group 2: the LOCK update set is exactly two software arms --------------
gate "grep -q \"decoded_reg_strb.LOCK && !decoded_req_is_wr) begin // SW set on read\" '$CSR'" \
     "LOCK update arm 1 of 2 is software set-on-read"
gate "grep -q 'decoded_reg_strb.LOCK && decoded_req_is_wr && hwif_in.valid_user) begin // SW write 1 clear' '$CSR'" \
     "LOCK update arm 2 of 2 is software write-1-clear"
# The whole field_combo block for LOCK spans lines 585..600; count its arms.
gate "test \"\$(grep -c 'if(' '$LOCK_BLOCK')\" -eq 2" \
     "LOCK combinational block contains exactly 2 update arms, no more"
gate "! grep -q 'hwset\|hwclr\|hwif_in.lock' '$LOCK_BLOCK'" \
     "LOCK combinational block references no hardware set/clear source"

# --- group 3: no hardware input exists that could reach LOCK ----------------
# Note: field_combo.LOCK.LOCK.next exists and is legitimate -- it is the
# field's own internal combinational output. The claim is about the hwif_in
# namespace, which is the only surface a hardware agent can reach.
gate "! grep -q 'hwif_in.LOCK' '$CSR'" \
     "the csr consumes nothing from the hwif_in.LOCK namespace"
gate "! grep -q 'hwif_in.LOCK.LOCK.hwset\|hwif_in.LOCK.LOCK.hwclr' '$CSR'" \
     "no hardware set or clear input for LOCK is consumed anywhere in the csr"
gate "! grep -q 'sha512_acc_csr__LOCK__in_t' '$PKG'" \
     "package declares no LOCK input struct type"
# The top-level input struct spans lines 83..95: enumerate its members.
gate "! grep -q 'LOCK' '$IN_STRUCT'" \
     "top-level csr input struct has no LOCK member a hardware agent could drive"

# --- group 4: sibling fields DO have hardware paths (contrast) --------------
gate "grep -q 'sha512_acc_csr__EXECUTE__in_t' '$PKG'" \
     "contrast: EXECUTE has an input struct type in the same package"
gate "test \"\$(grep -c 'hwset\|hwclr' '$PKG')\" -ge 7" \
     "contrast: at least 7 hwset/hwclr members exist in the package for other fields"
gate "grep -q 'if(hwif_in.EXECUTE.EXECUTE.hwclr) begin' '$CSR'" \
     "contrast: EXECUTE consumes a hardware clear arm in the same csr"

# --- group 5: lock_set is NOT a LOCK control (rules out a false witness) ----
# hwif_in.lock_set exists, but it is the USER field's hardware write enable.
# Any testbench that drives lock_set expecting LOCK to move is driving the
# wrong signal; this gate pins down what lock_set actually gates.
gate "grep -q 'logic lock_set;' '$PKG'" \
     "an input named lock_set does exist in the csr input struct"
gate "grep -q 'if(hwif_in.lock_set) begin // HW Write - we' '$CSR'" \
     "lock_set is a hardware write-enable, not a LOCK update source"
gate "test \"\$(grep -n 'if(hwif_in.lock_set)' '$CSR' | wc -l)\" -eq 1" \
     "lock_set is consumed at exactly one site"
gate "grep -q 'Field: sha512_acc_csr.USER.USER' '$LOCKSET_SITE' || grep -B4 'if(hwif_in.lock_set)' '$CSR' | grep -q 'USER'" \
     "the single lock_set consumer is the USER field, not LOCK"

# --- group 6: software-only lock is reachable by unprivileged software ------
gate "! grep -qE 'lc_escalate|debug|priv' '$LOCK_BLOCK'" \
     "LOCK arms carry no privilege or debug qualifier beyond valid_user"
gate "grep -q 'readback_array\[0\]\[0:0\] = (decoded_reg_strb.LOCK && !decoded_req_is_wr)' '$CSR'" \
     "reading LOCK returns the stored value, so set-on-read is observable to software"

{
  echo
  echo "structural_gates_passed=${gates_ok}/${gates_total}"
} | tee -a "$AUDIT_LOG"

if [ "$gates_ok" -eq "$gates_total" ]; then
  echo "result=PASS" | tee -a "$AUDIT_LOG"
  rc=0
else
  echo "STRUCTURAL_AUDIT: FAIL" | tee -a "$AUDIT_LOG"
  rc=1
fi

# This case ships no simulation, so run.log is the transcript of the audit run
# itself rather than of a simulator, and witness.log is the extract of the gates
# that carry the claim. Both are derived from the audit output above; neither
# stands in for simulator output.
cp "$AUDIT_LOG" "$LOGS/run.log"
{
  echo "BUG-035 witness extract: the gates that assert the absence of a"
  echo "hardware set/clear path for the SHA accelerator LOCK field."
  echo
  grep -E 'hwif_in.LOCK namespace|hardware set or clear input for LOCK|no LOCK input struct type|no LOCK member|references no hardware set/clear source|exactly 2 update arms' "$AUDIT_LOG"
  echo
  echo "supporting contrast gates (a hardware path is expressible here):"
  grep -E 'contrast:' "$AUDIT_LOG"
  echo
  echo "gates that rule out lock_set as a LOCK control:"
  grep -E 'lock_set' "$AUDIT_LOG"
  echo
  echo "structural_gates_passed=${gates_ok}/${gates_total}"
} >"$LOGS/witness.log"

exit "$rc"
