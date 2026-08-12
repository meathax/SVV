`timescale 1ns/1ps
module tb_ssv_srmp7_bank;
logic clk = 0, cold_rst = 1, write = 0, data = 0, bank;
always #5 clk = ~clk;
ssv_srmp7_bank dut (.*);
initial begin
    repeat (2) @(posedge clk);
    cold_rst = 0;
    data = 1; write = 1; @(posedge clk); #1; write = 0;
    if (bank !== 1'b1) $fatal(1, "bank write 1 failed");
    data = 0; @(posedge clk); #1;
    if (bank !== 1'b1) $fatal(1, "bank changed without write");
    write = 1; @(posedge clk); #1;
    if (bank !== 1'b0) $fatal(1, "bank write 0 failed");
    $display("PASS tb_ssv_srmp7_bank");
    $finish;
end
endmodule
