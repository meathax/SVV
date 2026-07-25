-- SPDX-License-Identifier: GPL-3.0-or-later
-- Capture per-frame SSV RGB (+ palette-index proxy) CRC32 for Dyna Gear.
-- Arms on lockout/video_enable write to $21000E bit7, matching RTL VE.
-- Geometry: 336x240.

local WIDTH = 336
local HEIGHT = 240
local output_path = "sim_output/diff/mame_attract_idle_frames.crc"
local max_frames = 120

local screen = manager.machine.screens[":screen"]
assert(screen, "SSV :screen was not found")
local maincpu = manager.machine.devices[":maincpu"]
assert(maincpu, "SSV :maincpu was not found")
local program = maincpu.spaces["program"]
assert(program, "program space missing")

local output = assert(io.open(output_path, "w"))
output:setvbuf("line")

local frame_count = 0
local armed = false
local crc_table = {}

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

emu.register_frame_done(function()
    if manager.machine.paused or not armed then
        return
    end
    if frame_count >= max_frames then
        output:close()
        print(string.format("SSV_FRAME_CRC_DONE frames=%d path=%s", frame_count, output_path))
        manager.machine:exit()
        return
    end
    if frame_count == 0 then
        print(string.format("SSV_FRAME_CRC_ARMED path=%s", output_path))
    end
    capture_frame()
end)

print(string.format(
    "SSV_FRAME_CRC_READY %dx%d max_frames=%d output=%s",
    WIDTH, HEIGHT, max_frames, output_path))
