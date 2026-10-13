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

-- capture.dump(where, path, type_names) -> nodes, values, parts | nil, message: one line per
-- registered node: id, category, owner, invalidated, its values, then each part of its
-- breakdown (multiplier|filter|values)
function capture.dump(where, path, type_names)
    local m = capture.manager(where)
    if m == nil then
        return nil, "no node manager (no game)"
    end
    local f = io.open(path, "w")
    if f == nil then
        return nil, "cannot write " .. path
    end
    f:write("id\tcategory\towner\tinvalid\tvalues\tparts\n")
    local data, count = ptr(m, 8), i32(m, 20)
    local nodes, values, parts = 0, 0, 0
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
            f:write(string.format("%d\t%s\t%d\t%d\t%s\t%s\n", bit.band(i32(node, 8), 0xFFFFF),
                capture.CATEGORIES[i32(ptr(node, 0), 8)] or "?", i32(node, 0xc), ffi.cast("uint8_t *", node + 0x108)[0],
                table.concat(own, ","), table.concat(added, ";")))
            nodes, values = nodes + 1, values + n
        end
    end
    f:close()
    return nodes, values, parts
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
