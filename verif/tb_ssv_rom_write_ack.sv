`timescale 1ns/1ps
// ROM-region CPU writes must nop-ack. Before the fix, sel_rom && m_we waited
// forever on ext_done while never starting an SDRAM cycle (ext_busy stuck 0).

module tb_ssv_rom_write_ack;

// Layout comes from ssv_pkg, not a local copy: five benches used to
// restate 0x0100000/0x1100000/0x1160000 and a divergence between them and
// the RTL is the classic "wrong ROM load offset" fake bug.
import ssv_pkg::*;
logic clk_sys = 0;
always #5 clk_sys = ~clk_sys;
logic rst = 1;
logic ce_cpu = 1;
logic sdr_p0_req, sdr_p0_ack;
logic [SDR_AW:1] sdr_p0_addr;
logic [15:0] sdr_p0_dout;
logic sdr_p2_req, sdr_p2_ack;
logic [SDR_AW:4] sdr_p2_addr;
logic [127:0] sdr_p2_dout;
logic sdr_wr_req, sdr_wr_ack;
logic sdr_p4_req, sdr_p4_ack;
logic [SDR_AW:1] sdr_p4_addr;
logic [15:0] sdr_p4_dout;

logic [SDR_AW:1] sdr_wr_addr;
logic [15:0] sdr_wr_din;
logic [1:0] sdr_wr_be;
logic [23:0] rgb;
logic ce_pixel, hs, vs, hb, vb;
logic signed [15:0] audio_l, audio_r;
logic [31:0] debug_pc;
logic [23:0] debug_status;
integer cycles;

ssv_core dut (
    .cfg(ssv_pkg::cfg_dynagear()),
    .clk_sys(clk_sys), .rst(rst), .ce_cpu(ce_cpu),
    .sdr_p0_req(sdr_p0_req), .sdr_p0_addr(sdr_p0_addr),
    .sdr_p0_dout(sdr_p0_dout), .sdr_p0_ack(sdr_p0_ack),
    .sdr_p2_req(sdr_p2_req), .sdr_p2_addr(sdr_p2_addr),
    .sdr_p2_dout(sdr_p2_dout), .sdr_p2_ack(sdr_p2_ack),
    .sdr_wr_req(sdr_wr_req), .sdr_wr_addr(sdr_wr_addr),
    .sdr_wr_din(sdr_wr_din), .sdr_wr_be(sdr_wr_be),
    .sdr_wr_ack(sdr_wr_ack),
    .sdr_p4_req(sdr_p4_req), .sdr_p4_addr(sdr_p4_addr),
    .sdr_p4_dout(sdr_p4_dout), .sdr_p4_ack(sdr_p4_ack),
    .in_dsw1(16'hffff), .in_dsw2(16'hffff),
    .in_p1(16'hffff), .in_p2(16'hffff),
    .in_system(16'hffff), .in_extra(16'hffff),
    .rgb(rgb), .ce_pixel(ce_pixel), .hs(hs), .vs(vs), .hb(hb), .vb(vb),
    .audio_l(audio_l), .audio_r(audio_r),
    .debug_pc(debug_pc), .debug_status(debug_status)
);

always_ff @(posedge clk_sys) begin
    sdr_p0_ack <= sdr_p0_req;
    sdr_p2_ack <= sdr_p2_req;
    sdr_wr_ack <= sdr_wr_req;
    sdr_p0_dout <= 16'hffff;
    sdr_p2_dout <= 128'd0;
end

initial begin
    repeat (4) @(posedge clk_sys);
    rst = 0;
    repeat (4) @(posedge clk_sys);

    // Force a ROM write cycle on the memory bus.
    force dut.m_req = 1'b1;
    force dut.m_we = 1'b1;
    force dut.m_addr = 23'h780000; // byte 0xF00000
    force dut.m_wdata = 16'hA5A5;
    force dut.m_be = 2'b11;

    for (cycles = 0; cycles < 32; cycles = cycles + 1) begin
        @(posedge clk_sys);
        if (dut.m_ack)
            break;
    end
    release dut.m_req;
    release dut.m_we;
    release dut.m_addr;
    release dut.m_wdata;
    release dut.m_be;
    if (!dut.m_ack && (cycles >= 32))
        $fatal(1, "ROM write did not ack (ext_busy=%b ext_done=%b)",
               dut.ext_busy, dut.ext_done);
    $display("PASS tb_ssv_rom_write_ack acked in %0d cycles busy=%b",
             cycles, dut.ext_busy);
    $finish;
end
endmodule
