-- graph_mapping.lua : the game's modifier definitions and economy, read from the game's files, as
-- stellar.graph nodes: a check of the mapping layer on real data, offline.
--
--   luajit tools/graph_mapping.lua [modifiers.log] [game dir]
--
-- 1. reads modifiers.log (the game writes it at every start, logs/script_documentation) into the
--    definitions (names, categories);
-- 2. reads common/strategic_resources and common/economic_categories (pdxscript), generates the
--    names each category makes by the game's rules and checks them against modifiers.log;
-- 3. reads common/static_modifiers and common/pop_jobs: modifier blocks and resource tables;
-- 4. builds a colony with one bulk unit of every job (base amounts; triggered blocks off), sums
--    its production, then applies a country-wide edict and shows what the graph recomputes.
-- Bounded: a few seconds.

local dir = (arg and arg[0] or ""):match("^(.*)[/\\]tools[/\\][^/\\]*$") or "."
package.path = dir .. "/lua/?.lua;" .. dir .. "/lib/stellar-lua-pdxscript/?.lua;" .. package.path

local core = require("stellar.graph.core")
local modifiers = require("stellar.graph.modifiers")
local economy = require("stellar.graph.economy")
local source = require("stellar.script.source")
local util = require("stellar.util")

local log_path = arg and arg[1] or ((os.getenv("USERPROFILE") or ""):gsub("\\", "/")
    .. "/Documents/Paradox Interactive/Stellaris/logs/script_documentation/modifiers.log")
local game_dir = arg and arg[2] or "C:/Program Files (x86)/Steam/steamapps/common/Stellaris"

local t_start = util.now()
local function say(fmt, ...)
    io.write(string.format("[%6.2fs] " .. fmt .. "\n", util.now() - t_start, ...))
    io.flush()
end

-- 1. definitions
local f = io.open(log_path, "rb")
if f == nil then
    say("no modifiers.log at %s (give its path as the first argument)", log_path)
    os.exit(1)
end
local text = f:read("*a")
f:close()
local defs = modifiers.definitions()
local ndefs = defs:read_log(text)
say("modifiers.log: %d definitions", ndefs)
if ndefs == 0 then
    say("modifiers.log is empty (the game rewrites it while it starts)")
    os.exit(1)
end

