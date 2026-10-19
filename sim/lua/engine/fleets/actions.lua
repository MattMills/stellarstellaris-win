-- engine/fleets/actions.lua : the fleets' scripted actions (CFleetAction: queue_actions in the
-- scripts, `actions = { }` in the save), run as the game runs them, on every tick
-- (CFleet::MicroUpdateSerial, Linux 0x291f460, in fleet id order, before the movement). From the
-- disassembly of 4.5.2 (docs/re notes: actions_queue.md, actions_find_move_orbit.md,
-- actions_wait_automove.md) [V].
--
-- The queue: only its first action runs; Init once (the fleet's `action_initialized` property),
-- then Update in the same call; a finished action is removed and the next one starts on the next
-- tick. A container (repeat, find_planet) holds one `current` child, made lazily, one at a time.
--
--   actions.tick(host)                    every fleet's head action (systems.lua, micro.update)
--   actions.queue(fid, block, ctx)        the queue_actions effect: the block's actions appended
--   actions.clear(fid)                    clear_fleet_actions
--   actions.report()
--
-- Kinds: repeat, find_planet (find_planet / find_closest_planet / find_random_planet), move_to,
-- orbit_planet, wait, effect. find_system, find_fleet, attack, merge, destroy_planet, terraform:
-- not modelled (their CreateInstance is null: a repeat or find_planet holding one ends).

local world = require("engine.world")
local live = require("engine.store.live")

local actions = {
    stats = { ticks = 0, inits = 0, updates = 0, finished = 0, draws = 0, orders = 0, not_modelled = {},
        triggers_missing = {}, queued = 0, cleared = 0, effects = 0 },
}
local S = actions.stats

local function draw()
    S.draws = S.draws + 1
    return RUST.rand()
end

local function eval() return package.loaded["simscript.eval"] or require("simscript.eval") end
local function orders() return package.loaded["engine.fleets.orders"] or require("engine.fleets.orders") end

local function num(v) return tonumber(v) end
local function u32(x) return x % 4294967296 end

-- ---------------------------------------------------------------------------------------------
-- named triggers and effects (`trigger = { id = X ... }`): the game keeps them by id
-- (CTriggerDatabase::FindNamedTriggerInstance); here an index of every `id` block of the files
-- that queue actions, made once

local named
local function strip_id(block)
    local out = {}
    for _, e in ipairs(block) do
        if not (e.op and e.key and e.key.text == "id") then out[#out + 1] = e end
    end
    return out
end
local function index_tree(tree)
    if type(tree) ~= "table" then return end
    for _, e in ipairs(tree) do
        local v = e.value
        if e.op and type(v) == "table" and v.text == nil then
            for _, x in ipairs(v) do
                if x.op and x.key and x.key.text == "id" and x.value and x.value.text then
                    local id = x.value.text:gsub('^"(.*)"$', "%1")
                    if named[id] == nil then named[id] = strip_id(v) end
                end
            end
            index_tree(v)
        elseif not e.op and type(e) == "table" and e.text == nil then
            index_tree(e)
        end
    end
end
local function named_block(id)
    if not named then
        named = {}
        local defs = require("engine.defs")
        for _, folder in ipairs({ "common/scripted_effects", "common/solar_system_initializers",
            "common/scripted_triggers", "common/on_actions", "common/megastructures", "common/anomalies" }) do
            for _, d in pairs(defs.folder(folder) or {}) do
                index_tree(d.block)
            end
        end
        local source = require("stellar.script.source")
        if defs.fs then
            for _, f in ipairs(source.files(defs.fs, "events", "txt")) do
                local ok, tree = pcall(source.parse, defs.fs, f)
                if ok then index_tree(tree) end
            end
        end
    end
    return named[id]
end
actions.named_block = named_block

-- ---------------------------------------------------------------------------------------------
-- scopes: { kind, id, root = { kind, id }, from = { kind, id }, prev = scope | nil, block = the
-- save's scope block (kept as read) }

local KIND_OF_TYPE = { galactic_object = "system", fleet = "fleet", planet = "planet", country = "country",
    ship = "ship", leader = "leader", pop_group = "pop_group", starbase = "starbase", species = "species" }
local TYPE_OF_KIND = { system = "galactic_object" }

local function ref_of(b)
    if type(b) ~= "table" then return nil end
    local ty = world.field(b, "type")
    return { kind = KIND_OF_TYPE[ty] or ty, id = num(world.field(b, "id")) }
end
local function scope_from_block(b)
    local r = ref_of(b) or { kind = "none" }
    r.block = b
    r.root = ref_of(world.field(b, "root")) or { kind = r.kind, id = r.id }
    r.from = ref_of(world.field(b, "from"))
    local pb = world.field(b, "prev")
    r.prev = type(pb) == "table" and scope_from_block(pb) or nil
    return r
end
local function ref_block(key, r, crude)
    local b = {}
    world.append(b, "type", TYPE_OF_KIND[r.kind] or r.kind)
    world.append(b, "id", r.id or 4294967295)
    world.append(b, "opener_id", 4294967295)
    if crude then
        local rb = {}
        world.push(rb, "0")
        world.push(rb, tostring(crude))
        world.append(b, "random", rb)
        world.append(b, "random_allowed", "yes")
    end
    return b
end
-- the save's form of a scope made here (this, its random state, root, from, prev)
local function scope_block(sc)
    if sc.block then return sc.block end
    local b = ref_block("scope", sc, sc.crude)
    if sc.root then world.append(b, "root", ref_block("root", sc.root)) end
    if sc.from then world.append(b, "from", ref_block("from", sc.from)) end
    if sc.prev then world.append(b, "prev", scope_block(sc.prev)) end
    sc.block = b
    return b
end
-- the script context of a scope (this, root, from, prev)
local function ctx_of(sc)
    local E = eval()
    local ctx = E.new_ctx(E.S(sc.kind, sc.id), sc.from and E.S(sc.from.kind, sc.from.id) or nil)
    if sc.root and sc.root.id then ctx.root = E.S(sc.root.kind, sc.root.id) end
    if sc.prev and sc.prev.id then ctx.prev = E.S(sc.prev.kind, sc.prev.id) end
    return ctx
end
-- a script context back to a scope (queue_actions: the effect's own scope)
local function scope_of_ctx(ctx)
    local function r(s) return s and s.kind ~= "none" and { kind = s.kind, id = s.id } or nil end
    local sc = r(ctx.this) or { kind = "none" }
    sc.root = r(ctx.root)
    sc.from = r(ctx.from)
    sc.prev = r(ctx.prev)
    return sc
end
-- CCrudeRandom::Seed(r) (0x422b0a0): its state CNoiseRandom{ r, 0x5ea6ba9f }.GetNext(), as saved
local function crude_state(r)
    local h = RUST.noise_raw(u32(r), 0x5ea6ba9f)
    return u32(bit.bxor(h, bit.rshift(h, 8)))
end

-- ---------------------------------------------------------------------------------------------
-- data (the actions' templates: CFleetActionData), from the script (queue_actions) or the save
-- (`data = { }`). Each keeps the save's form of itself: key, value (a token or a block).

local parse_children

local DATA = {}

local function unquote(t) return type(t) == "string" and t:gsub('^"(.*)"$', "%1") or t end

-- trigger: a block with id (the script) or the id (the save)
local function named_of(v)
    if type(v) == "table" then
        local id = unquote(world.field(v, "id"))
        if id and named and named[id] == nil then named[id] = strip_id(v) end
        if id and not named then named_block(id); if named[id] == nil then named[id] = strip_id(v) end end
        return id and tostring(id) or nil
    end
    return v and tostring(unquote(v)) or nil
end

DATA.repeat_ = function(v)
    local d = { kind = "repeat", max = -1, children = {} }
    for _, e in ipairs(type(v) == "table" and v or {}) do
        if e.op and e.key then
            local k = e.key.text
            if k == "max_iterations" then d.max = num(e.value.text) or -1
            elseif k == "while" then d.while_id = named_of(e.value.text or e.value)
            else
                local c = parse_children and parse_children({ e })[1]
                if c then d.children[#d.children + 1] = c end
            end
        end
    end
    return d
end
local function find_planet_data(method)
    return function(v)
        local d = { kind = "find_planet", method = method, found = {}, failed = {} }
        for _, e in ipairs(type(v) == "table" and v or {}) do
            if e.op and e.key then
                local k = e.key.text
                if k == "trigger" then d.trigger_id = named_of(e.value.text or e.value)
                elseif k == "found_planet" then d.found = parse_children(e.value)
                elseif k == "failed" then d.failed = parse_children(e.value)
                elseif k == "method" then d.method = e.value.text == "random" and "random" or "closest"
                end
            end
        end
        return d
    end
end
DATA.find_planet = find_planet_data("closest")
DATA.find_closest_planet = find_planet_data("closest")
DATA.find_random_planet = find_planet_data("random")
DATA.move_to = function(v) return { kind = "move_to", target = v and v.text or "this" } end
DATA.orbit_planet = function(v) return { kind = "orbit_planet", target = v and v.text or "this" } end
DATA.wait = function(v)
    local d = { kind = "wait", duration = 0, random = 0 }
    if v and v.text then
        d.duration = num(v.text) or 0
    elseif type(v) == "table" then
        d.duration = num(world.field(v, "duration")) or 0
        d.random = num(world.field(v, "random")) or 0
    end
    return d
end
DATA.effect = function(v)
    local d = { kind = "effect" }
    if type(v) == "table" and v.text == nil then
        d.id = unquote(world.field(v, "id"))
        d.block = strip_id(v)
        if d.id and named_block(d.id) == nil then named[d.id] = d.block end
    else
        d.id = unquote(v and v.text)
    end
    return d
end

parse_children = function(block)
    local out = {}
    for _, e in ipairs(type(block) == "table" and block or {}) do
        if e.op and e.key then
            local k = e.key.text
            local f = DATA[k == "repeat" and "repeat_" or k]
            if f then
                out[#out + 1] = f(e.value)
            else
                -- kept as a data that makes no instance (the game's would; not modelled here)
                out[#out + 1] = { kind = k, unknown = true }
                S.not_modelled[k] = (S.not_modelled[k] or 0) + 1
            end
        end
    end
    return out
end
actions.parse = parse_children

-- the save's form of a data: key, value
local write_data
local function data_block(list)
    local b = {}
    for _, c in ipairs(list) do
        local k, v = write_data(c)
        if k then world.append(b, k, v) end
    end
    return b
end
write_data = function(d)
    if d.kind == "repeat" then
        local b = {}
        if d.while_id then world.append(b, "while", d.while_id, true) end
        world.append(b, "max_iterations", d.max)
        for _, c in ipairs(d.children) do
            local k, v = write_data(c)
            if k then world.append(b, k, v) end
        end
        return "repeat", b
    elseif d.kind == "find_planet" then
        local b = {}
        if d.trigger_id then world.append(b, "trigger", d.trigger_id, true) end
        if #d.found > 0 then world.append(b, "found_planet", data_block(d.found)) end
        if #d.failed > 0 then world.append(b, "failed", data_block(d.failed)) end
        world.append(b, "method", d.method)
        return "find_planet", b
    elseif d.kind == "move_to" or d.kind == "orbit_planet" then
        return d.kind, { text = d.target }
    elseif d.kind == "wait" then
        if (d.random or 0) == 0 then return "wait", { text = world.number_text(d.duration) } end
        local b = {}
        world.append(b, "duration", d.duration)
        world.append(b, "random", d.random)
        return "wait", b
    elseif d.kind == "effect" then
        return "effect", { text = tostring(d.id), quoted = true }
    end
    return nil
end

-- ---------------------------------------------------------------------------------------------
-- the fleet's things the actions read

local function fleet(fid) return world.object("fleet", fid) end
local function coord_of(b)
    if type(b) ~= "table" then return nil end
    return { x = num(world.field(b, "x")) or 0, y = num(world.field(b, "y")) or 0, origin = num(world.field(b, "origin")) }
end
local function fleet_coord(f) return coord_of(world.path(f, "movement_manager", "coordinate")) end
local function planet_coord(pid)
    local p = world.object("planet", pid)
    return p and coord_of(world.field(p, "coordinate"))
end
local function dist_sq(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return dx * dx + dy * dy
end
local function system_planets(sid)
    local g = sid and world.object("galactic_object", sid)
    local out = {}
    for _, p in ipairs(g and world.fields(g, "planet") or {}) do
        local pid = num(p)
        if pid then out[#out + 1] = pid end
    end
    return out
end
local function orbit_target(f)
    local ob = world.path(f, "movement_manager", "orbit", "orbitable")
    return type(ob) == "table" and num(world.field(ob, "planet")) or nil
end
local function current_order_type(fid)
    local ty = orders().current(fid)
    return ty
end
local function system_of_scope(sc)
    if sc.kind == "system" then return sc.id end
    if sc.kind == "planet" then
        local c = planet_coord(sc.id)
        return c and c.origin
    end
    if sc.kind == "fleet" then
        local c = fleet_coord(fleet(sc.id))
        return c and c.origin
    end
    return nil
end

-- ---------------------------------------------------------------------------------------------
-- instances (CFleetAction): { kind, data, done, ... }; create(data, scope) -> instance | nil

local CREATE, INIT, UPDATE, WRITE, READ = {}, {}, {}, {}, {}

local function create(d, sc)
    local f = CREATE[d.kind]
    if not f then return nil end
    return f(d, sc)
end
local function init(a, fid) local f = INIT[a.kind]; S.inits = S.inits + 1; if f then f(a, fid) end end
local function update(a, fid) S.updates = S.updates + 1; UPDATE[a.kind](a, fid) end

-- repeat (CRepeatFleetAction 0x29692e0 / 0x2969980 / 0x29699e0)
CREATE["repeat"] = function(d, sc)
    return { kind = "repeat", data = d, iterations = 0, index = -1, scope = sc }
end
INIT["repeat"] = function(a, fid)
    if #a.data.children == 0 then return end
    a.done, a.iterations, a.index = false, 0, 0
    a.current = create(a.data.children[1], a.scope)
    if a.current then init(a.current, fid) end
end
UPDATE["repeat"] = function(a, fid)
    if not a.current then
        if a.index == -1 then a.done = true; return end
        a.current = create(a.data.children[a.index + 1], a.scope)
        if not a.current then a.done = true; return end
        init(a.current, fid)
    end
    update(a.current, fid)
    if not a.current.done then return end
    a.current = nil
    a.index = a.index + 1
    if a.index < #a.data.children then return end
    a.iterations = a.iterations + 1
    if a.data.max ~= -1 and a.iterations >= a.data.max then a.done = true; return end
    if a.data.while_id then
        local b = named_block(a.data.while_id)
        if not b then
            S.triggers_missing[a.data.while_id] = true
        elseif not eval().trigger(b, ctx_of(a.scope)) then
            a.done = true
            return
        end
    end
    a.index = 0
end

-- find_planet (CFindPlanetFleetAction 0x296a940 / Init 0x296b000 / Update 0x296bc40)
CREATE["find_planet"] = function(d, sc)
    return { kind = "find_planet", data = d, scope = sc, index = -1, planet = nil }
end
local function planet_passes(a, pid)
    local b = named_block(a.data.trigger_id)
    if not b then
        S.triggers_missing[a.data.trigger_id] = true
        return false
    end
    local E = eval()
    local ctx = ctx_of(a.scope)
    local c = E.push(ctx, E.S("planet", pid))
    return E.trigger(b, c) and true or false
end
INIT["find_planet"] = function(a, fid)
    local f = fleet(fid)
    local here = fleet_coord(f)
    local ids = system_planets(here and here.origin)
    local found
    if a.data.trigger_id then
        if a.data.method == "random" then
            -- the loop stops at the first planet that passes; then one draw, r % 1 [V]
            for _, pid in ipairs(ids) do
                if planet_passes(a, pid) then
                    draw()
                    found = pid
                    break
                end
            end
        else
            local pairs_ = {}
            for i, pid in ipairs(ids) do
                local pc = planet_coord(pid)
                pairs_[#pairs_ + 1] = { d = pc and here and dist_sq(here, pc) or math.huge, pid = pid, i = i }
            end
            table.sort(pairs_, function(x, y) if x.d ~= y.d then return x.d < y.d end return x.i < y.i end)
            for _, p in ipairs(pairs_) do
                if planet_passes(a, p.pid) then found = p.pid; break end
            end
        end
    else
        if a.data.method == "random" then
            if #ids > 0 then
                local r = draw()
                found = ids[(r % #ids) + 1]
            end
        else
            -- the best distance is never kept: the system's first planet [V]
            found = ids[1]
        end
    end
    a.index = 0
    a.planet = found
end
local function planet_valid(pid) return pid ~= nil and world.object("planet", pid) ~= nil end
UPDATE["find_planet"] = function(a, fid)
    local valid = planet_valid(a.planet)
    local list = valid and a.data.found or a.data.failed
    while true do
        if a.current then
            update(a.current, fid)
            if not a.current.done then return end
            a.current = nil
            a.index = a.index + 1
            if a.index >= #list then a.done = true end
            return
        end
        if a.index >= #list then a.done = true; return end
        if planet_valid(a.planet) then
            -- a fresh scope: this = the planet, prev = the action's, root and from its; its random
            -- seeded by a draw [V]
            local r = draw()
            local sc = { kind = "planet", id = a.planet, root = a.scope.root, from = a.scope.from, prev = a.scope,
                crude = crude_state(r) }
            a.current = create(list[a.index + 1], sc)
        else
            a.current = create(list[a.index + 1], a.scope)
        end
        if not a.current then a.done = true; return end
        init(a.current, fid)
    end
end

-- move_to (CMoveToFleetAction 0x296fb20 / Init 0x29702a0 / Update 0x2970300)
local MOVE_TO_ACTION_THRESHOLD = 5   -- NDefines::NShip, against the squared distance
local function target_scope(sc, token)
    token = tostring(token or "this"):lower()
    if token == "this" then return sc end
    if token == "prev" then return sc.prev end
    if token == "root" then return sc.root end
    if token == "from" then return sc.from end
    return nil
end
local function space_coordinate(t)
    if not t or not t.id then return nil end
    if t.kind == "planet" then return planet_coord(t.id) end
    if t.kind == "fleet" then return fleet_coord(fleet(t.id)) end
    if t.kind == "system" then return { x = 0, y = 0, origin = t.id } end
    return nil
end
CREATE["move_to"] = function(d, sc)
    local c = space_coordinate(target_scope(sc, d.target))
    return { kind = "move_to", coord = c or { x = 0, y = 0, origin = 4294967295 } }
end
INIT["move_to"] = function(a, fid)
    local o = orders()
    o.clear(fid)
    if a.coord.origin and a.coord.origin ~= 4294967295 then
        o.move_to(fid, { x = a.coord.x, y = a.coord.y, origin = a.coord.origin })
        S.orders = S.orders + 1
    end
end
UPDATE["move_to"] = function(a, fid)
    local here = fleet_coord(fleet(fid))
    if here and a.coord.origin == here.origin and dist_sq(here, a.coord) < MOVE_TO_ACTION_THRESHOLD then
        a.done = true
        return
    end
    if current_order_type(fid) ~= "move_to_system_point_order" then a.done = true end
end

-- orbit_planet (COrbitPlanetFleetAction 0x29682f0 / Init 0x2968f30 / Update 0x2968ea0)
CREATE["orbit_planet"] = function(d, sc)
    if tostring(d.target):lower() == "random" then
        local ids
        if sc.kind == "country" then
            ids = {}
            for _, pid in ipairs(world.all("planet")) do
                local p = world.object("planet", pid)
                if p and num(world.field(p, "owner")) == sc.id then ids[#ids + 1] = pid end
            end
        else
            ids = system_planets(system_of_scope(sc))
        end
        if #ids == 0 then return nil end
        local r = draw()
        return { kind = "orbit_planet", planet = ids[(r % #ids) + 1] }
    end
    local t = target_scope(sc, d.target)
    if not t or t.kind ~= "planet" then return nil end
    return { kind = "orbit_planet", planet = t.id }
end
INIT["orbit_planet"] = function(a, fid)
    local o = orders()
    o.clear(fid)
    o.orbit(fid, a.planet)
    S.orders = S.orders + 1
end
UPDATE["orbit_planet"] = function(a, fid)
    if orbit_target(fleet(fid)) == a.planet then a.done = true; return end
    if current_order_type(fid) == "orbit_planet_order" then return end
    INIT["orbit_planet"](a, fid)
end

-- wait (CWaitFleetActionData::CreateInstance 0x2969e10, CWaitFleetAction::Update 0x296a080): the
-- time left (fixed point, 1.0 = 100000) = duration + fmul(u, random), u = a draw % 100000
-- (GetFixedPointForMacro, made even when random is 0); 0.1 day less on every tick, done at <= 0 [V]
local function fixed(v) return math.floor((v or 0) * 100000 + 0.5) end
local function fmul(a, b)
    local p = a * b
    local q = p / 100000
    return q >= 0 and math.floor(q) or math.ceil(q)
end
CREATE["wait"] = function(d, sc)
    local u = draw() % 100000
    return { kind = "wait", time = fixed(d.duration) + fmul(u, fixed(d.random)) }
end
UPDATE["wait"] = function(a, fid)
    a.time = a.time - 10000
    if a.time <= 0 then a.done = true end
end

-- effect (CExecuteEffectFleetAction 0x296a580): the effect run in the action's scope, done
CREATE["effect"] = function(d, sc) return { kind = "effect", data = d, scope = sc } end
UPDATE["effect"] = function(a, fid)
    local b = a.data.block or named_block(a.data.id)
    if b then
        S.effects = S.effects + 1
        local E = eval()
        pcall(E.effect, b, ctx_of(a.scope))
    else
        S.triggers_missing[tostring(a.data.id)] = true
    end
    a.done = true
end

-- ---------------------------------------------------------------------------------------------
-- the save's form of an instance (WriteMembers), and back (ReadMember)

local write_instance
local function data_value(d)
    local _, v = write_data(d)
    return v
end
write_instance = function(a)
    local b = {}
    if a.kind == "repeat" then
        world.append(b, "data", a.data_block or data_value(a.data))
        world.append(b, "index", a.index)
        world.append(b, "scope", scope_block(a.scope))
        world.append(b, "iterations", a.iterations)
    elseif a.kind == "find_planet" then
        world.append(b, "data", a.data_block or data_value(a.data))
        world.append(b, "scope", scope_block(a.scope))
        if a.planet then world.append(b, "planet", a.planet) end
        world.append(b, "index", a.index)
    elseif a.kind == "move_to" then
        local c = {}
        world.append(c, "x", a.coord.x)
        world.append(c, "y", a.coord.y)
        world.append(c, "origin", a.coord.origin or 4294967295)
        world.append(b, "coordinate", c)
    elseif a.kind == "orbit_planet" then
        local o = {}
        world.append(o, "planet", a.planet)
        world.append(b, "orbitable", o)
    elseif a.kind == "wait" then
        world.append(b, "time", a.time / 100000)
    elseif a.kind == "effect" then
        world.append(b, "data", data_value(a.data))
        world.append(b, "scope", scope_block(a.scope))
    end
    if a.current then
        local c = {}
        world.append(c, a.current.kind, write_instance(a.current))
        world.append(b, "current", c)
    end
    if a.done then world.append(b, "done", "yes") end
    return b
end

local read_instance
read_instance = function(kind, b)
    local a = { kind = kind, done = world.field(b, "done") == "yes" }
    local db = world.field(b, "data")
    if kind == "repeat" then
        a.data = DATA.repeat_(db)
        a.data_block = db
        a.index = num(world.field(b, "index")) or -1
        a.iterations = num(world.field(b, "iterations")) or 0
        a.scope = scope_from_block(world.field(b, "scope"))
    elseif kind == "find_planet" then
        a.data = DATA.find_planet(db)
        a.data_block = db
        a.scope = scope_from_block(world.field(b, "scope"))
        a.planet = num(world.field(b, "planet"))
        a.index = num(world.field(b, "index")) or -1
    elseif kind == "move_to" then
        a.coord = coord_of(world.field(b, "coordinate")) or { x = 0, y = 0, origin = 4294967295 }
    elseif kind == "orbit_planet" then
        local o = world.field(b, "orbitable")
        a.planet = type(o) == "table" and num(world.field(o, "planet")) or num(world.field(b, "planet"))
    elseif kind == "wait" then
        a.time = fixed(num(world.field(b, "time")) or 0)
    elseif kind == "effect" then
        a.data = DATA.effect(db)
        a.scope = scope_from_block(world.field(b, "scope"))
    else
        S.not_modelled[kind] = (S.not_modelled[kind] or 0) + 1
        return nil
    end
    local cur = world.field(b, "current")
    if type(cur) == "table" then
        for _, e in ipairs(cur) do
            if e.op and e.key and type(e.value) == "table" and e.value.text == nil then
                a.current = read_instance(e.key.text, e.value)
            end
        end
    end
    return a
end

-- ---------------------------------------------------------------------------------------------
-- the queues: per fleet { list = { instances }, unknown = { kinds not modelled } }, read from the
-- save once, written back when they change

local queues = {}
local function property(f, key)
    local p = world.field(f, "properties")
    return type(p) == "table" and world.field(p, key) == "yes"
end
local function set_property(f, key, on)
    local p = world.field(f, "properties")
    if type(p) ~= "table" then
        if not on then return end
        p = world.child(f, "properties")
    end
    if on then
        world.set(p, key, "yes")
    else
        local e = world.token_entry(p, key)
        if e then world.remove_entry(p, e) end
    end
end
local function queue_of(fid)
    local q = queues[fid]
    if q then return q end
    q = { list = {} }
    local f = fleet(fid)
    local ab = f and world.field(f, "actions")
    if type(ab) == "table" then
        for _, e in ipairs(ab) do
            if e.op and e.key and type(e.value) == "table" and e.value.text == nil then
                local a = read_instance(e.key.text, e.value)
                if a then q.list[#q.list + 1] = a else q.opaque = true end
            end
        end
    end
    queues[fid] = q
    return q
end
local function write_queue(fid, q)
    local f = fleet(fid)
    if not f or q.opaque then return end
    local ab = world.field(f, "actions")
    if #q.list == 0 then
        if type(ab) == "table" then
            for _, e in ipairs(f) do
                if e.op and e.key and e.key.text == "actions" then world.remove_entry(f, e); break end
            end
        end
    else
        local entries = {}
        for _, a in ipairs(q.list) do
            entries[#entries + 1] = { key = { text = a.kind }, op = "=", value = write_instance(a) }
        end
        if type(ab) ~= "table" then ab = world.child(f, "actions") end
        world.replace(ab, entries)
    end
    live.touch("fleet", fid)
end

-- the fleets with actions, in id order (the game's fleet slot order)
local with_actions
local function fleets_with_actions()
    if with_actions then return with_actions end
    with_actions = {}
    for _, fid in ipairs(world.all("fleet")) do
        local f = fleet(fid)
        if f and type(world.field(f, "actions")) == "table" then with_actions[#with_actions + 1] = fid end
    end
    table.sort(with_actions)
    return with_actions
end
local function track(fid)
    local list = fleets_with_actions()
    for _, x in ipairs(list) do if x == fid then return end end
    list[#list + 1] = fid
    table.sort(list)
end

-- CFleet::MicroUpdateSerial's actions part: the head action of every fleet, in fleet id order
function actions.tick(host)
    S.ticks = S.ticks + 1
    for _, fid in ipairs(fleets_with_actions()) do
        local f = fleet(fid)
        if f and not property(f, "mia") then
            local q = queue_of(fid)
            local a = q.list[1]
            if a and not q.opaque then
                if not property(f, "action_initialized") then
                    init(a, fid)
                    set_property(f, "action_initialized", true)
                end
                update(a, fid)
                if a.done then
                    table.remove(q.list, 1)
                    S.finished = S.finished + 1
                    set_property(f, "action_initialized", false)
                end
                write_queue(fid, q)
            end
        end
    end
end

-- queue_actions = { <actions> } (CQueueFleetActionsEffect::ExecuteActual 0x372c950): each made in
-- the effect's scope (their CreateInstance draws made now) and appended; the first of an empty
-- queue clears action_initialized
function actions.queue(fid, block, ctx)
    local f = fleet(fid)
    if not f then return end
    local q = queue_of(fid)
    local sc = scope_of_ctx(ctx)
    for _, d in ipairs(parse_children(block)) do
        local a = create(d, sc)
        if a then
            q.list[#q.list + 1] = a
            if #q.list == 1 then set_property(f, "action_initialized", false) end
            S.queued = S.queued + 1
        end
    end
    track(fid)
    write_queue(fid, q)
end

-- clear_fleet_actions (CFleet::ClearFleetActions 0x2946bb0): the queue emptied, the auto move reset
function actions.clear(fid)
    local f = fleet(fid)
    if not f then return end
    local q = queue_of(fid)
    q.list = {}
    q.opaque = nil
    set_property(f, "action_initialized", false)
    S.cleared = S.cleared + 1
    local am = package.loaded["engine.fleets.automove"]
    if am and am.reset then am.reset(fid) end
    write_queue(fid, q)
end

function actions.report()
    local nm, miss = {}, {}
    for k, v in pairs(S.not_modelled) do nm[#nm + 1] = k .. " " .. v end
    for k in pairs(S.triggers_missing) do miss[#miss + 1] = k end
    table.sort(nm); table.sort(miss)
    return string.format("fleet actions: %d ticks, %d inits, %d updates, %d finished, %d queued, %d cleared; "
        .. "%d draws, %d orders, %d effects; not modelled: %s; named triggers not found: %s",
        S.ticks, S.inits, S.updates, S.finished, S.queued, S.cleared, S.draws, S.orders, S.effects,
        #nm > 0 and table.concat(nm, ", ") or "none", #miss > 0 and table.concat(miss, ", ") or "none")
end

return actions
