-- render/windows/events_data.lua : what the event windows, the Situation Log and the
-- Discoveries view show, read from the world (engine.world) where the simulation runs; laid out
-- by render.windows.events / situations / discoveries where the GUI runs (docs/windows/events.md).
--
--   local data = require("render.windows.events_data")
--   local chunk = data.chunk(game_dir)   -- a Lua chunk, `return { ... }` (it travels in the
--                                        -- simulation's snapshots: render.galaxy `events`)
--
-- The open player events (CGameState::AddOpenPlayerEvent, COpenPlayerEvent): the save's
-- `player_event = { id event date scope country }` blocks (`date` the day the event expires:
-- 2210.01.01's first_contact.1 has 2210.03.04 and the game drops it then), and the events the
-- simulation opened for the human player since the load (simscript.events `opened`: the
-- simulation takes the first valid option at once, the game waits; the window is shown until the
-- player closes it or EVENT_AUTOSELECT_MONTHS have passed). For each: the texts the window shows,
-- chosen as the game chooses them (a `desc`, `title` or `picture` block with a trigger: the first
-- whose trigger holds; an option with a trigger false is not shown), as localisation keys, and the
-- names its [scope commands] give, as name blocks (render.names formats them where the
-- localisation is).

local world = require("engine.world")
local source = require("stellar.script.source")

local M = {}

local NONE = 4294967295

local function text(v)
    if type(v) ~= "string" and type(v) ~= "number" then
        return nil
    end
    return (tostring(v):gsub('^"(.*)"$', "%1"))
end

local function blocks_of(block, key)
    local out = {}
    for _, e in ipairs(type(block) == "table" and block or {}) do
        if e.op and e.key and e.key.text == key then
            out[#out + 1] = e.value
        end
    end
    return out
end

local function get(block, key)
    for _, e in ipairs(type(block) == "table" and block or {}) do
        if e.op and e.key and e.key.text:lower() == key then
            return e.value.text or e.value
        end
    end
    return nil
end

-- a save's name block -> { key, literal, vars = { { key, value } } } (render.names' form)
local function name_block(b)
    if type(b) == "string" then
        return { key = text(b), literal = true }
    end
    if type(b) ~= "table" then
        return nil
    end
    local n = { key = text(world.field(b, "key")) or "", literal = world.field(b, "literal") == "yes", vars = {} }
    for _, v in ipairs(world.blocks(world.field(b, "variables") or {})) do
        n.vars[#n.vars + 1] = { key = text(world.field(v, "key")) or "", value = name_block(world.field(v, "value")) }
    end
    return n
end
M.name_block = name_block

-- ---------------------------------------------------------------------------------------------
-- scopes: { kind, id } as the save writes them (type=country id=0)

local KIND = { galactic_object = "system", pop_faction = "pop_faction" }

local function player()
    local pl = world.meta and world.meta.player
    if type(pl) == "table" then
        for _, b in ipairs(world.blocks(pl)) do
            local c = tonumber(world.field(b, "country"))
            if c then
                return c
            end
        end
    end
    return 0
end
M.player = player

local function object(sc)
    if not sc or not sc.id or sc.id == NONE then
        return nil
    end
    return world.object(sc.kind, sc.id)
end

-- a country's name as the player sees it: before communications, the name the first contact gave
-- it (the player's relation's pre_communications_name: "Kappa Menace")
local function country_name(id, pid)
    local c = world.object("country", id)
    if not c then
        return nil
    end
    if id ~= pid then
        local pc = world.object("country", pid)
        for _, r in ipairs(world.fields(world.field(pc, "relations_manager") or {}, "relation")) do
            if tonumber(world.field(r, "country")) == id and world.field(r, "communications") ~= "yes" then
                local pre = world.field(r, "pre_communications_name")
                if type(pre) == "table" then
                    return name_block(pre)
                end
            end
        end
    end
    return name_block(world.field(c, "name"))
end

local function species_of_country(c)
    local ref = c and tonumber(world.field(c, "founder_species_ref"))
    return ref and world.object("species", ref)
end

-- the scope a link leads to from sc: owner, system, contact country, capital, species...
local function link(sc, name, pid)
    local o = object(sc)
    if not o then
        return nil
    end
    name = name:lower()
    local k = sc.kind
    if name == "owner" or name == "controller" then
        local v = tonumber(world.field(o, "owner")) or (k == "country" and sc.id)
        return v and { kind = "country", id = v }
    elseif name == "system" or name == "solar_system" or name == "getsolarsystem" then
        if k == "system" then
            return sc
        end
        local loc = world.field(o, "location")
        if type(loc) == "table" then
            loc = world.field(loc, "id")
        end
        local v = tonumber(loc) or tonumber(world.path(o, "coordinate", "origin"))
        if k == "planet" then
            v = tonumber(world.path(o, "coordinate", "origin"))
        end
        return v and { kind = "system", id = v }
    elseif name == "contactcountry" or name == "contact_country" then
        local v = tonumber(world.field(o, "country"))
        return v and { kind = "country", id = v }
    elseif name == "capital" or name == "capital_scope" then
        local v = tonumber(world.field(o, "capital"))
        return v and { kind = "planet", id = v }
    elseif name == "species" or name == "founder_species" then
        local v = tonumber(world.field(o, "founder_species_ref")) or tonumber(world.field(o, "species_index"))
        return v and { kind = "species", id = v }
    elseif name == "leader" then
        local v = tonumber(world.field(o, "leader"))
        return v and v ~= NONE and { kind = "leader", id = v }
    end
    return nil
end

-- a scope's name (GetName) and the others the texts use
local function functions(sc, pid)
    local o = object(sc)
    local out = {}
    if not o then
        return out
    end
    if sc.kind == "country" then
        out.getname = country_name(sc.id, pid)
        out.getadj = name_block(world.path(o, "adjective"))
        local sp = species_of_country(o)
        if sp then
            out.getspeciesname = name_block(world.field(sp, "name"))
            out.getspeciesnameplural = name_block(world.field(sp, "plural"))
            out.getspeciesadj = name_block(world.field(sp, "adjective"))
        end
    elseif sc.kind == "species" then
        out.getname = name_block(world.field(o, "name"))
        out.getnameplural = name_block(world.field(o, "plural"))
        out.getadj = name_block(world.field(o, "adjective"))
    elseif sc.kind == "first_contact" then
        out.getname = name_block(world.field(o, "name"))
    else
        out.getname = name_block(world.field(o, "name"))
    end
    return out
end

-- the names a text may ask for, by its lower-case command ("this.system.getname"): from each
-- root scope (this, root, from, fromfrom, the saved event targets), its own and one or two links on
local LINKS = { "owner", "system", "solar_system", "contactcountry", "contact_country", "capital", "species", "leader" }
local function names_of(roots, pid)
    local out = {}
    local function add(prefix, sc, depth)
        for f, n in pairs(functions(sc, pid)) do
            out[prefix .. "." .. f] = out[prefix .. "." .. f] or n
            if prefix == "this" then
                out[f] = out[f] or n
            end
        end
        if depth < 2 then
            for _, l in ipairs(LINKS) do
                local s = link(sc, l, pid)
                if s and not (s.kind == sc.kind and s.id == sc.id) then
                    add(prefix .. "." .. l, s, depth + 1)
                end
            end
        end
    end
    for name, sc in pairs(roots) do
        add(name, sc, 0)
    end
    return out
end

-- a save's event scope block (`scope = { type id root = {..} from = {..} saved_event_target = {
-- .. name } }`) -> roots { this, root, from, fromfrom, <target name> = scope }
local function save_scope(b)
    local function sc(x)
        if type(x) ~= "table" then
            return nil
        end
        local kind = text(world.field(x, "type"))
        local id = tonumber(world.field(x, "id"))
        if not kind or not id or kind == "none" then
            return nil
        end
        return { kind = KIND[kind] or kind, id = id }
    end
    local roots = {}
    roots.this = sc(b)
    roots.root = sc(world.field(b, "root")) or roots.this
    local from = world.field(b, "from")
    roots.from = sc(from)
    roots.fromfrom = sc(type(from) == "table" and world.field(from, "from") or nil)
    local function targets(x, depth)
        if type(x) ~= "table" or depth > 4 then
            return
        end
        for _, t in ipairs(world.fields(x, "saved_event_target")) do
            local n = text(world.field(t, "name"))
            if n and not roots[n:lower()] then
                roots[n:lower()] = sc(t)
            end
        end
        targets(world.field(x, "from"), depth + 1)
        targets(world.field(x, "root"), depth + 1)
    end
    targets(b, 0)
    return roots
end

-- ---------------------------------------------------------------------------------------------
-- triggers: the simulation's evaluator when it runs here (simscript.eval), else the few country
-- triggers the event texts ask most (ethics, authority, civics) [I]

local function ethics(c)
    local set = {}
    for _, e in ipairs(world.list(world.path(c, "ethos", "ethics") or {})) do
        set[text(e)] = true
    end
    return set
end

local function civics(c)
    local set = {}
    for _, e in ipairs(world.list(world.path(c, "government", "civics") or {})) do
        set[text(e)] = true
    end
    return set
end

local function mini_trigger(block, sc, pid)
    local function country(s)
        if not s then
            return nil
        end
        if s.kind == "country" then
            return world.object("country", s.id)
        end
        local o = link(s, "owner", pid)
        return o and world.object("country", o.id)
    end
    local function eval(b, s)
        local all = true
        for _, e in ipairs(type(b) == "table" and b or {}) do
            if e.op and e.key then
                local k, v = e.key.text:lower(), e.value
                local ok
                local yes = v.text and v.text ~= "no"
                if k == "and" then
                    ok = eval(v, s)
                elseif k == "or" then
                    ok = false
                    for _, x in ipairs(v) do
                        if x.op and x.key and eval({ x }, s) then
                            ok = true
                        end
                    end
                elseif k == "nor" or k == "not" then
                    -- (NOT is true when none of its triggers is: a NOR)
                    ok = true
                    for _, x in ipairs(v) do
                        if x.op and x.key and eval({ x }, s) then
                            ok = false
                        end
                    end
                elseif k == "nand" then
                    ok = not eval(v, s)
                elseif k == "custom_tooltip" then
                    -- its trigger without the tooltip's own keys
                    local inner = {}
                    for _, x in ipairs(v) do
                        if x.op and x.key and x.key.text ~= "fail_text" and x.key.text ~= "success_text" and x.key.text ~= "text" then
                            inner[#inner + 1] = x
                        end
                    end
                    ok = eval(inner, s)
                elseif k == "always" then
                    ok = yes
                elseif k == "owner" or k == "contact_country" or k == "from" or k == "root" or k == "this" then
                    local t = (k == "owner" or k == "contact_country") and link(s, k, pid) or s
                    ok = t and eval(v, t) or false
                else
                    local c = country(s)
                    local et, cv = ethics(c), civics(c)
                    local auth = text(world.path(c, "government", "authority")) or ""
                    local function ethic(n)
                        return et["ethic_" .. n] or et["ethic_fanatic_" .. n] or false
                    end
                    if k:match("^is_(%a+)$") and ({ xenophobe = 1, xenophile = 1, militarist = 1, pacifist = 1, spiritualist = 1, materialist = 1, egalitarian = 1, authoritarian = 1 })[k:sub(4)] then
                        ok = ethic(k:sub(4)) == yes
                    elseif k == "is_gestalt" then
                        ok = (et.ethic_gestalt_consciousness or false) == yes
                    elseif k == "is_hive_empire" then
                        ok = (auth == "auth_hive_mind") == yes
                    elseif k == "is_machine_empire" then
                        ok = (auth == "auth_machine_intelligence") == yes
                    elseif k == "is_wilderness_empire" then
                        ok = (auth == "auth_wilderness") == yes
                    elseif k == "has_valid_civic" or k == "has_civic" then
                        ok = cv[text(v.text)] or false
                    elseif k == "has_ethic" then
                        ok = et[text(v.text)] or false
                    elseif k == "has_authority" then
                        ok = auth == text(v.text)
                    elseif k == "is_homicidal" then
                        ok = (cv.civic_fanatic_purifiers or cv.civic_hive_devouring_swarm or cv.civic_machine_terminator or false) == yes
                    elseif k == "has_technology" then
                        local want, has = text(v.text), false
                        for _, t in ipairs(world.fields(world.field(c or {}, "tech_status") or {}, "technology")) do
                            if text(t) == want then
                                has = true
                            end
                        end
                        ok = has
                    elseif k == "has_modifier" then
                        local want, has = text(v.text), false
                        for _, m in ipairs(world.fields(c or {}, "timed_modifier")) do
                            if type(m) == "table" and text(world.field(m, "modifier")) == want then
                                has = true
                            end
                        end
                        ok = has
                    elseif v.text == "yes" or v.text == "no" then
                        -- an unknown yes/no trigger: as if false [I]
                        ok = not yes
                    else
                        -- an unknown trigger: false [I]
                        ok = false
                    end
                end
                if not ok then
                    all = false
                end
            end
        end
        return all
    end
    return eval(block, sc)
end

local function trigger(block, roots, pid)
    if type(block) ~= "table" then
        return true
    end
    -- (the evaluator is there in a world loaded without the simulation too, but without the
    -- game's scripts: its scripted triggers, is_xenophobe among them, are then all false)
    local ev = package.loaded["simscript.eval"]
    local sdb = package.loaded["simscript.db"]
    if ev and ev.trigger and ev.new_ctx and roots.this and sdb and type(sdb.events) == "table" and next(sdb.events) then
        local function S(s)
            return s and ev.S(s.kind, s.id) or ev.NONE
        end
        local targets = {}
        for k, s in pairs(roots) do
            if k ~= "this" and k ~= "root" and k ~= "from" and k ~= "fromfrom" then
                targets[k] = S(s)
            end
        end
        local ctx = ev.new_ctx(S(roots.this), S(roots.from), targets)
        ctx.root = S(roots.root)
        ctx.fromfrom = S(roots.fromfrom)
        local ok, r = pcall(ev.trigger, block, ctx)
        if os.getenv("STELLAR_EVENTS_DEBUG") then
            io.stderr:write(string.format("events_data: simscript trigger %s %s; mini %s\n", tostring(ok), tostring(r), tostring(mini_trigger(block, roots.this, pid))))
        end
        if ok then
            return r and true or false
        end
    end
    local r = mini_trigger(block, roots.this, pid)
    if os.getenv("STELLAR_EVENTS_DEBUG") then
        io.stderr:write(string.format("events_data: mini trigger %s (this %s %s)\n", tostring(r), tostring(roots.this and roots.this.kind), tostring(roots.this and roots.this.id)))
    end
    return r
end

M.trigger = trigger

-- ---------------------------------------------------------------------------------------------
-- the events' definitions: the simulation's database when it runs, else the event's file read

local files_text = {}   -- events/<file> -> its text
local trees = {}        -- file -> parsed tree
local defs = {}         -- event id -> its block

local function event_block(game_dir, id)
    if defs[id] ~= nil then
        return defs[id] or nil
    end
    local db = package.loaded["simscript.db"]
    if db and db.events and db.events[id] and db.events[id].block then
        defs[id] = db.events[id].block
        return defs[id]
    end
    if not next(files_text) then
        for _, f in ipairs(source.files(game_dir, "events", "txt")) do
            local h = io.open(game_dir .. "/" .. f, "rb")
            if h then
                files_text[f] = h:read("*a")
                h:close()
            end
        end
    end
    local pat = "id%s*=%s*\"?" .. id:gsub("%p", "%%%0") .. "\"?%s"
    for f, t in pairs(files_text) do
        if t:find(pat) then
            local tree = trees[f]
            if tree == nil then
                tree = source.parse(game_dir, f) or false
                trees[f] = tree
            end
            for _, e in ipairs(tree or {}) do
                if e.op and e.key and e.value.text == nil and text(get(e.value, "id")) == id then
                    defs[id] = e.value
                    return e.value
                end
            end
        end
    end
    defs[id] = false
    return nil
end

-- the first of an event's `key` entries that applies: a plain value, or a block { trigger = {..}
-- text|picture = .. } whose trigger holds (CEvent::CDescOption; NEventWindowUtil::GetEventWindowDesc)
local function choose(def, key, field, roots, pid)
    local fallback
    for _, e in ipairs(def) do
        if e.op and e.key and e.key.text:lower() == key then
            local v = e.value
            if v.text then
                return text(v.text)
            end
            local t = get(v, "trigger")
            local val = text(get(v, field) or get(v, "text"))
            fallback = fallback or val
            if trigger(t, roots, pid) then
                return val
            end
        end
    end
    return fallback
end

local function event_entry(game_dir, e, pid)
    local def = event_block(game_dir, e.event)
    local out = { id = e.id, event = e.event, expires = e.expires, fired = e.fired, kind = def and e.kind }
    if not def then
        out.title = e.event .. ".name"
        out.desc = e.event .. ".desc"
        out.options = {}
        return out
    end
    out.title = choose(def, "title", "text", e.roots, pid) or (e.event .. ".name")
    out.desc = choose(def, "desc", "text", e.roots, pid) or (e.event .. ".desc")
    out.picture = choose(def, "picture", "picture", e.roots, pid)
    out.location = get(def, "location") ~= nil
    out.diplomatic = get(def, "diplomatic") == "yes"
    out.options = {}
    for _, o in ipairs(blocks_of(def, "option")) do
        local show = get(o, "default_hide_option") ~= "yes" and get(o, "is_dialog_only") ~= "yes"
        local t = get(o, "trigger")
        if show and type(t) == "table" then
            show = trigger(t, e.roots, pid)
        end
        if show then
            local n = get(o, "name")
            if type(n) == "table" then
                n = get(n, "text")
            end
            out.options[#out.options + 1] = { name = text(n) or "OK", allow = true }
        end
    end
    out.names = names_of(e.roots, pid)
    return out
end

-- ---------------------------------------------------------------------------------------------
-- the events the simulation opened for the human since the load (simscript.events' hook)

M.opened = M.opened or {}
local next_id = nil

local function date_after_months(date, months)
    local y, m, d = tostring(date):match("^(%d+)%.(%d+)%.(%d+)$")
    if not y then
        return nil
    end
    y, m = tonumber(y), tonumber(m) + months
    while m > 12 do
        y, m = y + 1, m - 12
    end
    return string.format("%d.%02d.%02d", y, m, tonumber(d))
end

local function hook()
    local events = package.loaded["simscript.events"]
    if not events or events.opened == M.on_opened then
        return
    end
    -- (simscript.events calls `opened(ev, ctx, option)` for a human's event it answers)
    events.opened = M.on_opened
end

function M.on_opened(ev, ctx)
    if not next_id then
        next_id = (tonumber(world.meta and world.meta.last_event_id) or 0) + 1000
    end
    local function sc(s)
        if type(s) ~= "table" or s.kind == "none" or s.id == nil then
            return nil
        end
        return { kind = s.kind, id = tonumber(s.id) or s.id }
    end
    local roots = { this = sc(ctx.this), root = sc(ctx.root), from = sc(ctx.from), fromfrom = sc(ctx.fromfrom) }
    for k, s in pairs(ctx.targets or {}) do
        roots[tostring(k):lower()] = roots[tostring(k):lower()] or sc(s)
    end
    local date = text(world.meta and world.meta.date)
    local e = { id = next_id, event = ev.id, roots = roots, fired = true, date = date,
        expires = date_after_months(date, 9) }
    next_id = next_id + 1
    M.opened[#M.opened + 1] = e
    -- a bounded list (the newest kept)
    while #M.opened > 50 do
        table.remove(M.opened, 1)
    end
end

-- ---------------------------------------------------------------------------------------------
-- the Situation Log's and the Discoveries view's content

local function store_entries(top, sub)
    local b = world.meta and world.meta[top]
    if type(b) ~= "table" then
        for _, e in ipairs(world.tree or {}) do
            if e.op and e.key and e.key.text == top and e.value.text == nil then
                b = e.value
                break
            end
        end
    end
    if type(b) ~= "table" then
        return {}
    end
    if sub then
        b = world.field(b, sub)
    end
    local out = {}
    for _, e in ipairs(type(b) == "table" and b or {}) do
        if e.op and e.key and e.value.text == nil and tonumber(e.key.text) then
            out[#out + 1] = { id = tonumber(e.key.text), block = e.value }
        end
    end
    return out
end

local function first_contacts(pid)
    local out = {}
    local ids = {}
    for _, id in ipairs(world.list(world.path(world.object("country", pid), "first_contact", "contacts") or {})) do
        ids[tonumber(id)] = true
    end
    local entries = store_entries("first_contacts", "contacts")
    if #entries == 0 then
        for _, id in ipairs(world.all("first_contact")) do
            entries[#entries + 1] = { id = id, block = world.object("first_contact", id) }
        end
    end
    for _, e in ipairs(entries) do
        local b = e.block
        if tonumber(world.field(b, "owner")) == pid or ids[e.id] then
            local ev = world.field(b, "event")
            out[#out + 1] = {
                id = e.id, name = name_block(world.field(b, "name")), country = tonumber(world.field(b, "country")),
                status = text(world.field(b, "status")), stage = text(world.field(b, "stage")),
                clues = tonumber(world.field(b, "clues")) or 0, difficulty = tonumber(world.field(b, "difficulty")) or 0,
                days_left = tonumber(world.field(b, "days_left")) or 0, location = tonumber(world.field(b, "location")),
                system_name = name_block(world.field(world.object("system", tonumber(world.field(b, "location")) or -1) or {}, "name")),
                event = type(ev) == "table" and world.field(ev, "expired") ~= "yes" and text(world.field(ev, "event_id")) or nil,
                leader = tonumber(world.field(b, "leader")),
            }
        end
    end
    return out
end

local function situations(pid)
    local out = {}
    for _, e in ipairs(store_entries("situations", "situations")) do
        local b = e.block
        if tonumber(world.field(b, "country")) == pid then
            out[#out + 1] = {
                id = e.id, type = text(world.field(b, "type")), progress = tonumber(world.field(b, "progress")) or 0,
                monthly = tonumber(world.field(b, "last_month_progress")) or 0, stage = tonumber(world.field(b, "stage")) or 0,
                approach = text(world.field(b, "approach")),
            }
        end
    end
    return out
end

local function sites(pid)
    local out = {}
    for _, e in ipairs(store_entries("archaeological_sites", "sites")) do
        local b = e.block
        local loc = world.field(b, "location")
        local planet = type(loc) == "table" and tonumber(world.field(loc, "id")) or nil
        local excavator = tonumber(world.field(b, "last_excavator_country"))
        local p = planet and world.object("planet", planet)
        -- a site the player knows: on a planet the player has surveyed [I] or digs
        local surveyed = false
        for _, c in ipairs(world.fields(p or {}, "surveyed_by")) do
            if tonumber(c) == pid then
                surveyed = true
            end
        end
        if excavator == pid or surveyed then
            out[#out + 1] = {
                id = e.id, type = text(world.field(b, "type")), planet = planet,
                planet_name = p and name_block(world.field(p, "name")) or nil,
                index = tonumber(world.field(b, "index")) or 0, clues = tonumber(world.field(b, "clues")) or 0,
                difficulty = tonumber(world.field(b, "difficulty")) or 0, days_left = tonumber(world.field(b, "days_left")) or 0,
                excavator = excavator ~= NONE and excavator or nil,
            }
        end
    end
    return out
end

local function chains_and_projects(pid)
    local c = world.object("country", pid)
    local chains, projects = {}, {}
    local ev = world.field(c or {}, "events")
    for _, ch in ipairs(world.fields(type(ev) == "table" and ev or {}, "event_chain")) do
        if type(ch) == "table" then
            local counters = {}
            local cb = world.field(ch, "counter")
            for _, e in ipairs(type(cb) == "table" and cb or {}) do
                if e.op and e.key and e.value.text then
                    counters[e.key.text] = tonumber(e.value.text) or 0
                end
            end
            chains[#chains + 1] = { key = text(world.field(ch, "event_chain")), counters = counters }
        end
    end
    for _, sp in ipairs(world.fields(type(ev) == "table" and ev or {}, "special_project")) do
        if type(sp) == "table" then
            local sc = world.field(sp, "scope")
            projects[#projects + 1] = {
                key = text(world.field(sp, "special_project")),
                status = text(world.field(sp, "status")),
                days_left = tonumber(world.field(sp, "days_left")),
                location = type(sc) == "table" and text(world.field(sc, "type")) or nil,
            }
        end
    end
    return chains, projects
end

-- the anomalies the player has found and not yet researched: a planet's `anomaly` (its category)
-- with the player among its `surveyed_by` [I]
local function anomalies(pid)
    local out = {}
    for _, id in ipairs(world.all("planet")) do
        local p = world.object("planet", id)
        local cat = world.field(p, "anomaly")
        if cat then
            local by = false
            for _, c in ipairs(world.fields(p, "surveyed_by")) do
                if tonumber(c) == pid then
                    by = true
                end
            end
            if by then
                out[#out + 1] = { planet = id, category = text(cat), planet_name = name_block(world.field(p, "name")) }
            end
        end
    end
    return out
end

-- ---------------------------------------------------------------------------------------------

-- data.read(game_dir) -> { player, date, events = { ... }, first_contacts, situations, sites,
-- chains, projects, anomalies }
function M.read(game_dir)
    hook()
    local pid = player()
    local date = text(world.meta and world.meta.date) or ""
    local list = {}
    for _, e in ipairs(world.tree or {}) do
        if e.op and e.key and e.key.text == "player_event" and e.value.text == nil then
            local b = e.value
            if tonumber(world.field(b, "country")) == pid then
                list[#list + 1] = {
                    id = tonumber(world.field(b, "id")), event = text(world.field(b, "event")),
                    expires = text(world.field(b, "date")), roots = save_scope(world.field(b, "scope")),
                }
            end
        end
    end
    for _, e in ipairs(M.opened) do
        if not e.expires or e.expires > date then
            list[#list + 1] = e
        end
    end
    local events = {}
    for _, e in ipairs(list) do
        if e.event then
            local ok, entry = pcall(event_entry, game_dir, e, pid)
            if ok then
                events[#events + 1] = entry
            else
                events[#events + 1] = { id = e.id, event = e.event, error = tostring(entry), options = {} }
            end
        end
    end
    local chains, projects = chains_and_projects(pid)
    return {
        player = pid, date = date, events = events,
        first_contacts = first_contacts(pid), situations = situations(pid), sites = sites(pid),
        chains = chains, projects = projects, anomalies = anomalies(pid),
    }
end

-- data.log(game_dir) -> what the Situation Log shows (render.windows.situation): the player's event
-- chains (their counters), special projects, situations, first contacts, archaeological sites and
-- anomalies
function M.log(game_dir)
    local pid = player()
    local chains, projects = chains_and_projects(pid)
    return {
        player = pid, date = text(world.meta and world.meta.date) or "",
        first_contacts = first_contacts(pid), situations = situations(pid), sites = sites(pid),
        chains = chains, projects = projects, anomalies = anomalies(pid),
    }
end

-- a value as Lua source
local function serialize(v, out)
    local t = type(v)
    if t == "table" then
        out[#out + 1] = "{"
        local n = #v
        for i = 1, n do
            serialize(v[i], out)
            out[#out + 1] = ","
        end
        for k, x in pairs(v) do
            if not (type(k) == "number" and k >= 1 and k <= n and k == math.floor(k)) then
                out[#out + 1] = "["
                serialize(k, out)
                out[#out + 1] = "]="
                serialize(x, out)
                out[#out + 1] = ","
            end
        end
        out[#out + 1] = "}"
    elseif t == "string" then
        out[#out + 1] = string.format("%q", v)
    elseif t == "number" then
        out[#out + 1] = v == math.floor(v) and string.format("%d", v) or string.format("%.17g", v)
    elseif t == "boolean" then
        out[#out + 1] = tostring(v)
    else
        out[#out + 1] = "nil"
    end
end

-- data.chunk(game_dir) -> "return { ... }"
function M.chunk(game_dir)
    local out = { "return " }
    serialize(M.read(game_dir), out)
    return table.concat(out)
end

return M
