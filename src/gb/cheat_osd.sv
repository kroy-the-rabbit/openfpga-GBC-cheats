// SPDX-License-Identifier: GPL-3.0-or-later
//
// Draws the two cheat slots over the game picture, each marked on or off.
//
// The Pocket menu cannot do this. APF fixes every label in interact.json at
// build time and gives a core no way to put a string on screen, which is why
// the menu can only ever say "Cheat slot 1". The core does own every pixel of
// the game picture, though, so the names go there instead.
//
//      3 CHEATS  5 CODES
//     ROM FILE
//     1 ON  INFINITE HEALTH (3 HE
//     2 OFF 999 RUPEES
//
// The header counts what the parser made of the file, so a file with more
// cheats than slots says so. The second header row says whether the game is a
// cartridge or a file, because the two get their cheats by different routes
// and a wrong file looks the same as no file. Then one row per loaded slot:
// its number, ON or OFF from the menu, and the cheat's name.
//
// The screen is 160x144 and the cell is 6x8, so the grid is 26 columns by
// 18 rows. The six column slot prefix leaves 20 for the name.
//
// The line buffer is filled during horizontal blanking. Each text row needs 26
// glyph bytes and each takes a RAM read plus a font lookup; doing that per
// pixel would put a memory on the video path. A line of blanking is far longer
// than the 30 cycles this needs.

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

	input  wire [31:0] enable_mask,  // bit n: slot n+1 is on
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
	localparam SLOTS     = 2;        // one row each
	localparam PREFIX    = 6;        // "1 ON  " before the name

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

	// "1 ON  " or "2 OFF ", in front of the name.
	function automatic [5:0] slot_char(input [4:0] slot, input [4:0] col);
		begin
			case (col)
				5'd0: slot_char = 6'h11 + {1'b0, slot};   // '1' is font index 17
				5'd2: slot_char = O;
				5'd3: slot_char = enable_mask[slot] ? N : F;
				5'd4: slot_char = enable_mask[slot] ? SP : F;
				default: slot_char = SP;
			endcase
		end
	endfunction

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
					5'd0: header_char = digit(group_count, 1'b1);
					5'd1: header_char = digit(group_count, 1'b0);
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
	// Two stages, address then write. cheat_titles registers its read once, so
	// its answer for the column asked at d1 is valid in step with d2. The header
	// and the slot prefix take the same two so every part of a line agrees on
	// the column.
	reg [4:0] fill_col_d1, fill_col_d2;
	reg       fill_hdr_d1, fill_hdr_d2;
	reg [5:0] hdr_char_d1, hdr_char_d2;
	reg [5:0] pre_char_d1, pre_char_d2;

	wire in_header = (text_row < HDR_ROWS[4:0]);
	wire [4:0] row_index = text_row - HDR_ROWS[4:0];   // the slot, 0 based
	wire       row_used  = in_header
	                    || (row_index < SLOTS[4:0] && {1'b0, row_index} < group_count);

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
		// The name starts after the prefix, so the RAM is asked for the
		// column PREFIX back; what it says for the prefix columns is unused.
		title_group <= row_used && !in_header ? row_index : 5'd0;
		title_col   <= fill[4:0] - PREFIX[4:0];
		fill_col_d1 <= fill[4:0];
		fill_hdr_d1 <= in_header;
		hdr_char_d1 <= header_char(text_row, fill[4:0]);
		pre_char_d1 <= slot_char(row_index, fill[4:0]);

		// Write stage: the RAM is answering, so the glyph row is out.
		fill_col_d2 <= fill_col_d1;
		fill_hdr_d2 <= fill_hdr_d1;
		hdr_char_d2 <= hdr_char_d1;
		pre_char_d2 <= pre_char_d1;
		if (filling && fill >= 6'd2 && fill_col_d2 < COLS[4:0])
			line_bits[fill_col_d2] <= row_used ? font_bits : 8'd0;
	end

	wire in_prefix = (fill_col_d2 < PREFIX[4:0]);
	wire beyond    = ({1'b0, fill_col_d2} >= PREFIX[5:0] + {1'b0, title_len});
	assign font_ch  = fill_hdr_d2 ? hdr_char_d2
	                : in_prefix   ? pre_char_d2
	                : beyond      ? SP : title_char;
	assign font_row = glyph_row;

	// ------------------------------------------------------------- output
	// The sixth pixel of a cell reads bit 2, which is below the 5 wide glyph
	// and therefore always clear: the gap between letters needs no special case.
	wire [7:0] bits = line_bits[text_col];
	assign active = show && de && row_used && (text_col < COLS[4:0]);
	assign ink    = active && bits[3'd7 - pixel_col];

endmodule
