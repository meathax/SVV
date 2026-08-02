// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1ns/1ps

module tb_ssv_nvram_bridge;
    localparam int SDR_AW = 26;
    localparam logic [SDR_AW:0] BASE = 27'h0460000;

    logic clk = 1'b0;
    logic rst = 1'b1;
    always #5 clk = ~clk;

    logic [1:0] nvram_size_mode;
    logic cfg_commit;
    logic init_busy;
    logic init_done;
    logic modified;
    logic dirty;
    logic ioctl_download;
    logic ioctl_upload;
    logic ioctl_wr;
    logic ioctl_rd;
    logic [15:0] ioctl_index;
    logic [26:0] ioctl_addr;
    logic [7:0] ioctl_dout;
    logic [7:0] ioctl_din;
    logic ioctl_wait;
    logic ioctl_upload_req;
    logic sdr_ready;
    logic sdr_wr_req;
    logic [SDR_AW:1] sdr_wr_addr;
    logic [15:0] sdr_wr_din;
    logic [1:0] sdr_wr_be;
    logic sdr_wr_ack;
    logic sdr_rd_req;
    logic [SDR_AW:1] sdr_rd_addr;
    logic [15:0] sdr_rd_dout;
    logic sdr_rd_ack;

    ssv_nvram_bridge #(
        .SDR_AW(SDR_AW),
        .NVRAM_BASE(BASE)
    ) dut (.*);

    task automatic tick;
        @(posedge clk);
        #1;
    endtask

    task automatic check(input logic condition, input string message);
        if (!condition)
            $fatal(1, "NVRAM bridge: %s", message);
    endtask

    task automatic finish_write;
        ioctl_wr = 1'b0;
        sdr_wr_ack = 1'b1;
        tick();
        sdr_wr_ack = 1'b0;
        check(!sdr_wr_req, "write request did not retire on ack");
        check(!ioctl_wait, "write ack did not release ioctl_wait");
    endtask

    task automatic download_byte_check(
        input logic [26:0] byte_addr,
        input logic [7:0] data,
        input logic [SDR_AW:1] expected_word,
        input logic [1:0] expected_be
    );
        ioctl_download = 1'b1;
        ioctl_wr = 1'b1;
        ioctl_addr = byte_addr;
        ioctl_dout = data;
        #1;
        check(!ioctl_wait, "ready write was stalled before acceptance");
        tick();
        check(sdr_wr_req, "valid download did not issue a write");
        check(ioctl_wait, "pending write did not backpressure hps_io");
        check(sdr_wr_addr == expected_word, "download word address mismatch");
        check(sdr_wr_din == {data, data}, "download data was not lane duplicated");
        check(sdr_wr_be == expected_be, "download byte enable mismatch");
        finish_write();
        ioctl_download = 1'b0;
    endtask

    task automatic cold_init_check(
        input logic [1:0] mode,
        input integer expected_words
    );
        integer word_index;
        nvram_size_mode = mode;
        ioctl_index = 16'd1;
        ioctl_addr = 27'd0;
        ioctl_download = 1'b1;
        ioctl_wr = 1'b1;
        tick();
        check(init_busy && !init_done,
              "descriptor byte zero did not arm cold init");
        check(!sdr_wr_req, "cold init wrote before descriptor commit");
        ioctl_download = 1'b0;
        ioctl_wr = 1'b0;
        cfg_commit = 1'b1;
        tick();
        cfg_commit = 1'b0;

        if (expected_words == 0) begin
            check(!init_busy && init_done,
                  "disabled/invalid descriptor did not bypass cold init");
            check(!sdr_wr_req, "disabled/invalid cold init touched SDRAM");
        end
        else begin
            check(init_busy && !init_done,
                  "enabled descriptor did not start cold init");
            for (word_index = 0; word_index < expected_words;
                 word_index = word_index + 1) begin
                while (!sdr_wr_req)
                    tick();
                check(sdr_wr_addr == BASE[SDR_AW:1] + word_index,
                      "cold-zero address/count mismatch");
                check(sdr_wr_din == 16'h0000 && sdr_wr_be == 2'b11,
                      "cold-zero write was not a full zero word");
                sdr_wr_ack = 1'b1;
                tick();
                sdr_wr_ack = 1'b0;
                if (word_index != expected_words - 1)
                    check(init_busy && !init_done,
                          "cold init completed before exact descriptor size");
            end
            check(!init_busy && init_done,
                  "cold init did not complete on exact final word");
            check(!sdr_wr_req, "cold init request survived final ack");
        end
        ioctl_index = 16'd8;
    endtask

    initial begin
        nvram_size_mode = 2'd0;
        cfg_commit = 1'b0;
        modified = 1'b0;
        ioctl_download = 1'b0;
        ioctl_upload = 1'b0;
        ioctl_wr = 1'b0;
        ioctl_rd = 1'b0;
        ioctl_index = 16'd8;
        ioctl_addr = 27'd0;
        ioctl_dout = 8'h00;
        sdr_ready = 1'b1;
        sdr_wr_ack = 1'b0;
        sdr_rd_dout = 16'h0000;
        sdr_rd_ack = 1'b0;

        repeat (3) tick();
        rst = 1'b0;
        tick();

        // Disabled and invalid descriptor modes are completely isolated.
        modified = 1'b1;
        ioctl_download = 1'b1;
        ioctl_upload = 1'b1;
        ioctl_wr = 1'b1;
        tick();
        modified = 1'b0;
        check(!dirty && !ioctl_upload_req, "disabled mode became dirty");
        check(!sdr_wr_req && !sdr_rd_req && !ioctl_wait,
              "disabled mode touched or stalled SDRAM");
        check(ioctl_din == 8'h00, "disabled upload returned nonzero data");

        nvram_size_mode = 2'd3;
        tick();
        check(!dirty && !ioctl_upload_req, "invalid mode became dirty");
        check(!sdr_wr_req && !sdr_rd_req && !ioctl_wait,
              "invalid mode touched or stalled SDRAM");
        ioctl_download = 1'b0;
        ioctl_upload = 1'b0;
        ioctl_wr = 1'b0;

        // Each descriptor gets exactly one MAME DEFAULT_ALL_0 fill. Disabled
        // and reserved modes complete without any SDRAM access.
        cold_init_check(2'd0, 0);
        cold_init_check(2'd3, 0);
        cold_init_check(2'd1, 1024);

        // 2 KiB download boundaries and byte lanes.
        download_byte_check(27'd0,    8'h12, BASE[SDR_AW:1],               2'b01);
        download_byte_check(27'd1,    8'h34, BASE[SDR_AW:1],               2'b10);
        download_byte_check(27'd2047, 8'h56, BASE[SDR_AW:1] + 26'd1023,    2'b10);

        ioctl_download = 1'b1;
        ioctl_wr = 1'b1;
        ioctl_addr = 27'd2048;
        tick();
        check(!sdr_wr_req && !ioctl_wait, "2 KiB range accepted byte 2048");
        ioctl_index = 16'd7;
        ioctl_addr = 27'd0;
        tick();
        check(!sdr_wr_req && !ioctl_wait, "non-index-8 download was accepted");
        ioctl_index = 16'd8;
        ioctl_download = 1'b0;
        ioctl_wr = 1'b0;

        // 64 KiB has an exact, non-wrapping final address.
        cold_init_check(2'd2, 32768);
        download_byte_check(27'd65535, 8'h78,
                            BASE[SDR_AW:1] + 26'd32767, 2'b10);
        ioctl_download = 1'b1;
        ioctl_wr = 1'b1;
        ioctl_addr = 27'd65536;
        tick();
        check(!sdr_wr_req && !ioctl_wait, "64 KiB range accepted byte 65536");
        ioctl_download = 1'b0;
        ioctl_wr = 1'b0;

        // A not-ready controller stalls a valid byte without issuing it.
        nvram_size_mode = 2'd1;
        sdr_ready = 1'b0;
        ioctl_download = 1'b1;
        ioctl_wr = 1'b1;
        ioctl_addr = 27'd2;
        #1;
        check(ioctl_wait, "not-ready write did not stall");
        tick();
        check(!sdr_wr_req, "not-ready write touched SDRAM");
        ioctl_download = 1'b0;
        ioctl_wr = 1'b0;

        // Upload reads one 16-bit word, returns the selected byte, and stalls
        // immediately when hps_io advances to the next exact byte address.
        ioctl_upload = 1'b1;
        ioctl_addr = 27'd0;
        #1;
        check(ioctl_wait, "not-ready upload did not stall");
        tick();
        check(!sdr_rd_req, "not-ready upload touched SDRAM");
        sdr_ready = 1'b1;
        tick();
        check(sdr_rd_req, "valid upload did not issue a read");
        check(sdr_rd_addr == BASE[SDR_AW:1], "upload word address mismatch");
        check(ioctl_wait, "outstanding upload read did not stall");

        sdr_rd_dout = 16'hC3A5;
        sdr_rd_ack = 1'b1;
        tick();
        sdr_rd_ack = 1'b0;
        check(!sdr_rd_req && !ioctl_wait, "upload ack did not release wait");
        check(ioctl_din == 8'hA5, "even upload selected wrong byte lane");

        ioctl_addr = 27'd1;
        ioctl_rd = 1'b1;
        #1;
        check(ioctl_wait && ioctl_din == 8'h00,
              "new upload address reused stale byte data");
        tick();
        ioctl_rd = 1'b0;
        check(sdr_rd_req, "next upload byte did not issue a read");
        check(sdr_rd_addr == BASE[SDR_AW:1],
              "odd upload changed the containing word address");
        sdr_rd_dout = 16'hC3A5;
        sdr_rd_ack = 1'b1;
        tick();
        sdr_rd_ack = 1'b0;
        check(!ioctl_wait && ioctl_din == 8'hC3,
              "odd upload selected wrong byte lane");

        // Ending this exploratory upload leaves the lifecycle clean.
        ioctl_upload = 1'b0;
        tick();
        check(!dirty, "clean exploratory upload dirtied NVRAM");

        ioctl_upload = 1'b1;
        ioctl_addr = 27'd2047;
        tick();
        check(sdr_rd_req, "last 2 KiB byte did not issue a read");
        check(sdr_rd_addr == BASE[SDR_AW:1] + 26'd1023,
              "last 2 KiB upload word address mismatch");
        sdr_rd_dout = 16'h5A11;
        sdr_rd_ack = 1'b1;
        tick();
        sdr_rd_ack = 1'b0;
        check(!ioctl_wait && ioctl_din == 8'h5A,
              "last 2 KiB upload selected wrong lane");
        ioctl_addr = 27'd2048;
        ioctl_rd = 1'b1;
        #1;
        check(!ioctl_wait && ioctl_din == 8'h00,
              "out-of-range upload stalled or leaked data");
        tick();
        ioctl_rd = 1'b0;
        check(!sdr_rd_req, "out-of-range upload touched SDRAM");
        ioctl_upload = 1'b0;
        tick();

        // CPU modification raises one request edge and remains dirty until a
        // clean upload ends.
        modified = 1'b1;
        tick();
        modified = 1'b0;
        check(dirty && !ioctl_upload_req,
              "modification did not set dirty before request generation");
        tick();
        check(ioctl_upload_req, "dirty NVRAM did not request index-8 upload");

        ioctl_upload = 1'b1;
        ioctl_addr = 27'd0;
        tick();
        check(dirty && !ioctl_upload_req,
              "upload start cleared dirty early or left request high");
        sdr_rd_dout = 16'h2211;
        sdr_rd_ack = 1'b1;
        tick();
        sdr_rd_ack = 1'b0;
        ioctl_upload = 1'b0;
        tick();
        check(!dirty && !ioctl_upload_req,
              "clean upload completion did not clear dirty/request");

        // A modification during upload must survive and generate a fresh
        // rising request only after that upload has ended.
        modified = 1'b1;
        tick();
        modified = 1'b0;
        tick();
        check(ioctl_upload_req, "second modification did not request upload");
        ioctl_upload = 1'b1;
        ioctl_addr = 27'd0;
        tick();
        check(!ioctl_upload_req, "second upload did not lower request");
        sdr_rd_dout = 16'h4433;
        sdr_rd_ack = 1'b1;
        tick();
        sdr_rd_ack = 1'b0;
        modified = 1'b1;
        tick();
        modified = 1'b0;
        ioctl_upload = 1'b0;
        tick();
        check(dirty && !ioctl_upload_req,
              "in-flight modification was lost or requested too early");
        tick();
        check(ioctl_upload_req,
              "in-flight modification did not create a fresh request edge");

        // A genuinely accepted host restore at byte zero establishes a clean
        // persisted baseline.  A blocked restore must not clear it.
        sdr_ready = 1'b0;
        ioctl_download = 1'b1;
        ioctl_wr = 1'b1;
        ioctl_addr = 27'd0;
        tick();
        check(dirty && ioctl_upload_req,
              "blocked host restore cleared dirty/request");
        sdr_ready = 1'b1;
        tick();
        check(sdr_wr_req, "ready host restore did not issue byte-zero write");
        check(!dirty && !ioctl_upload_req,
              "accepted host restore did not clear dirty/request");
        finish_write();
        ioctl_download = 1'b0;

        $display("SSV NVRAM BRIDGE PASS");
        $finish;
    end
endmodule
