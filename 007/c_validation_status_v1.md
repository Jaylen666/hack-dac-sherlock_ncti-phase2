# Bug 007 — validation status

**Case:** `axi_sub_arb` exports a granted read transaction's request with the
concurrent write request's AXI USER attribute.

## What was executed

| Step | Tool | Result |
| --- | --- | --- |
| Structural gates (9) | `grep` over the submitted checkout | all `gate_ok` |
| Compile | Verilator 5.024, `g++-10`, one `axi_sub_arb` DUT | `compile_ok` |
| Directed simulation | 3 control cases + 1 violating case | `checks=4 fails=0 witness_hits=1` |
| Determinism | script run twice from a wiped build directory | identical, exit 0 both times |

Success marker: `BUG_007_PROOF_COMPLETE`.

## Reproduce

```bash
CALIPTRA_ROOT=/path/to/caliptra proof/scripts/run_bug_007_proof.sh
```

Requires Verilator 5.x and a C++20-capable compiler for `--timing`
(`g++-10` or newer). Override with `VERILATOR` and `CXX`. Inspect
`proof/logs/run.log` first; `proof/logs/sim.log` carries the per-case lines.

## Software-visible observation

No C-level software test is included. The bypass is an attribute-selection
fault on the AXI subordinate arbiter's component interface, one clock wide, and
the mismatched field is consumed combinationally by the `soc_ifc` AXI_USER
allowlist comparisons. Firmware running on the Caliptra core cannot sample that
interface directly, so the observable evidence is taken at the arbiter boundary
in simulation, where both the granted channel (`write`, `addr`, `id`) and the
exported identity (`user`) are visible in the same cycle.

## Scope

Proven: the identity mismatch on the granted request, and that the affected
`user` output reaches `soc_req.user` and its allowlist comparisons.

Not proven: an end-to-end data disclosure over a full SoC boot, and the rate at
which the concurrent-request window arises in a given integration. The CVSS
attack complexity is rated High for that reason.
