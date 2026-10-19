-- engine/fleets/destroy.lua : ships and fleets taken out of the world, the bookkeeping the game's
-- CShip::SetToBeKilled / CFleet removal leaves behind them [I: the parts the save shows]: the
-- ship out of its fleet's list (the fleet's hit points), a military ship's template count and its
-- country's fleet size and naval capacity used; a fleet left empty removed with its system's
-- presence, its country's owned_fleets entry and its template. Used by the colony ship's landing
-- (engine.fleets.colonize), the transports' (engine.fleets.armies) and combat
-- (engine.fleets.combat).
--
--   destroy.ship(sid[, keep_fleet]) -> true | false   the ship gone; its fleet too when emptied
--   destroy.fleet(fid)                                the fleet and its ships gone

local world = require("engine.world")

local destroy = { stats = { ships = 0, fleets = 0 } }

local NO_ID = 4294967295

local function unq(v) return v and (tostring(v):gsub('"', "")) or nil end

local function system_of(f)
    local s = tonumber(world.path(f, "movement_manager", "coordinate", "origin"))
    return s and s ~= NO_ID and s or nil
end

local function ship_ids(f)
    local out = {}
    for _, v in ipairs(world.list(world.field(f, "ships") or {})) do out[#out + 1] = tonumber(v) end
    return out
end

-- a military ship's share of its country's fleet size and its template (create.add_ship's reverse)
local function uncount(f, fid, s)
    local sdi = world.field(s, "ship_design_implementation")
    local did = type(sdi) == "table" and tonumber(world.field(sdi, "design"))
    local okc, create = pcall(require, "engine.fleets.create")
    local info = okc and did and create.design_info(did, tonumber(world.field(sdi, "growth_stage")) or 0)
    if not info or info.civilian or info.class ~= "shipclass_military" then return end
    local size = info.size_multiplier or 1
    local c = world.fleet_owner and world.object("country", world.fleet_owner[fid])
    if c then
        for _, k in ipairs({ "fleet_size", "used_naval_capacity" }) do
            local v = tonumber(world.field(c, k))
            if v then world.set(c, k, math.max(0, v - size)) end
        end
    end
    local tid = tonumber(world.field(f, "fleet_template"))
    local t = tid and world.object("fleet_template", tid)
    if not t then return end
    local upgrade = tonumber(world.field(sdi, "upgrade"))
    for _, want in ipairs({ upgrade ~= NO_ID and upgrade or nil, did }) do
        for _, e in ipairs(world.blocks(world.field(t, "fleet_template_design") or {})) do
            local esdi = world.field(e, "ship_design_implementation")
            local n = tonumber(world.field(e, "count")) or 0
            if type(esdi) == "table" and tonumber(world.field(esdi, "design")) == want and n > 0 then
                world.set(e, "count", n - 1)
                world.set(t, "fleet_size", math.max(0, (tonumber(world.field(t, "fleet_size")) or 0) - size))
                return
            end
        end
    end
end

-- the fleet's own entries elsewhere: its system's presence, its country's owned_fleets, its template
local function unlink_fleet(fid, f)
    local sys = system_of(f)
    local g = sys and world.object("galactic_object", sys)
    local fp = g and world.field(g, "fleet_presence")
    if type(fp) == "table" then world.remove_value(fp, fid) end
    local country = world.fleet_owner and world.fleet_owner[fid]
    local c = country and world.object("country", country)
    local owned = c and world.path(c, "fleets_manager", "owned_fleets")
    if type(owned) == "table" then
        for i = #owned, 1, -1 do
            local e = owned[i]
            if type(e) == "table" and not e.op and not e.text and tonumber(world.field(e, "fleet")) == fid then
                world.remove_at(owned, i)
            end
        end
    end
    local tid = tonumber(world.field(f, "fleet_template"))
    if tid and world.object("fleet_template", tid) then
        local mgr = c and world.field(c, "fleet_template_manager")
        local list = type(mgr) == "table" and world.field(mgr, "fleet_template")
        if type(list) == "table" then world.remove_value(list, tid) end
        world.remove("fleet_template", tid)
    end
    world.remove("fleet", fid)
    if world.fleet_owner then world.fleet_owner[fid] = nil end
    destroy.stats.fleets = destroy.stats.fleets + 1
end

function destroy.ship(sid, keep_fleet)
    local s = world.object("ships", sid)
    if not s then return false end
    local fid = tonumber(world.field(s, "fleet"))
    local f = fid and world.object("fleet", fid)
    if f then
        uncount(f, fid, s)
        local list = world.field(f, "ships")
        if type(list) == "table" then world.remove_value(list, sid) end
        local hp = tonumber(world.field(s, "hitpoints")) or 0
        world.set(f, "hit_points", string.format("%.5f", math.max(0, (tonumber(world.field(f, "hit_points")) or 0) - hp)))
    end
    world.remove("ships", sid)
    destroy.stats.ships = destroy.stats.ships + 1
    if f and not keep_fleet and #ship_ids(f) == 0 then
        unlink_fleet(fid, f)
    end
    return true
end

function destroy.fleet(fid)
    local f = world.object("fleet", fid)
    if not f then return false end
    for _, sid in ipairs(ship_ids(f)) do destroy.ship(sid, true) end
    unlink_fleet(fid, f)
    return true
end

destroy.unquote = unq
return destroy
