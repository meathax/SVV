// SPDX-License-Identifier: GPL-3.0-or-later
// Ensoniq ES5506 (OTTO) host interface and register file.
//
// This is original RTL based on the Ensoniq OTTO Specification Rev. 2.3.
// Register masks and reset behavior were cross-checked against MAME's
// BSD-3-Clause es5506.cpp and the zlib-licensed vgsound_emu ES550x model.
// See docs/ES5506_RESEARCH.md.

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

    // Voice-engine dual port (read current voice; writeback next state).
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

(* ramstyle = "MLAB, no_rw_check" *) logic [15:0] voice_control [0:31];
(* ramstyle = "MLAB, no_rw_check" *) logic [16:0] voice_fc      [0:31];
(* ramstyle = "MLAB, no_rw_check" *) logic [15:0] voice_lvol    [0:31];
(* ramstyle = "MLAB, no_rw_check" *) logic  [7:0] voice_lvramp  [0:31];
(* ramstyle = "MLAB, no_rw_check" *) logic [15:0] voice_rvol    [0:31];
(* ramstyle = "MLAB, no_rw_check" *) logic  [7:0] voice_rvramp  [0:31];
(* ramstyle = "MLAB, no_rw_check" *) logic  [8:0] voice_ecount  [0:31];
(* ramstyle = "MLAB, no_rw_check" *) logic [15:0] voice_k2      [0:31];
(* ramstyle = "MLAB, no_rw_check" *) logic  [8:0] voice_k2ramp  [0:31];
(* ramstyle = "MLAB, no_rw_check" *) logic [15:0] voice_k1      [0:31];
(* ramstyle = "MLAB, no_rw_check" *) logic  [8:0] voice_k1ramp  [0:31];

(* ramstyle = "MLAB, no_rw_check" *) logic [31:0] voice_start   [0:31];
(* ramstyle = "MLAB, no_rw_check" *) logic [31:0] voice_end     [0:31];
(* ramstyle = "MLAB, no_rw_check" *) logic [31:0] voice_accum   [0:31];
(* ramstyle = "MLAB, no_rw_check" *) logic [17:0] voice_o4n1    [0:31];
(* ramstyle = "MLAB, no_rw_check" *) logic [17:0] voice_o3n1    [0:31];
(* ramstyle = "MLAB, no_rw_check" *) logic [17:0] voice_o3n2    [0:31];
(* ramstyle = "MLAB, no_rw_check" *) logic [17:0] voice_o2n1    [0:31];
(* ramstyle = "MLAB, no_rw_check" *) logic [17:0] voice_o2n2    [0:31];
(* ramstyle = "MLAB, no_rw_check" *) logic [17:0] voice_o1n1    [0:31];

wire [1:0] host_byte = host_addr[1:0];
wire [3:0] host_reg  = host_addr[5:2];
wire [4:0] voice     = current_page[4:0];

assign eng_cr       = voice_control[eng_voice];
assign eng_cr_valid = voice_control_valid[eng_voice];
assign eng_fc       = voice_fc[eng_voice];
assign eng_lvol     = voice_lvol[eng_voice];
assign eng_lvramp   = voice_lvramp[eng_voice];
assign eng_rvol     = voice_rvol[eng_voice];
assign eng_rvramp   = voice_rvramp[eng_voice];
assign eng_ecount   = voice_ecount[eng_voice];
assign eng_k1       = voice_k1[eng_voice];
assign eng_k1ramp   = voice_k1ramp[eng_voice];
assign eng_k2       = voice_k2[eng_voice];
assign eng_k2ramp   = voice_k2ramp[eng_voice];
assign eng_start    = voice_start[eng_voice];
assign eng_end      = voice_end[eng_voice];
assign eng_accum    = voice_accum[eng_voice];
assign eng_o4n1     = voice_o4n1[eng_voice];
assign eng_o3n1     = voice_o3n1[eng_voice];
assign eng_o3n2     = voice_o3n2[eng_voice];
assign eng_o2n1     = voice_o2n1[eng_voice];
assign eng_o2n2     = voice_o2n2[eng_voice];
assign eng_o1n1     = voice_o1n1[eng_voice];

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

logic [31:0] selected_register;
always_comb begin
    selected_register = 32'd0;
    if (current_page < 7'h20) begin
        unique case (host_reg)
            4'h0: selected_register = voice_control_valid[voice]
                ? {16'd0, voice_control[voice]} : 32'h0000_0003;
            4'h1: selected_register = {15'd0, voice_fc[voice]};
            4'h2: selected_register = {16'd0, voice_lvol[voice]};
            4'h3: selected_register = {16'd0, voice_lvramp[voice], 8'd0};
            4'h4: selected_register = {16'd0, voice_rvol[voice]};
            4'h5: selected_register = {16'd0, voice_rvramp[voice], 8'd0};
            4'h6: selected_register = {23'd0, voice_ecount[voice]};
            4'h7: selected_register = {16'd0, voice_k2[voice]};
            4'h8: selected_register = {
                16'd0, voice_k2ramp[voice][7:0], 7'd0,
                voice_k2ramp[voice][8]
            };
            4'h9: selected_register = {16'd0, voice_k1[voice]};
            4'ha: selected_register = {
                16'd0, voice_k1ramp[voice][7:0], 7'd0,
                voice_k1ramp[voice][8]
            };
            4'hb: selected_register = {27'd0, active_voices};
            4'hc: selected_register = {27'd0, mode};
            4'hd: selected_register = {22'd0, par_data};
            4'he: selected_register = {24'd0, irq_vector};
            4'hf: selected_register = {25'd0, current_page};
        endcase
    end
    else if (current_page < 7'h40) begin
        unique case (host_reg)
            4'h0: selected_register = voice_control_valid[voice]
                ? {16'd0, voice_control[voice]} : 32'h0000_0003;
            4'h1: selected_register = voice_start[voice];
            4'h2: selected_register = voice_end[voice];
            4'h3: selected_register = voice_accum[voice];
            4'h4: selected_register = {14'd0, voice_o4n1[voice]};
            4'h5: selected_register = {14'd0, voice_o3n1[voice]};
            4'h6: selected_register = {14'd0, voice_o3n2[voice]};
            4'h7: selected_register = {14'd0, voice_o2n1[voice]};
            4'h8: selected_register = {14'd0, voice_o2n2[voice]};
            4'h9: selected_register = {14'd0, voice_o1n1[voice]};
            4'ha: selected_register = {25'd0, word_clock_start};
            4'hb: selected_register = {25'd0, word_clock_end};
            4'hc: selected_register = {25'd0, lr_clock_end};
            4'hd: selected_register = {22'd0, par_data};
            4'he: selected_register = {24'd0, irq_vector};
            4'hf: selected_register = {25'd0, current_page};
        endcase
    end
    else begin
        unique case (host_reg)
            4'hd: selected_register = {22'd0, par_data};
            4'he: selected_register = {24'd0, irq_vector};
            4'hf: selected_register = {25'd0, current_page};
            default: selected_register = 32'd0;
        endcase
    end
