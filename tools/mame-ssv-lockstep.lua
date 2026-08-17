-- SPDX-License-Identifier: GPL-3.0-or-later
-- Protocol-v2 raw-frame adapter for the parent-only SSV differential workflow.

local root = assert(os.getenv("SSV_LOCKSTEP_DIR"), "SSV_LOCKSTEP_DIR is required")
local setname = assert(os.getenv("SSV_LOCKSTEP_SET"), "SSV_LOCKSTEP_SET is required")
local width = assert(tonumber(os.getenv("SSV_LOCKSTEP_WIDTH")), "SSV_LOCKSTEP_WIDTH is required")
local height = assert(tonumber(os.getenv("SSV_LOCKSTEP_HEIGHT")), "SSV_LOCKSTEP_HEIGHT is required")
local trace_start_frame = tonumber(os.getenv("SSV_LOCKSTEP_START_FRAME")) or 0
local startup_mode = os.getenv("SSV_LOCKSTEP_REFERENCE_STARTUP_MODE") or "cold-lockstep"
local catchup_target = tonumber(os.getenv("SSV_LOCKSTEP_CATCHUP_TARGET")) or -1
local strict_inputs = os.getenv("SSV_LOCKSTEP_STRICT_INPUTS") == "1"
local trace_registers = os.getenv("SSV_LOCKSTEP_TRACE_REGS") == "1"
local dump_index_frame = tonumber(os.getenv("SSV_LOCKSTEP_DUMP_INDEX_FRAME")) or -1
local dump_index_path = os.getenv("SSV_LOCKSTEP_DUMP_INDEX_PATH")
local first_comparable_token = assert(
    tonumber(os.getenv("SSV_LOCKSTEP_FIRST_COMPARABLE_TOKEN")),
    "SSV_LOCKSTEP_FIRST_COMPARABLE_TOKEN is required")
assert(first_comparable_token >= 1,
       "SSV_LOCKSTEP_FIRST_COMPARABLE_TOKEN must be positive")

local screen = assert(manager.machine.screens[":screen"], "SSV :screen missing")
local maincpu = assert(manager.machine.devices[":maincpu"], "SSV :maincpu missing")
local dsp = manager.machine.devices[":dsp"]
local program = assert(maincpu.spaces["program"], "V60 program space missing")
local ports = manager.machine.ioport.ports
local dsw1 = assert(ports[":DSW1"], "DSW1 missing")
local dsw2 = assert(ports[":DSW2"], "DSW2 missing")
local p1 = assert(ports[":P1"], "P1 missing")
local p2 = assert(ports[":P2"], "P2 missing")
local system = assert(ports[":SYSTEM"], "SYSTEM missing")

local frame = 0
local captured = -1
local armed = false
local stopped = false
local step_pending = false
local last_screen_frame = -1
local crc_table = {}
local trace_sequence = 0
local trace_buffer = {}
local trace_stopped = false
local trace_suppressed = false
local boot_watchdog_reads = 0
ssv_lockstep_bus_taps = {}

local function path(relative)
    return root .. "/" .. relative
end

local function atomic_write(relative, data, binary)
    local target = path(relative)
    local temporary = target .. ".tmp"
    local stream = assert(io.open(temporary, binary and "wb" or "w"))
    stream:write(data)
    stream:flush()
    stream:close()
    -- Windows readers do not always grant delete sharing. The coordinator's
    -- token read is very short, but a remove/rename can still land inside it.
    -- Retry the same atomic publish until that handle closes instead of
    -- aborting an otherwise deterministic multi-minute reference run.
    for _ = 1, 1000 do
        os.remove(target)
        if os.rename(temporary, target) then return end
    end
    error("cannot publish " .. target)
end

local function read_integer(relative)
    local stream = io.open(path(relative), "r")
    if not stream then return nil end
    local value = tonumber(stream:read("*l") or "")
    stream:close()
    return value
end

local function exists(relative)
    local stream = io.open(path(relative), "rb")
    if not stream then return false end
    stream:close()
    return true
end

