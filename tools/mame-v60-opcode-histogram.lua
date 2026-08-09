-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- MAME Lua harness: V60 executed-opcode histogram for Dyna Gear (ssv.cpp).
--
-- Purpose
-- -------
-- The MiSTer SSV core's `s32_v60` is the dominant area consumer.  Four V60
-- instruction groups are only partially implemented in RTL:
--
--   0x59  decimal (BCD)      0x5B  bit string
--   0x5D  bit field          0x5C / 0x5F  floating point
--
-- Before any of them can be parameter-gated out for area, we need dynamic
-- evidence about whether Dyna Gear ever executes them.  This script records,
-- for every instruction the V60 actually retires, the primary opcode byte at
-- PC (and, for the 0x58..0x5F two-byte groups, the sub-opcode byte at PC+1).
--
-- Method
-- ------
-- MAME 0.285 exposes no `set_instruction_hook`, so we install a read tap over
-- the program ROM window (0xf00000-0xffffff) and keep only the taps whose
-- address equals the CPU's current PC.  In MAME's V60 core `PC` is updated to
-- the instruction start before the opcode fetch, so `tap_address == PC` is
-- true exactly for the opcode-fetch byte and false for every operand byte and
-- every data read.  The program space is 16-bit little-endian, so the tap
-- offset is the word address and the byte lane is selected by the mask.
--
-- Caveat, stated up front: consecutive taps at the same PC are collapsed
-- (`last_pc`) to avoid double counting prefetch re-reads.  A one-instruction
-- self-loop therefore counts once per entry rather than once per iteration.
-- This affects instruction *counts* only, never the presence/absence answer
-- that this script exists to produce.
--
-- Environment variables
-- ---------------------
--   V60_OUT          output report path (default sim_output/mame/v60_opcodes.txt)
--   V60_PROGRESS     progress/coverage-curve log path
--   V60_SNAP_EVERY   emulated seconds between screenshots (0 = off)
--   V60_SEED         input-bot PRNG seed (default 1)
--   V60_PRESET       run profile, one of:
--                      play_easy  - Free Play / Easy / 4 lives / 4 hearts,
--                                   1P bot, Start mashed so it always
--                                   continues.  Maximises stage depth.
--                      play_2p    - as play_easy but P2 also joins, covering
--                                   the two-player code paths.
--                      gameover   - Hardest / 1 life / no Free Play and only
--                                   two coins at the start, so the run
--                                   actually reaches GAME OVER, high-score
--                                   name entry and the attract loop.
--                      idle       - no input at all; attract mode only.
--                      service    - Test switch held, service/diagnostic menu.
--   V60_REPORT_EVERY emulated seconds between incremental report dumps
--   V60_PCLIST       optional path; on exit, writes every distinct executed
--                    instruction address (one hex value per line)
--
-- Reproduce with (see docs/V60_OPCODE_HITLIST.md):
--   mame dynagear -rompath <dir> -video none -sound none -nothrottle \
--        -seconds_to_run <N> -autoboot_script tools/mame-v60-opcode-histogram.lua

local out_path      = os.getenv("V60_OUT")      or "sim_output/mame/v60_opcodes.txt"
local prog_path     = os.getenv("V60_PROGRESS") or "sim_output/mame/v60_progress.txt"
local snap_every    = tonumber(os.getenv("V60_SNAP_EVERY")) or 0
local seed          = tonumber(os.getenv("V60_SEED")) or 1
local preset        = os.getenv("V60_PRESET") or "play_easy"
local report_every  = tonumber(os.getenv("V60_REPORT_EVERY")) or 60

local ROM_BASE = 0xf00000
local ROM_END  = 0xffffff

local cpu     = assert(manager.machine.devices[":maincpu"], "maincpu missing")
local program = assert(cpu.spaces["program"], "program space missing")
local pcstate = assert(cpu.state["PC"], "PC state entry missing")

