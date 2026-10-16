-- engine/script/objects_countries.lua : species, countries and planet ownership made by script
-- (create_species, create_country, create_colony, set_owner / set_controller / set_capital on a
-- planet), from the 4.5.2 Linux build (docs/script_objects.md "Countries and species"). The
-- guardians, enclaves and pre-FTL civilizations of a new game come from these.
--
-- Not ported (each said where it applies): the government solver's random fill
-- (CGovernmentRestrictionsSolver, CalcRandomConfiguration), CTraitSet::Randomize's point budget,
-- the flag randomization (CEmpireFlag::Randomize), the AI block of a new country.

local world = require("engine.world")
local defs = require("engine.defs")
local systems = require("engine.systems")
local objects = require("engine.script.objects")

local applied, skipped, unq, NO_ID = objects.applied, objects.skipped, objects.unq, objects.NO_ID
local draw = objects.draw

local countries = {}
objects.countries = countries

local function names(block, key)
    local out = {}
    local l = block and defs.field(block, key)
    if type(l) == "table" then
        for _, e in ipairs(l) do
            if e.text then out[#out + 1] = unq(e.text) end
        end
    end
    return out
end
local function key_block(key, vars)
    local b = {}
    world.append(b, "key", key, true)
    if vars then world.append(b, "variables", vars) end
    return b
end
local function var(key, value)
    local v = {}
    world.append(v, "key", key, true)
    world.append(v, "value", value)
    return v
end
local function today_text()
    return objects.leaders and objects.leaders.today_text() or "2200.01.01"
end

-- ---------------------------------------------------------------------------------------------
-- species

-- the species classes a random pick may take (`randomized` not no, `playable` not `always = no`);
-- pre-FTL: also the classes with pre-FTL portraits; non-machine: not the MACHINE archetype [I]
local function class_candidates(mode)
    local out = {}
    for _, d in ipairs(objects.ordered("common/species_classes")) do
        local b = d[2].block
        local playable = defs.field(b, "playable")
        local never = type(playable) == "table" and defs.field(playable, "always") == "no"
        local arch = unq(defs.field(b, "archetype"))
        if defs.field(b, "randomized") ~= "no" and not never and arch ~= "PRESAPIENT" then
            if not (mode == "random_non_machine" or mode == "random_pre_ftl") or (arch ~= "MACHINE" and arch ~= "ROBOT") then
                out[#out + 1] = d[1]
            end
        end
    end
    return out
end

-- the portraits of a class (common/portrait_sets: the sets of species_class = class)
local function class_portraits(class, pre_ftl)
    local out = {}
    for _, d in ipairs(objects.ordered("common/portrait_sets")) do
        local b = d[2].block
        if unq(defs.field(b, "species_class")) == class then
            for _, p in ipairs(names(b, "portraits")) do out[#out + 1] = p end
            if not pre_ftl then
                for _, p in ipairs(names(b, "non_pre_ftl_portraits")) do out[#out + 1] = p end
            end
        end
    end
    return out
end

-- the species names of a class not yet used (common/species_names, CSpecies::RandomizeName)
local function used_names()
    local s = {}
    for _, sid in ipairs(world.all("species_db")) do
        local k = world.path(world.object("species_db", sid), "name", "key")
        if k then s[unq(k)] = true end
    end
    return s
end
local function class_names(class)
    for _, d in ipairs(objects.ordered("common/species_names")) do
        if d[1] == class then
            local out = {}
            for _, e in ipairs(d[2].block) do
                if e.op and e.key and e.value.text == nil then
                    out[#out + 1] = { data = e.key.text, block = e.value }
                end
            end
            return out
        end
    end
    return {}
end

-- species.create(t) -> species id: CCreateSpecies::ExecuteActual (0x36e2b00): the class (random: one
-- draw over the candidates, CSpecies::GetRandomClass [I: uniform weights]), the name (random: one
-- draw, the next unused name of the class's list from it, CSpecies::RandomizeName / TakeUnusedIndex),
-- the portrait (random: one draw), the homeworld (its class the planet preference), the traits
-- (random_traits: CTraitSet::Randomize, not ported; then the habitability trait of the homeworld's
-- class, or one draw over the class preferences), in the species store (last_created_species)
function countries.create_species(t)
    local class = t.class
    if not class or class == "random" or class == "random_pre_ftl" or class == "random_non_machine" then
        local cand = class_candidates(class)
        if #cand == 0 then return nil end
        class = cand[draw() % #cand + 1]
    end
    local cb = defs.get("common/species_classes", class)
    if not cb then return nil end
    local s = {}
    local name, plural, data, list = t.name, t.plural, nil, t.name_list
    if not name or name == "random" then
        local cn = class_names(class)
        local used = used_names()
        local r = draw()
        if #cn > 0 then
            local start = r % #cn
            local pick = cn[start + 1]
            for i = 0, #cn - 1 do
                local x = cn[(start + i) % #cn + 1]
                if not used[unq(defs.field(x.block, "name") or "")] then pick = x break end
            end
            name = unq(defs.field(pick.block, "name"))
            plural = unq(defs.field(pick.block, "plural"))
            data = pick.data
            list = list or unq(defs.field(pick.block, "name_list"))
        end
    end
    world.append(s, "name_list", list or "HUM1", true)
    world.append(s, "name", key_block(name or "SPEC_Unknown"))
    world.append(s, "plural", key_block(plural or name or "SPEC_Unknown"))
    world.append(s, "adjective", key_block("%ADJECTIVE%", { var("adjective", key_block(name or "SPEC_Unknown")) }))
    world.append(s, "class", class, true)
    local portrait = t.portrait
    if not portrait or portrait == "random" then
        local ps = class_portraits(class, t.pre_ftl)
        local r = draw()
        portrait = #ps > 0 and ps[r % #ps + 1] or nil
    end
    if portrait then world.append(s, "portrait", portrait, true) end
    local tr = {}
    local arch_trait = unq(defs.field(cb.block, "trait"))
    if arch_trait then world.append(tr, "trait", arch_trait, true) end
    for _, x in ipairs(t.traits or {}) do
        if x ~= "random_traits" and defs.get("common/traits", x) then world.append(tr, "trait", x, true) end
    end
    local hw = t.homeworld
    local pclass = hw and unq(world.field(world.object("planet", hw), "planet_class"))
    local hab = pclass and ("trait_" .. pclass .. "_preference")
    if hab and defs.get("common/traits", hab) then
        world.append(tr, "trait", hab, true)
    else
        -- CTraitSet::RandomizeHabitabilityTrait: one draw [V]; over the habitability traits [I]
        local habs = {}
        for _, d in ipairs(objects.ordered("common/traits")) do
            if d[1]:match("^trait_pc_.*_preference$") then habs[#habs + 1] = d[1] end
        end
        local r = draw()
        if #habs > 0 then world.append(tr, "trait", habs[r % #habs + 1], true) end
    end
    world.append(s, "traits", tr)
    local home = {}
    world.append(home, "type", "planet")
    world.append(home, "reference", hw or NO_ID)
    world.append(s, "home_planet", home)
    if data then world.append(s, "name_data", data, true) end
    world.append(s, "gender", t.gender or "not_set")
    local sid = objects.create("species_db", s)
    objects.set_meta("last_created_species_ref", sid)
    return sid
end

function systems.effects.create_species(t)
    local sid = countries.create_species(t)
    if not sid then return skipped("create_species", "not made") end
    return applied("create_species", sid)
end

-- ---------------------------------------------------------------------------------------------
-- planets and colonies

local function list_add(obj, key, v)
    local l = objects.list_of(obj, key)
    for _, x in ipairs(world.list(l)) do if tonumber(x) == v then return end end
    world.append_value(l, v)
end
local function list_remove(obj, key, v)
    local l = obj and world.field(obj, key)
    if type(l) == "table" then world.remove_value(l, v) end
end

-- CGameState::CreateNewColony (0x1b46a30) -> CColony::Create: a colony of the planet (carrier ref)
function countries.create_colony_object(pid)
    local p = world.object("planet", pid)
    local c = {}
    world.append(c, "pop_groups", {})
    world.append(c, "final_designation", "col_capital", true)
    world.append(c, "species_refs", {})
    local car = {}
    world.append(car, "type", "planet")
    world.append(car, "reference", pid)
    world.append(c, "carrier", car)
    local cid = objects.create("colony", c)
    world.set(p, "colony", cid)
    world.colony_planet[cid], world.planet_colony[pid] = pid, cid
    return cid
end

-- CPlanet::SetOwner (0x2a628e0, settings 6): owner, original_owner, colonize_date, the colony made
-- when there is none (CColony::SetOwner: three draws and on_colony_transfer, as from the null
-- country [I: whether the explicit transfer repeats]), the country's owned and controlled lists
function countries.set_planet_owner(pid, country)
    local p = world.object("planet", pid)
    if not p then return false end
    local old = objects.ref(world.field(p, "owner"))
    if old == country then return true end
    if world.field(p, "original_owner") == nil then world.set(p, "original_owner", country) end
    if world.field(p, "colonize_date") == nil then world.append(p, "colonize_date", today_text(), true) end
    world.set(p, "owner", country)
    local cid = world.planet_colony[pid] or countries.create_colony_object(pid)
    local oc = old and world.object("country", old)
    if oc then
        list_remove(oc, "owned_planets", cid)
        list_remove(oc, "controlled_colonies", cid)
    end
    local nc = world.object("country", country)
    if nc then
        list_add(nc, "owned_planets", cid)
    end
    -- the planet index (planets_of)
    if old and world.planets_of[old] then
        for i = #world.planets_of[old], 1, -1 do
            if world.planets_of[old][i] == pid then table.remove(world.planets_of[old], i) end
        end
    end
    local l = world.planets_of[country]
    if not l then l = {}; world.planets_of[country] = l end
    l[#l + 1] = pid
    -- CColony::SetOwner: three draws (this = the colony, from = the new owner, fromfrom = the old)
    draw()
    draw()
    draw()
    local eval = package.loaded["simscript.eval"]
    if eval then objects.on_action("on_colony_transfer", eval.S("planet", pid), eval.S("country", country)) end
    return true
end

-- CPlanet::SetController (0x2a60b10): the controller, the country's controlled lists; a change from
-- an old controller draws three and fires on_planet_occupied / returned (none for a fresh planet)
function countries.set_planet_controller(pid, country)
    local p = world.object("planet", pid)
    if not p then return false end
    local old = objects.ref(world.field(p, "controller"))
    world.set(p, "controller", country)
    local cid = world.planet_colony[pid]
    local oc = old and old ~= country and world.object("country", old)
    if oc then
        list_remove(oc, "controlled_planets", pid)
        if cid then list_remove(oc, "controlled_colonies", cid) end
    end
    local nc = world.object("country", country)
    if nc then
        list_add(nc, "controlled_planets", pid)
        if cid then list_add(nc, "controlled_colonies", cid) end
    end
    if old and old ~= country then
        draw()
        draw()
        draw()
        local eval = package.loaded["simscript.eval"]
        local owner = objects.ref(world.field(p, "owner"))
        if eval then
            objects.on_action(country == owner and "on_planet_returned" or "on_planet_occupied", eval.S("planet", pid), eval.S("country", country))
        end
    end
    return true
end

-- CCountry::SetCapital (0x2343490): capital = the colony; one draw for the old capital's designation
-- update when there is one, one for the new; a change draws two more and fires on_capital_changed [V]
function countries.set_capital(country, cid)
    local c = world.object("country", country)
    if not c then return false end
    local old = objects.ref(world.field(c, "capital"))
    if old and world.object("colony", old) then draw() end
    draw()
    world.set(c, "capital", cid)
    if old ~= cid then
        draw()
        draw()
        local eval = package.loaded["simscript.eval"]
        local pid = world.colony_planet[cid]
        if eval and pid then objects.on_action("on_capital_changed", eval.S("planet", pid), nil) end
    end
    return true
end

local function planet_of(kind, id)
    if kind == "planet" then return id end
    if kind == "colony" then return world.colony_planet[id] end
    return nil
end

-- set_owner on a planet (CSetOwnerEffect 0x36e0a80): only a planet with pops, or of a class that
-- allows it, or for a country type that can own empty planets (can_own_empty_planets) [V]
function systems.effects.set_planet_owner(t)
    local pid = planet_of(t.kind, t.id)
    local p = pid and world.object("planet", pid)
    local c = world.object("country", t.country)
    if not p or not c then return skipped("set_owner", "no planet or country") end
    local cid = world.planet_colony[pid]
    local pops = cid and #world.list(world.field(world.object("colony", cid), "pop_groups")) > 0
    local ct = defs.get("common/country_types", unq(world.field(c, "type")) or "")
    local empty_ok = ct and defs.field(ct.block, "can_own_empty_planets") == "yes"
    if not pops and not empty_ok and objects.ref(world.field(p, "owner")) ~= t.country then
        return skipped("set_owner", "empty planet")
    end
    countries.set_planet_owner(pid, t.country)
    return applied("set_owner")
end

function systems.effects.set_planet_controller(t)
    local pid = planet_of(t.kind, t.id)
    if not pid or not world.object("country", t.country) then return skipped("set_controller", "no planet or country") end
    countries.set_planet_controller(pid, t.country)
    return applied("set_controller")
end

-- set_capital = yes (CSetCapitalEffect 0x37101f0): the scope's colony the capital of its owner [V]
function systems.effects.set_capital(t)
    local pid = planet_of(t.kind, t.id)
    local cid = pid and world.planet_colony[pid]
    local owner = pid and objects.ref(world.field(world.object("planet", pid), "owner"))
    if not cid or not owner then return skipped("set_capital", "no colony or owner") end
    countries.set_capital(owner, cid)
    return applied("set_capital")
end

-- create_colony = { owner species ethos } (CCreateOrStartColonyEffect<SCreateColony> 0x370e540): the
-- planet owned and controlled, its colonization data (the species: colonizing, not ported) [V]
function systems.effects.create_colony(t)
    local pid = planet_of(t.kind, t.id)
    if not pid or not world.object("country", t.owner) then return skipped("create_colony", "no planet or owner") end
    countries.set_planet_owner(pid, t.owner)
    countries.set_planet_controller(pid, t.owner)
    return applied("create_colony")
end

-- ---------------------------------------------------------------------------------------------
-- countries

local function country_type(key)
    local d = key and defs.get("common/country_types", key)
    return d and d.block
end
local function needs_colony(tb)
    local f = tb and defs.field(tb, "faction")
    if type(f) == "table" and defs.field(f, "needs_colony") == "no" then return false end
    return true
end

-- the country's start technologies (the technologies with `start_tech = yes`, as the generator's
-- empires) [I for other types]
local start_techs
local function techs_block()
    if not start_techs then
        start_techs = {}
        for _, d in ipairs(objects.ordered("common/technology")) do
            if defs.field(d[2].block, "start_tech") == "yes" then start_techs[#start_techs + 1] = d[1] end
        end
    end
    local ts = {}
    for _, t in ipairs(start_techs) do
        world.append(ts, "technology", t, true)
        world.append(ts, "level", 1)
    end
    return ts
end

-- the ethics of `ethos = random`: CCountryEthos::ChooseRandomEthic draws (the solver's fill, not
-- ported): one draw per ethic over the non-gestalt regular ethics until three ethic points [I]
local function random_ethics()
    local regular = {}
    for _, d in ipairs(objects.ordered("common/ethics")) do
        local k = d[1]
        if not k:match("fanatic") and k ~= "ethic_gestalt_consciousness" then regular[#regular + 1] = k end
    end
    local out, taken = {}, {}
    for _ = 1, 3 do
        if #regular == 0 then break end
        local k = regular[draw() % #regular + 1]
        if not taken[k] then taken[k] = true; out[#out + 1] = k end
    end
    return out
end

-- an authority of `authority = random` (ChooseAuthorityForFilling): one draw over the authorities
-- not for machines or hives [I]
local function random_authority()
    local list = {}
    for _, d in ipairs(objects.ordered("common/governments/authorities")) do
        if d[1] ~= "auth_machine_intelligence" and d[1] ~= "auth_hive_mind" and d[1] ~= "auth_corporate" then list[#list + 1] = d[1] end
    end
    if #list == 0 then return "auth_democratic" end
    return list[draw() % #list + 1]
end

-- countries.create(t) -> country id: CCreateCountry::ExecuteActual (0x3700620), in the game's order
-- of what is ported: CreateNewCountry (the next index), the name, the species, the ethics and
-- government (random parts drawn, see random_ethics / random_authority), a planet scope's planet
-- owned and its colony the capital for a type that needs a colony, SetGovernmentAndCivics' two draws
-- for a type with a government, `flag = random` (one draw; the flag left as the type's [I]), the
-- ruler (a created leader), the policies (InitializePolicy), then the caller runs `effect` and
-- on_country_created (a scope draw each)
function countries.create(t)
    local tb = country_type(t.ctype)
    if not tb then return nil end
    local c = {}
    world.append(c, "initialized", "yes")
    local flag = {}
    if type(t.flag) == "table" then
        for _, e in ipairs(t.flag) do if e.op and e.key then world.append_entry(flag, e) end end
    else
        local colors = {}
        for _, x in ipairs({ "red", "black", "null", "null" }) do colors[#colors + 1] = { text = x, quoted = true } end
        world.append(flag, "colors", colors)
    end
    world.append(c, "flag", flag)
    local sid = t.species
    local sname = sid and world.path(world.object("species_db", sid), "name", "key")
    if t.name and t.name ~= "random" then
        world.append(c, "custom_name", "yes")
        world.append(c, "name", key_block(t.name))
        world.append(c, "adjective", key_block(t.adjective or t.name))
    else
        local adj = key_block("%ADJECTIVE%", { var("adjective", key_block(sname and unq(sname) or "SPEC_Unknown")) })
        world.append(c, "name", adj)
        world.append(c, "adjective", key_block("%ADJECTIVE%", { var("adjective", key_block(sname and unq(sname) or "SPEC_Unknown")) }))
    end
    world.append(c, "tech_status", techs_block())
    if t.graphical_culture then world.append(c, "graphical_culture", t.graphical_culture, true) end
    if sid then world.append(c, "founder_species_ref", sid) end
    local ethics = t.ethos == "random" and random_ethics() or t.ethos or {}
    local eth = {}
    local en = {}
    for _, x in ipairs(ethics) do en[#en + 1] = { text = x, quoted = true } end
    world.append(eth, "ethics", en)
    world.append(c, "ethos", eth)
    local gov = {}
    local auth = t.authority == "random" and random_authority() or t.authority
    if auth then world.append(gov, "authority", auth, true) end
    local cv = {}
    for _, x in ipairs(t.civics or {}) do
        if x ~= "random" then cv[#cv + 1] = { text = x, quoted = true } end
    end
    world.append(gov, "civics", cv)
    if t.origin then world.append(gov, "origin", t.origin, true) end
    world.append(c, "government", gov)
    local list = t.name_list or (sid and unq(world.field(world.object("species_db", sid), "name_list")))
    if list then world.append(c, "name_list", list, true) end
    world.append(c, "active_policies", {})
    world.append(c, "owned_leaders", {})
    world.append(c, "owned_planets", {})
    world.append(c, "controlled_colonies", {})
    world.append(c, "controlled_planets", {})
    world.append(c, "type", t.ctype, true)
    local modules = {}
    world.append(modules, "standard_event_module", {})
    world.append(modules, "exclusive_diplomacy_module", {})
    world.append(modules, "basic_technology_module", {})
    world.append(c, "modules", modules)
    local fm = {}
    world.append(fm, "owned_fleets", {})
    world.append(c, "fleets_manager", fm)
    world.append(c, "customization", "default")
    world.append(c, "starbase_capacity_used", 0)
    world.append(c, "starbase_capacity", 3)
    if sid then
        local os = {}
        os[1] = { text = tostring(sid) }
        world.append(c, "owned_species_refs", os)
    end
    local id = objects.create("country", c)
    objects.set_meta("last_created_country", id)
    -- a planet scope and a type that needs a colony: the planet owned, controlled, its colony the
    -- capital (CPlanet::SetOwner, SetController, colonize_date, CCountry::SetCapital) [V]
    if t.planet and needs_colony(tb) then
        countries.set_planet_owner(t.planet, id)
        countries.set_planet_controller(t.planet, id)
        local cid = world.planet_colony[t.planet]
        if cid then countries.set_capital(id, cid) end
    end
    if defs.field(tb, "government") ~= "no" then
        draw()
        draw()
    end
    if t.flag == "random" then draw() end
    -- the ruler (CCountry::RandomizeRuler when the country has none) [I: through leaders.create]
    if objects.leaders and sid then
        local lid = objects.leaders.create({ country = id, class = "official", species = sid })
        if lid then world.set(world.object("country", id), "ruler", lid) end
    end
    if objects.leaders then objects.leaders.initialize_policies(id) end
    -- default_ships (yes unless the effect says no): CCountry::SetDefaultShipDesigns, engine.ai.designer
    -- of branch ai-fleets when it is there (no stations)
    if t.default_ships ~= false then
        local okd, designer = pcall(require, "engine.ai.designer")
        if okd and type(designer) == "table" and designer.set_default_designs then
            pcall(designer.set_default_designs, id, false)
        end
    end
    return id
end

function systems.effects.create_country(t)
    local id = countries.create(t)
    if not id then return skipped("create_country", "not made") end
    return applied("create_country", id)
end

return countries
