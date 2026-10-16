-- engine/ai/shipbuilding.lua : the AI's ships and armies (docs/shipbuilding.md section 7,
-- docs/ai_fleets.md), the interior minister's daily part (CAIInteriorMinister::DailyUpdate, Linux
-- 4.5.2 0x2751e20), after the research choice:
--
--   BuildArmies (0x27525d0), for a type with construction or limited_construction (bits 7, 8)
--   and a country not human recently: two unsynced AI draws (the scopes); then each colony of the
--   country without an army in its queue, on a planet it owns: each army type the strategy wants
--   (list 10, BUILD_ARMY, id = the army type's index) scores 1 - queued / (wanted + queued)
--   (x 10 for a type that is not defensive, the country at war); the best (a tie: one draw, odd
--   takes the new one), and for it NAIUtil::GetBestSpeciesForArmyType; posted with
--   AddAICommandWithCostAndUpkeepForPosting (the armies budget: expenditure and upkeep).
--
--   BuildShips (0x2753350), for construction or limited_military_construction (bits 7, 17):
--   BuildColonizer (not ported), the federation's fleet (not modelled), then
--   BuildShipOfOwnerType(country) (0x2764b40), one ship at most a call: for each AI ship size
--   (engine.ai.navy) the strategy wants (list 9, BUILD_SHIP, rebuilt monthly by engine.ai.navy):
--   GetOrRequestDesign (0x2766270: one unsynced draw for the role; without a role the country's
--   latest design of the size; with one the minister's design of the size, else
--   RequestNewShipDesign, engine.ai.designer: four draws more, the design posted to be made when
--   the commands execute and ordered the next day), the design's cost against the size's
--   economic category's expenditure budget (CanAffordExpenditure), then each shipyard of the
--   country with room: the lowest fill ratio have / (have + wanted) wins; the winner is posted
--   (PostBuildCommand: its cost and its upkeep within the AI's budgets, else nothing;
--   CAddBuildableToQueueCommand, the item in the shipyard's queue, its cost from the stockpile;
--   the strategy's wanted count - 1 when it executes).
--
-- Not ported: the size families, CanCountryBuild, the cheaper design asked for when a strategic
-- resource falls short, BuildColonizer, DisbandShips, the federation's and the galactic
-- community's ships. STELLAR_AI_DESIGNS=latest lets the country's latest design of the size stand
-- in for the designer's (a check's variant).

local world = require("engine.world")
local slice = require("engine.slice")   -- a phase in pieces (docs/frame_timing.md)
local cmds = require("engine.ai.commands")
local defs = require("engine.defs")
local rng = require("engine.ai.rng")

local M = {
    stats = { days = 0, army_days = 0, ship_days = 0, ai_draws = 0, ship_posts = 0, army_posts = 0,
              executed = 0, failed = 0, designs_requested = 0, no_design = 0, unaffordable = 0, no_queue = 0,
              army_unaffordable = 0 },
    posted = {},   -- { date, country, kind, design | army_type, queue | colony, cost }
    design_info = {}, -- country -> size -> { design, date } (CAIInteriorMinister +0x90; not saved)
}
local S = M.stats
local NO_ID = 4294967295

local function create()
    return require("engine.fleets.create")
end

local function draw(country)
    S.ai_draws = S.ai_draws + 1
    return rng.draw(country)
end

local function unq(v)
    if type(v) == "string" then
        return (v:gsub('^"(.*)"$', "%1"))
    end
    return v
end

-- ---------------------------------------------------------------------------------------------
-- the databases' indices (the load order of the folder's definitions)

