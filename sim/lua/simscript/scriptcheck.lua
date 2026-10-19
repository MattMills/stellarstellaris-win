-- simscript/scriptcheck.lua : checks that every keyword of the game's script is wired to Lua that
-- does something, and that what the Lua knows is what the game documents.
--
-- Three sources, joined per keyword:
--   docs     the game's own script documentation (logs/script_documentation: triggers.log,
--            effects.log, scopes.log, localizations.log, modifiers.log), the authority on which
--            keywords exist and the scopes each one supports (docs/script_docs.md);
--   lua      the script layer's handlers (simscript.eval: TRIG, EFF, LINKS, LISTS and the
--            patterns eval.status knows) and the engine's appliers (engine.systems.effects);
--   vanilla  how often vanilla's script uses each keyword (simscript.coverage's census).
--
-- Static part (no world needed):
--   - every documented trigger, effect and scope link: its status (eval.status: lua, property,
--     flag, iterator, event, scripted, engine-unmodelled, or missing);
--   - every handler name the Lua registers that the game does not document ("invented": a typo,
--     an old name, or a keyword the game has under another name);
--   - every effect handler's own source read for what it does: records itself as unmodelled,
--     pushes engine effects (each checked against engine.systems.effects), or has an empty body.
-- Dynamic part (a loaded world, run after a save's load by examples/run.rs):
--   - one use of every documented trigger, effect and link, from the docs mod
--     (lib/stellar-lua-pdxscript/tools/docs_mod/make_docs_mod.lua: manifest.tsv gives each use's
--     file, line and scope), run in an object of that scope; what it did is measured: a miss, a
--     Lua error, an unmodelled record, engine effects applied or not applied, the world's writes,
--     the script state's writes. An effect that ran without any of these is "silent".
--
--   local check = require("simscript.scriptcheck")
--   local r = check.run{ docs = DIR, mod = DOCS_MOD_DIR, out = TSV_PATH, dynamic = true }
--   print(r.text)
--
-- Effects change the world they run in (in manifest order): run it on a throwaway load.

local pdxscript = require("pdxscript")
local eval = require("simscript.eval")
local db = require("simscript.db")

local X = {}

-- ---------------------------------------------------------------------------------------------
-- the game's documentation

local function lines_of(path)
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local t = f:read("*a")
    f:close()
    local out = {}
    for l in (t:gsub("\r", "") .. "\n"):gmatch("([^\n]*)\n") do
        out[#out + 1] = l
    end
    return out
end

local function words(s)
    local t = {}
    for w in s:gmatch("%S+") do
        t[#t + 1] = w
    end
    return t
end

-- triggers.log, effects.log, scopes.log: name -> { scopes = {...} or "all", output, desc }.
-- An entry ends with its "Supported Scopes:" line (syntax text may hold blank lines); its name is
-- the first line of the entry's text that reads `name - description` or is a single word.
local function read_entries(path)
    local ls = lines_of(path)
    if not ls then
        return nil
    end
    local out, block, last = {}, {}, nil
    for _, l in ipairs(ls) do
        local sc = l:match("^Supported Scopes:%s*(.*)$")
        local os_ = l:match("^Output Scope:%s*(.*)$")
        if sc then
            local name, desc
            for _, b in ipairs(block) do
                local n, d = b:match("^([%w_:%.@]+) %- (.*)$")
                if n then
                    name, desc = n, d
                    break
                end
            end
            if not name then
                for _, b in ipairs(block) do
                    local n = b:match("^([%w_:%.@]+)%s*$")
                    if n then
                        name = n
                        break
                    end
                end
            end
            if name then
                local scopes = sc == "all" and "all" or words(sc)
                last = { name = name, desc = desc, scopes = scopes }
                out[name:lower()] = last
            end
            block = {}
        elseif os_ and last then
            last.output = os_
        elseif not l:match("^%[%d%d:%d%d:%d%d%]") and not l:match("^==") and not l:match("^=+$") then
            if l:match("%S") then
                block[#block + 1] = l
            end
        end
    end
    return out
end

-- modifiers.log: `- <name>, Category: ...`
local function read_modifiers(path)
    local ls = lines_of(path)
    if not ls then
        return nil
    end
    local out = {}
    for _, l in ipairs(ls) do
        local n = l:match("^%- ([^,]+),")
        if n then
            out[n:lower()] = true
        end
    end
    return out
end

-- localizations.log: one command per line, indented by a space, under `--Section--`
local function read_loc(path)
    local ls = lines_of(path)
    if not ls then
        return nil
    end
    local out = {}
    for _, l in ipairs(ls) do
        local n = l:match("^ ([%w_]+)%s*$")
        if n then
            out[n] = true
        end
    end
    return out
end

function X.read_docs(dir)
    return {
        trigger = read_entries(dir .. "/triggers.log") or {},
        effect = read_entries(dir .. "/effects.log") or {},
        link = read_entries(dir .. "/scopes.log") or {},
        modifier = read_modifiers(dir .. "/modifiers.log") or {},
        loc = read_loc(dir .. "/localizations.log") or {},
    }
end

local function count(t)
    local n = 0
    for _ in pairs(t) do
        n = n + 1
    end
    return n
end

-- ---------------------------------------------------------------------------------------------
-- the Lua's handlers

local I = eval._internal

-- the handlers' own source, for what each does
local source_cache = {}
local function source_of(fn)
    local info = debug.getinfo(fn, "S")
    if not info or info.what ~= "Lua" or not info.source:match("^@") then
        return nil
    end
    local path = info.source:sub(2)
    local ls = source_cache[path]
    if ls == nil then
        ls = lines_of(path) or false
        source_cache[path] = ls
    end
    if not ls then
        return nil
    end
    local body = {}
    for i = info.linedefined, info.lastlinedefined do
        body[#body + 1] = ls[i] or ""
    end
    return table.concat(body, "\n"), path:match("([^/\\]+/[^/\\]+)$") .. ":" .. info.linedefined
end

local systems_ok, systems = pcall(require, "engine.systems")
local appliers = systems_ok and systems.effects or {}

-- what an effect handler's source says it does: { unmodelled, empty, pushes = { type = applied? } }
local function classify(fn)
    local src, where = source_of(fn)
    if not src then
        return { where = "?" }
    end
    local c = { where = where, pushes = {} }
    c.unmodelled = src:find("unmodelled%(") ~= nil
    for ty in src:gmatch("type%s*=%s*[\"']([%w_]+)[\"']") do
        if ty ~= "unmodelled" then
            c.pushes[ty] = appliers[ty] ~= nil
        end
    end
    -- a body with nothing between its first and last line but blanks, comments and returns
    local inner = src:gsub("^[^\n]*\n", ""):gsub("\n[^\n]*$", "")
    inner = inner:gsub("%-%-[^\n]*", ""):gsub("return[^\n]*", ""):gsub("%s+", "")
    c.empty = inner == ""
    return c
end

-- the documented iterators' list names (every_x, random_x, ordered_x, any_x, count_x -> x)
local function iterator_lists(docs)
    local lists = {}
    for _, kind in ipairs({ "trigger", "effect" }) do
        for name in pairs(docs[kind]) do
            local l = name:match("^every_(.+)$") or name:match("^random_(.+)$") or name:match("^ordered_(.+)$")
                or name:match("^any_(.+)$") or name:match("^count_(.+)$")
            if l then
                lists[l] = true
            end
        end
    end
    return lists
end

-- ---------------------------------------------------------------------------------------------
-- the static check

function X.static(docs)
    local r = { trigger = {}, effect = {}, link = {}, invented = {}, handlers = {} }
    for _, kind in ipairs({ "trigger", "effect" }) do
        for name in pairs(docs[kind]) do
            r[kind][name] = eval.status(kind, name) or "missing"
        end
    end
    for name in pairs(docs.link) do
        r.link[name] = I.LINKS[name] and "lua" or "missing"
    end
    -- invented: what the Lua registers that the game does not document
    local lists = iterator_lists(docs)
    -- keywords the game accepts and vanilla uses though its documentation leaves them out
    local ACCEPTED = { optimize_memory = true }
    local function inv(tbl, kind, ok)
        for name in pairs(tbl) do
            if type(name) == "string" and not ok(name:lower()) and not ACCEPTED[name:lower()] then
                r.invented[#r.invented + 1] = { kind = kind, name = name }
            end
        end
    end
    inv(I.TRIG, "trigger", function(n) return docs.trigger[n] or docs.link[n] end)
    inv(eval.EFF, "effect", function(n) return docs.effect[n] or docs.link[n] end)
    inv(I.LINKS, "link", function(n) return docs.link[n] or docs.trigger[n] or docs.effect[n] end)
    inv(I.LISTS, "list", function(n) return lists[n] end)
    table.sort(r.invented, function(a, b) return a.kind .. a.name < b.kind .. b.name end)
    -- the effect handlers' sources
    for name, fn in pairs(eval.EFF) do
        if type(fn) == "function" then
            r.handlers[name] = classify(fn)
        end
    end
    return r
end

-- ---------------------------------------------------------------------------------------------
-- the dynamic check

local SCOPE_KIND = {
    country = "country", planet = "planet", colony = "planet", galactic_object = "system",
    fleet = "fleet", ship = "ship", leader = "leader", pop_group = "pop_group", species = "species",
    starbase = "starbase", sector = "sector", megastructure = "megastructure", federation = "federation",
    war = "war", army = "army", deposit = "deposit", situation = "situation", first_contact = "first_contact",
    ["planet ship colony"] = "planet", all = "country", no_scope = "country",
}
-- scopes whose objects are in a store engine.world.KINDS does not name
local SCOPE_STORE = {
    design = "ship_design", archaeological_site = "sites", spy_network = "spy_networks",
    ambient_object = "ambient_object", bypass = "bypasses", job = "pop_jobs",
}

-- keywords that only hold other statements, only show text or only touch the interface (a sound, a
-- tab, telemetry): when their documented use changes nothing, that is the use (its body), not the
-- keyword
local CONTAINER = {}
for _, k in ipairs({ "if", "else", "else_if", "while", "switch", "inverted_switch", "random", "random_list",
    "locked_random_list", "hidden_effect", "custom_tooltip", "custom_tooltip_fail", "tooltip", "log", "log_error",
    "break", "debug_break", "custom_tooltip_with_params", "country_list_tooltip", "owned_planet_list_tooltip",
    "owned_pop_faction_list_tooltip", "owned_leader_list_tooltip", "owned_fleet_list_tooltip", "play_sound",
    "open_shroud_tab", "complete_tutorial_step", "endgame_telemetry" }) do
    CONTAINER[k] = true
end
local function is_container(name)
    return CONTAINER[name] or name:match("^every_") ~= nil or name:match("^random_") ~= nil
        or name:match("^ordered_") ~= nil
end

-- the save's (first) human player's country: `player = { { name country } }`
local function player_country(world)
    local ok, blocks = pcall(world.blocks, world.meta and world.meta.player)
    for _, b in ipairs(ok and blocks or {}) do
        local c = tonumber(world.field(b, "country"))
        if c and world.object("country", c) then
            return c
        end
    end
end

-- the object a keyword's use runs in: the player's country; for a planet scope the player's
-- capital (a colony: most planet keywords need one), else the first colonised planet; else the
-- first object of the store
local function first_of(world, kind, store)
    if store then
        for _, id in ipairs(world.all(store)) do
            if world.object(store, id) then
                return id
            end
        end
        return nil
    end
    if kind == "country" then
        local p = player_country(world)
        if p then
            return p
        end
    end
    if kind == "planet" then
        local p = player_country(world)
        local cap = p and tonumber(world.field(world.object("country", p), "capital"))
        local pid = cap and world.colony_planet and world.colony_planet[cap]
        if pid and world.object("planet", pid) then
            return pid
        end
        for _, id in ipairs(world.all("planet")) do
            if world.planet_colony and world.planet_colony[id] and world.object("planet", id) then
                return id
            end
        end
    end
    for _, id in ipairs(world.all(kind)) do
        if world.object(kind, id) then
            return id
        end
    end
end

-- the world's writers, counted
local function count_writes(world)
    local n = { v = 0 }
    local names = { "set", "append", "insert", "push", "append_value", "remove_value", "remove_entry", "remove",
        "replace", "append_entry", "set_entry", "set_text", "set_key", "insert_value", "remove_at", "place",
        "create", "wrote" }
    local saved = {}
    for _, k in ipairs(names) do
        local f = world[k]
        if type(f) == "function" then
            saved[k] = f
            world[k] = function(...)
                n.v = n.v + 1
                return f(...)
            end
        end
    end
    return n, function()
        for k, f in pairs(saved) do
            world[k] = f
        end
    end
end

-- the blocks whose content is triggers, and those whose content is effects (the docs mod's
-- events and scripted definitions use these; anything inside keeps its block's kind)
local TRIGGER_CTX = { trigger = true, limit = true, potential = true, allow = true, possible = true }
local EFFECT_CTX = { immediate = true, option = true, after = true, effect = true }

-- the statement of a file's tree at a line whose key is the keyword, and whether it stands in a
-- trigger block ("trigger") or an effect block ("effect") by its nearest such block
local function node_at(tree, line, key)
    local found, found_ctx
    local function walk(block, ctx)
        for _, e in ipairs(block) do
            if found then
                return
            end
            if e.key and e.line == line and e.key.text:lower() == key then
                found, found_ctx = e, ctx
                return
            end
            if type(e.value) == "table" and e.value.text == nil then
                local k = e.key and e.key.text:lower()
                local c = ctx
                if k and TRIGGER_CTX[k] then c = "trigger" elseif k and EFFECT_CTX[k] then c = "effect" end
                walk(e.value, c)
            end
        end
    end
    walk(tree, nil)
    return found, found_ctx
end

local function sum_missing(stats)
    local n = 0
    for _, m in pairs(stats.missing) do
        n = n + m.count
    end
    return n
end
local function sum_unmodelled(stats)
    local n = 0
    for _, m in pairs(stats.unmodelled) do
        n = n + (type(m) == "table" and (m.count or 1) or tonumber(m) or 1)
    end
    return n
end

function X.dynamic(mod_dir)
    local world = require("engine.world")
    local E = _G.E
    local stats = eval.stats
    local manifest = lines_of(mod_dir .. "/manifest.tsv")
    if not manifest then
        return nil, "no manifest.tsv in " .. mod_dir
    end
    local trees = {}
    local writes, restore = count_writes(world)
    local out = {}
    for i = 2, #manifest do
        local f = {}
        for v in (manifest[i] .. "\t"):gmatch("([^\t]*)\t") do
            f[#f + 1] = v
        end
        local kind, name, file, line, scope, placed = f[1], f[2], f[3], tonumber(f[4]), f[5], f[6]
        if (kind == "trigger" or kind == "effect" or kind == "link") and placed == "placed" and line then
            local tree = trees[file]
            if tree == nil then
                local text = db.read_file(mod_dir .. "/" .. file)
                tree = text and pdxscript.parse(text, file) or false
                trees[file] = tree
            end
            local res = { kind = kind, name = name, scope = scope }
            local node, nctx
            if tree then node, nctx = node_at(tree, line, name:lower()) end
            local sk = SCOPE_KIND[scope] or scope
            local id = node and first_of(world, sk, SCOPE_STORE[scope])
            if not node then
                res.result = "no node"
            elseif not id then
                res.result = "no object in scope " .. scope
            else
                if E and E.flush then pcall(E.flush) end
                local m0, u0, s0, w0 = sum_missing(stats), sum_unmodelled(stats), stats.script, writes.v
                local ap0 = E and E.stats and E.stats.applied or 0
                local un0 = {}
                if E and E.stats and E.stats.unapplied then
                    for k, c in pairs(E.stats.unapplied) do un0[k] = c end
                end
                -- `from` is the player's country: many effects take their actor from it
                local pc = player_country(world)
                local ctx = eval.new_ctx(eval.S(sk, id), pc and eval.S("country", pc) or nil, nil, file)
                -- the use's own block decides (a link's use is `link = { always = yes }` in a trigger)
                local is_trigger = nctx == "trigger" or (nctx == nil and kind == "trigger")
                local ok, err = pcall(function()
                    if is_trigger then
                        res.value = eval.trigger({ node }, ctx)
                    else
                        eval.effect({ node }, ctx)
                    end
                    if E and E.flush then E.flush() end
                end)
                -- engine effects not applied: refused by their applier, or with none
                local refused, noapp, types = 0, 0, {}
                if E and E.stats and E.stats.unapplied then
                    for k, c in pairs(E.stats.unapplied) do
                        local d = c - (un0[k] or 0)
                        if d > 0 then
                            types[#types + 1] = k
                            if appliers[k] then refused = refused + d else noapp = noapp + d end
                        end
                    end
                end
                table.sort(types)
                res.missing = sum_missing(stats) - m0
                res.unmodelled = sum_unmodelled(stats) - u0
                res.script = stats.script - s0
                res.writes = writes.v - w0
                res.applied = (E and E.stats and E.stats.applied or 0) - ap0
                res.unapplied = refused + noapp
                res.engine_types = table.concat(types, " ")
                if not ok then
                    res.result = "error"
                    res.error = tostring(err):gsub("[\r\n\t]", " "):sub(1, 200)
                elseif res.missing > 0 then
                    res.result = "missing"
                elseif res.unmodelled > 0 then
                    res.result = "unmodelled"
                elseif noapp > 0 then
                    res.result = "no applier"
                elseif refused > 0 and res.applied == 0 and res.writes == 0 then
                    res.result = "refused"
                elseif is_trigger and kind == "link" then
                    -- `link = { always = yes }`: true when the link found its scope
                    res.result = res.value and "resolved" or "no target"
                elseif is_trigger then
                    res.result = "evaluated"
                elseif res.writes > 0 or res.applied > 0 or res.script > 0 then
                    res.result = "acted"
                elseif is_container(name:lower()) then
                    res.result = "container"
                else
                    res.result = "silent"
                end
            end
            out[#out + 1] = res
        end
    end
    restore()
    return out
end

-- ---------------------------------------------------------------------------------------------
-- the report

function X.run(opts)
    local docs = X.read_docs(opts.docs)
    local st = X.static(docs)
    -- vanilla's uses (simscript.coverage's census, when it has run)
    local census = {}
    local okc, cov = pcall(require, "simscript.coverage")
    if okc and cov.census then
        census = cov.census() or {}
    end
    local function uses(kind, name)
        local c = census[kind] and census[kind][name]
        return c and c.count or 0
    end
    local dyn
    if opts.dynamic and opts.mod then
        dyn = X.dynamic(opts.mod)
    end
    local dres = {}
    for _, d in ipairs(dyn or {}) do
        dres[d.kind .. "\t" .. d.name:lower()] = d
    end

    local out = {}
    local function p(fmt, ...) out[#out + 1] = string.format(fmt, ...) end
    p("documented: %d triggers, %d effects, %d scope links, %d modifiers, %d localisation commands",
        count(docs.trigger), count(docs.effect), count(docs.link), count(docs.modifier), count(docs.loc))
    for _, kind in ipairs({ "trigger", "effect", "link" }) do
        local by = {}
        for _, s in pairs(st[kind]) do
            by[s] = (by[s] or 0) + 1
        end
        local names = {}
        for s in pairs(by) do names[#names + 1] = s end
        table.sort(names)
        local parts = {}
        for _, s in ipairs(names) do parts[#parts + 1] = s .. " " .. by[s] end
        p("static %s: %s", kind, table.concat(parts, ", "))
        -- the missing ones by the scope the game documents first for them
        local by_scope = {}
        for name, s in pairs(st[kind]) do
            if s == "missing" then
                local e = docs[kind][name]
                local sc = type(e.scopes) == "table" and (e.scopes[1] or "?") or tostring(e.scopes)
                by_scope[sc] = (by_scope[sc] or 0) + 1
            end
        end
        local scs = {}
        for sc, n in pairs(by_scope) do scs[#scs + 1] = { sc, n } end
        table.sort(scs, function(a, b) return a[2] > b[2] end)
        local sp = {}
        for _, x in ipairs(scs) do sp[#sp + 1] = x[1] .. " " .. x[2] end
        if #sp > 0 then p("  missing by scope: %s", table.concat(sp, ", ")) end
    end
    p("invented (registered by the Lua, not documented by the game): %d", #st.invented)
    for i = 1, math.min(40, #st.invented) do
        p("  %s %s", st.invented[i].kind, st.invented[i].name)
    end
    local nh, unm, empty, noapp = 0, 0, 0, {}
    for name, c in pairs(st.handlers) do
        nh = nh + 1
        if c.unmodelled then unm = unm + 1 end
        if c.empty then empty = empty + 1 end
        for ty, has in pairs(c.pushes or {}) do
            if not has then noapp[#noapp + 1] = name .. " -> " .. ty end
        end
    end
    table.sort(noapp)
    p("effect handlers: %d; record unmodelled in some path: %d; empty bodies: %d; push an engine effect nothing applies: %d",
        nh, unm, empty, #noapp)
    for i = 1, math.min(30, #noapp) do p("  %s", noapp[i]) end
    if dyn then
        local by = {}
        for _, d in ipairs(dyn) do
            local k = d.kind .. " " .. d.result
            by[k] = (by[k] or 0) + 1
        end
        local names = {}
        for k in pairs(by) do names[#names + 1] = k end
        table.sort(names)
        p("dynamic (one documented use each, run in a world):")
        for _, k in ipairs(names) do p("  %-34s %5d", k, by[k]) end
    end

    -- one row per documented keyword
    if opts.out then
        local f = assert(io.open(opts.out, "wb"))
        f:write("kind\tname\tscopes\tstatic\tvanilla_uses\tdynamic\tmissing\tunmodelled\tunapplied\tapplied\twrites\tscript\thandler\tnote\n")
        for _, kind in ipairs({ "trigger", "effect", "link" }) do
            local names = {}
            for n in pairs(docs[kind]) do names[#names + 1] = n end
            table.sort(names)
            for _, n in ipairs(names) do
                local e = docs[kind][n]
                local d = dres[kind .. "\t" .. n] or {}
                local h = kind == "effect" and st.handlers[n] or nil
                local note = d.error or ""
                if d.engine_types and d.engine_types ~= "" then
                    note = (note ~= "" and note .. "; " or "") .. "engine: " .. d.engine_types
                end
                if h then
                    local tags = {}
                    if h.unmodelled then tags[#tags + 1] = "unmodelled-path" end
                    if h.empty then tags[#tags + 1] = "empty" end
                    for ty, has in pairs(h.pushes or {}) do tags[#tags + 1] = "push:" .. ty .. (has and "" or "(no applier)") end
                    table.sort(tags)
                    if #tags > 0 then note = (note ~= "" and note .. "; " or "") .. table.concat(tags, " ") end
                end
                f:write(table.concat({
                    kind, e.name, type(e.scopes) == "table" and table.concat(e.scopes, " ") or tostring(e.scopes),
                    st[kind][n] or "", tostring(uses(kind, n)), d.result or "", tostring(d.missing or ""),
                    tostring(d.unmodelled or ""), tostring(d.unapplied or ""), tostring(d.applied or ""),
                    tostring(d.writes or ""), tostring(d.script or ""), h and h.where or "", note,
                }, "\t") .. "\n")
            end
        end
        for _, v in ipairs(st.invented) do
            f:write(table.concat({ "invented-" .. v.kind, v.name, "", "", "", "", "", "", "", "", "", "", "", "" }, "\t") .. "\n")
        end
        f:close()
        p("written: %s", opts.out)
    end
    return { text = table.concat(out, "\n"), static = st, dynamic = dyn, docs = docs }
end

return X
