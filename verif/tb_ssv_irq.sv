`timescale 1ns/1ps

module tb_ssv_irq;
logic clk = 0;
always #5 clk = ~clk;

logic rst, cold_rst, vblank_pulse, vector_we, enable_we, ack_we, cpu_irq_ack;
logic line0_pulse, irq_level1_line0;
logic line120_pulse, irq_level2_line120;
logic adc_eoc_pulse;
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
    rst = 1; cold_rst = 1; vblank_pulse = 0; vector_we = 0; enable_we = 0;
    ack_we = 0; cpu_irq_ack = 0; vector_level = 0; ack_level = 0;
    vector_data = 0; enable_data = 0; enable_be = 0;
    line0_pulse = 0; irq_level1_line0 = 0;
    line120_pulse = 0; irq_level2_line120 = 0;
    adc_eoc_pulse = 0;
    repeat (2) tick();
    rst = 0; cold_rst = 0;

    vector_we = 1; vector_level = 3; vector_data = 16'h0006; tick();
    vector_we = 0;
    enable_we = 1; enable_be = 2'b01; enable_data = 16'h0008; tick();
    enable_we = 0;
    vblank_pulse = 1; tick();
    vblank_pulse = 0; tick();

    if (irq_n !== 1'b0 || irq_vector !== 8'h06 ||
        requested !== 8'h08 || enabled !== 8'h08)
        $fatal(1, "vblank IRQ mismatch");

    // MAME ssv_state::machine_reset clears pending causes only. A watchdog
    // reset must retain the programmed mask and vector RAM.
    rst = 1; tick();
    rst = 0; tick();
    if (requested !== 8'h00 || enabled !== 8'h08 || irq_n !== 1'b1)
        $fatal(1, "soft reset did not retain IRQ configuration");
    vblank_pulse = 1; tick();
    vblank_pulse = 0; tick();
    if (irq_n !== 1'b0 || irq_vector !== 8'h06)
        $fatal(1, "retained IRQ vector/mask did not service vblank");

    ack_we = 1; ack_level = 3; tick();
    ack_we = 0; tick();
    if (irq_n !== 1'b1 || requested !== 8'h00)
        $fatal(1, "IRQ acknowledge mismatch");

    rst = 1; cold_rst = 1; tick();
    rst = 0; cold_rst = 0; tick();
    if (requested !== 8'h00 || enabled !== 8'h00)
        $fatal(1, "cold reset did not clear IRQ configuration");

    // MAME update_irq_state() is called by cause/ack handlers, not by the
    // enable-register write.  Reproduce Vasara's boot ordering: a vblank is
    // already pending while masked, then levels 2/3 are enabled before vector
    // RAM is initialized.  The mask write must not retroactively assert IRQ0.
    vector_we = 1; vector_level = 3; vector_data = 16'h0006; tick();
    vector_we = 0;
    vblank_pulse = 1; tick();
    vblank_pulse = 0; tick();
    if (requested !== 8'h08 || irq_n !== 1'b1)
        $fatal(1, "masked pending vblank incorrectly asserted IRQ");
    enable_we = 1; enable_be = 2'b01; enable_data = 16'h000c; tick();
    enable_we = 0; tick();
    if (enabled !== 8'h0c || irq_n !== 1'b1)
        $fatal(1, "enable write retroactively asserted pending IRQ");
    vblank_pulse = 1; tick();
    vblank_pulse = 0; tick();
    if (irq_n !== 1'b0 || irq_vector !== 8'h06)
        $fatal(1, "new cause did not refresh enabled pending IRQ");
    ack_we = 1; ack_level = 3; tick();
    ack_we = 0; tick();
    if (requested !== 8'h00 || irq_n !== 1'b1)
        $fatal(1, "event-refreshed IRQ acknowledge mismatch");

    // Ultra X and Twin Eagle II select the scanline-0 level-1 source in their
    // runtime descriptor.  The same raster pulse must be inert for every
    // ordinary SSV descriptor, then use the programmed level-1 vector and
    // acknowledge path when the descriptor enables it.
    enable_we = 1; enable_be = 2'b01; enable_data = 16'h0002; tick();
    enable_we = 0;
    line0_pulse = 1; tick(); line0_pulse = 0; tick();
    if (requested !== 8'h00 || irq_n !== 1'b1)
        $fatal(1, "disabled line-0 source requested IRQ1");
    irq_level1_line0 = 1;
    vector_we = 1; vector_level = 1; vector_data = 16'h0005; tick();
    vector_we = 0; line0_pulse = 1; tick(); line0_pulse = 0; tick();
    if (requested !== 8'h02 || irq_n !== 1'b0 || irq_vector !== 8'h05)
        $fatal(1, "enabled line-0 IRQ1 mismatch");
    ack_we = 1; ack_level = 1; tick(); ack_we = 0; tick();
    if (requested !== 8'h00 || irq_n !== 1'b1)
        $fatal(1, "line-0 IRQ1 acknowledge mismatch");

    // Both causes latch at scanline zero. The lower numbered cause supplies
    // the vector; acknowledging it exposes the still-pending IRQ3.
    enable_we = 1; enable_data = 16'h000a; tick(); enable_we = 0;
    line0_pulse = 1; vblank_pulse = 1; tick();
    line0_pulse = 0; vblank_pulse = 0; tick();
    if (requested !== 8'h0a || irq_n !== 1'b0 || irq_vector !== 8'h05)
        $fatal(1, "simultaneous IRQ1/IRQ3 priority mismatch");
    ack_we = 1; ack_level = 1; tick(); ack_we = 0; tick();
    if (requested !== 8'h08 || irq_n !== 1'b0 || irq_vector !== 8'h06)
        $fatal(1, "IRQ1 ack did not leave pending IRQ3 asserted");
    ack_we = 1; ack_level = 3; tick(); ack_we = 0; tick();
    if (requested !== 8'h00 || irq_n !== 1'b1)
        $fatal(1, "simultaneous IRQ1/IRQ3 final clear mismatch");
    irq_level1_line0 = 0;

    // Descriptor-v3 raster class requests level 2 only when enabled.
    enable_we = 1; enable_be = 2'b01; enable_data = 16'h0004; tick();
    enable_we = 0;
    line120_pulse = 1; tick(); line120_pulse = 0; tick();
    if (requested !== 8'h00 || irq_n !== 1'b1)
        $fatal(1, "disabled line-120 source requested IRQ2");
    irq_level2_line120 = 1;
    vector_we = 1; vector_level = 2; vector_data = 16'h0004; tick();
    vector_we = 0; line120_pulse = 1; tick(); line120_pulse = 0; tick();
    if (requested !== 8'h04 || irq_n !== 1'b0 || irq_vector !== 8'h04)
        $fatal(1, "enabled line-120 IRQ2 mismatch");

    ack_we=1; ack_level=2; tick(); ack_we=0; tick();
    vector_we=1; vector_level=6; vector_data=16'h0007; tick(); vector_we=0;
    enable_we=1; enable_data=16'h0040; tick(); enable_we=0;
    adc_eoc_pulse=1; tick(); adc_eoc_pulse=0; tick();
    if (requested !== 8'h40 || irq_n !== 1'b0 || irq_vector !== 8'h07)
        $fatal(1, "ADC EOC IRQ6 mismatch");

    $display("PASS tb_ssv_irq");
    $finish;
end
endmodule
