module hmac_drbg #(
  parameter REG_SIZE = 384,
  parameter [REG_SIZE-1:0] HMAC_DRBG_PRIME = '1
) (
  input  wire                  clk,
  input  wire                  reset_n,
  input  wire                  zeroize,
  input  wire                  init_cmd,
  input  wire                  next_cmd,
  output wire                  ready,
  output wire                  valid,
  input  wire [REG_SIZE-1:0]   lfsr_seed,
  input  wire [REG_SIZE-1:0]   entropy,
  input  wire [REG_SIZE-1:0]   nonce,
  output wire [REG_SIZE-1:0]   drbg
);
  logic valid_q;
  logic [REG_SIZE-1:0] drbg_q;
  logic [REG_SIZE-1:0] command_mix;

  assign command_mix = entropy ^ nonce ^ lfsr_seed ^ REG_SIZE'(384'h6e0036e0036e0036e0036e0036e0036e0036e0036e0036e0036e0036e0036e0036e0036e0036e0036e003);

  always_ff @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
      valid_q <= 1'b0;
      drbg_q <= '0;
    end else if (zeroize) begin
      valid_q <= 1'b0;
      drbg_q <= '0;
    end else begin
      valid_q <= init_cmd | next_cmd;
      if (init_cmd | next_cmd) begin
        drbg_q <= (command_mix == '0) ? REG_SIZE'(384'h1) : command_mix;
      end
    end
  end

  assign ready = 1'b1;
  assign valid = valid_q;
  assign drbg = drbg_q;
endmodule

module caliptra_prim_lfsr #(
  parameter string LfsrType = "FIB_XNOR",
  parameter int unsigned LfsrDw = 32,
  parameter int unsigned StateOutDw = 32
) (
  input  logic                    clk_i,
  input  logic                    rst_ni,
  input  logic                    seed_en_i,
  input  logic [LfsrDw-1:0]       seed_i,
  input  logic                    lfsr_en_i,
  input  logic [LfsrDw-1:0]       entropy_i,
  output logic [StateOutDw-1:0]   state_o
);
  logic [StateOutDw-1:0] state_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= '0;
    end else if (seed_en_i) begin
      state_q <= StateOutDw'(seed_i) ^ StateOutDw'(32'hc003_cafe);
    end else if (lfsr_en_i) begin
      state_q <= {state_q[StateOutDw-2:0], ^state_q ^ ^entropy_i ^ 1'b1};
    end
  end

  assign state_o = state_q;
endmodule