local index_cache = {}
local function db_index(folder)
    local t = index_cache[folder]
    if t then
        return t
    end
    t = { of = {}, names = {} }
    local db = require("simscript.db")
    local source = require("stellar.script.source")
    local i = 0
    for _, file in ipairs(source.files(db.fs, folder, "txt")) do
        for _, e in ipairs(source.parse(db.fs, file) or {}) do
            if e.op and e.key and e.value.text == nil and e.key.text:sub(1, 1) ~= "@" and t.of[e.key.text] == nil then
                t.of[e.key.text] = i
                t.names[#t.names + 1] = e.key.text
                i = i + 1
            end
        end
    end
    index_cache[folder] = t
    return t
end
M.db_index = db_index

-- ---------------------------------------------------------------------------------------------
-- the strategy lists (country.ai = { strategy = { id target value type } ... })

local function ai_block(country)
    local c = world.object("country", country)
    local ai = c and world.field(c, "ai")
    return type(ai) == "table" and ai or nil
end

-- the strategy entries of an AI block by "type/id", in the block's order: built once per version
-- of the lists (engine.ai.strategy bumps it when it rewrites them) and block length (an entry
-- removed or added); scanning every entry per lookup was a quarter of the simulation's time
local index_by_block = setmetatable({}, { __mode = "k" })
local function strategy_index(ai)
    local st = package.loaded["engine.ai.strategy"]
    local version = st and st.version or 0
    local c = index_by_block[ai]
    if c and c.version == version and c.n == #ai then
        return c.map
    end
    local map = {}
    for _, e in ipairs(ai) do
        slice.tick("strategy index")
        if e.op and e.key and e.key.text == "strategy" and type(e.value) == "table" then
            local k = tostring(world.field(e.value, "type")) .. "/" .. tostring(world.field(e.value, "id"))
            local list = map[k]
            if not list then
                list = {}
                map[k] = list
            end
            list[#list + 1] = e
        end
    end
    index_by_block[ai] = { version = version, n = #ai, map = map }
    return map
end

-- GetStrategyValue(type, id, target): the first entry's value
function M.strategy_value(country, ty, id, target)
    local ai = ai_block(country)
    if not ai then
        return 0
    end
    for _, e in ipairs(strategy_index(ai)[tostring(ty) .. "/" .. tostring(id)] or {}) do
        if target == nil or tonumber(world.field(e.value, "target")) == target then
            return tonumber(world.field(e.value, "value")) or 0, e
        end
    end
    return 0
end

-- AddStrategy(type, id, target, delta) merged (0x1af9870): the entry's value + delta, the entry
-- removed below 1
function M.strategy_add(country, ty, id, target, delta)
    local ai = ai_block(country)
    local v, e = M.strategy_value(country, ty, id, target)
    if not (ai and e) then
        return
    end
    v = v + delta
    if v < 1 then
        world.remove_entry(ai, e)
    else
        world.set(e.value, "value", v)
    end
end

-- ---------------------------------------------------------------------------------------------
-- costs: the size's and the components' resources tables, with a modifier node

local function economy()
    local e = require("engine.economy")
    e.init()
    return e
end

local function size_template(size)
    local d = size and defs.get("common/ship_sizes", size)
    if not d then
        return nil
    end
    local block = defs.field(require("engine.economy.units").expanded(d), "resources")
    return block and economy().template(block, d.file), d
end

-- the design's table (cost, upkeep) with the modifiers M (the country's for the AI's check, the
-- shipyard's starbase for the item: CBuildableShipBase<CBuildableShip>::CalcCost)
function M.ship_table(country, did, kind, Mods)
    local C = create()
    local info = C.design_info(did)
    if not info then
        return {}, nil
    end
    local e = economy()
    local eval = require("simscript.eval")
    local ctx = eval.new_ctx(eval.S("country", country), eval.S("country", country), nil, "ship design")
    local base = {}
    -- a value: a number, a scripted variable (the template's file's or the global ones), else the
    -- script layer's value
    local function value(v, file)
        local text = type(v) == "table" and v.text
        if text and text:sub(1, 1) == "@" then
            return C.number(text, file)
        end
        local ok, x = pcall(e.value_of, v, ctx)
        return ok and x or nil
    end
    local function add(t)
        for _, b in ipairs(t and t[kind] or {}) do
            local ok, holds = true, true
            if b.trigger then
                ok, holds = pcall(eval.trigger, b.trigger, ctx)
            end
            if ok and holds then
                local m = b.mult and value(b.mult, t.file) or 1
                for _, rv in ipairs(b.values) do
                    local v = value(rv[2], t.file)
                    if v then base[rv[1]] = (base[rv[1]] or 0) + v * m end
                end
            end
        end
    end
    local st, sd = size_template(info.size)
    add(st)
    if not (sd and defs.field(sd.block, "components_add_to_cost") == "no") then
        local comps, secs = C.components(), C.sections()
        for _, sec in ipairs(info.sections) do
            local stt = secs[sec.template]
            local srb = stt and defs.field(stt.block, "resources")
            if srb then add(e.template(srb, stt.file)) end
            for _, c in ipairs(sec.components) do
                local ct = comps[c.template]
                local rb = ct and defs.field(ct.block, "resources")
                if rb then add(e.template(rb, ct.file)) end
            end
        end
        for _, r in ipairs(info.required) do
            local ct = comps[r]
            local rb = ct and defs.field(ct.block, "resources")
            if rb then add(e.template(rb, ct.file)) end
        end
    end
    local category = st and st.category or "ships"
    local out = e.apply(category, kind, base, 1, Mods or {}, ctx)
    -- the size's own mult (ship_<size>_<kind>_mult: a shipyard's ship_corvette_cost_mult) [I]
    local sm = (Mods or {})["ship_" .. tostring(info.size) .. "_" .. kind .. "_mult"]
    if sm and sm ~= 0 then
        for r, v in pairs(out) do
            out[r] = v * (1 + sm)
        end
    end
    return out, category
end

-- the build time (CBaseDesignImplementation::CalcBuildTime): the size's base_buildtime times
-- 1 + the starbase's shipyard and size build time mults [I]
function M.build_time(did, Mods)
    local info = create().design_info(did)
    local sb = info and info.size_block
    local base = sb and create().number(defs.field(sb, "base_buildtime"), info.size_file) or 0
    Mods = Mods or {}
    local mult = 1 + (Mods.starbase_shipyard_build_time_mult or 0) + (Mods.starbase_shipyard_artificial_build_time_mult or 0)
        + (Mods["shipsize_" .. tostring(info and info.size) .. "_build_time_mult"] or 0)
    return math.floor(base * mult * 100000 + 0.5) / 100000
end

-- ---------------------------------------------------------------------------------------------
-- designs

-- CCountry::GetLatestShipDesign(size, country): the last design of the country's
-- ship_design_collection whose first stage is that size [I]
function M.latest_design(country, size)
    local c = world.object("country", country)
    local coll = c and world.path(c, "ship_design_collection", "ship_design")
    local best
    for _, v in ipairs(world.list(coll)) do
        local info = create().design_info(tonumber(v))
        if info and info.size == size then
            best = tonumber(v)
        end
    end
    return best
end

local function size_roles(size)
    local d = defs.get("common/ship_sizes", size)
    local r = d and defs.field(d.block, "ship_roles")
    local out = {}
    for _, e in ipairs(type(r) == "table" and r or {}) do
        if e.text then out[#out + 1] = e.text end
    end
    return out
end

local STALE
local function stale_months()
    if STALE == nil then
        STALE = 24
        local g = defs.get("common/defines", "NAI")
        local v = g and tonumber(defs.field(g.block, "SHIP_DESIGN_STALE_MONTHS"))
        if v then STALE = v end
    end
    return STALE
end

local function months_between(a, b)
    local function m(t)
        local y, mo = tostring(t):match("^(%d+)%.(%d+)")
        return (tonumber(y) or 0) * 12 + (tonumber(mo) or 1)
    end
    return m(b) - m(a)
end

-- RequestNewShipDesign (0x2765d20; engine.ai.designer): draws r1 (CreateShipDesign's seed), r2
-- (the design's role), and with a role r3 and r4; the design of the info's name with identical
-- components, else the newest identical one (its name then the info's), comes back with the info
-- dated today; else a CCreateOrUpdateShipDesignCommand is posted (the design made when the
-- commands execute) and nothing comes back this day
function M.request_new_design(country, size, info, today, commands)
    local designer = require("engine.ai.designer")
    local r1 = draw(country)
    local role = designer.role_for(country, size, draw(country))
    if role ~= "" then
        draw(country) -- r3: AddRandomSectionsToShipDesign, every slot filled already
        draw(country) -- r4: AddSectionComponentsToShipDesign
    end
    -- the sections: rolled with seed 0 once the role is set; without a role CreateShipDesign's
    -- (CCrudeRandom(r1)'s first value)
    local stage = designer.plain(designer.generate(country, size, role, role == "" and designer.crude(r1):int() or 0))
    if not stage then
        S.no_design = S.no_design + 1
        return nil
    end
    local did = designer.by_name_and_size(country, info.name, size)
    if did and designer.identical(designer.stage_of(did), stage) then
        info.date = today
        designer.stats.reused = designer.stats.reused + 1
        return did
    end
    did = designer.find_identical(country, stage)
    if did then
        info.name = designer.name_key_of(did) or info.name
        info.date = today
        designer.stats.reused = designer.stats.reused + 1
        return did
    end
    commands[#commands + 1] = cmds.make("engine.ai.shipbuilding", "design_command", M.ctor.design_command, country, stage, info.name, role)
    designer.stats.posted = designer.stats.posted + 1
    S.designs_requested = S.designs_requested + 1
    return nil
end

-- GetOrRequestDesign (0x2766270): one draw for the role (GetEffectiveRoleForShipSize); no role:
-- the country's latest design of the size; else the minister's SShipSizeDesignInfo of the size
-- (a name and a date, not saved; a first one draws the class name, TakeRandomShipClassNameFor-
-- Design): the design of that name and size while the info is younger than
-- SHIP_DESIGN_STALE_MONTHS, else RequestNewShipDesign. STELLAR_AI_DESIGNS=latest lets the
-- latest existing design stand in for the designer's (a check's variant)
function M.get_or_request_design(country, size, today, commands)
    local designer = require("engine.ai.designer")
    local role = designer.role_for(country, size, draw(country))
    if role == "" then
        return M.latest_design(country, size)
    end
    local infos = M.design_info[country] or {}
    M.design_info[country] = infos
    local info = infos[size]
    if info then
        if months_between(info.date, today) < stale_months() then
            local did = designer.by_name_and_size(country, info.name, size)
            if did then
                return did
            end
        end
    else
        info = { date = today, name = designer.class_name(country, size, draw(country)) }
        infos[size] = info
    end
    if os.getenv("STELLAR_AI_DESIGNS") == "latest" then
        info.date = today
        return M.latest_design(country, size)
    end
    return M.request_new_design(country, size, info, today, commands or {})
end

-- ---------------------------------------------------------------------------------------------
-- shipyards

local QUEUES, ITEMS = "construction.queue_mgr.queues", "construction.item_mgr.items"

local function starbase_owner(sb)
    return require("engine.construction").starbase_owner(sb)
end

local function construction_types(size)
    local d = defs.get("common/ship_sizes", size)
    local v = d and defs.field(d.block, "construction_type")
    local out = {}
    if type(v) == "table" then
        for _, e in ipairs(v) do
            if e.text then out[e.text] = true end
        end
    elseif v then
        out[v] = true
    end
    return out
end

-- the country's shipyards that build the size with room in their queue (the per-queue cache's
-- items below the queue's simultaneous count [I]): { { starbase, queue, items } } in the
-- starbases' order
function M.shipyards(country, size)
    local types = construction_types(size)
    local out = {}
    for _, sbid in ipairs(world.all("starbases")) do
        slice.tick("ai/shipbuilding.lua:366")
        local sb = world.object("starbases", sbid)
        local q = tonumber(world.field(sb, "shipyard_build_queue"))
        local ct = unq(world.field(sb, "construction_type"))
        if q and q ~= NO_ID and ct and types[ct] and starbase_owner(sbid) == country then
            local qb = world.object(QUEUES, q)
            local n = qb and #world.list(world.field(qb, "items")) or 0
            if qb and world.field(qb, "disabled") ~= "yes" and n < (tonumber(world.field(qb, "simultaneous")) or 1) then
                out[#out + 1] = { starbase = sbid, queue = q, items = n }
            end
        end
    end
    return out
end
function M.free_shipyard(country, size)
    local s = M.shipyards(country, size)[1]
    return s and s.starbase, s and s.queue
end

-- CountOwnedShips / CountQueuedShips: the country's ships and queued ship items per size
local function count_ships(country)
    local owned, queued = {}, {}
    local C = create()
    for _, sid in ipairs(world.all("ships")) do
        slice.tick("ai/shipbuilding.lua:389")
        local s = world.object("ships", sid)
        local f = tonumber(world.field(s, "fleet"))
        if f and world.fleet_owner[f] == country then
            local sdi = world.field(s, "ship_design_implementation")
            local info = type(sdi) == "table" and C.design_info(tonumber(world.field(sdi, "design")), tonumber(world.field(sdi, "growth_stage")) or 0)
            if info then owned[info.size] = (owned[info.size] or 0) + 1 end
        end
    end
    for _, item in pairs(world.stores[ITEMS] or {}) do
        local b = world.field(item, "buildable_ship")
        if type(b) == "table" and tonumber(world.field(item, "paying_country")) == country then
            local sdi = world.field(b, "ship_design_implementation")
            local info = type(sdi) == "table" and C.design_info(tonumber(world.field(sdi, "design")))
            if info then queued[info.size] = (queued[info.size] or 0) + 1 end
        end
    end
    return owned, queued
end

-- the queued items of a kind of the country (their buildable's key)
local function queued(country, kind, key)
    local out = {}
    for _, item in pairs(world.stores[ITEMS] or {}) do
        if tonumber(world.field(item, "paying_country")) == country then
            local b = world.field(item, "buildable_" .. kind)
            if type(b) == "table" then
                local k = unq(world.field(b, key))
                out[k] = (out[k] or 0) + 1
            end
        end
    end
    return out
end

-- ---------------------------------------------------------------------------------------------
-- the commands

local COST_ORDER
local function cost_order()
    if COST_ORDER == nil then
        COST_ORDER = economy().resources
    end
    return COST_ORDER
end

local function ship_command(country, size, size_index, did, sbid, queue, cost, today)
    return {
        kind = "ai_build_ship", country = country,
        execute = function()
            local orders = require("engine.ai.economy.orders")
            if not orders.can_pay(country, cost) then
                S.failed = S.failed + 1
                return false
            end
            local sdi = {}
            world.append(sdi, "design", did)
            world.append(sdi, "upgrade", NO_ID)
            world.append(sdi, "growth_stage", 0)
            local ob = {}
            world.append(ob, "starbase", sbid)
            local id = orders.add {
                country = country, queue = queue, kind = "ship",
                fields = { { "ship_design_implementation", sdi }, { "orbitable", ob } },
                cost = cost, cost_order = cost_order(),
                build_time = M.build_time(did, require("engine.economy").modifiers("starbase", sbid) or {}),
            }
            if not id then
                S.failed = S.failed + 1
                return false
            end
            M.strategy_add(country, 9, size_index, 0, -1)
            S.executed = S.executed + 1
            return true
        end,
    }
end

-- the design command (CCreateOrUpdateShipDesignCommand), executed after every AI decided
local function design_command(country, stage, name, role)
    return {
        kind = "ai_ship_design", country = country,
        execute = function()
            require("engine.ai.designer").execute_create(country, stage, name, role)
            return true
        end,
    }
end

-- CAIInteriorMinister::BuildShipOfOwnerType(country) (0x2764b40): one ship at most a call. Over
-- the AI's ship sizes (those with ai_ship_data, the database's order) the strategy wants (list 9,
-- slot = the size's index): the design (GetOrRequestDesign, which may ask the designer), its cost
-- (the country's modifiers) within the size's category's expenditure budget (CanAffordExpenditure;
-- short of a basic resource the size is skipped), not a colonizer (BuildColonizer's) nor, for a
-- country human recently, a constructor or science ship; then for each of the country's shipyards
-- with room the candidate's fill ratio have / (have + wanted), have = owned + queued of the size:
-- the lowest wins (a tie: the queue with fewer items). PostBuildCommand: the item at the shipyard
-- (its cost with the starbase's modifiers) posted through AddAICommandWithCostAndUpkeepForPosting
-- (0x27897d0): its cost within the expenditure budget and its upkeep within the upkeep budget
-- (CanAffordUpkeep), else nothing is posted; the cost withdrawn; the strategy's wanted count - 1
-- (CAIAddStrategyCommand) when it executes. The size families (the ratio over a family's sizes by
-- their naval capacity) are not modelled; no family at the 2210 tech levels.
function M.build_ships(country, today, commands)
    local budget = require("engine.ai.budget")
    local economy_mod = require("engine.economy")
    local owned, queued
    local best
    local human = require("engine.ai").human(country)
    for _, entry in ipairs(require("engine.ai.navy").ai_sizes()) do
        local size, idx = entry.name, entry.slot
        local wanted = M.strategy_value(country, 9, idx, 0)
        if wanted > 0 then
            local did = M.get_or_request_design(country, size, today, commands)
            local info = did and create().design_info(did)
            if not (info and info.size == size) then
                S.no_design = S.no_design + 1
            else
                local cost, category = M.ship_table(country, did, "cost", economy_mod.modifiers("country", country) or {})
                if not budget.can_afford_expenditure(country, category, cost) then
                    S.unaffordable = S.unaffordable + 1
                elseif info.class ~= "shipclass_colonizer"
                    and not (human and (info.class == "shipclass_constructor" or info.class == "shipclass_science_ship")) then
                    if not owned then owned, queued = count_ships(country) end
                    local have = (owned[size] or 0) + (queued[size] or 0)
                    local ratio = have / (have + wanted)
                    local yards = M.shipyards(country, size)
                    if #yards == 0 then
                        S.no_queue = S.no_queue + 1
                    end
                    for _, y in ipairs(yards) do
                        if best == nil or ratio < best.ratio or (ratio == best.ratio and y.items < best.items) then
                            best = { ratio = ratio, size = size, idx = idx, did = did, starbase = y.starbase, queue = y.queue,
                                     items = y.items, category = category }
                        end
                    end
                end
            end
        end
    end
    if not best then
        return
    end
    -- PostBuildCommand: the item's own cost and upkeep (the shipyard's modifiers)
    local smods = economy_mod.modifiers("starbase", best.starbase) or {}
    local item_cost = M.ship_table(country, best.did, "cost", smods)
    local item_upkeep = M.ship_table(country, best.did, "upkeep", economy_mod.modifiers("country", country) or {})
    if not budget.can_afford_expenditure(country, best.category, item_cost) then
        S.unaffordable = S.unaffordable + 1
        return
    end
    if not budget.can_afford_upkeep(country, best.category, item_upkeep) then
        S.upkeep_unaffordable = (S.upkeep_unaffordable or 0) + 1
        return
    end
    commands[#commands + 1] = cmds.make("engine.ai.shipbuilding", "ship_command", ship_command, country, best.size, best.idx, best.did, best.starbase, best.queue, item_cost, today)
    budget.withdraw(country, best.category, item_cost)
    S.ship_posts = S.ship_posts + 1
    M.posted[#M.posted + 1] = { date = today, country = country, kind = "ship", design = best.did, size = best.size,
                                queue = best.queue, cost = item_cost }
end

-- ---------------------------------------------------------------------------------------------
-- armies

local function army_table(country, colony, army_type, kind)
    local d = defs.get("common/armies", army_type)
    local e = economy()
    local block = d and defs.field(require("engine.economy.units").expanded(d), "resources")
    local t = block and e.template(block, d.file)
    if not t then
        return {}, "armies"
    end
    local eval = require("simscript.eval")
    local planet = world.colony_planet[colony]
    local ctx = eval.new_ctx(eval.S("planet", planet or colony), eval.S("country", country), nil, d.file)
    local base = {}
    for _, b in ipairs(t[kind] or {}) do
        local ok, holds = true, true
        if b.trigger then ok, holds = pcall(eval.trigger, b.trigger, ctx) end
        if ok and holds then
            local m = b.mult and e.value_of(b.mult, ctx) or 1
            for _, rv in ipairs(b.values) do
                local okv, v = pcall(e.value_of, rv[2], ctx)
                if okv and v then base[rv[1]] = (base[rv[1]] or 0) + v * m end
            end
        end
    end
    return e.apply(t.category or "armies", kind, base, 1, e.modifiers("colony", colony) or {}, ctx), t.category or "armies"
end

-- a planet's queue of a type (construction.queue_mgr.queues: location = { type = 2 id = planet },
-- type = army | planet | ...)
local queue_index
local function planet_queue(planet, ty)
    if queue_index == nil then
        queue_index = {}
        for _, qid in ipairs(world.all(QUEUES)) do
            slice.tick("ai/shipbuilding.lua:555")
            local q = world.object(QUEUES, qid)
            local loc = world.field(q, "location")
            if type(loc) == "table" and tonumber(world.field(loc, "type")) == 2 then
                queue_index[tostring(world.field(loc, "id")) .. "/" .. tostring(world.field(q, "type"))] = qid
            end
        end
    end
    return queue_index[tostring(planet) .. "/" .. ty]
end
M.planet_queue = planet_queue
M.db_index = db_index   -- (engine.load parses its folders with the load)

local function army_command(country, colony, planet, army_type, species, cost)
    return {
        kind = "ai_build_army", country = country,
        execute = function()
            local orders = require("engine.ai.economy.orders")
            local queue = planet_queue(planet, "army")
            if not queue or not orders.can_pay(country, cost) then
                S.failed = S.failed + 1
                return false
            end
            local d = defs.get("common/armies", army_type)
            local time = d and tonumber(defs.field(d.block, "time")) or 0
            local Mc = require("engine.economy").modifiers("colony", colony) or {}
            time = time * (1 + (Mc.planet_army_build_time_mult or 0))
            local id = orders.add {
                country = country, queue = queue, kind = "army",
                fields = { { "army_type", army_type, true }, { "species", species }, { "planet", colony }, { "starbase", NO_ID } },
                cost = cost, cost_order = cost_order(), build_time = time,
            }
            if not id then
                S.failed = S.failed + 1
                return false
            end
            S.executed = S.executed + 1
            return true
        end,
    }
end

-- the colony's queue holds an army (CColony::HasQueuedArmyConstruction)
local function has_queued_army(planet)
    local queue = planet_queue(planet, "army")
    local q = queue and world.object(QUEUES, queue)
    for _, iid in ipairs(world.list(q and world.field(q, "items"))) do
        local item = world.object(ITEMS, tonumber(iid))
        if item and world.field(item, "buildable_army") then
            return true
        end
    end
    return false
end

local function at_war(country)
    for _, wid in ipairs(world.all("war")) do
        slice.tick("ai/shipbuilding.lua:610")
        local w = world.object("war", wid)
        for _, side in ipairs({ "attackers", "defenders" }) do
            for _, d in ipairs(world.blocks(world.field(w, side))) do
                if tonumber(world.field(d, "country")) == country then
                    return true
                end
            end
        end
    end
    return false
end

-- CAIInteriorMinister::BuildArmies
function M.build_armies(country, today, commands)
    draw(country)
    draw(country)
    local types = db_index("common/armies")
    local q = queued(country, "army", "army_type")
    local war
    local best_type, best_colony, best_score
    for _, pid in ipairs(world.planets_of and world.planets_of[country] or {}) do
        local colony = world.planet_colony and world.planet_colony[pid]
        if colony and not has_queued_army(pid) then
            for i, t in ipairs(types.names) do
                local wanted = M.strategy_value(country, 10, i - 1, 0)
                if wanted > 0 then
                    local queued_n = q[t] or 0
                    local score = 1 - queued_n / (wanted + queued_n)
                    local d = defs.get("common/armies", t)
                    local defensive = d and (defs.field(d.block, "defensive") == "yes" or defs.field(d.block, "is_pop_spawned") == "yes")
                    if not defensive then
                        if war == nil then war = at_war(country) end
                        if war then score = math.min(score * 10, 10) end
                    end
                    if best_type == nil or score > best_score then
                        best_type, best_colony, best_score = t, colony, score
                    elseif score == best_score and draw(country) % 2 == 1 then
                        best_type, best_colony = t, colony
                    end
                end
            end
        end
    end
    if not best_type then
        return
    end
    local planet = world.colony_planet[best_colony]
    local c = world.object("country", country)
    local species = c and tonumber(world.field(c, "founder_species_ref"))
    local cost, category = army_table(country, best_colony, best_type, "cost")
    local upkeep = army_table(country, best_colony, best_type, "upkeep")
    local budget = require("engine.ai.budget")
    if not (budget.can_afford_expenditure(country, category, cost) and budget.can_afford_upkeep(country, category, upkeep)) then
        S.army_unaffordable = S.army_unaffordable + 1
        return
    end
    commands[#commands + 1] = cmds.make("engine.ai.shipbuilding", "army_command", army_command, country, best_colony, planet, best_type, species, cost)
    budget.withdraw(country, category, cost)
    S.army_posts = S.army_posts + 1
    M.posted[#M.posted + 1] = { date = today, country = country, kind = "army", army_type = best_type, colony = best_colony, cost = cost }
end

-- ---------------------------------------------------------------------------------------------

-- the interior minister's daily part, after the research choice (engine.ai)
function M.daily(country, today, commands)
    if os.getenv("STELLAR_SHIPBUILD") == "off" then
        return
    end
    local ai = require("engine.ai")
    S.days = S.days + 1
    if ai.setting(country, "construction") or ai.setting(country, "limited_construction") then
        S.army_days = S.army_days + 1
        M.build_armies(country, today, commands)
    end
    -- BuildShips (0x2753350): with ai.construction, BuildColonizer (not ported: no AI draws),
    -- BuildShipOfOwnerType for the federation's fleet (owner 1) when the country is in a
    -- federation (its leader, or a member while the progression's flag +0x2b4 is clear) or for the
    -- galactic community's (2) when it owns the defense force, then for its own (0): the headless
    -- game, traced, calls both for the 2210 hegemony's members each day. The federation's and the
    -- community's ships are not modelled. With only ai.limited_military_construction, its own.
    if ai.setting(country, "construction") then
        S.ship_days = S.ship_days + 1
        if require("engine.ai.navy").federation_of(country) then
            S.federation_days = (S.federation_days or 0) + 1   -- the federation's ships: not modelled
        end
        M.build_ships(country, today, commands)
    elseif ai.setting(country, "limited_military_construction") then
        S.ship_days = S.ship_days + 1
        M.build_ships(country, today, commands)
    end
end

function M.report()
    local text = string.format("ai shipbuilding: %d country-days (%d armies, %d ships); %d unsynced draws; posted %d ships, %d armies (%d executed, %d failed); %d designs requested, %d size-days without a design, %d not affordable, %d over the upkeep budget, %d without a free shipyard, %d armies not affordable",
        S.days, S.army_days, S.ship_days, S.ai_draws, S.ship_posts, S.army_posts, S.executed, S.failed,
        S.designs_requested, S.no_design, S.unaffordable, S.upkeep_unaffordable or 0, S.no_queue, S.army_unaffordable)
    local dz = package.loaded["engine.ai.designer"]
    if type(dz) == "table" then
        text = text .. "\n" .. dz.report()
    end
    for _, p in ipairs(M.posted) do
        local cost = {}
        for r, v in pairs(p.cost or {}) do cost[#cost + 1] = string.format("%s %.2f", r, v) end
        table.sort(cost)
        text = text .. string.format("\n  %s %s %s %s at %s: %s", tostring(p.date), tostring(p.country), p.kind,
            tostring(p.design or p.army_type), tostring(p.queue or p.colony), table.concat(cost, ", "))
    end
    return text
end

M.ctor = { ship_command = ship_command, army_command = army_command, design_command = design_command }

return M
