// SPDX-License-Identifier: GPL-3.0-or-later
// ROM-free checks for row reuse, delayed acknowledgements, code wrapping,
// three/four-quarter data and reset/reload invalidation.
`timescale 1ns/1ps
module tb_ssv_gfx_row_fetch;
import ssv_pkg::*;
logic clk=0;always #5 clk=~clk;
logic rst=1,start=0,ack=0;
logic [19:0] code=0;
logic [2:0] row=0;
ssv_cfg_t cfg;
wire req,busy,done;
wire [SDR_AW:4] addr;
logic [127:0] data;
wire [31:0] p0,p1,p2,p3;
integer requests=0,cyc=0;
logic req_d=0;
always @(posedge clk) begin
 cyc<=cyc+1;req_d<=req;
 if(req&&!req_d) requests<=requests+1;
end
ssv_gfx_row_fetch dut(.clk(clk),.rst(rst),.cfg(cfg),.start(start),
 .tile_code(code),.tile_row(row),.rom_req(req),.rom_addr(addr),
 .rom_data(data),.rom_ack(ack),.busy(busy),.done(done),
 .plane01(p0),.plane23(p1),.plane45(p2),.plane67(p3));
task automatic fetch(input [19:0] c,input [2:0] r,input bit miss,input [127:0] value);
 integer before_count;
 begin
  @(negedge clk);code=c;row=r;start=1;before_count=requests;
  @(negedge clk);start=0;
  if(miss) begin
   if(!req||!busy||done) $fatal(1,"miss did not issue");
   repeat(13) begin
    @(negedge clk);
    if(!req||done) $fatal(1,"miss completed before acknowledgement");
   end
   data=value;ack=1;
   @(negedge clk);ack=0;
  end
  if(!done||busy||req) $fatal(1,"bad completion");
  if({p3,p2,p1,p0} !== ((cfg.gfx_quarters==4)?value:{32'd0,value[95:0]}))
    $fatal(1,"row data mismatch");
  @(negedge clk);
  if(requests-before_count != integer'(miss)) $fatal(1,"wrong request count");
 end
endtask
initial begin
 cfg=cfg_dynagear(); data=0;
 repeat(3) @(negedge clk);rst=0;
 fetch(20'h1234,3,1,128'h0123456789abcdef1122334455667788);
 fetch(20'h1234,3,0,128'h0123456789abcdef1122334455667788);
 // Code modulus aliases must refer to the same immutable ROM row.
 fetch(20'h21234,3,0,128'h0123456789abcdef1122334455667788);
 fetch(20'h1234,4,1,128'h9988776655443322abcdef0123456789);
 fetch(20'h1235,4,1,128'hfedcba98765432100011223344556677);
 cfg.gfx_quarters=4;
 fetch(20'h1235,4,1,128'hfedcba98765432100011223344556677);
 fetch(20'h1235,4,0,128'hfedcba98765432100011223344556677);
 // A reload may replace data at exactly the same address.
 @(negedge clk);rst=1;
 @(negedge clk);rst=0;
 fetch(20'h1235,4,1,128'h00112233445566778899aabbccddeeff);
 fetch(20'h1235,4,0,128'h00112233445566778899aabbccddeeff);
 cfg=cfg_ultrax();
 fetch(20'h14234,3,1,128'h12345678123456781234567812345678);
 fetch(20'h2c234,3,0,128'h12345678123456781234567812345678);
 cfg=cfg_survartsu();
 fetch(20'h2aaaa,5,1,128'hfedcba9876543210fedcba9876543210);
 fetch(20'h5aaaa,5,0,128'hfedcba9876543210fedcba9876543210);
 cfg=cfg_vasara();
 fetch(20'h23456,6,1,128'h112233445566778899aabbccddeeff00);
 fetch(20'h63456,6,0,128'h112233445566778899aabbccddeeff00);
 $display("ROW_REUSE_PASS requests=%0d",requests);$finish;
end
initial begin #100000;$fatal(1,"timeout");end
endmodule
