# Caliptra bug 013 witness proof

This proof bundle demonstrates that `entropy_src_repcnts_ht` reports the symbol-level repetition-count health-test failure one accepted repeated symbol later than the configured threshold.

Contents:

- `tb/entropy_src_bug_013_repcnts_harness.cpp`: C++ harness for one Verilated `entropy_src_repcnts_ht` DUT.
- `scripts/run_bug_013_repcnts_witness.sh`: deterministic build-and-run entry point.
- `logs/compile.log`: captured compile log from the provided run.
- `logs/run.log`: captured witness log from the provided run.

Required tools:

- Verilator
- `g++-10` or `g++`
- A Caliptra RTL checkout passed explicitly with `CALIPTRA_ROOT`

Reproduction:

```bash
CALIPTRA_ROOT=/path/to/caliptra ./scripts/run_bug_013_repcnts_witness.sh
```

Inspect `logs/run.log`. The key observations are:

```text
OBSERVE boundary_count=3 threshold=3 boundary_fail=0
OBSERVE next_count=4 threshold=3 next_fail=1
PASS BUG013_REPCNTS_OFF_BY_ONE_WITNESS
```

The controls show that alternating symbols do not fail and that subthreshold repetition does not fail. The witness shows the configured threshold boundary is skipped, with failure delayed until the next repeated symbol.
