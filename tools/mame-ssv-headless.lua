-- SPDX-License-Identifier: GPL-3.0-or-later
-- Cold, windowless SSV reference capture.  This adapter observes the complete
-- V60 program space from reset onward and never mutates emulated memory.

local root = assert(os.getenv("SSV_HEADLESS_DIR"), "SSV_HEADLESS_DIR is required")
local setname = assert(os.getenv("SSV_HEADLESS_SET"), "SSV_HEADLESS_SET is required")
local width = assert(tonumber(os.getenv("SSV_HEADLESS_WIDTH")), "SSV_HEADLESS_WIDTH is required")
local height = assert(tonumber(os.getenv("SSV_HEADLESS_HEIGHT")), "SSV_HEADLESS_HEIGHT is required")
local rom_base = assert(tonumber(os.getenv("SSV_HEADLESS_ROM_BASE")), "SSV_HEADLESS_ROM_BASE is required")
local max_frames = tonumber(os.getenv("SSV_HEADLESS_FRAMES")) or 360
local input_journal = os.getenv("SSV_HEADLESS_INPUT_JOURNAL")
local neutral_after_frame = tonumber(os.getenv("SSV_HEADLESS_NEUTRAL_AFTER_FRAME"))
local gameplay_entry_frame = tonumber(os.getenv("SSV_HEADLESS_GAMEPLAY_ENTRY_FRAME"))
local journal_required = os.getenv("SSV_HEADLESS_JOURNAL_REQUIRED") == "1"
local scenario_file = os.getenv("SSV_HEADLESS_SCENARIO_FILE") or ""
local mame_version = os.getenv("SSV_HEADLESS_MAME_VERSION") or "0.289 (mame0289)"
local mame_sha256 = os.getenv("SSV_HEADLESS_MAME_SHA256") or ""
local journal_sha256 = os.getenv("SSV_HEADLESS_JOURNAL_SHA256") or ""
local coin_impulse = tonumber(os.getenv("SSV_HEADLESS_COIN_IMPULSE")) or 0
local expected_dsw1 = tonumber(os.getenv("SSV_HEADLESS_DSW1"))
local expected_dsw2 = tonumber(os.getenv("SSV_HEADLESS_DSW2"))
local expected_watchdog_resets = tonumber(os.getenv("SSV_HEADLESS_EXPECTED_WATCHDOG_RESETS")) or 0
local expected_watchdog_min_frame = tonumber(os.getenv("SSV_HEADLESS_EXPECTED_WATCHDOG_MIN_FRAME")) or 0
local expected_watchdog_max_frame = tonumber(os.getenv("SSV_HEADLESS_EXPECTED_WATCHDOG_MAX_FRAME")) or 0
-- Full bus capture is the strict differential mode.  A bounded barrier-only
-- mode is available for adapter/path smoke tests so a short run cannot
-- allocate gigabytes of diagnostic JSON before its receipt is inspected.
local bus_capture = os.getenv("SSV_HEADLESS_BUS_MODE") or "all"
local strict_only = os.getenv("SSV_HEADLESS_STRICT_ONLY") == "1"
local bus_start_frame = tonumber(os.getenv("SSV_HEADLESS_BUS_START_FRAME")) or -1
local bus_stop_frame = tonumber(os.getenv("SSV_HEADLESS_BUS_STOP_FRAME")) or -1
-- Optional, read-only causal probe.  It is deliberately disabled for normal
-- captures so the canonical bus stream remains unchanged.  When enabled it
-- snapshots the V60 architectural state at the first active work-RAM write
-- used by the Dyna strict-divergence experiment (0x7904).
local state_capture = os.getenv("SSV_HEADLESS_STATE_CAPTURE") == "1"
local state_capture_address = tonumber(os.getenv("SSV_HEADLESS_STATE_ADDRESS")) or 0x007904
local state_capture_pc = tonumber(os.getenv("SSV_HEADLESS_STATE_PC")) or -1
-- Optional, read-only per-frame memory-state CRC sidecar.  This uses the
-- established state contract from mame-capture-ssv-frames.lua, but runs on
-- the canonical journaled headless adapter so its frame cursor and inputs
-- are the same as the strict differential lane.
local state_crc_capture = os.getenv("SSV_HEADLESS_STATE_CRC_CAPTURE") == "1"
local state_crc_path = os.getenv("SSV_HEADLESS_STATE_CRC_OUTPUT") or
    (root .. "/mame-state.crc")
-- Optional, read-only V60 instruction-boundary probe.  MAME's V60 core calls
-- its debugger instruction hook immediately before executing an instruction;
-- the ROM read tap below therefore records the same pre-execution PC/opcode
-- boundary without mutating the machine.  It is diagnostic-only and remains
-- absent from normal canonical captures.
local instruction_capture = os.getenv("SSV_HEADLESS_INSN_CAPTURE") == "1"
-- Optional, read-only instruction-hook trace.  Unlike the ROM read tap above,
-- MAME's debugger tracer runs from device_debug::instruction_hook before every
-- executed instruction, including instructions satisfied from the V60's
-- internal prefetch/cache path.  It is enabled only for narrow diagnostic
-- windows and writes a separate generated artifact; canonical bus captures are
-- unchanged when it is disabled.
local debugger_instruction_trace =
    os.getenv("SSV_HEADLESS_DEBUGGER_INSN_TRACE") == "1"
