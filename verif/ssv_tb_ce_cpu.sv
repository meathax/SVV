// SPDX-License-Identifier: GPL-3.0-or-later
// MAME-accurate V60 clock enable for SSV benches.
// Matches Arcade-SSV.sv and the board's 704:315 CPU-to-pixel clock ratio.
// Wired into realrom/hang/frame TBs with sticky multi-cycle SDRAM acks
// (see DYNAGEAR_NATURAL_IRQ_SKEW).
`timescale 1ns/1ps

module ssv_tb_ce_cpu (
    input  logic clk,
    input  logic rst,
    output logic ce_cpu
);
    import ssv_pkg::SSV_CPU_INC;
    logic [15:0] cpu_acc;
    logic [15:0] cpu_inc;
    integer cpu_inc_override;

    // Diagnostic-only cadence probe.  The canonical benches use the package
    // constant; a bounded +CPU_INC_OVERRIDE sweep can falsify a too-fast/too-
    // slow CPU hypothesis without changing production RTL or any golden run.
    initial begin
        cpu_inc = SSV_CPU_INC;
        if ($value$plusargs("CPU_INC_OVERRIDE=%d", cpu_inc_override)) begin
            if (cpu_inc_override <= 0 || cpu_inc_override > 16'hffff)
                $fatal(1, "CPU_INC_OVERRIDE out of range: %0d", cpu_inc_override);
            cpu_inc = cpu_inc_override;
        end
    end

    always_ff @(posedge clk) begin
        logic [16:0] cpu_sum;
        if (rst) begin
            cpu_acc <= 16'd0;
            ce_cpu  <= 1'b0;
        end else begin
            cpu_sum = {1'b0, cpu_acc} + {1'b0, cpu_inc};
            ce_cpu  <= cpu_sum[16];
            cpu_acc <= cpu_sum[15:0];
        end
    end
endmodule
