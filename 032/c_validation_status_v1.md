# C validation status — BUG-032

- **bug_id:** 032
- **module:** sha256
- **status:** `header_witness`

## Conclusion

Every input this defect needs is firmware-addressable through the generated
Caliptra register header, and so is the observation. The message block, the start
command and the digest window are all plain MMIO registers in the SHA-256 block's
aperture, and the testbench drives exactly that interface through the module's own
`cs`/`we`/`address` bus. No new C test was compiled for this submission. The
reachability claim rests on the generated header; the behavioural claim, that a
completed hash leaves the digest window reading all zeros while `STATUS.VALID`
reports success, rests on the unit-level simulation and its negative control.

Note that reachability here means an ordinary firmware operation reaches the defect
and silently receives a wrong result, not that an attacker reaches a protected
asset. See the "Not claimed" section.

## Checked paths

| Path | What it shows |
| --- | --- |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:7658` | `CLP_SHA256_REG_BASE_ADDR = 0x10028000`, so the block under test sits in the MMIO map firmware can address. |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:7703` | `CLP_SHA256_REG_SHA256_BLOCK_0 = 0x10028080`, the message-block window the witness writes. |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:7675` | `CLP_SHA256_REG_SHA256_CTRL = 0x10028010`, the register that starts the hash. |
| `src/integration/rtl/caliptra_reg/caliptra_reg_field_defines.svh:6053-6060` | `CTRL.INIT` is bit 0, `MODE` is bit 2 and `ZEROIZE` is bit 3, so the witness sequence is expressible as two firmware register writes. |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:7693` | `CLP_SHA256_REG_SHA256_STATUS = 0x10028018`, the register firmware polls before reading the result. |
| `src/integration/rtl/caliptra_reg/caliptra_reg_field_defines.svh:6072-6073` | `STATUS.VALID` is bit 1, the bit that reports the digest ready while the window is held at zero. |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:7767` | `CLP_SHA256_REG_SHA256_DIGEST_0 = 0x10028100`, the eight-dword window that cannot return the result. |
| `src/sha256/rtl/sha256.sv:414-431` | The wrapper wires `cs` to `s_cpuif_req` and `we` to `s_cpuif_req_is_wr` with `s_cpuif_wr_biten` tied high, so the bus the testbench drives is the one firmware reaches. |
| `src/sha256/rtl/sha256_reg.rdl:131-135` | The `DIGEST` field is `sw = r` with a hardware clear, so firmware has no write path by which it could work around the held clear. |

## Not claimed

No security claim is made here, and no C test was run against an integrated
Caliptra image. What the header establishes is that ordinary firmware can start a
SHA-256 hash and will read zeros back from the digest window with no error
indication. It does not establish, and the accompanying simulation actively
refutes, any path by which digest material is disclosed through this defect: the
containment probe pulses `debugUnlock_or_scan_mode_switch` in its real
edge-detected shape and the window still reads all-zero, because the internal
`digest_reg` is cleared from the correctly-driven strobe on the same edge. See
`proof_result_v1.json` for the containment result and the priority argument that
together set the severity.
