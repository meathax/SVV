-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- MAME Lua harness: V60 executed-opcode histogram for ANY ssv.cpp set.
--
-- Generalisation of tools/mame-v60-opcode-histogram.lua, which hardcoded
-- Dyna Gear's program-ROM window (0xf00000) and DIP field names.  The SSV
-- core is now universal (one RBF, MRA-selected game), so a V60 instruction
-- group that Dyna Gear never executes may still be executed by Vasara,
-- Storm Blade, Twin Eagle II, ... and gating it away on Dyna Gear evidence
-- alone would hang those games on hardware.
--
-- What is generalised
-- -------------------
-- * Program-ROM window.  ssv_map() maps `map(rom, 0xffffff).rom().region(
--   "maincpu", 0)`, so the base is exactly `0x1000000 - maincpu_region.size`.
--   Observed: dynagear 0xf00000 (1 MiB), cairblad/twineag2/ultrax 0xe00000
--   (2 MiB), vasara/vasara2/drifto94/stmblade 0xc00000 (4 MiB).
--   This is DERIVED, not assumed, and then VERIFIED (see below).
-- * DIP switches.  Set by (field name, setting name) lookup through
--   field.settings, so "Difficulty -> Easy" works whichever raw value the
--   set happens to use, and silently no-ops on a set that lacks the field.
-- * Inputs.  Fields are looked up by name across every port, so a set with
--   no Test switch or no ADD_BUTTONS just gets fewer inputs driven.
-- * Screen geometry for snapshots comes from the screen device.
--
-- Integrity check (this is the load-bearing part)
-- ----------------------------------------------
-- A wrong ROM base would make the tap fire on nothing and produce a
-- beautiful, entirely false "never executed" answer.  Every recorded opcode
-- byte is therefore cross-checked against the same byte read straight out of
-- the ROM region at `pc - base`.  Any disagreement increments `mismatches`,
-- which is printed in the report header.  A run with mismatches > 0, or with
-- retired_instructions == 0, MUST be discarded.
--
-- The tap-vs-PC method, the deliberately-global tap handle (a local one is
-- garbage collected and silently stops recording), and the flat ~8-cycle
-- V60 instruction cost that makes counts a scale indicator rather than a
-- profile are all inherited from the single-set script; see
-- docs/V60_OPCODE_HITLIST.md for the derivation and the positive control.
--
-- Environment variables
--   V60_OUT          report path
--   V60_PROGRESS     progress/coverage-curve path
--   V60_PCLIST       distinct executed instruction addresses, one hex/line
--   V60_SEED         input-bot PRNG seed (default 1)
--   V60_PRESET       play | play_2p | idle | service
--   V60_REPORT_EVERY emulated seconds between incremental dumps (default 30)
--   V60_SNAP_EVERY   emulated seconds between PPM screenshots (0 = off)
--   V60_SNAP_PREFIX  screenshot path prefix
--   V60_INJECT       addr:op:sub (hex) positive control - never for evidence

local out_path     = os.getenv("V60_OUT")      or "sim_output/mame/v60_opcodes.txt"
local prog_path    = os.getenv("V60_PROGRESS") or "sim_output/mame/v60_progress.txt"
local snap_every   = tonumber(os.getenv("V60_SNAP_EVERY")) or 0
local seed         = tonumber(os.getenv("V60_SEED")) or 1
local preset       = os.getenv("V60_PRESET") or "play"
local report_every = tonumber(os.getenv("V60_REPORT_EVERY")) or 30

local setname = emu.romname and emu.romname() or "unknown"

local cpu     = assert(manager.machine.devices[":maincpu"], "maincpu missing")
local program = assert(cpu.spaces["program"], "program space missing")
local pcstate = assert(cpu.state["PC"], "PC state entry missing")

----------------------------------------------------------------------------
-- Program ROM region and derived window
----------------------------------------------------------------------------
local rom_region, rom_region_name
for name, region in pairs(manager.machine.memory.regions) do
    if name:find("maincpu") then
        rom_region, rom_region_name = region, name
        break
    end
