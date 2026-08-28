`timescale 1ns/1ps
/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */

module tb_ssv_cached_sprite_renderer;
logic clk = 1'b0;
always #5 clk = ~clk;

ssv_pkg::ssv_cfg_t cfg;
logic rst, cache_start, cache_restart, cache_deadline, start;
logic [8:0] target_y;
logic [15:0] local_control, flip_control, coordinate_control;
logic [15:0] global_y_base, global_y_adjust;
logic [255:0] sprite_offsets;
logic [511:0] tilemap_scrolls;
logic shadow_4bit;
logic [16:0] spr_addr;
logic [15:0] spr_data, spr_data_next;
logic rom_req;
logic [ssv_pkg::SDR_AW:4] rom_addr;
logic [127:0] rom_data;
logic rom_ack = 1'b0;
logic [3:0] plot_we;
logic [35:0] plot_x;
logic [59:0] plot_color;
logic plot_shadow;
logic [31:0] plot_pen;
logic plot_shadow_4bit;
logic cache_busy, cache_ready, cache_overflow, busy, done;

ssv_cached_sprite_renderer dut (.*);

logic [15:0] sprite_mem [0:131071];
always_ff @(posedge clk) begin
    spr_data <= sprite_mem[spr_addr];
    spr_data_next <= sprite_mem[spr_addr | 17'd1];
end
always @(negedge clk) rom_ack = rom_req;

integer i;
integer timeout;
integer render_cycles;
integer plot_cycles;
integer plot_writes;

task automatic clear_sprite_ram;
begin
    for (i = 0; i < 131072; i = i + 1)
        sprite_mem[i] = 16'd0;
end
endtask

task automatic pulse_cache_start;
begin
    @(negedge clk);
    cache_start = 1'b1;
    @(negedge clk);
    cache_start = 1'b0;
end
endtask

task automatic wait_cache;
begin
    timeout = 0;
    while (!cache_ready && timeout < 500000) begin
        @(negedge clk);
        timeout = timeout + 1;
    end
    if (!cache_ready || cache_busy)
        $fatal(1, "cache did not publish busy=%0b ready=%0b state=%0d",
               cache_busy, cache_ready, dut.state);
end
endtask

task automatic set_global(
    input integer global_index,
    input integer local_pointer
);
begin
    sprite_mem[global_index * 4 + 0] = 16'h6000;
    sprite_mem[global_index * 4 + 1] = local_pointer[15:0];
    sprite_mem[global_index * 4 + 2] = 16'd0;
    sprite_mem[global_index * 4 + 3] = 16'd0;
end
endtask

task automatic set_local(
    input integer local_pointer,
    input logic [15:0] x,
    input logic [15:0] y
);
integer address;
begin
    address = local_pointer * 4;
    sprite_mem[address + 0] = 16'd0;
    sprite_mem[address + 1] = 16'h0001;
    sprite_mem[address + 2] = x;
    sprite_mem[address + 3] = y;
end
endtask

initial begin
    cfg = ssv_pkg::cfg_dynagear();
    rst = 1'b1;
    cache_start = 1'b0;
    cache_restart = 1'b0;
    cache_deadline = 1'b0;
    start = 1'b0;
    target_y = 9'd20;
    local_control = 16'd0;
    flip_control = 16'd0;
    coordinate_control = 16'd0;
    global_y_base = 16'd0;
    global_y_adjust = 16'd0;
    sprite_offsets = '0;
    tilemap_scrolls = '0;
    shadow_4bit = 1'b0;
    rom_data = '0;
    clear_sprite_ram();

    repeat (4) @(negedge clk);
    rst = 1'b0;

    // Three one-tile objects exercise signed 10-bit Y coordinates and clip
    // at both screen edges: [-4,3], [20,27], and [238,245].
    set_global(0, 16'h0400);
    set_global(1, 16'h0401);
    set_global(2, 16'h0402);
    sprite_mem[3 * 4 + 1] = 16'h8000;
    set_local(16'h0400, 16'd10, 16'h03fb);
    set_local(16'h0401, 16'd20, 16'h03e3);
    set_local(16'h0402, 16'd30, 16'h0309);

    pulse_cache_start();
    wait_cache();
    if (cache_overflow || dut.cache_count != 3)
        $fatal(1, "edge fixture count=%0d overflow=%0b",
               dut.cache_count, cache_overflow);
    if (dut.line_meta[0][11:0] != 1 ||
        dut.line_meta[3][11:0] != 1 ||
        dut.line_meta[4][11:0] != 0 ||
        dut.line_meta[20][11:0] != 1 ||
        dut.line_meta[27][11:0] != 1 ||
        dut.line_meta[28][11:0] != 0 ||
        dut.line_meta[237][11:0] != 0 ||
        dut.line_meta[238][11:0] != 1 ||
        dut.line_meta[239][11:0] != 1)
        $fatal(1, "signed Y clipping or first/last-line bucket mismatch");

    // One opaque pixel in the first four-pixel group. The baseline renderer
    // visits all four groups even though three cannot assert plot_we.
    rom_data = 128'd0;
    rom_data[7] = 1'b1;
    render_cycles = 0;
    plot_cycles = 0;
    plot_writes = 0;
    @(negedge clk);
    start = 1'b1;
    @(negedge clk);
    start = 1'b0;
    while (!done && render_cycles < 1000) begin
        @(negedge clk);
        render_cycles = render_cycles + 1;
        if (dut.state == dut.PLOT)
            plot_cycles = plot_cycles + 1;
        if (plot_we != 0) begin
            plot_writes = plot_writes + plot_we[0] + plot_we[1] +
                          plot_we[2] + plot_we[3];
            if ((plot_we != 4'b0001) || (plot_x[8:0] != 9'd20) ||
                (plot_pen[7:0] != 8'd1))
                $fatal(1, "sparse plot mismatch we=%b x=%0d pen=%0d",
                       plot_we, plot_x[8:0], plot_pen[7:0]);
        end
    end
    if (!done || (plot_cycles != 1) || (plot_writes != 1))
        $fatal(1, "sparse plot cycles=%0d plot=%0d writes=%0d done=%0b",
               render_cycles, plot_cycles, plot_writes, done);
    rom_data = 128'd0;

    // The cache is the private per-frame snapshot. A CPU-side live RAM write
    // after publication must not alter the descriptor being displayed.
    sprite_mem[16'h0401 * 4 + 2] = 16'd200;
    if ($signed(dut.descriptor_cache[1][86:70]) != 17'sd20)
        $fatal(1, "published descriptor changed with live sprite RAM");

    // Fill the complete 2048-entry descriptor cache using 64 global entries
    // of 32 locals each. All objects cross the same eight lines, exercising
    // 16384 pooled line occurrences and the complete list order.
    clear_sprite_ram();
    for (i = 0; i < 64; i = i + 1) begin
        set_global(i, 16'h0400 + i * 32);
        sprite_mem[i * 4 + 0] = 16'h601f;
    end
    for (i = 0; i < 2048; i = i + 1) begin
        set_local(16'h0400 + i, (i < 128) ? i[15:0] : 16'd10,
                  16'h03e3);
        sprite_mem[(16'h0400 + i) * 4 + 0] = i[15:0];
    end
    sprite_mem[64 * 4 + 1] = 16'h8000;
    pulse_cache_start();
    wait_cache();
    if (cache_overflow || dut.cache_count != 2048 ||
        dut.line_meta[20][11:0] != 2048 ||
        dut.line_pool_alloc != 16384)
        $fatal(1, "dense-line evaluation count=%0d line=%0d overflow=%0b",
               dut.cache_count, dut.line_meta[20][11:0], cache_overflow);
    for (i = 0; i < 128; i = i + 1)
        if ($signed(dut.descriptor_cache[i][86:70]) != i)
            $fatal(1, "descriptor order mismatch slot=%0d x=%0d", i,
                   $signed(dut.descriptor_cache[i][86:70]));

    // Reproduce the old torn-index failure at its first causal boundary.
    // Abort the list walk, then require the bounded prefix/reindex finish to
    // publish matching descriptor and per-line counts, never mixed epochs.
    pulse_cache_start();
    timeout = 0;
    while (dut.state != dut.BUILD_ADVANCE && timeout < 10000) begin
        @(negedge clk);
        timeout = timeout + 1;
    end
    if (dut.state != dut.BUILD_ADVANCE)
        $fatal(1, "did not reach list-walk advance state");
    cache_deadline = 1'b1;
    @(negedge clk);
    cache_deadline = 1'b0;
    wait_cache();
    if (!cache_overflow || dut.cache_count == 0 ||
        dut.cache_count >= 2048 ||
        dut.line_meta[20][11:0] != dut.cache_count)
        $fatal(1, "deadline publication is torn count=%0d line=%0d overflow=%0b",
               dut.cache_count, dut.line_meta[20][11:0], cache_overflow);

    $display("PASS tb_ssv_cached_sprite_renderer dense=2048 abort_count=%0d",
             dut.cache_count);
    $finish;
end
endmodule
