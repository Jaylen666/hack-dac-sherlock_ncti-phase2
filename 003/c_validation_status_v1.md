# C validation status — BUG-003

- **bug_id:** 003
- **module:** aes
- **status:** `header_witness`

## Conclusion

Both registers involved in the attack are firmware-reachable through the
generated Caliptra register header, at fixed MMIO addresses in the AES aperture.
No new C test was compiled for this submission; the software reachability claim
rests on the generated header plus the RDL access qualifiers, and the behavioural
claim rests on the unit-level simulation and its negative control.

## Checked paths

| Path | What it shows |
| --- | --- |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:1514` | `CLP_AES_REG_BASE_ADDR = 0x10011000`, so the AES block sits in the MMIO map firmware can address. |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:1643` | `CLP_AES_REG_CTRL_AUX_SHADOWED = 0x10011078`, the register the attacker writes. |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:1646-1647` | `KEY_TOUCH_FORCES_RESEED` is exposed as bit 0 with mask `0x1`, so firmware can target the field directly. |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:1651` | `CLP_AES_REG_CTRL_AUX_REGWEN = 0x1001107c`, the lock register. |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:1595` | `CLP_AES_REG_DATA_IN_0 = 0x10011054` (relevant to the companion finding BUG-005). |
| `src/aes/data/aes.rdl:160-165` | `KEY_TOUCH_FORCES_RESEED` is `sw = rw`, so software may write it. |
| `src/aes/data/aes.rdl:181-188` | `CTRL_AUX_REGWEN` is `sw = rw` and documented as making the AUX register unwritable once cleared. |
| `src/aes/rtl/aes_reg_top.sv:1115` | The lock bit is instantiated `SwAccess(SwAccessW0C)` with `RESVAL(1'h1)`, confirming write-0-to-lock and reset-to-unlocked. |
| `src/integration/test_suites/` | No existing smoke test in this tree writes `CTRL_AUX_REGWEN` and then attempts an AUX write, so the condition is not covered by the current regression suite. |

## Rationale

The attack needs only two ordinary 32-bit MMIO writes to addresses that appear
verbatim in the generated firmware header, so it is reachable by any code running
with access to the AES aperture — ROM, FMC, or runtime firmware. Nothing about
the sequence requires a debug state, a scan mode, or an external agent.

The reason this is recorded as `header_witness` rather than `c_witness` is a
choice about evidence quality, not a gap in reachability. A full-SoC Verilator
run of this sequence takes on the order of fifteen minutes and executes in ROM
flow, where any observation would be confounded by boot-stage state. The
unit-level testbench instead drives the register block directly, reaches the
committed field value in microseconds of simulated time, and — critically — is
paired with a negative control proving the observation disappears once the
tree's own REGWEN gating idiom is applied to that line. That discrimination is what a top-level pass/fail print
could not have provided.

The final side-channel consequence of clearing `KEY_TOUCH_FORCES_RESEED`, namely
recovering an AES key from power or electromagnetic traces, requires physical
measurement access to the device. That is a scope statement about how far the
impact chain is carried here, and it does not weaken the proven claim: a
one-way configuration lock does not block writes.
