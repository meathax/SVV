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
    "O[5:3],Scandoubler Fx,None,CRT 25%,CRT 50%,CRT 75%;",
    "O[6],Service Mode,Off,On;",
    "O[7],Pause,Off,On;",
    "-;",
    // Dyna Gear DSW2 (active-low). Defaults match MAME dynagear: Flip Off,
    // Demo Sounds On, Difficulty Normal, Lives 2, Free Play Off, 4 Hearts.
    "O[8],Flip Screen,Off,On;",
    "O[9],Demo Sounds,On,Off;",
    "O[11:10],Difficulty,Normal,Easy,Hard,Hardest;",
    "O[13:12],Lives,2,1,3,4;",
    "O[14],Free Play,Off,On;",
    "O[15],Health,4 Hearts,3 Hearts;",
    // Dyna Gear DSW1: SSV_COINAGE_EXTENDED (Coin A low nibble, Coin B high).
    // OSD index 0 = 1C/1C (DIP all Off = 0xF / 0xF).
    "O[19:16],Coin A,1C/1C,4C/1C,3C/1C,2C/1C,2C/3C,1C/2C,1C/3C,1C/4C,1C/5C,1C/6C,Multi A,Multi B,Multi C,Multi D,Multi E;",
    "O[23:20],Coin B,1C/1C,4C/1C,3C/1C,2C/1C,2C/3C,1C/2C,1C/3C,1C/4C,1C/5C,1C/6C,Multi A,Multi B,Multi C,Multi D,Multi E;",
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
assign AUDIO_MIX = 2'b00;
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

hps_io #(.CONF_STR(CONF_STR)) hps_io (
    .clk_sys(clk_sys), .HPS_BUS(HPS_BUS),
    .buttons(buttons), .status(status),
    .ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr),
    .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
    .ioctl_index(ioctl_index), .ioctl_wait(ioctl_wait),
    // H1 hides the three CRT Adjust amounts while CRT Adjust is Off.
    .status_menumask({14'd0, ~status[24], 1'b0}),
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
logic ce_cpu;
logic [15:0] cpu_acc;
always_ff @(posedge clk_sys) begin
    logic [16:0] sum;
    if (!pll_locked || status[7]) begin
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

// Map OSD index → MAME SSV_COINAGE_EXTENDED nibble (default 0 → 0xF = 1C/1C).
function automatic [3:0] coinage_nibble(input [3:0] osd);
    case (osd)
        4'd0:  coinage_nibble = 4'hF; // 1C/1C
        4'd1:  coinage_nibble = 4'h7; // 4C/1C
        4'd2:  coinage_nibble = 4'h8; // 3C/1C
        4'd3:  coinage_nibble = 4'h9; // 2C/1C
        4'd4:  coinage_nibble = 4'h6; // 2C/3C
        4'd5:  coinage_nibble = 4'hE; // 1C/2C
        4'd6:  coinage_nibble = 4'hD; // 1C/3C
        4'd7:  coinage_nibble = 4'hC; // 1C/4C
        4'd8:  coinage_nibble = 4'hB; // 1C/5C
        4'd9:  coinage_nibble = 4'hA; // 1C/6C
        4'd10: coinage_nibble = 4'h5; // Multi A
        4'd11: coinage_nibble = 4'h4; // Multi B
        4'd12: coinage_nibble = 4'h3; // Multi C
        4'd13: coinage_nibble = 4'h2; // Multi D
        4'd14: coinage_nibble = 4'h1; // Multi E
        default: coinage_nibble = 4'hF;
    endcase
endfunction
wire [15:0] dsw1_port = {8'hff,
    coinage_nibble(status[23:20]), // Coin B
    coinage_nibble(status[19:16])  // Coin A
};

