# Manual review notes

## Why this invariant suits a formal proof

The target invariant is local to `aes_prng_masking`. It needs no bus protocol, key
schedule, or cryptographic primitive model, so the proof obligation is small and
the result is easy to audit.

## Checker design

The SVA deliberately observes the wrapper-level signal `bivium_allow_lockup`
rather than primitive state. The reported behavior occurs where
`src/aes/rtl/aes_prng_masking.sv:87` assigns that signal, which is upstream of
the primitive consuming it, so primitive state is not part of the obligation.

## Assumptions

None are required, and none were declared. `force_masks_i` is a module input and
may be driven freely by the formal engine. With the feature gate at `0`, the
submitted RTL still assigns `bivium_allow_lockup = force_masks_i`, which is the
counterexample the tool found.

That zero-assumption setup is what makes the counterexamples trustworthy: a
failing assertion is only meaningful if the environment was not over-constrained
into failing. The `:noDeadEnd` and `:noConflict` checks were both proven and both
cover properties were hit, which confirms the trigger and the violating state are
genuinely reachable.

## Execution record

The proof was executed with JasperGold 2022.09p001 on a compute server holding
the license, not on the packaging workstation. Both assertions returned
counterexamples at bound 1 and all three covers were hit; see
`../logs/bug006_property_summary.txt` for the per-property table and
`../logs/bug006_jasper.log` for the full transcript.

## Scope limit found during review

The proof establishes that the override input is assertable while the feature gate
is disabled. It does **not** establish a persistent primitive state change.
`src/caliptra_prim/rtl/caliptra_prim_trivium.sv:188` computes
`restore = lockup & (StrictLockupProtection | ~allow_lockup_i)`, and the wrapper
passes `StrictLockupProtection(!SecAllowForcingMasks)`, which is `1` in exactly
the configuration where this bug triggers. The all-zero state is therefore still
recovered. This is recorded as a containment note in `../README.md` rather than
left for a reader to discover, because it is the difference between a
defense-in-depth defect and a masking bypass.
