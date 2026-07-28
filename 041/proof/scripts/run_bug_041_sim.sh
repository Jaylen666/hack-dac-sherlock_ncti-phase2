#!/usr/bin/env bash
# BUG-041 directed simulation.
#
# Compiles ONE unmodified `uart` top and drives it only through its ports: real
# serial frames into cio_rx_i, all software observation over the AHB-Lite slave
# port. Verdict comes from the bench's own check counters, printed as a
# `result=` line.
#
# DUT_UART_CORE can be overridden to point at a patched copy; the negative
# control uses that to run this same bench against corrected RTL.
set -euo pipefail

CMP="${CMP_ROOT:-/home/smy/hackatdac26-phase-2-caliptra}"
S="$CMP/src"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="${BUILD_DIR:-$HERE/../build}"
LOGS="${LOG_DIR:-$HERE/../logs}"
TB_FILE="$HERE/../tb/uart_bug_041_tb.sv"
TB_TOP="uart_bug_041_tb"

DUT_UART_CORE="${DUT_UART_CORE:-$S/uart/rtl/uart_core.sv}"

mkdir -p "$BUILD" "$LOGS"
cd "$BUILD"

# Explicit closure for the packages and the leaf cells that must be elaborated
# by name; everything else is resolved from the -y library directories below.
cat > filelist.f <<EOF
+incdir+$S/libs/rtl
+incdir+$S/caliptra_prim/rtl
+incdir+$S/caliptra_prim_generic/rtl
+incdir+$S/uart/rtl

$S/libs/rtl/ahb_defines_pkg.sv
$S/caliptra_prim/rtl/caliptra_prim_util_pkg.sv
$S/caliptra_prim/rtl/caliptra_prim_mubi_pkg.sv
$S/caliptra_prim/rtl/caliptra_prim_pkg.sv
$S/caliptra_prim/rtl/caliptra_prim_alert_pkg.sv
$S/caliptra_prim/rtl/caliptra_prim_subreg_pkg.sv
$S/caliptra_prim/rtl/caliptra_prim_count_pkg.sv
$S/uart/rtl/uart_reg_pkg.sv

$S/caliptra_prim_generic/rtl/caliptra_prim_generic_buf.sv
$S/caliptra_prim_generic/rtl/caliptra_prim_generic_flop.sv
$S/caliptra_prim/rtl/caliptra_prim_buf.sv
$S/caliptra_prim/rtl/caliptra_prim_flop.sv
$S/caliptra_prim/rtl/caliptra_prim_sec_anchor_buf.sv
$S/caliptra_prim/rtl/caliptra_prim_sec_anchor_flop.sv
$S/caliptra_prim/rtl/caliptra_prim_diff_decode.sv
$S/caliptra_prim/rtl/caliptra_prim_alert_sender.sv
$S/caliptra_prim/rtl/caliptra_prim_onehot_check.sv
$S/caliptra_prim/rtl/caliptra_prim_reg_we_check.sv
$S/caliptra_prim/rtl/caliptra_prim_subreg_arb.sv
$S/caliptra_prim/rtl/caliptra_prim_subreg.sv
$S/caliptra_prim/rtl/caliptra_prim_subreg_ext.sv
$S/caliptra_prim/rtl/caliptra_prim_intr_hw.sv
$S/caliptra_prim/rtl/caliptra_prim_fifo_sync.sv
$S/caliptra_prim/rtl/caliptra_prim_fifo_sync_cnt.sv
$S/libs/rtl/ahb_slv_sif.sv
$S/libs/rtl/ahb_to_reg_adapter.sv

$S/uart/rtl/uart_rx.sv
$S/uart/rtl/uart_tx.sv
$S/uart/rtl/uart_reg_top.sv
$DUT_UART_CORE
$S/uart/rtl/uart.sv

$TB_FILE
EOF

export TMPDIR="${TMPDIR:-/home/smy/.cache/vcstmp}"
mkdir -p "$TMPDIR"

# AssertConnected_A in caliptra_prim_onehot_check fires in any compile that does
# not bind CALIPTRA_ASSERT_PRIM_COUNT_ERROR_TRIGGER_ALERT above the block. It
# says nothing about this defect. The filter_names flag asks VCS to suppress it;
# VCS may report it anyway. It is inert either way: it fires identically in the
# audited and negative-control runs, and the verdict is computed only from this
# bench's check counters and covers, never from an assertion inside the DUT.
vcs -full64 -sverilog -timescale=1ns/1ps \
    -assert svaext \
    -assert "filter_names=AssertConnected_A" \
    +lint=none \
    -y "$S/caliptra_prim/rtl" +libext+.sv \
    -y "$S/caliptra_prim_generic/rtl" +libext+.sv \
    -f filelist.f \
    -top "$TB_TOP" \
    -o simv \
    -l "$LOGS/compile.log" > "$LOGS/compile_stdout.log" 2>&1 || {
      echo "result=FAIL"
      echo "COMPILE FAILED - see $LOGS/compile.log"
      exit 1
    }

./simv -l "$LOGS/sim.log" > "$LOGS/sim_stdout.log" 2>&1 || true

grep -E "^(case=|TBFAIL|cov_|witness_hits=|checks=|result=|PROOF_RESULT:)" \
  "$LOGS/sim.log" || true

if grep -q "^result=PASS" "$LOGS/sim.log"; then
  exit 0
elif grep -q "^result=NOT_THE_AUDITED_SIGNATURE" "$LOGS/sim.log"; then
  exit 2
fi
exit 1
