// BUG-N-004 directed witness: the OCP LOCK HEK seed fuse has no hardware clear
// path, so the secret-scrubbing strobe that clears every other DOE secret input
// leaves it resident.
//
// DUT is one unmodified soc_ifc_reg, driven only through its declared ports: the
// s_cpuif_* bus, the hwif_in structure and cptra_pwrgood inside it. There is no
// force, no deposit and no hierarchical assignment to any DUT signal, and every
// observation is read from hwif_out or from a bus read.
//
// soc_ifc_reg is the correct unit for this defect. The missing clear is a
// property of the register field itself: src/soc_ifc/rtl/soc_ifc_fuse_reg.rdl
// declares fuse_hek_seed with the Fuse field type (line 21), which carries no
// hwclr, while fuse_uds_seed and fuse_field_entropy use the secret type (line
// 19), which does. That choice propagates into this generated block, where the
// HEK storage element has a pwrgood reset arm and nothing else. Driving both
// families side by side through one bus is what makes the asymmetry visible.

`default_nettype none

module soc_ifc_reg_bug_N004_tb;

  import soc_ifc_reg_pkg::*;

  localparam int HEK_DWORDS = 8;   // src/keyvault/rtl/kv_defines_pkg.sv:43
  localparam int UDS_DWORDS = 16;  // fuse_uds_seed[16] in the RDL
  localparam int FE_DWORDS  = 8;   // fuse_field_entropy[8] in the RDL

  // Byte addresses decoded by this block, taken from the generated decode:
  //   src/soc_ifc/rtl/soc_ifc_reg.sv:288  fuse_uds_seed      @ 12'h200 + i*4
  //   src/soc_ifc/rtl/soc_ifc_reg.sv:291  fuse_field_entropy @ 12'h240 + i*4
  //   src/soc_ifc/rtl/soc_ifc_reg.sv:320  fuse_hek_seed      @ 12'h3c0 + i*4
  localparam logic [11:0] ADDR_UDS = 12'h200;
  localparam logic [11:0] ADDR_FE  = 12'h240;
  localparam logic [11:0] ADDR_HEK = 12'h3c0;

  logic clk = 1'b0;
  logic rst;
  logic pwrgood;

  logic        cpuif_req;
  logic        cpuif_req_is_wr;
  logic [11:0] cpuif_addr;
  logic [31:0] cpuif_wr_data;
  logic [31:0] cpuif_wr_biten;
  logic        cpuif_rd_ack;
  logic        cpuif_rd_err;
  logic [31:0] cpuif_rd_data;
  logic        cpuif_wr_ack;
  logic        cpuif_wr_err;
  logic        cpuif_stall_wr, cpuif_stall_rd;

  soc_ifc_reg__in_t  hwif_in;
  soc_ifc_reg__out_t hwif_out;

  // The secret-scrubbing strobe under test. In the integration this is
  // clear_obf_secrets_debugScanQ (src/integration/rtl/caliptra_top.sv:772),
  // which is clear_obf_secrets | cptra_in_debug_scan_mode | cptra_error_fatal,
  // delivered to the block at :1466. Here it is a TB-side signal fanned into
  // exactly the hwif_in hwclr members that src/soc_ifc/rtl/soc_ifc_top.sv:542
  // and :550 drive from it.
  logic clear_obf_secrets;

  always #5 clk = ~clk;

  soc_ifc_reg dut (
    .clk                  (clk),
    .rst                  (rst),
    .s_cpuif_req          (cpuif_req),
    .s_cpuif_req_is_wr    (cpuif_req_is_wr),
    .s_cpuif_addr         (cpuif_addr),
    .s_cpuif_wr_data      (cpuif_wr_data),
    .s_cpuif_wr_biten     (cpuif_wr_biten),
    .s_cpuif_req_stall_wr (cpuif_stall_wr),
    .s_cpuif_req_stall_rd (cpuif_stall_rd),
    .s_cpuif_rd_ack       (cpuif_rd_ack),
    .s_cpuif_rd_err       (cpuif_rd_err),
    .s_cpuif_rd_data      (cpuif_rd_data),
    .s_cpuif_wr_ack       (cpuif_wr_ack),
    .s_cpuif_wr_err       (cpuif_wr_err),
    .hwif_in              (hwif_in),
    .hwif_out             (hwif_out)
  );

  // --------------------------------------------------------------------------
  // hwif_in drive. Everything defaults to zero, then the members that
  // soc_ifc_top drives from the scrubbing strobe are connected to it. This
  // mirrors src/soc_ifc/rtl/soc_ifc_top.sv:542 and :550 for the two fuse
  // families that have a clear. It reproduces the audited omission for HEK by
  // the only means available: the generated in_t for the Fuse field type has no
  // hwclr member at all (src/soc_ifc/rtl/soc_ifc_reg_pkg.sv:304-306, 384-386),
  // so this TB could not connect one even if it tried.
  // --------------------------------------------------------------------------
  always_comb begin
    hwif_in = '0;
    hwif_in.cptra_pwrgood = pwrgood;

    for (int i = 0; i < UDS_DWORDS; i++) begin
      hwif_in.fuse_uds_seed[i].seed.hwclr = clear_obf_secrets;
      hwif_in.fuse_uds_seed[i].seed.swwel = 1'b0;  // fuse write window open
    end
    for (int i = 0; i < FE_DWORDS; i++) begin
      hwif_in.fuse_field_entropy[i].seed.hwclr = clear_obf_secrets;
      hwif_in.fuse_field_entropy[i].seed.swwel = 1'b0;
    end
    for (int i = 0; i < HEK_DWORDS; i++) begin
      // Only swwel exists on this family in the audited tree.
      // src/soc_ifc/rtl/soc_ifc_top.sv:739 drives exactly this one member and
      // nothing else.
      hwif_in.fuse_hek_seed[i].seed.swwel = 1'b0;
`ifdef BUG_N004_HEK_HAS_HWCLR
      // Compiled only by the negative control, which adds the hwclr member to
      // the Fuse_w32 input struct. This is the fix under test: the HEK family
      // joins the same strobe its siblings are already on. On the audited run
      // this define is absent and the code below does not exist, so it cannot
      // mask the defect.
      hwif_in.fuse_hek_seed[i].seed.hwclr = clear_obf_secrets;
