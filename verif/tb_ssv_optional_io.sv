`timescale 1ns/1ps
module tb_ssv_optional_io;
logic clk=0,rst=1,we=0; always #5 clk=~clk;
logic [7:0] ctl=0,d4701; logic [11:0] x=12'h123,y=12'habc;
logic [7:0] analog=8'ha5,cycles=8'd3; logic cs=1,sck=0,serial;
ssv_upd4701 a(.clk,.rst,.coord_x(x),.coord_y(y),.control_we(we),.control(ctl),.data(d4701));
ssv_upd7001 b(.clk,.rst,.analog,.cycles,.control_we(we),.cs_in(cs),.sck_in(sck),.eoc_so(serial));
task tick; @(posedge clk); #1; endtask
initial begin
    tick(); rst=0;
    ctl=8'h40; we=1; tick(); we=0; if(d4701!==8'h23)$fatal(1,"4701 X low");
    ctl=8'h60; we=1; tick(); we=0; if(d4701!==8'h01)$fatal(1,"4701 X high");
    ctl=8'h50; we=1; tick(); we=0; if(d4701!==8'hbc)$fatal(1,"4701 Y low");
    cs=0; we=1; tick(); we=0; cs=1; we=1; tick(); we=0;
    repeat(3) tick();
    cs=0; we=1; tick(); we=0; if(!serial)$fatal(1,"7001 first serial bit");
    sck=1; we=1; tick(); sck=0; tick(); we=0;
    if(serial)$fatal(1,"7001 shifted serial bit");
    $display("PASS tb_ssv_optional_io"); $finish;
end
endmodule
