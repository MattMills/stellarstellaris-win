-- sim/tools/modifier_world.lua : the modifier graph built from a save alone (engine.modifiers.world:
-- the nodes and links of engine.modifiers.structure), checked value by value against a capture of
-- the game's nodes at the same moment, with a plain LuaJIT.
--
--   luajit sim/tools/modifier_world.lua
--     STELLARIS_DIR   the game (default /opt/stellaris)
--     STELLAR_SAVE    the save (default /opt/stellaris-saves/autosave_2211.07.01.sav)
--     MODCHECK_NODES  the capture (default /opt/stellaris-captures/modifier-nodes-2211.07.01-edges.tsv)
--     MODCHECK_TYPES  its modifiers.log (default /opt/stellaris-captures/modifiers-2211.07.01.log)
--
-- Four graphs: (1) the world's structure with the capture's own parts (the structure on its own:
-- every difference is a link or a filter), (2) the world's structure with the own parts
-- engine.modifiers computes, for the categories it models (the capture's for the others), (3) the
-- computed parts alone, (4) mw.world_graph, as the engine reads it (the multipliers that are
-- another modifier's value from its own graph, where (2) and (3) read them from the capture).

local dir = (arg and arg[0] or ""):match("^(.*)[/\\]sim[/\\]tools[/\\][^/\\]*$") or "."
package.path = dir .. "/sim/lua/?.lua;" .. dir .. "/sim/lua/?/init.lua;" .. dir .. "/lib/stellar-lua-pdxscript/?.lua;"
    .. dir .. "/lua/?.lua;" .. dir .. "/lua/?/init.lua;" .. package.path

-- the platform's helpers (sim/src/runtime.rs), when not run from it
RUST = RUST or {}
RUST.clock = RUST.clock or os.clock
RUST.list_files = RUST.list_files or function(root, sub)
    local out = {}
    local p = io.popen("cd '" .. root .. "' && find '" .. sub .. "' -type f -iname '*.txt' | LC_ALL=C sort")
    for line in p:lines() do
        out[#out + 1] = line
    end
    p:close()
    return out
end
E = E or {}

local function env(k, d)
    local v = os.getenv(k)
    return (v and v ~= "") and v or d
end
local game_dir = env("STELLARIS_DIR", "/opt/stellaris")
local save = env("STELLAR_SAVE", "/opt/stellaris-saves/autosave_2211.07.01.sav")
local nodes_tsv = env("MODCHECK_NODES", "/opt/stellaris-captures/modifier-nodes-2211.07.01-edges.tsv")
local types_log = env("MODCHECK_TYPES", "/opt/stellaris-captures/modifiers-2211.07.01.log")

local function read(path)
    local f = assert(io.open(path, "rb"))
    local head = f:read(2)
    f:close()
    local p = head == "PK" and io.popen("unzip -p '" .. path .. "' gamestate") or io.open(path, "rb")
    local text = p:read("*a")
    p:close()
    return text
end

local t0 = os.clock()
local text = read(save)
local y, m, d = text:match('\ndate%s*=%s*"(%d+)%.(%d+)%.(%d+)"')
local hours = 43800000 + ((tonumber(y) or 2200) * 360 + ((tonumber(m) or 1) - 1) * 30 + (tonumber(d) or 1) - 1) * 24
RUST.date = RUST.date or function() return hours end
local draws = 0
RUST.rand = RUST.rand or function()
    draws = draws + 1
    return draws
end
local engine = require("engine")
io.write(engine.load(game_dir, text), "\n")
text = nil
local world = require("engine.world")
local edefs = require("engine.defs")
local fs = require("simscript.db").fs

local core = require("stellar.graph.core")
local gmod = require("stellar.graph.modifiers")
local nodes = require("stellar.graph.nodes")
local modifiers = require("engine.modifiers")
local structure = require("engine.modifiers.structure")
local mw = require("engine.modifiers.world")

local defs = gmod.definitions()
defs:read_log(read(types_log))
local snap = nodes.read_capture(read(nodes_tsv))
local st = structure.new(world, edefs)
print(string.format("capture %d nodes (children: %s); read in %.1f s", #snap.nodes, tostring(snap.has_children), os.clock() - t0))

-- the capture's own parts by (category, owner): what is left of each node when its parents are taken
-- out (stellar.graph.nodes, with the capture's children or by content)
local t1 = os.clock()
local cap = nodes.build(core.new(), defs, snap)
cap:materialize()
local captured = {}
for _, n in ipairs(snap.nodes) do
    local h = cap.holders[n.id]
    local parts = {}
    for name, values in pairs(h.sources) do
        parts[#parts + 1] = { name = name, mult = 100000, filter = -1, values = values }
    end
    captured[mw.category_of(n) .. ":" .. n.owner] = parts
end
local function from_capture(category, owner)
    return captured[category .. ":" .. owner]
end
print(string.format("the capture's own parts in %.1f s", os.clock() - t1))

-- (1) the structure on its own
t1 = os.clock()
local wg = mw.build(core.new(), defs, st, from_capture)
print(string.format("world graph: %d nodes, %d links (%d parents not in the world), %d own parts; built in %.1f s",
    wg.stats.nodes, wg.stats.links, wg.stats.missing_parents, wg.stats.parts, os.clock() - t1))
print(mw.format(mw.compare(wg, snap, defs), "(1) the world's structure, the capture's own parts:"))

-- (2) the computed own parts where engine.modifiers models the category
t1 = os.clock()
local src = modifiers.new({ types = defs, game_dir = game_dir, fs = fs })
local node_of = {}
for _, n in ipairs(snap.nodes) do
    node_of[n.category .. ":" .. tostring(n.owner)] = n.id
end
-- a multiplier that is another modifier's value, read from the capture's graph (as check.lua does)
src.resolve_ref = function(ref)
    local key
    if ref.scope == "this" then
        local c = ({ pop_group = "PopGroup", planet = "Planet", country = "Country" })[ref.kind]
        key = c and (c .. ":" .. tostring(ref.id))
    elseif ref.scope == "planet" and ref.kind == "pop_group" then
        key = "Colony:" .. tostring(world.field(world.object("pop_group", ref.id), "planet"))
    elseif ref.scope == "owner" and ref.kind == "pop_group" then
        local colony = world.field(world.object("pop_group", ref.id), "planet")
        local planet = src.planet_of_colony[colony]
        key = "Country:" .. tostring(planet and world.field(world.object("planet", planet), "owner"))
    end
    local id = key and node_of[key]
    return id and cap.tree:get(cap.holders[id], ref.type) or nil
end
local modelled = {}
for _, c in ipairs(modifiers.CATEGORIES) do
    modelled[c] = true
end
local wg2 = mw.build(core.new(), defs, st, function(category, owner)
    if modelled[category] then
        return src:parts(category, owner)
    end
    return from_capture(category, owner)
end)
print(string.format("world graph with computed own parts (%s) built in %.1f s", table.concat(modifiers.CATEGORIES, ", "),
    os.clock() - t1))
print(mw.format(mw.compare(wg2, snap, defs), "(2) the world's structure, computed own parts where modelled:"))

-- (3) the world alone: computed own parts where modelled, none for the other categories
t1 = os.clock()
local wg3 = mw.build(core.new(), defs, st, function(category, owner)
    if modelled[category] then
        return src:parts(category, owner)
    end
    return nil
end)
print(mw.format(mw.compare(wg3, snap, defs), string.format(
    "(3) the world alone (own parts of the categories not modelled: none; built in %.1f s):", os.clock() - t1)))

-- (4) mw.world_graph, as the engine reads its modifiers: the world alone, the multipliers that are
-- another modifier's value read from its own graph, not the capture's
t1 = os.clock()
local wg4 = mw.world_graph({ defs = defs, world = world, edefs = edefs, fs = fs, st = st })
print(mw.format(mw.compare(wg4, snap, defs), string.format(
    "(4) mw.world_graph (the multipliers from its own graph; built twice in %.1f s):", os.clock() - t1)))
-- mw.values against the tree, on every node
local checked, wrong, read_nodes = 0, 0, 0
for key, h in pairs(wg4.holders) do
    local category, owner = key:match("^(.-):(.*)$")
    read_nodes = read_nodes + 1
    for name, v in pairs(mw.values(wg4, category, tonumber(owner) or owner) or {}) do
        checked = checked + 1
        if wg4.tree:get(h, name) ~= math.floor(v * 100000 + 0.5) then
            wrong = wrong + 1
        end
    end
end
print(string.format("mw.values: %d values of %d nodes read, %d not the tree's", checked, read_nodes, wrong))
print(string.format("total %.1f s", os.clock() - t0))
