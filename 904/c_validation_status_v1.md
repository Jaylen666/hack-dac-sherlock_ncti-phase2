# C validation status — BUG-N-004

- **bug_id:** N-004
- **module:** soc_ifc
- **status:** `software_reachable_not_exercised_in_c`
- **defect site:** `src/soc_ifc/rtl/soc_ifc_fuse_reg.rdl:147` (field type) and `src/soc_ifc/rtl/soc_ifc_top.sv:557-559`

## Why this is different from a JTAG-only defect

Both halves of this attack are software-addressable, so unlike a JTAG-side
finding there is no structural reason a C test could not exist. The trigger and
the readback are both ordinary loads and stores from the core:

| Step | Address | Symbol |
|---|---|---|
| Raise the scrubbing event | `0x30030008` | [caliptra_reg.h:10669](../../src/integration/rtl/caliptra_reg/caliptra_reg.h#L10669) `CLP_SOC_IFC_REG_CPTRA_FW_ERROR_FATAL` |
| Read the surviving seed | `0x300303c0` | [caliptra_reg.h:11509](../../src/integration/rtl/caliptra_reg/caliptra_reg.h#L11509) `CLP_SOC_IFC_REG_FUSE_HEK_SEED_0` |

Writing a non-masked new bit to the first asserts `cptra_error_fatal`
([soc_ifc_top.sv:1090-1092](../../src/soc_ifc/rtl/soc_ifc_top.sv#L1090-L1092)),
which is one of the three terms of the scrubbing strobe
([caliptra_top.sv:772](../../src/integration/rtl/caliptra_top.sv#L772)). That
register's documented access is `Caliptra Access: RW`
([soc_ifc_external_reg.rdl:65](../../src/soc_ifc/rtl/soc_ifc_external_reg.rdl#L65)),
so firmware is a permitted writer.

## Why the proof is at RTL rather than in C

The claim being proved is a property of one register field: that it has no
hardware clear while its siblings do. Establishing that in C would require the
HEK fuse to hold known non-zero material first, and the fuse's Caliptra-side
access is read-only
([soc_ifc_fuse_reg.rdl:145](../../src/soc_ifc/rtl/soc_ifc_fuse_reg.rdl#L145)) —
programming it is a SOC-side action (`SOC Access: RWL-S`, `:146`), not something
firmware can do. A C test would therefore depend on external fuse provisioning to
produce a distinguishable value, and on the surrounding integration to deliver
the strobe, neither of which is what is in question.

The directed simulation drives both families side by side through the real
`soc_ifc_reg` bus, so the asymmetry is observed directly: the same strobe, the
same DUT, the same clock, one family cleared and the other not. That is a
stronger statement about the field than a firmware sequence would be, and it is
what the negative control inverts.

## Checked paths

| # | What is needed | Witness | Verified content |
|---|---|---|---|
| 1 | The audited field type has no hardware clear | [soc_ifc_fuse_reg.rdl:21](../../src/soc_ifc/rtl/soc_ifc_fuse_reg.rdl#L21) | `field Fuse {sw = rw; hw = r; swwel; resetsignal = cptra_pwrgood;};` |
| 2 | The sibling type does | [soc_ifc_fuse_reg.rdl:19](../../src/soc_ifc/rtl/soc_ifc_fuse_reg.rdl#L19) | `field secret {... hwclr; resetsignal = cptra_pwrgood;};` |
| 3 | The HEK fuse uses the type without it | [soc_ifc_fuse_reg.rdl:147](../../src/soc_ifc/rtl/soc_ifc_fuse_reg.rdl#L147) | `Fuse seed[32]=0;` inside `fuse_hek_seed` |
| 4 | The block drives a clear for its siblings only | [soc_ifc_top.sv:542](../../src/soc_ifc/rtl/soc_ifc_top.sv#L542) | `fuse_uds_seed[i].seed.hwclr = clear_obf_secrets` |
| 5 | The HEK loop assigns none | [soc_ifc_top.sv:557-559](../../src/soc_ifc/rtl/soc_ifc_top.sv#L557-L559) | reads `.seed.value` out and nothing else |
| 6 | There is no clear port to drive | [soc_ifc_reg_pkg.sv:304-306](../../src/soc_ifc/rtl/soc_ifc_reg_pkg.sv#L304-L306) | `Fuse_w32__in_t` has one member, `swwel` |
| 7 | The generated field has no clear branch | [soc_ifc_reg.sv:4066-4088](../../src/soc_ifc/rtl/soc_ifc_reg.sv#L4066-L4088) | SW write arm plus a `cptra_pwrgood` reset arm only |
| 8 | The residue is software-readable | [soc_ifc_reg.sv:7450](../../src/soc_ifc/rtl/soc_ifc_reg.sv#L7450) | readback returns `field_storage.fuse_hek_seed[i0].seed.value` |
| 9 | The strobe is reachable from firmware | [soc_ifc_external_reg.rdl:65](../../src/soc_ifc/rtl/soc_ifc_external_reg.rdl#L65) | `Caliptra Access: RW` on `CPTRA_FW_ERROR_FATAL` |
| 10 | The seed feeds the DOE HEK flow | [doe_fsm.sv:276](../../src/doe/rtl/doe_fsm.sv#L276) | `running_hek ? obf_hek_seed[...]` |

All ten were dereferenced against the files in this tree at packaging time.

## Residual gap

The firmware trigger path is argued from the register's documented access and the
assertion logic at
[soc_ifc_top.sv:1090-1092](../../src/soc_ifc/rtl/soc_ifc_top.sv#L1090-L1092)
rather than executed. The simulation raises the strobe directly at the block
boundary, which is the same signal that path produces. Nothing here carries the
surviving seed through the DOE to a derived key.
