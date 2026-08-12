-- MiSTer FPGA Ultimate Autopilot v5.1 MAME capture adapter template.
--
-- This is not golden until every AUTO below is replaced from the pinned MAME source
-- and docs/OBSERVABILITY.json is set strict=true for the emitted domain.

local trace_path = os.getenv("MISTER_TRACE_OUT")
if not trace_path or trace_path == "" then
    error("MISTER_TRACE_OUT is required")
end

local trace = assert(io.open(trace_path, "w"))
local machine = manager.machine

-- AUTO: exact device tag and address space.
local device_tag = ":maincpu"
local cpu = machine.devices[device_tag]
assert(cpu, "MAME device not found: " .. device_tag)
local space = cpu.spaces["program"]
assert(space, "program address space is unavailable for " .. device_tag)

local seq = { mainbus = 0 }
local taps = {}
local trace_closed = false

local function json_escape(value)
    value = tostring(value)
    value = value:gsub("\\", "\\\\")
    value = value:gsub('"', '\\"')
    value = value:gsub("\n", "\\n")
    value = value:gsub("\r", "\\r")
    return value
end

local function emit(domain, event, phase, rw, address, data, byte_enable)
    local n = seq[domain] or 0
    -- Numeric values are emitted as decimal to avoid Lua JSON/library dependencies.
    local line = string.format(
        '{"domain":"%s","seq":%d,"event":"%s","phase":"%s","rw":"%s",' ..
        '"address":%u,"data":%u,"byte_enable":%u}\n',
        json_escape(domain), n, json_escape(event), json_escape(phase), json_escape(rw),
        address, data, byte_enable
    )
    trace:write(line)
    assert(trace:flush(), "trace event flush failed")
    seq[domain] = n + 1
end

local function counts_json()
    local fields = {}
    for domain, count in pairs(seq) do
        fields[#fields + 1] = string.format('"%s":%d', json_escape(domain), count)
    end
    table.sort(fields)
    return "{" .. table.concat(fields, ",") .. "}"
end

local function emit_barrier(name, phase)
    trace:write(string.format(
        '{"record":"barrier","name":"%s","phase":"%s","counts":%s}\n',
        json_escape(name), json_escape(phase or "completed"), counts_json()))
    assert(trace:flush(), "trace barrier flush failed")
end

local function close_trace(reason)
    if trace_closed then return end
    trace:write(string.format(
        '{"record":"receipt","reason":"%s","complete":true,' ..
        '"dropped":0,"counts":%s}\n',
        json_escape(reason or "machine_stop"), counts_json()))
    assert(trace:flush(), "trace receipt flush failed")
    trace:close()
    trace_closed = true
end

-- AUTO:
-- - address range
-- - tap callback semantics for the pinned MAME version
-- - address unit (byte/word)
-- - data width
-- - mask-to-byte-enable conversion
-- - whether this hook observes request, accepted or completed transfer
-- - side effects and debugger/access suppression
--
-- Keep each returned tap object alive in `taps`.
--
-- Example shape only:
--
-- taps[#taps + 1] = space:install_read_tap(
--     0x000000, 0xffffff, "mister-mainbus-read",
--     function(offset, data, mask)
--         local byte_enable = AUTO_CONVERT_MASK(mask)
--         emit("mainbus", "bus", "completed", "R", offset, data, byte_enable)
--         return data
--     end
-- )
--
-- taps[#taps + 1] = space:install_write_tap(
--     0x000000, 0xffffff, "mister-mainbus-write",
--     function(offset, data, mask)
--         local byte_enable = AUTO_CONVERT_MASK(mask)
--         emit("mainbus", "bus", "completed", "W", offset, data, byte_enable)
--         return data
--     end
-- )

local input_path = os.getenv("MISTER_INPUT_FILE")
-- AUTO: parse and replay the v4 semantic input JSONL. Do not translate raw MAME cycles
-- into an allegedly shared timebase. Prefer canonical event or proven video-position anchors.

emu.register_machine_stop(function()
    emit_barrier("machine_stop", "completed")
    close_trace("machine_stop")
end)

print("MiSTer FPGA capture template loaded. It intentionally emits nothing until board hooks are wired.")
