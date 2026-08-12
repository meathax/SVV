// Bounded contention regression for rtl/mem/sdram.sv.
// Six simultaneously pending readers must be served in rotating order.  The
// write mailbox owns the bus while pending, after which read rotation resumes.
`timescale 1ns/1ps

module tb_ssv_sdram_fairness;
localparam real HALF_PERIOD = 5.176;
localparam int BOUND = 256;

logic clk = 0, init = 1;
always #(HALF_PERIOD) clk = ~clk;

wire [15:0] dq;
wire [12:0] a;
wire [1:0] ba;
wire dqml, dqmh, ncs, ncas, nras, nwe, cke, ready;
logic wr_req=0; logic [26:1] wr_addr='0; logic [15:0] wr_din='0; logic [1:0] wr_be=2'b11; wire wr_ack;
logic p0_req=0; logic [26:1] p0_addr='0; wire [15:0] p0_dout; wire p0_ack;
logic p1_req=0; logic [26:3] p1_addr='0; wire [63:0] p1_dout; wire p1_ack;
logic p2_req=0; logic [26:4] p2_addr='0; wire [127:0] p2_dout; wire p2_ack;
logic p3_req=0; logic [26:1] p3_addr='0; wire [15:0] p3_dout; wire p3_ack;
logic p4_req=0; logic [26:1] p4_addr='0; wire [15:0] p4_dout; wire p4_ack;
logic p5_req=0; logic [26:3] p5_addr='0; wire [63:0] p5_dout; wire p5_ack;

sdram dut(.*,.SDRAM_DQ(dq),.SDRAM_A(a),.SDRAM_BA(ba),.SDRAM_DQML(dqml),
 .SDRAM_DQMH(dqmh),.SDRAM_nCS(ncs),.SDRAM_nCAS(ncas),.SDRAM_nRAS(nras),
 .SDRAM_nWE(nwe),.SDRAM_CKE(cke));
ssv_sdram_chip #(.BANK_BITS(2),.ROW_BITS(13),.COL_BITS(9),.CHECK_OPEN_ROW(1)) mem(
 .clk,.SDRAM_DQ(dq),.SDRAM_A(a),.SDRAM_BA(ba),.SDRAM_DQML(dqml),
 .SDRAM_DQMH(dqmh),.SDRAM_nCS(ncs),.SDRAM_nCAS(ncas),.SDRAM_nRAS(nras),
 .SDRAM_nWE(nwe),.SDRAM_CKE(cke));

logic [6:0] ack, ack_d;
int count[0:6], order[0:31], norder;
function automatic [15:0] pat(input int word_addr);
 pat = 16'h4000 ^ word_addr[15:0];
endfunction
always_comb ack = {wr_ack,p5_ack,p4_ack,p3_ack,p2_ack,p1_ack,p0_ack};
always @(posedge clk) begin
 ack_d <= ack;
 for (int i=0;i<7;i++) if (ack[i] && !ack_d[i]) begin
  count[i] <= count[i]+1; order[norder] <= i; norder <= norder+1;
  case(i)
   0: if(p0_dout!==pat(16'h0000)) $fatal(1,"p0 data packet corrupt");
   1: for(int w=0;w<4;w++) if(p1_dout[w*16+:16]!==pat(16'h0200+w)) $fatal(1,"p1 lane %0d corrupt",w);
   2: for(int w=0;w<8;w++) if(p2_dout[w*16+:16]!==pat(16'h0400+w)) $fatal(1,"p2 lane %0d corrupt",w);
   3: if(p3_dout!==pat(16'h0180)) $fatal(1,"p3 data packet corrupt");
   4: if(p4_dout!==pat(16'h0200)) $fatal(1,"p4 data packet corrupt");
   5: for(int w=0;w<4;w++) if(p5_dout[w*16+:16]!==pat(16'h0600+w)) $fatal(1,"p5 lane %0d corrupt",w);
   default: ;
  endcase
 end
end

task automatic pulse_reads;
 begin
  @(negedge clk); {p5_req,p4_req,p3_req,p2_req,p1_req,p0_req}=6'b111111;
  @(negedge clk); {p5_req,p4_req,p3_req,p2_req,p1_req,p0_req}=0;
 end
endtask
task automatic await_reads(input int base, input int expected_count);
 int cycles;
 begin
  cycles=0;
  while (norder < base+6 && cycles < BOUND) begin @(negedge clk); cycles++; end
  if (norder != base+6) $fatal(1,"read starvation: %0d/6 completed in %0d cycles",norder-base,cycles);
  for (int i=0;i<6;i++) begin
   if (order[base+i] != i) $fatal(1,"rotation mismatch slot %0d got p%0d",i,order[base+i]);
   if (count[i] != expected_count) $fatal(1,"p%0d duplicate/lost ack count=%0d",i,count[i]);
  end
 end
endtask

initial begin
 ack_d=0; norder=0; for(int i=0;i<7;i++) count[i]=0;
 // Separate rows avoid aliasing; burst addresses are naturally aligned.
 p0_addr=26'h000000; p1_addr=24'h000080; p2_addr=23'h000080;
 p3_addr=26'h000180; p4_addr=26'h000200; p5_addr=24'h000180;
 for(int w=0;w<8;w++) begin
  mem.mem[16'h0000+w]=pat(16'h0000+w); mem.mem[16'h0180+w]=pat(16'h0180+w);
  mem.mem[16'h0200+w]=pat(16'h0200+w); mem.mem[16'h0400+w]=pat(16'h0400+w);
  mem.mem[16'h0600+w]=pat(16'h0600+w);
 end
 repeat(8) @(negedge clk); init=0; wait(ready); repeat(2) @(negedge clk);

 pulse_reads(); await_reads(0,1);

 // A simultaneously captured write must complete first. Reads are required to
 // resume only after that finite write; continuous writes are outside the
 // runtime contract because game logic is reset during download.
 @(negedge clk);
 wr_addr=26'h000300; wr_din=16'ha55a; wr_req=1;
 {p5_req,p4_req,p3_req,p2_req,p1_req,p0_req}=6'b111111;
 @(negedge clk); wr_req=0; {p5_req,p4_req,p3_req,p2_req,p1_req,p0_req}=0;
 repeat(2) @(negedge clk);
 if (norder != 6) $fatal(1,"read granted before pending write");
 begin int cycles=0; while(count[6]!=1 && cycles<BOUND) begin @(negedge clk);cycles++;end
  if(count[6]!=1) $fatal(1,"write did not complete within bound"); end
 await_reads(7,2);
 repeat(4) @(negedge clk);
 if(mem.mem[16'h0300]!==16'ha55a) $fatal(1,"write ack did not identify completed data packet");
 for(int i=0;i<7;i++) if(count[i] != (i==6 ? 1 : 2)) $fatal(1,"final ack count[%0d]=%0d",i,count[i]);
 $display("PASS tb_ssv_sdram_fairness bound=%0d order=p0,p1,p2,p3,p4,p5",BOUND);
 $finish;
end

initial begin #5000000; $fatal(1,"TIMEOUT tb_ssv_sdram_fairness"); end
endmodule
