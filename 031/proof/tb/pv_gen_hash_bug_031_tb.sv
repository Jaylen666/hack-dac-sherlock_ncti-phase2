// SPDX-License-Identifier: Apache-2.0
//
// BUG-031 directed witness: the PCR gen-hash read pointer is not cleared on zeroize,
// so a quote started after a zeroize covers only part of the PCR bank.
//
// Property under test: the gen-hash walk must cover every PCR entry, 0 through
// PV_NUM_PCR-1, on every run. src/pcrvault/rtl/pv_gen_hash.sv:119 declares the walk
// finished when read_offset and read_entry both reach their maxima, so the walk's
// start value fully determines how many entries the digest covers.
//
// src/pcrvault/rtl/pv_gen_hash.sv:199-219 resets read_entry and read_offset in the
// reset branch but omits them from the zeroize branch, while the FSM state itself is
// forced back to IDLE. Nothing on the IDLE->BLOCK_0 start arc at :130 resets the
// pointer either: :122 asserts rst_rd_ptr only on the two BLOCK->NONCE arcs, which a
// truncated run never reaches. The stale pointer therefore survives into the next run.
//
// This testbench instantiates one real pv_gen_hash and drives it only through its
// declared ports. The PCR read response is modelled by a simple responder that echoes
// the requested coordinates back as read data, so the set of entries the DUT visits
// can be observed from its own outputs. There is no force, no deposit and no
// hierarchical assignment anywhere in this harness.
//
`timescale 1ns/1ps

module pv_gen_hash_bug_031_tb
  import pv_defines_pkg::*;
();

  localparam int unsigned CLK_HALF = 5;

  // Where in the bank the interrupting zeroize lands. Any entry strictly between 0
  // and PV_NUM_PCR-1 works; the value only sets how much of the bank is skipped.
  localparam int unsigned ZEROIZE_AT_ENTRY = 20;

  logic clk, rst_b, zeroize;
  logic start, core_ready, core_digest_valid;
  logic [PV_SIZE_OF_NONCE/32-1:0][31:0] nonce;

  logic gen_hash_ip, gen_hash_init_reg, gen_hash_next_reg, gen_hash_last_reg;
  logic block_we;
  logic [$clog2(1024/32)-1:0] block_offset;
  logic [31:0] block_wr_data;
  pv_read_t    pv_read;
  pv_rd_resp_t pv_rd_resp;

  int unsigned checks, fails;
  int unsigned cov_full_walk_from_reset;
  int unsigned cov_truncated_walk_after_zeroize;
  int unsigned cov_idle_zeroize_harmless;
  int unsigned witness_hits;

  // Per-run record of which PCR entries the DUT actually asked for.
  bit visited [0:PV_NUM_PCR-1];
  bit tracking;

  pv_gen_hash dut (
    .clk              (clk),
    .rst_b            (rst_b),
    .zeroize          (zeroize),
    .start            (start),
    .core_ready       (core_ready),
    .core_digest_valid(core_digest_valid),
    .nonce            (nonce),
    .gen_hash_ip      (gen_hash_ip),
    .gen_hash_init_reg(gen_hash_init_reg),
    .gen_hash_next_reg(gen_hash_next_reg),
    .gen_hash_last_reg(gen_hash_last_reg),
    .block_we         (block_we),
    .block_offset     (block_offset),
    .block_wr_data    (block_wr_data),
    .pv_read          (pv_read),
    .pv_rd_resp       (pv_rd_resp)
  );

  initial clk = 1'b0;
  always #CLK_HALF clk = ~clk;

  // PCR responder: return the requested coordinates back as tagged read data, so
  // every dword the DUT feeds into the hash block carries the identity of the PCR
  // entry it came from. Coverage is then measured from the data that actually
  // entered the block, not merely from the address the DUT drove.
  localparam logic [15:0] PCR_TAG = 16'hDA7A;
  always_comb begin
    pv_rd_resp.error     = 1'b0;
    pv_rd_resp.last      = 1'b0;
    pv_rd_resp.read_data = {PCR_TAG, 7'd0, pv_read.read_offset, pv_read.read_entry};
  end

  // Observe the walk from the tagged data the DUT writes into the block. The nonce
  // and padding phases write untagged values, so they are excluded automatically.
  always @(posedge clk) begin
    if (tracking && block_we && block_wr_data[31:16] == PCR_TAG)
      visited[block_wr_data[PV_ENTRY_ADDR_W-1:0]] = 1'b1;
  end

  task automatic step(input int unsigned n);
    for (int unsigned i = 0; i < n; i++) @(posedge clk);
  endtask

  task automatic clear_visited();
    for (int i = 0; i < PV_NUM_PCR; i++) visited[i] = 1'b0;
  endtask

  function automatic int unsigned visited_count();
    visited_count = 0;
    for (int i = 0; i < PV_NUM_PCR; i++) if (visited[i]) visited_count++;
  endfunction

  function automatic int lowest_visited();
    lowest_visited = -1;
    for (int i = PV_NUM_PCR-1; i >= 0; i--) if (visited[i]) lowest_visited = i;
  endfunction

  task automatic record(input string name, input bit ok, input string what);
    checks++;
    if (ok) $display("  case=%s PASS %s", name, what);
    else begin
      fails++;
      $display("  TBFAIL case=%s %s", name, what);
    end
  endtask

  // Start a quote and let it run to completion, retiring the core handshake.
  task automatic start_quote_and_finish();
    @(negedge clk); start = 1'b1;
    @(negedge clk); start = 1'b0;
    // Let the walk run; retire the final block when the FSM waits for it.
    for (int unsigned i = 0; i < 20000; i++) begin
      @(posedge clk);
      if (gen_hash_last_reg) begin
        core_digest_valid = 1'b1;
        @(posedge clk);
        core_digest_valid = 1'b0;
        break;
      end
    end
    // Settle back to idle.
    for (int unsigned i = 0; i < 200; i++) begin
      @(posedge clk);
      if (!gen_hash_ip) break;
    end
  endtask

  initial begin
    checks = 0; fails = 0;
    cov_full_walk_from_reset         = 0;
    cov_truncated_walk_after_zeroize = 0;
    cov_idle_zeroize_harmless        = 0;
    witness_hits                     = 0;
    tracking = 1'b0;

    start = 0; core_ready = 1'b1; core_digest_valid = 0; zeroize = 0;
    for (int i = 0; i < PV_SIZE_OF_NONCE/32; i++) nonce[i] = 32'hA5A5_0000 + i;
    rst_b = 1'b0;
    step(5);
    rst_b = 1'b1;
    step(5);

    $display("===== BUG-031 directed witness: gen-hash read pointer across zeroize =====");
    $display("      PV_NUM_PCR=%0d PV_NUM_DWORDS=%0d", PV_NUM_PCR, PV_NUM_DWORDS);

    // ---- control 1: a clean run from reset must cover the whole bank.
    $display("--- control_full_walk_from_reset ---");
    clear_visited(); tracking = 1'b1;
    start_quote_and_finish();
    tracking = 1'b0;
    $display("      entries visited=%0d lowest=%0d", visited_count(), lowest_visited());
    if (visited_count() == PV_NUM_PCR) cov_full_walk_from_reset++;
    record("control_full_walk_from_reset", visited_count() == PV_NUM_PCR,
           "a quote started from reset must read every PCR entry");

    // ---- witness: interrupt a quote with zeroize part-way through the bank,
    // then start a fresh quote. The FSM is returned to IDLE, so software sees an
    // idle engine and a clean start; the read pointer is not returned with it.
    $display("--- violating_walk_after_mid_run_zeroize ---");
    @(negedge clk); start = 1'b1;
    @(negedge clk); start = 1'b0;
    // Let the walk advance to a specific point well inside the bank. Anchoring on
    // the observed pointer rather than a cycle count keeps the stimulus meaningful
    // if the walk's timing changes.
    for (int unsigned i = 0; i < 20000; i++) begin
      @(posedge clk);
      if (gen_hash_ip && pv_read.read_entry == ZEROIZE_AT_ENTRY) break;
    end
    $display("      read pointer when zeroize asserted: entry=%0d offset=%0d",
             pv_read.read_entry, pv_read.read_offset);
    @(negedge clk); zeroize = 1'b1;
    @(negedge clk); zeroize = 1'b0;
    step(4);
    $display("      gen_hash_ip after zeroize=%0b (engine reports idle)", gen_hash_ip);
    $display("      read pointer after zeroize:  entry=%0d offset=%0d",
             pv_read.read_entry, pv_read.read_offset);

    clear_visited(); tracking = 1'b1;
    start_quote_and_finish();
    tracking = 1'b0;
    $display("      entries visited=%0d lowest=%0d", visited_count(), lowest_visited());
    if (visited_count() < PV_NUM_PCR) begin
      cov_truncated_walk_after_zeroize++;
      witness_hits++;
      $display("      OBSERVED: BUG_031_WITNESS_OBSERVED fresh quote after zeroize covered only %0d of %0d PCR entries, starting at entry %0d",
               visited_count(), PV_NUM_PCR, lowest_visited());
    end
    record("violating_walk_after_mid_run_zeroize", visited_count() == PV_NUM_PCR,
           "a quote started after a zeroize must still read every PCR entry");

    // ---- containment: a zeroize while the engine is already idle and the
    // pointer already at zero must not disturb the next run. This separates the
    // stale-pointer defect from any claim that zeroize itself is broken.
    $display("--- containment_idle_zeroize_then_full_walk ---");
    rst_b = 1'b0; step(4); rst_b = 1'b1; step(4);
    @(negedge clk); zeroize = 1'b1;
    @(negedge clk); zeroize = 1'b0;
    step(4);
    clear_visited(); tracking = 1'b1;
    start_quote_and_finish();
    tracking = 1'b0;
    $display("      entries visited=%0d lowest=%0d", visited_count(), lowest_visited());
    if (visited_count() == PV_NUM_PCR) cov_idle_zeroize_harmless++;
    record("containment_idle_zeroize_then_full_walk", visited_count() == PV_NUM_PCR,
           "a zeroize taken while idle must leave the next quote complete");

    $display("");
    $display("cov_full_walk_from_reset=%0d",         cov_full_walk_from_reset);
    $display("cov_truncated_walk_after_zeroize=%0d", cov_truncated_walk_after_zeroize);
    $display("cov_idle_zeroize_harmless=%0d",        cov_idle_zeroize_harmless);
    $display("witness_hits=%0d", witness_hits);
    $display("checks=%0d fails=%0d", checks, fails);

    // Expected on the audited RTL: the two clean runs cover the bank, the run
    // following a mid-run zeroize does not.
    if (checks == 3 && fails == 1 && witness_hits == 1 &&
        cov_full_walk_from_reset == 1 &&
        cov_truncated_walk_after_zeroize == 1 &&
        cov_idle_zeroize_harmless == 1) begin
      $display("result=PASS");
      $display("PROOF_RESULT: PASS");
    end
    else begin
      // No "result=" marker here; the negative control expects this branch.
      $display("PROOF_RESULT: FAIL");
    end
    $finish;
  end

  initial begin
    #20000000;
    $display("TBFAIL global timeout");
    $display("PROOF_RESULT: FAIL");
    $finish;
  end

endmodule
