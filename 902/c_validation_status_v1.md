# C validation status — BUG-N-002

- **bug_id:** N-002
- **module:** sha512
- **status:** `header_witness`

## Conclusion

Every step of this defect is firmware-addressable through the generated Caliptra
register header, including the observation. Starting a PCR hash extend is one MMIO
write to `SHA512_VAULT_RD_CTRL`, raising the security erase is one MMIO write to
`SHA512_CTRL`, and the consequence is a plain read of
`SHA512_GEN_PCR_HASH_STATUS.READY`. No new C test was compiled for this submission,
but unlike a timing-level finding there is no gap between what the unit-level
witness measures and what firmware could see: the testbench drives the same
register bus at the same offsets and reads the same status bit a driver would poll.

The effect is also within a firmware polling loop's resolution, because it is not a
cycle-level difference. `src/sha512/rtl/sha512.sv:372` clears the residual bit only
on `pcr_hash_extend_ip & kv_dest_done`, and the vault completion it waits for
belongs to the transaction the erase cancelled, so the status bit stays low
indefinitely rather than for a bounded number of cycles. A driver that polls for
readiness before starting a PCR extend would hang.

Reachability here means ordinary privileged firmware reaches the defective
condition and its software-visible consequence through documented registers. It
does not mean firmware reaches a protected asset: see "Not claimed".

## Checked paths

| Path | What it shows |
| --- | --- |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:7130` | `CLP_SHA512_REG_BASE_ADDR = 0x10020000`, so the SHA-512 block sits in the MMIO map firmware can address. |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:7363` | `CLP_SHA512_REG_SHA512_VAULT_RD_CTRL = 0x10020600`, the register that starts the PCR hash extend and so raises the state that survives the erase. |
| `src/integration/rtl/caliptra_reg/caliptra_reg_field_defines.svh:5796` | `VAULT_RD_CTRL.READ_EN` is bit 0, one half of the set condition at `src/sha512/rtl/sha512.sv:371`. |
| `src/integration/rtl/caliptra_reg/caliptra_reg_field_defines.svh:5800` | `VAULT_RD_CTRL.PCR_HASH_EXTEND` is bit 6, the other half of that set condition. |
| `src/integration/rtl/caliptra_reg/caliptra_reg_field_defines.svh:5798` | `VAULT_RD_CTRL.READ_ENTRY` starts at bit 1, and `src/sha512/rtl/sha512.sv:257` latches it into `hash_extend_entry`, so firmware chooses the entry that outlives the erase. |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:7147` | `CLP_SHA512_REG_SHA512_CTRL = 0x10020010`, the register carrying the erase. |
| `src/integration/rtl/caliptra_reg/caliptra_reg_field_defines.svh:5636` | `SHA512_CTRL.ZEROIZE` is bit 4, so the erase is a single firmware write. |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:7461` | `CLP_SHA512_REG_SHA512_GEN_PCR_HASH_STATUS = 0x10020634`, the register firmware polls before starting a PCR extend. |
| `src/integration/rtl/caliptra_reg/caliptra_reg_field_defines.svh:5881` | `GEN_PCR_HASH_STATUS.READY` is bit 0, the bit that stays low after the erase. |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:7163` | `CLP_SHA512_REG_SHA512_STATUS = 0x10020018`, the block's own readiness register, read by the discriminator to show the block itself recovered. |
| `src/integration/rtl/caliptra_reg/caliptra_reg_field_defines.svh:5645` | `SHA512_STATUS.READY` is bit 0, which reads high after the erase while the PCR hash status does not. |
| `src/sha512/rtl/sha512.sv:335` | `GEN_PCR_HASH_STATUS.READY.next` is gated on `~pcr_hash_extend_ip`, which is the path from the residual internal bit to the register firmware reads. |
| `src/sha512/rtl/sha512.sv:284-286` | `zeroize_reg` is raised by `SHA512_CTRL.ZEROIZE` or `debugUnlock_or_scan_mode_switch`, so the erase is firmware-triggerable and also asserted on a debug or scan-mode boundary. |
| `src/sha512/rtl/sha512.sv:372` | The only non-reset clear needs `kv_dest_done`, so no firmware-reachable register write retires the residue. |

## Not claimed

- No C test was compiled or run for this submission. The register offsets and field
  positions above were read out of the generated header, and the unit-level witness
  drives exactly those offsets.
- No claim that firmware can read key-vault or PCR material as a result. The vault
  response ports are unmodelled in the witness, so the forced write enable at
  `src/sha512/rtl/sha512.sv:470` and the overridden destination entry at
  `src/sha512/rtl/sha512.sv:471` are reported from the RTL rather than observed.
- No claim that the erase fails as a whole. On the audited RTL the zeroize branch
  still clears eight registers, and `SHA512_STATUS.READY` still recovers, which the
  discriminator confirms.
- No claim about `SHA512_DIGEST`. Its hardware-clear at
  `src/sha512/rtl/sha512.sv:300` is driven from a separate signal that is the
  subject of a different finding, and it is excluded from this case.
