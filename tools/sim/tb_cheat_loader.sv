// SPDX-License-Identifier: GPL-3.0-or-later
// Testbench for src/gb/cheat_loader.sv.
//
// Streams a real .cht file through the parser one byte at a time and prints
// every code it latches into CODES. tools/sim/run.py compares this against
// tools/cheats/chtparse.py over the whole libretro database.
//
//   iverilog -g2012 -o tb tools/sim/tb_cheat_loader.sv src/gb/cheat_loader.sv
//   vvp tb +f=path/to/file.cht

`timescale 1ns / 1ps

module tb;

  reg         clk = 0;
  reg         reset = 1;
  reg         wr = 0;
  reg  [7:0]  data = 8'd0;

  wire [128:0] code;
  wire [31:0]  enable_mask;
  wire [5:0]   code_count, group_count;
  wire [19:0]  byte_count;

  always #5 clk = ~clk;

  cheat_loader #(
      .MAX_CODES (32),
      .MAX_GROUPS(32)
  ) dut (
      .clk        (clk),
      .reset      (reset),
      .wr         (wr),
      .data       (data),
      .code       (code),
      .enable_mask(enable_mask),
      .code_count (code_count),
      .group_count(group_count),
      .byte_count (byte_count)
  );

  // Print each code as CODES would latch it: on the rising edge of code[128].
  reg prev_latch = 1'b0;
  always @(posedge clk) begin
    if (code[128] && !prev_latch)
      $display("CODE grp=%0d usecmp=%0d addr=%04x cmp=%02x val=%02x",
               code[101:97], code[96], code[79:64], code[39:32], code[7:0]);
    prev_latch <= code[128];
  end

  integer fd, c;
  reg [8*512-1:0] fname;

  initial begin
    if (!$value$plusargs("f=%s", fname)) begin
      $display("ERROR: pass +f=<file>");
      $finish;
    end
    fd = $fopen(fname, "rb");
    if (fd == 0) begin
      $display("ERROR: cannot open file");
      $finish;
    end

    repeat (4) @(posedge clk);
    reset <= 1'b0;
    @(posedge clk);

    c = $fgetc(fd);
    while (c != -1) begin
      @(posedge clk);
      data <= c[7:0];
      wr   <= 1'b1;
      @(posedge clk);
      wr <= 1'b0;
      repeat (3) @(posedge clk);   // emit sequencer takes two cycles
      c = $fgetc(fd);
    end
    $fclose(fd);

    repeat (10) @(posedge clk);
    $display("TOTAL codes=%0d groups=%0d mask=%08x",
             code_count, group_count, enable_mask);
    $finish;
  end

endmodule
