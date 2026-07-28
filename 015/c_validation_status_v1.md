# BUG-015 C validation status

**Bug:** `hmac_zeroize_leaves_tag_validity_flag_asserted`
**Defect site:** `src/hmac/rtl/hmac_core.sv:190`
**Status:** `header_witness`

## What this means

No new C test was written for this bug. The proof is a directed RTL simulation of one
unmodified `hmac_core` plus a scripted structural audit and a patched-copy negative
control, all three of which pass. What a C test would add here is only the demonstration
that the two software-side steps of the attack flow, issuing the zeroize and then reading
the status and tag registers, are ordinary MMIO accesses available to software. That
reachability is established instead from the generated register header in this tree, which
is the same artifact firmware compiles against, so every address and bit position below is
a witness taken from the design rather than an assumption.

The RTL-side consequence does not depend on software at all. The parent's spurious tag
capture (`src/hmac/rtl/hmac.sv:163`) fires from the zeroize strobe itself, with no polling
required, and that edge is measured in `proof/logs/sim.log` by recomputing the parent's own
expression against the real core output.

## Checked paths

| # | What is needed | Witness | Verified content |
|---|---|---|---|
| 1 | The block is at a fixed MMIO base software can reach | [caliptra_reg.h:962](../../src/integration/rtl/caliptra_reg/caliptra_reg.h#L962) | `CLP_HMAC_REG_BASE_ADDR` = `0x10010000` |
| 2 | The control register carrying the zeroize strobe is addressable | [caliptra_reg.h:979](../../src/integration/rtl/caliptra_reg/caliptra_reg.h#L979) | `CLP_HMAC_REG_HMAC512_CTRL` = `0x10010010` |
| 3 | The zeroize field's bit position within it | [caliptra_reg.h:986](../../src/integration/rtl/caliptra_reg/caliptra_reg.h#L986) | `HMAC_REG_HMAC512_CTRL_ZEROIZE_LOW` = `2` |
| 4 | The zeroize field's mask, so a single write suffices | [caliptra_reg.h:987](../../src/integration/rtl/caliptra_reg/caliptra_reg.h#L987) | `HMAC_REG_HMAC512_CTRL_ZEROIZE_MASK` = `0x4` |
| 5 | That field actually drives the strobe in RTL | [hmac.sv:259](../../src/hmac/rtl/hmac.sv#L259) | `zeroize_reg` assigned from `hwif_out.HMAC512_CTRL.ZEROIZE.value` |
| 6 | The strobe reaches the audited core | [hmac.sv:171](../../src/hmac/rtl/hmac.sv#L171) | `.zeroize(zeroize_reg)` on the `hmac_core` instance |
| 7 | The status register software polls is addressable | [caliptra_reg.h:995](../../src/integration/rtl/caliptra_reg/caliptra_reg.h#L995) | `CLP_HMAC_REG_HMAC512_STATUS` = `0x10010018` |
| 8 | The valid bit's position within status | [caliptra_reg.h:1000](../../src/integration/rtl/caliptra_reg/caliptra_reg.h#L1000) | `HMAC_REG_HMAC512_STATUS_VALID_LOW` = `1` |
| 9 | The valid bit's mask | [caliptra_reg.h:1001](../../src/integration/rtl/caliptra_reg/caliptra_reg.h#L1001) | `HMAC_REG_HMAC512_STATUS_VALID_MASK` = `0x2` |
| 10 | The tag the spurious capture writes is software-readable | [caliptra_reg.h:1195](../../src/integration/rtl/caliptra_reg/caliptra_reg.h#L1195) | `CLP_HMAC_REG_HMAC512_TAG_0` = `0x10010100` |
| 11 | The hardware clear the spurious capture defeats | [hmac.sv:267](../../src/hmac/rtl/hmac.sv#L267) | `TAG.hwclr` driven by `zeroize_reg` |

All eleven were dereferenced against the files in this tree at packaging time.

## What a C test would and would not add

It would add an end-to-end firmware sequence performing steps 1 through 5 of the attack
flow in `submission_v1.json` and reading back a set `VALID` bit after a zeroize. It would
not strengthen the core claim, which is that the zeroize arm at
[hmac_core.sv:190-196](../../src/hmac/rtl/hmac_core.sv#L190-L196) omits an assignment its
own reset arm makes at [hmac_core.sv:185](../../src/hmac/rtl/hmac_core.sv#L185), that both
module outputs depend on that register
([hmac_core.sv:111-112](../../src/hmac/rtl/hmac_core.sv#L111-L112)), and that the refresh
the arm's comment promises never occurs while idle. Those are settled by the audit and the
simulation, and the negative control shows the verdict flips when the single missing
assignment is added.

## Residual gap

The register addresses above are cited from the generated header rather than exercised by a
running firmware image, so this submission does not enumerate which existing firmware
sequences issue a zeroize and then read the tag. The block-level consequence is measured;
the integration-level exposure is argued from the address map.
