// SPDX-License-Identifier: GPL-3.0-or-later
//
// DB15 SNAC reader for the MiSTer User I/O port.
//
// Protocol and bit order are those of the Antonio Villena DB15 splitter, as
// implemented by Aitor Pelaez (NeuroRulez) in joy_db15.v and shipped by the
// arcade cores that support the adapter. The adapter holds two DB15 (NeoGeo /
// CHAMMA) ports behind a parallel-in / serial-out shift register:
//
//   USER_OUT[0] -> JOY_LOAD   parallel load, active low, one JOY_CLK period
//   USER_OUT[1] -> JOY_CLK    ~190 kHz shift clock
//   USER_IN [5] <- JOY_DATA   serial data, active low at the pin
//
// Difference from the reference module, and the only one: the reference uses
// the divider bit itself as a clock (`assign JOY_CLK = JCLOCKS[7]` followed by
// `always @(posedge JOY_CLK)`). That is a ripple clock, and Quartus would carry
// it as a second, unconstrained clock domain -- which this project cannot
// afford, because SSV already closes timing with little margin and the .sdc
// would have to grow a domain that exists only to read a joystick. Here the
// same divider drives a clock ENABLE in clk_sys, so the sampling instants are
// identical (the enable fires on exactly the clk edge where the reference's
// JOY_CLK would rise) while the whole module stays in the one existing domain.
//
// joy_data is resynchronised into clk_sys before use: it arrives from an
// external pin with no relationship to clk_sys. Two flops cost 41 ns against a
// 2.6 us half period.
//
// Output bit order (active high), matching the reference:
//   11 Select, 10 Start, 9 F, 8 E, 7 D, 6 C, 5 B, 4 A, 3 Up, 2 Dn, 1 Lf, 0 Rt

`timescale 1ns/1ps

module ssv_joy_db15 #(
    // clk / 2^DIV_BITS is the JOY_CLK rate. The maintained MiSTer-DB9 fork
    // (sys/joydb15.v) divides a 48-50 MHz clock by 16 and states ~3 MHz is the
    // splitter's spec, so DIV_BITS = 4: 48.3185 / 16 = 3.020 MHz, one full
    // 26-slot poll every 8.6 us. An earlier draft here used /256 (94 kHz),
    // copied from the older Arcade-TNKIII module; that is 32x off spec.
    parameter int DIV_BITS = 4
) (
    input  logic clk,

    output logic joy_clk,     // -> USER_OUT[1]
    output logic joy_load,    // -> USER_OUT[0]
    input  logic joy_data,    // <- USER_IN[5]

    output logic [15:0] joystick1,
    output logic [15:0] joystick2
);

// ---------------------------------------------------------------------------
// Shift clock and its clock enable.
// ---------------------------------------------------------------------------
logic [DIV_BITS-1:0] div = '0;
always_ff @(posedge clk) div <= div + 1'b1;

assign joy_clk = div[DIV_BITS-1];

// One tick per JOY_CLK period, on the first clk where joy_clk is already high
// -- the same instant the fork's `joy_tick = (JCLOCKS[3:0] == 4'b1000)` fires,
// which samples JOY_DATA one clk (21 ns) after the JOY_CLK rise rather than on
// it. Against a 333 ns bit period that is free settling time.
wire joy_ce = (div == {1'b1, {(DIV_BITS-1){1'b0}}});

// ---------------------------------------------------------------------------
// Input synchroniser.
// ---------------------------------------------------------------------------
logic joy_data_meta = 1'b1;
logic joy_data_sync = 1'b1;
always_ff @(posedge clk) begin
    joy_data_meta <= joy_data;
    joy_data_sync <= joy_data_meta;
end

// ---------------------------------------------------------------------------
// 26-slot sequence. Slot 0 pulses LOAD low; slots 2..25 shift the 24 bits in.
//
// The reference splits this across two always blocks that race on joy_count
// (blocking assignment in one, read in the other). Synthesis resolves that as
// "both use the pre-increment value", so both are folded into this one block
// with non-blocking assignments -- same hardware, no race.
// ---------------------------------------------------------------------------
logic [4:0] joy_count = 5'd0;
logic [15:0] joy1 = 16'hFFFF;
logic [15:0] joy2 = 16'hFFFF;

initial joy_load = 1'b1;

always_ff @(posedge clk) if (joy_ce) begin
    joy_load  <= (joy_count != 5'd0);
    joy_count <= (joy_count == 5'd25) ? 5'd0 : joy_count + 1'd1;

    case (joy_count)
        5'd2  : joy1[7]  <= joy_data_sync;  // P1 D
        5'd3  : joy1[6]  <= joy_data_sync;  // P1 C
        5'd4  : joy1[5]  <= joy_data_sync;  // P1 B
        5'd5  : joy1[4]  <= joy_data_sync;  // P1 A
        5'd6  : joy1[0]  <= joy_data_sync;  // P1 Right
        5'd7  : joy1[1]  <= joy_data_sync;  // P1 Left
        5'd8  : joy1[2]  <= joy_data_sync;  // P1 Down
        5'd9  : joy1[3]  <= joy_data_sync;  // P1 Up
        5'd10 : joy2[0]  <= joy_data_sync;  // P2 Right
        5'd11 : joy2[1]  <= joy_data_sync;  // P2 Left
        5'd12 : joy2[2]  <= joy_data_sync;  // P2 Down
        5'd13 : joy2[3]  <= joy_data_sync;  // P2 Up
        5'd14 : joy1[9]  <= joy_data_sync;  // P1 F
        5'd15 : joy1[8]  <= joy_data_sync;  // P1 E
        5'd16 : joy1[11] <= joy_data_sync;  // P1 Select
        5'd17 : joy1[10] <= joy_data_sync;  // P1 Start
        5'd18 : joy2[9]  <= joy_data_sync;  // P2 F
        5'd19 : joy2[8]  <= joy_data_sync;  // P2 E
        5'd20 : joy2[11] <= joy_data_sync;  // P2 Select
        5'd21 : joy2[10] <= joy_data_sync;  // P2 Start
        5'd22 : joy2[7]  <= joy_data_sync;  // P2 D
        5'd23 : joy2[6]  <= joy_data_sync;  // P2 C
        5'd24 : joy2[5]  <= joy_data_sync;  // P2 B
        5'd25 : joy2[4]  <= joy_data_sync;  // P2 A
        default: ;
    endcase
end

assign joystick1 = ~joy1;
assign joystick2 = ~joy2;

endmodule
