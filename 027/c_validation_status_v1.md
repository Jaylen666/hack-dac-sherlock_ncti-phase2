# C validation status — BUG-027

- **bug_id:** 027
- **module:** keyvault
- **status:** `header_witness`

## Conclusion

Both inputs the attack needs are firmware-addressable through the generated Caliptra
register header, and the audited RTL wires them to the rule check without any
intervening software-invisible qualification. The destination slot comes from
`HMAC512_KV_WR_CTRL.WRITE_ENTRY` and the forwarded-source condition comes from
`HMAC512_KV_RD_KEY_CTRL.READ_EN`, both single MMIO fields in the HMAC aperture. No
new C test was compiled for this submission. The software-reachability claim rests
on the generated header plus the wrapper's own metric assignments; the behavioural
claim, that `write_allow` is granted for a non-AES writer targeting KV23, rests on
the unit-level simulation and its negative control.

## Checked paths

| Path | What it shows |
| --- | --- |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:962` | `CLP_HMAC_REG_BASE_ADDR = 0x10010000`, so the non-AES engine used in the witness sits in the MMIO map firmware can address. |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:1351` | `CLP_HMAC_REG_HMAC512_KV_WR_CTRL = 0x10010610`, the register selecting the KeyVault destination slot. |
| `src/integration/rtl/caliptra_reg/caliptra_reg_field_defines.svh:1069-1070` | `HMAC512_KV_WR_CTRL.WRITE_ENTRY` is bits 5:1, mask `0x3e`, wide enough to encode slot 23, so software picks the release slot directly. |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:1307` | `CLP_HMAC_REG_HMAC512_KV_RD_KEY_CTRL = 0x10010600`, the register that arms the forwarded KeyVault source. |
| `src/integration/rtl/caliptra_reg/caliptra_reg_field_defines.svh:1027-1030` | `READ_EN` is bit 0, mask `0x1`, and `READ_ENTRY` is bits 5:1, mask `0x3e`, so one MMIO write both asserts forwarding and selects the source slot. |
| `src/hmac/rtl/hmac.sv:368` | `kv_key_data_present_set = kv_key_read_ctrl_reg.read_en`, so the software-written `READ_EN` bit is what raises the present flag. |
| `src/hmac/rtl/hmac.sv:514` | `kv_write_metrics.kv_data0_present = kv_key_data_present`, carrying that flag into the rule check as the term the finding turns on. |
| `src/hmac/rtl/hmac.sv:515` | `kv_write_metrics.kv_data0_entry = kv_key_read_ctrl_reg.read_entry`, so the forwarded source slot is the one software selected. |
| `src/hmac/rtl/hmac.sv:519` | `kv_write_metrics.kv_write_entry = kv_write_ctrl_reg.write_entry`, so the destination slot is the one software selected. |
| `src/hmac/rtl/hmac.sv:518` | `kv_write_metrics.kv_write_src = 1 << KV_WRITE_IDX_HMAC`, a hardwired non-AES writer identity, so the attacker does not need to spoof it. |
| `src/hmac/rtl/hmac.sv:520` | `kv_write_metrics.aes_decrypt_ecb_op = 1'b0` in this wrapper, matching the witness stimulus exactly. |
| `src/hmac/rtl/hmac.sv:534` | The wrapper instantiates `kv_write_rule_check` with those metrics, so the unit under test is the one on the firmware-reachable path. |
| `src/keyvault/rtl/kv_write_client.sv` | Consumes `write_allow`, so the granted verdict gates a real KeyVault write rather than only a status bit. |

## Reachability note

`src/hmac/rtl/hmac.sv:336-337` gates the `READ_EN` and `READ_ENTRY` fields with
`swwe = !kv_key_data_present && !busy_o`, so those fields are writable before the
operation starts and are then held stable. That is a sequencing constraint on when
firmware programs the register, not a restriction on the values it may program, so
it does not block the sequence in `exploit_or_attack_flow`.

## Not claimed

No C test was run against an integrated Caliptra image, so nothing here asserts an
end-to-end firmware exploit or a measured key release over AXI. The claim is
narrower and is what the evidence supports: the two inputs that turn the rule off
are software-writable MMIO fields, and on the unit under test that combination
grants the write.
