-- SPDX-License-Identifier: GPL-3.0-or-later
-- Capture ordered 16-bit V60 program-space writes for SSV comparison.

local maincpu = manager.machine.devices[":maincpu"]
assert(maincpu, "SSV :maincpu device was not found")
local program = maincpu.spaces["program"]
assert(program, "SSV :maincpu program address space was not found")

local output_path = "sim_output/diff/mame_ssv_writes.trace"
local output = assert(io.open(output_path, "w"))
output:setvbuf("line")
local sequence = 0

ssv_write_tap = program:install_write_tap(
    0x000000,
    0x5fffff,
    "ssv_ordered_writes",
    function(offset, data, mask)
        sequence = sequence + 1
        output:write(string.format(
            "WRITE %08d %08x %04x %04x\n",
            sequence,
            offset,
            data & 0xffff,
            mask & 0xffff))
        return data
    end)

print(string.format(
    "SSV_WRITE_TRACE_READY width=%d endian=%s output=%s",
    program.data_width,
    program.endianness,
    output_path))
