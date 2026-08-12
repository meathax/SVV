`timescale 1ns/1ps

module tb_ssv_es5506_regs;

logic clk = 1'b0;
logic rst = 1'b1;
logic cold_rst = 1'b1;
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
wire         eng_cr_valid;
wire [31:0]  eng_start;
wire [31:0]  eng_end;
wire [31:0]  eng_accum;
logic [4:0]  eng_voice;
logic        eng_wr_accum;
logic [31:0] eng_accum_w;
logic        eng_wr_cr;
logic [15:0] eng_cr_w;
logic        eng_wr_filt;
logic [17:0] eng_o4n1_w, eng_o3n1_w, eng_o3n2_w;
logic [17:0] eng_o2n1_w, eng_o2n2_w, eng_o1n1_w;
logic        eng_wr_env;
logic [15:0] eng_lvol_w, eng_rvol_w, eng_k1_w, eng_k2_w;
logic [8:0]  eng_ecount_w;

ssv_es5506_regs dut (
    .clk, .rst, .cold_rst,
    .host_we, .host_re, .host_addr, .host_wdata, .host_rdata,
    .par_data, .irq_set, .irq_voice, .irq_n,
    .current_page, .active_voices, .mode,
    .word_clock_start, .word_clock_end, .lr_clock_end,
    .commit, .commit_page, .commit_reg, .commit_data,
    .eng_voice,
    .eng_cr(), .eng_cr_valid, .eng_fc(),
    .eng_lvol(), .eng_lvramp(), .eng_rvol(), .eng_rvramp(),
    .eng_ecount(), .eng_k1(), .eng_k1ramp(), .eng_k2(), .eng_k2ramp(),
    .eng_start, .eng_end, .eng_accum,
    .eng_o4n1(), .eng_o3n1(), .eng_o3n2(),
    .eng_o2n1(), .eng_o2n2(), .eng_o1n1(),
    .eng_wr_accum, .eng_accum_w,
    .eng_wr_cr, .eng_cr_w,
    .eng_wr_filt,
    .eng_o4n1_w, .eng_o3n1_w, .eng_o3n2_w,
    .eng_o2n1_w, .eng_o2n2_w, .eng_o1n1_w,
    .eng_wr_env,
    .eng_lvol_w, .eng_rvol_w,
    .eng_k1_w, .eng_k2_w, .eng_ecount_w
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
        // Byte 0 steals the MLAB port; read_latch fills one cycle later.
        if (byte_index == 0) begin
            @(posedge clk);
        end
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

task automatic collide_host_engine(
    input [3:0]  reg_index,
    input [31:0] host_data
);
    logic do_accum, do_cr, do_filt, do_env;
begin
    do_accum = eng_wr_accum;
    do_cr    = eng_wr_cr;
    do_filt  = eng_wr_filt;
    do_env   = eng_wr_env;
    eng_wr_accum = 1'b0;
    eng_wr_cr    = 1'b0;
    eng_wr_filt  = 1'b0;
    eng_wr_env   = 1'b0;
    write_byte({reg_index, 2'd0}, host_data[31:24]);
    write_byte({reg_index, 2'd1}, host_data[23:16]);
    write_byte({reg_index, 2'd2}, host_data[15:8]);
    @(negedge clk);
    host_addr  = {reg_index, 2'd3};
    host_wdata = host_data[7:0];
    host_we    = 1'b1;
    eng_wr_accum = do_accum;
    eng_wr_cr    = do_cr;
    eng_wr_filt  = do_filt;
    eng_wr_env   = do_env;
    @(negedge clk);
    host_we       = 1'b0;
    eng_wr_accum  = 1'b0;
    eng_wr_cr     = 1'b0;
    eng_wr_filt   = 1'b0;
    eng_wr_env    = 1'b0;
    repeat (3) @(posedge clk);
end
endtask

logic [31:0] value;
logic [31:0] engine_start_before_steal;
logic [31:0] engine_end_before_steal;
logic [31:0] engine_accum_before_steal;

initial begin
    host_we    = 1'b0;
    host_re    = 1'b0;
    host_addr  = 6'd0;
    host_wdata = 8'd0;
    par_data   = 10'h155;
    irq_set    = 1'b0;
    irq_voice  = 5'd0;
    eng_voice = 5'd0;
    eng_wr_accum = 1'b0;
    eng_accum_w = 32'd0;
    eng_wr_cr = 1'b0;
    eng_cr_w = 16'd0;
    eng_wr_filt = 1'b0;
    eng_o4n1_w = 18'd0;
    eng_o3n1_w = 18'd0;
    eng_o3n2_w = 18'd0;
    eng_o2n1_w = 18'd0;
    eng_o2n2_w = 18'd0;
    eng_o1n1_w = 18'd0;
    eng_wr_env = 1'b0;
    eng_lvol_w = 16'd0;
    eng_rvol_w = 16'd0;
    eng_k1_w = 16'd0;
    eng_k2_w = 16'd0;
    eng_ecount_w = 9'd0;

    repeat (3) @(posedge clk);
    rst = 1'b0;
    cold_rst = 1'b0;
    // The cold-reset sweep initializes all 32 voice banks in parallel.
    repeat (35) @(posedge clk);
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

    // The hold bank intentionally has no reset. It is hidden by eng_hold until
    // this first byte-0 host steal captures every engine field on the same
    // edge, and must preserve the engine voice while the MLAB port recovers.
    engine_start_before_steal = eng_start;
    engine_end_before_steal   = eng_end;
    engine_accum_before_steal = eng_accum;
    @(negedge clk);
    host_addr = {4'h1, 2'd0};
    host_re   = 1'b1;
    @(posedge clk);
    #1;
    expect32(eng_start, engine_start_before_steal, "engine START during first steal");
    expect32(eng_end, engine_end_before_steal, "engine END during first steal");
    expect32(eng_accum, engine_accum_before_steal, "engine ACCUM during first steal");
    if (eng_cr_valid !== 1'b1) begin
        $display("FAIL engine CR validity during first steal");
        $fatal(1);
    end
    @(negedge clk);
    host_re = 1'b0;
    repeat (2) begin
        @(posedge clk);
        #1;
        expect32(eng_start, engine_start_before_steal, "engine START after first steal");
        expect32(eng_end, engine_end_before_steal, "engine END after first steal");
        expect32(eng_accum, engine_accum_before_steal, "engine ACCUM after first steal");
    end

    read_reg(4'h1, value);
    expect32(value, 32'h3894_3000, "voice16 START");
    read_reg(4'h2, value);
    expect32(value, 32'h3bb6_f000, "voice16 END mask");
    read_reg(4'h3, value);
    expect32(value, 32'h3894_3000, "voice16 ACCUM");

    // A host byte-3 commit used to silently discard an engine writeback on
    // the same edge. Different fields of the same voice must both survive.
    eng_voice    = 5'd16;
    eng_accum_w  = 32'hdead_beef;
    eng_wr_accum = 1'b1;
    collide_host_engine(4'h1, 32'h1122_3344);
    read_reg(4'h1, value);
    expect32(value, 32'h1122_3000, "host START across engine collision");
    read_reg(4'h3, value);
    expect32(value, 32'hdead_beef, "engine ACCUM replay after host collision");

    // If both writers target the same voice field, the host programming
    // transaction is authoritative and the stale engine value is discarded.
    eng_accum_w  = 32'hcafe_babe;
    eng_wr_accum = 1'b1;
    collide_host_engine(4'h3, 32'h5566_7788);
    read_reg(4'h3, value);
    expect32(value, 32'h5566_7788, "host ACCUM wins same-field collision");

    // A deferred control write must mark the deferred voice valid, not the
    // host-selected voice. Exercise a different voice to catch index errors.
    eng_voice = 5'd17;
    eng_cr_w  = 16'h8000;
    eng_wr_cr = 1'b1;
    collide_host_engine(4'h1, 32'h3894_3000);
    write_reg(4'hf, 32'h0000_0011);
    read_reg(4'h0, value);
    expect32(value, 32'h0000_8000, "voice17 deferred CR");
    write_reg(4'h0, 32'h0000_0003);
    write_reg(4'hf, 32'h0000_0030);
    write_reg(4'h3, 32'h3894_3000);

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

    // A watchdog/software reset restores only the ES5506 device-level mode;
    // programmed voice registers and PAGE survive it.
    rst = 1'b1;
    repeat (3) @(posedge clk);
    rst = 1'b0;
    @(posedge clk);
    if (active_voices !== 5'h1f || mode !== 5'h17) begin
        $display("FAIL soft reset device defaults");
        $fatal(1);
    end
    read_reg(4'h0, value);
    expect32(value, 32'h0000_8000, "voice16 CR after soft reset");
    read_reg(4'h1, value);
    expect32(value, 32'h0000_0800, "voice16 FC after soft reset");
    read_reg(4'h2, value);
    expect32(value, 32'h0000_f550, "voice16 LVOL after soft reset");

    // PAGE selects a distinct voice.
    write_reg(4'hf, 32'h0000_0011);
    read_reg(4'h0, value);
    expect32(value, 32'h0000_0003, "voice17 reset CR");
    read_reg(4'h2, value);
    expect32(value, 32'h0000_8000, "voice17 reset LVOL");
    read_reg(4'h4, value);
    expect32(value, 32'h0000_8000, "voice17 reset RVOL");
    write_reg(4'hf, 32'h0000_0031);
    read_reg(4'h1, value);
    expect32(value, 32'h0000_0000, "voice17 reset START");
    read_reg(4'h2, value);
    expect32(value, 32'h0000_0000, "voice17 reset END");
    read_reg(4'h3, value);
    expect32(value, 32'h0000_0000, "voice17 reset ACCUM");
    write_reg(4'hf, 32'h0000_0011);

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

    // A later voice retains CR.IRQ and must not displace an occupied IRQV.
    // The voice engine retries this event after the host acknowledges voice 18.
    @(negedge clk);
    irq_voice = 5'd19;
    irq_set   = 1'b1;
    @(negedge clk);
    irq_set   = 1'b0;
    read_reg(4'he, value);
    expect32(value, 32'h0000_0012, "IRQV snapshot");
    if (irq_n !== 1'b1) begin
        $display("FAIL IRQV acknowledge");
        $fatal(1);
    end
    @(negedge clk);
    irq_set   = 1'b1; // voice 19 retry after IRQV became available
    @(negedge clk);
    irq_set   = 1'b0;
    read_reg(4'he, value);
    expect32(value, 32'h0000_0013, "stacked IRQV promotion");

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
