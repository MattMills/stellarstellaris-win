-- modifier_capture.lua : the game's modifier nodes as they are, for a simulation to be checked
-- against (docs/modifiers.md, "Per-object modifier nodes").
--
-- Every object with modifiers (country, planet, colony, pop group, fleet, ship, leader, starbase,
-- ...) has a node in the node manager's registry: its category, its owner (the object's id, as in
-- the save), its value set (CModifier: type -> fixed-point value, 1.0 = 100000) and, for nodes
-- that keep it, the breakdown (_Added: each part added, with its multiplier and category filter,
-- and the values it added). capture.dump writes them all, one node a line; with the same save read
-- by the simulation, the two can be compared value by value.
--
--   local capture = require("stellar.modifier_capture")
--   local where = assert(capture.locate(found, stellar.read))   -- before anything hooks Invalidate
--   capture.dump(where, path, type_names)                         -- a game loaded, paused

local ffi = require("ffi")
local fnmatch = require("fnmatch")

local capture = {}

local BASE = "NModifierNode::CModifierNodeBase<CModifier,enum EModifierNodeCategory>::"
local MANAGER = "NModifierNode::CModifierNodeManager<CModifier,enum EModifierNodeCategory>::"
capture.FUNCTIONS = {
    invalidate = BASE .. "Invalidate",
    node_update = BASE .. "Update",
    mark = MANAGER .. "MarkNodeAsInvalid",
    update = MANAGER .. "Update",
}

-- EModifierNodeCategory (4.5.2 PDB)
capture.CATEGORIES = {
    [0] = "CountryRelayNetwork", "Country", "GalacticObjectTimed", "GalacticObjectLeader",
    "GalacticObjectCosmicStorm", "GalacticObjectPsionicAura", "GalacticObjectPopJob", "GalacticObjectBuilding",
    "LeaderSkill", "Federation", "GalacticCommunity", "EspionageOperation", "Sector", "SpyNetwork", "Orbital",
    "CosmicStorm", "Planet", "Colony", "AstralRift", "Leader", "MegaStructure", "MegaStructureSystem", "PopGroup",
    "Fleet", "StarbaseExternal", "StarbaseCountry", "StarbaseSystem", "StarbasePlanet", "StarbaseDefensePlatform",
    "Starbase", "Army", "Ship", "WaystationNetworkSystem", "WaystationNetworkCountry",
}

-- capture.locate(found, read) -> where | nil, message: the functions, and the manager's instance
-- (CModifierNodeBase::Invalidate: mov rcx, [rip+_pInstance]; call MarkNodeAsInvalid)
function capture.locate(found, read)
    local where = {}
    for key, name in pairs(capture.FUNCTIONS) do
        where[key] = found[name]
        if where[key] == nil then
            return nil, name .. " not found"
        end
    end
    local bytes, pos, last_load = read(where.invalidate, 256), 1, nil
    while bytes and pos <= #bytes - 15 do
        local i = fnmatch.decode(bytes, where.invalidate, pos)
        if i == nil or i.flow == "return" and where.instance then
            break
        end
        if i.rip_relative and i.target and i.text:match("^mov rcx,") then
            last_load = i.target
        elseif i.flow == "call" and i.target == where.mark and last_load then
            where.instance = last_load
            break
        end
        pos = pos + i.length
    end
    if where.instance == nil then
        return nil, "the node manager's instance not found in CModifierNodeBase::Invalidate"
    end
    return where
end

