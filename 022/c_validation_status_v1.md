# c_validation_status — kv_bug_022

- **bug_id:** kv_bug_022
- **module:** keyvault
- **status:** no_witness

## Conclusion

No software-visible witness exists, and none is expected: the case resolved to
`false_alarm`, so there is no software-observable violation to demonstrate.

The relevant software-side observation is not an absence but an inversion of the
claim. The stage isolation the candidate says hardware should enforce is already
reachable from software, and the tree's own firmware library exercises it.
`src/integration/test_suites/libs/keyvault/keyvault.c:21-25` implements
`kv_set_clear(entry)`, which writes the `CLEAR` bit of `KV_REG_KEY_CTRL_<entry>`
to wipe a KeyVault entry. `LOCK_USE` sits in the same register, one bit away, and
suppresses reads for every client at `src/keyvault/rtl/kv.sv:233-234`.

An earlier boot stage that must not leak an entry to the next stage therefore has
two register writes available to it and needs no hardware transition clear. A C
test that provisioned an entry, advanced a stage and observed the entry still
readable would be demonstrating firmware declining to call `kv_set_clear`, not
hardware failing to enforce a property.

## Checked paths

| Path | What it establishes |
| --- | --- |
| `src/integration/test_suites/libs/keyvault/keyvault.c:21-25` | Firmware already has a per-entry clear helper, writing `KEY_CTRL.CLEAR`. The isolation mechanism is software-driven by design. |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:1940-1947` | `CLP_KV_REG_KEY_CTRL_0` exposes `LOCK_WR`, `LOCK_USE` and `CLEAR` to firmware at bits 0, 1 and 2, so both isolation mechanisms are software-reachable per entry. |
| `src/keyvault/rtl/kv.sv:160` | The `KEY_CTRL.clear` write reaches `key_entry_clear`, qualified only by the entry's own lock bits. The software path is live. |
| `src/keyvault/rtl/kv.sv:233-234` | `lock_use_q` suppresses the read mux for every client, so `LOCK_USE` isolates an entry without wiping it. |
| `src/keyvault/rtl/kv_reg.rdl:28-31` | `lock_wr` and `lock_use` are `sw=rw; hw=r`, so these bits are software-only by construction; hardware cannot set them. |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h` (KeyVault block) | No boot-stage, stage-policy or retention-mask register field exists for firmware to program, consistent with no such concept existing in the RTL. |

## Rationale

For a `false_alarm` the useful software-observability statement is whether the
security duty the candidate assigns to hardware is in fact discharged elsewhere.
Here it is, and visibly so: the duty sits with firmware, the register bits exist,
and the tree ships the helper that writes them. There is nothing for a C test to
assert that these paths do not already state directly, and any test that appeared
to show a leak would be showing a firmware sequence that chose not to clear.
