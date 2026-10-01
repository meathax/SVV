// SPDX-License-Identifier: GPL-3.0-or-later
// Invalidate a vblank descriptor build when its CPU-writable inputs change.
module ssv_cache_restart (
    input  logic clk,
    input  logic rst,
    input  logic write_accept,
    input  logic scroll_write,
    input  logic write_window,
    input  logic write_window_end,
    output logic restart
);
logic list_write_pending;

// A large sprite-list update gets one restart, retaining the vblank budget.
// Scroll writes are a short sequence of individual register stores. Every
// store must invalidate the build: restarting only on the first one lets
// successive 64-line slices capture different values of the same scroll.
assign restart = write_accept && write_window &&
                 (scroll_write || !list_write_pending);

always_ff @(posedge clk) begin
    if (rst || write_window_end)
        list_write_pending <= 1'b0;
    else if (restart)
        list_write_pending <= 1'b1;
end
endmodule
