# Bug 001 — validation status

**Case:** the AES KeyVault export buffer and its valid bit are not cleared on
entry to debug-unlocked or scan mode.

## What was executed

| Step | Tool | Result |
| --- | --- | --- |
| Structural gates (9) | `grep` over the submitted checkout | all `gate_ok` |
| Compile | VCS W-2024.09-SP1, one real `aes` DUT | `compile_ok` |
| Directed simulation | 2 control cases + 1 violating case | `checks=3 fails=0 witness_hits=1` |
| Determinism | script run three times from a wiped build directory | identical, exit 0 every time |

Success marker: `BUG_001_PROOF_COMPLETE`.

## Reproduce

```bash
CALIPTRA_ROOT=/path/to/caliptra proof/scripts/run_bug_001_proof.sh
```

Requires Synopsys VCS; override the binary with `VCS=/path/to/vcs`. The script
sets the prim-library variables and the register include path itself. Inspect
`proof/logs/run.log` first; `proof/logs/sim.log` carries the per-case buffer
dumps.

## Witness construction

The testbench instantiates one real `aes` module and loads the KeyVault export
buffer over that module's own capture path. Normal operation reaches this path
through an AES-with-KeyVault-destination flow; to keep the witness short and
deterministic, the internal capture controls on that same path are driven
directly during the load phase only, and released before any clear is applied.
Every clear decision reported is therefore produced by the DUT's own logic.

One drive persists: `TRIGGER.DATA_OUT_CLEAR` is held at its normal deasserted
value. That register resets asserted (`RESVAL 1'h1`, `src/aes/rtl/aes_reg_top.sv:1199`)
and is deasserted by the AES control FSM once a clear has completed, so holding
it at 0 models the state in which a result is being exported. It is the
non-clearing value, so it cannot manufacture the retention under test — visible
in the two controls, which clear the buffer through the other paths while it is
held.

## Software-visible observation

No C-level software test is included. The missing clear is a hardware response
to a physical-state transition (debug unlock or scan enable), not a
firmware-reachable register effect, and the specification assigns firmware only
the follow-up clear. Firmware therefore cannot observe the absent hardware
clear; the observable evidence is the retained export buffer and valid bit at
the AES KeyVault interface in simulation.

## Scope

Proven: the clearing request is produced, never consumed by the AES core, and
both export registers survive its assertion while responding to the two clear
sources the RTL does implement.

Not proven: scan-chain or JTAG extraction of the retained flops, and any claim
about KeyVault-internal storage.
