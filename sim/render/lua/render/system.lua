-- render/system.lua : a system for the 3D view, from the world and the game's files: its stars and
-- planets (galactic_object.planet -> planets: planet_class, planet_size, coordinate in the
-- system's space, orbit, moon_of, entity = the class's model variant) with their models
-- (common/planet_classes: entity, entity_scale, atmosphere_color), and the ships in it (ships:
-- coordinate, rotation, forward_x/forward_y, graphical_culture, ship_design_implementation.design
-- -> ship_design.growth_stages: ship_size and sections -> common/section_templates' entity, at
-- common/ship_sizes' section_slots locators, on the culture's frame entity).
--
--   local sys = require("render.system")
--   return sys.extract(game_dir, system_id)

local world = require("engine.world")
local source = require("stellar.script.source")
local models = require("render.models")

local system = {}

local NONE = 4294967295
local worldgfx -- defined below the files read once

local function get(block, key)
    for _, e in ipairs(type(block) == "table" and block or {}) do
        if e.op and e.key and e.key.text == key then
            return e.value.text or e.value
        end
    end
    return nil
end

local function hsv_to_rgb(h, s, v)
    h = (h % 1) * 6
    local i = math.floor(h)
    local f = h - i
    local p, q, t = v * (1 - s), v * (1 - s * f), v * (1 - s * (1 - f))
    if i == 0 then return v, t, p elseif i == 1 then return q, v, p elseif i == 2 then return p, v, t
    elseif i == 3 then return p, q, v elseif i == 4 then return t, p, v end
    return v, p, q
end

local function colour(block)
    if type(block) ~= "table" then
        return nil
    end
    local n = {}
    for _, e in ipairs(block) do
        if e.text then
            n[#n + 1] = tonumber(e.text)
        end
    end
    if #n < 3 then
        return nil
    end
    if block.type == "hsv" then
        local r, g, b = hsv_to_rgb(n[1], n[2], n[3])
        return { r, g, b }
    end
    if n[1] > 1 or n[2] > 1 or n[3] > 1 then
        return { n[1] / 255, n[2] / 255, n[3] / 255 }
    end
    return { n[1], n[2], n[3] }
end

-- the game files read once: planet classes, scripted variables, section templates, ship sizes
local cache
local function files(game_dir)
    if cache then
        return cache
    end
    cache = { vars = {}, templates = {}, slots = {} }
    for _, f in ipairs(source.files(game_dir, "common/scripted_variables", "txt")) do
        for _, e in ipairs(source.parse(game_dir, f) or {}) do
            if e.op and e.key and e.key.text:sub(1, 1) == "@" and e.value.text then
                cache.vars[e.key.text] = tonumber(e.value.text)
            end
        end
    end
    cache.classes = source.definitions(game_dir, "common/planet_classes")
    for _, f in ipairs(source.files(game_dir, "common/section_templates", "txt")) do
        for _, e in ipairs(source.parse(game_dir, f) or {}) do
            if e.op and e.key and e.key.text == "ship_section_template" and type(e.value) == "table" then
                local key = get(e.value, "key")
                if key then
                    cache.templates[key] = get(e.value, "entity")
                end
            end
        end
    end
    local sizes = source.definitions(game_dir, "common/ship_sizes")
    for name, d in pairs(sizes) do
        local slots = {}
        local ss = get(d.block, "section_slots")
        for _, e in ipairs(type(ss) == "table" and ss or {}) do
            if e.op and e.key and type(e.value) == "table" then
                slots[e.key.text] = get(e.value, "locator")
            end
        end
        cache.slots[name] = slots
        cache.slots[name .. "#entity"] = get(d.block, "entity")
    end
    worldgfx(game_dir, cache)
    return cache
end


-- the star classes' settings of gfx/worldgfx (gfx_settings: world = <tag>, lava_bright_color,
-- lava_hot_stone_color, lava_cold_stone_color, each x its _intensity): world tag -> lava colours.
-- A star class pc_<tag> uses the world <tag> [I]
worldgfx = function(game_dir, f)
    f.worldgfx = {}
    for _, rel in ipairs(source.files(game_dir, "gfx/worldgfx", "txt")) do
        for _, e in ipairs(source.parse(game_dir, rel) or {}) do
            if e.op and e.key and e.key.text == "gfx_settings" and type(e.value) == "table" then
                local b = e.value
                local world = get(b, "world")
                local function c(name)
                    local rgb = colour(get(b, name .. "_color"))
                    local k = tonumber(get(b, name .. "_intensity")) or 1
                    return rgb and { rgb[1] * k, rgb[2] * k, rgb[3] * k }
                end
                if world and get(b, "lava_bright_color") then
                    f.worldgfx[world] = { c("lava_bright"), c("lava_hot_stone"), c("lava_cold_stone") }
                end
            end
        end
    end
end

-- a planet class's look: atmosphere colour, intensity, width; a star's lava colours
local function look(f, class)
    local d = f.classes[class]
    local out = {
        atmosphere = d and colour(get(d.block, "atmosphere_color")) or { 0.6, 0.7, 0.9 },
        intensity = d and tonumber(get(d.block, "atmosphere_intensity")) or 1,
        width = d and tonumber(get(d.block, "atmosphere_width")) or 0.5,
    }
    local tag = class:match("^pc_(.*)$")
    out.lava = tag and f.worldgfx[tag] or f.worldgfx.g_star
    return out
