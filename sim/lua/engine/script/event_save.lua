-- engine/script/event_save.lua : the event state the save keeps, read into the script layer and kept
-- in the save's form as it changes (docs/script_creation.md "Delayed events"):
--
-- - delayed events: a planet's `delayed_event = { event days scope }`, a country's in
--   `modules = { standard_event_module = { delayed_event = { } } }` (CDelayedEvent::WriteMembers;
--   the managers of CPlanet and CStandardEventCountryModule), loaded into simscript.events with their
--   scopes; their `days` counted down, the fired ones taken out, new ones of those scopes written;
-- - the global event targets: the save's top-level `saved_event_target = { type id name }`.
--
-- A scope block (CEventScope::WriteMembers): type, id, opener_id, random = { <seed> <position> },
-- random_allowed, root = { }, from = { }, saved_event_target = { type id opener_id name }.

local world = require("engine.world")
local eval = require("simscript.eval")
local SR = require("engine.script.scope_random")
local events -- simscript.events, given to M.install (it installs this while it loads)

local M = { loaded = false, stats = { delayed = 0, targets = 0, written = 0, removed = 0 } }

-- the save's scope type names and the script layer's kinds
local KIND = { galactic_object = "system" }
local TYPE = { system = "galactic_object" }
local NO_ID = 4294967295

local function unq(v)
    return type(v) == "string" and (v:gsub('^"(.*)"$', "%1")) or v
end

-- a scope block -> { this, rng, from_rec (the from scope, the same form), root (the same form),
-- targets }
local function parse_scope(b)
    if type(b) ~= "table" then
        return nil
    end
    local t = unq(world.field(b, "type"))
    local id = tonumber(world.field(b, "id"))
    local out = { targets = {} }
    out.this = (t and id and t ~= "none") and eval.S(KIND[t] or t, id) or eval.NONE
    local r = world.field(b, "random")
    if type(r) == "table" then
        local v = world.list(r)
        out.rng = SR.from_save(v[1], v[2])
    end
    out.from_rec = parse_scope(world.field(b, "from"))
    out.root = parse_scope(world.field(b, "root"))
    for _, st in ipairs(world.fields(b, "saved_event_target")) do
        if type(st) == "table" then
            local tt, tid, name = unq(world.field(st, "type")), tonumber(world.field(st, "id")), unq(world.field(st, "name"))
            if tt and tid and name then
                out.targets[name] = eval.S(KIND[tt] or tt, tid)
            end
        end
    end
    return out
end
M.parse_scope = parse_scope

-- the day index of the save's date (as eval.today counts: 360-day years, 30-day months)
local function save_day()
    local d = world.meta and world.meta.date
    local y, m, dd = tostring(d or ""):gsub('"', ""):match("^(%d+)%.(%d+)%.(%d+)")
    if not y then
        return eval.today()
    end
    return tonumber(y) * 360 + (tonumber(m) - 1) * 30 + tonumber(dd) - 1
end

local function entry_of(block, holder, day0)
    local id = unq(world.field(block, "event"))
    local days = tonumber(world.field(block, "days")) or 0
    local sc = parse_scope(world.field(block, "scope"))
    if not id or not sc then
        return nil
    end
    local f = sc.from_rec
    local entry = { id = id, days = days, scope = sc.this, from = f and f.this or eval.NONE,
        fromfrom = f and f.from_rec and f.from_rec.this or eval.NONE, from_rec = f,
        root = sc.root and sc.root.this or sc.this, targets = sc.targets, rng = sc.rng or SR.default(),
        block = block, holder = holder }
    -- counted from the save's day (the save is read when the first event is, maybe a day later)
    entry.due = day0 + days
    return entry
end

-- the blocks that hold an object's delayed events
local function holder_of(kind, id, create)
    if kind == "country" then
        local c = world.object("country", id)
        local modules = c and world.field(c, "modules")
        if type(modules) ~= "table" then
            return nil
        end
        local m = world.field(modules, "standard_event_module")
        if type(m) ~= "table" and create then
            m = world.child(modules, "standard_event_module")
        end
        return type(m) == "table" and m or nil
    elseif kind == "planet" then
        return world.object("planet", id)
    end
    return nil
end

