#!/usr/bin/env bash
# BUG-035 negative control (non-vacuity proof).
#
# Restores the LOCK hardware set/clear path on a scratch copy of the two csr
# files and re-runs the identical audit against them. The audit must FAIL, and
# it must fail for the right reasons: the gates that assert "no hardware path
# exists" must flip, while the gates describing the software arms and the
# lock_set/USER relationship must stay green (they are unrelated to the fix).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROOF="$(cd "$HERE/.." && pwd)"
CMP="${CMP:-$(cd "$PROOF/../../.." && pwd)}"
LOGS="$PROOF/logs"
mkdir -p "$LOGS"
NC_LOG="$LOGS/negative_control.log"
: >"$NC_LOG"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
cp "$CMP/src/soc_ifc/rtl/sha512_acc_csr.sv"     "$SCRATCH/sha512_acc_csr.sv"
cp "$CMP/src/soc_ifc/rtl/sha512_acc_csr_pkg.sv" "$SCRATCH/sha512_acc_csr_pkg.sv"

python3 - "$SCRATCH" <<'PY'
import io, os, sys
d = sys.argv[1]

# --- 1. package: add a LOCK input struct type and a LOCK member -------------
pkg_path = os.path.join(d, "sha512_acc_csr_pkg.sv")
pkg = io.open(pkg_path, encoding="utf-8").read()

anchor_type = "    typedef struct packed{\n        logic lock_set;"
if pkg.count(anchor_type) != 1:
    sys.exit("expected exactly 1 top-level in_t anchor, found %d"
             % pkg.count(anchor_type))
new_type = (
    "    typedef struct packed{\n"
    "        logic hwset;\n"
    "        logic hwclr;\n"
    "    } sha512_acc_csr__LOCK_LOCK__in_t;\n\n"
    "    typedef struct packed{\n"
    "        sha512_acc_csr__LOCK_LOCK__in_t LOCK;\n"
    "    } sha512_acc_csr__LOCK__in_t;\n\n"
    "    typedef struct packed{\n"
    "        sha512_acc_csr__LOCK__in_t LOCK;\n"
    "        logic lock_set;"
)
pkg = pkg.replace(anchor_type, new_type, 1)
io.open(pkg_path, "w", encoding="utf-8").write(pkg)

# --- 2. csr: give LOCK a highest-priority hardware set/clear arm ------------
csr_path = os.path.join(d, "sha512_acc_csr.sv")
csr = io.open(csr_path, encoding="utf-8").read()

anchor_arm = ("        if(decoded_reg_strb.LOCK && !decoded_req_is_wr) begin"
              " // SW set on read\n")
if csr.count(anchor_arm) != 1:
    sys.exit("expected exactly 1 LOCK set-on-read arm, found %d"
             % csr.count(anchor_arm))
new_arm = (
    "        if(hwif_in.LOCK.LOCK.hwclr) begin // HW Clear\n"
    "            next_c = '0;\n"
    "            load_next_c = '1;\n"
    "        end else if(hwif_in.LOCK.LOCK.hwset) begin // HW Set\n"
    "            next_c = '1;\n"
    "            load_next_c = '1;\n"
    "        end else if(decoded_reg_strb.LOCK && !decoded_req_is_wr) begin"
    " // SW set on read\n"
)
csr = csr.replace(anchor_arm, new_arm, 1)
io.open(csr_path, "w", encoding="utf-8").write(csr)
print("negative control: LOCK hardware set/clear restored on scratch copy")
PY
[ $? -eq 0 ] || { echo "NEGATIVE_CONTROL: FAIL (patch step failed)" | tee -a "$NC_LOG"; exit 1; }

NC_AUDIT="$LOGS/negative_control_audit.log"
DUT_CSR_SV="$SCRATCH/sha512_acc_csr.sv" \
DUT_CSR_PKG_SV="$SCRATCH/sha512_acc_csr_pkg.sv" \
  "$HERE/run_bug_035_proof.sh" >"$NC_AUDIT" 2>&1
rc=$?

# The audit writes structural_audit.log unconditionally; the fixed-tree run has
# now overwritten it. Preserve the NC copy and note that the unmodified-tree
# audit must be re-run last.
cp "$LOGS/structural_audit.log" "$LOGS/structural_audit_negative_control.log" 2>/dev/null || true

{
  echo "=== negative control audit (fixed scratch copy) ==="
  cat "$NC_AUDIT"
  echo
  echo "audit_exit_code=$rc"
} >>"$NC_LOG"

fails=0

# (a) the audit as a whole must no longer pass
if [ "$rc" -eq 0 ]; then
  echo "NC_CHECK_FAIL audit_still_passes_after_fix" | tee -a "$NC_LOG"
  fails=$((fails + 1))
else
  echo "NC_CHECK_PASS audit_fails_on_fixed_copy" | tee -a "$NC_LOG"
fi

# (b) the absence gates must positively flip
for desc in \
  "the csr consumes nothing from the hwif_in.LOCK namespace" \
  "no hardware set or clear input for LOCK is consumed anywhere in the csr" \
  "package declares no LOCK input struct type" \
  "top-level csr input struct has no LOCK member a hardware agent could drive" \
  "LOCK combinational block references no hardware set/clear source" \
  "LOCK combinational block contains exactly 2 update arms, no more"
do
  if grep -qF "gate_fail" "$NC_AUDIT" && grep -F "$desc" "$NC_AUDIT" | grep -q 'gate_fail'; then
    echo "NC_CHECK_PASS flipped: $desc" | tee -a "$NC_LOG"
  else
    echo "NC_CHECK_FAIL did_not_flip: $desc" | tee -a "$NC_LOG"
    fails=$((fails + 1))
  fi
done

# (c) the fix must be targeted, not a blanket rewrite: unrelated gates stay ok
for desc in \
  "LOCK update arm 1 of 2 is software set-on-read" \
  "LOCK update arm 2 of 2 is software write-1-clear" \
  "LOCK is a flop whose reset value is 1 (lock held out of reset)" \
  "lock_set is a hardware write-enable, not a LOCK update source" \
  "the single lock_set consumer is the USER field, not LOCK" \
  "contrast: EXECUTE consumes a hardware clear arm in the same csr"
do
  if grep -F "$desc" "$NC_AUDIT" | grep -q 'gate_ok'; then
    echo "NC_CHECK_PASS unaffected: $desc" | tee -a "$NC_LOG"
  else
    echo "NC_CHECK_FAIL unexpectedly_changed: $desc" | tee -a "$NC_LOG"
    fails=$((fails + 1))
  fi
done

{
  echo
  echo "nc_checks_failed=$fails"
} | tee -a "$NC_LOG"

if [ "$fails" -eq 0 ]; then
  echo "NEGATIVE_CONTROL: PASS" | tee -a "$NC_LOG"
  exit 0
else
  echo "NEGATIVE_CONTROL: FAIL" | tee -a "$NC_LOG"
  exit 1
fi
