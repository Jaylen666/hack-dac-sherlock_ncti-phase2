#!/usr/bin/env bash
# BUG-041 structural audit.
#
# Every gate below is checked against the submitted tree on its own terms: the
# claim is that this RTL contradicts its own sibling instantiation, its own
# tree-wide idiom, and the software-visible contract its own register
# description publishes. Censuses are COMPUTED and are written so as not to name
# the audited signal, so a pattern that stopped matching reports a wrong count
# and fails a gate instead of passing silently.
set -euo pipefail

CMP="${CMP_ROOT:-/home/smy/hackatdac26-phase-2-caliptra}"
S="$CMP/src"

CORE="$S/uart/rtl/uart_core.sv"
FIFO="$S/caliptra_prim/rtl/caliptra_prim_fifo_sync.sv"
RTOP="$S/uart/rtl/uart_reg_top.sv"
PKG="$S/uart/rtl/uart_reg_pkg.sv"
HJSON="$S/uart/data/uart.hjson"

gates_passed=0
gates_failed=0
gate() {
  local cond="$1" desc="$2"
  if eval "$cond"; then
    echo "  ok   $desc"
    gates_passed=$((gates_passed + 1))
  else
    echo "  FAIL $desc"
    gates_failed=$((gates_failed + 1))
  fi
}

echo "=== BUG-041 structural audit ==="
echo ""

# ---------------------------------------------------------------------------
echo "--- 1. the audited instantiation and its form ---"

gate "grep -q \"caliptra_prim_fifo_sync #(8, 1'b0, 32, 1'b0) u_uart_rxfifo\" '$CORE'" \
     "the rx FIFO is instantiated with four positional parameters, the fourth being 1'b0"
gate "grep -q 'parameter bit OutputZeroIfEmpty     = 1.b1' '$FIFO'" \
     "the library's default for that fourth parameter is 1'b1"
gate "grep -q 'if == 1 always output 0 when FIFO is empty' '$FIFO'" \
     "the library documents that parameter as controlling whether the output is zeroed when empty"

# Census: how many instantiations of this FIFO exist, and how many are
# positional. Written without naming the audited instance.
TOTAL_FIFO=$( { grep -rn "caliptra_prim_fifo_sync #(" --include=*.sv "$S" || true; } \
              | { grep -v "rtl/caliptra_prim_fifo_sync" || true; } | wc -l)
POSITIONAL=$( { grep -rn "caliptra_prim_fifo_sync #( *[0-9]" --include=*.sv "$S" || true; } \
              | { grep -v "rtl/caliptra_prim_fifo_sync" || true; } | wc -l)
echo "fifo_sync_instantiations_in_tree=$TOTAL_FIFO"
echo "fifo_sync_positional_instantiations=$POSITIONAL"
gate "test $TOTAL_FIFO -ge 30" \
     "the FIFO is a widely used library cell, so its idiom is well established (measured $TOTAL_FIFO)"
gate "test $POSITIONAL -eq 1" \
     "exactly one instantiation in the whole tree passes parameters positionally (measured $POSITIONAL)"
echo ""

# ---------------------------------------------------------------------------
echo "--- 2. the sibling in the same file disagrees ---"

# The tx FIFO is 100 lines above the rx FIFO in the same module, same file,
# same author, and takes the default.
gate "grep -q 'u_uart_txfifo' '$CORE'" \
     "the same module instantiates a second FIFO of the same library cell"
gate "grep -q '.Width   (8),' '$CORE'" \
     "that sibling passes its parameters by name"
# Take only the FIRST such range, so the audited instance further down the file
# cannot leak into what is supposed to be the sibling's parameter list. A plain
# sed range restarts on every match and would include it.
TX_BLOCK=$(awk '/caliptra_prim_fifo_sync #\(/{inb=1} inb{print} /u_uart_txfifo/{exit}' "$CORE")
gate "! echo \"\$TX_BLOCK\" | grep -q 'OutputZeroIfEmpty'" \
     "the sibling does not override OutputZeroIfEmpty, so it takes the documented default"
gate "echo \"\$TX_BLOCK\" | grep -q 'u_uart_txfifo'" \
     "the extracted block really is the sibling's, so the gate above is not passing on empty text"
gate "test \$(grep -c 'u_uart_rxfifo' '$CORE') -eq 1" \
     "there is exactly one rx FIFO instance, so the finding is not ambiguous about which"
echo ""

# ---------------------------------------------------------------------------
echo "--- 3. why this instance is different from the others that set it to 0 ---"

# Other instances do set the parameter to 0. The distinguishing fact is not the
# value, it is that this one's output reaches a software-readable register.
OZIE_ZERO=$( { grep -rn "OutputZeroIfEmpty *( *1'b0" --include=*.sv "$S" || true; } | wc -l)
echo "named_ozie_zero_instances=$OZIE_ZERO"
gate "test $OZIE_ZERO -ge 1" \
     "other instances do set that parameter to zero, so the value alone is not the finding (measured $OZIE_ZERO)"
