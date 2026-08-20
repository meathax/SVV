// SPDX-License-Identifier: GPL-3.0-or-later
//
// Hiscore save/restore across both memories the SSV core exposes to
// rtl/hiscore.v: block-RAM main RAM ($000000-$00ffff) and the SDRAM-backed
// extra work RAM ($010000-$03ffff, rtl/mem/ssv_hs_extram.sv).
//
// The configuration blob is Twin Eagle II's, byte for byte as
// tools/gen_ssv_mras.py writes it into the MRA on ioctl index 3, so a change
// to either the header layout or the entry layout fails here.
`timescale 1ns/1ps

module tb_ssv_hiscore;

localparam int SDR_AW = 26;
localparam logic [SDR_AW:0] EXTRA_BASE = 27'h0420000;

logic clk = 0;
always #10 clk = ~clk;

logic reset = 1'b1;

// ---------------------------------------------------------------------------
// Twin Eagle II MRA payload
// ---------------------------------------------------------------------------
// 16-byte header, then two 8-byte entries:
//   $00e208 length $03 start $40 end $0f   (main RAM)
//   $015572 length $2f start $40 end $0a   (extra work RAM)
localparam int CFG_LEN = 32;
byte unsigned cfg_blob [] = '{
    8'h00, 8'h00, 8'h00, 8'h00, 8'hFF, 8'hFF, 8'h00, 8'h40,
    8'h01, 8'h00, 8'h00, 8'h01, 8'h00, 8'h0F, 8'h04, 8'h00,
    8'h00, 8'h00, 8'hE2, 8'h08, 8'h03, 8'h40, 8'h0F, 8'h00,
    8'h00, 8'h01, 8'h55, 8'h72, 8'h2F, 8'h40, 8'h0A, 8'h00
};

localparam int DUMP_LEN = 3 + 47;   // must equal <nvram index="4" size="50"/>
byte unsigned dump [] = new[DUMP_LEN];

// ---------------------------------------------------------------------------
// ioctl
// ---------------------------------------------------------------------------
logic        ioctl_download = 1'b0;
logic        ioctl_upload   = 1'b0;
logic        ioctl_wr       = 1'b0;
logic [24:0] ioctl_addr     = '0;
logic  [7:0] ioctl_index    = '0;
logic  [7:0] ioctl_dout     = '0;
logic        osd_status     = 1'b0;

// ---------------------------------------------------------------------------
// Hiscore module and the two memories behind it
// ---------------------------------------------------------------------------
wire [17:0] hs_addr;
wire  [7:0] hs_data_to_ram, hs_data_to_hps;
wire        hs_ram_write, hs_configured, hs_upload_req;
wire        hs_intent_read, hs_intent_write;

wire [14:0] hs_word_addr = hs_addr[15:1];
wire [15:0] hs_word_din  = {hs_data_to_ram, hs_data_to_ram};
wire  [1:0] hs_word_be   = hs_addr[0] ? 2'b10 : 2'b01;
wire        hs_ext_sel, hs_ext_ready;
wire  [7:0] hs_ext_dout;
wire        hs_ram_we = hs_ram_write && !hs_ext_sel;

// Main RAM: one 32Kx16 byte-enabled port with a registered read, exactly the
// shape of the work_ram port ssv_core hands out.
logic [15:0] main_ram [0:32767];
logic [15:0] hs_word_dout;
always_ff @(posedge clk) begin
    if (hs_ram_we) begin
        if (hs_word_be[0]) main_ram[hs_word_addr][7:0]  <= hs_word_din[7:0];
        if (hs_word_be[1]) main_ram[hs_word_addr][15:8] <= hs_word_din[15:8];
    end
    hs_word_dout <= main_ram[hs_word_addr];
end

logic hs_addr0_q, hs_ext_sel_q;
always_ff @(posedge clk) begin
    hs_addr0_q   <= hs_addr[0];
    hs_ext_sel_q <= hs_ext_sel;
end
wire [7:0] hs_main_from_ram = hs_addr0_q ? hs_word_dout[15:8] : hs_word_dout[7:0];
wire [7:0] hs_data_from_ram = hs_ext_sel_q ? hs_ext_dout : hs_main_from_ram;

// SDRAM stand-in for the extra work RAM: 64-bit burst reads and byte-enabled
// word writes, both answered late enough to prove the wait handshake works.
logic        ext_rd_req, ext_rd_ack = 1'b0;
logic [SDR_AW:3] ext_rd_addr;
logic [63:0] ext_rd_dout = '0;
logic        ext_wr_req, ext_wr_ack = 1'b0;
logic [SDR_AW:1] ext_wr_addr;
logic [15:0] ext_wr_din;
logic  [1:0] ext_wr_be;

logic [15:0] sdram_words [logic [SDR_AW:1]];

function automatic logic [15:0] sd_read(input logic [SDR_AW:1] a);
    sd_read = sdram_words.exists(a) ? sdram_words[a] : 16'h0000;
endfunction

int rd_delay = 0;
always_ff @(posedge clk) begin
    ext_rd_ack <= 1'b0;
    if (ext_rd_req && !ext_rd_ack) begin
        if (rd_delay == 11) begin
            ext_rd_dout <= {sd_read({ext_rd_addr, 2'd3}),
                            sd_read({ext_rd_addr, 2'd2}),
                            sd_read({ext_rd_addr, 2'd1}),
                            sd_read({ext_rd_addr, 2'd0})};
            ext_rd_ack  <= 1'b1;
            rd_delay    <= 0;
        end
        else rd_delay <= rd_delay + 1;
    end
    else rd_delay <= 0;
end

int wr_delay = 0;
always_ff @(posedge clk) begin
    ext_wr_ack <= 1'b0;
    if (ext_wr_req && !ext_wr_ack) begin
        if (wr_delay == 7) begin
            begin
                automatic logic [15:0] cur = sd_read(ext_wr_addr);
                if (ext_wr_be[0]) cur[7:0]  = ext_wr_din[7:0];
                if (ext_wr_be[1]) cur[15:8] = ext_wr_din[15:8];
                sdram_words[ext_wr_addr] = cur;
            end
            ext_wr_ack <= 1'b1;
            wr_delay   <= 0;
        end
        else wr_delay <= wr_delay + 1;
    end
    else wr_delay <= 0;
end

ssv_hs_extram #(
    .SDR_AW(SDR_AW), .EXTRA_BASE(EXTRA_BASE), .CPU_BASE(18'h10000)
) dut_extram (
    .clk(clk), .rst(reset), .enable(1'b1),
    .hs_access(hs_intent_read | hs_intent_write),
    .hs_addr(hs_addr), .hs_write(hs_ram_write), .hs_din(hs_data_to_ram),
    .hs_dout(hs_ext_dout), .hs_ready(hs_ext_ready), .hs_sel(hs_ext_sel),
    .sdr_ready(1'b1),
    .rd_req(ext_rd_req), .rd_addr(ext_rd_addr),
    .rd_dout(ext_rd_dout), .rd_ack(ext_rd_ack),
    .wr_req(ext_wr_req), .wr_addr(ext_wr_addr),
    .wr_din(ext_wr_din), .wr_be(ext_wr_be), .wr_ack(ext_wr_ack)
);

hiscore #(
    .HS_ADDRESSWIDTH(18), .HS_SCOREWIDTH(8), .CFG_ADDRESSWIDTH(4)
) dut (
    .clk(clk), .paused(1'b0), .reset(reset), .autosave(1'b1),
    .ioctl_upload(ioctl_upload), .ioctl_upload_req(hs_upload_req),
    .ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr),
    .ioctl_addr(ioctl_addr), .ioctl_index(ioctl_index),
    .OSD_STATUS(osd_status),
    .data_from_hps(ioctl_dout),
    .data_from_ram(hs_data_from_ram),
    .ram_ready(hs_ext_ready),
    .ram_address(hs_addr),
    .data_to_hps(hs_data_to_hps),
    .data_to_ram(hs_data_to_ram),
    .ram_write(hs_ram_write),
    .ram_intent_read(hs_intent_read), .ram_intent_write(hs_intent_write),
    .pause_cpu(), .configured(hs_configured)
);

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
task automatic ioctl_send(input logic [7:0] index, input byte unsigned data[],
                          input int len);
    ioctl_index <= index;
    ioctl_download <= 1'b1;
    @(posedge clk);
    for (int i = 0; i < len; i++) begin
        ioctl_addr <= i;
        ioctl_dout <= data[i];
        ioctl_wr   <= 1'b1;
        @(posedge clk);
        ioctl_wr   <= 1'b0;
        @(posedge clk);
    end
    ioctl_download <= 1'b0;
    @(posedge clk);
endtask

function automatic logic [7:0] main_byte(input int unsigned a);
    main_byte = a[0] ? main_ram[a[15:1]][15:8] : main_ram[a[15:1]][7:0];
endfunction

task automatic main_poke(input int unsigned a, input logic [7:0] d);
    if (a[0]) main_ram[a[15:1]][15:8] = d;
    else      main_ram[a[15:1]][7:0]  = d;
endtask

function automatic logic [SDR_AW:1] ext_word(input int unsigned a);
    ext_word = (EXTRA_BASE[SDR_AW:1] + ((a - 32'h10000) >> 1));
endfunction

function automatic logic [7:0] ext_byte(input int unsigned a);
    logic [15:0] w;
    w = sd_read(ext_word(a));
    ext_byte = a[0] ? w[15:8] : w[7:0];
endfunction

task automatic ext_poke(input int unsigned a, input logic [7:0] d);
    logic [15:0] w;
    w = sd_read(ext_word(a));
    if (a[0]) w[15:8] = d; else w[7:0] = d;
    sdram_words[ext_word(a)] = w;
endtask

int errors = 0;

task automatic expect_byte(input string what, input logic [7:0] got,
                           input logic [7:0] want);
    if (got !== want) begin
        $display("FAIL %s: got %02x want %02x", what, got, want);
        errors++;
    end
endtask

// ---------------------------------------------------------------------------
// Stimulus
// ---------------------------------------------------------------------------
byte unsigned upload_got [] = new[DUMP_LEN];

initial begin
    for (int i = 0; i < 32768; i++) main_ram[i] = 16'h0000;
    for (int i = 0; i < DUMP_LEN; i++) dump[i] = 8'(8'h30 + i);
    // The restored table must satisfy the dat's own start/end markers, so the
    // dump carries them at the positions the entries name.
    dump[0]  = 8'h40;   // $00e208 start
    dump[2]  = 8'h0f;   // $00e20a end
    dump[3]  = 8'h40;   // $015572 start
    dump[49] = 8'h0a;   // $0155a0 end

    repeat (4) @(posedge clk);

    ioctl_send(8'd3, cfg_blob, CFG_LEN);
    if (!hs_configured) begin
        $display("FAIL: configured did not assert after the index-3 blob");
        errors++;
    end
    ioctl_send(8'd4, dump, DUMP_LEN);

    // The game has initialised its table: both entries show their markers.
    main_poke(32'h00e208, 8'h40);
    main_poke(32'h00e20a, 8'h0f);
    ext_poke (32'h015572, 8'h40);
    ext_poke (32'h0155a0, 8'h0a);

    repeat (4) @(posedge clk);
    reset <= 1'b0;

    // Restore: 50 bytes at WRITE_HOLD=256 cycles each, plus check retries.
    repeat (200000) @(posedge clk);

    for (int i = 0; i < 3; i++)
        expect_byte($sformatf("main $%06x", 32'h00e208 + i),
                    main_byte(32'h00e208 + i), dump[i]);
    for (int i = 0; i < 47; i++)
        expect_byte($sformatf("extra $%06x", 32'h015572 + i),
                    ext_byte(32'h015572 + i), dump[3 + i]);

    // The game then moves the scores on: extraction on OSD open must pick the
    // new bytes up out of both memories and ask for an upload.
    main_poke(32'h00e209, 8'h77);
    ext_poke (32'h015580, 8'h99);
    // $0155a0 is the last byte the restore wrote, so it is the one still in
    // the bridge's cached line: a line kept across accesses would hand
    // extraction the pre-CPU byte here.
    ext_poke (32'h0155a0, 8'h6b);
    repeat (10) @(posedge clk);

    osd_status <= 1'b1;
    fork
        begin
            repeat (200000) @(posedge clk);
            $display("FAIL: no upload request after OSD open");
            errors++;
        end
        begin
            @(posedge hs_upload_req);
        end
    join_any
    disable fork;
    osd_status <= 1'b0;

    // Read the saved dump back the way HPS does.
    ioctl_index  <= 8'd4;
    ioctl_upload <= 1'b1;
    @(posedge clk);
    for (int i = 0; i < DUMP_LEN; i++) begin
        ioctl_addr <= i;
        repeat (3) @(posedge clk);
        upload_got[i] = hs_data_to_hps;
    end
    ioctl_upload <= 1'b0;

    expect_byte("saved $00e209", upload_got[1], 8'h77);
    expect_byte("saved $015580", upload_got[3 + 14], 8'h99);
    expect_byte("saved $0155a0", upload_got[3 + 46], 8'h6b);
    for (int i = 0; i < DUMP_LEN; i++) begin
        if (i != 1 && i != (3 + 14) && i != (3 + 46))
            expect_byte($sformatf("saved byte %0d", i), upload_got[i], dump[i]);
    end

    if (errors == 0) $display("PASS tb_ssv_hiscore");
    else             $display("FAIL tb_ssv_hiscore (%0d errors)", errors);
    $finish;
end

endmodule
