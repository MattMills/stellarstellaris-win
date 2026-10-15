-- engine/slice.lua : a phase cut into pieces a frame can hold (docs/frame_timing.md).
--
-- The platform can run a phase as a coroutine with a deadline (sim/src/scheduler.rs:
-- Simulation::step_until). The engine calls slice.check(site) between its objects, and
-- slice.tick(site) in its loops over many small ones and in the script evaluator's own calls: past
-- the deadline they yield, and the platform resumes the phase where it stopped in a later frame.
-- Nothing else runs in the Lua state in between, so a phase sees the world as if it had run whole
-- (the 180-day comparison with the game's save gives the same counts). Without a deadline (a whole
-- tick, a worker, a tool) a check only keeps the record.
--
-- A check reads the platform's clock through the FFI (RUST.now_fn); a tick reads it every few
-- calls of its site, as many as take about TARGET seconds, and at every one near the deadline.
-- Neither yields where the coroutine cannot (in a sort's comparator, a gsub callback, a call from
-- Rust): coroutine.isyieldable() says so.
--
-- Each site keeps the longest stretch after it (a check) or call of it (a tick), fading: a check
-- also yields before a stretch that will not fit in what the frame has left but fits in a frame of
-- its own, and so does a phase's start (slice.begin).
--
-- The record (slice.report): the longest stretches between two checks by the pair of sites, and
-- the ones that crossed a frame's end (the platform gives it: Runtime::set_frame_end), with where
-- the longest of each ended (STELLAR_SLICE_TRACE=1). STELLAR_SLICE_PROFILE=1: LuaJIT's sampling
-- profiler in the long stretches; STELLAR_SLICE_GC=1: the heap and the collector's steps.

local ffi = require("ffi")

local slice = { yields = 0, waits = 0 }

-- (STELLAR_SLICE_GC=1: every weak table made from here on kept with where it was made, for
-- slice.gc_report)
local weak_tables = {}
if os.getenv("STELLAR_SLICE_GC") == "1" then
    local sm = setmetatable
    setmetatable = function(t, mt)
        if type(mt) == "table" and mt.__mode then
            local info = debug.getinfo(2, "Sl")
            weak_tables[#weak_tables + 1] = { t, info and (info.short_src .. ":" .. tostring(info.currentline)) or "?", mt.__mode }
        end
        return sm(t, mt)
    end
end

local now
if RUST and RUST.now_fn then
    now = ffi.cast("double (*)(void)", RUST.now_fn)
else
    now = os.clock
end
slice.now = now

local isyieldable = coroutine.isyieldable or function() return coroutine.running() ~= nil end
local yield = coroutine.yield

local deadline = math.huge
local frame_end = math.huge    -- the end of the frame the piece is in (later than its deadline)
local crossed = {}             -- "from > to" -> { n, max }: the stretches that crossed a frame's end
local piece_start = 0          -- when the frame's first piece began (the platform's set_deadline)
local last, last_site = now(), "start"
local last_ticked = false      -- whether the last check came from slice.tick
local passive = false          -- the VM stops the pieces; the checks only keep their record

-- the stretch that follows each site of slice.check, and the time of a call at each site of
-- slice.tick: the longest seen, fading (by DECAY at each shorter one), so that a check can yield
-- before a stretch that would not fit in what the piece has left (and run it in the next, from
-- its start)
local after, per_call = {}, {}
local DECAY = 0.97
-- slice.tick reads the clock every few calls of a site: as many as take about TARGET seconds at
-- the pace of its last ones (at most MOST; one to begin with), and in the last NEAR seconds before
-- the deadline no more than half of what is left holds
local NEAR = 1.5e-3
local TARGET = 5e-5
local MOST = 4
local near = false
local left = math.huge         -- the time to the deadline at the last check
local counts, spacings = {}, {}

-- the gaps at least this long are recorded (seconds); STELLAR_SLICE_GAP_MS overrides
local GAP = (tonumber(os.getenv("STELLAR_SLICE_GAP_MS") or "") or 0.5) / 1000
local gaps = {}      -- "from > to" -> { n, max, sum }

local function gap(to, t)
    local d = t - last
    if d >= GAP then
        local key = last_site .. " > " .. to
        local g = gaps[key]
        if not g then
            g = { n = 0, max = 0, sum = 0 }
            gaps[key] = g
        end
        g.n = g.n + 1
        g.sum = g.sum + d
        if d > g.max then g.max = d end
    end
end

