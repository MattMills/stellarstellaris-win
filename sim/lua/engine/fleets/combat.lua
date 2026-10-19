-- engine/fleets/combat.lua : space combat, the way the game's micro tick runs it (4.5.2 Linux; the
-- RE notes: scratchpad re5/SPEC_combat.md, summarised in docs/windows/fleet.md "Combat"):
--
--   combat.tick(host, date)          one micro tick (10 a day), from engine.systems' micro.update:
--                                    detection, then the ship pool (UpdateShipParallel: one global
--                                    draw per ship of the store, every tick; skipped, not drawn, with
--                                    no fleet in combat: its values seed only those), then the shots
--   combat.report()
--
-- What it does, in the game's order (CGameState::MicroUpdate 0x1b15b10):
--   1. detection (CheckForNewCombatsParallel 0x297a740) for every fleet: the fleets of its system
--      that are another's, a damage dealer on one side, hostile (CCountry::IsHostile [I]: a war, the
--      relation's `hostile`), or the target of a follow-and-attack order; in range: r = max(attack
--      radii) x COMBAT_DETECT_RANGE_MULT, at least COMBAT_DETECT_RANGE_MIN; a new combat within r, a
--      kept one within 2r, two military fleets already fighting kept without the test [V]
--   2. the lists applied (CheckForNewCombats 0x297d8b0), symmetric (AddInCombatWith): a fleet's
--      first combat draws one `targeting` value per ship (CShip::OnCombatStarted) [V]; a fleet left
--      with none ends its combat (OnCombatEnded: targeting 1, disengaged no) [V]
--   3. the weapons (CWeaponComponent::MicroUpdateTargetingParallel 0x23049b0): windup and cooldown
--      in micro ticks on private streams (CCrudeRandom chains: the ship's seed, a section's, a
--      weapon's) [V]; the target the best scored enemy in range (CalcBestWeaponComponentTarget:
--      average damage x chance to hit x weight; no draw) [V]
--   4. the shots (CWeaponComponent::Shoot 0x2303d50), ship by ship: one hit roll (evaded below
--      evasion - tracking, hit below accuracy), on a hit the damage roll (NCombatRules::CalcDamage
--      0x22a2cb0: shields, then armour, then hull, with the penetrations and multipliers) [V]
--   5. the target's damage (CShip::TakeDamage 0x2ab8670): a ship with disable_at_health disabled
--      at it (starbases), else destroyed at 0 hull, else the disengage roll (a fleet that can FTL,
--      below SHIP_DISENGAGE_HEALTH_THRESHOLD) [V]; destroyed ships removed at the tick's end.
-- Not done: combat movement (the fleets stay where combat found them; ranges are the fleets'
-- distances) [I], the ships' main targets and their draws (CShipTargeting), missiles, strike
-- craft, point defence, collateral and chain damage, on_hit effects, capture and admiral-death
-- rolls, the weapon-tag and territory modifiers, regeneration in combat, emergency FTL, MIA,
-- bombardment, the inactivity disengage, debris, war exhaustion, the battle events' scopes.

local ffi = require("ffi")
local bit = require("bit")
local world = require("engine.world")

local combat = {
    stats = { ticks = 0, started = 0, ended = 0, shots = 0, hits = 0, evaded = 0, missed = 0,
              destroyed = 0, disabled = 0, disengaged = 0 },
    -- each fleet's combat so far (SFleetCombatStatsData, CFleet +0x988: its damage dealt and its
    -- shots' outcomes, what the combat view's Damage Output shows), anew when its combat starts;
    -- not written to the save [I]
    fleet_stats = {},
}
local S = combat.stats

local NO_ID = 4294967295
local ONE = 100000

local function unq(v) return v and (tostring(v):gsub('"', "")) or nil end
local function num(v) return tonumber(v) end

---------------------------------------------------------------- the game's random streams

local U64 = ffi.typeof("uint64_t")
local M32 = 4294967296
local function u32(x) return x % M32 end
local function mul(a, b) return tonumber((U64(a) * U64(b)) % 4294967296ULL) end
local function xor(a, b) return u32(bit.bxor(a, b)) end
local function shr(a, n) return u32(bit.rshift(a, n)) end
local function shl(a, n) return u32(bit.lshift(a, n)) end

