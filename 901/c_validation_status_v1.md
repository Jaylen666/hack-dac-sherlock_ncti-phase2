# C validation status — BUG-N-001

- **bug_id:** N-001
- **module:** soc_ifc
- **status:** `not_applicable_jtag_interface`
- **defect site:** `src/soc_ifc/rtl/soc_ifc_top.sv:828`

## Why no C test applies

This defect is not reachable from software running on the Caliptra core. The
write qualifier under test is driven entirely from the uncore DMI port, which is
a JTAG-side interface, not an MMIO register the core can write. The register
itself is software read-only: its field definition in
[soc_ifc_subsystem_reg.rdl:143](../../src/soc_ifc/rtl/soc_ifc_subsystem_reg.rdl#L143)
is `sw = r; hw = rw; we`, so no software store can reach it and there is nothing
for a C test to drive.

The attack surface is a physical JTAG attacker instead, and the whole path is
inside RTL. That path is exercised end to end in the directed simulation, which
drives the real `soc_ifc_top` DMI port and reads the resulting
`cptra_ss_debug_intent` output. A C test would add nothing that the simulation
does not already show.

## Checked paths

| # | What is needed | Witness | Verified content |
|---|---|---|---|
| 1 | The field is software read-only, so software cannot be the actor | [soc_ifc_subsystem_reg.rdl:143](../../src/soc_ifc/rtl/soc_ifc_subsystem_reg.rdl#L143) | `field strap {sw = r; hw = rw; we; resetsignal = cptra_pwrgood;} debug_intent=1'b0;` |
| 2 | The documented access policy restricts TAP writes to debug/manuf mode | [soc_ifc_subsystem_reg.rdl:142](../../src/soc_ifc/rtl/soc_ifc_subsystem_reg.rdl#L142) | `TAP Access [in debug/manuf mode]: RW` |
| 3 | The DMI port is the only write path, and it is JTAG-side | [caliptra_top.sv:632-633](../../src/integration/rtl/caliptra_top.sv#L632-L633) | `.dmi_uncore_en` / `.dmi_uncore_wr_en` driven from the JTAG debug module |
| 4 | Those signals reach the audited block | [caliptra_top.sv:1528-1529](../../src/integration/rtl/caliptra_top.sv#L1528-L1529) | `.cptra_uncore_dmi_reg_en` / `.cptra_uncore_dmi_reg_wr_en` on the `soc_ifc_top` instance |
| 5 | The matching address is a deliberate non-zero constant | [soc_ifc_pkg.sv:96](../../src/soc_ifc/rtl/soc_ifc_pkg.sv#L96) | `parameter DMI_REG_SS_DEBUG_INTENT = 7'h63;` |
| 6 | The written data is attacker-chosen | [soc_ifc_top.sv:891](../../src/soc_ifc/rtl/soc_ifc_top.sv#L891) | `debug_intent.next` takes `cptra_uncore_dmi_reg_wdata[0]` in subsystem mode |
| 7 | The lifecycle restriction lives in the term the defect inverts | [soc_ifc_top.sv:774-776](../../src/soc_ifc/rtl/soc_ifc_top.sv#L774-L776) | `cptra_uncore_dmi_unlocked_reg_en` gated on `~debug_locked` or `DEVICE_MANUFACTURING` |
| 8 | The resulting flag is consumed by the debug-unlock request path | [soc_ifc_top.sv:924-925](../../src/soc_ifc/rtl/soc_ifc_top.sv#L924-L925) | `MANUF_DBG_UNLOCK_REQ.swwe` / `PROD_DBG_UNLOCK_REQ.swwe` |

All eight were dereferenced against the files in this tree at packaging time.

## What software does become able to do

Although software cannot trigger the defect, it is a beneficiary of it. Once a
JTAG-side attacker sets `debug_intent` on a debug-locked production part, the
gating at [soc_ifc_top.sv:924-925](../../src/soc_ifc/rtl/soc_ifc_top.sv#L924-L925)
opens `MANUF_DBG_UNLOCK_REQ` and `PROD_DBG_UNLOCK_REQ` to software writes, and
[soc_ifc_top.sv:946](../../src/soc_ifc/rtl/soc_ifc_top.sv#L946) releases the
write lock on `SS_SOC_DBG_UNLOCK_LEVEL`. So the defect converts a physical
foothold into new software-writable security state. That consequence is argued
from the gating expressions rather than exercised by firmware here.

## Residual gap

The simulation is at block boundary on `soc_ifc_top`. It establishes that the
flag is set with no DMI write asserted and that a legitimate write is ignored,
but it does not carry the sequence forward through the full debug-unlock
handshake, which involves authenticated payload checks outside this block. The
claim made is about the policy flag being attacker-controlled, not about
completing an unlock.
