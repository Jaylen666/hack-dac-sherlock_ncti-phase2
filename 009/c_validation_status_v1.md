# C validation status — BUG-009

- **bug_id:** 009
- **module:** csrng_state_db
- **status:** `header_witness`

## Conclusion

Every input this defect needs is firmware-addressable through the generated Caliptra
register header, and so is the observation. The authorization mask, the application
selector and the dump window are all plain MMIO registers in the CSRNG aperture, and
the testbench drives exactly the signals those registers produce: `INT_STATE_READ_ENABLE`
becomes `int_state_read_enable_i`, a write to `INT_STATE_NUM` becomes the id pulse plus
`state_db_reg_rd_id_i`, and each read of `INT_STATE_VAL` becomes one `state_db_reg_rd_sel_i`
pulse advancing the window pointer. No new C test was compiled for this submission.
The reachability claim rests on the generated header and on the register-block wiring;
the behavioural claim, that the window serves an application whose own authorization
bit is clear and refuses one whose bit is set, rests on the unit-level simulation and
its negative control.

Reachability here means firmware can reach the defect through its documented interface
and obtain another application's DRBG key. It does not mean the outer gates on this
path were bypassed — see "Not claimed".

## Checked paths

| Path | What it shows |
| --- | --- |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:9229` | `CLP_CSRNG_REG_BASE_ADDR = 0x20002000`, so the block under test sits in the MMIO map firmware can address. |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:9342` | `CLP_CSRNG_REG_INT_STATE_READ_ENABLE = 0x20002038`, the authorization mask the attack programs. |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:9346` | `INT_STATE_READ_ENABLE` occupies mask `0x7`, one bit per instance, so the per-application intent is expressible from firmware. |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:9354` | `CLP_CSRNG_REG_INT_STATE_NUM = 0x20002040`, the register that selects which application to dump. |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:9360` | `CLP_CSRNG_REG_INT_STATE_VAL = 0x20002044`, the 32-bit window each read advances. |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:9280` | `CLP_CSRNG_REG_CTRL = 0x20002014`, and `:9288` shows `READ_INT_STATE` at mask `0xf00`, the outer enable firmware must set first. |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:9348` | `CLP_CSRNG_REG_INT_STATE_READ_ENABLE_REGWEN = 0x2000203c`, the write-protection on the mask, which must still permit writes. |
| `src/csrng/rtl/csrng_reg_top.sv:2317` | `int_state_read_enable_wd = reg_wdata[2:0]`, so that MMIO write lands in the field the DUT consumes. |
| `src/csrng/rtl/csrng_core.sv:1247` | `int_state_read_enable = reg2hw.int_state_read_enable.q`, the field driving the DUT port with no further qualification. |
| `src/csrng/rtl/csrng_core.sv:1285` | `.int_state_read_enable_i(int_state_read_enable)`, closing the path from the MMIO register to the mis-indexed qualification. |

## Not claimed

- No claim that `CTRL.READ_INT_STATE`, `otp_en_csrng_sw_app_read`, or the regwen were
  bypassed. The defect is in the per-application layer beneath them and needs those
  gates open, which is the normal configuration for diagnostic internal-state reads.
- No claim about the reseed counter. `src/csrng/rtl/csrng_state_db.sv:180` exports it
  unconditionally by design, which is why every probe in the testbench reads a key
  word instead of window word 0.
- No claim that a compiled C test was run on this defect.
