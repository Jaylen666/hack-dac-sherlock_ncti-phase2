# C validation status — BUG-017

- **bug_id:** 017
- **module:** hmac
- **status:** `header_witness`

## Conclusion

The registers that make the weak seed reachable and reusable from software are
firmware-addressable through the generated Caliptra register header, at fixed
MMIO addresses in the HMAC aperture. No new C test was compiled for this
submission. The software-reachability claim rests on the generated header; the
behavioural claim, that the masking seed loses its hardware component, rests on
the unit-level simulation and its negative control.

A C test is a poor fit for this finding specifically: the defect is the
predictability of an internal masking seed, which no MMIO read exposes. Observing
it from software would require side-channel measurement equipment rather than a
firmware test. The simulation observes the internal signals directly instead.

## Checked paths

| Path | What it shows |
| --- | --- |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:962` | `CLP_HMAC_REG_BASE_ADDR = 0x10010000`, so the HMAC block sits in the MMIO map firmware can address. |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:1259` | `CLP_HMAC_REG_HMAC512_LFSR_SEED_0 = 0x10010140`, the register that becomes the sole masking seed. |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:979` | `CLP_HMAC_REG_HMAC512_CTRL = 0x10010010`, the register whose INIT bit reseeds the LFSRs on every operation. |
| `src/hmac/rtl/hmac.sv:311` | The LFSR seed the core uses is taken straight from that software-written register. |
| `src/hmac/rtl/hmac_core.sv:166` | `seed_en_i(init_cmd)`, so the seed is reapplied on every INIT rather than once per boot. |

## What was verified behaviourally

The directed simulation (`proof/logs/sim.log`) samples the H2 start strobes on
every cycle of the CTRL_IPAD window and finds neither ever asserted, while
confirming H1 is started in that same window. It then reads the value
`set_entropy` latched and compares `lfsr_entropy` against the seed the testbench
wrote. The negative control (`proof/logs/negative_control.log`) shows all three
observations invert once H2 is started from the file's own first_round arm, while
the H1 control check still passes.
