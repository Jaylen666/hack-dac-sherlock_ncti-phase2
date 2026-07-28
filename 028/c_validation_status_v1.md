# C validation status — BUG-028

- **bug_id:** 028
- **module:** keyvault
- **status:** `header_witness`

## Conclusion

The one input this defect needs is firmware-addressable through the generated
Caliptra register header: the destination slot comes from
`HMAC512_KV_WR_CTRL.WRITE_ENTRY`, a single MMIO field wide enough to encode slot
15. No new C test was compiled for this submission. The reachability claim rests on
the generated header plus the wrapper's own metric assignments; the behavioural
claim, that a standard-to-standard write into slot 15 is refused during OCP LOCK,
rests on the unit-level simulation and its negative control.

Note that reachability here means a legitimate firmware operation reaches the
defect and fails, not that an attacker reaches a protected asset. See the "Not
claimed" section.

## Checked paths

| Path | What it shows |
| --- | --- |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:962` | `CLP_HMAC_REG_BASE_ADDR = 0x10010000`, so the engine used in the witness sits in the MMIO map firmware can address. |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:1351` | `CLP_HMAC_REG_HMAC512_KV_WR_CTRL = 0x10010610`, the register selecting the KeyVault destination slot. |
| `src/integration/rtl/caliptra_reg/caliptra_reg_field_defines.svh:1069-1070` | `HMAC512_KV_WR_CTRL.WRITE_ENTRY` is bits 5:1, mask `0x3e`, so slot 15 is directly selectable by firmware. |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:1307` | `CLP_HMAC_REG_HMAC512_KV_RD_KEY_CTRL = 0x10010600`, the register that arms the forwarded source. |
| `src/integration/rtl/caliptra_reg/caliptra_reg_field_defines.svh:1027-1030` | `READ_EN` is bit 0 and `READ_ENTRY` is bits 5:1, so the standard-region source slot used in the witness is firmware-selected. |
| `src/hmac/rtl/hmac.sv:519` | `kv_write_metrics.kv_write_entry = kv_write_ctrl_reg.write_entry`, carrying the firmware-selected destination into the rule check unchanged. |
| `src/hmac/rtl/hmac.sv:515` | `kv_write_metrics.kv_data0_entry = kv_key_read_ctrl_reg.read_entry`, carrying the firmware-selected source slot. |
| `src/hmac/rtl/hmac.sv:534` | The wrapper instantiates `kv_write_rule_check` with those metrics, so the unit under test is the one on the firmware-reachable path. |
| `src/keyvault/rtl/kv_write_client.sv` | Consumes `write_allow`, so a withheld verdict means the KeyVault write does not occur rather than only a status bit changing. |

## Not claimed

No security claim is made here, and no C test was run against an integrated
Caliptra image. What the header establishes is that ordinary privileged firmware
can select slot 15 as a destination and will have that write refused during OCP
LOCK. It does not establish, and the accompanying simulation actively refutes, any
path by which OCP LOCK region data reaches the standard region through this defect:
slot 15 sits below `KV_OCP_LOCK_SLOT_LOW`, so `rule_fail.lock_to_lock` still
rejects a LOCK-sourced write targeting it. See `proof_result_v1.json` for the
containment result and the polarity argument that together set the severity.
