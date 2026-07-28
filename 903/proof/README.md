# Caliptra N-003 witness proof

This proof bundle demonstrates that `ecc_hmac_drbg_interface` retains `lfsr_seed_reg` and `sca_entropy_reg` after `zeroize`, while other HMAC-DRBG interface output registers are cleared.

Contents:

- `tb/N003_ecc_hmac_drbg_zeroize_residue_tb.sv`: directed single-DUT residue testbench.
- `tb/ecc_hmac_drbg_child_models.sv`: deterministic child models used to drive reachable handshakes and nonzero results.
- `scripts/run_n003_ecc_hmac_drbg_zeroize_residue.sh`: deterministic Verilator entry script.
- `logs/compile.log`: compile transcript from the latest packaged run.
- `logs/run.log`: witness output from the latest packaged run.

Run:

```bash
CALIPTRA_ROOT=/path/to/caliptra ./scripts/run_n003_ecc_hmac_drbg_zeroize_residue.sh
```

Inspect `logs/run.log`. The expected success marker is:

```text
N003_ZEROIZE_RESIDUE_WITNESS_PASS
```

The key observation is that `N003_WITNESS_AFTER_ZEROIZE` reports `lfsr_seed_reg_nonzero=1` and `sca_entropy_reg_nonzero=1`, while `lambda_zero=1`, `scalar_zero=1`, `masking_zero=1`, and `drbg_zero=1`.