function M.load()
    if M.loaded or not world.tree then
        return
    end
    M.loaded = true
    local day0 = save_day()
    for _, cid in ipairs(world.all("country")) do
        local h = holder_of("country", cid, false)
        for _, b in ipairs(h and world.fields(h, "delayed_event") or {}) do
            local entry = type(b) == "table" and entry_of(b, h, day0)
            if entry then
                events.queue_entry(entry.scope.key, entry)
                M.stats.delayed = M.stats.delayed + 1
            end
        end
    end
    for _, pid in ipairs(world.all("planet")) do
        local h = world.object("planet", pid)
        for _, b in ipairs(world.fields(h, "delayed_event")) do
            local entry = type(b) == "table" and entry_of(b, h, day0)
            if entry then
                events.queue_entry(entry.scope.key, entry)
                M.stats.delayed = M.stats.delayed + 1
            end
        end
    end
    for _, e in ipairs(world.tree) do
        if e.op and e.key and e.key.text == "saved_event_target" and e.value.text == nil then
            local t, id, name = unq(world.field(e.value, "type")), tonumber(world.field(e.value, "id")), unq(world.field(e.value, "name"))
            if t and id and name then
                eval.state.global_targets[name] = eval.S(KIND[t] or t, id)
                M.stats.targets = M.stats.targets + 1
            end
        end
    end
end

-- a scope block for the save: the scope, its random state, its root when another object, its from
-- chain (records { this, rng, from_rec }; a from scope the script layer has no state for: a
-- default scope's [I]), the saved event targets
local function scope_block(sc, rng, from_rec, root, targets)
    local b = {}
    world.append(b, "type", TYPE[sc.kind] or sc.kind)
    world.append(b, "id", sc.id or NO_ID)
    world.append(b, "opener_id", NO_ID)
    local r = rng or SR.default()
    world.append(b, "random", { { text = tostring(r.seed) }, { text = tostring(r.pos) } })
    world.append(b, "random_allowed", "yes")
    if root and root ~= sc and root.kind ~= "none" then
        world.append(b, "root", scope_block(root, nil, nil, nil, nil))
    end
    if from_rec and from_rec.this and from_rec.this.kind ~= "none" then
        world.append(b, "from", scope_block(from_rec.this, from_rec.rng, from_rec.from_rec, nil, nil))
    end
    local names = {}
    for name in pairs(targets or {}) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        local t = targets[name]
        if t and t.kind ~= "none" then
            local st = {}
            world.append(st, "type", TYPE[t.kind] or t.kind)
            world.append(st, "id", t.id)
            world.append(st, "opener_id", NO_ID)
            world.append(st, "name", name, true)
            world.append(b, "saved_event_target", st)
        end
    end
    return b
end

function M.on_queued(entry)
    local h = holder_of(entry.scope.kind, entry.scope.id, true)
    if not h then
        return
    end
    local b = {}
    world.append(b, "event", entry.id, true)
    world.append(b, "days", entry.days)
    local from_rec = entry.from_rec
    if not from_rec and entry.from and entry.from.kind ~= "none" then
        from_rec = { this = entry.from, from_rec = entry.fromfrom and { this = entry.fromfrom } or nil }
    end
    world.append(b, "scope", scope_block(entry.scope, entry.rng, from_rec, entry.root, entry.targets))
    world.append(h, "delayed_event", b)
    entry.block, entry.holder = b, h
    M.stats.written = M.stats.written + 1
end

function M.on_tick(entry, days)
    if entry.block then
        world.set(entry.block, "days", days)
    end
end

function M.on_removed(entry)
    if entry.block and entry.holder then
        for i = #entry.holder, 1, -1 do
            local e = entry.holder[i]
            if e.op and e.key and e.key.text == "delayed_event" and e.value == entry.block then
                world.remove_entry(entry.holder, e)
                M.stats.removed = M.stats.removed + 1
                break
            end
        end
    end
end

function M.install(ev)
    events = ev
    events.on_queued, events.on_tick, events.on_removed = M.on_queued, M.on_tick, M.on_removed
    events.ensure = M.load
end

function M.report()
    local s = M.stats
    return string.format("event save: %d delayed events loaded, %d global event targets; %d written, %d removed",
        s.delayed, s.targets, s.written, s.removed)
end

return M
