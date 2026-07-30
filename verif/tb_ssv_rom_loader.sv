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

// Configuration blocks. Layout documented in rtl/mem/ssv_rom_loader.sv; byte 15
// is the negated sum of bytes 0..14, and byte 1 is the version (2).
//
// These are the bytes the MRAs ACTUALLY SHIP, not values restated from
// ssv_pkg::cfg_dynagear(). This task used to hand-build its own, and it drifted:
// it carried bank_map 0xE4 and flags0 0x00 while the shipped MRA carries 0x00
// and 0x04. Because the bench and the reference record were wrong in the same
// direction, nothing could detect it -- simulation and hardware were running
// different configurations for the one title considered working.
//
// check_cfg_matches_record() closes the loop: the bytes come from the MRA and
// the decode must equal cfg_dynagear() field by field, so the three can no
// longer disagree silently. That the MRA is itself current with MAME is provable
// separately by re-running tools/gen_ssv_mras.py and diffing.
//
// Copied verbatim from the MRAs, so a regenerated MRA this bench no longer
// matches shows up as a failure rather than as drift.
//   mra/Dyna Gear.mra                       -- no ST010, 3 quarters, 4 MB samples
//   mra/Drift Out '94 - The Hard Order.mra   -- ST010, 4 quarters, 8 MB samples
localparam logic [127:0] CFG_DYNAGEAR = 128'h53020110110003000404010004000079;
localparam logic [127:0] CFG_DRIFTO94 = 128'h53020420120004040308000F0800004B;

// Drift Out '94's st010 block sits behind 4 MB program + 32 MB graphics +
// 8 MB samples. Derived here so the bench states the same arithmetic the loader
// must perform, rather than a magic number.
localparam logic [26:0] DRIFTO94_ST010_BASE = 27'h0400000    // program
                                            + 27'h2000000    // graphics
                                            + 27'h0800000;   // samples

