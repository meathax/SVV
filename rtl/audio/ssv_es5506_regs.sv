// SPDX-License-Identifier: GPL-3.0-or-later
// Ensoniq ES5506 (OTTO) host interface and register file.
//
// This is original RTL based on the Ensoniq OTTO Specification Rev. 2.3.
// Register masks and reset behavior were cross-checked against MAME's
// BSD-3-Clause es5506.cpp and the zlib-licensed vgsound_emu ES550x model.
// See docs/ES5506_RESEARCH.md.
//
// Voice banks are explicit 32xW MLAB simple-dual-port RAMs (ssv_mlab32_sdp).
// One shared rd_addr: engine refresh, or host byte-0 steal.  Registered MLAB
// reads add one cycle before read_latch fills (ssv_core sound path waits 2).

`timescale 1ns/1ps

module ssv_es5506_regs (
    input  logic        clk,
    input  logic        rst,

    input  logic        host_we,
    input  logic        host_re,
    input  logic [5:0]  host_addr,
    input  logic [7:0]  host_wdata,
    output logic [7:0]  host_rdata,

    input  logic [9:0]  par_data,
    input  logic        irq_set,
    input  logic [4:0]  irq_voice,
    output logic        irq_n,

    output logic [6:0]  current_page,
    output logic [4:0]  active_voices,
    output logic [4:0]  mode,
    output logic [6:0]  word_clock_start,
    output logic [6:0]  word_clock_end,
    output logic [6:0]  lr_clock_end,

    output logic        commit,
    output logic [6:0]  commit_page,
    output logic [3:0]  commit_reg,
    output logic [31:0] commit_data,

    // Voice-engine port (registered read of current voice; writeback next state).
    input  logic [4:0]  eng_voice,
    output logic [15:0] eng_cr,
    output logic        eng_cr_valid,
    output logic [16:0] eng_fc,
    output logic [15:0] eng_lvol,
    output logic [7:0]  eng_lvramp,
    output logic [15:0] eng_rvol,
    output logic [7:0]  eng_rvramp,
    output logic [8:0]  eng_ecount,
    output logic [15:0] eng_k1,
    output logic [8:0]  eng_k1ramp,
    output logic [15:0] eng_k2,
    output logic [8:0]  eng_k2ramp,
    output logic [31:0] eng_start,
    output logic [31:0] eng_end,
    output logic [31:0] eng_accum,
    output logic [17:0] eng_o4n1,
    output logic [17:0] eng_o3n1,
    output logic [17:0] eng_o3n2,
    output logic [17:0] eng_o2n1,
    output logic [17:0] eng_o2n2,
    output logic [17:0] eng_o1n1,

    input  logic        eng_wr_accum,
    input  logic [31:0] eng_accum_w,
    input  logic        eng_wr_cr,
    input  logic [15:0] eng_cr_w,
    input  logic        eng_wr_filt,
    input  logic [17:0] eng_o4n1_w,
    input  logic [17:0] eng_o3n1_w,
    input  logic [17:0] eng_o3n2_w,
    input  logic [17:0] eng_o2n1_w,
    input  logic [17:0] eng_o2n2_w,
    input  logic [17:0] eng_o1n1_w,
    input  logic        eng_wr_env,
    input  logic [15:0] eng_lvol_w,
    input  logic [15:0] eng_rvol_w,
    input  logic [15:0] eng_k1_w,
    input  logic [15:0] eng_k2_w,
    input  logic [8:0]  eng_ecount_w
);

logic [31:0] write_latch;
logic [31:0] read_latch;
logic  [7:0] irq_vector;
logic [31:0] voice_control_valid;

wire [1:0] host_byte = host_addr[1:0];
wire [3:0] host_reg  = host_addr[5:2];
wire [4:0] voice     = current_page[4:0];

wire host_rd_steal = host_re && (host_byte == 2'd0);
wire host_commit   = host_we && (host_byte == 2'd3);

logic [31:0] assembled_write;
always_comb begin
    assembled_write = write_latch;
    unique case (host_byte)
        2'd0: assembled_write[31:24] = host_wdata;
        2'd1: assembled_write[23:16] = host_wdata;
        2'd2: assembled_write[15:8]  = host_wdata;
        2'd3: assembled_write[7:0]   = host_wdata;
    endcase
end

// Shared MLAB read address: host byte-0 steals one cycle for PAGE voice.
wire [4:0] rd_addr = host_rd_steal ? voice : eng_voice;

logic [15:0] q_control;
logic [16:0] q_fc;
logic [15:0] q_lvol;
logic  [7:0] q_lvramp;
logic [15:0] q_rvol;
logic  [7:0] q_rvramp;
logic  [8:0] q_ecount;
logic [15:0] q_k2;
logic  [8:0] q_k2ramp;
logic [15:0] q_k1;
logic  [8:0] q_k1ramp;
logic [31:0] q_start;
logic [31:0] q_end;
logic [31:0] q_accum;
logic [17:0] q_o4n1;
logic [17:0] q_o3n1;
logic [17:0] q_o3n2;
logic [17:0] q_o2n1;
logic [17:0] q_o2n2;
logic [17:0] q_o1n1;

logic        we_control, we_fc, we_lvol, we_lvramp, we_rvol, we_rvramp;
logic        we_ecount, we_k2, we_k2ramp, we_k1, we_k1ramp;
logic        we_start, we_end, we_accum;
logic        we_o4n1, we_o3n1, we_o3n2, we_o2n1, we_o2n2, we_o1n1;
logic [4:0]  wr_addr;
logic [15:0] w_control;
logic [16:0] w_fc;
logic [15:0] w_lvol;
logic  [7:0] w_lvramp;
logic [15:0] w_rvol;
logic  [7:0] w_rvramp;
logic  [8:0] w_ecount;
logic [15:0] w_k2;
logic  [8:0] w_k2ramp;
logic [15:0] w_k1;
logic  [8:0] w_k1ramp;
logic [31:0] w_start;
logic [31:0] w_end;
logic [31:0] w_accum;
logic [17:0] w_o4n1;
logic [17:0] w_o3n1;
logic [17:0] w_o3n2;
logic [17:0] w_o2n1;
logic [17:0] w_o2n2;
logic [17:0] w_o1n1;

logic host_rd_pending;
logic [6:0] page_r;
logic [3:0] reg_r;
logic [7:0] irqv_r;

// Hold engine snapshot while MLAB q carries the host-steal read.
logic        eng_hold;
logic [15:0] eng_cr_h;
logic        eng_cr_valid_h;
logic [16:0] eng_fc_h;
logic [15:0] eng_lvol_h;
logic  [7:0] eng_lvramp_h;
logic [15:0] eng_rvol_h;
logic  [7:0] eng_rvramp_h;
logic  [8:0] eng_ecount_h;
logic [15:0] eng_k1_h;
logic  [8:0] eng_k1ramp_h;
logic [15:0] eng_k2_h;
logic  [8:0] eng_k2ramp_h;
logic [31:0] eng_start_h;
logic [31:0] eng_end_h;
logic [31:0] eng_accum_h;
logic [17:0] eng_o4n1_h;
logic [17:0] eng_o3n1_h;
logic [17:0] eng_o3n2_h;
logic [17:0] eng_o2n1_h;
logic [17:0] eng_o2n2_h;
logic [17:0] eng_o1n1_h;

assign eng_cr       = eng_hold ? eng_cr_h       : q_control;
assign eng_cr_valid = eng_hold ? eng_cr_valid_h : voice_control_valid[eng_voice];
assign eng_fc       = eng_hold ? eng_fc_h       : q_fc;
assign eng_lvol     = eng_hold ? eng_lvol_h     : q_lvol;
assign eng_lvramp   = eng_hold ? eng_lvramp_h   : q_lvramp;
assign eng_rvol     = eng_hold ? eng_rvol_h     : q_rvol;
assign eng_rvramp   = eng_hold ? eng_rvramp_h   : q_rvramp;
assign eng_ecount   = eng_hold ? eng_ecount_h   : q_ecount;
assign eng_k1       = eng_hold ? eng_k1_h       : q_k1;
assign eng_k1ramp   = eng_hold ? eng_k1ramp_h   : q_k1ramp;
assign eng_k2       = eng_hold ? eng_k2_h       : q_k2;
assign eng_k2ramp   = eng_hold ? eng_k2ramp_h   : q_k2ramp;
assign eng_start    = eng_hold ? eng_start_h    : q_start;
assign eng_end      = eng_hold ? eng_end_h      : q_end;
assign eng_accum    = eng_hold ? eng_accum_h    : q_accum;
assign eng_o4n1     = eng_hold ? eng_o4n1_h     : q_o4n1;
assign eng_o3n1     = eng_hold ? eng_o3n1_h     : q_o3n1;
assign eng_o3n2     = eng_hold ? eng_o3n2_h     : q_o3n2;
assign eng_o2n1     = eng_hold ? eng_o2n1_h     : q_o2n1;
assign eng_o2n2     = eng_hold ? eng_o2n2_h     : q_o2n2;
assign eng_o1n1     = eng_hold ? eng_o1n1_h     : q_o1n1;

always_comb begin
    we_control = 1'b0;
    we_fc = 1'b0;
    we_lvol = 1'b0;
    we_lvramp = 1'b0;
    we_rvol = 1'b0;
    we_rvramp = 1'b0;
    we_ecount = 1'b0;
    we_k2 = 1'b0;
    we_k2ramp = 1'b0;
    we_k1 = 1'b0;
    we_k1ramp = 1'b0;
    we_start = 1'b0;
    we_end = 1'b0;
    we_accum = 1'b0;
    we_o4n1 = 1'b0;
    we_o3n1 = 1'b0;
    we_o3n2 = 1'b0;
    we_o2n1 = 1'b0;
    we_o2n2 = 1'b0;
    we_o1n1 = 1'b0;
    wr_addr = eng_voice;
    w_control = eng_cr_w;
    w_fc = 17'd0;
    w_lvol = eng_lvol_w;
    w_lvramp = 8'd0;
    w_rvol = eng_rvol_w;
    w_rvramp = 8'd0;
    w_ecount = eng_ecount_w;
    w_k2 = eng_k2_w;
    w_k2ramp = 9'd0;
    w_k1 = eng_k1_w;
    w_k1ramp = 9'd0;
    w_start = 32'd0;
    w_end = 32'd0;
    w_accum = eng_accum_w;
    w_o4n1 = eng_o4n1_w;
    w_o3n1 = eng_o3n1_w;
    w_o3n2 = eng_o3n2_w;
    w_o2n1 = eng_o2n1_w;
    w_o2n2 = eng_o2n2_w;
    w_o1n1 = eng_o1n1_w;

    if (host_commit) begin
        // Host byte-3 commit owns the write port (engine writebacks held off).
        wr_addr = voice;
        if (current_page < 7'h20) begin
            unique case (host_reg)
                4'h0: begin we_control = 1'b1; w_control = assembled_write[15:0]; end
                4'h1: begin we_fc = 1'b1; w_fc = assembled_write[16:0]; end
                4'h2: begin we_lvol = 1'b1; w_lvol = assembled_write[15:0]; end
                4'h3: begin we_lvramp = 1'b1; w_lvramp = assembled_write[15:8]; end
                4'h4: begin we_rvol = 1'b1; w_rvol = assembled_write[15:0]; end
                4'h5: begin we_rvramp = 1'b1; w_rvramp = assembled_write[15:8]; end
                4'h6: begin we_ecount = 1'b1; w_ecount = assembled_write[8:0]; end
                4'h7: begin we_k2 = 1'b1; w_k2 = assembled_write[15:0]; end
                4'h8: begin
                    we_k2ramp = 1'b1;
                    w_k2ramp = {assembled_write[0], assembled_write[15:8]};
                end
                4'h9: begin we_k1 = 1'b1; w_k1 = assembled_write[15:0]; end
                4'ha: begin
                    we_k1ramp = 1'b1;
                    w_k1ramp = {assembled_write[0], assembled_write[15:8]};
                end
                default: ;
            endcase
        end
        else if (current_page < 7'h40) begin
            unique case (host_reg)
                4'h0: begin we_control = 1'b1; w_control = assembled_write[15:0]; end
                4'h1: begin
                    we_start = 1'b1;
                    w_start = assembled_write & 32'hffff_f800;
                end
                4'h2: begin
                    we_end = 1'b1;
                    w_end = assembled_write & 32'hffff_ff80;
                end
                4'h3: begin we_accum = 1'b1; w_accum = assembled_write; end
                4'h4: begin we_o4n1 = 1'b1; w_o4n1 = assembled_write[17:0]; end
                4'h5: begin we_o3n1 = 1'b1; w_o3n1 = assembled_write[17:0]; end
                4'h6: begin we_o3n2 = 1'b1; w_o3n2 = assembled_write[17:0]; end
                4'h7: begin we_o2n1 = 1'b1; w_o2n1 = assembled_write[17:0]; end
                4'h8: begin we_o2n2 = 1'b1; w_o2n2 = assembled_write[17:0]; end
                4'h9: begin we_o1n1 = 1'b1; w_o1n1 = assembled_write[17:0]; end
                default: ;
            endcase
        end
    end
    else begin
        wr_addr = eng_voice;
        if (eng_wr_accum) we_accum = 1'b1;
        if (eng_wr_cr)    we_control = 1'b1;
        if (eng_wr_filt) begin
            we_o4n1 = 1'b1;
            we_o3n1 = 1'b1;
            we_o3n2 = 1'b1;
            we_o2n1 = 1'b1;
            we_o2n2 = 1'b1;
            we_o1n1 = 1'b1;
        end
        if (eng_wr_env) begin
            we_lvol = 1'b1;
            we_rvol = 1'b1;
            we_k1 = 1'b1;
            we_k2 = 1'b1;
            we_ecount = 1'b1;
        end
    end
end

ssv_mlab32_sdp #(.WIDTH(16)) u_control (
    .clk, .wr_addr, .we(we_control), .wdata(w_control), .rd_addr, .q(q_control));
ssv_mlab32_sdp #(.WIDTH(17)) u_fc (
    .clk, .wr_addr, .we(we_fc), .wdata(w_fc), .rd_addr, .q(q_fc));
ssv_mlab32_sdp #(.WIDTH(16)) u_lvol (
    .clk, .wr_addr, .we(we_lvol), .wdata(w_lvol), .rd_addr, .q(q_lvol));
ssv_mlab32_sdp #(.WIDTH(8)) u_lvramp (
    .clk, .wr_addr, .we(we_lvramp), .wdata(w_lvramp), .rd_addr, .q(q_lvramp));
ssv_mlab32_sdp #(.WIDTH(16)) u_rvol (
    .clk, .wr_addr, .we(we_rvol), .wdata(w_rvol), .rd_addr, .q(q_rvol));
ssv_mlab32_sdp #(.WIDTH(8)) u_rvramp (
    .clk, .wr_addr, .we(we_rvramp), .wdata(w_rvramp), .rd_addr, .q(q_rvramp));
ssv_mlab32_sdp #(.WIDTH(9)) u_ecount (
    .clk, .wr_addr, .we(we_ecount), .wdata(w_ecount), .rd_addr, .q(q_ecount));
ssv_mlab32_sdp #(.WIDTH(16)) u_k2 (
    .clk, .wr_addr, .we(we_k2), .wdata(w_k2), .rd_addr, .q(q_k2));
ssv_mlab32_sdp #(.WIDTH(9)) u_k2ramp (
    .clk, .wr_addr, .we(we_k2ramp), .wdata(w_k2ramp), .rd_addr, .q(q_k2ramp));
ssv_mlab32_sdp #(.WIDTH(16)) u_k1 (
    .clk, .wr_addr, .we(we_k1), .wdata(w_k1), .rd_addr, .q(q_k1));
ssv_mlab32_sdp #(.WIDTH(9)) u_k1ramp (
    .clk, .wr_addr, .we(we_k1ramp), .wdata(w_k1ramp), .rd_addr, .q(q_k1ramp));
ssv_mlab32_sdp #(.WIDTH(32)) u_start (
    .clk, .wr_addr, .we(we_start), .wdata(w_start), .rd_addr, .q(q_start));
ssv_mlab32_sdp #(.WIDTH(32)) u_end (
    .clk, .wr_addr, .we(we_end), .wdata(w_end), .rd_addr, .q(q_end));
ssv_mlab32_sdp #(.WIDTH(32)) u_accum (
    .clk, .wr_addr, .we(we_accum), .wdata(w_accum), .rd_addr, .q(q_accum));
ssv_mlab32_sdp #(.WIDTH(18)) u_o4n1 (
    .clk, .wr_addr, .we(we_o4n1), .wdata(w_o4n1), .rd_addr, .q(q_o4n1));
ssv_mlab32_sdp #(.WIDTH(18)) u_o3n1 (
    .clk, .wr_addr, .we(we_o3n1), .wdata(w_o3n1), .rd_addr, .q(q_o3n1));
ssv_mlab32_sdp #(.WIDTH(18)) u_o3n2 (
    .clk, .wr_addr, .we(we_o3n2), .wdata(w_o3n2), .rd_addr, .q(q_o3n2));
ssv_mlab32_sdp #(.WIDTH(18)) u_o2n1 (
    .clk, .wr_addr, .we(we_o2n1), .wdata(w_o2n1), .rd_addr, .q(q_o2n1));
ssv_mlab32_sdp #(.WIDTH(18)) u_o2n2 (
    .clk, .wr_addr, .we(we_o2n2), .wdata(w_o2n2), .rd_addr, .q(q_o2n2));
ssv_mlab32_sdp #(.WIDTH(18)) u_o1n1 (
    .clk, .wr_addr, .we(we_o1n1), .wdata(w_o1n1), .rd_addr, .q(q_o1n1));

always_comb begin
    unique case (host_byte)
        2'd0: host_rdata = read_latch[31:24];
        2'd1: host_rdata = read_latch[23:16];
        2'd2: host_rdata = read_latch[15:8];
        2'd3: host_rdata = read_latch[7:0];
    endcase
end

function automatic [31:0] assemble_host_read(
    input [6:0] page,
    input [3:0] regn,
    input       cr_valid,
    input [15:0] control,
    input [16:0] fc,
    input [15:0] lvol,
    input [7:0]  lvramp,
    input [15:0] rvol,
    input [7:0]  rvramp,
    input [8:0]  ecount,
    input [15:0] k2,
    input [8:0]  k2ramp,
    input [15:0] k1,
    input [8:0]  k1ramp,
    input [31:0] start_a,
    input [31:0] end_a,
    input [31:0] accum,
    input [17:0] o4n1,
    input [17:0] o3n1,
    input [17:0] o3n2,
    input [17:0] o2n1,
    input [17:0] o2n2,
    input [17:0] o1n1,
    input [4:0]  act_v,
    input [4:0]  mode_v,
    input [9:0]  par,
    input [7:0]  irqv,
    input [6:0]  page_v,
    input [6:0]  wcs,
    input [6:0]  wce,
    input [6:0]  lre
);
    begin
        assemble_host_read = 32'd0;
        if (page < 7'h20) begin
            unique case (regn)
                4'h0: assemble_host_read = cr_valid
                    ? {16'd0, control} : 32'h0000_0003;
                4'h1: assemble_host_read = {15'd0, fc};
                4'h2: assemble_host_read = {16'd0, lvol};
                4'h3: assemble_host_read = {16'd0, lvramp, 8'd0};
                4'h4: assemble_host_read = {16'd0, rvol};
                4'h5: assemble_host_read = {16'd0, rvramp, 8'd0};
                4'h6: assemble_host_read = {23'd0, ecount};
                4'h7: assemble_host_read = {16'd0, k2};
                4'h8: assemble_host_read = {
                    16'd0, k2ramp[7:0], 7'd0, k2ramp[8]
                };
                4'h9: assemble_host_read = {16'd0, k1};
                4'ha: assemble_host_read = {
                    16'd0, k1ramp[7:0], 7'd0, k1ramp[8]
                };
                4'hb: assemble_host_read = {27'd0, act_v};
                4'hc: assemble_host_read = {27'd0, mode_v};
                4'hd: assemble_host_read = {22'd0, par};
                4'he: assemble_host_read = {24'd0, irqv};
                4'hf: assemble_host_read = {25'd0, page_v};
            endcase
        end
        else if (page < 7'h40) begin
            unique case (regn)
                4'h0: assemble_host_read = cr_valid
                    ? {16'd0, control} : 32'h0000_0003;
                4'h1: assemble_host_read = start_a;
                4'h2: assemble_host_read = end_a;
                4'h3: assemble_host_read = accum;
                4'h4: assemble_host_read = {14'd0, o4n1};
                4'h5: assemble_host_read = {14'd0, o3n1};
                4'h6: assemble_host_read = {14'd0, o3n2};
                4'h7: assemble_host_read = {14'd0, o2n1};
                4'h8: assemble_host_read = {14'd0, o2n2};
                4'h9: assemble_host_read = {14'd0, o1n1};
                4'ha: assemble_host_read = {25'd0, wcs};
                4'hb: assemble_host_read = {25'd0, wce};
                4'hc: assemble_host_read = {25'd0, lre};
                4'hd: assemble_host_read = {22'd0, par};
                4'he: assemble_host_read = {24'd0, irqv};
                4'hf: assemble_host_read = {25'd0, page_v};
            endcase
        end
        else begin
            unique case (regn)
                4'hd: assemble_host_read = {22'd0, par};
                4'he: assemble_host_read = {24'd0, irqv};
                4'hf: assemble_host_read = {25'd0, page_v};
                default: assemble_host_read = 32'd0;
            endcase
        end
    end
endfunction

always_ff @(posedge clk) begin
    if (rst) begin
        write_latch      <= 32'd0;
        read_latch       <= 32'hffff_ffff;
        current_page     <= 7'd0;
        active_voices    <= 5'h1f;
        mode             <= 5'h17;
        word_clock_start <= 7'd0;
        word_clock_end   <= 7'd0;
        lr_clock_end     <= 7'd0;
        irq_vector       <= 8'h80;
        commit           <= 1'b0;
        voice_control_valid <= 32'd0;
        commit_page      <= 7'd0;
        commit_reg       <= 4'd0;
        commit_data      <= 32'd0;
        host_rd_pending  <= 1'b0;
        eng_hold         <= 1'b0;
        page_r           <= 7'd0;
        reg_r            <= 4'd0;
        irqv_r           <= 8'h80;
        eng_cr_h         <= 16'd0;
        eng_cr_valid_h   <= 1'b0;
        eng_fc_h         <= 17'd0;
        eng_lvol_h       <= 16'd0;
        eng_lvramp_h     <= 8'd0;
        eng_rvol_h       <= 16'd0;
        eng_rvramp_h     <= 8'd0;
        eng_ecount_h     <= 9'd0;
        eng_k1_h         <= 16'd0;
        eng_k1ramp_h     <= 9'd0;
        eng_k2_h         <= 16'd0;
        eng_k2ramp_h     <= 9'd0;
        eng_start_h      <= 32'd0;
        eng_end_h        <= 32'd0;
        eng_accum_h      <= 32'd0;
        eng_o4n1_h       <= 18'd0;
        eng_o3n1_h       <= 18'd0;
        eng_o3n2_h       <= 18'd0;
        eng_o2n1_h       <= 18'd0;
        eng_o2n2_h       <= 18'd0;
        eng_o1n1_h       <= 18'd0;
    end
    else begin
        commit <= 1'b0;
        host_rd_pending <= host_rd_steal;
        // Hold engine snapshots through the steal cycle and the following
        // cycle while MLAB q still reflects the host rd_addr (address_reg_b).
        // Dropping hold with steal alone lets eng_* sample host voice data.
        eng_hold        <= host_rd_steal || host_rd_pending;

        if (host_rd_steal) begin
            page_r <= current_page;
            reg_r  <= host_reg;
            irqv_r <= irq_vector;
            // q still holds the prior engine read at this edge.
            eng_cr_h       <= q_control;
            eng_cr_valid_h <= voice_control_valid[eng_voice];
            eng_fc_h       <= q_fc;
            eng_lvol_h     <= q_lvol;
            eng_lvramp_h   <= q_lvramp;
            eng_rvol_h     <= q_rvol;
            eng_rvramp_h   <= q_rvramp;
            eng_ecount_h   <= q_ecount;
            eng_k1_h       <= q_k1;
            eng_k1ramp_h   <= q_k1ramp;
            eng_k2_h       <= q_k2;
            eng_k2ramp_h   <= q_k2ramp;
            eng_start_h    <= q_start;
            eng_end_h      <= q_end;
            eng_accum_h    <= q_accum;
            eng_o4n1_h     <= q_o4n1;
            eng_o3n1_h     <= q_o3n1;
            eng_o3n2_h     <= q_o3n2;
            eng_o2n1_h     <= q_o2n1;
            eng_o2n2_h     <= q_o2n2;
            eng_o1n1_h     <= q_o1n1;
        end

        // MLAB q is one cycle behind rd_addr (steal or eng).
        if (host_rd_pending) begin
            read_latch <= assemble_host_read(
                page_r, reg_r,
                voice_control_valid[page_r[4:0]],
                q_control, q_fc, q_lvol, q_lvramp, q_rvol, q_rvramp,
                q_ecount, q_k2, q_k2ramp, q_k1, q_k1ramp,
                q_start, q_end, q_accum,
                q_o4n1, q_o3n1, q_o3n2, q_o2n1, q_o2n2, q_o1n1,
                active_voices, mode, par_data, irqv_r, page_r,
                word_clock_start, word_clock_end, lr_clock_end
            );
            // Spec: reading IRQV clears the pending vector (after snapshot).
            if ((reg_r == 4'he) && (page_r < 7'h40))
                irq_vector <= 8'h80;
        end

        if (irq_set && irq_vector[7])
            irq_vector <= {3'd0, irq_voice};

        if (host_we) begin
            write_latch <= assembled_write;
            if (host_byte == 2'd3) begin
                commit      <= 1'b1;
                commit_page <= current_page;
                commit_reg  <= host_reg;
                commit_data <= assembled_write;

                if (host_reg == 4'hf)
                    current_page <= assembled_write[6:0];
                else if (current_page < 7'h20) begin
                    unique case (host_reg)
                        4'h0: voice_control_valid[voice] <= 1'b1;
                        4'hb: active_voices <= assembled_write[4:0];
                        4'hc: mode <= assembled_write[4:0];
                        default: ;
                    endcase
                end
                else if (current_page < 7'h40) begin
                    unique case (host_reg)
                        4'h0: voice_control_valid[voice] <= 1'b1;
                        4'ha: word_clock_start <= assembled_write[6:0];
                        4'hb: word_clock_end <= assembled_write[6:0];
                        4'hc: lr_clock_end <= assembled_write[6:0];
                        default: ;
                    endcase
                end

                write_latch <= 32'd0;
            end
        end

        if (!host_commit && eng_wr_cr)
            voice_control_valid[eng_voice] <= 1'b1;
    end
end

assign irq_n = irq_vector[7];

endmodule
