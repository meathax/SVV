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
logic [SDR_AW:1] sdr_wr_addr;
logic [15:0] sdr_wr_din;
logic [1:0] sdr_wr_be;
logic [26:0] download_max_addr;
logic [SDR_AW:1] q0_addr, q1_addr, q2_addr;
logic st010_drom_we;
logic [10:0] st010_drom_wa;
logic [15:0] st010_drom_wd;

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

// Serialize one runtime profile exactly as the MRA index-1 block does.
task send_cfg(input ssv_cfg_t c);
    logic [7:0] b [0:15];
    logic [7:0] sum;
    int i;
    begin
        b[0]=8'h53; b[1]=8'd2; b[2]={5'd0,c.prog_mb};
        b[3]={2'd0,c.gfx_mb}; b[4]={3'd0,c.gfx_code_k};
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
        ioctl_index = 8'd1;
        for (i = 0; i < 16; i = i + 1) begin
            ioctl_addr = 27'(i);
            ioctl_dout = b[i];
            ioctl_wr   = 1'b1;
            tick();
            ioctl_wr   = 1'b0;
            tick();
        end
        ioctl_index = 8'd0;
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

    rst = 1; mem_ready = 0; ioctl_download = 0; ioctl_index = 0;
    ioctl_wr = 0; ioctl_addr = 0; ioctl_dout = 0; sdr_wr_ack = 0;
    repeat (2) tick();
    rst = 0; mem_ready = 1; ioctl_download = 1;

    // The loader now requires an MRA <rom index="1"> block BEFORE index 0 and
    // discards index-0 bytes until it validates, so send the Dyna Gear record
    // first. The expectations below are unchanged by it.
    dynagear_cfg = cfg_dynagear();
    send_cfg(dynagear_cfg);
    if (!cfg_valid || cfg.extra_ram_mode !== 2'd1 || cfg.nvram_mode !== 2'd0)
        $fatal(1, "Dyna Gear configuration/RAM-map block was rejected");

    send_byte(0, 8'h34);
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
        cfg.nvram_mode !== 2'd2)
        $fatal(1, "Cairblad NVRAM configuration flag was rejected");

    // Non-power-of-two quarter sizes are a universal-profile boundary. A
    // 24 MiB MAME region has 6 MiB quarters; the old shift-based mapper
    // treated each as 2 MiB and routed later quarters to the wrong tile code.
    stmblade_cfg = cfg_stmblade();
    send_cfg(stmblade_cfg);
    if (!cfg_valid || cfg.game_id !== stmblade_cfg.game_id ||
        cfg.extra_ram_mode !== 2'd0 || cfg.nvram_mode !== 2'd1)
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
        cfg.extra_ram_mode !== 2'd2 || cfg.nvram_mode !== 2'd0)
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

    // The whole region must sit in the free bank 2 and never touch the sample
    // region, which the open-ended `>= STREAM_SAMPLES` branch would have
    // claimed had the st010 test not been put ahead of it.
    if (st010_stream_dest_cfg(st010_cfg, st010_start)
            [SDR_AW:SDR_AW-1] !== 2'd2 ||
        st010_stream_dest_cfg(
            st010_cfg, st010_start + STREAM_ST010_SIZE - 27'd1)
            [SDR_AW:SDR_AW-1] !== 2'd2)
        $fatal(1, "st010 region left SDRAM bank 2");

    ioctl_download = 0;
    tick();
    if (!rom_loaded) $fatal(1, "rom_loaded did not assert after drain");
    $display("PASS tb_ssv_rom_loader");
    $finish;
end
endmodule