`endif
    end
  end

  int checks = 0;
  int fails  = 0;
  int witness_hits = 0;

  bit cov_reset_clear        = 0;
  bit cov_write_takes_effect = 0;
  bit cov_siblings_scrubbed  = 0;
  bit cov_hek_survives_scrub = 0;
  bit cov_pwrgood_clears_hek = 0;

  task automatic step(input int n = 1);
    repeat (n) @(negedge clk);
  endtask

  task automatic check(input string name, input bit ok);
    checks++;
    if (ok) begin
      $display("case=%s PASS", name);
    end else begin
      fails++;
      $display("TBFAIL case=%s", name);
    end
  endtask

  // Single-beat write on the generated CPU interface. Read and write latencies
  // are balanced and both stall outputs are tied off
  // (src/soc_ifc/rtl/soc_ifc_reg.sv:57-59), so one cycle with req high is a
  // complete transaction.
  task automatic bus_write(input logic [11:0] a, input logic [31:0] d);
    @(negedge clk);
    cpuif_req       = 1'b1;
    cpuif_req_is_wr = 1'b1;
    cpuif_addr      = a;
    cpuif_wr_data   = d;
    cpuif_wr_biten  = 32'hFFFF_FFFF;
    @(negedge clk);
    cpuif_req       = 1'b0;
    cpuif_req_is_wr = 1'b0;
    cpuif_addr      = 12'h0;
    cpuif_wr_data   = 32'h0;
    cpuif_wr_biten  = 32'h0;
  endtask

  task automatic bus_read(input logic [11:0] a, output logic [31:0] d);
    @(negedge clk);
    cpuif_req       = 1'b1;
    cpuif_req_is_wr = 1'b0;
    cpuif_addr      = a;
    @(posedge clk);
    #1;
    d = cpuif_rd_data;
    @(negedge clk);
    cpuif_req  = 1'b0;
    cpuif_addr = 12'h0;
  endtask

  // Aggregate helpers reading the block's own outputs.
  function automatic bit hek_all_zero();
    for (int i = 0; i < HEK_DWORDS; i++)
      if (hwif_out.fuse_hek_seed[i].seed.value != 32'h0) return 1'b0;
    return 1'b1;
  endfunction

  function automatic bit uds_all_zero();
    for (int i = 0; i < UDS_DWORDS; i++)
      if (hwif_out.fuse_uds_seed[i].seed.value != 32'h0) return 1'b0;
    return 1'b1;
  endfunction

  function automatic bit fe_all_zero();
    for (int i = 0; i < FE_DWORDS; i++)
      if (hwif_out.fuse_field_entropy[i].seed.value != 32'h0) return 1'b0;
    return 1'b1;
  endfunction

  logic [31:0] rd;

  initial begin
    cpuif_req         = 1'b0;
    cpuif_req_is_wr   = 1'b0;
    cpuif_addr        = 12'h0;
    cpuif_wr_data     = 32'h0;
    cpuif_wr_biten    = 32'h0;
    clear_obf_secrets = 1'b0;

    // ---- cold reset ----
    pwrgood = 1'b0;
    rst     = 1'b1;
    step(4);
    pwrgood = 1'b1;
    rst     = 1'b0;
    step(4);

    // Control 1: the harness can observe the cleared state at all.
    $display("    after cold reset -> hek_all_zero=%0b uds_all_zero=%0b fe_all_zero=%0b",
             hek_all_zero(), uds_all_zero(), fe_all_zero());
    check("control_reset_leaves_all_secrets_clear",
          hek_all_zero() && uds_all_zero() && fe_all_zero());
    if (hek_all_zero() && uds_all_zero() && fe_all_zero()) cov_reset_clear = 1;

    // ---- load the three families of DOE secret input ----
    // The HEK fuse is Caliptra Access: RO and SOC Access: RWL-S per the RDL
    // (src/soc_ifc/rtl/soc_ifc_fuse_reg.rdl:141-142), so this models SOC-side
    // fuse programming before the write-done lock is set. Distinct non-zero
    // patterns per dword so a stale read cannot pass for a live one.
    for (int i = 0; i < HEK_DWORDS; i++)
      bus_write(ADDR_HEK + i*4, 32'hDEC0_0000 + i);
    for (int i = 0; i < UDS_DWORDS; i++)
      bus_write(ADDR_UDS + i*4, 32'h0D50_0000 + i);
    for (int i = 0; i < FE_DWORDS; i++)
      bus_write(ADDR_FE  + i*4, 32'h0FE0_0000 + i);
    step(2);

    $display("    after fuse programming -> hek[0]=%08h uds[0]=%08h fe[0]=%08h",
             hwif_out.fuse_hek_seed[0].seed.value,
             hwif_out.fuse_uds_seed[0].seed.value,
             hwif_out.fuse_field_entropy[0].seed.value);

    // Control 2: without this the run could be vacuous, because a secret that
    // was never loaded is trivially clear after the scrub.
    check("control_fuse_programming_takes_effect",
          !hek_all_zero() && !uds_all_zero() && !fe_all_zero());
    if (!hek_all_zero() && !uds_all_zero() && !fe_all_zero()) cov_write_takes_effect = 1;

    // ---- assert the secret-scrubbing strobe ----
    // This is the debug-unlock / scan-mode / fatal-error event.
    clear_obf_secrets = 1'b1;
    step(4);

    $display("    with clear_obf_secrets asserted -> uds_all_zero=%0b fe_all_zero=%0b hek[0]=%08h",
             uds_all_zero(), fe_all_zero(), hwif_out.fuse_hek_seed[0].seed.value);

    // Control 3: the two families that carry hwclr must scrub. If this fails the
    // strobe reached nothing and the HEK observation below would prove nothing.
    check("control_sibling_secrets_are_scrubbed", uds_all_zero() && fe_all_zero());
    if (uds_all_zero() && fe_all_zero()) cov_siblings_scrubbed = 1;

    // The defect: HEK seed is still resident on the same strobe.
    if (!hek_all_zero()) begin
      witness_hits++;
      $display("    OBSERVED: BUG_N004_WITNESS_OBSERVED HEK seed still resident after the strobe that cleared every sibling DOE secret");
      cov_hek_survives_scrub = 1;
    end
    check("violating_hek_seed_survives_secret_scrub", hek_all_zero());

    // Hold the strobe much longer: the residue is not a latency artefact.
    step(50);
    $display("    after 50 further cycles with the strobe still high -> hek[0]=%08h",
             hwif_out.fuse_hek_seed[0].seed.value);
    check("violating_hek_residue_persists_while_strobe_held", hek_all_zero());

    // The surviving secret is software-visible, not merely internal state. The
    // generated readback path at src/soc_ifc/rtl/soc_ifc_reg.sv:7450 returns the
    // stored value.
    bus_read(ADDR_HEK, rd);
    $display("    bus readback of fuse_hek_seed[0] after the strobe -> %08h", rd);
    check("violating_surviving_hek_seed_is_readable_over_the_bus", rd == 32'h0);

    // ---- containment ----
    clear_obf_secrets = 1'b0;
    step(2);
    pwrgood = 1'b0;
    step(4);
    pwrgood = 1'b1;
    step(4);
    $display("    after pwrgood cold reset -> hek_all_zero=%0b", hek_all_zero());
    check("containment_pwrgood_reset_clears_hek", hek_all_zero());
    if (hek_all_zero()) cov_pwrgood_clears_hek = 1;

    $display("cov_reset_clear=%0d",        cov_reset_clear);
    $display("cov_write_takes_effect=%0d", cov_write_takes_effect);
    $display("cov_siblings_scrubbed=%0d",  cov_siblings_scrubbed);
    $display("cov_hek_survives_scrub=%0d", cov_hek_survives_scrub);
    $display("cov_pwrgood_clears_hek=%0d", cov_pwrgood_clears_hek);
    $display("witness_hits=%0d", witness_hits);
    $display("checks=%0d fails=%0d", checks, fails);

    // On the audited RTL exactly the three violating checks fail and the witness
    // fires once. The negative control, which gives the HEK family a real hwclr,
    // must drive fails to 0 and witness_hits to 0 while keeping all three
    // controls and the containment case passing.
    if (checks == 7 && fails == 3 && witness_hits == 1 &&
        cov_reset_clear && cov_write_takes_effect && cov_siblings_scrubbed &&
        cov_hek_survives_scrub && cov_pwrgood_clears_hek) begin
      $display("result=PASS");
      $display("PROOF_RESULT: PASS");
    end else begin
      $display("result=NOT_THE_AUDITED_SIGNATURE");
      $display("PROOF_RESULT: SIGNATURE_MISMATCH");
    end
    $finish;
  end

  // Global timeout so a hang is reported rather than silently ending the run.
  initial begin
    #200000;
    $display("TBFAIL global timeout");
    $display("PROOF_RESULT: TIMEOUT");
    $finish;
  end

endmodule

`default_nettype wire
