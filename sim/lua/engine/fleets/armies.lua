-- engine/fleets/armies.lua : transports landing their armies on a planet and the ground combat that
-- follows, as the game does them (4.5.2 Linux; the RE notes: scratchpad re4/SPEC_orders.md section
-- 2, summarised in docs/windows/fleet.md):
--
--   land_armies_order = { colony [resources] <base> }   (CLandArmiesFleetOrder)
--     tick    TickOrder (0x29b4370): away from the colony's planet its orbit sub-order; in orbit each
--             ship carrying an army (`army=`) that can land begins landing (CShip::BeginLandArmy)
--     done    IsDone (0x29b4720): in orbit, no sub-order, no ship still landing
--   landing   CShip::TickLandArmy (0x2aa4820): + 1 a day, landed at NShip.LANDING_TIME_DAYS (10):
--             LandArmyFinished -> NPlanetArmies::Add: the transport ship killed, the army's colony
--             set (its ship field gone), the army into the colony's ground combat when it is hostile
--   ground combat, daily (CColony::DailyUpdateSerialHandleCombat 0x287fe10, CGroundCombat::
--             DailyUpdateSerial 0x1c76c90): each living army of a side picks a random enemy and
--             deals its random damage (army type damage x [BASE_DAMAGE_MIN, BASE_DAMAGE_MAX]) times
--             the morale factor (DISENGAGED 0.15, broken 0.25, below LOW_MORALE_THRESHOLD 0.75),
--             morale damage the same x MORALE_DAMAGE_MULT; an army at 0 health dies; the attackers
--             alone left: the planet's controller the attacker (occupation; the owner stays), the
--             attackers its garrison; the defenders alone left: the combat over
--
--   armies.order(colony) -> the order block (CFleetLandArmiesCommand)
--   armies.check(fleet, planet) -> true | false, key (ListLandableArmies' keys)
--   armies.daily(host, date)   the landings and the ground combats (from engine.systems' fleets day)
--   armies.hostile(a, b)
-- Not done: the combat width (every army fights), the targeting weights (low health x2), the
-- disengage roll, collateral damage (planet devastation, pop kills), experience, generals, the
-- war's battle record, retreat, the messages; the armies' modifiers (damage, health, morale).

local world = require("engine.world")

local armies = { stats = { landed = 0, combats = 0, captured = 0, repelled = 0, killed = 0 } }
local S = armies.stats

local NO_ID = 4294967295
local ONE = 100000

local function unq(v) return v and (tostring(v):gsub('"', "")) or nil end
local function ref(v)
    local n = tonumber(v)
    return n and n ~= NO_ID and n or nil
end

local landing = {}   -- ship -> days landing (CShip +0xa98: not in the save [I])
armies.landing = landing

local DEF
local function defines()
    if DEF then return DEF end
    local defs = require("engine.defs")
    local function d(group, key, default)
        local g = defs.get("common/defines", group)
        return tonumber(g and defs.field(g.block, key)) or default
    end
    DEF = {
        LANDING = d("NShip", "LANDING_TIME_DAYS", 10),
        DMG_MIN = d("NArmy", "BASE_DAMAGE_MIN", 1.5), DMG_MAX = d("NArmy", "BASE_DAMAGE_MAX", 3.0),
        MORALE_MULT = d("NArmy", "MORALE_DAMAGE_MULT", 1.0),
        DISENGAGED = d("NArmy", "DISENGAGED_EFFECT", 0.15), BROKEN = d("NArmy", "BROKEN_MORALE_EFFECT", 0.25),
        LOW_THR = d("NArmy", "LOW_MORALE_THRESHOLD", 0.5), LOW = d("NArmy", "LOW_MORALE_EFFECT", 0.75),
        BASE_MORALE = d("NArmy", "BASE_MORALE", 200),
    }
    return DEF
end

local function army_type(a)
    local defs = require("engine.defs")
    local d = defs.get("common/armies", unq(world.field(a, "type")) or "")
    return d and d.block
end
local function type_num(a, key, default)
    local defs = require("engine.defs")
    local b = army_type(a)
    return tonumber(b and defs.field(b, key)) or default
end

-- the combat's hostility (the relation, war, a hostile country type)
function armies.hostile(a, b)
    return require("engine.fleets.combat").hostile(a, b)
end

local function colony_planet(cid) return world.colony_planet and world.colony_planet[cid] end

-- ListLandableArmies (0x293db50): the keys [V], the order of the tests [I]
function armies.check(fid, pid)
    local f = world.object("fleet", fid)
    local p = world.object("planet", pid)
    if not f or not p then return false, "FLEETORDER_LAND_ARMIES_NOT_COLONIZABLE" end
    local cid = world.planet_colony and world.planet_colony[pid]
    local c = cid and world.object("colony", cid)
    if not c then return false, "FLEETORDER_LAND_ARMIES_COLONIZE_FIRST" end
    if ref(world.field(c, "colonizing_species")) then return false, "FLEETORDER_LAND_ARMIES_COLONIZING" end
    local any = false
    for _, v in ipairs(world.list(world.field(f, "ships") or {})) do
        local s = world.object("ships", tonumber(v))
        if s and ref(world.field(s, "army")) then any = true end
    end
    if not any then return false, "FLEETORDER_LAND_ARMIES_NO_ARMIES" end
    return true
end

function armies.order(cid)
    local b = {}
    world.append(b, "colony", cid)
    return { { key = { text = "land_armies_order" }, op = "=", value = b } }
end

---------------------------------------------------------------- the ground combat

local function store()
    if world.ensure_store then pcall(world.ensure_store, "ground_combat") end
end

local function colony_armies(cid)
    local out = {}
    for _, aid in ipairs(world.all("army")) do
        local a = world.object("army", aid)
        if a and ref(world.field(a, "colony")) == cid and not ref(world.field(a, "ship")) then out[#out + 1] = aid end
    end
    return out
end

-- the colony's ground combat: { colony attackers defenders } (the save's ground_combat store)
local function combat_of(cid)
    local c = world.object("colony", cid)
    local gid = c and ref(world.field(c, "ground_combat"))
    return gid, gid and world.object("ground_combat", gid)
end

local function ids(gc, key)
    local out = {}
    for _, v in ipairs(world.list(world.field(gc, key) or {})) do out[#out + 1] = tonumber(v) end
    return out
end

local function start_combat(cid, attacker_army)
    store()
    local p = world.object("planet", colony_planet(cid))
    local controller = p and ref(world.field(p, "controller"))
    local b = {}
    world.append(b, "colony", cid)
    local att, def = {}, {}
    world.append_value(att, attacker_army)
    for _, aid in ipairs(colony_armies(cid)) do
        local a = world.object("army", aid)
        if a and ref(world.field(a, "owner")) == controller and aid ~= attacker_army then world.append_value(def, aid) end
    end
    world.append(b, "attackers", att)
    world.append(b, "defenders", def)
    local okc, create = pcall(require, "engine.fleets.create")
    local gid
    if okc and create.allocate then
        local id, entry = create.allocate("ground_combat")
        if id then create.place("ground_combat", id, entry, b) gid = id end
    end
    if not gid then return nil end
    world.set(world.object("colony", cid), "ground_combat", gid)
    for _, aid in ipairs(ids(b, "attackers")) do world.set(world.object("army", aid), "ground_combat", gid) end
    for _, aid in ipairs(ids(b, "defenders")) do world.set(world.object("army", aid), "ground_combat", gid) end
    S.combats = S.combats + 1
    return gid
end

-- NPlanetArmies::Add (0x1e4fe20): the army onto the colony (its ship killed) and into its combat
local function land(sid, s, cid)
    local aid = ref(world.field(s, "army"))
    local a = aid and world.object("army", aid)
    if not a then return end
    local e = world.entry(a, "ship")
    if e then world.remove_entry(a, e) end
    world.set(a, "colony", cid)
    S.landed = S.landed + 1
    local p = world.object("planet", colony_planet(cid))
    local controller = p and ref(world.field(p, "controller"))
    local own = ref(world.field(a, "owner"))
    if controller and own ~= controller and armies.hostile(own, controller) then
        local gid, gc = combat_of(cid)
        if gc then
            world.append_value(world.field(gc, "attackers"), aid)
            world.set(a, "ground_combat", gid)
        else
            start_combat(cid, aid)
        end
    end
    -- (the transport: the army's ship field cleared first, then the ship killed)
    local se = world.entry(s, "army")
    if se then world.remove_entry(s, se) end
    require("engine.fleets.destroy").ship(sid)
end

local function rnd() return (RUST.rand() % ONE) / ONE end

-- CArmy::DealDamage (0x222f570)
local function deal(a, target)
    local d = defines()
    local mult = 1
    if world.field(a, "disengaged") == "yes" then
        mult = d.DISENGAGED
    else
        local morale = tonumber(world.field(a, "morale")) or d.BASE_MORALE
        local max_morale = d.BASE_MORALE * type_num(a, "morale", 1)
        if morale <= 0 then mult = d.BROKEN elseif morale < max_morale * d.LOW_THR then mult = d.LOW end
    end
    local dmult = type_num(a, "damage", 1)
    local dmg = (d.DMG_MIN + (d.DMG_MAX - d.DMG_MIN) * rnd()) * dmult * mult
    local mdmg = dmg * d.MORALE_MULT * type_num(a, "morale_damage", 1)
    local h = (tonumber(world.field(target, "health")) or 0) - dmg
    world.set(target, "health", string.format("%.5f", math.max(0, h)))
    local m = (tonumber(world.field(target, "morale")) or 0) - mdmg
    world.set(target, "morale", string.format("%.5f", math.max(0, m)))
    return h <= 0
end

local function alive(aid)
    local a = world.object("army", aid)
    return a and (tonumber(world.field(a, "health")) or 0) > 0
end

local function kill_army(aid)
    world.remove("army", aid)
    S.killed = S.killed + 1
end

local function combat_day(gid, gc)
    local cid = ref(world.field(gc, "colony"))
    local att, def = ids(gc, "attackers"), ids(gc, "defenders")
    local dead = {}
    -- DailyUpdateInternalSide(attackers, true), then (defenders, false): each army a random target
    for _, side in ipairs({ { att, def }, { def, att } }) do
        local targets = {}
        for _, t in ipairs(side[2]) do if alive(t) and not dead[t] then targets[#targets + 1] = t end end
        for _, aid in ipairs(side[1]) do
            if alive(aid) and not dead[aid] and #targets > 0 then
                local pick = targets[(RUST.rand() % #targets) + 1]
                if deal(world.object("army", aid), world.object("army", pick)) then dead[pick] = true end
            end
        end
    end
    local function survivors(list)
        local out = {}
        for _, aid in ipairs(list) do
            if dead[aid] or not alive(aid) then kill_army(aid) else out[#out + 1] = aid end
        end
        return out
    end
    att, def = survivors(att), survivors(def)
    local function set(key, list)
        local l = {}
        for _, aid in ipairs(list) do world.append_value(l, aid) end
        local e = world.entry(gc, key)
        if e then world.remove_entry(gc, e) end
        world.append(gc, key, l)
    end
    set("attackers", att)
    set("defenders", def)
    if #att > 0 and #def > 0 then return end
    -- over: the attackers' win (occupation) or the defenders'
    local c = world.object("colony", cid)
    local pid = colony_planet(cid)
    if #def == 0 and #att > 0 then
        local a = world.object("army", att[1])
        local winner = a and ref(world.field(a, "owner"))
        if winner and pid then
            require("engine.script.objects_colony")
            require("engine.script.objects_countries").set_planet_controller(pid, winner)
        end
        S.captured = S.captured + 1
    else
        S.repelled = S.repelled + 1
    end
    for _, aid in ipairs(att) do
        local e = world.entry(world.object("army", aid), "ground_combat")
        if e then world.remove_entry(world.object("army", aid), e) end
    end
    for _, aid in ipairs(def) do
        local e = world.entry(world.object("army", aid), "ground_combat")
        if e then world.remove_entry(world.object("army", aid), e) end
    end
    if c then
        local e = world.entry(c, "ground_combat")
        if e then world.remove_entry(c, e) end
    end
    world.remove("ground_combat", gid)
end

---------------------------------------------------------------- the order

local order = {}
armies.order_type = order

local function colony_of(o) return ref(world.field(o.block, "colony")) end

function order.tick(o, fid, f, orders)
    local cid = colony_of(o)
    local pid = cid and colony_planet(cid)
    if not pid then return end
    if not orders.in_orbit_of(fid, f, pid) then
        orders.tick_orbit_sub_order(o, fid, f, pid)
        return
    end
    orders.clear_sub_order(o)
    for _, v in ipairs(world.list(world.field(f, "ships") or {})) do
        local sid = tonumber(v)
        local s = world.object("ships", sid)
        if s and ref(world.field(s, "army")) and not landing[sid] then landing[sid] = 0 end
    end
end
order.start = order.tick

function order.is_done(o, fid, f, orders)
    local cid = colony_of(o)
    local pid = cid and colony_planet(cid)
    if not pid then return true end
    if world.field(o.block, "sub_order") ~= nil or not orders.in_orbit_of(fid, f, pid) then return false end
    for _, v in ipairs(world.list(world.field(f, "ships") or {})) do
        if landing[tonumber(v)] then return false end
    end
    return true
end
function order.finish() end
function order.cancel(o, fid, f)
    for _, v in ipairs(world.list(world.field(f, "ships") or {})) do landing[tonumber(v)] = nil end
end

-- the day: the landings (CShip::TickLandArmy), then the ground combats
function armies.daily(host, date)
    local d = defines()
    local done = {}
    for sid, days in pairs(landing) do
        local s = world.object("ships", sid)
        if not s then
            landing[sid] = nil
        else
            days = days + 1
            landing[sid] = days
            if days >= d.LANDING then done[#done + 1] = sid end
        end
    end
    table.sort(done)
    for _, sid in ipairs(done) do
        landing[sid] = nil
        local s = world.object("ships", sid)
        local fid = s and ref(world.field(s, "fleet"))
        local f = fid and world.object("fleet", fid)
        local cur = f and world.field(f, "current_order")
        local lo = type(cur) == "table" and world.field(cur, "land_armies_order")
        local cid = type(lo) == "table" and ref(world.field(lo, "colony"))
        if s and cid then land(sid, s, cid) end
    end
    for _, gid in ipairs(world.all("ground_combat")) do
        local gc = world.object("ground_combat", gid)
        if gc then combat_day(gid, gc) end
    end
end

function armies.report()
    return string.format("armies: %d landed, %d ground combats, %d captured, %d repelled, %d armies killed",
        S.landed, S.combats, S.captured, S.repelled, S.killed)
end

return armies
