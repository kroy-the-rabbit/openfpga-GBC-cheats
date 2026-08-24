// SPDX-License-Identifier: GPL-3.0-or-later
// Testbench for src/gb/cheatcodes.sv (module CODES).
//
// Covers the Pocket additions: the per-cheat group index carried in the code
// word, and enable_mask gating each stored code, on top of the original
// Game Genie compare behaviour.

`timescale 1ns / 1ps

module tb_codes;

  localparam MAX_CODES  = 32;
  localparam MAX_GROUPS = 32;

  reg          clk = 0;
  reg          reset = 1;
  reg          enable = 1;
  reg  [15:0]  addr_in = 0;
  reg  [7:0]   data_in = 0;
  reg  [128:0] code = 0;
  reg  [31:0]  enable_mask = 32'hFFFFFFFF;
  wire         available, genie_ovr;
  wire [7:0]   genie_data;

  integer fails = 0;

  always #5 clk = ~clk;

  CODES #(
      .ADDR_WIDTH(16), .DATA_WIDTH(8),
      .MAX_CODES(MAX_CODES), .MAX_GROUPS(MAX_GROUPS)
  ) dut (
      .clk(clk), .reset(reset), .enable(enable), .available(available),
      .addr_in(addr_in), .data_in(data_in), .code(code),
      .enable_mask(enable_mask), .genie_ovr(genie_ovr), .scan_index (5'd0),
	.scan_bank      (),
	.scan_bank_qual (),
	.scan_addr     (),
	.scan_data     (),
	.scan_poke     (),
	.entry_count   (),
	.genie_data(genie_data)
  );

  task load(input [4:0] grp, input usecmp, input [15:0] a,
            input [7:0] cmp, input [7:0] val);
    begin
      @(posedge clk);
      code <= {1'b0, 26'd0, grp, usecmp, 16'd0, a, 24'd0, cmp, 24'd0, val};
      @(posedge clk);
      code[128] <= 1'b1;
      @(posedge clk);
      code[128] <= 1'b0;
      @(posedge clk);
    end
  endtask

  task expect_ovr(input [15:0] a, input [7:0] d,
                  input exp_ovr, input [7:0] exp_data, input [200*8-1:0] what);
    begin
      addr_in = a; data_in = d;
      #1;
      if (genie_ovr !== exp_ovr || (exp_ovr && genie_data !== exp_data)) begin
        $display("FAIL %0s: addr=%04x data=%02x -> ovr=%0d data=%02x (want ovr=%0d data=%02x)",
                 what, a, d, genie_ovr, genie_data, exp_ovr, exp_data);
        fails = fails + 1;
      end else begin
        $display("ok   %0s", what);
      end
    end
  endtask

  initial begin
    repeat (4) @(posedge clk);
    reset <= 0;
    @(posedge clk);

    // group 0: plain override; group 1: with compare; group 2: plain
    load(5'd0, 1'b0, 16'hC6AD, 8'h00, 8'h99);
    load(5'd1, 1'b1, 16'h4000, 8'h22, 8'h11);
    load(5'd2, 1'b0, 16'h1234, 8'h00, 8'h55);
    repeat (3) @(posedge clk);

    if (!available) begin $display("FAIL available should be high"); fails = fails + 1; end

    expect_ovr(16'hC6AD, 8'h00, 1'b1, 8'h99, "group 0 overrides");
    expect_ovr(16'h1234, 8'h00, 1'b1, 8'h55, "group 2 overrides");
    expect_ovr(16'h4000, 8'h22, 1'b1, 8'h11, "group 1 compare matches");
    expect_ovr(16'h4000, 8'h23, 1'b0, 8'h00, "group 1 compare mismatch is ignored");
    expect_ovr(16'hBEEF, 8'h00, 1'b0, 8'h00, "unrelated address untouched");

    // mask gating, one group at a time
    enable_mask = 32'hFFFFFFFE; repeat (2) @(posedge clk);
    expect_ovr(16'hC6AD, 8'h00, 1'b0, 8'h00, "group 0 off via mask");
    expect_ovr(16'h1234, 8'h00, 1'b1, 8'h55, "group 2 still on");

    enable_mask = 32'hFFFFFFFB; repeat (2) @(posedge clk);
    expect_ovr(16'hC6AD, 8'h00, 1'b1, 8'h99, "group 0 back on");
    expect_ovr(16'h1234, 8'h00, 1'b0, 8'h00, "group 2 off via mask");

    enable_mask = 32'h00000000; repeat (2) @(posedge clk);
    expect_ovr(16'hC6AD, 8'h00, 1'b0, 8'h00, "all groups masked off");

    // master switch
    enable_mask = 32'hFFFFFFFF; repeat (2) @(posedge clk);
    enable = 1'b0; #1;
    expect_ovr(16'hC6AD, 8'h00, 1'b0, 8'h00, "master switch off");
    enable = 1'b1; repeat (2) @(posedge clk);
    expect_ovr(16'hC6AD, 8'h00, 1'b1, 8'h99, "master switch back on");

    // reset clears everything
    reset = 1'b1; repeat (2) @(posedge clk); reset = 1'b0;
    repeat (2) @(posedge clk);
    expect_ovr(16'hC6AD, 8'h00, 1'b0, 8'h00, "reset cleared the table");
    if (available) begin $display("FAIL available should be low after reset"); fails = fails + 1; end

    if (fails == 0) $display("\nCODES: all checks passed");
    else begin
      $display("\nCODES: %0d FAILURES", fails);
      $fatal(1);
    end
    $finish;
  end

endmodule
