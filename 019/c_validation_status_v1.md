# C validation status — BUG-019

- **bug_id:** 019
- **module:** hmac
- **status:** `header_witness`

## Conclusion

Both registers this finding needs, the control register that issues INIT and the
tag register whose stale contents stay valid, are firmware-addressable through
the generated Caliptra register header at fixed MMIO addresses in the HMAC
aperture. No new C test was compiled for this submission. The
software-reachability claim rests on the generated header; the behavioural claim,
that `digest_valid_reg` survives an INIT, rests on the unit-level simulation and
its negative control.

## Checked paths

| Path | What it shows |
| --- | --- |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:962` | `CLP_HMAC_REG_BASE_ADDR = 0x10010000`, so the HMAC block is in the MMIO map firmware can address. |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:979` | `CLP_HMAC_REG_HMAC512_CTRL = 0x10010010`, whose INIT bit starts the operation that fails to invalidate the old result. |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:995` | `CLP_HMAC_REG_HMAC512_STATUS = 0x10010018`, the register a client polls for valid. |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:1195` | `CLP_HMAC_REG_HMAC512_TAG_0 = 0x10010100`, where the stale tag is read back. |
| `src/hmac/rtl/hmac_core.sv:111-112` | Both `tag` and `tag_valid` are derived from `digest_valid_reg`, so the stale bit is what exposes the old digest. |

## What was verified behaviourally

The directed simulation (`proof/logs/sim.log`) sets `digest_valid_reg` to stand in
for a completed prior operation, issues an INIT, and observes the bit still
asserted afterwards. The same run issues a NEXT and observes the bit clear, which
confirms the clear path works and isolates the defect to the init_cmd arm. The
negative control (`proof/logs/negative_control.log`) shows the bit clearing on
INIT once the missing enable is added, with `cover_stale_valid` falling to 0 and
the check failing, while `cover_next_clears` continues to fire.
