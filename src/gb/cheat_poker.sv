// SPDX-License-Identifier: GPL-3.0-or-later
//
// cheat_poker - write GameShark codes into RAM once a frame
//
// A Game Genie code patches ROM, so faking it on the CPU's read is exactly
// right. A GameShark code is a RAM write, and faking the read only approximates
// it. The approximation holds for the common case, a counter the game reads
// back and draws, and breaks wherever the value is reached some other way: a
// DMA copy, a routine that caches it once, or a read-modify-write whose result
// is stored and then re-faked on the next read. The value is never actually in
// memory, which is not what the codes were written against.
//
// So this walks the code table on the rising edge of vblank and issues one
// write per live GameShark entry, the way the cartridge did. CODES decides
// which entries belong here: an entry is the poker's only if its address is
// somewhere the poker can reach, which keeps GameShark codes aimed at cart RAM
// or ROM on the read-override path rather than silently doing nothing.
//
// It is worth being clear about what this does not fix. Oracle of Ages painting
// sixteen hearts across the HUD was the code, not the mechanism: "Infinite
// Hearts (Max)" writes 0x40 to $C6AA, which is sixty-four quarter hearts, and a
// poke of 0x40 draws the same sixteen hearts a faked read does. The game does
// not clamp it. Wrong value, not wrong mechanism.
//
// A GameShark code may name a work RAM bank in its type byte (any TT but 0x01).
// Such a code applies only while SVBK has that bank mapped; without the check
// it would write whichever bank happened to be selected at vblank, which is a
// different variable in a different part of the game.
//
// Writes go through port B of the WRAM and HRAM blocks, which the savestate
// engine owns. Savestate always wins; `blocked` simply abandons the walk, and
// nothing is lost because the identical write happens again next frame.
//

`default_nettype none

module cheat_poker #(
    parameter MAX_CODES = 32,
    parameter INDEX_W   = 5
) (
    input  wire                clk,
    input  wire                reset,
    input  wire                enable,      // master cheat switch
    input  wire                vblank,      // level from the LCD, edge detected here
    input  wire                blocked,     // savestate owns the RAM port

    // code table scan port on CODES
    output reg  [INDEX_W-1:0]  scan_index = 0,
    input  wire [15:0]         scan_addr,
    input  wire [7:0]          scan_data,
    input  wire                scan_poke,   // live, and this module's to write
    input  wire [3:0]          scan_bank,   // work RAM bank the code names
    input  wire                scan_bank_qual,

    input  wire [2:0]          wram_bank,   // SVBK, as the CPU currently sees it

    // RAM write, in the clk domain of the dprams' port B
    // Given power-up values, not left to the fitter: Power-Up Don't Care is on
    // in this project, and a poke_wr that comes up asserted writes into work
    // RAM before anything has had a chance to reset it.
    output reg                 poke_wr = 0,
    output reg  [15:0]         poke_addr = 0,
    output reg  [7:0]          poke_data = 0
);

  // CODES registers its scan outputs, so a new index costs one cycle before
  // the entry is readable.
  localparam [2:0] IDLE = 3'd0, SETTLE = 3'd1, LOOK = 3'd2,
                   WRITE = 3'd3, NEXT = 3'd4;

  reg [2:0] state = IDLE;
  reg       vblank_d = 0;

  wire vblank_rise = vblank & ~vblank_d;

  // $D000-$DFFF is the switchable window, so a code that names a bank applies
  // only while that bank is mapped. $C000-$CFFF is always bank 0, where naming
  // a bank means nothing. SVBK 0 selects bank 1 on hardware; normalise both
  // sides the same way before comparing.
  wire [3:0] bank_now  = (wram_bank == 3'd0) ? 4'd1 : {1'b0, wram_bank};
  wire [3:0] bank_want = (scan_bank == 4'd0) ? 4'd1 : scan_bank;
  wire       bank_ok = !scan_bank_qual
                    || (scan_addr[15:12] != 4'hD)
                    || (bank_want == bank_now);

  always @(posedge clk) begin
    if (reset) begin
      state      <= IDLE;
      scan_index <= {INDEX_W{1'b0}};
      poke_wr    <= 1'b0;
      poke_addr  <= 16'd0;
      poke_data  <= 8'd0;
      vblank_d   <= 1'b0;
    end else begin
      vblank_d <= vblank;
      poke_wr  <= 1'b0;

      if (blocked || !enable) begin
        // give the port back immediately; the walk restarts next frame
        state <= IDLE;
      end else begin
        case (state)
          IDLE: if (vblank_rise) begin
            scan_index <= {INDEX_W{1'b0}};
            state      <= SETTLE;
          end

          SETTLE: state <= LOOK;

          LOOK: begin
            if (scan_poke && bank_ok) begin
              poke_addr <= scan_addr;
              poke_data <= scan_data;
              poke_wr   <= 1'b1;
              state     <= WRITE;
            end else begin
              state <= NEXT;
            end
          end

          WRITE: state <= NEXT;

          NEXT: begin
            if (scan_index == MAX_CODES[INDEX_W-1:0] - {{(INDEX_W-1){1'b0}}, 1'b1}) begin
              state <= IDLE;
            end else begin
              scan_index <= scan_index + {{(INDEX_W-1){1'b0}}, 1'b1};
              state      <= SETTLE;
            end
          end

          default: state <= IDLE;
        endcase
      end
    end
  end

endmodule

`default_nettype wire
