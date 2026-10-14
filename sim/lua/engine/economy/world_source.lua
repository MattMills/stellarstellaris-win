-- engine/economy/world_source.lua : the engine's modifier source from the world alone, the
-- rewrite's own modifier system (engine.modifiers.world: every node of the world, its links and its
-- own parts, `mult = modifier:x` references resolved from a first build), in place of the game's
-- capture (engine/economy/capture.lua). It answers the same question for every system:
--
--   f(kind, id) -> { [modifier name] = value as a float } | nil      (nil: no such node)
--
-- kind is the engine's (colony, planet, pop_group, country, ship, fleet, leader, starbase, army,
-- megastructure, sector, federation, spy_network); a colony's node is keyed by the colony id, a
-- planet's by the planet id, as the game's.
--
-- The graph is built from the world as it is when built; the engine brings it up to date in the
-- monthly modifier phase (the game updates its nodes daily: between two builds the values are
-- held), changing only what changed (engine.modifiers.incremental: the graph and the values asked
-- of it kept, those of the holders whose values changed dropped; docs/modifier_incremental.md). The
-- modifier types (names, categories) are built from the game's files (stellar.graph.modifiers
-- game_definitions), or read from the game's modifier documentation when one is given
-- (script_documentation/modifiers.log, STELLAR_MODIFIER_TYPES).
--
--   local ws = require("engine.economy.world_source")
--   local source, why = ws.new([types_log_path])
--   economy.set_modifier_source(source.get)
--   source.rebuild()                   -- the world changed (a month passed)

local M = {}

M.CATEGORY = {
    colony = "Colony", planet = "Planet", pop_group = "PopGroup", country = "Country", ship = "Ship",
    fleet = "Fleet", leader = "Leader", starbase = "Starbase", army = "Army", megastructure = "MegaStructure",
    sector = "Sector", federation = "Federation", spy_network = "SpyNetwork",
}

local function read_file(path)
    local f = path and io.open(path, "rb")
    if not f then
        return nil
    end
    local text = f:read("*a")
    f:close()
    return text
end

