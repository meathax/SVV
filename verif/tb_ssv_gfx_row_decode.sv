`timescale 1ns/1ps

module tb_ssv_gfx_row_decode;
logic [31:0] plane01, plane23, plane45, plane67;
logic [2:0] gfx_mode;
logic flip_x;
logic [127:0] pens;

ssv_gfx_row_decode dut (.*);

function automatic [7:0] pen(input integer index);
    pen = pens[index * 8 +: 8];
endfunction

task automatic check(input logic condition, input string message);
    if (!condition) begin
        $error("FAIL: %s", message);
        $fatal(1);
    end
endtask

initial begin
    // x0 has every plane set (ff); x1 has even-numbered planes set (55).
    // x8 has only planes 7 and 0 set (81).
    plane01 = 32'h008080c0;
    plane23 = 32'h000080c0;
    plane45 = 32'h000080c0;
    plane67 = 32'h800080c0;
    gfx_mode = 3'd7;
    flip_x = 1'b0;
    #1;

    check(pen(0) == 8'hff, "eight-plane x0 decode");
    check(pen(1) == 8'h55, "paired-plane x1 decode");
    check(pen(8) == 8'h81, "second byte-pair x8 decode");
    check(pen(2) == 8'h00 && pen(15) == 8'h00, "unset pixels stay transparent");

    gfx_mode = 3'd6;
    #1;
    check(pen(0) == 8'h3f && pen(8) == 8'h01, "six-bpp mask");

    gfx_mode = 3'd5;
    #1;
    check(pen(0) == 8'h0f && pen(1) == 8'h05 && pen(8) == 8'h08,
          "upper-nibble four-bpp mode");

    gfx_mode = 3'd7;
    flip_x = 1'b1;
    #1;
    check(pen(15) == 8'hff && pen(14) == 8'h55 && pen(7) == 8'h81,
          "horizontal flip reverses the decoded row");

    $display("PASS tb_ssv_gfx_row_decode");
    $finish;
end
endmodule
