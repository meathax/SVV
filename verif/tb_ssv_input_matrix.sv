`timescale 1ns/1ps

// Directly verifies the same synthesizable cabinet-input block instantiated by
// Arcade-SSV.sv. No copied wrapper functions are used here.
module tb_ssv_input_matrix;

logic [31:0] joy_p1, joy_p2;
logic [3:0] input_layout;
logic system_input_mode;
logic [1:0] extra_input_mode;
logic test_button, service_button, coin1_button, coin2_button;
logic [15:0] p1_port, p2_port, system_port, extra_port;
integer fails;

ssv_input_ports dut (.*);

task automatic expect16(input string name, input [15:0] got, input [15:0] exp);
    if (got !== exp) begin
        $display("FAIL %s got=%04x exp=%04x", name, got, exp);
        fails++;
    end
endtask

task automatic settle;
    #1;
endtask

// DIP bytes are direct wrapper passthroughs and remain checked independently;
// they are not descriptor-selected cabinet transforms handled by the DUT.
function automatic logic [15:0] dsw_port(input logic [7:0] value);
    dsw_port = {8'hff, value};
endfunction

initial begin
    fails = 0;
    joy_p1 = '0; joy_p2 = '0;
    input_layout = 4'd0;
    system_input_mode = 1'b0;
    extra_input_mode = 2'd0;
    test_button = 1'b0; service_button = 1'b0;
    coin1_button = 1'b0; coin2_button = 1'b0;
    settle();

    expect16("P1 idle", p1_port, 16'hffff);
    expect16("P2 idle", p2_port, 16'hffff);

    joy_p1 = 32'h0000_0008; settle(); expect16("P1 UP", p1_port, 16'hff7f);
    joy_p1 = 32'h0000_0004; settle(); expect16("P1 DOWN", p1_port, 16'hffbf);
    joy_p1 = 32'h0000_0002; settle(); expect16("P1 LEFT", p1_port, 16'hffdf);
    joy_p1 = 32'h0000_0001; settle(); expect16("P1 RIGHT", p1_port, 16'hffef);
    joy_p1 = 32'h0000_0010; settle(); expect16("P1 B1", p1_port, 16'hfff7);
    joy_p1 = 32'h0000_0020; settle(); expect16("P1 B2", p1_port, 16'hfffb);
    joy_p1 = 32'h0000_0040; settle(); expect16("P1 B3", p1_port, 16'hfffd);
    joy_p1 = 32'h0000_1000; settle(); expect16("P1 START", p1_port, 16'hfffe);
    joy_p1 = 32'hffff_ffff; settle(); expect16("P1 all", p1_port, 16'hff00);

    // Quiz layout maps B1-B4 to bits 7:4 and retains START on bit 0.
    input_layout = 4'd2;
    joy_p1 = 32'h0000_0010; settle(); expect16("quiz B1", p1_port, 16'hff7f);
    joy_p1 = 32'h0000_0020; settle(); expect16("quiz B2", p1_port, 16'hffbf);
    joy_p1 = 32'h0000_0040; settle(); expect16("quiz B3", p1_port, 16'hffdf);
    joy_p1 = 32'h0000_0080; settle(); expect16("quiz B4", p1_port, 16'hffef);
    joy_p1 = 32'h0000_1000; settle(); expect16("quiz START", p1_port, 16'hfffe);
    input_layout = 4'd1;
    joy_p1 = 32'h0000_0001; settle(); expect16("unknown layout defaults normal", p1_port, 16'hffef);

    joy_p1 = 32'h0000_0380; joy_p2 = 32'h0000_0380;
    extra_input_mode = 2'd0; settle(); expect16("extra absent idle", extra_port, 16'hffff);
    extra_input_mode = 2'd1; settle(); expect16("extra decoded idle", extra_port, 16'hffff);
    extra_input_mode = 2'd2; settle(); expect16("extra six button", extra_port, 16'hff88);
    extra_input_mode = 2'd3; settle(); expect16("extra reserved idle", extra_port, 16'hffff);

    joy_p1 = '0; joy_p2 = '0;
    coin1_button = 1'b1; settle(); expect16("SYSTEM coin1", system_port, 16'hfffe);
    coin1_button = 1'b0; coin2_button = 1'b1; settle(); expect16("SYSTEM coin2", system_port, 16'hfffd);
    coin2_button = 1'b0; service_button = 1'b1; settle(); expect16("SYSTEM service", system_port, 16'hfffb);
    service_button = 1'b0; test_button = 1'b1; settle(); expect16("SYSTEM live test", system_port, 16'hffef);
    system_input_mode = 1'b1; settle(); expect16("SYSTEM fixed Test/Tilt high", system_port, 16'hffff);
    coin1_button = 1'b1; settle(); expect16("SYSTEM fixed mode preserves coin", system_port, 16'hfffe);

    expect16("DSW1 default", dsw_port(8'hff), 16'hffff);
    expect16("DSW2 default", dsw_port(8'hfd), 16'hfffd);
    for (int i = 0; i < 256; i++)
        expect16("DSW passthrough", dsw_port(i[7:0]), {8'hff, i[7:0]});

    if (fails != 0)
        $fatal(1, "input matrix failures=%0d", fails);
    $display("PASS tb_ssv_input_matrix direct_synth_block=1");
    $finish;
end

endmodule
