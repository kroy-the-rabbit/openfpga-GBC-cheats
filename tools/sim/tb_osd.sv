// SPDX-License-Identifier: GPL-3.0-or-later
//
// Renders one frame of the cheat overlay and dumps it as a bitmap.
//
// A file goes in through the real parser, its descriptions land in the real
// title RAM, and the real renderer draws them against generated video timing.
// run_osd.py turns the bitmap back into characters and checks them against
// what the file says, so this proves the whole path: a name written in a .cht
// on a card is the name a player reads on the screen.
//
// Plusargs:
//   +f=<path>     cheat file to load
//   +cart=1       pretend a cartridge is in the slot
//   +show=0       leave the overlay switched off

`timescale 1ns/1ps

module tb_osd;

  localparam COLS = 20, ROWS = 18;
  localparam H_ACTIVE = 160, H_BLANK = 60;
  localparam V_ACTIVE = 144, V_BLANK = 10;

  reg clk_sys = 0;
  reg clk_vid = 0;
  always #5  clk_sys = ~clk_sys;    // 100 MHz, the ratio is what matters here
  always #7  clk_vid = ~clk_vid;

  reg reset = 1;
  reg wr = 0;
  reg [7:0] data = 8'd0;

  wire [128:0] code;
  wire [31:0]  enable_mask;
  wire [5:0]   code_count, group_count;
  wire [19:0]  byte_count;
  wire         desc_wr, desc_end;
  wire [4:0]   desc_group, desc_col;
  wire [5:0]   desc_char;

  cheat_loader #(.MAX_CODES(32), .MAX_GROUPS(32)) loader (
    .clk (clk_sys), .reset (reset), .wr (wr), .data (data),
    .code (code), .enable_mask (enable_mask),
    .code_count (code_count), .group_count (group_count),
    .byte_count (byte_count),
    .desc_wr (desc_wr), .desc_group (desc_group), .desc_col (desc_col),
    .desc_char (desc_char), .desc_end (desc_end)
  );

  wire [4:0] t_group, t_col, t_len;
  wire [5:0] t_char;

  cheat_titles titles (
    .wr_clk (clk_sys), .wr_reset (reset),
    .wr_en (desc_wr), .wr_group (desc_group), .wr_col (desc_col),
    .wr_char (desc_char), .wr_end (desc_end),
    .rd_clk (clk_vid), .rd_group (t_group), .rd_col (t_col),
    .rd_char (t_char), .rd_len (t_len)
  );

  wire [5:0] font_ch;
  wire [2:0] font_row;
  wire [7:0] font_bits;
  cheat_font font (.ch (font_ch), .row (font_row), .bits (font_bits));

  reg de = 0, v_blank = 1;
  reg cart = 0, show = 1;
  wire active, ink;

  cheat_osd #(.COLS(COLS), .ROWS(ROWS)) osd (
    .clk (clk_vid), .reset (reset),
    .show (show), .cart_mode (cart),
    .de (de), .v_blank (v_blank),
    .enable_mask (enable_mask),
    .group_count (group_count), .code_count (code_count),
    .title_group (t_group), .title_col (t_col),
    .title_char (t_char), .title_len (t_len),
    .font_ch (font_ch), .font_row (font_row), .font_bits (font_bits),
    .active (active), .ink (ink)
  );

  // core_top registers the overlay outputs into video_rgb_reg on the video
  // clock, so the pixel that reaches the screen is the one computed *before*
  // the edge. Sample it the same way: reading the combinational outputs after
  // the edge is reading the next pixel, and shifts every glyph one column.
  reg capt_active, capt_ink;
  always_ff @(posedge clk_vid) begin
    capt_active <= active;
    capt_ink    <= ink;
  end

  reg dbg = 0;
  always @(posedge clk_vid)
    if (dbg && osd.filling && osd.fill >= 6'd2 && osd.fill_col_d2 < 5'd20)
      $display("W row=%0d fill=%0d d1=%0d d2=%0d ch=%0d bits=%02x",
               osd.text_row, osd.fill, osd.fill_col_d1, osd.fill_col_d2,
               font_ch, font_bits);

  // ------------------------------------------------------------ file input --
  reg [7:0] fbuf [0:1048575];
  reg [8*1024-1:0] fname;
  integer fd, flen, i, arg;

  task load_file;
    begin
      if (!$value$plusargs("f=%s", fname)) begin
        $display("FAIL: no +f=<file>");
        $finish;
      end
      fd = $fopen(fname, "rb");
      if (fd == 0) begin
        $display("FAIL: cannot open %0s", fname);
        $finish;
      end
      flen = $fread(fbuf, fd);
      $fclose(fd);
      @(posedge clk_sys);
      reset <= 1'b0;
      for (i = 0; i < flen; i = i + 1) begin
        @(posedge clk_sys);
        wr   <= 1'b1;
        data <= fbuf[i];
      end
      @(posedge clk_sys);
      wr <= 1'b0;
      repeat (20) @(posedge clk_sys);
    end
  endtask

  // ---------------------------------------------------------- video timing --
  reg [7:0] pixel [0:V_ACTIVE-1][0:H_ACTIVE-1];
  integer x, y, l;

  task blank_lines(input integer n);
    integer k, c;
    begin
      v_blank <= 1'b1;
      for (k = 0; k < n; k = k + 1)
        for (c = 0; c < H_ACTIVE + H_BLANK; c = c + 1) @(posedge clk_vid);
      v_blank <= 1'b0;
    end
  endtask

  // One frame. `capture` records what the overlay put on each pixel.
  task frame(input capture);
    integer k, c;
    begin
      for (k = 0; k < V_ACTIVE; k = k + 1) begin
        de <= 1'b1;
        for (c = 0; c < H_ACTIVE; c = c + 1) begin
          @(posedge clk_vid);
          #1;
          if (capture)
            pixel[k][c] = capt_ink ? 8'd2 : (capt_active ? 8'd1 : 8'd0);
        end
        de <= 1'b0;
        for (c = 0; c < H_BLANK; c = c + 1) @(posedge clk_vid);
      end
      blank_lines(V_BLANK);
    end
  endtask

  initial begin
    if ($value$plusargs("cart=%d", arg)) cart = (arg != 0);
    if ($value$plusargs("show=%d", arg)) show = (arg != 0);
    if ($value$plusargs("dbg=%d", arg)) dbg = (arg != 0);

    repeat (8) @(posedge clk_sys);
    load_file;

    v_blank = 1'b1;
    repeat (4000) @(posedge clk_vid);
    v_blank = 1'b0;

    frame(1'b0);      // the display list is built during blanking, so draw twice
    frame(1'b1);

    $display("PARSED codes=%0d groups=%0d mask=%08x", code_count, group_count,
             enable_mask);
    $display("FRAME %0d %0d", V_ACTIVE, H_ACTIVE);
    for (y = 0; y < V_ACTIVE; y = y + 1) begin
      $write("PIX ");
      for (x = 0; x < H_ACTIVE; x = x + 1)
        $write("%0s", pixel[y][x] == 8'd2 ? "#" :
                      pixel[y][x] == 8'd1 ? "." : " ");
      $write("\n");
    end
    $display("END");
    $finish;
  end

endmodule
