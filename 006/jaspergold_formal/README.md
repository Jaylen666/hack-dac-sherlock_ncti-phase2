# Bug 006 — JasperGold formal evidence

- **bug_id:** 006
- **bug_name:** `aes_prng_masking_force_masks_gate`
- **module:** aes
- **evidence version:** formal property proof (JasperGold 2022.09p001)
- **primary location:** `src/aes/rtl/aes_prng_masking.sv:87`

This is the **second of two independent proofs** for bug 006. The other is a
directed single-DUT simulation witness. They prove the same finding by different
means and neither replaces the other:

| evidence | what it shows | strength |
| --- | --- | --- |
| directed simulation | one concrete stimulus produces the violating output | concrete, but one input valuation |
| **this package** | the property fails for **every** reachable input valuation, at bound 1 | exhaustive over the module's input space |

## What was proven

`src/aes/rtl/aes_prng_masking.sv:17-18` declares `SecAllowForcingMasks` as the
compile-time gate for `force_masks_i`, an SCA-only test input. Line 87 then
assigns the Bivium lockup override without consulting that gate:

```systemverilog
assign bivium_allow_lockup = force_masks_i;   // :87
```

and line 104 forwards it to the primitive's `allow_lockup_i` port. A checker
bound to `aes_prng_masking` asserts that with the gate disabled the override must
stay low. JasperGold returns a **counterexample at bound 1** for both assertions:

| property | kind | expected | observed |
| --- | --- | --- | --- |
| `..._FORCE_MASKS_DISABLED_BLOCKS_LOCKUP` | assert | FAIL | **cex**, bound 1 |
| `..._DISABLED_LOCKUP_INVARIANT` | assert | FAIL | **cex**, bound 1 |
| `..._TRIGGER` | cover | COVERED | **covered**, bound 1 |
| `..._VIOLATION` | cover | COVERED | **covered**, bound 1 |

Counterexample state: `SecAllowForcingMasks=0`, `force_masks_i=1`,
`bivium_allow_lockup=1`. One cycle suffices because line 87 is combinational.

`SecAllowForcingMasks` defaults to `0` at every level of the hierarchy
(`aes.sv:24`, `aes_core.sv:18`, `aes_cipher_core.sv:101`), and
`aes_prng_masking.sv:69` raises a static lint error if it is ever non-default.
The counterexample is therefore the **shipped configuration**, not a contrived one.

## Why the counterexamples are not vacuous

A failing assertion is worthless if the setup made it fail. Four things rule that
out, and they are visible in `logs/bug006_property_summary.txt`:

- **no assumptions** — `assumptions: 0`. Nothing constrained the environment.
- **`:noDeadEnd` and `:noConflict` both proven** — the structural vacuity checks.
- **two cover properties hit** — the trigger *and* the violating state are proven
  reachable, independently of the assertions.
- **no blackbox** — `aes_prng_masking` elaborated as top with 41 analyzed Verilog
  modules, real `caliptra_prim_trivium` included.

## Scope: what this does not prove

The proof observes `bivium_allow_lockup`, the wrapper signal driving the
primitive port. It does **not** show that an all-zero primitive state persists,
and it should not be read that way. `src/caliptra_prim/rtl/caliptra_prim_trivium.sv:188`
computes:

```systemverilog
assign restore = lockup & (StrictLockupProtection | ~allow_lockup_i);
```

and the wrapper instantiates the primitive with
`StrictLockupProtection(!SecAllowForcingMasks)` (`aes_prng_masking.sv:95`), which
is `1` in the same configuration where this bug triggers. That OR term holds
`restore` high, so the primitive is still recovered from the all-zero state.

So this is a **defense-in-depth defect**: a disabled test input reaches a
security-control port it was never supposed to reach, and the only thing
containing it is an unrelated parameter in a different module. That containment is
why bug 006 carries a Low severity rather than a masking-bypass severity. Stating
this plainly is more useful than overclaiming the impact.

## Supporting in-tree argument

Every *other* use of `force_masks_i` in the AES tree qualifies it with the gate —
`aes_cipher_core.sv:844`, `:858`, `:865`, `:876`, `:882` all write
`(SecAllowForcingMasks && force_masks_i)`. Line 87 is the lone unqualified use.
The same file also contradicts itself: `:71-73` declares the input **unused** when
the gate is `0`, while `:87` uses it unconditionally.

## Contents

```text
scripts/run_bug006_formal.sh        entry point; prints result=PASS/FAIL
scripts/jasper_bug006.tcl           analyze / elaborate / prove -all
tb/checker.sv                       SVA checker (2 asserts, 2 covers)
tb/bind_all.sv                      bind into aes_prng_masking
logs/bug006_property_summary.txt    per-property result table — read this first
logs/bug006_jasper.log              full tool transcript
formal_metadata/property_index.json property list and intent
formal_metadata/result_contract.json expected vs observed status
formal_metadata/source_files.json   RTL closure required to elaborate
formal_metadata/case.json           case metadata, verified source hash
```

## Reproducing

```bash
CALIPTRA_ROOT=<path to the Caliptra checkout> ./scripts/run_bug006_formal.sh
```

Requires JasperGold on `PATH` (override with `JASPERGOLD_BIN`). The script exits
nonzero unless both assertions return counterexamples, so a clean proof is
reported as a failure of the evidence rather than passing silently.

Read `logs/bug006_property_summary.txt` first — the `cex` rows for the two
assertions and the `covered` rows for the two covers are the result. In
`logs/bug006_jasper.log` the lines that matter are the `IPF055` counterexample
records and the `IPF047` cover records.

The proof ran on a compute server with a JasperGold license. `formal_metadata/case.json`
records the SHA-256 of `src/aes/rtl/aes_prng_masking.sv` used in that run; it was
recomputed against the submitted tree at packaging time and matches, so the proof
ran on the same bytes as the submitted RTL.

## Detection method

The candidate was identified by CSBC, an LLM-driven RTL security analysis
framework, and independently validated by JasperGold formal property proof against
the submitted RTL.
