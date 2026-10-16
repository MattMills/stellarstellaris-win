-- engine/ai/navy.lua : the ships the AI wants, the strategy's list 9 (BUILD_SHIP), rebuilt every
-- calendar month by CCountryAI::CreateNavyBuildData (Linux 4.5.2 0x26ec970) from
-- CreateStrategicData (engine.ai.strategy); docs/ai_fleets.md section 2.
--
--   for a type with ai.construction or ai.limited_military_construction (bits 7, 17):
--   owned[slot]   the ships of the country's mobile fleets by their size's index + the design's
--                 owner (ship_owner_type: federation 1, galactic community 2) x the size count
--                 (AddShipsFromFleets 0x26fe800); a queued ship counts only for a slot with an
--                 owned ship already (AddQueuedShipsToOwned 0x26f3520: `if owned > 0: owned + 1`)
--   each ship size with ai_ship_data, in the database's order (CShipSizeDatabase::
--   FillAIShipSizesCache 0x2b28250), that the country can build (NUtil::CanBuildShipOfSize
--   0x268fbe0: prerequisites, graphical culture, potential_country, possible_country): its
--   fraction (CAIShipData::GetRawFactor, a weight block), summed per owner
--   naval capacity N = CCountry::CalcNavalCapacity (navy.naval_capacity)
--   a size with a fraction > 0: round(fraction / total * N / max(size_multiplier, 1))
--   else: max(min, 0) + floor(planet_mult * planets) + floor(system_mult * systems), at most max
--         (when max > 0; a sum of 0 then gives max: the code's order of its two tests)
--   value = that - owned; AddStrategy(9, slot, 0, value) for each value > 0, in slot order
--
-- Checked at load against the 2210.01.01 save's list 9 (navy.compare): 25 of 27 entries of the AI
-- empires equal. Not modelled: the wanted ships of a federation's fleet (its leader's) and the
-- galactic community's, the ship size limits (NCountryUtil::GetShipOfSizeLimit: juggernauts,
-- colossi), CanBuildShipOfSize's ship category check.

local world = require("engine.world")
local defs = require("engine.defs")
local slice = require("engine.slice")

local navy = { stats = { built = 0, countries = 0, errors = 0 }, last = {} }

local function sb()
    return require("engine.ai.shipbuilding")
end

local function eval()
    return require("simscript.eval")
end

