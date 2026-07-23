// SPDX-License-Identifier: GPL-3.0-or-later
// MiSTer top-level for the Sammy/Seta/Visco SSV core (Dyna Gear target).

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
    "R[0],Reset;",
    "J1,B1,B2,B3,Start,Coin,Test,Service;",
    "V,v",`BUILD_DATE
};

assign ADC_BUS = 'Z;
assign USER_OUT = '1;
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
assign LED_DISK = 2'b00;
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
    .joystick_0(joystick_0), .joystick_1(joystick_1)
);

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
wire loader_reset = ~pll_locked;
wire video_reset = RESET | status[0] | buttons[1] | ~pll_locked;
wire core_reset = video_reset | ioctl_download | ~rom_loaded | ~sdram_ready_sys;
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
    .sdr_wr_ack(ld_wr_ack), .rom_loaded(rom_loaded)
);

wire p0_req, p0_ack;
wire [24:1] p0_addr;
wire [15:0] p0_dout;
wire p1_req, p1_ack;
wire [24:3] p1_addr;
wire [63:0] p1_dout;

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
    .p1_req(p1_req), .p1_addr(p1_addr), .p1_dout(p1_dout), .p1_ack(p1_ack),
    .p2_req(1'b0), .p2_addr('0), .p2_dout(), .p2_ack(),
    .p3_req(1'b0), .p3_addr('0), .p3_dout(), .p3_ack(),
    .p4_req(1'b0), .p4_addr('0), .p4_dout(), .p4_ack(),
    .p5_req(1'b0), .p5_addr('0), .p5_dout(), .p5_ack()
);

function automatic [15:0] player_port(input [31:0] joy);
    player_port = {8'hff, ~{joy[3], joy[2], joy[1], joy[0],
                              joy[4], joy[5], joy[6], joy[10]}};
endfunction

wire test_button = status[6] | joystick_0[12] | joystick_1[12];
wire service_button = joystick_0[13] | joystick_1[13];
wire [15:0] system_port = {8'hff,
    ~{3'b000, test_button, 1'b0, service_button,
      joystick_1[11], joystick_0[11]}};

wire [23:0] core_rgb;
wire core_ce, core_hs, core_vs, core_hb, core_vb;
wire signed [15:0] core_audio_l, core_audio_r;
wire [31:0] debug_pc;
wire [23:0] debug_status;

ssv_core core (
    .clk_sys(clk_sys), .rst(core_reset), .ce_cpu(ce_cpu),
    .sdr_p0_req(p0_req), .sdr_p0_addr(p0_addr),
    .sdr_p0_dout(p0_dout), .sdr_p0_ack(p0_ack),
    .sdr_p1_req(p1_req), .sdr_p1_addr(p1_addr),
    .sdr_p1_dout(p1_dout), .sdr_p1_ack(p1_ack),
    .sdr_wr_req(core_wr_req), .sdr_wr_addr(core_wr_addr),
    .sdr_wr_din(core_wr_din), .sdr_wr_be(core_wr_be),
    .sdr_wr_ack(core_wr_ack),
    .in_dsw1(16'hffff), .in_dsw2(16'hfffd),
    .in_p1(player_port(joystick_0)), .in_p2(player_port(joystick_1)),
    .in_system(system_port), .in_extra(16'hffff),
    .rgb(core_rgb), .ce_pixel(core_ce),
    .hs(core_hs), .vs(core_vs), .hb(core_hb), .vb(core_vb),
    .audio_l(core_audio_l), .audio_r(core_audio_r),
    .debug_pc(debug_pc), .debug_status(debug_status)
);

wire [23:0] startup_rgb = ioctl_download ? 24'h0000c0 :
                          ~rom_loaded ? 24'hc00000 :
                          video_reset ? 24'hc0c000 : core_rgb;
assign CE_PIXEL = core_ce;
assign VGA_R = startup_rgb[23:16];
assign VGA_G = startup_rgb[15:8];
assign VGA_B = startup_rgb[7:0];
assign VGA_HS = core_hs;
assign VGA_VS = core_vs;
assign VGA_DE = ~(core_hb | core_vb);
assign VGA_SL = status[4:3];
assign AUDIO_L = status[7] ? 16'd0 : core_audio_l;
assign AUDIO_R = status[7] ? 16'd0 : core_audio_r;

wire [1:0] aspect = status[2:1];
assign VIDEO_ARX = (aspect == 0) ? 13'd4 : {11'd0, aspect - 1'b1};
assign VIDEO_ARY = (aspect == 0) ? 13'd3 : 13'd0;

wire unused_inputs = &{1'b0, HDMI_WIDTH, HDMI_HEIGHT, CLK_AUDIO, SD_MISO,
                       SD_CD, UART_CTS, UART_RXD, UART_DSR, USER_IN,
                       OSD_STATUS, DDRAM_BUSY, DDRAM_DOUT,
                       DDRAM_DOUT_READY, clk_aux, debug_pc, debug_status};

endmodule
