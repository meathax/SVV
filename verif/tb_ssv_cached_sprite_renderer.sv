/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off MULTIDRIVEN */
`timescale 1ns/1ps

module tb_ssv_cached_sprite_renderer;
logic clk = 1'b0;
always #5 clk = ~clk;

`ifdef WAVES
initial begin
    $dumpfile("D:/Arcade/AI/SVV/sim_output/cached_sprite_line_buckets_wave3/cached_sprite.vcd");
    $dumpvars(0, tb_ssv_cached_sprite_renderer);
end
`endif

logic rst, cache_start, start;
logic cache_deadline;
logic [8:0] target_y;
logic [15:0] local_control, flip_control, coordinate_control;
logic [15:0] global_y_base, global_y_adjust;
logic [255:0] sprite_offsets;
logic [511:0] tilemap_scrolls;
logic shadow_4bit;
logic [16:0] spr_addr;
logic [15:0] spr_data;
logic rom_req;
logic [24:4] rom_addr;
logic [127:0] rom_data;
logic rom_ack;
logic [3:0] plot_we;
logic [35:0] plot_x;
logic [59:0] plot_color;
logic plot_shadow;
logic [31:0] plot_pen;
logic plot_shadow_4bit;
logic cache_busy, cache_ready, cache_overflow;
logic busy, done;

ssv_cached_sprite_renderer dut (.*);

logic [15:0] sprite_mem [0:131071];
always_ff @(posedge clk)
    spr_data <= sprite_mem[spr_addr];

logic rom_req_d;
integer rom_delay;
integer rom_quarter;
always_ff @(posedge clk) begin
    rom_req_d <= rom_req;
    rom_ack <= 1'b0;
    if (rom_req && !rom_req_d)
        rom_delay <= 2;
    if (rom_delay > 0) begin
        rom_delay <= rom_delay - 1;
        if (rom_delay == 1) begin
            rom_data <= 128'h80;
            rom_ack <= 1'b1;
            rom_quarter <= rom_quarter + 1;
        end
    end
end

integer plots;
integer first_x;
integer monitor_lane;
integer batch_plot_count;
integer batch_first_lane;
always_comb begin
    batch_plot_count = 0;
    batch_first_lane = -1;
    for (monitor_lane = 0; monitor_lane < 4;
         monitor_lane = monitor_lane + 1) begin
        if (plot_we[monitor_lane]) begin
            batch_plot_count = batch_plot_count + 1;
            if (batch_first_lane < 0)
                batch_first_lane = monitor_lane;
        end
    end
end

always_ff @(posedge clk) begin
    if (batch_plot_count != 0) begin
        plots <= plots + batch_plot_count;
        // Key first-pixel capture directly from its sentinel.  Using the
        // separately updated plot count makes this monitor scheduler-order
        // dependent when a batch and the waiting test resume together.
        if (first_x < 0)
            first_x <= plot_x[batch_first_lane * 9 +: 9];
    end
    for (monitor_lane = 0; monitor_lane < 4;
         monitor_lane = monitor_lane + 1) begin
        if (plot_we[monitor_lane] &&
            (plot_color[monitor_lane * 15 +: 15] !== 15'd65 ||
             plot_pen[monitor_lane * 8 +: 8] !== 8'd1 ||
             plot_shadow || plot_shadow_4bit))
            $fatal(1,
                "plot metadata lane=%0d color=%0d pen=%0d shadow=%0b shadow4=%0b x=%0d addr=%h",
                monitor_lane,
                plot_color[monitor_lane * 15 +: 15],
                plot_pen[monitor_lane * 8 +: 8],
                plot_shadow, plot_shadow_4bit,
                plot_x[monitor_lane * 9 +: 9], spr_addr);
    end
end

integer cycles;
always_ff @(posedge clk) begin
    cycles <= cycles + 1;
    if (cycles > 10000)
        $fatal(1,
            "timeout state=%0d cache_busy=%0b ready=%0b count=%0d index=%0d busy=%0b",
            dut.state, cache_busy, cache_ready, dut.cache_count,
            dut.cache_read_index, busy);
end

integer i;
initial begin
    for (i = 0; i < 131072; i = i + 1)
        sprite_mem[i] = 16'd0;

    // One global entry pointing at one 16x8, six-bpp local sprite.
    sprite_mem[0] = 16'h6000;
    sprite_mem[1] = 16'h0400;
    sprite_mem[2] = 16'd0;
    sprite_mem[3] = 16'd0;
    sprite_mem[5] = 16'h8000; // end marker in the next global entry

    sprite_mem[16'h1000] = 16'd0;
    sprite_mem[16'h1001] = 16'h0001;
    sprite_mem[16'h1002] = 16'd10;
    sprite_mem[16'h1003] = 16'h03e3; // -29 -> final screen y 20

    rst = 1'b1;
    cache_start = 1'b0;
    cache_deadline = 1'b0;
    start = 1'b0;
    target_y = 9'd20;
    local_control = 16'd0;
    flip_control = 16'd0;
    coordinate_control = 16'd0;
    global_y_base = 16'd0;
    global_y_adjust = 16'd0;
    sprite_offsets = 256'd0;
    tilemap_scrolls = 512'd0;
    shadow_4bit = 1'b0;
    spr_data = 16'd0;
    rom_data = 128'd0;
    rom_ack = 1'b0;
    rom_req_d = 1'b0;
    rom_delay = 0;
    rom_quarter = 0;
    plots = 0;
    first_x = -1;
    cycles = 0;

    repeat (4) @(negedge clk);
    rst = 1'b0;
    cache_start = 1'b1;
    @(negedge clk);
    cache_start = 1'b0;

    wait (cache_ready);
    if (cache_busy || cache_overflow)
        $fatal(1, "cache completion flags mismatch");

    // Prove rendering uses the vblank snapshot, not live sprite RAM.
    sprite_mem[16'h1002] = 16'd100;

    @(negedge clk);
    start = 1'b1;
    @(negedge clk);
    start = 1'b0;

    wait (done);
    @(posedge clk);
    if (plots != 1 || first_x != 10)
        $fatal(1, "plot coverage count=%0d first=%0d", plots, first_x);
    if (rom_addr < 21'h10000)
        $fatal(1, "graphics ROM address outside sprite region: %h", rom_addr);
    // An unbucketed line must complete through the synchronous count read
    // without issuing pixels from a stale line entry.
    target_y = 9'd19;
    @(negedge clk);
    start = 1'b1;
    @(negedge clk);
    start = 1'b0;

    wait (done);
    @(posedge clk);
    if (plots != 1)
        $fatal(1, "empty line produced pixels count=%0d", plots);

    // MAME draw_sprites() identifies this as tilemap scroll group 1:
    // local count is nonzero, code is 1, attr is zero, x size is one
    // tile and y size is eight. Two identical adjacent slices exercise
    // exact-consecutive overlap elision; a following group-zero entry is
    // still excluded.
    sprite_mem[0] = 16'h0302;
    sprite_mem[1] = 16'h0400;
    sprite_mem[2] = 16'd0;
    sprite_mem[3] = 16'd0;
    sprite_mem[16'h1000] = 16'd1;
    sprite_mem[16'h1001] = 16'd0;
    sprite_mem[16'h1002] = 16'd0;
    sprite_mem[16'h1003] = 16'd20;
    sprite_mem[16'h1004] = 16'd1;
    sprite_mem[16'h1005] = 16'd0;
    sprite_mem[16'h1006] = 16'd0;
    sprite_mem[16'h1007] = 16'd20;
    sprite_mem[16'h1008] = 16'd0;
    sprite_mem[16'h1009] = 16'd0;
    sprite_mem[16'h100a] = 16'd0;
    sprite_mem[16'h100b] = 16'd0;

    // A 512-pixel map on page one. At target line 20, MAME's +2
    // vertical adjustment selects tile words 0x802/0x803.
    tilemap_scrolls[4 * 16 +: 16] = 16'h0200;
    tilemap_scrolls[5 * 16 +: 16] = 16'h0000;
    tilemap_scrolls[6 * 16 +: 16] = 16'h0000;
    tilemap_scrolls[7 * 16 +: 16] = 16'h2600;
    for (i = 0; i < 21; i = i + 1) begin
        sprite_mem[16'h0802 + i * 64] = 16'd0;
        sprite_mem[16'h0803 + i * 64] = 16'd1;
    end

    plots = 0;
    first_x = -1;
    cycles = 0;
    target_y = 9'd20;
    @(negedge clk);
    cache_start = 1'b1;
    @(negedge clk);
    cache_start = 1'b0;
    wait (cache_busy);
    wait (cache_ready);
    if (cache_overflow || dut.cache_count != 2)
        $fatal(1, "tilemap cache mismatch overflow=%0b count=%0d",
               cache_overflow, dut.cache_count);

    @(negedge clk);
    start = 1'b1;
    @(negedge clk);
    start = 1'b0;
    wait (done);
    @(posedge clk);
    if (plots != 21 || first_x != 0)
        $fatal(1, "tilemap line coverage count=%0d first=%0d",
               plots, first_x);

    target_y = 9'd85;
    @(negedge clk);
    start = 1'b1;
    @(negedge clk);
    start = 1'b0;
    wait (done);
    @(posedge clk);
    if (plots != 21)
        $fatal(1,
               "tilemap rendered outside 65-line slice count=%0d",
               plots);

    // Character-select uses 52 one-tile descriptors on several lines. The
    // object pass starts after the background renderer and has 2,558 system
    // clocks left before the next line flip in the full-core reproducer. This
    // unit ROM model adds one handshake clock to each of 133 row fetches, so
    // its equivalent deadline is 2,691 clocks.
    for (i = 0; i < 131072; i = i + 1)
        sprite_mem[i] = 16'd0;
    // Four 21-tile map strips + 47 one-tile sprites + one two-tile
    // sprite = 52 descriptors and 133 row fetches, matching frame 169.
    sprite_mem[0] = 16'h631f; // 32 locals, y-size eight
    sprite_mem[1] = 16'h0400;
    sprite_mem[4] = 16'h6312; // 19 one-tile locals
    sprite_mem[5] = 16'h0800;
    sprite_mem[8] = 16'h6700; // one two-tile local
    sprite_mem[9] = 16'h0c00;
    sprite_mem[13] = 16'h8000; // end marker in fourth global entry

    tilemap_scrolls = 512'd0;
    tilemap_scrolls[4 * 16 +: 16] = 16'h0200;
    tilemap_scrolls[7 * 16 +: 16] = 16'h2600;
    tilemap_scrolls[8 * 16 +: 16] = 16'h0200;
    tilemap_scrolls[11 * 16 +: 16] = 16'h2600;
    tilemap_scrolls[12 * 16 +: 16] = 16'h0200;
    tilemap_scrolls[15 * 16 +: 16] = 16'h2600;
    tilemap_scrolls[16 * 16 +: 16] = 16'h0200;
    tilemap_scrolls[19 * 16 +: 16] = 16'h2600;
    for (i = 0; i < 21; i = i + 1) begin
        sprite_mem[16'h0802 + i * 64] = 16'd0;
        sprite_mem[16'h0803 + i * 64] = 16'd1;
    end
    for (i = 0; i < 4; i = i + 1) begin
        sprite_mem[16'h1000 + i * 4] = 16'd1 + i;
        sprite_mem[16'h1001 + i * 4] = 16'd0;
        sprite_mem[16'h1002 + i * 4] = 16'd0;
        sprite_mem[16'h1003 + i * 4] = 16'd20;
    end
    for (i = 4; i < 32; i = i + 1) begin
        sprite_mem[16'h1000 + i * 4] = 16'd8 + i;
        sprite_mem[16'h1001 + i * 4] = 16'h0001;
        sprite_mem[16'h1002 + i * 4] = 16'd10;
        sprite_mem[16'h1003 + i * 4] = 16'h03e3;
    end
    for (i = 0; i < 19; i = i + 1) begin
        sprite_mem[16'h2000 + i * 4] = 16'd40 + i;
        sprite_mem[16'h2001 + i * 4] = 16'h0001;
        sprite_mem[16'h2002 + i * 4] = 16'd10;
        sprite_mem[16'h2003 + i * 4] = 16'h03e3;
    end
    sprite_mem[16'h3000] = 16'd80;
    sprite_mem[16'h3001] = 16'h0001;
    sprite_mem[16'h3002] = 16'd10;
    sprite_mem[16'h3003] = 16'h03e3;

    plots = 0;
    first_x = -1;
    cycles = 0;
    target_y = 9'd20;
    @(negedge clk);
    cache_start = 1'b1;
    @(negedge clk);
    cache_start = 1'b0;
    wait (cache_busy);
    wait (cache_ready);
    if (cache_overflow || dut.cache_count != 52)
        $fatal(1, "dense cache mismatch overflow=%0b count=%0d",
               cache_overflow, dut.cache_count);

    cycles = 0;
    @(negedge clk);
    start = 1'b1;
    @(negedge clk);
    start = 1'b0;
    wait (done);
    @(posedge clk);
    if (plots != 133 || first_x != 0)
        $fatal(1, "dense line coverage count=%0d first=%0d", plots, first_x);
    $display("DENSE_LINE cycles=%0d limit=2691", cycles);
    if (cycles > 2691)
        $fatal(1, "dense line deadline cycles=%0d limit=2691", cycles);

    // ------------------------------------------------------------------
    // Vblank deadline abort.
    //
    // The sprite list is only bounded by 1024 globals x 32 locals, which is
    // far longer than a frame. Build a list that never terminates itself
    // (no global has bit 15 of word 1 set, so the walk runs to LAST_GLOBAL)
    // and assert cache_deadline part-way through.
    //
    // Without the abort in BUILD_ADVANCE the build ignores the deadline and
    // holds cache_busy for the rest of the walk. In ssv_core that suppresses
    // every line_buffer_start, and because the next vblank re-arms the build
    // it never recovers -- the display freezes permanently. Observed failure
    // mode with the abort removed: cache_busy still high after the timeout
    // below, so this $fatal fires.
    // ------------------------------------------------------------------
    for (i = 0; i < 4096; i = i + 4) begin
        sprite_mem[i + 0] = 16'h0001;  // one local entry
        sprite_mem[i + 1] = 16'h0400;  // local list ptr, bit15 clear = no end
        sprite_mem[i + 2] = 16'd0;
        sprite_mem[i + 3] = 16'd0;
    end

    cache_deadline = 1'b0;
    @(negedge clk);
    cache_start = 1'b1;
    @(negedge clk);
    cache_start = 1'b0;
    wait (cache_busy);

    // Let it get well past the line clear, then close the window.
    repeat (600) @(negedge clk);
    if (cache_ready)
        $fatal(1, "unterminated list completed early - test is not exercising the abort");
    cache_deadline = 1'b1;

    cycles = 0;
    while (cache_busy && cycles < 2000) begin
        @(negedge clk);
        cycles = cycles + 1;
    end
    if (cache_busy)
        $fatal(1, "cache_deadline ignored: still busy after %0d cycles", cycles);
    if (!cache_ready || !cache_overflow)
        $fatal(1, "aborted build must publish ready+overflow (ready=%0b overflow=%0b)",
               cache_ready, cache_overflow);
    $display("DEADLINE_ABORT released cache_busy in %0d cycles, overflow=%0b",
             cycles, cache_overflow);
    cache_deadline = 1'b0;

    $display("PASS tb_ssv_cached_sprite_renderer");
    $finish;
end
endmodule
