`timescale 1ns/1ps
// Focused ES5506 PCM path: one forward voice, bank-2 samples, expect non-zero audio.

module tb_ssv_es5506_voice;
import ssv_pkg::*;
logic clk = 0;
always #5 clk = ~clk;
logic rst = 1;
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

logic        sdr_req, sdr_ack;
logic [24:1] sdr_addr;
logic [15:0] sdr_dout;
logic signed [15:0] audio_l, audio_r;
logic sample_tick, underrun;

// Tiny synthetic sample ROM: ramp at words 0..
logic [15:0] samp [0:255];
initial begin
    for (int i = 0; i < 256; i++)
        samp[i] = 16'(i * 128);
end

wire [24:1] samp_base = SDR_SAMPLES_BASE[24:1];
always_ff @(posedge clk) begin
    sdr_ack <= 0;
    if (!rst && sdr_req) begin
        sdr_dout <= samp[(sdr_addr - samp_base) & 21'hff];
        sdr_ack  <= 1;
    end
end

ssv_es5506_voice dut (
    .clk, .rst, .ce,
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
    .eng_irq_set, .eng_irq_voice,
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
    end
end

integer ticks;
initial begin
    ticks = 0;
    repeat (4) @(posedge clk);
    rst = 0;
    forever begin
        @(posedge clk);
        if (sample_tick) begin
            ticks = ticks + 1;
            if (ticks == 1)
                $display("first sample L=%0d R=%0d accum=%08x",
                         audio_l, audio_r, eng_accum);
            if (ticks >= 8) begin
                if (audio_l == 0 && audio_r == 0)
                    $fatal(1, "audio still silent after %0d ticks", ticks);
                $display("PASS tb_ssv_es5506_voice ticks=%0d L=%0d R=%0d",
                         ticks, audio_l, audio_r);
                $finish;
            end
        end
        if ($time > 1_000_000)
            $fatal(1, "timeout waiting for sample_tick");
    end
end
endmodule
