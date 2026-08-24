// SPDX-License-Identifier: GPL-3.0-or-later
// Stress the emit sequencer: drive bytes back-to-back with wr high every cycle,
// far faster than data_loader can ever deliver, and confirm no code is lost.
`timescale 1ns/1ps
module tb_fast;
  reg clk=0, reset=1, wr=0; reg [7:0] data=0;
  wire [128:0] code; wire [31:0] enable_mask; wire [5:0] code_count, group_count; wire [19:0] byte_count;
  integer fd, c, n=0;
  reg prev=0;
  always #5 clk=~clk;
  cheat_loader dut(.clk(clk),.reset(reset),.wr(wr),.data(data),.code(code),
                   .enable_mask(enable_mask),.code_count(code_count),
                   .group_count(group_count),.byte_count(byte_count));
  always @(posedge clk) begin
    if (code[128] && !prev) n = n + 1;
    prev <= code[128];
  end
  initial begin
    fd = $fopen("tools/sim/fixtures/backtoback.cht", "rb");
    repeat(3) @(posedge clk); reset<=0; @(posedge clk);
    c = $fgetc(fd);
    while (c != -1) begin
      @(posedge clk); data <= c[7:0]; wr <= 1'b1;   // no gap between bytes
      c = $fgetc(fd);
    end
    @(posedge clk); wr <= 1'b0;
    repeat(10) @(posedge clk);
    $display("back-to-back bytes: latched=%0d code_count=%0d group_count=%0d",
             n, code_count, group_count);
    if (n==4 && code_count==4 && group_count==2) $display("PASS");
    else begin $display("FAIL: expected 4 latched / 4 codes / 2 groups"); $fatal(1); end
    $finish;
  end
endmodule