local function init_crc()
    for index = 0, 255 do
        local value = index
        for _ = 1, 8 do
            value = ((value & 1) ~= 0) and
                ((value >> 1) ~ 0xedb88320) or (value >> 1)
        end
        crc_table[index] = value
    end
end

local function crc_byte(crc, value)
    return (crc >> 8) ~ crc_table[(crc ~ value) & 0xff]
end

local function crc16_words(base, count)
    local crc = 0xffffffff
    for index = 0, count - 1 do
        local value = program:read_u16(base + index * 2)
        crc = crc_byte(crc, value & 0xff)
        crc = crc_byte(crc, (value >> 8) & 0xff)
    end
    return (~crc) & 0xffffffff
end

local function neutral_port(port)
    for _, field in pairs(port.fields) do
        pcall(function() field:set_value(0) end)
    end
end

local function set_named(port, names, pressed)
    for _, name in ipairs(names) do
        local field = port.fields[name]
        if field then
            field:set_value(pressed and 1 or 0)
            return true
        end
    end
    return false
end

local p1_fields = {
    {0x01, {"1 Player Start", "P1 Start"}},
    {0x02, {"P1 Button 3", "P1 Button 4"}},
    {0x04, {"P1 Button 2"}},
    {0x08, {"P1 Button 1"}},
    {0x10, {"P1 Right"}},
    {0x20, {"P1 Left"}},
    {0x40, {"P1 Down"}},
    {0x80, {"P1 Up"}},
}
local p2_fields = {
    {0x01, {"2 Players Start", "2 Player Start", "P2 Start"}},
    {0x02, {"P2 Button 3", "P2 Button 4"}},
    {0x04, {"P2 Button 2"}},
    {0x08, {"P2 Button 1"}},
    {0x10, {"P2 Right"}},
    {0x20, {"P2 Left"}},
    {0x40, {"P2 Down"}},
    {0x80, {"P2 Up"}},
}
local system_fields = {
    {0x01, {"Coin 1"}}, {0x02, {"Coin 2"}},
    {0x04, {"Service 1", "Service"}}, {0x08, {"Tilt"}},
}

local function parse_packet(packet_frame)
    local stream = io.open(path(string.format("inputs/frame_%06d.json", packet_frame)), "r")
    if not stream then
        if strict_inputs then error("missing strict RTL-owner input packet " .. packet_frame) end
        return 0, 0, 0
    end
    local text = stream:read("*a")
    stream:close()
    if strict_inputs then
        local encoded_frame = tonumber(text:match('"frame"%s*:%s*(%d+)'))
        local source = text:match('"source"%s*:%s*"([^"]+)"')
        local expected_source = packet_frame == 0 and "neutral-seed" or "rtl-owner"
        assert(encoded_frame == packet_frame,
               "strict input packet frame mismatch for " .. packet_frame)
        assert(source == expected_source,
               "strict input packet owner mismatch for " .. packet_frame)
    end
    return tonumber(text:match('"p1_pressed"%s*:%s*(%d+)')) or 0,
           tonumber(text:match('"p2_pressed"%s*:%s*(%d+)')) or 0,
           tonumber(text:match('"system_pressed"%s*:%s*(%d+)')) or 0
end

local function apply_inputs(packet_frame)
    neutral_port(p1)
    neutral_port(p2)
    neutral_port(system)
    local p1_mask, p2_mask, system_mask = parse_packet(packet_frame)
    for _, binding in ipairs(p1_fields) do
        set_named(p1, binding[2], (p1_mask & binding[1]) ~= 0)
    end
    for _, binding in ipairs(p2_fields) do
        set_named(p2, binding[2], (p2_mask & binding[1]) ~= 0)
    end
    for _, binding in ipairs(system_fields) do
        set_named(system, binding[2], (system_mask & binding[1]) ~= 0)
    end
end