-- Low-volume architectural transition trace.  A debugger registerpoint runs
-- at the real instruction hook and logs only boundaries where R2 or R23
-- changed since the preceding boundary.  This is intentionally separate from
-- the canonical bus stream and from the full instruction trace.
local debugger_register_change_trace =
    os.getenv("SSV_HEADLESS_DEBUGGER_REG_CHANGE_TRACE") == "1"
local flush_frame_records = os.getenv("SSV_HEADLESS_FLUSH_FRAME_RECORDS") == "1"
-- Optional handler-entry marker for pairing MAME's natural IRQ cadence with
-- RTL IRQ acknowledgements.  This is a read-only instruction-hook record;
-- it does not alter debugger state or the emulated machine.
local irq_handler_pc_env = os.getenv("SSV_HEADLESS_IRQ_HANDLER_PC")
local irq_handler_pc = irq_handler_pc_env and tonumber(irq_handler_pc_env, 16) or nil
if bus_capture ~= "all" and bus_capture ~= "cpu_data" and bus_capture ~= "none" then
    error("SSV_HEADLESS_BUS_MODE must be all, cpu_data or none")
end

if max_frames <= 0 then
    error("SSV_HEADLESS_FRAMES must be positive")
end
if neutral_after_frame and neutral_after_frame < 0 then
    error("SSV_HEADLESS_NEUTRAL_AFTER_FRAME must be nonnegative")
end
if gameplay_entry_frame and gameplay_entry_frame < 0 then
    error("SSV_HEADLESS_GAMEPLAY_ENTRY_FRAME must be nonnegative")
end
if gameplay_entry_frame and neutral_after_frame and
   gameplay_entry_frame ~= neutral_after_frame then
    error("gameplay_entry and neutral-after frame must use the same cursor")
end
if journal_required and (not input_journal or input_journal == "") then
    error("scenario capture requires SSV_HEADLESS_INPUT_JOURNAL")
end
local ppm_frames = {}
local disable_ppm = os.getenv("SSV_HEADLESS_DISABLE_PPM") == "1"
local ppm_frame_list = os.getenv("SSV_HEADLESS_PPM_FRAMES")
if ppm_frame_list then
    for token in ppm_frame_list:gmatch("%d+") do ppm_frames[tonumber(token)] = true end
end

local machine = manager.machine
local screen = assert(machine.screens[":screen"], "SSV :screen missing")
local maincpu = assert(machine.devices[":maincpu"], "SSV :maincpu missing")
local program = assert(maincpu.spaces["program"], "V60 program space missing")
local ports = machine.ioport.ports
local p1 = assert(ports[":P1"], "P1 missing")
local p2 = assert(ports[":P2"], "P2 missing")
local system = assert(ports[":SYSTEM"], "SYSTEM missing")
local dsw1 = assert(ports[":DSW1"], "DSW1 missing")
local dsw2 = assert(ports[":DSW2"], "DSW2 missing")
local observed_dsw1 = dsw1:read() & 0xff
local observed_dsw2 = dsw2:read() & 0xff
if expected_dsw1 and observed_dsw1 ~= expected_dsw1 then
    error(string.format("MAME DSW1 mismatch: expected=%02X observed=%02X", expected_dsw1, observed_dsw1))
end
if expected_dsw2 and observed_dsw2 ~= expected_dsw2 then
    error(string.format("MAME DSW2 mismatch: expected=%02X observed=%02X", expected_dsw2, observed_dsw2))
end
-- Dyna Gear also declares an ADD_BUTTONS port, but its fields are
-- MAME UNKNOWN/fixed-high. Only the supported Survival Arts clone
-- receives journaled live-button writes.
local extra = (setname == "survartsu") and ports[":ADD_BUTTONS"] or nil
local frame = 0
local post_epoch_frames = 0
local video_epoch_seen = false
local seq = 0
local cpu_data_seq = 0
local instruction_seq = 0
local irq_entry_seq = 0
local current_instruction_pc = nil
local stopped = false
local reached_stop = false
local frame_complete_count = 0
local gameplay_entry_seen = false
local frame_artifact_count = 0
local first_frame_crc = nil
local last_frame_crc = nil
local first_event = true
local first_fetch = true
local reset_epoch = 0
local trace_file = assert(io.open(root .. "/mame-trace.jsonl", "w"))
local barrier_file = nil
local barrier_path = os.getenv("SSV_HEADLESS_BARRIER_PATH")
local barrier_dir = os.getenv("SSV_HEADLESS_BARRIER_DIR")
local barrier_sequence = 0
if barrier_path and barrier_path ~= "" and not barrier_dir then
    barrier_file = assert(io.open(barrier_path, "w"))
    barrier_file:setvbuf("line")
