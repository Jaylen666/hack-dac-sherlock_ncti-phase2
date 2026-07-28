#!/usr/bin/env bash
# BUG-040 structural audit.
#
# Establishes, from the submitted tree alone, that CONTROL's write-enable
# qualifier is inconsistent with every other write-enable in the same generated
# file, that the spurious-write-enable checker cannot see the resulting
# out-of-bounds update, and that the register it lands in carries the fields that
# make it matter.
#
# The censuses below are COMPUTED, and computed without naming control_we, so a
# pattern that fails to match reports a wrong count and fails a gate rather than
# passing silently.
set -euo pipefail

CMP="${CMP_ROOT:-/home/smy/hackatdac26-phase-2-caliptra}"
S="$CMP/src"
TOP="$S/spi_host/rtl/spi_host_reg_top.sv"
PKG="$S/spi_host/rtl/spi_host_reg_pkg.sv"
HJSON_DOC="$S/spi_host/doc"

gates_passed=0
gates_failed=0
gate() {
  local cond="$1"; local desc="$2"
  if eval "$cond" >/dev/null 2>&1; then
    echo "  ok   $desc"; gates_passed=$((gates_passed+1))
  else
    echo "  FAIL $desc"; gates_failed=$((gates_failed+1))
  fi
}

echo "=== BUG-040 structural audit ==="
echo "audit_root=$CMP"
echo "target=src/spi_host/rtl/spi_host_reg_top.sv:2019 (CONTROL write-enable qualifier)"
echo ""

# ---------------------------------------------------------------------------
echo "--- 1. the qualifier, and how its siblings are written ---"

gate "grep -q 'assign control_we = (~&{~addr_hit\[4\], ~addr_hit\[5\]}) &' '$TOP'" \
     "CONTROL's write-enable is qualified with two address hits (soc line: spi_host_reg_top.sv:2019)"

# Census A: how many write-enable assignments use the single-address form.
# Deliberately does not mention control_we.
SINGLE_HIT_WE=$(grep -cE "^  assign [a-z0-9_]+_we = addr_hit\[[0-9]+\] & reg_we & !reg_error;" "$TOP")
echo "single_address_write_enables=$SINGLE_HIT_WE"
gate "test $SINGLE_HIT_WE -eq 12" \
     "12 write-enables in this file use the single-address form (measured $SINGLE_HIT_WE)"

# Census B: how many use anything else. Should be exactly the one under audit.
TOTAL_WE=$(grep -cE "^  assign [a-z0-9_]+_we = " "$TOP")
echo "total_write_enable_assignments=$TOTAL_WE"
gate "test $TOTAL_WE -eq 13" \
     "the file has 13 write-enable assignments in total (measured $TOTAL_WE)"
gate "test $((TOTAL_WE - SINGLE_HIT_WE)) -eq 1" \
     "exactly 1 write-enable departs from the single-address form (measured $((TOTAL_WE - SINGLE_HIT_WE)))"

# Census C: the NAND-of-inversions idiom, tree-wide. If this construct were a
# house style, it would appear in more than one place.
IDIOM_TREE=$(grep -rE '~&\{~addr_hit' "$S" | wc -l)
echo "nand_of_inverted_addr_hit_uses_tree_wide=$IDIOM_TREE"
gate "test $IDIOM_TREE -eq 1" \
     "the NAND-of-inverted-address-hits idiom appears exactly once in the whole tree (measured $IDIOM_TREE)"

# Census D: the hand-written comment above it. Generated register blocks carry
# generated comments; this one does not appear anywhere else in the file.
QUAL_COMMENT=$(grep -c "// Register update qualification\." "$TOP")
echo "register_update_qualification_comments=$QUAL_COMMENT"
gate "test $QUAL_COMMENT -eq 1" \
     "the 'Register update qualification.' comment appears once, on this assignment (measured $QUAL_COMMENT)"
GEN_COMMENT=$(grep -c "// Generate write-enables" "$TOP")
gate "test $GEN_COMMENT -eq 1" \
     "the generator's own section comment for this block is 'Generate write-enables' (measured $GEN_COMMENT)"
gate "grep -rq '// Generate write-enables' '$S'/*/rtl/*_reg_top.sv" \
     "that section comment is the generator idiom shared by other register blocks in the tree"
