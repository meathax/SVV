// SPDX-License-Identifier: GPL-3.0-or-later
// MiSTer top-level for the Sammy/Seta/Visco SSV core (Dyna Gear target).

`timescale 1ns/1ps

module emu (
    input         CLK_50M,
    input         RESET,
    inout  [45:0] HPS_BUS,

    output        CLK_VIDEO,
    output        CE_PIXEL,
    output [12:0] VIDEO_ARX,
    output [12:0] VIDEO_ARY,
    output  [7:0] VGA_R,
    output  [7:0] VGA_G,
    output  [7:0] VGA_B,
    output        VGA_HS,
    output        VGA_VS,
    output        VGA_DE,
    output        VGA_F1,
    output  [1:0] VGA_SL,
    output        VGA_SCALER,
    output        VGA_DISABLE,

    input  [11:0] HDMI_WIDTH,
    input  [11:0] HDMI_HEIGHT,
    output        HDMI_FREEZE,
    output        HDMI_BLACKOUT,
    output        HDMI_BOB_DEINT,

    output        LED_USER,
    output  [1:0] LED_POWER,
    output  [1:0] LED_DISK,
    output  [1:0] BUTTONS,
    output [15:0] AUDIO_L,
    output [15:0] AUDIO_R,
    output        AUDIO_S,
    output  [1:0] AUDIO_MIX,

    output        DDRAM_CLK,
    input         DDRAM_BUSY,
    output  [7:0] DDRAM_BURSTCNT,
    output [28:0] DDRAM_ADDR,
    input  [63:0] DDRAM_DOUT,
    input         DDRAM_DOUT_READY,
    output        DDRAM_RD,
    output [63:0] DDRAM_DIN,
    output  [7:0] DDRAM_BE,
    output        DDRAM_WE,

    output        SDRAM_CLK,
    output        SDRAM_CKE,
    output [12:0] SDRAM_A,
    output  [1:0] SDRAM_BA,
    inout  [15:0] SDRAM_DQ,
    output        SDRAM_DQML,
    output        SDRAM_DQMH,
    output        SDRAM_nCS,
    output        SDRAM_nCAS,
    output        SDRAM_nRAS,
    output        SDRAM_nWE,

    input         CLK_AUDIO,
    inout   [3:0] ADC_BUS,
    output        SD_SCK,
    output        SD_MOSI,
    input         SD_MISO,
    output        SD_CS,
    input         SD_CD,
    input         UART_CTS,
    output        UART_RTS,
    input         UART_RXD,
    output        UART_TXD,
    output        UART_DTR,
    input         UART_DSR,
    input   [6:0] USER_IN,
    output  [6:0] USER_OUT,
    input         OSD_STATUS
);

`ifndef BUILD_DATE
`define BUILD_DATE "SSV"
`endif

