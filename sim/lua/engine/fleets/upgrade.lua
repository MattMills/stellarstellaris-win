-- engine/fleets/upgrade.lua : a fleet upgraded to its designs' newest versions at a shipyard, as the
-- game does it (4.5.2 Linux; the RE notes: scratchpad re4/SPEC_orders.md section 3, summarised in
-- docs/windows/fleet.md):
--
--   upgrade_design_at_orbitable_fleet_order = { orbitable = { starbase } status = { { ship
--     upgrade_implementation = { design upgrade growth_stage } value status } ... } queue
--     self_upgrading <base> }   (CUpgradeDesignAtOrbitableFleetOrder)
--     tick    TickOrder (0x29a57f0): away from the starbase its orbit sub-order; in orbit each ship
--             waiting starts its upgrade (in the game a construction-queue item of the shipyard,
--             CBuildableShipUpgrade; here kept in the status entry [I]: its cost paid at its start,
--             `value` its progress in days)
--     done    no ship waiting or upgrading
--   a ship's upgrade: its ship_design_implementation's `upgrade` (the newer design the game marks)
--   the target; the cost [I: CShip::CalcUpgradeCost not read in full] the new design's cost less
--   FLEET_UPGRADE_COMPONENT_COST_REFUND_MULT of the old one's, per resource, at least 0; the time
--   CalcUpgradeProgressionTimeNeeded: the new design's build time x (the upgrade's cost / the
--   design's full cost) x FLEET_UPGRADE_TIME_COST_MULT [V the parts, I the order]; done:
--   CShip::UpgradeToDesign: the design the new one, `upgrade` none, the hit points rebuilt full
--   [I], on_ship_upgraded.
--
--   upgrade.order(fleet, starbase) -> the order block (CFleetUpgradeDesignCommand)
--   upgrade.check(fleet) -> true | false, key (IsValid's keys)
--   upgrade.shipyard(fleet) -> the starbase of the nearest shipyard (FindNearestShipyardQueue [I]:
--     the fleet's system's own starbase with a shipyard, else the capital's)
-- Not done: the construction queue's item (the shipyard's queue length and its other items), the
-- rarity cost, the affordability over time (FLEET_UPGRADE_CANT_AFFORD_*), allied shipyards, mobile
-- starbases, the fleet template's swap, the done message.

local world = require("engine.world")

local upgrade = { stats = { started = 0, done = 0, refused = 0 } }
local S = upgrade.stats

local NO_ID = 4294967295

local function unq(v) return v and (tostring(v):gsub('"', "")) or nil end
local function ref(v)
    local n = tonumber(v)
    return n and n ~= NO_ID and n or nil
end

local function shipbuilding() return require("engine.ai.shipbuilding") end
local function stations() return require("engine.fleets.stations") end

local DEF
local function defines()
    if DEF then return DEF end
    local defs = require("engine.defs")
    local function d(group, key, default)
        local g = defs.get("common/defines", group)
        return tonumber(g and defs.field(g.block, key)) or default
    end
    DEF = { REFUND = d("NEconomy", "FLEET_UPGRADE_COMPONENT_COST_REFUND_MULT", 0.9),
            TIME = d("NEconomy", "FLEET_UPGRADE_TIME_COST_MULT", 0.5) }
    return DEF
end

local function ship_ids(f)
    local out = {}
    for _, v in ipairs(world.list(world.field(f, "ships") or {})) do out[#out + 1] = tonumber(v) end
    return out
end

local function target_design(s)
    local sdi = world.field(s, "ship_design_implementation")
    return type(sdi) == "table" and ref(world.field(sdi, "upgrade")) or nil, sdi
end

-- the upgrade's cost (per resource) and its days
function upgrade.cost(country, sid)
    local s = world.object("ships", sid)
    local new, sdi = target_design(s)
    if not new then return nil end
    local old = ref(world.field(sdi, "design"))
    local okb, sb = pcall(shipbuilding)
    if not okb then return nil end
    local nc = sb.ship_table(country, new, "cost") or {}
    local oc = old and sb.ship_table(country, old, "cost") or {}
    local out, u, full = {}, 0, 0
    for r, v in pairs(nc) do
        local c = math.max(0, v - defines().REFUND * (oc[r] or 0))
        if c > 0 then out[r] = c end
        u = u + c
        full = full + v
    end
    local bt = sb.build_time(new) or 0
    local days = bt * (math.max(u, 1) / math.max(full, 1)) * defines().TIME
    return out, math.max(1, math.floor(days + 0.5))
end

-- the nearest shipyard: the fleet's system's starbase of its owner with a shipyard module, else the
-- capital system's [I]
function upgrade.shipyard(fid)
    local f = world.object("fleet", fid)
    local country = world.fleet_owner and world.fleet_owner[fid]
    if not f or not country then return nil end
    local function yard(sys)
        local sb = sys and stations().primary_starbase and stations().primary_starbase(sys)
        local o = sb and world.object("starbases", sb)
        if not o then return nil end
        for _, m in ipairs(world.list(world.field(o, "modules") or {})) do
            if unq(m) == "shipyard" then return sb end
        end
        local ms = world.field(o, "modules")
        for _, e in ipairs(type(ms) == "table" and ms or {}) do
            if e.op and e.value and unq(e.value.text) == "shipyard" then return sb end
        end
        return nil
    end
    local here = tonumber(world.path(f, "movement_manager", "coordinate", "origin"))
    local sb = yard(here)
    if sb then return sb end
    local c = world.object("country", country)
    local col = c and ref(world.field(c, "capital"))
    local pid = col and world.colony_planet and world.colony_planet[col]
    local p = pid and world.object("planet", pid)
    return yard(p and tonumber(world.path(p, "coordinate", "origin")))
end

-- CFleetUpgradeDesignCommand::IsValid's keys
function upgrade.check(fid)
    local f = world.object("fleet", fid)
    if not f or world.path(f, "properties", "station") == "yes" then return false, "UPGRADE_NOT_OWNER" end
    local any = false
    for _, sid in ipairs(ship_ids(f)) do
        if target_design(world.object("ships", sid)) then any = true end
    end
    if not any then return false, "NO_UPGRADE_AVAILABLE" end
    local cur = world.field(f, "current_order")
    if type(cur) == "table" and world.field(cur, "upgrade_design_at_orbitable_fleet_order") then
        return false, "FLEETORDER_UPGRADE_ALREADY_UPGRADING"
    end
    if not upgrade.shipyard(fid) then return false, "NO_UPGRADE_REACHABLE" end
    return true
end

function upgrade.order(fid, sb)
    local f = world.object("fleet", fid)
    local b = {}
    local ob = {}
    world.append(ob, "starbase", sb)
    world.append(b, "orbitable", ob)
    local st = {}
    for _, sid in ipairs(f and ship_ids(f) or {}) do
        local s = world.object("ships", sid)
        local new, sdi = target_design(s)
        if new then
            local e, ui = {}, {}
            world.append(e, "ship", sid)
            world.append(ui, "design", new)
            world.append(ui, "upgrade", NO_ID)
            world.append(ui, "growth_stage", tonumber(world.field(sdi, "growth_stage")) or 0)
            world.append(e, "upgrade_implementation", ui)
            world.append(e, "value", 0)
            world.append(e, "status", "upgrade_waiting")
            world.push(st, e)
        end
    end
    world.append(b, "status", st)
    world.append(b, "self_upgrading", "no")
    return { { key = { text = "upgrade_design_at_orbitable_fleet_order" }, op = "=", value = b } }
end

local function starbase_of(o) return ref(world.path(o.block, "orbitable", "starbase")) end

-- CShip::UpgradeToDesign: the new design, its hit points full [I]
local function finish_ship(country, sid, e)
    local s = world.object("ships", sid)
    if not s then return end
    local sdi = world.field(s, "ship_design_implementation")
    local new = ref(world.path(e, "upgrade_implementation", "design"))
    if type(sdi) ~= "table" or not new then return end
    world.set(sdi, "design", new)
    world.set(sdi, "upgrade", NO_ID)
    local okc, create = pcall(require, "engine.fleets.create")
    if okc and create.hit_points then
        local hull, armor, shield = create.hit_points(country, new, tonumber(world.field(sdi, "growth_stage")) or 0)
        if hull then
            for k, v in pairs({ hitpoints = hull, max_hitpoints = hull, armor_hitpoints = armor, max_armor_hitpoints = armor,
                                shield_hitpoints = shield, max_shield_hitpoints = shield }) do
                world.set(s, k, string.format("%.5f", v or 0))
            end
        end
        pcall(create.on_action, "on_ship_upgraded", { "ship", sid }, nil)
    end
    S.done = S.done + 1
end

local order = {}
upgrade.order_type = order

function order.tick(o, fid, f, orders)
    local sb = starbase_of(o)
    if not sb then return end
    if not orders.in_orbit_of(fid, f, sb) then
        -- (in_orbit_of takes planets; a starbase's orbit: the fleet's orbitable)
        local ob = world.path(f, "movement_manager", "orbit", "orbitable")
        if not (type(ob) == "table" and ref(world.field(ob, "starbase")) == sb) then
            orders.tick_orbit_sub_order(o, fid, f, sb, "starbase")
            return
        end
    end
    orders.clear_sub_order(o)
    local country = world.fleet_owner and world.fleet_owner[fid]
    for _, e in ipairs(world.blocks(world.field(o.block, "status") or {})) do
        local st = unq(world.field(e, "status"))
        local sid = ref(world.field(e, "ship"))
        if st == "upgrade_waiting" and sid then
            local cost, days = upgrade.cost(country, sid)
            if cost and stations().can_afford(country, cost) then
                for r, v in pairs(cost) do
                    local c = world.object("country", country)
                    local stock = c and world.path(c, "modules", "standard_economy_module", "resources")
                    local now = stock and tonumber(world.field(stock, r))
                    if now then world.set(stock, r, string.format("%.5f", now - v)) end
                end
                world.set(e, "status", "upgrade_upgrading")
                world.set(e, "days", days)
                S.started = S.started + 1
            elseif not cost then
                world.set(e, "status", "upgrade_canceled")
            end
        elseif st == "upgrade_upgrading" and sid then
            local v = (tonumber(world.field(e, "value")) or 0) + 1
            world.set(e, "value", v)
            if v >= (tonumber(world.field(e, "days")) or 1) then
                finish_ship(country, sid, e)
                world.set(e, "status", "upgrade_done")
            end
        end
    end
end
order.start = order.tick

function order.is_done(o)
    for _, e in ipairs(world.blocks(world.field(o.block, "status") or {})) do
        local st = unq(world.field(e, "status"))
        if st == "upgrade_waiting" or st == "upgrade_upgrading" then return false end
    end
    return true
end
function order.finish() end

function upgrade.report()
    return string.format("upgrade: %d started, %d done, %d refused", S.started, S.done, S.refused)
end

return upgrade
