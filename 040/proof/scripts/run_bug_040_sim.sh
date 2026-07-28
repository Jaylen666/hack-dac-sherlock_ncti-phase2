#!/usr/bin/env bash
# BUG-040 directed simulation: a write to the read-only STATUS register also
# commits new values into CONTROL, because CONTROL's write-enable is qualified
# with two address hits instead of one.
#
# Compiles one spi_host_reg_top plus the primitive closure it needs. Every
# source is taken verbatim from the audited tree; only the negative control may
# point DUT_SPI_HOST_REG_TOP at a patched scratch copy.
set -euo pipefail

CMP="${CMP_ROOT:-/home/smy/hackatdac26-phase-2-caliptra}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TB="$(cd "$HERE/../tb" && pwd)"
LOGS="$(cd "$HERE/../logs" && pwd)"
BUILD="$LOGS/../build"
S="$CMP/src"

DUT_SPI_HOST_REG_TOP="${DUT_SPI_HOST_REG_TOP:-$S/spi_host/rtl/spi_host_reg_top.sv}"

SIM_LOG="${SIM_LOG:-$LOGS/sim.log}"
CMP_LOG="${CMP_LOG:-$LOGS/compile.log}"
TB_FILE="${TB_FILE:-$TB/spi_host_reg_top_bug_040_tb.sv}"
TB_TOP="${TB_TOP:-spi_host_reg_top_bug_040_tb}"

export CALIPTRA_ROOT="$CMP"

rm -rf "$BUILD"
mkdir -p "$BUILD"
cd "$BUILD"

cat > filelist.f <<EOF
+incdir+$S/libs/rtl
+incdir+$S/caliptra_prim/rtl
+incdir+$S/caliptra_prim_generic/rtl
+incdir+$S/spi_host/rtl
$S/libs/rtl/ahb_defines_pkg.sv
$S/caliptra_prim/rtl/caliptra_prim_util_pkg.sv
$S/caliptra_prim/rtl/caliptra_prim_mubi_pkg.sv
$S/caliptra_prim/rtl/caliptra_prim_pkg.sv
$S/caliptra_prim/rtl/caliptra_prim_subreg_pkg.sv
$S/caliptra_prim_generic/rtl/caliptra_prim_generic_buf.sv
$S/caliptra_prim_generic/rtl/caliptra_prim_generic_flop.sv
$S/caliptra_prim/rtl/caliptra_prim_buf.sv
$S/caliptra_prim/rtl/caliptra_prim_flop.sv
$S/caliptra_prim/rtl/caliptra_prim_onehot_check.sv
$S/caliptra_prim/rtl/caliptra_prim_reg_we_check.sv
$S/caliptra_prim/rtl/caliptra_prim_subreg_arb.sv
$S/caliptra_prim/rtl/caliptra_prim_subreg.sv
$S/caliptra_prim/rtl/caliptra_prim_subreg_ext.sv
$S/libs/rtl/ahb_slv_sif.sv
$S/libs/rtl/ahb_to_reg_adapter.sv
$S/spi_host/rtl/spi_host_reg_pkg.sv
$DUT_SPI_HOST_REG_TOP
$TB_FILE
EOF

export TMPDIR="${TMPDIR:-/home/smy/.cache/vcstmp}"
mkdir -p "$TMPDIR"

# AssertConnected_A in caliptra_prim_onehot_check fires in any block-level
# compile: it checks that the *instantiating* block bound the count-error alert
# via CALIPTRA_ASSERT_PRIM_COUNT_ERROR_TRIGGER_ALERT, which happens above
# spi_host_reg_top and is therefore absent here. It says nothing about this
# defect. The filter_names flag below asks VCS to suppress it; VCS reports it
# anyway, so expect it once at 1ps in the transcript. It is inert either way: it
# fires identically in the audited and negative-control runs, the sim reaches its
# own $finish, and the verdict is computed only from this bench's check counters
# and covers. Every other assertion stays enabled, and this proof reads the DUT
# through its ports only, so no verdict depends on any assertion inside it.
vcs -full64 -sverilog -timescale=1ns/1ps \
    -assert svaext \
    -assert "filter_names=AssertConnected_A" \
    +lint=none \
    -f filelist.f \
    -top "$TB_TOP" \
    -l "$CMP_LOG" -o simv 2>&1 | tail -25

./simv -l "$SIM_LOG" 2>&1 | tail -60

# ---- verdicts ----
# The defect is reported by the TB as TBFAIL lines on the violating checks, so a
# TBFAIL here is expected and is not a script failure. Only a global timeout
# means the harness did not run to completion.
if grep -q 'TBFAIL global timeout' "$SIM_LOG"; then
  echo "SIM RESULT: FAIL (harness timed out)" | tee -a "$SIM_LOG"
  exit 1
fi

if grep -q '^result=PASS' "$SIM_LOG"; then
  echo "SIM RESULT: PASS (audited RTL shows the defect signature)"
  exit 0
fi

if grep -q '^result=NOT_THE_AUDITED_SIGNATURE' "$SIM_LOG"; then
  echo "SIM RESULT: SIGNATURE_MISMATCH (qualifier appears corrected)"
  exit 2
fi

echo "SIM RESULT: FAIL (no recognised verdict in $SIM_LOG)"
exit 1
