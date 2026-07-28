# C validation status — BUG-018

- **bug_id:** 018
- **module:** hmac
- **status:** `header_witness`

## Conclusion

The single register write that triggers the FSM skip is firmware-addressable
through the generated Caliptra register header, at a fixed MMIO address in the
HMAC aperture, and both command bits live in that one register. No new C test was
compiled for this submission. The software-reachability claim rests on the
generated header and on the register wiring in `src/hmac/rtl/hmac.sv`; the
behavioural claim, that the FSM reaches CTRL_OPAD without visiting CTRL_IPAD,
rests on the unit-level simulation and its negative control.

## Checked paths

| Path | What it shows |
| --- | --- |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:962` | `CLP_HMAC_REG_BASE_ADDR = 0x10010000`, so the HMAC block is in the MMIO map firmware can address. |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:979` | `CLP_HMAC_REG_HMAC512_CTRL = 0x10010010`, the single register holding both the INIT and the NEXT command bit. |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:995` | `CLP_HMAC_REG_HMAC512_STATUS = 0x10010018`, which firmware polls for ready before the write. |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:1195` | `CLP_HMAC_REG_HMAC512_TAG_0 = 0x10010100`, where the resulting tag is read back. |
| `src/hmac/rtl/hmac.sv:251-252` | Both command fields share one `swwe = ready_reg`, so one write can set both. |
| `src/hmac/rtl/hmac.sv:257-258` | Both command signals are sourced from fields of that same register. |

## What was verified behaviourally

The directed simulation (`proof/logs/sim.log`) drives both commands for one cycle
from CTRL_IDLE and reads the FSM state register, recording that CTRL_IPAD was
never entered. The negative control (`proof/logs/negative_control.log`) shows the
FSM entering CTRL_IPAD once the two arms are chained, with `cover_ipad_skipped`
falling to 0 and three checks failing, while `cover_next_clears` continues to
fire, so the harness itself is intact.
