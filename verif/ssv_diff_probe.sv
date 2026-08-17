`timescale 1ns/1ps

// Canonical, simulation-only SSV observation sink.  All inputs are explicit
// ports from ssv_core: this module must never reach the Quartus source closure
// and intentionally contains no hierarchical DUT references.
module ssv_diff_probe (
    input logic clk,
    input logic rst,
    input logic run_done,
    input logic checkpoint_prepare,
    input logic checkpoint_restore,
    input logic [31:0] pc,
    input logic [31:0] reset_epoch,
    input logic [31:0] frame,
    input logic [31:0] post_epoch_frame,
    input logic [8:0] scanline,
    input logic [8:0] hpos,
    input logic retire,
    input logic [31:0] retire_pc,
    input logic [7:0] retire_opcode,
    input logic [31:0] retire_psw,
    input logic [1023:0] retire_gprs,
    input logic mainbus_complete,
    input logic mainbus_write,
    input logic [23:0] mainbus_addr,
    input logic [15:0] mainbus_data,
    input logic [1:0] mainbus_be,
    input logic [7:0] mainbus_device,
    input logic ifetch_complete,
    input logic [23:0] ifetch_addr,
    input logic [63:0] ifetch_data,
    input logic irq_ack,
    input logic [7:0] irq_vector,
    input logic [7:0] irq_requested,
    input logic [7:0] irq_enabled,
    input logic watchdog_kick,
    input logic watchdog_reset,
    input logic st010_retire,
    input logic [13:0] st010_pc,
    input logic st010_host_access,
    input logic st010_fetch_req,
    input logic st010_fetch_done,
    input logic sound_commit,
    input logic [6:0] sound_page,
    input logic [3:0] sound_reg,
    input logic [31:0] sound_data,
    input logic sound_irq_promote,
    input logic sound_voice_writeback,
    input logic [4:0] sound_voice,
    input logic sample_req,
    input logic sample_done,
    input logic sample_tick,
    input logic sample_underrun,
    input logic video_enable,
    input logic line_boundary,
    input logic frame_boundary,
    input logic renderer_overrun
);

integer trace_fd;
string trace_path;
integer reg_trace_fd;
string reg_trace_path;
longint unsigned cycle;
longint unsigned mainbus_seq, cpu_data_seq, retire_seq, ifetch_seq, irq_seq;
longint unsigned watchdog_seq, st010_seq, sound_seq, video_seq;
integer expected_watchdog_resets, expected_watchdog_min_frame, expected_watchdog_max_frame;
longint unsigned start_cycle, stop_cycle, max_events, total_events;
bit strict_only;
integer gpr_i;
logic rst_d, video_enable_d;
logic [7:0] irq_requested_d, irq_enabled_d;
integer gameplay_entry_frame;
logic gameplay_entry_seen;
longint unsigned reg_change_seq;
logic reg_state_seen;
logic [31:0] prev_r2, prev_r23, prev_retire_pc;
logic [7:0] prev_retire_opcode;

function automatic logic enabled_now();
    enabled_now = (cycle >= start_cycle) &&
                  ((stop_cycle == 0) || (cycle <= stop_cycle));
endfunction

task automatic reserve_event();
    if (max_events != 0 && total_events >= max_events)
        $fatal(1, "SSV_TRACE_CAPACITY_EXCEEDED cycle=%0d max_events=%0d",
               cycle, max_events);
    total_events = total_events + 1;
endtask

initial begin
    trace_fd = 0;
    reg_trace_fd = 0;
    cycle = 0;
    mainbus_seq = 0;
    cpu_data_seq = 0;
    retire_seq = 0;
    ifetch_seq = 0;
    irq_seq = 0;
    watchdog_seq = 0;
    expected_watchdog_resets = 0;
    expected_watchdog_min_frame = 0;
    expected_watchdog_max_frame = 0;
    st010_seq = 0;
    sound_seq = 0;
    video_seq = 0;
    total_events = 0;
    rst_d = 1'b1;
    video_enable_d = 1'b0;
    irq_requested_d = 8'd0;
    irq_enabled_d = 8'd0;
    gameplay_entry_frame = -1;
    gameplay_entry_seen = 1'b0;
    reg_change_seq = 0;
    reg_state_seen = 1'b0;
    prev_r2 = 32'd0;
    prev_r23 = 32'd0;
    prev_retire_pc = 32'd0;
    prev_retire_opcode = 8'd0;
    start_cycle = 0;
    stop_cycle = 0;
    max_events = 0;
    strict_only = 1'b0;
    void'($value$plusargs("TRACE_START_CYCLE=%d", start_cycle));
    void'($value$plusargs("TRACE_STOP_CYCLE=%d", stop_cycle));
    void'($value$plusargs("TRACE_MAX_EVENTS=%d", max_events));
    strict_only = $test$plusargs("TRACE_STRICT_ONLY");
    void'($value$plusargs("GAMEPLAY_ENTRY_FRAME=%d", gameplay_entry_frame));
    void'($value$plusargs("EXPECTED_WATCHDOG_RESETS=%d", expected_watchdog_resets));
    void'($value$plusargs("EXPECTED_WATCHDOG_MIN_FRAME=%d", expected_watchdog_min_frame));
    void'($value$plusargs("EXPECTED_WATCHDOG_MAX_FRAME=%d", expected_watchdog_max_frame));
    if ($value$plusargs("MISTER_TRACE_OUT=%s", trace_path)) begin
        trace_fd = $fopen(trace_path, "w");
        if (!trace_fd) $fatal(1, "cannot open MISTER_TRACE_OUT=%s", trace_path);
        $fwrite(trace_fd,
            "{\"record\":\"contract\",\"schema\":\"mister-raw-trace-v4\",\"producer\":\"ssv-headless-rtl\",\"headless\":true,\"display_backend\":\"none\",\"strict_candidate\":\"cpu_data\",\"diagnostic_domain\":\"mainbus\",\"program_rom_device_excluded\":1,\"strict_only\":%s}\n",
            strict_only ? "true" : "false");
    end
    if ($value$plusargs("MISTER_REG_TRACE_OUT=%s", reg_trace_path)) begin
        reg_trace_fd = $fopen(reg_trace_path, "w");
        if (!reg_trace_fd)
            $fatal(1, "cannot open MISTER_REG_TRACE_OUT=%s", reg_trace_path);
        $fwrite(reg_trace_fd,
            "{\"record\":\"contract\",\"schema\":\"ssv-v60-register-change-v1\",\"producer\":\"ssv-headless-rtl\",\"headless\":true,\"display_backend\":\"none\",\"sampling\":\"before_execute\",\"registers\":[\"R2\",\"R23\"]}\n");
    end
end

always @(posedge checkpoint_prepare) begin
    if (trace_fd) begin
        $fwrite(trace_fd,
            "{\"record\":\"barrier\",\"name\":\"checkpoint_prepare\",\"phase\":\"completed\",\"cycle\":%0d,\"frame\":%0d}\n",
            cycle, frame);
        $fclose(trace_fd);
        trace_fd = 0;
    end
    if (reg_trace_fd) begin
        $fwrite(reg_trace_fd,
            "{\"record\":\"barrier\",\"name\":\"checkpoint_prepare\",\"phase\":\"completed\",\"cycle\":%0d,\"frame\":%0d}\n",
            cycle, frame);
        $fclose(reg_trace_fd);
        reg_trace_fd = 0;
    end
end

always @(posedge checkpoint_restore) begin
    // File descriptors are process-local and are never trusted from a saved
    // Verilated model. Re-read the output path and append in this process.
    void'($value$plusargs("MISTER_TRACE_OUT=%s", trace_path));
    trace_fd = $fopen(trace_path, "a");
    if (!trace_fd) $fatal(1, "cannot reopen MISTER_TRACE_OUT=%s", trace_path);
    $fwrite(trace_fd,
        "{\"record\":\"barrier\",\"name\":\"checkpoint_restore\",\"phase\":\"completed\",\"cycle\":%0d,\"frame\":%0d}\n",
        cycle, frame);
    if ($value$plusargs("MISTER_REG_TRACE_OUT=%s", reg_trace_path)) begin
        reg_trace_fd = $fopen(reg_trace_path, "a");
        if (!reg_trace_fd)
            $fatal(1, "cannot reopen MISTER_REG_TRACE_OUT=%s", reg_trace_path);
        $fwrite(reg_trace_fd,
            "{\"record\":\"barrier\",\"name\":\"checkpoint_restore\",\"phase\":\"completed\",\"cycle\":%0d,\"frame\":%0d}\n",
            cycle, frame);
    end
end

// Plain always is deliberate: counters receive their process-start values in
// the initial block and then have this single clocked writer. always_ff would
// reject that legal testbench initialization as a second procedural writer.
always @(posedge clk) begin
    cycle <= cycle + 1;
    rst_d <= rst;
    video_enable_d <= video_enable;
    irq_requested_d <= irq_requested;
    irq_enabled_d <= irq_enabled;

    if (reg_trace_fd && retire) begin
        if (!reg_state_seen ||
            retire_gprs[2 * 32 +: 32] != prev_r2 ||
            retire_gprs[23 * 32 +: 32] != prev_r23) begin
            $fwrite(reg_trace_fd,
                "{\"domain\":\"v60_reg_change\",\"seq\":%0d,\"event\":\"instruction_boundary\",\"phase\":\"before_execute\",\"first\":%0d,\"pc\":%0d,\"opcode\":%0d,\"psw\":%0d,\"producer_pc\":%0d,\"producer_opcode\":%0d,\"old_r2\":%0d,\"new_r2\":%0d,\"old_r23\":%0d,\"new_r23\":%0d,\"cycle\":%0d,\"frame\":%0d,\"post_epoch_frame\":%0d,\"scanline\":%0d}\n",
                reg_change_seq, !reg_state_seen, retire_pc, retire_opcode,
                retire_psw, prev_retire_pc, prev_retire_opcode,
                prev_r2, retire_gprs[2 * 32 +: 32], prev_r23,
                retire_gprs[23 * 32 +: 32], cycle, frame,
                post_epoch_frame, scanline);
            reg_change_seq <= reg_change_seq + 1;
        end
        reg_state_seen <= 1'b1;
        prev_r2 <= retire_gprs[2 * 32 +: 32];
        prev_r23 <= retire_gprs[23 * 32 +: 32];
        prev_retire_pc <= retire_pc;
        prev_retire_opcode <= retire_opcode;
    end

    if (trace_fd && rst_d && !rst) begin
        $fwrite(trace_fd,
            "{\"record\":\"barrier\",\"name\":\"reset_release\",\"phase\":\"completed\",\"cycle\":%0d,\"reset_epoch\":%0d}\n",
            cycle, reset_epoch);
    end

    if (trace_fd && enabled_now()) begin
        if (gameplay_entry_frame >= 0 && !gameplay_entry_seen &&
            frame >= gameplay_entry_frame) begin
            $fwrite(trace_fd,
                "{\"record\":\"barrier\",\"name\":\"gameplay_entry\",\"phase\":\"completed\",\"cycle\":%0d,\"frame\":%0d}\n",
                cycle, frame);
            gameplay_entry_seen <= 1'b1;
        end
        if (mainbus_complete) begin
            reserve_event();
            if (strict_only)
                $fwrite(trace_fd,
                    "{\"domain\":\"mainbus\",\"seq\":%0d,\"event\":\"bus\",\"phase\":\"completed\",\"rw\":\"%s\",\"address\":%0d,\"data\":%0d,\"byte_enable\":%0d,\"device\":%0d}\n",
                    mainbus_seq, mainbus_write ? "W" : "R", mainbus_addr,
                    mainbus_data, mainbus_be, mainbus_device);
            else
                $fwrite(trace_fd,
                    "{\"domain\":\"mainbus\",\"seq\":%0d,\"event\":\"bus\",\"phase\":\"completed\",\"rw\":\"%s\",\"address\":%0d,\"data\":%0d,\"byte_enable\":%0d,\"device\":%0d,\"pc\":%0d,\"cycle\":%0d,\"reset_epoch\":%0d,\"frame\":%0d,\"post_epoch_frame\":%0d,\"scanline\":%0d}\n",
                    mainbus_seq, mainbus_write ? "W" : "R", mainbus_addr,
                    mainbus_data, mainbus_be, mainbus_device, pc, cycle,
                    reset_epoch, frame, post_epoch_frame, scanline);
            mainbus_seq <= mainbus_seq + 1;
            if (mainbus_device != 8'd1)
                cpu_data_seq <= cpu_data_seq + 1;
        end
        if (!strict_only && ifetch_complete) begin
            reserve_event();
            $fwrite(trace_fd,
                "{\"domain\":\"v60_ifetch\",\"seq\":%0d,\"event\":\"fetch64\",\"phase\":\"completed\",\"address\":%0d,\"data\":%0d,\"pc\":%0d,\"cycle\":%0d,\"frame\":%0d,\"scanline\":%0d}\n",
                ifetch_seq, ifetch_addr, ifetch_data, pc, cycle, frame, scanline);
            if (ifetch_seq == 0)
                $fwrite(trace_fd, "{\"record\":\"barrier\",\"name\":\"first_fetch\",\"phase\":\"completed\",\"cycle\":%0d}\n", cycle);
            ifetch_seq <= ifetch_seq + 1;
        end
        if (!strict_only && retire) begin
            reserve_event();
            $fwrite(trace_fd,
                "{\"domain\":\"v60_retire\",\"seq\":%0d,\"event\":\"instruction_boundary\",\"phase\":\"completed\",\"pc\":%0d,\"opcode\":%0d,\"psw\":%0d,\"cycle\":%0d,\"frame\":%0d,\"post_epoch_frame\":%0d,\"scanline\":%0d",
                retire_seq, retire_pc, retire_opcode, retire_psw, cycle,
                frame, post_epoch_frame, scanline);
            for (gpr_i = 0; gpr_i < 32; gpr_i = gpr_i + 1)
                $fwrite(trace_fd, ",\"r%0d\":%0d", gpr_i,
                        retire_gprs[gpr_i * 32 +: 32]);
            $fwrite(trace_fd, "}\n");
            if (retire_seq == 0)
                $fwrite(trace_fd, "{\"record\":\"barrier\",\"name\":\"first_retirement\",\"phase\":\"completed\",\"cycle\":%0d}\n", cycle);
            retire_seq <= retire_seq + 1;
        end
        if (!strict_only && (irq_ack || irq_requested != irq_requested_d || irq_enabled != irq_enabled_d)) begin
            reserve_event();
            $fwrite(trace_fd,
                "{\"domain\":\"irq\",\"seq\":%0d,\"event\":\"%s\",\"phase\":\"completed\",\"requested\":%0d,\"enabled\":%0d,\"vector\":%0d,\"pc\":%0d,\"cycle\":%0d,\"frame\":%0d,\"scanline\":%0d}\n",
                irq_seq, irq_ack ? "ack" : "state", irq_requested,
                irq_enabled, irq_vector, pc, cycle, frame, scanline);
            irq_seq <= irq_seq + 1;
        end
        if (!strict_only && (watchdog_kick || watchdog_reset)) begin
            reserve_event();
            $fwrite(trace_fd, "{\"domain\":\"watchdog\",\"seq\":%0d,\"event\":\"%s\",\"phase\":\"completed\",\"pc\":%0d,\"cycle\":%0d,\"frame\":%0d}\n", watchdog_seq, watchdog_reset ? "reset" : "kick", pc, cycle, frame);
            watchdog_seq <= watchdog_seq + 1;
        end
        if (!strict_only && st010_retire) begin
            reserve_event();
            $fwrite(trace_fd, "{\"domain\":\"st010\",\"seq\":%0d,\"event\":\"retire\",\"phase\":\"completed\",\"pc\":%0d,\"cycle\":%0d,\"frame\":%0d,\"scanline\":%0d}\n", st010_seq, st010_pc, cycle, frame, scanline);
        end
        if (!strict_only && st010_host_access) begin
            reserve_event();
            $fwrite(trace_fd, "{\"domain\":\"st010\",\"seq\":%0d,\"event\":\"host_access\",\"phase\":\"completed\",\"pc\":%0d,\"cycle\":%0d,\"frame\":%0d,\"scanline\":%0d}\n", st010_seq + st010_retire, st010_pc, cycle, frame, scanline);
        end
        if (!strict_only && st010_fetch_req) begin
            reserve_event();
            $fwrite(trace_fd, "{\"domain\":\"st010\",\"seq\":%0d,\"event\":\"program_fetch_request\",\"phase\":\"accepted\",\"pc\":%0d,\"cycle\":%0d,\"frame\":%0d,\"scanline\":%0d}\n", st010_seq + st010_retire + st010_host_access, st010_pc, cycle, frame, scanline);
        end
        if (!strict_only && st010_fetch_done) begin
            reserve_event();
            $fwrite(trace_fd, "{\"domain\":\"st010\",\"seq\":%0d,\"event\":\"program_fetch_complete\",\"phase\":\"completed\",\"pc\":%0d,\"cycle\":%0d,\"frame\":%0d,\"scanline\":%0d}\n", st010_seq + st010_retire + st010_host_access + st010_fetch_req, st010_pc, cycle, frame, scanline);
        end
        if (!strict_only && (st010_retire || st010_host_access || st010_fetch_req || st010_fetch_done))
            st010_seq <= st010_seq + st010_retire + st010_host_access +
                         st010_fetch_req + st010_fetch_done;

        if (!strict_only && sound_commit) begin
            reserve_event();
            $fwrite(trace_fd, "{\"domain\":\"es5506\",\"seq\":%0d,\"event\":\"host_commit\",\"phase\":\"completed\",\"page\":%0d,\"register\":%0d,\"data\":%0d,\"cycle\":%0d,\"frame\":%0d,\"scanline\":%0d}\n", sound_seq, sound_page, sound_reg, sound_data, cycle, frame, scanline);
        end
        if (!strict_only && sound_voice_writeback) begin
            reserve_event();
            $fwrite(trace_fd, "{\"domain\":\"es5506\",\"seq\":%0d,\"event\":\"voice_writeback\",\"phase\":\"completed\",\"voice\":%0d,\"cycle\":%0d,\"frame\":%0d,\"scanline\":%0d}\n", sound_seq + sound_commit, sound_voice, cycle, frame, scanline);
        end
        if (!strict_only && sound_irq_promote) begin
            reserve_event();
            $fwrite(trace_fd, "{\"domain\":\"es5506\",\"seq\":%0d,\"event\":\"irq_promote\",\"phase\":\"completed\",\"voice\":%0d,\"cycle\":%0d,\"frame\":%0d,\"scanline\":%0d}\n", sound_seq + sound_commit + sound_voice_writeback, sound_voice, cycle, frame, scanline);
        end
        if (!strict_only && sample_req) begin
            reserve_event();
            $fwrite(trace_fd, "{\"domain\":\"es5506\",\"seq\":%0d,\"event\":\"sample_request\",\"phase\":\"accepted\",\"cycle\":%0d,\"frame\":%0d,\"scanline\":%0d}\n", sound_seq + sound_commit + sound_voice_writeback + sound_irq_promote, cycle, frame, scanline);
        end
        if (!strict_only && sample_done) begin
            reserve_event();
            $fwrite(trace_fd, "{\"domain\":\"es5506\",\"seq\":%0d,\"event\":\"sample_complete\",\"phase\":\"completed\",\"cycle\":%0d,\"frame\":%0d,\"scanline\":%0d}\n", sound_seq + sound_commit + sound_voice_writeback + sound_irq_promote + sample_req, cycle, frame, scanline);
        end
        if (!strict_only && sample_tick) begin
            reserve_event();
            $fwrite(trace_fd, "{\"domain\":\"es5506\",\"seq\":%0d,\"event\":\"sample_tick\",\"phase\":\"completed\",\"cycle\":%0d,\"frame\":%0d,\"scanline\":%0d}\n", sound_seq + sound_commit + sound_voice_writeback + sound_irq_promote + sample_req + sample_done, cycle, frame, scanline);
        end
        if (!strict_only && sample_underrun) begin
            reserve_event();
            $fwrite(trace_fd, "{\"domain\":\"es5506\",\"seq\":%0d,\"event\":\"underrun\",\"phase\":\"completed\",\"cycle\":%0d,\"frame\":%0d,\"scanline\":%0d}\n", sound_seq + sound_commit + sound_voice_writeback + sound_irq_promote + sample_req + sample_done + sample_tick, cycle, frame, scanline);
        end
        if (!strict_only && (sound_commit || sound_voice_writeback || sound_irq_promote ||
            sample_req || sample_done || sample_tick || sample_underrun)
        )
            sound_seq <= sound_seq + sound_commit + sound_voice_writeback +
                         sound_irq_promote + sample_req + sample_done +
                         sample_tick + sample_underrun;
        if (!strict_only && (video_enable != video_enable_d || line_boundary || frame_boundary || renderer_overrun)) begin
            reserve_event();
            $fwrite(trace_fd,
                "{\"domain\":\"video\",\"seq\":%0d,\"event\":\"%s\",\"phase\":\"completed\",\"video_enable\":%0d,\"cycle\":%0d,\"frame\":%0d,\"scanline\":%0d,\"hpos\":%0d}\n",
                video_seq, renderer_overrun ? "renderer_ownership_violation" :
                (frame_boundary ? "frame_boundary" :
                (line_boundary ? "scanline_boundary" : "video_enable")),
                video_enable, cycle, frame, scanline, hpos);
            if (frame_boundary)
                $fwrite(trace_fd, "{\"record\":\"barrier\",\"name\":\"frame_complete\",\"phase\":\"completed\",\"cycle\":%0d,\"frame\":%0d}\n", cycle, frame);
        end
        if (!strict_only && mainbus_complete && mainbus_write &&
            (mainbus_device == 3 || mainbus_device == 4 || mainbus_device == 6)) begin
            reserve_event();
            $fwrite(trace_fd,
                "{\"domain\":\"video\",\"seq\":%0d,\"event\":\"register_or_ram_write\",\"phase\":\"completed\",\"device\":%0d,\"address\":%0d,\"data\":%0d,\"byte_enable\":%0d,\"cycle\":%0d,\"frame\":%0d,\"scanline\":%0d}\n",
                video_seq + ((video_enable != video_enable_d || line_boundary ||
                              frame_boundary || renderer_overrun) ? 1 : 0),
                mainbus_device, mainbus_addr, mainbus_data,
                mainbus_be, cycle, frame, scanline);
        end
        if (!strict_only && ((video_enable != video_enable_d || line_boundary || frame_boundary ||
             renderer_overrun) ||
            (mainbus_complete && mainbus_write &&
             (mainbus_device == 3 || mainbus_device == 4 || mainbus_device == 6))))
            video_seq <= video_seq +
                (video_enable != video_enable_d || line_boundary ||
                 frame_boundary || renderer_overrun) +
                (mainbus_complete && mainbus_write &&
                 (mainbus_device == 3 || mainbus_device == 4 || mainbus_device == 6));
    end
end

final begin
    if (trace_fd) begin
        // Do not pass a ternary string expression to Verilator's `%s` writer:
        // the fixed-width temporary it creates pads the shorter branch (the
        // resulting `"   stop"` barrier is rejected by strict comparators).
        if (run_done) begin
            $fwrite(trace_fd,
                "{\"record\":\"barrier\",\"name\":\"stop\",\"phase\":\"completed\",\"cycle\":%0d,\"frame\":%0d}\n",
                cycle, frame);
            $fwrite(trace_fd,
                "{\"record\":\"receipt\",\"reason\":\"stop_barrier\",\"complete\":true,\"dropped\":0,\"expected_watchdog\":{\"resets\":%0d,\"min_post_video_frame\":%0d,\"max_post_video_frame\":%0d},\"counts\":{\"mainbus\":%0d,\"cpu_data\":%0d,\"v60_retire\":%0d,\"v60_ifetch\":%0d,\"irq\":%0d,\"watchdog\":%0d,\"st010\":%0d,\"es5506\":%0d,\"video\":%0d}}\n",
                expected_watchdog_resets, expected_watchdog_min_frame, expected_watchdog_max_frame,
                mainbus_seq, cpu_data_seq, retire_seq, ifetch_seq, irq_seq, watchdog_seq,
                st010_seq, sound_seq, video_seq);
        end
        else begin
            $fwrite(trace_fd,
                "{\"record\":\"barrier\",\"name\":\"aborted\",\"phase\":\"completed\",\"cycle\":%0d,\"frame\":%0d}\n",
                cycle, frame);
            $fwrite(trace_fd,
                "{\"record\":\"receipt\",\"reason\":\"aborted\",\"complete\":false,\"dropped\":0,\"counts\":{\"mainbus\":%0d,\"cpu_data\":%0d,\"v60_retire\":%0d,\"v60_ifetch\":%0d,\"irq\":%0d,\"watchdog\":%0d,\"st010\":%0d,\"es5506\":%0d,\"video\":%0d}}\n",
                mainbus_seq, cpu_data_seq, retire_seq, ifetch_seq, irq_seq, watchdog_seq,
                st010_seq, sound_seq, video_seq);
        end
        $fclose(trace_fd);
    end
    if (reg_trace_fd) begin
        if (run_done)
            $fwrite(reg_trace_fd,
                "{\"record\":\"receipt\",\"reason\":\"stop_barrier\",\"complete\":true,\"dropped\":0,\"count\":%0d}\n",
                reg_change_seq);
        else
            $fwrite(reg_trace_fd,
                "{\"record\":\"receipt\",\"reason\":\"aborted\",\"complete\":false,\"dropped\":0,\"count\":%0d}\n",
                reg_change_seq);
        $fclose(reg_trace_fd);
    end
end

endmodule
