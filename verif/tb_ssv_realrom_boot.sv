`timescale 1ns/1ps

module tb_ssv_realrom_boot;
logic clk_sys = 0;
always #5 clk_sys = ~clk_sys;
logic rst, ce_cpu;
logic [1:0] ce_div;
logic sdr_p0_req, sdr_p0_ack;
logic [24:1] sdr_p0_addr;
logic [15:0] sdr_p0_dout;
logic sdr_p1_req, sdr_p1_ack;
logic [24:3] sdr_p1_addr;
logic [63:0] sdr_p1_dout;

logic sdr_wr_req, sdr_wr_ack;
logic [24:1] sdr_wr_addr;
logic [15:0] sdr_wr_din;
logic [1:0] sdr_wr_be;
logic [23:0] rgb;
logic ce_pixel, hs, vs, hb, vb;
logic signed [15:0] audio_l, audio_r;
logic [31:0] debug_pc;
logic [23:0] debug_status;
byte rom_bytes [0:1048575];
string rom_path;
string trace_path;
string irq_schedule_path;
string write_trace_path;
integer fd, read_count, cycles;
integer trace_fd, write_trace_fd, trace_cycles;
integer irq_schedule_fd, irq_scan_result;
logic [31:0] trace_last_pc;
logic [31:0] trace_window_start, trace_window_end;
logic trace_window_enabled, trace_window_active;
logic trace_pc_only, trace_hash_only;
logic diff_irq_enabled, diff_vblank_pulse;
logic diff_count_started;
longint unsigned retire_count, next_irq_retire;
logic p0_seen;
logic [1:0] ack_hold;
logic [31:0] first_changed_pc;
logic booted;

ssv_core dut (
    .clk_sys(clk_sys), .rst(rst), .ce_cpu(ce_cpu),
    .sdr_p0_req(sdr_p0_req), .sdr_p0_addr(sdr_p0_addr),
    .sdr_p0_dout(sdr_p0_dout), .sdr_p0_ack(sdr_p0_ack),
    .sdr_p1_req(sdr_p1_req), .sdr_p1_addr(sdr_p1_addr),
    .sdr_p1_dout(sdr_p1_dout), .sdr_p1_ack(sdr_p1_ack),
    .sdr_wr_req(sdr_wr_req), .sdr_wr_addr(sdr_wr_addr),
    .sdr_wr_din(sdr_wr_din), .sdr_wr_be(sdr_wr_be),
    .sdr_wr_ack(sdr_wr_ack),
    .in_dsw1(16'hffff), .in_dsw2(16'hfffd),
    .in_p1(16'hffff), .in_p2(16'hffff),
    .in_system(16'hffff), .in_extra(16'hffff),
    .rgb(rgb), .ce_pixel(ce_pixel), .hs(hs), .vs(vs), .hb(hb), .vb(vb),
    .audio_l(audio_l), .audio_r(audio_r),
    .debug_pc(debug_pc), .debug_status(debug_status)
);

function automatic logic [63:0] v60_state_hash;
    logic [63:0] hash;
    integer hash_i;
    begin
        hash = 64'hcbf29ce484222325;
        hash = (hash ^ {32'd0, dut.cpu.psw}) *
               64'h00000100000001b3;
        for (hash_i = 0; hash_i < 32; hash_i = hash_i + 1)
            hash = (hash ^ {32'd0, dut.cpu.r[hash_i]}) *
                   64'h00000100000001b3;
        v60_state_hash = hash;
    end
endfunction

always_ff @(posedge clk_sys) begin
    if (rst) begin
        ce_div <= 0;
        ce_cpu <= 0;
    end
    else begin
        ce_cpu <= (ce_div == 2);
        ce_div <= (ce_div == 2) ? 0 : ce_div + 1'd1;
    end
end

always_ff @(posedge clk_sys) begin
    sdr_p0_ack <= 0;
    sdr_p1_ack <= 0;
    sdr_p1_dout <= 64'd0;
    sdr_wr_ack <= 0;
    if (rst) begin
        p0_seen <= 0;
        ack_hold <= 0;
    end
    else begin
        if (sdr_p0_req && !p0_seen) begin
            p0_seen <= 1;
            sdr_p0_dout <= {
                rom_bytes[{sdr_p0_addr[19:1], 1'b0} + 1],
                rom_bytes[{sdr_p0_addr[19:1], 1'b0}]
            };
            ack_hold <= 2;
        end
        if (!sdr_p0_req) p0_seen <= 0;
        if (ack_hold != 0) begin
            sdr_p0_ack <= 1;
            ack_hold <= ack_hold - 1'd1;
        end
        if (sdr_wr_req) sdr_wr_ack <= 1;
    end
end

always_comb begin
    diff_vblank_pulse =
        diff_irq_enabled && diff_count_started && ce_cpu &&
        dut.cpu.st == 7'd3 &&
        retire_count + 1 == next_irq_retire;
end

always_ff @(posedge clk_sys) begin
    if (rst) begin
        retire_count <= 0;
        diff_count_started <= 1'b0;
    end else begin
        if (ce_cpu && dut.cpu.st == 7'd3 &&
            !(!dut.irq_n && dut.cpu.psw_ie)) begin
            if (!diff_count_started) begin
                if (dut.cpu.pc == 32'h00f1_0120) begin
                    diff_count_started <= 1'b1;
                    retire_count <= 1;
                end
            end else begin
                if (diff_irq_enabled &&
                    retire_count + 1 == next_irq_retire) begin
                    irq_scan_result = $fscanf(
                        irq_schedule_fd, "%d\n", next_irq_retire);
                    if (irq_scan_result != 1)
                        next_irq_retire <= {64{1'b1}};
                end
                retire_count <= retire_count + 1;
            end
        end
    end
end

always_ff @(posedge clk_sys) begin
    if (rst) begin
        trace_window_active <= 1'b0;
    end else if (trace_fd != 0 && ce_cpu && dut.cpu.st == 7'd3 &&
                 !(!dut.irq_n && dut.cpu.psw_ie)) begin
        if (!trace_window_enabled || trace_window_active ||
            dut.cpu.pc == trace_window_start) begin
            if (trace_pc_only)
                $fdisplay(trace_fd, "%08x", dut.cpu.pc);
            else if (trace_hash_only)
                $fdisplay(trace_fd, "HASH %08x %016x",
                          dut.cpu.pc, v60_state_hash());
            else
                $fdisplay(trace_fd, "STATE %08x %08x %08x %08x %08x %08x",
                          dut.cpu.pc, dut.cpu.psw, dut.cpu.r[0],
                          dut.cpu.r[1], dut.cpu.r[2], dut.cpu.r[31]);
        end
        if (trace_window_enabled) begin
            if (dut.cpu.pc == trace_window_end) trace_window_active <= 1'b0;
            else if (dut.cpu.pc == trace_window_start) trace_window_active <= 1'b1;
        end
    end
end

always_ff @(posedge clk_sys) begin
    if (!rst && write_trace_fd != 0 &&
        ce_cpu && dut.m_req && dut.m_we && dut.m_ack)
        $fdisplay(write_trace_fd, "WRITE %08x %04x %04x",
                  {8'd0, dut.m_addr, 1'b0},
                  dut.m_wdata,
                  {{8{dut.m_be[1]}}, {8{dut.m_be[0]}}});
end

initial begin
    if (!$value$plusargs("ROM=%s", rom_path))
        rom_path = "sim_output/rom/maincpu.bin";
    fd = $fopen(rom_path, "rb");
    if (fd == 0) $fatal(1, "cannot open ROM image: %s", rom_path);
    read_count = $fread(rom_bytes, fd);
    $fclose(fd);
    if (read_count != 1048576)
        $fatal(1, "short ROM read: %0d", read_count);

    trace_fd = 0;
    trace_last_pc = 32'hffffffff;
    trace_window_start = 0;
    trace_window_end = 0;
    trace_window_enabled =
        $value$plusargs("TRACE_WINDOW_START=%h", trace_window_start) &&
        $value$plusargs("TRACE_WINDOW_END=%h", trace_window_end);
    trace_pc_only = $test$plusargs("TRACE_PC_ONLY");
    trace_hash_only = $test$plusargs("TRACE_HASH_ONLY");
    diff_irq_enabled = 1'b0;
    irq_schedule_fd = 0;
    if ($value$plusargs("DIFF_IRQ_SCHEDULE=%s", irq_schedule_path)) begin
        irq_schedule_fd = $fopen(irq_schedule_path, "r");
        if (irq_schedule_fd == 0)
            $fatal(1, "cannot open IRQ schedule: %s", irq_schedule_path);
        irq_scan_result = $fscanf(
            irq_schedule_fd, "%d\n", next_irq_retire);
        if (irq_scan_result != 1)
            $fatal(1, "empty IRQ schedule: %s", irq_schedule_path);
        diff_irq_enabled = 1'b1;
        force dut.vblank_pulse = diff_vblank_pulse;
    end
    if ($value$plusargs("TRACE=%s", trace_path)) begin
        trace_fd = $fopen(trace_path, "w");
        if (trace_fd == 0) $fatal(1, "cannot open trace output: %s", trace_path);
    end
    write_trace_fd = 0;
    if ($value$plusargs("WRITE_TRACE=%s", write_trace_path)) begin
        write_trace_fd = $fopen(write_trace_path, "w");
        if (write_trace_fd == 0) $fatal(1, "cannot open write trace: %s", write_trace_path);
    end
    if (!$value$plusargs("TRACE_CYCLES=%d", trace_cycles))
        trace_cycles = 0;

    rst = 1;
    repeat (8) @(posedge clk_sys);
    rst = 0;
    if (trace_cycles > 0) begin
        repeat (trace_cycles) @(posedge clk_sys);
        if (trace_fd != 0) $fclose(trace_fd);
        if (write_trace_fd != 0) $fclose(write_trace_fd);
        $display("PASS tb_ssv_realrom_boot trace cycles=%0d pc=%08x", trace_cycles, debug_pc);
        $finish;
    end

    first_changed_pc = 0;
    booted = 0;
    cycles = 0;
    while (!booted && cycles < 200000) begin
        @(posedge clk_sys);
        cycles = cycles + 1;
        if (debug_pc != 32'hfffffff0 && debug_pc != 0 && first_changed_pc == 0)
            first_changed_pc = debug_pc;
        if (debug_pc[31:24] == 8'h00 && debug_pc != 0)
            booted = 1;
    end
    if (!booted)
        $fatal(1, "V60 did not leave reset ROM window: pc=%08x first=%08x status=%06x",
               debug_pc, first_changed_pc, debug_status);
    $display("PASS tb_ssv_realrom_boot pc=%08x first=%08x cycles=%0d",
             debug_pc, first_changed_pc, cycles);
    $finish;
end
endmodule
