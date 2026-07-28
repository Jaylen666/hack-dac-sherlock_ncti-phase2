# C validation status — BUG-011

- **bug_id:** 011
- **module:** doe_fsm
- **status:** `header_witness`

## Conclusion

Every input this defect needs is firmware-addressable through the generated
Caliptra register header. Starting a de-obfuscation flow and raising the cleanup
event are both ordinary MMIO writes to a single register, `DOE_CTRL`: the command
field selects the flow, and the clear command that raises `zeroize` is another
encoding of that same field. No new C test was compiled for this submission.

The observation is the part firmware cannot make. What this defect changes is the
duration of an internal hold, `zeroize_reg`, measured as a one-cycle difference in
how quickly the FSM leaves `DOE_IDLE` after a cleanup event. That signal is
module-local and the difference is a single clock, so it is below what a firmware
polling loop on `DOE_STATUS` can resolve. The behavioural claim therefore rests on
the unit-level simulation and its negative control, not on a C witness, and this is
recorded as a limitation rather than as an untested path.

Reachability here means ordinary privileged firmware reaches the defective
condition through documented registers. It does not mean firmware reaches a
protected asset: see "Not claimed".

## Checked paths

| Path | What it shows |
| --- | --- |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:20` | `CLP_DOE_REG_BASE_ADDR = 0x10000000`, so the DOE block sits in the MMIO map firmware can address. |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:37` | `CLP_DOE_REG_DOE_CTRL = 0x10000010`, the single register that both starts a flow and raises the clear command. |
| `src/integration/rtl/caliptra_reg/caliptra_reg_field_defines.svh:33-35` | `DOE_CTRL.CMD` is bits `[1:0]` and `DEST` starts at bit 2, so selecting a de-obfuscation flow is one register write. |
| `src/integration/rtl/caliptra_reg/caliptra_reg_field_defines.svh:37-38` | `DOE_CTRL.CMD_EXT` is bits `[8:7]`, the upper half of the command that `src/doe/rtl/doe_cbc.sv:206` concatenates into `doe_cmd_reg.cmd`. |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:47` | `CLP_DOE_REG_DOE_STATUS = 0x10000014`, the register firmware polls, and the only place the FSM's progress is visible to software. |
| `src/integration/rtl/caliptra_reg/caliptra_reg_field_defines.svh:42-44` | `DOE_STATUS.READY` is bit 0 and `VALID` is bit 1, which is the whole of the software-visible FSM state and carries no cycle-level timing. |
| `src/doe/rtl/doe_cbc.sv:206` | `doe_cmd_reg.cmd` is formed from the `CMD_EXT` and `CMD` register fields, so the command the FSM sees is exactly what firmware wrote. |
| `src/doe/rtl/doe_cbc.sv:213-214` | `zeroize` is raised by the `DOE_CLEAR` command or by `debugUnlock_or_scan_mode_switch`, so the cleanup event is firmware-triggerable through the same register. |
| `src/doe/rtl/doe_cbc.sv:203-204` | `CMD` and `CMD_EXT` are hardware-cleared on `clear_obf_secrets`, which is why no command is pending during the window the hold is supposed to cover. |
| `src/doe/rtl/doe_cbc.sv:256` | `init_done` is wired to `core_ready`, establishing that the defective release term depends on core readiness rather than on a flow. |

## Not claimed

- No C test was compiled or run for this submission.
- No claim that firmware can observe the shortened hold. The difference measured is
  one clock cycle in the command-to-`doe_init` latency, and `doe_init` is not a
  software-visible signal; `DOE_STATUS` exposes only `READY` and `VALID`.
- No claim that firmware can read UDS, field entropy or HEK material as a result.
  The hold performs no wipe of its own, and no secret was read back in any case.
- No claim that the cleanup abort fails. On the audited RTL a `zeroize` pulse still
  forces the FSM to `DOE_IDLE` and still clears the offset and destination
  registers, which the containment case confirms.
