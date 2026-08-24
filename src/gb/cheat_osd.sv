// SPDX-License-Identifier: GPL-3.0-or-later
//
// Draws the names of the enabled cheats over the game picture.
//
// The Pocket menu cannot do this. APF fixes every label in interact.json at
// build time and gives a core no way to put a string on screen, which is why
// the menu can only ever say "Cheat 1", "Cheat 2". The core does own every
// pixel of the game picture, though, so the list goes there instead.
//
//     10 CHEATS 16 CODES
//     ROM FILE
//     INFINITE HEALTH (3 HEARTS)
//     999 RUPEES
//     INFINITE BOMBS
//     ...
//
// The screen is 160x144 and the cell is 6x8, so the grid is 26 columns by
// 18 rows: two header rows and up to 16 titles. The second header row says
// whether the game is a cartridge or a file, because the two get their cheats
// by different routes and a wrong file looks the same as no file.
//
// Two things are computed ahead of the pixels that need them:
//
// The display list, during vertical blanking. Walking 32 groups to find the
// nth enabled one cannot be done combinationally per pixel, so it is done once
// a frame into a small array.
//
// The line buffer, during horizontal blanking. Each text row needs 20 glyph
// bytes and each takes a RAM read plus a font lookup; doing that per pixel
// would put a memory on the video path. A line of blanking is far longer than
// the 22 cycles this needs.

