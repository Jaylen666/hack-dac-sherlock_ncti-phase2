// BUG-N-001 directed witness: soc_ifc_top SS_DEBUG_INTENT write qualifier polarity.
//
// One real soc_ifc_top is instantiated and driven only through its declared
// ports. There is no force, no deposit and no hierarchical assignment to any
// DUT signal: the observation is taken from the DUT's own cptra_ss_debug_intent
// output port, which src/soc_ifc/rtl/soc_ifc_top.sv:897 drives from the
// SS_DEBUG_INTENT register value.
//
// The property under test is that debug_intent may only be written by a DMI
// write that is actually asserted. The audited write qualifier at
// src/soc_ifc/rtl/soc_ifc_top.sv:828-830 reduces to
// (~wr_en & addr == DMI_REG_SS_DEBUG_INTENT), so the register is written when
// no DMI write is in flight, and is not written when a legitimate one is. Both
// halves of that inversion are checked here.

`default_nettype none

module soc_ifc_top_bug_N001_tb
  import soc_ifc_pkg::*;
  import mbox_pkg::*;
  import axi_pkg::*;
  import kv_defines_pkg::*;
  import caliptra_prim_mubi_pkg::*;
  ();

  // ---------------- parameters, mirrored from the project's own TB ----------
  parameter AHB_ADDR_WIDTH  = `CALIPTRA_SLAVE_ADDR_WIDTH(`CALIPTRA_SLAVE_SEL_SOC_IFC);
  parameter AHB_DATA_WIDTH  = `CALIPTRA_AHB_HDATA_SIZE;
  parameter AXI_ADDR_WIDTH  = `CALIPTRA_SLAVE_ADDR_WIDTH(`CALIPTRA_SLAVE_SEL_SOC_IFC);
  parameter AXI_DATA_WIDTH  = `CALIPTRA_AXI_DATA_WIDTH;
  parameter AXI_ID_WIDTH    = `CALIPTRA_AXI_ID_WIDTH;
  parameter AXI_USER_WIDTH  = `CALIPTRA_AXI_USER_WIDTH;
  parameter AXIM_ADDR_WIDTH = `CALIPTRA_AXI_DMA_ADDR_WIDTH;
  parameter AXIM_DATA_WIDTH = CPTRA_AXI_DMA_DATA_WIDTH;
  parameter AXIM_ID_WIDTH   = CPTRA_AXI_DMA_ID_WIDTH;
  parameter AXIM_USER_WIDTH = CPTRA_AXI_DMA_USER_WIDTH;

  // ---------------- clock / reset ------------------------------------------
  logic clk;
  logic cptra_pwrgood;
  logic cptra_rst_b;

  initial clk = 1'b0;
  always #5 clk = ~clk;

  // ---------------- DUT connections ----------------------------------------
  security_state_t security_state;

  logic        ready_for_fuses, ready_for_mb_processing;
  logic        mailbox_data_avail;
  logic [63:0] generic_input_wires;

  logic [AHB_ADDR_WIDTH-1:0] haddr_i;
  logic [AHB_DATA_WIDTH-1:0] hwdata_i;
  logic                      hsel_i, hwrite_i, hready_i;
  logic [1:0]                htrans_i;
  logic [2:0]                hsize_i;
  logic                      hresp_o, hreadyout_o;
  logic [AHB_DATA_WIDTH-1:0] hrdata_o;

  cptra_mbox_sram_req_t  mbox_sram_req;
  cptra_mbox_sram_resp_t mbox_sram_resp;

  logic                                     clear_obf_secrets, scan_mode;
  logic [`CLP_OBF_KEY_DWORDS-1:0][31:0]     cptra_obf_key_reg;
  logic [`CLP_OBF_FE_DWORDS-1:0][31:0]      obf_field_entropy;
  logic [`CLP_OBF_UDS_DWORDS-1:0][31:0]     obf_uds_seed;
  logic [OCP_LOCK_HEK_NUM_DWORDS-1:0][31:0] obf_hek_seed;

  kv_read_t    kv_read;
  kv_rd_resp_t kv_rd_resp = '{error: 1'b0, last: 1'b0, read_data: '0};

  soc_ifc_req_t              aes_req_data;
  logic                      aes_req_dv, aes_req_hold;
  logic [SOC_IFC_DATA_W-1:0] aes_rdata;

  logic cptra_noncore_rst_b, cptra_uc_rst_b;
  logic ss_debug_intent;
  logic cptra_ss_debug_intent;

  // the DMI port, the attacker-facing surface under test
  logic        dmi_reg_en;
  logic        dmi_reg_wr_en;
  logic [31:0] dmi_reg_rdata;
  logic [6:0]  dmi_reg_addr;
  logic [31:0] dmi_reg_wdata;

  // Mailbox SRAM model: the DUT needs a responsive SRAM to leave reset
  // cleanly. Not part of the property under test.
  logic [CPTRA_MBOX_DATA_AND_ECC_W-1:0] mbox_ram [0:CPTRA_MBOX_DEPTH-1];
  always @(posedge clk) begin
    if (mbox_sram_req.cs && mbox_sram_req.we)
      mbox_ram[mbox_sram_req.addr] <= mbox_sram_req.wdata;
    if (mbox_sram_req.cs && !mbox_sram_req.we)
      mbox_sram_resp.rdata <= mbox_ram[mbox_sram_req.addr];
  end

  assign hready_i = hreadyout_o;

  axi_if #(.AW(AXIM_ADDR_WIDTH), .DW(AXIM_DATA_WIDTH),
           .IW(AXIM_ID_WIDTH),   .UW(AXIM_USER_WIDTH))
         m_axi_if (.clk(clk), .rst_n(cptra_rst_b));
  axi_if #(.AW(AXI_ADDR_WIDTH), .DW(AXI_DATA_WIDTH),
           .IW(AXI_ID_WIDTH),   .UW(AXI_USER_WIDTH))
         s_axi_if (.clk(clk), .rst_n(cptra_rst_b));

  // Quiescent AXI: no transactions are needed to exercise the DMI path.
  initial begin
    s_axi_if.awvalid = 1'b0; s_axi_if.wvalid = 1'b0; s_axi_if.bready = 1'b0;
    s_axi_if.arvalid = 1'b0; s_axi_if.rready = 1'b0;
    m_axi_if.awready = 1'b0; m_axi_if.wready = 1'b0; m_axi_if.bvalid = 1'b0;
    m_axi_if.bid = '0; m_axi_if.bresp = '0;
    m_axi_if.arready = 1'b0; m_axi_if.rvalid = 1'b0; m_axi_if.rdata = '0;
    m_axi_if.rid = '0; m_axi_if.rresp = '0; m_axi_if.rlast = 1'b0;
  end

  // ---------------- the one real DUT ---------------------------------------
  soc_ifc_top #(
      .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),   .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
      .AXI_ID_WIDTH(AXI_ID_WIDTH),       .AXI_USER_WIDTH(AXI_USER_WIDTH),
      .AXIM_ADDR_WIDTH(AXIM_ADDR_WIDTH), .AXIM_DATA_WIDTH(AXIM_DATA_WIDTH),
      .AXIM_ID_WIDTH(AXIM_ID_WIDTH),     .AXIM_USER_WIDTH(AXIM_USER_WIDTH),
      .AHB_DATA_WIDTH(AHB_DATA_WIDTH),   .AHB_ADDR_WIDTH(AHB_ADDR_WIDTH)
  ) dut (
      .clk(clk), .clk_cg(clk), .soc_ifc_clk_cg(clk), .rdc_clk_cg(clk),
      .cptra_pwrgood(cptra_pwrgood), .cptra_rst_b(cptra_rst_b),
      .ready_for_fuses(ready_for_fuses),
      .ready_for_mb_processing(ready_for_mb_processing),
      .ready_for_runtime(),
      .mailbox_data_avail(mailbox_data_avail), .mailbox_flow_done(),
      .recovery_data_avail(1'b0), .recovery_image_activated(1'b0),
      .security_state(security_state),
      .generic_input_wires(generic_input_wires),
      .BootFSM_BrkPoint(1'b0), .generic_output_wires(),
      .s_axi_w_if(s_axi_if.w_sub), .s_axi_r_if(s_axi_if.r_sub),
      .haddr_i(haddr_i), .hwdata_i(hwdata_i), .hsel_i(hsel_i),
      .hwrite_i(hwrite_i), .hready_i(hready_i), .htrans_i(htrans_i),
      .hsize_i(hsize_i), .hresp_o(hresp_o), .hreadyout_o(hreadyout_o),
      .hrdata_o(hrdata_o),
      .m_axi_w_if(m_axi_if.w_mgr), .m_axi_r_if(m_axi_if.r_mgr),
      .cptra_error_fatal(), .cptra_error_non_fatal(), .trng_req(),
      .soc_ifc_error_intr(), .soc_ifc_notif_intr(),
      .sha_error_intr(), .sha_notif_intr(),
      .dma_error_intr(), .dma_notif_intr(), .timer_intr(),
      .mbox_sram_req(mbox_sram_req), .mbox_sram_resp(mbox_sram_resp),
      .rv_ecc_sts(rv_ecc_sts_t'{default: 1'b0}),
      .debugUnlock_or_scan_mode_switch(1'b0),
      .clear_obf_secrets(clear_obf_secrets), .scan_mode(scan_mode),
      .cptra_obf_key('0), .cptra_obf_key_reg(cptra_obf_key_reg),
      .cptra_obf_field_entropy_vld(1'b0), .cptra_obf_field_entropy('0),
      .obf_field_entropy(obf_field_entropy),
      .cptra_obf_uds_seed_vld(1'b0), .cptra_obf_uds_seed('0),
      .obf_uds_seed(obf_uds_seed), .obf_hek_seed(obf_hek_seed),
      .aes_input_ready('0), .aes_output_valid('0), .aes_status_idle('0),
      .aes_req_dv(aes_req_dv), .aes_req_hold(aes_req_hold),
      .aes_req_data(aes_req_data), .aes_rdata('0), .aes_error('0),
      .kv_read(kv_read), .kv_rd_resp(kv_rd_resp),
      .strap_ss_caliptra_base_addr('0), .strap_ss_mci_base_addr('0),
      .strap_ss_recovery_ifc_base_addr('0),
      .strap_ss_external_staging_area_base_addr('0),
      .strap_ss_otp_fc_base_addr('0), .strap_ss_uds_seed_base_addr('0),
      .strap_ss_key_release_base_addr('0), .strap_ss_key_release_key_size('0),
      .strap_ss_prod_debug_unlock_auth_pk_hash_reg_bank_offset('0),
      .strap_ss_num_of_prod_debug_unlock_auth_pk_hashes('0),
      .strap_ss_strap_generic_0('0), .strap_ss_strap_generic_1('0),
      .strap_ss_strap_generic_2('0), .strap_ss_strap_generic_3('0),
      .strap_ss_caliptra_dma_axi_user('0),
      .ss_debug_intent(ss_debug_intent),
      .cptra_ss_debug_intent(cptra_ss_debug_intent),
      .ss_dbg_manuf_enable(), .ss_soc_dbg_unlock_level(),
      .ss_generic_fw_exec_ctrl(),
      .ss_ocp_lock_en(1'b0), .ss_ocp_lock_in_progress(),
      .ss_key_release_key_size(),
      .nmi_vector(), .nmi_intr(), .iccm_lock(), .iccm_axs_blocked(1'b0),
      .cptra_noncore_rst_b(cptra_noncore_rst_b),
      .cptra_uc_rst_b(cptra_uc_rst_b),
      .clk_gating_en(), .rdc_clk_dis(), .fw_update_rst_window(),
      .crypto_error('0),
      .cptra_uncore_dmi_reg_en(dmi_reg_en),
      .cptra_uncore_dmi_reg_wr_en(dmi_reg_wr_en),
      .cptra_uncore_dmi_reg_rdata(dmi_reg_rdata),
      .cptra_uncore_dmi_reg_addr(dmi_reg_addr),
      .cptra_uncore_dmi_reg_wdata(dmi_reg_wdata)
  );

  // ---------------- bookkeeping --------------------------------------------
  int checks, fails, witness_hits;
  bit cov_reset_clear, cov_addr_mismatch_no_write;
  bit cov_no_write_sets_intent, cov_legit_write_ignored;

  task automatic step(input int n);
    repeat (n) @(posedge clk);
  endtask

  task automatic record(input string name, input bit ok, input string what);
    checks++;
    if (ok) $display("  case=%s PASS %s", name, what);
    else begin
      fails++;
      $display("  TBFAIL case=%s %s", name, what);
    end
  endtask

  // Present an address and data on the DMI port WITHOUT asserting a write.
  // This is the attacker action: no DMI write is issued at any point.
  task automatic dmi_present_no_write(input logic [6:0] a, input logic [31:0] d);
    @(negedge clk);
    dmi_reg_en    = 1'b0;
    dmi_reg_wr_en = 1'b0;
    dmi_reg_addr  = a;
    dmi_reg_wdata = d;
  endtask

  // A legitimate DMI write. Address, data and write enable are applied on the
  // same negedge so no cycle exists in which the address is presented while the
  // write enable is low, which would otherwise trip the defect itself.
  task automatic dmi_legit_write(input logic [6:0] a, input logic [31:0] d);
    @(negedge clk);
    dmi_reg_en    = 1'b1;
    dmi_reg_wr_en = 1'b1;
    dmi_reg_addr  = a;
    dmi_reg_wdata = d;
    step(2);
    @(negedge clk);          // retire all three together, again no exposed cycle
    dmi_reg_en    = 1'b0;
    dmi_reg_wr_en = 1'b0;
    dmi_reg_addr  = 7'h0;
    dmi_reg_wdata = 32'h0;
  endtask

  task automatic cold_reset();
    @(negedge clk);
    cptra_pwrgood = 1'b0;
    cptra_rst_b   = 1'b0;
    step(4);
    @(negedge clk) cptra_pwrgood = 1'b1;
    step(4);
    @(negedge clk) cptra_rst_b = 1'b1;
    step(20);
  endtask

  // ---------------- stimulus -----------------------------------------------
  initial begin
    checks = 0; fails = 0; witness_hits = 0;
    cov_reset_clear = 0; cov_addr_mismatch_no_write = 0;
    cov_no_write_sets_intent = 0; cov_legit_write_ignored = 0;

    generic_input_wires = '0;
    haddr_i = '0; hwdata_i = '0; hsel_i = 1'b0; hwrite_i = 1'b0;
    htrans_i = 2'b00; hsize_i = 3'b010;
    dmi_reg_en = 1'b0; dmi_reg_wr_en = 1'b0;
    dmi_reg_addr = 7'h0; dmi_reg_wdata = 32'h0;

    // Most-locked configuration: debug locked, production silicon. The register
    // definition in src/soc_ifc/rtl/soc_ifc_subsystem_reg.rdl:143 gives TAP
    // write access only in debug or manufacturing mode, so in this state no
    // agent should be able to write debug_intent at all.
    security_state = '{device_lifecycle: DEVICE_PRODUCTION, debug_locked: 1'b1};
    ss_debug_intent = 1'b0;

    $display("===== BUG-N-001 directed witness: SS_DEBUG_INTENT write qualifier =====");
    $display("  configuration: subsystem mode, debug_locked=1, lifecycle=PRODUCTION");
    $display("  DMI_REG_SS_DEBUG_INTENT = 7'h%02h", DMI_REG_SS_DEBUG_INTENT);

    cold_reset();

    // ---- control 1: reset leaves the flag clear, DMI idle at address 0 ----
    record("control_reset_leaves_debug_intent_clear",
           cptra_ss_debug_intent === 1'b0,
           "after cold reset with the DMI idle the block must report no debug intent");
    if (cptra_ss_debug_intent === 1'b0) cov_reset_clear = 1'b1;

    // ---- control 2: a non-matching address must not write (anti-vacuity) ----
    // Same attacker action, but on an address that is not the debug-intent
    // register. If this wrote too, the address decode would be doing nothing
    // and the witness below would be meaningless.
    dmi_present_no_write(7'h62, 32'h1);
    step(6);
    $display("      addr=7'h62 wdata[0]=1 wr_en=0 -> debug_intent=%0b",
             cptra_ss_debug_intent);
    record("control_addr_mismatch_no_write",
           cptra_ss_debug_intent === 1'b0,
           "presenting a different address without a write must not set debug intent");
    if (cptra_ss_debug_intent === 1'b0) cov_addr_mismatch_no_write = 1'b1;

    // ---- violating 1: no DMI write at all, yet the flag is set ----
    dmi_present_no_write(DMI_REG_SS_DEBUG_INTENT, 32'h1);
    step(6);
    $display("      addr=7'h%02h wdata[0]=1 wr_en=0 -> debug_intent=%0b",
             DMI_REG_SS_DEBUG_INTENT, cptra_ss_debug_intent);
    if (cptra_ss_debug_intent === 1'b1) begin
      witness_hits++;
      cov_no_write_sets_intent = 1'b1;
      $display("      OBSERVED: BUG_N001_WITNESS_OBSERVED debug_intent set with no DMI write issued, in debug-locked production");
    end
    record("violating_no_dmi_write_sets_debug_intent",
           cptra_ss_debug_intent === 1'b0,
           "debug intent must not be settable without an asserted DMI write");

    // Show the data is attacker-chosen, not a stuck value: present 0 the same
    // way and the flag follows the presented data.
    dmi_present_no_write(DMI_REG_SS_DEBUG_INTENT, 32'h0);
    step(6);
    $display("      same address with wdata[0]=0 -> debug_intent=%0b (data is attacker-chosen)",
             cptra_ss_debug_intent);

    // ---- violating 2: the legitimate write is the one that does nothing ----
    // Move to MANUFACTURING so the lifecycle gate at
    // src/soc_ifc/rtl/soc_ifc_top.sv:774-776 opens and the DMI write is the
    // documented, permitted access. It still has no effect.
    cold_reset();
    @(negedge clk)
      security_state = '{device_lifecycle: DEVICE_MANUFACTURING, debug_locked: 1'b1};
    step(4);
    $display("      lifecycle=MANUFACTURING, issuing a permitted DMI write to debug_intent");
    dmi_legit_write(DMI_REG_SS_DEBUG_INTENT, 32'h1);
    step(6);
    $display("      after a legitimate DMI write (reg_en=1 wr_en=1 wdata[0]=1) -> debug_intent=%0b",
             cptra_ss_debug_intent);
    if (cptra_ss_debug_intent === 1'b0) cov_legit_write_ignored = 1'b1;
    record("violating_legitimate_dmi_write_is_ignored",
           cptra_ss_debug_intent === 1'b1,
           "a permitted DMI write to debug_intent must take effect");

    // ---- containment: the pwrgood reset still clears the flag ----
    // Set it again the defective way, then cold reset, to show the register is
    // not simply stuck and the defect is confined to the write qualifier.
    dmi_present_no_write(DMI_REG_SS_DEBUG_INTENT, 32'h1);
    step(6);
    $display("      re-armed via the defect -> debug_intent=%0b", cptra_ss_debug_intent);
    @(negedge clk) begin
      dmi_reg_addr  = 7'h0;
      dmi_reg_wdata = 32'h0;
    end
    cold_reset();
    $display("      after cold reset -> debug_intent=%0b", cptra_ss_debug_intent);
    record("containment_pwrgood_reset_clears",
           cptra_ss_debug_intent === 1'b0,
           "a pwrgood reset must still clear the flag, confining the defect to the write qualifier");

    $display("");
    $display("cov_reset_clear=%0b", cov_reset_clear);
    $display("cov_addr_mismatch_no_write=%0b", cov_addr_mismatch_no_write);
    $display("cov_no_write_sets_intent=%0b", cov_no_write_sets_intent);
    $display("cov_legit_write_ignored=%0b", cov_legit_write_ignored);
    $display("witness_hits=%0d", witness_hits);
    $display("checks=%0d fails=%0d", checks, fails);

    // The two violating checks are expected to fail on the audited RTL, and
    // both anti-vacuity controls plus the containment case must pass.
    if (checks == 5 && fails == 2 && witness_hits == 1 &&
        cov_reset_clear && cov_addr_mismatch_no_write &&
        cov_no_write_sets_intent && cov_legit_write_ignored) begin
      $display("result=PASS");
      $display("PROOF_RESULT: PASS");
    end
    else begin
      $display("result=FAIL");
      $display("PROOF_RESULT: FAIL");
    end
    $finish;
  end

  // global watchdog
  initial begin
    #500000;
    $display("      TBFAIL global timeout");
    $display("result=FAIL");
    $display("PROOF_RESULT: FAIL");
    $finish;
  end

endmodule

`default_nettype wire
