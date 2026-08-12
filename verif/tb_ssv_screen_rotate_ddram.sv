// Focused producer-boundary test for screen_rotate's MiSTer DDRAM bundle.
// An unrelated observer clock must never see payload movement without an
// intervening CLK_VIDEO producer edge. This is not a model of the HPS DDRAM
// consumer; it proves the exported packet and clock have one RTL owner.
`timescale 1ns/1ps

module tb_ssv_screen_rotate_ddram;
logic clk_video = 0, clk_observer = 0;
always #7 clk_video = ~clk_video;       // 71.43 MHz
always #5 clk_observer = ~clk_observer; // deliberately non-coincident

logic ce_pixel=1, hs=0, vs=0, de=0;
logic [7:0] r=0, g=0, b=0;
logic fb_vbl=0, fb_ll=0, busy=0;
wire video_rotated, fb_en;
wire [4:0] fb_format;
wire [11:0] fb_width, fb_height;
wire [31:0] fb_base;
wire [13:0] fb_stride;
wire ddram_clk, we, rd;
wire [7:0] burstcnt, be;
wire [28:0] addr;
wire [63:0] din;

screen_rotate dut(
 .CLK_VIDEO(clk_video),.CE_PIXEL(ce_pixel),
 .VGA_R(r),.VGA_G(g),.VGA_B(b),.VGA_HS(hs),.VGA_VS(vs),.VGA_DE(de),
 .rotate_ccw(1'b1),.no_rotate(1'b0),.flip(1'b0),.video_rotated,
 .FB_EN(fb_en),.FB_FORMAT(fb_format),.FB_WIDTH(fb_width),.FB_HEIGHT(fb_height),
 .FB_BASE(fb_base),.FB_STRIDE(fb_stride),.FB_VBL(fb_vbl),.FB_LL(fb_ll),
 .DDRAM_CLK(ddram_clk),.DDRAM_BUSY(busy),.DDRAM_BURSTCNT(burstcnt),
 .DDRAM_ADDR(addr),.DDRAM_DIN(din),.DDRAM_BE(be),.DDRAM_WE(we),.DDRAM_RD(rd));

int producer_epoch=0, observer_epoch=-1, packets=0;
logic [110:0] observed_payload;
wire [110:0] payload={burstcnt,addr,din,be,we,rd};

always @(posedge clk_video) producer_epoch <= producer_epoch+1;
always @(posedge clk_observer) begin
 #1;
 if(payload !== observed_payload) begin
  if(observer_epoch == producer_epoch)
   $fatal(1,"DDRAM payload changed without a CLK_VIDEO producer edge");
  observed_payload <= payload;
  observer_epoch <= producer_epoch;
 end
end

// Sample after the producer edge, when its registered packet is stable.
always @(negedge clk_video) begin
 if(ddram_clk !== clk_video) $fatal(1,"DDRAM_CLK is not CLK_VIDEO");
 if(rd !== 1'b0 || burstcnt !== 8'd1)
  $fatal(1,"invalid fixed DDRAM controls rd=%b burst=%0d",rd,burstcnt);
 if(we) begin
  packets++;
  if(din[63:32] !== din[31:0]) $fatal(1,"DDRAM data halves incoherent");
  if(be !== 8'h0f && be !== 8'hf0) $fatal(1,"DDRAM byte enable incoherent: %02x",be);
  if(addr[28:22] !== 7'b0010010) $fatal(1,"DDRAM address escaped framebuffer base");
 end
end

task automatic pixel(input [7:0] n);
 begin
  @(negedge clk_video); de=1; r=n; g=n^8'h55; b=n^8'haa;
  @(negedge clk_video); de=0;
 end
endtask

task automatic frame_pulse;
 begin
  // Supply a short active line so geometry/stride state is non-zero.
  pixel(8'h10); pixel(8'h11); pixel(8'h12); pixel(8'h13);
  @(negedge clk_video); vs=1;
  repeat(2) @(negedge clk_video);
  vs=0; repeat(2) @(negedge clk_video);
 end
endtask

initial begin
 observed_payload='x;
 repeat(4) @(negedge clk_video);
 // FB_EN is a three-frame synchronizer in screen_rotate.
 repeat(4) frame_pulse();
 if(!fb_en) $fatal(1,"screen_rotate framebuffer path did not enable");
 for(int i=0;i<24;i++) pixel(i[7:0]+8'h40);
 repeat(6) @(negedge clk_video);
 if(packets < 20) $fatal(1,"insufficient DDRAM write packets: %0d",packets);
 $display("PASS tb_ssv_screen_rotate_ddram packets=%0d noncoincident_clocks=1",packets);
 $finish;
end

initial begin #200000; $fatal(1,"TIMEOUT tb_ssv_screen_rotate_ddram"); end
endmodule