-- the AI's ship sizes: those with ai_ship_data, in the database's order, with their slot (the
-- size's index in the database)
local AI_SIZES
local function ai_sizes()
    if AI_SIZES then
        return AI_SIZES
    end
    local out = {}
    local idx = sb().db_index("common/ship_sizes")
    for i, name in ipairs(idx.names) do
        local d = defs.get("common/ship_sizes", name)
        local data = d and defs.field(d.block, "ai_ship_data")
        if type(data) == "table" then
            out[#out + 1] = { name = name, slot = i - 1, def = d, data = data }
        end
    end
    AI_SIZES = out
    return out
end
navy.ai_sizes = ai_sizes

local function size_count()
    return #sb().db_index("common/ship_sizes").names
end
navy.size_count = size_count

local expanded = setmetatable({}, { __mode = "k" })
local function fraction_block(entry)
    local f = defs.field(entry.data, "fraction")
    if type(f) ~= "table" then
        return nil
    end
    local x = expanded[f]
    if x == nil then
        x = f
        for _, e in ipairs(f) do
            if e.op and e.key and e.key.text:lower() == "inline_script" then
                local db = require("simscript.db")
                x = require("stellar.script.source").expand(db.fs, f, {}, 0, "file: " .. tostring(entry.def.file))
                break
            end
        end
        expanded[f] = x
    end
    return x
end

local function ctx_of(country, file)
    local E = eval()
    return E.new_ctx(E.S("country", country), E.S("country", country), nil, file or "common/ship_sizes")
end

local function value_of(v, ctx, file)
    if v == nil then
        return 0
    end
    if type(v) == "table" then
        local ok, x = pcall(eval().value_block, v, ctx)
        return ok and x or 0
    end
    local n = tonumber(v)
    if n then
        return n
    end
    if v:sub(1, 1) == "@" then
        return require("engine.fleets.create").number(v, file) or 0
    end
    local ok, x = pcall(eval().value, { text = v }, ctx)
    if not ok then
        navy.stats.errors = navy.stats.errors + 1
        return 0
    end
    return x or 0
end

-- CAIShipData::GetRawFactor: the fraction block as a weight (base 0 when it gives none)
local function raw_factor(entry, ctx)
    local b = fraction_block(entry)
    if not b then
        return 0
    end
    local ok, v = pcall(eval().weight, b, ctx, 0)
    if not ok then
        navy.stats.errors = navy.stats.errors + 1
        return 0
    end
    return v or 0
end

-- NUtil::CanBuildShipOfSize(size, owner 0, country): the size's prerequisites researched, its
-- potential_country and possible_country triggers
local function researched(country)
    local research = require("engine.research")
    return setmetatable({}, { __index = function(t, name)
        local v = research.level(country, name) ~= nil
        rawset(t, name, v)
        return v
    end })
end

-- CShipSize::IsAvailableForCulture: a size with `graphical_culture = { ... }` lists the cultures
-- that build it; `graphical_culture = no` (CShipSize +0xca bit 1) skips the check, as a size
-- without the key does [I]
local function culture_ok(b, country)
    local lists, off = {}, false
    for _, e in ipairs(b) do
        if e.op and e.key and e.key.text == "graphical_culture" then
            if e.value.text == "no" then
                off = true
            elseif e.value.text == nil then
                lists[#lists + 1] = e.value
            end
        end
    end
    if off or #lists == 0 then
        return true
    end
    local mine = world.field(world.object("country", country), "graphical_culture")
    mine = mine and tostring(mine):gsub('^"(.*)"$', "%1")
    for _, l in ipairs(lists) do
        for _, x in ipairs(l) do
            if x.text and x.text:gsub('^"(.*)"$', "%1") == mine then
                return true
            end
        end
    end
    return false
end

function navy.can_build_size(country, entry, techs, ctx)
    local b = entry.def.block
    local pre = defs.field(b, "prerequisites")
    for _, e in ipairs(type(pre) == "table" and pre or {}) do
        local t = e.text and e.text:gsub('^"(.*)"$', "%1")
        if t and not techs[t] then
            return false
        end
    end
    if not culture_ok(b, country) then
        return false
    end
    for _, key in ipairs({ "potential_country", "possible_country" }) do
        local tr = defs.field(b, key)
        if type(tr) == "table" then
            local ok, holds = pcall(eval().trigger, tr, ctx)
            if not (ok and holds) then
                return false
            end
        end
    end
    return true
end

-- CCountry::CalcNavalCapacity(bool, bool, CString*) (0x23a4090), the parts the 2210 saves use:
--   NAVAL_CAPACITY_BASE (NGameplay) + country_naval_cap_add, times 1 + country_naval_cap_mult
--   (skipped for a country human recently), times the galaxy's naval_capacity_mult; a federation
--   member's times 1 - max(the federation's federation_fleet_contribution_factor x (1 +
--   country_federation_fleet_contribution_discount) - country_federation_fleet_contribution_
--   naval_cap_reduction_discount, 0) (CalcFederationFleetContributionCost 0x23a5d10); at most
--   NAVAL_CAPACITY_MAX. Not modelled: the pops part (NAVAL_CAPACITY_POP_MULT is 0), the
--   subjects' contribution (country_naval_capacity_contribution_*), the penalty without a naval
--   head (1 + NAVAL_CAPACITY_NO_LEADER_PENALTY without a filled COUNCIL_NAVAL_POSITIONS position,
--   CGovernment::GetNavalHead 0x1c14290: every AI of the 2210 saves has one)
local DEF
local function nav_defines()
    if DEF then
        return DEF
    end
    DEF = { base = 50, max = 9999 }
    for _, d in pairs(defs.folder("common/defines")) do
        local g = defs.field(d.block, "NGameplay")
        if type(g) == "table" then
            DEF.base = tonumber(defs.field(g, "NAVAL_CAPACITY_BASE")) or DEF.base
            DEF.max = tonumber(defs.field(g, "NAVAL_CAPACITY_MAX")) or DEF.max
        end
    end
    return DEF
end

local function galaxy_mult()
    for _, e in ipairs(world.tree or {}) do
        if e.op and e.key and e.key.text == "galaxy" and e.value.text == nil then
            return tonumber(world.field(e.value, "naval_capacity_mult")) or 1
        end
    end
    return 1
end

local function unq(v)
    return (tostring(v):gsub('^"(.*)"$', "%1"))
end

-- the country's federation (`federation = id`), when it exists
local function federation_of(country)
    local fid = tonumber(world.field(world.object("country", country), "federation"))
    return fid and fid ~= 4294967295 and world.object("federation", fid) and fid or nil
end
navy.federation_of = federation_of

-- CFederation::GetFleetContribution: the federation's federation_fleet_contribution_factor (the
-- modifiers of its laws)
local function fleet_contribution(fid)
    local f = world.object("federation", fid)
    local laws = world.path(f, "federation_progression", "laws")
    local sum = 0
    for _, name in world.statements(type(laws) == "table" and laws or {}) do
        local d = type(name) ~= "table" and defs.get("common/federation_laws", unq(name)) or nil
        local m = d and defs.field(d.block, "modifier")
        local v = type(m) == "table" and defs.field(m, "federation_fleet_contribution_factor")
        if v then
            sum = sum + (require("engine.fleets.create").number(v, d.file) or 0)
        end
    end
    return sum
end

function navy.naval_capacity(country)
    local d = nav_defines()
    local economy = require("engine.economy")
    local M = economy.modifiers("country", country) or {}
    local cap = d.base + (M.country_naval_cap_add or 0)
    if not require("engine.ai").human(country) then
        cap = cap * (1 + (M.country_naval_cap_mult or 0))
    end
    cap = cap * galaxy_mult()
    local fid = federation_of(country)
    if fid then
        local cost = fleet_contribution(fid) * (1 + (M.country_federation_fleet_contribution_discount or 0))
        local c = cost - (M.country_federation_fleet_contribution_naval_cap_reduction_discount or 0)
        if c < 0 then c = 0 end
        cap = cap * (1 - c)
    end
    if cap > d.max then cap = d.max end
    return cap
end

-- EDesignOwner of a design (`ship_owner_type = federation | galactic_community`; none for the
-- country's own): a slot is the size's index + the owner x the size count
local OWNER = { federation = 1, galactic_community = 2 }
local function design_owner(did)
    local d = world.object("ship_design", did)
    local t = d and world.field(d, "ship_owner_type")
    return t and OWNER[unq(t)] or 0
end
navy.design_owner = design_owner

-- the owned and queued ships per slot (AddShipsFromFleets, AddQueuedShipsToOwned)
function navy.owned(country)
    local C = require("engine.fleets.create")
    local idx = sb().db_index("common/ship_sizes").of
    local N = size_count()
    local owned = {}
    local c = world.object("country", country)
    for _, e in ipairs(world.blocks(world.path(c, "fleets_manager", "owned_fleets"))) do
        local fid = tonumber(world.field(e, "fleet"))
        local f = fid and world.object("fleet", fid)
        if f and world.path(f, "properties", "mobile") == "yes" then
            for _, sid in ipairs(world.list(world.field(f, "ships"))) do
                slice.tick("ai/navy.lua owned")
                local s = world.object("ships", tonumber(sid))
                local sdi = s and world.field(s, "ship_design_implementation")
                local did = type(sdi) == "table" and tonumber(world.field(sdi, "design"))
                local info = did and C.design_info(did, tonumber(world.field(sdi, "growth_stage")) or 0)
                local slot = info and idx[info.size]
                if slot then
                    slot = slot + design_owner(did) * N
                    owned[slot] = (owned[slot] or 0) + 1
                end
            end
        end
    end
    for _, item in pairs(world.stores["construction.item_mgr.items"] or {}) do
        local b = world.field(item, "buildable_ship")
        if type(b) == "table" and tonumber(world.field(item, "paying_country")) == country then
            local sdi = world.field(b, "ship_design_implementation")
            local did = type(sdi) == "table" and tonumber(world.field(sdi, "design"))
            local info = did and C.design_info(did)
            local slot = info and idx[info.size]
            if slot then
                slot = slot + design_owner(did) * N
                if (owned[slot] or 0) > 0 then
                    owned[slot] = owned[slot] + 1
                end
            end
        end
    end
    return owned
end

local function systems_owned(country)
    local n = 0
    for _, owner in pairs(world.system_owner or {}) do
        if owner == country then n = n + 1 end
    end
    return n
end

local function planets_owned(country)
    local c = world.object("country", country)
    return #world.list(world.field(c, "owned_planets"))
end

-- navy.compute(country) -> { { type = 9, id = slot, target = 0, value = n } } in slot order, or
-- nil for a type that builds no ships
function navy.compute(country)
    local ai = require("engine.ai")
    if not (ai.setting(country, "construction") or ai.setting(country, "limited_military_construction")) then
        return nil
    end
    local ctx = ctx_of(country)
    local techs = researched(country)
    local owned = navy.owned(country)
    local tuples, total = {}, 0
    require("engine.ai.economy.script").with(function()
        for _, entry in ipairs(ai_sizes()) do
            slice.tick("ai/navy.lua sizes")
            local f = raw_factor(entry, ctx)
            if navy.can_build_size(country, entry, techs, ctx) then
                tuples[#tuples + 1] = { entry = entry, factor = f }
                total = total + f
            end
        end
    end)
    local cap = navy.naval_capacity(country)
    local planets, systems
    local wanted = {}
    local C = require("engine.fleets.create")
    for _, t in ipairs(tuples) do
        local e = t.entry
        local n
        if t.factor > 0 then
            local usage = C.number(defs.field(e.def.block, "size_multiplier"), e.def.file) or 1
            if usage < 1 then usage = 1 end
            local v = t.factor / total * cap / usage
            -- CFixedPoint::GetRounded: to the nearest [I] (16777223's 9.57 are 10 in the save)
            n = math.floor(v + 0.5)
            t.raw = v
        else
            planets = planets or planets_owned(country)
            systems = systems or systems_owned(country)
            local d = e.data
            local mn = math.floor(value_of(defs.field(d, "min"), ctx, e.def.file))
            if mn < 0 then mn = 0 end
            local sum = mn + math.floor(value_of(defs.field(d, "planet_mult"), ctx, e.def.file) * planets + 1e-9)
                + math.floor(value_of(defs.field(d, "system_mult"), ctx, e.def.file) * systems + 1e-9)
            local mx = math.floor(value_of(defs.field(d, "max"), ctx, e.def.file))
            n = sum
            if mx > 0 then
                n = (sum == 0) and mx or math.min(sum, mx)
            end
        end
        wanted[e.slot] = n - (owned[e.slot] or 0)
        navy.last[country .. "/" .. e.slot] = string.format("%s %.3f-%d", e.name, t.raw or n, owned[e.slot] or 0)
    end
    local out = {}
    for slot = 0, 3 * size_count() - 1 do
        local v = wanted[slot]
        if v and v > 0 then
            out[#out + 1] = { type = 9, id = slot, target = 0, value = v }
        end
    end
    navy.stats.built = navy.stats.built + 1
    return out
end

-- navy.compare() -> text: list 9 computed now against the world's (a loaded save), per country
function navy.compare()
    local lines, same, diff = {}, 0, 0
    for _, id in ipairs(world.all("country")) do
        local c = world.object("country", id)
        local ai = c and world.field(c, "ai")
        if type(ai) == "table" and world.field(c, "type") == "default" then
            local mine = {}
            for _, s in ipairs(navy.compute(id) or {}) do mine[s.id] = s.value end
            local theirs = {}
            for _, e in ipairs(ai) do
                if e.op and e.key and e.key.text == "strategy" and e.value.text == nil and tonumber(world.field(e.value, "type")) == 9 then
                    theirs[tonumber(world.field(e.value, "id"))] = tonumber(world.field(e.value, "value"))
                end
            end
            local keys = {}
            for k in pairs(mine) do keys[k] = true end
            for k in pairs(theirs) do keys[k] = true end
            local parts = {}
            for k in pairs(keys) do parts[#parts + 1] = k end
            table.sort(parts)
            local row = {}
            for _, k in ipairs(parts) do
                if mine[k] == theirs[k] then same = same + 1 else diff = diff + 1 end
                row[#row + 1] = string.format("%d:%s/%s", k, tostring(mine[k] or 0), tostring(theirs[k] or 0))
            end
            local raw = {}
            for _, k in ipairs(parts) do raw[#raw + 1] = navy.last[id .. "/" .. k] or "?" end
            lines[#lines + 1] = string.format("  %d (cap %.2f): %s   [%s]", id, navy.naval_capacity(id), table.concat(row, " "), table.concat(raw, ", "))
        end
    end
    return string.format("navy build data (list 9, simulation/save): %d equal, %d differ\n%s", same, diff, table.concat(lines, "\n"))
end

return navy
