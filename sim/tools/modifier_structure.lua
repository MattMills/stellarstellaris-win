-- sim/tools/modifier_structure.lua : the modifier nodes and links engine.modifiers.structure derives
-- from a save, against the game's own (a capture with children: stellar.modifier_capture, the
-- nodes' _ChildNodes), with a plain LuaJIT.
--
--   luajit sim/tools/modifier_structure.lua
--     STELLAR_SAVE    the save (default /opt/stellaris-saves/autosave_2211.07.01.sav)
--     MODCHECK_NODES  the capture of the same moment, with children
--                     (default /opt/stellaris-captures/modifier-nodes-2211.07.01-edges.tsv)
--
-- Per category: the game's nodes and the world's (by owner). Per kind of link (child < parent):
-- the game's edges, the world's, matched, missing (the game's only), extra (the world's only), and
-- for the matched edges whose parent added a part, whether the part's filter is the world's.

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
RUST.date = RUST.date or function() return 0 end
RUST.rand = RUST.rand or function() return 0 end
E = E or {}

local function env(k, d)
    local v = os.getenv(k)
    return (v and v ~= "") and v or d
end
local game_dir = env("STELLARIS_DIR", "/opt/stellaris")
local save = env("STELLAR_SAVE", "/opt/stellaris-saves/autosave_2211.07.01.sav")
local nodes_tsv = env("MODCHECK_NODES", "/opt/stellaris-captures/modifier-nodes-2211.07.01-edges.tsv")

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
-- the engine as sim/src/runtime.rs loads it: the script layer, the definitions, the world
local engine = require("engine")
engine.load(game_dir, read(save))
local world = require("engine.world")
local defs = require("engine.defs")
local nodes = require("stellar.graph.nodes")
local snap = nodes.read_capture(read(nodes_tsv))
assert(snap.has_children, "the capture has no children")
local structure = require("engine.modifiers.structure")
local st = structure.new(world, defs)
print(string.format("world %s and capture (%d nodes) read in %.1f s", tostring(world.meta.date), #snap.nodes, os.clock() - t0))

-- nodes: the game's by (category, owner), the world's
local game_key, by_id = {}, {}
local game_cats, world_cats = {}, {}
for _, n in ipairs(snap.nodes) do
    by_id[n.id] = n
    local k = n.category .. ":" .. tostring(n.owner)
    game_key[k] = n
    game_cats[n.category] = (game_cats[n.category] or 0) + 1
end
local world_nodes = st:nodes()
local world_key = {}
for _, n in ipairs(world_nodes) do
    local k = n.category .. ":" .. tostring(n.owner)
    world_key[k] = n
    world_cats[n.category] = (world_cats[n.category] or 0) + 1
end
local cats = {}
for c in pairs(game_cats) do
    cats[c] = true
end
for c in pairs(world_cats) do
    cats[c] = true
end
local list = {}
for c in pairs(cats) do
    list[#list + 1] = c
end
table.sort(list)
print("nodes (category: game, world, both):")
for _, c in ipairs(list) do
    local both = 0
    for k, n in pairs(game_key) do
        if n.category == c and world_key[k] then
            both = both + 1
        end
    end
    print(string.format("  %-26s %6d %6d %6d", c, game_cats[c] or 0, world_cats[c] or 0, both))
end

-- edges: the game's (parent's children), the world's (st:parents)
local kinds = {}
local function kind(k)
    local e = kinds[k]
    if e == nil then
        e = { game = 0, world = 0, matched = 0, missing = {}, extra = {}, filter_ok = 0, filter_bad = {}, nmissing = 0,
            nextra = 0, nfilter_bad = 0 }
        kinds[k] = e
    end
    return e
end
local game_edges = {}
for _, p in ipairs(snap.nodes) do
    for _, c in ipairs(p.children or {}) do
        local child = by_id[c]
        if child then
            local ek = child.category .. ":" .. child.owner .. "<" .. p.category .. ":" .. p.owner
            game_edges[ek] = { child = child, parent = p }
            kind(child.category .. "<" .. p.category).game = kind(child.category .. "<" .. p.category).game + 1
        end
    end
end
local world_edges = {}
for _, n in ipairs(world_nodes) do
    for _, l in ipairs(st:parents(n.category, n.owner)) do
        local ek = n.category .. ":" .. n.owner .. "<" .. l.category .. ":" .. l.owner
        world_edges[ek] = l
        local e = kind(n.category .. "<" .. l.category)
        e.world = e.world + 1
    end
end
local function sample(listt, text)
    if #listt < 4 then
        listt[#listt + 1] = text
    end
end
for ek, ge in pairs(game_edges) do
    local e = kind(ge.child.category .. "<" .. ge.parent.category)
    local wl = world_edges[ek]
    if wl then
        e.matched = e.matched + 1
        -- the part that is the parent's clone, if any: its filter against the world's
        local pkey = nodes.key_of(ge.parent.values)
        for _, part in ipairs(ge.child.parts) do
            if pkey ~= "" and nodes.key_of(part.values) == pkey then
                if part.filter == wl.filter or (part.filter == -1 and wl.filter == -1) then
                    e.filter_ok = e.filter_ok + 1
                else
                    e.nfilter_bad = e.nfilter_bad + 1
                    sample(e.filter_bad, string.format("%s: game %d, world %d", ek, part.filter, wl.filter))
                end
                break
            end
        end
    else
        e.nmissing = e.nmissing + 1
        sample(e.missing, ek .. (next(ge.parent.values) and " (parent has values)" or ""))
    end
end
for ek in pairs(world_edges) do
    if not game_edges[ek] then
        local k = ek:match("^([^:]+):[^<]+<([^:]+):")
        local child_cat, parent_cat = ek:match("^([^:]+):[^<]+<([^:]+):")
        local e = kind(child_cat .. "<" .. parent_cat)
        e.nextra = e.nextra + 1
        sample(e.extra, ek)
    end
end
local klist = {}
for k, e in pairs(kinds) do
    klist[#klist + 1] = { k, e }
end
table.sort(klist, function(a, b) return a[2].game > b[2].game end)
local tg, tm = 0, 0
print("links (kind: game, world, matched, missing, extra; filters of the matched with a part: ok / wrong):")
for _, x in ipairs(klist) do
    local k, e = x[1], x[2]
    tg, tm = tg + e.game, tm + e.matched
    print(string.format("  %-42s %6d %6d %6d %6d %6d   filters %d / %d", k, e.game, e.world, e.matched, e.nmissing, e.nextra,
        e.filter_ok, e.nfilter_bad))
    for _, s in ipairs(e.missing) do
        print("      missing " .. s)
    end
    for _, s in ipairs(e.extra) do
        print("      extra   " .. s)
    end
    for _, s in ipairs(e.filter_bad) do
        print("      filter  " .. s)
    end
end
print(string.format("%d of the game's %d edges derived from the world (%.1f%%), in %.1f s", tm, tg, 100 * tm / math.max(tg, 1),
    os.clock() - t0))
