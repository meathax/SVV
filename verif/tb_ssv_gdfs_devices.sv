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
initial begin
 channel=0;start=0;cs=0;sk=0;di=0;reg_we=0;reg_addr=0;reg_wdata=0;reg_be=0;
 repeat(2) @(negedge clk);rst=0;
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
