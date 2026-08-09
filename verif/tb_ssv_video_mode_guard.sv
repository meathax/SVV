`timescale 1ns/1ps

module tb_ssv_video_mode_guard;

logic clk = 1'b0;
always #5 clk = ~clk;

logic rst = 1'b1;
logic native_ce = 1'b0;
logic native_hsync = 1'b1;
logic native_vblank = 1'b0;
logic sd_request = 1'b0;
logic crt_request = 1'b0;
logic [4:0] crt_hsize_request = 5'd0;
logic [5:0] crt_hpos_request = 6'd0;
logic [5:0] crt_vshift_request = 6'd0;
logic [1:0] rotation_request = 2'd0;
logic [1:0] aspect_request = 2'd0;
logic [1:0] scale_request = 2'd0;

logic sd_on;
logic crt_on;
logic [4:0] crt_hsize_idx;
logic [5:0] crt_hpos;
logic [5:0] crt_vshift;
logic [1:0] rotation;
logic [1:0] aspect;
logic [1:0] scale_select;

ssv_video_mode_guard dut (.*);

task automatic pixel_tick;
	native_ce = 1'b1;
	@(posedge clk);
	#1 native_ce = 1'b0;
	@(posedge clk);
	#1;
endtask

task automatic line_start;
	native_hsync = 1'b0;
	pixel_tick();
	native_hsync = 1'b1;
	pixel_tick();
endtask

task automatic check_ok(input logic condition, input string message);
	if (!condition)
		$fatal(1, "FAIL tb_ssv_video_mode_guard: %s", message);
endtask

initial begin
	repeat (2) @(posedge clk);
	#1 rst = 1'b0;

	sd_request = 1'b1;
	crt_request = 1'b1;
	crt_hsize_request = 5'd19;
	crt_hpos_request = 6'h2a;
	crt_vshift_request = 6'h35;
	rotation_request = 2'd2;
	aspect_request = 2'd3;
	scale_request = 2'd2;

	// Active-video changes must not touch any structural output.
	line_start();
	check_ok({sd_on, crt_on, crt_hsize_idx, crt_hpos, crt_vshift,
	        rotation, aspect, scale_select} == '0,
	       "mode changed during active video");

	// Commit atomically at the first native line reference in VBlank.
	native_vblank = 1'b1;
	line_start();
	check_ok(sd_on && crt_on, "buffered video paths did not enable in VBlank");
	check_ok(crt_hsize_idx == 5'd19 && crt_hpos == 6'h2a &&
	       crt_vshift == 6'h35, "CRT controls were not committed atomically");
	check_ok(rotation == 2'd2 && aspect == 2'd3 && scale_select == 2'd2,
	       "rotation/aspect/scale were not committed atomically");

	// Only one commit is permitted per frame, even if Main updates status while
	// VBlank is still active.
	sd_request = 1'b0;
	crt_request = 1'b0;
	rotation_request = 2'd1;
	aspect_request = 2'd1;
	scale_request = 2'd1;
	line_start();
	check_ok(sd_on && crt_on && rotation == 2'd2,
	       "mode changed twice in one VBlank");

	// Re-arm in active video, then take the new request next frame.
	native_vblank = 1'b0;
	pixel_tick();
	check_ok(sd_on && crt_on, "mode changed on VBlank exit");
	native_vblank = 1'b1;
	line_start();
	check_ok(!sd_on && !crt_on && rotation == 2'd1 &&
	       aspect == 2'd1 && scale_select == 2'd1,
	       "next-frame mode request was not committed");

	// The fourth OSD Scale value must survive the same frame-safe commit path.
	scale_request = 2'd3;
	native_vblank = 1'b0;
	pixel_tick();
	native_vblank = 1'b1;
	line_start();
	check_ok(scale_select == 2'd3,
	       "HV-integer mode request was not committed");

	// Reset always returns to a monitor-safe native path immediately.
	rst = 1'b1;
	@(posedge clk);
	#1;
	check_ok(!sd_on && !crt_on && rotation == 2'd0 && scale_select == 2'd0,
	       "reset did not select safe native video path");

	$display("PASS tb_ssv_video_mode_guard frame-safe mode commits");
	$finish;
end

endmodule
