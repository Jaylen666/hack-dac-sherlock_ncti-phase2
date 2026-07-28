module BUG_012_doe_fsm_real_dut_tb;
  import doe_defines_pkg::*;
  import kv_defines_pkg::*;

  logic clk;
  logic rst_b;
  logic hard_rst_b;
  logic [0:0][127:0] obf_field_entropy;
  logic [1:0][127:0] obf_uds_seed;
  logic [1:0][127:0] obf_hek_seed;
  doe_cmd_reg_t doe_cmd_reg;
  logic ocp_lock_en;
  kv_write_t kv_write;
  logic src_write_en;
  logic [127:0] src_write_data;
  logic doe_init;
  logic doe_next;
  logic init_done;
  logic dest_data_avail;
  logic [3:0][31:0] dest_data;
  logic flow_done;
  logic flow_error;
  logic flow_in_progress;
  logic lock_uds_flow;
  logic lock_fe_flow;
  logic lock_hek_flow;
  logic zeroize;

  doe_fsm #(.SRC_WIDTH(128), .DEST_WIDTH(128)) dut (.*);

  task automatic tick;
    begin
      clk = 1'b0;
      #1;
      clk = 1'b1;
      #1;
      clk = 1'b0;
      #1;
    end
  endtask

  task automatic reset_dut;
    begin
      clk = 1'b0;
      rst_b = 1'b0;
      hard_rst_b = 1'b0;
      obf_field_entropy = '{default: 128'h012};
      obf_uds_seed = '{default: 128'h0};
      obf_hek_seed = '{default: 128'h0};
      doe_cmd_reg = '0;
      ocp_lock_en = 1'b0;
      init_done = 1'b0;
      dest_data_avail = 1'b0;
      dest_data = '{32'h00112233, 32'h44556677, 32'h8899aabb, 32'hccddeeff};
      zeroize = 1'b0;
      repeat (2) tick();
      rst_b = 1'b1;
      hard_rst_b = 1'b1;
      tick();
    end
  endtask

  initial begin
    reset_dut();

    doe_cmd_reg.cmd = DOE_FE;
    doe_cmd_reg.dest_sel = 5'd3;
    #1;
    $display("BUG012_CONTROL_FE cmd=DOE_FE observed_write_dest_valid=0x%03h expected=0x003",
             kv_write.write_dest_valid);
    if (kv_write.write_dest_valid !== 9'h003) $fatal(1, "BUG012_CONTROL_FAIL FE destination mask is not 0x003");

    doe_cmd_reg.cmd = DOE_UDS;
    doe_cmd_reg.dest_sel = 5'd0;
    #1;
    $display("BUG012_WITNESS cmd=DOE_UDS observed_write_dest_valid=0x%03h secure_expected=0x003 expanded_bit5=%0b",
             kv_write.write_dest_valid, kv_write.write_dest_valid[5]);
    if (kv_write.write_dest_valid !== 9'h023) $fatal(1, "BUG012_WITNESS_NOT_OBSERVED UDS destination was not expanded");

    $display("BUG012_WITNESS_PASS");
    $finish;
  end
endmodule