end
if os.getenv("SSV_HEADLESS_UNBUFFERED_TRACE") == "1" then
    trace_file:setvbuf("no")
else
    trace_file:setvbuf("line")
end
-- Keep low-volume record/barrier output out of the mixed MAME stream.  The
-- runner merges this sidecar after both handles close, preserving source
-- artifacts and preventing the sparse-file defect seen in barrier-only runs.
local trace = {}
function trace:write(text)
    if barrier_dir and text:sub(1, 10) == '{"record":' then
        local path = string.format("%s/record_%08d.json", barrier_dir, barrier_sequence)
        barrier_sequence = barrier_sequence + 1
        local record = assert(io.open(path, "w"))
        record:setvbuf("no")
        record:write(text)
        record:close()
    elseif barrier_file and text:sub(1, 10) == '{"record":' then
        barrier_file:write(text)
    else
        trace_file:write(text)
    end
end
function trace:flush()
    trace_file:flush()
    if barrier_file then barrier_file:flush() end
end
function trace:close()
    trace_file:close()
    if barrier_file then barrier_file:close() end
end
local state_crc_output = nil
if state_crc_capture then
    state_crc_output = assert(io.open(state_crc_path, "w"))
    state_crc_output:setvbuf("line")
end
local receipt_written = false
local debugger_trace_active = false
local debugger_trace_path = root .. "/mame-v60-debugger.tr"
local debugger_register_change_installed = false

local function update_debugger_post_epoch_frame()
    if not machine.debugger or not maincpu.debug then return end
    machine.debugger.visible_cpu = maincpu
    -- MAME debugger numeric literals default to hexadecimal.  Format the
    -- decimal Lua cursor as hexadecimal text so temp2 retains the same value.
    machine.debugger:command(string.format("temp2=%X", post_epoch_frames))
end

local function install_debugger_register_change_trace()
    if not debugger_register_change_trace or debugger_register_change_installed then return end
    if not machine.debugger or not maincpu.debug then
        error("debugger register-change trace requires MAME -debug -debugger none")
    end
    machine.debugger.visible_cpu = maincpu
    machine.debugger:command("temp0=R2; temp1=R23")
    update_debugger_post_epoch_frame()
    machine.debugger:command(
        'rp {R2 != temp0 || R23 != temp1},{printf "SSVREGCHANGE cursor=%d pc=%08X opcode=%02X psw=%08X beamx=%d beamy=%d old_r2=%08X new_r2=%08X old_r23=%08X new_r23=%08X\\n",temp2,PC,pb@PC,PSW,beamx,beamy,temp0,R2,temp1,R23; temp0=R2; temp1=R23; g}')
    debugger_register_change_installed = true
    trace:write(
        '{"record":"barrier","name":"mame_debugger_register_change_trace_start","phase":"completed","registers":["R2","R23"],"sampling":"before_execute","artifact":"mame/debug.log"}\n')
end

local function stop_debugger_instruction_trace()
    if not debugger_trace_active then return end
    machine.debugger:command("trace off,:maincpu")
    machine.debugger:command("traceflush")
    debugger_trace_active = false
    trace:write(string.format(
        '{"record":"barrier","name":"mame_debugger_instruction_trace_stop","phase":"completed","frame":%d,"post_epoch_frame":%d}\n',
        frame, post_epoch_frames))
end

