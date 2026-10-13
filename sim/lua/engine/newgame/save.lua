-- engine/newgame/save.lua : the generated game in the save's own form: a pdxscript tree like the
-- `gamestate` the game writes (CGameState::WriteMembers), so that engine.world, the tick and the
-- renderer read it as they read a save. Only what game creation makes is written; the stores the
-- game keeps empty at the start are written empty or left out.
--
--   local save = require("engine.newgame.save")
--   local tree = save.gamestate(game)   -- game: engine/newgame/init.lua's model
--   local meta = save.meta(game)        -- the save's `meta` text

local pdxscript = require("pdxscript")

local save = {}

-- ---------------------------------------------------------------------------------------------
-- tree builders (pdxscript's form: a block is an array of entries; a statement is { key, op,
-- value }, a bare value a token { text, quoted })

local NONE = 4294967295 -- the save's "no object"
save.NONE = NONE

-- a number as the save writes it: integers bare, others with up to 5 decimals
local function number_text(v)
    if v == math.floor(v) and math.abs(v) < 1e15 then
        return string.format("%d", v)
    end
    local s = string.format("%.5f", v):gsub("0+$", ""):gsub("%.$", "")
    return s
end
save.number_text = number_text

local function token(v, quoted)
    if type(v) == "number" then
        return { text = number_text(v) }
    elseif type(v) == "boolean" then
        return { text = v and "yes" or "no" }
    end
    return { text = tostring(v), quoted = quoted or nil }
end

local B = {}
B.__index = B

function save.block()
    return setmetatable({}, B)
end

