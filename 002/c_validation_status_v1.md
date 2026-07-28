# BUG-002 C validation status

status: header_witness

## What was checked

The witness for this bug is a SystemVerilog testbench driving the `aes` block over
its TileLink register interface, not a C program running on a core. This file
records what was checked in the C and header layer so the register offsets and
field positions used by the testbench are traceable to the tree's own
definitions rather than to hand-copied constants.

Offsets and field positions used by the testbench, each confirmed against the
generated register definitions in the audited checkout:

| Symbol | Value used | Source |
| --- | --- | --- |
| `KEY_SHARE0_0` | 0x04 | `src/aes/rtl/aes_reg_pkg.sv` offset table |
| `KEY_SHARE1_0` | 0x24 | `src/aes/rtl/aes_reg_pkg.sv` offset table |
| `DATA_IN_0` | 0x54 | `src/aes/rtl/aes_reg_pkg.sv` offset table |
| `DATA_OUT_0` | 0x64 | `src/aes/rtl/aes_reg_pkg.sv` offset table |
| `CTRL_SHADOWED` | 0x74 | `src/aes/rtl/aes_reg_pkg.sv` offset table |
| `TRIGGER` | 0x80 | `src/aes/rtl/aes_reg_pkg.sv` offset table |
| `STATUS` | 0x84 | `src/aes/rtl/aes_reg_pkg.sv` offset table |
| `STATUS.idle` bit 0 | 0 | `src/aes/rtl/aes_reg_top.sv` status read arm |
| `STATUS.output_lost` bit 2 | 2 | `src/aes/rtl/aes_reg_top.sv:1836` |
| `STATUS.output_valid` bit 3 | 3 | `src/aes/rtl/aes_reg_top.sv` status read arm |
| `STATUS.input_ready` bit 4 | 4 | `src/aes/rtl/aes_reg_top.sv` status read arm |
| `CTRL.operation` bit 0 | 0 | `src/aes/rtl/aes_reg_top.sv` ctrl_shadowed field map |
| `CTRL.mode` bits 2 and up | 0x105 composite | `src/aes/rtl/aes_reg_top.sv` ctrl_shadowed field map |
| `CTRL.key_len` bit 8 | 8 | `src/aes/rtl/aes_reg_top.sv` ctrl_shadowed field map |

## Why no C test is submitted

The defect is in the presentation of `hw2reg.data_out` inside the `aes` block, and
the routing inputs that select that presentation, `caliptra2aes.kv_en` and
`caliptra2aes.block_reg_output`, arrive on the block's port boundary from
`aes_clp_wrapper`. Reaching the exposed state from a C program on a core would
additionally require driving the KeyVault write-control register and the OCP LOCK
state through the full subsystem, which broadens the witness well beyond the
line under test. Driving those two inputs at the `aes` port boundary isolates the
defect to its arming expression, which is what the claim is about.

## Note on the CTRL readback

The testbench compares the `CTRL_SHADOWED` readback against a mask of
`0x0000_01FF` rather than the full word. `PRNG_RESEED_RATE` reads back as bit 12
because the hardware substitutes a valid default when the written field is
`3'b000`, so a full-word comparison would fail for a reason unrelated to the
claim. Only the operation, mode and key-length fields are compared.