module cheat_osd #(
	// The glyph is 5 wide in an 8 wide byte, so a 6 pixel cell still leaves a
	// clear column between letters and fits 26 of them across a 160 pixel
	// screen instead of 20. Rows stay at 8: the gap under a glyph is what keeps
	// lines apart, and there is no shortage of height.
	parameter CELL = 6,
	parameter COLS = 26,             // 160 / 6, rounded down
	parameter ROWS = 18              // 144 / 8
) (
	input  wire        clk,          // video clock
	input  wire        reset,

	input  wire        show,         // menu toggle, already on this clock
	input  wire        cart_mode,    // playing a physical cartridge
	input  wire        de,           // active picture
	input  wire        v_blank,

	input  wire [31:0] enable_mask,  // which groups the file turned on
	input  wire [5:0]  group_count,
	input  wire [5:0]  code_count,

	output reg  [4:0]  title_group,  // to cheat_titles
	output reg  [4:0]  title_col,
	input  wire [5:0]  title_char,
	input  wire [4:0]  title_len,

	output wire [5:0]  font_ch,      // to cheat_font
	output wire [2:0]  font_row,
	input  wire [7:0]  font_bits,

	output wire        active,       // this pixel belongs to the overlay
	output wire        ink           // and it is part of a letter
);

	localparam HDR_ROWS  = 2;        // counts, then where the game came from
	localparam MAX_LINES = ROWS - HDR_ROWS;

	// ---------------------------------------------------------------- pixels
	reg [7:0] px;
	reg [7:0] py;
	reg       de_d;
	wire      line_end = de_d & ~de;

	always_ff @(posedge clk) begin
		de_d <= de;
		if (reset || v_blank) begin
			px <= 8'd0;
			py <= 8'd0;
		end else begin
			px <= de ? px + 8'd1 : 8'd0;
			// py names the line about to be drawn, so the line buffer can be
			// filled during the blanking that precedes it.
			if (line_end) py <= py + 8'd1;
		end
	end

	wire [4:0] text_row  = py[7:3];
	wire [2:0] glyph_row = py[2:0];
	// 6 does not divide a bit slice, so the column is counted rather than
	// sliced out of px. Both follow px exactly: reset while blanking, one step
	// per active pixel, so they name the pixel being computed just as px does.
	reg [4:0] text_col;
	reg [2:0] pixel_col;

	always_ff @(posedge clk) begin
		if (reset || !de) begin
			text_col  <= 5'd0;
			pixel_col <= 3'd0;
		end else if (pixel_col == CELL[2:0] - 3'd1) begin
			pixel_col <= 3'd0;
			text_col  <= text_col + 5'd1;
		end else begin
			pixel_col <= pixel_col + 3'd1;
		end
	end

	// ---------------------------------------------------- display list
	// Which groups are on, in order, rebuilt every vertical blank.
	reg [4:0] list [0:MAX_LINES-1];
	reg [4:0] list_n;
	reg [5:0] scan;
	reg [4:0] found;
	reg       scanning;
	reg       vb_d;
	wire      vb_rise = v_blank & ~vb_d;

	always_ff @(posedge clk) begin
		vb_d <= v_blank;
		if (reset) begin
			scanning <= 1'b0;
			list_n   <= 5'd0;
			scan     <= 6'd0;
			found    <= 5'd0;
		end else if (vb_rise) begin
			scanning <= 1'b1;
			scan     <= 6'd0;
			found    <= 5'd0;
		end else if (scanning) begin
			if (scan >= group_count || found >= MAX_LINES[4:0]) begin
				scanning <= 1'b0;
				list_n   <= found;
			end else begin
				if (enable_mask[scan[4:0]]) begin
					list[found] <= scan[4:0];
					found       <= found + 5'd1;
				end
				scan <= scan + 6'd1;
			end
		end
	end

	// How many enabled cheats did not fit on screen.
	wire [5:0] on_total = count_enabled(enable_mask, group_count);
	function automatic [5:0] count_enabled(input [31:0] mask, input [5:0] n);
		integer k;
		begin
			count_enabled = 6'd0;
			for (k = 0; k < 32; k = k + 1)
				if (mask[k] && k < n) count_enabled = count_enabled + 6'd1;
		end
	endfunction

	// ------------------------------------------------------------- header
	// "NN CHEATS MM CODES", or a plain statement when there is nothing to say.
	function automatic [5:0] digit(input [5:0] v, input tens);
		reg [5:0] t;
		begin
			t = (v >= 6'd60) ? 6'd6 : (v >= 6'd50) ? 6'd5 : (v >= 6'd40) ? 6'd4 :
			    (v >= 6'd30) ? 6'd3 : (v >= 6'd20) ? 6'd2 : (v >= 6'd10) ? 6'd1 : 6'd0;
			// A leading zero on a count of four cheats reads as a mistake, so
			// the tens column is blank below ten.
			digit = tens ? (t == 6'd0 ? SP : (6'h10 + t))  // '0' is font index 16
			             : (6'h10 + (v - (t * 6'd10)));
		end
	endfunction

	// Font indices: ASCII - 32. Spelled out so the header needs no string ROM.
	localparam [5:0] SP = 6'd0,  A = 6'd33, C = 6'd35, D = 6'd36, E = 6'd37,
	                 F = 6'd38, G = 6'd39, H = 6'd40, I = 6'd41, L = 6'd44,
	                 M = 6'd45, N = 6'd46, O = 6'd47, R = 6'd50, S = 6'd51,
	                 T = 6'd52;

	// Row 1 says where the game came from. In Play Cartridge mode APF does not
	// load a slot named after slot 0, so a cartridge session gets its cheat file
	// from the file browser instead, and which one is anybody's guess from the
	// picture alone. Saying which mode is running makes a wrong file obvious.
	function automatic [5:0] mode_char(input [4:0] col);
		begin
			if (cart_mode) begin
				// "CARTRIDGE"
				case (col)
					5'd0: mode_char = C;  5'd1: mode_char = A;
					5'd2: mode_char = R;  5'd3: mode_char = T;
					5'd4: mode_char = R;  5'd5: mode_char = I;
					5'd6: mode_char = D;  5'd7: mode_char = G;
					5'd8: mode_char = E;
					default: mode_char = SP;
				endcase
			end else begin
				// "ROM FILE"
				case (col)
					5'd0: mode_char = R;  5'd1: mode_char = O;
					5'd2: mode_char = M;
					5'd4: mode_char = F;  5'd5: mode_char = I;
					5'd6: mode_char = L;  5'd7: mode_char = E;
					default: mode_char = SP;
				endcase
			end
		end
	endfunction

	function automatic [5:0] header_char(input [4:0] row, input [4:0] col);
		begin
			if (row == 5'd1) begin
				header_char = mode_char(col);
			end else if (group_count == 6'd0) begin
				// "NO CHEATS LOADED"
				case (col)
					5'd0: header_char = N;  5'd1: header_char = O;
					5'd3: header_char = C;  5'd4: header_char = H;
					5'd5: header_char = E;  5'd6: header_char = A;
					5'd7: header_char = T;  5'd8: header_char = S;
					5'd10: header_char = L; 5'd11: header_char = O;
					5'd12: header_char = A; 5'd13: header_char = D;
					5'd14: header_char = E; 5'd15: header_char = D;
					default: header_char = SP;
				endcase
			end else begin
				case (col)
					5'd0: header_char = digit(on_total, 1'b1);
					5'd1: header_char = digit(on_total, 1'b0);
					5'd3: header_char = C;  5'd4: header_char = H;
					5'd5: header_char = E;  5'd6: header_char = A;
					5'd7: header_char = T;  5'd8: header_char = S;
					5'd10: header_char = digit(code_count, 1'b1);
					5'd11: header_char = digit(code_count, 1'b0);
					5'd13: header_char = C;  5'd14: header_char = O;
					5'd15: header_char = D;  5'd16: header_char = E;
					5'd17: header_char = S;
					default: header_char = SP;
				endcase
			end
		end
	endfunction

	// ---------------------------------------------------------- line buffer
	// Filled during the blanking before the line it belongs to.
	reg [7:0] line_bits [0:COLS-1];
	reg [5:0] fill;                  // 0..COLS+1, two past the end to drain
	reg       filling;
	// Three stages, because the address is registered here and again inside
	// cheat_titles before its data comes back. The header takes the same three
	// so both halves of a line agree on which column they are drawing.
	reg [4:0] fill_col_d1, fill_col_d2, fill_col_d3;
	reg       fill_hdr_d1, fill_hdr_d2, fill_hdr_d3;
	reg [5:0] hdr_char_d1, hdr_char_d2, hdr_char_d3;

	wire in_header = (text_row < HDR_ROWS[4:0]);
	wire [4:0] row_index = text_row - HDR_ROWS[4:0];
	wire       row_used  = in_header || (row_index < list_n);

	always_ff @(posedge clk) begin
		if (reset) begin
			filling <= 1'b0;
			fill    <= 6'd0;
		end else if (line_end || (v_blank && !filling && py == 8'd0)) begin
			filling <= 1'b1;
			fill    <= 6'd0;
		end else if (filling) begin
			if (fill > COLS + 2) filling <= 1'b0;
			else                 fill <= fill + 6'd1;
		end

		// Address stage: ask the title RAM and the font for column `fill`.
		title_group <= row_used && !in_header ? list[row_index] : 5'd0;
		title_col   <= fill[4:0];
		fill_col_d1 <= fill[4:0];
		fill_hdr_d1 <= in_header;
		hdr_char_d1 <= header_char(text_row, fill[4:0]);

		// Data stage: the RAM is answering.
		fill_col_d2 <= fill_col_d1;
		fill_hdr_d2 <= fill_hdr_d1;
		hdr_char_d2 <= hdr_char_d1;
		fill_col_d3 <= fill_col_d2;
		fill_hdr_d3 <= fill_hdr_d2;
		hdr_char_d3 <= hdr_char_d2;

		// Write stage: the glyph row is out.
		if (filling && fill >= 6'd3 && fill_col_d3 < COLS[4:0])
			line_bits[fill_col_d3] <= row_used ? font_bits : 8'd0;
	end

	// The title RAM answers two cycles after being asked, so the header has to
	// be delayed by the same two or the two halves of a line disagree about
	// which column they are drawing.
	wire beyond = !fill_hdr_d3 && (fill_col_d3 >= title_len);
	assign font_ch  = fill_hdr_d3 ? hdr_char_d3 : (beyond ? SP : title_char);
	assign font_row = glyph_row;

	// ------------------------------------------------------------- output
	// The sixth pixel of a cell reads bit 2, which is below the 5 wide glyph
	// and therefore always clear: the gap between letters needs no special case.
	wire [7:0] bits = line_bits[text_col];
	assign active = show && de && row_used && (text_col < COLS[4:0]);
	assign ink    = active && bits[3'd7 - pixel_col];

endmodule
