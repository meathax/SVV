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

    output        FB_EN,
    output  [4:0] FB_FORMAT,
    output [11:0] FB_WIDTH,
    output [11:0] FB_HEIGHT,
    output [31:0] FB_BASE,
    output [13:0] FB_STRIDE,
    input         FB_VBL,
    input         FB_LL,
    output        FB_FORCE_BLANK,

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

// SDR_AW: the SDRAM word-address width shared by the loader, the core and the
// controller. Taking it from the package rather than restating 24 here is the
// point -- the widths on this boundary are exactly where a silent truncation
// turns into "wrong ROM load offset" and a fake renderer bug.
import ssv_pkg::SDR_AW;

`ifndef BUILD_DATE
`define BUILD_DATE "SSV"
`endif

localparam CONF_STR = {
    "SSV;;",
    "-;",
    "O[2:1],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
    "O[44:43],Scale,Normal,Integer (Horizontal),V-Integer (Vertical),HV-Integer;",
    "O[50:49],Rotation,Horizontal,Vertical (CW),Vertical (CCW),Horizontal (Flipped);",
    // Was labelled "Scandoubler Fx" while no scandoubler existed. HQ2x is
    // gone with arcade_video; the line doubler that replaced it does not
    // filter, so the list is the scanline levels only. Any non-None setting
    // turns the doubler on, which is the convention arcade_video used.
    "O[5:3],Video Fx,None,Scanlines 25%,Scanlines 50%,Scanlines 75%;",
    "O[47:46],Stereo Mix,None,25%,50%,100%;",
    "O[6],Service Mode,Off,On;",
    "H1O[48],Autosave Hiscores,Off,On;",
    // Flip Screen, Demo Sounds, Difficulty, Lives, Free Play, Health and both
    // coinage nibbles are DIP switches and live in the MRA's <switches> block.
    // The framework only renders that as an OSD page when CONF_STR carries the
    // "DIP;" token below -- without it the switches are parsed and delivered to
    // sw[] but have no menu entry, which is why the DIP page was missing.
    // status bits 8..23 are free as a result.
    "-;",
    // CRT Adjust (rtl/crt_adjust.sv). Off is a pure passthrough; the three
    // amounts are hidden until it is On (status_menumask bit 2 below).
    "P1,CRT Adjust;",
    "P1-;",
    "P1O[24],CRT Adjust,Off,On;",
    // 28 entries, not 32: the shrink end stops at -12 because -13 and below
    // put more than 512 pixels on a line and overrun both line buffers in the
    // chain. See the crt_hsize_idx mapping below.
    "H2P1O[29:25],H-Size,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
    "H2P1O[35:30],H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
    "H2P1O[40:36],V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
    "-;",
    // Renders the MRA <switches> block as its own OSD page. Flip Screen lives
    // there; it is the board's own 180-degree flip, so it runs at native rate
    // and works on a 15 kHz CRT (unlike the framebuffer Rotation option above).
    "DIP;",
    "-;",
    "R[0],Reset;",
    // Six game buttons: SSV's P1/P2 ports carry B1-B3 and the
    // $500008 window carries B4-B6.
    "J1,Fire,Jump,Button 3,Button 4,Button 5,Button 6,Coin,Start,Service,Test;",
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
assign FB_FORCE_BLANK = 1'b0;
assign AUDIO_S = 1'b1;
// AUDIO_MIX is driven from the OSD at the bottom of this file.
assign LED_POWER = 2'b00;
// LED_DISK is driven below from the renderer overrun status.
assign BUTTONS = 2'b00;
// This core does not use the MiSTer User I/O port. Keep its open-drain
// outputs released while retaining the framework-required shell ports.
assign USER_OUT = 7'b1111111;

wire clk_sys, clk_ram, clk_aux, pll_locked;
wire pll_ready_sys, pll_ready_ram;
pll pll (
    .refclk_clk(CLK_50M), .reset_reset(1'b0),
    .outclk0_clk(clk_ram), .outclk1_clk(clk_sys),
    .outclk2_clk(SDRAM_CLK), .outclk3_clk(clk_aux),
    .locked_export(pll_locked)
);
assign CLK_VIDEO = clk_sys;
// Keep the established 2x system/DDR clock.  It is a platform clock, not a
// per-frame data signal: muxing it with screen_rotate's video clock creates a
// hardware clock mux and can make the HPS/HDMI path lose lock when rotation is
// changed or when FB_EN changes at a frame boundary.

wire [1:0] buttons;
wire [63:0] status;
wire ioctl_download, ioctl_upload, ioctl_wr, ioctl_rd, ioctl_wait;
wire [15:0] ioctl_index;
wire [26:0] ioctl_addr;
wire [7:0] ioctl_dout;
wire [31:0] joystick_0, joystick_1, joystick_2, joystick_3;
wire [15:0] joystick_l_analog_0;
// Driven by hps_io, consumed by the video chain at the bottom of this file.
// There is no gamma_bus: gamma_corr went with arcade_video.
wire        forced_scandoubler;
wire        video_rotated;

// High score save/load nets. The module itself is instantiated further down,
// next to ssv_core; these are declared here because hps_io and ssv_core both
// sit above it and both connect to them. See that instance for the mapping.
wire [15:0] hs_addr;
wire  [7:0] hs_data_to_ram, hs_data_from_ram;
wire        hs_ram_write, hs_configured;
wire  [7:0] hs_data_to_hps;
wire        hs_upload, hs_upload_req;

// Descriptor-sized board NVRAM uses MiSTer persistence index 8. hps_io has a
// single upload request/index/data path, so requests from this bridge and the
// existing hiscore index-4 client are serialized below.
wire  [7:0] nv_data_to_hps;
wire        nv_upload_req, nv_ioctl_wait;
wire        nv_init_busy, nv_init_done;
wire        nvram_transfer;

logic hs_upload_req_q, nv_upload_req_q;
logic hs_upload_pending, nv_upload_pending;
logic [2:0] upload_arb_state;
logic       upload_req_to_hps;
logic [7:0] upload_index_to_hps;
localparam logic [2:0] UP_IDLE = 3'd0, UP_SIGNAL = 3'd1,
                       UP_WAIT = 3'd2, UP_ACTIVE = 3'd3,
                       UP_GAP = 3'd4;

always_ff @(posedge clk_sys) begin
    if (!pll_ready_sys) begin
        hs_upload_req_q    <= 1'b0;
        nv_upload_req_q    <= 1'b0;
        hs_upload_pending  <= 1'b0;
        nv_upload_pending  <= 1'b0;
        upload_arb_state   <= UP_IDLE;
        upload_req_to_hps  <= 1'b0;
        upload_index_to_hps <= 8'd4;
    end
    else begin
        hs_upload_req_q <= hs_upload_req;
        nv_upload_req_q <= nv_upload_req;
        upload_req_to_hps <= 1'b0;

        if (hs_upload_req && !hs_upload_req_q)
            hs_upload_pending <= 1'b1;
        if (nv_upload_req && !nv_upload_req_q)
            nv_upload_pending <= 1'b1;

        case (upload_arb_state)
            UP_IDLE: begin
                // Board NVRAM has priority, but an index-4 edge is retained.
                if (nv_upload_pending) begin
                    nv_upload_pending   <= 1'b0;
                    upload_index_to_hps <= 8'd8;
                    upload_req_to_hps   <= 1'b1;
                    upload_arb_state    <= UP_SIGNAL;
                end
                else if (hs_upload_pending) begin
                    hs_upload_pending   <= 1'b0;
                    upload_index_to_hps <= 8'd4;
                    upload_req_to_hps   <= 1'b1;
                    upload_arb_state    <= UP_SIGNAL;
                end
            end
            UP_SIGNAL: upload_arb_state <= UP_WAIT;
            UP_WAIT: begin
                // Keep the selected index stable until HPS starts that upload.
                if (ioctl_upload &&
                    (ioctl_index[7:0] == upload_index_to_hps))
                    upload_arb_state <= UP_ACTIVE;
            end
            UP_ACTIVE: begin
                if (!ioctl_upload)
                    upload_arb_state <= UP_GAP;
            end
            UP_GAP: upload_arb_state <= UP_IDLE;
            default: upload_arb_state <= UP_IDLE;
        endcase
    end
end

assign hs_upload = ioctl_upload && (ioctl_index[7:0] == 8'd4);
wire [7:0] ioctl_data_to_hps = (ioctl_index[7:0] == 8'd8)
                                ? nv_data_to_hps : hs_data_to_hps;

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
    .ioctl_upload(ioctl_upload), .ioctl_rd(ioctl_rd),
    .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
    .ioctl_index(ioctl_index), .ioctl_wait(ioctl_wait),
    // Hiscore index 4 and board NVRAM index 8 share the HPS upload channel.
    .ioctl_upload_req(upload_req_to_hps),
    .ioctl_upload_index(upload_index_to_hps),
    .ioctl_din(ioctl_data_to_hps),
    // H1 hides Autosave on an MRA that carries no hiscore.dat entry.
    // H2 hides the three CRT Adjust amounts while CRT Adjust itself is Off.
    .status_menumask({13'd0, ~status[24], ~hs_configured, 1'b0}),
    .forced_scandoubler(forced_scandoubler),
    .video_rotated(video_rotated),
    .joystick_0(joystick_0), .joystick_1(joystick_1),
    .joystick_2(joystick_2), .joystick_3(joystick_3)
    ,.joystick_l_analog_0(joystick_l_analog_0)
);

// V60 clock enable.
//
// CONFIRMED from a real STA-0001B photograph: the board's second crystal is
// **48.000 MHz**, and 48.000 / 3 = 16.000 MHz is the V60 clock. The accumulator
// below targets that from clk_sys.
//
// The two board clocks are independent, so their ratio is the observable
// quantity for gameplay/frame lock: 16 MHz / (42.954545 MHz / 6) = 704/315.
// SSV_CPU_INC=21701 against SSV_PIXEL_INC=9710 is within 3.7 ppm; the former
// 21702 value was 42.4 ppm fast relative to video and visibly accumulated an
// ES5506/frame-boundary phase error in current Dyna Gear lockstep evidence.
//
// The OSD is deliberately not part of the emulation pause path. MiSTer may
// retune or redraw video while the menu is open, so freezing the CPU here can
// disturb the frame/audio phase and make HDMI sync fragile. Keep only pauses
// required for data transfers and hiscore RAM transactions.
//
// hs_pause is the hiscore module asking for the CPU to be still while it
// reads or writes the score table. It is a registered output over there, so
// feeding game_pause straight back into its paused input is a handshake and
// not a combinational loop.
wire hs_pause;
wire game_pause;

logic ce_cpu;
logic [15:0] cpu_acc;
always_ff @(posedge clk_sys) begin
    logic [16:0] sum;
    if (!pll_ready_sys || game_pause) begin
        ce_cpu <= 1'b0;
        if (!pll_ready_sys) cpu_acc <= 16'd0;
    end
    else begin
        sum = {1'b0, cpu_acc} + {1'b0, ssv_pkg::SSV_CPU_INC};
        ce_cpu <= sum[16];
        cpu_acc <= sum[15:0];
    end
end

wire sdram_ready;
wire sdram_ready_sys;
wire rom_loaded;
wire loader_reset, video_reset;
wire core_cold_reset, core_reset;
wire wdog_rst;

ssv_host_guard u_host_guard (
    .clk_sys(clk_sys), .clk_ram(clk_ram),
    .pll_locked_async(pll_locked),
    // RESET is an asynchronous shell input; status/buttons already originate
    // in clk_sys through hps_io and must retain their existing phase.
    .reset_async(RESET), .reset_request(status[0] | buttons[1]),
    .sdram_ready_async(sdram_ready),
    .ioctl_download(ioctl_download), .ioctl_upload(ioctl_upload),
    .ioctl_index(ioctl_index),
    .rom_loaded(rom_loaded),
    .nv_init_done(nv_init_done), .nv_init_busy(nv_init_busy),
    .hs_pause(hs_pause), .wdog_rst(wdog_rst),
    .pll_ready_sys(pll_ready_sys), .pll_ready_ram(pll_ready_ram),
    .sdram_ready_sys(sdram_ready_sys),
    .nvram_transfer(nvram_transfer), .game_pause(game_pause),
    .loader_reset(loader_reset), .video_reset(video_reset),
    .core_cold_reset(core_cold_reset), .core_reset(core_reset)
);

assign LED_USER = ~rom_loaded;

`ifdef SIMULATION
// Release builds contain no reset-cause state or diagnostic ports.  The
// simulation-only edge log makes an unsolicited reset distinguishable between
// watchdog, host persistence, media readiness, PLL and front-panel sources.
logic sim_video_reset_d, sim_core_reset_d, sim_wdog_rst_d;
wire [9:0] sim_reset_causes = {
    wdog_rst, ~nv_init_done, ~sdram_ready_sys, ~rom_loaded,
    nvram_transfer,
    ioctl_download && ((ioctl_index == 16'd0) || (ioctl_index == 16'd1)),
    ~pll_ready_sys, buttons[1], status[0], RESET
};
initial begin
    sim_video_reset_d = 1'b0;
    sim_core_reset_d  = 1'b0;
    sim_wdog_rst_d    = 1'b0;
