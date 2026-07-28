# c_validation_status — kv_bug_025

- **bug_id:** kv_bug_025
- **module:** keyvault
- **status:** no_witness

## Conclusion

No software-visible witness exists, and none is expected: the case resolved to
`false_alarm`, so there is no software-observable violation to demonstrate.

The relevant negative result is itself part of the disproof. Software cannot
reach the signal the alleged bypass depends on. `kv_read_dest` is not exposed by
any register: the structure that a KeyVault read client's control register
decodes into, `kv_read_ctrl_reg_t`, carries only `rsvd`, `read_entry`,
`pcr_hash_extend` and `read_en`. A destination selector appears only on the
write side, as `write_dest_vld` in `kv_write_ctrl_reg_t`, which does not feed the
read-side rule module.

Consequently, privileged firmware can select a KeyVault read entry — including
the OCP Lock release slot 23 — but has no register write that influences the
destination vector examined at `src/keyvault/rtl/kv_read_rule_check.sv:64`. The
multi-hot destination vector that the classification would admit is not
constructible from software.

## Checked paths

| Path | What it establishes |
| --- | --- |
| `src/keyvault/rtl/kv_defines_pkg.sv:52-60` | `KV_DEST_IDX_*` constants; each read client owns one destination index. |
| `src/keyvault/rtl/kv_defines_pkg.sv` (`kv_read_ctrl_reg_t`) | Read control structure has no destination member, so no register field reaches `kv_read_dest`. |
| `src/keyvault/rtl/kv_read_client.sv:64` | Sole instantiation of the rule module; `read_metrics` passes through unmodified. |
| `src/aes/rtl/aes_clp_wrapper.sv:420`, `src/hmac/rtl/hmac.sv:437`, `src/hmac/rtl/hmac.sv:473`, `src/axi/rtl/axi_dma_ctrl.sv:1350`, `src/ecc/rtl/ecc_dsa_ctrl.sv:892`, `src/ecc/rtl/ecc_dsa_ctrl.sv:928` | All 6 destination producers are hardcoded one-hot shift literals, driven by hardware, not software. |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h` | Generated firmware register header carries no KeyVault read destination field, consistent with the structure above. |
| `src/integration/test_suites/` | No existing test exercises a KeyVault read destination selector, because no such software-facing control exists. |

## Rationale

For a `false_alarm` the useful software-observability statement is the absence of
a control path, not the presence of an exploit path. That absence is exactly what
makes the case a false alarm: the permissive classification is real, but the
input it would mishandle is hardware-generated and always one-hot, so no
firmware sequence can reach it. A C test would have nothing to assert beyond the
absence of a register field, which the structure definition and the generated
header already state more directly.
