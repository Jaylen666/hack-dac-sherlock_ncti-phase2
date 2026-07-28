# C validation status — BUG-005

- **bug_id:** 005
- **module:** aes
- **status:** `header_witness`

## Conclusion

Every address the attack touches is firmware-reachable through the generated
Caliptra register header, at fixed MMIO offsets in the AES aperture. No new C
test was compiled for this submission: the software-reachability claim rests on
the generated header plus the RDL access qualifiers, and the behavioural claim
rests on the unit-level simulation and its negative control.

## Checked paths

| Path | What it shows |
| --- | --- |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:1514` | `CLP_AES_REG_BASE_ADDR = 0x10011000`, so the AES block sits in the MMIO map firmware can address. |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:1595` | `CLP_AES_REG_DATA_IN_0 = 0x10011054`, the first word the attacker reads. |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:1607` | `CLP_AES_REG_DATA_IN_3 = 0x10011060`, the last word, so the whole 128-bit window is exposed as four consecutive dwords. |
| `src/aes/data/aes.rdl:68` | The DATA_IN field is `sw = w`: write-only, no software read. This is the contract the RTL breaks. |
| `src/aes/data/aes.rdl:82` | `} DATA_IN[4] @ 0x54;` fixes the offsets that the header above reflects. |
| `src/aes/rtl/aes_reg_top.sv:720` | `u_data_in_0` is instantiated `SwAccess(caliptra_prim_subreg_pkg::SwAccessWO)` with `RESVAL (32'h0)`, so the generated declaration agrees with the RDL and disagrees with the read multiplexer in the same file. |
| `src/aes/rtl/aes_reg_top.sv:1503` | `addr_hit[21] = (reg_addr == AES_DATA_IN_0_OFFSET);` — the read is genuinely decoded, not dead code. |
| `src/aes/rtl/aes_control_fsm.sv:1013` | Loading the block clears only `data_in_new_q`, the tracking flag. The register contents survive the operation that consumes them. |
| `src/aes/rtl/aes_control_fsm.sv:836` and `src/aes/rtl/aes_core.sv:820-821` | The registers are overwritten with `prd_clearing_data` only in state `CTRL_CLEAR_I`, reached when software writes `KEY_IV_DATA_IN_CLEAR`. This bounds the exposure window and is stated as a scope limit rather than left implicit. |
| `src/integration/rtl/config_defines.svh:60` and `src/integration/rtl/caliptra_top.sv:1135-1147` | AES is attached to the internal AHB-lite responder fabric as `CALIPTRA_SLAVE_SEL_AES`, so the reachable adversary is software on the Caliptra core, not an external SoC master. This is why the CVSS vector uses `PR:H`. |
| `docs/CaliptraIntegrationSpecification.md` (OCP LOCK section) | "Firmware shall execute the clear operation after any AES operation used to generate or load the MEK" and "Firmware must clear any obfuscated MEK from memory immediately after use." The specification treats AES register residue as sensitive and assigns the clearing duty to firmware, which is the arrangement a read path on a write-only window undercuts. |
| `src/integration/test_suites/` | No existing smoke test in this tree writes DATA_IN and then reads those offsets back, so the condition is not covered by the current regression suite. |

## Rationale

The attack is four ordinary 32-bit MMIO reads at addresses that appear verbatim
in the generated firmware header. It needs no debug state, no scan mode, and no
external agent — only execution on the Caliptra core with access to the AES
aperture.

This is recorded as `header_witness` rather than `c_witness` as a choice about
evidence quality, not because reachability is in doubt. A full-SoC Verilator run
takes on the order of fifteen minutes and executes in ROM flow, where any
observation would be entangled with boot-stage state. The unit-level testbench
instead drives the register block directly over TL-UL, reconstructs the exact
128-bit block in microseconds of simulated time, and is paired with a negative
control proving the observation disappears once the file's own write-only read
treatment is
restored. A top-level pass/fail print could not have provided that
discrimination.

Two limits are worth stating plainly. The exposure lasts until firmware writes
the `KEY_IV_DATA_IN_CLEAR` trigger, so the claim is bounded to that interval
rather than asserted as permanent residue. And the asset recovered is the AES
input block, not the key; no key-recovery claim is made here.
