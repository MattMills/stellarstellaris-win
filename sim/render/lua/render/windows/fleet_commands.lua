-- render/windows/fleet_commands.lua : what the fleet windows' buttons do to the world, run in the
-- simulation's runtime (fleetwin.rs: App::fleet_command, Clock::query), through the engine's own
-- fleet orders (engine.fleets.orders, engine.fleets.create) where it has them (docs/windows/fleet.md).
--
--   local fc = require("render.windows.fleet_commands")
--   fc.<name>(fleet_id)                       an order button without a target (stop, return_home,
--                                            stance, ground_support, merge, split, disband ...)
--   fc.ship_disband(ship_id)                  the ship list's disband
--   fc.target(fleet_id, order, kind, id)      a targeted order (move, survey, research ...) given
--                                            on the map: kind "system" | "planet" | "fleet" | "ship"
--   fc.template(fleet_id, design_id, delta)   the Fleet Manager's row: the template's count +- 1
--
-- Each returns a short text: "ok ..." when the world changed, "refused: why" when the game would
-- not do it either, "not done: why" for what the engine does not model yet. A nil or missing
-- object is a refusal, never an error (the other windows keep drawing).

local world = require("engine.world")

local fc = {}

local NO_ID = 4294967295

local function orders()
    return require("engine.fleets.orders")
end

local function unquote(v)
    return v and (tostring(v):gsub('"', "")) or nil
end

local function player()
    return require("render.windows.fleet_data").player()
end

-- the player's own fleet, else nil and why
local function own_fleet(fid)
    fid = tonumber(fid)
    local f = fid and world.object("fleet", fid)
    if not f then
        return nil, "no fleet " .. tostring(fid)
    end
    if world.fleet_owner and world.fleet_owner[fid] ~= player() then
        return nil, "not the player's fleet"
    end
    return f
end

local function props(f, key)
    return world.path(f, "properties", key) == "yes"
end

local function system_of(f)
    local s = tonumber(world.path(f, "movement_manager", "coordinate", "origin"))
    return s and s ~= NO_ID and s or nil
end

