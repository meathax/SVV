`timescale 1ns/1ps

module tb_ssv_realrom_boot;
logic clk_sys = 0;
always #5 clk_sys = ~clk_sys;
logic rst, ce_cpu;
logic [1:0] ce_div;
logic sdr_p0_req, sdr_p0_ack;
logic [24:1] sdr_p0_addr;
logic [15:0] sdr_p0_dout;
logic sdr_p1_req, sdr_p1_ack;
logic [24:3] sdr_p1_addr;
logic [63:0] sdr_p1_dout;

logic sdr_wr_req, sdr_wr_ack;
logic [24:1] sdr_wr_addr;
logic [15:0] sdr_wr_din;
logic [1:0] sdr_wr_be;
logic [23:0] rgb;
logic ce_pixel, hs, vs, hb, vb;
logic signed [15:0] audio_l, audio_r;
logic [31:0] debug_pc;
logic [23:0] debug_status;
byte rom_bytes [0:1048575];
string rom_path;
integer fd, read_count, cycles;
logic p0_seen;
logic [1:0] ack_hold;
logic [31:0] first_changed_pc;
logic booted;

ssv_core dut (
    .clk_sys(clk_sys), .rst(rst), .ce_cpu(ce_cpu),
    .sdr_p0_req(sdr_p0_req), .sdr_p0_addr(sdr_p0_addr),
    .sdr_p0_dout(sdr_p0_dout), .sdr_p0_ack(sdr_p0_ack),
    .sdr_p1_req(sdr_p1_req), .sdr_p1_addr(sdr_p1_addr),
    .sdr_p1_dout(sdr_p1_dout), .sdr_p1_ack(sdr_p1_ack),
    .sdr_wr_req(sdr_wr_req), .sdr_wr_addr(sdr_wr_addr),
    .sdr_wr_din(sdr_wr_din), .sdr_wr_be(sdr_wr_be),
    .sdr_wr_ack(sdr_wr_ack),
    .in_dsw1(16'hffff), .in_dsw2(16'hfffd),
    .in_p1(16'hffff), .in_p2(16'hffff),
    .in_system(16'hffff), .in_extra(16'hffff),
    .rgb(rgb), .ce_pixel(ce_pixel), .hs(hs), .vs(vs), .hb(hb), .vb(vb),
    .audio_l(audio_l), .audio_r(audio_r),
    .debug_pc(debug_pc), .debug_status(debug_status)
);

always_ff @(posedge clk_sys) begin
    if (rst) begin
        ce_div <= 0;
        ce_cpu <= 0;
    end
    else begin
        ce_cpu <= (ce_div == 2);
        ce_div <= (ce_div == 2) ? 0 : ce_div + 1'd1;
    end
end

always_ff @(posedge clk_sys) begin
    sdr_p0_ack <= 0;
    sdr_p1_ack <= 0;
    sdr_p1_dout <= 64'd0;
    sdr_wr_ack <= 0;
    if (rst) begin
        p0_seen <= 0;
        ack_hold <= 0;
    end
    else begin
        if (sdr_p0_req && !p0_seen) begin
            p0_seen <= 1;
            sdr_p0_dout <= {
                rom_bytes[{sdr_p0_addr[19:1], 1'b0} + 1],
                rom_bytes[{sdr_p0_addr[19:1], 1'b0}]
            };
            ack_hold <= 2;
        end
        if (!sdr_p0_req) p0_seen <= 0;
        if (ack_hold != 0) begin
            sdr_p0_ack <= 1;
            ack_hold <= ack_hold - 1'd1;
        end
        if (sdr_wr_req) sdr_wr_ack <= 1;
    end
end

initial begin
    if (!$value$plusargs("ROM=%s", rom_path))
        rom_path = "sim_output/rom/maincpu.bin";
    fd = $fopen(rom_path, "rb");
    if (fd == 0) $fatal(1, "cannot open ROM image: %s", rom_path);
    read_count = $fread(rom_bytes, fd);
    $fclose(fd);
    if (read_count != 1048576)
        $fatal(1, "short ROM read: %0d", read_count);

    rst = 1;
    repeat (8) @(posedge clk_sys);
    rst = 0;
    first_changed_pc = 0;
    booted = 0;
    cycles = 0;
    while (!booted && cycles < 200000) begin
        @(posedge clk_sys);
        cycles = cycles + 1;
        if (debug_pc != 32'hfffffff0 && debug_pc != 0 && first_changed_pc == 0)
            first_changed_pc = debug_pc;
        if (debug_pc[31:24] == 8'h00 && debug_pc != 0)
            booted = 1;
    end
    if (!booted)
        $fatal(1, "V60 did not leave reset ROM window: pc=%08x first=%08x status=%06x",
               debug_pc, first_changed_pc, debug_status);
    $display("PASS tb_ssv_realrom_boot pc=%08x first=%08x cycles=%0d",
             debug_pc, first_changed_pc, cycles);
    $finish;
end
endmodule
