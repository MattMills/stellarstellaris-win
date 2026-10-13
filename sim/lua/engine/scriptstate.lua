-- engine/scriptstate.lua : the script layer's state (flags, variables) kept where the save keeps
-- it, on the objects of the world, so a save loaded is the script state the game had, and a save
-- written has what the script set.
--
-- - an object's flags: `flags = { name = <hour set> }`, or for a timed flag
--   `name = { flag_date = <hour set> flag_days = <days left> }` (engine.systems counts them down);
-- - the global flags: the save's top-level `flags = { ... }`, the same form;
-- - an object's variables: `variables = { name = value }`.
--
-- engine.load installs it over simscript.eval's own tables (eval.store).

local world = require("engine.world")

local scriptstate = {}

local function object(sc)
    if sc == nil or sc.kind == "none" then
        return nil
    end
    return world.object(sc.kind, sc.id)
end

-- the global flags' block (the save's top-level `flags`), made if there is none
local function global_flags(create)
    local f = world.meta.flags
    if type(f) == "table" then
        return f
    end
    if not create then
        return nil
    end
    f = {}
    world.tree[#world.tree + 1] = { key = { text = "flags" }, op = "=", value = f }
    world.meta.flags = f
    return f
end

local function flags_of(sc, create)
    if sc == nil then
        return global_flags(create)
    end
    local o = object(sc)
    if not o then
        return nil
    end
    if create then
        return world.child(o, "flags")
    end
    local f = world.field(o, "flags")
    return type(f) == "table" and f or nil
end

local function entry_of(block, name)
    for _, e in ipairs(block) do
        if e.op and e.key and e.key.text == name then
            return e
        end
    end
    return nil
end

local store = {}

function store.has_flag(sc, name)
    local f = flags_of(sc, false)
    return f ~= nil and #world.fields(f, name) > 0
end

function store.set_flag(sc, name, days)
    local f = flags_of(sc, true)
    if not f then
        return
    end
    local old = entry_of(f, name)
    if old then
        world.remove_entry(f, old)
    end
    local now = E.date()
    if days then
        local block = {}
        world.append(block, "flag_date", now)
        world.append(block, "flag_days", math.floor(days + 0.5))
        world.append(f, name, block)
    else
        world.append(f, name, now)
    end
end

function store.remove_flag(sc, name)
    local f = flags_of(sc, false)
    local e = f and entry_of(f, name)
    if e then
        world.remove_entry(f, e)
    end
end

function store.getvar(sc, name)
    local o = object(sc)
    local vars = o and world.field(o, "variables")
    if type(vars) ~= "table" then
        return nil
    end
    local v = world.field(vars, name)
    return type(v) == "number" and v or tonumber(v)
end

function store.setvar(sc, name, v)
    local o = object(sc)
    if not o then
        return
    end
    world.set(world.child(o, "variables"), name, v)
end

scriptstate.store = store

-- scriptstate.install(): the script layer reads and writes the world's flags and variables
function scriptstate.install()
    require("simscript.eval").store = store
end

return scriptstate