----------------------------------------------------------------------------
-- Program ROM shadow.  Read through machine.memory.regions so that fetching
-- the sub-opcode byte never re-enters the address space (and therefore never
-- re-enters our own tap).
----------------------------------------------------------------------------
local rom_region = nil
local rom_region_name = nil
for name, region in pairs(manager.machine.memory.regions) do
    if region.size >= 0x100000 and (name:find("maincpu") or name:find("user1")) then
        rom_region = region
        rom_region_name = name
        break
    end
end

----------------------------------------------------------------------------
-- Positive control.  A detector that reports "never executed" is worthless
-- until it has been shown to fire when the opcode IS executed.  V60_INJECT
-- takes "addr:op:sub" (hex) and patches the loaded program ROM image so the
-- instruction at `addr` becomes the two-byte group opcode `op`/`sub`.  The
-- game will usually crash immediately afterwards - that is fine, the point is
-- only that the histogram records the hit.
--
--   V60_INJECT=f10130:59:00  -> expect "GROUP 59  EXECUTED"
--
-- Never set this for an evidence run.
local inject = os.getenv("V60_INJECT")

local function rom_byte(addr)
    if not rom_region then return -1 end
    local off = addr - ROM_BASE
    if off < 0 or off >= rom_region.size then return -1 end
    return rom_region:read_u8(off)
end

if inject then
    local a, o, s = inject:match("^(%x+):(%x+):(%x+)$")
    assert(a, "V60_INJECT must be addr:op:sub in hex")
    a, o, s = tonumber(a, 16), tonumber(o, 16), tonumber(s, 16)
    assert(rom_region, "no program ROM region to patch")
    rom_region:write_u8(a - ROM_BASE, o)
    rom_region:write_u8(a - ROM_BASE + 1, s)
    print(string.format("V60_INJECT patched %06x <- %02x %02x", a, o, s))
end

----------------------------------------------------------------------------
-- Accumulators
----------------------------------------------------------------------------
local hist        = {}   -- opcode byte -> retire count
local first_pc    = {}   -- opcode byte -> first PC seen
local sites       = {}   -- opcode byte -> { [pc] = count }  (0x58..0x5F only)
local subops      = {}   -- opcode byte -> { [subop] = count } (0x58..0x5F only)
local seen_pc     = {}   -- pc -> true  (distinct instruction addresses)
local distinct_pc = 0
local total_ops   = 0
local last_pc     = -1

local TRACKED = {}       -- opcodes we record per-site detail for
for op = 0x58, 0x5F do TRACKED[op] = true end

----------------------------------------------------------------------------
-- Opcode-fetch tap
----------------------------------------------------------------------------
-- NOTE: this MUST be a global.  The passthrough handler returned by
-- install_read_tap is removed when its Lua wrapper is collected, and a local
-- in the main chunk becomes garbage as soon as the chunk returns.  A silently
-- collected tap looks exactly like "the game stopped executing new code".
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
        hist[b] = (hist[b] or 0) + 1
        if not seen_pc[pc] then
            seen_pc[pc] = true
            distinct_pc = distinct_pc + 1
        end
        if first_pc[b] == nil then first_pc[b] = pc end
        if TRACKED[b] then
            local s = sites[b]
            if not s then s = {}; sites[b] = s end
            s[pc] = (s[pc] or 0) + 1
            local sub = rom_byte(pc + 1)
            local t = subops[b]
            if not t then t = {}; subops[b] = t end
            t[sub] = (t[sub] or 0) + 1
        end
        return data
    end)

----------------------------------------------------------------------------
-- DIP switches: make the bot's life as long as possible.
----------------------------------------------------------------------------
local function set_dip(port, field, value)
    local p = manager.machine.ioport.ports[port]
    if not p then return false end
    local f = p.fields[field]
    if not f then return false end
    local ok = pcall(function() f.user_value = value end)
    return ok
end

if preset == "play_easy" or preset == "play_2p" or preset == "play_rush" then
    set_dip(":DSW2", "Free Play",  0)    -- On
    set_dip(":DSW2", "Difficulty", 8)    -- Easy
    set_dip(":DSW2", "Lives",      0)    -- 4
    set_dip(":DSW2", "Health",     128)  -- 4 Hearts
    set_dip(":DSW2", "Demo Sounds", 0)   -- On (keeps the sound path exercised)
