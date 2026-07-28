# c_validation_status — kv_bug_024

- **bug_id:** kv_bug_024
- **module:** keyvault
- **status:** no_witness

## Conclusion

No software-visible witness exists for either proposition, and none is expected:
the case resolved to `false_alarm`, so there is no software-observable violation
to demonstrate.

Both propositions are, moreover, structurally out of reach of a C test on this
design, for opposite reasons.

The flush proposition cannot be witnessed from firmware because the condition that
triggers it terminates firmware execution. A KeyVault flush on a fatal error is
driven by `cptra_error_fatal` reaching the module's flush input
(`src/integration/rtl/caliptra_top.sv:770`, `:1208`), and
`docs/CaliptraIntegrationSpecification.md:949` states that a fatal error is only
recoverable through an SoC power-good reset. A C test could induce the error but
could not then run to observe the KeyVault, and the power-good reset that ends the
condition also clears the key entries by their own `hard_reset_b` resetsignal
(`src/keyvault/rtl/kv_reg.rdl:22`). The flush is therefore measured at the module
boundary instead, in `proof/tb/kv_flush_and_error_tb.sv`, where the flush input can
be pulsed directly and the entries read back through the module's own
`kv_rd_resp` port.

The reporting proposition needs no C witness because the reporting path it says is
missing is already software-readable, just not where the claim looked. A KeyVault
read or write failure is reported to the initiating engine as `KV_READ_FAIL` or
`KV_WRITE_FAIL` in the KV status `ERROR` field
(`src/keyvault/rtl/kv_def.rdl:25-36`), and four engine register blocks expose that
field to firmware. Software already learns of the failure, with the engine
identified; a C test would be re-reading a register whose definition states the
same thing.

## Checked paths

| Path | What it establishes |
| --- | --- |
| `src/keyvault/rtl/kv_def.rdl:25-36` | The KeyVault error status field defines `SUCCESS`, `KV_READ_FAIL` and `KV_WRITE_FAIL` as `sw=r`, so KeyVault failures are software-readable by construction. |
| `src/keyvault/rtl/kv_read_client.sv:119`, `src/keyvault/rtl/kv_write_client.sv` | The clients drive those encodings from the KeyVault response error, so the software-visible field is live rather than declarative. |
| `src/aes/rtl/aes_clp_reg_pkg.sv`, `src/ecc/rtl/ecc_reg_pkg.sv`, `src/hmac/rtl/hmac_reg_pkg.sv`, `src/sha512/rtl/sha512_reg_pkg.sv` | Four engine register blocks carry the KV status `ERROR` field, so the report is per engine and attributable rather than global. |
| `src/soc_ifc/rtl/soc_ifc_external_reg.rdl:27-31` | `CPTRA_HW_ERROR_FATAL` declares exactly four error fields and a 28-bit reserved field. There is no KeyVault field for firmware to poll, which is the fact the claim rests on and which the audit confirms is not required. |
| `docs/CaliptraIntegrationSpecification.md:949` | A fatal error is only recoverable via SoC power-good reset, which is why no C test can observe KeyVault state after inducing one. |
| `src/keyvault/rtl/kv_reg.rdl:22` | The key data fields reset on `hard_reset_b`, so the power-good reset that clears a fatal error also clears the entries; a post-reset C observation could not distinguish a flush from the reset. |
| `src/integration/rtl/caliptra_top.sv:473-474`, `:485-486` | `kv_error_intr` and `kv_notif_intr` are tied to zero with a TODO while their VeeR vectors are wired to consume them, so an interrupt-driven C witness has nothing to wait on. This is recorded as an open observation, not as evidence for the reporting claim. |

## Rationale

For a `false_alarm` the useful software-observability statement is whether the
security duty the candidate says is missing is discharged somewhere firmware can
see. For the reporting proposition it is, at finer granularity than the claim
asked for. For the flush proposition the duty is discharged in hardware under a
condition firmware cannot survive, which is why the evidence is a module-boundary
measurement rather than a C test — and why a C test that appeared to show secrets
surviving a fatal error would in fact be showing a test that never reached the
observation point.
