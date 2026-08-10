`timescale 1ns/1ps

module tb_ssv_host_guard;

logic clk_sys = 1'b0;
logic clk_ram = 1'b0;
always #5 clk_sys = ~clk_sys;
always #3 clk_ram = ~clk_ram;

logic pll_locked_async = 1'b0;
logic reset_async = 1'b0;
logic reset_request = 1'b0;
logic sdram_ready_async = 1'b0;
logic ioctl_download = 1'b0;
logic ioctl_upload = 1'b0;
logic [15:0] ioctl_index = 16'd0;
logic rom_loaded = 1'b0;
logic nv_init_done = 1'b0;
logic nv_init_busy = 1'b0;
logic hs_pause = 1'b0;
logic wdog_rst = 1'b0;

logic pll_ready_sys;
logic pll_ready_ram;
logic sdram_ready_sys;
logic nvram_transfer;
logic game_pause;
logic loader_reset;
logic video_reset;
logic core_cold_reset;
logic core_reset;

ssv_host_guard #(.RESET_HOLD_CYCLES(4)) dut (.*);

task automatic tick_sys(input integer count);
	repeat (count) @(posedge clk_sys);
	#1;
endtask

task automatic check_ok(input logic condition, input string message);
	if (!condition)
		$fatal(1, "FAIL tb_ssv_host_guard: %s", message);
endtask

initial begin
	#2;
	check_ok(!pll_ready_sys && !pll_ready_ram, "PLL ready asserted while unlocked");
	check_ok(video_reset && core_reset, "reset not asserted while PLL unlocked");

	pll_locked_async = 1'b1;
	tick_sys(3);
	check_ok(pll_ready_sys, "clk_sys PLL release was not synchronized");
	repeat (3) @(posedge clk_ram);
	#1;
	check_ok(pll_ready_ram, "clk_ram PLL release was not synchronized");

	sdram_ready_async = 1'b1;
	rom_loaded = 1'b1;
	nv_init_done = 1'b1;
	tick_sys(7);
	check_ok(sdram_ready_sys, "SDRAM ready did not cross into clk_sys");
	check_ok(!video_reset && !core_reset, "qualified startup reset did not release");

	// A ready-level dip after initialization is not a valid machine reset.
	sdram_ready_async = 1'b0;
	tick_sys(4);
	check_ok(sdram_ready_sys && !core_reset, "SDRAM ready dip reset the machine");
	sdram_ready_async = 1'b1;

	// Hiscore config/data are persistence traffic, not replacement media.
	ioctl_download = 1'b1;
	ioctl_index = 16'd3;
	#1;
	check_ok(!core_reset && !game_pause, "hiscore config download reset/paused core");
	ioctl_index = 16'd4;
	#1;
	check_ok(!core_reset, "hiscore data download reset core");
	ioctl_download = 1'b0;

	// Battery NVRAM is serialized under a CPU pause, without resetting video or
	// machine state.
	ioctl_index = 16'd8;
	ioctl_download = 1'b1;
	#1;
	check_ok(nvram_transfer && game_pause, "NVRAM restore did not pause CPU");
	check_ok(!video_reset && !core_reset, "NVRAM restore reset core/video");
	ioctl_download = 1'b0;
	ioctl_upload = 1'b1;
	#1;
	check_ok(nvram_transfer && game_pause && !core_reset,
	       "NVRAM save was not a reset-free pause");
	ioctl_upload = 1'b0;

	hs_pause = 1'b1;
	#1;
	check_ok(game_pause && !core_reset, "hiscore pause reset core");
	hs_pause = 1'b0;
	nv_init_busy = 1'b1;
	#1;
	check_ok(game_pause && !core_reset, "NVRAM initialization pause reset core");
	nv_init_busy = 1'b0;

	// Descriptor/ROM replacement still performs a deliberate cold reset.
	ioctl_download = 1'b1;
	ioctl_index = 16'd0;
	#1;
	check_ok(core_cold_reset && core_reset, "ROM download did not cold-reset core");
	ioctl_index = 16'd1;
	#1;
	check_ok(core_cold_reset, "descriptor download did not cold-reset core");
	ioctl_download = 1'b0;

	wdog_rst = 1'b1;
	#1;
	check_ok(core_reset && !core_cold_reset && !video_reset,
	       "watchdog reset propagated into cold/video reset");
	wdog_rst = 1'b0;

	// A one-cycle host request is held long enough for every synchronous block.
	reset_request = 1'b1;
	tick_sys(1);
	reset_request = 1'b0;
	tick_sys(3);
	check_ok(video_reset && core_reset, "host reset hold released too early");
	tick_sys(2);
	check_ok(!video_reset && !core_reset, "host reset hold did not release");

	// The external shell pin may change next to a clk_sys edge. Assertion is
	// asynchronous; release is synchronized and then receives the same hold.
	#2 reset_async = 1'b1;
	#1;
	check_ok(video_reset && core_reset, "async shell reset did not assert");
	reset_async = 1'b0;
	tick_sys(5);
	check_ok(video_reset && core_reset, "async reset hold released too early");
	tick_sys(2);
	check_ok(!video_reset && !core_reset, "async reset did not release cleanly");

	// PLL loss asserts reset without waiting for a destination clock edge.
	#2 pll_locked_async = 1'b0;
	#1;
	check_ok(!pll_ready_sys && !pll_ready_ram, "PLL loss was not asynchronous");
	check_ok(video_reset && core_reset && !sdram_ready_sys,
	       "PLL loss did not reset all guarded readiness");

	$display("PASS tb_ssv_host_guard persistence/reset/CDC hardening");
	$finish;
end

endmodule