local function capture_ppm(token)
    local rows = {string.format("P6\n%d %d\n255\n", width, height)}
    for y = 0, height - 1 do
        local row = {}
        for x = 0, width - 1 do
            local pixel = screen:pixel(x, y)
            row[#row + 1] = string.char(
                (pixel >> 16) & 0xff, (pixel >> 8) & 0xff, pixel & 0xff)
        end
        rows[#rows + 1] = table.concat(row)
    end
    atomic_write(string.format("reference/frame_%06d.ppm", token),
                 table.concat(rows), true)
end

-- The driver renders bitmap_ind16 pens and the screen exposes only the final
-- xRGB888 value.  For renderer diagnosis, invert that conversion using the
-- live SSV palette RAM at the same frame boundary.  The first matching pen is
-- sufficient for the normal palette (duplicate RGB entries are harmless for
-- this diagnostic); 0xffff marks an RGB value not present in palette RAM.
local function capture_index_frame(token)
    if dump_index_frame ~= token or not dump_index_path then return end

    local first_pen = {}
    for pen = 0, 0x7fff do
        local even = program:read_u16(0x140000 + pen * 4)
        local odd = program:read_u16(0x140000 + pen * 4 + 2)
        local rgb = (((odd & 0x00ff) << 16) |
                     ((even & 0xff00)) |
                     (even & 0x00ff))
        if first_pen[rgb] == nil then first_pen[rgb] = pen end
    end

    local bytes = {}
    for y = 0, height - 1 do
        for x = 0, width - 1 do
            local pixel = screen:pixel(x, y)
            local rgb = pixel & 0xffffff
            local pen = first_pen[rgb] or 0xffff
            bytes[#bytes + 1] = string.char(pen & 0xff, (pen >> 8) & 0xff)
        end
    end
    local stream = assert(io.open(dump_index_path, "wb"))
    stream:write(table.concat(bytes))
    stream:flush()
    stream:close()
    print(string.format("SSV_LOCKSTEP_INDEX_DUMP frame=%d path=%s", token,
                        dump_index_path))
end

local function cpu_pc()
    local ok, value = pcall(function() return maincpu.state["PC"].value end)
    return ok and tonumber(value) or 0
end

local function cpu_state(name)
    local ok, value = pcall(function() return maincpu.state[name].value end)
    return ok and tonumber(value) or 0
end

local function dsp_state(name)
    if not dsp then return 0 end
    local ok, value = pcall(function() return dsp.state[name].value end)
    return ok and tonumber(value) or 0
end

local function trace_bus(rw, device, offset, data, mask)
    if trace_stopped or trace_suppressed or frame < trace_start_frame then return end
    local mask16 = mask & 0xffff
    local lanes = ((mask16 & 0x00ff) ~= 0 and 1 or 0) |
                  ((mask16 & 0xff00) ~= 0 and 2 or 0)
    local lane_mask = ((lanes & 1) ~= 0 and 0x00ff or 0) |
                      ((lanes & 2) ~= 0 and 0xff00 or 0)
    trace_sequence = trace_sequence + 1
    local fields = {
        string.format('"frame":%d', frame),
        string.format('"cycle":%d', trace_sequence),
        string.format('"pc":%d', cpu_pc()),
        '"cpu":0', '"event":"bus"', string.format('"rw":"%s"', rw),
        string.format('"address":%d', offset & 0xfffffe),
        string.format('"data":%d', data & lane_mask & 0xffff),
        string.format('"lanes":%d', lanes),
        string.format('"device":%d', device)
    }
    if trace_registers then
        for index = 0, 31 do
            fields[#fields + 1] = string.format('"r%d":%u', index,
                                                 cpu_state("R" .. index))
        end
        fields[#fields + 1] = string.format('"psw":%u', cpu_state("PSW"))
    end
    trace_buffer[#trace_buffer + 1] = "{" .. table.concat(fields, ",") .. "}\n"
end

local function with_trace_suppressed(callback)
    trace_suppressed = true
    local result = table.pack(pcall(callback))
    trace_suppressed = false
    if not result[1] then error(result[2]) end
    return table.unpack(result, 2, result.n)
end

local function install_trace_range(first, last, device, name)
    ssv_lockstep_bus_taps[#ssv_lockstep_bus_taps + 1] =
        program:install_read_tap(first, last, name .. "_r",
            function(offset, data, mask)
                trace_bus("r", device, offset, data, mask)
            end)
    ssv_lockstep_bus_taps[#ssv_lockstep_bus_taps + 1] =
        program:install_write_tap(first, last, name .. "_w",
            function(offset, data, mask)
                trace_bus("w", device, offset, data, mask)
            end)
end

local function flush_trace()
    if #trace_buffer ~= 0 then
        local stream = assert(io.open(path("reference_trace.jsonl"), "a"))
        stream:write(table.concat(trace_buffer))
        stream:flush()
        stream:close()
        trace_buffer = {}
    end
    if exists("TRACE_STOP.txt") then trace_stopped = true end
end

local function capture_state(token)
    local list512_crc, spr8k_crc, scroll63_crc, pal512_crc =
        with_trace_suppressed(function()
            return crc16_words(0x100000, 512),
                   crc16_words(0x100000, 8192),
                   -- Word 0 is read-overlaid by vblank_r(), while RTL state
                   -- inspection sees the underlying scroll RAM. Exclude it
                   -- so this is a like-for-like register-state checksum.
                   crc16_words(0x1c0002, 63),
                   crc16_words(0x140000, 1024)
        end)
    local fields = {
        string.format('"frame":%d', token), '"producer":"reference"',
        string.format('"pc":%d', cpu_pc()),
        string.format('"list512_crc":%u', list512_crc),
        string.format('"spr8k_crc":%u', spr8k_crc),
        string.format('"scroll63_crc":%u', scroll63_crc),
        string.format('"pal512_crc":%u', pal512_crc)
    }
    for index = 0, 31 do
        fields[#fields + 1] = string.format('"r%d":%u', index,
                                             cpu_state("R" .. index))
    end
    fields[#fields + 1] = string.format('"psw":%u', cpu_state("PSW"))
    if dsp then
        for _, name in ipairs({"PC", "A", "B", "DP", "DR", "K", "L", "M", "N"}) do
            fields[#fields + 1] = string.format('"st010_%s":%u',
                                                 string.lower(name),
                                                 dsp_state(name))
        end
    end
    local state = "{" .. table.concat(fields, ",") .. "}\n"
    local stream = assert(io.open(path("reference_state.jsonl"), "a"))
    stream:setvbuf("line")
    stream:write(state)
    stream:close()
end

local function stop_machine(reason)
    if stopped then return end
    stopped = true
    print("SSV_LOCKSTEP_REFERENCE_STOP " .. reason)
    manager.machine:exit()
end

init_crc()
apply_inputs(0)
os.remove(path("reference_state.jsonl"))
os.remove(path("reference_trace.jsonl"))

install_trace_range(0x100000, 0x13ffff, 2, "sprram")
install_trace_range(0x140000, 0x15ffff, 3, "palette")
install_trace_range(0x1c0000, 0x1c007f, 5, "scroll")
install_trace_range(0x210000, 0x210011, 6, "board_io")
install_trace_range(0x230000, 0x230071, 7, "irq_vector")
install_trace_range(0x240000, 0x240071, 7, "irq_ack")
install_trace_range(0x260000, 0x260001, 7, "irq_enable")
install_trace_range(0x300000, 0x30007f, 8, "es5506")
if dsp then
    install_trace_range(0x480000, 0x480001, 9, "st010_data")
    install_trace_range(0x482000, 0x482fff, 9, "st010_ram")
end
if setname == "dynagear" then
    install_trace_range(0x500008, 0x500009, 6, "extra_input")
end

local warmup_tokens = {}
for token = 0, first_comparable_token - 1 do
    warmup_tokens[#warmup_tokens + 1] = tostring(token)
end
local warmup_excluded_tokens = "[" .. table.concat(warmup_tokens, ",") .. "]"
local ready = string.format(
    '{"schema":"ssv-lockstep-ready-v2","producer":"reference",' ..
    '"set":"%s","geometry":[%d,%d],"dips":{"DSW1":%d,"DSW2":%d},' ..
    '"sound_enabled":true,"input_role":"consumer","raw_frame_format":"P6-RGB24",' ..
    '"epoch":"accepted-write:21000e:low-byte:data-bit7","first_complete_token":1,' ..
    '"first_comparable_token":%d,"warmup_excluded_tokens":%s,' ..
    '"capture_start_token":%d,' ..
    '"startup_mode":"%s","catchup_target":%d,' ..
    '"frame_boundary":"MAME register_frame_done raw screen pixels after draw"}\n',
    setname, width, height, dsw1:read() & 0xff, dsw2:read() & 0xff,
    first_comparable_token, warmup_excluded_tokens, trace_start_frame,
    startup_mode, catchup_target)
atomic_write("reference_ready.json", ready, false)

ssv_lockstep_ve_tap = program:install_write_tap(
    0x21000e, 0x21000f, "ssv_lockstep_video_enable",
    function(offset, data, mask)
        if (mask & 0x00ff) ~= 0 and (data & 0x80) ~= 0 and not armed then
            print(string.format(
                "SSV_LOCKSTEP_BOOT_VIDEO_ENABLE screen_frame=%d to_frame_zero=%.12f frame_period=%.12f pc=%08x watchdog_reads=%d",
                tonumber(screen:frame_number()), screen:time_until_pos(0, 0),
                screen.frame_period, cpu_pc(), boot_watchdog_reads))
            armed = true
        end
    end)

-- Boot transactions precede protocol frame zero and are intentionally absent
-- from the normal high-volume trace.  Keep this tiny source-backed census so a
-- long RAM self-test can distinguish "the game never kicked its watchdog"
-- from "RTL reached the same kick too late" without buffering millions of RAM
-- events or perturbing the frame barrier.
ssv_lockstep_boot_watchdog_tap = program:install_read_tap(
    0x210000, 0x210001, "ssv_lockstep_boot_watchdog",
    function(offset, data, mask)
        if not armed and (mask & 0xffff) ~= 0 then
            boot_watchdog_reads = boot_watchdog_reads + 1
            if boot_watchdog_reads <= 8 then
                print(string.format(
                    "SSV_LOCKSTEP_BOOT_WATCHDOG_READ count=%d screen_frame=%d pc=%08x mask=%04x",
                    boot_watchdog_reads, tonumber(screen:frame_number()),
                    cpu_pc(), mask & 0xffff))
            end
        end
    end)

emu.register_frame_done(function()
    if stopped or not armed then return end
    -- The callback also runs for host redraws while emulation is paused.
    -- screen.frame_number advances only for a newly emulated frame, making it
    -- the causal boundary for a single-step release.
    local screen_frame = tonumber(screen:frame_number())
    if screen_frame == last_screen_frame then return end
    last_screen_frame = screen_frame
    if frame >= trace_start_frame then
        capture_ppm(frame)
        capture_index_frame(frame)
        capture_state(frame)
        flush_trace()
    end
    captured = frame
    step_pending = false
    atomic_write("reference_frame.txt", tostring(frame) .. "\n", false)
    print(string.format("SSV_LOCKSTEP_REFERENCE_FRAME frame=%d", frame))
    frame = frame + 1
    emu.pause()
end)

emu.register_periodic(function()
    if stopped then return end
    if exists("STOP.txt") then
        stop_machine("session stop")
        return
    end
    if captured >= 0 and manager.machine.paused then
        local released = read_integer("release_frame.txt")
        if released and released >= captured then
            if not step_pending then
                apply_inputs(captured + 1)
                step_pending = true
            end
            -- Resume normally and let the next distinct screen.frame_number
            -- callback pause again. emu.step() re-pauses before frame_done on
            -- this MAME build and can yield only a redraw of the old surface.
            -- Retry unpause while the machine still reports paused: a single
            -- lost/deferred unpause used to strand a session forever because
            -- step_pending then suppressed every subsequent periodic retry.
            emu.unpause()
        end
    end
end)

emu.add_machine_stop_notifier(function()
    stopped = true
end)

print(string.format("SSV_LOCKSTEP_REFERENCE_READY set=%s geometry=%dx%d", setname, width, height))
