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

// Dyna Gear configuration block. Layout documented in
// rtl/mem/ssv_rom_loader.sv; byte 15 is the negated sum of bytes 0..14.
task send_cfg;
    logic [7:0] b [0:15];
    logic [7:0] sum;
    int i;
    begin
        b[0]=8'h53; b[1]=8'd1;  b[2]=8'd1;  b[3]=8'd16;
        b[4]=8'd17; b[5]=8'd0;  b[6]=8'd3;  b[7]=8'b11_10_01_00;
        b[8]=8'b0000_0100;      b[9]=8'd0;  b[10]=8'd1; b[11]=8'd0;
        b[12]=8'd0; b[13]=8'd0; b[14]=8'd0;
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
    // -----------------------------------------------------------------------

    // First program word.
    drom_clr = 1'b1; tick(); drom_clr = 1'b0; tick();
    send_byte(STREAM_ST010,        8'h1a);
    send_byte(STREAM_ST010 + 27'd1, 8'h2b);
    if (!sdr_wr_req || sdr_wr_addr !== (st010_stream_dest(STREAM_ST010) >> 1) ||
        sdr_wr_din !== 16'h2b1a)
        $fatal(1, "st010 program base mismatch got %h", sdr_wr_addr);
    // The SDRAM destination of instruction 0 must be what the fetch path will
    // ask for. If these two ever disagree the DSP executes garbage, so assert
    // the identity directly rather than trusting both sides separately.
    if (st010_stream_dest(STREAM_ST010) !== st010_prg_byte_addr(14'd0))
        $fatal(1, "st010 program base is not st010_prg_byte_addr(0)");
    sdr_wr_ack = 1; tick();
    sdr_wr_ack = 0; tick();

    // Instruction 5 occupies st010.bin bytes 20..23 (4 bytes per dword).
    send_byte(STREAM_ST010 + 27'd20, 8'h3c);
    send_byte(STREAM_ST010 + 27'd21, 8'h4d);
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
    send_byte(STREAM_ST010 + ST010_DATA_OFFSET + 27'h22, 8'hde);
    send_byte(STREAM_ST010 + ST010_DATA_OFFSET + 27'h23, 8'had);
    if (!drom_seen)
        $fatal(1, "dspdata byte did not write the on-chip data ROM");
    if (drom_wa_l !== st010_drom_word(STREAM_ST010 + ST010_DATA_OFFSET +
                                      27'h23))
        $fatal(1, "dspdata word index mismatch got %h", drom_wa_l);
    if (drom_wa_l !== 11'h011)
        $fatal(1, "dspdata word index is not 0x011, got %h", drom_wa_l);
    if (drom_wd_l !== 16'hdead)
        $fatal(1, "dspdata is not big-endian, got %h", drom_wd_l);
    // The same pair also lands in SDRAM at its identity offset.
    if (!sdr_wr_req ||
        sdr_wr_addr !== (st010_stream_dest(STREAM_ST010 + ST010_DATA_OFFSET +
                                          27'h22) >> 1))
        $fatal(1, "dspdata SDRAM address mismatch got %h", sdr_wr_addr);
    sdr_wr_ack = 1; tick();
    sdr_wr_ack = 0; tick();

    // The whole region must sit in the free bank 2 and never touch the sample
    // region, which the open-ended `>= STREAM_SAMPLES` branch would have
    // claimed had the st010 test not been put ahead of it.
    if (st010_stream_dest(STREAM_ST010)[SDR_AW:SDR_AW-1] !== 2'd2 ||
        st010_stream_dest(STREAM_ST010 + STREAM_ST010_SIZE - 27'd1)
            [SDR_AW:SDR_AW-1] !== 2'd2)
        $fatal(1, "st010 region left SDRAM bank 2");

    ioctl_download = 0;
    tick();
    if (!rom_loaded) $fatal(1, "rom_loaded did not assert after drain");
    $display("PASS tb_ssv_rom_loader");
    $finish;
end
endmodule
