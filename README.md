# hack-dac-sherlock_ncti-phase2

## Bug 006 — two independent proofs

Bug 006 (`aes_prng_masking_force_masks_gate`, `src/aes/rtl/aes_prng_masking.sv:87`)
is backed by **two independent bodies of evidence**. They prove the same finding by
different means, and neither supersedes the other:

| # | evidence | location | what it shows |
| --- | --- | --- | --- |
| 1 | directed simulation witness | `006/proof/` | a concrete stimulus drives the violating output on the real DUT |
| 2 | **JasperGold formal proof** | `006/jaspergold_formal/` | the property fails for **every** reachable input valuation, at bound 1 |

The second version uses a **formal verification tool** (JasperGold 2022.09p001).
An SVA checker is bound into `aes_prng_masking` and asserts that while the
compile-time gate `SecAllowForcingMasks` is disabled, `force_masks_i` must not
assert the Bivium lockup override. Both assertions return counterexamples at bound
1 and both cover properties are hit, with zero assumptions declared and the
`:noDeadEnd` / `:noConflict` vacuity checks proven — so the failures are real
rather than artifacts of an over-constrained environment.

The formal package also records a **containment limit** that the simulation
witness alone does not make obvious: `src/caliptra_prim/rtl/caliptra_prim_trivium.sv:188`
keeps the primitive's restore path active in this configuration, so the defect is
defense-in-depth (a disabled test input reaching a security-control port) rather
than a masking bypass. That is why bug 006 carries a Low severity.

See `006/jaspergold_formal/README.md` for the property table, the vacuity
controls, and reproduction instructions.
