// SPDX-License-Identifier: GPL-3.0-or-later
//
// cheat_loader - parse libretro .cht cheat files into CODES entries
//
// Consumes the raw byte stream of a .cht file from data_loader and shifts each
// recognised code into the CODES module (cheatcodes.sv) using its 129-bit
// protocol. Nothing is decoded host-side: drop a file from
// libretro-database/cht next to the ROM and it works.
//
// File format (libretro):
//
//     cheats = 28
//
//     cheat0_desc = "Infinite Health (3 Hearts)"
//     cheat0_code = "010CAAC6"
//     cheat0_enable = false
//
// Only the value of a key ending in `_code` is examined, and a keyword only
// counts as a key once `=` follows it. Free text is never tokenized, because
// plenty of English words are valid hex ("Decade", "Facade", "Beaded" all parse
// as 6-digit Game Genie codes). Matching the bare characters is not enough:
// `_code` is a substring of `notes_codecs`, and `# _code means "Facade"` would
// otherwise emit a patch out of a comment.
//
// One cheat may hold several codes joined by '+' ("01XXADC6+010YAEC6"); they
// share one on/off state, so a cheat is a *group* and each group owns one bit
// of the enable mask. Codes with placeholder letters (XX, YY) are not valid hex
// and are dropped; a group with no valid codes consumes no mask bit.
//
// Whether a cheat is on comes from the file, via the `cheatN_enable` key that
// libretro files already carry. A group with no enable key defaults to on, so a
// hand-written file that lists nothing but codes works. libretro writes desc,
// code and enable in that order, so an enable key applies to the group the
// preceding `_code` completed; if that block produced no valid codes, the key
// is ignored rather than falling through onto the previous cheat.
//
// Recognised tokens (hyphens are cosmetic and ignored):
//   8 hex digits  TTVVAAAA   GameShark: value VV at address AAAA (little endian),
//                              TT other than 0x01 restricting it to a WRAM bank
//   9 hex digits  ABC-DEF-GHI Game Genie with compare byte
//   6 hex digits  ABC-DEF     Game Genie without compare
//
// Game Genie decode follows SameBoy's Core/cheats.c; tools/cheats/ggdecode.py
// is the executable copy of the same algorithm and tools/sim cross-checks this
// module against it over the whole libretro database.
//
// This is a byte-for-byte model of tools/cheats/chtparse.py. Keep them in step.
//

