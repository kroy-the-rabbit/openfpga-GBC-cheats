// SPDX-License-Identifier: GPL-3.0-or-later
// End to end: APF bridge writes -> data_loader -> cheat_loader -> CODES.
//
// tb_cheat_loader proves the parser and tb_codes proves the code store, but
// neither covers the seam between them: the byte stream arriving through
// data_loader's dual clock FIFO at real APF rates. That seam is where the
// loader silently dropped bytes once already, so it gets its own test.
//
//   +f=<path>    the .cht file to send
//   +e=<path>    expected hits, one per line: "<addr> <val> <cmp> <usecmp>"
//
// Clocks are the real ones: 74.25 MHz on the bridge side, 33.554432 MHz core.

`timescale 1ns/1ps
`default_nettype none

module tb_e2e;

  reg clk_74a = 0;
  reg clk_sys = 0;
  always #6.7340  clk_74a = ~clk_74a;   // 74.25 MHz
  always #14.9012 clk_sys = ~clk_sys;   // 33.554432 MHz

  // ------------------------------------------------------------ APF bridge --
  reg        bridge_wr = 0;
  reg [31:0] bridge_addr = 0;
  reg [31:0] bridge_wr_data = 0;

  wire       cheat_wr;
  wire [7:0] cheat_dout;

  data_loader #(
      .ADDRESS_MASK_UPPER_4  (4'h5),
      .OUTPUT_WORD_SIZE      (1),
      .WRITE_MEM_CLOCK_DELAY (4)
  ) dl (
      .clk_74a              (clk_74a),
      .clk_memory           (clk_sys),
      .bridge_wr            (bridge_wr),
      .bridge_endian_little (1'b0),
      .bridge_addr          (bridge_addr),
      .bridge_wr_data       (bridge_wr_data),
      .write_en             (cheat_wr),
      .write_addr           (),
      .write_data           (cheat_dout)
  );

  // ------------------------------------------------------------- the core --
  reg reset = 1;

  wire [128:0] code;
  wire [31:0]  mask;
  wire [5:0]   ccount, gcount;
  wire [19:0]  bcount;

  cheat_loader #(.MAX_CODES(32), .MAX_GROUPS(32)) cl (
      .clk         (clk_sys),
      .reset       (reset),
      .wr          (cheat_wr),
      .data        (cheat_dout),
      .code        (code),
      .enable_mask (mask),
      .code_count  (ccount),
      .group_count (gcount),
      .byte_count  (bcount)
  );

  reg [15:0] addr_in = 0;
  reg [7:0]  data_in = 0;
  reg        cheats_on = 1;
  wire       ovr, avail;
  wire [7:0] odata;

  wire [4:0]  scan_index;
  wire [15:0] scan_addr;
  wire [7:0]  scan_data;
  wire        scan_poke;
  wire [3:0]  scan_bank;
  wire        scan_bank_qual;
  wire [5:0]  entry_count;

  CODES codes (
      .clk         (clk_sys),
      .reset       (reset),
      .enable      (cheats_on),
      .available   (avail),
      .addr_in     (addr_in),
      .data_in     (data_in),
      .code        (code),
      .enable_mask (mask),
      .genie_ovr   (ovr),
      .genie_data  (odata),
      .scan_index  (scan_index),
      .scan_addr   (scan_addr),
      .scan_data   (scan_data),
      .scan_poke      (scan_poke),
      .scan_bank      (scan_bank),
      .scan_bank_qual (scan_bank_qual),
      .entry_count    (entry_count)
  );

  // ---------------------------------------------------------- the poker --
  reg        vblank  = 0;
  reg        blocked = 0;
  reg [31:0] bank_arg;
  reg [2:0]  wram_bank = 3'd1;   // SVBK as the CPU has it, +bank=N overrides
  wire       poke_wr;
  wire [15:0] poke_addr;
  wire [7:0]  poke_data;

  cheat_poker #(.MAX_CODES(32), .INDEX_W(5)) poker (
      .clk        (clk_sys),
      .reset      (reset),
      .enable     (cheats_on),
      .vblank     (vblank),
      .blocked    (blocked),
      .scan_index (scan_index),
      .scan_addr  (scan_addr),
      .scan_data  (scan_data),
      .scan_poke      (scan_poke),
      .scan_bank      (scan_bank),
      .scan_bank_qual (scan_bank_qual),
      .wram_bank      (wram_bank),
      .poke_wr    (poke_wr),
      .poke_addr  (poke_addr),
      .poke_data  (poke_data)
  );

  // Stand-in for the WRAM and HRAM blocks: whatever the poker writes, we keep.
  reg [7:0] ram [0:65535];
  reg       written [0:65535];
  integer   pokes = 0;
  always @(posedge clk_sys) begin
    if (poke_wr) begin
      ram[poke_addr]     <= poke_data;
      written[poke_addr] <= 1'b1;
      pokes              <= pokes + 1;
    end
  end

  task frame;
    begin
      vblank = 1'b1;
      repeat (4) @(posedge clk_sys);
      vblank = 1'b0;
      repeat (300) @(posedge clk_sys);   // a walk is ~130 cycles
    end
  endtask

  // ------------------------------------------------------------- stimulus --
  reg [7:0] fbuf [0:1048575];
  integer   flen;
  integer   fails = 0;

  // 128 bytes was not enough: a plusarg string longer than the vector is kept
  // from the right, so a long absolute path silently lost its leading
  // directories and the open failed with a truncated name. CI paths are longer
  // than a checkout in $HOME, which is where this first showed up.
  reg [8*1024-1:0] fname, ename;
  integer fd, i, n;
  reg [31:0] w;

  // One APF word. APF delivers roughly one every 75 clk_74a cycles; anything
  // faster than that is not a case the hardware can produce.
  task send_word(input [31:0] a, input [31:0] d);
    begin
      @(posedge clk_74a);
      bridge_addr    <= a;
      bridge_wr_data <= d;
      bridge_wr      <= 1'b1;
      @(posedge clk_74a);
      bridge_wr      <= 1'b0;
      repeat (73) @(posedge clk_74a);
    end
  endtask

  integer ea, ev, ec, eu, ep, got;
  reg [31:0] want_entries;

  initial begin
    for (i = 0; i < 65536; i = i + 1) begin
      ram[i]     = 8'h00;
      written[i] = 1'b0;
    end

    if (!$value$plusargs("f=%s", fname)) begin
      $display("FAIL: no +f=<cht file>");
      $finish;
    end

    fd = $fopen(fname, "rb");
    if (fd == 0) begin
      $display("FAIL: cannot open %0s", fname);
      $finish;
    end
    flen = $fread(fbuf, fd);
    $fclose(fd);

    if ($value$plusargs("bank=%d", bank_arg)) wram_bank = bank_arg[2:0];

    repeat (8) @(posedge clk_sys);
    reset <= 1'b0;
    repeat (4) @(posedge clk_sys);

    // Pad to a whole number of 32-bit words, as APF does.
    for (i = 0; i < flen; i = i + 4) begin
      w = { fbuf[i],
            (i+1 < flen) ? fbuf[i+1] : 8'h00,
            (i+2 < flen) ? fbuf[i+2] : 8'h00,
            (i+3 < flen) ? fbuf[i+3] : 8'h00 };
      send_word(32'h5000_0000 + i, w);
    end

    // let the FIFO drain and entry_ena settle
    repeat (200) @(posedge clk_sys);

    // two frames: the poker must be idempotent, not one-shot
    frame();
    frame();

    $display("BANK %0d", wram_bank);
    $display("RESULT bytes=%0d codes=%0d groups=%0d mask=%08x available=%0d entries=%0d",
             bcount, ccount, gcount, mask, avail, entry_count);

    // APF always sends whole 32-bit words, so a file that is not a multiple
    // of four arrives rounded up with zero padding. The parser ignores it.
    if (bcount != ((flen + 3) / 4) * 4)
      $display("FAIL: loader received %0d bytes, expected %0d",
               bcount, ((flen + 3) / 4) * 4);

    // ------------------------------------------------------- expected hits --
    if ($value$plusargs("e=%s", ename)) begin
      fd = $fopen(ename, "r");
      if (fd == 0) begin
        $display("FAIL: cannot open %0s", ename);
        $finish;
      end
      n = 0;
      while ($fscanf(fd, "%d %d %d %d %d\n", ea, ev, ec, eu, ep) == 5) begin
        n = n + 1;
        addr_in = ea[15:0];
        data_in = eu ? ec[7:0] : 8'h00;
        #1;
        if (ep) begin
          // A GameShark code the poker owns: it must be written into RAM, and
          // it must NOT also fake the CPU's read. Overriding the read is what
          // stops the game clamping the value to its own maximum.
          if (!written[ea[15:0]] || ram[ea[15:0]] !== ev[7:0]) begin
            fails = fails + 1;
            $display("FAIL: addr %04x expected poke %02x, RAM holds %02x (written=%0d)",
                     ea, ev, ram[ea[15:0]], written[ea[15:0]]);
          end
          if (ovr) begin
            fails = fails + 1;
            $display("FAIL: addr %04x is poked but still overrides the read", ea);
          end
        end else begin
          if (!ovr || odata !== ev[7:0]) begin
            fails = fails + 1;
            $display("FAIL: addr %04x expected val %02x, got ovr=%0d data=%02x",
                     ea, ev, ovr, odata);
          end
          // a code with a compare byte must not fire on a different byte
          if (eu) begin
            data_in = ~ec[7:0];
            #1;
            if (ovr) begin
              fails = fails + 1;
              $display("FAIL: addr %04x fired with the wrong compare byte", ea);
            end
          end
        end
      end
      $fclose(fd);
      // Entries are per (address, cheat), so this is not the number of checks:
      // several cheats may aim at one address, and disabled ones are stored too.
      if ($value$plusargs("entries=%d", want_entries)
          && entry_count != want_entries[5:0]) begin
        fails = fails + 1;
        $display("FAIL: CODES holds %0d entries, expected %0d",
                 entry_count, want_entries);
      end
      $display("CHECKED %0d expected hits, %0d pokes issued", n, pokes);
    end

    // ------------------------------------- savestate keeps the RAM port --
    pokes   = 0;
    blocked = 1;
    frame();
    if (pokes != 0) begin
      fails = fails + 1;
      $display("FAIL: %0d pokes issued while the savestate engine held the port",
               pokes);
    end
    blocked = 0;

    // and with cheats off, nothing is written either
    cheats_on = 0;
    pokes     = 0;
    frame();
    if (pokes != 0) begin
      fails = fails + 1;
      $display("FAIL: %0d pokes issued with cheats switched off", pokes);
    end

    // ------------------------------------------------- the master switch --
    #1;
    got = 0;
    for (i = 0; i < 65536; i = i + 1) begin
      addr_in = i[15:0];
      data_in = 8'h00;
      #1;
      if (ovr) got = got + 1;
    end
    if (got != 0) begin
      fails = fails + 1;
      $display("FAIL: %0d addresses still override with cheats off", got);
    end
    cheats_on = 1;

    for (i = 0; i < 65536; i = i + 1)
      if (written[i]) $display("WROTE %04x=%02x", i[15:0], ram[i]);

    if (fails == 0) $display("PASS");
    else            $display("FAILURES %0d", fails);
    $finish;
  end

endmodule

`default_nettype wire
