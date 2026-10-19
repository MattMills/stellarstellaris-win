-- engine/script/objects.lua : the engine side of the effects that make the game's objects
-- (simscript/handlers/objects*.lua queue them; docs/script_objects.md has each effect's semantics
-- from the 4.5.2 Linux build). The appliers are registered in engine.systems.effects under the
-- queued effect's type by the domain files this loads (engine/script/objects_<domain>.lua) and
-- applied at the barrier (E.flush) to the world in the save's own form.
--
--   local objects = require("engine.script.objects")
--   objects.report()

local world = require("engine.world")
local defs = require("engine.defs")
local systems = require("engine.systems")

world.KINDS.ambient_object = world.KINDS.ambient_object or "ambient_object"
world.KINDS.bypass = world.KINDS.bypass or "bypasses"
world.KINDS.natural_wormhole = world.KINDS.natural_wormhole or "natural_wormholes"
world.KINDS.ship_design = world.KINDS.ship_design or "ship_design"

local objects = {
    stats = {},     -- effect type -> { applied =, skipped = { [why] = n } }
    errors = {},
}

local NO_ID = 4294967295
objects.NO_ID = NO_ID

local function unq(v)
    if type(v) == "string" then
        return (v:gsub('^"(.*)"$', "%1"))
    end
    return v
end
objects.unq = unq

local function stat(kind)
    local s = objects.stats[kind]
    if not s then
        s = { applied = 0, skipped = {} }
        objects.stats[kind] = s
    end
    return s
end
-- objects.applied(kind[, value]) -> value or true: the effect did its work
function objects.applied(kind, value)
    local s = stat(kind)
    s.applied = s.applied + 1
    if value == nil then return true end
    return value
end
-- objects.skipped(kind, why) -> nil: the effect did nothing (the game's own no-ops: an unknown
-- type, a missing scope, a check that fails), and why
function objects.skipped(kind, why)
    local s = stat(kind)
    s.skipped[why] = (s.skipped[why] or 0) + 1
    return nil
