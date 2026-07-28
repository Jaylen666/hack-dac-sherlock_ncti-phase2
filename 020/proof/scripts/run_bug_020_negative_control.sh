#!/usr/bin/env bash
# BUG-020 negative control (non-vacuity proof).
#
# This case is unusual: there is no stub, no tied-off signal and no dangling
# port to restore, because the detector and every reference to it are gone. The
# control therefore reconstructs the shape of the missing logic on a scratch
# copy of the source tree -- a boot_flow_monitor source deriving three phase
# outputs from ICCM fetch observation, an instance of it in the integration top,
# and a boot-phase input on the key vault -- and re-runs the identical audit
# against that tree.
#
# The audit must fail, and it must fail on the census gates rather than on the
# anchors or on the software-origin gates, which the reconstruction leaves
# untouched. The scratch tree is a copy: the submitted checkout is never
# modified.
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
SRC2="$SCRATCH/src"
mkdir -p "$SRC2/integration/rtl" "$SRC2/soc_ifc/rtl" "$SRC2/keyvault/rtl" \
         "$SRC2/keyvault/config"
cp "$CMP/src/integration/rtl/caliptra_top.sv"  "$SRC2/integration/rtl/"
cp "$CMP/src/soc_ifc/rtl/soc_ifc_top.sv"       "$SRC2/soc_ifc/rtl/"
cp "$CMP/src/keyvault/rtl/kv.sv"               "$SRC2/keyvault/rtl/"
cp "$CMP/src/keyvault/config/keyvault.md"      "$SRC2/keyvault/config/"

# --- reconstruct the missing detector --------------------------------------
cat >"$SRC2/integration/rtl/boot_flow_monitor.sv" <<'SV'
// Reconstructed for the BUG-020 negative control only. Not a proposed
// implementation: its role is to give the audit something to find, so that the
// census gates can be shown to detect a restored detector.
module boot_flow_monitor (
  input  logic        clk,
  input  logic        rst_b,
  input  logic        iccm_fetch_valid,
  input  logic [31:0] iccm_fetch_addr,
  input  logic [31:0] fmc_region_base,
  input  logic [31:0] fmc_region_last,
  input  logic [31:0] rt_region_base,
  input  logic [31:0] rt_region_last,
  output logic        boot_flow_fmc,
  output logic        boot_flow_rt,
  output logic        boot_flow_error
);
  logic in_fmc, in_rt;
  always_comb begin
    in_fmc = iccm_fetch_valid &&
             (iccm_fetch_addr >= fmc_region_base) &&
             (iccm_fetch_addr <= fmc_region_last);
    in_rt  = iccm_fetch_valid &&
             (iccm_fetch_addr >= rt_region_base) &&
             (iccm_fetch_addr <= rt_region_last);
  end
  always_ff @(posedge clk or negedge rst_b) begin
    if (!rst_b) begin
      boot_flow_fmc   <= 1'b0;
      boot_flow_rt    <= 1'b0;
      boot_flow_error <= 1'b0;
    end else begin
      if (in_fmc) boot_flow_fmc <= 1'b1;
      if (in_rt)  boot_flow_rt  <= 1'b1;
      if (in_rt && !boot_flow_fmc) boot_flow_error <= 1'b1;
    end
  end
endmodule
SV

python3 - "$SRC2" <<'PY'
import io, os, sys
src2 = sys.argv[1]

# 1. instantiate the detector in the integration top, anchored on the kv
#    instance so the insertion lands in the same structural region.
top = os.path.join(src2, "integration", "rtl", "caliptra_top.sv")
s = io.open(top, encoding="utf-8").read()
anchor = "kv #(\n"
if s.count(anchor) != 1:
    sys.exit("expected exactly 1 kv instance anchor, found %d" % s.count(anchor))
inst = (
    "logic boot_flow_fmc;\n"
    "logic boot_flow_rt;\n"
    "logic boot_flow_error;\n"
    "boot_flow_monitor boot_flow_monitor_i (\n"
    "    .clk(clk),\n"
    "    .rst_b(cptra_noncore_rst_b),\n"
    "    .iccm_fetch_valid(1'b0),\n"
    "    .iccm_fetch_addr(32'h0),\n"
    "    .fmc_region_base(32'h0),\n"
    "    .fmc_region_last(32'h0),\n"
    "    .rt_region_base(32'h0),\n"
    "    .rt_region_last(32'h0),\n"
    "    .boot_flow_fmc(boot_flow_fmc),\n"
    "    .boot_flow_rt(boot_flow_rt),\n"
    "    .boot_flow_error(boot_flow_error)\n"
    ");\n\n"
    "kv #(\n"
)
io.open(top, "w", encoding="utf-8").write(s.replace(anchor, inst, 1))

