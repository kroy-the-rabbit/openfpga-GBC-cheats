// SPDX-License-Identifier: GPL-3.0-or-later
// Behavioural stand-in for Altera's dcfifo, for Icarus only. Never synthesised.
//
// Models the parts data_loader depends on: 4-word depth, non-showahead reads,
// gray-coded pointers with a multi-stage synchroniser on the write pointer, and
// overflow_checking="OFF" (a write past full silently corrupts). The overflow
// warning is the point of this model: it is how the loader lost bytes before.

`default_nettype none

module dcfifo #(
    parameter lpm_width = 8,
    parameter lpm_numwords = 4,
    parameter lpm_widthu = 2,
    parameter lpm_showahead = "OFF",
    parameter lpm_type = "dcfifo",
    parameter overflow_checking = "OFF",
    parameter underflow_checking = "OFF",
    parameter use_eab = "OFF",
    parameter rdsync_delaypipe = 5,
    parameter wrsync_delaypipe = 5,
    parameter clocks_are_synchronized = "FALSE",
    parameter intended_device_family = "Cyclone V"
) (
    input  wire [lpm_width-1:0] data,
    input  wire                 rdclk,
    input  wire                 rdreq,
    input  wire                 wrclk,
    input  wire                 wrreq,
    output reg  [lpm_width-1:0] q,
    output wire                 rdempty
);

  localparam AW = lpm_widthu;

  reg [lpm_width-1:0] mem [0:lpm_numwords-1];
  reg [AW:0] wptr = 0;
  reg [AW:0] rptr = 0;

  integer overflows = 0;

  function [AW:0] bin2gray(input [AW:0] b);
    bin2gray = b ^ (b >> 1);
  endfunction

  function [AW:0] gray2bin(input [AW:0] g);
    integer k;
    begin
      gray2bin = g;
      for (k = 1; k <= AW; k = k + 1) gray2bin = gray2bin ^ (g >> k);
    end
  endfunction

  // write pointer crossing into the read domain
  reg [AW:0] wsync [0:15];
  integer s;
  initial for (s = 0; s < 16; s = s + 1) wsync[s] = 0;
  always @(posedge rdclk) begin
    wsync[0] <= bin2gray(wptr);
    for (s = 1; s < 16; s = s + 1) wsync[s] <= wsync[s-1];
  end

  wire [AW:0] wptr_rd = gray2bin(wsync[rdsync_delaypipe-1]);
  assign rdempty = (wptr_rd == rptr);

  wire full = ((wptr - rptr) == lpm_numwords[AW:0]);

  always @(posedge wrclk) begin
    if (wrreq) begin
      if (full) begin
        overflows <= overflows + 1;
        $display("DCFIFO OVERFLOW: write past full, byte lost");
      end
      mem[wptr[AW-1:0]] <= data;
      wptr <= wptr + 1'b1;
    end
  end

  always @(posedge rdclk) begin
    if (rdreq && !rdempty) begin
      q    <= mem[rptr[AW-1:0]];
      rptr <= rptr + 1'b1;
    end
  end

endmodule

`default_nettype wire
