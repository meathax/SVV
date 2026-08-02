// SPDX-License-Identifier: GPL-3.0-or-later
//
// ssv_st010_prg_fetch against a behavioural p5 model.
//
// WHAT THIS IS FOR
//
// The uPD96050 core itself is covered by verif/upd96050/ (258 checks), and its
// ISA bench already re-runs with a stalled program fetch, so the request/valid
// PROTOCOL is tested. What was not tested is the arithmetic between an
// instruction address and three bytes of SDRAM:
//
//   * st010_prg_byte_addr(pc) = SDR_ST010_BASE + 4*pc, in a 64-bit port whose
//     address is in 8-byte units, so one line holds TWO instructions;
//   * the loader packs stream byte pairs LITTLE-endian, while MAME's dspprg is
//     a 32-bit BIG-endian region read as read_dword(pc) >> 8.
//
// Get either backwards and the DSP executes plausible garbage. So the SDRAM
// model here is filled through ssv_pkg::st010_stream_dest_cfg() -- the same function
// the loader calls -- and the expected instruction is rebuilt from the raw
// st010.bin bytes, not from anything the fetcher produces.
//
// REFUTATION CONDITION: any fetched instruction that differs from
// {rom[4pc], rom[4pc+1], rom[4pc+2]} fails the bench.

`timescale 1ns/1ps

module tb_ssv_st010_prg_fetch;

import ssv_pkg::*;

logic clk = 0;
always #5 clk = ~clk;

logic rst = 1;
logic enable = 1;

logic [13:0] prg_addr;
logic        prg_req;
wire  [23:0] prg_data;
wire         prg_valid;

wire        sdr_req;
wire [SDR_AW:3] sdr_addr;
logic [63:0] sdr_dout;
logic        sdr_ack;

ssv_st010_prg_fetch dut (
    .clk(clk), .rst(rst), .enable(enable),
    .prg_addr(prg_addr), .prg_req(prg_req),
    .prg_data(prg_data), .prg_valid(prg_valid),
    .sdr_req(sdr_req), .sdr_addr(sdr_addr),
    .sdr_dout(sdr_dout), .sdr_ack(sdr_ack)
);

// ---------------------------------------------------------------------------
// Synthetic st010.bin and the SDRAM image the loader would build from it.
// Only the program half matters here; 4096 instructions is plenty.
// ---------------------------------------------------------------------------
localparam int NINSN = 4096;
logic [7:0] rom [0:4*NINSN-1];

// Sparse 16-bit SDRAM store, addressed by WORD address exactly as the
// controller's ports are.
logic [15:0] mem16 [logic [SDR_AW:1]];

initial begin
    int i, k;
    logic [SDR_AW:0] dest;
    for (i = 0; i < 4*NINSN; i++)
        rom[i] = 8'((i * 7) + 3);
    // Byte pair k -> one 16-bit word, packed little-endian by the loader
    // (sdr_wr_din = {odd byte, even byte}), at the loader's own destination.
    for (k = 0; k < 2*NINSN; k++) begin
        dest = st010_stream_dest_cfg(
            cfg_dynagear(), STREAM_ST010 + 27'(2*k));
        mem16[dest[SDR_AW:1]] = {rom[2*k+1], rom[2*k]};
    end
end

// p5 model: 4-word burst, dout[15:0] is the word at the lowest address
// (sdram.sv deliver(), :628), ack high for exactly one clk.
function automatic logic [15:0] rd16(input logic [SDR_AW:1] wa);
    rd16 = mem16.exists(wa) ? mem16[wa] : 16'hxxxx;
endfunction

int lat = 0;
int bursts = 0;
logic req_d = 0;
always_ff @(posedge clk) begin
    logic [SDR_AW:1] base;
    sdr_ack <= 1'b0;
    if (rst) begin
        lat <= 0; req_d <= 1'b0;
    end
    else begin
        req_d <= sdr_req;
        if (sdr_req && !req_d) begin
            lat <= 4;                      // arbitration + ACT + CAS, in clk_sys
            bursts <= bursts + 1;
        end
        else if (lat > 1)
            lat <= lat - 1;
        else if (lat == 1) begin
            lat  <= 0;
            base = {sdr_addr, 2'b00};      // 8-byte unit -> word address
            sdr_dout <= {rd16(base + 3), rd16(base + 2),
                         rd16(base + 1), rd16(base + 0)};
            sdr_ack  <= 1'b1;
        end
    end
end

// ---------------------------------------------------------------------------
task automatic fetch(input int pc);
    logic [23:0] want;
    int guard;
    begin
        want = {rom[4*pc], rom[4*pc+1], rom[4*pc+2]};
        prg_addr = 14'(pc);
        prg_req  = 1'b1;
        // Let the combinational hit/mux settle before reading prg_valid or
        // prg_data. Without this the bench samples the PREVIOUS fetch's values
        // whenever the new address is already a line hit -- which is exactly
        // the case a 2-instruction line makes common, and it looked like an RTL
        // bug the first time this bench ran.
        #1;
        guard    = 0;
        while (!prg_valid) begin
            @(posedge clk); #1;
            guard++;
            if (guard > 200)
                $fatal(1, "pc %0d never returned prg_valid", pc);
        end
        if (prg_data !== want)
            $fatal(1, "pc %0d: got %06h want %06h", pc, prg_data, want);
        prg_req = 1'b0;
        @(posedge clk); #1;
    end
endtask

int checks = 0;
task automatic check(input int pc);
    begin fetch(pc); checks++; end
endtask

initial begin
    int i;
    prg_req = 0; prg_addr = 0; sdr_dout = 0; sdr_ack = 0;
    repeat (4) @(posedge clk);
    rst = 0;
    @(posedge clk); #1;

    // Instruction 0 and 1 share one line: the second must be a HIT, which is
    // the whole reason a 64-bit port was chosen. Asserted, not assumed.
    check(0);
    if (bursts != 1)
        $fatal(1, "instruction 0 took %0d bursts, expected 1", bursts);
    check(1);
    if (bursts != 1)
        $fatal(1, "instruction 1 was not a line hit (%0d bursts)", bursts);

    // Sequential run across many line boundaries: one burst per PAIR, which is
    // the 1.25e6 bursts/s the bandwidth argument in ssv_st010_prg_fetch.sv
    // rests on. 62 instructions (2..63) => 31 more bursts.
    for (i = 2; i < 64; i++) check(i);
    if (bursts != 32)
        $fatal(1, "sequential run took %0d bursts, expected 32", bursts);

    // Line-crossing and non-sequential targets, including both parities either
    // side of a line, which is where an off-by-one in pc[0] shows up.
    check(1000); check(1001); check(1002);
    check(1001); check(999);
    check(2047); check(2048);
    check(NINSN-1);
    check(0);

    // Disabled means silent: prg_valid must never assert and no burst issued.
    enable = 0;
    prg_addr = 14'd7; prg_req = 1'b1;
    repeat (40) begin
        @(posedge clk); #1;
        if (prg_valid) $fatal(1, "prg_valid asserted with enable = 0");
        if (sdr_req)   $fatal(1, "sdr_req asserted with enable = 0");
    end
    prg_req = 1'b0;
    enable = 1;
    @(posedge clk); #1;
    check(7);

    $display("PASS tb_ssv_st010_prg_fetch (%0d instruction fetches checked)",
             checks);
    $finish;
end

endmodule
