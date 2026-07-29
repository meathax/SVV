// SPDX-License-Identifier: GPL-3.0-or-later
// SSV eight-level interrupt controller, translated from MAME ssv.cpp.
`timescale 1ns/1ps

module ssv_irq (
    input              clk,
    input              rst,
    input              vblank_pulse,
    // Scanline-0 pulse, and whether this board raises IRQ level 1 on it.
    // MAME's init_ssv_irq1 sets m_interrupt_ultrax for ultrax and twineag2;
    // ssv.cpp notes it is "needed by ultrax to coin up, breaks cairblad",
    // which is why it is per game and not unconditional.
    input              line0_pulse,
    input              irq_level1_line0,

    input              vector_we,
    input        [2:0] vector_level,
    input       [15:0] vector_data,

    input              enable_we,
    input        [1:0] enable_be,
    input       [15:0] enable_data,

    input              ack_we,
    input        [2:0] ack_level,

    input              cpu_irq_ack,
    output logic       irq_n,
    output logic [7:0] irq_vector,
    output logic [7:0] requested,
    output logic [7:0] enabled
);

logic [2:0] vectors [0:7];
integer i;

always_ff @(posedge clk) begin
    if (rst) begin
        requested <= 8'h00;
        enabled   <= 8'h00;
        for (i = 0; i < 8; i = i + 1)
            vectors[i] <= 3'd0;
    end
    else begin
        // Clear first, set second: a $240000 ack that lands on the same
        // clk_sys edge as vblank must not swallow the new frame interrupt.
        // On the board the vblank latch is set by the raster, not by the CPU
        // write, so the set always wins.
        if (ack_we)
            requested[ack_level] <= 1'b0;

        if (vblank_pulse)
            requested[3] <= 1'b1;

        // Level 1 at scanline 0, for boards whose init sets
        // m_interrupt_ultrax (ultrax, twineag2). Raised alongside the level-3
        // vblank request, never instead of it.
        if (line0_pulse && irq_level1_line0)
            requested[1] <= 1'b1;

        if (vector_we)
            vectors[vector_level] <= vector_data[2:0];

        if (enable_we) begin
            if (enable_be[0])
                enabled <= enable_data[7:0];
            // MAME stores a 16-bit register, but SSV defines eight causes.
            // Preserve byte-lane semantics while ignoring unused high bits.
        end
    end
end

always_comb begin
    irq_n      = ~(|(requested & enabled));
    irq_vector = 8'h00;
    // MAME searches pending levels from 0 through 7 and uses the first one.
    if      (requested[0]) irq_vector = {5'b0, vectors[0]};
    else if (requested[1]) irq_vector = {5'b0, vectors[1]};
    else if (requested[2]) irq_vector = {5'b0, vectors[2]};
    else if (requested[3]) irq_vector = {5'b0, vectors[3]};
    else if (requested[4]) irq_vector = {5'b0, vectors[4]};
    else if (requested[5]) irq_vector = {5'b0, vectors[5]};
    else if (requested[6]) irq_vector = {5'b0, vectors[6]};
    else if (requested[7]) irq_vector = {5'b0, vectors[7]};
end

// Kept as an explicit input because the V60 core exposes the acknowledge
// cycle. SSV clears a source through 0x240000 rather than on CPU acknowledge.
logic unused_cpu_irq_ack;
always_comb unused_cpu_irq_ack = cpu_irq_ack;

endmodule
