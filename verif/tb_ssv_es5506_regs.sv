`timescale 1ns/1ps

module tb_ssv_es5506_regs;

logic clk = 1'b0;
logic rst = 1'b1;
always #5 clk = ~clk;

logic        host_we;
logic        host_re;
logic [5:0]  host_addr;
logic [7:0]  host_wdata;
wire  [7:0]  host_rdata;
logic [9:0]  par_data;
logic        irq_set;
logic [4:0]  irq_voice;
wire         irq_n;
wire [6:0]   current_page;
wire [4:0]   active_voices;
wire [4:0]   mode;
wire [6:0]   word_clock_start;
wire [6:0]   word_clock_end;
wire [6:0]   lr_clock_end;
wire         commit;
wire [6:0]   commit_page;
wire [3:0]   commit_reg;
wire [31:0]  commit_data;

ssv_es5506_regs dut (
    .clk, .rst,
    .host_we, .host_re, .host_addr, .host_wdata, .host_rdata,
    .par_data, .irq_set, .irq_voice, .irq_n,
    .current_page, .active_voices, .mode,
    .word_clock_start, .word_clock_end, .lr_clock_end,
    .commit, .commit_page, .commit_reg, .commit_data
);

task automatic write_byte(input [5:0] address, input [7:0] data);
begin
    @(negedge clk);
    host_addr  = address;
    host_wdata = data;
    host_we    = 1'b1;
    @(negedge clk);
    host_we    = 1'b0;
end
endtask

task automatic write_reg(input [3:0] reg_index, input [31:0] data);
begin
    write_byte({reg_index, 2'd0}, data[31:24]);
    write_byte({reg_index, 2'd1}, data[23:16]);
    write_byte({reg_index, 2'd2}, data[15:8]);
    write_byte({reg_index, 2'd3}, data[7:0]);
end
endtask

task automatic read_reg(
    input [3:0] reg_index,
    output logic [31:0] data
);
    integer byte_index;
begin
    data = 32'd0;
    for (byte_index = 0; byte_index < 4; byte_index = byte_index + 1) begin
        @(negedge clk);
        host_addr = {reg_index, byte_index[1:0]};
        host_re   = 1'b1;
        @(posedge clk);
        #1;
        data[31 - byte_index * 8 -: 8] = host_rdata;
        @(negedge clk);
        host_re = 1'b0;
    end
end
endtask

task automatic expect32(
    input [31:0] actual,
    input [31:0] expected,
    input [255:0] label
);
begin
    if (actual !== expected) begin
        $display("FAIL %0s: got %08x expected %08x",
                 label, actual, expected);
        $fatal(1);
    end
end
endtask

logic [31:0] value;

initial begin
    host_we    = 1'b0;
    host_re    = 1'b0;
    host_addr  = 6'd0;
    host_wdata = 8'd0;
    par_data   = 10'h155;
    irq_set    = 1'b0;
    irq_voice  = 5'd0;

    repeat (3) @(posedge clk);
    rst = 1'b0;
    @(posedge clk);

    if (current_page !== 7'h00 ||
        active_voices !== 5'h1f ||
        mode !== 5'h17 ||
        irq_n !== 1'b1) begin
        $display("FAIL reset state");
        $fatal(1);
    end

    // Bytes 0-2 must not commit a register.
    write_byte(6'h3c, 8'h00);
    write_byte(6'h3d, 8'h00);
    write_byte(6'h3e, 8'h00);
    if (current_page !== 7'h00 || commit !== 1'b0) begin
        $display("FAIL PAGE committed before byte 3");
        $fatal(1);
    end
    write_byte(6'h3f, 8'h30);
    if (current_page !== 7'h30 ||
        commit_page !== 7'h00 ||
        commit_reg !== 4'hf ||
        commit_data !== 32'h0000_0030) begin
        $display("FAIL PAGE commit/latch");
        $fatal(1);
    end

    // Dyna Gear voice 16 high-page setup.
    write_reg(4'h1, 32'h3894_3000); // START
    write_reg(4'h2, 32'h3bb6_f07f); // END masks low 7 bits
    write_reg(4'h3, 32'h3894_3000); // ACCUM
    write_reg(4'h0, 32'h0000_0003); // stopped while configured

    read_reg(4'h1, value);
    expect32(value, 32'h3894_3000, "voice16 START");
    read_reg(4'h2, value);
    expect32(value, 32'h3bb6_f000, "voice16 END mask");
    read_reg(4'h3, value);
    expect32(value, 32'h3894_3000, "voice16 ACCUM");

    // Switch to the low page for the same voice and apply the trace values.
    write_reg(4'hf, 32'h0000_0010);
    write_reg(4'h7, 32'h0000_f030); // K2
    write_reg(4'h9, 32'h0000_ff80); // K1
    write_reg(4'h1, 32'h0000_0800); // FC
    write_reg(4'h2, 32'h0000_f550); // LVOL
    write_reg(4'h4, 32'h0000_f550); // RVOL
    write_reg(4'h0, 32'h0000_8000); // bank 2, running

    read_reg(4'h0, value);
    expect32(value, 32'h0000_8000, "voice16 CR");
    read_reg(4'h1, value);
    expect32(value, 32'h0000_0800, "voice16 FC");
    read_reg(4'h7, value);
    expect32(value, 32'h0000_f030, "voice16 K2");
    read_reg(4'h9, value);
    expect32(value, 32'h0000_ff80, "voice16 K1");

    // PAGE selects a distinct voice.
    write_reg(4'hf, 32'h0000_0011);
    read_reg(4'h0, value);
    expect32(value, 32'h0000_0003, "voice17 reset CR");

    // IRQV returns the active-low vector and byte-0 read acknowledges it.
    @(negedge clk);
    irq_voice = 5'd18;
    irq_set   = 1'b1;
    @(negedge clk);
    irq_set   = 1'b0;
    if (irq_n !== 1'b0) begin
        $display("FAIL IRQ set");
        $fatal(1);
    end
    read_reg(4'he, value);
    expect32(value, 32'h0000_0012, "IRQV snapshot");
    if (irq_n !== 1'b1) begin
        $display("FAIL IRQV acknowledge");
        $fatal(1);
    end

    // PAR and global serial registers are readable on their documented pages.
    read_reg(4'hd, value);
    expect32(value, 32'h0000_0155, "PAR");
    write_reg(4'hf, 32'h0000_0020);
    write_reg(4'ha, 32'h0000_0030);
    write_reg(4'hb, 32'h0000_0040);
    write_reg(4'hc, 32'h0000_0040);
    if (word_clock_start !== 7'h30 ||
        word_clock_end !== 7'h40 ||
        lr_clock_end !== 7'h40) begin
        $display("FAIL serial timing registers");
        $fatal(1);
    end

    $display("PASS tb_ssv_es5506_regs");
    $finish;
end

initial begin
    $dumpfile("tb_ssv_es5506_regs.vcd");
    $dumpvars(0, tb_ssv_es5506_regs);
end

endmodule
