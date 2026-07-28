# BUG-020 C validation status

status: not_applicable_structural_only

## Why no software test accompanies this case

The finding is that no hardware-derived boot-phase event exists. A C program
cannot observe the absence of a hardware mechanism: from software the phase
register reads and writes exactly as it would in a design that also had a
detector cross-checking it. A C test would therefore pass on this checkout while
the defect is present.

There is also nothing to drive. The detector, its instance and every textual
reference are gone, so the elaborated design holds no stub, no tied-off output
and no dangling port that a test could stimulate.

What software could demonstrate is the consequence rather than the cause: write
the phase-indicating register field from a context that has not legitimately
reached that phase, then show a downstream consumer applying the later phase's
policy. That test belongs with the downstream policy cases, and it needs a
consumer whose behaviour visibly changes with the phase bit.

## What was run instead

- `proof/scripts/run_bug_020_proof.sh` - 20 structural gates, `result=PASS`.
- `proof/scripts/run_bug_020_negative_control.sh` - reconstructs the shape of
  the missing detector on a scratch copy of the tree, wires it into the
  integration top and the key vault, and requires the identical census to fail
  on the absence gates while the anchors stay green. It also verifies the
  submitted checkout is unmodified afterwards. `NEGATIVE_CONTROL: PASS`.

Neither script needs a simulator.