-- the layouts (4.5.2): the manager's registry (data +8, count +20; 24-byte entries, the node at
-- +8); a node (its type +0, whose category is at +8; id +8, -1 unregistered; owner +0xc; the value
-- set +0x50; invalidated +0x108); a value set (entries: data +0x38, count +0x44, 16 bytes each:
-- value int64, type int32; the breakdown _Added: data +0x90, count +0x9c, 32 bytes each: the
-- part's value set, multiplier int64, name, category filter int32 +0x18)
local function ptr(p, off)
    return ffi.cast("uint8_t **", p + off)[0]
end
local function i32(p, off)
    return ffi.cast("int32_t *", p + off)[0]
end
local function i64(p, off)
    return ffi.cast("int64_t *", p + off)[0]
end

local function entries_of(set, type_names)
    local data, count = ptr(set, 0x38), i32(set, 0x44)
    if data == nil or count <= 0 or count > 100000 then
        return {}, 0
    end
    local out = {}
    for k = 0, count - 1 do
        local e = data + k * 16
        local t = i32(e, 8)
        out[#out + 1] = string.format("%s=%d", type_names and type_names[t] or tostring(t), tonumber(i64(e, 0)))
    end
    return out, count
end

-- capture.manager(where) -> the manager, or nil before a game exists
function capture.manager(where)
    local m = ptr(ffi.cast("uint8_t *", where.instance), 0)
    return m ~= nil and m or nil
end

-- capture.count(where) -> registered nodes, by category name
function capture.count(where)
    local m = capture.manager(where)
    if m == nil then
        return 0, {}
    end
    local data, count = ptr(m, 8), i32(m, 20)
    local total, by = 0, {}
    for k = 0, count - 1 do
        local node = ptr(data + k * 24, 8)
        if node ~= nil and i32(node, 8) ~= -1 then
            local c = capture.CATEGORIES[i32(ptr(node, 0), 8)] or "?"
            by[c] = (by[c] or 0) + 1
            total = total + 1
        end
    end
    return total, by
end

-- the children of a node: the ids of the nodes that read it (_ChildNodes +0x128, a
-- CPdxUnorderedSet<uint>: a robin-hood table, entries +0x130, _TableMod +0x13c, _MaxDistancePlus1
-- +0x140; _TableMod + 1 + _MaxDistancePlus1 slots of 8 bytes, the distance + 1 (0: empty) and the
-- id at +4, as CModifierNodeBase::InvalidateChildren walks them). -> the registry indices of the
-- live ones, and how many were dead (the registry's id at that index is another version)
local function children_of(node, registry, count)
    local entries = ptr(node, 0x130)
    local slots = i32(node, 0x13c) + 1 + ffi.cast("uint8_t *", node + 0x140)[0]
    local out, dead = {}, 0
    if entries == nil or slots <= 0 or slots > 4000000 then
        return out, dead
    end
    for k = 0, slots - 1 do
        local e = entries + k * 8
        if e[0] ~= 0 then
            local id = ffi.cast("uint32_t *", e + 4)[0]
            local index = bit.band(id, 0xFFFFF)
            if index < count and ffi.cast("uint32_t *", registry + index * 24)[0] == id and ptr(registry + index * 24, 8) ~= nil then
                out[#out + 1] = index
            else
                dead = dead + 1
            end
        end
    end
    return out, dead
end
capture.children_of = children_of

-- capture.dump(where, path, type_names) -> nodes, values, parts, edges, dead | nil, message: one
-- line per registered node: id, category, owner, invalidated, its values, each part of its
-- breakdown (multiplier|filter|values), its children (the ids of the nodes that read it), the
-- depth and the category filter of its value set
function capture.dump(where, path, type_names)
    local m = capture.manager(where)
    if m == nil then
        return nil, "no node manager (no game)"
    end
    local f = io.open(path, "w")
    if f == nil then
        return nil, "cannot write " .. path
    end
    f:write("id\tcategory\towner\tinvalid\tvalues\tparts\tchildren\tdepth\tcategories\n")
    local data, count = ptr(m, 8), i32(m, 20)
    local nodes, values, parts, edges, dead = 0, 0, 0, 0, 0
    for k = 0, count - 1 do
        local node = ptr(data + k * 24, 8)
        if node ~= nil and i32(node, 8) ~= -1 then
            local set = node + 0x50
            local own, n = entries_of(set, type_names)
            local added, added_count = {}, i32(set, 0x88 + 0x14)
            local added_data = ptr(set, 0x88 + 8)
            if added_data ~= nil and added_count > 0 and added_count < 10000 then
                for a = 0, added_count - 1 do
                    local p = added_data + a * 32
                    local part = ptr(p, 0)
                    local vals = part ~= nil and entries_of(part, type_names) or {}
                    added[#added + 1] = string.format("%d|%d|%s", tonumber(i64(p, 8)), i32(p, 0x18), table.concat(vals, ","))
                end
                parts = parts + added_count
            end
            local children, d = children_of(node, data, count)
            edges, dead = edges + #children, dead + d
            f:write(string.format("%d\t%s\t%d\t%d\t%s\t%s\t%s\t%d\t%d\n", bit.band(i32(node, 8), 0xFFFFF),
                capture.CATEGORIES[i32(ptr(node, 0), 8)] or "?", i32(node, 0xc), ffi.cast("uint8_t *", node + 0x108)[0],
                table.concat(own, ","), table.concat(added, ";"), table.concat(children, ","), i32(set, 0xa8), i32(set, 0xac)))
            nodes, values = nodes + 1, values + n
        end
    end
    f:close()
    return nodes, values, parts, edges, dead
end

-- reading nodes into Lua tables (stellar.graph.nodes snapshots, types by their index) -------------

-- a value set: { [type] = value }
local function value_map(set)
    local data, count = ptr(set, 0x38), i32(set, 0x44)
    local out = {}
    if data == nil or count <= 0 or count > 100000 then
        return out
    end
    for k = 0, count - 1 do
        local e = data + k * 16
        local t = i32(e, 8)
        out[t] = (out[t] or 0) + tonumber(i64(e, 0))
    end
    return out
end

-- capture.registry(where) -> the registry's data and count, or nil before a game exists
function capture.registry(where)
    local m = capture.manager(where)
    if m == nil then
        return nil
    end
    return ptr(m, 8), i32(m, 20)
end

-- capture.node_at(registry, count, index) -> the node at a registry index (registered), and its full
-- id (the index in the low 20 bits, a version above)
function capture.node_at(registry, count, index)
    if index < 0 or index >= count then
        return nil
    end
    local node = ptr(registry + index * 24, 8)
    if node == nil or i32(node, 8) == -1 then
        return nil
    end
    return node, ffi.cast("uint32_t *", node + 8)[0]
end

-- capture.read_values(node) -> { [type] = value }: a node's values only
function capture.read_values(node)
    return value_map(node + 0x50)
end

-- capture.read_node(node, registry, count) -> { id (the registry index), full_id, category, owner,
-- invalid, values, parts = { { mult, filter, values } }, children = { index }, depth, categories, address }
function capture.read_node(node, registry, count)
    local set = node + 0x50
    local full = ffi.cast("uint32_t *", node + 8)[0]
    local n = { id = bit.band(full, 0xFFFFF), full_id = full, category = capture.CATEGORIES[i32(ptr(node, 0), 8)] or "?",
        owner = i32(node, 0xc), invalid = ffi.cast("uint8_t *", node + 0x108)[0] ~= 0, values = value_map(set), parts = {},
        depth = i32(set, 0xa8), categories = i32(set, 0xac), address = node }
    local added_count, added_data = i32(set, 0x88 + 0x14), ptr(set, 0x88 + 8)
    if added_data ~= nil and added_count > 0 and added_count < 10000 then
        for a = 0, added_count - 1 do
            local p = added_data + a * 32
            local part = ptr(p, 0)
            n.parts[#n.parts + 1] = { mult = tonumber(i64(p, 8)), filter = i32(p, 0x18),
                values = part ~= nil and value_map(part) or {} }
        end
    end
    n.children = children_of(node, registry, count)
    return n
end

-- capture.snapshot(where) -> snapshot (stellar.graph.nodes) of every registered node | nil, message
function capture.snapshot(where)
    local registry, count = capture.registry(where)
    if registry == nil then
        return nil, "no node manager (no game)"
    end
    local snap = { nodes = {}, has_children = true }
    for k = 0, count - 1 do
        local node = capture.node_at(registry, count, k)
        if node ~= nil then
            snap.nodes[#snap.nodes + 1] = capture.read_node(node, registry, count)
        end
    end
    return snap
end

-- capture.children_index(where) -> { [child index] = { parent index, ... } }: every node's children,
-- read now (the edges AddModifierNode registered)
function capture.children_index(where)
    local registry, count = capture.registry(where)
    local parents = {}
    if registry == nil then
        return parents
    end
    for k = 0, count - 1 do
        local node = capture.node_at(registry, count, k)
        if node ~= nil then
            for _, c in ipairs((children_of(node, registry, count))) do
                local list = parents[c]
                if list == nil then
                    list = {}
                    parents[c] = list
                end
                list[#list + 1] = k
            end
        end
    end
    return parents
end

-- capture.definitions(index_where, names) -> defs (stellar.graph.modifiers.definitions) of the game's
-- modifier types by index, with their categories from _Definitions (stellar.modifier_index.locate:
-- data and size; 176-byte CPdxModifierDefinition, _Category at +0x9c); names: { [index] = name } or nil
function capture.definitions(index_where, names)
    local defs = require("stellar.graph.modifiers").definitions()
    local data = ptr(ffi.cast("uint8_t *", index_where.data), 0)
    local count = ffi.cast("int32_t *", index_where.size)[0]
    for k = 0, count - 1 do
        local name = names and names[k] or ("#" .. k)
        defs.names[k] = name
        defs.ids[name] = k
        defs.cats[k] = i32(data + k * 176, 0x9c)
    end
    defs.n = count
    return defs, count
end

-- capture.stats_hook(where) -> true | nil, message: the counts of what the nodes cost over time
-- (src/dll/modifier_stats.cpp: recomputes and their time by category, marks by category and by
-- caller, the manager's passes)
function capture.stats_hook(where)
    return require("stellar").modifier_stats_hook(where.node_update, where.mark, where.update)
end

-- capture.stats_report(stats, base, top) -> text: one line of what stellar.modifier_stats gave
-- (callers as +rva of the game, the `top` most marking)
function capture.stats_report(stats, base, top)
    local cats, recomputed, seconds, marked = {}, 0, 0, 0
    for c, s in pairs(stats.categories or {}) do
        recomputed, seconds, marked = recomputed + s.recomputed, seconds + s.seconds, marked + s.marked
        cats[#cats + 1] = { capture.CATEGORIES[c] or tostring(c), s }
    end
    table.sort(cats, function(a, b) return a[2].seconds > b[2].seconds end)
    local parts = {}
    for i = 1, math.min(#cats, 8) do
        local s = cats[i][2]
        parts[i] = string.format("%s %d in %.1f ms (%d marked)", cats[i][1], s.recomputed, s.seconds * 1000, s.marked)
    end
    local callers = {}
    for address, n in pairs(stats.callers or {}) do
        callers[#callers + 1] = { address, n }
    end
    table.sort(callers, function(a, b) return a[2] > b[2] end)
    local by = {}
    for i = 1, math.min(#callers, top or 6) do
        by[i] = string.format("+%x %d", callers[i][1] - base, callers[i][2])
    end
    return string.format("%d passes in %.1f ms; %d nodes recomputed in %.1f ms (%d calls on valid nodes), %d marks; %s; marked from %s",
        stats.passes, stats.pass_seconds * 1000, recomputed, seconds * 1000, stats.valid_calls, marked,
        table.concat(parts, ", "), table.concat(by, ", "))
end

-- capture.type_names(path) -> { [type] = name } from a modifiers.log (line k of the list is type k)
function capture.type_names(path)
    local f = io.open(path, "r")
    if f == nil then
        return nil
    end
    local names, k = {}, 0
    for line in f:lines() do
        local name = line:match("^%[?[%d:]*%]?%- ([%w_]+), Category:") or line:match("^%- ([%w_]+), Category:")
        if name then
            names[k] = name
            k = k + 1
        end
    end
    f:close()
    return names
end

return capture
