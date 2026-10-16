-- render/windows/fleet_rightclick.lua : a right click on the map with the player's fleets selected,
-- as the game decides it (CFleet::PerformAction 0x2dd36a0 and its PerformActionOnPlanet /
-- PerformActionOnFleet; docs/windows/fleet.md "Right click"), run in the simulation's runtime
-- (fleetwin.rs: App::fleet_right_click, Clock::query). Either an order at once, or the order
-- selector's entries (CMainGui's order_selector, main.gui), or a Yes/No popup.
--
--   local rc = require("render.windows.fleet_rightclick")
--   rc.at(fleets, target, mods) -> a result table (fleet_data.serialize crosses it to the GUI):
--     { done = "what was ordered" }                       the order posted
--     { menu = { entry, ... } }                           the order selector opened
--     { popup = { title, desc, run } }                    a Yes/No popup (yes: `run`)
--     { none = "why" }                                    nothing (the game's click_decline_action)
--   fleets: the selected fleets' ids (the player's mobile fleets, the selection's order)
--   target: { kind = "system" | "planet" | "fleet" | "point" | "none", id, x, y, origin,
--             view = "galaxy" | "system" }
--   mods:   { shift, ctrl, alt }
--   entry:  { key, names = { VAR = name block }, vars = { VAR = text }, cost = { res = n },
--             possible, run }   (key: the label's localisation key; run: rc.run's argument)
--   rc.run(run, shift, ctrl) -> text: an entry chosen (or a popup's yes): the commands posted,
--     the queue modifiers read at the click (COrderWindow's Click reads Shift / Ctrl then) [V]
--
-- The queue (CFleetFlyToCoordinatesCommand / CFleetOrbitPlanetCommand / CFollowFleetCommand
-- Execute [V]): no Shift -> the fleet's orders cleared, the order the only one; Shift -> appended;
-- Shift + Ctrl -> in front.

local world = require("engine.world")

local rc = {}

local NO_ID = 4294967295
local CLASS = { military = "shipclass_military", constructor = "shipclass_constructor",
                science = "shipclass_science_ship", colonizer = "shipclass_colonizer", transport = "shipclass_transport" }
-- EShipClass of the stations (engine.fleets.stations.CLASS)
local STATION = { mining = 5, research = 6, observation = 9, starbase = 10 }
local STATION_TOKEN = { [5] = "shipclass_mining_station", [6] = "shipclass_research_station",
                        [9] = "shipclass_observation_station", [10] = "shipclass_starbase" }

local function orders() return require("engine.fleets.orders") end
local function stations() return require("engine.fleets.stations") end
local function survey() return require("engine.fleets.survey") end

local function unquote(v) return v and (tostring(v):gsub('"', "")) or nil end

local function fleet(fid) return fid and world.object("fleet", fid) end
local function owner(fid) return world.fleet_owner and world.fleet_owner[fid] end
local function class_of(f) return unquote(world.field(f, "ship_class")) or CLASS.military end
local function prop(f, k) return world.path(f, "properties", k) == "yes" end

local function coord_of(b)
    if type(b) ~= "table" then return nil end
    return { x = tonumber(world.field(b, "x")) or 0, y = tonumber(world.field(b, "y")) or 0, origin = tonumber(world.field(b, "origin")) or NO_ID }
end
local function fleet_coord(f) return coord_of(world.path(f, "movement_manager", "coordinate")) end
local function planet_system(pid)
    local p = world.object("planet", pid)
    local c = p and coord_of(world.field(p, "coordinate"))
    return c and c.origin ~= NO_ID and c.origin or nil
end
local function name_block(obj)
    local ok, galaxy = pcall(require, "render.galaxy")
    local n = obj and world.field(obj, "name")
    return ok and n and galaxy.name_block(n) or nil
end

-- the player's own mobile fleets of the list (CanTakeOrders) [I: the controller the owner]
local function orderable(fids, player)
    local out = {}
    for _, fid in ipairs(fids or {}) do
        fid = tonumber(fid)
        local f = fleet(fid)
        if f and owner(fid) == player and prop(f, "mobile") and not prop(f, "station") then
            out[#out + 1] = fid
        end
    end
    return out
end

local function diplomacy()
    local ok, d = pcall(require, "engine.diplomacy")
    return ok and d or nil
end
-- IsHostile [I: a war, or the relation's `hostile` flag (space monsters, the pirates)]
local function hostile(us, other)
    if other == nil or other == us then return false end
    local d = diplomacy()
    if not d then return false end
    local rel = d.relation and d.relation(us, other)
    if rel and d.rflag and d.rflag(rel, "hostile") then return true end
    return d.at_war_with and d.at_war_with(us, other) or false
end

local function surveyed(country, pid)
    local ok, r = pcall(survey().has_surveyed, country, 0, pid)
    return ok and r or false
end
local function has_anomaly(pid)
    local p = world.object("planet", pid)
    return p ~= nil and world.field(p, "anomaly") ~= nil
end
local function system_bodies(sid)
    local g = world.object("galactic_object", sid)
    local out = {}
    for _, v in ipairs(g and world.fields(g, "planet") or {}) do
        local pid = tonumber(v)
        if pid and world.object("planet", pid) then out[#out + 1] = pid end
    end
    return out
end
local function star_of(sid)
    local st = stations()
    return st.star_of and st.star_of(sid) or system_bodies(sid)[1]
end
local function primary_starbase(sid)
    local st = stations()
    return st.primary_starbase and st.primary_starbase(sid) or nil
end

-- CalcMoveToOrbitable(system) [I]: the primary starbase's slot, else the star
local function system_orbitable(sid)
    local sb = primary_starbase(sid)
    if sb then return "starbase", sb end
    local star = star_of(sid)
    if star then return "planet", star end
    return nil
end

---------------------------------------------------------------- the commands

-- the queue mode: "replace" (no Shift), "append" (Shift), "front" (Shift + Ctrl)
local function mode(shift, ctrl)
    if shift then return ctrl and "front" or "append" end
    return "replace"
end
local function prepare(fid, m)
    if m == "replace" then orders().clear(fid) end
    return m == "front" and { front = true } or nil
end

local function orbit_block(kind, id)
    local b, ob = {}, {}
    world.append(ob, kind, id)
    world.append(b, "orbitable", ob)
    local sid = kind == "planet" and planet_system(id) or nil
    if kind == "starbase" then
        local s = world.object("starbases", id)
        local ship = s and tonumber(world.field(s, "station"))
        local sh = ship and world.object("ships", ship)
        local sf = sh and tonumber(world.field(sh, "fleet"))
        local c = sf and fleet_coord(fleet(sf))
        sid = c and c.origin
    end
    local star = sid and star_of(sid)
    if star then
        local sb = {}
        world.append(sb, "planet", star)
        world.append(b, "star", sb)
    end
    world.append(b, "merge_fleet", "none")
    return b
end

local COMMANDS = {}

-- CFleetOrbitPlanetCommand (a planet, a star or a starbase's slot)
function COMMANDS.orbit(fid, m, kind, id)
    local opts = prepare(fid, m)
    return orders().issue(fid, { { key = { text = "orbit_planet_order" }, op = "=", value = orbit_block(kind, tonumber(id)) } }, opts)
end
-- CFleetFlyToCoordinatesCommand
function COMMANDS.move(fid, m, x, y, origin)
    local opts = prepare(fid, m)
    return orders().move_to(fid, { x = tonumber(x) or 0, y = tonumber(y) or 0, origin = tonumber(origin) }, opts)
end
-- CFleetSurveyDepositHolderCommand on a planet
function COMMANDS.survey(fid, m, pid)
    local opts = prepare(fid, m)
    return orders().survey(fid, tonumber(pid), opts)
end
-- on a system: every unsurveyed body, the clicked one first (CSurveyDepositHoldersOrderWindow's
-- planet [V: the game's frame, "Surveying Toarus I (+5 Orders)"]), then nearest first
-- (engine.fleets.orders.survey_system skips those queued)
function COMMANDS.survey_system(fid, m, sid, first)
    local opts = prepare(fid, m)
    local id
    first = tonumber(first)
    if first and not surveyed(owner(fid), first) then
        id = orders().survey(fid, first, opts)
    end
    return orders().survey_system(fid, tonumber(sid), opts) or id
end
-- CFleetResearchAnomalyCommand
function COMMANDS.research(fid, m, pid)
    local opts = prepare(fid, m)
    return orders().research_anomaly(fid, tonumber(pid), opts)
end
-- CFleetBuildOrbitalStationCommand: a planet's station, or (system) one per body that can have one
function COMMANDS.build(fid, m, pid, class, system)
    local st = stations()
    local country = owner(fid)
    local opts = prepare(fid, m)
    class = tonumber(class)
    local targets = {}
    if system then
        for _, b in ipairs(system_bodies(tonumber(system))) do
            if st.can_build_station(country, b, class) then targets[#targets + 1] = b end
        end
    else
        targets[1] = tonumber(pid)
    end
    local last
    for _, b in ipairs(targets) do
        last = orders().issue(fid, st.build_order(b, class, country), opts) or last
    end
    return last
end
-- CFollowFleetCommand (attack: attack_when_in_range)
function COMMANDS.follow(fid, m, target, attack)
    local opts = prepare(fid, m)
    local t = fleet(tonumber(target))
    if not t then return false end
    local b = {}
    world.append(b, "fleet", tonumber(target))
    local c = fleet_coord(t) or { x = 0, y = 0, origin = NO_ID }
    local cb = {}
    world.append(cb, "x", c.x)
    world.append(cb, "y", c.y)
    world.append(cb, "origin", c.origin)
    world.append(b, "coordinate", cb)
    world.append(b, "has_triggered_message", "no")
    world.append(b, "attack_when_in_range", attack and "yes" or "no")
    world.append(b, "cancelled", "no")
    return orders().issue(fid, { { key = { text = "follow_order" }, op = "=", value = b } }, opts)
end
-- CSetHomeBaseCommand: the fleet's template's home_base = { orbitable = { starbase = id } }
function COMMANDS.home_base(fid, m, sb)
    local f = fleet(fid)
    local tid = f and tonumber(world.field(f, "fleet_template"))
    local t = tid and world.object("fleet_template", tid)
    if not t then return false end
    local hb, ob = {}, {}
    world.append(ob, "starbase", tonumber(sb))
    world.append(hb, "orbitable", ob)
    local e = world.entry(t, "home_base")
    if e then world.remove_entry(t, e) end
    world.append(t, "home_base", hb)
    return true
end

-- rc.run(run, shift, ctrl): run = { cmd, fleets = { ids }, args = { ... } }
function rc.run(run, shift, ctrl)
    local ok, r = pcall(function()
        local cmd = COMMANDS[run and run.cmd]
        if not cmd then return "not done: " .. tostring(run and run.cmd) end
        local m = mode(shift, ctrl)
        local out = {}
        local up = table.unpack or unpack
        local args = run.args or {}
        for _, fid in ipairs(run.fleets or {}) do
            local id = cmd(tonumber(fid), m, up(args, 1, tonumber(args.n) or #args))
            out[#out + 1] = tostring(fid) .. ":" .. tostring(id)
        end
        return "ok " .. run.cmd .. " (" .. m .. ") " .. table.concat(out, " ")
    end)
    return ok and r or ("error: " .. tostring(r))
end

---------------------------------------------------------------- the menu's entries

local function entry(key, run, opts)
    opts = opts or {}
    return { key = key, run = run, possible = opts.possible ~= false, names = opts.names, vars = opts.vars, cost = opts.cost }
end

local function run_of(cmd, fids, ...)
    -- (n: the arguments' count, a nil among them kept across fleet_data.serialize)
    return { cmd = cmd, fleets = fids, args = { n = select("#", ...), ... } }
end

local function station_cost(country, pid, class)
    local ok, c = pcall(stations().cost, country, pid, class)
    return ok and c or nil
end

-- a body's station entry (CBuildOrbitalStationOrderWindow) [I from the game's frames]: listed when
-- the body could ever take one (CanCreateOrbitalStation: the class's design, no station of it yet;
-- a mining or research station on a body whose deposit is of that class; an outpost on the
-- system's primary star; observation posts not modelled), possible (else crossed and disabled)
-- when it can be built now (CanBuildStation: surveyed, the resource known, the borders) and paid
local function station_listed(player, b, c, sid)
    local st = stations()
    if not st.can_create(player, b, c) then return false end
    if c == STATION.starbase then return star_of(sid) == b end
    if c == STATION.observation then return false end
    return st.orbital_class(b) == c
end
-- (and [I, the game's frame: both crossed in a system being surveyed, not the player's]: an
-- outpost only in a system every body of which is surveyed ("A System must be surveyed before it
-- can be claimed"), a mining or research station only in a system of the player's)
local function station_possible(player, b, c, cost)
    local st = stations()
    if not (st.can_build_station(player, b, c) and (cost == nil or st.can_afford(player, cost))) then
        return false
    end
    local sid = planet_system(b)
    if c == STATION.starbase then
        for _, o in ipairs(system_bodies(sid)) do
            if not surveyed(player, o) then return false end
        end
        return true
    end
    return world.system_owner ~= nil and world.system_owner[sid] == player
end

-- PerformActionOnPlanet (0x2dd5b20)
local function on_planet(fids, pid, mods, player)
    local menu = {}
    local single = #fids == 1
    local f = fleet(fids[1])
    local class = class_of(f)
    local sid = planet_system(pid)
    if not sid then return { none = "no system" } end
    -- A: a single civilian ship (no Alt): its class's entries, then Enter Orbit last [V]
    if single and prop(f, "civilian") and not mods.alt then
        if class == CLASS.constructor then
            if surveyed(player, pid) then
                for _, c in ipairs({ STATION.mining, STATION.research, STATION.observation, STATION.starbase }) do
                    if station_listed(player, pid, c, sid) then
                        local cost = station_cost(player, pid, c)
                        menu[#menu + 1] = entry("FLEETORDER_BUILD_CURRENT_" .. STATION_TOKEN[c] .. "_BUTTON",
                            run_of("build", fids, pid, c), { cost = cost, possible = station_possible(player, pid, c, cost) })
                    end
                end
            end
        elseif class == CLASS.colonizer then
            if surveyed(player, pid) and stations().colonizable(pid) then
                -- CColonizeOrderWindow opens the colonise view (the species): not done here
                menu[#menu + 1] = entry("FLEETORDER_COLONIZE_BUTTON", run_of("colonize", fids, pid), { possible = false })
            end
        elseif class == CLASS.science then
            if not surveyed(player, pid) then
                menu[#menu + 1] = entry("FLEETORDER_SURVEY_BUTTON", run_of("survey", fids, pid))
                menu[#menu + 1] = entry("FLEETORDER_SURVEY_ALL_BUTTON", run_of("survey_system", fids, sid, pid))
            elseif has_anomaly(pid) then
                menu[#menu + 1] = entry("FLEETORDER_RESEARCH_BUTTON", run_of("research", fids, pid))
            end
        end
        menu[#menu + 1] = entry("FLEETORDER_ORBIT_BUTTON", run_of("orbit", fids, "planet", pid))
        return { menu = menu }
    end
    -- B: unsurveyed and every fleet a science ship: Survey System + Enter Orbit [V]
    local all_science = true
    for _, fid in ipairs(fids) do
        all_science = all_science and class_of(fleet(fid)) == CLASS.science
    end
    if all_science and not surveyed(player, pid) then
        return { menu = { entry("FLEETORDER_SURVEY_ALL_BUTTON", run_of("survey_system", fids, sid, pid)),
                          entry("FLEETORDER_ORBIT_BUTTON", run_of("orbit", fids, "planet", pid)) } }
    end
    -- a single transport: Land Armies (not done here) + Enter Orbit [V]
    if single and class == CLASS.transport then
        return { menu = { entry("FLEETORDER_LAND_ARMIES_TITLE", run_of("land_armies", fids, pid), { possible = false }),
                          entry("FLEETORDER_ORBIT_BUTTON", run_of("orbit", fids, "planet", pid)) } }
    end
    -- military on a colony whose controller is not hostile: the bombardment popup [V]
    local p = world.object("planet", pid)
    local controller = p and tonumber(world.field(p, "controller") or world.field(p, "owner"))
    if class == CLASS.military and controller and controller ~= player and not hostile(player, controller)
        and world.field(p, "colony") ~= nil then
        return { popup = { title = "FLEETORDER_ORBIT_PLANET_BOMBARDMENT_TITLE", desc = "FLEETORDER_ORBIT_PLANET_BOMBARDMENT_DESC",
                           run = run_of("orbit", fids, "planet", pid) } }
    end
    -- otherwise: an orbit, at once, per fleet
    return { direct = run_of("orbit", fids, "planet", pid) }
end

-- PerformActionOnFleet (0x2dd7190)
local function on_fleet(fids, tid, mods, player)
    local t = fleet(tid)
    if not t or #world.list(world.field(t, "ships") or {}) == 0 then return { none = "no ships" } end
    local f = fleet(fids[1])
    local class = class_of(f)
    local towner = owner(tid)
    local others = {}
    for _, fid in ipairs(fids) do
        if fid ~= tid then others[#others + 1] = fid end
    end
    if #others == 0 then return { none = "itself" } end
    -- military: follow and attack another country's fleet; a neutral one after the popup [V]
    if class == CLASS.military and towner ~= player then
        if hostile(player, towner) then
            return { direct = run_of("follow", others, tid, true) }
        end
        if towner ~= nil then
            return { popup = { title = "FLEETORDER_FOLLOW_AND_ATTACK_TITLE", desc = "FLEETORDER_FOLLOW_AND_ATTACK_DESC",
                               run = run_of("follow", others, tid, true) } }
        end
    end
    -- a static starbase: Enter Orbit, Set home base [V; the fleet upgrade entry not done here]
    if prop(t, "station") and class_of(t) == "shipclass_starbase" then
        -- the starbase whose station ship is the fleet's
        local ships, sb = {}, nil
        for _, s in ipairs(world.list(world.field(t, "ships") or {})) do ships[tonumber(s)] = true end
        for _, sbid in ipairs(world.all("starbases")) do
            local o = world.object("starbases", sbid)
            if o and ships[tonumber(world.field(o, "station"))] then
                sb = sbid
                break
            end
        end
        if sb then
            local menu = { entry("FLEETORDER_ORBIT_BUTTON", run_of("orbit", others, "starbase", sb)) }
            if towner == player and world.field(f, "fleet_template") then
                -- the starbase's name: "$PLANET$ Station", the system's star [V: the game's frame]
                local c = fleet_coord(t)
                local star = c and star_of(c.origin)
                local nested = { HOMEBASE = { key = "STARBASE_STATION_NAME_FORMAT_NON_PRIMARY",
                                              names = { PLANET = name_block(star and world.object("planet", star)) } } }
                local e = entry("FLEETORDER_SET_HOMEBASE", run_of("home_base", others, sb))
                e.nested = nested
                menu[#menu + 1] = e
                -- CUpgradeFleetOrderWindow (helper 0x2dd9e30 [I]): the upgrade order not done here
                menu[#menu + 1] = entry("FLEETORDER_UPGRADE_FLEET_BUTTON", run_of("upgrade", others, sb))
            end
            return { menu = menu }
        end
    end
    -- otherwise: follow [V]
    return { direct = run_of("follow", others, tid, false) }
end

-- a system target (galaxy view's star, a system label) or a point of a system (system view)
local function on_system(fids, target, mods, player)
    local sid = target.kind == "system" and target.id or nil
    local single = #fids == 1
    local menu = {}
    local f = fleet(fids[1])
    local class = class_of(f)
    if sid and not mods.alt then
        if single and class == CLASS.science then
            local unsurveyed = false
            for _, b in ipairs(system_bodies(sid)) do
                unsurveyed = unsurveyed or not surveyed(player, b)
            end
            if unsurveyed then menu[#menu + 1] = entry("FLEETORDER_SURVEY_ALL_BUTTON", run_of("survey_system", fids, sid)) end
        elseif single and class == CLASS.constructor then
            -- (with intel on the system [V]; a class listed when a body is, possible when one is:
            -- its cost that body's [I])
            local listed, can = {}, {}
            for _, b in ipairs(system_bodies(sid)) do
                if surveyed(player, b) then
                    for _, c in ipairs({ STATION.mining, STATION.research, STATION.observation, STATION.starbase }) do
                        if station_listed(player, b, c, sid) then
                            listed[c] = listed[c] or b
                            if not can[c] and station_possible(player, b, c, station_cost(player, b, c)) then can[c] = b end
                        end
                    end
                end
            end
            for _, c in ipairs({ STATION.mining, STATION.research, STATION.observation, STATION.starbase }) do
                local b = can[c] or listed[c]
                if b then
                    menu[#menu + 1] = entry("FLEETORDER_MULTI_BUILD_CURRENT_" .. STATION_TOKEN[c] .. "_BUTTON",
                        c == STATION.starbase and run_of("build", fids, b, c) or run_of("build", fids, nil, c, sid),
                        { cost = station_cost(player, b, c), possible = can[c] ~= nil })
                end
            end
        elseif not single and class == CLASS.science then
            local all = true
            for _, fid in ipairs(fids) do all = all and class_of(fleet(fid)) == CLASS.science end
            local unsurveyed = false
            for _, b in ipairs(system_bodies(sid)) do unsurveyed = unsurveyed or not surveyed(player, b) end
            if all and unsurveyed then menu[#menu + 1] = entry("FLEETORDER_SURVEY_ALL_BUTTON", run_of("survey_system", fids, sid)) end
        end
    end
    -- the move: to the system's orbitable (galaxy) or the clicked point (system view)
    local move
    if sid then
        local k, id = system_orbitable(sid)
        move = k and run_of("orbit", fids, k, id) or run_of("move", fids, 0, 0, sid)
    elseif target.kind == "point" then
        move = run_of("move", fids, target.x, target.y, target.origin)
    else
        return { none = "empty galaxy space" }
    end
    if #menu > 0 then
        -- "Move Here" first ("Explore System" without intel: [I] not read here)
        table.insert(menu, 1, entry("FLEETORDER_MOVE_BUTTON", move))
        return { menu = menu }
    end
    return { direct = move }
end

function rc.at(fids, target, mods)
    local ok, r = pcall(function()
        local player = require("render.windows.fleet_data").player()
        mods = mods or {}
        fids = orderable(fids, player)
        if #fids == 0 then return { none = "no fleet of the player's" } end
        target = target or {}
        -- a ship: its fleet
        if target.kind == "ship" then
            local s = world.object("ships", tonumber(target.id))
            target = { kind = "fleet", id = s and tonumber(world.field(s, "fleet")) }
        end
        local res
        if target.kind == "planet" and target.id then
            res = on_planet(fids, tonumber(target.id), mods, player)
        elseif target.kind == "fleet" and target.id then
            res = on_fleet(fids, tonumber(target.id), mods, player)
        else
            res = on_system(fids, target, mods, player)
        end
        if res.direct then
            return { done = rc.run(res.direct, mods.shift, mods.ctrl) }
        end
        if res.menu and #res.menu == 0 then return { none = "an empty menu" } end
        return res
    end)
    if not ok then return { none = "error: " .. tostring(r) } end
    return r
end

rc.COMMANDS = COMMANDS

return rc
