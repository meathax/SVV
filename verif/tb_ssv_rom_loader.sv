`timescale 1ns/1ps

module tb_ssv_rom_loader;
logic clk = 0;
always #5 clk = ~clk;
logic rst, mem_ready, ioctl_download, ioctl_wr, sdr_wr_ack;
logic [7:0] ioctl_index, ioctl_dout;
logic [26:0] ioctl_addr;
logic ioctl_wait, sdr_wr_req, rom_loaded;
logic [24:1] sdr_wr_addr;
logic [15:0] sdr_wr_din;
logic [1:0] sdr_wr_be;
logic [26:0] download_max_addr;

ssv_rom_loader dut (.*);

task tick;
    @(posedge clk); #1;
endtask

task send_byte(input [26:0] addr, input [7:0] data);
    while (ioctl_wait) tick();
    ioctl_addr = addr;
    ioctl_dout = data;
    ioctl_wr = 1;
    tick();
    ioctl_wr = 0;
    tick();
endtask

initial begin
    rst = 1; mem_ready = 0; ioctl_download = 0; ioctl_index = 0;
    ioctl_wr = 0; ioctl_addr = 0; ioctl_dout = 0; sdr_wr_ack = 0;
    repeat (2) tick();
    rst = 0; mem_ready = 1; ioctl_download = 1;

    send_byte(0, 8'h34);
    send_byte(1, 8'h12);
    if (!sdr_wr_req || sdr_wr_addr !== 24'd0 ||
        sdr_wr_din !== 16'h1234 || sdr_wr_be !== 2'b11)
        $fatal(1, "first packed write mismatch");
    sdr_wr_ack = 1; tick();
    sdr_wr_ack = 0; tick();

    // Code 2, row 3 in MAME's Q0 and Q1 quarters must become the
    // low/high halves of one aligned 64-bit SDRAM word.
    send_byte(27'h010004c, 8'h11);
    send_byte(27'h010004d, 8'h22);
    if (!sdr_wr_req ||
        sdr_wr_addr !== (25'h0100098 >> 1) ||
        sdr_wr_din !== 16'h2211)
        $fatal(1, "Q0 packed-row address mismatch");
    sdr_wr_ack = 1; tick();
    sdr_wr_ack = 0; tick();

    send_byte(27'h050004c, 8'h33);
    send_byte(27'h050004d, 8'h44);
    if (!sdr_wr_req ||
        sdr_wr_addr !== (25'h010009c >> 1) ||
        sdr_wr_din !== 16'h4433)
        $fatal(1, "Q1 packed-row address mismatch");
    sdr_wr_ack = 1; tick();
    sdr_wr_ack = 0; tick();

    // Q2 remains in place so its two adjacent 32-bit rows share a second
    // aligned 64-bit read without increasing the 12 MiB graphics footprint.
    send_byte(27'h090004c, 8'h55);
    send_byte(27'h090004d, 8'h66);
    if (!sdr_wr_req ||
        sdr_wr_addr !== (25'h090004c >> 1) ||
        sdr_wr_din !== 16'h6655)
        $fatal(1, "Q2 native-row address mismatch");
    sdr_wr_ack = 1; tick();
    sdr_wr_ack = 0; tick();

    send_byte(27'h0d00000, 8'hcd);
    send_byte(27'h0d00001, 8'hab);
    if (!sdr_wr_req || sdr_wr_addr !== (25'h0d00000 >> 1) ||
        sdr_wr_din !== 16'habcd)
        $fatal(1, "sample-region write mismatch");
    sdr_wr_ack = 1; tick();
    sdr_wr_ack = 0; tick();

    ioctl_download = 0;
    tick();
    if (!rom_loaded) $fatal(1, "rom_loaded did not assert after drain");
    $display("PASS tb_ssv_rom_loader");
    $finish;
end
endmodule