elseif preset == "gameover" then
    -- Free Play OFF and only two coins, so credits genuinely run out and the
    -- run reaches GAME OVER / high-score name entry / the attract loop.
    -- Everything else stays generous so the score gets as high as possible
    -- before that happens - name entry is only reachable above the table's
    -- lowest entry.
    set_dip(":DSW2", "Free Play",  64)   -- Off
    set_dip(":DSW2", "Difficulty", 8)    -- Easy
    set_dip(":DSW2", "Lives",      0)    -- 4
    set_dip(":DSW2", "Health",     128)  -- 4 Hearts
    set_dip(":DSW2", "Demo Sounds", 0)
end

----------------------------------------------------------------------------
-- Deterministic input bot
----------------------------------------------------------------------------
local P1     = manager.machine.ioport.ports[":P1"]
local P2     = manager.machine.ioport.ports[":P2"]
local SYSTEM = manager.machine.ioport.ports[":SYSTEM"]

local F = {
    up     = P1.fields["P1 Up"],
    down   = P1.fields["P1 Down"],
    left   = P1.fields["P1 Left"],
    right  = P1.fields["P1 Right"],
    b1     = P1.fields["P1 Button 1"],
    b2     = P1.fields["P1 Button 2"],
    b3     = P1.fields["P1 Button 3"],
    start1 = P1.fields["1 Player Start"],
    start2 = P2.fields["2 Players Start"],
    coin1  = SYSTEM.fields["Coin 1"],
    coin2  = SYSTEM.fields["Coin 2"],
    svc    = SYSTEM.fields["Test"],
    p2b1     = P2.fields["P2 Button 1"],
    p2b2     = P2.fields["P2 Button 2"],
    p2right  = P2.fields["P2 Right"],
}

-- Small deterministic LCG (Numerical Recipes constants), so an identical
-- V60_SEED reproduces the identical input stream.
local rng_state = seed & 0xffffffff
local function rnd(n)
    rng_state = (rng_state * 1664525 + 1013904223) & 0xffffffff
    return (rng_state >> 16) % n
end

local frame = 0
local dir_hold, dir_left, dir_vert = 0, false, 0

local function pulse(f, lo, hi)
    if f then f:set_value((frame % hi) < lo and 1 or 0) end
end

local function apply_inputs()
    for _, f in pairs(F) do f:set_value(0) end

    if preset == "idle" then return end
    if preset == "service" then
        -- Hold Test for the whole run; mash Service/Start/buttons so the
        -- diagnostic menu is walked rather than sitting on page one.
        F.svc:set_value(1)
        if (frame % 90) < 6 then F.start1:set_value(1) end
        if (frame % 47) < 4 then F.b1:set_value(1) end
        if (frame % 73) < 4 then F.down:set_value(1) end
        if (frame % 151) < 4 then F.right:set_value(1) end
        return
    end

    if preset == "gameover" then
        -- Only two coins, both in the first second, so credits genuinely run
        -- out and the run reaches GAME OVER / name entry / attract.
        if frame < 8 or (frame >= 40 and frame < 48) then F.coin1:set_value(1) end
    else
        -- Credits: coin every 4 s regardless of Free Play (harmless, and
        -- covers the case where the Free Play DIP write did not take).
        if (frame % 240) < 4 then F.coin1:set_value(1) end
    end

    -- Start: mashed early (title / mode select), then a slow cadence so a
    -- game-over or continue prompt is always answered.  Kept slow during
    -- play in case Start is wired to a pause.
    if frame < 1800 then
        if (frame % 60) < 5 then F.start1:set_value(1) end
    else
        if (frame % 420) < 5 then F.start1:set_value(1) end
    end
    if preset == "play_2p" then
        if (frame % 137) < 5 then F.start2:set_value(1) end
        if (frame % 11) < 5 then F.p2b1:set_value(1) end
        if (frame % 53) < 6 then F.p2right:set_value(1) end
        if (frame % 89) < 5 then F.p2b2:set_value(1) end
    end

    -- Attack: mashed continuously.
    if (frame % 6) < 3 then F.b1:set_value(1) end
    -- Jump / special: random short taps.
    if preset == "play_rush" then
        if (frame % 19) < 4 then F.b2:set_value(1) end
        if (frame % 61) < 3 then F.b3:set_value(1) end
    else
        if (frame % 37) < 4 then F.b2:set_value(1) end
        if (frame % 211) < 3 then F.b3:set_value(1) end
    end

    -- Movement: random walk biased right, re-rolled every 30-90 frames.
    -- play_rush is strongly forward-biased: the stage has a 99-unit timer and
    -- a 25%-left random walk was observed to time out before reaching the
    -- stage-1 boss, so that variant almost never lets go of Right and jumps
    -- much more often to clear obstacles.
    if dir_hold <= 0 then
        if preset == "play_rush" then
            dir_hold = 20 + rnd(40)
            dir_left = rnd(100) < 6
            dir_vert = rnd(12)
        else
            dir_hold = 30 + rnd(60)
            dir_left = rnd(100) < 25
            dir_vert = rnd(6)      -- 0/1 up, 2 down, else neutral
        end
    end
    dir_hold = dir_hold - 1
    if dir_left then F.left:set_value(1) else F.right:set_value(1) end
    if dir_vert <= 1 then F.up:set_value(1)
    elseif dir_vert == 2 then F.down:set_value(1) end
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

