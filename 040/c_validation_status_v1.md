# C validation status — BUG-040

- **bug_id:** 040
- **module:** spi_host
- **status:** `not_software_addressable_in_this_tree`
- **defect site:** `src/spi_host/rtl/spi_host_reg_top.sv:2019-2020` (`control_we` qualifier)

## Why there is no C test

The block is not reachable from firmware in this tree, for two measured reasons
rather than one:

| # | What was measured | Value |
|---|---|---|
| 1 | `spi_host` instantiations in design files (`*/rtl/*`) | 0 |
| 2 | `spi_host` instantiations elsewhere in the tree | 1 — its own testbench, [spi_host_tb.sv:123](../../src/spi_host/tb/spi_host_tb.sv#L123) |
| 3 | `SPI_HOST` entries in the SoC software register map (`caliptra_reg.h`) | 0 |

With no instantiation in any design file there is no parent to attach the block's
AHB-Lite slave port to, and with no entry in
[caliptra_reg.h](../../src/integration/rtl/caliptra_reg/caliptra_reg.h) there is
no address a C test could store to. All three counts are computed by the
structural audit rather than asserted. Row 2 is the control on rows 1 and 3: the
pattern is required to find the testbench's instance, so a pattern that had
stopped matching would report zero there and fail its gate instead of making row
1 look like a finding.

This is a deliverable-block finding: `spi_host` ships with its own register
description, its own generated register file and its own published offsets, and
the defect is inside that deliverable. The proof is therefore stated at the
boundary the block actually presents.

## What replaces the C test

The directed simulation drives the block's own AHB-Lite slave port, which is the
same interface a core would drive through the SoC fabric. Nothing is forced,
nothing is referenced hierarchically, and the hardware-side inputs are held at
zero for the whole run, so no hardware path can be blamed for a `CONTROL` field
moving:

| Step | Address | Meaning |
|---|---|---|
| Configure normally | `0x10` | `SPI_HOST_CONTROL_OFFSET` ([spi_host_reg_pkg.sv:319](../../src/spi_host/rtl/spi_host_reg_pkg.sv#L319)) |
| The illegal write | `0x14` | `SPI_HOST_STATUS_OFFSET` ([spi_host_reg_pkg.sv:320](../../src/spi_host/rtl/spi_host_reg_pkg.sv#L320)), declared `swaccess: "ro"` |

Both are ordinary single-word bus writes. A C test on an integrated part would
issue exactly these two stores at the block's base address; the only thing it
would add is the fabric in between.

## Checked paths

| # | What is needed | Witness | Verified content |
|---|---|---|---|
| 1 | The enable admits a second address | [spi_host_reg_top.sv:2019](../../src/spi_host/rtl/spi_host_reg_top.sv#L2019) | `assign control_we = (~&{~addr_hit[4], ~addr_hit[5]}) &` |
| 2 | Its 12 siblings do not | [spi_host_reg_top.sv:1999](../../src/spi_host/rtl/spi_host_reg_top.sv#L1999) | `// Generate write-enables`, section using `addr_hit[N] & reg_we & !reg_error` |
| 3 | Index 5 is STATUS | [spi_host_reg_top.sv:1965](../../src/spi_host/rtl/spi_host_reg_top.sv#L1965) | `addr_hit[ 5] = (reg_addr == SPI_HOST_STATUS_OFFSET);` |
| 4 | STATUS is software-read-only | [spi_host.hjson:136](../../src/spi_host/data/spi_host.hjson#L136) | `swaccess: "ro"` (with `hwaccess: "hwo"` at `:137`) |
| 5 | STATUS is hardware-driven storage | [spi_host_reg_top.sv:582](../../src/spi_host/rtl/spi_host_reg_top.sv#L582) | `// R[status]: V(False)` |
| 6 | The countermeasure is fed a constant for it | [spi_host_reg_top.sv:2123](../../src/spi_host/rtl/spi_host_reg_top.sv#L2123) | `reg_we_check[5] = 1'b0;` |
| 7 | While CONTROL's own bit is live | [spi_host_reg_top.sv:2122](../../src/spi_host/rtl/spi_host_reg_top.sv#L2122) | `reg_we_check[4] = control_we;` |
| 8 | That vector is the integrity error | [spi_host_reg_top.sv:94](../../src/spi_host/rtl/spi_host_reg_top.sv#L94) | `assign intg_err_o = err_q \| reg_we_err;` |
| 9 | The read-only control case | [spi_host_reg_top.sv:2128](../../src/spi_host/rtl/spi_host_reg_top.sv#L2128) | `reg_we_check[10] = 1'b0;` — RXDATA, whose hit reaches no write-enable |
| 10 | All five fields share the enable | [spi_host_reg_top.sv:565](../../src/spi_host/rtl/spi_host_reg_top.sv#L565) | `.we (control_we)`, as at `:457`, `:484`, `:511`, `:538` |
| 11 | `sw_rst` takes the raw bus word | [spi_host_reg_top.sv:2028](../../src/spi_host/rtl/spi_host_reg_top.sv#L2028) | `assign control_sw_rst_wd = reg_wdata[30];` |

All eleven were dereferenced against the files in this tree at packaging time.

## Residual gap

Which agents can reach the block's AHB port is not answerable here, because the
block is not instantiated — see the residual uncertainty recorded in
[proof_result_v1.json](proof_result_v1.json). The availability effect of
`sw_rst` and `spien` is read from their consumers in
[spi_host.sv](../../src/spi_host/rtl/spi_host.sv) rather than simulated: the
proof establishes that the illegal write lands in `CONTROL` and that the
countermeasure stays silent, not the downstream SPI behaviour that follows.
