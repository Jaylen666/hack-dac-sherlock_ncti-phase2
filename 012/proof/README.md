# Caliptra bug 012 witness proof

This proof bundle demonstrates that `doe_fsm` marks a DOE UDS KeyVault write as valid for the AES-key destination.

Contents:

- `tb/BUG-012_doe_fsm_real_dut_tb.sv`: directed single-DUT testbench.
- `scripts/run_bug_012_doe_fsm_witness.sh`: deterministic Verilator entry script.
- `logs/compile.log`: compile transcript from the latest packaged run.
- `logs/run.log`: witness output from the latest packaged run.

Run:

```bash
CALIPTRA_ROOT=/path/to/caliptra ./scripts/run_bug_012_doe_fsm_witness.sh
```

Inspect `logs/run.log`. The expected success marker is:

```text
BUG012_WITNESS_PASS
```

The key observation is `observed_write_dest_valid=0x023` with `expanded_bit5=1` for `DOE_UDS`.