# 2. give the key vault a boot-phase input, so the gate asserting it has none
#    can be shown to detect one.
kv = os.path.join(src2, "keyvault", "rtl", "kv.sv")
k = io.open(kv, encoding="utf-8").read()
kanchor = "    input logic fw_update_rst_window,"
if k.count(kanchor) != 1:
    sys.exit("expected exactly 1 fw_update_rst_window declaration, found %d"
             % k.count(kanchor))
io.open(kv, "w", encoding="utf-8").write(
    k.replace(kanchor,
              "    input logic boot_flow_fmc,\n"
              "    input logic boot_flow_rt,\n"
              "    input logic boot_flow_error,\n" + kanchor, 1))
print("negative control: detector reconstructed, instantiated, and wired to kv")
PY
[ $? -eq 0 ] || { echo "NEGATIVE_CONTROL: FAIL (patch step failed)" | tee -a "$NC_LOG"; exit 1; }

NC_AUDIT="$LOGS/negative_control_audit.log"
DUT_SRC_DIR="$SRC2" "$HERE/run_bug_020_proof.sh" >"$NC_AUDIT" 2>&1
rc=$?
cp "$LOGS/structural_audit.log" "$LOGS/structural_audit_negative_control.log" 2>/dev/null || true

fails=0
if [ "$rc" -eq 0 ]; then
  echo "NC_CHECK_FAIL audit_still_passes_after_reconstruction" | tee -a "$NC_LOG"
  fails=$((fails + 1))
else
  echo "NC_CHECK_PASS audit_fails_on_reconstructed_tree" | tee -a "$NC_LOG"
fi

# the census gates must positively flip
for desc in \
  "the boot-flow transition detector source file does not exist" \
  "no file under src references boot_flow at all" \
  "none of the three phase outputs is referenced anywhere" \
  "the integration top does not instantiate the detector" \
  "the key vault module references no boot-flow signal"
do
  if grep -F "$desc" "$NC_AUDIT" | grep -q 'gate_fail'; then
    echo "NC_CHECK_PASS flipped: $desc" | tee -a "$NC_LOG"
  else
    echo "NC_CHECK_FAIL did_not_flip: $desc" | tee -a "$NC_LOG"
    fails=$((fails + 1))
  fi
done

# the anchors and the software-origin gates must be untouched, which is what
# shows the audit is a targeted census rather than a blanket grep
for desc in \
  "anchor: debug gating exists in the integration top" \
  "anchor: the CPU wrapper is instantiated, so fetch-side logic is present" \
  "anchor: the key vault is instantiated in the integration top" \
  "the OCP lock phase signal is driven straight from a software register field" \
  "the ICCM lock is also driven from a software register field" \
  "contrast: the key vault does take a firmware-update reset window input" \
  "the description states the obligation as a software requirement"
do
  if grep -F "$desc" "$NC_AUDIT" | grep -q 'gate_ok'; then
    echo "NC_CHECK_PASS unaffected: $desc" | tee -a "$NC_LOG"
  else
    echo "NC_CHECK_FAIL unexpectedly_changed: $desc" | tee -a "$NC_LOG"
    fails=$((fails + 1))
  fi
done

# the submitted checkout must be untouched by this control
if [ "$(grep -rl 'boot_flow' "$CMP/src" 2>/dev/null | wc -l)" -eq 0 ]; then
  echo "NC_CHECK_PASS submitted_checkout_unmodified" | tee -a "$NC_LOG"
else
  echo "NC_CHECK_FAIL submitted_checkout_was_modified" | tee -a "$NC_LOG"
  fails=$((fails + 1))
fi

{ echo; echo "=== negative control audit transcript ==="; cat "$NC_AUDIT"; } >>"$NC_LOG"
echo "nc_checks_failed=$fails" | tee -a "$NC_LOG"
if [ "$fails" -eq 0 ]; then
  echo "NEGATIVE_CONTROL: PASS" | tee -a "$NC_LOG"; exit 0
else
  echo "NEGATIVE_CONTROL: FAIL" | tee -a "$NC_LOG"; exit 1
fi
