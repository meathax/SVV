-- SPDX-License-Identifier: GPL-3.0-or-later
-- Capture SSV CPU accesses to the ES5506 host register window.
--
-- Usage:
--   mame dynagear -autoboot_script tools/mame-capture-es5506.lua \
--        -seconds_to_run 30 -video none -sound none -nothrottle

local maincpu = manager.machine.devices[":maincpu"]
assert(maincpu, "SSV :maincpu device was not found")

local program = maincpu.spaces["program"]
assert(program, "SSV :maincpu program address space was not found")

local sequence = 0

-- Keep the tap alive for the full emulation session.  MAME removes a tap when
-- its Lua object is collected.
ssv_es5506_write_tap = program:install_write_tap(
    0x300000,
    0x30007f,
    "ssv_es5506_write",
    function(offset, data, mask)
        sequence = sequence + 1
        print(string.format(
            "ES5506_WRITE %08d addr=%08x data=%08x mask=%08x",
            sequence,
            offset,
            data,
            mask))
        return data
    end)

ssv_es5506_read_tap = program:install_read_tap(
    0x300000,
    0x30007f,
    "ssv_es5506_read",
    function(offset, data, mask)
        print(string.format(
            "ES5506_READ  %08d addr=%08x data=%08x mask=%08x",
            sequence,
            offset,
            data,
            mask))
        return data
    end)

print("ES5506_TRACE_READY")
