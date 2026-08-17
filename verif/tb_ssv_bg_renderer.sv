`timescale 1ns/1ps

module tb_ssv_bg_renderer;
logic clk = 1'b0;
always #5 clk = ~clk;

ssv_pkg::ssv_cfg_t cfg;
logic rst, line_start;
logic [8:0] target_y;
logic clear_done;
logic [15:0] scroll_x, scroll_y, scroll_mode;
logic [15:0] global_y_base, global_y_adjust, flip_control;
logic shadow_4bit;
logic [16:0] spr_addr;
logic [15:0] spr_data;
// Sprite RAM is banked by word parity in ssv_core, so the word at spr_addr|1
// is available in the same cycle. Model both banks here.
logic [15:0] spr_data_next;
logic rom_req;
logic [ssv_pkg::SDR_AW:4] rom_addr;
logic [127:0] rom_data;
logic rom_ack;
logic [3:0] plot_we;
logic [35:0] plot_x;
logic [59:0] plot_color;
logic plot_shadow;
logic [31:0] plot_pen;
logic plot_shadow_4bit;
logic busy, done;

localparam logic [ssv_pkg::SDR_AW:4] GFX_FLIP_ROW_ADDR =
    ssv_pkg::SDR_GFX_BASE[ssv_pkg::SDR_AW:4] + 23'd15;

ssv_bg_renderer dut (.*);

logic [15:0] sprite_mem [0:131071];
always_ff @(posedge clk) begin
    if (rst) begin
        spr_data      <= 16'd0;
        spr_data_next <= 16'd0;
    end
    else begin
        spr_data      <= sprite_mem[spr_addr];
        spr_data_next <= sprite_mem[spr_addr | 17'd1];
    end
end

// Responder and capture state have exactly one driver each -- the always_ff
// blocks below. The stimulus arms them with `capture_arm` rather than writing
// them directly. A variable written from both an initial block and an always_ff
// is the classic way to get a testbench that silently observes nothing, and
// that is exactly what this bench used to do: `first_x`, `last_x` and
// `first_rom_addr` are write-only here and read only from the initial block, so
// under Verilator their writes were discarded and they sat at their initial
// values while the assertions read them. `plots` and `requests` survived only
// because `x <= x + n` also reads them. See the same note in
// tb_ssv_tilemap_page.sv, which was written the right way round.
logic capture_arm;

logic rom_req_d;
integer rom_delay;
integer rom_quarter;
integer requests;
logic [ssv_pkg::SDR_AW:4] first_rom_addr;
always_ff @(posedge clk) begin
    if (rst) begin
        rom_req_d      <= 1'b0;
        rom_ack        <= 1'b0;
        rom_data       <= 128'd0;
        rom_delay      <= 0;
        rom_quarter    <= 0;
        requests       <= 0;
        first_rom_addr <= '0;
    end
    else begin
        rom_req_d <= rom_req;
        rom_ack <= 1'b0;
        if (rom_req && !rom_req_d) begin
            if (requests == 0)
                first_rom_addr <= rom_addr;
            requests <= requests + 1;
            rom_delay <= 2;
        end
        if (rom_delay > 0) begin
            rom_delay <= rom_delay - 1;
            if (rom_delay == 1) begin
                // One 128-bit record per tile row: plane01 supplies pen bit
                // zero at pixel zero, the other quarters are blank.
                rom_data <= 128'h80;
                rom_ack <= 1'b1;
                rom_quarter <= rom_quarter + 1;
            end
        end
        // Last, so arming wins over anything above it on the same edge.
        if (capture_arm) begin
            rom_req_d      <= 1'b0;
            rom_ack        <= 1'b0;
            rom_data       <= 128'd0;
            rom_delay      <= 0;
            rom_quarter    <= 0;
            requests       <= 0;
            first_rom_addr <= '0;
        end
    end
end

integer plots;
integer first_x;
integer last_x;
integer monitor_lane;
// The always_ff below needs its own loop variable: sharing `monitor_lane` with
// the always_comb makes it multidriven, which IEEE 1800-2023 9.2.2.2 forbids
// for an always_comb output and which -Wno-MULTIDRIVEN was hiding.
integer check_lane;
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
        if (plots == 0)
            first_x <= plot_x[batch_first_lane * 9 +: 9];
        plots <= plots + batch_plot_count;
    end
    for (check_lane = 0; check_lane < 4;
         check_lane = check_lane + 1) begin
        if (plot_we[check_lane]) begin
            last_x <= plot_x[check_lane * 9 +: 9];
            if (plot_color[check_lane * 15 +: 15] !== 15'd65 ||
                plot_pen[check_lane * 8 +: 8] !== 8'd1 ||
                plot_shadow || plot_shadow_4bit)
                $fatal(1, "plot metadata mismatch lane=%0d",
                       check_lane);
        end
    end
    // Last, so arming wins over anything above it on the same edge.
    if (capture_arm) begin
        plots   <= 0;
        first_x <= -1;
        last_x  <= -1;
    end
end

integer i;
initial begin
    cfg = ssv_pkg::cfg_dynagear();
    // Exercise this renderer's actual consumer. Nibble d is asymmetric under
    // reversal: ordinary SSV expands it to b; Cair Blade preserves d.
    cfg.tile_code_identity = 1'b0;
    if (dut.expand_code(cfg, 16'h1234, 16'h3400) !== 20'hb1234)
        $fatal(1, "background scrambled tile-code expansion mismatch");
    cfg.tile_code_identity = 1'b1;
    if (dut.expand_code(cfg, 16'h1234, 16'h3400) !== 20'hd1234)
        $fatal(1, "background Cair Blade identity tile-code expansion mismatch");
    cfg = ssv_pkg::cfg_dynagear();
    for (i = 0; i < 131072; i = i + 1)
        sprite_mem[i] = 16'd0;
    // Each column's descriptor is 64 words apart for a 512-pixel map.
    for (i = 0; i <= 20; i = i + 1) begin
        sprite_mem[i * 64] = 16'd0;
        sprite_mem[i * 64 + 1] = 16'h0001;
    end

    rst = 1'b1;
    line_start = 1'b0;
    target_y = 9'd0;
    clear_done = 1'b0;
    scroll_x = 16'd0;
    scroll_y = 16'hfffe; // cancels the renderer's documented +2 tweak
    scroll_mode = 16'h2000; // enabled, 512-pixel map, six-bpp mode
    global_y_base = 16'd0;
    global_y_adjust = 16'd0;
    flip_control = 16'd0;
    shadow_4bit = 1'b0;
    capture_arm = 1'b0;

    // Arm the responder and the monitor; their own always_ff blocks clear them.
    @(negedge clk);
    capture_arm = 1'b1;
    @(negedge clk);
    capture_arm = 1'b0;

    repeat (2) @(negedge clk);
    rst = 1'b0;
    line_start = 1'b1;
    @(negedge clk);
    line_start = 1'b0;
    repeat (3) @(negedge clk);
    clear_done = 1'b1;
    @(negedge clk);
    clear_done = 1'b0;

    wait (done);
    @(posedge clk);
    if (plots != 21 || first_x != 0 || last_x != 320)
        $fatal(1, "plot coverage count=%0d first=%0d last=%0d",
               plots, first_x, last_x);
    if (first_rom_addr != ssv_pkg::SDR_GFX_BASE[ssv_pkg::SDR_AW:4])
        $fatal(1, "normal row address got %h", first_rom_addr);

    // Vertical flip must select code+1 and row 7 for source line zero.
    for (i = 0; i <= 20; i = i + 1)
        sprite_mem[i * 64 + 1] = 16'h4001;
    @(negedge clk);
    capture_arm = 1'b1;
    @(negedge clk);
    capture_arm = 1'b0;
    line_start = 1'b1;
    @(negedge clk);
    line_start = 1'b0;
    repeat (3) @(negedge clk);
    clear_done = 1'b1;
    @(negedge clk);
    clear_done = 1'b0;

    wait (done);
    @(posedge clk);
    if (plots != 21 || first_x != 0 || last_x != 320)
        $fatal(1, "flipped plot coverage count=%0d first=%0d last=%0d",
               plots, first_x, last_x);
    if (first_rom_addr != GFX_FLIP_ROW_ADDR)
        $fatal(1, "vertical-flip row address got %h", first_rom_addr);

    $display("PASS tb_ssv_bg_renderer");
    $finish;
end
endmodule
