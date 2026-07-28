# C validation status — BUG-029

- **bug_id:** 029
- **module:** kmac
- **status:** `header_witness`

## Conclusion

The defect is a missing internal state clear inside the SHA3 datapath. There is no
register that reports the Keccak sponge state, and by design there should not be:
`src/kmac/rtl/sha3.sv:333-338` mux the outward-facing state through `MuxGuard`, so
outside the squeeze window `state_o` reads zero, and `sha3.sv:517-519` assert that
property. A C test therefore cannot read the stale state directly, and none was
compiled for this submission.

What C validation is available is reachability of the surrounding sequence: the
entropy source that instantiates this SHA3 engine is firmware-addressable, software
enables it and reads the conditioned entropy it produces through the generated
register map, and the SHA3 `done` that fails to clear is issued once per seed by
that block's own state machine with no software involvement needed. So an
unprivileged caller reaching for successive seeds walks the sequence in the flow
without doing anything unusual. The behavioural claim — that the state survives the
`done` bit-for-bit and that a second identical absorb therefore diverges — rests on
the directed simulation and its negative control.

## Checked paths

| Path | What it shows |
| --- | --- |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:9466` | `CLP_ENTROPY_SRC_REG_BASE_ADDR = 0x20003000`, so the entropy source that instantiates this SHA3 engine is in the MMIO map firmware can address. |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:9539` | `CLP_ENTROPY_SRC_REG_MODULE_ENABLE = 0x20003020`, the register through which software turns the block on and therefore starts the seed pipeline that issues the `done`. |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:9543` | `ENTROPY_SRC_REG_MODULE_ENABLE_MODULE_ENABLE_MASK = 0xf`, so the enable is a software-writable field. |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:9571` | `CLP_ENTROPY_SRC_REG_ENTROPY_DATA = 0x2000302c`, where software reads the conditioned entropy that the affected sponge produces. |
| `src/entropy_src/rtl/entropy_src_core.sv:2737` | This exact `sha3` module is instantiated as the entropy source's conditioning engine, so the defective copy is the one in the seed path. |
| `src/entropy_src/rtl/entropy_src_core.sv:2768` | `done_i` is driven by the block's own `sha3_done`, so the command that fails to clear is issued internally on every seed, with no software action needed to trigger it. |
| `src/entropy_src/rtl/entropy_src_core.sv:2734` | `pfifo_cond_rdata = sha3_state[0][SeedLen-1:0]`: the squeezed state is taken straight into the conditioned-entropy path that becomes a seed. |
| `src/entropy_src/rtl/entropy_src_main_sm.sv:246-247` | The consumer's own comment states the intent the RTL does not honour: the `done` is there to clear the SHA3 internal state so it starts from scratch for the next seed. |
| `src/entropy_src/rtl/entropy_src_main_sm.sv:248` | That `done` is issued as a strictly-valid `MuBi4True`, so the command the module ignores is well formed and is not a stimulus artefact. |
| `src/kmac/rtl/sha3.sv:333-338` | The `state_guarded` mux returns zero outside the squeeze window, which is why the harm is cross-run carryover rather than a software-readable state disclosure, and why no C test can observe the stale value directly. |

## What was verified behaviourally

The directed simulation (`proof/logs/sim.log`) drives one absorb to the squeeze
window, reads the child's storage hierarchically at `04618e735288ea59`, issues a
strictly-valid `done_i`, and observes `keccak_done = 0x6` while `keccak_done2` and
hence `clear_i` read `0x9` in that same branch. The FSM moves `StSqueeze` to
`StIdle` and the storage stays bit-for-bit identical. Continuous monitors, rather
than single-cycle samples, confirm `rst_storage` never asserted and `clear_i` never
passed the strict true test at any point in the entire run. Absorbing the
byte-identical message a second time then yields `cdb5488900229739`, which is the
cross-run carryover the missing clear produces. 16 checks, 0 errors, four cover
counters at 1.

The negative control (`proof/logs/negative_control.log`) rewires one port in a
scratch copy so `clear_i` receives the same `done_i`-derived signal the twin
`src/sha3/rtl/ot_sha3.sv:492` uses. On that copy `clear_i` reads `0x6`, the storage
goes to zero, and the second identical absorb reproduces `04618e735288ea59`
exactly. Five BUG-029 checks fail and `cover_state_survives_done`,
`cover_clear_never_strict` and `cover_cross_run_carryover` all drop to 0, while
`cover_fsm_did_advance` stays at 1 and the reset control check still passes, so the
harness is intact and the failure is attributable to the RTL change.