end
assert(rom_region, "no maincpu ROM region")

local ROM_BASE = 0x1000000 - rom_region.size
local ROM_END  = 0xffffff

local function rom_byte(addr)
    local off = addr - ROM_BASE
    if off < 0 or off >= rom_region.size then return -1 end
    return rom_region:read_u8(off)
end

----------------------------------------------------------------------------
-- Positive control
----------------------------------------------------------------------------
local inject = os.getenv("V60_INJECT")
if inject then
    local a, o, s = inject:match("^(%x+):(%x+):(%x+)$")
    assert(a, "V60_INJECT must be addr:op:sub in hex")
    a, o, s = tonumber(a, 16), tonumber(o, 16), tonumber(s, 16)
    rom_region:write_u8(a - ROM_BASE, o)
    rom_region:write_u8(a - ROM_BASE + 1, s)
    print(string.format("V60_INJECT patched %06x <- %02x %02x", a, o, s))
end

----------------------------------------------------------------------------
-- Accumulators
----------------------------------------------------------------------------
local hist, first_pc, sites, subops = {}, {}, {}, {}
local seen_pc = {}
local distinct_pc, total_ops, mismatches = 0, 0, 0
local last_pc = -1

local TRACKED = {}
for op = 0x58, 0x5F do TRACKED[op] = true end

