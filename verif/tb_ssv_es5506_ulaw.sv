`timescale 1ns/1ps
// Source-backed ES5506 compressed-sample decoder checks.
// Values below are from the exact equation in MAME es5506.cpp, not generic
// telephony u-law (the two formats are not interchangeable).

module tb_ssv_es5506_ulaw;
import ssv_pkg::*;

task automatic check_code(
    input logic [7:0] code,
    input logic signed [15:0] expected
);
    logic signed [15:0] actual;
    begin
        actual = es5506_ulaw_decode(code);
        if (actual !== expected)
            $fatal(1, "ES5506 u-law code %02x: got %0d expected %0d",
                   code, actual, expected);
    end
endtask

initial begin
    // Exponent-zero, positive full-scale, and the sign transition.
    check_code(8'h00, 16'sd8);
    check_code(8'h01, 16'sd24);
    check_code(8'h7f, 16'sd2016);
    check_code(8'h80, -16'sd4032);
    check_code(8'hfe, 16'sd31232);
    check_code(8'hff, 16'sd32256);

    // The table must be ordered through the sign transition and reach both
    // positive/negative rails used by the compressed ES5506 path.
    if (es5506_ulaw_decode(8'h7f) <= 0 ||
        es5506_ulaw_decode(8'h80) >= 0 ||
        es5506_ulaw_decode(8'hff) <= es5506_ulaw_decode(8'h7f))
        $fatal(1, "ES5506 u-law polarity/ordering mismatch");

    $display("PASS tb_ssv_es5506_ulaw: MAME equation samples");
    $finish;
end
endmodule
