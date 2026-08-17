-- SSV fallback main-bus capture adapter for pinned MAME 0.289.
-- The normal universal supported-set lane uses tools/mame-ssv-headless.lua because that
-- adapter also owns frame artifacts and journaled inputs. This file remains a
-- functional bus-only adapter for executor discovery and focused captures.

local trace_path = os.getenv("MISTER_TRACE_OUT")
if not trace_path or trace_path == "" then
    error("MISTER_TRACE_OUT is required")
end

local trace = assert(io.open(trace_path, "w"))
local machine = manager.machine

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

local function byte_enable(mask)
    local mask16 = mask & 0xffff
    return (((mask16 & 0x00ff) ~= 0) and 1 or 0) |
           (((mask16 & 0xff00) ~= 0) and 2 or 0)
end

emit_barrier("adapter_ready", "completed")
taps[#taps + 1] = space:install_read_tap(
    0x000000, 0xffffff, "mister-mainbus-read",
    function(offset, data, mask)
        local be = byte_enable(mask)
        local lane_mask = (((be & 1) ~= 0) and 0x00ff or 0) |
                          (((be & 2) ~= 0) and 0xff00 or 0)
        emit("mainbus", "bus", "completed", "R", offset & 0xfffffe,
             data & lane_mask & 0xffff, be)
    end
)
taps[#taps + 1] = space:install_write_tap(
    0x000000, 0xffffff, "mister-mainbus-write",
    function(offset, data, mask)
        local be = byte_enable(mask)
        local lane_mask = (((be & 1) ~= 0) and 0x00ff or 0) |
                          (((be & 2) ~= 0) and 0xff00 or 0)
        emit("mainbus", "bus", "completed", "W", offset & 0xfffffe,
             data & lane_mask & 0xffff, be)
    end
)

local input_path = os.getenv("MISTER_INPUT_FILE")
if input_path and input_path ~= "" then
    error("bus-only fallback does not own inputs; use tools/mame-ssv-headless.lua")
end

emu.add_machine_stop_notifier(function()
    emit_barrier("machine_stop", "completed")
    close_trace("machine_stop")
end)

print("SSV bus-only fallback capture loaded for MAME 0.289")
