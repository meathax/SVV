// SPDX-License-Identifier: GPL-3.0-or-later
// Which tilemap page does a row-scrolled scanline read?
//
// MAME, ssv_v.cpp draw_row_64pixhigh():
//
//     int tilemap_scrollx = m_scroll[scrollreg * 4 + 0];
//     const int size = 1 << (8 + ((mode & 0xe000) >> 13));
//     const int page = (tilemap_scrollx & 0x7fff) / size;   // raw scroll
//     ...
//     if (BIT(mode, 12))                                    // row-scroll
//         tilemap_scrollx += m_spriteram[scrolltable_base + (realy & 0x1ff)];
//     int x = tilemap_scrollx;
//     for (...) { get_tile(x, realy, size, page, ...); x += 0x10; }
//
// and ssv_v.cpp get_tile():
//
//     s3 = &m_spriteram[page * (size * ((0x1000 / 0x200) / 2)) +
//                       ((x & ((size - 1) & ~0xf)) << 2) +
//                       ((y & ((0x200 - 1) & ~0xf)) >> 3)];
//
// `page` selects *which map* the whole scanline reads and is fixed by the raw
// scroll register. The running `x` only walks columns inside it. Folding the
// row-scroll offset into the page term lets a per-line offset of a few pixels
// move an entire scanline onto the neighbouring map.
//
// The renderer's sprite-RAM address is an output port, so these cases are
// checked at the module boundary against the formula above rather than against
// any internal signal.
`timescale 1ns/1ps

module tb_ssv_tilemap_page;

logic clk = 1'b0;
always #5 clk = ~clk;

logic rst, line_start;
logic [8:0] target_y;
logic clear_done;
logic [15:0] scroll_x, scroll_y, scroll_mode;
logic [15:0] global_y_base, global_y_adjust, flip_control;
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
logic busy, done;

ssv_bg_renderer dut (.*);

logic [15:0] sprite_mem [0:131071];
always_ff @(posedge clk)
    spr_data <= sprite_mem[spr_addr];

// Minimal ROM responder, same shape as tb_ssv_bg_renderer.
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

// The reference address, transcribed from get_tile() above.
function automatic logic [16:0] mame_tile_word(
    input logic [16:0] raw_scroll_x,
    input logic [16:0] x,
    input logic [16:0] y,
    input logic [15:0] mode
);
    logic [4:0]  size_shift;
    logic [16:0] size_mask;
    logic [16:0] page;
    begin
        size_shift = 5'd8 + {2'b0, mode[15:13]};
        size_mask = (17'd1 << size_shift) - 17'd1;
        page = (raw_scroll_x & 17'h07fff) >> size_shift;
        mame_tile_word = (page << (size_shift + 5'd2)) +
                         ((x & (size_mask & 17'h1fff0)) << 2) +
                         ((y & 17'h001f0) >> 3);
    end
endfunction

// The first sprite-RAM address that is not the row-scroll table lookup is the
// scanline's first tile-code fetch.
// Capture state has exactly one driver, this always_ff. The stimulus arms it
// with `capture_arm` rather than writing these registers directly; a variable
// written from both an initial block and an always_ff is the classic way to get
// a testbench that silently observes nothing.
logic [16:0] rowscroll_addr;
logic [16:0] first_tile_addr;
logic        first_tile_seen;
logic        saw_rowscroll;
logic        watching;
logic        capture_arm;

// The scanline's horizontal origin. MAME: sx1 = 0 - (tilemap_scrollx & 0xf),
// where tilemap_scrollx has ALREADY had the row-scroll offset added
// (ssv_v.cpp:702 then :706). Captured from the renderer at the first tile so
// the check is on the value actually used, not on a derived pixel position
// that clipping would obscure.
logic signed [10:0] first_screen_x;
logic               screen_x_seen;

always_ff @(posedge clk) begin
    if (capture_arm) begin
        saw_rowscroll   <= 1'b0;
        first_tile_seen <= 1'b0;
        first_tile_addr <= '1;
        screen_x_seen   <= 1'b0;
        first_screen_x  <= 11'sd0;
    end
    else if (watching) begin
        if (spr_addr == rowscroll_addr)
            saw_rowscroll <= 1'b1;
        else if (saw_rowscroll && !first_tile_seen) begin
            first_tile_addr <= spr_addr;
            first_tile_seen <= 1'b1;
        end
        // TILE_CODE_ADDR is state 5; by then the origin for the line is set.
        if (saw_rowscroll && !screen_x_seen && (dut.state == 5'd5)) begin
            first_screen_x <= dut.screen_x;
            screen_x_seen  <= 1'b1;
        end
    end
end

integer i;
integer errors;

task automatic run_line(
    input logic [15:0] mode,
    input logic [15:0] sx,
    input logic [15:0] rowscroll,
    input string        name
);
    logic [16:0] expected;
    logic [16:0] running_x;
    logic signed [10:0] expected_sx;
    begin
        scroll_mode = mode;
        scroll_x    = sx;
        rowscroll_addr = ({9'd0, mode[7:0]} << 9);  // target_y is 0 throughout
        for (i = 0; i < 131072; i = i + 1)
            sprite_mem[i] = 16'd0;
        sprite_mem[rowscroll_addr] = rowscroll;
        // Give every map word a non-zero attribute so a wrong fetch is still a
        // legal tile; the test judges the address, not the pixels.
        for (i = 0; i < 131072; i = i + 2)
            sprite_mem[i + 1] = 16'h0001;
        sprite_mem[rowscroll_addr] = rowscroll;

        running_x = {1'b0, sx} + {1'b0, rowscroll};
        expected  = mame_tile_word({1'b0, sx}, running_x, 17'd0, mode);

        watching = 1'b0;
        capture_arm = 1'b1;
        @(negedge clk);
        capture_arm = 1'b0;
        watching = 1'b1;

        @(negedge clk);
        line_start = 1'b1;
        @(negedge clk);
        line_start = 1'b0;
        repeat (3) @(negedge clk);
        clear_done = 1'b1;
        @(negedge clk);
        clear_done = 1'b0;

        wait (done);
        @(posedge clk);
        watching = 1'b0;

        if (!first_tile_seen) begin
            $display("FAIL %s: no tile fetch observed", name);
            errors = errors + 1;
        end
        else if (first_tile_addr !== expected) begin
            $display("FAIL %s: first tile word %0d, MAME says %0d (scroll=%0d rowscroll=%0d mode=%04x)",
                     name, first_tile_addr, expected, sx, rowscroll, mode);
            errors = errors + 1;
        end
        else begin
            $display("ok   %s: first tile word %0d (scroll=%0d rowscroll=%0d mode=%04x)",
                     name, first_tile_addr, sx, rowscroll, mode);
        end

        // Horizontal origin, MAME sx1 = 0 - ((scrollx + rowscroll) & 0xf).
        expected_sx = -$signed({7'd0, (sx + rowscroll) & 16'h000f});
        if (!screen_x_seen) begin
            $display("FAIL %s: no screen_x observed", name);
            errors = errors + 1;
        end
        else if (first_screen_x !== expected_sx) begin
            $display("FAIL %s: screen_x %0d, MAME sx1 says %0d (scroll=%0d rowscroll=%0d)",
                     name, first_screen_x, expected_sx, sx, rowscroll);
            errors = errors + 1;
        end
        else begin
            $display("ok   %s: screen_x %0d matches MAME sx1",
                     name, first_screen_x);
        end
        repeat (4) @(negedge clk);
    end
endtask

initial begin
    errors = 0;
    rst = 1'b1;
    line_start = 1'b0;
    target_y = 9'd0;
    clear_done = 1'b0;
    scroll_x = 16'd0;
    scroll_y = 16'hfffe;        // cancels the renderer's documented +2 tweak
    scroll_mode = 16'h3003;
    global_y_base = 16'd0;
    global_y_adjust = 16'd0;
    flip_control = 16'd0;
    shadow_4bit = 1'b0;
    spr_data = 16'd0;
    rom_data = 128'd0;
    rom_ack = 1'b0;
    rom_req_d = 1'b0;
    rom_delay = 0;
    rom_quarter = 0;
    watching = 1'b0;
    capture_arm = 1'b0;
    rowscroll_addr = 17'd1536;
    for (i = 0; i < 131072; i = i + 1)
        sprite_mem[i] = 16'd0;

    repeat (4) @(negedge clk);
    rst = 1'b0;
    repeat (2) @(negedge clk);

    // Control: no row-scroll offset. Both readings agree, so this case pins the
    // ordinary path and fails if a fix breaks it.
    run_line(16'h3003, 16'd479, 16'd0, "rowscroll=0 control");

    // The reported symptom. 512-pixel map, scroll 33 pixels below the page
    // boundary, a 48-pixel row-scroll offset carries the line across it.
    // MAME stays on page 0; using the row-scrolled position picks page 1.
    run_line(16'h3003, 16'd479, 16'd48, "offset crosses page boundary");

    // Same defect at a larger offset: a row-scroll value of 0x2000 is 16 pages
    // away, so the whole line lands in a completely unrelated map.
    run_line(16'h3003, 16'd100, 16'h2000, "large offset, far page");

    // A 1024-pixel map, to show the rule is not specific to one size.
    run_line(16'h5003, 16'd1000, 16'd64, "1024-pixel map boundary");

    // Sub-tile offsets. Every case above uses a row-scroll value that is a
    // multiple of 16, so the low nibble is the same whether or not the offset
    // is included and the horizontal-origin check cannot fail. These two carry
    // a sub-tile component and are what actually exercise it.
    //
    // 0xffff is the value the background layer really uses on hardware -- a
    // one-pixel step back -- and is what made this defect worth chasing.
    run_line(16'h3003, 16'd1024, 16'hffff, "sub-tile offset -1 (real value)");
    run_line(16'h3003, 16'd480,  16'd5,    "sub-tile offset +5");

    if (errors != 0)
        $fatal(1, "tb_ssv_tilemap_page: %0d case(s) failed", errors);
    $display("PASS tb_ssv_tilemap_page");
    $finish;
end

endmodule
