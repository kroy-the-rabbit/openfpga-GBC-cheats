// SPDX-License-Identifier: GPL-3.0-or-later
// Cheat Code handling by Kitrinx
// Apr 21, 2019

// Code layout:
// {clock bit, code flags,     32'b address, 32'b compare, 32'b replace}
//  128        127:96          95:64         63:32         31:0
// Integer values are in BIG endian byte order, so it up to the loader
// or generator of the code to re-arrange them correctly.
//
// Pocket port (openfpga-GBC cheats): the flags field now carries the cheat
// group index that a code belongs to, so several codes from one libretro
// cheat share a single on/off bit, plus a bit marking GameShark codes:
//   code[96]     use compare byte
//   code[101:97] group index, selects the bit of enable_mask that gates it
//   code[102]    GameShark, i.e. a RAM write rather than a ROM patch
//   code[106:103] work RAM bank the code names, if any
//   code[107]    that bank field is meaningful (GameShark TT other than 0x01)

module CODES(
	input  clk,        // Best to not make it too high speed for timing reasons
	input  reset,      // This should only be triggered when a new rom is loaded or before new codes load, not warm reset
	input  enable,
	output logic available,
	input  [ADDR_WIDTH - 1:0] addr_in,
	input  [DATA_WIDTH - 1:0] data_in,
	input  [128:0] code,
	input  [MAX_GROUPS - 1:0] enable_mask, // per-group on/off, from the cheat file
	output logic genie_ovr,
	output logic [DATA_WIDTH - 1:0] genie_data,

	// Scan port for cheat_poker: one entry per cycle, registered.
	input  [INDEX_SIZE - 1:0] scan_index,
	output logic [ADDR_WIDTH - 1:0] scan_addr,
	output logic [DATA_WIDTH - 1:0] scan_data,
	output logic scan_poke,
	output logic [3:0] scan_bank,
	output logic scan_bank_qual,

	// How many entries are actually loaded, for the menu readout. The parsed
	// code count comes from cheat_loader; this is what arrived at the far end.
	output logic [5:0] entry_count
);

parameter ADDR_WIDTH   = 16; // Not more than 32
parameter DATA_WIDTH   = 8;  // Not more than 32
parameter MAX_CODES    = 32;
parameter MAX_GROUPS   = 32;

localparam INDEX_SIZE  = $clog2(MAX_CODES-1); // Number of bits for index, must accomodate MAX_CODES
localparam GROUP_SIZE  = $clog2(MAX_GROUPS);  // Number of bits for the group index

localparam DATA_S      = DATA_WIDTH - 1;
localparam COMP_S      = DATA_S + DATA_WIDTH;
localparam ADDR_S      = COMP_S + ADDR_WIDTH;
localparam COMP_F_S    = ADDR_S + 1;
localparam GROUP_S     = COMP_F_S + GROUP_SIZE;
localparam POKE_S      = GROUP_S + 1;
localparam BANK_S      = POKE_S + 4;
localparam BANKQ_S     = BANK_S + 1;
localparam ENA_F_S     = BANKQ_S + 1;
localparam CODE_WIDTH  = ENA_F_S + 1;

reg [ENA_F_S:0] codes[MAX_CODES];

wire [ADDR_WIDTH-1: 0] code_addr    = code[64+:ADDR_WIDTH];
wire [DATA_WIDTH-1: 0] code_compare = code[32+:DATA_WIDTH];
wire [DATA_WIDTH-1: 0] code_data    = code[0+:DATA_WIDTH];
wire code_comp_f = code[96];
wire [GROUP_SIZE-1:0] code_group = code[97+:GROUP_SIZE];
wire code_poke = code[102];
wire [3:0] code_bank = code[103+:4];
wire code_bank_qual = code[107];

wire [BANKQ_S:0] code_trimmed = {code_bank_qual, code_bank, code_poke, code_group, code_comp_f, code_addr, code_compare, code_data};