-- MUST be global: a local tap handle is collected and stops recording.
v60_opcode_tap = program:install_read_tap(ROM_BASE, ROM_END, "v60_opcode_fetch",
    function(off, data, mask)
        local pc = pcstate.value & 0xffffff
        if pc == last_pc then return data end
        local b
        if (pc & 1) == 0 then
            if off ~= pc or (mask & 0x00ff) == 0 then return data end
            b = data & 0xff
        else
            if off ~= (pc - 1) or (mask & 0xff00) == 0 then return data end
            b = (data >> 8) & 0xff
        end
        last_pc = pc
        total_ops = total_ops + 1
        -- Integrity: the byte the CPU fetched must equal the byte sitting at
        -- pc-ROM_BASE in the region.  If ROM_BASE were wrong this diverges.
        if rom_byte(pc) ~= b then mismatches = mismatches + 1 end
        hist[b] = (hist[b] or 0) + 1
        if not seen_pc[pc] then
            seen_pc[pc] = true
            distinct_pc = distinct_pc + 1
        end
        if first_pc[b] == nil then first_pc[b] = pc end
        if TRACKED[b] then
            local s = sites[b]
            local firsthit = (s == nil)
            if not s then s = {}; sites[b] = s end
            s[pc] = (s[pc] or 0) + 1
            local sub = rom_byte(pc + 1)
            local t = subops[b]
            if not t then t = {}; subops[b] = t end
            t[sub] = (t[sub] or 0) + 1
            -- Tripwire dump.  MAME's V60 core fatalerror()s on sub-opcodes and
            -- addressing modes it does not implement ("Unhandled 5D opcode at
            -- PC: ..."), and a fatalerror skips the machine-stop notifier, so
            -- the report would never be written and a REAL hit would look
            -- exactly like a detector blind spot.  Dump on the first hit of
            -- each group, straight from the tap, before control returns to the
            -- CPU core.  At most 8 extra dumps per run.
            if firsthit and write_report_now then write_report_now(b, pc) end
        end
        return data
    end)

----------------------------------------------------------------------------
-- Generic DIP handling: (field name, setting name) -> raw value
----------------------------------------------------------------------------
local dip_log = {}

local function set_dip(field_name, setting_name)
    for pname, port in pairs(manager.machine.ioport.ports) do
        local f = port.fields[field_name]
        if f then
            local ok, settings = pcall(function() return f.settings end)
            if ok and settings then
                for value, name in pairs(settings) do
                    if name == setting_name then
                        local applied = pcall(function() f.user_value = value end)
                        dip_log[#dip_log + 1] = string.format(
                            "%s.%s=%s(%d)%s", pname, field_name, setting_name,
                            value, applied and "" or " FAILED")
                        return applied
                    end
                end
            end
        end
    end
    return false
end

-- Highest numeric setting of a field (e.g. Lives -> the largest count).
local function set_dip_max_numeric(field_name)
    for pname, port in pairs(manager.machine.ioport.ports) do
        local f = port.fields[field_name]
        if f then
            local ok, settings = pcall(function() return f.settings end)
            if ok and settings then
                local best_v, best_n
                for value, name in pairs(settings) do
                    local n = tonumber(name)
                    if n and (best_n == nil or n > best_n) then
                        best_v, best_n = value, n
                    end
                end
                if best_v then
                    local applied = pcall(function() f.user_value = best_v end)
                    dip_log[#dip_log + 1] = string.format(
                        "%s.%s=%d(%d)%s", pname, field_name, best_n, best_v,
                        applied and "" or " FAILED")
                    return applied
                end
            end
        end
    end
    return false
end

if preset == "play" or preset == "play_2p" then
    set_dip("Free Play", "On")
    set_dip("Difficulty", "Easy")
    set_dip("Demo Sounds", "On")
    set_dip_max_numeric("Lives")
    set_dip_max_numeric("Health")
    set_dip_max_numeric("Bomber Stock")
    set_dip_max_numeric("Vasara Stock")
    set_dip("Secret Character", "On")
    set_dip("English Subtitles", "On")
    set_dip("Rapid Fire", "On")
elseif preset == "service" then
    set_dip("Service Mode", "On")
end

----------------------------------------------------------------------------
-- Generic input lookup: find a named field in whichever port owns it.
----------------------------------------------------------------------------
local function field(name)
    for _, port in pairs(manager.machine.ioport.ports) do
        local f = port.fields[name]
        if f then return f end
    end
    return nil
end

local F = {
    up      = field("P1 Up"),
    down    = field("P1 Down"),
    left    = field("P1 Left"),
    right   = field("P1 Right"),
    b1      = field("P1 Button 1"),
    b2      = field("P1 Button 2"),
    b3      = field("P1 Button 3"),
    start1  = field("1 Player Start"),
    start2  = field("2 Players Start"),
    coin1   = field("Coin 1"),
    coin2   = field("Coin 2"),
    svc     = field("Test"),
    svc1    = field("Service 1"),
    p2b1    = field("P2 Button 1"),
    p2b2    = field("P2 Button 2"),
    p2up    = field("P2 Up"),
    p2right = field("P2 Right"),
}

local rng_state = seed & 0xffffffff
local function rnd(n)
    rng_state = (rng_state * 1664525 + 1013904223) & 0xffffffff
    return (rng_state >> 16) % n
end

local frame = 0
local dir_hold, dir_h, dir_v = 0, 0, 0

local function apply_inputs()
    for _, f in pairs(F) do f:set_value(0) end
    if preset == "idle" then return end

    if preset == "service" then
        if F.svc then F.svc:set_value(1) end
        if (frame % 90) < 6 and F.start1 then F.start1:set_value(1) end
        if (frame % 47) < 4 and F.b1 then F.b1:set_value(1) end
        if (frame % 73) < 4 and F.down then F.down:set_value(1) end
        if (frame % 151) < 4 and F.right then F.right:set_value(1) end
        return
    end

    -- Credits.  Coin often (2 s) so a shmup bot can always continue; Free
    -- Play is set too but not every set has the DIP.
    if (frame % 120) < 4 and F.coin1 then F.coin1:set_value(1) end

    -- Start: mashed through title/mode-select, then a steady cadence so
    -- continue and game-over prompts are always answered.
    if frame < 1800 then
        if (frame % 60) < 5 and F.start1 then F.start1:set_value(1) end
    else
        if (frame % 180) < 5 and F.start1 then F.start1:set_value(1) end
    end
    if preset == "play_2p" then
        if (frame % 137) < 5 and F.start2 then F.start2:set_value(1) end
        if (frame % 11) < 5 and F.p2b1 then F.p2b1:set_value(1) end
        if (frame % 53) < 6 and F.p2up then F.p2up:set_value(1) end
        if (frame % 89) < 5 and F.p2b2 then F.p2b2:set_value(1) end
    end

    -- Fire held down almost continuously (shmups), plus bomb/special taps.
    if (frame % 4) < 3 and F.b1 then F.b1:set_value(1) end
    if (frame % 37) < 4 and F.b2 then F.b2:set_value(1) end
    if (frame % 211) < 3 and F.b3 then F.b3:set_value(1) end

    -- Movement: random walk.  These are mostly vertical shmups and Drift
    -- Out '94 is a racer, so bias forward (Up) rather than Right.
    if dir_hold <= 0 then
        dir_hold = 20 + rnd(50)
        dir_h = rnd(10)          -- 0-3 right, 4-7 left, else neutral
        dir_v = rnd(10)          -- 0-5 up, 6-7 down, else neutral
    end
    dir_hold = dir_hold - 1
    if dir_h < 4 and F.right then F.right:set_value(1)
    elseif dir_h < 8 and F.left then F.left:set_value(1) end
    if dir_v < 6 and F.up then F.up:set_value(1)
    elseif dir_v < 8 and F.down then F.down:set_value(1) end
end

----------------------------------------------------------------------------
-- Reporting
----------------------------------------------------------------------------
local progress = assert(io.open(prog_path, "w"))
progress:setvbuf("line")

local function sorted_keys(t)
    local k = {}
    for key in pairs(t) do k[#k + 1] = key end
    table.sort(k)
    return k
end

-- Counted so a run whose reports were being dropped is self-evident rather
-- than looking like a quiet, well-behaved "never executed" result.
local write_failures = 0

local function write_report_inner(final)
    local f = io.open(out_path, "w")
    if not f then
        write_failures = write_failures + 1
        return
    end
    f:write("# V60 executed-opcode histogram (multi-set harness)\n")
    f:write(string.format("# setname=%s\n", setname))
    f:write(string.format("# mame_version=%s\n", emu.app_version and emu.app_version() or "unknown"))
    f:write(string.format("# rom_region=%s size=%x rom_base=%06x\n",
        tostring(rom_region_name), rom_region.size, ROM_BASE))
    f:write(string.format("# seed=%d preset=%s\n", seed, preset))
    f:write(string.format("# dips=%s\n", table.concat(dip_log, ",")))
    f:write(string.format("# emulated_frames=%d\n", frame))
    f:write(string.format("# retired_instructions=%d\n", total_ops))
    f:write(string.format("# distinct_instruction_addresses=%d\n", distinct_pc))
    f:write(string.format("# rom_base_mismatches=%d\n", mismatches))
    f:write(string.format("# final=%s\n", tostring(final)))
    f:write("#\n# opcode  count  first_pc  distinct_sites\n")
    for _, op in ipairs(sorted_keys(hist)) do
        local nsites = ""
        if sites[op] then
            local c = 0
            for _ in pairs(sites[op]) do c = c + 1 end
            nsites = tostring(c)
        end
        f:write(string.format("OP %02x %d %06x %s\n", op, hist[op],
            first_pc[op] or 0, nsites))
    end
    f:write("#\n# two-byte group detail (0x58..0x5F): opcode subop count\n")
    for op = 0x58, 0x5F do
        if subops[op] then
            for _, s in ipairs(sorted_keys(subops[op])) do
                f:write(string.format("SUBOP %02x %02x %d\n", op, s, subops[op][s]))
            end
        else
            f:write(string.format("# NOHIT %02x - never executed\n", op))
        end
    end
    local pclist = os.getenv("V60_PCLIST")
    if pclist then
        local pf = io.open(pclist, "w")
        if pf then
            for _, pc in ipairs(sorted_keys(seen_pc)) do
                pf:write(string.format("%06x\n", pc))
            end
            pf:close()
        end
    end
    f:write("#\n# sites for 0x58..0x5F (pc count)\n")
    for op = 0x58, 0x5F do
        if sites[op] then
            for _, pc in ipairs(sorted_keys(sites[op])) do
                f:write(string.format("SITE %02x %06x %d\n", op, pc, sites[op][pc]))
            end
        end
    end
    f:close()
end

-- Tolerant wrapper.  Under heavy parallelism on a Windows DrvFs mount an
-- io.open can fail; an uncaught error raised inside register_frame_done takes
-- the whole callback down, which silently stops BOTH the periodic reports and
-- the input bot.  A run then burns an hour going nowhere and its last report
-- looks like an ordinary, honest "never executed" result.  Never let report
-- I/O propagate an error; count the failures instead and publish the count.
local function write_report(final)
    local ok = pcall(write_report_inner, final)
    if not ok then write_failures = write_failures + 1 end
end

-- Global, so the tap closure (installed earlier in the file) can reach it.
-- Called on the first execution of each 0x58..0x5F group; also drops a
-- one-line marker file so a crashed run is still self-evidently a HIT.
function write_report_now(op, pc)
    write_report(false)
    local mk = io.open(out_path .. ".hit", "a")
    if mk then
        mk:write(string.format("HIT set=%s op=%02x pc=%06x sub=%02x frame=%d\n",
            setname, op, pc, rom_byte(pc + 1) & 0xff, frame))
        mk:close()
    end
    print(string.format("V60_GROUP_HIT set=%s op=%02x pc=%06x", setname, op, pc))
end

----------------------------------------------------------------------------
-- Screenshots (video none: dump the screen bitmap directly)
----------------------------------------------------------------------------
local snap_prefix = os.getenv("V60_SNAP_PREFIX") or "sim_output/mame/snap/shot"
local snap_screen = nil
for _, s in pairs(manager.machine.screens) do snap_screen = s break end

local function write_ppm(fr)
    if not snap_screen then return end
    local w, h = snap_screen.width, snap_screen.height
    local path = string.format("%s_f%06d.ppm", snap_prefix, fr)
    local fh = io.open(path, "wb")
    if not fh then return end
    fh:write(string.format("P6\n%d %d\n255\n", w, h))
    for y = 0, h - 1 do
        local row = {}
        for x = 0, w - 1 do
            local p = snap_screen:pixel(x, y)
            row[#row + 1] = string.char((p >> 16) & 0xff, (p >> 8) & 0xff, p & 0xff)
        end
        fh:write(table.concat(row))
    end
    fh:close()
end

local next_report = report_every * 60
local next_snap   = snap_every * 60

emu.register_frame_done(function()
    if manager.machine.paused then return end
    apply_inputs()
    frame = frame + 1
    if snap_every > 0 and frame >= next_snap then
        next_snap = next_snap + snap_every * 60
        write_ppm(frame)
    end
    if frame >= next_report then
        next_report = next_report + report_every * 60
        progress:write(string.format(
            "PROGRESS frame=%d sec=%.1f ops=%d distinct_pc=%d opcodes=%d mism=%d\n",
            frame, frame / 60.0, total_ops, distinct_pc,
            #sorted_keys(hist), mismatches))
        write_report(false)
    end
end)

emu.add_machine_stop_notifier(function()
    write_report(true)
    progress:write(string.format(
        "FINAL frame=%d sec=%.1f ops=%d distinct_pc=%d opcodes=%d mism=%d\n",
        frame, frame / 60.0, total_ops, distinct_pc,
        #sorted_keys(hist), mismatches))
    progress:close()
    print(string.format(
        "V60_OPCODE_DONE set=%s frames=%d ops=%d distinct_pc=%d mism=%d out=%s",
        setname, frame, total_ops, distinct_pc, mismatches, out_path))
end)

print(string.format(
    "V60_OPCODE_READY set=%s rom_base=%06x size=%x seed=%d preset=%s",
    setname, ROM_BASE, rom_region.size, seed, preset))
