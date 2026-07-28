# C validation status — BUG-033

- **bug_id:** 033
- **module:** sha512
- **status:** `no_witness`

## Conclusion

No C test is offered for this submission, and unlike BUG-003 and BUG-005 that is
not a matter of evidence economy: the trigger for this bug is not a software
action at all. The digest wipe is driven by a hardware transition signal that
firmware cannot assert. The proof is therefore necessarily an RTL-level one, and
the software-reachable parts of the picture — the digest window and the ZEROIZE
control — are recorded below because they establish that the exposed asset is a
real, addressable register rather than an internal node.

## Checked paths

| Path | What it shows |
| --- | --- |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:7130` | `CLP_SHA512_REG_BASE_ADDR = 0x10020000`, so the SHA-512 block sits in the MMIO map. |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:7299` | `CLP_SHA512_REG_SHA512_DIGEST_0 = 0x10020100`, the window that should have been wiped. |
| `src/integration/rtl/caliptra_reg/caliptra_reg.h:7147` | `CLP_SHA512_REG_SHA512_CTRL = 0x10020010`, with `ZEROIZE` at bit 4, mask `0x10`. This is the software half of the strobe, and it still works. |
| `src/sha512/rtl/sha512_reg.rdl:83-85` | `ZEROIZE` is documented as "Zeroize all internal registers after SHA process, to avoid SCA leakage" and marked `singlepulse`. The security intent is stated in the tree's own specification. |
| `src/sha512/rtl/sha512_reg.rdl:130` | `default sw = rw` for the digest window, which is what makes the register software-writable and therefore usable as a probe in the testbench. |
| `src/sha512/rtl/sha512_reg.sv:916-918` | The DIGEST `hwclr` reaches a branch that drives the field to zero, so the strobe under test is live rather than decorative. |
| `src/sha512/rtl/sha512_reg_pkg.sv:6` | `SHA512_REG_DATA_WIDTH = 32`. The register block is a flat 32-bit interface even though the `sha512` wrapper carries 64-bit data ports; each DIGEST dword has its own 4-byte offset. This governs how the testbench drives the bus. |
| `src/integration/rtl/caliptra_top.sv:763-767` | The switch is formed from edge terms: an XOR on `debug_locked` and an and-not on the latched scan-mode signal. It is a transition pulse, not a steady state, which is why the claim is scoped to the transition. |
| `src/integration/rtl/caliptra_top.sv:770` | `debug_lock_or_scan_mode_switch = debug_lock_switch \| scan_mode_switch \| device_lifecycle_switch \| cptra_error_fatal` — four independent triggers, none of them a software write. |
| `src/integration/rtl/caliptra_top.sv` (9 sites) | The same signal is fanned out to `sha512_ctrl`, `sha256_ctrl`, `sha3_ctrl`, `doe_ctrl`, `ecc_top`, `hmac_ctrl`, `abr_top`, `aes_clp_wrapper` and `soc_ifc_top`. The wipe is a design-wide convention. |
| `src/hmac/rtl/hmac.sv:267` | HMAC still clears its TAG output from the single unmodified strobe — an in-tree control showing what the correct pattern looks like. |
| `src/sha256/rtl/sha256.sv:388-403` | The sibling block carries the structurally identical rewiring, which is why the mitigation covers both. Its digest window is `sw = r` (`sha256_reg.rdl:132`), so the software-write probe used here is not available there. |
| `src/integration/test_suites/` | No existing test in this tree seeds the digest window and then checks it against a debug or scan transition, so the condition is not covered by the current regression suite. |

## Rationale

`debugUnlock_or_scan_mode_switch` is derived at the top level from latched
security-state and scan-mode inputs. Firmware has no register that drives it, so
a C test running on the Caliptra core cannot create the precondition this bug
needs. Recording the status as `c_witness` would misrepresent what kind of bug
this is.

The unit-level testbench instead drives the signal directly, which is the only
way to exercise the case at all, and it is deliberately built to observe rather
than assume. It drives both polarities of the input and prints what the hardware
does in each, so the truth table is measured rather than derived from reading the
expression. The negative control then inverts every one of those observations on
patched RTL — quiescent retains, debug/scan wipes, software ZEROIZE wipes — while
the software-ZEROIZE control check keeps passing, which is what distinguishes "the
fix changed the behaviour" from "the harness broke".

Two limits are stated plainly. The switch is edge-derived, so what is proven is
that no clear happens on the transition, not that the digest persists for any
particular length of time afterwards. And the asset is a SHA-512 digest result:
what it discloses depends on what was hashed, and no key-recovery or forgery
chain is claimed.
