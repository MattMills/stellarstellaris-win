-- engine.construction_planet: the planet view's buildables that engine.construction does not model
-- itself (CBuildableDecision, CBuildableReplaceBuilding, CBuildableRepairBuilding,
-- CBuildableReplaceDistrict, CBuildableClearDepositBlocker, a zone replacing another) and the
-- planet's terraforming (CStartTerraformationCommand: a process on the planet, advanced daily).
--
-- engine.construction asks it for these kinds' daily progress (speed) and to finish them (finish);
-- its daily update runs the terraforming (daily). render.windows.planet's commands queue them.
--
-- The save keys of the items' buildables are the game's (buildable_decision,
-- buildable_planet_replace_building, buildable_planet_repair_building, buildable_replace_district,
-- buildable_clear_deposit_blocker); their fields are **[I]** (no save of 2210-2212 holds one):
--   decision                  decision = KEY, planet = colony
--   planet_replace_building   building = NEW, planet = colony, replace_building = building id
--   planet_repair_building    building = TYPE, planet = colony, repair_building = building id
--   replace_district          district = NEW, planet = colony, replace_district = OLD type
--   clear_deposit_blocker     deposit = deposit id, planet = colony
--   zone (a replacement)      zone_to_replace = zone id with the zone's usual fields

local world = require("engine.world")
local defs = require("engine.defs")

local cp = {}

local KINDS = {
    decision = true, planet_replace_building = true, planet_repair_building = true,
    replace_district = true, clear_deposit_blocker = true,
}
cp.KINDS = KINDS

local function unq(v)
    return v and (tostring(v):gsub('"', "")) or nil
end

local function colony_mods(colony)
    local economy = package.loaded["engine.economy"]
    return economy and economy.modifiers("colony", colony or -1) or {}
end

-- whether a buildable is one of ours: our kinds, and a zone replacing another
function cp.handles(kind, b)
    return KINDS[kind] or (kind == "zone" and world.field(b, "zone_to_replace") ~= nil)
end

-- the daily progress of one of ours (the planet's build speed, as engine.construction's planet
-- kinds; a decision: planet_decision_enact_speed_mult; a blocker: planet_clear_blocker_speed_mult)
function cp.speed(kind, b)
    local M = colony_mods(tonumber(world.field(b, "planet")))
    if kind == "decision" then
        return 1 + (M.planet_decision_enact_speed_mult or 0)
    elseif kind == "clear_deposit_blocker" then
        return 1 + (M.planet_clear_blocker_speed_mult or 0)
    end
    return 1 + (M.planet_building_build_speed_mult or 0)
end