end
always @(posedge clk_sys) begin
    if (video_reset !== sim_video_reset_d)
        $display("SSV_VIDEO_RESET_%s time=%0t causes=%b",
                 video_reset ? "ASSERT" : "RELEASE",
                 $time, sim_reset_causes);
    if (core_reset !== sim_core_reset_d)
        $display("SSV_CORE_RESET_%s time=%0t causes=%b",
                 core_reset ? "ASSERT" : "RELEASE",
                 $time, sim_reset_causes);
    if (wdog_rst !== sim_wdog_rst_d)
        $display("SSV_WDOG_RESET_%s time=%0t mode=%0d counter=%0d",
                 wdog_rst ? "ASSERT" : "RELEASE",
                 $time, game_cfg.wdog_mode, core.wdog_cycle_cnt);
    sim_video_reset_d <= video_reset;
    sim_core_reset_d  <= core_reset;
    sim_wdog_rst_d    <= wdog_rst;
end
`endif

wire ld_wr_req, ld_wr_ack;
wire ld_ioctl_wait;
wire [SDR_AW:1] ld_wr_addr;
wire [15:0] ld_wr_din;
wire [1:0] ld_wr_be;
wire st010_drom_we;
wire [10:0] st010_drom_wa;
wire [15:0] st010_drom_wd;

// Per-game configuration, parsed by the loader from the MRA's
// <rom index="1"> block. game_cfg is what the core actually runs on; there is
// no fallback to a compiled-in default, because a silent fallback turns a
// packaging mistake into a corrupt-graphics bug hunt. game_cfg_valid gates
// rom_loaded inside the loader, so a missing block shows up as LED_USER
// staying lit rather than as a broken picture.
ssv_pkg::ssv_cfg_t game_cfg;
wire               game_cfg_valid;
wire               game_cfg_commit;

ssv_rom_loader loader (
    .cfg(game_cfg), .cfg_valid(game_cfg_valid),
    .cfg_commit(game_cfg_commit),
    .clk(clk_sys), .rst(loader_reset), .mem_ready(sdram_ready_sys),
    .ioctl_download(ioctl_download), .ioctl_index(ioctl_index[7:0]),
    .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr),
    .ioctl_dout(ioctl_dout), .ioctl_wait(ld_ioctl_wait),
    .sdr_wr_req(ld_wr_req), .sdr_wr_addr(ld_wr_addr),
    .sdr_wr_din(ld_wr_din), .sdr_wr_be(ld_wr_be),
    .sdr_wr_ack(ld_wr_ack), .rom_loaded(rom_loaded),
    .st010_drom_we(st010_drom_we),
    .st010_drom_wa(st010_drom_wa), .st010_drom_wd(st010_drom_wd)
);

// While cold-zeroing, descriptor bytes (index 1) must continue to flow, but
// index 0 and persisted index 8 are held until the exact-sized fill completes.
wire nv_init_ioctl_wait = (game_cfg_commit || nv_init_busy) &&
                          ioctl_download &&
                          ((ioctl_index == 16'd0) ||
                           (ioctl_index == 16'd8));
assign ioctl_wait = ld_ioctl_wait | nv_ioctl_wait | nv_init_ioctl_wait;

wire core_p0_req;
wire [SDR_AW:1] core_p0_addr;
wire p0_ack;
wire [15:0] p0_dout;
wire p0_req  = core_p0_req;
wire [SDR_AW:1] p0_addr = core_p0_addr;

// Graphics row fetch: one 128-bit p2 burst per 16-pixel tile row. p1 (64-bit,
// 4-word burst) is now unused by this core and is left tied off below -- it is
// the natural home for a future ES5506 sample line cache, whose worst-case
// latency is better served by a 13-cycle transaction than p2's 17.
wire p2_req, p2_ack;
wire [SDR_AW:4] p2_addr;
wire [127:0] p2_dout;
wire nv_p3_req, nv_p3_ack;
wire [SDR_AW:1] nv_p3_addr;
wire [15:0] nv_p3_dout;
wire p4_req, p4_ack;
wire [SDR_AW:1] p4_addr;
wire [15:0] p4_dout;
wire p5_req, p5_ack;
wire [SDR_AW:3] p5_addr;
wire [63:0] p5_dout;

wire core_wr_req, core_wr_ack;
wire [SDR_AW:1] core_wr_addr;
wire [15:0] core_wr_din;
wire [1:0] core_wr_be;
wire nv_wr_req, nv_wr_ack;
wire [SDR_AW:1] nv_wr_addr;
wire [15:0] nv_wr_din;
wire [1:0] nv_wr_be;
wire nv_modified;
wire sw_req, sw_ack;
wire [SDR_AW:1] sw_addr;
wire [15:0] sw_din;
wire [1:0] sw_be;
wire [1:0] nvram_size_mode = (game_cfg_valid && game_cfg.has_nvram)
                              ? game_cfg.nvram_mode : 2'd0;

ssv_nvram_bridge #(
    .SDR_AW(SDR_AW),
    .NVRAM_BASE(ssv_pkg::SDR_NVRAM_BASE)
) nvram_bridge (
    .clk(clk_sys), .rst(loader_reset),
    .nvram_size_mode(nvram_size_mode),
    .cfg_commit(game_cfg_commit),
    .init_busy(nv_init_busy), .init_done(nv_init_done),
    .modified(nv_modified), .dirty(),
    .ioctl_download(ioctl_download), .ioctl_upload(ioctl_upload),
    .ioctl_wr(ioctl_wr), .ioctl_rd(ioctl_rd),
    .ioctl_index(ioctl_index), .ioctl_addr(ioctl_addr),
    .ioctl_dout(ioctl_dout), .ioctl_din(nv_data_to_hps),
    .ioctl_wait(nv_ioctl_wait), .ioctl_upload_req(nv_upload_req),
    .sdr_ready(sdram_ready_sys),
    .sdr_wr_req(nv_wr_req), .sdr_wr_addr(nv_wr_addr),
    .sdr_wr_din(nv_wr_din), .sdr_wr_be(nv_wr_be),
    .sdr_wr_ack(nv_wr_ack),
    .sdr_rd_req(nv_p3_req), .sdr_rd_addr(nv_p3_addr),
    .sdr_rd_dout(nv_p3_dout), .sdr_rd_ack(nv_p3_ack)
);

wire loader_owns_write = ld_wr_req;
wire nvram_owns_write = !loader_owns_write && nv_wr_req;

assign sw_req  = loader_owns_write ? ld_wr_req  :
                 nvram_owns_write  ? nv_wr_req  : core_wr_req;
assign sw_addr = loader_owns_write ? ld_wr_addr :
                 nvram_owns_write  ? nv_wr_addr : core_wr_addr;
assign sw_din  = loader_owns_write ? ld_wr_din  :
                 nvram_owns_write  ? nv_wr_din  : core_wr_din;
assign sw_be   = loader_owns_write ? ld_wr_be   :
                 nvram_owns_write  ? nv_wr_be   : core_wr_be;
assign ld_wr_ack   = loader_owns_write ? sw_ack : 1'b0;
assign nv_wr_ack   = nvram_owns_write ? sw_ack : 1'b0;
assign core_wr_ack = (!loader_owns_write && !nvram_owns_write) ? sw_ack : 1'b0;

// Only a completed core write in the exact descriptor-selected physical
// NVRAM range marks persistence dirty. Loader/zero-fill/index-8 writes do not.
wire [SDR_AW:1] nvram_word_limit = ssv_pkg::SDR_NVRAM_BASE[SDR_AW:1] +
    ((nvram_size_mode == 2'd1) ? SDR_AW'(1024) :
     (nvram_size_mode == 2'd2) ? SDR_AW'(32768) : SDR_AW'(0));
assign nv_modified = core_wr_req && core_wr_ack &&
                     ((nvram_size_mode == 2'd1) ||
                      (nvram_size_mode == 2'd2)) &&
                     (core_wr_addr >= ssv_pkg::SDR_NVRAM_BASE[SDR_AW:1]) &&
                     (core_wr_addr < nvram_word_limit);

// The 128 MB module fitted on this board is TWO 32Mx16 devices, not one
// 64Mx16 part: SDRAM_nCS selects between them and DQML/DQMH are shorted to
// A11/A12. The controller encodes that contract and takes NO geometry
// parameters -- parameterising it is exactly how the wrong part came to be
// configured, which byte-masked every write through the A11 short and left
// device 1 without an MRS. See rtl/mem/sdram.sv and
// docs/issues/SDRAM_MODULE_CONTRACT.md; the failure is reproduced by
// verif/tb_ssv_sdram_module_contract.sv.
sdram sdram (
    .clk(clk_ram), .init(~pll_ready_ram), .ready(sdram_ready),
    .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
    .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
    .SDRAM_nCS(SDRAM_nCS), .SDRAM_nCAS(SDRAM_nCAS),
    .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_CKE(SDRAM_CKE),
    .wr_req(sw_req), .wr_addr(sw_addr), .wr_din(sw_din),
    .wr_be(sw_be), .wr_ack(sw_ack),
    .p0_req(p0_req), .p0_addr(p0_addr), .p0_dout(p0_dout), .p0_ack(p0_ack),
    .p1_req(1'b0), .p1_addr('0), .p1_dout(), .p1_ack(),
    .p2_req(p2_req), .p2_addr(p2_addr), .p2_dout(p2_dout), .p2_ack(p2_ack),
    .p3_req(nv_p3_req), .p3_addr(nv_p3_addr),
    .p3_dout(nv_p3_dout), .p3_ack(nv_p3_ack),
    .p4_req(p4_req), .p4_addr(p4_addr), .p4_dout(p4_dout), .p4_ack(p4_ack),
    .p5_req(p5_req), .p5_addr(p5_addr), .p5_dout(p5_dout), .p5_ack(p5_ack)
);

// MiSTer J1 order: Fire,Jump,B3,B4,B5,B6,Start,Coin,Service,Test
//                  joy[4]..joy[13]
// (the MRA's <buttons names=...> list must stay in this same order).
//
wire [31:0] joy_p1 = joystick_0;
wire [31:0] joy_p2 = joystick_1;
wire [31:0] joy_p3 = joystick_2;
wire [31:0] joy_p4 = joystick_3;

wire [15:0] p1_input_port;
wire [15:0] p2_input_port;
// Feeds ssv_core's UNUSED in_mahjong_rows port only -- the mahjong/Eagle Shot/
// Sexy Reaction/GDFS optional-I/O family is not in the universal profile, so
// this value is discarded inside the core. Kept in step with that port, which
// eight verif/ benches still bind by name; remove both together.
wire [23:0] mahjong_rows = {~joy_p4[9:4], ~joy_p3[9:4],
                            ~joy_p2[9:4], ~joy_p1[9:4]};
wire signed [7:0] analog_x = joystick_l_analog_0[7:0];
wire signed [7:0] analog_y = joystick_l_analog_0[15:8];
wire [11:0] optional_coord_x = 12'h800 + (12'($signed(analog_x)) <<< 3);
wire [11:0] optional_coord_y = 12'h800 + (12'($signed(analog_y)) <<< 3);
wire [7:0] optional_paddle = 8'h80 + 8'($signed(analog_x));

wire test_button = status[6] | joy_p1[13] | joy_p2[13];
// OSD assign-button prompt order for the standard 10-slot layout follows
// fixed joystick bits per slot position (4..13), not the MRA's <buttons>
// name text -- see docs/debug/... (2026-08-19 reorder). To get the desired
// on-screen prompt order Coin,Start,Service,Test, the CORE must read those
// functions from bits 10,11,12,13 in that same order; Start moved out of
// player_port() in ssv_input_ports.sv from bit 12 to bit 11 to match (grep
// that file for the companion change). Bit 12 was Start until this change --
// wiring service_button to a bit still read as Start elsewhere caused the
// 2026-08-19 Service/Start cross-firing bug; keep this comment in sync with
// player_port() if either side is touched again.
wire coin1_button = joy_p1[10];
wire coin2_button = joy_p2[10];
wire service_button = joy_p1[12] | joy_p2[12];
wire [15:0] system_port;
wire [15:0] extra_input_port;
wire core_frame_tick;

ssv_input_ports input_ports (
    .clk(clk_sys), .rst(core_cold_reset), .frame_tick(core_frame_tick),
    .joy_p1(joy_p1), .joy_p2(joy_p2),
    .input_layout(game_cfg.input_layout),
    .system_input_mode(game_cfg.system_input_mode),
    .extra_input_mode(game_cfg.extra_input_mode),
    .rapid_fire_b3_to_b1(game_cfg.rapid_fire_b3_to_b1),
    .rapid_fire_b1(game_cfg.rapid_fire_b1),
    .rapid_fire_b2(game_cfg.rapid_fire_b2),
    .test_button(test_button), .service_button(service_button),
    .coin1_button(coin1_button), .coin2_button(coin2_button),
    .p1_port(p1_input_port), .p2_port(p2_input_port),
    .system_port(system_port), .extra_port(extra_input_port)
);

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
wire renderer_overrun;
wire signed [15:0] core_audio_l, core_audio_r;
ssv_core core (
    .cfg(game_cfg),
    .clk_sys(clk_sys), .rst(core_reset), .cold_rst(core_cold_reset),
    .ce_cpu(ce_cpu), .watchdog_hold(game_pause),
    .sdr_p0_req(core_p0_req), .sdr_p0_addr(core_p0_addr),
    .sdr_p0_dout(p0_dout), .sdr_p0_ack(p0_ack),
    .sdr_p2_req(p2_req), .sdr_p2_addr(p2_addr),
    .sdr_p2_dout(p2_dout), .sdr_p2_ack(p2_ack),
    .sdr_wr_req(core_wr_req), .sdr_wr_addr(core_wr_addr),
    .sdr_wr_din(core_wr_din), .sdr_wr_be(core_wr_be),
    .sdr_wr_ack(core_wr_ack),
    .sdr_p5_req(p5_req), .sdr_p5_addr(p5_addr),
    .sdr_p5_dout(p5_dout), .sdr_p5_ack(p5_ack),
    .st010_drom_we(st010_drom_we), .st010_drom_wa(st010_drom_wa),
    .st010_drom_wd(st010_drom_wd),
    .sdr_p4_req(p4_req), .sdr_p4_addr(p4_addr),
    .sdr_p4_dout(p4_dout), .sdr_p4_ack(p4_ack),
    .in_dsw1(dsw1_port), .in_dsw2(dsw2_port),
    .in_p1(p1_input_port), .in_p2(p2_input_port),
    .in_system(system_port),
    .in_extra(extra_input_port),
    .in_mahjong_rows(mahjong_rows),
    .in_coord_x(optional_coord_x), .in_coord_y(optional_coord_y),
    .in_paddle(optional_paddle), .in_ball_switch(joy_p1[11]),
    .frame_tick(core_frame_tick),
    .hs_addr(hs_word_addr), .hs_din(hs_word_din), .hs_be(hs_word_be),
    .hs_we(hs_ram_we), .hs_dout(hs_word_dout),
    .rgb(core_rgb), .ce_pixel(core_ce), .ce_pix_x2(ce_pix_x2),
    .hs(core_hs), .vs(core_vs), .hb(core_hb), .vb(core_vb),
    .audio_l(core_audio_l), .audio_r(core_audio_r),
    .wdog_rst(wdog_rst),
    .coin_lockout(), .renderer_overrun(renderer_overrun), .motor_output()
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
    // Do not trigger the hiscore scan when the OSD opens: that path pauses
    // the game CPU and can destabilize video/audio synchronization.
    .OSD_STATUS(1'b0),

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
wire ce_pix_x2;

// ---------------------------------------------------------------------------
// Video output.
//
// The chain is deliberately small: an optional 2x line doubler, then
// video_freak for the scaling modes and VGA_DE. What is NOT here matters as
// much as what is.
//
// sys/arcade_video.v was used briefly and removed. It reaches a scandoubler
// through video_mixer, and that scandoubler keeps its line storage inside
// Hq2x -- two input line buffers plus an output buffer four times the pixel
// width -- which is about nine M10K at this game's 336-pixel active width,
// with gamma_corr adding roughly four more. This design is at its block RAM
// ceiling and the fitter is at its memory ceiling, and neither the HQ2x filter
// nor a gamma curve earns that on an arcade board driving a CRT. Dropping
// arcade_video takes gamma with it, so there is no GAMMA parameter to set.
//
// CRT Adjust (rmonic79) was removed with it and is now BACK, upstream of the
// doubler -- see the block below for where and why.
//
// Scanline FX are unaffected by any of this -- sys_top applies them itself
// from VGA_SL (sys/sys_top.v: scanlines #(0) VGA_scanlines), which is why the
// option kept working even before this core had any video chain at all.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// CRT Adjust (rtl/crt_adjust.sv, rmonic79) -- core-side integration.
//
// Everything the picture is resized and repositioned by happens inside a line
// buffer whose engine restarts on the module's own line reference, so the sync
// never moves out of phase with the content and a real 15 kHz CRT keeps its
// lock while the controls are moved live. sys/ is untouched, which is the whole
// point of choosing the core-side variant over crt_adjust_sys.sv.
//
// PLACEMENT: between the core raster and ssv_scandoubler, NOT as an alternative
// to it. The previous integration muxed the two whole paths against each other,
// on the argument that no display wants both. That argument is wrong in one
// direction: a 15 kHz CRT user runs Video Fx = None, so sd_on is 0 and CRT
// Adjust has to work on the UNDOUBLED path -- which it does here -- but a user
// on a 31 kHz analog set needs the doubler to get a picture at all, and the old
// mux silently took the doubler away the moment CRT Adjust was switched on,
// dropping them back to 15 kHz. Sitting upstream, CRT Adjust adjusts and the
// doubler doubles whatever it is handed, so both are available together.
//
// This composes rather than fighting because ssv_scandoubler MEASURES its line
// length (hmax) instead of hardcoding one: it counts ce_pix ticks between line
// references and wraps the read pointer there. Change the pixel rate under it
// and it follows. It does need its two enables in an exact 2:1 -- see the
// accumulator below.
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
// write pointer resets on the line reference at hcnt 400, leaving 54 samples of
// margin before the active region and 122 after it inside the 512-entry bank --
// so +-32 of content shift cannot run the picture out of the buffer window.
// ---------------------------------------------------------------------------
localparam int CRT_HTOTAL = 454;
localparam int CRT_VTOTAL = 262;

wire       sd_on;
wire       crt_on;
wire [4:0] crt_hsize_idx;
wire signed [5:0] crt_hpos;
wire signed [5:0] crt_vshift;
wire [1:0] rotation;
wire [1:0] aspect;
wire [1:0] scale_select;

ssv_video_mode_guard u_video_mode_guard (
    .clk(clk_sys), .rst(video_reset),
    .native_ce(av_ce), .native_hsync(av_hs), .native_vblank(av_vb),
    .sd_request(forced_scandoubler | (|status[5:3])),
    .crt_request(status[24]),
    .crt_hsize_request(status[29:25]),
    .crt_hpos_request(status[35:30]),
    .crt_vshift_request(status[40:36]),
    .rotation_request(status[50:49]),
    .aspect_request(status[2:1]),
    .scale_request(status[44:43]),
    .sd_on(sd_on), .crt_on(crt_on),
    .crt_hsize_idx(crt_hsize_idx),
    .crt_hpos(crt_hpos), .crt_vshift(crt_vshift),
    .rotation(rotation), .aspect(aspect), .scale_select(scale_select)
);

// H-Size is offered as an INDEX, not as raw two's complement, so that the
// shrink end can be cut short. Shrinking speeds the read up, which puts MORE
// output pixels on a line, and both line buffers in this chain hold 512 entries
// per bank: crt_adjust's own read address is 9 bits, and ssv_scandoubler
// measures the line into a 9-bit hmax. Measured with the directed chain bench,
// pixels per output line are 454 at H-Size 0, 510 at -12, and 533 at -16 --
// so -13 and below overrun the bank. At -16 the doubler's measured line length
// collapsed from 509 to 19, i.e. the picture is destroyed, not merely clipped.
//
// The integration removed in 095d3b2 offered the full -16..+15 and had the same
// defect; it is fixed here rather than restored. Indices 0..15 are +0..+15 and
// indices 16..27 are -12..-1, which is what the OSD list enumerates; the
// subtraction below is 5-bit and wraps to exactly that (16 - 28 = -12).
wire signed [4:0] crt_hsize =
    (crt_hsize_idx <= 5'd15) ? $signed(crt_hsize_idx)
                             : $signed(crt_hsize_idx - 5'd28);
wire signed [8:0] crt_hoffset = 9'($signed(crt_hpos));

// Read clock enable, restarted on the module's hs_ref_out -- never on the raw
// HSync, or the read rate and the module's read counter drift apart and the
// picture desyncs when shrinking.
//
// ONE accumulator, stepped 32 per clk against a period in sixteenths, so each
// carry is a HALF-pixel tick and every second carry is a whole pixel. That is
// the same construction ssv_video_timing uses for the native pair, and for the
// same reason: the doubler downstream needs its x2 enable to be exactly twice
// its pixel enable and in phase, and two independent accumulators cannot be
// held in that relationship (measured: 907 half-ticks per line where 908 were
// needed, every doubled line one pixel short). Deriving both from one carry
// chain makes the ratio true by construction at any H-Size.
wire crt_hs_ref;
reg  crt_hs_ref_d;
always_ff @(posedge clk_sys) crt_hs_ref_d <= crt_hs_ref;
wire crt_hs_ref_rise = crt_hs_ref & ~crt_hs_ref_d;

wire [7:0] crt_rd_period = 8'd108 + {{3{crt_hsize[4]}}, crt_hsize}; // 92..123
reg  [7:0] crt_rd_acc;
reg        crt_rd_phase;
wire       crt_x2_tick = (crt_rd_acc + 8'd32) >= crt_rd_period;
always_ff @(posedge clk_sys) begin
    if (crt_hs_ref_rise) begin
        crt_rd_acc   <= 8'd0;
        crt_rd_phase <= 1'b0;
    end
    else if (crt_x2_tick) begin
        crt_rd_acc   <= crt_rd_acc + 8'd32 - crt_rd_period;
        crt_rd_phase <= ~crt_rd_phase;
    end
    else begin
        crt_rd_acc   <= crt_rd_acc + 8'd32;
    end
end
wire crt_rd_tick = crt_x2_tick & crt_rd_phase;
wire crt_rd_ce   = crt_on ? crt_rd_tick : av_ce;

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

// The stream the rest of the chain sees. Muxed rather than always taken from
// crt_adjust's bypass path so that with CRT Adjust Off the video is bit- and
// cycle-identical to a build without this module: bypass still costs a pixel of
// latency on every signal, and the default path should not pay for a feature
// that is not switched on.
wire [7:0] vid_r     = crt_on ? crt_r     : av_r;
wire [7:0] vid_g     = crt_on ? crt_g     : av_g;
wire [7:0] vid_b     = crt_on ? crt_b     : av_b;
wire       vid_hs    = crt_on ? crt_hs    : av_hs;
wire       vid_vs    = crt_on ? crt_vs    : av_vs;
wire       vid_hb    = crt_on ? crt_hb    : av_hb;
wire       vid_vb    = crt_on ? crt_vb    : av_vb;
// vid_ce is crt_rd_ce by definition -- the same mux, named once.
wire       vid_ce    = crt_rd_ce;
wire       vid_ce_x2 = crt_on ? crt_x2_tick : ce_pix_x2;

// The OSD centres itself on the rising edge of VGA_DE. Left following the
// module's blank it would slide with the picture whenever H-Position moves, so
// build a DE window that rises with the NATIVE active region and falls with the
// adjusted one: the image moves, the OSD stays put on the physical screen.
//
// The native HSync rise is once per line, which is the cadence the reference
// glue gets from a hcnt == HTOTAL-1 tick; sampling VBlank on it also delivers
// the one-line delay the read side needs (it is emitting the previous line).
//
// This is used on the UNDOUBLED path only. On the doubled path VGA_DE comes
// from the doubler's replayed blank, so with CRT Adjust and the doubler both on
// the OSD tracks the image horizontally. Keeping it fixed there would mean
// storing this bit through the line buffer, i.e. editing ssv_scandoubler; the
// display that needs a stable OSD and analog geometry correction at once is the
// 15 kHz set, and that is the path it is correct on.
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

// Any Fx selection implies doubling, the same rule arcade_video used. The
// request is committed by u_video_mode_guard at a VBlank line boundary.

// The doubler needs an enable at exactly twice the pixel rate and in phase
// with it. That now comes from ssv_video_timing, which runs ONE accumulator at
// twice the pixel increment and takes ce_pixel as every second carry, so the
// 2:1 ratio holds by construction.
//
// It used to be generated here by a SECOND accumulator restarted on the line
// reference, while the core's free-runs. verif/tb_ssv_scandoubler.sv measured
// that at a constant 907 ticks per line where exact doubling of a 454-pixel
// line needs 908 -- every doubled line was one pixel short. Do not reintroduce
// a local generator; the two accumulators cannot be kept in step.

wire [23:0] sd_rgb;
wire        sd_hs, sd_vs, sd_hb, sd_vb;

ssv_scandoubler u_scandoubler (
    .clk(clk_sys), .rst(video_reset),
    .ce_pix(vid_ce), .ce_pix_x2(vid_ce_x2),
    .rgb_in({vid_r, vid_g, vid_b}),
    .hs_in(vid_hs), .vs_in(vid_vs), .hb_in(vid_hb), .vb_in(vid_vb),
    .rgb_out(sd_rgb),
    .hs_out(sd_hs), .vs_out(sd_vs), .hb_out(sd_hb), .vb_out(sd_vb)
);

assign CE_PIXEL = sd_on ? vid_ce_x2 : vid_ce;
assign VGA_R    = sd_on ? sd_rgb[23:16] : vid_r;
assign VGA_G    = sd_on ? sd_rgb[15:8]  : vid_g;
assign VGA_B    = sd_on ? sd_rgb[7:0]   : vid_b;
assign VGA_HS   = sd_on ? sd_hs : vid_hs;
assign VGA_VS   = sd_on ? sd_vs : vid_vs;
assign VGA_SL   = status[4:3];

wire vga_de_in = sd_on   ? ~(sd_hb | sd_vb)
               : crt_on  ? crt_de_osd
               :           ~(av_hb | av_vb);
wire rotation_active = (rotation == 2'd1) || (rotation == 2'd2);

// Follow the established MiSTer vertical-core contract: present the native
// cabinet aspect as 4:3 horizontally and 3:4 after framebuffer rotation.
wire [11:0] scale_aspect_x = (aspect == 0)
    ? (rotation_active ? 12'd3 : 12'd4)
    : {10'd0, aspect - 1'b1};
wire [11:0] scale_aspect_y = (aspect == 0)
    ? (rotation_active ? 12'd4 : 12'd3)
    : 12'd0;

// Keep the established modes and expose the upstream best-fit HV-integer mode
// explicitly for users who want it. Integer (Horizontal) remains the existing
// best-fit path; HV-Integer is the same upstream mode as a named option.
logic [2:0] scale_mode;
always_comb begin
    case (scale_select)
        2'd1: scale_mode = 3'd4;
        2'd2: scale_mode = 3'd1;
        2'd3: scale_mode = 3'd4;
        default: scale_mode = 3'd0;
    endcase
end
wire rotate_ddram_clk, rotate_ddram_we, rotate_ddram_rd;
wire [7:0] rotate_ddram_burstcnt;
wire [28:0] rotate_ddram_addr;
wire [63:0] rotate_ddram_din;
wire [7:0] rotate_ddram_be;

screen_rotate u_screen_rotate (
    .CLK_VIDEO(CLK_VIDEO), .CE_PIXEL(CE_PIXEL),
    .VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
    .VGA_HS(VGA_HS), .VGA_VS(VGA_VS), .VGA_DE(vga_de_in),
    .rotate_ccw(rotation == 2'd2),
    .no_rotate((rotation == 2'd0) || (rotation == 2'd3)),
    .flip(rotation == 2'd3),
    .video_rotated(video_rotated),
    .FB_EN(FB_EN), .FB_FORMAT(FB_FORMAT), .FB_WIDTH(FB_WIDTH),
    .FB_HEIGHT(FB_HEIGHT), .FB_BASE(FB_BASE), .FB_STRIDE(FB_STRIDE),
    .FB_VBL(FB_VBL), .FB_LL(FB_LL),
    .DDRAM_CLK(rotate_ddram_clk), .DDRAM_BUSY(DDRAM_BUSY),
    .DDRAM_BURSTCNT(rotate_ddram_burstcnt), .DDRAM_ADDR(rotate_ddram_addr),
    .DDRAM_DIN(rotate_ddram_din), .DDRAM_BE(rotate_ddram_be),
    .DDRAM_WE(rotate_ddram_we), .DDRAM_RD(rotate_ddram_rd)
);

// Keep the entire screen_rotate write bundle in its producer domain. Driving
// clk_ram here advertised unrelated sampling edges for clk_sys-owned payload.
assign DDRAM_CLK      = rotate_ddram_clk;
assign DDRAM_BURSTCNT = rotate_ddram_burstcnt;
assign DDRAM_ADDR     = rotate_ddram_addr;
assign DDRAM_DIN      = rotate_ddram_din;
assign DDRAM_BE       = rotate_ddram_be;
assign DDRAM_WE       = rotate_ddram_we;
assign DDRAM_RD       = rotate_ddram_rd;

video_freak u_video_freak (
    .CLK_VIDEO(CLK_VIDEO), .CE_PIXEL(CE_PIXEL), .VGA_VS(VGA_VS),
    .HDMI_WIDTH(HDMI_WIDTH), .HDMI_HEIGHT(HDMI_HEIGHT),
    .VGA_DE(VGA_DE), .VIDEO_ARX(VIDEO_ARX), .VIDEO_ARY(VIDEO_ARY),
    .VGA_DE_IN(vga_de_in),
    .ARX(scale_aspect_x), .ARY(scale_aspect_y),
    .CROP_SIZE(12'd0), .CROP_OFF(5'd0),
    .SCALE(scale_mode)
);

assign AUDIO_L = game_pause ? 16'd0 : core_audio_l;
assign AUDIO_R = game_pause ? 16'd0 : core_audio_r;
assign AUDIO_MIX = status[47:46];

// {override, activity}: make a renderer deadline/cache overflow visible on
// hardware even though debug_status itself is simulation-only.
assign LED_DISK = {1'b1, renderer_overrun};

wire unused_inputs = &{1'b0, CLK_AUDIO, SD_MISO,
                       SD_CD, UART_CTS, UART_RXD, UART_DSR, USER_IN,
                       DDRAM_BUSY, DDRAM_DOUT,
                       DDRAM_DOUT_READY, clk_aux};

endmodule
