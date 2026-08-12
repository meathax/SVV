`timescale 1ns/1ps

// Hardware-only integration coverage for descriptor-selected external memory
// and the ST010 daughterboard as wired through the real ssv_core bus mux.
module tb_ssv_core_memory_windows;
import ssv_pkg::*;

logic clk_sys = 0;
always #5 clk_sys = ~clk_sys;
logic rst = 1;
ssv_cfg_t cfg;

logic sdr_p0_req, sdr_p0_ack = 0;
logic [SDR_AW:1] sdr_p0_addr;
logic [15:0] sdr_p0_dout = 16'h5a3c;
logic sdr_p2_req, sdr_p2_ack = 0;
logic [SDR_AW:4] sdr_p2_addr;
logic [127:0] sdr_p2_dout = 0;
logic sdr_wr_req, sdr_wr_ack = 0;
logic [SDR_AW:1] sdr_wr_addr;
logic [15:0] sdr_wr_din;
logic [1:0] sdr_wr_be;
logic sdr_p4_req, sdr_p4_ack = 0;
logic [SDR_AW:1] sdr_p4_addr;
logic [15:0] sdr_p4_dout = 0;
logic sdr_p5_req, sdr_p5_ack = 0;
logic [SDR_AW:3] sdr_p5_addr;
logic [63:0] sdr_p5_dout = 0;
logic p5_seen;
logic [23:0] rgb;
logic ce_pixel, ce_pix_x2, hs, vs, hb, vb;
logic signed [15:0] audio_l, audio_r;

ssv_core dut (
    .cfg(cfg), .clk_sys(clk_sys), .rst(rst), .cold_rst(rst),
    .ce_cpu(1'b1), .watchdog_hold(1'b0),
    .sdr_p0_req(sdr_p0_req), .sdr_p0_addr(sdr_p0_addr),
    .sdr_p0_dout(sdr_p0_dout), .sdr_p0_ack(sdr_p0_ack),
    .sdr_p2_req(sdr_p2_req), .sdr_p2_addr(sdr_p2_addr),
    .sdr_p2_dout(sdr_p2_dout), .sdr_p2_ack(sdr_p2_ack),
    .sdr_wr_req(sdr_wr_req), .sdr_wr_addr(sdr_wr_addr),
    .sdr_wr_din(sdr_wr_din), .sdr_wr_be(sdr_wr_be),
    .sdr_wr_ack(sdr_wr_ack),
    .sdr_p4_req(sdr_p4_req), .sdr_p4_addr(sdr_p4_addr),
    .sdr_p4_dout(sdr_p4_dout), .sdr_p4_ack(sdr_p4_ack),
    .sdr_p5_req(sdr_p5_req), .sdr_p5_addr(sdr_p5_addr),
    .sdr_p5_dout(sdr_p5_dout), .sdr_p5_ack(sdr_p5_ack),
    .st010_drom_we(1'b0), .st010_drom_wa('0), .st010_drom_wd('0),
    .in_dsw1(16'hffff), .in_dsw2(16'hffff),
    .in_p1(16'hffff), .in_p2(16'hffff), .in_system(16'hffff),
    .in_extra(16'hffff), .in_mahjong_rows(24'hffffff),
    .in_coord_x(12'h800), .in_coord_y(12'h800),
    .in_paddle(8'h80), .in_ball_switch(1'b0),
    .hs_addr('0), .hs_din('0), .hs_be('0), .hs_we(1'b0),
    .rgb(rgb), .ce_pixel(ce_pixel), .ce_pix_x2(ce_pix_x2),
    .hs(hs), .vs(vs), .hb(hb), .vb(vb),
    .audio_l(audio_l), .audio_r(audio_r)
);

task automatic bus_begin(input logic [23:0] addr, input logic we,
                         input logic [15:0] data, input logic [1:0] be);
begin
    force dut.m_req = 1'b1;
    force dut.m_we = we;
    force dut.m_addr = addr[23:1];
    force dut.m_wdata = data;
    force dut.m_be = be;
end
endtask

task automatic bus_end;
begin
    force dut.m_req = 1'b0;
    @(posedge clk_sys);
    release dut.m_req;
    release dut.m_we;
    release dut.m_addr;
    release dut.m_wdata;
    release dut.m_be;
    repeat (3) @(posedge clk_sys);
end
endtask

task automatic ext_write(input logic [23:0] addr,
                         input logic [SDR_AW:0] phys,
                         input logic [15:0] data, input logic [1:0] be);
    integer n;
begin
    bus_begin(addr, 1'b1, data, be);
    for (n = 0; n < 12 && !sdr_wr_req; n++) @(posedge clk_sys);
    if (!sdr_wr_req) $fatal(1, "no external write for %h", addr);
    if (sdr_wr_addr !== phys[SDR_AW:1] || sdr_wr_din !== data || sdr_wr_be !== be)
        $fatal(1, "write mismatch cpu=%h addr=%h/%h data=%h be=%b",
               addr, sdr_wr_addr, phys[SDR_AW:1], sdr_wr_din, sdr_wr_be);
    sdr_wr_ack = 1'b1;
    @(posedge clk_sys);
    sdr_wr_ack = 1'b0;
    for (n = 0; n < 12 && !dut.m_ack; n++) @(posedge clk_sys);
    if (!dut.m_ack) $fatal(1, "external write did not ack for %h", addr);
    bus_end();
end
endtask

task automatic ext_read(input logic [23:0] addr,
                        input logic [SDR_AW:0] phys);
    integer n;
begin
    bus_begin(addr, 1'b0, 16'h0, 2'b11);
    for (n = 0; n < 12 && !sdr_p0_req; n++) @(posedge clk_sys);
    if (!sdr_p0_req) $fatal(1, "no external read for %h", addr);
    if (sdr_p0_addr !== phys[SDR_AW:1])
        $fatal(1, "read address mismatch cpu=%h addr=%h expected=%h",
               addr, sdr_p0_addr, phys[SDR_AW:1]);
    sdr_p0_ack = 1'b1;
    @(posedge clk_sys);
    sdr_p0_ack = 1'b0;
    for (n = 0; n < 12 && !dut.m_ack; n++) @(posedge clk_sys);
    if (!dut.m_ack || dut.m_rdata !== sdr_p0_dout)
        $fatal(1, "external read result mismatch cpu=%h ack=%b data=%h",
               addr, dut.m_ack, dut.m_rdata);
    bus_end();
end
endtask

task automatic expect_absent(input logic [23:0] addr);
    integer n;
begin
    bus_begin(addr, 1'b0, 16'h0, 2'b11);
    for (n = 0; n < 6; n++) begin
        @(posedge clk_sys);
        if (sdr_p0_req || sdr_wr_req)
            $fatal(1, "disabled/outside window generated SDRAM request at %h", addr);
    end
    bus_end();
end
endtask

task automatic st010_write(input logic [23:0] addr,
                           input logic [15:0] data, input logic [1:0] be);
    integer n;
begin
    bus_begin(addr, 1'b1, data, be);
    for (n = 0; n < 8 && !dut.m_ack; n++) @(posedge clk_sys);
    if (!dut.m_ack) $fatal(1, "ST010 write did not ack at %h", addr);
    bus_end();
end
endtask

task automatic st010_read(input logic [23:0] addr,
                          input logic [15:0] expected);
    integer n;
begin
    bus_begin(addr, 1'b0, 16'h0, 2'b11);
    for (n = 0; n < 12 && !dut.m_ack; n++) @(posedge clk_sys);
    if (!dut.m_ack || dut.m_rdata !== expected)
        $fatal(1, "ST010 read mismatch at %h got=%h expected=%h",
               addr, dut.m_rdata, expected);
    bus_end();
end
endtask

initial begin
    cfg = cfg_dynagear();
    force dut.if_req = 1'b0;
    repeat (5) @(posedge clk_sys);
    rst = 0;
    repeat (5) @(posedge clk_sys);

    // Disabled profiles must not claim any optional external-memory window.
    cfg.extra_ram_mode = 0;
    cfg.has_nvram = 0;
    cfg.nvram_mode = 0;
    expect_absent(24'h400000);
    expect_absent(24'h010000);
    expect_absent(24'h580000);

    // Mode 1: $400000-$43ffff -> SDR_CPU_RAM_BASE.
    cfg.extra_ram_mode = 1;
    ext_write(24'h400000, SDR_CPU_RAM_BASE, 16'ha55a, 2'b01);
    ext_write(24'h43fffe, SDR_CPU_RAM_BASE + 27'h3fffe, 16'h3cc3, 2'b10);
    expect_absent(24'h440000);

    // Mode 2: $010000-$03ffff -> the same physical RAM base.
    cfg.extra_ram_mode = 2;
    ext_read(24'h010000, SDR_CPU_RAM_BASE);
    ext_write(24'h03fffe, SDR_CPU_RAM_BASE + 27'h2fffe, 16'hc35a, 2'b11);
    expect_absent(24'h040000);

    // Battery RAM modes: 2 KiB and 64 KiB, both based at $580000.
    cfg.extra_ram_mode = 0;
    cfg.has_nvram = 1;
    cfg.nvram_mode = 1;
    ext_read(24'h580000, SDR_NVRAM_BASE);
    ext_write(24'h5807fe, SDR_NVRAM_BASE + 27'h7fe, 16'h55aa, 2'b01);
    expect_absent(24'h580800);
    cfg.nvram_mode = 2;
    ext_write(24'h58fffe, SDR_NVRAM_BASE + 27'hfffe, 16'h9669, 2'b10);
    expect_absent(24'h590000);
    cfg.has_nvram = 0;
    expect_absent(24'h580000);

    // ST010 absent: no decode ownership and no program-fetch traffic.
    cfg.has_st010 = 0;
    expect_absent(24'h482000);
    force dut.st010_prg_req = 1'b1;
    force dut.st010_prg_addr = 14'h0000;
    repeat (8) begin
        @(posedge clk_sys);
        if (sdr_p5_req) $fatal(1, "disabled ST010 raised p5 request");
    end

    // ST010 host RAM is an 8-bit low-lane window. A[1] selects byte within
    // one DSP word; a high-lane-only write must be ignored.
    cfg.has_st010 = 1;
    st010_write(24'h482000, 16'h00aa, 2'b01);
    st010_write(24'h482002, 16'h00bb, 2'b01);
    st010_read(24'h482000, 16'h00aa);
    st010_read(24'h482002, 16'h00bb);
    st010_write(24'h482000, 16'hcc00, 2'b10);
    st010_read(24'h482000, 16'h00aa);

    // Exercise the exact DSP-request -> integrated fetcher -> p5 route. The
    // uPD96050 ISA/fetch sequencing itself has a separate exhaustive bench;
    // forcing its request here isolates the core-level gate and wiring.
    p5_seen = 1'b0;
    repeat (20) begin
        @(posedge clk_sys);
        if (sdr_p5_req && !p5_seen) begin
            if (sdr_p5_addr !== SDR_ST010_BASE[SDR_AW:3])
                $fatal(1, "first ST010 p5 address mismatch got=%h expected=%h",
                       sdr_p5_addr, SDR_ST010_BASE[SDR_AW:3]);
            sdr_p5_ack = 1'b1;
            @(posedge clk_sys);
            sdr_p5_ack = 1'b0;
            release dut.st010_prg_req;
            release dut.st010_prg_addr;
            p5_seen = 1'b1;
        end
    end
    if (!p5_seen)
        $fatal(1, "enabled ST010 never requested program fetch on p5");
    $display("PASS tb_ssv_core_memory_windows external_windows=1 st010=1");
    $finish;
end

endmodule
