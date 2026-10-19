-- engine/species_mod.lua : species modification projects ("Apply Genetic Modification": a species
-- template applied to the pops of other species of its base). The 4.5.2 Linux build's code
-- (docs/windows/empire.md section 14; the shared notes' empire_re/species_mod_project.md):
--
--   start     CCreateSpeciesModSpecialProjectCommand: IsValid (CanApplyTemplateToColonies), then
--             CCountryEventManager::AddSpecialProject (events.special_project, its id
--             next_special_project_id) and CTechnologyStatus::ResearchSpecialProject (a queue item
--             before the queue's first technology: society_queue, engineering_queue for a robotic
--             template)
--   cost      NSpeciesModification::CalcCost: TRAIT_MODIFICATION_BASE_COST + per 100 pops
--             TRAIT_MODIFICATION_COST_MULT x the traits' difference + MODIFICATION_COST_MULT (the
--             ROBO_ defines for robots), x AI_POP_MODIFICATION_DISCOUNT for a country no human plays,
--             x (1 + modify_species_cost_mult); in society research (engineering for robots),
--             recomputed from the pops each time
--   progress  the research queue's monthly points (engine.research's area_day), only while the
--             project can progress (CSpecialProjectInstance::CanProgress); done when its progress
--             reaches max(cost, 1), checked daily
--   daily     CCountryEventManager::DailyUpdateSerial: a project that cannot progress counts its
--             days_left down and fails (status failed: out of the queue and the events)
--   complete  OnSuccessSpeciesModification: one draw of the generator; for each pair whose colony
--             the country still owns, CCountry::HandleSpeciesModification (the default species; the
--             leaders and armies of the species by the colony's share; the colony's pop groups of the
--             species moved, last first, into the template's group of the same category; the founder
--             species) and on_modification_complete; then on_modification_completion, the flag
--             has_modified_species (not for robots); the project leaves the events
--
-- The lookups the cost needs (a trait's cost, a class's archetype, the defines, the country's
-- modifiers, whether a human plays the country) are M.lookup's, so the views' runtime can give its
-- own (render.windows.species_mod).

local world = require("engine.world")

local M = {
    stats = { started = 0, refused = 0, progressed = 0, completed = 0, failed = 0, pops_moved = 0 },
}

local NONE = 4294967295
local FP = 100000

local function strip(v)
    return type(v) == "string" and (v:gsub('"', "")) or v
end

-- the simulation's definitions (engine.defs)
local function def(dir, key)
    local ok, defs = pcall(require, "engine.defs")
    local d = ok and defs.get(dir, key or "")
    return d and (d.block or d), d and d.file
end

local function define(group, key)
    local ok, defs = pcall(require, "engine.defs")
    if not ok then
        return nil
    end
    for _, d in pairs(defs.folder("common/defines") or {}) do
        local v = defs.field(defs.field(d.block, group) or {}, key)
        if v ~= nil then
            return tonumber(v)
        end
    end
    return nil
end

local humans
M.lookup = {
    -- a trait's cost (CTrait::GetCost: a number, or a scripted block in the country's scope)
    trait_cost = function(key, cid)
        local d, file = def("common/traits", key)
        local v = d and world.field(d, "cost")
        if type(v) == "number" then
            return v
        end
        if type(v) == "table" then
            local ok, eval = pcall(function()
                return package.loaded["simscript.eval"] or require("simscript.eval")
            end)
            if ok then
                local e = world.entry(d, "cost")
                local ok2, r = pcall(eval.value, e.value, eval.new_ctx(eval.S("country", cid), nil, nil, file), e)
                if ok2 and tonumber(r) then
                    return tonumber(r)
                end
            end
        end
        return tonumber(v) or 0
    end,
    -- a species class's archetype (common/species_classes `archetype`)
    archetype = function(class)
        local d = def("common/species_classes", class)
        return strip(d and world.field(d, "archetype")) or "BIOLOGICAL"
    end,
    -- an archetype's robotic flag (common/species_archetypes `robotic = yes`)
    robotic = function(arch)
        local d = def("common/species_archetypes", arch)
        return d ~= nil and world.field(d, "robotic") == "yes"
    end,
    define = function(key, default)
        return define("NSpecies", key) or define("NPop", key) or define("NGameplay", key) or default
    end,
    modifiers = function(cid)
        local economy = package.loaded["engine.economy"]
        return economy and economy.has_modifier_source() and economy.modifiers("country", cid) or {}
    end,
    -- whether a human plays the country (the save's `player = { { country } }`)
    human = function(cid)
        if humans == nil then
            humans = {}
            for _, e in ipairs(world.tree or {}) do
                if e.op and e.key and e.key.text == "player" and e.value.text == nil then
                    for _, p in ipairs(world.blocks(e.value)) do
                        local c = tonumber(world.field(p, "country"))
                        if c then humans[c] = true end
                    end
                end
            end
        end
        return humans[cid] == true
    end,
}