// Fields of every stored entry, broken out once. Slicing codes[x] inside a
// procedural loop is legal but not portable (Icarus warns that it widens the
// select), and the simulation is the only check these comparisons get.
wire [ADDR_WIDTH-1:0] entry_addr  [MAX_CODES];
wire [DATA_WIDTH-1:0] entry_data  [MAX_CODES];
wire [DATA_WIDTH-1:0] entry_comp  [MAX_CODES];
wire                  entry_compf [MAX_CODES];
wire [GROUP_SIZE-1:0] entry_group [MAX_CODES];
wire                  entry_poke  [MAX_CODES];
wire [3:0]            entry_bank  [MAX_CODES];
wire                  entry_bankq [MAX_CODES];
wire                  entry_used  [MAX_CODES];

genvar gi;
generate
	for (gi = 0; gi < MAX_CODES; gi = gi + 1) begin : unpack
		assign entry_addr[gi]  = codes[gi][ADDR_S -: ADDR_WIDTH];
		assign entry_data[gi]  = codes[gi][DATA_S -: DATA_WIDTH];
		assign entry_comp[gi]  = codes[gi][COMP_S -: DATA_WIDTH];
		assign entry_compf[gi] = codes[gi][COMP_F_S];
		assign entry_group[gi] = codes[gi][GROUP_S -: GROUP_SIZE];
		assign entry_poke[gi]  = codes[gi][POKE_S];
		assign entry_bank[gi]  = codes[gi][BANK_S -: 4];
		assign entry_bankq[gi] = codes[gi][BANKQ_S];
		assign entry_used[gi]  = codes[gi][ENA_F_S];
	end
endgenerate