end
function objects.err(msg)
    if #objects.errors < 20 then
        objects.errors[#objects.errors + 1] = msg
    end
end

-- the draws of the game's generator (CRandom, the global stream: RUST.rand)
objects.draws = 0
function objects.draw()
    objects.draws = objects.draws + 1
    return RUST.rand()
end

-- objects.new_id(store) -> the id a new object of the store takes (CPdxObjectDatabase: the next
-- index, generation 0 for a store that never freed one [I]); the store made if the save has none
function objects.new_id(store)
    world.ensure_store(store)
    return world.next_index(store)
end

-- objects.create(store, block) -> id: a new object at the store's end
function objects.create(store, block)
    local id = objects.new_id(store)
    world.create(store, id, block)
    return id
end

-- objects.set_meta(key, value): a top-level value of the save (`last_created_country = 3`), in the
-- tree (written back) and in world.meta
function objects.set_meta(key, value)
    world.meta[key] = tostring(value)
    local tree = world.tree
    if not tree then return end
    for _, e in ipairs(tree) do
        if e.op and e.key and e.key.text == key and e.value.text ~= nil then
            e.value.text = tostring(value)
            return
        end
    end
    tree[#tree + 1] = { key = { text = key }, op = "=", value = { text = tostring(value) } }
end

-- a reference as the save writes it: an id, or nil for none
function objects.ref(v)
    v = tonumber(v)
    return (v and v ~= NO_ID) and v or nil
end

-- a definition's block (engine.defs), or nil
function objects.def(folder, key)
    local d = key and defs.get(folder, key)
    return d and d.block or nil
end

-- objects.ordered(folder) -> { { name, definition } ... } in the game's database order (the files
-- in load order, then their line), cached
local ordered_cache = {}
function objects.ordered(folder)
    local l = ordered_cache[folder]
    if l then return l end
    l = {}
    for name, d in pairs(defs.folder(folder)) do
        l[#l + 1] = { name, d }
    end
    table.sort(l, function(a, b)
        local fa, fb = tostring(a[2].file), tostring(b[2].file)
        if fa ~= fb then return fa < fb end
        return (a[2].line or 0) < (b[2].line or 0)
    end)
    ordered_cache[folder] = l
    return l
end

-- the list block `key = { }` of obj, made when missing
function objects.list_of(obj, key)
    local l = world.field(obj, key)
    if type(l) ~= "table" then l = world.child(obj, key) end
    return l
end

-- an on_action through the script layer: this and from as eval scopes (or nil)
function objects.on_action(name, this, from)
    local ok, err = pcall(function()
        local events = package.loaded["simscript.events"] or require("simscript.events")
        local eval = package.loaded["simscript.eval"] or require("simscript.eval")
        events.on_action(name, this, from and eval.new_ctx(from) or nil)
    end)
    if not ok then objects.err(name .. ": " .. tostring(err)) end
end

-- the modifier nodes the objects feed (a carrier's deposits, districts, buildings, pops): a change
-- marks them stale (objects.touch); a read of a modifier value by script (check_modifier_value,
-- export_modifier_to_variable) first brings the world's graph up to date (objects.fresh), as the
-- game's carrier refresh does when a deposit or district is added (CColonyCarrier vfunc 0xa0,
-- CColony::UpdateModifier after the jobs pass) [I]
objects.stale = false
function objects.touch()
    objects.stale = true
end
function objects.fresh()
    if not objects.stale then return end
    objects.stale = false
    local engine = package.loaded["engine"]
    local source = engine and engine.modifier_source
    if source and source.rebuild then
        local t0 = RUST.clock()
        local ok, err = pcall(source.rebuild)
        if not ok then objects.err("modifier rebuild: " .. tostring(err)) end
        objects.rebuilds = (objects.rebuilds or 0) + 1
        objects.rebuild_seconds = (objects.rebuild_seconds or 0) + RUST.clock() - t0
    end
end
-- the appliers that change what a carrier's modifiers come from, wrapped to mark them stale
local function touching(name)
    local f = systems.effects[name]
    if f and not objects.wrapped[name] then
        objects.wrapped[name] = true
        systems.effects[name] = function(t)
            local r = f(t)
            if r ~= nil and r ~= false then objects.touch() end
            return r
        end
    end
end
objects.wrapped = {}
objects.touching = touching

-- the domains (they require this module: it is registered first)
package.loaded["engine.script.objects"] = objects
for _, name in ipairs({ "colony", "fleets", "leaders", "countries", "galaxy", "starbase" }) do
    local mod = "engine.script.objects_" .. name
    local ok, err = pcall(require, mod)
    if not ok and not tostring(err):find("module '" .. mod .. "' not found", 1, true) then
        error(err, 0)
    end
end

-- what changes a carrier's modifiers: marks them stale
require("engine.script.creation")
-- (what the start script reads, the carriers' district caps, comes from the deposits, the planet
-- class and the timed modifiers: districts, buildings and pops do not mark the graph stale, which
-- would cost a rebuild of the whole graph for each read in game_start.12) [I]
for _, n in ipairs({ "add_deposit", "remove_deposit", "clear_deposits", "change_pc", "add_timed_modifier",
    "remove_timed_modifier", "clear_blockers", "add_blocker", "change_planet_size", "set_deposit" }) do
    touching(n)
end

function objects.report()
    local parts = {}
    local keys = {}
    for k in pairs(objects.stats) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
        local s = objects.stats[k]
        local sk = {}
        for why, n in pairs(s.skipped) do sk[#sk + 1] = string.format("%s %d", why, n) end
        table.sort(sk)
        parts[#parts + 1] = string.format("%s %d%s", k, s.applied, #sk > 0 and (" (skipped: " .. table.concat(sk, ", ") .. ")") or "")
    end
    local line = "script objects: " .. (#parts > 0 and table.concat(parts, "; ") or "nothing applied")
        .. string.format("; %d draws; %d modifier rebuilds in %.2f s", objects.draws, objects.rebuilds or 0, objects.rebuild_seconds or 0)
    for _, e in ipairs(objects.errors) do
        line = line .. "\n  error: " .. e
    end
    return line
end

return objects
