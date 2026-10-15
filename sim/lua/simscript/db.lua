-- simscript/db.lua : the game's script, loaded from the install with the repo's readers.
--
-- Files, parsing, inline scripts and scripted trigger / effect / value instantiation come from
-- stellar.script.source (lua/stellar/script/source.lua) over pdxscript
-- (lib/stellar-lua-pdxscript): the game's own rules. This module indexes what the simulation runs:
-- events (every *_event of events/), on_actions (merged over common/on_actions), scripted
-- triggers, scripted effects, script values, scripted variables and static modifiers, plus the
-- game's documented trigger and effect names (logs/script_documentation) when available.

local pdxscript = require("pdxscript")
local source = require("stellar.script.source")

local db = {
    events = {},          -- id -> event
    event_list = {},      -- events in load order
    on_actions = {},      -- name -> { events = {id...}, random_events = {{w, id}...}, triggers = {}, effects = {}, file }
    scripted_triggers = {},
    scripted_effects = {},
    script_values = {},
    static_modifiers = {},
    globalvars = {},
    doc_triggers = {},
    doc_effects = {},
    load_errors = {},
    counts = {},
}

local filevars_cache = {}

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local t = f:read("*a")
    f:close()
    return t
end
db.read_file = read_file

-- the top-level `@name = value` statements of a parsed file
local function collect_vars(tree, into)
    into = into or {}
    for _, e in ipairs(tree) do
        if e.op and e.key and e.key.text:sub(1, 1) == "@" and e.value and e.value.text then
            into[e.key.text:sub(2)] = e.value.text
        end
    end
    return into
end

-- the file-local scripted variables of a file (relative path), parsed once
function db.filevars(file)
    if not file then
        return nil
    end
    local v = filevars_cache[file]
    if v == nil then
        v = false
        local tree = source.parse(db.fs, file)
        if tree then
            v = collect_vars(tree)
        end
        filevars_cache[file] = v
    end
    return v or nil
end

-- db.set_filevars(file, vars): a file's variables from a parse made elsewhere (engine.defs.load,
-- through stellar.script.source.definitions), as db.filevars would read them (false: the file does
-- not parse), so that the first read of one does not parse the file again
function db.set_filevars(file, vars)
    if filevars_cache[file] == nil then
        filevars_cache[file] = vars
    end
end

local function doc_names(path, into)
    local text = path and read_file(path)
    if not text then
        return 0
    end
    local n, prev_blank = 0, true
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        line = line:gsub("\r$", "")
        local name = line:match("^([%w_:@]+) %- ")
        if name and prev_blank then
            into[name:lower()] = true
            n = n + 1
        end
        prev_blank = line == "" or line:sub(1, 2) == "=="
    end
    return n
end

local EVENT_KINDS = {
    country_event = "country", planet_event = "planet", colony_event = "planet", pop_event = "pop_group",
    pop_group_event = "pop_group", leader_event = "leader", event = "none", fleet_event = "fleet",
    ship_event = "ship", carrier_event = "carrier", situation_event = "situation", system_event = "system",
    starbase_event = "starbase", observer_event = "observer", first_contact_event = "first_contact",
    astral_rift_event = "astral_rift", espionage_operation_event = "espionage_operation",
    archaeological_site_event = "archaeological_site", species_event = "species",
    cosmic_storm_event = "cosmic_storm", cosmic_storm_influence_field_event = "cosmic_storm_influence_field",
    federation_event = "federation", agreement_event = "agreement",
}
db.EVENT_KINDS = EVENT_KINDS

local function block_of(e)
    return e and e.value and e.value.text == nil and e.value or nil
end

