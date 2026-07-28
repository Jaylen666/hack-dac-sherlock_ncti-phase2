# BUG-014 C validation status

status: header_witness

## What was checked

The witness for this bug is a SystemVerilog testbench driving the `hmac` block over
its native `cs`/`we` register interface, not a C program running on a core. This
file records what was checked in the register-definition layer so the offsets and
field positions used by the testbench are traceable to the tree's own definitions
rather than to hand-copied constants.

Offsets and field positions used by the testbench, each confirmed against the
address decode and field logic in the audited checkout:

| Symbol | Value used | Source |
| --- | --- | --- |
| `HMAC512_CTRL` | 0x10 | `src/hmac/rtl/hmac_reg.rdl:90` register address, matching the `hmac_reg.sv` decode |
| `HMAC512_STATUS` | 0x18 | `src/hmac/rtl/hmac_reg.sv` address decode |
| `HMAC512_KEY[0]` | 0x40 | `src/hmac/rtl/hmac_reg.sv` address decode, stride 4 over 16 words |
| `HMAC512_BLOCK[0]` | 0x80 | `src/hmac/rtl/hmac_reg.sv` address decode, stride 4 over 32 words |
| `HMAC512_TAG[0]` | 0x100 | `src/hmac/rtl/hmac_reg.sv` address decode, stride 4 over 16 words |
| `error_internal_intr_r` | 0x814 | `src/hmac/rtl/hmac_reg.sv` address decode |
| `CTRL.INIT` bit 0 | 0 | `src/hmac/rtl/hmac_reg.sv:761` uses `decoded_wr_data[0:0]` |
| `CTRL.NEXT` bit 1 | 1 | `src/hmac/rtl/hmac_reg.sv:785` uses `decoded_wr_data[1:1]` |
| `CTRL.ZEROIZE` bit 2 | 2 | `src/hmac/rtl/hmac_reg.sv:809` uses `decoded_wr_data[2:2]` |
| `CTRL.MODE` bit 3 | 3 | `src/hmac/rtl/hmac_reg.sv:833` uses `decoded_wr_data[3:3]` |
| `CTRL.CSR_MODE` bit 4 | 4 | `src/hmac/rtl/hmac_reg.sv:854` uses `decoded_wr_data[4:4]` |
| `CTRL` bit 5, the field under test | 5 | `src/hmac/rtl/hmac_reg.sv:875` uses `decoded_wr_data[5:5]`; declared at `src/hmac/rtl/hmac_reg.rdl:88` |
| `STATUS.READY` bit 0 | 0 | `src/hmac/rtl/hmac_reg.sv:2278` readback arm |
| `STATUS.VALID` bit 1 | 1 | `src/hmac/rtl/hmac_reg.sv:2279` readback arm |
| `error_internal_intr_r.key_mode_error_sts` bit 0 | 0 | `src/hmac/rtl/hmac_reg.sv:2330` readback arm |
| `error_internal_intr_r.key_zero_error_sts` bit 1 | 1 | `src/hmac/rtl/hmac_reg.sv:2331` readback arm |
| `error_internal_intr_r.error2_sts` bit 2 | 2 | `src/hmac/rtl/hmac_reg.sv:2332` readback arm |

## Notes for anyone reusing these constants in C

`HMAC512_CTRL` is software-write-only. `src/hmac/rtl/hmac_reg.rdl:68` sets the
register's default software access to write, and the `hmac_reg.sv` decode carries
no read arm for it, so a read of offset 0x10 returns zero regardless of what was
written. C code must not attempt to confirm a command by reading CTRL back. The
testbench records this as a passing bound rather than a failure, so the
`ctrl_rb=0x00000000` line in the log is the designed behaviour and not a broken
bus read.

`INIT`, `NEXT` and `ZEROIZE` are `singlepulse` fields: they self-clear one cycle
after the write. Bit 5 is not, so a write to it persists until reset. C code that
writes bit 5 while intending to set some other bit later will leave a stale
request standing in the register.

`INIT`, `NEXT`, `MODE` and `CSR_MODE` are qualified by `swwe` from `ready_reg`
(`src/hmac/rtl/hmac.sv:250-253`), so writes to them while the block is busy are
dropped. Bit 5 carries no such qualifier and accepts writes at any time.

The witness holds `kv_rd_resp` and `kv_wr_resp` at their absent values, so
`kv_key_data_present` is low. That matters for any C reproduction: both error
conditions the block actually drives are gated on that signal
(`src/hmac/rtl/hmac.sv:395-396`), so a purely register-programmed sequence cannot
raise `key_mode_error_sts` or `key_zero_error_sts` either. Reading
`error_internal_intr_r` as zero after a command therefore carries no information
about whether the command was valid.
