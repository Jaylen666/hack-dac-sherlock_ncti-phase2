# C validation status — BUG-004

- **bug_id:** 004
- **module:** aes_reg_top
- **status:** `header_witness`

## Conclusion

Every step of this defect is firmware-addressable, and so is the observation. The
whole sequence is three kinds of MMIO access at offsets the generated register
package declares: poll `AES_STATUS.IDLE`, write the sixteen key-share words, read
those same sixteen addresses. No new C test was compiled for this submission, but
there is no gap between what the unit-level witness measures and what firmware
would see: the testbench drives the same register bus at the same offsets, and the
defect is in the read response itself rather than in a timing relationship or an
internal signal that only a testbench can reach.

The observation is also not cycle-sensitive. `src/aes/rtl/aes_reg_top.sv:1735-1765`
selects the response source combinationally for as long as the address is decoded,
so a driver reading the address at any time gets the same answer. A firmware
conformance test asserting write-only-reads-zero would fail on the first read.

Reachability here means ordinary unprivileged firmware reaches the defective
condition and its software-visible consequence through documented registers. It
does **not** mean firmware reaches a protected asset: see "Not claimed".

## Checked paths

Fourteen paths were checked to establish that the sequence is expressible in C
against the audited tree, and that the observation firmware would make is the one
the witness makes.

1. `src/aes/data/aes.rdl:8` — KEY_SHARE0 fields declared `sw = w`, the policy a C
   conformance test would assert against.
2. `src/aes/data/aes.rdl:27` — KEY_SHARE1 fields declared `sw = w`.
3. `src/aes/data/aes.rdl:24` — KEY_SHARE0[8] placed at `0x04`.
4. `src/aes/data/aes.rdl:43` — KEY_SHARE1[8] placed at `0x24`.
5. `src/aes/data/aes.rdl:46` — IV fields declared `sw = rw`, the readable neighbour
   a C test would use as its own control.
6. `src/aes/rtl/aes_reg_pkg.sv:268` — `AES_KEY_SHARE0_0_OFFSET` at 4, so the
   address a driver would use is a declared offset rather than an assumed one.
7. `src/aes/rtl/aes_reg_pkg.sv` — `AES_KEY_SHARE1_0_OFFSET` likewise declared.
8. `src/aes/rtl/aes_reg_pkg.sv` — `AES_STATUS_OFFSET` declared, which is the idle
   precondition a driver must poll before loading keys.
9. `src/aes/rtl/aes_reg_top.sv:1735-1765` — the sixteen defective arms, with no
   privilege, lifecycle or debug qualifier anywhere in that range, so the read is
   available to unprivileged firmware.
10. `src/aes/rtl/aes_reg_top.sv:125` — the response reaches the bus directly from
    `reg_rdata_next`, so what firmware reads is what the multiplexer selected.
11. `src/aes/rtl/aes_reg_top.sv:1731-1733` — the constant-zero arm, which is the
    value a conformant read would return and therefore the expected value in a C
    assertion.
12. `src/caliptra_prim/rtl/caliptra_prim_subreg_ext.sv:27-28` — `qs = d` versus
    `q = wd`, which is why the value firmware reads back is its own bus data.
13. `src/caliptra_tlul/rtl/caliptra_tlul_adapter_reg.sv:84` — `wdata_o` from
    `tl_i.a_data`, the far end of that path from the requester's side.
14. `src/aes/rtl/aes_core.sv:1028-1029` — the loaded shares driving the
    hardware-side port, which is the value a disclosure would have to carry and
    which no C test could obtain through these addresses.

## Not claimed

Firmware reachability of the defect is not reachability of the key. The witness
measured this directly on the whole block: the readback carried the requester's
own A-channel data on every sampled address and changed when that data changed,
while the written key patterns never appeared. `src/aes/rtl/aes_reg_top.sv:298`
leaves the port carrying the loaded shares unconnected on all sixteen instances,
and no `key_share*_qs` signal exists in the file, so a C program reading these
addresses cannot obtain key material no matter how it is written. A C test would
demonstrate the same thing the SystemVerilog witness demonstrates: a write-only
address answers with non-zero data, and that data is the reader's own.

No C test was compiled or run for this submission. The status is
`header_witness`: the register-level sequence is expressible against the generated
header and every offset it needs is declared, but the evidence submitted is the
SystemVerilog witness, the structural audit and the negative control, not a
firmware binary.