local function crossing(to, t)
    local key = last_site .. " > " .. to
    local c = crossed[key]
    if not c then
        c = { n = 0, max = 0 }
        crossed[key] = c
    end
    c.n = c.n + 1
    if t - last > c.max then
        c.max = t - last
        -- where the longest one ended (STELLAR_SLICE_TRACE=1)
        if os.getenv("STELLAR_SLICE_TRACE") == "1" then
            c.trace = debug.traceback("", 3):gsub("\n%s*", " < "):gsub("%.%.%.[^ ]*/", ""):sub(1, 700)
        end
    end
end

local function check(site, ticked, calls)
    local t = now()
    local d = t - last
    if d >= GAP then gap(site, t) end
    if t > frame_end and last <= frame_end then crossing(site, t) end
    if not last_ticked then
        local a = after[last_site]
        after[last_site] = (a == nil or d > a) and d or a * DECAY
    end
    if ticked then
        -- the site's calls between two clock reads: TARGET's worth at the pace of these
        local per = d / calls
        spacings[site] = per > 0 and math.max(1, math.min(MOST, math.floor(TARGET / per))) or MOST
        local a = per_call[site]
        per_call[site] = (a == nil or per > a) and per or a * DECAY
    end
    last, last_site, last_ticked = t, site, ticked
    if deadline ~= math.huge then
        -- past the deadline, or before a stretch that will not fit in what is left but fits in a
        -- piece of its own: what follows this check, or the calls to this tick's next check
        local e
        if ticked then
            e = (per_call[site] or 0) * (near and 1 or (spacings[site] or 1))
        else
            e = after[site] or 0
        end
        if not passive and (t >= deadline or (t + e > deadline and piece_start + e <= deadline)) and isyieldable() then
            slice.yields = slice.yields + 1
            yield()
            t = now()
            last, last_site = t, site
        end
        left = deadline - t
        near = left < NEAR
    end
end

-- slice.passive(on): the VM itself stops a piece past its deadline (sim/src/preempt.rs): the
-- checks keep their record and yield no more; slice.wait still yields
function slice.passive(on)
    passive = on and true or false
end

-- slice.check(site): between two objects of a loop. Past the deadline, the phase yields.
function slice.check(site)
    return check(site, false)
end

-- slice.tick(site): a check every few calls of the site (about TARGET seconds' worth; every call
-- near the deadline), for the loops over many small objects and the evaluator's own calls (a
-- trigger, an effect), where a clock read each time would cost more than the work between two
local floor = math.floor
function slice.tick(site)
    local c = (counts[site] or 0) + 1
    local sp = spacings[site] or 1
    if near then
        -- near the deadline: no more calls than half of what was left holds at the site's pace
        local pc = per_call[site]
        local m = (pc and pc > 0) and floor(left * 0.5 / pc) or 1
        if m < sp then sp = m end
    end
    if c >= sp then
        counts[site] = 0
        check(site, true, c)
    else
        counts[site] = c
    end
end

-- slice.left() -> seconds to the deadline (math.huge without one)
function slice.left()
    if deadline == math.huge then return math.huge end
    return deadline - now()
end

-- slice.sliced() -> whether the phase runs in pieces now (a deadline and a coroutine to yield)
function slice.sliced()
    return deadline ~= math.huge and isyieldable()
end

-- slice.wait(site): something runs elsewhere (the worker pool) and the frame's time is up:
-- yield to a later frame
function slice.wait(site)
    if slice.sliced() then
        slice.waits = slice.waits + 1
        yield()
    end
    last, last_site = now(), site
end