// Map OSD → active-low DSW2 bits (see MAME INPUT_PORTS_START(dynagear)).
wire [1:0] dip_difficulty =
    (status[11:10] == 2'd0) ? 2'b11 : // Normal
    (status[11:10] == 2'd1) ? 2'b10 : // Easy
    (status[11:10] == 2'd2) ? 2'b01 : // Hard
                              2'b00;  // Hardest
wire [1:0] dip_lives =
    (status[13:12] == 2'd0) ? 2'b11 : // 2
    (status[13:12] == 2'd1) ? 2'b01 : // 1
    (status[13:12] == 2'd2) ? 2'b10 : // 3
                              2'b00;  // 4
wire [7:0] dsw2_lo = {
    ~status[15],          // Health: 0=4 hearts default, 1=3 hearts
    ~status[14],          // Free Play Off default
    dip_lives,
    dip_difficulty,
    status[9],            // Demo Sounds: OSD On(0)->DIP 0, Off(1)->DIP 1
    ~status[8]            // Flip Screen Off default
};
wire [15:0] dsw2_port = {8'hff, dsw2_lo};

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
    .rgb(core_rgb), .ce_pixel(core_ce),
    .hs(core_hs), .vs(core_vs), .hb(core_hb), .vb(core_vb),
    .audio_l(core_audio_l), .audio_r(core_audio_r),
    .wdog_rst(wdog_rst),
    .debug_pc(debug_pc), .debug_status(debug_status)
);

// Set ENABLE_DIAG_VIDEO=0 before a release RBF to strip the second raster
// timing path (~200 ALUTs + routing). Keep 1 for bring-up color bars.
localparam bit ENABLE_DIAG_VIDEO = 1'b0;

wire diag_rst = ~pll_locked;
wire cpu_halted = debug_status[23];
wire video_enable = debug_status[22];
wire irq_n_dbg = debug_status[21];
wire ext_busy = debug_status[18];
wire [7:0] irq_enabled = debug_status[7:0];
wire [23:0] diag_rgb;
wire diag_ce, diag_hs, diag_vs, diag_hb, diag_vb;
wire use_core_video;
logic [15:0] diag_frame;
logic diag_vs_d;

generate
if (ENABLE_DIAG_VIDEO) begin : g_diag
    always_ff @(posedge clk_sys) begin
        if (diag_rst) begin
            diag_frame <= 16'd0;
            diag_vs_d <= 1'b1;
        end
        else begin
            diag_vs_d <= diag_vs;
            if (diag_vs_d && !diag_vs)
                diag_frame <= diag_frame + 1'd1;
        end
    end

    ssv_diag_video diag_video (
        .clk(clk_sys), .rst(diag_rst),
        .show_core(1'b1), .core_rgb(core_rgb),
        .pll_locked(pll_locked),
        .ioctl_download(ioctl_download),
        .rom_loaded(rom_loaded),
        .sdram_ready(sdram_ready_sys),
        .video_reset(video_reset),
        .core_reset(core_reset),
        .video_enable(video_enable),
        .cpu_halted(cpu_halted),
        .cpu_pause(status[7]),
        .service_mode(status[6]),
        .irq_n(irq_n_dbg),
        .irq_enabled(irq_enabled),
        .ext_busy(ext_busy),
        .rom_sig_ok(rom_sig_ok),
        .probe_done(probe_done),
        .probe_sig0(probe_sig0),
        .probe_sig1(probe_sig1),
        .debug_pc(debug_pc),
        .ioctl_addr(ioctl_addr),
        .download_max_addr(download_max_addr),
        .frame_count(diag_frame),
        .rgb(diag_rgb), .ce_pixel(diag_ce),
        .hs(diag_hs), .vs(diag_vs), .hb(diag_hb), .vb(diag_vb),
        .use_core_video(use_core_video)
    );
end else begin : g_no_diag
    assign diag_rgb = 24'd0;
    assign diag_ce = 1'b0;
    assign diag_hs = 1'b0;
    assign diag_vs = 1'b0;
    assign diag_hb = 1'b1;
    assign diag_vb = 1'b1;
    assign use_core_video = 1'b1;
    always_ff @(posedge clk_sys) begin
        diag_frame <= 16'd0;
        diag_vs_d <= 1'b1;
    end
end
endgenerate

// Bring-up states 0-7/A/B keep the independent diag raster. Once the game
// enables video (state 8), drive HDMI from the core's own timing so pixels
// and sync share one phase.
wire [7:0] av_r = use_core_video ? core_rgb[23:16] : diag_rgb[23:16];
wire [7:0] av_g = use_core_video ? core_rgb[15:8]  : diag_rgb[15:8];
wire [7:0] av_b = use_core_video ? core_rgb[7:0]   : diag_rgb[7:0];
wire av_hs = use_core_video ? core_hs : diag_hs;
wire av_vs = use_core_video ? core_vs : diag_vs;
wire av_hb = use_core_video ? core_hb : diag_hb;
wire av_vb = use_core_video ? core_vb : diag_vb;
wire av_ce = use_core_video ? core_ce : diag_ce;

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

assign CE_PIXEL = crt_on ? crt_rd_ce : av_ce;
assign VGA_R = crt_on ? crt_r : av_r;
assign VGA_G = crt_on ? crt_g : av_g;
assign VGA_B = crt_on ? crt_b : av_b;
assign VGA_HS = crt_on ? crt_hs : av_hs;
assign VGA_VS = crt_on ? crt_vs : av_vs;
assign VGA_DE = crt_on ? crt_de_osd : ~(av_hb | av_vb);
assign VGA_SL = status[4:3];
assign AUDIO_L = status[7] ? 16'd0 : core_audio_l;
assign AUDIO_R = status[7] ? 16'd0 : core_audio_r;

// The scanline renderer latches a sticky flag when it misses a line deadline
// or truncates a descriptor/line-slot list. With ENABLE_DIAG_VIDEO=0 nothing
// else reads debug_status, so on hardware that failure was silent -- it just
// drops sprites. Drive the I/O board's HDD LED from it so the first board
// bring-up can see it. {1'b1, value} is the MiSTer override encoding.
wire renderer_overrun = debug_status[16];
assign LED_DISK = {1'b1, renderer_overrun};

wire [1:0] aspect = status[2:1];
assign VIDEO_ARX = (aspect == 0) ? 13'd4 : {11'd0, aspect - 1'b1};
assign VIDEO_ARY = (aspect == 0) ? 13'd3 : 13'd0;

wire unused_inputs = &{1'b0, HDMI_WIDTH, HDMI_HEIGHT, CLK_AUDIO, SD_MISO,
                       SD_CD, UART_CTS, UART_RXD, UART_DSR, USER_IN,
                       OSD_STATUS, DDRAM_BUSY, DDRAM_DOUT,
                       DDRAM_DOUT_READY, clk_aux};

endmodule