-- CNoiseRandom (0x42359d0): the hash of (n, seed) before its last step (RUST.noise_raw, the
-- engine's own: sim/src/rng.rs; the Lua one when it is missing); GetInteger's and GetNext's
local function hash(n, seed)
    if RUST and RUST.noise_raw then return RUST.noise_raw(n, seed) end
    local x = u32(mul(n, 0xB5297A4D) + seed)
    x = xor(x, shr(x, 8))
    x = u32(x + 0x68E31DA4)
    x = xor(x, shl(x, 8))
    x = mul(x, 0x1B56C4E9)
    x = xor(x, shr(x, 8))
    x = mul(x, 0x92D68CA2)
    return x
end
local function get_integer(r)
    local x = hash(r.n, r.seed)
    r.n = u32(r.n + 1)
    return xor(bit.band(x, 0x7FFFFFFE), shr(x, 8))
end
-- CCrudeRandom(seed) (0x422b070): { n = GetNext({ n = seed, seed = 0x5EA6BA9F }), seed = 0 }
local function crude(seed)
    local x = hash(u32(seed), 0x5EA6BA9F)
    return { n = xor(x, shr(x, 8)), seed = 0 }
end

-- the global stream (RUST.rand: CRandom::_Random's GetInteger)
local function global_int() return RUST.rand() end
local function global_fixed() return (global_int() % ONE) / ONE end

---------------------------------------------------------------- definitions

local DEF
local function defines()
    if DEF then return DEF end
    local defs = require("engine.defs")
    local function d(group, key, default)
        local g = defs.get("common/defines", group)
        local v = g and defs.field(g.block, key)
        return tonumber(v) or default
    end
    DEF = {
        DETECT_MULT = d("NShip", "COMBAT_DETECT_RANGE_MULT", 1.05),
        DETECT_MIN = d("NShip", "COMBAT_DETECT_RANGE_MIN", 10),
        AREA_MIN = d("NShip", "COMBAT_AREA_MIN_ATTACK_RADIUS", 0.2),
        SHIELD_RECHARGE = d("NShip", "SHIELD_RECHARGE_TICKS", 20),
        DIS_THRESHOLD = d("NShip", "SHIP_DISENGAGE_HEALTH_THRESHOLD", 0.5),
        DIS_BASE = d("NShip", "SHIP_DISENGAGE_BASE_CHANCE", 0.75),
        DIS_MAX = d("NShip", "SHIP_DISENGAGE_MAX_CHANCE", 0.5),
        DIS_FRIENDLY = d("NShip", "SHIP_DISENGAGE_FRIENDLY_TERRITORY_MULT", 1.25),
        MAX_EVASION = d("NShip", "SHIP_MAX_EVASION", 0.9),
        MAX_DAMAGE_SCALING = d("NShip", "MAX_DAMAGE_SCALING", 100),
        UNARMED_WEIGHT = d("NShip", "COMBAT_SHIP_UNARMED_TARGETING_WEIGHT", 0.005),
        CURRENT_TARGET = d("NShip", "SHIP_CURRENT_TARGET_MULTIPLIER", 1.1),
    }
    return DEF
end

-- common/component_templates/weapon_components.csv: the weapons' stats by key
local WEAPONS
local function weapons()
    if WEAPONS then return WEAPONS end
    WEAPONS = {}
    local ok, defs = pcall(require, "engine.defs")
    local rel = "common/component_templates/weapon_components.csv"
    local path = ok and defs.fs and defs.fs:path(rel)
    local f = path and io.open(path, "r")
    if not f then return WEAPONS end
    local cols
    for line in f:lines() do
        if not line:match("^#") then
            local t = {}
            for c in (line .. ";"):gmatch("([^;]*);") do t[#t + 1] = c end
            if not cols and t[1] == "key" then
                cols = {}
                for i, c in ipairs(t) do cols[c] = i end
            elseif cols and t[1] and t[1] ~= "" then
                local function v(name) return tonumber(t[cols[name] or 0]) or 0 end
                WEAPONS[t[1]] = {
                    min = v("min_damage"), max = v("max_damage"), hull = v("hull_damage"),
                    shield = v("shield_damage"), shield_pen = v("shield_penetration"), armor = v("armor_damage"),
                    armor_pen = v("armor_penetration"), windup_min = v("min_windup"), windup_max = v("max_windup"),
                    cooldown = v("cooldown"), range = v("range"), accuracy = v("accuracy"), tracking = v("tracking"),
                    size_factor = v("size_damage_factor"), missile = v("missile_speed") > 0,
                }
            end
        end
    end
    f:close()
    return WEAPONS
end

local function modifiers(kind, id)
    local economy = package.loaded["engine.economy"]
    local ok, M = pcall(function() return economy and economy.modifiers and economy.modifiers(kind, id) end)
    return ok and M or {}
end

-- a ship size's evasion (common/ship_sizes: modifier ship_evasion_add, a scripted variable) [V the
-- data; I that the ship's own modifiers add the rest]
local size_evasion = {}
local function ship_size_of(sid)
    local s = world.object("ships", sid)
    local sdi = s and world.field(s, "ship_design_implementation")
    local did = type(sdi) == "table" and num(world.field(sdi, "design"))
    local ok, create = pcall(require, "engine.fleets.create")
    local info = ok and did and create.design_info(did, num(world.field(sdi, "growth_stage")) or 0)
    return info and info.size, info
end
local function base_evasion(size)
    if not size then return 0 end
    if size_evasion[size] == nil then
        local defs = require("engine.defs")
        local d = defs.get("common/ship_sizes", size)
        local m = d and defs.field(d.block, "modifier")
        local v = type(m) == "table" and defs.field(m, "ship_evasion_add")
        local n = tonumber(v)
        if not n and type(v) == "string" and d.file then
            local okc, create = pcall(require, "engine.fleets.create")
            n = okc and create.number and create.number(v, d.file) or nil
        end
        size_evasion[size] = n or 0
    end
    return size_evasion[size]
end

---------------------------------------------------------------- fleets and ships

local function fleet(fid) return fid and world.object("fleet", fid) end
local function owner(fid) return world.fleet_owner and world.fleet_owner[fid] end
local function prop(f, k) return world.path(f, "properties", k) == "yes" end
local function coord(f)
    local c = world.path(f, "movement_manager", "coordinate")
    if type(c) ~= "table" then return nil end
    return { x = num(world.field(c, "x")) or 0, y = num(world.field(c, "y")) or 0, origin = num(world.field(c, "origin")) or NO_ID }
end
local function ship_ids(f)
    local out = {}
    for _, v in ipairs(world.list(world.field(f, "ships") or {})) do out[#out + 1] = tonumber(v) end
    return out
end
local function dist2(a, b)
    if not a or not b or a.origin ~= b.origin then return math.huge end
    local dx, dy = a.x - b.x, a.y - b.y
    if math.abs(dx) < 0.1 and math.abs(dy) < 0.1 then return 0 end
    return dx * dx + dy * dy
end

-- a ship's weapon entries (section = { weapon = { index template ... } }), in section then slot order
local function ship_weapons(s)
    local out = {}
    for _, sec in ipairs(world.fields(s, "section")) do
        if type(sec) == "table" then
            for _, w in ipairs(world.fields(sec, "weapon")) do
                if type(w) == "table" then
                    local key = unq(world.field(w, "template"))
                    local t = key and weapons()[key]
                    if t and not t.missile then out[#out + 1] = { block = w, t = t, section = sec } end
                end
            end
        end
    end
    return out
end

local function sections(s)
    local out = {}
    for _, sec in ipairs(world.fields(s, "section")) do
        if type(sec) == "table" then
            local ws = {}
            for _, w in ipairs(world.fields(sec, "weapon")) do
                if type(w) == "table" then
                    local key = unq(world.field(w, "template"))
                    local t = key and weapons()[key]
                    ws[#ws + 1] = { block = w, t = t }
                end
            end
            out[#out + 1] = ws
        end
    end
    return out
end

local cache = {}   -- per tick: fleet -> { radius, armed }
local function fleet_info(fid, f)
    local c = cache[fid]
    if c then return c end
    local radius, armed = 0, false
    for _, sid in ipairs(ship_ids(f)) do
        local s = world.object("ships", sid)
        if s then
            local M = modifiers("ship", sid)
            for _, w in ipairs(ship_weapons(s)) do
                armed = true
                local r = w.t.range * (1 + (M.ship_weapon_range_mult or 0))
                if r > radius then radius = r end
            end
        end
    end
    c = { radius = math.max(radius, defines().AREA_MIN), armed = armed }
    cache[fid] = c
    return c
end

local function in_combat_with(f)
    local out = {}
    local list = world.path(f, "combat", "in_combat_with")
    for _, e in ipairs(world.blocks(type(list) == "table" and list or {})) do
        local id = num(world.field(e, "fleet"))
        if id then out[#out + 1] = id end
    end
    return out
end
local function has_combat(f) return #in_combat_with(f) > 0 end
combat.in_combat_with = in_combat_with

-- the country type's faction { hostile = yes } (space fauna, marauders' raiders...) [I]
local type_hostile = {}
local function hostile_type(c)
    local co = c and world.object("country", c)
    local t = co and unq(world.field(co, "type"))
    if not t then return false end
    if type_hostile[t] == nil then
        local okd, defs = pcall(require, "engine.defs")
        local d = okd and defs.get("common/country_types", t)
        local fac = d and defs.field(d.block, "faction")
        type_hostile[t] = type(fac) == "table" and defs.field(fac, "hostile") == "yes" or false
    end
    return type_hostile[t]
end

-- CCountry::IsHostileCached: the relation's `hostile`, at war, or a hostile country type [I]
local function hostile(a, b)
    if a == nil or b == nil or a == b then return false end
    local ok, o = pcall(require, "engine.ai.opinion")
    if ok then
        if o.rflag(o.relation(a, b), "hostile") or o.rflag(o.relation(b, a), "hostile") then return true end
        if o.at_war(a, b) then return true end
    end
    return hostile_type(a) or hostile_type(b)
end
combat.hostile = hostile

-- the follow-and-attack target of a fleet's current order (follow_order attack_when_in_range)
local function attack_target(f)
    local cur = world.field(f, "current_order")
    local fo = type(cur) == "table" and world.field(cur, "follow_order")
    if type(fo) == "table" and world.field(fo, "attack_when_in_range") == "yes" then
        return num(world.field(fo, "fleet"))
    end
    return nil
end

local function movement_state(f)
    return unq(world.path(f, "movement_manager", "state")) or "move_idle"
end
local function can_fight(f)
    local st = movement_state(f)
    if st == "move_wind_up" or st == "move_galaxy" or st == "move_in_ftl" then return false end
    if world.path(f, "properties", "valid_for_combat") == "no" then return false end
    return #ship_ids(f) > 0 and not prop(f, "disabled")
end
local function military(f) return unq(world.field(f, "ship_class")) == "shipclass_military" end
local function unarmed_station(fid, f)
    return prop(f, "station") and unq(world.field(f, "ship_class")) ~= "shipclass_starbase" and not fleet_info(fid, f).armed
end

---------------------------------------------------------------- 1, 2: detection and the lists

local function candidates(fid, f, by_system, inlist)
    local out = {}
    local ca = coord(f)
    local others = false
    for _, oid in ipairs(by_system[ca and ca.origin or -1] or {}) do
        if oid ~= fid and owner(oid) ~= owner(fid) then others = true break end
    end
    -- (nothing to check without another's fleet in the system: the weapons not read)
    if not others then return out end
    if not can_fight(f) then return nil end
    local A = fleet_info(fid, f)
    local tgt = attack_target(f)
    for _, oid in ipairs(by_system[ca and ca.origin or -1] or {}) do
        local o = oid ~= fid and fleet(oid)
        if o and can_fight(o) and owner(oid) ~= owner(fid) then
            local B = fleet_info(oid, o)
            local ok = A.armed or B.armed
            if ok and unarmed_station(fid, f) and attack_target(o) ~= fid then ok = false end
            if ok and unarmed_station(oid, o) and tgt ~= oid then ok = false end
            if ok then
                local listed = inlist[oid]
                ok = tgt == oid or (attack_target(o) == fid and listed) or hostile(owner(fid), owner(oid))
                if ok and not (listed and military(f) and military(o)) then
                    local r = math.max(math.max(A.radius, B.radius) * defines().DETECT_MULT, defines().DETECT_MIN)
                    local d2 = dist2(ca, coord(o))
                    local need = listed and (2 * r) ^ 2 or r * r
                    ok = d2 < need
                end
            end
            if ok then out[#out + 1] = oid end
        end
    end
    return out
end

local function combat_block(f)
    local c = world.field(f, "combat")
    if type(c) ~= "table" then
        c = world.child(f, "combat")
    end
    return c
end

local function set_list(f, ids)
    local c = combat_block(f)
    local e = world.entry(c, "in_combat_with")
    if e then world.remove_entry(c, e) end
    if #ids == 0 then return end
    local l = {}
    for _, id in ipairs(ids) do
        local b = {}
        world.append(b, "fleet", id)
        world.push(l, b)
    end
    world.insert(c, 1, "in_combat_with", l)
end

local function on_action(name, this, from)
    local ok, create = pcall(require, "engine.fleets.create")
    if ok and create.on_action then pcall(create.on_action, name, this, from) end
end

-- CFleet::OnCombatStarted -> CShip::OnCombatStarted: disengagement_opportunities_used 0, targeting a
-- global draw per ship [V]
local function combat_started(fid, f, other, date)
    S.started = S.started + 1
    combat.fleet_stats[fid] = { hull = 0, armor = 0, shields = 0, hits = 0, missed = 0, evaded = 0 }
    local c = combat_block(f)
    local today = date and date.year and string.format("%d.%02d.%02d", date.year, date.month or 1, date.day or 1) or nil
    if today then world.set(c, "start_date", today, true) end
    for _, sid in ipairs(ship_ids(f)) do
        local s = world.object("ships", sid)
        if s then
            world.set(s, "disengagement_opportunities_used", 0)
            world.set(s, "targeting", string.format("%.5f", global_fixed()))
        end
    end
    on_action("on_entering_battle", { "fleet", fid }, { "fleet", other })
end

-- CFleet::OnCombatEnded: every ship not disengaged, its targeting back to 1 [V]
local function combat_ended(fid, f)
    S.ended = S.ended + 1
    for _, sid in ipairs(ship_ids(f)) do
        local s = world.object("ships", sid)
        if s then
            local e = world.entry(s, "targeting")
            if e then world.remove_entry(s, e) end
            local d = world.entry(s, "disengaged")
            if d then world.remove_entry(s, d) end
        end
    end
end

---------------------------------------------------------------- 3, 4, 5: weapons and damage

-- a ship's defence (SDefenseInfo, BuildDefenseInfo 0x2ab4410) and evasion
local function defence(sid, s)
    local M = modifiers("ship", sid)
    local size = ship_size_of(sid)
    local ev = (base_evasion(size) + (M.ship_evasion_add or 0)) / 100 * (1 + (M.ship_evasion_mult or 0))
    return {
        shield = num(world.field(s, "shield_hitpoints")) or 0, armor = num(world.field(s, "armor_hitpoints")) or 0,
        hull = num(world.field(s, "hitpoints")) or 0, max_hull = num(world.field(s, "max_hitpoints")) or 1,
        shield_hard = math.max(0, math.min(1, M.ship_shield_hardening_add or 0)),
        armor_hard = math.max(0, math.min(1, M.ship_armor_hardening_add or 0)),
        red_add = math.max(0, math.min(1, M.ship_damage_reduction_add or 0)),
        red_mult = math.max(0, math.min(1, M.ship_damage_reduction_mult or 0)),
        evasion = math.max(0, math.min(defines().MAX_EVASION, ev)),
        size_value = 1,
    }
end

-- NCombatRules::CalcDamage (0x22a2cb0): roll nil = the average (scoring)
local function calc_damage(D, t, roll)
    local dmg
    if roll then
        dmg = t.min + (t.max - t.min) * ((math.abs(roll) % 1000) * 100) / ONE
    else
        dmg = t.min + (t.max - t.min) / 2
    end
    dmg = math.max(0, dmg * (1 - D.red_mult) - D.red_add)
    if t.size_factor > 0 then
        dmg = dmg * (1 + t.size_factor * math.max(1, math.min(D.size_value, defines().MAX_DAMAGE_SCALING)))
    end
    local rem, shield, armor = dmg, 0, 0
    if D.shield > 0 then
        local sp = math.max(0, math.min(1, t.shield_pen - D.shield_hard))
        local to = dmg * (1 - sp)
        rem = rem - math.min(to, D.shield)
        shield = to * t.shield
    end
    if D.armor > 0 then
        local ap = math.max(0, math.min(1, t.armor_pen - D.armor_hard))
        local to = rem * (1 - ap)
        rem = rem - math.min(to, D.armor)
        armor = to * t.armor
    end
    return { hull = math.max(0, rem * t.hull), armor = math.max(0, armor), shield = math.max(0, shield) }
end

local function accuracy(t, M) return (t.accuracy + (M.ship_accuracy_add or 0) / 100) * (1 + (M.ship_accuracy_mult or 0)) end
local function tracking(t, M) return (t.tracking + (M.ship_tracking_add or 0) / 100) * (1 + (M.ship_tracking_mult or 0)) end

-- CalcBestWeaponComponentTarget: the best scored enemy ship in range, the current one x1.1 [V]
local function best_target(shooter, sc, w, M, enemies, current)
    local best, bs
    local rmax = w.t.range * (1 + (M.ship_weapon_range_mult or 0))
    for _, e in ipairs(enemies) do
        if e.alive and not e.disengaged and dist2(sc, e.coord) <= rmax * rmax then
            local res = calc_damage(e.D, w.t, nil)
            local hit = math.max(0, math.min(1, accuracy(w.t, M) - math.max(0, math.min(1, e.D.evasion - tracking(w.t, M)))))
            local score = (res.hull + res.armor + res.shield) * hit * e.weight
            if res.hull >= e.D.hull then score = score * 1.5 end
            if not e.armed then score = score * defines().UNARMED_WEIGHT end
            if e.sid == current then score = score * defines().CURRENT_TARGET end
            if not bs or score > bs then best, bs = e, score end
        end
    end
    return best
end

-- CShip::TakeDamage (0x2ab8670)
local function take_damage(e, res, attacker_fid, killed)
    local s = world.object("ships", e.sid)
    if not s or not e.alive then return end
    local hp_before = e.D.hull / math.max(e.D.max_hull, 1)
    if e.D.shield >= 0 and res.shield >= e.D.shield and res.shield > 0 then
        world.set(s, "shield_recharge_time", defines().SHIELD_RECHARGE)
    end
    e.D.shield = math.max(0, e.D.shield - res.shield)
    e.D.armor = math.max(0, e.D.armor - res.armor)
    if res.hull > 0 then e.D.hull = e.D.hull - res.hull end
    world.set(s, "shield_hitpoints", string.format("%.5f", e.D.shield))
    world.set(s, "armor_hitpoints", string.format("%.5f", e.D.armor))
    local dah = num(world.field(s, "disable_at_health"))
    local T = dah and dah >= 0 and dah * e.D.max_hull or -1
    if T >= 0 and e.D.hull <= T then
        e.D.hull = math.max(T, 1.0)
        e.alive = false
        world.set(s, "disabled", "yes")
        S.disabled = S.disabled + 1
    elseif e.D.hull <= 0 then
        e.D.hull = 0
        e.alive = false
        killed[#killed + 1] = e.sid
        S.destroyed = S.destroyed + 1
    else
        -- the disengage roll (4.1): evasive any hull damage, else below the threshold; a fleet that
        -- can FTL [V; I the ship size's factor 1 and the modifiers]
        local f = fleet(e.fid)
        local evasive = f and unq(world.field(f, "fleet_stance")) == "evasive"
        local thr = evasive and 1.0 or defines().DIS_THRESHOLD
        if f and hp_before < thr and not prop(f, "station") and attacker_fid then
            local used = num(world.field(s, "disengagement_opportunities_used")) or 0
            local opp = (num(world.field(s, "disengagement_opportunities")) or 1) - used
            if evasive or opp > 0 then
                local x = evasive and res.hull or 1.0
                local chance = defines().DIS_BASE * x
                local c = coord(f)
                local so = c and world.system_owner and world.system_owner[c.origin]
                if so and so == owner(e.fid) then chance = chance * defines().DIS_FRIENDLY end
                local roll = global_fixed()
                if roll <= math.min(chance, defines().DIS_MAX) then
                    world.set(s, "disengaged", "yes")
                    world.set(s, "disengagement_opportunities_used", used + 1)
                    e.disengaged = true
                    S.disengaged = S.disengaged + 1
                end
            end
        end
    end
    world.set(s, "hitpoints", string.format("%.5f", e.D.hull))
end

---------------------------------------------------------------- the tick

function combat.wants()
    -- a fleet in combat, or two fleets of different owners in one system (a start possible)
    local seen = {}
    for _, fid in ipairs(world.all("fleet")) do
        local f = fleet(fid)
        if f then
            if has_combat(f) then return true end
            local c = coord(f)
            local o = owner(fid)
            if c and c.origin ~= NO_ID and o then
                local k = seen[c.origin]
                if k and k ~= o then return true end
                seen[c.origin] = k or o
            end
        end
    end
    return false
end

function combat.tick(host, date)
    S.ticks = S.ticks + 1
    cache = {}
    -- the fleets by system
    local by_system, order = {}, {}
    for _, fid in ipairs(world.all("fleet")) do
        local f = fleet(fid)
        local c = f and coord(f)
        if c and c.origin ~= NO_ID then
            local l = by_system[c.origin]
            if not l then l = {}; by_system[c.origin] = l end
            l[#l + 1] = fid
            order[#order + 1] = fid
        end
    end
    -- 1. detection (from the tick's start state), 2. the lists applied
    local found, before = {}, {}
    for _, fid in ipairs(order) do
        local f = fleet(fid)
        local inlist = {}
        local old = in_combat_with(f)
        for _, id in ipairs(old) do inlist[id] = true end
        before[fid] = old
        found[fid] = candidates(fid, f, by_system, inlist)
    end
    -- the pairs: A and B fight when either detects the other and both can fight (a fleet that
    -- cannot, found nil: in FTL, disabled, emptied, drops out of every list) [I: the game's
    -- symmetric lists, RemoveFromEnemyCombatLists]
    local pairs_of = {}
    local function link(x, y)
        local l = pairs_of[x]
        if not l then l = {}; pairs_of[x] = l end
        l[y] = true
    end
    for _, fid in ipairs(order) do
        for _, id in ipairs(found[fid] or {}) do
            if found[id] and fleet(id) then link(fid, id); link(id, fid) end
        end
    end
    for _, fid in ipairs(order) do
        local f = fleet(fid)
        if f then
            local want, keep = pairs_of[fid] or {}, {}
            local first = nil
            for _, id in ipairs(before[fid]) do
                if want[id] then keep[#keep + 1] = id; want[id] = nil end
            end
            for _, id in ipairs(order) do
                if want[id] then keep[#keep + 1] = id; first = first or id end
            end
            if #keep > 0 or #before[fid] > 0 then set_list(f, keep) end
            if #before[fid] == 0 and #keep > 0 then combat_started(fid, f, first, date) end
            if #before[fid] > 0 and #keep == 0 then combat_ended(fid, f) end
        end
    end
    -- the ship pool (UpdateShipParallel), in the ships store's order: drawn when a fleet fights
    local all = world.all("ships")
    local any = false
    for _, fid in ipairs(order) do
        local f = fleet(fid)
        if f and has_combat(f) then any = true break end
    end
    if not any then
        RUST.skip(#all)
        return
    end
    local seeds, index = {}, {}
    for i, sid in ipairs(all) do
        index[sid] = i
        seeds[i] = global_int()
    end
    -- the participants: every ship of the fleets in combat
    local entries = {}
    local function entry(sid, fid)
        local e = entries[sid]
        if e then return e end
        local s = world.object("ships", sid)
        if not s then return nil end
        local f = fleet(fid)
        e = { sid = sid, fid = fid, D = defence(sid, s), coord = coord(f), alive = world.field(s, "disabled") ~= "yes",
              disengaged = world.field(s, "disengaged") == "yes", armed = fleet_info(fid, f).armed,
              weight = 1 + (num(world.field(s, "targeting")) or 1) }
        entries[sid] = e
        return e
    end
    local shooters = {}
    for _, fid in ipairs(order) do
        local f = fleet(fid)
        local enemies_f = f and in_combat_with(f) or {}
        if #enemies_f > 0 and f and (fleet_info(fid, f).armed or military(f)) then
            local enemies = {}
            for _, oid in ipairs(enemies_f) do
                local o = fleet(oid)
                for _, sid in ipairs(o and ship_ids(o) or {}) do
                    local e = entry(sid, oid)
                    if e then enemies[#enemies + 1] = e end
                end
            end
            for _, sid in ipairs(ship_ids(f)) do
                shooters[#shooters + 1] = { sid = sid, fid = fid, enemies = enemies }
            end
        end
    end
    table.sort(shooters, function(a, b) return (index[a.sid] or 0) < (index[b.sid] or 0) end)
    local killed = {}
    for _, sh in ipairs(shooters) do
        local s = world.object("ships", sh.sid)
        local me = entry(sh.sid, sh.fid)
        if s and me and me.alive and not me.disengaged then
            local M = modifiers("ship", sh.sid)
            local rngS = crude(seeds[index[sh.sid]] or 0)
            for _, sec in ipairs(sections(s)) do
                local rngC = crude(get_integer(rngS))
                for _, w in ipairs(sec) do
                    local rngW = crude(get_integer(rngC))
                    if w.t and not w.t.missile then
                        -- windup and cooldown (3.1): a budget of one micro tick
                        local windup = num(world.field(w.block, "windup")) or 0
                        local cooldown = num(world.field(w.block, "cooldown")) or 0
                        local budget, fire = 1.0, false
                        local cur = num(world.path(w.block, "targeting_module", "target", "id"))
                        local target = best_target(sh.sid, me.coord, w, M, sh.enemies, cur)
                        local function roll_windup()
                            local r = get_integer(rngW)
                            local v = w.t.windup_min + (w.t.windup_max - w.t.windup_min) * ((r % 1000) * 100) / ONE
                            return v <= 0 and 0.01 or v
                        end
                        for _ = 1, 4 do
                            if cooldown > 0 then
                                local c = cooldown - budget
                                if c > 0 then cooldown, budget = c, 0 else budget, cooldown = budget - cooldown, 0 end
                            end
                            if cooldown ~= 0 or budget <= 0 then break end
                            if windup == 0 then
                                if not target then break end
                                windup = roll_windup()
                            end
                            if windup > 0 and budget > 0 then
                                local b2 = budget - windup
                                if b2 < 0 then windup = windup - budget; budget = 0; break end
                                windup, budget = 0, b2
                                if target then cooldown = w.t.cooldown; fire = true; break end
                                windup = roll_windup()
                            end
                            if budget <= 0 then break end
                        end
                        world.set(w.block, "windup", string.format("%.5f", windup))
                        world.set(w.block, "cooldown", string.format("%.5f", cooldown))
                        if fire and target and target.alive then
                            -- the shot (3.3): one roll, evaded / hit / missed
                            S.shots = S.shots + 1
                            local acc, trk = accuracy(w.t, M), tracking(w.t, M)
                            local r = (global_int() % ONE) / ONE
                            local fs = combat.fleet_stats[sh.fid]
                            if not fs then
                                fs = { hull = 0, armor = 0, shields = 0, hits = 0, missed = 0, evaded = 0 }
                                combat.fleet_stats[sh.fid] = fs
                            end
                            if r < target.D.evasion - trk then
                                S.evaded = S.evaded + 1
                                fs.evaded = fs.evaded + 1
                            elseif r < acc then
                                S.hits = S.hits + 1
                                fs.hits = fs.hits + 1
                                local res = calc_damage(target.D, w.t, global_int())
                                -- (what the shot takes off: at most what the target has [I])
                                fs.shields = fs.shields + math.min(res.shield, math.max(0, target.D.shield))
                                fs.armor = fs.armor + math.min(res.armor, math.max(0, target.D.armor))
                                fs.hull = fs.hull + math.min(res.hull, math.max(0, target.D.hull))
                                take_damage(target, res, sh.fid, killed)
                            else
                                S.missed = S.missed + 1
                                fs.missed = fs.missed + 1
                            end
                        end
                    end
                end
            end
        end
    end
    -- the destroyed ships removed (SetToBeKilled; the fleet with its last ship)
    local destroy = require("engine.fleets.destroy")
    for _, sid in ipairs(killed) do
        local s = world.object("ships", sid)
        local fid = s and num(world.field(s, "fleet"))
        destroy.ship(sid)
        if fid and not fleet(fid) then
            -- out of the others' lists (RemoveFromEnemyCombatLists)
            for _, oid in ipairs(order) do
                local o = fleet(oid)
                if o then
                    local l, changed = {}, false
                    for _, x in ipairs(in_combat_with(o)) do
                        if x == fid then changed = true else l[#l + 1] = x end
                    end
                    if changed then
                        set_list(o, l)
                        if #l == 0 then combat_ended(oid, o) end
                    end
                end
            end
        end
    end
end

function combat.report()
    return string.format("combat: %d ticks, %d started, %d ended, %d shots (%d hits, %d evaded, %d missed), %d destroyed, %d disabled, %d disengaged",
        S.ticks, S.started, S.ended, S.shots, S.hits, S.evaded, S.missed, S.destroyed, S.disabled, S.disengaged)
end

return combat
