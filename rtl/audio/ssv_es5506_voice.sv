// SPDX-License-Identifier: GPL-3.0-or-later
// Ensoniq ES5506 voice scheduler / PCM / filter / mixer.
// OTTO Spec Rev. 2.3 + MAME es5506.cpp behavioral cross-check.
// See docs/ES5506_RESEARCH.md.
`timescale 1ns/1ps

module ssv_es5506_voice (
    input  logic        clk,
    input  logic        rst,
    input  logic        ce,

    input  logic [4:0]  active_voices,

    output logic [4:0]  eng_voice,
    input  logic [15:0] eng_cr,
    input  logic        eng_cr_valid,
    input  logic [16:0] eng_fc,
    input  logic [15:0] eng_lvol,
    input  logic [7:0]  eng_lvramp,
    input  logic [15:0] eng_rvol,
    input  logic [7:0]  eng_rvramp,
    input  logic [8:0]  eng_ecount,
    input  logic [15:0] eng_k1,
    input  logic [8:0]  eng_k1ramp,
    input  logic [15:0] eng_k2,
    input  logic [8:0]  eng_k2ramp,
    input  logic [31:0] eng_start,
    input  logic [31:0] eng_end,
    input  logic [31:0] eng_accum,
    input  logic [17:0] eng_o4n1,
    input  logic [17:0] eng_o3n1,
    input  logic [17:0] eng_o3n2,
    input  logic [17:0] eng_o2n1,
    input  logic [17:0] eng_o2n2,
    input  logic [17:0] eng_o1n1,

    output logic        eng_wr_accum,
    output logic [31:0] eng_accum_w,
    output logic        eng_wr_cr,
    output logic [15:0] eng_cr_w,
    output logic        eng_wr_filt,
    output logic [17:0] eng_o4n1_w,
    output logic [17:0] eng_o3n1_w,
    output logic [17:0] eng_o3n2_w,
    output logic [17:0] eng_o2n1_w,
    output logic [17:0] eng_o2n2_w,
    output logic [17:0] eng_o1n1_w,
    output logic        eng_wr_env,
    output logic [15:0] eng_lvol_w,
    output logic [15:0] eng_rvol_w,
    output logic [15:0] eng_k1_w,
    output logic [15:0] eng_k2_w,
    output logic [8:0]  eng_ecount_w,
    output logic        eng_irq_set,
    output logic [4:0]  eng_irq_voice,

    output logic        sdr_req,
    output logic [24:1] sdr_addr,
    input  logic [15:0] sdr_dout,
    input  logic        sdr_ack,

    output logic signed [15:0] audio_l,
    output logic signed [15:0] audio_r,
    output logic        sample_tick,
    output logic        underrun
);

import ssv_pkg::*;

localparam logic [15:0] CR_STOP = 16'h0003;
localparam logic [15:0] CR_DIR  = 16'h0040;
localparam logic [15:0] CR_IRQE = 16'h0020;
localparam logic [15:0] CR_IRQ  = 16'h0080;
localparam logic [15:0] CR_BLE  = 16'h0010;
localparam logic [15:0] CR_LPE  = 16'h0008;
localparam logic [15:0] CR_LEI  = 16'h0004;
localparam logic [15:0] CR_CMPD = 16'h2000;

typedef enum logic [2:0] {
    S_START, S_WAIT1, S_REQ2, S_WAIT2, S_PROC, S_NEXT
} st_t;

st_t state;
logic [4:0] voice_i;
logic [3:0] filtcount [0:31];
logic signed [23:0] mix_l, mix_r;
logic signed [15:0] s1, s2;
logic        got_ack;
logic [15:0] cr;
logic        cr_valid;
logic [16:0] fc;
logic [15:0] lvol, rvol, k1, k2;
logic [7:0]  lvramp, rvramp;
logic [8:0]  ecount, k1ramp, k2ramp;
logic [31:0] vstart, vend, accum;
logic [17:0] o4n1, o3n1, o3n2, o2n1, o2n2, o1n1;

wire stopped = !cr_valid || |(cr & CR_STOP) || |(cr & CR_CMPD);

function automatic logic [15:0] vol_gain(input logic [15:0] vol);
    logic [11:0] idx;
    logic [3:0]  e;
    logic [8:0]  m;
    begin
        idx = vol[15:4];
        e   = idx[11:8];
        m   = {1'b1, idx[7:0]};
        vol_gain = 16'((32'(m) << 7) >> (16 - e));
    end
endfunction

function automatic logic signed [17:0] sat18(input logic signed [31:0] v);
    if (v > 32'sh0001_ffff) return 18'sh1ffff;
    if (v < -32'sh0002_0000) return -18'sh20000;
    return v[17:0];
endfunction

function automatic logic signed [17:0] lp(
    input logic signed [17:0] x,
    input logic [15:0] k,
    input logic signed [17:0] h
);
    logic signed [31:0] t;
    begin
        t = (($signed({{14{x[17]}}, x}) - $signed({{14{h[17]}}, h}))
             * $signed({1'b0, k[15:4]})) >>> 12;
        lp = sat18($signed({{14{h[17]}}, h}) + t);
    end
endfunction

function automatic logic signed [17:0] hp(
    input logic signed [17:0] x,
    input logic [15:0] k,
    input logic signed [17:0] h,
    input logic signed [17:0] prev
);
    logic signed [31:0] t;
    begin
        t = ($signed({1'b0, k[15:4]}) * $signed({{14{h[17]}}, h})) >>> 13;
        hp = sat18($signed({{14{x[17]}}, x}) - $signed({{14{prev[17]}}, prev})
                   + t + ($signed({{14{h[17]}}, h}) >>> 1));
    end
endfunction

function automatic logic signed [15:0] lerp(
    input logic signed [15:0] a,
    input logic signed [15:0] b,
    input logic [31:0] acc
);
    logic [8:0] frac;
    logic signed [31:0] t;
    begin
        frac = acc[10:2];
        t = $signed(a) * (32'sd512 - 32'(frac)) + $signed(b) * 32'(frac);
        lerp = t[24:9];
    end
endfunction

assign eng_voice = voice_i;

// Sample SDRAM handshake is independent of ce_snd. Production ce_snd is a
// sparse ~16 MHz enable; acks arrive on clk_sys and must not be dropped.
always_ff @(posedge clk) begin
    if (rst) begin
        state <= S_START;
        voice_i <= '0;
        sdr_req <= 1'b0;
        sdr_addr <= '0;
        got_ack <= 1'b0;
        mix_l <= '0;
        mix_r <= '0;
        audio_l <= '0;
        audio_r <= '0;
        sample_tick <= 1'b0;
        underrun <= 1'b0;
        eng_wr_accum <= 1'b0;
        eng_wr_cr <= 1'b0;
        eng_wr_filt <= 1'b0;
        eng_wr_env <= 1'b0;
        eng_irq_set <= 1'b0;
        eng_accum_w <= '0;
        eng_cr_w <= '0;
        eng_o4n1_w <= '0;
        eng_o3n1_w <= '0;
        eng_o3n2_w <= '0;
        eng_o2n1_w <= '0;
        eng_o2n2_w <= '0;
        eng_o1n1_w <= '0;
        eng_lvol_w <= '0;
        eng_rvol_w <= '0;
        eng_k1_w <= '0;
        eng_k2_w <= '0;
        eng_ecount_w <= '0;
        eng_irq_voice <= '0;
        for (int i = 0; i < 32; i++) filtcount[i] <= '0;
    end else begin
        sample_tick <= 1'b0;
        eng_wr_accum <= 1'b0;
        eng_wr_cr <= 1'b0;
        eng_wr_filt <= 1'b0;
        eng_wr_env <= 1'b0;
        eng_irq_set <= 1'b0;

        // Capture SDRAM data whenever ack pulses, even if ce is low.
        if (sdr_ack && sdr_req) begin
            sdr_req <= 1'b0;
            if (state == S_WAIT1 && !got_ack) begin
                s1 <= sdr_dout;
                got_ack <= 1'b1;
            end else if (state == S_WAIT2 && !got_ack) begin
                s2 <= sdr_dout;
                got_ack <= 1'b1;
            end
        end

        if (ce) begin
            unique case (state)
                S_START: begin
                    cr       <= eng_cr_valid ? eng_cr : 16'h0003;
                    cr_valid <= eng_cr_valid;
                    fc       <= eng_fc;
                    lvol     <= eng_lvol;
                    rvol     <= eng_rvol;
                    lvramp   <= eng_lvramp;
                    rvramp   <= eng_rvramp;
                    ecount   <= eng_ecount;
                    k1       <= eng_k1;
                    k2       <= eng_k2;
                    k1ramp   <= eng_k1ramp;
                    k2ramp   <= eng_k2ramp;
                    vstart   <= eng_start;
                    vend     <= eng_end;
                    accum    <= eng_accum;
                    o4n1     <= eng_o4n1;
                    o3n1     <= eng_o3n1;
                    o3n2     <= eng_o3n2;
                    o2n1     <= eng_o2n1;
                    o2n2     <= eng_o2n2;
                    o1n1     <= eng_o1n1;
                    if (!eng_cr_valid ||
                        |((eng_cr_valid ? eng_cr : 16'h0003) & CR_STOP) ||
                        ((eng_cr_valid ? eng_cr : 16'h0) & CR_CMPD)) begin
                        s1 <= '0;
                        s2 <= '0;
                        state <= S_PROC;
                    end else if ((eng_cr_valid ? eng_cr[15:14] : 2'b00) != 2'b10) begin
                        // Only bank 2 is populated for Dyna Gear.
                        s1 <= '0;
                        s2 <= '0;
                        state <= S_PROC;
                    end else begin
                        sdr_addr <= SDR_SAMPLES_BASE[24:1] + {4'd0, eng_accum[31:11]};
                        sdr_req  <= 1'b1;
                        got_ack  <= 1'b0;
                        state    <= S_WAIT1;
                    end
                end

                S_WAIT1: if (got_ack) begin
                    got_ack <= 1'b0;
                    state <= S_REQ2;
                end

                S_REQ2: begin
                    sdr_addr <= SDR_SAMPLES_BASE[24:1] + {4'd0, accum[31:11] + 21'd1};
                    sdr_req  <= 1'b1;
                    got_ack  <= 1'b0;
                    state    <= S_WAIT2;
                end

                S_WAIT2: if (got_ack) begin
                    got_ack <= 1'b0;
                    state <= S_PROC;
                end

                S_PROC: begin
                    // Defaults for writebacks
                    eng_accum_w <= accum;
                    eng_cr_w <= cr;
                    eng_o1n1_w <= o1n1;
                    eng_o2n1_w <= o2n1;
                    eng_o2n2_w <= o2n2;
                    eng_o3n1_w <= o3n1;
                    eng_o3n2_w <= o3n2;
                    eng_o4n1_w <= o4n1;
                    eng_lvol_w <= lvol;
                    eng_rvol_w <= rvol;
                    eng_k1_w <= k1;
                    eng_k2_w <= k2;
                    eng_ecount_w <= ecount;

                    if (!stopped) begin
                        logic signed [15:0] ip;
                        logic signed [17:0] p1, p2, p3, p4, xin;
                        logic [31:0] accn;
                        logic [15:0] crn;
                        logic signed [31:0] aL, aR;
                        logic [15:0] gL, gR;
                        logic do_irq;
                        logic [1:0] lpm;
                        logic [3:0] fcc;

                        ip  = lerp(s1, s2, accum);
                        accn = (cr & CR_DIR) ? (accum - {15'd0, fc})
                                             : (accum + {15'd0, fc});
                        crn = cr;
                        do_irq = 1'b0;
                        lpm = cr[9:8];

                        if (!(cr & CR_DIR) && (accn > vend) && !(cr & CR_LEI)) begin
                            if (cr & CR_IRQE) begin crn = crn | CR_IRQ; do_irq = 1'b1; end
                            unique case (cr & (CR_LPE|CR_BLE))
                                16'h0000, CR_BLE: crn = crn | 16'h0001;
                                CR_LPE: accn = vstart + (accn - vend);
                                default: begin
                                    accn = vend - (accn - vend);
                                    crn = crn ^ CR_DIR;
                                end
                            endcase
                        end else if ((cr & CR_DIR) && (accn < vstart) && !(cr & CR_LEI)) begin
                            if (cr & CR_IRQE) begin crn = crn | CR_IRQ; do_irq = 1'b1; end
                            unique case (cr & (CR_LPE|CR_BLE))
                                16'h0000, CR_BLE: crn = crn | 16'h0001;
                                CR_LPE: accn = vend - (vstart - accn);
                                default: begin
                                    accn = vstart + (vstart - accn);
                                    crn = crn ^ CR_DIR;
                                end
                            endcase
                        end

                        xin = {{2{ip[15]}}, ip};
                        p1 = lp(xin, k1, o1n1);
                        p2 = lp(p1, k1, o2n1);
                        unique case (lpm)
                            2'b00: begin
                                p3 = hp(p2, k2, o3n1, o2n2);
                                p4 = hp(p3, k2, o4n1, o3n2);
                            end
                            2'b01: begin
                                p3 = lp(p2, k1, o3n1);
                                p4 = hp(p3, k2, o4n1, o3n2);
                            end
                            2'b10: begin
                                p3 = lp(p2, k2, o3n1);
                                p4 = lp(p3, k2, o4n1);
                            end
                            default: begin
                                p3 = lp(p2, k1, o3n1);
                                p4 = lp(p3, k2, o4n1);
                            end
                        endcase

                        gL = vol_gain(lvol);
                        gR = vol_gain(rvol);
                        aL = $signed(p4[17:2]) * $signed({1'b0, gL});
                        aR = $signed(p4[17:2]) * $signed({1'b0, gR});
                        mix_l <= mix_l + (aL >>> 11);
                        mix_r <= mix_r + (aR >>> 11);

                        eng_wr_accum <= 1'b1;
                        eng_accum_w  <= accn;
                        eng_wr_filt  <= 1'b1;
                        eng_o1n1_w   <= p1;
                        eng_o2n2_w   <= o2n1;
                        eng_o2n1_w   <= p2;
                        eng_o3n2_w   <= o3n1;
                        eng_o3n1_w   <= p3;
                        eng_o4n1_w   <= p4;
                        if (crn != cr) begin
                            eng_wr_cr <= 1'b1;
                            eng_cr_w  <= crn;
                        end
                        if (do_irq) begin
                            eng_irq_set <= 1'b1;
                            eng_irq_voice <= voice_i;
                        end

                        if (ecount != 9'd0) begin
                            logic signed [16:0] tmp;
                            fcc = filtcount[voice_i] + 4'd1;
                            filtcount[voice_i] <= fcc;
                            eng_wr_env <= 1'b1;
                            eng_ecount_w <= ecount - 9'd1;
                            if (lvramp != 8'd0) begin
                                tmp = $signed({1'b0, lvol}) + $signed({{9{lvramp[7]}}, lvramp});
                                if (tmp < 0) eng_lvol_w <= 16'd0;
                                else if (tmp > 17'sh0ffff) eng_lvol_w <= 16'hffff;
                                else eng_lvol_w <= tmp[15:0];
                            end
                            if (rvramp != 8'd0) begin
                                tmp = $signed({1'b0, rvol}) + $signed({{9{rvramp[7]}}, rvramp});
                                if (tmp < 0) eng_rvol_w <= 16'd0;
                                else if (tmp > 17'sh0ffff) eng_rvol_w <= 16'hffff;
                                else eng_rvol_w <= tmp[15:0];
                            end
                            if (k1ramp[7:0] != 8'd0 && (!k1ramp[8] || fcc[2:0] == 3'd0)) begin
                                tmp = $signed({1'b0, k1}) + $signed({{9{k1ramp[7]}}, k1ramp[7:0]});
                                if (tmp < 0) eng_k1_w <= 16'd0;
                                else if (tmp > 17'sh0ffff) eng_k1_w <= 16'hffff;
                                else eng_k1_w <= tmp[15:0];
                            end
                            if (k2ramp[7:0] != 8'd0 && (!k2ramp[8] || fcc[2:0] == 3'd0)) begin
                                tmp = $signed({1'b0, k2}) + $signed({{9{k2ramp[7]}}, k2ramp[7:0]});
                                if (tmp < 0) eng_k2_w <= 16'd0;
                                else if (tmp > 17'sh0ffff) eng_k2_w <= 16'hffff;
                                else eng_k2_w <= tmp[15:0];
                            end
                        end
                    end else if (ecount != 9'd0) begin
                        eng_wr_env <= 1'b1;
                        eng_ecount_w <= ecount - 9'd1;
                    end
                    state <= S_NEXT;
                end

                S_NEXT: begin
                    if (voice_i == active_voices) begin
                        if (mix_l > 24'sh007fff) audio_l <= 16'sh7fff;
                        else if (mix_l < -24'sh008000) audio_l <= -16'sh8000;
                        else audio_l <= mix_l[15:0];
                        if (mix_r > 24'sh007fff) audio_r <= 16'sh7fff;
                        else if (mix_r < -24'sh008000) audio_r <= -16'sh8000;
                        else audio_r <= mix_r[15:0];
                        sample_tick <= 1'b1;
                        voice_i <= 5'd0;
                        mix_l <= '0;
                        mix_r <= '0;
                    end else
                        voice_i <= voice_i + 5'd1;
                    state <= S_START;
                end

                default: state <= S_START;
            endcase
        end
    end
end

endmodule