-- ws.new([types_log]) -> source | nil, message: source.get(kind, id), source.rebuild(),
-- source.stats. The modifier types are built from the game's files (stellar.graph.modifiers
-- game_definitions: the types the game defines in code, and those it generates from the
-- databases); a modifiers log given (the game's script_documentation/modifiers.log) is read instead.
function M.new(types_log)
    local ok_mw, mw = pcall(require, "engine.modifiers.world")
    if not ok_mw or not mw.world_graph or not mw.values then
        return nil, "engine.modifiers.world has no world_graph/values (the modifiers branch is not merged)"
    end
    local gmod = require("stellar.graph.modifiers")
    local world = require("engine.world")
    local edefs = require("engine.defs")
    local defs, types_from
    local text = types_log and types_log ~= "" and read_file(types_log)
    if text then
        defs = gmod.definitions()
        defs:read_log(text)
        types_from = types_log
    elseif gmod.game_definitions then
        defs = gmod.game_definitions(edefs.folder)
        types_from = "the game's files"
    else
        return nil, "no modifier types: no log at " .. tostring(types_log) .. " (STELLAR_MODIFIER_TYPES) and no game_definitions"
    end
    text = nil
    local okdb, db = pcall(require, "simscript.db")
    local fs = okdb and db.fs or nil

    local source = { stats = { builds = 0, seconds = 0, asked = 0, missing = 0, kept = 0, dropped = 0 } }
    -- the graph kept from month to month (engine.modifiers.incremental), unless
    -- STELLAR_MODIFIER_INCREMENTAL=off: then built whole every month (engine.modifiers.world)
    local mode = os.getenv("STELLAR_MODIFIER_INCREMENTAL")
    local incremental = mode ~= "off" and mode ~= "0"
    -- STELLAR_MODIFIER_CHECK=1: every rebuild also builds the graph whole and compares every value
    -- of every node, and every value still cached, with it (docs/modifier_incremental.md)
    local check = os.getenv("STELLAR_MODIFIER_CHECK")
    check = check ~= nil and check ~= "" and check ~= "0" and check ~= "off"
    local wg, cache
    -- full: the graph built whole from the same world (before the update, so that a trigger reading
    -- a modifier reads the month before's in both, as the full rebuild alone does)
    local function check_graph(full, seconds)
        local t0 = RUST.clock()
        full.defs = full.defs or defs
        local r = { holders = 0, values = 0, mismatches = 0, missing = 0, extra = 0, cached = 0, cache_mismatches = 0 }
        local examples = {}
        local function bad(what)
            if #examples < 5 then
                examples[#examples + 1] = what
            end
        end
        local function compare(a, b, key, what)
            local n = 0
            for name, v in pairs(a) do
                if b[name] ~= v then
                    n = n + 1
                    bad(string.format("%s %s %s: %s, full rebuild %s", what, key, name, tostring(b[name]), tostring(v)))
                end
            end
            for name, v in pairs(b) do
                if a[name] == nil then
                    n = n + 1
                    bad(string.format("%s %s %s: %s, full rebuild nil", what, key, name, tostring(v)))
                end
            end
            return n
        end
        for key, h in pairs(full.holders) do
            r.holders = r.holders + 1
            local want = mw.values(full, h.kind, h.key)
            local got = mw.values(wg, h.kind, h.key)
            for _ in pairs(want) do
                r.values = r.values + 1
            end
            if got == nil then
                r.missing = r.missing + 1
                bad("missing " .. key)
            else
                r.mismatches = r.mismatches + compare(want, got, key, "value")
            end
            local c = cache[key]
            if c ~= nil then
                r.cached = r.cached + 1
                if c == false then
                    r.cache_mismatches = r.cache_mismatches + 1
                    bad("cached as missing " .. key)
                else
                    r.cache_mismatches = r.cache_mismatches + compare(want, c, key, "cached")
                end
            end
        end
        if wg.recs then
            for key in pairs(wg.recs) do
                if full.holders[key] == nil then
                    r.extra = r.extra + 1
                    bad("extra " .. key)
                end
            end
        end
        for key, c in pairs(cache) do
            if full.holders[key] == nil and c ~= false then
                r.extra = r.extra + 1
                bad("cached, not in the world " .. key)
            end
        end
        local cs = source.stats.check or { builds = 0, holders = 0, values = 0, mismatches = 0, missing = 0, extra = 0, cached = 0,
            cache_mismatches = 0, seconds = 0 }
        source.stats.check = cs
        cs.builds = cs.builds + 1
        for k in pairs(r) do
            cs[k] = cs[k] + r[k]
        end
        cs.seconds = cs.seconds + seconds + (RUST.clock() - t0)
        print(string.format("modifier check %d (day %s): %d holders, %d values: %d differ, %d missing, %d extra; %d cached values tables: %d differ%s",
            cs.builds, tostring(RUST.date and RUST.date()), r.holders, r.values, r.mismatches, r.missing, r.extra, r.cached,
            r.cache_mismatches, #examples > 0 and (": " .. table.concat(examples, "; ")) or ""))
    end
    function source.rebuild()
        local full, full_seconds
        if check then
            local t = RUST.clock()
            full = mw.world_graph({ defs = defs, world = world, edefs = edefs, fs = fs })
            full_seconds = RUST.clock() - t
        end
        local t0 = RUST.clock()
        if incremental then
            if wg == nil then
                wg = require("engine.modifiers.incremental").new({ defs = defs, world = world, edefs = edefs, fs = fs })
                cache = {}
            end
            -- only the cached values of the holders whose values may have changed (new and gone
            -- ones among them) are dropped, and the misses (a holder may be new)
            local changed = wg:update()
            for key in pairs(changed) do
                if cache[key] ~= nil then
                    cache[key] = nil
                    source.stats.dropped = source.stats.dropped + 1
                end
            end
            for key, v in pairs(cache) do
                if v == false then
                    cache[key] = nil
                else
                    source.stats.kept = source.stats.kept + 1
                end
            end
        else
            wg = mw.world_graph({ defs = defs, world = world, edefs = edefs, fs = fs })
            wg.defs = wg.defs or defs
            cache = {}
        end
        source.stats.builds = source.stats.builds + 1
        source.stats.seconds = source.stats.seconds + (RUST.clock() - t0)
        if check then
            if incremental then
                print(wg:report())
            end
            check_graph(full, full_seconds)
        end
        local economy = package.loaded["engine.economy"]
        if economy and economy.invalidate then
            economy.invalidate()
        end
    end
    function source.get(kind, id)
        if wg == nil then
            source.rebuild()
        end
        local cat = M.CATEGORY[kind] or kind
        local key = cat .. ":" .. tostring(id)
        local v = cache[key]
        if v == nil then
            v = mw.values(wg, cat, id) or false
            cache[key] = v
            source.stats.asked = source.stats.asked + 1
            if v == false then
                source.stats.missing = source.stats.missing + 1
            end
        end
        return v or nil
    end
    function source.report()
        local s = source.stats
        local line = string.format("modifiers: from the world (%s; types from %s), %d builds in %.1f s, %d nodes asked, %d not in the world",
            incremental and "engine.modifiers.incremental" or "engine.modifiers.world", types_from, s.builds, s.seconds, s.asked, s.missing)
        if incremental and wg and wg.report then
            line = line .. string.format("; cached values kept %d, dropped %d; last %s", s.kept, s.dropped, wg:report())
        end
        local c = s.check
        if c then
            line = line .. string.format("\nmodifier check: %d rebuilds compared with a full one: %d holders, %d values, %d differ, %d missing, %d extra; %d cached values tables, %d values differ (%.1f s)",
                c.builds, c.holders, c.values, c.mismatches, c.missing, c.extra, c.cached, c.cache_mismatches, c.seconds)
        end
        return line
    end
    return source
end

return M