end

always_comb begin
    unique case (host_byte)
        2'd0: host_rdata = read_latch[31:24];
        2'd1: host_rdata = read_latch[23:16];
        2'd2: host_rdata = read_latch[15:8];
        2'd3: host_rdata = read_latch[7:0];
    endcase
end

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

    end
    else begin
        commit <= 1'b0;

        if (host_re && (host_byte == 2'd0)) begin
            read_latch <= selected_register;
            if ((host_reg == 4'he) && (current_page < 7'h40))
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
                        4'h0: begin
                            voice_control[voice] <= assembled_write[15:0];
                            voice_control_valid[voice] <= 1'b1;
                        end
                        4'h1: voice_fc[voice] <= assembled_write[16:0];
                        4'h2: voice_lvol[voice] <= assembled_write[15:0];
                        4'h3: voice_lvramp[voice] <= assembled_write[15:8];
                        4'h4: voice_rvol[voice] <= assembled_write[15:0];
                        4'h5: voice_rvramp[voice] <= assembled_write[15:8];
                        4'h6: voice_ecount[voice] <= assembled_write[8:0];
                        4'h7: voice_k2[voice] <= assembled_write[15:0];
                        4'h8: voice_k2ramp[voice] <= {
                            assembled_write[0], assembled_write[15:8]
                        };
                        4'h9: voice_k1[voice] <= assembled_write[15:0];
                        4'ha: voice_k1ramp[voice] <= {
                            assembled_write[0], assembled_write[15:8]
                        };
                        4'hb: active_voices <= assembled_write[4:0];
                        4'hc: mode <= assembled_write[4:0];
                        default: ;
                    endcase
                end
                else if (current_page < 7'h40) begin
                    unique case (host_reg)
                        4'h0: begin
                            voice_control[voice] <= assembled_write[15:0];
                            voice_control_valid[voice] <= 1'b1;
                        end
                        4'h1: voice_start[voice] <=
                            assembled_write & 32'hffff_f800;
                        4'h2: voice_end[voice] <=
                            assembled_write & 32'hffff_ff80;
                        4'h3: voice_accum[voice] <= assembled_write;
                        4'h4: voice_o4n1[voice] <= assembled_write[17:0];
                        4'h5: voice_o3n1[voice] <= assembled_write[17:0];
                        4'h6: voice_o3n2[voice] <= assembled_write[17:0];
                        4'h7: voice_o2n1[voice] <= assembled_write[17:0];
                        4'h8: voice_o2n2[voice] <= assembled_write[17:0];
                        4'h9: voice_o1n1[voice] <= assembled_write[17:0];
                        4'ha: word_clock_start <= assembled_write[6:0];
                        4'hb: word_clock_end <= assembled_write[6:0];
                        4'hc: lr_clock_end <= assembled_write[6:0];
                        default: ;
                    endcase
                end

                // Any byte-three write commits and clears the shared latch.
                write_latch <= 32'd0;
            end
        end

        // Engine writebacks (host commit in the same cycle wins).
        if (!(host_we && host_byte == 2'd3)) begin
            if (eng_wr_accum)
                voice_accum[eng_voice] <= eng_accum_w;
            if (eng_wr_cr) begin
                voice_control[eng_voice] <= eng_cr_w;
                voice_control_valid[eng_voice] <= 1'b1;
            end
            if (eng_wr_filt) begin
                voice_o4n1[eng_voice] <= eng_o4n1_w;
                voice_o3n1[eng_voice] <= eng_o3n1_w;
                voice_o3n2[eng_voice] <= eng_o3n2_w;
                voice_o2n1[eng_voice] <= eng_o2n1_w;
                voice_o2n2[eng_voice] <= eng_o2n2_w;
                voice_o1n1[eng_voice] <= eng_o1n1_w;
            end
            if (eng_wr_env) begin
                voice_lvol[eng_voice]   <= eng_lvol_w;
                voice_rvol[eng_voice]   <= eng_rvol_w;
                voice_k1[eng_voice]     <= eng_k1_w;
                voice_k2[eng_voice]     <= eng_k2_w;
                voice_ecount[eng_voice] <= eng_ecount_w;
            end
        end
    end
end

assign irq_n = irq_vector[7];

endmodule
