-- tools/starbase_probe.lua: the starbase package's silent and refused effects run with real targets in the
-- loaded save (STELLAR_LUA=tools/starbase_probe.lua, run 0 <save>; for the coverage review: docs/script_coverage.md). Each case: the scope and the
-- event targets picked from the world, the effect text, then the world's writes, the engine
-- effects applied and refused, and a check of the field the effect is documented to change.
local world = require("engine.world")
local eval = require("simscript.eval")
local pdxscript = require("pdxscript")
local I = eval._internal
local E = I.E
local S, NONE = eval.S, I.NONE
local NO_ID = 4294967295
local R = require("engine.script.runtime")
local D = require("engine.diplomacy")
local objects = require("engine.script.objects")
local out = {}
local function say(s) out[#out + 1] = s print(s) end

local function ref(v) v = tonumber(v) return (v and v ~= NO_ID) and v or nil end
local function unq(v) return v and (tostring(v):gsub('"', "")) or nil end
local function f(o, k) return o and world.field(o, k) end

-- the writes counter (scriptcheck's)
local writes = 0
for _, k in ipairs({ "set", "append", "insert", "push", "append_value", "remove_value", "remove_entry", "remove",
    "replace", "append_entry", "set_entry", "set_text", "set_key", "insert_value", "remove_at", "place", "create" }) do
    local fn = world[k]
    if type(fn) == "function" then
        world[k] = function(...) writes = writes + 1 return fn(...) end
    end
end

-- the actors
local player
do
    local ok, blocks = pcall(world.blocks, world.meta and world.meta.player)
    for _, b in ipairs(ok and blocks or {}) do player = player or tonumber(world.field(b, "country")) end
end
local contact
for _, c in ipairs(world.all("country")) do
    if c ~= player and D.flag(player, c, "communications") and D.alive(c) then contact = contact or c end
end
say(("probe: player %s, contact %s"):format(tostring(player), tostring(contact)))

local function first(store, pred)
    for _, id in ipairs(world.all(store)) do
        local o = world.object(store, id)
        if o and (not pred or pred(o, id)) then return id, o end
    end
end
local function mega_of_type(pat, with_bypass)
    return first("megastructures", function(o)
        return (unq(f(o, "type")) or ""):match(pat) and (not with_bypass or ref(f(o, "bypass")))
    end)
end
local cap
do
    local col = ref(f(world.object("country", player), "capital"))
    local kind, id = R.carrier_of("colony", col)
    cap = kind and R.system_of(kind, id)
end
say("probe: capital system " .. tostring(cap))

local function run(name, kind, id, text, targets, check)
    if not id then say(("probe-case %s: no object for the scope (%s)"):format(name, kind)) return end
    local tree = pdxscript.parse(text, "probe")
    local ctx = eval.new_ctx(S(kind, id), contact and S("country", contact) or nil, targets or {}, "probe")
    local w0, a0 = writes, E.stats and E.stats.applied or 0
    local un0 = {}
    for k, c in pairs(E.stats and E.stats.unapplied or {}) do un0[k] = c end
    local before = check and check()
    local ok, err = pcall(function()
        eval.effect(tree, ctx)
        if E.flush then E.flush() end
    end)
    local refused = {}
    for k, c in pairs(E.stats and E.stats.unapplied or {}) do
        if c > (un0[k] or 0) then refused[#refused + 1] = k end
    end
    local after = check and check()
    say(("probe-case %s: %s %s | %s | writes +%d applied +%d refused {%s} | %s -> %s"):format(name, kind, tostring(id),
        text:gsub("%s+", " "), writes - w0, (E.stats and E.stats.applied or 0) - a0, table.concat(refused, " "),
        tostring(before), tostring(after) .. (ok and "" or (" ERROR " .. tostring(err)))))
end
local T = function(kind, id) return id and S(kind, id) or nil end

-- gateways: activate_gateway, link_to
local g1 = mega_of_type("^gateway", true)
local g2 = first("megastructures", function(o, id) return id ~= g1 and (unq(f(o, "type")) or ""):match("^gateway") and ref(f(o, "bypass")) end)
local function bp_of(m) return ref(f(world.object("megastructures", m), "bypass")) end
run("activate_gateway", "country", player, "activate_gateway = event_target:g1", { g1 = T("megastructure", g1) },
    function() return g1 and f(world.object("bypasses", bp_of(g1)), "active") end)
run("link_to", "megastructure", g1, "link_to = event_target:g2", { g2 = T("megastructure", g2) },
    function() return g1 and tostring(f(world.object("bypasses", bp_of(g1)), "linked_to")) end)
-- megastructure upgrades: upgrade_megastructure_to then finish_upgrade
local gr = mega_of_type("^gateway_ruined")
run("finish_upgrade", "megastructure", gr, "upgrade_megastructure_to = gateway_restored finish_upgrade = yes", nil,
    function() return gr and unq(f(world.object("megastructures", gr), "type")) end)

-- hyperlanes: two systems with no lane between them
local far
for _, sid in ipairs(world.all("galactic_object")) do
    if sid ~= cap then
        local linked = false
        for _, n in ipairs(R.hyperlanes(cap)) do if n == sid then linked = true end end
        if not linked then far = sid break end
    end
end
local function lane(a, b)
    for _, n in ipairs(R.hyperlanes(a)) do if n == b then return "linked" end end
    return "none"
end
run("add_hyperlane", "country", player, "add_hyperlane = { from = event_target:a to = event_target:b }",
    { a = T("system", cap), b = T("system", far) }, function() return lane(cap, far) end)
run("remove_hyperlane", "country", player, "remove_hyperlane = { from = event_target:a to = event_target:b }",
    { a = T("system", cap), b = T("system", far) }, function() return lane(cap, far) end)

-- bypasses: add_seen_bypass, lock_bypass, renew_bypass_lock
local bp = first("bypasses")
run("add_seen_bypass", "country", player, "add_seen_bypass = event_target:bp", { bp = T("bypass", bp) },
    function() return #world.list(f(world.object("country", player), "seen_bypasses")) end)
run("lock_bypass", "bypass", bp, "lock_bypass = { country = from duration = 360 }", nil,
    function() return tostring(f(world.object("bypasses", bp), "lock_country")) .. "/" .. tostring(f(world.object("bypasses", bp), "lock_remaining_days")) end)
run("renew_bypass_lock", "bypass", bp, "renew_bypass_lock = yes", nil,
    function() return tostring(f(world.object("bypasses", bp), "lock_remaining_days")) end)

-- closest_system: the nearest system 1..3 jumps away
run("closest_system", "country", player, "closest_system = { min_steps = 1 max_steps = 3 limit = { always = yes } set_star_class = sc_m }", nil,
    function()
        local n = R.hyperlanes(cap)[1]
        return n and unq(f(world.object("galactic_object", n), "star_class"))
    end)

-- removals: a megastructure, an ambient object
local m3 = first("megastructures", function(o, id) return id ~= g1 and id ~= g2 and id ~= gr end)
run("delete_megastructure", "country", player, "delete_megastructure = event_target:m", { m = T("megastructure", m3) },
    function() return world.object("megastructures", m3) ~= nil end)
local m4 = first("megastructures", function(o, id) return id ~= g1 and id ~= g2 and id ~= gr and id ~= m3 end)
run("remove_megastructure", "country", player, "remove_megastructure = event_target:m", { m = T("megastructure", m4) },
    function() return world.object("megastructures", m4) ~= nil end)
local amb = first("ambient_object")
run("destroy_ambient_object", "country", player, "destroy_ambient_object = event_target:a", { a = T("ambient_object", amb) },
    function() return world.object("ambient_object", amb) ~= nil end)

-- closed borders towards the contact
run("set_closed_borders", "country", player, "set_closed_borders = { who = from status = yes }", nil,
    function() return tostring(D.flag(player, contact, "closed_borders")) end)

-- starbases: a starbase of the player's with modules and buildings
local sbm = first("starbases", function(o, id)
    return R.starbase_owner(id) == player and #R.starbase_items(id, "modules") > 0 and #R.starbase_items(id, "buildings") > 0
end)
run("remove_starbase_module", "starbase", sbm, "remove_starbase_module = { slot = 1 module = all }", nil,
    function() return #R.starbase_items(sbm, "modules") end)
run("remove_starbase_building", "starbase", sbm, "remove_starbase_building = { slot = 1 building = all }", nil,
    function() return #R.starbase_items(sbm, "buildings") end)
local sbb = first("starbases", function(o, id) return #R.starbase_items(id, "buildings") > 0 end)
run("remove_random_starbase_building", "starbase", sbb, "remove_random_starbase_building = { count = 1 }", nil,
    function() return #R.starbase_items(sbb, "buildings") end)

-- create_starbase: the star of an unowned system without a starbase
local free
for _, sid in ipairs(world.all("galactic_object")) do
    if not R.system_owner(sid) and not R.primary_starbase(sid) and R.star_planet(sid) then free = sid break end
end
local star = free and R.star_planet(free)
run("create_starbase", "planet", star, "create_starbase = { owner = from size = starbase_outpost }", nil,
    function() return tostring(R.primary_starbase(free)) .. " owner " .. tostring(R.system_owner(free)) end)

-- psionic auras: spawned, then set and add
local asys = far
run("set_aura_intensity", "system", asys, "spawn_psionic_aura = { country = from } set_aura_intensity = 3", nil,
    function() return "aura" end)
run("add_aura_intensity", "system", asys, "add_aura_intensity = 2", nil, function()
    for _, e in ipairs(world.tree) do
        if e.op and e.key and e.key.text == "psionic_auras" then
            for _, a in ipairs(world.blocks(world.field(e.value, "psionic_auras"))) do
                if tonumber(world.field(a, "system")) == asys then return "intensity " .. tostring(world.field(a, "intensity")) end
            end
        end
    end
    return "no aura"
end)

-- spawn_custom_debris: a fleet of the player's (not a station)
local fl = first("fleet", function(o, id)
    return R.fleet_owner(id) == player and world.field(o, "station") ~= "yes" and #R.fleet_ships(id) > 0
end)
run("spawn_custom_debris", "fleet", fl, "spawn_custom_debris = { for = root.owner must_research = yes }", nil,
    function() return #world.all("debris") end)

-- create_sector: a colony of the player's in a system with no sector
local col
for _, c in ipairs(world.all("colony")) do
    local kind, pid = R.carrier_of("colony", c)
    local sid = pid and R.system_of("planet", pid)
    local s = sid and world.object("galactic_object", sid)
    if s and not ref(f(s, "sector")) and R.system_owner(sid) then col = c break end
end
run("create_sector", "colony", col, "create_sector = yes", nil, function()
    local kind, pid = R.carrier_of("colony", col)
    local sid = R.system_of("planet", pid)
    return tostring(f(world.object("galactic_object", sid), "sector"))
end)


-- other areas' rows in the package, for the record: link_wormholes (objects_galaxy), remove_modifier
-- (creation)
local wh = {}
for _, sid in ipairs(world.all("galactic_object")) do
    if #world.list(f(world.object("galactic_object", sid), "natural_wormholes")) > 0 then wh[#wh + 1] = sid end
end
local function linked_to(sid)
    local w = tonumber(world.list(f(world.object("galactic_object", sid), "natural_wormholes"))[1])
    local b = w and ref(f(world.object("natural_wormholes", w), "bypass"))
    return b and tostring(f(world.object("bypasses", b), "linked_to"))
end
run("link_wormholes", "system", wh[1], "link_wormholes = event_target:w", { w = T("system", wh[3] or wh[2]) },
    function() return wh[1] and linked_to(wh[1]) end)
run("remove_modifier", "country", player, "add_modifier = { modifier = artificial_planet_modifier days = 30 } remove_modifier = artificial_planet_modifier", nil,
    function()
        local tm = f(world.object("country", player), "timed_modifier")
        local n = 0
        for _, it in ipairs(world.blocks(type(tm) == "table" and f(tm, "items") or nil)) do
            if unq(f(it, "modifier")) == "artificial_planet_modifier" then n = n + 1 end
        end
        return n
    end)

-- create_sector, with a system taken out of its sector first (every colony of the save is in one):
-- a colony of the player's that is not its capital
local col2, sid2
for _, c in ipairs(world.all("colony")) do
    local kind, pid = R.carrier_of("colony", c)
    local sid = pid and R.system_of("planet", pid)
    if sid and sid ~= cap and R.system_owner(sid) and ref(f(world.object("galactic_object", sid), "sector")) then col2, sid2 = c, sid break end
end
if sid2 then
    local s = world.object("galactic_object", sid2)
    local sec = ref(f(s, "sector"))
    local so = sec and world.object("sectors", sec)
    if so then world.remove_value(world.field(so, "systems"), sid2) end
    world.set(s, "sector", NO_ID)
end
run("create_sector (system taken out of its sector)", "colony", col2, "create_sector = yes", nil, function()
    return tostring(f(world.object("galactic_object", sid2), "sector"))
end)
-- set_closed_borders both ways (the contact's borders were closed in the save)
run("set_closed_borders (open)", "country", player, "set_closed_borders = { who = from status = no }", nil,
    function() return tostring(D.flag(player, contact, "closed_borders")) end)
run("set_closed_borders (close)", "country", player, "set_closed_borders = { who = from status = yes }", nil,
    function() return tostring(D.flag(player, contact, "closed_borders")) end)
return table.concat(out, "\n")
