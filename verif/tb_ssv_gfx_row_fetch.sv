`timescale 1ns/1ps
// One 16-pixel tile row now costs ONE 128-bit transaction, not two 64-bit
// ones. This bench asserts the transaction count, the record address and the
// plane extraction, because those three together are the entire contract
// between ssv_rom_loader's packing and ssv_gfx_row_decode's consumption.

module tb_ssv_gfx_row_fetch;
logic clk = 1'b0;
always #5 clk = ~clk;

logic rst, start;
logic [19:0] tile_code;
logic [2:0] tile_row;
logic rom_req;
logic [24:4] rom_addr;
logic [127:0] rom_data;
logic rom_ack;
logic busy, done;
logic [31:0] plane01, plane23, plane45, plane67;

ssv_gfx_row_fetch dut (.*);

logic req_d;
integer delay_count;
integer transaction;
logic [24:4] expected;

always_ff @(posedge clk) begin
    req_d <= rom_req;
    rom_ack <= 1'b0;
    if (rom_req && !req_d) begin
        if (rom_addr !== expected) begin
            $error("address %0d got %h expected %h",
                   transaction, rom_addr, expected);
            $fatal(1);
        end
        delay_count <= 2;
    end
    if (delay_count > 0) begin
        delay_count <= delay_count - 1;
        if (delay_count == 1) begin
            // Distinct per-quarter payload so a swapped slice is visible.
            rom_data <= {
                32'hf000_0000,   // quarter 3 -- never loaded on Dyna Gear
                32'hc000_0000,   // quarter 2 -> plane45
                32'hb000_0000,   // quarter 1 -> plane23
                32'ha000_0000    // quarter 0 -> plane01
            };
            rom_ack <= 1'b1;
            transaction <= transaction + 1;
        end
    end
end

task automatic pulse_start;
    begin
        @(posedge clk);
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;
    end
endtask

initial begin
    rst = 1'b1;
    start = 1'b0;
    tile_code = 20'h00002;
    tile_row = 3'd3;
    rom_data = '0;
    rom_ack = 1'b0;
    req_d = 1'b0;
    delay_count = 0;
    transaction = 0;

    // ssv_pkg::gfx_record_addr(2, 3)
    //   = 0x0100000 + (2 << 7) + (3 << 4) = 0x0100130, >> 4 = 0x10013.
    expected = 21'h10013;

    repeat (3) @(posedge clk);
    rst <= 1'b0;
    pulse_start();

    wait (done);
    #1;
    if (plane01 !== 32'ha000_0000 ||
        plane23 !== 32'hb000_0000 ||
        plane45 !== 32'hc000_0000 ||
        // Load-bearing: the loader never writes the quarter-3 slot, so the
        // fetcher must ignore rom_data[127:96] rather than forward it.
        plane67 !== 32'd0) begin
        $error("packed plane extraction failed %h %h %h %h",
               plane01, plane23, plane45, plane67);
        $fatal(1);
    end
    if (transaction != 1 || busy) begin
        $error("expected exactly one transaction, got %0d (busy=%b)",
               transaction, busy);
        $fatal(1);
    end

    $display("PASS tb_ssv_gfx_row_fetch transactions=%0d", transaction);
    $finish;
end
endmodule
