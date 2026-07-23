// SPDX-License-Identifier: GPL-3.0-or-later
// Fixed Dyna Gear memory/ROM layout used by the initial SSV core.
`timescale 1ns/1ps

package ssv_pkg;

    localparam logic [24:0] SDR_MAINCPU_BASE = 25'h0000000;
    localparam logic [24:0] SDR_SPRITES_BASE = 25'h0100000;
    localparam logic [24:0] SDR_SAMPLES_BASE = 25'h0D00000;

    // CPU-writable regions that do not fit comfortably beside the original
    // board RAMs in Cyclone V block memory.
    localparam logic [24:0] SDR_XRAM_BASE     = 25'h1100000;
    localparam logic [24:0] SDR_DYNA_RAM_BASE = 25'h1120000;

    localparam logic [26:0] STREAM_MAINCPU   = 27'h0000000;
    localparam logic [26:0] STREAM_SPRITES   = 27'h0100000;
    localparam logic [26:0] STREAM_SAMPLES   = 27'h0D00000;
    localparam logic [26:0] STREAM_END       = 27'h1100000;

    localparam logic [8:0] SSV_HTOTAL  = 9'h1C6; // 454
    localparam logic [8:0] SSV_HBSTART = 9'h150; // 336
    localparam logic [8:0] SSV_VTOTAL  = 9'h106; // 262
    localparam logic [8:0] SSV_VBSTART = 9'h0F0; // 240

endpackage
