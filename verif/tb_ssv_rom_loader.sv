`timescale 1ns/1ps

module tb_ssv_rom_loader;

// Expectations are DERIVED from ssv_pkg, never restated as literals.
//
// They used to be hardcoded (0x0100130 etc.), which meant the SDRAM map could
// not move without this bench failing for a reason that was not a bug -- and
// worse, it invited "fix" by editing the expected numbers to match whatever
// the loader now produced, which would test nothing. gfx_plane_addr() is THE
// authority (ssv_pkg.sv); asking it what the answer should be keeps this a
// real check of the loader against the map.
import ssv_pkg::*;
logic clk = 0;
always #5 clk = ~clk;
logic rst, mem_ready, ioctl_download, ioctl_wr, sdr_wr_ack;
logic [7:0] ioctl_index, ioctl_dout;
logic [26:0] ioctl_addr;
logic ioctl_wait, sdr_wr_req, rom_loaded;
ssv_cfg_t cfg;
logic cfg_valid;
logic cfg_commit;
logic [SDR_AW:1] sdr_wr_addr;
logic [15:0] sdr_wr_din;
logic [1:0] sdr_wr_be;
logic [26:0] download_max_addr;
logic [SDR_AW:1] q0_addr, q1_addr, q2_addr;
logic st010_drom_we;
logic [10:0] st010_drom_wa;
logic [15:0] st010_drom_wd;

logic cfg_commit_d;
always @(posedge clk) begin
    if (rst)
        cfg_commit_d <= 1'b0;
    else begin
        if (cfg_commit && cfg_commit_d)
            $fatal(1, "cfg_commit was not a one-cycle pulse");
        cfg_commit_d <= cfg_commit;
    end
end

ssv_rom_loader dut (.*);

// st010_drom_we is a one-clk pulse coincident with the SDRAM write request, so
// it has already fallen by the time send_byte() returns. Latch it.
// drom_clr, not a blocking assignment to drom_seen from the initial block:
// mixing blocking and non-blocking writes to one variable is exactly the
// BLKANDNBLK case this build suppresses, and it does not reliably work.
logic        drom_seen;
logic        drom_clr = 1'b0;
logic [10:0] drom_wa_l;
logic [15:0] drom_wd_l;
always @(posedge clk) begin
    if (rst || drom_clr)
        drom_seen <= 1'b0;
    else if (st010_drom_we) begin
        drom_seen <= 1'b1;
        drom_wa_l <= st010_drom_wa;
        drom_wd_l <= st010_drom_wd;
    end
end

task tick;
    @(posedge clk); #1;
endtask

function automatic logic [127:0] encode_cfg(input ssv_cfg_t c);
    logic [7:0] b [0:15];
    logic [7:0] sum;
    int i;
    begin
        b[0]=8'h53; b[1]=8'd2; b[2]={5'd0,c.prog_mb};
        b[3]={1'd0,c.gfx_mb}; b[4]={3'd0,c.gfx_code_k};
        b[5]={7'd0,c.gfx_code_mul3}; b[6]={5'd0,c.gfx_quarters};
        b[7]=c.bank_map; b[8]={4'd0,c.bank_valid};
        b[9]={c.extra_input_mode,c.lockout_inverted,
              c.has_drifto_unknown,c.has_st010,1'b0,
              c.irq_level1_line0,c.tile_code_identity};
        b[10]={c.nvram_mode,c.system_input_mode,
               c.extra_ram_mode,c.has_nvram,c.wdog_mode};
        b[11]={4'd0,c.game_id};
        b[12]={2'd0,c.sample_mb};
        b[13]=c.visible_width_half; b[14]=c.visible_height;
        sum = 8'd0;
        for (i = 0; i < 15; i = i + 1) sum = sum + b[i];
        b[15] = -sum;
        encode_cfg = '0;
        for (i = 0; i < 16; i = i + 1)
            encode_cfg[i * 8 +: 8] = b[i];
    end
endfunction

function automatic logic [191:0] encode_cfg_v3(input ssv_cfg_t c);
    logic [7:0] b [0:23];
    logic [7:0] sum;
    logic [127:0] base;
    int i;
    begin
        base = encode_cfg(c);
        for (i = 0; i < 24; i = i + 1) b[i] = 8'd0;
        for (i = 0; i < 15; i = i + 1) b[i] = base[i * 8 +: 8];
        b[1] = 8'd3;
        b[15] = {7'd0, c.mainram_mirror_010000};
        b[16] = {4'd0, c.input_layout};
        b[17] = {5'd0, c.mahjong_mode};
        b[18] = {7'd0, c.irq_level2_line120};
        b[19] = {5'd0, c.custom_output_mode};
        b[20] = {6'd0, c.srmp7_irqv_mame, c.srmp7_sample_half_bank};
        b[21] = {6'd0, c.optional_io_mode};
        b[22] = c.adc_conversion_cycles;
        sum = 8'd0;
        for (i = 0; i < 23; i = i + 1) sum = sum + b[i];
        b[23] = -sum;
        encode_cfg_v3 = '0;
        for (i = 0; i < 24; i = i + 1)
            encode_cfg_v3[i * 8 +: 8] = b[i];
    end
endfunction

task send_cfg_image(input logic [127:0] image);
    int i;
    begin
        ioctl_index = 8'd1;
        for (i = 0; i < 16; i = i + 1) begin
            ioctl_addr = 27'(i);
            ioctl_dout = image[i * 8 +: 8];
            ioctl_wr   = 1'b1;
            tick();
            ioctl_wr   = 1'b0;
            tick();
        end
        ioctl_index = 8'd0;
        tick();
    end
endtask

task send_cfg_v3_image(input logic [191:0] image);
    int i;
    begin
        ioctl_index = 8'd1;
        for (i = 0; i < 24; i = i + 1) begin
            ioctl_addr = 27'(i);
            ioctl_dout = image[i * 8 +: 8];
            ioctl_wr = 1'b1; tick();
            ioctl_wr = 1'b0; tick();
            if (i == 15 && (cfg_valid || cfg_commit))
                $fatal(1, "version 3 committed at legacy version-2 boundary");
        end
        ioctl_index = 8'd0;
        tick();
    end
endtask

// Version is deliberately the final missing byte. Completion must use the
// accepted byte, not stale cfg_raw[1] from the preceding transaction.
task send_cfg_v3_version_last(input logic [191:0] image);
    int i;
    begin
        ioctl_index = 8'd1;
        ioctl_addr = 27'd0; ioctl_dout = image[7:0]; ioctl_wr = 1'b1; tick();
        ioctl_wr = 1'b0; tick();
        for (i = 2; i < 24; i = i + 1) begin
            ioctl_addr = 27'(i); ioctl_dout = image[i * 8 +: 8];
            ioctl_wr = 1'b1; tick(); ioctl_wr = 1'b0; tick();
        end
        ioctl_addr = 27'd1; ioctl_dout = image[15:8]; ioctl_wr = 1'b1; tick();
        ioctl_wr = 1'b0; tick(); ioctl_index = 8'd0; tick();
    end
endtask

// Serialize one runtime profile exactly as the MRA index-1 block does.
task send_cfg(input ssv_cfg_t c);
    begin
        send_cfg_image(encode_cfg(c));
    end
endtask

// Exercise the actual index transition: byte zero is already being held when
// descriptor commit raises ioctl_wait. It must be accepted exactly once after
// cfg/cfg_valid commit, never dropped and never interpreted with stale cfg.
task send_cfg_then_byte0_no_gap(input ssv_cfg_t c, input logic [7:0] byte0);
    logic [127:0] image;
    int i;
    begin
        image = encode_cfg(c);
        ioctl_index = 8'd1;
        for (i = 0; i < 15; i = i + 1) begin
            ioctl_addr = 27'(i);
            ioctl_dout = image[i * 8 +: 8];
            ioctl_wr = 1'b1; tick();
            ioctl_wr = 1'b0; tick();
        end
        ioctl_addr = 27'd15;
        ioctl_dout = image[127:120];
        ioctl_wr = 1'b1;
        tick();
        if (!ioctl_wait)
            $fatal(1, "descriptor commit did not hold back-to-back index 0");
        // Keep the accepted final-byte level asserted for the wait cycle.
        // The loader's commit pulse must come from its validated transaction,
        // not from this repeated raw level.
        tick();
        if (!cfg_commit)
            $fatal(1, "accepted descriptor did not emit cfg_commit");
        ioctl_index = 8'd0;
        ioctl_addr = 27'd0;
        ioctl_dout = byte0;
        tick();
        if (!cfg_valid || cfg_commit || ioctl_wait)
            $fatal(1, "descriptor did not commit atomically under held byte 0");
        tick();
        ioctl_wr = 1'b0;
        tick();
    end
endtask

task send_byte(input [26:0] addr, input [7:0] data);
    while (ioctl_wait) tick();
    ioctl_addr = addr;
    ioctl_dout = data;
    ioctl_wr = 1;
    tick();
    ioctl_wr = 0;
    tick();
endtask

initial begin
    ssv_cfg_t dynagear_cfg;
    ssv_cfg_t cairblad_cfg;
    ssv_cfg_t st010_cfg;
    ssv_cfg_t stmblade_cfg;
    ssv_cfg_t ultrax_cfg;
    logic [26:0] st010_start;
    logic [127:0] malformed_cfg;
    logic [191:0] v3_image;
    logic [7:0] malformed_sum;

    rst = 1; mem_ready = 0; ioctl_download = 0; ioctl_index = 0;
    ioctl_wr = 0; ioctl_addr = 0; ioctl_dout = 0; sdr_wr_ack = 0;
    repeat (2) tick();
    rst = 0; mem_ready = 1; ioctl_download = 1;

    // The loader now requires an MRA <rom index="1"> block BEFORE index 0 and
    // discards index-0 bytes until it validates, so send the Dyna Gear record
    // first. The expectations below are unchanged by it.
    dynagear_cfg = cfg_dynagear();
    send_cfg_then_byte0_no_gap(dynagear_cfg, 8'h34);
    if (!cfg_valid || cfg.extra_ram_mode !== 2'd1 || cfg.nvram_mode !== 2'd0 ||
        cfg.gfx_code_mask !== 20'h1ffff)
        $fatal(1, "Dyna Gear configuration/RAM-map block was rejected");

    send_byte(1, 8'h12);
    if (!sdr_wr_req || sdr_wr_addr !== (SDR_MAINCPU_BASE >> 1) ||
        sdr_wr_din !== 16'h1234 || sdr_wr_be !== 2'b11)
        $fatal(1, "first packed write mismatch");
    sdr_wr_ack = 1; tick();
    sdr_wr_ack = 0; tick();

    // Code 2, row 3 of MAME's three populated quarters must land in ONE
    // aligned 16-byte record at gfx_record_addr(2,3) .. +15:
    //   Q0 -> +0, Q1 -> +4, Q2 -> +8, and +12 is the unwritten quarter 3.
    // That single record is what lets ssv_gfx_row_fetch read a whole tile row
    // with one 128-bit p2 burst instead of two 64-bit p1 bursts.
    send_byte(27'h010004c, 8'h11);
    send_byte(27'h010004d, 8'h22);
    if (!sdr_wr_req ||
        sdr_wr_addr !== (gfx_plane_addr(17'd2, 3'd3, 2'd0, 2'd0) >> 1) ||
        sdr_wr_din !== 16'h2211)
        $fatal(1, "Q0 record address mismatch got %h", sdr_wr_addr);
    q0_addr = sdr_wr_addr;
    sdr_wr_ack = 1; tick();
    sdr_wr_ack = 0; tick();

    send_byte(27'h050004c, 8'h33);
    send_byte(27'h050004d, 8'h44);
    if (!sdr_wr_req ||
        sdr_wr_addr !== (gfx_plane_addr(17'd2, 3'd3, 2'd1, 2'd0) >> 1) ||
        sdr_wr_din !== 16'h4433)
        $fatal(1, "Q1 record address mismatch got %h", sdr_wr_addr);
    q1_addr = sdr_wr_addr;
    sdr_wr_ack = 1; tick();
    sdr_wr_ack = 0; tick();

    send_byte(27'h090004c, 8'h55);
    send_byte(27'h090004d, 8'h66);
    if (!sdr_wr_req ||
        sdr_wr_addr !== (gfx_plane_addr(17'd2, 3'd3, 2'd2, 2'd0) >> 1) ||
        sdr_wr_din !== 16'h6655)
        $fatal(1, "Q2 record address mismatch got %h", sdr_wr_addr);
    q2_addr = sdr_wr_addr;
    sdr_wr_ack = 1; tick();
    sdr_wr_ack = 0; tick();

    // The point of the repack, asserted directly: all three quarters of one
    // tile row share a single 16-byte record, i.e. one p2 burst address.
    if (q0_addr[24:4] !== q1_addr[24:4] || q0_addr[24:4] !== q2_addr[24:4])
        $fatal(1,
               "quarters did not share one 16-byte record: %h %h %h",
               q0_addr, q1_addr, q2_addr);

    // The sample region no longer sits at its stream offset.  Unlike the V60
    // and packed graphics paths, it is a canonical ROM_REGION16_BE image: the
    // even stream byte is the high half of the ES5506 word.
    send_byte(27'h0d00000, 8'hcd);
    send_byte(27'h0d00001, 8'hab);
    if (!sdr_wr_req || sdr_wr_addr !== (SDR_SAMPLES_BASE >> 1) ||
        sdr_wr_din !== 16'hcdab)
        $fatal(1, "sample-region write mismatch got %h", sdr_wr_addr);
    sdr_wr_ack = 1; tick();
    sdr_wr_ack = 0; tick();

    // Signed PCM and the zero-filled lane used by unpaired ROM_LOAD16_BYTE
    // regions both discriminate the byte order directly.
    send_byte(27'h0d00002, 8'h80);
    send_byte(27'h0d00003, 8'h01);
    if (!sdr_wr_req || sdr_wr_din !== 16'h8001)
        $fatal(1, "signed sample word was byte-swapped: %h", sdr_wr_din);
    sdr_wr_ack = 1; tick();
    sdr_wr_ack = 0; tick();
    send_byte(27'h0d00004, 8'h80);
    send_byte(27'h0d00005, 8'h00);
    if (!sdr_wr_req || sdr_wr_din !== 16'h8000)
        $fatal(1, "sparse sample lane was byte-swapped: %h", sdr_wr_din);
    sdr_wr_ack = 1; tick();
    sdr_wr_ack = 0; tick();

    cairblad_cfg = cfg_cairblad();
    send_cfg(cairblad_cfg);
    if (!cfg_valid || !cfg.has_nvram || cfg.extra_ram_mode !== 2'd0 ||
        cfg.nvram_mode !== 2'd2 || cfg.gfx_code_mask !== 20'h3ffff)
        $fatal(1, "Cairblad NVRAM configuration flag was rejected");

    // Version 3 commits only after all 24 bytes and decodes its extension
    // atomically. Sending version last also covers the nonblocking old-byte
    // hazard in the receive-mask completion decision.
    cairblad_cfg.mainram_mirror_010000 = 1'b1;
    cairblad_cfg.input_layout = 4'd2;
    cairblad_cfg.irq_level2_line120 = 1'b1;
    v3_image = encode_cfg_v3(cairblad_cfg);
    send_cfg_v3_version_last(v3_image);
    if (!cfg_valid || !cfg.mainram_mirror_010000 ||
        cfg.input_layout !== 4'd2 || !cfg.irq_level2_line120)
        $fatal(1, "version-3 extension did not commit atomically");

    // A complete checksum-valid image with an unsupported enum fails closed.
    v3_image = encode_cfg_v3(cairblad_cfg);
    v3_image[19 * 8 +: 8] = 8'd1;
    malformed_sum = 8'd0;
    for (int v3_i = 0; v3_i < 23; v3_i++)
        malformed_sum = malformed_sum + v3_image[v3_i * 8 +: 8];
    v3_image[23 * 8 +: 8] = -malformed_sum;
    send_cfg_v3_image(v3_image);
    if (cfg_valid || cfg_commit || cfg.custom_output_mode !== 3'd1)
        $fatal(1, "unsupported version-3 custom-output enum was accepted");
    // The timing cut deliberately permits the rejected payload to appear on
    // cfg, but cfg_valid remains its ownership qualifier.  Index 0 must not
    // use that payload for either SDRAM or the ST010 side destination.
    if (ioctl_wait)
        $fatal(1, "rejected descriptor left the loader waiting");
    ioctl_index = 8'd0;
    ioctl_addr = 27'd0; ioctl_dout = 8'h5a; ioctl_wr = 1'b1; tick();
    ioctl_addr = 27'd1; ioctl_dout = 8'ha5; tick();
    ioctl_wr = 1'b0; tick();
    if (sdr_wr_req || st010_drom_we || rom_loaded)
        $fatal(1, "rejected descriptor allowed index-0 side effects");

    // An out-of-domain exponent is rejected and its unqualified decoded mask
    // takes the safe default rather than evaluating a variable shift.
    v3_image = encode_cfg_v3(cairblad_cfg);
    v3_image[4 * 8 +: 8] = 8'd13;
    malformed_sum = 8'd0;
    for (int mask_i = 0; mask_i < 23; mask_i++)
        malformed_sum = malformed_sum + v3_image[mask_i * 8 +: 8];
    v3_image[23 * 8 +: 8] = -malformed_sum;
    send_cfg_v3_image(v3_image);
    if (cfg_valid || cfg_commit || cfg.gfx_code_mask !== 20'h00000)
        $fatal(1, "invalid graphics exponent did not fail to safe mask");

    v3_image = encode_cfg_v3(cairblad_cfg);
    v3_image[23 * 8 +: 8] = v3_image[23 * 8 +: 8] ^ 8'h01;
    send_cfg_v3_image(v3_image);
    if (cfg_valid || cfg_commit)
        $fatal(1, "bad version-3 23-byte checksum was accepted");

    // A following v2 transaction must not inherit any v3 high bytes.
    cairblad_cfg = cfg_cairblad();
    send_cfg(cairblad_cfg);
    if (!cfg_valid || cfg.mainram_mirror_010000 ||
        cfg.input_layout !== 4'd0 || cfg.irq_level2_line120)
        $fatal(1, "version-2 compatibility inherited stale version-3 fields");

    // Full SRMP7 family geometry: 64 MiB graphics, 24 MiB samples, expanded
    // RAM and matrix/bank classes must remain one validated shared profile.
    cairblad_cfg = cfg_vasara();
    cairblad_cfg.gfx_mb = 7'd64;
    cairblad_cfg.gfx_code_k = 5'd19;
    cairblad_cfg.gfx_code_mask = 20'h7ffff;
    cairblad_cfg.bank_valid = 4'hf;
    cairblad_cfg.sample_mb = 6'd24;
    cairblad_cfg.extra_ram_mode = 2'd3;
    cairblad_cfg.lockout_inverted = 1'b1;
    cairblad_cfg.input_layout = 4'd1;
    cairblad_cfg.mahjong_mode = 3'd5;
    cairblad_cfg.srmp7_sample_half_bank = 1'b1;
    cairblad_cfg.srmp7_irqv_mame = 1'b1;
    send_cfg_v3_image(encode_cfg_v3(cairblad_cfg));
    if (!cfg_valid || cfg.gfx_mb !== 7'd64 || cfg.sample_mb !== 6'd24 ||
        cfg.extra_ram_mode !== 2'd3 || cfg.mahjong_mode !== 3'd5 ||
        cfg.gfx_code_mask !== 20'h7ffff)
        $fatal(1, "SRMP7 family descriptor was rejected");

    cairblad_cfg = cfg_dynagear();
    cairblad_cfg.gfx_mb = 7'd14;
    cairblad_cfg.gfx_code_k = 5'd14;
    cairblad_cfg.gfx_code_mask = 20'h03fff;
    cairblad_cfg.gfx_quarters = 3'd4;
    cairblad_cfg.optional_io_mode = 2'd1;
    cairblad_cfg.has_nvram = 1'b1;
    cairblad_cfg.nvram_mode = 2'd1;
    cairblad_cfg.lockout_inverted = 1'b1;
    cairblad_cfg.wdog_mode = 2'd0;
    send_cfg_v3_image(encode_cfg_v3(cairblad_cfg));
    if (!cfg_valid || cfg.optional_io_mode !== 2'd1 || cfg.gfx_mb !== 7'd14 ||
        cfg.gfx_code_mask !== 20'h03fff)
        $fatal(1, "Eagle Shot optional-device descriptor was rejected");

    cairblad_cfg = cfg_cairblad();
    cairblad_cfg.optional_io_mode = 2'd2;
    cairblad_cfg.adc_conversion_cycles = 8'd56;
    send_cfg_v3_image(encode_cfg_v3(cairblad_cfg));
    if (!cfg_valid || cfg.optional_io_mode !== 2'd2 ||
        cfg.adc_conversion_cycles !== 8'd56)
        $fatal(1, "Sexy Reaction optional-device descriptor was rejected");

    // A repaired checksum does not make a reserved descriptor bit legal.
    malformed_cfg = encode_cfg(cairblad_cfg);
    malformed_cfg[5 * 8 + 7] = 1'b1;
    malformed_sum = 8'd0;
    for (int malformed_i = 0; malformed_i < 15; malformed_i++)
        malformed_sum = malformed_sum +
                        malformed_cfg[malformed_i * 8 +: 8];
    malformed_cfg[15 * 8 +: 8] = -malformed_sum;
    send_cfg_image(malformed_cfg);
    if (cfg_valid)
        $fatal(1, "checksum-valid reserved descriptor bit was accepted");

    // Non-power-of-two quarter sizes are a universal-profile boundary. A
    // 24 MiB MAME region has 6 MiB quarters; the old shift-based mapper
    // treated each as 2 MiB and routed later quarters to the wrong tile code.
    stmblade_cfg = cfg_stmblade();
    send_cfg(stmblade_cfg);
    if (!cfg_valid || cfg.game_id !== stmblade_cfg.game_id ||
        cfg.extra_ram_mode !== 2'd0 || cfg.nvram_mode !== 2'd1 ||
        cfg.gfx_code_mask !== 20'h0ffff)
        $fatal(1, "24 MiB configuration block was rejected");
    send_byte(stream_gfx_start_cfg(stmblade_cfg) +
              gfx_quarter_bytes_cfg(stmblade_cfg), 8'h77);
    send_byte(stream_gfx_start_cfg(stmblade_cfg) +
              gfx_quarter_bytes_cfg(stmblade_cfg) + 27'd1, 8'h66);
    if (!sdr_wr_req ||
        sdr_wr_addr !== (gfx_plane_addr(18'd0, 3'd0, 2'd1, 2'd0) >> 1) ||
        sdr_wr_din !== 16'h6677)
        $fatal(1, "24 MiB Q1 mapping mismatch got %h", sdr_wr_addr);
    sdr_wr_ack = 1; tick();
    sdr_wr_ack = 0; tick();

    ultrax_cfg = cfg_ultrax();
    send_cfg(ultrax_cfg);
    if (!cfg_valid || cfg.game_id !== ultrax_cfg.game_id ||
        cfg.extra_ram_mode !== 2'd2 || cfg.nvram_mode !== 2'd0 ||
        cfg.gfx_code_mask !== 20'h07fff)
        $fatal(1, "12 MiB configuration block was rejected");
    send_byte(stream_gfx_start_cfg(ultrax_cfg) +
              gfx_quarter_bytes_cfg(ultrax_cfg) * 27'd2, 8'h88);
    send_byte(stream_gfx_start_cfg(ultrax_cfg) +
              gfx_quarter_bytes_cfg(ultrax_cfg) * 27'd2 + 27'd1, 8'h99);
    if (!sdr_wr_req ||
        sdr_wr_addr !== (gfx_plane_addr(18'd0, 3'd0, 2'd2, 2'd0) >> 1) ||
        sdr_wr_din !== 16'h9988)
        $fatal(1, "12 MiB Q2 mapping mismatch got %h", sdr_wr_addr);
    sdr_wr_ack = 1; tick();
    sdr_wr_ack = 0; tick();

    // -----------------------------------------------------------------------
    // ST010: one 69,632-byte st010.bin appended to the stream, split by MAME's
    // ROM_COPY into a 64 KB 32-bit-BE "dspprg" and a 4 KB 16-bit-BE "dspdata".
    // Every expected address comes from ssv_pkg, so this checks the loader
    // against the map rather than against a transcription of it.
    // -----------------------------------------------------------------------

    // Switch to a representative 4 MB program / 32 MB graphics / 8 MB sample
    // ST010 profile. Its DSP image starts at 0x2c00000, not the obsolete
    // Dyna-Gear-only 0x1100000 constant. This is the case that proves the
    // universal loader uses the descriptor for both SDRAM and DSP data ROM.
    st010_cfg = cfg_drifto94();
    send_cfg(st010_cfg);
    if (!cfg_valid || !cfg.has_st010 || !cfg.has_drifto_unknown)
        $fatal(1, "ST010 configuration block was rejected");
    st010_start = stream_st010_start_cfg(st010_cfg);
    if (st010_start !== 27'h2c00000)
        $fatal(1, "representative ST010 stream start mismatch %h", st010_start);

    // First program word.
    drom_clr = 1'b1; tick(); drom_clr = 1'b0; tick();
    send_byte(st010_start,         8'h1a);
    send_byte(st010_start + 27'd1, 8'h2b);
    if (!sdr_wr_req ||
        sdr_wr_addr !== (st010_stream_dest_cfg(st010_cfg, st010_start) >> 1) ||
        sdr_wr_din !== 16'h2b1a)
        $fatal(1, "st010 program base mismatch got %h", sdr_wr_addr);
    // The SDRAM destination of instruction 0 must be what the fetch path will
    // ask for. If these two ever disagree the DSP executes garbage, so assert
    // the identity directly rather than trusting both sides separately.
    if (st010_stream_dest_cfg(st010_cfg, st010_start) !==
        st010_prg_byte_addr(14'd0))
        $fatal(1, "st010 program base is not st010_prg_byte_addr(0)");
    sdr_wr_ack = 1; tick();
    sdr_wr_ack = 0; tick();

    // Instruction 5 occupies st010.bin bytes 20..23 (4 bytes per dword).
    send_byte(st010_start + 27'd20, 8'h3c);
    send_byte(st010_start + 27'd21, 8'h4d);
    if (!sdr_wr_req ||
        sdr_wr_addr !== (st010_prg_byte_addr(14'd5) >> 1) ||
        sdr_wr_din !== 16'h4d3c)
        $fatal(1, "st010 instruction-5 address mismatch got %h", sdr_wr_addr);
    if (drom_seen)
        $fatal(1, "program-half byte wrote the on-chip data ROM");
    sdr_wr_ack = 1; tick();
    sdr_wr_ack = 0; tick();

    // Data half. Byte offset 0x22/0x23 inside "dspdata" is word 0x11, and the
    // region is ROM_REGION16_BE, so the EVEN byte is the HIGH half.
    send_byte(st010_start + ST010_DATA_OFFSET + 27'h22, 8'hde);
    send_byte(st010_start + ST010_DATA_OFFSET + 27'h23, 8'had);
    if (!drom_seen)
        $fatal(1, "dspdata byte did not write the on-chip data ROM");
    if (drom_wa_l !== st010_drom_word_cfg(
            st010_cfg, st010_start + ST010_DATA_OFFSET + 27'h23))
        $fatal(1, "dspdata word index mismatch got %h", drom_wa_l);
    if (drom_wa_l !== 11'h011)
        $fatal(1, "dspdata word index is not 0x011, got %h", drom_wa_l);
    if (drom_wd_l !== 16'hdead)
        $fatal(1, "dspdata is not big-endian, got %h", drom_wd_l);
    // The same pair also lands in SDRAM at its identity offset.
    if (!sdr_wr_req ||
        sdr_wr_addr !== (st010_stream_dest_cfg(
            st010_cfg, st010_start + ST010_DATA_OFFSET + 27'h22) >> 1))
        $fatal(1, "dspdata SDRAM address mismatch got %h", sdr_wr_addr);
    sdr_wr_ack = 1; tick();
    sdr_wr_ack = 0; tick();

    // The whole region must sit in the bank-3 tail after samples and never touch
    // region, which the open-ended `>= STREAM_SAMPLES` branch would have
    // claimed had the st010 test not been put ahead of it.
    if (((st010_stream_dest_cfg(st010_cfg, st010_start) >>
          (SDR_AW-1)) & 2'b11) !== 2'd3 ||
        ((st010_stream_dest_cfg(
            st010_cfg, st010_start + STREAM_ST010_SIZE - 27'd1) >>
          (SDR_AW-1)) & 2'b11) !== 2'd3)
        $fatal(1, "st010 region left SDRAM bank 3");

    ioctl_download = 0;
    tick();
    if (!rom_loaded) $fatal(1, "rom_loaded did not assert after drain");

    // A malformed replacement descriptor invalidates both the decoded profile
    // and the prior loaded-ROM state, and must never emit an accepted commit.
    ioctl_download = 1'b1;
    send_cfg_image(malformed_cfg);
    if (cfg_valid || rom_loaded || cfg_commit)
        $fatal(1, "malformed replacement descriptor did not fail closed");

    // Reset on the validation cycle must cancel the pending transaction and
    // its wait without publishing either validity or a commit pulse.
    v3_image = encode_cfg_v3(cfg_cairblad());
    ioctl_index = 8'd1;
    for (int reset_i = 0; reset_i < 23; reset_i++) begin
        ioctl_addr = 27'(reset_i);
        ioctl_dout = v3_image[reset_i * 8 +: 8];
        ioctl_wr = 1'b1; tick(); ioctl_wr = 1'b0; tick();
    end
    ioctl_addr = 27'd23;
    ioctl_dout = v3_image[23 * 8 +: 8];
    ioctl_wr = 1'b1; tick();
    if (!ioctl_wait || cfg_valid || cfg_commit)
        $fatal(1, "final descriptor byte did not enter pending commit");
    rst = 1'b1; tick();
    ioctl_wr = 1'b0;
    if (ioctl_wait || cfg_valid || cfg_commit || rom_loaded ||
        sdr_wr_req || st010_drom_we)
        $fatal(1, "reset did not clear pending descriptor state");
    rst = 1'b0; tick();

    // Re-prove the no-gap path after that interrupted transaction: the final
    // descriptor byte commits once, byte zero is retained, and byte one makes
    // exactly the expected first SDRAM word.
    send_cfg_then_byte0_no_gap(dynagear_cfg, 8'h78);
    send_byte(27'd1, 8'h56);
    if (!sdr_wr_req || sdr_wr_addr !== (SDR_MAINCPU_BASE >> 1) ||
        sdr_wr_din !== 16'h5678 || sdr_wr_be !== 2'b11)
        $fatal(1, "post-reset no-gap descriptor/first write mismatch");
    $display("PASS tb_ssv_rom_loader");
    $finish;
end
endmodule