localparam CONF_STR = {
    "SSV;;",
    "-;",
    "O[2:1],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
    "O[45:43],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer,HV-Integer;",
    // Was labelled "Scandoubler Fx" while no scandoubler existed. HQ2x is
    // offered because arcade_video builds its filter either way -- the line
    // stores it needs are the scandoubler's, so refusing the option would save
    // nothing.
    "O[5:3],Video Fx,None,HQ2x,Scanlines 25%,Scanlines 50%,Scanlines 75%;",
    "O[47:46],Stereo Mix,None,25%,50%,100%;",
    "O[6],Service Mode,Off,On;",
    "O[7],Pause,Off,On;",
    "H2O[48],Autosave Hiscores,Off,On;",
    // Flip Screen, Demo Sounds, Difficulty, Lives, Free Play, Health and both
    // coinage nibbles are DIP switches and now live in the MRA's <switches>
    // block, which the framework renders as its own OSD page. status bits
    // 8..23 are free as a result.
    "-;",
    // CRT Adjust (rtl/crt_adjust.sv). Off is a pure passthrough; the three
    // amounts are hidden until it is On (status_menumask bit 1 below).
    "P1,CRT Adjust;",
    "P1-;",
    "P1O[24],CRT Adjust,Off,On;",
    "H1P1O[29:25],H-Size,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
    "H1P1O[35:30],H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
    "H1P1O[40:36],V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
    "-;",
    // Direct arcade controls through the User I/O port (Antonio Villena DB15
    // SNAC splitter). Off leaves both players on the HPS/USB joysticks.
    "O[42:41],DB15 Devices,Off,P1 only,P2 only,P1 & P2;",
    "-;",
    "R[0],Reset;",
    "J1,Fire,Jump,Test,Service,Start,Coin;",
    "V,v",`BUILD_DATE
};

assign ADC_BUS = 'Z;
assign {UART_RTS, UART_TXD, UART_DTR} = 3'b000;
assign {SD_SCK, SD_MOSI, SD_CS} = 3'bZZZ;
assign VGA_F1 = 1'b0;
assign VGA_SCALER = 1'b0;
assign VGA_DISABLE = 1'b0;
assign HDMI_FREEZE = 1'b0;
assign HDMI_BLACKOUT = 1'b0;
assign HDMI_BOB_DEINT = 1'b0;
assign AUDIO_S = 1'b1;
// AUDIO_MIX is driven from the OSD at the bottom of this file.
assign LED_POWER = 2'b00;
// LED_DISK is driven below from the renderer overrun status.
assign BUTTONS = 2'b00;

assign DDRAM_BURSTCNT = 8'd0;
assign DDRAM_ADDR = 29'd0;
assign DDRAM_RD = 1'b0;
assign DDRAM_DIN = 64'd0;
assign DDRAM_BE = 8'd0;
assign DDRAM_WE = 1'b0;

wire clk_sys, clk_ram, clk_aux, pll_locked;
pll pll (
    .refclk_clk(CLK_50M), .reset_reset(1'b0),
    .outclk0_clk(clk_ram), .outclk1_clk(clk_sys),
    .outclk2_clk(SDRAM_CLK), .outclk3_clk(clk_aux),
    .locked_export(pll_locked)
);
assign CLK_VIDEO = clk_sys;
assign DDRAM_CLK = clk_ram;

wire [1:0] buttons;
wire [63:0] status;
wire ioctl_download, ioctl_wr, ioctl_wait;
wire [15:0] ioctl_index;
wire [26:0] ioctl_addr;
wire [7:0] ioctl_dout;
wire [31:0] joystick_0, joystick_1;
// Driven by hps_io, consumed by the video chain at the bottom of this file.
wire [21:0] gamma_bus;
wire        forced_scandoubler;

// High score save/load nets. The module itself is instantiated further down,
// next to ssv_core; these are declared here because hps_io and ssv_core both
// sit above it and both connect to them. See that instance for the mapping.
wire [15:0] hs_addr;
wire  [7:0] hs_data_to_ram, hs_data_from_ram;
wire        hs_ram_write, hs_configured;
wire  [7:0] hs_data_to_hps;
wire        hs_upload, hs_upload_req;

// SSV main RAM is 16-bit and the hiscore module speaks bytes. The board is
// little-endian (the loader packs LE and the golden CRC depends on it), so
// byte address N is the low half of word N>>1 when N is even.
wire [14:0] hs_word_addr = hs_addr[15:1];
wire [15:0] hs_word_din  = {hs_data_to_ram, hs_data_to_ram};
wire  [1:0] hs_word_be   = hs_addr[0] ? 2'b10 : 2'b01;
wire        hs_ram_we    = hs_ram_write;
wire [15:0] hs_word_dout;
// The read side is registered inside the RAM, so the byte lane has to be
// selected with the address that produced the data, not the current one.
reg  hs_addr0_q;
always_ff @(posedge clk_sys) hs_addr0_q <= hs_addr[0];
assign hs_data_from_ram = hs_addr0_q ? hs_word_dout[15:8] : hs_word_dout[7:0];

hps_io #(.CONF_STR(CONF_STR)) hps_io (
    .clk_sys(clk_sys), .HPS_BUS(HPS_BUS),
    .buttons(buttons), .status(status),
    .ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr),
    .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
    .ioctl_index(ioctl_index), .ioctl_wait(ioctl_wait),
    // Hiscore save path: index 4 is <MRA name>.nvm.
    .ioctl_upload(hs_upload), .ioctl_upload_req(hs_upload_req),
    .ioctl_upload_index(8'd4), .ioctl_din(hs_data_to_hps),
    // H1 hides the three CRT Adjust amounts while CRT Adjust is Off.
    // H2 hides Autosave on an MRA that carries no hiscore.dat entry.
    .status_menumask({13'd0, ~hs_configured, ~status[24], 1'b0}),
    .forced_scandoubler(forced_scandoubler),
    .gamma_bus(gamma_bus),
    .joystick_0(joystick_0), .joystick_1(joystick_1)
);

// ---------------------------------------------------------------------------
// DB15 SNAC controls on the User I/O port.
//
// USER_OUT[0] = LOAD, USER_OUT[1] = CLK, USER_IN[5] = DATA. sys_top drives the
// USER_IO pins open-drain (`!user_out[n] ? 1'b0 : 1'bZ`), so the unused lines
// must stay high or they pull the adapter's pins down.
// ---------------------------------------------------------------------------
wire db15_clk, db15_load;
wire [15:0] db15_p1_raw, db15_p2_raw;

ssv_joy_db15 joy_db15 (
    .clk(clk_sys),
    .joy_clk(db15_clk), .joy_load(db15_load), .joy_data(USER_IN[5]),
    .joystick1(db15_p1_raw), .joystick2(db15_p2_raw)
);

// Only drive the adapter while DB15 is actually selected. sys_top's open-drain
// wrapper turns a 1 into high-Z, so with the option Off the port is released
// entirely and whatever else the user has on User I/O is left alone.
assign USER_OUT = (|status[42:41]) ? {5'b11111, db15_clk, db15_load}
                                   : 7'b1111111;

// V60 clock enable.
//
// CONFIRMED from a real STA-0001B photograph: the board's second crystal is
// **48.000 MHz**, and 48.000 / 3 = 16.000 MHz is the V60 clock. The accumulator
// below targets that from clk_sys.
//
// Accuracy note, deliberately NOT changed: at clk_sys = 48.3185 MHz the
// constant 21702 yields 15.99887 MHz, i.e. 71 ppm slow. 21704 would give
// 16.00035 MHz (22 ppm). The improvement is real but ~0.007%, and changing the
// CPU-to-raster phase would invalidate the 950-frame golden CRC that was just
// re-baselined against MAME. Not worth trading a verified reference for 49 ppm.
// Revisit only if the golden is being re-cut for another reason.
//
// Pause also stops the CPU while the OSD is open, which is what a player
// expects from opening a menu mid-game and costs one gate. status[7] remains
// the explicit manual pause; the renderer keeps running either way, so the
// last frame stays on screen.
//
// hs_pause is the hiscore module asking for the CPU to be still while it
// reads or writes the score table. It is a registered output over there, so
// feeding game_pause straight back into its `paused` input is a handshake and
// not a combinational loop.
wire hs_pause;
wire game_pause = status[7] | OSD_STATUS | hs_pause;

logic ce_cpu;
logic [15:0] cpu_acc;
always_ff @(posedge clk_sys) begin
    logic [16:0] sum;
    if (!pll_locked || game_pause) begin
        ce_cpu <= 1'b0;
        if (!pll_locked) cpu_acc <= 16'd0;
    end
    else begin
        sum = {1'b0, cpu_acc} + 17'd21702;
        ce_cpu <= sum[16];
        cpu_acc <= sum[15:0];
    end
end

wire sdram_ready;
logic sdram_ready_meta, sdram_ready_sys;
always_ff @(posedge clk_sys) begin
    if (!pll_locked) begin
        sdram_ready_meta <= 1'b0;
        sdram_ready_sys <= 1'b0;
    end
    else begin
        sdram_ready_meta <= sdram_ready;
        sdram_ready_sys <= sdram_ready_meta;
    end
end

wire rom_loaded;
wire [26:0] download_max_addr;
wire loader_reset = ~pll_locked;
wire video_reset = RESET | status[0] | buttons[1] | ~pll_locked;

// After ROM download, read two known program words from SDRAM before the
// CPU is released. Expected LE packing matches the loader/sim model:
//   addr 0x000000 -> 0x207a (reset stub BR)
//   addr 0x01f3d0 -> 0x0c7a (BR16 over "12345678")
logic        probe_done, probe_req, probe_seen;
logic  [1:0] probe_step;
logic [15:0] probe_sig0, probe_sig1;
logic        rom_sig_ok;
wire         probe_active = rom_loaded && sdram_ready_sys &&
                            !ioctl_download && !probe_done;

wire wdog_rst;
wire core_reset = video_reset | ioctl_download | ~rom_loaded |
                  ~sdram_ready_sys | ~probe_done | wdog_rst;
assign LED_USER = ~rom_loaded;

wire ld_wr_req, ld_wr_ack;
wire [24:1] ld_wr_addr;
wire [15:0] ld_wr_din;
wire [1:0] ld_wr_be;

ssv_rom_loader loader (
    .clk(clk_sys), .rst(loader_reset), .mem_ready(sdram_ready_sys),
    .ioctl_download(ioctl_download), .ioctl_index(ioctl_index[7:0]),
    .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr),
    .ioctl_dout(ioctl_dout), .ioctl_wait(ioctl_wait),
    .sdr_wr_req(ld_wr_req), .sdr_wr_addr(ld_wr_addr),
    .sdr_wr_din(ld_wr_din), .sdr_wr_be(ld_wr_be),
    .sdr_wr_ack(ld_wr_ack), .rom_loaded(rom_loaded),
    .download_max_addr(download_max_addr)
);

wire core_p0_req;
wire [24:1] core_p0_addr;
wire p0_ack;
wire [15:0] p0_dout;
wire p0_req  = probe_active ? probe_req  : core_p0_req;
wire [24:1] p0_addr = probe_active ?
    (probe_step[0] ? 24'(25'h1F3D0 >> 1) : 24'(25'h0 >> 1)) :
    core_p0_addr;

always_ff @(posedge clk_sys) begin
    if (loader_reset || ioctl_download || !rom_loaded) begin
        probe_done <= 1'b0;
        probe_req  <= 1'b0;
        probe_seen <= 1'b0;
        probe_step <= 2'd0;
        probe_sig0 <= 16'hffff;
        probe_sig1 <= 16'hffff;
        rom_sig_ok <= 1'b0;
    end
    else if (!probe_done && sdram_ready_sys) begin
        if (p0_ack && probe_seen) begin
            probe_req  <= 1'b0;
            probe_seen <= 1'b0;
            if (probe_step == 2'd0) begin
                probe_sig0 <= p0_dout;
                probe_step <= 2'd1;
            end
            else begin
                probe_sig1 <= p0_dout;
                rom_sig_ok <= (probe_sig0 == 16'h207a) && (p0_dout == 16'h0c7a);
                probe_done <= 1'b1;
            end
        end
        else if (!probe_req) begin
            probe_req  <= 1'b1;
            probe_seen <= 1'b0;
        end
        else if (probe_req && !probe_seen)
            probe_seen <= 1'b1;
    end
end

// Graphics row fetch: one 128-bit p2 burst per 16-pixel tile row. p1 (64-bit,
// 4-word burst) is now unused by this core and is left tied off below -- it is
// the natural home for a future ES5506 sample line cache, whose worst-case
// latency is better served by a 13-cycle transaction than p2's 17.
wire p2_req, p2_ack;
wire [24:4] p2_addr;
wire [127:0] p2_dout;
wire p4_req, p4_ack;
wire [24:1] p4_addr;
wire [15:0] p4_dout;

wire core_wr_req, core_wr_ack;
wire [24:1] core_wr_addr;
wire [15:0] core_wr_din;
wire [1:0] core_wr_be;
wire sw_req, sw_ack;
wire [24:1] sw_addr;
wire [15:0] sw_din;
wire [1:0] sw_be;
wire loader_owns_write = ld_wr_req;

assign sw_req  = loader_owns_write ? ld_wr_req  : core_wr_req;
assign sw_addr = loader_owns_write ? ld_wr_addr : core_wr_addr;
assign sw_din  = loader_owns_write ? ld_wr_din  : core_wr_din;
assign sw_be   = loader_owns_write ? ld_wr_be   : core_wr_be;
assign ld_wr_ack   = loader_owns_write ? sw_ack : 1'b0;
assign core_wr_ack = loader_owns_write ? 1'b0 : sw_ack;

sdram sdram (
    .clk(clk_ram), .init(~pll_locked), .ready(sdram_ready),
    .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
    .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
    .SDRAM_nCS(SDRAM_nCS), .SDRAM_nCAS(SDRAM_nCAS),
    .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_CKE(SDRAM_CKE),
    .wr_req(sw_req), .wr_addr(sw_addr), .wr_din(sw_din),
    .wr_be(sw_be), .wr_ack(sw_ack),
    .p0_req(p0_req), .p0_addr(p0_addr), .p0_dout(p0_dout), .p0_ack(p0_ack),
    .p1_req(1'b0), .p1_addr('0), .p1_dout(), .p1_ack(),
    .p2_req(p2_req), .p2_addr(p2_addr), .p2_dout(p2_dout), .p2_ack(p2_ack),
    .p3_req(1'b0), .p3_addr('0), .p3_dout(), .p3_ack(),
    .p4_req(p4_req), .p4_addr(p4_addr), .p4_dout(p4_dout), .p4_ack(p4_ack),
    .p5_req(1'b0), .p5_addr('0), .p5_dout(), .p5_ack()
);

// MiSTer J1 order: Fire,Jump,Test,Service,Start,Coin → joy[4]..joy[9]
// (the MRA's <buttons names=...> list must stay in this same order).
//
// Map a DB15 pad onto that same numbering so everything downstream is written
// once. DB15 bit order is 11 Select, 10 Start, 9 F, 8 E, 7 D, 6 C, 5 B, 4 A,
// 3 Up, 2 Down, 1 Left, 0 Right.
//
//   A = Fire, B = Jump, Start = Start, Select = Coin
//   Select+A = Test, Select+B = Service
//
// Test and Service are chords, not buttons of their own, because a CHAMMA
// cabinet harness carries six buttons per player: putting Service on a plain
// button means a stray press during play drops the board into the service
// menu. The chord convention is the one Arcade-TNKIII uses. Coin is suppressed
// while a chord is held so entering test mode does not also insert a credit.
function automatic [31:0] db15_to_joy(input [15:0] db);
    logic sel, chord;
    begin
        sel   = db[11];
        chord = sel & (db[4] | db[5]);
        db15_to_joy = {22'd0,
                       sel & ~chord,  // joy[9]  Coin    <- Select alone
                       db[10],        // joy[8]  Start   <- Start
                       sel & db[5],   // joy[7]  Service <- Select+B
                       sel & db[4],   // joy[6]  Test    <- Select+A
                       db[5] & ~sel,  // joy[5]  Jump    <- B
                       db[4] & ~sel,  // joy[4]  Fire    <- A
                       db[3], db[2], db[1], db[0]};  // Up, Down, Left, Right
    end
endfunction

// status[42:41]: 0 = Off, 1 = P1 only, 2 = P2 only, 3 = both.
wire [1:0] db15_sel = status[42:41];
wire [31:0] joy_p1 = db15_sel[0] ? db15_to_joy(db15_p1_raw) : joystick_0;
wire [31:0] joy_p2 = db15_sel[1] ? db15_to_joy(db15_p2_raw) : joystick_1;

// MAME P1 ($210008) bits 7:0: UP, DOWN, LEFT, RIGHT, B1, B2, B3, START.
// Dyna Gear has no third button, so B3 is tied released and no input can
// reach it.
function automatic [15:0] player_port(input [31:0] joy);
    player_port = {8'hff, ~{joy[3], joy[2], joy[1], joy[0],
                              joy[4], joy[5], 1'b0, joy[8]}};
endfunction

wire test_button = status[6] | joy_p1[6] | joy_p2[6];
wire service_button = joy_p1[7] | joy_p2[7];
wire coin1_button = joy_p1[9];
wire coin2_button = joy_p2[9];
// MAME SYSTEM ($21000c): COIN1, COIN2, SERVICE1, TILT, TEST
wire [15:0] system_port = {8'hff,
    ~{3'b000, test_button, 1'b0, service_button,
      coin2_button, coin1_button}};

// ---------------------------------------------------------------------------
// DIP switches, from the MRA.
//
// These used to be OSD options, each one hand-mapped to a DIP bit pattern --
// coinage in particular needed a 16-entry lookup, because the OSD list order
// and the board's nibble values have nothing to do with each other. The MRA
// expresses that directly (<dip ... ids=... values=...>) and the HPS sends the
// assembled bytes on ioctl index 254, so the core can take them verbatim.
//
// That removes the translation layer and, with it, the class of bug where the
// OSD says one thing and the board is told another. It also means a second SSV
// title only needs its own MRA, not RTL changes -- these bytes ARE what the
// game reads at $210002 and $210004.
//
// The reset default matches MAME's dynagear (FF / FD) so the core still comes
// up sanely if an MRA carries no <switches> block at all.
// ---------------------------------------------------------------------------
logic [7:0] sw [0:1];
initial begin
    sw[0] = 8'hff;  // DSW1: Coin A and Coin B both 1C/1C
    sw[1] = 8'hfd;  // DSW2: Flip Off, Demo On, Normal, 2 lives, Free Play Off,
                    //       4 Hearts
end
always_ff @(posedge clk_sys) begin
    if (ioctl_wr && (ioctl_index[7:0] == 8'd254) && !ioctl_addr[24:1])
        sw[ioctl_addr[0]] <= ioctl_dout;
end

wire [15:0] dsw1_port = {8'hff, sw[0]};
wire [15:0] dsw2_port = {8'hff, sw[1]};

wire [23:0] core_rgb;
wire core_ce, core_hs, core_vs, core_hb, core_vb;
wire signed [15:0] core_audio_l, core_audio_r;
wire [31:0] debug_pc;
wire [23:0] debug_status;

ssv_core core (
    .clk_sys(clk_sys), .rst(core_reset), .ce_cpu(ce_cpu),
    .sdr_p0_req(core_p0_req), .sdr_p0_addr(core_p0_addr),
    .sdr_p0_dout(p0_dout), .sdr_p0_ack(p0_ack && !probe_active),
    .sdr_p2_req(p2_req), .sdr_p2_addr(p2_addr),
    .sdr_p2_dout(p2_dout), .sdr_p2_ack(p2_ack),
    .sdr_wr_req(core_wr_req), .sdr_wr_addr(core_wr_addr),
    .sdr_wr_din(core_wr_din), .sdr_wr_be(core_wr_be),
    .sdr_wr_ack(core_wr_ack),
    .sdr_p4_req(p4_req), .sdr_p4_addr(p4_addr),
    .sdr_p4_dout(p4_dout), .sdr_p4_ack(p4_ack),
    .in_dsw1(dsw1_port), .in_dsw2(dsw2_port),
    .in_p1(player_port(joy_p1)), .in_p2(player_port(joy_p2)),
    .in_system(system_port), .in_extra(16'hffff),
    .hs_addr(hs_word_addr), .hs_din(hs_word_din), .hs_be(hs_word_be),
    .hs_we(hs_ram_we), .hs_dout(hs_word_dout),
    .rgb(core_rgb), .ce_pixel(core_ce),
    .hs(core_hs), .vs(core_vs), .hb(core_hb), .vb(core_vb),
    .audio_l(core_audio_l), .audio_r(core_audio_r),
    .wdog_rst(wdog_rst),
    .debug_pc(debug_pc), .debug_status(debug_status)
);

// ---------------------------------------------------------------------------
// High score save/load (rtl/hiscore.v, alanswx / JimmyStones).
//
// The MRA carries the game's hiscore.dat entry on ioctl index 3; the saved
// dump is <MRA name>.nvm on index 4. The module walks the entry list, waits
// for the game to have initialised its table, then restores it -- and on OSD
// open it reads the table back and requests a save if anything changed.
//
// SSV main RAM is 16-bit and the module speaks bytes, so this converts. The
// board is little-endian (the loader packs LE and the golden CRC depends on
// it), so byte address N is the low half of word N>>1 when N is even.
// ---------------------------------------------------------------------------
hiscore #(
    // 16 bits covers the whole of SSV main RAM ($0000-$ffff).
    .HS_ADDRESSWIDTH(16),
    // 128 bytes of dump. Dyna Gear's table is 36 (a 4-byte high score plus
    // four 8-byte entries), so this is generous, and halving it from the
    // default keeps the two score buffers to one M10K each.
    .HS_SCOREWIDTH(7),
    .CFG_ADDRESSWIDTH(4)
) u_hiscore (
    .clk(clk_sys),
    .reset(core_reset),
    .paused(game_pause),
    .autosave(status[48]),
    .OSD_STATUS(OSD_STATUS),

    .ioctl_upload(hs_upload),
    .ioctl_upload_req(hs_upload_req),
    .ioctl_download(ioctl_download),
    .ioctl_wr(ioctl_wr),
    .ioctl_addr(ioctl_addr[24:0]),
    .ioctl_index(ioctl_index[7:0]),

    .data_from_hps(ioctl_dout),
    .data_to_hps(hs_data_to_hps),
    .data_from_ram(hs_data_from_ram),
    .data_to_ram(hs_data_to_ram),
    .ram_address(hs_addr),
    .ram_write(hs_ram_write),
    .ram_intent_read(),
    .ram_intent_write(),
    .pause_cpu(hs_pause),
    .configured(hs_configured)
);

// The core's own raster is the only video source. The independent bring-up
// raster (ssv_diag_video) that used to sit alongside it has been removed: it
// was permanently disabled by a hardcoded localparam, so the mux below always
// selected the core and the second timing path was dead weight in every build.
wire [7:0] av_r = core_rgb[23:16];
wire [7:0] av_g = core_rgb[15:8];
wire [7:0] av_b = core_rgb[7:0];
wire av_hs = core_hs;
wire av_vs = core_vs;
wire av_hb = core_hb;
wire av_vb = core_vb;
wire av_ce = core_ce;

// ---------------------------------------------------------------------------
// CRT Adjust (rtl/crt_adjust.sv, rmonic79) -- core-side integration.
//
// Everything the picture is resized and repositioned by happens inside a line
// buffer whose engine restarts on the module's own line reference, so the sync
// never moves out of phase with the content and a real 15 kHz CRT keeps its
// lock while the controls are moved live. sys/ is untouched, which is the whole
// point of choosing the core-side variant over crt_adjust_sys.sv.
//
// Deviations from the upstream reference glue, both forced by this core:
//
//  1. Read-rate units are SIXTEENTHS of a clk_sys cycle, not quarters. The
//     reference assumes an integer clk/pixel ratio (96/6 = 16 cycles = 64
//     quarters). SSV's pixel clock is a fractional accumulator: 9710/65536 of
//     48.3185 MHz = 7.159091 MHz, i.e. 6.74933 clk per pixel, which is not an
//     integer and cannot be. 6.74933 x 16 = 107.99, so the base period is 108
//     sixteenths -- 0.01% slow at H-Size 0, which is 0.05 pixel across a
//     454-pixel line and is reset every line anyway. It also makes each H-Size
//     step 1/108 = 0.93%, finer than the reference's 1.5%.
//
//  2. H-Position is a signed 6-bit OSD field (-32..+31 px) rather than the
//     reference's 7-bit wrap encoding of +-48. The wrap encoding needs a
//     128-entry OSD list to place -48 at index 79; plain two's complement puts
//     0 at index 0 with a 64-entry list and no dead entries. The module's
//     hoffset input is unchanged (signed 9-bit); only the range offered is.
//
// HPOS_MODE = CONTENTSHIFT: 336 active pixels on a 454-pixel line, and the
// write pointer resets at hcnt 400, leaving 54 samples of margin before the
// active region and 122 after it inside the 512-entry bank -- so +-32 of
// content shift cannot run the picture out of the buffer window.
// ---------------------------------------------------------------------------
localparam int CRT_HTOTAL = 454;
localparam int CRT_VTOTAL = 262;

reg crt_on;
always_ff @(posedge clk_sys) if (av_ce) crt_on <= status[24];

reg signed [4:0] crt_hsize;
always_ff @(posedge clk_sys) if (av_ce) crt_hsize <= $signed(status[29:25]);

reg signed [5:0] crt_hpos;
always_ff @(posedge clk_sys) if (av_ce) crt_hpos <= $signed(status[35:30]);
wire signed [8:0] crt_hoffset = 9'($signed(crt_hpos));

reg signed [5:0] crt_vshift;
always_ff @(posedge clk_sys) if (av_ce) crt_vshift <= 6'($signed(status[40:36]));

// Read clock enable, stepped in sixteenths of clk_sys and restarted on the
// module's hs_ref_out -- never on the raw HSync, or the read rate and the
// module's read counter drift apart and the picture desyncs when shrinking.
wire crt_hs_ref;
reg  crt_hs_ref_d;
always_ff @(posedge clk_sys) crt_hs_ref_d <= crt_hs_ref;
wire crt_hs_ref_rise = crt_hs_ref & ~crt_hs_ref_d;

wire [7:0] crt_rd_period = 8'd108 + {{3{crt_hsize[4]}}, crt_hsize}; // 92..123
reg  [7:0] crt_rd_acc;
wire       crt_rd_tick = (crt_rd_acc + 8'd16) >= crt_rd_period;
always_ff @(posedge clk_sys) begin
    if      (crt_hs_ref_rise) crt_rd_acc <= 8'd0;
    else if (crt_rd_tick)     crt_rd_acc <= crt_rd_acc + 8'd16 - crt_rd_period;
    else                      crt_rd_acc <= crt_rd_acc + 8'd16;
end
wire crt_rd_ce = crt_on ? crt_rd_tick : av_ce;

wire [7:0] crt_r, crt_g, crt_b;
wire crt_hs, crt_vs, crt_hb, crt_vb;

crt_adjust #(
    .VTOTAL   (CRT_VTOTAL),
    .HTOTAL   (CRT_HTOTAL),
    // 1 = HPOS_CONTENTSHIFT. Spelled as a literal rather than the module's
    // `HPOS_CONTENTSHIFT macro because this file is compiled before rtl/ in
    // files.qip, so the macro is not defined yet at this point.
    .HPOS_MODE(1)
) u_crt_adjust (
    .clk      (clk_sys),
    .pxl_cen  (av_ce),
    .pxl2_cen (crt_rd_ce),
    .active   (crt_on),
    .hsize    (crt_hsize),
    .hoffset  (crt_hoffset),
    .voffset  (crt_vshift),
    .r_in     (av_r), .g_in(av_g), .b_in(av_b),
    .hs_in    (av_hs), .vs_in(av_vs),
    .hb_in    (av_hb | av_vb), .vb_in(av_vb),
    .r_out    (crt_r), .g_out(crt_g), .b_out(crt_b),
    .hs_out   (crt_hs), .vs_out(crt_vs),
    .hb_out   (crt_hb), .vb_out(crt_vb),
    .hs_ref_out(crt_hs_ref)
);

