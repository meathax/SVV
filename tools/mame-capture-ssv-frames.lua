-- SPDX-License-Identifier: GPL-3.0-or-later
-- Capture per-frame SSV RGB (+ palette-index proxy) CRC32 for Dyna Gear.
-- Arms on lockout/video_enable write to $21000E bit7, matching RTL VE.
-- Geometry: 336x240.

local WIDTH = 336
local HEIGHT = 240
local output_path = os.getenv("SSV_FRAME_OUTPUT") or
    "sim_output/diff/mame_attract_idle_frames.crc"
local state_path = os.getenv("SSV_STATE_OUTPUT") or
    "sim_output/diff/mame_attract_idle_states.crc"
local max_frames = tonumber(os.getenv("SSV_MAX_FRAMES")) or 120
local scenario = os.getenv("SSV_SCENARIO") or "attract_idle"
local ppm_prefix = os.getenv("SSV_PPM_PREFIX")
local es5506_path = os.getenv("SSV_ES5506_OUTPUT")
local ppm_frames = {}
for value in string.gmatch(os.getenv("SSV_PPM_FRAMES") or "", "[^,]+") do
    ppm_frames[tonumber(value)] = true
end

local screen = manager.machine.screens[":screen"]
assert(screen, "SSV :screen was not found")
local maincpu = manager.machine.devices[":maincpu"]
assert(maincpu, "SSV :maincpu was not found")
local program = maincpu.spaces["program"]
assert(program, "program space missing")
local p1 = manager.machine.ioport.ports[":P1"]
local system = manager.machine.ioport.ports[":SYSTEM"]
assert(p1 and system, "Dyna Gear input ports were not found")
local p1_up = assert(p1.fields["P1 Up"])
local p1_right = assert(p1.fields["P1 Right"])
local p1_button1 = assert(p1.fields["P1 Button 1"])
local p1_start = assert(p1.fields["1 Player Start"])
local coin1 = assert(system.fields["Coin 1"])

local output = assert(io.open(output_path, "w"))
output:setvbuf("line")
local state_output = assert(io.open(state_path, "w"))
state_output:setvbuf("line")
local es5506_output = nil
local es5506_sequence = 0
if es5506_path then
    es5506_output = assert(io.open(es5506_path, "w"))
    es5506_output:setvbuf("line")
end

local frame_count = 0
local armed = false
local crc_table = {}

if es5506_output then
    ssv_es5506_write_tap = program:install_write_tap(
        0x300000,
        0x30007f,
        "ssv_es5506_gameplay_write",
        function(offset, data, mask)
            es5506_sequence = es5506_sequence + 1
            es5506_output:write(string.format(
                "ES5506_WRITE %08d addr=%08x data=%08x mask=%08x\n",
                es5506_sequence, offset, data, mask))
            return data
        end)
    ssv_es5506_read_tap = program:install_read_tap(
        0x300000,
        0x30007f,
        "ssv_es5506_gameplay_read",
        function(offset, data, mask)
            es5506_output:write(string.format(
                "ES5506_READ  %08d addr=%08x data=%08x mask=%08x\n",
                es5506_sequence, offset, data, mask))
            return data
        end)
end

-- Per-game override for the coin/start frame window below. The hardcoded
-- 30-34 / 165-170 defaults are Dyna Gear-tuned (see file header) and land
-- before other games' coin-poll loops even start -- confirmed for vasara1
-- via docs/debug/vasara/GAMEPLAY_AND_SOUND.md: its own coin-accept polling
-- loop (SYSTEM port read at PC 0xF01046/0xF01094) does not begin until
-- ~frame 73, so any injection ending at or before frame 60 (including the
-- old 20-60 coin_start_probe hold) is structurally invisible to the game,
-- regardless of pulse duration or bit polarity -- both already-ruled-out
-- hypotheses in that journal. This does not change Dyna Gear's defaults.
local coin_frame_lo = tonumber(os.getenv("SSV_COIN_FRAME_LO")) or 30
local coin_frame_hi = tonumber(os.getenv("SSV_COIN_FRAME_HI")) or 34
local start_frame_lo = tonumber(os.getenv("SSV_START_FRAME_LO")) or 165
local start_frame_hi = tonumber(os.getenv("SSV_START_FRAME_HI")) or 170

local function apply_inputs(frame)
    coin1:set_value(0)
    p1_start:set_value(0)
    p1_button1:set_value(0)
    p1_right:set_value(0)
    p1_up:set_value(0)
    if scenario ~= "coin_start_p1" and
       scenario ~= "coin_start_p1_gameplay" then
        return
    end
    coin1:set_value((frame >= coin_frame_lo and frame < coin_frame_hi) and 1 or 0)
    p1_start:set_value(((frame >= start_frame_lo and frame < start_frame_hi) or
                        (frame >= 250 and frame < 255) or
                        (scenario == "coin_start_p1_gameplay" and
                         frame >= 480 and frame < 485)) and 1 or 0)
    p1_button1:set_value(((frame >= 255 and frame < 262) or
                          (frame >= 330 and frame < 360) or
                          (scenario == "coin_start_p1_gameplay" and
                           ((frame >= 420 and frame < 425) or
                            (frame >= 540 and frame < 545) or
                            (frame >= 840 and frame < 848) or
                            (frame >= 875 and frame < 883)))) and 1 or 0)
    p1_right:set_value(((frame >= 300 and frame < 330) or
                        (scenario == "coin_start_p1_gameplay" and
                         frame >= 820 and frame < 870)) and 1 or 0)
    p1_up:set_value(((frame >= 360 and frame < 390) or
                     (scenario == "coin_start_p1_gameplay" and
                      frame >= 890 and frame < 920)) and 1 or 0)
