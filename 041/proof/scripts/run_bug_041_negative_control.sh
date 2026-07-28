#!/usr/bin/env bash
# BUG-041 negative control.
#
# Rewrites the audited instantiation in a scratch copy so the RX FIFO takes the
# library default OutputZeroIfEmpty = 1'b1 -- the same value the tx FIFO
# immediately above it takes -- and reruns the UNMODIFIED bench against it.
#
# Expected: the residual disappears, so the three violating checks stop failing
# and the bench reports result=NOT_THE_AUDITED_SIGNATURE, while the controls
# still show real bytes arriving and reading back. That is what makes the audited
# run's failures attributable to this one parameter and not to the bench.
set -euo pipefail

CMP="${CMP_ROOT:-/home/smy/hackatdac26-phase-2-caliptra}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$CMP/src/uart/rtl/uart_core.sv"
SCRATCH="$HERE/../scratch"
NCRUN="$HERE/../negative_control_run"
LOGS="$HERE/../logs"

mkdir -p "$SCRATCH" "$NCRUN" "$LOGS"

gates_ok=0
gates_bad=0
gate() {
  local cond="$1" desc="$2"
  if eval "$cond"; then
    echo "  ok   $desc"
    gates_ok=$((gates_ok + 1))
  else
    echo "  BAD  $desc"
    gates_bad=$((gates_bad + 1))
  fi
}

echo "=== BUG-041 negative control ==="
echo ""
echo "--- 1. patch the scratch copy ---"

cp "$SRC" "$SCRATCH/uart_core.sv"

python3 - "$SRC" "$SCRATCH/uart_core.sv" <<'PY'
import sys, difflib

src, dst = sys.argv[1], sys.argv[2]
t = open(src).read()

# The audited line: the only positional instantiation of this FIFO in the tree.
# Its fourth positional argument is OutputZeroIfEmpty = 1'b0.
old = "  caliptra_prim_fifo_sync #(8, 1'b0, 32, 1'b0) u_uart_rxfifo ("
# The corrected form: named parameters, OutputZeroIfEmpty left at the library
# default of 1'b1, matching u_uart_txfifo at :172-176.
new = ("  caliptra_prim_fifo_sync #(\n"
       "    .Width   (8),\n"
       "    .Pass    (1'b0),\n"
       "    .Depth   (32)\n"
       "  ) u_uart_rxfifo (")

assert t.count(old) == 1, f"expected exactly one positional instantiation, found {t.count(old)}"
assert "1'b0) u_uart_rxfifo" in old, "guard: the patched text must carry the OZIE=0 positional argument"

patched = t.replace(old, new)
open(dst, "w").write(patched)

# Size gate: exactly one line removed, five added. A patch that touched anything
# else would fail here rather than silently changing the experiment.
hunk = list(difflib.unified_diff(t.splitlines(), patched.splitlines(), lineterm="", n=0))
added   = [l for l in hunk if l.startswith("+") and not l.startswith("+++")]
removed = [l for l in hunk if l.startswith("-") and not l.startswith("---")]
print(f"patch_lines_added={len(added)}")
print(f"patch_lines_removed={len(removed)}")
assert len(added) == 5, f"expected 5 added lines, got {len(added)}"
assert len(removed) == 1, f"expected 1 removed line, got {len(removed)}"

# The audited source must still contain the defect afterwards.
assert "#(8, 1'b0, 32, 1'b0) u_uart_rxfifo" in open(src).read(), \
    "the audited source was modified -- it must not be"
print("audited_source_unmodified=yes")
PY

gate "grep -q '.Depth   (32)' '$SCRATCH/uart_core.sv'" \
     "the scratch copy now uses named parameters"
gate "! grep -q \"#(8, 1'b0, 32, 1'b0)\" '$SCRATCH/uart_core.sv'" \
     "the scratch copy no longer overrides OutputZeroIfEmpty"
gate "grep -q \"#(8, 1'b0, 32, 1'b0) u_uart_rxfifo\" '$SRC'" \
     "the audited source still contains the defect"
gate "test \$(grep -c 'u_uart_rxfifo' '$SCRATCH/uart_core.sv') -eq 1" \
     "the scratch copy still has exactly one rx FIFO instance"
echo ""

echo "--- 2. run the unmodified bench against the corrected RTL ---"

set +e
DUT_UART_CORE="$SCRATCH/uart_core.sv" \
BUILD_DIR="$HERE/../build_nc" \
LOG_DIR="$NCRUN" \
  bash "$HERE/run_bug_041_sim.sh" > "$NCRUN/negative_control_stdout.log" 2>&1
nc_rc=$?
set -e
echo "negative_control_exit_code=$nc_rc"

NC_SIM="$NCRUN/sim.log"
gate "test -f '$NC_SIM'" "the negative-control run produced a simulation log"
gate "test $nc_rc -eq 2" \
     "the corrected RTL yields the distinct signature-mismatch exit code (got $nc_rc)"
gate "grep -q '^result=NOT_THE_AUDITED_SIGNATURE' '$NC_SIM'" \
     "the bench reports NOT_THE_AUDITED_SIGNATURE on the corrected RTL"
gate "grep -q '^witness_hits=0' '$NC_SIM'" \
     "no residual is observed once the parameter takes its default"
gate "grep -q '^checks=7 fails=0' '$NC_SIM'" \
     "all 7 checks hold on the corrected RTL, so the bench is not simply failing"
echo ""

echo "--- 3. the controls still exercise the datapath ---"
gate "grep -q 'case=control_serial_byte_is_received_and_readable PASS' '$NC_SIM'" \
     "a real serial byte still arrives and reads back, so the fix did not break reception"
gate "grep -q 'case=control_second_byte_reads_back_as_itself PASS' '$NC_SIM'" \
     "a second, different byte still reads back as itself"
gate "grep -q 'case=control_status_reports_rxempty_after_drain PASS' '$NC_SIM'" \
     "STATUS still reports the FIFO empty after the drain"
gate "grep -q 'cov_byte_a=1 cov_byte_b=1' '$NC_SIM'" \
     "both received-byte covers are still hit on the corrected RTL"
echo ""

echo "--- 4. the audited run is unaffected ---"
gate "grep -q '^result=PASS' '$LOGS/sim.log'" \
     "the audited run in proof/logs/sim.log still reports PASS"
gate "grep -q '^checks=7 fails=3' '$LOGS/sim.log'" \
     "the audited run still shows 3 violating checks failing"
gate "grep -q '^witness_hits=1' '$LOGS/sim.log'" \
     "the audited run still observes the residual"
echo ""

rm -rf "$HERE/../build_nc"

echo "gates_ok=$gates_ok gates_bad=$gates_bad"
if [ "$gates_bad" -eq 0 ]; then
  echo "NEGATIVE CONTROL: PASS - correcting the parameter removes the behaviour"
  echo "result=PASS"
  exit 0
fi
echo "NEGATIVE CONTROL: FAIL - $gates_bad gate(s) did not hold"
echo "result=FAIL"
exit 1