// The OSD centres itself on the rising edge of VGA_DE. Left following the
// module's blank it would slide with the picture whenever H-Position moves, so
// build a DE window that rises with the NATIVE active region and falls with the
// adjusted one: the image moves, the OSD stays put on the physical screen.
//
// The native HSync rise is once per line, which is the cadence the reference
// glue gets from a hcnt == HTOTAL-1 tick; sampling VBlank on it also delivers
// the one-line delay the read side needs (it is emitting the previous line).
reg av_hs_d;
always_ff @(posedge clk_sys) if (av_ce) av_hs_d <= av_hs;
wire av_hs_rise = av_ce && (av_hs & ~av_hs_d);

reg crt_vb_1l;
always_ff @(posedge clk_sys) if (av_hs_rise) crt_vb_1l <= av_vb;

wire crt_native_active = ~(av_hb | crt_vb_1l);
reg  crt_native_active_d;
always_ff @(posedge clk_sys) if (av_ce) crt_native_active_d <= crt_native_active;
wire crt_native_rise = crt_native_active & ~crt_native_active_d;

wire crt_adj_active = ~crt_hb;
reg  crt_adj_active_d;
always_ff @(posedge clk_sys) if (crt_rd_ce) crt_adj_active_d <= crt_adj_active;
wire crt_adj_fall = crt_adj_active_d & ~crt_adj_active;

