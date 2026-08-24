// SPDX-License-Identifier: GPL-3.0-or-later
//
// The text of each cheat's name, so the overlay can say which cheats are on.
//
// cheat_loader parses the value of a `cheatN_desc` key and streams it here a
// character at a time; cheat_osd reads it back while drawing. Those happen on
// different clocks, the parser on clk_sys and the video on clk_vid, so this is
// a dual clock RAM: one write port, one read port, no arbitration needed
// because the two never touch the same word at a useful moment (a file loads
// while the picture is blank, and the overlay only draws from a file that has
// finished loading).
//
// 32 titles of 26 characters. 26 because the Game Boy screen is 160 pixels and
// the font cell is 6, so that is a full line and there is nowhere to put a
// twenty-seventh character. Characters are stored as font indices, the ASCII
// code minus 32, which is what cheat_font wants and saves storing a byte.
//
// A title shorter than 20 characters is not padded. Its length is kept in a
// small register file instead, because clearing 20 bytes per title on every
// load would need a state machine and the length needs one adder.

module cheat_titles (
	input  wire        wr_clk,
	input  wire        wr_reset,     // new file arriving: forget every title

	input  wire        wr_en,        // one character
	input  wire [4:0]  wr_group,
	input  wire [4:0]  wr_col,
	input  wire [5:0]  wr_char,      // ASCII - 32

	input  wire        wr_end,       // title finished, wr_col is its length
	input  wire [4:0]  rd_group,     // on rd_clk
	input  wire [4:0]  rd_col,
	input  wire        rd_clk,
	output reg  [5:0]  rd_char,
	output reg  [4:0]  rd_len
);

	logic [5:0] ram [0:831];         // 32 titles x 26 characters
	reg   [4:0] len [0:31];

	// group*26 = group*16 + group*8 + group*2: three shifts and two adds.
	// Spelled out because 26 is not a power of two, so the address is not just
	// a concatenation of the group and the column.
	wire [9:0] wr_base = ({5'd0, wr_group} << 4) + ({5'd0, wr_group} << 3)
	                   + ({5'd0, wr_group} << 1);
	wire [9:0] wr_at   = wr_base + {5'd0, wr_col};
	wire [9:0] rd_base = ({5'd0, rd_group} << 4) + ({5'd0, rd_group} << 3)
	                   + ({5'd0, rd_group} << 1);
	wire [9:0] rd_at   = rd_base + {5'd0, rd_col};

	integer i;
	always_ff @(posedge wr_clk) begin
		if (wr_reset) begin
			for (i = 0; i < 32; i = i + 1) len[i] <= 5'd0;
		end else begin
			if (wr_en)  ram[wr_at] <= wr_char;
			if (wr_end) len[wr_group] <= wr_col;
		end
	end

	// The length is read from the writer's registers on the reader's clock.
	// It changes only while a file is loading, and the worst a torn read can
	// do is draw one frame of a title at the wrong length, so this is a
	// deliberate single register rather than a synchroniser per bit.
	always_ff @(posedge rd_clk) begin
		rd_char <= ram[rd_at];
		rd_len  <= len[rd_group];
	end

endmodule
