`timescale 1ns/1ps

module tb_ssv_mlab240_sdp;
    logic clk = 1'b0;
    logic [7:0] wr_addr = '0;
    logic we = 1'b0;
    logic [179:0] wdata = '0;
    logic [7:0] rd_addr = '0;
    logic [179:0] q;

    always #5 clk = ~clk;

    ssv_mlab240_sdp #(.WIDTH(180)) dut (
        .clk(clk), .wr_addr(wr_addr), .we(we), .wdata(wdata),
        .rd_addr(rd_addr), .q(q)
    );

    task automatic check(input logic [179:0] expected, input string label);
        if (q !== expected) begin
            $display("FAIL %s: got %h expected %h", label, q, expected);
            $fatal(1);
        end
    endtask

    initial begin
        // The registered read must return the old value on a same-address
        // write, then expose the written value on the following read.
        @(negedge clk);
        wr_addr = 8'd7;
        rd_addr = 8'd7;
        wdata = 180'h0123_4567_89ab_cdef_0011_2233_4455_6677_8899;
        we = 1'b1;
        @(posedge clk);
        #1;
        @(negedge clk);
        we = 1'b0;
        @(posedge clk);
        #1;
        check(180'h0123_4567_89ab_cdef_0011_2233_4455_6677_8899,
              "registered read after write");

        // A different address must not disturb the stored word.
        @(negedge clk);
        wr_addr = 8'd239;
        rd_addr = 8'd7;
        wdata = 180'h0fed_cba9_8765_4321_ffe0_ddcc_bbaa_9988_7766;
        we = 1'b1;
        @(posedge clk);
        #1;
        check(180'h0123_4567_89ab_cdef_0011_2233_4455_6677_8899,
              "independent address read");

        $display("tb_ssv_mlab240_sdp: PASS");
        $finish;
    end
endmodule