task send_cfg_hex(input logic [127:0] blk);
    logic [7:0] b [0:15];
    logic [7:0] sum;
    int i;
    begin
        for (i = 0; i < 16; i = i + 1)
            b[i] = blk[(15 - i) * 8 +: 8];
        // The checksum is verified, not recomputed: these bytes are supposed to
        // be exactly what the MRA ships, so a bad sum means the literal above
        // was mistyped rather than that the block needs fixing up.
        sum = 8'd0;
        for (i = 0; i < 15; i = i + 1) sum = sum + b[i];
        if (b[15] !== ((-sum) & 8'hFF))
            $fatal(1, "cfg literal %h has checksum %h, computed %h",
                   blk, b[15], (-sum) & 8'hFF);
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

task send_cfg;
    send_cfg_hex(CFG_DYNAGEAR);
endtask

// The block the MRA ships must decode to exactly the record the benches and the
// docs call Dyna Gear. Checked field by field rather than as a struct compare so
// a failure names the field that drifted.
task check_cfg_matches_record;
    ssv_cfg_t want;
    begin
        want = ssv_pkg::cfg_dynagear();
        if (cfg.game_id !== want.game_id)
            $fatal(1, "game_id: MRA %0d vs cfg_dynagear %0d", cfg.game_id, want.game_id);
        if (cfg.prog_mb !== want.prog_mb)
            $fatal(1, "prog_mb: MRA %0d vs cfg_dynagear %0d", cfg.prog_mb, want.prog_mb);
        if (cfg.gfx_mb !== want.gfx_mb)
            $fatal(1, "gfx_mb: MRA %0d vs cfg_dynagear %0d", cfg.gfx_mb, want.gfx_mb);
        if (cfg.gfx_code_k !== want.gfx_code_k)
            $fatal(1, "gfx_code_k: MRA %0d vs cfg_dynagear %0d",
                   cfg.gfx_code_k, want.gfx_code_k);
        if (cfg.gfx_code_mul3 !== want.gfx_code_mul3)
            $fatal(1, "gfx_code_mul3: MRA %0b vs cfg_dynagear %0b",
                   cfg.gfx_code_mul3, want.gfx_code_mul3);
        if (cfg.gfx_code_mask !== want.gfx_code_mask)
            $fatal(1, "gfx_code_mask: MRA %h vs cfg_dynagear %h",
                   cfg.gfx_code_mask, want.gfx_code_mask);
        if (cfg.gfx_quarters !== want.gfx_quarters)
            $fatal(1, "gfx_quarters: MRA %0d vs cfg_dynagear %0d",
                   cfg.gfx_quarters, want.gfx_quarters);
        if (cfg.samples_mb !== want.samples_mb)
            $fatal(1, "samples_mb: MRA %0d vs cfg_dynagear %0d",
                   cfg.samples_mb, want.samples_mb);
        if (cfg.bank_map !== want.bank_map)
            $fatal(1, "bank_map: MRA %b vs cfg_dynagear %b", cfg.bank_map, want.bank_map);
        if (cfg.bank_valid !== want.bank_valid)
            $fatal(1, "bank_valid: MRA %b vs cfg_dynagear %b",
                   cfg.bank_valid, want.bank_valid);
        if (cfg.tile_code_identity !== want.tile_code_identity)
            $fatal(1, "tile_code_identity: MRA %0b vs cfg_dynagear %0b",
                   cfg.tile_code_identity, want.tile_code_identity);
        if (cfg.irq_level1_line0 !== want.irq_level1_line0)
            $fatal(1, "irq_level1_line0: MRA %0b vs cfg_dynagear %0b",
                   cfg.irq_level1_line0, want.irq_level1_line0);
        if (cfg.has_add_buttons !== want.has_add_buttons)
            $fatal(1, "has_add_buttons: MRA %0b vs cfg_dynagear %0b",
                   cfg.has_add_buttons, want.has_add_buttons);
        if (cfg.has_st010 !== want.has_st010)
            $fatal(1, "has_st010: MRA %0b vs cfg_dynagear %0b",
                   cfg.has_st010, want.has_st010);
        if (cfg.wdog_mode !== want.wdog_mode)
            $fatal(1, "wdog_mode: MRA %0d vs cfg_dynagear %0d",
                   cfg.wdog_mode, want.wdog_mode);
        $display("PASS cfg block from mra/Dyna Gear.mra matches ssv_pkg::cfg_dynagear()");
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
    rst = 1; mem_ready = 0; ioctl_download = 0; ioctl_index = 0;
    ioctl_wr = 0; ioctl_addr = 0; ioctl_dout = 0; sdr_wr_ack = 0;
    repeat (2) tick();
    rst = 0; mem_ready = 1; ioctl_download = 1;

    // The loader now requires an MRA <rom index="1"> block BEFORE index 0 and
    // discards index-0 bytes until it validates, so send the Dyna Gear record
    // first. The expectations below are unchanged by it.
    send_cfg();
    if (!cfg_valid)
        $fatal(1, "configuration block was rejected");
    check_cfg_matches_record();

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
        sdr_wr_addr !== (gfx_plane_addr(18'd2, 3'd3, 2'd0, 2'd0) >> 1) ||
        sdr_wr_din !== 16'h2211)
        $fatal(1, "Q0 record address mismatch got %h", sdr_wr_addr);
    q0_addr = sdr_wr_addr;
    sdr_wr_ack = 1; tick();
    sdr_wr_ack = 0; tick();

    send_byte(27'h050004c, 8'h33);
    send_byte(27'h050004d, 8'h44);
    if (!sdr_wr_req ||
        sdr_wr_addr !== (gfx_plane_addr(18'd2, 3'd3, 2'd1, 2'd0) >> 1) ||
        sdr_wr_din !== 16'h4433)
        $fatal(1, "Q1 record address mismatch got %h", sdr_wr_addr);
    q1_addr = sdr_wr_addr;
    sdr_wr_ack = 1; tick();
    sdr_wr_ack = 0; tick();

    send_byte(27'h090004c, 8'h55);
    send_byte(27'h090004d, 8'h66);
    if (!sdr_wr_req ||
        sdr_wr_addr !== (gfx_plane_addr(18'd2, 3'd3, 2'd2, 2'd0) >> 1) ||
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

    // The sample region no longer sits at its stream offset: the 16 MB
    // graphics region displaced it to SDR_SAMPLES_BASE = 0x1160000.
    send_byte(27'h0d00000, 8'hcd);
    send_byte(27'h0d00001, 8'hab);
    if (!sdr_wr_req || sdr_wr_addr !== (SDR_SAMPLES_BASE >> 1) ||
        sdr_wr_din !== 16'habcd)
        $fatal(1, "sample-region write mismatch got %h", sdr_wr_addr);
    sdr_wr_ack = 1; tick();
    sdr_wr_ack = 0; tick();

    // -----------------------------------------------------------------------
    // ST010: one 69,632-byte st010.bin appended to the stream, split by MAME's
    // ROM_COPY into a 64 KB 32-bit-BE "dspprg" and a 4 KB 16-bit-BE "dspdata".
    // Every expected address comes from ssv_pkg, so this checks the loader
    // against the map rather than against a transcription of it.
    //
    // Driven with DRIFT OUT '94's config, not Dyna Gear's. Two reasons:
    //  * Dyna Gear has no daughterboard, and the loader now gates the dspdata
    //    window on cfg.has_st010, so under the Dyna Gear record these writes
    //    must NOT reach the DSP -- which is asserted first, below.
    //  * The st010 block has no fixed stream offset any more. It sits behind
    //    that game's program + graphics + samples, which for Drift Out '94 is
    //    0x2C00000 and for Storm Blade 0x1880000. Using a per-game base is the
    //    whole point of the change.
    // -----------------------------------------------------------------------

    // First, the negative case: with Dyna Gear's record still loaded, bytes at
    // an st010 offset must not be mistaken for DSP data.
    drom_clr = 1'b1; tick(); drom_clr = 1'b0; tick();
    send_byte(DRIFTO94_ST010_BASE + ST010_DATA_OFFSET + 27'h22, 8'hde);
    if (drom_seen)
        $fatal(1, "a set without has_st010 wrote the DSP data ROM");
    sdr_wr_ack = 1; tick();
    sdr_wr_ack = 0; tick();

    // Now switch to the ST010 title's record.
    send_cfg_hex(CFG_DRIFTO94);
    if (!cfg_valid)
        $fatal(1, "Drift Out '94 configuration block was rejected");
    if (!cfg.has_st010)
        $fatal(1, "Drift Out '94 record does not report has_st010");
    if (cfg.samples_mb !== 4'd8)
        $fatal(1, "Drift Out '94 samples_mb is %0d, expected 8", cfg.samples_mb);

    // First program word.
    drom_clr = 1'b1; tick(); drom_clr = 1'b0; tick();
    send_byte(DRIFTO94_ST010_BASE,         8'h1a);
    send_byte(DRIFTO94_ST010_BASE + 27'd1, 8'h2b);
    if (!sdr_wr_req ||
        sdr_wr_addr !== (st010_stream_dest(DRIFTO94_ST010_BASE,
                                           DRIFTO94_ST010_BASE) >> 1) ||
        sdr_wr_din !== 16'h2b1a)
        $fatal(1, "st010 program base mismatch got %h", sdr_wr_addr);
    // The SDRAM destination of instruction 0 must be what the fetch path will
    // ask for. If these two ever disagree the DSP executes garbage, so assert
    // the identity directly rather than trusting both sides separately.
    if (st010_stream_dest(DRIFTO94_ST010_BASE, DRIFTO94_ST010_BASE) !==
        st010_prg_byte_addr(14'd0))
        $fatal(1, "st010 program base is not st010_prg_byte_addr(0)");
    sdr_wr_ack = 1; tick();
    sdr_wr_ack = 0; tick();

    // Instruction 5 occupies st010.bin bytes 20..23 (4 bytes per dword).
    send_byte(DRIFTO94_ST010_BASE + 27'd20, 8'h3c);
    send_byte(DRIFTO94_ST010_BASE + 27'd21, 8'h4d);
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
    send_byte(DRIFTO94_ST010_BASE + ST010_DATA_OFFSET + 27'h22, 8'hde);
    send_byte(DRIFTO94_ST010_BASE + ST010_DATA_OFFSET + 27'h23, 8'had);
    if (!drom_seen)
        $fatal(1, "dspdata byte did not write the on-chip data ROM");
    if (drom_wa_l !== st010_drom_word(DRIFTO94_ST010_BASE + ST010_DATA_OFFSET +
                                      27'h23, DRIFTO94_ST010_BASE))
        $fatal(1, "dspdata word index mismatch got %h", drom_wa_l);
    if (drom_wa_l !== 11'h011)
        $fatal(1, "dspdata word index is not 0x011, got %h", drom_wa_l);
    if (drom_wd_l !== 16'hdead)
        $fatal(1, "dspdata is not big-endian, got %h", drom_wd_l);
    // The same pair also lands in SDRAM at its identity offset.
    if (!sdr_wr_req ||
        sdr_wr_addr !== (st010_stream_dest(DRIFTO94_ST010_BASE +
                                           ST010_DATA_OFFSET + 27'h22,
                                           DRIFTO94_ST010_BASE) >> 1))
        $fatal(1, "dspdata SDRAM address mismatch got %h", sdr_wr_addr);
    sdr_wr_ack = 1; tick();
    sdr_wr_ack = 0; tick();

    // The whole region must sit in the free bank 2 and never touch the sample
    // region, which the open-ended `>= str_samp_base` branch would have claimed
    // had the st010 test not been put ahead of it.
    if (st010_stream_dest(DRIFTO94_ST010_BASE,
                          DRIFTO94_ST010_BASE)[SDR_AW:SDR_AW-1] !== 2'd2 ||
        st010_stream_dest(DRIFTO94_ST010_BASE + STREAM_ST010_SIZE - 27'd1,
                          DRIFTO94_ST010_BASE)[SDR_AW:SDR_AW-1] !== 2'd2)
        $fatal(1, "st010 region left SDRAM bank 2");

    ioctl_download = 0;
    tick();
    if (!rom_loaded) $fatal(1, "rom_loaded did not assert after drain");
    $display("PASS tb_ssv_rom_loader");
    $finish;
end
endmodule