reg crt_de_osd;
always_ff @(posedge clk_sys) begin
    if      (crt_native_rise) crt_de_osd <= 1'b1;
    else if (crt_adj_fall)    crt_de_osd <= 1'b0;
end

// ---------------------------------------------------------------------------
// Standard MiSTer arcade video chain: gamma, scandoubler and scanline FX.
//
// WIDTH is the game's active width, 336, and it is not cosmetic. arcade_video
// passes LINE_LENGTH = WIDTH+4 to the scandoubler, which sizes the Hq2x line
// stores; the library default of 768 would more than double their block RAM on
// a design where M10K is the binding resource.
//
// This path and CRT Adjust are mutually exclusive, and that is a statement
// about the hardware rather than a shortcut. CRT Adjust exists to hand a
// 15 kHz analog CRT byte-exact pixels at a chosen duration; a scandoubler
// exists to turn 15 kHz into 31 kHz for a monitor that cannot do 15 kHz. There
// is no display for which both are wanted, and scanline FX on a real CRT that
// already has scanlines is meaningless. So the mux below picks one whole path
// or the other, and CRT Adjust deliberately gets no gamma: resampling nothing
// is the entire point of it.
// ---------------------------------------------------------------------------
wire [7:0] mix_r, mix_g, mix_b;
wire       mix_hs, mix_vs, mix_de, mix_ce;
wire [1:0] mix_sl;

