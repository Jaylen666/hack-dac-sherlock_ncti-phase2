# Caliptra bug 006 witness proof

This proof bundle demonstrates that `aes_prng_masking` forwards `force_masks_i` to the masking PRNG lockup-override input even when `SecAllowForcingMasks` is disabled.

Contents:

- `tb/BUG-006_aes_prng_masking_real_dut_tb.sv`: directed single-DUT testbench.
- `scripts/run_bug_006_aes_prng_masking_witness.sh`: deterministic Verilator entry script.
- `logs/compile.log`: compile transcript from the latest packaged run.
- `logs/run.log`: witness output from the latest packaged run.

Run:

```bash
CALIPTRA_ROOT=/path/to/caliptra ./scripts/run_bug_006_aes_prng_masking_witness.sh
```

Inspect `logs/run.log`. The expected success marker is:

```text
BUG006_WITNESS_PASS
```

The key observation is `observed_primitive_allow=1 secure_expected=0` under `SecAllowForcingMasks=0`.
