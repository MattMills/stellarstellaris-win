-- engine/store/bench.lua : the store against the Lua tables, on the loaded world (run after a load:
-- STELLAR_LUA=<this file> examples/run 0 <save>, or require("engine.store.bench").run()).
--
-- 1. the world's tree built into the store (time, size), written back (byte for byte the same text
--    as pdxscript.write of the tree);
-- 2. microbenchmarks, each the same reads over the table world (engine.world) and the store
--    (engine.store.world's API, and the raw core API with key ids looked up once);
-- 3. memory and garbage collection: the Lua heap and a full collection's time with the table world
--    and with the world only in the store (destructive: the engine cannot run after it).

local S = require("engine.store.core")
local W = require("engine.store.world")
local world = require("engine.world")
local pdxscript = require("pdxscript")

local M = {}

local clock = RUST.clock

local function timeit(n, f)
    f(math.max(1, math.floor(n / 10)))   -- warm up (traces compiled)
    local t0 = clock()
    local r = f(n)
    return (clock() - t0) * 1e9 / n, r
end

function M.run(opts)
    opts = opts or {}
    local lines = {}
    local function out(fmt, ...) lines[#lines + 1] = string.format(fmt, ...) end
    S.attach()

    -- 1. build and round trip
    local t0 = clock()
    local root = W.build(world.tree)
    local t_build = clock() - t0
    out("build: the world's tree into the store in %.2f s: %s", t_build, S.usage())
    t0 = clock()
    W.index()
    out("index (planets_of, owners, ...) over the store in %.2f s", clock() - t0)
    if opts.roundtrip ~= false then
        t0 = clock()
        local a = S.write(root)
        local t_sw = clock() - t0
        t0 = clock()
        local b = pdxscript.write(world.tree)
        local t_pw = clock() - t0
        local same = a == b
        local at
        if not same then
            for i = 1, math.min(#a, #b) do
                if a:byte(i) ~= b:byte(i) then at = i break end
            end
            at = at or math.min(#a, #b) + 1
        end
        out("round trip: store write %.2f s, pdxscript.write %.2f s, %d bytes, %s", t_sw, t_pw, #b,
            same and "the same text" or ("DIFFERENT at byte " .. at .. ": " .. a:sub(at - 40, at + 40):gsub("\n", "\\n") .. " | " .. b:sub(at - 40, at + 40):gsub("\n", "\\n")))
    end

    -- 2. microbenchmarks
    local cids = world.all("country")
    local c0 = world.object("country", cids[1])
    local h0 = W.object("country", cids[1])
    local b0 = W.bid(h0)
    local K = { capital = S.kid("capital"), owned_planets = S.kid("owned_planets"), type = S.kid("type"),
        movement_manager = S.kid("movement_manager"), coordinate = S.kid("coordinate"), origin = S.kid("origin") }
    local E = S.E

    out("microbenchmarks (ns per operation; tables = engine.world, store = engine.store.world, raw = engine.store.core with key ids):")
    -- a. one hot field of a country, again and again
    local ta = timeit(2e6, function(n)
        local s = 0
        for _ = 1, n do s = s + (world.field(c0, "capital") or 0) end
        return s
    end)
    local sa = timeit(2e6, function(n)
        local s = 0
        for _ = 1, n do s = s + (W.field(h0, "capital") or 0) end
        return s
    end)
    local ra = timeit(2e6, function(n)
        local s = 0
        local find, token, k = S.find, S.token, K.capital
        for _ = 1, n do local i = find(b0, k); s = s + (i and token(i) or 0) end
        return s
    end)
    out("  a. a country's capital, one object (%d entries):  tables %.1f  store %.1f  raw %.1f", S.count(b0), ta, sa, ra)

    -- b. the same field over every country (55 objects)
    local tb = timeit(2e5, function(n)
        local s = 0
        for _ = 1, n / #cids do
            for _, id in ipairs(cids) do s = s + (world.field(world.object("country", id), "capital") or 0) end
        end
        return s
    end)
    local sb = timeit(2e5, function(n)
        local s = 0
        for _ = 1, n / #cids do
            for _, id in ipairs(cids) do s = s + (W.field(W.object("country", id), "capital") or 0) end
        end
        return s
    end)
    local cb = {}
    for i, id in ipairs(cids) do cb[i] = W.bid(W.object("country", id)) end
    local rb = timeit(2e5, function(n)
        local s = 0
        local find, token, k = S.find, S.token, K.capital
        for _ = 1, n / #cids do
            for i = 1, #cb do local x = find(cb[i], k); s = s + (x and token(x) or 0) end
        end
        return s
    end)
    out("  b. capital of every country (55 objects):          tables %.1f  store %.1f  raw %.1f", tb, sb, rb)

    -- c. a path in many small objects: every fleet's movement_manager.coordinate.origin
    local fids = world.all("fleet")
    local tc = timeit(4e5, function(n)
        local s = 0
        for _ = 1, n / #fids do
            for _, id in ipairs(fids) do
                s = s + (tonumber(world.path(world.object("fleet", id), "movement_manager", "coordinate", "origin")) or 0)
            end
        end
        return s
    end)
    local sc = timeit(4e5, function(n)
        local s = 0
        for _ = 1, n / #fids do
            for _, id in ipairs(fids) do
                s = s + (tonumber(W.path(W.object("fleet", id), "movement_manager", "coordinate", "origin")) or 0)
            end
        end
        return s
    end)
    local fb = {}
    for i, id in ipairs(fids) do fb[i] = W.bid(W.object("fleet", id)) end
    local rc = timeit(4e5, function(n)
        local s = 0
        local find, token = S.find, S.token
        local km, kc, ko = K.movement_manager, K.coordinate, K.origin
        for _ = 1, n / #fb do
            for i = 1, #fb do
                local x = find(fb[i], km)
                x = x and find(E[x].v.u.a, kc)
                x = x and find(E[x].v.u.a, ko)
                s = s + (x and token(x) or 0)
            end
        end
        return s
    end)
    out("  c. fleet.movement_manager.coordinate.origin (%d fleets): tables %.1f  store %.1f  raw %.1f", #fids, tc, sc, rc)

    -- d. iterate every entry of every country (a walk over a country-scale object)
    local nent = 0
    for _, id in ipairs(cids) do nent = nent + #world.object("country", id) end
    local td = timeit(nent * 20, function(n)
        local s = 0
        for _ = 1, n / nent do
            for _, id in ipairs(cids) do
                local c = world.object("country", id)
                for i = 1, #c do
                    local e = c[i]
                    if e.op and e.value.text then s = s + 1 end
                end
            end
        end
        return s
    end)
    local rd = timeit(nent * 20, function(n)
        local s = 0
        local B = S.B
        for _ = 1, n / nent do
            for j = 1, #cb do
                local b = B[cb[j]]
                for i = b.first, b.first + b.count - 1 do
                    local e = E[i]
                    if e.op ~= 0 and e.kind ~= 3 then s = s + 1 end
                end
            end
        end
        return s
    end)
    out("  d. walk every top-level entry of every country (%d entries): tables %.2f  raw %.2f", nent, td, rd)

    -- e. many distinct fields of a country-scale object: every key of country 0, once each
    local keys, seen = {}, {}
    for _, e in ipairs(c0) do
        if e.op and not seen[e.key.text] then seen[e.key.text] = true keys[#keys + 1] = e.key.text end
    end
    local te = timeit(#keys * 2000, function(n)
        local s = 0
        for _ = 1, n / #keys do
            for k = 1, #keys do if world.field(c0, keys[k]) ~= nil then s = s + 1 end end
        end
        return s
    end)
    local se = timeit(#keys * 2000, function(n)
        local s = 0
        for _ = 1, n / #keys do
            for k = 1, #keys do if W.field(h0, keys[k]) ~= nil then s = s + 1 end end
        end
        return s
    end)
    out("  e. each of a country's %d keys, by name:          tables %.1f  store %.1f", #keys, te, se)

    -- f. a list of numbers: owned_planets of every country (exploration's numbers())
    local function numbers(block)
        local o = {}
        if type(block) == "table" then
            for _, e in ipairs(block) do
                if e.text then o[#o + 1] = tonumber(e.text) end
            end
        end
        return o
    end
    local tf = timeit(2e5, function(n)
        local s = 0
        for _ = 1, n / #cids do
            for _, id in ipairs(cids) do s = s + #numbers(world.field(world.object("country", id), "owned_planets")) end
        end
        return s
    end)
    local rf = timeit(2e5, function(n)
        local s = 0
        local find, k = S.find, K.owned_planets
        for _ = 1, n / #cb do
            for i = 1, #cb do
                local x = find(cb[i], k)
                if x then s = s + #S.numbers(E[x].v.u.a) end
            end
        end
        return s
    end)
    local rf2 = timeit(2e5, function(n)
        local s = 0
        local find, k, B, num_of = S.find, K.owned_planets, S.B, S.num_of
        for _ = 1, n / #cb do
            for i = 1, #cb do
                local x = find(cb[i], k)
                if x then
                    local b = B[E[x].v.u.a]
                    for j = b.first, b.first + b.count - 1 do
                        local v = num_of(E[j].v.u.a)
                        if v then s = s + v end
                    end
                end
            end
        end
        return s
    end)
    out("  f. owned_planets of every country as numbers:        tables %.1f  raw %.1f (a Lua array)  raw in place %.1f", tf, rf, rf2)

    -- g. the ships of every fleet, the ship's hitpoints (two stores, ids followed)
    local tg = timeit(2e5, function(n)
        local s = 0
        for _ = 1, n / #fids do
            for _, id in ipairs(fids) do
                local f = world.object("fleet", id)
                for _, sh in ipairs(numbers(world.field(f, "ships"))) do
                    s = s + (tonumber(world.field(world.object("ship", sh), "hitpoints")) or 0)
                end
            end
        end
        return s
    end)
    local sg = timeit(2e5, function(n)
        local s = 0
        local find, token, kships, khp = S.find, S.token, S.kid("ships"), S.kid("hitpoints")
        local ships, B, num_of = W.stores.ships, S.B, S.num_of
        for _ = 1, n / #fb do
            for i = 1, #fb do
                local x = find(fb[i], kships)
                if x then
                    local b = B[E[x].v.u.a]
                    for j = b.first, b.first + b.count - 1 do
                        local h = ships[num_of(E[j].v.u.a)]
                        local y = h and find(W.bid(h), khp)
                        s = s + (y and token(y) or 0)
                    end
                end
            end
        end
        return s
    end)
    out("  g. every fleet's ships' hitpoints:                    tables %.1f  raw %.1f (per fleet)", tg, sg)

    -- 3. memory and collection
    if opts.gc ~= false then
        collectgarbage("collect")
        collectgarbage("collect")
        local kb1 = collectgarbage("count")
        t0 = clock()
        collectgarbage("collect")
        local gc1 = clock() - t0
        -- the world's tables dropped: the tree, the stores, the field index, the script state's copy
        world.tree, world.stores, world.entries, world.store_blocks, world.meta = nil, {}, {}, {}, {}
        world.planets_of, world.pop_groups_of, world.leaders_of = nil, nil, nil
        for k, v in pairs(package.loaded) do
            if type(v) == "table" and k:match("^engine%.") and k ~= "engine.store.core" and k ~= "engine.store.world" then
                -- module caches may hold blocks of the old world: dropped with the modules
                package.loaded[k] = nil
            end
        end
        package.loaded["engine"] = nil
        collectgarbage("collect")
        collectgarbage("collect")
        local kb2 = collectgarbage("count")
        t0 = clock()
        collectgarbage("collect")
        local gc2 = clock() - t0
        out("memory: Lua heap %.0f MB with the table world, %.0f MB with the world in the store (the store %s); a full collection %.0f ms against %.0f ms",
            kb1 / 1024, kb2 / 1024, S.usage(), gc1 * 1000, gc2 * 1000)
    end
    return table.concat(lines, "\n")
end

return M
