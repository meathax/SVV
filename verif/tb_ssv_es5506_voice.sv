`timescale 1ns/1ps
// Focused ES5506 PCM path: one forward voice, bank-2 samples, expect non-zero audio.

module tb_ssv_es5506_voice;
import ssv_pkg::*;
logic clk = 0;
always #5 clk = ~clk;
logic rst = 1;
ssv_cfg_t cfg;
// Sparse enable like production ce_snd (~1/3). Catches ack-vs-ce races.
logic [1:0] ce_div = 0;
logic ce = 0;
always_ff @(posedge clk) begin
    if (rst) begin
        ce_div <= 0;
        ce <= 0;
    end else begin
        ce <= (ce_div == 2);
        ce_div <= (ce_div == 2) ? 0 : ce_div + 1'd1;
    end
end

logic [4:0] active_voices = 5'd0; // scan voice 0 only
logic [4:0] eng_voice;
logic [15:0] eng_cr = 16'h8000; // bank 2, running
logic        eng_cr_valid = 1;
logic [16:0] eng_fc = 17'h0800;
logic [15:0] eng_lvol = 16'hf550;
logic [7:0]  eng_lvramp = 0;
logic [15:0] eng_rvol = 16'hf550;
logic [7:0]  eng_rvramp = 0;
logic [8:0]  eng_ecount = 0;
logic [15:0] eng_k1 = 16'hff80;
logic [8:0]  eng_k1ramp = 0;
logic [15:0] eng_k2 = 16'hf030;
logic [8:0]  eng_k2ramp = 0;
logic [31:0] eng_start = 32'h00000000;
logic [31:0] eng_end   = 32'h00ffffff;
logic [31:0] eng_accum = 32'h00000000;
logic [17:0] eng_o4n1=0, eng_o3n1=0, eng_o3n2=0, eng_o2n1=0, eng_o2n2=0, eng_o1n1=0;

wire        eng_wr_accum, eng_wr_cr, eng_wr_filt, eng_wr_env, eng_irq_set;
wire [31:0] eng_accum_w;
wire [15:0] eng_cr_w, eng_lvol_w, eng_rvol_w, eng_k1_w, eng_k2_w;
wire [17:0] eng_o4n1_w, eng_o3n1_w, eng_o3n2_w, eng_o2n1_w, eng_o2n2_w, eng_o1n1_w;
wire [8:0]  eng_ecount_w;
wire [4:0]  eng_irq_voice;
logic       irq_ready = 1'b1;
logic       host_ecount_write = 1'b0;
logic [4:0] host_ecount_voice = 5'd0;

logic        sdr_req, sdr_ack;
logic [SDR_AW:1] sdr_addr;
logic [15:0] sdr_dout;
logic signed [15:0] audio_l, audio_r;
logic sample_tick, underrun;

// Tiny synthetic sample ROM: ramp at words 0..
logic [15:0] samp [0:255];
initial begin
    for (int i = 0; i < 256; i++)
        samp[i] = 16'(i * 128);
end

wire [SDR_AW:1] samp_base = SDR_SAMPLES_BASE[SDR_AW:1];
always_ff @(posedge clk) begin
    sdr_ack <= 0;
    if (!rst && sdr_req) begin
        // Dyna Gear plays CR bank 2, but that bank aliases loaded slot 0.
        // This catches the stale identity bank map that used to send it 8 MiB
        // beyond its only 4 MiB sample image.
        if ((sdr_addr - samp_base) >= (25'd1 << 21))
            $fatal(1, "Dyna Gear bank 2 did not alias sample slot 0: %h",
                   sdr_addr);
        sdr_dout <= samp[(sdr_addr - samp_base) & 21'hff];
        sdr_ack  <= 1;
    end
end

ssv_es5506_voice dut (
    .cfg, .clk, .rst, .ce,
    .active_voices,
    .eng_voice,
    .eng_cr, .eng_cr_valid, .eng_fc,
    .eng_lvol, .eng_lvramp, .eng_rvol, .eng_rvramp,
    .eng_ecount, .eng_k1, .eng_k1ramp, .eng_k2, .eng_k2ramp,
    .eng_start, .eng_end, .eng_accum,
    .eng_o4n1, .eng_o3n1, .eng_o3n2, .eng_o2n1, .eng_o2n2, .eng_o1n1,
    .eng_wr_accum, .eng_accum_w, .eng_wr_cr, .eng_cr_w,
    .eng_wr_filt, .eng_o4n1_w, .eng_o3n1_w, .eng_o3n2_w,
    .eng_o2n1_w, .eng_o2n2_w, .eng_o1n1_w,
    .eng_wr_env, .eng_lvol_w, .eng_rvol_w, .eng_k1_w, .eng_k2_w, .eng_ecount_w,
    .irq_ready,
    .eng_irq_set, .eng_irq_voice,
    .host_ecount_write, .host_ecount_voice,
    .sdr_req, .sdr_addr, .sdr_dout, .sdr_ack,
    .audio_l, .audio_r, .sample_tick, .underrun
);

// Simple writeback model
always_ff @(posedge clk) begin
    if (!rst) begin
        if (eng_wr_accum) eng_accum <= eng_accum_w;
        if (eng_wr_cr) eng_cr <= eng_cr_w;
        if (eng_wr_filt) begin
            eng_o1n1 <= eng_o1n1_w;
            eng_o2n1 <= eng_o2n1_w;
            eng_o2n2 <= eng_o2n2_w;
            eng_o3n1 <= eng_o3n1_w;
            eng_o3n2 <= eng_o3n2_w;
            eng_o4n1 <= eng_o4n1_w;
        end
        if (eng_wr_env) begin
            eng_lvol <= eng_lvol_w;
            eng_rvol <= eng_rvol_w;
            eng_k1 <= eng_k1_w;
            eng_k2 <= eng_k2_w;
            eng_ecount <= eng_ecount_w;
        end
    end
end

integer sdr_fetches;
integer irq_events;
always_ff @(posedge clk) begin
    if (rst) begin
        sdr_fetches <= 0;
        irq_events <= 0;
    end else begin
        if (sdr_ack && sdr_req) sdr_fetches <= sdr_fetches + 1;
        if (eng_irq_set) irq_events <= irq_events + 1;
    end
end

task automatic defaults;
begin
    active_voices = 5'd0;
    eng_cr = 16'h8000;
    eng_cr_valid = 1'b1;
    eng_fc = 17'h0800;
    eng_lvol = 16'hf550;
    eng_lvramp = 8'd0;
    eng_rvol = 16'hf550;
    eng_rvramp = 8'd0;
    eng_ecount = 9'd0;
    eng_k1 = 16'hff80;
    eng_k1ramp = 9'd0;
    eng_k2 = 16'hf030;
    eng_k2ramp = 9'd0;
    eng_start = 32'h0000_0000;
    eng_end = 32'h00ff_ffff;
    eng_accum = 32'h0000_0000;
    eng_o4n1 = 18'd0;
    eng_o3n1 = 18'd0;
    eng_o3n2 = 18'd0;
    eng_o2n1 = 18'd0;
    eng_o2n2 = 18'd0;
    eng_o1n1 = 18'd0;
    irq_ready = 1'b1;
    host_ecount_write = 1'b0;
    host_ecount_voice = 5'd0;
end
endtask

task automatic reset_dut;
begin
    rst = 1'b1;
    repeat (4) @(posedge clk);
    rst = 1'b0;
end
endtask

task automatic wait_sample;
begin
    @(posedge sample_tick);
    #1;
end
endtask

integer ticks;
initial begin
    cfg = cfg_dynagear();
    defaults();
    reset_dut();

    // Baseline forward PCM and bank-2 alias path.
    for (ticks = 0; ticks < 8; ticks = ticks + 1) wait_sample();
    if (audio_l == 0 && audio_r == 0)
        $fatal(1, "baseline PCM remained silent");

    // BLE without LPE is ES5506 trans-wave mode: wrap once, clear BLE/LPE,
    // and set LEI so later crossings do not loop again.
    defaults();
    eng_cr = 16'h8010;
    eng_start = 32'h0000_0000;
    eng_end = 32'h0000_1000;
    eng_accum = 32'h0000_1000;
    reset_dut();
    wait_sample();
    if (eng_accum !== 32'h0000_0800 || eng_cr !== 16'h8004)
        $fatal(1, "BLE trans-wave mismatch accum=%08x cr=%04x",
               eng_accum, eng_cr);

    // START == END stops before either sample word is fetched.
    defaults();
    eng_start = 32'h0012_3000;
    eng_end = 32'h0012_3000;
    eng_accum = 32'h0012_3000;
    reset_dut();
    wait_sample();
    if (sdr_fetches != 0 || !(eng_cr & 16'h0001) ||
        eng_accum !== 32'h0012_3000)
        $fatal(1, "START==END did not stop before fetch: fetches=%0d cr=%04x accum=%08x",
               sdr_fetches, eng_cr, eng_accum);

    // Envelopes continue while stopped. Slow negative K ramps use the old
    // filtcount, so they step immediately at count zero but not at count one.
    defaults();
    eng_cr = 16'h8001;
    eng_lvol = 16'h0100;
    eng_lvramp = 8'h01;
    eng_rvol = 16'h0200;
    eng_rvramp = 8'hff;
    eng_k1 = 16'h1000;
    eng_k1ramp = 9'h1ff;
    eng_k2 = 16'h2000;
    eng_k2ramp = 9'h001;
    eng_ecount = 9'd3;
    reset_dut();
    wait_sample();
    if (eng_lvol !== 16'h0101 || eng_rvol !== 16'h01ff ||
        eng_k1 !== 16'h0fff || eng_k2 !== 16'h2001 || eng_ecount !== 9'd2)
        $fatal(1, "stopped envelope tick0 mismatch");
    wait_sample();
    if (eng_lvol !== 16'h0102 || eng_rvol !== 16'h01fe ||
        eng_k1 !== 16'h0fff || eng_k2 !== 16'h2002 || eng_ecount !== 9'd1)
        $fatal(1, "stopped envelope tick1 mismatch");

    // A new ECOUNT write restarts slow-ramp cadence at zero.
    @(negedge clk);
    eng_ecount = 9'd2;
    host_ecount_write = 1'b1;
    @(negedge clk);
    host_ecount_write = 1'b0;
    wait_sample();
    if (eng_k1 !== 16'h0ffe)
        $fatal(1, "ECOUNT write did not restart slow K-ramp cadence: k1=%04x",
               eng_k1);

    // A boundary IRQ remains pending in CR while IRQV is occupied. Once the
    // prior vector is acknowledged, the stopped voice promotes and clears it.
    defaults();
    eng_cr = 16'h8020;
    eng_start = 32'h0000_0000;
    eng_end = 32'h0000_1000;
    eng_accum = 32'h0000_1000;
    irq_ready = 1'b0;
    reset_dut();
    wait_sample();
    if (irq_events != 0 || !(eng_cr & 16'h0080))
        $fatal(1, "busy IRQV did not retain voice IRQ: events=%0d cr=%04x",
               irq_events, eng_cr);
    irq_ready = 1'b1;
    wait_sample();
    if (irq_events != 1 || (eng_cr & 16'h0080))
        $fatal(1, "pending voice IRQ was not promoted/cleared: events=%0d cr=%04x",
               irq_events, eng_cr);

    // Compressed mode must run and fetch words; it is not a STOP condition.
    defaults();
    samp[0] = 16'h7f00;
    samp[1] = 16'h7f00;
    eng_cr = 16'ha000;
    reset_dut();
    wait_sample();
    if (sdr_fetches < 2 || eng_accum !== 32'h0000_0800)
        $fatal(1, "compressed voice did not execute: fetches=%0d accum=%08x",
               sdr_fetches, eng_accum);
    if (audio_l <= 0 || audio_r <= 0)
        $fatal(1, "positive compressed code produced non-positive audio: L=%0d R=%0d",
               audio_l, audio_r);

    // The adjacent code is on the negative side of the MAME table.  This
    // catches a decoder that merely scales the high byte as PCM.
    samp[0] = 16'h8000;
    samp[1] = 16'h8000;
    reset_dut();
    wait_sample();
    if (audio_l >= 0 || audio_r >= 0)
        $fatal(1, "negative compressed code produced non-negative audio: L=%0d R=%0d",
               audio_l, audio_r);

    $display("PASS tb_ssv_es5506_voice semantics");
    $finish;
end

initial begin
    #2_000_000;
    $fatal(1, "timeout waiting for ES5506 voice semantic tests");
end
endmodule
