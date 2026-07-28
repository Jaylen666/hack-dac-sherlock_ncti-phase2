#include "Ventropy_src_repcnts_ht.h"
#include "verilated.h"

#include <cstdlib>
#include <iostream>

static vluint64_t sim_time = 0;
double sc_time_stamp() { return static_cast<double>(sim_time); }

static void tick(Ventropy_src_repcnts_ht *dut) {
  dut->clk_i = 0;
  dut->eval();
  ++sim_time;
  dut->clk_i = 1;
  dut->eval();
  ++sim_time;
}

[[noreturn]] static void fail(const char *msg, Ventropy_src_repcnts_ht *dut) {
  std::cout << "FAIL " << msg
            << " cnt=" << static_cast<int>(dut->test_cnt_o)
            << " fail=" << static_cast<int>(dut->test_fail_pulse_o)
            << " count_err=" << static_cast<int>(dut->count_err_o)
            << std::endl;
  std::exit(1);
}

static void reset_and_prime(Ventropy_src_repcnts_ht *dut, int threshold) {
  dut->rst_ni = 0;
  dut->entropy_bit_i = 0;
  dut->entropy_bit_vld_i = 0;
  dut->clear_i = 0;
  dut->active_i = 0;
  dut->thresh_i = threshold;
  tick(dut);
  tick(dut);
  dut->rst_ni = 1;
  tick(dut);
  tick(dut);
  if (dut->test_cnt_o != 1) fail("reset_prime_counter_not_one", dut);
  if (dut->test_fail_pulse_o != 0 || dut->count_err_o != 0) {
    fail("reset_prime_unexpected_failure", dut);
  }
}

static void drive_valid(Ventropy_src_repcnts_ht *dut, int sample) {
  dut->entropy_bit_i = sample;
  dut->entropy_bit_vld_i = 1;
  tick(dut);
  std::cout << "TRACE sample=0x" << std::hex << sample << std::dec
            << " cnt=" << static_cast<int>(dut->test_cnt_o)
            << " fail=" << static_cast<int>(dut->test_fail_pulse_o)
            << " count_err=" << static_cast<int>(dut->count_err_o)
            << std::endl;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  auto *dut = new Ventropy_src_repcnts_ht;

  reset_and_prime(dut, 3);
  dut->active_i = 1;
  drive_valid(dut, 0x0);
  drive_valid(dut, 0xf);
  drive_valid(dut, 0x0);
  drive_valid(dut, 0xf);
  if (dut->test_fail_pulse_o != 0 || dut->count_err_o != 0) {
    fail("alternating_control_failed", dut);
  }
  std::cout << "PASS control_alternating_symbols_no_fail" << std::endl;

  reset_and_prime(dut, 3);
  dut->active_i = 1;
  drive_valid(dut, 0x0);
  if (dut->test_cnt_o != 2 || dut->test_fail_pulse_o != 0) {
    fail("below_threshold_control_failed", dut);
  }
  std::cout << "PASS control_below_threshold_no_fail cnt="
            << static_cast<int>(dut->test_cnt_o) << std::endl;

  drive_valid(dut, 0x0);
  if (dut->test_cnt_o != 3) fail("boundary_counter_not_at_threshold", dut);
  if (dut->test_fail_pulse_o != 0) fail("boundary_unexpected_fail", dut);
  std::cout << "OBSERVE boundary_count=" << static_cast<int>(dut->test_cnt_o)
            << " threshold=" << static_cast<int>(dut->thresh_i)
            << " boundary_fail=" << static_cast<int>(dut->test_fail_pulse_o)
            << std::endl;

  drive_valid(dut, 0x0);
  if (dut->test_cnt_o != 4 || dut->test_fail_pulse_o != 1) {
    fail("threshold_plus_one_missing_fail", dut);
  }
  std::cout << "OBSERVE next_count=" << static_cast<int>(dut->test_cnt_o)
            << " threshold=" << static_cast<int>(dut->thresh_i)
            << " next_fail=" << static_cast<int>(dut->test_fail_pulse_o)
            << std::endl;

  std::cout << "PASS BUG013_REPCNTS_OFF_BY_ONE_WITNESS" << std::endl;
  dut->final();
  delete dut;
  return 0;
}
