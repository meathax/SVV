`timescale 1ns/1ps
module tb_ssv_gdfs_devices;
logic clk=0,rst=1; always #5 clk=~clk;
logic [2:0] channel; logic start; logic [7:0] adc_data; logic eoc,busy;
logic cs,sk,di,edo;
logic reg_we; logic [6:0] reg_addr; logic [15:0] reg_wdata,reg_rdata;
logic [1:0] reg_be,bank; logic blit_start,blit_valid;
logic [31:0] blit_src,blit_dst,blit_len;
ssv_adc0809 adc(.clk,.rst,.conversion_cycles(8'd3),.channel,.start,
 .ch0(8'h12),.ch1(8'h34),.ch2(8'h56),.ch3(8'h78),.data(adc_data),
 .eoc_pulse(eoc),.busy);
ssv_93c46_16 ee(.clk,.rst,.cs,.sk,.di,.dout(edo));
ssv_st0020_ctrl st(.clk,.rst,.reg_we,.reg_addr,.reg_wdata,.reg_be,
 .reg_rdata,.gfx_bank(bank),.blit_start,.blit_src,.blit_dst,.blit_len,
 .blit_valid);
task wr(input [6:0] a,input [15:0] d);
begin @(negedge clk);reg_addr=a;reg_wdata=d;reg_be=2'b11;reg_we=1;
 @(negedge clk);reg_we=0; end endtask
task ee_bit(input logic value);
begin
 @(negedge clk); di=value; sk=1;
 @(negedge clk); sk=0;
end endtask
task ee_cmd(input logic [1:0] opcode,input logic [5:0] addr);
begin
 cs=1;
 ee_bit(1'b1); ee_bit(opcode[1]); ee_bit(opcode[0]);
 for(integer b=5;b>=0;b=b-1) ee_bit(addr[b]);
end endtask
task ee_end;
begin @(negedge clk);cs=0;sk=0;di=0;@(negedge clk); end endtask
task ee_read(input logic [5:0] addr,output logic [15:0] value);
begin
 ee_cmd(2'b10,addr);
 // READ presents D15 on the command's ninth rising edge, then advances one
 // bit on each following rising edge.
 value[15]=edo;
 for(integer b=14;b>=0;b=b-1) begin ee_bit(1'b0); value[b]=edo; end
 ee_end();
end endtask
task ee_write(input logic [5:0] addr,input logic [15:0] value);
begin
 ee_cmd(2'b01,addr);
 for(integer b=15;b>=0;b=b-1) ee_bit(value[b]);
 ee_end();
end endtask
initial begin
 logic [15:0] ee_value;
 channel=0;start=0;cs=0;sk=0;di=0;reg_we=0;reg_addr=0;reg_wdata=0;reg_be=0;
 repeat(2) @(negedge clk);rst=0;
 // Reset erases all 64 words over one RAM write per clock. Commands driven
 // during that interval are ignored and DOUT stays at the idle high level.
 cs=1; sk=1; di=0;
 repeat(64) begin @(negedge clk); if(edo!==1'b1)$fatal(1,"EEPROM not idle during reset erase"); end
 cs=0; sk=0; @(negedge clk);
 ee_read(6'h15,ee_value);
 if(ee_value!==16'hffff)$fatal(1,"EEPROM reset erased state mismatch");
 // EWEN, WRITE, READ, ERASE, then EWDS and prove a disabled WRITE is ignored.
 ee_cmd(2'b00,6'b110000); ee_end();
 ee_write(6'h15,16'ha596);
 ee_read(6'h15,ee_value);
 if(ee_value!==16'ha596)$fatal(1,"EEPROM write/read or serial bit timing mismatch");
 ee_cmd(2'b11,6'h15); ee_end();
 ee_read(6'h15,ee_value);
 if(ee_value!==16'hffff)$fatal(1,"EEPROM erase mismatch");
 ee_cmd(2'b00,6'b000000); ee_end();
 ee_write(6'h15,16'h1234);
 ee_read(6'h15,ee_value);
 if(ee_value!==16'hffff)$fatal(1,"EEPROM EWDS did not inhibit write");
 channel=2; start=1; @(negedge clk); start=0;
 wait(eoc); if(adc_data!==8'h56)$fatal(1,"ADC channel/sample mismatch");
 wr(7'h45,16'h0007); if(bank!==2'd3)$fatal(1,"bank must clamp data&3");
 wr(7'h60,16'h0010); wr(7'h61,16'h0001);
 wr(7'h62,16'h0020); wr(7'h63,16'h0000); wr(7'h64,16'h0003);
 wr(7'h65,16'h0001);
 if(!blit_start || !blit_valid)$fatal(1,"valid blit not observed");
 if(blit_src!==32'h00020020 || blit_dst!==32'h00000200 ||
    blit_len!==32'h00000030)$fatal(1,"blit unit conversion mismatch");
 wr(7'h61,16'h0080); wr(7'h65,16'h0001);
 if(blit_valid)$fatal(1,"out-of-range source accepted");
 if(reg_rdata!==0)$fatal(1,"MAME-profile status must read zero");
 $display("PASS tb_ssv_gdfs_devices"); $finish;
end
endmodule