end

local function init_crc()
    for i = 0, 255 do
        local c = i
        for _ = 1, 8 do
            if (c & 1) ~= 0 then
                c = (c >> 1) ~ 0xEDB88320
            else
                c = c >> 1
            end
        end
        crc_table[i] = c
    end
end

local function crc32_update(crc, byte)
    return (crc >> 8) ~ crc_table[(crc ~ byte) & 0xFF]
end

local function crc16_words(base, count)
    local crc = 0xFFFFFFFF
    for index = 0, count - 1 do
        local value = program:read_u16(base + index * 2)
        crc = crc32_update(crc, value & 0xFF)
        crc = crc32_update(crc, (value >> 8) & 0xFF)
    end
    return ~crc & 0xFFFFFFFF
end

local function capture_state(frame)
    local list512 = crc16_words(0x100000, 512)
    local spr8k = crc16_words(0x100000, 8192)
    local scroll64 = crc16_words(0x1C0000, 64)
    local pal512 = crc16_words(0x140000, 1024)
    state_output:write(string.format(
        "STATE %u list512=%08x spr8k=%08x scroll64=%08x pal512=%08x\n",
        frame, list512, spr8k, scroll64, pal512))
end

init_crc()

ssv_ve_tap = program:install_write_tap(
    0x21000e,
    0x21000f,
    "ssv_video_enable_arm",
    function(offset, data, mask)
        if (data & 0x00c0) ~= 0 or (data & 0x80) ~= 0 then
            if (data & 0x80) ~= 0 then
                armed = true
            end
        end
        return data
    end)

local function capture_frame()
    local idx_crc = 0xFFFFFFFF
    local rgb_crc = 0xFFFFFFFF
    for y = 0, HEIGHT - 1 do
        for x = 0, WIDTH - 1 do
            local pix = screen:pixel(x, y)
            local r = (pix >> 16) & 0xFF
            local g = (pix >> 8) & 0xFF
            local b = pix & 0xFF
            -- SSV screen is RGB; index CRC uses 5:5:5 pack as a shared proxy
            -- until an indexed bitmap tap is available on both sides.
            local idx15 = ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3)
            idx_crc = crc32_update(idx_crc, idx15 & 0xFF)
            idx_crc = crc32_update(idx_crc, (idx15 >> 8) & 0x7F)
            rgb_crc = crc32_update(rgb_crc, r)
            rgb_crc = crc32_update(rgb_crc, g)
            rgb_crc = crc32_update(rgb_crc, b)
        end
    end
    idx_crc = ~idx_crc & 0xFFFFFFFF
    rgb_crc = ~rgb_crc & 0xFFFFFFFF
    output:write(string.format("FRAME %u %08x %08x\n", frame_count, idx_crc, rgb_crc))
    frame_count = frame_count + 1
end

local function capture_ppm(frame)
    if not ppm_prefix or not ppm_frames[frame] then
        return
    end
    local path = string.format("%s_f%04d.ppm", ppm_prefix, frame)
    local ppm = assert(io.open(path, "wb"))
    ppm:write(string.format("P6\n%d %d\n255\n", WIDTH, HEIGHT))
    for y = 0, HEIGHT - 1 do
        local row = {}
        for x = 0, WIDTH - 1 do
            local pix = screen:pixel(x, y)
            row[#row + 1] = string.char(
                (pix >> 16) & 0xFF,
                (pix >> 8) & 0xFF,
                pix & 0xFF)
        end
        ppm:write(table.concat(row))
    end
    ppm:close()
    print(string.format("SSV_FRAME_PPM frame=%d path=%s", frame, path))
end

emu.register_frame_done(function()
    if manager.machine.paused or not armed then
        return
    end
    if frame_count >= max_frames then
        output:close()
        state_output:close()
        if es5506_output then
            es5506_output:close()
        end
        print(string.format("SSV_FRAME_CRC_DONE frames=%d path=%s", frame_count, output_path))
        manager.machine:exit()
        return
    end
    if frame_count == 0 then
        print(string.format("SSV_FRAME_CRC_ARMED path=%s", output_path))
    end
    capture_ppm(frame_count)
    capture_state(frame_count)
    capture_frame()
    apply_inputs(frame_count)
end)

apply_inputs(0)

print(string.format(
    "SSV_FRAME_CRC_READY %dx%d max_frames=%d scenario=%s output=%s states=%s",
    WIDTH, HEIGHT, max_frames, scenario, output_path, state_path))