gate "grep -q '.rdata_o (uart_rdata)' '$CORE'" \
     "the audited instance's read data leaves the FIFO on a named signal"
gate "grep -q 'assign hw2reg.rdata.d = uart_rdata;' '$CORE'" \
     "that signal is assigned directly to a register field's hardware-to-software input"
gate "grep -q 'UART_RDATA_OFFSET' '$PKG'" \
     "that field belongs to a register with a published software offset"
echo ""

# ---------------------------------------------------------------------------
echo "--- 4. the readback path is ungated ---"

gate "grep -q 'reg_rdata_next\[7:0\] = rdata_qs;' '$RTOP'" \
     "the register block returns the field's stored value on readback with no empty-condition qualifier"
gate "grep -q 'assign rdata_re = addr_hit\[6\] & reg_re & !reg_error;' '$RTOP'" \
     "the read strobe is qualified only by address and bus validity, not by whether data is present"
gate "grep -q '.d      (hw2reg.rdata.d)' '$RTOP'" \
     "the field is an external subreg fed straight from the hardware input"
echo ""

# ---------------------------------------------------------------------------
echo "--- 5. software is simultaneously told the FIFO is empty ---"

gate "grep -qE 'assign hw2reg\.status\.rxempty\.d +=  *~rx_fifo_rvalid;' '$CORE'" \
     "the same module reports emptiness to software from the FIFO's own valid signal"
gate "grep -q 'name: \"RXEMPTY\"' '$HJSON'" \
     "that bit is a documented field of the status register"
gate "grep -q 'UART_STATUS_OFFSET' '$PKG'" \
     "the status register has a published software offset, so both facts are readable by the same agent"
echo ""

# ---------------------------------------------------------------------------
echo "--- 6. neither software-visible clear removes the data ---"

gate "grep -q 'parameter int unsigned resetOnClear = 0' '$FIFO'" \
     "the library's clear-the-storage behaviour is off by default"
gate "! grep -q \"resetOnClear\" '$CORE'" \
     "the audited instance does not enable it, so its documented clear does not wipe storage"
gate "grep -q '.clr_i   (uart_fifo_rxrst)' '$CORE'" \
     "the clear input is nevertheless wired to the software-writable FIFO reset"
gate "grep -q 'name: \"RXRST\"' '$HJSON'" \
     "that reset is a documented software control, i.e. the mechanism software is given to clear the FIFO"
# The storage flops themselves: a bare posedge block with no reset branch.
gate "grep -q 'gen_depth_gt1_no_reset' '$FIFO'" \
     "the storage array has a no-reset variant, which is the one selected here"
STORAGE_BLOCK=$(sed -n '/gen_depth_gt1_no_reset/,/^    end$/p' "$FIFO")
gate "echo '$STORAGE_BLOCK' | grep -q 'always_ff @(posedge clk_i)$'" \
     "in that variant the storage flops are clocked with no reset in their sensitivity list"
gate "! echo '$STORAGE_BLOCK' | grep -q 'rst_ni'" \
     "so a block reset does not clear received payload either"
echo ""

# ---------------------------------------------------------------------------
echo "--- 7. reach: the register is software-addressable ---"

INST_RE="^[[:space:]]*uart[[:space:]]+(#|[a-zA-Z_])"
UART_RTL_INST=$( { grep -rlE "$INST_RE" --include=*.sv "$S" || true; } | { grep '/rtl/' || true; } | wc -l)
UART_OTHER_INST=$( { grep -rlE "$INST_RE" --include=*.sv "$S" || true; } | { grep -v '/rtl/' || true; } | wc -l)
echo "uart_instantiations_in_design=$UART_RTL_INST"
echo "uart_instantiations_elsewhere=$UART_OTHER_INST"
gate "test $((UART_RTL_INST + UART_OTHER_INST)) -ge 1" \
     "the pattern finds at least one instantiation, so a zero below would be a real absence and not a regex miss (measured $((UART_RTL_INST + UART_OTHER_INST)))"
gate "grep -q 'AMBA AHB Lite Interface' '$S/uart/rtl/uart.sv'" \
     "the block presents an AHB-Lite slave port, so its registers are reachable by any master on that bus"
gate "test -f '$S/uart/data/uart.hjson'" \
     "the block ships a register description, so its software-visible contract is documented in-tree"
gate "grep -q 'swaccess: \"ro\"' '$HJSON'" \
     "that description marks read-only registers, i.e. it defines a software-visible contract to violate"
echo ""

echo "gates_passed=$gates_passed gates_failed=$gates_failed"
if [ "$gates_failed" -eq 0 ]; then
  echo "RESULT: PASS - all structural gates confirm BUG-041"
  echo "result=PASS"
  exit 0
fi
echo "RESULT: FAIL - $gates_failed structural gate(s) did not hold"
echo "result=FAIL"
exit 1
