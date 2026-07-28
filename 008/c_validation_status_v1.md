# C validation status — BUG-008

- **bug_id:** 008
- **module:** caliptra_prim
- **status:** `header_witness`

## Conclusion

The defect is in a SystemVerilog package function, so there is no register to
write that triggers it directly and no C test can observe it by itself. What C
validation is available here is reachability: the MuBi4 fields that feed the
weakened function are software-writable four-bit fields in one firmware-addressable
register, and the internal state the weakest of them unlocks is read back through
another. No new C test was compiled for this submission. The reachability claim
rests on the generated Caliptra register header and on the consumer wiring in
`src/csrng/rtl/csrng_core.sv`; the behavioural claim, that the strict test accepts
two encodings rather than one, rests on the exhaustive simulation and its negative
control.

## Checked paths

| Path | What it shows |
| --- | --- |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:9229` | `CLP_CSRNG_REG_BASE_ADDR = 0x20002000`, so the CSRNG block is in the MMIO map firmware can address. |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:9280` | `CLP_CSRNG_REG_CTRL = 0x20002014`, the single register holding all three MuBi4 configuration fields. |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:9284` | `CSRNG_REG_CTRL_ENABLE_MASK = 0xf`: the enable field is four bits wide, so software can write any of the 16 encodings including `4'h7`. |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:9286` | `CSRNG_REG_CTRL_SW_APP_ENABLE_MASK = 0xf0`, same for the software-application enable. |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:9288` | `CSRNG_REG_CTRL_READ_INT_STATE_MASK = 0xf00`, same for the internal-state readback enable. |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:9360` | `CLP_CSRNG_REG_INT_STATE_VAL = 0x20002044`, where the internal DRBG state that field unlocks is read back. |
| `src/csrng/rtl/csrng_core.sv:788` | `mubi_cs_enable` is cast straight from `reg2hw.ctrl.enable.q`, so the register field's raw four-bit value reaches the function unfiltered. |
| `src/csrng/rtl/csrng_core.sv:829` | `mubi_read_int_state` is cast the same way from `reg2hw.ctrl.read_int_state.q`. |
| `src/csrng/rtl/csrng_core.sv:794`, `:811`, `:830` | The three permissions are derived from `mubi4_test_true_strict` of those fanouts, under the `SEC_CM: CONFIG.MUBI` marker at `:786`. |
| `src/csrng/rtl/csrng_core.sv:831` | `read_int_state_pfa` uses `mubi4_test_invalid` on the same field, which is what makes the contradiction observable: for `4'h7` the alert path fires while the permission path has already granted. |

## What was verified behaviourally

The directed simulation (`proof/logs/sim.log`) sweeps all 16 four-bit encodings
through `mubi4_test_true_strict` and counts acceptances, recording 2 rather than 1
and identifying the extra encoding as `4'h7` at Hamming distance 1 from
`MuBi4True`. The same sweep records `mubi4_test_invalid(4'h7) = 1` alongside
`mubi4_test_true_strict(4'h7) = 1`, which is the self-contradiction. The negative
control (`proof/logs/negative_control.log`) restores the exact comparison in a
scratch copy and shows the sweep accepting exactly 1 encoding, with
`cover_strict_accepts_nontrue` and `cover_accepted_is_invalid` both falling to 0
and three checks failing, while `cover_wider_widths_reject` continues to fire and
`MuBi4True` is still accepted, so the harness itself is intact.
