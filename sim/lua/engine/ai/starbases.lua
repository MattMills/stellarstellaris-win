-- engine/ai/starbases.lua : the AI's starbases on its week (docs/stations.md), the part of
-- CAIInteriorMinister::WeeklyUpdate (GOG 4.5.2 0xbb3d10) after the districts and buildings:
-- HandleStarbases (0xbc4f70) and HandleStarbasesDefenses (0xbc9020).
--
-- HandleStarbases:
--   capacity = trunc(the country's starbase_capacity); used = CCountry::
--     CalcNumStarbasesIncludingConstruction (L:0x23acf30 Linux: each of our systems whose primary
--     starbase is upgraded or has its upgrade queued)
--   the starbases of the systems with our starbases: a primary outpost (not upgraded, not a
--     waystation) goes to the outposts' list, every other to the upgraded list
--   DowngradeStarbases(capacity - used, upgraded)              (not ported: never over capacity in
--   BuildStarbaseModulesAndBuildings(upgraded)                  the 2210 saves; modules and
--                                                               buildings: none queued in 180 days)
--   with the type's ai.starbase_upgrade:
--     UpgradeExistingStarbases(upgraded) (0xbc5800): the next level of an upgraded starbase
--       (not ported: the starhold's technology, none in the window)
--     capacity - used > 0: BuildNewStarbases(outposts) (0xbc5ab0): of the outposts that may be
--       upgraded (IsValidStarbaseToUpgrade, CanQueueUpgradeConstruction [I]: nothing in its
--       queue), the first of the highest CalcStarbaseSystemScore(system, starbase, true) above 0;
--       its upgrade to the next level posted with its cost and upkeep
--       (AddAICommandWithCostAndUpkeepForPosting: CanAffordExpenditure, CanAffordUpkeep,
--       WithdrawCost)
-- CalcStarbaseSystemScore (0xbc4c10): STARBASE_COLONY_SCORE with a colony of ours, else
--   STARBASE_HABITABLE_PLANET_SCORE with a colonizable planet; + STARBASE_MEGASTRUCTURE_SCORE,
--   + STARBASE_BYPASS_SCORE, + the chokepoint's value (NAIUtil::IsChokePoint: not ported),
--   + STARBASE_SECTOR_CAPITAL_SCORE; divided by max(1, the level's ai_weight)
-- HandleStarbasesDefenses: defense platforms, from AI_BUDGETING_MID_YEARS on (not ported: not
--   before 2230).
--
-- The item (a CAddBuildableToQueueCommand, executed after every AI decided) goes to the
-- starbase's build queue through engine.ai.economy.orders, in the save's form:
--   buildable_starbase_upgrade = { starbase_upgrade = "starbase_level_starport" starbase = id }
-- with its cost taken from the stockpile; engine.construction runs the queue.
-- STELLAR_AI_STARBASES=off turns it off.

local world = require("engine.world")
local slice = require("engine.slice")   -- a phase in pieces (docs/frame_timing.md)
local cmds = require("engine.ai.commands")
local defs = require("engine.defs")

local M = {
    stats = { weeks = 0, upgrades = 0, unaffordable = 0, executed = 0, failed = 0, full = 0 },
    decisions = {},
}
local S = M.stats
local NO_ID = 4294967295

local function stations()
    return require("engine.fleets.stations")
end

local D
local function defines()
    if D == nil then
        local g = defs.get("common/defines", "NAI")
        local function v(k, default)
            return g and tonumber(defs.field(g.block, k)) or default
        end
        D = {
            COLONY = v("STARBASE_COLONY_SCORE", 5), HABITABLE = v("STARBASE_HABITABLE_PLANET_SCORE", 3),
            MEGA = v("STARBASE_MEGASTRUCTURE_SCORE", 5), BYPASS = v("STARBASE_BYPASS_SCORE", 10),
            SECTOR = v("STARBASE_SECTOR_CAPITAL_SCORE", 5),
        }
    end
    return D
end

local function level_def(level)
    return level and defs.get("common/starbase_levels", tostring(level):gsub('"', ""))
end

local function base_level()
    return stations().defines().BASE_LEVEL
end

local function is_upgraded(sb)
    local s = world.object("starbases", sb)
    local level = s and tostring(world.field(s, "level") or ""):gsub('"', "")
    return level ~= nil and level ~= base_level()
end

-- an upgrade queued in the starbase's build queue (CStarbase::CalcIsUpgradingStarbase [I])
local function queued_items(sb)
    local s = world.object("starbases", sb)
    local q = s and world.object("construction.queue_mgr.queues", tonumber(world.field(s, "build_queue")))
    return world.list(q and world.field(q, "items")), q
end
local function upgrading(sb)
    for _, iid in ipairs(queued_items(sb)) do
        slice.tick("ai/starbases.lua:89")
        local item = world.object("construction.item_mgr.items", tonumber(iid))
        if item and world.field(item, "buildable_starbase_upgrade") then
            return true
        end
    end
    return false
end

local function own_systems(country)
    local out = {}
    for _, sid in ipairs(world.all("system")) do
        slice.tick("ai/starbases.lua:99")
        if world.system_owner[sid] == country then out[#out + 1] = sid end
    end
    return out
end

-- CalcStarbaseSystemScore(system, starbase, true)
local function system_score(country, sid, sb)
    local d = defines()
    local g = require("engine.ai.strategy").galaxy()
    local score = 0
    local colony = false
    for _, pid in ipairs(g.planets_of[sid] or {}) do
        slice.tick("ai/starbases.lua:113")
        local p = world.object("planet", pid)
        if p and tonumber(world.field(p, "owner")) == country and world.planet_colony[pid] then
            colony = true
            break
        end
    end
    if colony then
        score = score + d.COLONY
    else
        for _, pid in ipairs(g.planets_of[sid] or {}) do
            slice.tick("ai/starbases.lua:123")
            if stations().colonizable(pid) then
                score = score + d.HABITABLE
                break
            end
        end
    end
    local sys = world.object("system", sid)
    local mega = world.list(sys and world.field(sys, "megastructures"))
    if #mega > 0 then score = score + d.MEGA end
    if #(g.bypasses_of[sid] or {}) > 0 then score = score + d.BYPASS end
    -- a sector's local capital in the system
    for _, sec in ipairs(world.all("sectors")) do
        slice.tick("ai/starbases.lua:133")
        local s = world.object("sectors", sec)
        local cap = s and tonumber(world.field(s, "local_capital"))
        local pid = cap and world.colony_planet[cap]
        if pid and g.system_of[pid] == sid then
            score = score + d.SECTOR
            break
        end
    end
    local s = world.object("starbases", sb)
    local ld = level_def(s and world.field(s, "level"))
    local aw = ld and defs.field(ld.block, "ai_weight")
    local w = tonumber(type(aw) == "table" and defs.field(aw, "weight") or nil) or 1
    if w < 1 then w = 1 end
    return score / w
end

local function command(country, sb, level, queue, cost, size)
    return {
        kind = "starbase_upgrade", country = country, target = sb,
        execute = function()
            local orders = require("engine.ai.economy.orders")
            local e = require("engine.economy")
            local sd = defs.get("common/ship_sizes", size)
            local bt = sd and tonumber(defs.field(sd.block, "base_buildtime")) or 360
            local id = orders.add{
                country = country, queue = queue, kind = "starbase_upgrade",
                fields = { { "starbase_upgrade", level, true }, { "starbase", sb } },
                cost = cost, cost_order = e.resources or {}, build_time = bt,
            }
            if id then
                S.executed = S.executed + 1
                return true
            end
            S.failed = S.failed + 1
            return false
        end,
    }
end

-- BuildNewStarbases (0xbc5ab0)
local function build_new_starbases(country, outposts, commands, today)
    local best, best_score
    for _, sb in ipairs(outposts) do
        slice.tick("ai/starbases.lua:179")
        if not is_upgraded(sb) and not upgrading(sb) then
            local s = world.object("starbases", sb)
            local ld = level_def(world.field(s, "level"))
            local nxt = ld and defs.field(ld.block, "next_level")
            if nxt then
                local sid
                for _, x in ipairs(own_systems(country)) do
                    slice.tick("ai/starbases.lua:186")
                    if stations().primary_starbase(x) == sb then sid = x break end
                end
                local score = sid and system_score(country, sid, sb) or 0
                if score > 0 and (best == nil or score > best_score) then
                    best, best_score = sb, score
                end
            end
        end
    end
    if not best then
        return
    end
    local s = world.object("starbases", best)
    local nxt = defs.field(level_def(world.field(s, "level")).block, "next_level")
    local nd = level_def(nxt)
    local size = nd and defs.field(nd.block, "ship_size")
    local cost, category = stations().size_table(country, size, "cost")
    local upkeep = stations().size_table(country, size, "upkeep")
    local b = require("engine.ai.budget")
    if not (b.can_afford_expenditure(country, category, cost) and b.can_afford_upkeep(country, category, upkeep)) then
        S.unaffordable = S.unaffordable + 1
        return
    end
    local q = tonumber(world.field(s, "build_queue"))
    if not q or q == NO_ID then
        return
    end
    b.withdraw(country, category, cost)
    commands[#commands + 1] = cmds.make("engine.ai.starbases", "command", command, country, best, nxt, q, cost, size)
    S.upgrades = S.upgrades + 1
    M.decisions[#M.decisions + 1] = { date = today, country = country, starbase = best, level = nxt }
end

-- M.weekly(country, today, commands): HandleStarbases
function M.weekly(country, today, commands, host)
    if os.getenv("STELLAR_AI_STARBASES") == "off" then
        return
    end
    local ai = require("engine.ai")
    if not (ai.setting(country, "construction") or ai.setting(country, "limited_construction")) then
        return
    end
    local c = world.object("country", country)
    if not c then
        return
    end
    S.weeks = S.weeks + 1
    local capacity = math.floor(tonumber(world.field(c, "starbase_capacity")) or 0)
    local used = 0
    local outposts, upgraded = {}, {}
    for _, sid in ipairs(own_systems(country)) do
        slice.tick("ai/starbases.lua:237")
        local primary = stations().primary_starbase(sid)
        if primary and (is_upgraded(primary) or upgrading(primary)) then
            used = used + 1
        end
        local g = world.object("system", sid)
        for _, v in ipairs(world.list(g and world.field(g, "starbases"))) do
            slice.tick("ai/starbases.lua:243")
            local sb = tonumber(v)
            if sb and sb ~= NO_ID and world.object("starbases", sb) then
                if sb == primary and not is_upgraded(sb) then
                    outposts[#outposts + 1] = sb
                else
                    upgraded[#upgraded + 1] = sb
                end
            end
        end
    end
    if ai.setting(country, "starbase_upgrade") then
        if capacity - used > 0 then
            build_new_starbases(country, outposts, commands, today)
        else
            S.full = S.full + 1
        end
    end
end

function M.log()
    local lines = {}
    for _, d in ipairs(M.decisions) do
        slice.tick("ai/starbases.lua:265")
        lines[#lines + 1] = string.format("%s %d starbase %d -> %s", d.date or "?", d.country, d.starbase, tostring(d.level))
    end
    return table.concat(lines, "\n")
end

function M.report()
    return string.format("ai starbases: %d weeks, %d upgrades ordered (%d unaffordable, %d weeks at capacity); commands %d executed, %d failed",
        S.weeks, S.upgrades, S.unaffordable, S.full, S.executed, S.failed)
end

M.ctor = { command = command }

return M
