-- engine/store/modifiers.lua : the modifier values in the shared store, for the engine on the
-- workers (docs/data_layer.md, "The engine on the workers").
--
-- engine.economy's modifier source in the main state is the world's modifier graph
-- (engine.economy.world_source over engine.modifiers.incremental). A worker has no graph; it reads
-- the values the main state's graph gives. Those are held from one rebuild of the graph to the next
-- (the monthly modifier phase), so the copy is brought up to date only after a rebuild: the holders
-- whose values may have changed are written again, new ones added, gone ones taken out.
--
-- Root 6 is a block of `"<Category>:<owner>" = { <modifier> = <value> ... }`, one per holder of the
-- graph (a ship's not: no worker asks yet), each value a NUMBER entry holding the float as the
-- source gives it; a gone holder's entry is renamed "-". Root 7 counts the exports; a worker's
-- reader drops what it read when it moved.
--
--   local MX = require("engine.store.modifiers")
--   MX.sync()                                         -- main state, before a phase on the workers
--   economy.set_modifier_source(MX.reader())          -- a worker (engine.store.worker)

local S = require("engine.store.core")

local ROOT, GEN = 6, 7
local MX = { stats = { exports = 0, holders = 0, written = 0, gone = 0, seconds = 0 } }

-- the categories not copied (a worker asking for one raises an error)
local SKIP = { Ship = true }

local CATEGORY = {
    colony = "Colony", planet = "Planet", pop_group = "PopGroup", country = "Country", ship = "Ship",
    fleet = "Fleet", leader = "Leader", starbase = "Starbase", army = "Army", megastructure = "MegaStructure",
    sector = "Sector", federation = "Federation", spy_network = "SpyNetwork",
}

local root          -- the root block (main state)
local bid_of = {}   -- holder key -> its block
local entry_of = {} -- holder key -> its entry in the root block
local builds_seen

-- one holder's values written into its block (in place)
local function write(key, values)
    local bid = bid_of[key]
    if bid == nil then
        bid = S.new_block(0)
        local _, i = S.append_block(root, key, bid)
        bid_of[key], entry_of[key] = bid, i
    else
        S.clear(bid)
    end
    for name, v in pairs(values) do
        local i = S.append(bid, name, 0)
        local e = S.E[i]
        e.kind = S.NUMBER
        e.v.num = v
    end
    MX.stats.written = MX.stats.written + 1
end

-- MX.sync(): after a rebuild of the graph, the changed holders written into the store (all of them
-- the first time)
function MX.sync()
    local engine = package.loaded["engine"]
    local source = type(engine) == "table" and engine.modifier_source
    if not (source and source.graph and source.stats) then return end
    if source.stats.builds == builds_seen then return end
    local wg = source.graph()
    if not (wg and wg.by_cat) then return end
    local t0 = RUST.clock()
    local first = root == nil
    if first then
        root = S.new_block(0)
        S.H.roots[ROOT] = root
    end
    builds_seen = source.stats.builds
    local changed = source.take_changed and source.take_changed() or nil
    local seen = 0
    for cat, owners in pairs(wg.by_cat) do
        if not SKIP[cat] then
            for owner in pairs(owners) do
                local key = cat .. ":" .. tostring(owner)
                seen = seen + 1
                if first or changed == nil or changed[key] or bid_of[key] == nil then
                    write(key, source.get(cat, owner) or {})
                end
            end
        end
    end
    -- the holders gone from the graph
    for key, i in pairs(entry_of) do
        local cat, owner = key:match("^([^:]+):(.*)$")
        local owners = wg.by_cat[cat]
        if not (owners and (owners[owner] or owners[tonumber(owner)])) then
            S.E[i].key = S.id("-")
            bid_of[key], entry_of[key] = nil, nil
            MX.stats.gone = MX.stats.gone + 1
        end
    end
    MX.stats.holders = seen
    MX.stats.exports = MX.stats.exports + 1
    S.H.roots[GEN] = MX.stats.exports
    MX.stats.seconds = MX.stats.seconds + (RUST.clock() - t0)
end

-- MX.reader() -> f(kind, id): a worker's modifier source over the copy (engine.economy's
-- source.get: { [modifier] = value } or nil for a holder not in the graph)
function MX.reader()
    local seen, map, cache
    return function(kind, id)
        local g = S.H.roots[GEN]
        if g ~= seen then
            seen, map, cache = g, {}, {}
            local r = S.H.roots[ROOT]
            if r ~= 0 then
                local b = S.B[r]
                for i = b.first, b.first + b.count - 1 do
                    local e = S.E[i]
                    if e.kind == S.BLOCK then map[S.str(e.key)] = e.v.u.a end
                end
            end
        end
        local cat = CATEGORY[kind] or kind
        if SKIP[cat] then error("the modifier values of a " .. cat .. " are not in the store (engine.store.modifiers)", 2) end
        if seen == 0 then error("no modifier values in the store (engine.store.modifiers.sync)", 2) end
        local key = cat .. ":" .. tostring(id)
        local v = cache[key]
        if v == nil then
            local bid = map[key]
            if bid then
                v = {}
                local b = S.B[bid]
                for i = b.first, b.first + b.count - 1 do
                    local e = S.E[i]
                    v[S.str(e.key)] = e.v.num
                end
            else
                v = false
            end
            cache[key] = v
        end
        return v or nil
    end
end

function MX.report()
    local s = MX.stats
    return string.format("modifier values in the store: %d exports, %d holders, %d written, %d gone, %.2f s",
        s.exports, s.holders, s.written, s.gone, s.seconds)
end

return MX