local function load_event(kind, e, file, namespace)
    local b = e.value
    local ev = { kind = kind, scope_kind = EVENT_KINDS[kind], block = b, file = file, line = e.line, options = {} }
    for _, x in ipairs(b) do
        if x.op and x.key then
            local k = x.key.text:lower()
            if k == "id" then
                ev.id = x.value.text
            elseif k == "is_triggered_only" then
                ev.triggered_only = x.value.text == "yes"
            elseif k == "fire_only_once" then
                ev.once = x.value.text == "yes"
            elseif k == "hide_window" then
                ev.hidden = x.value.text == "yes"
            elseif k == "trigger" then
                ev.trigger = block_of(x)
            elseif k == "pre_triggers" then
                ev.pre_triggers = block_of(x)
            elseif k == "immediate" then
                ev.immediate = block_of(x)
            elseif k == "after" then
                ev.after = block_of(x)
            elseif k == "mean_time_to_happen" then
                ev.mtth = block_of(x)
            elseif k == "option" and block_of(x) then
                ev.options[#ev.options + 1] = x.value
            end
        end
    end
    if ev.id then
        db.events[ev.id] = ev
        db.event_list[#db.event_list + 1] = ev
    end
    return ev
end

local function load_on_actions()
    for _, file in ipairs(source.files(db.fs, "common/on_actions", "txt")) do
        local tree, msg = source.parse(db.fs, file)
        if not tree then
            db.load_errors[#db.load_errors + 1] = msg
        else
            tree = source.expand(db.fs, tree, db.load_errors, 0, "file: " .. file)
            for _, e in ipairs(tree) do
                local b = block_of(e)
                if b and e.key.text:sub(1, 1) ~= "@" then
                    local name = e.key.text
                    local oa = db.on_actions[name]
                    if not oa then
                        oa = { name = name, events = {}, random_events = {}, triggers = {}, effects = {}, file = file }
                        db.on_actions[name] = oa
                    end
                    for _, x in ipairs(b) do
                        if x.op and x.key then
                            local k = x.key.text:lower()
                            local xb = block_of(x)
                            if k == "events" and xb then
                                for _, id in ipairs(xb) do
                                    if id.text then
                                        oa.events[#oa.events + 1] = id.text
                                    end
                                end
                            elseif k == "random_events" and xb then
                                for _, r in ipairs(xb) do
                                    if r.op and r.value.text then
                                        oa.random_events[#oa.random_events + 1] = { tonumber(r.key.text) or 0, r.value.text, r.line }
                                    end
                                end
                            elseif k == "trigger" and xb then
                                oa.triggers[#oa.triggers + 1] = xb
                            elseif k == "effect" and xb then
                                oa.effects[#oa.effects + 1] = xb
                            end
                        end
                    end
                end
            end
        end
    end
end

local function load_events()
    local files = RUST.list_files(db.game_dir, "events")
    for _, file in ipairs(files) do
        local tree, msg = source.parse(db.fs, file)
        if not tree then
            db.load_errors[#db.load_errors + 1] = msg
        else
            filevars_cache[file] = collect_vars(tree)
            tree = source.expand(db.fs, tree, db.load_errors, 0, "file: " .. file)
            local namespace
            for _, e in ipairs(tree) do
                if e.op and e.key then
                    local k = e.key.text:lower()
                    if k == "namespace" then
                        namespace = e.value.text
                    elseif EVENT_KINDS[k] and block_of(e) then
                        load_event(k, e, file, namespace)
                    end
                end
            end
        end
    end
end

local function load_static_modifiers()
    local defs = source.definitions(db.fs, "common/static_modifiers")
    for name, def in pairs(defs) do
        local entries = {}
        for _, x in ipairs(def.block) do
            if x.op and x.key and x.value.text and tonumber(x.value.text) then
                entries[#entries + 1] = { x.key.text, tonumber(x.value.text) }
            end
        end
        db.static_modifiers[name] = entries
    end
end

local function count(t)
    local n = 0
    for _ in pairs(t) do
        n = n + 1
    end
    return n
end

function db.load(game_dir, docs_dir)
    local t0 = RUST.clock()
    db.game_dir = game_dir
    db.fs = source.filesystem(game_dir)
    for _, file in ipairs(source.files(db.fs, "common/scripted_variables", "txt")) do
        local tree = source.parse(db.fs, file)
        if tree then
            collect_vars(tree, db.globalvars)
        end
    end
    db.scripted_triggers = source.definitions(db.fs, "common/scripted_triggers")
    db.scripted_effects = source.definitions(db.fs, "common/scripted_effects")
    db.script_values = source.definitions(db.fs, "common/script_values")
    load_static_modifiers()
    load_on_actions()
    load_events()
    if docs_dir then
        doc_names(docs_dir .. "/triggers.log", db.doc_triggers)
        doc_names(docs_dir .. "/effects.log", db.doc_effects)
    end
    db.counts = {
        events = #db.event_list,
        on_actions = count(db.on_actions),
        scripted_triggers = count(db.scripted_triggers),
        scripted_effects = count(db.scripted_effects),
        script_values = count(db.script_values),
        static_modifiers = count(db.static_modifiers),
        scripted_variables = count(db.globalvars),
        doc_triggers = count(db.doc_triggers),
        doc_effects = count(db.doc_effects),
        load_errors = #db.load_errors,
        seconds = RUST.clock() - t0,
    }
end

-- An instance of a scripted trigger / effect / value for a call's arguments ({ {name, value} }),
-- cached; nil, message on failure.
local instances = {}
function db.instance(kind, def, name, args)
    local key = kind .. "|" .. name
    for _, a in ipairs(args) do
        key = key .. "|" .. a[1] .. "=" .. a[2]
    end
    local inst = instances[key]
    if inst == nil then
        local block, msg = source.instantiate(db.fs, def, args, nil, "file: " .. def.file)
        inst = block or { failed = msg or "instantiate failed" }
        instances[key] = inst
    end
    if inst.failed then
        return nil, inst.failed
    end
    return inst
end

db.pdxscript = pdxscript
db.source = source
return db