local function start_debugger_instruction_trace()
    if not debugger_instruction_trace or debugger_trace_active then return end
    if not machine.debugger or not maincpu.debug then
        error("debugger instruction trace requires MAME -debug -debugger none")
    end
    machine.debugger.visible_cpu = maincpu
    local names = {}
    local formats = {}
    local expressions = {"temp2", "PC", "pb@PC", "PSW", "beamx", "beamy"}
    formats[#formats + 1] = " beamx=%d"
    formats[#formats + 1] = " beamy=%d"
    for index = 0, 28 do
        names[#names + 1] = "r" .. index
        formats[#formats + 1] = " r" .. index .. "=%08X"
        expressions[#expressions + 1] = "R" .. index
    end
    for _, alias in ipairs({"AP", "FP", "SP"}) do
        names[#names + 1] = alias:lower()
        formats[#formats + 1] = " " .. alias:lower() .. "=%08X"
        expressions[#expressions + 1] = alias
    end
    local action = string.format(
        '{tracelog "SSVREG cursor=%%d pc=%%08X opcode=%%02X psw=%%08X%s\\n",%s}',
        table.concat(formats), table.concat(expressions, ","))
    local command = string.format(
        'trace "%s",:maincpu,noloop,%s', debugger_trace_path, action)
    machine.debugger:command(command)
    debugger_trace_active = true
    trace:write(string.format(
        '{"record":"barrier","name":"mame_debugger_instruction_trace_start","phase":"completed","frame":%d,"post_epoch_frame":%d,"artifact":"%s","register_aliases":["AP","FP","SP"],"loop_suppression":false}\n',
        frame, post_epoch_frames, debugger_trace_path))
end

local function finish_capture(reason)
    if receipt_written then return end
    stop_debugger_instruction_trace()
    if state_crc_output then
        state_crc_output:flush()
        state_crc_output:close()
        state_crc_output = nil
    end
    receipt_written = true
    trace:write(string.format('{"record":"barrier","name":"%s","phase":"completed","frame":%d,"post_epoch_frames":%d,"counts":{"mainbus":%d,"cpu_data":%d}}\n',
        reason == "stop_barrier" and "stop" or "aborted", frame, post_epoch_frames, seq, cpu_data_seq))
    trace:write(string.format('{"record":"receipt","reason":"%s","complete":%s,"dropped":0,"set":"%s","mame_version":"%s","mame_sha256":"%s","scenario_file":"%s","journal_sha256":"%s","coin_impulse":%d,"dips":{"DSW1":%d,"DSW2":%d},"geometry":{"width":%d,"height":%d},"expected_frames":%d,"frames":%d,"frame_artifacts":%d,"first_frame_crc32":%s,"last_frame_crc32":%s,"neutral_after_frame":%d,"gameplay_entry_frame":%d,"gameplay_entry_seen":%s,"expected_watchdog":{"resets":%d,"min_post_video_frame":%d,"max_post_video_frame":%d},"counts":{"mainbus":%d,"cpu_data":%d},"bus_capture":"%s"}\n',
        reason, reason == "stop_barrier" and "true" or "false", setname, mame_version, mame_sha256, scenario_file, journal_sha256, coin_impulse, observed_dsw1, observed_dsw2, width, height, max_frames, frame_complete_count, frame_artifact_count, first_frame_crc and tostring(first_frame_crc) or "null", last_frame_crc and tostring(last_frame_crc) or "null", neutral_after_frame or -1, gameplay_entry_frame or -1, gameplay_entry_seen and "true" or "false", expected_watchdog_resets, expected_watchdog_min_frame, expected_watchdog_max_frame, seq, cpu_data_seq, bus_capture))
    trace:flush()
    trace:close()
end

local journal = {}
local journal_dir = nil
local function parse_packet(text)
    local f = tonumber(text:match('"frame"%s*:%s*(%d+)'))
    local p1 = tonumber(text:match('"p1_pressed"%s*:%s*(%d+)'))
    local p2 = tonumber(text:match('"p2_pressed"%s*:%s*(%d+)'))
    local system = tonumber(text:match('"system_pressed"%s*:%s*(%d+)'))
    if not f or not p1 or not p2 or not system or
       p1 < 0 or p1 > 0xffff or p2 < 0 or p2 > 0xffff or
       system < 0 or system > 0xffff then
        return nil
    end
    return {p1 = p1, p2 = p2, system = system}, f
end
if input_journal and input_journal ~= "" then
    local stream = io.open(input_journal, "r")
    if stream then
        local previous_frame = -1
        for line in stream:lines() do
            local packet, f = parse_packet(line)
            if packet and f then
                if f <= previous_frame or journal[f] then
                    error(string.format("input journal frame order is not strictly increasing: frame=%d", f))
                end
                journal[f] = packet
                previous_frame = f
            elseif journal_required and line:match("%S") then
                error("scenario input journal contains a malformed packet")
            end
        end
        stream:close()
    else
        -- The scenario compiler emits a directory of immutable protocol-v2
        -- frame_NNNNNN.json packets. Read packets lazily, but fail closed on
        -- a missing packet when a scenario is active; silently substituting a
        -- neutral packet would change the input contract.
        journal_dir = input_journal
        if journal_required then
            local manifest = io.open(input_journal .. "/manifest.json", "r")
            if not manifest then
                error("scenario journal manifest is missing: " .. input_journal)
            end
            manifest:close()
        end
    end
end

local function journal_packet(frame_number)
    if journal[frame_number] then return journal[frame_number] end
    if not journal_dir then return nil end
    local path = string.format("%s/frame_%06d.json", journal_dir, frame_number)
    local stream = io.open(path, "r")
    if not stream then
        if journal_required then
            error(string.format("scenario journal packet is missing: frame=%d", frame_number))
        end
        return nil
    end
    local packet, packet_frame = parse_packet(stream:read("*a"))
    stream:close()
    if journal_required and (not packet or packet_frame ~= frame_number) then
        error(string.format("scenario journal packet is malformed: frame=%d", frame_number))
    end
    if packet then journal[frame_number] = packet end
    return journal[frame_number]
end

local function cpu_pc()
    local ok, value = pcall(function() return maincpu.state["PC"].value end)
    return ok and tonumber(value) or 0
end

local function emit_state_snapshot(address, data, mask)
    if not state_capture or (address & 0xffffff) ~= state_capture_address then return end
    local values = {}
    local state_names = {}
    for index = 0, 28 do state_names[index + 1] = "R" .. index end
    state_names[30] = "AP"
    state_names[31] = "FP"
    state_names[32] = "SP"
    for index = 0, 31 do
        local ok, value = pcall(function()
            return maincpu.state[state_names[index + 1]].value
        end)
        values[index + 1] = ok and (tonumber(value) or 0) or 0
    end
    local ok_psw, psw = pcall(function() return maincpu.state["PSW"].value end)
    trace:write(string.format(
        '{"domain":"v60_state","event":"workram_write","address":%d,"phase":"completed","frame":%d,"pc":%d,"data":%d,"byte_enable":%d,"psw":%d,"r0":%d,"r1":%d,"r2":%d,"r3":%d,"r4":%d,"r5":%d,"r6":%d,"r7":%d,"r8":%d,"r9":%d,"r10":%d,"r11":%d,"r12":%d,"r13":%d,"r14":%d,"r15":%d,"r16":%d,"r17":%d,"r18":%d,"r19":%d,"r20":%d,"r21":%d,"r22":%d,"r23":%d,"r24":%d,"r25":%d,"r26":%d,"r27":%d,"r28":%d,"r29":%d,"r30":%d,"r31":%d}\n',
        state_capture_address, frame, cpu_pc(), data & 0xffff, mask & 0xffff,
        ok_psw and (tonumber(psw) or 0) or 0,
        table.unpack(values)))
end

local function instruction_window_active()
    if not instruction_capture then return false end
    if bus_start_frame >= 0 then
        if not video_epoch_seen or post_epoch_frames < bus_start_frame then return false end
        if bus_stop_frame >= 0 and post_epoch_frames > bus_stop_frame then return false end
    elseif bus_stop_frame >= 0 and video_epoch_seen and post_epoch_frames > bus_stop_frame then
        return false
    end
    return true
end

local function emit_instruction(pc, opcode)
    if not instruction_window_active() then return end
    current_instruction_pc = pc
    local ok_psw, psw = pcall(function() return maincpu.state["PSW"].value end)
    if irq_handler_pc and pc == irq_handler_pc then
        trace:write(string.format(
            '{"domain":"v60_irq_entry","seq":%d,"event":"handler_entry","phase":"before_execute","handler_pc":%d,"opcode":%d,"psw":%d,"frame":%d,"post_epoch_frame":%d}\n',
            irq_entry_seq, pc, opcode, ok_psw and (tonumber(psw) or 0) or 0,
            frame, post_epoch_frames))
        irq_entry_seq = irq_entry_seq + 1
    end
    trace:write(string.format(
        '{"domain":"v60_instruction","seq":%d,"event":"fetch","phase":"before_execute","pc":%d,"opcode":%d,"psw":%d,"frame":%d,"post_epoch_frame":%d}\n',
        instruction_seq, pc, opcode, ok_psw and (tonumber(psw) or 0) or 0,
        frame, post_epoch_frames))
    if state_capture and state_capture_pc >= 0 and pc == state_capture_pc then
        local values = {}
        local state_names = {}
        for index = 0, 28 do state_names[index + 1] = "R" .. index end
        state_names[30] = "AP"
        state_names[31] = "FP"
        state_names[32] = "SP"
        for index = 0, 31 do
            local ok, value = pcall(function()
                return maincpu.state[state_names[index + 1]].value
            end)
            values[index + 1] = ok and (tonumber(value) or 0) or 0
        end
        trace:write(string.format(
            '{"domain":"v60_state","event":"instruction_before_execute","pc":%d,"opcode":%d,"phase":"completed","frame":%d,"psw":%d,"r0":%d,"r1":%d,"r2":%d,"r3":%d,"r4":%d,"r5":%d,"r6":%d,"r7":%d,"r8":%d,"r9":%d,"r10":%d,"r11":%d,"r12":%d,"r13":%d,"r14":%d,"r15":%d,"r16":%d,"r17":%d,"r18":%d,"r19":%d,"r20":%d,"r21":%d,"r22":%d,"r23":%d,"r24":%d,"r25":%d,"r26":%d,"r27":%d,"r28":%d,"r29":%d,"r30":%d,"r31":%d}\n',
            pc, opcode, frame, ok_psw and (tonumber(psw) or 0) or 0,
            table.unpack(values)))
    end
    instruction_seq = instruction_seq + 1
end

local function video_position()
    local y_ok, y = pcall(function() return screen:vpos() end)
    local x_ok, x = pcall(function() return screen:hpos() end)
    return (y_ok and tonumber(y) or 0), (x_ok and tonumber(x) or 0)
end

local function device_for(address)
    address = address & 0xffffff
    if address <= 0x00ffff then return 2 end
    if address >= 0x100000 and address <= 0x13ffff then return 3 end
    if address >= 0x140000 and address <= 0x15ffff then return 4 end
    if (address >= 0x160000 and address <= 0x17ffff) or
       (address >= 0x010000 and address <= 0x03ffff) or
       (address >= 0x400000 and address <= 0x43ffff) or
       (address >= 0x580000 and address <= 0x58ffff) then return 5 end
    if address >= 0x1c0000 and address <= 0x1c007f then return 6 end
    if address >= 0x210000 and address <= 0x210011 then return 7 end
    if address == 0x500008 or address == 0x500009 then return 7 end
    if (address >= 0x230000 and address <= 0x230071) or
       (address >= 0x240000 and address <= 0x240071) or
       (address >= 0x260000 and address <= 0x260001) then return 8 end
    if address >= 0x300000 and address <= 0x30007f then return 9 end
    if (address >= 0x480000 and address <= 0x480001) or
       (address >= 0x482000 and address <= 0x482fff) then return 10 end
    if address == 0x510000 or address == 0x520000 then return 11 end
    -- The descriptor selects the program image size and therefore its 24-bit
    -- top-of-space base.  The runner derives this from descriptor byte 2;
    -- do not duplicate the set matrix in this adapter.
    if address >= rom_base then return 1 end
    return 0
end

local function emit_bus(rw, address, data, mask)
    if bus_capture == "none" then return end
    if bus_start_frame >= 0 then
        if not video_epoch_seen or post_epoch_frames < bus_start_frame then return end
        if bus_stop_frame >= 0 and post_epoch_frames > bus_stop_frame then return end
    elseif bus_stop_frame >= 0 and video_epoch_seen and post_epoch_frames > bus_stop_frame then
        return
    end
    local be = (((mask & 0x00ff) ~= 0) and 1 or 0) |
               (((mask & 0xff00) ~= 0) and 2 or 0)
    local lane_mask = (((be & 1) ~= 0) and 0x00ff or 0) |
                     (((be & 2) ~= 0) and 0xff00 or 0)
    local device = device_for(address)
    -- The strict differential projection excludes instruction-ROM fetches:
    -- MAME's program-space tap observes individual accesses while RTL fills
    -- 64-bit cache lines.  Devices 0 and 2..11 retain equivalent completed
    -- transaction semantics and are emitted in cpu_data mode.
    if bus_capture == "cpu_data" and device == 1 then return end
    local scanline, hpos = video_position()
    emit_state_snapshot(address, data, be)
    if first_event then
        trace:write(string.format('{"record":"barrier","name":"reset_release","phase":"completed","frame":%d}\n', frame))
        first_event = false
    end
    if strict_only then
        trace:write(string.format(
            '{"domain":"mainbus","seq":%d,"event":"bus","phase":"completed","rw":"%s","address":%d,"data":%d,"byte_enable":%d,"device":%d}\n',
            seq, rw, address & 0xfffffe, data & lane_mask & 0xffff, be, device))
    elseif instruction_capture then
        trace:write(string.format(
            '{"domain":"mainbus","seq":%d,"event":"bus","phase":"completed","rw":"%s","address":%d,"data":%d,"byte_enable":%d,"device":%d,"pc":%d,"instruction_pc":%d,"reset_epoch":%d,"frame":%d,"scanline":%d,"hpos":%d}\n',
            seq, rw, address & 0xfffffe, data & lane_mask & 0xffff, be,
            device, cpu_pc(), current_instruction_pc or 0, reset_epoch, frame, scanline, hpos))
    else
        trace:write(string.format(
            '{"domain":"mainbus","seq":%d,"event":"bus","phase":"completed","rw":"%s","address":%d,"data":%d,"byte_enable":%d,"device":%d,"pc":%d,"reset_epoch":%d,"frame":%d,"scanline":%d,"hpos":%d}\n',
            seq, rw, address & 0xfffffe, data & lane_mask & 0xffff, be,
            device, cpu_pc(), reset_epoch, frame, scanline, hpos))
    end
    seq = seq + 1
    if device ~= 1 then cpu_data_seq = cpu_data_seq + 1 end
    if first_fetch and rw == "R" and device == 1 then
        trace:write(string.format('{"record":"barrier","name":"first_fetch","phase":"completed","frame":%d,"seq":%d}\n', frame, seq - 1))
        first_fetch = false
    end
end

ssv_headless_read_tap = program:install_read_tap(
    0x000000, 0xffffff, "ssv_headless_all_r",
    function(offset, data, mask) emit_bus("R", offset, data, mask) end)

-- Keep this tap separate from the canonical bus tap.  It is installed only
-- when explicitly requested and emits no mainbus records.
if instruction_capture then
    ssv_headless_instruction_tap = program:install_read_tap(
        rom_base, 0xffffff, "ssv_headless_v60_instruction",
        function(offset, data, mask)
            local ok_pc, pc_value = pcall(function() return maincpu.state["PC"].value end)
            if not ok_pc then return data end
            local pc = tonumber(pc_value) & 0xffffff
            local opcode = nil
            if (pc & 1) == 0 then
                if offset == pc and (mask & 0x00ff) ~= 0 then opcode = data & 0xff end
            elseif offset == (pc - 1) and (mask & 0xff00) ~= 0 then
                opcode = (data >> 8) & 0xff
            end
            if opcode ~= nil then emit_instruction(pc, opcode) end
            return data
        end)
end
ssv_headless_write_tap = program:install_write_tap(
    0x000000, 0xffffff, "ssv_headless_all_w",
    function(offset, data, mask)
        emit_bus("W", offset, data, mask)
        -- The RTL testbench names the shared epoch at the accepted
        -- $21000e bit-7 write.  Count MAME's native frames from reset for
        -- causal context, but stop only after the same post-epoch budget.
        if (offset & 0xffffff) == 0x21000e and (data & 0x0080) ~= 0 and
           not video_epoch_seen then
            video_epoch_seen = true
            post_epoch_frames = 0
            trace:write(string.format(
                '{"record":"barrier","name":"video_enable_epoch","phase":"completed","frame":%d,"seq":%d}\n',
                frame, seq))
        end
    end)

local function neutral(port)
    for _, field in pairs(port.fields) do pcall(function() field:set_value(0) end) end
end

local function apply_port(port, mask, bindings)
    for bit, names in pairs(bindings) do
        for _, name in ipairs(names) do
            local field = port.fields[name]
            if field then field:set_value((mask & bit) ~= 0 and 1 or 0); break end
        end
    end
end

local function apply_inputs(target_frame)
    neutral(p1); neutral(p2); neutral(system)
    if extra then neutral(extra) end
    local item = journal_packet(target_frame)
    if journal_required and not item then
        error(string.format("scenario journal packet is missing: frame=%d", target_frame))
    end
    item = item or {p1=0, p2=0, system=0}
    if neutral_after_frame and target_frame >= neutral_after_frame and
       (item.p1 ~= 0 or item.p2 ~= 0 or item.system ~= 0) then
        error(string.format("non-neutral input after gameplay entry frame=%d", target_frame))
    end
    apply_port(p1, item.p1, {
        [0x01]={"1 Player Start","P1 Start"}, [0x02]={"P1 Button 3","P1 Button 4"},
        [0x04]={"P1 Button 2"}, [0x08]={"P1 Button 1"}, [0x10]={"P1 Right"},
        [0x20]={"P1 Left"}, [0x40]={"P1 Down"}, [0x80]={"P1 Up"}})
    apply_port(p2, item.p2, {
        [0x01]={"2 Players Start","2 Player Start","P2 Start"},
        [0x02]={"P2 Button 3","P2 Button 4"}, [0x04]={"P2 Button 2"},
        [0x08]={"P2 Button 1"}, [0x10]={"P2 Right"}, [0x20]={"P2 Left"},
        [0x40]={"P2 Down"}, [0x80]={"P2 Up"}})
    if extra then
        apply_port(extra, item.p1, {
            [0x100]={"P1 Button 4"}, [0x200]={"P1 Button 5"},
            [0x400]={"P1 Button 6"}})
        apply_port(extra, item.p2, {
            [0x100]={"P2 Button 4"}, [0x200]={"P2 Button 5"},
            [0x400]={"P2 Button 6"}})
    end
    apply_port(system, item.system, {
        [0x01]={"Coin 1"}, [0x02]={"Coin 2"},
        [0x04]={"Service 1","Service"}, [0x08]={"Tilt"},
        [0x10]={"Test"}})
end

local function crc32(data)
    local crc = 0xffffffff
    for index = 1, #data do
        crc = crc ~ data:byte(index)
        for _ = 1, 8 do
            if (crc & 1) ~= 0 then crc = (crc >> 1) ~ 0xedb88320
            else crc = crc >> 1 end
        end
    end
    return (~crc) & 0xffffffff
end

local function crc32_update_word(crc, value)
    for _, byte in ipairs({value & 0xff, (value >> 8) & 0xff}) do
        crc = crc ~ byte
        for _ = 1, 8 do
            if (crc & 1) ~= 0 then crc = (crc >> 1) ~ 0xedb88320
            else crc = crc >> 1 end
        end
    end
    return crc
end

local function crc16_words(base, count)
    local crc = 0xffffffff
    for index = 0, count - 1 do
        crc = crc32_update_word(crc, program:read_u16(base + index * 2))
    end
    return (~crc) & 0xffffffff
end

local function write_state_crc(target_frame)
    if not state_crc_output then return end
    local list512 = crc16_words(0x100000, 512)
    local spr8k = crc16_words(0x100000, 8192)
    local scroll63 = crc16_words(0x1c0000, 64)
    local pal512 = crc16_words(0x140000, 1024)
    state_crc_output:write(string.format(
        "STATE %u list512=%08x spr8k=%08x scroll63=%08x pal512=%08x\n",
        target_frame, list512, spr8k, scroll63, pal512))
end

local function write_ppm(target_frame)
    local rows = {}
    local pixels = {}
    for y = 0, height - 1 do
        local row = {}
        for x = 0, width - 1 do
            local pixel = screen:pixel(x, y)
            row[#row + 1] = string.char((pixel >> 16) & 0xff,
                                        (pixel >> 8) & 0xff, pixel & 0xff)
        end
        pixels[#pixels + 1] = table.concat(row)
    end
    local rgb = table.concat(pixels)
    local artifact = false
    if not disable_ppm and (ppm_frames[target_frame] or target_frame == max_frames - 1) then
        local path = string.format("%s/mame-native_f%06d.ppm", root, target_frame)
        local stream = assert(io.open(path, "wb"))
        stream:write(string.format("P6\n%d %d\n255\n", width, height), rgb)
        stream:close()
        artifact = true
    end
    return crc32(rgb), artifact
end

apply_inputs(0)
trace:write(string.format('{"record":"contract","schema":"mister-raw-trace-v4","producer":"mame-0.289-headless","mame_version":"%s","mame_sha256":"%s","headless":true,"display_backend":"none","strict_candidate":"cpu_data","diagnostic_domain":"mainbus","program_rom_device_excluded":1,"strict_only":%s,"set":"%s","geometry":{"width":%d,"height":%d},"expected_frames":%d,"scenario_file":"%s","journal_sha256":"%s","coin_impulse":%d,"bus_capture":"%s","bus_start_frame":%d,"bus_stop_frame":%d,"debugger_instruction_trace":%s,"debugger_register_change_trace":%s,"irq_handler_pc":%d,"irq_entry_trace":%s}\n', mame_version, mame_sha256, strict_only and "true" or "false", setname, width, height, max_frames, scenario_file, journal_sha256, coin_impulse, bus_capture, bus_start_frame, bus_stop_frame, debugger_instruction_trace and "true" or "false", debugger_register_change_trace and "true" or "false", irq_handler_pc or -1, irq_handler_pc and "true" or "false"))
install_debugger_register_change_trace()

emu.register_frame_done(function()
    if stopped then return end
    if video_epoch_seen then
        local item = journal_packet(post_epoch_frames)
        if journal_required and not item then
            error(string.format("scenario journal packet is missing: frame=%d", post_epoch_frames))
        end
        item = item or {p1=0, p2=0, system=0}
        local frame_crc, artifact = write_ppm(post_epoch_frames)
        write_state_crc(post_epoch_frames)
        if not first_frame_crc then first_frame_crc = frame_crc end
        last_frame_crc = frame_crc
        frame_complete_count = frame_complete_count + 1
        if artifact then frame_artifact_count = frame_artifact_count + 1 end
        trace:write(string.format('{"record":"barrier","name":"frame_complete","phase":"completed","frame":%d,"post_epoch_frame":%d,"input_cursor":%d,"p1_pressed":%d,"p2_pressed":%d,"system_pressed":%d,"frame_crc32":%u,"frame_artifact":%s,"counts":{"mainbus":%d,"cpu_data":%d}}\n', frame, post_epoch_frames, post_epoch_frames, item.p1, item.p2, item.system, frame_crc, artifact and "true" or "false", seq, cpu_data_seq))
        if gameplay_entry_frame and post_epoch_frames == gameplay_entry_frame then
            gameplay_entry_seen = true
            trace:write(string.format('{"record":"barrier","name":"gameplay_entry","phase":"completed","frame":%d,"input_cursor":%d,"neutral_after_frame":%d}\n', frame, post_epoch_frames, neutral_after_frame or gameplay_entry_frame))
        end
        if flush_frame_records then trace:flush() end
        post_epoch_frames = post_epoch_frames + 1
        update_debugger_post_epoch_frame()
        if debugger_instruction_trace then
            if not debugger_trace_active and
               (bus_start_frame < 0 or post_epoch_frames >= bus_start_frame) and
               (bus_stop_frame < 0 or post_epoch_frames <= bus_stop_frame) then
                start_debugger_instruction_trace()
            elseif debugger_trace_active and bus_stop_frame >= 0 and
                   post_epoch_frames > bus_stop_frame then
                stop_debugger_instruction_trace()
            end
        end
    end
    frame = frame + 1
    -- The stop cursor is exclusive: a finite scenario journal has packets
    -- through max_frames-1, but not at max_frames.
    if video_epoch_seen and post_epoch_frames < max_frames then
        apply_inputs(post_epoch_frames)
    end
    if video_epoch_seen and post_epoch_frames >= max_frames then
        reached_stop = true
        stopped = true
        finish_capture("stop_barrier")
        manager.machine:exit()
    elseif not video_epoch_seen and frame >= (max_frames * 4) then
        -- A missing epoch is an evidence failure, not an attract pass.
        stopped = true
        finish_capture("missing_video_epoch")
        manager.machine:exit()
    end
end)

emu.add_machine_stop_notifier(function()
    finish_capture(reached_stop and "stop_barrier" or (video_epoch_seen and "aborted" or "missing_video_epoch"))
end)

print(string.format("SSV_HEADLESS_MAME_READY set=%s geometry=%dx%d frames=%d", setname, width, height, max_frames))
