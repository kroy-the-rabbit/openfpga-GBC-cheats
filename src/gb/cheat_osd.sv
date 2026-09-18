// SPDX-License-Identifier: GPL-3.0-or-later
// Cheat overlay: counts, source, global switch, two slot rows, then the rest.
// Display list built in vblank, line buffer in hblank. See docs/CHEATS.md.

module cheat_osd #(
	parameter CELL = 6,              // 5 px glyph plus a gap
	parameter COLS = 26,             // 160 / 6, rounded down
	parameter ROWS = 18              // 144 / 8
) (
	input  wire        clk,          // video clock
	input  wire        reset,

	input  wire        show,         // menu toggle, already on this clock
	input  wire        cart_mode,    // playing a physical cartridge
	input  wire        de,           // active picture
	input  wire        v_blank,

	input  wire [31:0] file_mask,    // the file's _enable flags, bit n is group n
	input  wire [2:0]  switches,     // {Cheats enabled, slot 2, slot 1}, from the menu
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

	localparam HDR_ROWS   = 3;
	localparam MASTER_ROW = 2;
	localparam SLOTS      = 2;
	localparam PREFIX     = 6;       // "1 ON  "
	localparam REST_ROW   = HDR_ROWS + SLOTS;
	localparam MAX_REST   = ROWS - REST_ROW;

	localparam MASTER_LEN = 14;      // uppercase, at most COLS - 4
	localparam [8*MASTER_LEN-1:0] MASTER_LABEL = "CHEATS ENABLED";

	wire master_on = switches[2];

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
	// The rest the file left on, rebuilt every vblank; the slots are not in it.
	reg [4:0] list [0:MAX_REST-1];
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
			scan     <= SLOTS[5:0];
			found    <= 5'd0;
		end else if (scanning) begin
			if (scan >= group_count || found >= MAX_REST[4:0]) begin
				scanning <= 1'b0;
				list_n   <= found;
			end else begin
				if (file_mask[scan[4:0]]) begin
					list[found] <= scan[4:0];
					found       <= found + 5'd1;
				end
				scan <= scan + 6'd1;
			end
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

	function automatic [5:0] state_char(input on, input [4:0] col);
		begin
			case (col)
				5'd0: state_char = O;
				5'd1: state_char = on ? N : F;
				5'd2: state_char = on ? SP : F;
				default: state_char = SP;
			endcase
		end
	endfunction

	function automatic [5:0] slot_char(input [4:0] slot, input [4:0] col);
		begin
			if (col == 5'd0)      slot_char = 6'h11 + {1'b0, slot};   // '1' is font index 17
			else if (col >= 5'd2) slot_char = state_char(switches[slot[0]], col - 5'd2);
			else                  slot_char = SP;
		end
	endfunction

	function automatic [5:0] master_char(input [4:0] col);
		reg [7:0] ch;
		begin
			if (col < MASTER_LEN[4:0]) begin
				ch = MASTER_LABEL[8*(MASTER_LEN-1-col) +: 8];
				master_char = ch[5:0] - 6'd32;
			end else if (col > MASTER_LEN[4:0]) begin
				master_char = state_char(master_on, col - MASTER_LEN[4:0] - 5'd1);
			end else begin
				master_char = SP;
			end
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

	function automatic [5:0] fixed_char(input [4:0] row, input [4:0] col);
		begin
			if (row == 5'd1) begin
				fixed_char = mode_char(col);
			end else if (row == MASTER_ROW[4:0]) begin
				fixed_char = master_char(col);
			end else if (group_count == 6'd0) begin
				// "NO CHEATS LOADED"
				case (col)
					5'd0: fixed_char = N;  5'd1: fixed_char = O;
					5'd3: fixed_char = C;  5'd4: fixed_char = H;
					5'd5: fixed_char = E;  5'd6: fixed_char = A;
					5'd7: fixed_char = T;  5'd8: fixed_char = S;
					5'd10: fixed_char = L; 5'd11: fixed_char = O;
					5'd12: fixed_char = A; 5'd13: fixed_char = D;
					5'd14: fixed_char = E; 5'd15: fixed_char = D;
					default: fixed_char = SP;
				endcase
			end else begin
				case (col)
					5'd0: fixed_char = digit(group_count, 1'b1);
					5'd1: fixed_char = digit(group_count, 1'b0);
					5'd3: fixed_char = C;  5'd4: fixed_char = H;
					5'd5: fixed_char = E;  5'd6: fixed_char = A;
					5'd7: fixed_char = T;  5'd8: fixed_char = S;
					5'd10: fixed_char = digit(code_count, 1'b1);
					5'd11: fixed_char = digit(code_count, 1'b0);
					5'd13: fixed_char = C;  5'd14: fixed_char = O;
					5'd15: fixed_char = D;  5'd16: fixed_char = E;
					5'd17: fixed_char = S;
					default: fixed_char = SP;
				endcase
			end
		end
	endfunction

	// ---------------------------------------------------------- line buffer
	// Filled during the blanking before the line it belongs to.
	reg [7:0] line_bits [0:COLS-1];
	reg [5:0] fill;                  // 0..COLS+1, two past the end to drain
	reg       filling;
	// Two stages: cheat_titles answers one cycle after it is asked.
	reg [4:0] fill_col_d1, fill_col_d2;
	reg       fixed_d1, fixed_d2;
	reg       slot_d1, slot_d2;
	reg [5:0] fixed_char_d1, fixed_char_d2;
	reg [5:0] pre_char_d1, pre_char_d2;

	wire       fixed_row  = (text_row < HDR_ROWS[4:0])
	                     && !(text_row == MASTER_ROW[4:0] && group_count == 6'd0);
	wire [4:0] slot_index = text_row - HDR_ROWS[4:0];
	wire       slot_row   = (text_row >= HDR_ROWS[4:0]) && (text_row < REST_ROW[4:0])
	                     && ({1'b0, slot_index} < group_count);
	wire [4:0] rest_index = text_row - REST_ROW[4:0];
	wire       rest_row   = (text_row >= REST_ROW[4:0]) && (rest_index < list_n);
	wire       row_used   = fixed_row || slot_row || rest_row;

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

		title_group   <= slot_row ? slot_index : rest_row ? list[rest_index] : 5'd0;
		title_col     <= slot_row ? fill[4:0] - PREFIX[4:0] : fill[4:0];
		fill_col_d1   <= fill[4:0];
		fixed_d1      <= fixed_row;
		slot_d1       <= slot_row;
		fixed_char_d1 <= fixed_char(text_row, fill[4:0]);
		pre_char_d1   <= slot_char(slot_index, fill[4:0]);

		fill_col_d2   <= fill_col_d1;
		fixed_d2      <= fixed_d1;
		slot_d2       <= slot_d1;
		fixed_char_d2 <= fixed_char_d1;
		pre_char_d2   <= pre_char_d1;
		if (filling && fill >= 6'd2 && fill_col_d2 < COLS[4:0])
			line_bits[fill_col_d2] <= row_used ? font_bits : 8'd0;
	end

	wire [5:0] name_start = slot_d2 ? PREFIX[5:0] : 6'd0;
	wire in_prefix = slot_d2 && (fill_col_d2 < PREFIX[4:0]);
	wire beyond    = ({1'b0, fill_col_d2} >= name_start + {1'b0, title_len});
	assign font_ch  = fixed_d2  ? fixed_char_d2
	                : in_prefix ? pre_char_d2
	                : beyond    ? SP : title_char;
	assign font_row = glyph_row;

	// ------------------------------------------------------------- output
	// The sixth pixel of a cell reads bit 2, which is below the 5 wide glyph
	// and therefore always clear: the gap between letters needs no special case.
	wire [7:0] bits = line_bits[text_col];
	assign active = show && de && row_used && (text_col < COLS[4:0]);
	assign ink    = active && bits[3'd7 - pixel_col];

endmodule