// Where cheat_poker can actually write. Anything outside it stays on the read
// override, so a GameShark code aimed at cart RAM keeps working as before
// rather than quietly doing nothing. Assumes the Game Boy's 16 bit map.
function automatic logic pokeable(input logic [ADDR_WIDTH-1:0] a);
	pokeable = (a[15:13] == 3'b110)                              // $C000-$DFFF work RAM
	        || ((a[15:7] == 9'b111111111) && (a != 16'hFFFF));   // $FF80-$FFFE high RAM
endfunction

// If MAX_INDEX is changes, these need to be made larger
wire  [INDEX_SIZE-1:0] index;
logic [INDEX_SIZE-1:0] dup_index;
reg   [INDEX_SIZE:0]   next_index;
logic found_dup;

assign index = found_dup ? dup_index : next_index[INDEX_SIZE-1:0];

// See if this exact code exists already, so reloading a file updates entries in
// place rather than filling the table.
//
// Keyed on the cheat it belongs to as well as its address. Keyed on address
// alone, as this was, any two cheats aiming at one address collapse into one:
// a later *disabled* alternative overwrites an earlier enabled cheat, taking
// its group with it, and the enabled cheat silently stops working. Libretro
// files ship with everything disabled and often list several alternatives for
// one address, so that is the common case, not a corner. Unused slots are
// excluded too, or a code at address $0000 matches all 32 of them.
always_comb begin
	int x;
	dup_index = 0;
	found_dup = 0;

	for (x = 0; x < MAX_CODES; x = x + 1) begin
		if (entry_used[x] && entry_addr[x] == code_addr
		                  && entry_group[x] == code_group) begin
			dup_index = x[INDEX_SIZE-1:0];
			found_dup = 1;
		end
	end
end

assign available = |next_index;
assign entry_count = next_index[5:0];

reg code_change;
always_ff @(posedge clk) begin
	int x;
	if (reset) begin
		next_index <= 0;
		code_change <= 0;
		for (x = 0; x < MAX_CODES; x = x + 1) codes[x] <= '0;
	end else begin
		code_change <= code[128];
		if (code[128] && ~code_change && (found_dup || next_index < MAX_CODES)) begin // detect posedge
			// replace it enabled if it has the same address, otherwise, add a new code
			codes[index] <= {1'b1, code_trimmed};
			if (~found_dup) next_index <= next_index + 1'b1;
		end
	end
end

// Which entries are live, split by who acts on them. Registered on purpose:
// the mask lookup is a MAX_CODES-deep set of muxes, and the combinational
// compare below sits directly on the CPU data-in path. Both only change when a
// file loads, so a cycle of latency here costs nothing.
//
// An entry belongs to exactly one of these. entry_ena drives the read
// override; entry_pk is written into RAM by cheat_poker instead, which is what
// makes a GameShark code behave like the cartridge did.
reg [MAX_CODES-1:0] entry_ena;
reg [MAX_CODES-1:0] entry_pk;

always_ff @(posedge clk) begin
	int x;
	logic live, poked;
	if (reset) begin
		entry_ena <= '0;
		entry_pk  <= '0;
	end else begin
		for (x = 0; x < MAX_CODES; x = x + 1) begin
			live  = entry_used[x] && enable_mask[entry_group[x]];
			poked = entry_poke[x] && pokeable(entry_addr[x]);
			entry_ena[x] <= live && !poked;
			entry_pk[x]  <= live &&  poked;
		end
	end
end

// Scan port. Registered so the 32 way mux it needs cannot creep onto the CPU
// data path, and because cheat_poker has a whole frame to walk the table.
reg [ADDR_WIDTH-1:0] scan_addr_r;
reg [DATA_WIDTH-1:0] scan_data_r;
reg                  scan_poke_r;
reg [3:0]            scan_bank_r;
reg                  scan_bankq_r;

always_ff @(posedge clk) begin
	scan_addr_r  <= entry_addr[scan_index];
	scan_data_r  <= entry_data[scan_index];
	scan_poke_r  <= entry_pk[scan_index];
	scan_bank_r  <= entry_bank[scan_index];
	scan_bankq_r <= entry_bankq[scan_index];
end

assign scan_addr      = scan_addr_r;
assign scan_data      = scan_data_r;
assign scan_poke      = scan_poke_r;
assign scan_bank      = scan_bank_r;
assign scan_bank_qual = scan_bankq_r;

// Lookup is split in two so that data_in only ever feeds a single 8-bit
// compare. data_in is the CPU's read data: it settles late, after the memory
// read has resolved. addr_in is a register output and is stable from the start
// of the cycle, so the 32-way search belongs on that side.
//
// Testing the compare byte inside the search loop (as this module originally
// did) puts the whole comparator chain plus the priority mux between data_in
// and the CPU's DI pin, and on this device that path missed timing by 3.4 ns.
//
// Disabled entries are excluded here by entry_ena, so a disabled cheat sharing
// an address with an enabled one cannot hide it. That, plus keying the store on
// the cheat as well as the address, is what fixes the collision; the search
// itself deliberately stays as it was.
//
// One winner, chosen from addr_in alone. Carrying several candidates so that
// two compare-qualified entries could share an address was tried and cost 6 ns
// of setup slack: it made genie_data itself depend on data_in through a second
// mux, and built the candidate list with a 32-deep serial chain feeding that
// compare. The critical path runs video lcdc -> cpu_di -> here -> the CPU's
// data input, and it will not carry it. So two *enabled* cheats at one address
// still resolve to the last one loaded, which is a documented limit.
logic                  addr_hit;
logic [DATA_WIDTH-1:0] hit_data, hit_comp;
logic                  hit_comp_f;

always_comb begin
	int x;
	addr_hit   = 1'b0;
	hit_data   = '0;
	hit_comp   = '0;
	hit_comp_f = 1'b0;

	for (x = 0; x < MAX_CODES; x = x + 1) begin
		if (entry_ena[x] && entry_addr[x] == addr_in) begin
			addr_hit   = 1'b1;
			hit_data   = entry_data[x];
			hit_comp   = entry_comp[x];
			hit_comp_f = entry_compf[x];
		end
	end
end

always_comb begin
	genie_ovr  = enable && addr_hit && (!hit_comp_f || (hit_comp == data_in));
	genie_data = hit_data;
end

endmodule