end
local function number(v, vars)
    if type(v) == "string" and v:sub(1, 1) == "@" then
        return vars[v]
    end
    return tonumber(v)
end

-- the first entity of the names that exists
local function first_entity(names)
    for _, n in ipairs(names) do
        if n and RENDER_MODELS.entities[n] then
            return n
        end
    end
    return nil
end

-- a ship's model: its frame entity and its sections' entities at the frame's locators
local function ship_model(f, ship)
    local culture = tostring(world.field(ship, "graphical_culture") or "")
    local design_id = tonumber(world.path(ship, "ship_design_implementation", "design"))
    local design = design_id and world.object("ship_design", design_id)
    local stage = design and world.blocks(world.field(design, "growth_stages"))[1]
    local size = stage and tostring(world.field(stage, "ship_size") or "")
    if not size then
        return nil
    end
    local slots = f.slots[size] or {}
    local frame = first_entity({ culture .. "_" .. size .. "_entity", f.slots[size .. "#entity"] and culture .. "_" .. f.slots[size .. "#entity"], f.slots[size .. "#entity"] })
    local sections = {}
    for _, s in ipairs(world.fields(stage, "section")) do
        local template = tostring(world.field(s, "template") or "")
        local slot = tostring(world.field(s, "slot") or "")
        local ent = f.templates[template]
        local name = ent and first_entity({ culture .. "_" .. ent, ent })
        if name then
            sections[#sections + 1] = { entity = name, locator = slots[slot] or "" }
        end
    end
    return { size = size, culture = culture, frame = frame, sections = sections }
end

-- system.extract(game_dir, system_id) -> { id, name, x, y, bodies = { ... }, ships = { ... } }
function system.extract(game_dir, id)
    local f = files(game_dir)
    local obj = world.object("system", id)
    if not obj then
        return nil, "no system " .. tostring(id)
    end
    local out = { id = id, x = tonumber(world.path(obj, "coordinate", "x")) or 0, y = tonumber(world.path(obj, "coordinate", "y")) or 0, bodies = {}, ships = {} }
    for _, pid in ipairs(world.fields(obj, "planet")) do
        pid = tonumber(pid)
        local p = pid and world.object("planet", pid)
        if p then
            local class = tostring(world.field(p, "planet_class") or "")
            local d = f.classes[class]
            local base = d and get(d.block, "entity")
            local variant = tonumber(world.field(p, "entity")) or 0
            local ent = base and first_entity({ string.format("%s_%02d_entity", base, variant + 1), base .. "_01_entity", base .. "_entity", base })
            local c = world.field(p, "coordinate")
            out.bodies[#out.bodies + 1] = {
                id = pid, class = class, entity = ent or "",
                star = d and get(d.block, "star") == "yes" or false,
                size = tonumber(world.field(p, "planet_size")) or 10,
                entity_scale = d and number(get(d.block, "entity_scale"), f.vars) or 1,
                x = tonumber(world.field(c, "x")) or 0, y = tonumber(world.field(c, "y")) or 0,
                orbit = tonumber(world.field(p, "orbit")) or 0,
                moon_of = tonumber(world.field(p, "moon_of")) or -1,
                look = look(f, class),
            }
        end
    end
    -- the ships of the fleets in the system (stations too)
    for _, fid in ipairs(world.all("fleet")) do
        local fl = world.object("fleet", fid)
        local origin = tonumber(world.path(fl, "movement_manager", "coordinate", "origin"))
        if origin == id then
            local station = world.path(fl, "properties", "station") == "yes"
            for _, sid in ipairs(world.list(world.field(fl, "ships"))) do
                sid = tonumber(sid)
                local ship = sid and world.object("ship", sid)
                local c = ship and world.field(ship, "coordinate")
                if c and tonumber(world.field(c, "origin")) == id then
                    local m = ship_model(f, ship) or {}
                    local sections = {}
                    for _, s in ipairs(m.sections or {}) do
                        sections[#sections + 1] = s
                    end
                    out.ships[#out.ships + 1] = {
                        id = sid, fleet = fid, station = station,
                        x = tonumber(world.field(c, "x")) or 0, y = tonumber(world.field(c, "y")) or 0,
                        rotation = tonumber(world.field(ship, "rotation")) or 0,
                        fx = tonumber(world.field(ship, "forward_x")) or 0, fy = tonumber(world.field(ship, "forward_y")) or 1,
                        size = m.size or "", culture = m.culture or "", frame = m.frame or "", sections = sections,
                    }
                end
            end
        end
    end
    return out
end

-- system.look_of(game_dir, entity) -> the look of the planet class drawn with an entity (the
-- class whose `entity` the name starts with), or the default
function system.look_of(game_dir, entity)
    local f = files(game_dir)
    local best, len = nil, 0
    for name, d in pairs(f.classes) do
        local base = get(d.block, "entity")
        if base and entity:sub(1, #base) == base and #base > len then
            best, len = name, #base
        end
    end
    local out = look(f, best or "")
    out.class = best
    return out
end

return system
