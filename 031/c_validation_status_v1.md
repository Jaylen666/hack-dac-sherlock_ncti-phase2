# C validation status — BUG-031

- **bug_id:** 031
- **module:** pcrvault
- **status:** `header_witness`

## Conclusion

Every step of the sequence is a plain register access in one firmware-addressable
block, so the reachability half of this finding is established from the generated
register map rather than from a compiled test. Software starts a PCR quote, writes
the zeroize strobe part-way through it, restarts the quote and reads the digest
back, all through four defines in `caliptra_reg.h`. No C test was compiled for this
submission, because the thing that must be observed to distinguish a truncated
quote from a complete one is *which* PCR entries entered the hash block, and that is
not exposed anywhere in the register map: the only software-visible output is the
final digest at `SHA512_GEN_PCR_HASH_DIGEST_0`, which is a well-formed digest in
both cases. That is precisely the security problem, and it is also why the
behavioural claim rests on the directed simulation, which measures entry coverage
from the tagged data the DUT itself writes into the hash block.

A C test could detect the defect only indirectly, by computing the expected
full-bank digest in software and comparing, which would confirm a mismatch without
localising it. The simulation localises it: it reports the exact pointer value at
the moment of the zeroize and the exact set of entries the following quote covered.

## Checked paths

| Path | What it shows |
| --- | --- |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:7130` | `CLP_SHA512_REG_BASE_ADDR = 0x10020000`, so the SHA-512 block that owns the PCR gen-hash engine is in the MMIO map firmware can address. |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:7147` | `CLP_SHA512_REG_SHA512_CTRL = 0x10020010`, the control register carrying the zeroize strobe that reaches the incomplete branch. |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:7156` | `SHA512_REG_SHA512_CTRL_ZEROIZE_LOW = 4`: zeroize is bit 4 of that register. |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:7157` | `SHA512_REG_SHA512_CTRL_ZEROIZE_MASK = 0x10`, confirming it is an ordinary software-writable field rather than a hardware-only strobe. |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:7455` | `CLP_SHA512_REG_SHA512_GEN_PCR_HASH_CTRL = 0x10020630`, the register through which software starts a quote. |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:7459` | `SHA512_REG_SHA512_GEN_PCR_HASH_CTRL_START_MASK = 0x1`: the start command is a single software-written bit, so both the interrupt and the restart are one write each. |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:7469` | `CLP_SHA512_REG_SHA512_GEN_PCR_HASH_DIGEST_0 = 0x10020638`, where the resulting quote is read back — the truncated digest is returned here indistinguishably from a complete one. |
| `src/sha512/rtl/sha512.sv:284` | The parent turns the `SHA512_CTRL.ZEROIZE` field into the internal `zeroize_reg`, joining the software write to the hardware strobe. |
| `src/sha512/rtl/sha512.sv:522` | That `zeroize_reg` is the signal passed into this module's `zeroize` port, so the software-written bit is what reaches the branch that omits the pointer. |
| `src/pcrvault/rtl/pv.sv:145-147` | The PCR read mux selects the returned measurement by the entry and dword the pointer names, which is what makes a stale pointer a change in *which* PCRs are hashed. |

Note that `src/sha512/rtl/sha512.sv:284` assigns `{zeroize_reg, zeroize_reg2}`; only
`zeroize_reg`, the signal wired into this module at line 522, is relevant here. No
claim is made about the second signal in that concatenation.

## What was verified behaviourally

The directed simulation (`proof/logs/sim.log`) instantiates one unmodified
`pv_gen_hash` and drives it only through its declared ports — no force, no deposit,
no hierarchical assignment. Coverage is measured from the tagged PCR data the DUT
writes into the hash block, so the nonce and padding phases cannot be mistaken for
PCR reads. Three cases ran: a quote from reset covered 32 of 32 entries; a quote
interrupted by a one-cycle zeroize with the read pointer at entry 20 left
`gen_hash_ip = 0` while the pointer still read entry 20, and the next quote covered
only 12 of 32 entries starting at entry 20; a zeroize taken while the engine was
already idle left the following quote complete at 32 of 32. `checks=3 fails=1
witness_hits=1` with all three cover counters at 1.

The negative control (`proof/logs/negative_control.log`) adds the two omitted
assignments to the zeroize branch of a scratch copy and re-runs the identical
testbench. The post-zeroize quote then covers all 32 entries and reports
`case=violating_walk_after_mid_run_zeroize PASS`, the witness stops firing and
`cov_truncated_walk_after_zeroize` drops to 0, while the from-reset and idle-zeroize
cases still pass — so the observation is a property of the audited RTL, not of the
harness.

The structural audit (`proof/logs/run.log`, `proof/logs/witness.log`) passes 36 of
36 gates, including four computed censuses that fail loudly on a regex miss:
`reset_arm_assignments=5 zeroize_arm_assignments=3 else_arm_assignments=5` in the
module under test, `read_entry_references=8 read_offset_references=9` accounting for
every write to the two registers, `kv_fsm_reset_arm_assignments=2
kv_fsm_zeroize_arm_assignments=2` for the sibling that mirrors its branches, and
`sha512_zeroize_arm_assignments=8` for the parent that clears exhaustively on the
same strobe.
