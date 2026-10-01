`timescale 1ns/1ps
module tb_ssv_cache_restart;
import ssv_pkg::*;
logic clk=0;
always #5 clk=~clk;
logic rst=1, accepted=0, scroll_write=0, window_open=1, window_end=0;
wire restart;
ssv_cache_restart control (.clk(clk), .rst(rst), .write_accept(accepted),
    .scroll_write(scroll_write), .write_window(window_open),
    .write_window_end(window_end), .restart(restart));
logic cache_start=0;
ssv_cfg_t cfg;
logic [15:0] ram[0:8191];
logic [15:0] data, next_data;
wire [16:0] address;
logic [511:0] scrolls=0;
wire cache_busy, cache_ready, overflow;
always @(posedge clk) begin
    data <= ram[address[12:0]];
    next_data <= ram[(address|17'd1)&17'h1fff];
end
ssv_cached_sprite_renderer renderer (
    .clk(clk), .rst(rst), .cfg(cfg), .cache_start(cache_start),
    .cache_restart(restart), .cache_deadline(1'b0), .start(1'b0),
    .target_y(9'd0), .local_control(16'd0), .flip_control(16'd0),
    .coordinate_control(16'h5940), .global_y_base(16'd0),
    .global_y_adjust(16'd0), .sprite_offsets(256'd0),
    .tilemap_scrolls(scrolls), .shadow_4bit(1'b0),
    .spr_addr(address), .spr_data(data), .spr_data_next(next_data),
    .rom_req(), .rom_addr(), .rom_data(128'd0), .rom_ack(1'b0),
    .plot_we(), .plot_x(), .plot_color(), .plot_shadow(), .plot_pen(),
    .plot_shadow_4bit(), .cache_busy(cache_busy), .cache_ready(cache_ready),
    .cache_overflow(overflow), .busy(), .done());

task automatic store(input bit is_scroll, input bit expected_restart);
    @(negedge clk); accepted=1; scroll_write=is_scroll;
    #1;
    if(restart!==expected_restart) $fatal(1,"Unexpected restart scroll=%b expected=%b",is_scroll,expected_restart);
    @(negedge clk); accepted=0; scroll_write=0;
endtask

integer i, completed=0;
initial begin
    cfg=cfg_dynagear();
    for(i=0;i<8192;i=i+1)ram[i]=0;
    ram[0]=16'h6303; ram[1]=16'h0400;
    ram[5]=16'h8000;
    for(i=0;i<4;i=i+1) begin
        ram[4096+i*4]=1;
        ram[4096+i*4+3]=i*64;
    end
    scrolls[4*16+:16]=16'h0776;
    scrolls[5*16+:16]=16'hffdf;
    scrolls[6*16+:16]=16'h05ff;
    scrolls[7*16+:16]=16'h3629;
    repeat(5)@(negedge clk);rst=0;
    @(negedge clk);cache_start=1;
    @(negedge clk);cache_start=0;
    repeat(90)@(negedge clk);
    store(0,1); // Initial list invalidation; subsequent list stores coalesce.
    store(0,0);
    repeat(300)@(negedge clk);
    scrolls[4*16+:16]=16'h077a;
    store(1,1); // A scroll store must still invalidate after the first write.
    repeat(200)@(negedge clk);
    scrolls[5*16+:16]=16'hffe0;
    store(1,1); // Finish a multi-register update before publishing its cache.
    store(0,0);
    wait(cache_ready);@(negedge clk);
    if(overflow || renderer.cache_count!=4)$fatal(1,"Bad cache count or overflow");
    for(i=0;i<4;i=i+1)begin
        if(renderer.descriptor_cache[i][37:20]!=18'h0077a ||
           renderer.descriptor_cache[i][19:3]!=17'h0ffe2)
            $fatal(1,"Mixed scroll state at slice %0d",i);
    end
    completed=completed+1;

    // A completed small cache must be invalidated too; IDLE must accept it.
    scrolls[4*16+:16]=16'h077e;
    store(1,1);
    if(!cache_busy || cache_ready)$fatal(1,"Completed cache did not rebuild");
    if(renderer.line_pool_alloc!=0)$fatal(1,"Completed cache retained its line-entry allocation");
    wait(cache_ready);@(negedge clk);
    for(i=0;i<4;i=i+1)
        if(renderer.descriptor_cache[i][37:20]!=18'h0077e)
            $fatal(1,"Stale completed-cache slice %0d",i);
    completed=completed+1;

    window_open=0;
    store(1,0);store(0,0);
    window_end=1;@(negedge clk);window_end=0;window_open=1;
    store(0,1);store(0,0);
    completed=completed+1;
    $display("CACHE_RESTART_PASS cases=%0d",completed);
    $finish;
end
initial begin #2000000;$fatal(1,"Cache restart regression timed out");end
endmodule