local function ship_ids(f)
    local out = {}
    for _, v in ipairs(world.list(world.field(f, "ships") or {})) do
        out[#out + 1] = tonumber(v)
    end
    return out
end

local function guarded(name, fn, ...)
    local ok, r = pcall(fn, ...)
    if not ok then
        return "error: " .. name .. ": " .. tostring(r)
    end
    return r
end

local function issued(id, what)
    if id then
        return "ok " .. what .. " (order " .. tostring(id) .. ")"
    end
    return "refused: " .. what
end

---------------------------------------------------------------- orders without a target

-- CFleetView's stop (CStopFleetCommand): the orders cleared
function fc.stop(fid)
    return guarded("stop", function()
        local f, why = own_fleet(fid)
        if not f then return "refused: " .. why end
        orders().clear(tonumber(fid))
        return "ok stop"
    end)
end

-- return (return_fleet_order: to the home base's starbase)
function fc.return_home(fid)
    return guarded("return", function()
        local f, why = own_fleet(fid)
        if not f then return "refused: " .. why end
        if not props(f, "mobile") then return "refused: immobile" end
        return issued(orders().return_to_base(tonumber(fid), { front = true }), "return")
    end)
end
fc["return"] = fc.return_home

-- the stance button: the next stance the fleet supports (CFleet::SupportsFleetStance: evasive not
-- for a military fleet, aggressive not for a civilian one, an immobile one passive only)
function fc.stance(fid)
    return guarded("stance", function()
        local f, why = own_fleet(fid)
        if not f then return "refused: " .. why end
        if not props(f, "mobile") then return "refused: immobile" end
        -- passive -> aggressive -> evasive -> passive, the unsupported skipped [V: the RE spec]
        local civilian = props(f, "civilian")
        local class = unquote(world.field(f, "ship_class")) or "shipclass_military"
        local cur = unquote(world.field(f, "fleet_stance")) or "passive"
        local supports = { passive = true, aggressive = not civilian, evasive = class ~= "shipclass_military" }
        local NEXT = { passive = "aggressive", aggressive = "evasive", evasive = "passive" }
        local new = NEXT[cur] or "passive"
        while not supports[new] do new = NEXT[new] end
        if new == "passive" then
            -- the save leaves the default out
            local e = world.entry(f, "fleet_stance")
            while e do
                world.remove_entry(f, e)
                e = world.entry(f, "fleet_stance")
            end
        else
            world.set(f, "fleet_stance", new)
        end
        return "ok stance " .. new
    end)
end

-- the bombardment stance: the next of common/bombardment_stances in the database's order whose
-- potential passes [V: the RE spec]; the potentials are not evaluated here: selective and
-- indiscriminate, the two every ordinary empire has [I]
function fc.ground_support(fid)
    return guarded("ground_support", function()
        local f, why = own_fleet(fid)
        if not f then return "refused: " .. why end
        local cur = unquote(world.field(f, "ground_support_stance")) or "selective"
        local new = ({ selective = "indiscriminate" })[cur] or "selective"
        world.set(f, "ground_support_stance", new)
        return "ok ground_support " .. new
    end)
end

-- the fleet's template entry of a ship's design (or of the design it upgrades to) counted by
-- delta, its fleet_size by delta x size; false when there is none
local function template_count(f, did, upgrade, delta, size)
    local tid = tonumber(world.field(f, "fleet_template"))
    local t = tid and world.object("fleet_template", tid)
    if not t then return false end
    for _, want in ipairs({ upgrade ~= NO_ID and upgrade or nil, did }) do
        for _, e in ipairs(world.blocks(world.field(t, "fleet_template_design") or {})) do
            local esdi = world.field(e, "ship_design_implementation")
            local n = tonumber(world.field(e, "count")) or 0
            if type(esdi) == "table" and tonumber(world.field(esdi, "design")) == want and (delta > 0 or n > 0) then
                world.set(e, "count", n + delta)
                world.set(t, "fleet_size", math.max(0, (tonumber(world.field(t, "fleet_size")) or 0) + delta * size))
                return true
            end
        end
    end
    return false
end

-- the ships taken out of their fleet's list: the fleet's hit points, and for a military ship its
-- template's count and the country's fleet size and naval capacity used, as create.add_ship adds
-- them (so a move through add_ship counts once)
local function take_ship(f, sid)
    local list = world.field(f, "ships")
    if type(list) ~= "table" then return false end
    world.remove_value(list, sid)
    local s = world.object("ships", sid)
    local hp = s and tonumber(world.field(s, "hitpoints")) or 0
    world.set(f, "hit_points", string.format("%.5f", math.max(0, (tonumber(world.field(f, "hit_points")) or 0) - hp)))
    local sdi = s and world.field(s, "ship_design_implementation")
    local did = type(sdi) == "table" and tonumber(world.field(sdi, "design"))
    local info = did and require("engine.fleets.create").design_info(did, tonumber(world.field(sdi, "growth_stage")) or 0)
    if not info or info.civilian or info.class ~= "shipclass_military" then return true end
    local size = info.size_multiplier or 1
    local fid = tonumber(world.field(s, "fleet"))
    local c = fid and world.fleet_owner and world.object("country", world.fleet_owner[fid])
    if c then
        for _, k in ipairs({ "fleet_size", "used_naval_capacity" }) do
            local v = tonumber(world.field(c, k))
            if v then world.set(c, k, math.max(0, v - size)) end
        end
    end
    template_count(f, did, tonumber(world.field(sdi, "upgrade")), -1, size)
    return true
end

-- the ship put in a fleet (take_ship's reverse, for a merge): at the list's end [I: the game
-- keeps them by size], its fleet, the hit points, a military ship's template count and the
-- country's fleet size and naval capacity
local function put_ship(f, fid, sid)
    local s = world.object("ships", sid)
    local list = world.field(f, "ships")
    if not s or type(list) ~= "table" then return false end
    world.append_value(list, sid)
    world.set(s, "fleet", fid)
    local hp = tonumber(world.field(s, "hitpoints")) or 0
    world.set(f, "hit_points", string.format("%.5f", (tonumber(world.field(f, "hit_points")) or 0) + hp))
    local sdi = world.field(s, "ship_design_implementation")
    local did = type(sdi) == "table" and tonumber(world.field(sdi, "design"))
    local info = did and require("engine.fleets.create").design_info(did, tonumber(world.field(sdi, "growth_stage")) or 0)
    if not info or info.civilian or info.class ~= "shipclass_military" then return true end
    local size = info.size_multiplier or 1
    local c = world.fleet_owner and world.object("country", world.fleet_owner[fid])
    if c then
        for _, k in ipairs({ "fleet_size", "used_naval_capacity" }) do
            local v = tonumber(world.field(c, k))
            if v then world.set(c, k, v + size) end
        end
    end
    template_count(f, did, tonumber(world.field(sdi, "upgrade")), 1, size)
    return true
end

-- a fleet taken out of the world: its system's presence, its country's owned fleets, its template
local function remove_fleet(fid, f)
    local sys = system_of(f)
    local g = sys and world.object("system", sys)
    local fp = g and world.field(g, "fleet_presence")
    if type(fp) == "table" then world.remove_value(fp, fid) end
    local country = world.fleet_owner and world.fleet_owner[fid]
    local c = country and world.object("country", country)
    local owned = c and world.path(c, "fleets_manager", "owned_fleets")
    if type(owned) == "table" then
        for i = #owned, 1, -1 do
            local e = owned[i]
            if type(e) == "table" and e.op and type(e.value) == "table" and tonumber(world.field(e.value, "fleet")) == fid then
                world.remove_at(owned, i)
            end
        end
    end
    local tid = tonumber(world.field(f, "fleet_template"))
    if tid and world.object("fleet_template", tid) then
        local mgr = c and world.child(c, "fleet_template_manager")
        local list = mgr and world.field(mgr, "fleet_template")
        if type(list) == "table" then world.remove_value(list, tid) end
        world.remove("fleet_template", tid)
    end
    world.remove("fleet", fid)
    if world.fleet_owner then world.fleet_owner[fid] = nil end
end

-- disband (CDisbandFleetCommand): the fleet and its ships gone
function fc.disband(fid)
    return guarded("disband", function()
        local f, why = own_fleet(fid)
        if not f then return "refused: " .. why end
        if props(f, "station") or not props(f, "mobile") then return "refused: a station" end
        fid = tonumber(fid)
        local n = 0
        for _, sid in ipairs(ship_ids(f)) do
            take_ship(f, sid)
            world.remove("ships", sid)
            n = n + 1
        end
        remove_fleet(fid, f)
        return "ok disband (" .. n .. " ships)"
    end)
end

-- the ship list's disband (CDisbandShipCommand): the ship gone, its fleet with it when it was the last
function fc.ship_disband(sid)
    return guarded("ship_disband", function()
        sid = tonumber(sid)
        local s = sid and world.object("ships", sid)
        if not s then return "refused: no ship" end
        local fid = tonumber(world.field(s, "fleet"))
        local f, why = own_fleet(fid)
        if not f then return "refused: " .. why end
        if props(f, "station") then return "refused: a station" end
        take_ship(f, sid)
        world.remove("ships", sid)
        if #ship_ids(f) == 0 then
            remove_fleet(fid, f)
            return "ok ship_disband (the fleet gone)"
        end
        return "ok ship_disband"
    end)
end

-- merge (CMergeFleetsCommand): the player's other fleets of the class in the same system merged in
function fc.merge(fid)
    return guarded("merge", function()
        local f, why = own_fleet(fid)
        if not f then return "refused: " .. why end
        fid = tonumber(fid)
        local sys = system_of(f)
        local class = unquote(world.field(f, "ship_class"))
        local merged = 0
        local all = {}
        for i, x in ipairs(world.all("fleet")) do all[i] = x end
        for _, oid in ipairs(all) do
            local o = oid ~= fid and world.object("fleet", oid)
            if o and world.fleet_owner[oid] == world.fleet_owner[fid] and system_of(o) == sys
                and unquote(world.field(o, "ship_class")) == class and props(o, "mobile")
                and not props(o, "station") and not orders().current(oid) then
                for _, sid in ipairs(ship_ids(o)) do
                    take_ship(o, sid)
                    put_ship(f, fid, sid)
                end
                remove_fleet(oid, o)
                merged = merged + 1
            end
        end
        return merged > 0 and ("ok merge (" .. merged .. " fleets)") or "refused: no fleet to merge"
    end)
end

-- split (CSplitFleetCommand): the second half of the ships a new fleet where the fleet is [I]
function fc.split(fid)
    return guarded("split", function()
        local f, why = own_fleet(fid)
        if not f then return "refused: " .. why end
        fid = tonumber(fid)
        local ids = ship_ids(f)
        if #ids < 2 then return "refused: one ship" end
        local create = require("engine.fleets.create")
        local c = world.path(f, "movement_manager", "coordinate")
        local at = c and { x = tonumber(world.field(c, "x")) or 0, y = tonumber(world.field(c, "y")) or 0, origin = system_of(f) or NO_ID }
        local nid = create.fleet({ country = world.fleet_owner[fid], coordinate = at,
            civilian = props(f, "civilian"), ship_class = unquote(world.field(f, "ship_class")) })
        if not nid then return "not done: no fleet made" end
        local ok, mv = pcall(require, "engine.fleets.movement")
        if ok and type(mv) == "table" and mv.add_presence then mv.add_presence(at and at.origin, nid) end
        for i = math.floor(#ids / 2) + 1, #ids do
            take_ship(f, ids[i])
            create.add_ship(nid, ids[i], { no_events = true })
        end
        return "ok split (fleet " .. tostring(nid) .. ")"
    end)
end

---------------------------------------------------------------- targeted orders

-- a target's place: a system's centre, a planet's system, a fleet's (or a ship's fleet's) place
local function target_coordinate(kind, id)
    if kind == "system" then
        return { x = 0, y = 0, origin = id }
    end
    if kind == "planet" then
        local p = world.object("planet", id)
        local c = p and world.field(p, "coordinate")
        if type(c) == "table" then
            return { x = tonumber(world.field(c, "x")) or 0, y = tonumber(world.field(c, "y")) or 0, origin = tonumber(world.field(c, "origin")) or NO_ID }
        end
        return nil
    end
    if kind == "ship" then
        local s = world.object("ships", id)
        kind, id = "fleet", s and tonumber(world.field(s, "fleet"))
    end
    local f = id and world.object("fleet", id)
    local c = f and world.path(f, "movement_manager", "coordinate")
    if type(c) == "table" then
        return { x = tonumber(world.field(c, "x")) or 0, y = tonumber(world.field(c, "y")) or 0, origin = tonumber(world.field(c, "origin")) or NO_ID }
    end
    return nil
end

local function move(fid, kind, id)
    if kind == "planet" then
        return issued(orders().orbit(fid, id), "orbit " .. id)
    end
    local c = target_coordinate(kind, id)
    if not c or c.origin == NO_ID then return "refused: no place" end
    return issued(orders().move_to(fid, c), "move to " .. kind .. " " .. id)
end

-- the game's targeted orders: the button arms the cursor, the map's click gives the target
function fc.target(fid, order, kind, id)
    return guarded("target " .. tostring(order), function()
        local f, why = own_fleet(fid)
        if not f then return "refused: " .. why end
        fid, id = tonumber(fid), tonumber(id)
        if not props(f, "mobile") then return "refused: immobile" end
        if order == "move" then
            -- the move button replaces the orders (the shift-queue not here)
            orders().clear(fid)
            return move(fid, kind, id)
        elseif order == "survey" then
            orders().clear(fid)
            if kind == "planet" then return issued(orders().survey(fid, id), "survey " .. id) end
            if kind == "system" then return issued(orders().survey_system(fid, id), "survey system " .. id) end
            return "refused: survey needs a planet or a system"
        elseif order == "research" then
            if kind ~= "planet" then return "refused: research needs a planet" end
            orders().clear(fid)
            return issued(orders().research_anomaly(fid, id), "research " .. id)
        end
        -- the right click's commands (render.windows.fleet_rightclick): the build orders (a
        -- planet's station; the outpost on a system's or a planet's system's star) and the attack
        -- (follow_order with attack_when_in_range)
        local C = require("render.windows.fleet_rightclick").COMMANDS
        local CLASS = { build_mining = 5, build_research = 6, build_observation = 9, build_starbase = 10 }
        if CLASS[order] then
            local st = require("engine.fleets.stations")
            local pid = kind == "planet" and id or nil
            if order == "build_starbase" then
                local sid = kind == "system" and id or (pid and tonumber(world.path(world.object("planet", pid), "coordinate", "origin")))
                pid = sid and st.star_of(sid)
            end
            if not pid then return "refused: " .. order .. " needs a planet" end
            if not st.can_build_station(world.fleet_owner[fid], pid, CLASS[order]) then return "refused: " .. order .. " not possible on " .. pid end
            return issued(C.build(fid, "replace", pid, CLASS[order]), order .. " " .. pid)
        elseif order == "attack" then
            if kind == "ship" then
                local s = world.object("ships", id)
                kind, id = "fleet", s and tonumber(world.field(s, "fleet"))
            end
            if kind ~= "fleet" or not id or id == fid then return "refused: attack needs another fleet" end
            return issued(C.follow(fid, "replace", id, true), "attack " .. id)
        end
        return "not done: the engine has no " .. tostring(order) .. " order"
    end)
end


---------------------------------------------------------------- the Fleet Manager

-- a template row's count + delta (the reinforcement the game then queues: not done here)
function fc.template(fid, did, delta)
    return guarded("template", function()
        local f, why = own_fleet(fid)
        if not f then return "refused: " .. why end
        local tid = tonumber(world.field(f, "fleet_template"))
        local t = tid and world.object("fleet_template", tid)
        if not t then return "refused: no template" end
        did, delta = tonumber(did), tonumber(delta) or 0
        local info = require("engine.fleets.create").design_info(did, 0)
        local size = info and info.size_multiplier or 1
        for _, e in ipairs(world.blocks(world.field(t, "fleet_template_design") or {})) do
            local sdi = world.field(e, "ship_design_implementation")
            if type(sdi) == "table" and tonumber(world.field(sdi, "design")) == did then
                local n = (tonumber(world.field(e, "count")) or 0) + delta
                if n < 0 then return "refused: none left" end
                world.set(e, "count", n)
                world.set(t, "fleet_size", math.max(0, (tonumber(world.field(t, "fleet_size")) or 0) + delta * size))
                return "ok template " .. did .. " " .. n
            end
        end
        return "refused: no such row"
    end)
end

---------------------------------------------------------------- tests

-- a fleet's orders and place as one line (the script command `fleet_cmd .debug(FID)`): its
-- coordinate, movement state and orbit, the current order with its sub-order and progress, the
-- queue
function fc.debug(fid)
    return guarded("debug", function()
        fid = tonumber(fid)
        local f = world.object("fleet", fid)
        if not f then return "no fleet" end
        local mm = world.field(f, "movement_manager")
        local c = world.field(mm or {}, "coordinate")
        local function blk(b, depth)
            if type(b) ~= "table" then return tostring(b and b.text or b) end
            if depth > 2 then return "{...}" end
            local out = {}
            for _, e in ipairs(b) do
                if e.op and e.key then
                    out[#out + 1] = e.key.text .. "=" .. (type(e.value) == "table" and e.value.text == nil and blk(e.value, depth + 1) or tostring(e.value.text))
                elseif e.text then
                    out[#out + 1] = e.text
                end
            end
            return "{ " .. table.concat(out, " ") .. " }"
        end
        local orb = world.path(f, "movement_manager", "orbit")
        return string.format("fleet %d at %s state %s orbit %s current %s queue %s", fid, blk(c, 0),
            tostring(mm and world.field(mm, "state")), blk(orb, 0), blk(world.field(f, "current_order"), 0),
            blk(world.field(f, "order"), 1))
    end)
end

-- the fleet window's and the Fleet Manager's Upgrade (CFleetActionUpgradeButton::OnClick:
-- FindNearestShipyardQueue, then CFleetUpgradeDesignCommand: the orders cleared, the upgrade order
-- given; engine.fleets.upgrade)
function fc.upgrade(fid)
    return guarded("upgrade", function()
        local f, why = own_fleet(fid)
        if not f then return "refused: " .. why end
        fid = tonumber(fid)
        local up = require("engine.fleets.upgrade")
        local ok, key = up.check(fid)
        if not ok then return "refused: " .. tostring(key) end
        orders().clear(fid)
        return issued(orders().issue(fid, up.order(fid, up.shipyard(fid))), "upgrade")
    end)
end

---------------------------------------------------------------- what the engine does not do yet

local NOT_DONE = {
    auto_explore = "auto-explore (no automation)", auto_construct = "auto-build (no automation)",
    repair = "the repair order", reinforce = "reinforcement",
    mercenary = "mercenaries", transfer = "fleet transfer", follow = "the follow order",
    megastructure = "megastructure building", take_point = "take point", jump = "jump drives",
    retrofit = "retrofit", overwrite = "template overwrite", copy_template = "template copy",
    reinforce_all = "reinforcement", create_new_fleet = "new fleets from the manager",
}
setmetatable(fc, { __index = function(_, k)
    return function()
        return "not done: " .. (NOT_DONE[k] or tostring(k))
    end
end })

return fc
