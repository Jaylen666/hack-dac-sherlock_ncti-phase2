#!/usr/bin/env bash
# BUG-N-004 directed simulation: the OCP LOCK HEK seed fuse has no hardware
# clear, so the secret-scrubbing strobe leaves it resident.
#
# Compiles one unmodified soc_ifc_reg together with its generated package. The
# negative control may point DUT_SOC_IFC_REG at a patched scratch copy; every
# other source is taken verbatim from the audited tree.
#
# soc_ifc_reg is self-contained: it needs only its own package plus the shared
# defines, so the closure below is small and does not require the block-level
# filelist. That is deliberate, because the missing clear is a property of the
# generated register field, not of anything soc_ifc_top does around it.
set -euo pipefail

CMP="${CMP_ROOT:-/home/smy/hackatdac26-phase-2-caliptra}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TB="$(cd "$HERE/../tb" && pwd)"
LOGS="$(cd "$HERE/../logs" && pwd)"
BUILD="$LOGS/../build"

DUT_SOC_IFC_REG="${DUT_SOC_IFC_REG:-$CMP/src/soc_ifc/rtl/soc_ifc_reg.sv}"
DUT_SOC_IFC_REG_PKG="${DUT_SOC_IFC_REG_PKG:-$CMP/src/soc_ifc/rtl/soc_ifc_reg_pkg.sv}"

# The negative control adds an hwclr member to the Fuse_w32 input struct, so the
# TB must drive it there and must NOT reference it on the audited struct, where
# it does not exist. NC_MODE=1 selects the guarded drive. On the audited run the
# define is absent, so that code is not compiled at all and cannot mask the
# defect.
NC_DEFINE=""
if [ "${NC_MODE:-0}" = "1" ]; then
  NC_DEFINE="+define+BUG_N004_HEK_HAS_HWCLR"
fi
SIM_LOG="${SIM_LOG:-$LOGS/sim.log}"
CMP_LOG="${CMP_LOG:-$LOGS/compile.log}"
TB_FILE="${TB_FILE:-$TB/soc_ifc_reg_bug_N004_tb.sv}"
TB_TOP="${TB_TOP:-soc_ifc_reg_bug_N004_tb}"

export CALIPTRA_ROOT="$CMP"

rm -rf "$BUILD"
mkdir -p "$BUILD"
cd "$BUILD"

# soc_ifc_reg.sv:7633 expands CALIPTRA_ASSERT_KNOWN without including the header
# that defines it, relying on an earlier compilation unit having pulled it in. A
# one-line shim does that and touches no audited source.
cat > sva_shim.sv <<'EOF'
`include "caliptra_sva.svh"
EOF

cat > filelist.f <<EOF
+incdir+$CMP/src/libs/rtl
+incdir+$CMP/src/integration/rtl
+incdir+$CMP/src/integration/rtl/caliptra_reg
$BUILD/sva_shim.sv
$DUT_SOC_IFC_REG_PKG
$DUT_SOC_IFC_REG
$TB_FILE
EOF

export TMPDIR="${TMPDIR:-/home/smy/.cache/vcstmp}"
mkdir -p "$TMPDIR"

vcs -full64 -sverilog -timescale=1ns/1ps \
    -assert svaext \
    +lint=none \
    $NC_DEFINE \
    -f filelist.f \
    -top "$TB_TOP" \
    -l "$CMP_LOG" -o simv 2>&1 | tail -25

./simv -l "$SIM_LOG" 2>&1 | tail -60

# ---- verdicts ----
# The defect itself is reported by the TB as TBFAIL lines on the violating
# checks, so a TBFAIL is expected here and is not a script failure. Only a
# global timeout means the harness did not run to completion.
if grep -q 'TBFAIL global timeout' "$SIM_LOG"; then
  echo "SIM RESULT: FAIL (harness timed out)" | tee -a "$SIM_LOG"
  exit 1
fi
if ! grep -q 'PROOF_RESULT: PASS' "$SIM_LOG"; then
  echo "SIM RESULT: FAIL (no PASS verdict)" | tee -a "$SIM_LOG"
  exit 1
fi

grep -E 'cov_|OBSERVED:|checks=' "$SIM_LOG" || true
echo "SIM RESULT: PASS"
