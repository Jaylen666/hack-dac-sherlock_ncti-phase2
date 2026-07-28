# BUG-041 — C-level validation status

**bug_id:** 041
**module:** uart
**status:** `not_software_addressable_in_this_tree`

## Summary

The defect is reachable only over the block's register interface, and in this tree
nothing drives that interface from software. No design file instantiates the `uart`
block, and no C header defines its register addresses. A C test for the block does
exist in the tree, but every UART symbol it references is undefined here and the
hardware-configuration field that gates it does not exist, so it cannot compile.
The proof therefore drives the block's own AHB-Lite slave port directly from a
SystemVerilog testbench, which is the same interface software would use and the
only one available in this tree.

This is not a weakness in the finding. The register-level behaviour is what the
defect is about, and the register description in
[uart.hjson](../../src/uart/data/uart.hjson) documents all three registers the
attack uses -- `STATUS.RXEMPTY` at
[uart.hjson:162](../../src/uart/data/uart.hjson#L162), `RDATA` at
[uart.hjson:168](../../src/uart/data/uart.hjson#L168), and `FIFO_CTRL.RXRST` at
[uart.hjson:200](../../src/uart/data/uart.hjson#L200) -- as software-facing. The
C test that exists in the tree independently confirms the intended software usage:
it polls `STATUS.RXEMPTY` and then reads `RDATA`, which is exactly the sequence the
proof drives and exactly the sequence the defect corrupts.

## Measurements

Each count was produced by grep over the submitted tree. Rows marked **control**
exist to prove the search pattern matches something: a pattern that silently
stopped matching would report zero for the wrong reason, so a wrong control count
fails loudly instead of passing quietly.

| # | measurement | count |
|---|---|---|
| 1 | design files (`*/rtl/*.sv`) instantiating the `uart` block | 0 |
| 2 | **control** on row 1 — non-design files instantiating it, i.e. [src/uart/tb/uart_tb.sv](../../src/uart/tb/uart_tb.sv) | 1 |
| 3 | `CLP_UART_*` register-address defines in `caliptra_reg.h` | 0 |
| 4 | **control** on row 3 — same pattern against a symbol known to be present, `CLP_SOC_IFC_REG_CPTRA_HW_CONFIG` | 2 |
| 5 | C tests in the tree targeting this block ([smoke_test_uart.c](../../src/integration/test_suites/smoke_test_uart/smoke_test_uart.c)) | 1 |
| 6 | of the 11 UART symbols that C test references, how many are defined anywhere in the tree | 0 |
| 7 | definitions of `UART_EN`, the config field that C test branches on, anywhere in the tree | 0 |

Row 2 is what makes rows 1 and 3 trustworthy. The pattern used for row 1 matches
both `uart u_name` and `uart #(`; it finds the testbench, so its zero for design
files is a real zero. Row 4 does the same job for row 3: the identical
`#define`-matching pattern returns 2 for a symbol that is present, so its zero for
the UART addresses is a real zero.

Rows 5 through 7 are the interesting part. The block has a C test, so software
addressability was clearly intended at some point, but the test is vestigial in
this tree: all 11 of the symbols it needs are absent, including the four register
addresses `CLP_UART_STATUS`, `CLP_UART_RDATA`, `CLP_UART_WDATA` and
`CLP_UART_CTRL`, the field masks it uses to decode status, and
`SOC_IFC_REG_CPTRA_HW_CONFIG_UART_EN_MASK`, which its own
`end_sim_if_uart_disabled()` reads before deciding whether to run at all.

## Paths checked

| path | result |
|---|---|
| `src/*/rtl/*.sv` — any design instantiation of the block | none |
| [src/uart/tb/uart_tb.sv](../../src/uart/tb/uart_tb.sv) | instantiates it; testbench only |
| `src/integration/rtl/caliptra_top.sv` | no mention of the block |
| `src/integration/tb/` | no mention of the block |
| `src/integration/config/*.vf` filelists | no mention of the block |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h` | no UART register addresses |
| `src/integration/rtl/caliptra_reg_ss/caliptra_reg.h` | no UART register addresses |
| `src/integration/test_suites/includes/caliptra_defines.h` | no UART symbols at all |
| [smoke_test_uart.c](../../src/integration/test_suites/smoke_test_uart/smoke_test_uart.c) | present; cannot compile in this tree (rows 6-7) |
| `UART_EN` field in any `.sv` / `.rdl` / `.svh` / `.h` | absent |

## What was driven instead

[proof/tb/uart_bug_041_tb.sv](proof/tb/uart_bug_041_tb.sv) instantiates one
unmodified `uart` top, connects only its ports, and drives real 8N1 serial frames
into `cio_rx_i`. All observation is over the AHB-Lite slave port using the
documented register offsets from
[uart_reg_pkg.sv:331-335](../../src/uart/rtl/uart_reg_pkg.sv#L331-L335) -- the same
offsets, and the same poll-status-then-read-RDATA idiom, that the tree's own C test
uses. Four of the seven checks are controls, including one requiring that new
serial traffic displaces the residue, so the disclosed value cannot be a fixed
number the read would return regardless.

## Residual gap

Because no C-level path exists in this tree, the proof does not demonstrate the
disclosure from compiled software running on the embedded core. It demonstrates it
at the register interface that software would use, driven over the block's own bus
port. If this block is integrated and its addresses exported in a configuration
not present here, the step from this proof to a C reproduction is writing
`FIFO_CTRL.RXRST` and reading `RDATA` at their documented offsets -- no additional
hardware condition is required, since the measurement shows the residue survives
draining, the documented FIFO reset, and a block reset.
