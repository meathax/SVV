`timescale 1ns/1ps

module tb_ssv_audio_cdc;
    logic src_clk = 1'b0;
    logic dst_clk = 1'b0;
    always #5 src_clk = ~src_clk;
    always #7 dst_clk = ~dst_clk;

    logic src_rst = 1'b1;
    logic dst_rst = 1'b1;
    logic src_valid = 1'b0;
    logic signed [15:0] src_l = '0;
    logic signed [15:0] src_r = '0;
    logic src_ready;
    logic signed [15:0] dst_l;
    logic signed [15:0] dst_r;
    logic dst_valid;

    localparam int FIRST_COUNT = 32;
    localparam int SECOND_COUNT = 16;
    localparam int TOTAL_COUNT = FIRST_COUNT + SECOND_COUNT;
    logic signed [15:0] expected_l [0:TOTAL_COUNT-1];
    logic signed [15:0] expected_r [0:TOTAL_COUNT-1];
    int received = 0;

    function automatic logic signed [15:0] pattern_l(input int n);
        case (n % 8)
            0: pattern_l = 16'hAAAA;
            1: pattern_l = 16'h5555;
            2: pattern_l = 16'h8001;
            3: pattern_l = 16'h7FFE;
            4: pattern_l = 16'h0100;
            5: pattern_l = 16'h00FF;
            6: pattern_l = 16'hF00F;
            default: pattern_l = 16'h0FF0;
        endcase
    endfunction

    function automatic logic signed [15:0] pattern_r(input int n);
        case (n % 8)
            0: pattern_r = 16'h3333;
            1: pattern_r = 16'hCCCC;
            2: pattern_r = 16'h8000;
            3: pattern_r = 16'h7FFF;
            4: pattern_r = 16'h00F0;
            5: pattern_r = 16'h0F00;
            6: pattern_r = 16'hF0F0;
            default: pattern_r = 16'h0F0F;
        endcase
    endfunction

    ssv_audio_cdc dut (
        .src_clk(src_clk), .src_rst(src_rst),
        .src_valid(src_valid), .src_l(src_l), .src_r(src_r),
        .src_ready(src_ready),
        .dst_clk(dst_clk), .dst_rst(dst_rst),
        .dst_l(dst_l), .dst_r(dst_r), .dst_valid(dst_valid)
    );

    always @(negedge dst_clk) begin
        if (dst_valid) begin
            if (received >= TOTAL_COUNT)
                $fatal(1, "ssv_audio_cdc: unexpected extra destination sample");
            if (dst_l !== expected_l[received] || dst_r !== expected_r[received])
                $fatal(1, "ssv_audio_cdc: torn stereo sample at %0d: got %h/%h expected %h/%h",
                       received, dst_l, dst_r, expected_l[received], expected_r[received]);
            received = received + 1;
        end
    end

    task automatic send_sample(input int sequence_index);
        begin
            @(negedge src_clk);
            if (!src_ready)
                $fatal(1, "ssv_audio_cdc: source was not ready at the 16-clock tick cadence");
            src_l = expected_l[sequence_index];
            src_r = expected_r[sequence_index];
            src_valid = 1'b1;
            @(negedge src_clk);
            src_valid = 1'b0;
            // The voice engine's shortest documented output period is
            // 16 clk_sys ticks; do not hide a handshake overrun by waiting
            // for ready here.
            repeat (15) @(negedge src_clk);
        end
    endtask

    initial begin
        for (int i = 0; i < TOTAL_COUNT; i++) begin
            expected_l[i] = pattern_l(i);
            expected_r[i] = pattern_r(i + 3);
        end

        repeat (4) @(negedge src_clk);
        src_rst = 1'b0;
        dst_rst = 1'b0;
        repeat (4) @(negedge src_clk);

        for (int i = 0; i < FIRST_COUNT; i++)
            send_sample(i);
        while (received != FIRST_COUNT)
            @(negedge dst_clk);

        // A second reset must discard no in-flight sample and must restart the
        // toggle protocol at a known phase.
        src_rst = 1'b1;
        dst_rst = 1'b1;
        repeat (4) @(negedge src_clk);
        src_rst = 1'b0;
        dst_rst = 1'b0;
        repeat (4) @(negedge src_clk);

        for (int i = FIRST_COUNT; i < TOTAL_COUNT; i++)
            send_sample(i);
        while (received != TOTAL_COUNT)
            @(negedge dst_clk);

        $display("PASS tb_ssv_audio_cdc: %0d coherent stereo samples", received);
        $finish;
    end
endmodule