arcade_video #(.WIDTH(336), .DW(24), .GAMMA(1)) u_arcade_video (
    .clk_video(clk_sys), .ce_pix(av_ce),
    .RGB_in({av_r, av_g, av_b}),
    .HBlank(av_hb), .VBlank(av_vb), .HSync(av_hs), .VSync(av_vs),
    // CLK_VIDEO is only a pass-through of clk_video inside the module; it is
    // driven directly at the top of this file, so it is left unconnected here.
    .CLK_VIDEO(), .CE_PIXEL(mix_ce),
    .VGA_R(mix_r), .VGA_G(mix_g), .VGA_B(mix_b),
    .VGA_HS(mix_hs), .VGA_VS(mix_vs), .VGA_DE(mix_de), .VGA_SL(mix_sl),
    .fx(status[5:3]),
    .forced_scandoubler(forced_scandoubler),
    .gamma_bus(gamma_bus)
);

assign CE_PIXEL = crt_on ? crt_rd_ce : mix_ce;
assign VGA_R  = crt_on ? crt_r  : mix_r;
assign VGA_G  = crt_on ? crt_g  : mix_g;
assign VGA_B  = crt_on ? crt_b  : mix_b;
assign VGA_HS = crt_on ? crt_hs : mix_hs;
assign VGA_VS = crt_on ? crt_vs : mix_vs;
assign VGA_SL = crt_on ? 2'b00  : mix_sl;