-- the platform: before each piece of a phase (math.huge: no deadline). The pieces of one frame
-- share its deadline: piece_start is when the first of them began (what a frame's room holds)
local frame_deadline = nil
function slice.set_deadline(d, hard)
    deadline = d or math.huge
    frame_end = deadline ~= math.huge and hard or math.huge
    local t = now()
    if deadline ~= math.huge and deadline ~= frame_deadline then
        frame_deadline = deadline
        piece_start = t
    end
    left = deadline - t
    near = left < NEAR
    last, last_site, last_ticked = t, "resume", true
end

-- engine.phase: a phase's start and end, the bounds of its first and last gaps
function slice.begin(key)
    local site = "start " .. key
    local t = now()
    last, last_site, last_ticked = t, site, false
    -- a phase whose first stretch will not fit in what the frame has left waits for the next
    if deadline ~= math.huge then
        local e = after[site] or 0
        if not passive and (t >= deadline or (t + e > deadline and piece_start + e <= deadline)) and isyieldable() then
            slice.yields = slice.yields + 1
            yield()
            t = now()
            last, last_site = t, site
        end
        left = deadline - t
        near = left < NEAR
    end
end

function slice.finish(key)
    local t = now()
    if t - last >= GAP then gap("end " .. key, t) end
    if t > frame_end and last <= frame_end then crossing("end " .. key, t) end
    last, last_site = t, "end " .. key
end

-- slice.report([n]) -> text: the longest gaps between checks, by sites
function slice.report(n)
    local list = {}
    for k, g in pairs(gaps) do list[#list + 1] = { k, g } end
    table.sort(list, function(a, b) return a[2].max > b[2].max end)
    local out = { string.format("slice: %d yields, %d waits; gaps of %.2f ms or more between checks, the longest first:",
        slice.yields, slice.waits, GAP * 1000) }
    for i = 1, math.min(n or 30, #list) do
        local k, g = list[i][1], list[i][2]
        out[#out + 1] = string.format("  %8.2f ms max  %6d over  %8.2f ms mean  %s", g.max * 1000, g.n, g.sum / g.n * 1000, k)
    end
    local cl = {}
    for k, c in pairs(crossed) do cl[#cl + 1] = { k, c } end
    table.sort(cl, function(a, b) return a[2].n > b[2].n or (a[2].n == b[2].n and a[1] < b[1]) end)
    out[#out + 1] = string.format("slice: %d stretches between checks crossed a frame's end:", #cl > 0 and
        (function() local s = 0 for _, x in ipairs(cl) do s = s + x[2].n end return s end)() or 0)
    for i = 1, math.min(n or 30, #cl) do
        out[#out + 1] = string.format("  %4d  %8.2f ms max  %s", cl[i][2].n, cl[i][2].max * 1000, cl[i][1])
        if cl[i][2].trace then
            out[#out + 1] = "          " .. cl[i][2].trace
        end
    end
    if slice.profile_report then
        out[#out + 1] = slice.profile_report(n)
    end
    if os.getenv("STELLAR_SLICE_GC") == "1" then
        out[#out + 1] = slice.gc_report()
    end
    return table.concat(out, "\n")
end

-- STELLAR_SLICE_GC=1: the heap, the largest tables reachable from engine.world's upvalues, the
-- modifier graph's, the weak tables, the collector's steps through a cycle (the longest are what a
-- frame cannot cut) and a full collection's time
function slice.gc_report()
    local out = { string.format("gc: heap %.0f MB; %d cycles finished since the counting began (%.1f s)", collectgarbage("count") / 1024,
        slice.gc_cycles or 0, now() - (slice.gc_since or now())) }
    local function count(t)
        local n = 0
        for _ in pairs(t) do n = n + 1 end
        return n
    end
    local world = package.loaded["engine.world"]
    if world and world.stale_report and os.getenv("STELLAR_WORLD_CHECK") == "1" then
        out[#out + 1] = world.stale_report()
    end
    local seen = {}
    for name, f in pairs(world or {}) do
        if type(f) == "function" then
            local i = 1
            while true do
                local up, v = debug.getupvalue(f, i)
                if not up then break end
                if type(v) == "table" and not seen[v] then
                    seen[v] = true
                    local n = count(v)
                    if n > 20000 then
                        local mt = getmetatable(v)
                        out[#out + 1] = string.format("  world upvalue %s (of world.%s): %d entries%s", up, name, n,
                            mt and mt.__mode and (", weak " .. mt.__mode) or "")
                        if up == "fields_of" then
                            local h = { 0, 0, 0, 0, 0, 0 }
                            for k in pairs(v) do
                                local len = type(k) == "table" and #k or 0
                                local b = len <= 2 and 1 or len <= 4 and 2 or len <= 8 and 3 or len <= 16 and 4 or len <= 32 and 5 or 6
                                h[b] = h[b] + 1
                            end
                            out[#out + 1] = string.format("    by the block's entries: <=2 %d, <=4 %d, <=8 %d, <=16 %d, <=32 %d, more %d",
                                h[1], h[2], h[3], h[4], h[5], h[6])
                        end
                    end
                end
                i = i + 1
            end
        end
    end
    -- the modifier graph's own tables (the trees' maps by node id)
    local engine = package.loaded["engine"]
    local src = engine and engine.modifier_source
    local wg = src and src.graph and src.graph()
    if wg then
        for _, name in ipairs({ "tree1", "tree2" }) do
            local tree = wg[name]
            if tree then
                for _, f in ipairs({ "owner", "type_of" }) do
                    if type(tree[f]) == "table" then
                        out[#out + 1] = string.format("  modifier %s.%s: %d entries", name, f, count(tree[f]))
                    end
                end
            end
        end
        for _, f in ipairs({ "recs", "by_holder", "memo" }) do
            if type(wg[f]) == "table" then
                out[#out + 1] = string.format("  modifier graph %s: %d entries", f, count(wg[f]))
            end
        end
    end
    -- the weak tables by size (by where they were made)
    local by_site = {}
    for _, w in ipairs(weak_tables) do
        local s = by_site[w[2]] or { n = 0, tables = 0, mode = w[3] }
        by_site[w[2]] = s
        s.n = s.n + count(w[1])
        s.tables = s.tables + 1
    end
    local list = {}
    for site, s in pairs(by_site) do list[#list + 1] = { site, s } end
    table.sort(list, function(a, b) return a[2].n > b[2].n end)
    for i = 1, math.min(15, #list) do
        local s = list[i][2]
        out[#out + 1] = string.format("  weak (%s) %s: %d tables, %d entries", s.mode, list[i][1], s.tables, s.n)
    end
    -- one cycle in the collector's own steps (collectgarbage("step", 0) is one lj_gc_step): the
    -- longest steps are what an incremental cycle cannot cut
    local steps, total, longest = 0, 0, {}
    local cycles = 0
    while cycles < 2 and steps < 50000000 do
        local t = now()
        local done = collectgarbage("step", 0)
        local d = now() - t
        steps, total = steps + 1, total + d
        if d > 0.0005 then longest[#longest + 1] = d end
        if done then cycles = cycles + 1 end
    end
    table.sort(longest, function(a, b) return a > b end)
    local top = {}
    for i = 1, math.min(12, #longest) do top[i] = string.format("%.1f", longest[i] * 1000) end
    out[#out + 1] = string.format("  stepped to the end of a cycle and through the next: %d steps, %.0f ms; %d steps over 0.5 ms, the longest (ms): %s",
        steps, total * 1000, #longest, table.concat(top, " "))
    local t0 = now()
    collectgarbage("collect")
    out[#out + 1] = string.format("  a full collection: %.0f ms, heap after %.0f MB", (now() - t0) * 1000,
        collectgarbage("count") / 1024)
    return table.concat(out, "\n")
end

-- STELLAR_SLICE_PROFILE=1 (or a stack depth): LuaJIT's sampling profiler (jit.profile) every
-- millisecond; a sample taken in a stretch of STELLAR_SLICE_PROFILE_MS or more since the last check
-- counts its stack (the VM's state first: N compiled, I interpreted, C in C, G the collector, J the
-- compiler), to show where the long stretches go
local samples, tops = {}, {}
local PROFILE = os.getenv("STELLAR_SLICE_PROFILE")
if PROFILE and PROFILE ~= "" and PROFILE ~= "0" and not (RUST and RUST.worker_index) then
    local ok, profile = pcall(require, "jit.profile")
    if ok then
        local depth = tonumber(PROFILE) or 1
        depth = depth > 1 and depth or 10
        -- STELLAR_SLICE_PROFILE_MS: the stretches sampled, from this long (default 2 ms)
        local long = (tonumber(os.getenv("STELLAR_SLICE_PROFILE_MS") or "") or 2) / 1000
        profile.start("li1", function(thread, n, vmstate)
            -- (the samples taken while the platform ran, between two pieces, come in at a
            -- piece's start, in this file: left out)
            local where = profile.dumpstack(thread, "l", 1)
            if now() - last >= long and not where:find("slice.lua", 1, true) then
                local top = vmstate .. " " .. where
                tops[top] = (tops[top] or 0) + n
                local s = vmstate .. " " .. profile.dumpstack(thread, "l < ", depth)
                samples[s] = (samples[s] or 0) + n
            end
        end)
        function slice.profile_report(n)
            local function top_of(t, k, title)
                local list = {}
                for s, c in pairs(t) do list[#list + 1] = { s, c } end
                table.sort(list, function(a, b) return a[2] > b[2] end)
                local out = { title }
                for i = 1, math.min(k, #list) do
                    out[#out + 1] = string.format("  %6d  %s", list[i][2], list[i][1])
                end
                return table.concat(out, "\n")
            end
            return top_of(tops, 40, "profile: samples (1 ms) in the stretches past the gap, by line:") .. "\n"
                .. top_of(samples, 40, "profile: by stack (innermost first):")
        end
    end
end

-- (STELLAR_SLICE_GC=1: the collector's cycles counted from slice.reset, by a sentinel's finalizer)
local function sentinel()
    local p = newproxy(true)
    getmetatable(p).__gc = function()
        slice.gc_cycles = (slice.gc_cycles or 0) + 1
        sentinel()
    end
end

function slice.reset()
    if os.getenv("STELLAR_SLICE_GC") == "1" and not slice.gc_since then
        slice.gc_since, slice.gc_cycles = now(), 0
        sentinel()
    end
    gaps, crossed = {}, {}
    samples, tops = {}, {}
    slice.yields, slice.waits = 0, 0
end

return slice