local function write_report(final)
    local f = assert(io.open(out_path, "w"))
    f:write("# V60 executed-opcode histogram - Dyna Gear (MAME)\n")
    f:write(string.format("# mame_version=%s\n", emu.app_version and emu.app_version() or "unknown"))
    f:write(string.format("# rom_region=%s\n", tostring(rom_region_name)))
    f:write(string.format("# seed=%d preset=%s\n", seed, preset))
    f:write(string.format("# emulated_frames=%d\n", frame))
    f:write(string.format("# retired_instructions=%d\n", total_ops))
    f:write(string.format("# distinct_instruction_addresses=%d\n", distinct_pc))
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
    -- Optional: the full set of instruction addresses actually executed.
    -- tools/scan-v60-opcode-sites.py consumes this to mark which static
    -- candidate sites were reached.
    -- Written on every dump, not only the final one: a run that is killed
    -- before its exit notifier still leaves a usable list.
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

----------------------------------------------------------------------------
-- Screenshots.  `video:snapshot()` writes nothing under `-video none`, so dump
-- the screen bitmap directly the way tools/mame-capture-ssv-frames.lua does.
----------------------------------------------------------------------------
local SNAP_W, SNAP_H = 336, 240
local snap_prefix = os.getenv("V60_SNAP_PREFIX") or "sim_output/mame/snap/shot"
local snap_screen = manager.machine.screens[":screen"]

local function write_ppm(f)
    if not snap_screen then return end
    local path = string.format("%s_f%06d.ppm", snap_prefix, f)
    local fh = io.open(path, "wb")
    if not fh then return end
    fh:write(string.format("P6\n%d %d\n255\n", SNAP_W, SNAP_H))
    for y = 0, SNAP_H - 1 do
        local row = {}
        for x = 0, SNAP_W - 1 do
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
            "PROGRESS frame=%d sec=%.1f ops=%d distinct_pc=%d opcodes=%d\n",
            frame, frame / 60.0, total_ops, distinct_pc,
            #sorted_keys(hist)))
        write_report(false)
    end
end)

emu.add_machine_stop_notifier(function()
    write_report(true)
    progress:write(string.format(
        "FINAL frame=%d sec=%.1f ops=%d distinct_pc=%d opcodes=%d\n",
        frame, frame / 60.0, total_ops, distinct_pc, #sorted_keys(hist)))
    progress:close()
    print(string.format(
        "V60_OPCODE_DONE frames=%d ops=%d distinct_pc=%d out=%s",
        frame, total_ops, distinct_pc, out_path))
end)

print(string.format(
    "V60_OPCODE_READY out=%s seed=%d preset=%s rom_region=%s",
    out_path, seed, preset, tostring(rom_region_name)))
