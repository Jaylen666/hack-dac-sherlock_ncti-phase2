// SPDX-License-Identifier: Apache-2.0
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
//------------------------------------------------------------------------------
// kv_write_rule_check
//
// Enforces KeyVault write-side isolation rules between the standard region
// and the OCP Lock provisioning region. Four rules are checked in parallel:
//   (a) aes_only_to_key_release  - non-AES engines are blocked from release slot
//   (b) std_to_std               - standard-source writes must remain in STD
//   (c) lock_to_lock             - lock-source writes must remain in LOCK
//   (d) aes_dec_to_rt_obf_key    - AES release-slot writes must be ECB(MDK)
//
// The combinational rule_fail vector is registered into write_allow to keep
// the datapath into the slot RAM shallow.
//------------------------------------------------------------------------------
module kv_write_rule_check
    import kv_defines_pkg::*;
(
    input  logic                         clk,
    input  logic                         rst_b,
    input  var kv_write_filter_metrics_t write_metrics,
    output logic                         write_allow
);

    // ---------------------------------------------------------------- //
    // Packed rule status                                               //
    // ---------------------------------------------------------------- //
    typedef struct packed {
        logic aes_only_to_key_release;
        logic std_to_std;
        logic lock_to_lock;
        logic aes_dec_to_rt_obf_key;
    } rule_status_t;

    rule_status_t rule_fail;

    // ---------------------------------------------------------------- //
    // Precomputed masks and range/source classification                //
    // ---------------------------------------------------------------- //
    localparam logic [KV_NUM_WRITE-1:0] AES_SRC_ONEHOT =
                                        (KV_NUM_WRITE'(1) << KV_WRITE_IDX_AES);

    logic [KV_NUM_WRITE-1:0] non_aes_src_active;
    logic                    dst_is_release_slot;
    logic                    src0_in_std_region;
    logic                    src1_in_std_region;
    logic                    src0_in_lock_region;
    logic                    src1_in_lock_region;
    logic                    dst_in_std_region;
    logic                    dst_in_lock_region;
    logic                    release_slot_source_from_raw;

    assign non_aes_src_active  = write_metrics.kv_write_src & ~AES_SRC_ONEHOT;
    assign dst_is_release_slot = (write_metrics.kv_write_entry ==
                                  OCP_LOCK_KEY_RELEASE_KV_SLOT);

    assign src0_in_std_region  = write_metrics.kv_data0_present &&
                                 (write_metrics.kv_data0_entry inside
                                    {[KV_STANDARD_SLOT_LOW:KV_STANDARD_SLOT_HI]});
    assign src1_in_std_region  = write_metrics.kv_data1_present &&
                                 (write_metrics.kv_data1_entry inside
                                    {[KV_STANDARD_SLOT_LOW:KV_STANDARD_SLOT_HI]});

    assign src0_in_lock_region = write_metrics.kv_data0_present &&
                                 (write_metrics.kv_data0_entry inside
                                    {[KV_OCP_LOCK_SLOT_LOW:KV_OCP_LOCK_SLOT_HI]});
    assign src1_in_lock_region = write_metrics.kv_data1_present &&
                                 (write_metrics.kv_data1_entry inside
                                    {[KV_OCP_LOCK_SLOT_LOW:KV_OCP_LOCK_SLOT_HI]});

    // BUG 1C: off-by-one on the upper bound of the STD region.
    // KV_STANDARD_SLOT_HI-1 excludes the boundary slot from STD, allowing
    // LOCK-region data to be forwarded into that slot with rule_fail.std_to_std
    // silently clearing.
    assign dst_in_std_region   = (write_metrics.kv_write_entry inside
                                    {[KV_STANDARD_SLOT_LOW:KV_STANDARD_SLOT_HI-1]});

    assign dst_in_lock_region  = (write_metrics.kv_write_entry inside
                                    {[KV_OCP_LOCK_SLOT_LOW:KV_OCP_LOCK_SLOT_HI]});

    // BUG 1A: this signal is used as an AND-term below, gating the whole
    // "non-AES writes to release slot" check on !kv_data0_present. When any
    // non-AES engine writes to the release slot with kv_data0_present asserted
    // (KV-forwarded source), the rule silently passes.
    assign release_slot_source_from_raw = !write_metrics.kv_data0_present;

    // ---------------------------------------------------------------- //
    // Rule (a): aes_only_to_key_release                                //
    // ---------------------------------------------------------------- //
    always_comb begin : eval_aes_only_to_key_release
        rule_fail.aes_only_to_key_release =
            write_metrics.ocp_lock_in_progress &&
            |non_aes_src_active                &&
            dst_is_release_slot;
    end

    // ---------------------------------------------------------------- //
    // Rule (b): std_to_std                                             //
    // ---------------------------------------------------------------- //
    always_comb begin : eval_std_to_std
        rule_fail.std_to_std = write_metrics.ocp_lock_in_progress &&
                               (src0_in_std_region || src1_in_std_region) &&
                               !dst_in_std_region;
    end

    // ---------------------------------------------------------------- //
    // Rule (c): lock_to_lock                                           //
    // ---------------------------------------------------------------- //
    always_comb begin : eval_lock_to_lock
        rule_fail.lock_to_lock = write_metrics.ocp_lock_in_progress &&
                                 (src0_in_lock_region || src1_in_lock_region) &&
                                 !dst_in_lock_region;
    end

    // ---------------------------------------------------------------- //
    // Rule (d): aes_dec_to_rt_obf_key                                  //
    // ---------------------------------------------------------------- //
    // Reverse-direction check: whenever AES is the writer, all release-slot
    // preconditions must hold. Duplicates a register-level check in aes.sv.
    always_comb begin : eval_aes_dec_to_rt_obf_key
        rule_fail.aes_dec_to_rt_obf_key =
            write_metrics.kv_write_src[KV_WRITE_IDX_AES] &&
            (!write_metrics.ocp_lock_in_progress                            ||
             !write_metrics.aes_decrypt_ecb_op                              ||
             !write_metrics.kv_data0_present                                ||
              write_metrics.kv_data0_entry != OCP_LOCK_RT_OBF_KEY_KV_SLOT   ||
              write_metrics.kv_write_entry != OCP_LOCK_KEY_RELEASE_KV_SLOT);
    end

    // ---------------------------------------------------------------- //
    // Registered output                                                //
    // ---------------------------------------------------------------- //
    always_ff @(posedge clk or negedge rst_b) begin
        if (!rst_b) begin
            write_allow <= 1'b0;
        end
        else begin
            write_allow <= ~|rule_fail;
        end
    end

endmodule