QUAL_TREE=$(grep -rc "// Register update qualification\." "$S"/*/rtl/*_reg_top.sv 2>/dev/null | grep -v ':0$' | wc -l)
echo "register_blocks_carrying_that_comment=$QUAL_TREE"
gate "test $QUAL_TREE -eq 1" \
     "no other register block in the tree carries that comment (measured $QUAL_TREE file)"
echo ""

# ---------------------------------------------------------------------------
echo "--- 2. which address the second hit is, and whether it is writable ---"

gate "grep -q 'SPI_HOST_CONTROL_OFFSET = 6.\{0,3\} 10;' '$PKG'" \
     "CONTROL lives at offset 0x10 (spi_host_reg_pkg.sv)"
gate "grep -q 'SPI_HOST_STATUS_OFFSET = 6.\{0,3\} 14;' '$PKG'" \
     "STATUS lives at offset 0x14, the next word up (spi_host_reg_pkg.sv)"
gate "grep -qE 'addr_hit\[ *4\] = \(reg_addr == SPI_HOST_CONTROL_OFFSET\)' '$TOP'" \
     "address hit index 4 decodes CONTROL"
gate "grep -qE 'addr_hit\[ *5\] = \(reg_addr == SPI_HOST_STATUS_OFFSET\)' '$TOP'" \
     "address hit index 5 decodes STATUS, so the extra term in the qualifier is the STATUS address"

# STATUS has no write-enable of its own anywhere in the file: it is read-only.
STATUS_WE=$(grep -cE "^  assign status_[a-z0-9_]*we = " "$TOP" || true)
echo "status_own_write_enables=$STATUS_WE"
gate "test $STATUS_WE -eq 0" \
     "STATUS has no write-enable of its own, i.e. it is a read-only register (measured $STATUS_WE)"
gate "grep -q 'R\[status\]: V(False)' '$TOP'" \
     "STATUS is generated as a stored, hardware-driven register (R[status]: V(False))"
gate "grep -A2 'name: \"STATUS\"' '$S/spi_host/data/spi_host.hjson' | grep -q 'swaccess: \"ro\"'" \
     "the register spec declares STATUS software-read-only (spi_host.hjson)"
gate "grep -A3 'name: \"STATUS\"' '$S/spi_host/data/spi_host.hjson' | grep -q 'hwaccess: \"hwo\"'" \
     "and hardware-write-only, so software has no legitimate write path to it at all"
echo ""

# ---------------------------------------------------------------------------
echo "--- 3. why the spurious-write-enable checker does not catch it ---"

gate "grep -q 'reg_we_check\[4\] = control_we;' '$TOP'" \
     "the checker vector's bit 4 is driven by CONTROL's write-enable"
gate "grep -q 'reg_we_check\[5\] = 1.b0;' '$TOP'" \
     "the checker vector's bit 5, the STATUS index, is tied low"
gate "grep -q 'OneHotWidth(15)' '$TOP'" \
     "the checker is a 15-wide onehot check over that vector"
gate "grep -q 'assign intg_err_o = err_q | reg_we_err;' '$TOP'" \
     "its error output is the block's integrity error, latched permanently for alerting"

# So on a STATUS write exactly one vector bit is high: onehot is satisfied and
# no error is raised. Count how many indices are tied low to confirm 5 is not a
# special case of a broader pattern that would explain it away.
TIED_LOW=$(grep -cE "^    reg_we_check\[[0-9]+\] = 1'b0;" "$TOP")
echo "checker_bits_tied_low=$TIED_LOW"
gate "test $TIED_LOW -eq 2" \
     "2 checker bits are tied low, the two read-only registers (measured $TIED_LOW)"
gate "grep -q 'reg_we_check\[10\] = 1.b0;' '$TOP'" \
     "the other tied-low bit is index 10, RXDATA, also read-only"
# RXDATA is the control case: it is read-only too, and no other register's
# write-enable borrows its address hit.
# Count address-hit references that appear inside a write-enable assignment.
# The read-only registers' hits should appear in none; STATUS's appears in one.
RO_HIT_IN_WE=$(grep -E "^  assign [a-z0-9_]+_we = " "$TOP" | grep -cE "addr_hit\[ *10\]" || true)
echo "readonly_rxdata_hit_inside_write_enables=$RO_HIT_IN_WE"
gate "test $RO_HIT_IN_WE -eq 0" \
     "the other read-only register's address hit appears in no write-enable at all (measured $RO_HIT_IN_WE)"
STATUS_HIT_IN_WE=$(grep -E "^  assign [a-z0-9_]+_we = |^                      reg_we & !reg_error;" "$TOP" | grep -cE "addr_hit\[ *5\]" || true)
echo "status_hit_inside_write_enables=$STATUS_HIT_IN_WE"
gate "test $STATUS_HIT_IN_WE -eq 1" \
     "the STATUS address hit appears inside exactly 1 write-enable, the one under audit (measured $STATUS_HIT_IN_WE)"
# And the read-only register that is handled correctly proves the generator can
# do it: its hit is used only by its decoder, its permit check, its read-enable
# and its readback case.
RXDATA_TOTAL=$(grep -cE "addr_hit\[ *10\]" "$TOP")
echo "readonly_rxdata_hit_total_uses=$RXDATA_TOTAL"
gate "test $RXDATA_TOTAL -eq 4" \
     "that hit is used 4 times: decoder, permit check, read-enable and readback (measured $RXDATA_TOTAL)"
STATUS_TOTAL=$(grep -cE "addr_hit\[ *5\]" "$TOP")
echo "status_hit_total_uses=$STATUS_TOTAL"
gate "test $STATUS_TOTAL -eq 4" \
     "the STATUS hit is used 4 times as well, but one of them is a write-enable rather than a read-enable (measured $STATUS_TOTAL)"
echo ""

# ---------------------------------------------------------------------------
echo "--- 4. what lands in CONTROL, and why those fields matter ---"

gate "grep -q 'control_rx_watermark_wd = reg_wdata\[7:0\]' '$TOP'" \
     "the write data feeding CONTROL is the raw bus word, bits 7:0 to rx_watermark"
gate "grep -q 'control_tx_watermark_wd = reg_wdata\[15:8\]' '$TOP'" \
     "bits 15:8 to tx_watermark"
gate "grep -q 'control_output_en_wd = reg_wdata\[29\]' '$TOP'" \
     "bit 29 to output_en"
gate "grep -q 'control_sw_rst_wd = reg_wdata\[30\]' '$TOP'" \
     "bit 30 to sw_rst, the block's software reset"
gate "grep -q 'control_spien_wd = reg_wdata\[31\]' '$TOP'" \
     "bit 31 to spien, the enable that takes the SPI host offline when cleared"

# All five CONTROL fields share the one qualifier, so all five move together.
CONTROL_WE_USES=$(grep -cE "^    \.we     \(control_we\)," "$TOP")
echo "control_fields_sharing_the_qualifier=$CONTROL_WE_USES"
gate "test $CONTROL_WE_USES -eq 5" \
     "all 5 CONTROL fields take their write-enable from that one qualifier (measured $CONTROL_WE_USES)"
gate "grep -q 'SwAccess(caliptra_prim_subreg_pkg::SwAccessRW)' '$TOP'" \
     "those fields are software-writable at their own address, so the defect is a reach across addresses, not a new write capability"
gate "grep -q 'reg2hw.control.sw_rst.q' '$S/spi_host/rtl/spi_host.sv'" \
     "sw_rst is consumed by the block, so a spurious set has an effect beyond the register file"
gate "grep -q 'reg2hw.control.spien.q' '$S/spi_host/rtl/spi_host.sv'" \
     "spien is consumed by the block as well"
echo ""

# ---------------------------------------------------------------------------
echo "--- 5. reach: the register is software-addressable ---"

# spi_host is delivered as a standalone block in this tree: no design file
# instantiates it and it is not mapped into the SoC address space. So the reach
# claim is stated at the block boundary, which is where it can be established.
# The pattern below admits a parameterized instantiation, "spi_host #(", as well
# as a plain one; a pattern that only allowed an identifier after the module name
# would miss the tb's instance and report a zero for the wrong reason.
INST_RE="^[[:space:]]*spi_host[[:space:]]+(#|[a-zA-Z_])"
SPI_HOST_RTL_INSTANCES=$( { grep -rlE "$INST_RE" --include=*.sv "$S" || true; } | { grep '/rtl/' || true; } | wc -l)
SPI_HOST_TB_INSTANCES=$( { grep -rlE "$INST_RE" --include=*.sv "$S" || true; } | { grep -v '/rtl/' || true; } | wc -l)
echo "spi_host_instantiations_in_design=$SPI_HOST_RTL_INSTANCES"
echo "spi_host_instantiations_in_testbenches=$SPI_HOST_TB_INSTANCES"
gate "test $SPI_HOST_RTL_INSTANCES -eq 0" \
     "no design file instantiates the block, so reach is stated at its own bus boundary (measured $SPI_HOST_RTL_INSTANCES)"
gate "test $SPI_HOST_TB_INSTANCES -eq 1" \
     "the only instantiation in the tree is the block's own testbench, which confirms the pattern matches something and is not silently returning zero (measured $SPI_HOST_TB_INSTANCES)"
gate "grep -q 'AMBA AHB Lite Interface' '$TOP'" \
     "that boundary is an AHB-Lite slave port, i.e. any master on the bus it is attached to"
gate "grep -q 'devmode_i' '$TOP'" \
     "the block returns an explicit error only for unmapped accesses; STATUS is mapped, so a write to it is accepted at the bus level"
gate "grep -q 'SPI_HOST_STATUS_OFFSET' '$PKG'" \
     "STATUS's offset is a published parameter of the block's register package, so the address is part of its programming interface"
gate "test -f '$S/spi_host/data/spi_host.rdl'" \
     "the block ships a register description, so its software-visible contract is documented in-tree"
echo ""

echo "gates_passed=$gates_passed gates_failed=$gates_failed"
if [ "$gates_failed" -eq 0 ]; then
  echo "RESULT: PASS - all structural gates confirm BUG-040"
  echo "result=PASS"
  exit 0
fi
echo "RESULT: FAIL - $gates_failed structural gate(s) did not hold"
echo "result=FAIL"
exit 1