-- an effect block run with this = the planet, its owner as FROM (a decision's effect)
local function run_effect(block, pid, owner)
    if type(block) ~= "table" then
        return true
    end
    local eval = require("simscript.eval")
    local ctx = eval.new_ctx(eval.S("planet", pid), owner and eval.S("country", owner) or nil)
    local ok, err = pcall(eval.effect, block, ctx)
    if eval.sync then
        eval.sync()
    end
    return ok, err
end
cp.run_effect = run_effect

-- the colony's district of a type: id, block
local function district_of(c, dtype)
    for _, did in ipairs(world.list(world.field(c, "districts"))) do
        local d = world.object("districts", tonumber(did))
        if d and unq(world.field(d, "type")) == dtype then
            return tonumber(did), d
        end
    end
end

local function rebuild(cid)
    local ok, colony = pcall(require, "engine.script.objects_colony")
    local c = world.object("colony", cid)
    if ok and c and colony.rebuild_cache then
        colony.rebuild_cache(c)
    end
end

-- a blocker deposit cleared as clear_blockers clears each (objects_colony): its type's on_cleared,
-- then the deposit it hid takes its place, or it goes
function cp.clear_blocker(pid, did)
    local p = world.object("planet", pid)
    local d = world.object("deposit", did)
    if not (p and d) then
        return false, "no planet or deposit"
    end
    local key = unq(world.field(d, "type"))
    local def = defs.get("common/deposits", key)
    run_effect(def and defs.field(def.block or def, "on_cleared"), pid)
    local swap = world.field(d, "swap_type")
    if swap then
        world.set(d, "type", unq(swap))
        local e = world.token_entry and world.token_entry(d, "swap_type") or world.entry(d, "swap_type")
        if e then
            world.remove_entry(d, e)
        end
    else
        world.remove_value(world.field(p, "deposits"), did)
        world.remove("deposit", did)
    end
    return true
end

function cp.finish(kind, b, date)
    local cid = tonumber(world.field(b, "planet"))
    local c = cid and world.object("colony", cid)
    local pid = cid and world.colony_planet and world.colony_planet[cid]
    if not c then
        return false, kind .. ": no colony " .. tostring(cid)
    end
    pid = pid or tonumber(world.field(c, "planet"))
    if kind == "decision" then
        -- CEnactDecisionCommand's item done: the decision's effect on the planet
        local key = unq(world.field(b, "decision"))
        local def = defs.get("common/decisions", key)
        if not def then
            return false, "decision: no " .. tostring(key)
        end
        local owner = tonumber(world.field(world.object("planet", pid), "owner"))
        local ok, err = run_effect(defs.field(def.block or def, "effect"), pid, owner)
        return ok, err and ("decision " .. key .. ": " .. tostring(err)) or nil
    elseif kind == "planet_replace_building" or kind == "planet_repair_building" then
        -- the building in its slot becomes the new type (replace), or is no longer ruined (repair)
        local bid = tonumber(world.field(b, kind == "planet_replace_building" and "replace_building" or "repair_building"))
        local bl = bid and world.object("buildings", bid)
        if not bl then
            return false, kind .. ": no building " .. tostring(bid)
        end
        if kind == "planet_replace_building" then
            world.set(bl, "type", world.field(b, "building"))
        end
        local e = world.entry(bl, "ruined")
        if e then
            world.remove_entry(bl, e)
        end
        rebuild(cid)
        return true
    elseif kind == "replace_district" then
        -- the colony's district of the old type becomes the new type, its zones and buildings gone
        -- **[I]** (CBuildableReplaceDistrict: what the game keeps)
        local old, new = unq(world.field(b, "replace_district")), unq(world.field(b, "district"))
        local _, d = district_of(c, old)
        if not d then
            return false, "replace_district: no " .. tostring(old)
        end
        local zl = world.field(d, "zones")
        for _, z in ipairs(world.list(zl)) do
            local zb = tonumber(z) and world.object("zones", tonumber(z))
            if zb then
                for _, x in ipairs(world.list(world.field(zb, "buildings"))) do
                    world.remove("buildings", tonumber(x))
                end
                world.remove("zones", tonumber(z))
            end
        end
        if type(zl) == "table" then
            world.replace(zl, {})
        end
        world.set(d, "type", '"' .. new .. '"')
        rebuild(cid)
        return true
    elseif kind == "clear_deposit_blocker" then
        return cp.clear_blocker(pid, tonumber(world.field(b, "deposit")))
    elseif kind == "zone" then
        -- a zone replacing another (zone_construction on an occupied slot): the old one's
        -- buildings move to it (CDistrict::AddOrReplaceZone)
        local colony = require("engine.script.objects_colony")
        local d = world.object("districts", tonumber(world.field(b, "district")))
        local slot = tonumber(world.field(b, "zone_slot"))
        if not (d and slot) then
            return false, "zone: no district or slot"
        end
        local zid = colony.add_zone(d, unq(world.field(b, "zone")), slot, true)
        rebuild(cid)
        return zid ~= nil
    end
    return nil
end

-- ---------------------------------------------------------------------------------------------
-- terraforming: planet.terraform_process = { terraform_type = TO, progress, total,
-- player_started_terraform = yes } **[I]** the keys (the game's strings terraform_type,
-- player_started_terraform); the planet's class changes when it is done (change_pc)

local PROC = "terraform_process"
local index -- the planets with a process (a scan of the planets once)

local function processes()
    if not index then
        index = {}
        for _, pid in ipairs(world.all("planet")) do
            local p = world.object("planet", pid)
            if p and world.field(p, PROC) then
                index[pid] = true
            end
        end
    end
    return index
end

function cp.start_terraform(pid, to, total)
    local p = world.object("planet", pid)
    if not p or world.field(p, PROC) then
        return false
    end
    local blk = {}
    world.append(blk, "terraform_type", '"' .. to .. '"')
    world.append(blk, "progress", 0)
    world.append(blk, "total", total or 1)
    world.append(blk, "player_started_terraform", "yes")
    world.append(p, PROC, blk)
    processes()[pid] = true
    return true
end

function cp.cancel_terraform(pid)
    local p = world.object("planet", pid)
    local e = p and world.entry(p, PROC)
    if not e then
        return false
    end
    world.remove_entry(p, e)
    processes()[pid] = nil
    return true
end

-- the daily progress of every terraforming (1 a day, terraform_speed_mult of the colony)
function cp.daily(date)
    if not (world.stores and world.stores.planet) then
        return
    end
    for pid in pairs(processes()) do
        local p = world.object("planet", pid)
        local blk = p and world.field(p, PROC)
        if type(blk) ~= "table" then
            index[pid] = nil
        else
            local cid = world.planet_colony and world.planet_colony[pid]
            local speed = 1 + (colony_mods(cid).terraform_speed_mult or 0)
            local progress = (tonumber(world.field(blk, "progress")) or 0) + speed
            if progress >= (tonumber(world.field(blk, "total")) or 0) then
                local to = unq(world.field(blk, "terraform_type"))
                cp.cancel_terraform(pid)
                local systems = require("engine.systems")
                if systems.effects and systems.effects.change_pc then
                    pcall(systems.effects.change_pc, { kind = "planet", id = pid, class = to })
                else
                    world.set(p, "planet_class", '"' .. to .. '"')
                end
            else
                world.set(blk, "progress", progress)
            end
        end
    end
end

return cp