-- ---------------------------------------------------------------------------------------------
-- species and colonies

local function species(id)
    return id and world.object("species", tonumber(id))
end

function M.base_of(id)
    local s = species(id)
    return s and (tonumber(world.field(s, "base_ref")) or tonumber(id)) or nil
end

function M.traits(id)
    local out = {}
    local tb = world.field(species(id), "traits")
    for _, t in ipairs(world.fields(tb, "trait") or {}) do
        out[#out + 1] = strip(type(t) == "table" and t.text or t)
    end
    return out
end

local function archetype(id, L)
    return (L or M.lookup).archetype(strip(world.field(species(id), "class")))
end

-- CSpecies::IsSapient: not a pre-sapient [I: by the class's archetype]
function M.sapient(id, L)
    return species(id) ~= nil and archetype(id, L) ~= "PRESAPIENT"
end

-- the class's IsRobotic (the archetype's `robotic`)
function M.robotic(id, L)
    return (L or M.lookup).robotic(archetype(id, L))
end

-- the colony's planet's owner
local function owner(col)
    local c = world.object("colony", col)
    local carrier = c and world.field(c, "carrier")
    local pid = carrier and strip(world.field(carrier, "type")) == "planet" and tonumber(world.field(carrier, "reference"))
    local p = pid and world.object("planet", pid)
    return p and tonumber(world.field(p, "owner")) or nil
end
M.owner = owner

-- CalcNumPopsWithSpeciesOnColony<SExact>: the sizes of the colony's groups of the species
function M.pops_on(col, sp)
    local c = world.object("colony", col)
    local n = 0
    for _, gid in ipairs(world.list(c and world.field(c, "pop_groups"))) do
        local g = world.object("pop_groups", tonumber(gid))
        if g and tonumber(world.path(g, "key", "species")) == tonumber(sp) then
            n = n + (tonumber(world.field(g, "size")) or 0)
        end
    end
    return n
end

-- NSpeciesModification::CalcTraitModificationCost: the traits one has and the other not, each a
-- planet preference TRAIT_CLIMATE_MODIFICATION_COST (3), else |its cost| (1 when 0)
function M.trait_delta(template, sp, cid, traits_of, L)
    traits_of, L = traits_of or M.traits, L or M.lookup
    local a, b = traits_of(template), traits_of(sp)
    local sa, sb = {}, {}
    for _, t in ipairs(a) do sa[t] = true end
    for _, t in ipairs(b) do sb[t] = true end
    local function w(t)
        if t:match("^trait_pc_.*_preference$") then
            return L.define("TRAIT_CLIMATE_MODIFICATION_COST", 3)
        end
        local c = L.trait_cost(t, cid) or 0
        return c ~= 0 and math.abs(c) or 1
    end
    local cost = 0
    for _, t in ipairs(a) do
        if not sb[t] then cost = cost + w(t) end
    end
    for _, t in ipairs(b) do
        if not sa[t] then cost = cost + w(t) end
    end
    return cost
end

-- the research area of a template's project (GetTechDepartment: the class's IsRobotic + 1)
function M.area(template)
    return M.robotic(template) and "engineering" or "society"
end

