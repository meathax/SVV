`timescale 1ns/1ps

module tb_ssv_irq;
logic clk = 0;
always #5 clk = ~clk;

logic rst, vblank_pulse, vector_we, enable_we, ack_we, cpu_irq_ack;
logic [2:0] vector_level, ack_level;
logic [15:0] vector_data, enable_data;
logic [1:0] enable_be;
logic irq_n;
logic [7:0] irq_vector, requested, enabled;

ssv_irq dut (.*);

task tick;
    @(posedge clk); #1;
endtask

initial begin
    $dumpfile("ssv_irq.vcd");
    $dumpvars(0, tb_ssv_irq);
    rst = 1; vblank_pulse = 0; vector_we = 0; enable_we = 0;
    ack_we = 0; cpu_irq_ack = 0; vector_level = 0; ack_level = 0;
    vector_data = 0; enable_data = 0; enable_be = 0;
    repeat (2) tick();
    rst = 0;

    vector_we = 1; vector_level = 3; vector_data = 16'h0006; tick();
    vector_we = 0;
    enable_we = 1; enable_be = 2'b01; enable_data = 16'h0008; tick();
    enable_we = 0;
    vblank_pulse = 1; tick();
    vblank_pulse = 0; tick();

    if (irq_n !== 1'b0 || irq_vector !== 8'h06 ||
        requested !== 8'h08 || enabled !== 8'h08)
        $fatal(1, "vblank IRQ mismatch");

    ack_we = 1; ack_level = 3; tick();
    ack_we = 0; tick();
    if (irq_n !== 1'b1 || requested !== 8'h00)
        $fatal(1, "IRQ acknowledge mismatch");

    $display("PASS tb_ssv_irq");
    $finish;
end
endmodule