-- scripted variables (common/scripted_variables and a file's own @x = value)
local globals = {}
local function read_variables(tree, into)
    for _, e in ipairs(tree) do
        if e.op == "=" and e.key and e.key.text:sub(1, 1) == "@" and e.value.text then
            into[e.key.text] = tonumber(e.value.text)
        end
    end
end
for _, rel in ipairs(source.files(game_dir, "common/scripted_variables", "txt")) do
    local tree = source.parse(game_dir, rel)
    if tree then
        read_variables(tree, globals)
    end
end

-- 2. resources and economic categories
local resources = {}
for _, rel in ipairs(source.files(game_dir, "common/strategic_resources", "txt")) do
    local tree = source.parse(game_dir, rel)
    for _, e in ipairs(tree or {}) do
        if e.op == "=" and e.key and type(e.value) == "table" and e.value.text == nil then
            resources[#resources + 1] = e.key.text
        end
    end
end
say("strategic resources: %d (%s ... %s)", #resources, resources[1] or "", resources[#resources] or "")

local cats = economy.categories()
for _, rel in ipairs(source.files(game_dir, "common/economic_categories", "txt")) do
    local tree, message = source.parse(game_dir, rel)
    if tree == nil then
        say("%s", message)
    else
        cats:read(tree)
    end
end
local generated, found, missing = 0, 0, {}
local made = {}
for _, cat in ipairs(cats.list) do
    for _, name in ipairs(cats:generated(cat.name, resources)) do
        generated = generated + 1
        made[name] = true
        if defs.ids[name] then
            found = found + 1
        elseif #missing < 8 then
            missing[#missing + 1] = name
        end
    end
end
local extra, extra_list = 0, {}
for name in pairs(defs.ids) do
    if name:match("_(produces)_(add)$") or name:match("_(produces)_(mult)$") or name:match("_upkeep_add$")
        or name:match("_upkeep_mult$") or name:match("_cost_add$") or name:match("_cost_mult$")
        or name:match("_logistics_mult$") or name:match("_logistics_add$") then
        if not made[name] then
            extra = extra + 1
            if #extra_list < 8 then
                extra_list[#extra_list + 1] = name
            end
        end
    end
end
local maxdepth, deepest = 0, nil
for _, cat in ipairs(cats.list) do
    local d = #cats:chain(cat.name)
    if d > maxdepth then
        maxdepth, deepest = d, cat.name
    end
end
say("economic categories: %d, deepest chain %d (%s)", #cats.list, maxdepth, tostring(deepest))
say("generated names: %d by the rules, %d of them in modifiers.log%s", generated, found,
    #missing > 0 and (" (not found: " .. table.concat(missing, ", ") .. ")") or "")
say("economy-like names in modifiers.log the rules do not make: %d%s", extra,
    #extra_list > 0 and (" (" .. table.concat(extra_list, ", ") .. ", ...)") or "")

-- 3. static modifiers and jobs
local function number(token, vars)
    if token == nil or token.text == nil then
        return nil
    end
    local t = token.text
    if t:sub(1, 1) == "@" then
        return vars[t] or globals[t]
    end
    return tonumber(t)
end

local statics, static_entries, static_unknown, unknown_list = 0, 0, 0, {}
local NOT_MODIFIERS = { icon = true, icon_frame = true, custom_tooltip = true, apply_modifier_to_other_planets = true,
    show_only_custom_tooltip = true, hide_from_country_list = true, picture = true, important = true, desc = true,
    divide_over_pop_groups = true }
local static_values = {}
for _, rel in ipairs(source.files(game_dir, "common/static_modifiers", "txt")) do
    local tree = source.parse(game_dir, rel)
    local vars = {}
    read_variables(tree or {}, vars)
    for _, e in ipairs(tree or {}) do
        if e.op == "=" and e.key and type(e.value) == "table" and e.value.text == nil then
            statics = statics + 1
            local values = {}
            for _, m in ipairs(e.value) do
                local k = m.key and m.key.text
                if k and not NOT_MODIFIERS[k] then
                    local v = number(m.value, vars)
                    if defs.ids[k] and v then
                        values[k] = (values[k] or 0) + v
                        static_entries = static_entries + 1
                    elseif not defs.ids[k] then
                        static_unknown = static_unknown + 1
                        if #unknown_list < 6 then
                            unknown_list[#unknown_list + 1] = k
                        end
                    end
                end
            end
            static_values[e.key.text] = values
        end
    end
end
say("static modifiers: %d, %d modifier entries, %d keys that are not modifier types%s", statics, static_entries,
    static_unknown, #unknown_list > 0 and (" (" .. table.concat(unknown_list, ", ") .. ", ...)") or "")

-- jobs: resources = { category = C produces = { [trigger = { }] res = amount ... } ... }
local jobs, njobs, blocks, triggered, unresolved, nocat = {}, 0, 0, 0, 0, 0
for _, rel in ipairs(source.files(game_dir, "common/pop_jobs", "txt")) do
    local tree = source.parse(game_dir, rel)
    local vars = {}
    read_variables(tree or {}, vars)
    for _, e in ipairs(tree or {}) do
        if e.op == "=" and e.key and type(e.value) == "table" and e.value.text == nil then
            for _, m in ipairs(e.value) do
                if m.key and m.key.text == "resources" and type(m.value) == "table" then
                    local spec = { category = nil }
                    for _, r in ipairs(m.value) do
                        local k = r.key and r.key.text
                        if k == "category" then
                            spec.category = r.value.text
                        elseif economy.TABLES and (k == "produces" or k == "upkeep" or k == "cost") and type(r.value) == "table" then
                            local block = { values = {} }
                            for _, x in ipairs(r.value) do
                                local xk = x.key and x.key.text
                                if xk == "trigger" then
                                    block.has_trigger = true
                                elseif xk and xk ~= "multiplier" and xk ~= "mult" then
                                    local v = number(x.value, vars)
                                    if v then
                                        block.values[xk] = v
                                    else
                                        unresolved = unresolved + 1
                                    end
                                end
                            end
                            blocks = blocks + 1
                            if block.has_trigger then
                                triggered = triggered + 1
                            end
                            spec[k] = spec[k] or {}
                            spec[k][#spec[k] + 1] = block
                        end
                    end
                    if spec.category == nil or cats:get(spec.category) == nil then
                        nocat = nocat + 1
                    end
                    jobs[e.key.text] = spec
                    njobs = njobs + 1
                end
            end
        end
    end
end
say("pop jobs with resources: %d, %d resource blocks (%d with a trigger), %d values not resolved, %d without a known category",
    njobs, blocks, triggered, unresolved, nocat)

-- 4. a colony with one bulk unit (100 workforce) of every job
local g = core.new({ nodes = 65536, edges = 131072 })
local tree = modifiers.new(g, defs)
local eco = economy.new(tree, cats, { resources = resources })
local country = tree:holder("country", 1)
local colony = tree:holder("colony", 1)
tree:link(colony, country)  -- (the game: colony <- planet <- country, filtered by category)
local totals = {}
for _, r in ipairs(resources) do
    totals[r] = { produces = eco:total(core.MONTH), upkeep = eco:total(core.MONTH) }
end
local t0 = util.now()
local units = 0
local names = {}
for name in pairs(jobs) do
    names[#names + 1] = name
end
table.sort(names)
for _, name in ipairs(names) do
    local spec = jobs[name]
    if spec.category and cats:get(spec.category) then
        local s = { category = spec.category }
        for _, t in ipairs({ "produces", "upkeep" }) do
            if spec[t] then
                s[t] = {}
                for _, b in ipairs(spec[t]) do
                    -- triggered blocks: their trigger input stays 0 (the script layer sets it)
                    s[t][#s[t] + 1] = { values = b.values, trigger = b.has_trigger and g:input(0) or nil }
                end
            end
        end
        local unit = eco:unit(colony, s, 1)
        units = units + 1
        for _, t in ipairs({ "produces", "upkeep" }) do
            for r, node in pairs(unit[t] or {}) do
                if totals[r] then
                    g:link(node, totals[r][t])
                end
            end
        end
    end
end
local function report(label)
    local parts = {}
    for _, r in ipairs({ "energy", "minerals", "food", "alloys", "consumer_goods", "unity", "physics_research" }) do
        if totals[r] then
            parts[#parts + 1] = string.format("%s %.2f/%.2f", r, g:get(totals[r].produces), g:get(totals[r].upkeep))
        end
    end
    say("%s: %s", label, table.concat(parts, ", "))
end
local st = g:stats()
say("colony with %d job units: %d nodes, %d edges, %d modifier holders, built in %.1f ms", units, st.nodes, st.edges,
    tree.nholders, (util.now() - t0) * 1000)
report("produces/upkeep")
local before = g:stats()
tree:add(country, "edict_capacity_overload", { planet_jobs_produces_mult = 0.2 })
g:mark(1e18)
local pend = g:pending()
report("with planet_jobs_produces_mult +20%")
local after = g:stats()
say("the edict marked %d nodes; reading the totals computed %d (%d by delta), %d unmarked unchanged", pend.total,
    after.computes - before.computes, after.deltas - before.deltas, after.cutoffs - before.cutoffs)
local ok, msg = g:check(1e-6)
say("invariants: %s", ok and "ok" or msg)