-- the cost's formula: entries = { { n = the pops, d = the traits' difference } } (the pairs that
-- count), robo the template's robots' defines, cid the country (its modifiers; a human's or not)
function M.formula(robo, entries, cid, L)
    L = L or M.lookup
    local base = robo and L.define("ROBO_TRAIT_MODIFICATION_BASE_COST", 750) or L.define("TRAIT_MODIFICATION_BASE_COST", 1500)
    local bulk = L.define("POP_BULK_UNIT_SIZE", 100)
    local trait_sum, pops = 0, 0
    for _, e in ipairs(entries) do
        if e.n > 0 then
            trait_sum = trait_sum + math.floor(e.d * e.n / bulk)
            pops = pops + e.n
        end
    end
    local trait_part = trait_sum * (robo and L.define("ROBO_TRAIT_MODIFICATION_COST_MULT", 20) or L.define("TRAIT_MODIFICATION_COST_MULT", 10))
    local pop_part = math.floor(pops * (robo and L.define("ROBO_MODIFICATION_COST_MULT", 10) or L.define("MODIFICATION_COST_MULT", 5)) * FP / bulk) / FP
    local total = base + trait_part + pop_part
    if not L.human(cid) then
        total = total * L.define("AI_POP_MODIFICATION_DISCOUNT", 0.25)
    end
    total = total * (1 + (tonumber(L.modifiers(cid).modify_species_cost_mult) or 0))
    return math.floor(total * FP) / FP, pops
end

-- NSpeciesModification::CalcCost: pairs = { { species, colony } } (a sapient species on a colony the
-- country owns, its pops there); the cost in its area's research, and the pops
function M.cost(cid, template, pairs, traits_of, L)
    L = L or M.lookup
    local entries = {}
    for _, pr in ipairs(pairs) do
        local sp, col = pr[1], pr[2]
        if species(sp) and M.sapient(sp, L) and owner(col) == cid then
            local n = M.pops_on(col, sp)
            if n > 0 then
                entries[#entries + 1] = { n = n, d = M.trait_delta(template, sp, cid, traits_of, L) }
            end
        end
    end
    return M.formula(M.robotic(template, L), entries, cid, L)
end

-- ---------------------------------------------------------------------------------------------
-- the projects

local function events_of(cid)
    local c = world.object("country", cid)
    return c and world.field(c, "events")
end

-- the pairs of a project block (`species = { { species planet } }`: planet is a colony id)
function M.pairs(p)
    local out = {}
    for _, e in ipairs(world.blocks(world.field(p, "species"))) do
        out[#out + 1] = { tonumber(world.field(e, "species")), tonumber(world.field(e, "planet")) }
    end
    return out
end

-- the country's species modification project of an id (a special_project with convert_to)
function M.project(cid, id)
    for _, p in ipairs(world.fields(events_of(cid), "special_project") or {}) do
        if type(p) == "table" and tonumber(world.field(p, "id")) == id and world.field(p, "convert_to") ~= nil then
            return p
        end
    end
    return nil
end

-- CSpecialProjectInstance::CanProgress for a species modification: a pair's colony still owned and
-- still with its species (of the first pair's sapience)
function M.can_progress(cid, p)
    local prs = M.pairs(p)
    local first = prs[1] and M.sapient(prs[1][1])
    for _, pr in ipairs(prs) do
        if species(pr[1]) and M.sapient(pr[1]) == first and owner(pr[2]) == cid and M.pops_on(pr[2], pr[1]) > 0 then
            return true
        end
    end
    return false
end

-- the project's cost now (CalcProgressNeeded: at least 1)
function M.needed(cid, p)
    return math.max(1, (M.cost(cid, tonumber(world.field(p, "convert_to")), M.pairs(p))))
end

-- CanApplyTemplateToColonies (the command's IsValid): no modification running in the template's
-- area (ALREADY_MODIFYING), every pair an owned colony and a sapient species of the template's base
-- the country may modify, and pops to change (MUST_SELECT_PLANETS); nil or the reason
function M.invalid(cid, template, pairs)
    if not species(template) then
        return "no such template"
    end
    local area = M.area(template)
    for _, p in ipairs(world.fields(events_of(cid), "special_project") or {}) do
        if type(p) == "table" and world.field(p, "convert_to") ~= nil and M.area(tonumber(world.field(p, "convert_to"))) == area then
            return "ALREADY_MODIFYING"
        end
    end
    local sum = 0
    for _, pr in ipairs(pairs) do
        if owner(pr[2]) ~= cid or not species(pr[1]) or M.base_of(pr[1]) ~= M.base_of(template) or not M.sapient(pr[1]) then
            return "the pair " .. tostring(pr[1]) .. "/" .. tostring(pr[2]) .. " is not valid"
        end
        sum = sum + M.pops_on(pr[2], pr[1])
    end
    if sum <= 0 then
        return "MUST_SELECT_PLANETS"
    end
    return nil
end

local function today()
    return (tostring(world.meta.date or ""):gsub('"', ""))
end

-- CCreateSpeciesModSpecialProjectCommand::Execute: the project made and queued; its id, or nil and
-- why not
function M.start(cid, template, pairs)
    local why = M.invalid(cid, template, pairs)
    if why then
        M.stats.refused = M.stats.refused + 1
        return nil, why
    end
    local c = world.object("country", cid)
    local events = world.child(c, "events")
    local id = tonumber(world.field(events, "next_special_project_id")) or 1
    world.set(events, "next_special_project_id", id + 1)
    local p = {}
    world.append(p, "id", id)
    world.append(p, "days_left", M.lookup.define("TRAIT_MODIFICATION_TIME_LIMIT", 30))
    local coord = {}
    world.append(coord, "type", 10)
    world.append(coord, "id", NONE)
    world.append(p, "coordinate", coord)
    local carrier = {}
    world.append(carrier, "type", "planet")
    world.append(carrier, "reference", NONE)
    world.append(p, "carrier", carrier)
    world.append(p, "status", "in_progress")
    world.append(p, "convert_to", template)
    local list = {}
    for _, pr in ipairs(pairs) do
        local e = {}
        world.append(e, "species", pr[1])
        world.append(e, "planet", pr[2])
        world.push(list, e)
    end
    world.append(p, "species", list)
    -- (at the end of the events [I: the game writes its special projects first])
    world.append_entry(events, { key = { text = "special_project" }, op = "=", value = p })
    -- the queue item, before the queue's first technology
    local status = world.child(c, "tech_status")
    local queue = world.child(status, M.area(template) .. "_queue")
    local item = {}
    world.append(item, "special_project", id)
    world.append(item, "date", today(), true)
    local pos = #queue + 1
    for i, e in ipairs(queue) do
        if not e.op and not e.text and world.field(e, "technology") ~= nil then
            pos = i
            break
        end
    end
    world.insert_value(queue, pos, item)
    M.stats.started = M.stats.started + 1
    return id
end

-- the project's queue item taken out, the project out of the events
local function remove(cid, p)
    local c = world.object("country", cid)
    local id = tonumber(world.field(p, "id"))
    local status = world.field(c, "tech_status")
    for _, area in ipairs({ "physics", "society", "engineering" }) do
        local queue = world.field(status, area .. "_queue")
        for _, e in ipairs(type(queue) == "table" and world.blocks(queue) or {}) do
            if tonumber(world.field(e, "special_project")) == id then
                world.remove_entry(queue, e)
            end
        end
    end
    local events = events_of(cid)
    for _, e in ipairs(events or {}) do
        if e.op and e.key and e.key.text == "special_project" and e.value == p then
            world.remove_entry(events, e)
            break
        end
    end
end

-- CCountryEventManager::DailyUpdateSerial, its species modifications: one that cannot progress
-- counts days_left down and fails (ShouldFail: days_left 0, or no pair left to change)
function M.daily(cid)
    for _, p in ipairs(world.fields(events_of(cid), "special_project") or {}) do
        if type(p) == "table" and world.field(p, "convert_to") ~= nil and strip(world.field(p, "status")) == "in_progress"
            and not M.can_progress(cid, p) then
            local left = tonumber(world.field(p, "days_left")) or 0
            if left > 0 then
                left = left - 1
                world.set(p, "days_left", left)
            end
            world.set(p, "status", left == 0 and "timed_out" or "failed")
            M.stats.failed = M.stats.failed + 1
            remove(cid, p)
        end
    end
end

-- the generator's draw (CRandom::GetIntegerForMacro) the success makes
local function draw()
    local eval = package.loaded["simscript.eval"]
    if eval and eval.rand then
        pcall(eval.rand)
    end
end

local function fire(name, cid)
    local ok, eval = pcall(function()
        return package.loaded["simscript.eval"] or require("simscript.eval")
    end)
    if ok then
        pcall(function()
            require("simscript.events").on_action(name, eval.S("country", cid))
        end)
    end
end

-- the pops of a species on the country's colonies (GetNumPopsOfExactSpecies over its colonies)
local function country_pops(cid, sp)
    local c = world.object("country", cid)
    local n = 0
    for _, k in ipairs(world.list(world.field(c, "controlled_colonies"))) do
        n = n + M.pops_on(tonumber(k), sp)
    end
    return n
end

-- CCountry::HandleSpeciesModification(colony, from, to, mode 0)
local function handle(cid, col, from, to)
    if not species(from) or not M.sapient(from) then
        return
    end
    local c = world.object("country", cid)
    -- SetDefaultSpecies(to)
    world.set(world.child(c, "default_species"), tostring(M.base_of(to)), to)
    -- the leaders and armies of the species, by the colony's share of its pops (rounded) [I: the
    -- leaders' order: the ruler and the heir last]
    local here, all = M.pops_on(col, from), country_pops(cid, from)
    if here > 0 and all > 0 then
        local share = here / all
        local ruler = tonumber(world.field(c, "ruler"))
        local list, last = {}, {}
        for _, k in ipairs(world.list(world.field(c, "owned_leaders"))) do
            local l = world.object("leader", tonumber(k))
            if l and tonumber(world.field(l, "species")) == from then
                if tonumber(k) == ruler then
                    last[#last + 1] = l
                else
                    list[#list + 1] = l
                end
            end
        end
        for _, l in ipairs(last) do
            list[#list + 1] = l
        end
        local n = math.floor(#list * share + 0.5)
        for i = 1, n do
            world.set(list[i], "species", to)
        end
        local armies = {}
        for _, aid in ipairs(world.all("army")) do
            local a = world.object("army", aid)
            if a and tonumber(world.field(a, "owner")) == cid and tonumber(world.field(a, "species")) == from then
                armies[#armies + 1] = a
            end
        end
        for i = 1, math.floor(#armies * share + 0.5) do
            world.set(armies[i], "species", to)
        end
    end
    -- CColony::HandleSpeciesModification: the groups of the species, last first, into the group of
    -- the template with the same category (made when the colony has none)
    local colony = require("engine.script.objects_colony")
    local pops = require("engine.pops")
    local cobj = world.object("colony", col)
    local gids = world.list(cobj and world.field(cobj, "pop_groups"))
    for i = #gids, 1, -1 do
        local gid = tonumber(gids[i])
        local g = gid and world.object("pop_groups", gid)
        if g and tonumber(world.path(g, "key", "species")) == from then
            local cat = strip(world.path(g, "key", "category"))
            local size = tonumber(world.field(g, "size")) or 0
            local dst
            for _, other in ipairs(world.list(world.field(cobj, "pop_groups"))) do
                local o = world.object("pop_groups", tonumber(other))
                if o and tonumber(world.path(o, "key", "species")) == to and strip(world.path(o, "key", "category")) == cat then
                    dst = tonumber(other)
                end
            end
            dst = dst or colony.new_group(col, to, cat)
            if size > 0 then
                pops.move_size(dst, gid, size, "GROWTH_CAT_SPECIES_MOD", col)
                M.stats.pops_moved = M.stats.pops_moved + size
            end
        end
    end
    -- the founder species
    if tonumber(world.field(c, "founder_species_ref")) == from then
        world.set(c, "founder_species_ref", to)
    end
end

-- OnSuccessSpeciesModification, then the project out of the events
function M.complete(cid, p)
    local to = tonumber(world.field(p, "convert_to"))
    draw()
    for _, pr in ipairs(M.pairs(p)) do
        if owner(pr[2]) == cid then
            handle(cid, pr[2], pr[1], to)
            fire("on_modification_complete", cid)
        end
    end
    fire("on_modification_completion", cid)
    if not M.robotic(to) then
        local ok, eval = pcall(function()
            return package.loaded["simscript.eval"] or require("simscript.eval")
        end)
        if ok then
            pcall(eval.effect, { { key = { text = "set_country_flag" }, op = "=", value = { text = "has_modified_species" } } },
                eval.new_ctx(eval.S("country", cid)))
        end
    end
    world.set(p, "status", "completed")
    remove(cid, p)
    M.stats.completed = M.stats.completed + 1
end

return M
