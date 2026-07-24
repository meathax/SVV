`timescale 1ns/1ps

module tb_ssv_gfx_row_fetch;
logic clk = 1'b0;
always #5 clk = ~clk;

logic rst, start;
logic [19:0] tile_code;
logic [2:0] tile_row;
logic rom_req;
logic [24:3] rom_addr;
logic [63:0] rom_data;
logic rom_ack;
logic busy, done;
logic [31:0] plane01, plane23, plane45, plane67;

ssv_gfx_row_fetch dut (.*);

logic req_d;
integer delay_count;
integer transaction;
logic [24:3] expected [0:1];

always_ff @(posedge clk) begin
    req_d <= rom_req;
    rom_ack <= 1'b0;
    if (rom_req && !req_d) begin
        if (rom_addr !== expected[transaction]) begin
            $error("address %0d got %h expected %h",
                   transaction, rom_addr, expected[transaction]);
            $fatal(1);
        end
        delay_count <= 2;
    end
    if (delay_count > 0) begin
        delay_count <= delay_count - 1;
        if (delay_count == 1) begin
            rom_data <= {
                32'hd0000000 | transaction,
                32'ha0000000 | transaction
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

    expected[0] = 22'h020013;
    expected[1] = 22'h120009;

    repeat (3) @(posedge clk);
    rst <= 1'b0;
    pulse_start();

    wait (done);
    #1;
    if (plane01 !== 32'ha0000000 ||
        plane23 !== 32'hd0000000 ||
        plane45 !== 32'hd0000001 ||
        plane67 !== 32'd0) begin
        $error("packed plane extraction failed");
        $fatal(1);
    end
    if (transaction != 2 || busy) begin
        $error("transaction count/busy mismatch");
        $fatal(1);
    end

    $display("PASS tb_ssv_gfx_row_fetch");
    $finish;
end
endmodule
