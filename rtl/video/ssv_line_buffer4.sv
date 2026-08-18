// SPDX-License-Identifier: GPL-3.0-or-later
// Four-bank, double-buffered 352-pixel SSV palette-index scanline store.
`timescale 1ns/1ps

module ssv_line_buffer4 (
    input  logic        clk,
    input  logic        rst,
    // Pulses once per frame, during vblank and before the first active-line
    // line_start. See the frame_sync handling below for why this exists.
    input  logic        frame_sync,
    input  logic        line_start,
    input  logic        line_ready,
    input  logic        render_start,

    input  logic  [3:0] plot_we,
    input  logic [35:0] plot_x,
    input  logic [59:0] plot_color,
    input  logic        plot_shadow,
    input  logic [31:0] plot_pen,
    input  logic        shadow_4bit,

    input  logic  [8:0] scan_x,
    output logic [14:0] scan_color,

    output logic        clear_busy,
    output logic        clear_done
);

localparam logic [8:0] ACTIVE_WIDTH = 9'd352;
localparam logic [6:0] LAST_WORD = 7'd87;

// Consecutive four-pixel batches contain at most one write for each x[1:0]
// bank. Tiny 88x15 banks waste a full M10K each, so keep them in MLABs.
(* ramstyle = "MLAB, no_rw_check" *) logic [14:0] line0_b0 [0:87];
(* ramstyle = "MLAB, no_rw_check" *) logic [14:0] line0_b1 [0:87];
(* ramstyle = "MLAB, no_rw_check" *) logic [14:0] line0_b2 [0:87];
(* ramstyle = "MLAB, no_rw_check" *) logic [14:0] line0_b3 [0:87];
(* ramstyle = "MLAB, no_rw_check" *) logic [14:0] line1_b0 [0:87];
(* ramstyle = "MLAB, no_rw_check" *) logic [14:0] line1_b1 [0:87];
(* ramstyle = "MLAB, no_rw_check" *) logic [14:0] line1_b2 [0:87];
(* ramstyle = "MLAB, no_rw_check" *) logic [14:0] line1_b3 [0:87];

logic front_select;
logic render_select;
logic render_valid;
logic render_missed;
logic clear_select;
logic [6:0] clear_word;
logic [6:0] scan_word;
logic [1:0] scan_bank_q;
logic scan_valid_q;

logic [8:0] lane_x [0:3];
logic [14:0] lane_color [0:3];
logic [7:0] lane_pen [0:3];
logic [3:0] bank_req;
logic [6:0] bank_addr [0:3];
logic [14:0] bank_color [0:3];
logic [7:0] bank_pen [0:3];

logic [3:0] plot_pending;
logic plot_select_q;
logic [6:0] bank_addr_q [0:3];
logic [14:0] bank_color_q [0:3];
logic [7:0] bank_pen_q [0:3];
logic plot_shadow_q;
logic shadow_4bit_q;
logic [3:0] bypass_q;
logic [14:0] bypass_value_q [0:3];

logic [14:0] line0_q [0:3];
logic [14:0] line1_q [0:3];
logic [14:0] plot_source [0:3];
logic [14:0] write_value [0:3];

integer lane_i;
integer bank_i;
integer bank_ff_i;
always_comb begin
    scan_word = (scan_x < ACTIVE_WIDTH) ? scan_x[8:2] : 7'd0;

    for (lane_i = 0; lane_i < 4; lane_i = lane_i + 1) begin
        lane_x[lane_i] = plot_x[lane_i * 9 +: 9];
        lane_color[lane_i] = plot_color[lane_i * 15 +: 15];
        lane_pen[lane_i] = plot_pen[lane_i * 8 +: 8];
    end

    for (bank_i = 0; bank_i < 4; bank_i = bank_i + 1) begin
        bank_req[bank_i] = 1'b0;
        bank_addr[bank_i] = 7'd0;
        bank_color[bank_i] = 15'd0;
        bank_pen[bank_i] = 8'd0;
        for (lane_i = 0; lane_i < 4; lane_i = lane_i + 1) begin
            if (render_valid && plot_we[lane_i] &&
                (lane_x[lane_i] < ACTIVE_WIDTH) &&
                (lane_x[lane_i][1:0] == bank_i[1:0])) begin
                bank_req[bank_i] = 1'b1;
                bank_addr[bank_i] = lane_x[lane_i][8:2];
                bank_color[bank_i] = lane_color[lane_i];
                bank_pen[bank_i] = lane_pen[lane_i];
            end
        end

        plot_source[bank_i] = plot_select_q ? line1_q[bank_i] :
                                               line0_q[bank_i];
        if (bypass_q[bank_i])
            plot_source[bank_i] = bypass_value_q[bank_i];

        write_value[bank_i] = bank_color_q[bank_i];
        if (plot_shadow_q)
            write_value[bank_i] = shadow_4bit_q
                                ? {bank_pen_q[bank_i][3:0],
                                   plot_source[bank_i][10:0]}
                                : {bank_pen_q[bank_i][1:0],
                                   plot_source[bank_i][12:0]};
    end

    if (!scan_valid_q)
        scan_color = 15'd0;
    else begin
        unique case (scan_bank_q)
            2'd0: scan_color = front_select ? line1_q[0] : line0_q[0];
            2'd1: scan_color = front_select ? line1_q[1] : line0_q[1];
            2'd2: scan_color = front_select ? line1_q[2] : line0_q[2];
            default: scan_color = front_select ? line1_q[3] : line0_q[3];
        endcase
    end
end

always_ff @(posedge clk) begin
    clear_done <= 1'b0;
    scan_bank_q <= scan_x[1:0];
    scan_valid_q <= (scan_x < ACTIVE_WIDTH);

    if (front_select) begin
        line0_q[0] <= line0_b0[bank_addr[0]];
        line0_q[1] <= line0_b1[bank_addr[1]];
        line0_q[2] <= line0_b2[bank_addr[2]];
        line0_q[3] <= line0_b3[bank_addr[3]];
        line1_q[0] <= line1_b0[scan_word];
        line1_q[1] <= line1_b1[scan_word];
        line1_q[2] <= line1_b2[scan_word];
        line1_q[3] <= line1_b3[scan_word];
    end
    else begin
        line0_q[0] <= line0_b0[scan_word];
        line0_q[1] <= line0_b1[scan_word];
        line0_q[2] <= line0_b2[scan_word];
        line0_q[3] <= line0_b3[scan_word];
        line1_q[0] <= line1_b0[bank_addr[0]];
        line1_q[1] <= line1_b1[bank_addr[1]];
        line1_q[2] <= line1_b2[bank_addr[2]];
        line1_q[3] <= line1_b3[bank_addr[3]];
    end

    if (rst) begin
        front_select <= 1'b0;
        clear_select <= 1'b0;
        clear_word <= 7'd0;
        clear_busy <= 1'b0;
        clear_done <= 1'b0;
        scan_bank_q <= 2'd0;
        scan_valid_q <= 1'b0;
        plot_pending <= 4'd0;
        plot_select_q <= 1'b0;
        render_select <= 1'b0;
        render_valid <= 1'b0;
        render_missed <= 1'b0;
        plot_shadow_q <= 1'b0;
        shadow_4bit_q <= 1'b0;
        bypass_q <= 4'd0;
        for (bank_ff_i = 0; bank_ff_i < 4; bank_ff_i = bank_ff_i + 1) begin
            bank_addr_q[bank_ff_i] <= 7'd0;
            bank_color_q[bank_ff_i] <= 15'd0;
            bank_pen_q[bank_ff_i] <= 8'd0;
            bypass_value_q[bank_ff_i] <= 15'd0;
        end
    end
    else if (frame_sync) begin
        // front_select only toggles on a completed swap (the branch below),
        // never on a missed-deadline freeze or its drain -- both hold the
        // producer bank steady on purpose, so it can be reclaimed without
        // publishing a half-written line. That is correct for the frame the
        // overrun happened in, but it means a stall lasting an EVEN number
        // of lines leaves an ODD number of un-toggled line_starts behind it:
        // front_select keeps its pre-stall value while raster position has
        // moved on, so the scanline-to-buffer mapping is inverted from that
        // point on. Nothing else in this module ever corrects it -- there is
        // no periodic resync -- so it stays inverted for the rest of the
        // session, one raster line out of true, and a second even-length
        // stall inverts it back by accident rather than by design.
        //
        // Force a known-good mapping once per frame instead, at the one
        // point it costs nothing: during vblank, before any active-line
        // line_start of the new frame has fired. Confirmed against a
        // standalone parity model (tb_line_buffer_parity.sv): an odd total
        // of held (non-toggling) line_starts across a stall inverts
        // front_select's raster-line parity, and this resync bounds that
        // inversion to at most the one frame it happened in.
        front_select <= 1'b0;
        render_valid <= 1'b0;
        render_missed <= 1'b0;
    end
    else begin
        plot_pending <= bank_req;
        if (|bank_req) begin
            plot_select_q <= render_select;
            plot_shadow_q <= plot_shadow;
            shadow_4bit_q <= shadow_4bit;
            for (bank_ff_i = 0; bank_ff_i < 4; bank_ff_i = bank_ff_i + 1) begin
                bank_addr_q[bank_ff_i] <= bank_addr[bank_ff_i];
                bank_color_q[bank_ff_i] <= bank_color[bank_ff_i];
                bank_pen_q[bank_ff_i] <= bank_pen[bank_ff_i];
                bypass_q[bank_ff_i] <= plot_pending[bank_ff_i] &&
                                   (plot_select_q == render_select) &&
                                   (bank_addr_q[bank_ff_i] == bank_addr[bank_ff_i]);
                bypass_value_q[bank_ff_i] <= write_value[bank_ff_i];
            end
        end
        else begin
            bypass_q <= 4'd0;
        end

        if (line_start && !line_ready) begin
            // The producer missed this line's publication deadline.  Freeze
            // scanout on the last completed line and close the producer epoch
            // immediately: late plots must not leak into a future line.
            render_valid <= 1'b0;
            render_missed <= 1'b1;
            plot_pending <= 4'd0;
            bypass_q <= 4'd0;
        end
        else if (line_start && line_ready && render_missed) begin
            // The late renderer has drained.  Reclaim and clear its fixed
            // producer bank without publishing the stale line, then let the
            // newly launched pass reuse that same bank.
            render_missed <= 1'b0;
            render_valid <= render_start;
            clear_select <= render_select;
            clear_word <= 7'd0;
            clear_busy <= 1'b1;
            plot_pending <= 4'd0;
            bypass_q <= 4'd0;
        end
        else if (line_start && line_ready) begin
            // Plots are registered one cycle late. Commit any in-flight RMW
            // into the just-finished back buffer before the buffer flip, or
            // the last batch of the line is dropped.
            if (plot_pending[0]) begin
                if (plot_select_q) line1_b0[bank_addr_q[0]] <= write_value[0];
                else               line0_b0[bank_addr_q[0]] <= write_value[0];
            end
            if (plot_pending[1]) begin
                if (plot_select_q) line1_b1[bank_addr_q[1]] <= write_value[1];
                else               line0_b1[bank_addr_q[1]] <= write_value[1];
            end
            if (plot_pending[2]) begin
                if (plot_select_q) line1_b2[bank_addr_q[2]] <= write_value[2];
                else               line0_b2[bank_addr_q[2]] <= write_value[2];
            end
            if (plot_pending[3]) begin
                if (plot_select_q) line1_b3[bank_addr_q[3]] <= write_value[3];
                else               line0_b3[bank_addr_q[3]] <= write_value[3];
            end
            front_select <= ~front_select;
            // Publish only a completed producer buffer. A missed boundary
            // leaves the fixed producer bank in place so the pass can finish.
            // After an accepted swap, render_start opens the next epoch; if
            // no pass starts, later stale plots are rejected.
            render_valid <= render_start;
            if (render_start)
                render_select <= front_select;
            render_missed <= 1'b0;
            clear_select <= front_select;
            clear_word <= 7'd0;
            clear_busy <= 1'b1;
            plot_pending <= 4'd0;
        end
        else if (clear_busy) begin
            if (clear_select) begin
                line1_b0[clear_word] <= 15'd0;
                line1_b1[clear_word] <= 15'd0;
                line1_b2[clear_word] <= 15'd0;
                line1_b3[clear_word] <= 15'd0;
            end
            else begin
                line0_b0[clear_word] <= 15'd0;
                line0_b1[clear_word] <= 15'd0;
                line0_b2[clear_word] <= 15'd0;
                line0_b3[clear_word] <= 15'd0;
            end

            if (clear_word == LAST_WORD) begin
                clear_busy <= 1'b0;
                clear_done <= 1'b1;
            end
            else begin
                clear_word <= clear_word + 1'd1;
            end
        end
        else begin
            if (plot_pending[0]) begin
                if (plot_select_q) line1_b0[bank_addr_q[0]] <= write_value[0];
                else               line0_b0[bank_addr_q[0]] <= write_value[0];
            end
            if (plot_pending[1]) begin
                if (plot_select_q) line1_b1[bank_addr_q[1]] <= write_value[1];
                else               line0_b1[bank_addr_q[1]] <= write_value[1];
            end
            if (plot_pending[2]) begin
                if (plot_select_q) line1_b2[bank_addr_q[2]] <= write_value[2];
                else               line0_b2[bank_addr_q[2]] <= write_value[2];
            end
            if (plot_pending[3]) begin
                if (plot_select_q) line1_b3[bank_addr_q[3]] <= write_value[3];
                else               line0_b3[bank_addr_q[3]] <= write_value[3];
            end
        end
    end
end

endmodule