-- b:set(key, value[, quoted]): key = value (a number, a boolean, a text; a block as is)
function B:set(key, value, quoted)
    local v = value
    if type(value) ~= "table" then
        v = token(value, quoted)
    end
    self[#self + 1] = { key = { text = key }, op = "=", value = v }
    return self
end

-- b:str(key, text): key = "text"
function B:str(key, text)
    return self:set(key, text, true)
end

-- b:child(key) -> a new block, key = { }
function B:child(key)
    local c = save.block()
    self[#self + 1] = { key = { text = key }, op = "=", value = c }
    return c
end

-- b:value(v[, quoted]): a bare value (a list element)
function B:value(v, quoted)
    self[#self + 1] = token(v, quoted)
    return self
end

-- b:item() -> a new block as a list element: { { ... } { ... } }
function B:item()
    local c = save.block()
    self[#self + 1] = c
    return c
end

-- b:list(key, values[, quoted]): key = { v1 v2 ... }
function B:list(key, values, quoted)
    local c = self:child(key)
    for _, v in ipairs(values) do
        c:value(v, quoted)
    end
    return c
end

-- a coordinate block: { x y origin [randomized visual_height] }
function B:coordinate(key, x, y, origin, randomized, visual_height)
    local c = self:child(key)
    c:set("x", x)
    c:set("y", y)
    c:set("origin", origin or NONE)
    if randomized then
        c:set("randomized", true)
    end
    if visual_height then
        c:set("visual_height", visual_height)
    end
    return c
end

-- a localised name: { key = "..." [variables = { { key = "..." value = <name> } ... }] [literal = yes] }
-- name: a text (a key) or { key = "...", variables = { { "NAME", <name> } ... }, literal = bool }
function B:name(key, name)
    local function write(block, n)
        if type(n) ~= "table" then
            block:str("key", n)
            return
        end
        block:str("key", n.key)
        if n.literal then
            block:set("literal", true)
        end
        if n.variables and #n.variables > 0 then
            local vars = block:child("variables")
            for _, kv in ipairs(n.variables) do
                local item = vars:item()
                item:str("key", kv[1])
                write(item:child("value"), kv[2])
            end
        end
    end
    write(self:child(key), name)
    return self
end

-- ---------------------------------------------------------------------------------------------
-- rounding as the save shows it

-- system coordinates are written with 2 decimals (CCelestialCoordinate of a galactic object)
local function round2(v)
    return math.floor(v * 100 + 0.5) / 100
end
save.round2 = round2

local function round5(v)
    return math.floor(v * 100000 + 0.5) / 100000
end

-- ---------------------------------------------------------------------------------------------
-- the gamestate

local function write_system(store, s)
    local o = store:child(tostring(s.id))
    o:coordinate("coordinate", round2(s.x), round2(s.y), NONE, true, s.visual_height or 3.65056)
    o:name("name", s.name or ("System " .. s.id))
    for _, pid in ipairs(s.planets) do
        o:set("planet", pid)
    end
    o:str("star_class", s.star_class)
    local hl = o:child("hyperlane")
    for _, lane in ipairs(s.lanes) do
        local item = hl:item()
        item:set("to", lane.to)
        item:set("length", lane.length)
        if lane.bridge then
            item:set("bridge", true)
        end
    end
    if #s.belts > 0 then
        local belts = o:child("asteroid_belts")
        for _, belt in ipairs(s.belts) do
            local item = belts:item()
            item:str("type", belt.type)
            item:set("inner_radius", belt.inner_radius)
        end
    end
    if next(s.flags) then
        local f = o:child("flags")
        local names = {}
        for k in pairs(s.flags) do
            names[#names + 1] = k
        end
        table.sort(names)
        for _, k in ipairs(names) do
            f:set(k, s.flags[k])
        end
    end
    o:str("initializer", s.initializer or "")
    if s.init_parent then
        o:set("init_parent", s.init_parent)
    end
    o:set("inner_radius", s.inner_radius or 0)
    o:set("outer_radius", s.outer_radius or 0)
    local sb = o:child("starbases")
    sb:value(s.starbase or NONE)
    o:set("sector", s.sector or NONE)
    o:set("index", s.index or 0)
    if s.colonies and #s.colonies > 0 then
        o:list("colonies", s.colonies)
    end
    o:set("storm", NONE)
end

local function write_planet(store, p)
    local o = store:child(tostring(p.id))
    if p.colony then
        o:set("colony", p.colony)
    end
    o:str("planet_class", p.class)
    o:set("planet_size", p.size)
    if p.colonize_date then
        o:set("colonize_date", p.colonize_date, true)
    end
    if p.original_owner then
        o:set("original_owner", p.original_owner)
    end
    o:set("carrier_binary_flags", p.owner and 1 or 3)
    o:set("build_queue", p.build_queue or NONE)
    o:name("name", p.name)
    o:coordinate("coordinate", round5(p.x), round5(p.y), p.system)
    o:set("orbit", p.orbit)
    o:set("last_bombardment", "0.01.01", true)
    if p.owner then
        o:set("owner", p.owner)
        o:set("controller", p.owner)
    end
    if p.moon_of then
        o:set("moon_of", p.moon_of)
    end
    if p.moons and #p.moons > 0 then
        o:list("moons", p.moons)
    end
    if p.has_ring then
        o:set("has_ring", true)
    end
    o:child("planet_orbitals")
    if p.anomaly then
        o:str("anomaly", p.anomaly)
    end
    o:set("bombardment_damage", 0)
    if p.flags and next(p.flags) then
        local f = o:child("flags")
        local names = {}
        for k in pairs(p.flags) do
            names[#names + 1] = k
        end
        table.sort(names)
        for _, k in ipairs(names) do
            f:set(k, p.flags[k])
        end
    end
    if p.modifier then
        o:str("planet_modifier", p.modifier)
    end
    o:set("entity", p.entity or 0)
    if p.deposits and #p.deposits > 0 then
        o:list("deposits", p.deposits)
    end
end

-- save.gamestate(game) -> tree. game: { date, name, version, systems, planets, nebulas, clusters,
-- countries (blocks), species (blocks), galaxy (settings), galaxy_radius, random_seed,
-- random_count, extra = { {key, block} } }
function save.gamestate(game)
    local t = save.block()
    t:str("version", game.version or "Cygnus v4.5.2")
    t:set("version_control_revision", 101)
    t:str("name", game.name or "New Game")
    t:str("date", game.date)
    t:list("required_dlcs", game.dlcs or {}, true)
    local player = t:child("player")
    for _, p in ipairs(game.players or {}) do
        local item = player:item()
        item:str("name", p.name)
        item:set("country", p.country)
    end
    t:set("tick", 0)
    t:set("date_distortion", false)
    t:set("random_log_day", 0)
    t:set("cheated_on_save", false)
    if game.species_db then
        t[#t + 1] = { key = { text = "species_db" }, op = "=", value = game.species_db }
    end
    t:set("last_created_species_ref", game.last_created_species_ref or 0)

    for _, n in ipairs(game.nebulas or {}) do
        local nb = t:child("nebula")
        nb:coordinate("coordinate", round2(n.x), round2(n.y), NONE, true, 3.65056)
        nb:name("name", n.name)
        nb:set("radius", n.radius)
        for _, sid in ipairs(n.systems) do
            nb:set("galactic_object", sid)
        end
    end

    for _, extra in ipairs(game.before_systems or {}) do
        t[#t + 1] = { key = { text = extra[1] }, op = "=", value = extra[2] }
    end

    local gal = t:child("galactic_object")
    for _, s in ipairs(game.systems) do
        write_system(gal, s)
    end

    for _, extra in ipairs(game.before_planets or {}) do
        t[#t + 1] = { key = { text = extra[1] }, op = "=", value = extra[2] }
    end

    local planets = t:child("planets"):child("planet")
    for _, id in ipairs(game.planet_ids) do
        write_planet(planets, game.planets[id])
    end

    if game.country then
        t[#t + 1] = { key = { text = "country" }, op = "=", value = game.country }
    end
    t:set("last_created_country", game.last_created_country or NONE)
    t:set("last_created_system", #game.systems - 1)

    for _, extra in ipairs(game.after_country or {}) do
        t[#t + 1] = { key = { text = extra[1] }, op = "=", value = extra[2] }
    end

    -- the setup (CGalaxyConfiguration::WriteMembers)
    local g = t:child("galaxy")
    for _, kv in ipairs(game.galaxy) do
        g:set(kv[1], kv[2], kv[3])
    end
    t:set("galaxy_radius", round5(game.galaxy_radius))
    local flags = t:child("flags")
    for _, kv in ipairs(game.flags or {}) do
        flags:set(kv[1], kv[2])
    end

    for _, extra in ipairs(game.after_galaxy or {}) do
        t[#t + 1] = { key = { text = extra[1] }, op = "=", value = extra[2] }
    end

    -- clusters (CGalacticObjectCluster::WriteMembers): the empires' start clusters
    local cl = t:child("clusters")
    for _, c in ipairs(game.clusters or {}) do
        local item = cl:item()
        item:str("id", c.id)
        item:coordinate("position", round5(c.x), round5(c.y), NONE)
        item:set("radius", c.radius)
        item:list("objects", c.objects)
    end
    if game.rim and #game.rim > 0 then
        t:list("rim_galactic_objects", game.rim)
    end
    t:set("random_seed", game.random_seed or 0)
    t:set("random_count", game.random_count or 0)
    return t
end

function save.write(tree)
    return pdxscript.write(tree)
end

-- save.meta(game) -> the `meta` file's text
function save.meta(game)
    local m = save.block()
    m:str("version", game.version or "Cygnus v4.5.2")
    m:set("version_control_revision", 101)
    m:str("name", game.name or "New Game")
    m:str("date", game.date)
    m:list("required_dlcs", game.dlcs or {}, true)
    if game.meta_flag then
        m[#m + 1] = { key = { text = "flag" }, op = "=", value = game.meta_flag }
    end
    m:set("meta_fleets", game.meta_fleets or 0)
    m:set("meta_planets", game.meta_planets or 0)
    return pdxscript.write(m)
end

return save
