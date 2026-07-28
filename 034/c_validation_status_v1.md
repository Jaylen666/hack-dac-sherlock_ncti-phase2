# BUG-034 C validation status

status: header_witness

## What was validated

The witness is a SystemVerilog testbench driving one unmodified
`sha512_masked_core` over its module ports. No C program accompanies it, and the
reason is the observation channel: the exposure is on the core's `digest` port
during cycles when `digest_valid` is low, and reaching it from software requires
the `sha512` wrapper's register path, which this case does not drive.

What a C test could add is the software-visible half of the story: read the
SHA-512 digest registers while `STATUS.VALID` is clear and check whether the
value tracks the invalid-cycle output. That is the natural follow-up and would
lift the case from `partial_proof` to a full software-observable finding.

## What was run

- `proof/scripts/run_bug_034_proof.sh` - 15 structural gates, `result=PASS`.
- `proof/scripts/run_bug_034_sim.sh` - per-cycle sampling witness,
  `PROOF_RESULT: PASS` with 10 checks, 3 expected failures, 3 witness hits.
- `proof/scripts/run_bug_034_negative_control.sh` - neutralises the
  invalid-cycle arm; all three witness statements stop holding and the
  published test vector control still passes. `NEGATIVE_CONTROL: PASS`.

## Note on the sampling point

An earlier form of this witness captured the first non-zero sample and stopped.
That sample is the published SHA-512 initial hash value, because the working
registers still hold it for the first cycles after `init_cmd`. Such a witness
proves no exposure. The shipped testbench samples every invalid cycle and
records `iv=1` alongside 80 samples that are neither the initial value nor a
constant, 81 round-to-round transitions and 80 message-dependent positions.
