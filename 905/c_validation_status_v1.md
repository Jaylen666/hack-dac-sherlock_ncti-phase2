# C validation status — BUG-N-005

- **bug_id:** N-005
- **module:** pcrvault
- **status:** `software_reachable_not_exercised_in_c`
- **defect site:** `src/pcrvault/rtl/pv_reg.rdl:29-30` (the lock field's `resetsignal`)

## Every step of this attack is an ordinary load or store

Unlike a JTAG-side or SoC-side finding, nothing here needs an external agent.
All three steps of the sequence are plain firmware accesses to registers the core
can reach:

| Step | Address | Symbol |
|---|---|---|
| Set the lock on entry 7 | `0x1001a01c` | [caliptra_reg.h:3917](../../src/integration/rtl/caliptra_reg/caliptra_reg.h#L3917) `CLP_PV_REG_PCR_CTRL_0` + `4*7` |
| Trigger the microcontroller-only reset | `0x30030624` | [caliptra_reg.h:11743](../../src/integration/rtl/caliptra_reg/caliptra_reg.h#L11743) `CLP_SOC_IFC_REG_INTERNAL_FW_UPDATE_RESET` |
| Clear the still-populated entry | `0x1001a01c` | same `PCR_CTRL[7]`, `clear` bit |
| Read back the zeroed measurement | `0x1001a6a8` | [caliptra_reg.h:4301](../../src/integration/rtl/caliptra_reg/caliptra_reg.h#L4301) `CLP_PV_REG_PCR_ENTRY_0_0` + `4*(7*12)` |

The middle step is the one that carries the attack, and it is explicitly a
firmware operation. `internal_fw_update_reset.core_rst` is declared `sw = rw`
with `swwel = soc_req`
([soc_ifc_internal_reg.rdl:45](../../src/soc_ifc/rtl/soc_ifc_internal_reg.rdl#L45)),
so the SoC is excluded from writing it and firmware is not — this is a firmware
capability specifically. The in-tree description of the reset window says the same
thing in prose: "the firmware reset request is triggered by software"
([integration.md:1125](../../src/integration/config/integration.md#L1125)).

## Why the proof is at RTL rather than in C

The property in question is which reset domain one register field lives in. A C
test would observe the consequence, but it would observe it through two layers
that are not what is being claimed: the boot FSM's timing of `cptra_uc_rst_b`,
and firmware's own survival across a reset it triggers on itself. Because the
microcontroller is reset, a single C program cannot straddle the event — the
before and after readings would have to be stitched together across a reboot
through a status register or a memory location that itself survives, and any
discrepancy in that carrier would be indistinguishable from the finding.

The directed simulation instead drives the module's `core_only_rst_b` port
directly and reads the lock and the entry over the same AHB bus in one continuous
timeline. The reset it applies is the same signal the boot FSM produces, and the
audit's gate 3 establishes that firmware reaches that signal. Splitting the
proof this way keeps the measured claim narrow — one reset pulse, two register
reads — while the reachability leg is settled structurally.

## Checked paths

| # | What is needed | Witness | Verified content |
|---|---|---|---|
| 1 | The lock's reset domain is the microcontroller-only reset | [pv_reg.rdl:30](../../src/pcrvault/rtl/pv_reg.rdl#L30) | `sw=rw; swwel=true; hw=r; resetsignal = core_only_rst_b;` |
| 2 | The protected data's is not | [pv_reg.rdl:22](../../src/pcrvault/rtl/pv_reg.rdl#L22) | `sw=r; hw=rw; we=true; hwclr; resetsignal = hard_reset_b;` |
| 3 | The generated flop implements it | [pv_reg.sv:163-169](../../src/pcrvault/rtl/pv_reg.sv#L163-L169) | lock storage clocked with `negedge hwif_in.core_only_rst_b`, resetting to `1'h0` |
| 4 | The module input is not a top-level pin | [caliptra_top.sv:1226](../../src/integration/rtl/caliptra_top.sv#L1226) | `.core_only_rst_b (cptra_uc_rst_b),` — an internal signal |
| 5 | The boot FSM produces it | [soc_ifc_boot_fsm.sv:97](../../src/soc_ifc/rtl/soc_ifc_boot_fsm.sv#L97) | `arc_BOOT_DONE_BOOT_FWRST = (boot_fsm_ps == BOOT_DONE) & fw_update_rst;` |
| 6 | A register drives that arc | [soc_ifc_top.sv:334](../../src/soc_ifc/rtl/soc_ifc_top.sv#L334) | `.fw_update_rst (…internal_fw_update_reset.core_rst.value)` |
| 7 | Firmware may write that field | [soc_ifc_internal_reg.rdl:45](../../src/soc_ifc/rtl/soc_ifc_internal_reg.rdl#L45) | `hw = r; sw = rw; singlepulse=true; swwel = soc_req;` |
| 8 | The lock is the only gate on the clear | [pv.sv:110-111](../../src/pcrvault/rtl/pv.sv#L110-L111) | lock value feeds `swwel` of both `lock` and `clear` |
| 9 | The clear reaches the measurement | [pv.sv:130](../../src/pcrvault/rtl/pv.sv#L130) | `PCR_ENTRY[entry][dword].data.hwclr = …PCR_CTRL[entry].clear.value` |
| 10 | An in-tree statement forbids the clear | [pcrvault.md:6](../../src/pcrvault/config/pcrvault.md#L6) | "The lock bit is sticky and only resets on a powergood cycle." |

All ten were dereferenced against the files in this tree at packaging time.

## Residual gap

Two things are argued rather than executed. The firmware write to
`INTERNAL_FW_UPDATE_RESET.core_rst` is traced structurally to the boot FSM output
that the simulation drives, not issued from a C program. And re-extending the
cleared entry with attacker-chosen values is not measured at all: the PCR vault's
single hardware write client is the SHA-512 hash-extend path, and driving a
complete extend sequence is outside a `pv` module-boundary measurement. This case
claims the clear, which is already sufficient to break the attested measurement
chain; it does not claim a completed quote forgery.
