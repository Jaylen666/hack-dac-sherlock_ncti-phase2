# C validation status — BUG-016

- **bug_id:** 016
- **module:** hmac
- **status:** `header_witness`

## Conclusion

Every register this finding needs is firmware-addressable through the generated
Caliptra register header at fixed MMIO addresses in the HMAC aperture: the control
register carrying the ZEROIZE bit, the status register whose VALID bit returns to 1
after the wipe, and the tag register software then reads. No new C test was
compiled for this submission. The software-reachability claim rests on the
generated header; the behavioural claim, that `digest_valid_reg` survives a
zeroize and is never refreshed, rests on the unit-level simulation and its
negative control.

## Checked paths

| Path | What it shows |
| --- | --- |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:962` | `CLP_HMAC_REG_BASE_ADDR = 0x10010000`, so the HMAC block sits in the MMIO map firmware can address. |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:979` | `CLP_HMAC_REG_HMAC512_CTRL = 0x10010010`, the register carrying the ZEROIZE bit. |
| `src/integration/rtl/caliptra_reg/caliptra_reg_field_defines.svh:781-782` | `HMAC512_CTRL.ZEROIZE` is bit 2, mask `0x4`, so a single MMIO write triggers the sequence. |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:995` | `CLP_HMAC_REG_HMAC512_STATUS = 0x10010018`, the register whose VALID bit software polls. |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:1195` | `CLP_HMAC_REG_HMAC512_TAG_0 = 0x10010100`, the tag software reads once VALID reports ready. |
| `src/hmac/rtl/hmac.sv:259` | `zeroize_reg` is sourced from that control field, or from the debug-unlock/scan transition, so the trigger is software-reachable. |
| `src/hmac/rtl/hmac.sv:264` | `HMAC512_STATUS.VALID.next` is driven from `tag_valid_reg`, the bit the stale core value reloads. |

## What was verified behaviourally

The directed simulation (`proof/logs/sim.log`) stages a valid tag, asserts
zeroize, and observes `digest_valid_reg` still 1 while `hmac_ctrl_reg` and
`mode_reg` were both cleared by the same strobe, which proves zeroize reached the
DUT. After zeroize deasserts, `tag_valid` is still 1, and across 40 further idle
cycles `digest_valid_we` is never asserted, so the deferred refresh the RTL comment
relies on never happens. The reset arm of the same case statement does clear the
register, so it is clearable and the harness can observe it.

The negative control (`proof/logs/negative_control.log`) adds the single missing
assignment to the zeroize arm in a scratch copy. The same stimulus then drives
`tag_valid` to 0, both defect covers fall to 0 and three BUG-016 self-checks fail
with a nonzero exit, while the harness's own control observations still pass.

## Not claimed

The HMAC digest itself is not retained: the masked cores clear `H0..H7` on the same
strobe (`src/sha512_masked/rtl/sha512_masked_core.sv:297-316`), so the tag reads
zero. The finding is the false VALID indication, not retention of secret material.
No firmware sequence acting on that false indication was compiled or measured.