`default_nettype none

module cheat_loader #(
    parameter MAX_CODES  = 32,   // must match the CODES instance
    parameter MAX_GROUPS = 32    // enable-mask width
) (
    input  wire         clk,
    input  wire         reset,      // clears the parser and the code counters

    input  wire         wr,         // byte strobe from data_loader
    input  wire [7:0]   data,

    output reg  [128:0] code,        // to CODES; bit 128 latches on its rising edge
    output reg  [31:0]  enable_mask, // per-group on/off, read from the file
    output reg  [5:0]   code_count,  // codes accepted
    output reg  [5:0]   group_count, // groups accepted
    output reg  [19:0]  byte_count   // bytes received, for the menu readout
);

  // ---------------------------------------------------------------- lexing --
  localparam [39:0] KEY_CODE   = "_code";
  localparam [39:0] KEY_DESC   = "_desc";
  localparam [55:0] KEY_ENABLE = "_enable";

  reg [55:0] hist;         // last seven bytes, for keyword matching
  // A keyword only counts once '=' follows it. Matching the bare characters is
  // not enough: `_code` is a substring of `notes_codecs`, and a comment reading
  // `# _code means "Facade"` would otherwise arm the collector and emit a
  // phantom Game Genie patch out of the description that follows.
  reg        pend_code;    // `_code` seen, waiting to see whether it is a key
  reg        pend_desc;
  reg        pend_enable;
  reg        armed_code;   // a `_code =` key was seen; next string holds codes
  reg        armed_desc;
  reg        armed_enable; // a `_enable =` key was seen; next word is its value
  reg        in_str;       // skipping an uninteresting quoted string
  reg        collecting;   // inside a `_code` string
  reg        last_group_ok; // the previous `_code` block produced a group

  wire [7:0] ch      = data;
  wire       is_quote = (ch == 8'h22);
  wire       is_dash  = (ch == "-");
  wire       is_nl    = (ch == 8'h0A);
  wire       is_space = (ch == " ") || (ch == 8'h09);   // between key and '='
  wire       is_dig   = (ch >= "0") && (ch <= "9");
  wire       is_upper = (ch >= "A") && (ch <= "F");
  wire       is_lower = (ch >= "a") && (ch <= "f");
  wire       is_hex   = is_dig | is_upper | is_lower;
  wire       is_alpha = ((ch >= "A") && (ch <= "Z")) || ((ch >= "a") && (ch <= "z"));
  wire       is_alnum = is_alpha | is_dig;
  // "true"/"1" mean on; anything else ("false", "0") means off.
  wire       says_on  = (ch == "t") || (ch == "T") || (ch == "1");
  wire [3:0] nibble   = is_dig   ? (ch - "0")
                      : is_upper ? (ch - "A" + 8'd10)
                                 : (ch - "a" + 8'd10);

  // ------------------------------------------------------------ token buffer --
  reg  [3:0] nib [0:8];   // up to nine hex digits, nib[0] is the first
  reg  [3:0] tok_len;
  reg        tok_ovf;     // more than nine digits: not a code, drop it

  // ------------------------------------------------------------- group state --
  reg [5:0] cur_group;
  reg       group_has_code;

  // ------------------------------------------------------------------ decode --
  // Game Genie: value = AB, address = {~F, C, D, E}, compare = rotr2(GI) ^ 0xBA.
  wire [15:0] gg_addr = {~nib[5], nib[2], nib[3], nib[4]};
  wire [7:0]  gg_val  = {nib[0], nib[1]};
  wire [7:0]  gg_raw  = {nib[6], nib[8]};
  wire [7:0]  gg_cmp  = {gg_raw[1:0], gg_raw[7:2]} ^ 8'hBA;
  wire        gg_rom  = ~gg_addr[15];        // ROM only: address <= 0x7FFF

  // GameShark: TTVVAAAA, address little endian. TT is the type/bank byte.
  //
  // TT of 0x01 means any bank; anything else names a work RAM bank in its low
  // nibble, and the code then applies only while SVBK has that bank mapped.
  // This follows SameBoy, as the Game Genie decode does, and matches what
  // tools/cheats/ggdecode.py has always decoded. A named bank above 7 can never
  // match, which is correct: there is no such bank.
  wire [15:0] gs_addr = {nib[6], nib[7], nib[4], nib[5]};
  wire [7:0]  gs_val  = {nib[2], nib[3]};
  wire [7:0]  gs_type = {nib[0], nib[1]};
  wire        gs_bank_qual = (gs_type != 8'h01);
  wire [3:0]  gs_bank      = gs_type[3:0];

  reg         tok_ok;
  reg [15:0]  tok_addr;
  reg [7:0]   tok_val;
  reg [7:0]   tok_cmp;
  reg         tok_usecmp;
  // GameShark codes are RAM writes, not ROM patches. cheat_poker performs the
  // write; CODES keeps the read override for the ones it cannot reach.
  reg         tok_poke;
  reg         tok_bank_qual;   // the code names a work RAM bank
  reg  [3:0]  tok_bank;

  always @* begin
    tok_ok     = 1'b0;
    tok_addr   = 16'd0;
    tok_val    = 8'd0;
    tok_cmp    = 8'd0;
    tok_usecmp = 1'b0;
    tok_poke   = 1'b0;
    tok_bank_qual = 1'b0;
    tok_bank      = 4'd0;
    if (!tok_ovf) begin
      case (tok_len)
        4'd8: begin                       // GameShark
          tok_ok        = 1'b1;
          tok_addr      = gs_addr;
          tok_val       = gs_val;
          tok_poke      = 1'b1;
          tok_bank_qual = gs_bank_qual;
          tok_bank      = gs_bank;
        end
        4'd9: begin                       // Game Genie with compare
          tok_ok     = gg_rom;
          tok_addr   = gg_addr;
          tok_val    = gg_val;
          tok_cmp    = gg_cmp;
          tok_usecmp = 1'b1;
        end
        4'd6: begin                       // Game Genie without compare
          tok_ok   = gg_rom;
          tok_addr = gg_addr;
          tok_val  = gg_val;
        end
        default: ;
      endcase
    end
  end

  wire room = (code_count < MAX_CODES[5:0]) && (cur_group < MAX_GROUPS[5:0]);

  // ------------------------------------------------------------ emit to CODES --
  // CODES latches on the rising edge of code[128], so present the payload for
  // one cycle before raising it. Bytes arrive far apart (APF sends roughly one
  // 32-bit word per 75 cycles of clk_74a), so this always completes in time.
  reg [1:0] emit;

  integer i;
  always @(posedge clk) begin
    if (reset) begin
      hist           <= 56'd0;
      pend_code      <= 1'b0;
      pend_desc      <= 1'b0;
      pend_enable    <= 1'b0;
      armed_code     <= 1'b0;
      armed_desc     <= 1'b0;
      armed_enable   <= 1'b0;
      last_group_ok  <= 1'b0;
      enable_mask    <= 32'd0;
      in_str         <= 1'b0;
      collecting     <= 1'b0;
      tok_len        <= 4'd0;
      tok_ovf        <= 1'b0;
      cur_group      <= 6'd0;
      group_has_code <= 1'b0;
      code_count     <= 6'd0;
      group_count    <= 6'd0;
      byte_count     <= 20'd0;
      code           <= 129'd0;
      emit           <= 2'd0;
      for (i = 0; i < 9; i = i + 1) nib[i] <= 4'd0;
    end else begin
      // emit sequencer runs independently of the byte stream
      case (emit)
        2'd1: begin code[128] <= 1'b1; emit <= 2'd0; end
        default: ;
      endcase

      if (wr) begin
        // Counts every byte the loader hands over, whether or not it parses.
        // Distinguishes "the file never arrived" from "it arrived but produced
        // no codes", which is otherwise guesswork on hardware.
        if (byte_count != {20{1'b1}}) byte_count <= byte_count + 20'd1;

        if (collecting) begin
          if (is_hex) begin
            if (tok_len == 4'd9) tok_ovf <= 1'b1;
            else begin
              nib[tok_len] <= nibble;
              tok_len      <= tok_len + 4'd1;
            end
          end else if (!is_dash) begin
            // delimiter: flush the token
            if (tok_ok && room) begin
              code       <= {1'b0, 20'd0, tok_bank_qual, tok_bank,
                             tok_poke, cur_group[4:0], tok_usecmp,
                             16'd0, tok_addr, 24'd0, tok_cmp, 24'd0, tok_val};
              emit           <= 2'd1;
              code_count     <= code_count + 6'd1;
              group_has_code <= 1'b1;
            end
            tok_len <= 4'd0;
            tok_ovf <= 1'b0;
            if (is_quote || is_nl) begin      // end of value, or unterminated
              collecting <= 1'b0;
              if (group_has_code || (tok_ok && room)) begin
                enable_mask[cur_group[4:0]] <= 1'b1;  // on unless _enable says otherwise
                last_group_ok <= 1'b1;
                cur_group     <= cur_group + 6'd1;
                group_count   <= group_count + 6'd1;
              end else begin
                last_group_ok <= 1'b0;
              end
              group_has_code <= 1'b0;
            end
          end
        end else if (in_str) begin
          if (is_quote) in_str <= 1'b0;
        end else if (armed_enable && is_alnum) begin
          // the value of a `cheatN_enable` key: the first word after it
          if (last_group_ok && (cur_group != 6'd0) && !says_on)
            enable_mask[cur_group[4:0] - 5'd1] <= 1'b0;
          armed_enable <= 1'b0;
          pend_code    <= 1'b0;
          pend_desc    <= 1'b0;
          pend_enable  <= 1'b0;
          hist         <= 56'd0;
        end else if (is_quote) begin
          armed_code   <= 1'b0;
          armed_desc   <= 1'b0;
          armed_enable <= 1'b0;
          pend_code    <= 1'b0;
          pend_desc    <= 1'b0;
          pend_enable  <= 1'b0;
          hist         <= 56'd0;
          if (armed_code) begin
            collecting     <= 1'b1;
            tok_len        <= 4'd0;
            tok_ovf        <= 1'b0;
            group_has_code <= 1'b0;
          end else begin
            in_str <= 1'b1;
          end
        end else begin
          hist <= {hist[47:0], ch};
          if ({hist[47:0], ch} == KEY_ENABLE) begin
            pend_enable  <= 1'b1;
            pend_code    <= 1'b0;
            pend_desc    <= 1'b0;
            armed_code   <= 1'b0;
            armed_desc   <= 1'b0;
            armed_enable <= 1'b0;
          end else if ({hist[31:0], ch} == KEY_CODE) begin
            pend_code    <= 1'b1;
            pend_desc    <= 1'b0;
            pend_enable  <= 1'b0;
            armed_code   <= 1'b0;
            armed_desc   <= 1'b0;
            armed_enable <= 1'b0;
          end else if ({hist[31:0], ch} == KEY_DESC) begin
            pend_desc    <= 1'b1;
            pend_code    <= 1'b0;
            pend_enable  <= 1'b0;
            armed_code   <= 1'b0;
            armed_desc   <= 1'b0;
            armed_enable <= 1'b0;
          end else if (ch == "=") begin
            // Only now is it a key. Whatever was pending becomes armed.
            armed_code   <= pend_code;
            armed_desc   <= pend_desc;
            armed_enable <= pend_enable;
            pend_code    <= 1'b0;
            pend_desc    <= 1'b0;
            pend_enable  <= 1'b0;
          end else if (!is_space) begin
            // Anything else between the keyword and '=' means it was not a key,
            // just those characters inside some longer word or a comment.
            pend_code    <= 1'b0;
            pend_desc    <= 1'b0;
            pend_enable  <= 1'b0;
          end
        end
      end
    end
  end

endmodule

`default_nettype wire
