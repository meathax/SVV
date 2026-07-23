// SPDX-License-Identifier: GPL-3.0-or-later
// Double-buffered 336-pixel SSV palette-index scanline store.
`timescale 1ns/1ps

module ssv_line_buffer (
    input  logic        clk,
    input  logic        rst,
    input  logic        line_start,

    input  logic        plot_we,
    input  logic  [8:0] plot_x,
    input  logic [14:0] plot_color,
    input  logic        plot_shadow,
    input  logic  [7:0] plot_pen,
    input  logic        shadow_4bit,

    input  logic  [8:0] scan_x,
    output logic [14:0] scan_color,

    output logic        clear_busy,
    output logic        clear_done
);

localparam logic [8:0] ACTIVE_WIDTH = 9'd336;
localparam logic [8:0] LAST_PIXEL   = 9'd335;

// Each physical line has one synchronous role-multiplexed read port and one
// renderer/clear write port. The front line reads scan_x while the back line
// reads plot_x. This maps to one Cyclone V M10K per line. Plots are pipelined
// by one clock so shadow pixels can read/modify/write at one pixel per clock.
(* ramstyle = "M10K, no_rw_check" *) logic [14:0] line0 [0:ACTIVE_WIDTH-1];
(* ramstyle = "M10K, no_rw_check" *) logic [14:0] line1 [0:ACTIVE_WIDTH-1];

logic        front_select;
logic        clear_select;
logic  [8:0] clear_x;
logic  [8:0] read_addr0, read_addr1;
logic [14:0] line_q0, line_q1;
logic        scan_valid_q;

logic        plot_pending;
logic        plot_select_q;
logic  [8:0] plot_x_q;
logic [14:0] plot_color_q;
logic        plot_shadow_q;
logic  [7:0] plot_pen_q;
logic        shadow_4bit_q;
logic        plot_bypass_q;
logic [14:0] plot_bypass_value_q;
logic [14:0] plot_source;
logic [14:0] plot_write_value;

always_comb begin
    // Clamp inactive/out-of-range addresses so simulation and inferred RAM
    // agree for the unused 336..511 part of the 9-bit address space.
    if (front_select) begin
        read_addr0 = (plot_x < ACTIVE_WIDTH) ? plot_x : 9'd0;
        read_addr1 = (scan_x < ACTIVE_WIDTH) ? scan_x : 9'd0;
    end
    else begin
        read_addr0 = (scan_x < ACTIVE_WIDTH) ? scan_x : 9'd0;
        read_addr1 = (plot_x < ACTIVE_WIDTH) ? plot_x : 9'd0;
    end

    plot_source = plot_select_q ? line_q1 : line_q0;
    if (plot_bypass_q)
        plot_source = plot_bypass_value_q;

    plot_write_value = plot_color_q;
    if (plot_shadow_q)
        plot_write_value = shadow_4bit_q
                         ? {plot_pen_q[3:0], plot_source[10:0]}
                         : {plot_pen_q[1:0], plot_source[12:0]};
end

always_ff @(posedge clk) begin
    clear_done <= 1'b0;
    line_q0 <= line0[read_addr0];
    line_q1 <= line1[read_addr1];
    scan_valid_q <= (scan_x < ACTIVE_WIDTH);

    if (rst) begin
        front_select <= 1'b0;
        clear_select <= 1'b0;
        clear_x      <= 9'd0;
        clear_busy   <= 1'b0;
        clear_done   <= 1'b0;
        scan_valid_q <= 1'b0;
        plot_pending <= 1'b0;
        plot_select_q <= 1'b0;
        plot_x_q <= 9'd0;
        plot_color_q <= 15'd0;
        plot_shadow_q <= 1'b0;
        plot_pen_q <= 8'd0;
        shadow_4bit_q <= 1'b0;
        plot_bypass_q <= 1'b0;
        plot_bypass_value_q <= 15'd0;
    end
    else begin
        // Renderer request pipeline. Back-buffer selection is captured with
        // the request so a later line swap cannot redirect the write.
        plot_pending <= plot_we && (plot_x < ACTIVE_WIDTH);
        if (plot_we && (plot_x < ACTIVE_WIDTH)) begin
            plot_select_q <= ~front_select;
            plot_x_q <= plot_x;
            plot_color_q <= plot_color;
            plot_shadow_q <= plot_shadow;
            plot_pen_q <= plot_pen;
            shadow_4bit_q <= shadow_4bit;

            // Forward the write on this edge to an immediately following
            // request for the same pixel. This avoids depending on the
            // FPGA's mixed-port read-during-write result.
            plot_bypass_q <= plot_pending &&
                             (plot_select_q == ~front_select) &&
                             (plot_x_q == plot_x);
            plot_bypass_value_q <= plot_write_value;
        end

        if (line_start) begin
            // Newly visible front is the completed old back. Clear the old
            // front, which has now become the renderer's back buffer.
            front_select <= ~front_select;
            clear_select <= front_select;
            clear_x      <= 9'd0;
            clear_busy   <= 1'b1;
            plot_pending <= 1'b0;
        end
        else if (clear_busy) begin
            if (clear_select)
                line1[clear_x] <= 15'd0;
            else
                line0[clear_x] <= 15'd0;

            if (clear_x == LAST_PIXEL) begin
                clear_busy <= 1'b0;
                clear_done <= 1'b1;
            end
            else begin
                clear_x <= clear_x + 1'd1;
            end
        end
        else if (plot_pending) begin
            if (plot_select_q)
                line1[plot_x_q] <= plot_write_value;
            else
                line0[plot_x_q] <= plot_write_value;
        end
    end
end

always_comb
    scan_color = scan_valid_q
               ? (front_select ? line_q1 : line_q0)
               : 15'd0;

endmodule
