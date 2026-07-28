# BUG-035 C validation status

status: not_applicable_structural_only

## Why no software test accompanies this case

The claim is that the SHA accelerator LOCK field has no hardware set or clear
path. That is a statement about the absence of a port on `sha512_acc_csr`, and
no C program running on the core can observe the absence of a hardware input.
From software the register behaves exactly as a software-only lock: a read
acquires it, a write of 1 releases it. Both of those succeed on this checkout,
so a C test would report success while the defect is present.

What software could show is the consequence rather than the cause: acquire the
lock by reading it, never release it, and observe that a second agent cannot
proceed. That test needs a second requesting agent and the `sha512_acc_top`
wrapper's arbitration, neither of which this case drives. The result file
records that gap as the blocker and bounds the case at `partial_proof`.

## What was run instead

- `proof/scripts/run_bug_035_proof.sh` - 21 structural gates, `result=PASS`.
- `proof/scripts/run_bug_035_negative_control.sh` - restores the hardware set
  and clear path on a scratch copy and requires the identical audit to fail on
  the absence gates while the control gates stay green. `NEGATIVE_CONTROL: PASS`.

Neither script needs a simulator. Both are shell, awk, grep and python3 only.