// video_freak owns VGA_DE and the aspect outputs. It is pure logic -- one
// 12x12 multiplier and a few counters, no block RAM -- and it is what supplies
// the integer-scaling modes arcade cores are expected to offer.
wire vga_de_in = crt_on ? crt_de_osd : mix_de;
wire [1:0] aspect = status[2:1];

video_freak u_video_freak (
    .CLK_VIDEO(CLK_VIDEO), .CE_PIXEL(CE_PIXEL), .VGA_VS(VGA_VS),
    .HDMI_WIDTH(HDMI_WIDTH), .HDMI_HEIGHT(HDMI_HEIGHT),
    .VGA_DE(VGA_DE), .VIDEO_ARX(VIDEO_ARX), .VIDEO_ARY(VIDEO_ARY),
    .VGA_DE_IN(vga_de_in),
    .ARX((aspect == 0) ? 12'd4 : {10'd0, aspect - 1'b1}),
    .ARY((aspect == 0) ? 12'd3 : 12'd0),
    .CROP_SIZE(12'd0), .CROP_OFF(5'd0),
    .SCALE(status[45:43])
);

assign AUDIO_L = game_pause ? 16'd0 : core_audio_l;
assign AUDIO_R = game_pause ? 16'd0 : core_audio_r;
assign AUDIO_MIX = status[47:46];

// The scanline renderer latches a sticky flag when it misses a line deadline
// or truncates a descriptor/line-slot list. Nothing else reads debug_status,
// so on hardware that failure was silent -- it just drops sprites. Drive the
// I/O board's HDD LED from it so the first board bring-up can see it.
// {1'b1, value} is the MiSTer override encoding.
wire renderer_overrun = debug_status[16];
assign LED_DISK = {1'b1, renderer_overrun};

// Boot diagnostics that only ssv_diag_video ever consumed. They are kept
// because they are cheap and are what a bring-up bisect reaches for first --
// rom_sig_ok in particular is the one bit that says the ROM landed in SDRAM
// intact. Sunk here so removing their reader does not leave Quartus warning
// about dangling nets.
wire unused_debug = &{1'b0, debug_pc, debug_status, download_max_addr,
                      probe_sig0, probe_sig1, rom_sig_ok};

wire unused_inputs = &{1'b0, CLK_AUDIO, SD_MISO,
                       SD_CD, UART_CTS, UART_RXD, UART_DSR, USER_IN,
                       DDRAM_BUSY, DDRAM_DOUT,
                       DDRAM_DOUT_READY, clk_aux};

endmodule
