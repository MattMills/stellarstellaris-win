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
    cache = { vars = {}, templates = {}, slots = {}, component_slots = {}, template_order = {}, template_fit = {},
        slot_order = {}, size_cultures = {} }
    for _, f in ipairs(source.files(game_dir, "common/scripted_variables", "txt")) do
        for _, e in ipairs(source.parse(game_dir, f) or {}) do
            if e.op and e.key and e.key.text:sub(1, 1) == "@" and e.value.text then
                cache.vars[e.key.text] = tonumber(e.value.text)
            end
        end
    end
    cache.classes = source.definitions(game_dir, "common/planet_classes")
    -- the deposits (common/deposits): what each produces (resources.produces), for the planets'
    -- map labels
    cache.deposits = source.definitions(game_dir, "common/deposits")
    for _, f in ipairs(source.files(game_dir, "common/section_templates", "txt")) do
        for _, e in ipairs(source.parse(game_dir, f) or {}) do
            if e.op and e.key and e.key.text == "ship_section_template" and type(e.value) == "table" then
                local key = get(e.value, "key")
                if key then
                    cache.templates[key] = get(e.value, "entity")
                    -- (its size and slot, in the files' order: default_sections)
                    cache.template_order[#cache.template_order + 1] = key
                    cache.template_fit[key] = { size = get(e.value, "ship_size"), slot = get(e.value, "fits_on_slot") }
                    -- its component slots: name -> { template (a slot template), locator }
                    local cs = {}
                    for _, x in ipairs(e.value) do
                        if x.op and x.key and x.key.text == "component_slot" and type(x.value) == "table" then
                            local n = get(x.value, "name")
                            if n then
                                cs[n] = { template = get(x.value, "template") or "", locator = get(x.value, "locatorname") or "" }
                            end
                        end
                    end
                    cache.component_slots[key] = cs
                end
            end
        end
    end
    local sizes = source.definitions(game_dir, "common/ship_sizes")
    for name, d in pairs(sizes) do
        local slots, order = {}, {}
        local ss = get(d.block, "section_slots")
        for _, e in ipairs(type(ss) == "table" and ss or {}) do
            if e.op and e.key and type(e.value) == "table" then
                slots[e.key.text] = get(e.value, "locator")
                order[#order + 1] = e.key.text
            end
        end
        cache.slots[name] = slots
        cache.slot_order[name] = order
        -- (the cultures a size is limited to, `graphical_culture = { ... }`, in the files' order:
        -- browser_size)
        local gc = get(d.block, "graphical_culture")
        if type(gc) == "table" then
            local list = {}
            for _, x in ipairs(gc) do
                if x.text then list[#list + 1] = (x.text:gsub('"', "")) end
            end
            cache.size_cultures[#cache.size_cultures + 1] = { name = name, file = d.file or "", line = d.line or 0, cultures = list }
        end
        cache.slots[name .. "#entity"] = get(d.block, "entity")
    end
    -- the `ship` swatches of flags/colors.txt (the empire colour of 3D ships, PrimaryColor)
    cache.ship_swatches = {}
    local ctree = source.parse(game_dir, "flags/colors.txt")
    local colors = ctree and get(ctree, "colors")
    for _, e in ipairs(type(colors) == "table" and colors or {}) do
        if e.op and e.key and type(e.value) == "table" then
            cache.ship_swatches[e.key.text] = colour(get(e.value, "ship"))
        end
    end
    -- common/graphical_culture: ship_color and ship_lighting (the ships' camera lights) by culture
    cache.cultures = {}
    for name, d in pairs(source.definitions(game_dir, "common/graphical_culture")) do
        local l = get(d.block, "ship_lighting")
        local light
        if type(l) == "table" then
            local function vec(k)
                local v = get(l, k)
                local n = {}
                for _, t in ipairs(type(v) == "table" and v or {}) do
                    if t.text then
                        n[#n + 1] = tonumber(t.text) or 0
                    end
                end
                return { n[1] or 0, n[2] or 0, n[3] or 0 }
            end
            local function num(k, dflt)
                return tonumber(get(l, k)) or dflt
            end
            light = {
                dirs = { vec("cam_light_1_dir"), vec("cam_light_2_dir"), vec("cam_light_3_dir") },
                intensity_near = num("intensity_near", 1), intensity_far = num("intensity_far", 1),
                near_value = num("near_value", 0), far_value = num("far_value", 1),
                rim_start_near = num("rim_start_near", 0), rim_stop_near = num("rim_stop_near", 1),
                rim_start_far = num("rim_start_far", 0), rim_stop_far = num("rim_stop_far", 1),
                ambient_near = num("ambient_near", 0), ambient_far = num("ambient_far", 0),
            }
        end
        cache.cultures[name] = { ship_color = get(d.block, "ship_color") == "yes", lighting = light, fallback = get(d.block, "fallback") }
    end
    -- the weapons' turrets: a component template's weapon_type_* tag (common/component_templates)
    -- picks the entity of its slot's template (common/component_slot_templates `entities`)
    cache.weapon_types = {}
    for _, f in ipairs(source.files(game_dir, "common/component_templates", "txt")) do
        for _, e in ipairs(source.parse(game_dir, f) or {}) do
            if e.op and e.key and type(e.value) == "table" then
                local key = get(e.value, "key")
                local tags = get(e.value, "tags")
                for _, t in ipairs(type(tags) == "table" and tags or {}) do
                    if key and t.text and t.text:match("^weapon_type_") then
                        cache.weapon_types[key] = t.text
                    end
                end
            end
        end
    end
    cache.slot_entities = {}
    for name, d in pairs(source.definitions(game_dir, "common/component_slot_templates")) do
        local ents = get(d.block, "entities")
        local m = {}
        for _, x in ipairs(type(ents) == "table" and ents or {}) do
            if x.op and x.key and x.value.text then
                m[x.key.text] = x.value.text
            end
        end
        cache.slot_entities[name] = m
    end
    cache.star_classes = source.definitions(game_dir, "common/star_classes")
    -- a star's planet class -> its star class's world (planet = { key = pc_x }, class = x_star)
    cache.star_world_of = {}
    for _, d in pairs(cache.star_classes) do
        local p = get(d.block, "planet")
        local key = type(p) == "table" and get(p, "key")
        local class = get(d.block, "class")
        if key and class and not cache.star_world_of[key] then
            cache.star_world_of[key] = class
        end
    end
    -- common/asteroid_belts: a belt type's meshes (repeats weigh more), shader (default
    -- "Asteroid": gfx/FX/asteroid.shader), density and width (default 1)
    cache.belt_types = {}
    for name, d in pairs(source.definitions(game_dir, "common/asteroid_belts")) do
        local meshes = {}
        for _, e in ipairs(d.block) do
            if e.op and e.key and e.key.text == "mesh" and e.value.text then
                meshes[#meshes + 1] = e.value.text
            end
        end
        cache.belt_types[name] = {
            meshes = meshes, shader = get(d.block, "shader") or "Asteroid",
            density = tonumber(get(d.block, "density")) or 1, width = tonumber(get(d.block, "width")) or 1,
        }
    end
    worldgfx(game_dir, cache)
    return cache
end


-- the star classes' settings of gfx/worldgfx (gfx_settings: world = <tag>, lava_bright_color,
-- lava_hot_stone_color, lava_cold_stone_color, each x its _intensity): world tag -> lava colours.
-- A star class pc_<tag> uses the world <tag> [I]
worldgfx = function(game_dir, f)
    f.worldgfx = {}
    f.worldgfx_settings = {}
    for _, rel in ipairs(source.files(game_dir, "gfx/worldgfx", "txt")) do
        for _, e in ipairs(source.parse(game_dir, rel) or {}) do
            if e.op and e.key and e.key.text == "gfx_settings" and type(e.value) == "table" then
                local b = e.value
                local world = get(b, "world")
                -- the game reads these colours linear (^2.2: GfxToLinear in
                -- CWorldGraphicalMapData::ReadMember), then x the intensity
                local function c(name)
                    local rgb = colour(get(b, name .. "_color"))
                    local k = tonumber(get(b, name .. "_intensity")) or 1
                    local function l(v)
                        return math.max(v, 0) ^ 2.2 * k
                    end
                    return rgb and { l(rgb[1]), l(rgb[2]), l(rgb[3]) }
                end
                if world and get(b, "lava_bright_color") then
                    f.worldgfx[world] = { c("lava_bright"), c("lava_hot_stone"), c("lava_cold_stone") }
                end
                if world then
                    -- the scalar settings (numbers and strings), the sky's backgrounds in order,
                    -- and hsv triples by name
                    local s = { backgrounds = {} }
                    for _, x in ipairs(b) do
                        if x.op and x.key then
                            local k = x.key.text
                            if x.value.text then
                                s[k] = tonumber(x.value.text) or x.value.text
                            elseif k == "galaxy_background" then
                                local tex = get(x.value, "texture")
                                local trig = get(x.value, "trigger")
                                local pct
                                for _, t in ipairs(type(trig) == "table" and trig or {}) do
                                    if t.op and t.key and t.key.text == "distance_to_core_percent" then
                                        pct = tonumber(t.value.text)
                                    end
                                end
                                s.backgrounds[#s.backgrounds + 1] = { texture = tex, below = pct or 2.0, ycocg = get(x.value, "ycocg") == "yes" }
                            elseif type(x.value) == "table" and x.value.type then
                                s[k] = colour(x.value)
                            elseif type(x.value) == "table" then
                                local n = {}
                                for _, t in ipairs(x.value) do
                                    if t.text then
                                        n[#n + 1] = tonumber(t.text)
                                    end
                                end
                                s[k] = n
                            end
                        end
                    end
                    f.worldgfx_settings[world] = s
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
    -- the star class whose planet this class is (common/star_classes: planet = { key }, class), as
    -- CStarClass::CalcClassKeyHash: pc_m_giant_star -> m_star; else the class minus pc_
    local tag = f.star_world_of[class] or class:match("^pc_(.*)$")
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
            -- its weapons' turrets: the component in a slot, its weapon type, the slot
            -- template's entity for it (the culture's first), at the slot's locator
            local turrets = {}
            local cs = f.component_slots[template] or {}
            for _, c in ipairs(world.fields(s, "component")) do
                local slot_name = tostring(world.field(c, "slot") or ""):gsub('"', "")
                local comp = tostring(world.field(c, "template") or ""):gsub('"', "")
                local sl = cs[slot_name]
                local wt = f.weapon_types[comp]
                local te = sl and wt and (f.slot_entities[sl.template] or {})[wt]
                local tname = te and first_entity({ culture .. "_" .. te, te })
                if tname and sl.locator ~= "" then
                    turrets[#turrets + 1] = { entity = tname, locator = sl.locator }
                end
            end
            sections[#sections + 1] = { entity = name, locator = slots[slot] or "", turrets = turrets }
        end
    end
    return { size = size, culture = culture, frame = frame, sections = sections }
end

-- a culture's ship_lighting, else its fallback's
local function culture_lighting(f, name)
    for _ = 1, 4 do
        local c = f.cultures[name]
        if not c then
            return nil
        end
        if c.lighting then
            return c.lighting
        end
        name = c.fallback or ""
    end
    return nil
end

-- fleet id -> owner country id (the countries' fleets_manager.owned_fleets), built on demand
local owners_cache
local function fleet_owners()
    if owners_cache then
        return owners_cache
    end
    owners_cache = {}
    for _, cid in ipairs(world.all("country")) do
        local c = world.object("country", cid)
        local owned = c and world.path(c, "fleets_manager", "owned_fleets")
        for _, b in ipairs(owned and world.blocks(owned) or {}) do
            local fid = tonumber(world.field(b, "fleet"))
            if fid then
                owners_cache[fid] = tonumber(cid)
            end
        end
    end
    return owners_cache
end

-- system.extract(game_dir, system_id) -> { id, name, x, y, bodies = { ... }, ships = { ... } }
function system.extract(game_dir, id)
    owners_cache = nil
    local f = files(game_dir)
    local obj = world.object("system", id)
    if not obj then
        return nil, "no system " .. tostring(id)
    end
    local out = { id = id, x = tonumber(world.path(obj, "coordinate", "x")) or 0, y = tonumber(world.path(obj, "coordinate", "y")) or 0, bodies = {}, ships = {}, belts = {} }
    -- the system's size (outer_radius: the zoom steps are ZOOM_STEPS_SYSTEM_PERCENTAGES x it) and
    -- the world of gfx/worldgfx its star class names (common/star_classes `class`)
    out.outer_radius = tonumber(world.field(obj, "outer_radius")) or 0
    out.inner_radius = tonumber(world.field(obj, "inner_radius")) or 0
    local sc = f.star_classes[tostring(world.field(obj, "star_class") or ""):gsub('"', "")]
    out.world = sc and get(sc.block, "class") or ""
    -- the asteroid belts: type (its meshes, shader, density, width) and inner_radius
    local belts = world.field(obj, "asteroid_belts")
    for _, b in ipairs(belts and world.blocks(belts) or {}) do
        local t = f.belt_types[tostring(world.field(b, "type") or ""):gsub('"', "")]
        local r = tonumber(world.field(b, "inner_radius"))
        if t and r then
            out.belts[#out.belts + 1] = { radius = r, meshes = t.meshes, shader = t.shader, density = t.density, width = t.width }
        end
    end
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
                -- binary_flags bit 8: the planet has a ring (CPlanet +0xcb5, CHasRingTrigger)
                ring = math.floor((tonumber(world.field(p, "binary_flags")) or 0) / 256) % 2 == 1,
                look = look(f, class),
                name = require("render.galaxy").name_block(world.field(p, "name")),
                owner = tonumber(world.field(p, "owner")) or -1,
                colony = world.field(p, "colony") ~= nil,
                deposits = (function()
                    -- what its deposits produce, summed by resource (CPlanet::ListResourcesForMapmode)
                    local sums, order = {}, {}
                    for _, did in ipairs(world.list(world.field(p, "deposits"))) do
                        local d = world.object("deposit", tonumber(did))
                        local ty = d and tostring(world.field(d, "type") or ""):gsub('"', "")
                        local def = ty and f.deposits[ty]
                        local produces = def and get(get(def.block, "resources"), "produces")
                        for _, e in ipairs(type(produces) == "table" and produces or {}) do
                            if e.op and e.key and e.value and e.value.text and tonumber(e.value.text) then
                                local r = e.key.text
                                if not sums[r] then
                                    order[#order + 1] = r
                                end
                                sums[r] = (sums[r] or 0) + tonumber(e.value.text)
                            end
                        end
                    end
                    local out = {}
                    for _, r in ipairs(order) do
                        if sums[r] > 0 then
                            out[#out + 1] = { resource = r, amount = sums[r] }
                        end
                    end
                    return out
                end)(),
            }
        end
    end
    -- the ships of the fleets in the system (stations too)
    for _, fid in ipairs(world.all("fleet")) do
        local fl = world.object("fleet", fid)
        local origin = tonumber(world.path(fl, "movement_manager", "coordinate", "origin"))
        if origin == id then
            local station = world.path(fl, "properties", "station") == "yes"
            -- the owner's empire colour (CEmpireFlag::GetEntityColor: the first of its flag's
            -- colours with a swatch, its `ship` value)
            -- (a fleet's owner: the country whose fleets_manager.owned_fleets lists it)
            local owner = fleet_owners()[fid]
            local country = owner and world.object("country", owner)
            local ship_colour
            for _, name in ipairs(country and world.list(world.path(country, "flag", "colors")) or {}) do
                name = tostring(name):gsub('"', "")
                if not ship_colour and f.ship_swatches[name] then
                    ship_colour = f.ship_swatches[name]
                end
            end
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
                        -- PrimaryColor when the culture has ship_color, and its camera lights
                        colour = (f.cultures[m.culture or ""] or {}).ship_color and ship_colour or nil,
                        lighting = culture_lighting(f, m.culture or ""),
                    }
                end
            end
        end
    end
    return out
end

-- system.design_model(game_dir, design_id, owner) -> a ship design's model as a ship's (its first
-- growth stage: the frame entity, the sections' entities at the size's slots, their turrets; the
-- owner's colour when the culture takes it; the culture's lighting), for the ship designer's 3D
-- view (render.windows.designer); nil without one
function system.design_model(game_dir, design_id, owner)
    local design = world.object("ship_design", design_id)
    local stage = design and world.blocks(world.field(design, "growth_stages"))[1]
    local size = stage and tostring(world.field(stage, "ship_size") or ""):gsub('"', "")
    if not size then
        return nil
    end
    local plain = { size = size, sections = {} }
    for _, s in ipairs(world.fields(stage, "section")) do
        local sec = { template = tostring(world.field(s, "template") or ""):gsub('"', ""), slot = tostring(world.field(s, "slot") or ""):gsub('"', ""), components = {} }
        for _, c in ipairs(world.fields(s, "component")) do
            sec.components[tostring(world.field(c, "slot") or ""):gsub('"', "")] = tostring(world.field(c, "template") or ""):gsub('"', "")
        end
        plain.sections[#plain.sections + 1] = sec
    end
    return system.stage_model(game_dir, plain, tostring(world.field(design, "graphical_culture") or ""):gsub('"', ""), owner)
end

-- system.stage_model(game_dir, stage, culture, owner, colours) -> the model of a design's stage
-- { size, sections = { { template, slot, components = { [slot] = template } } } } (the ship
-- designer's design under modification), as design_model's; colours: the flag's colour names
-- (an empire design's, without an owner: the new game's preview)
function system.stage_model(game_dir, stage, culture, owner, colours)
    local f = files(game_dir)
    local size = stage and stage.size
    if not size then
        return nil
    end
    culture = (culture and culture ~= "") and culture or (stage.culture or "")
    if culture == "" and owner then
        -- a design without its own culture: its owner's [I]
        local c = world.object("country", owner)
        culture = tostring(c and world.field(c, "graphical_culture") or ""):gsub('"', "")
    end
    local slots = f.slots[size] or {}
    local frame = first_entity({ culture .. "_" .. size .. "_entity", f.slots[size .. "#entity"] and culture .. "_" .. f.slots[size .. "#entity"], f.slots[size .. "#entity"] })
    local sections = {}
    for _, s in ipairs(stage.sections or {}) do
        local ent = f.templates[s.template]
        local name = ent and first_entity({ culture .. "_" .. ent, ent })
        if name then
            local turrets = {}
            local cs = f.component_slots[s.template] or {}
            for slot, template in pairs(s.components or {}) do
                local sl = cs[slot]
                local wt = f.weapon_types[template]
                local te = sl and wt and (f.slot_entities[sl.template] or {})[wt]
                local tname = te and first_entity({ culture .. "_" .. te, te })
                if tname and sl.locator ~= "" then
                    turrets[#turrets + 1] = { entity = tname, locator = sl.locator }
                end
            end
            sections[#sections + 1] = { entity = name, locator = slots[s.slot] or "", turrets = turrets }
        end
    end
    local country = owner and world.object("country", owner)
    local colour
    for _, n in ipairs(colours or (country and world.list(world.path(country, "flag", "colors"))) or {}) do
        n = tostring(n):gsub('"', "")
        colour = colour or f.ship_swatches[n]
    end
    return {
        size = size, culture = culture, frame = frame or "", sections = sections,
        colour = (f.cultures[culture] or {}).ship_color and colour or nil,
        lighting = culture_lighting(f, culture),
    }
end

-- system.default_sections(game_dir, size) -> a stage's sections for a ship size shown without a
-- design (the creator's ship browser): for each of the size's section slots, the first section
-- template (in the files' order) of that size fitting the slot, no components [I: the game's
-- CShipBrowser choice not traced]
function system.default_sections(game_dir, size)
    local f = files(game_dir)
    local out = {}
    for _, slot in ipairs(f.slot_order[size] or {}) do
        for _, key in ipairs(f.template_order) do
            local fit = f.template_fit[key]
            if fit.size == size and fit.slot == slot then
                out[#out + 1] = { template = key, slot = slot, components = {} }
                break
            end
        end
    end
    return out
end

-- system.browser_size(game_dir, culture, size) -> the ship size a culture's ship is shown with
-- for size: size when the culture has its frame (or the models are not read yet), else the first
-- size (in the files' order) made for the culture (`graphical_culture`: the biological sets'
-- mauler_stage_1 for a corvette) [I: the game's ship browser lists other sizes for those sets]
function system.browser_size(game_dir, culture, size)
    local f = files(game_dir)
    local models = RENDER_MODELS and RENDER_MODELS.entities
    if not models or next(models) == nil or first_entity({ culture .. "_" .. size .. "_entity",
            f.slots[size .. "#entity"] and culture .. "_" .. f.slots[size .. "#entity"] }) then
        return size
    end
    if not f.size_cultures_sorted then
        table.sort(f.size_cultures, function(a, b)
            if a.file ~= b.file then return a.file < b.file end
            return a.line < b.line
        end)
        f.size_cultures_sorted = true
    end
    for _, s in ipairs(f.size_cultures) do
        for _, c in ipairs(s.cultures) do
            if c == culture then
                return s.name
            end
        end
    end
    return size
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

-- system.world_settings(game_dir, world) -> the gfx/worldgfx settings of a world tag ("default",
-- "system_view", "g_star", ...): numbers and strings by key, colours (hsv { }) as rgb, lists as
-- lists, `backgrounds` = { { texture, below = distance_to_core_percent bound, ycocg } } in order
function system.world_settings(game_dir, world)
    local f = files(game_dir)
    return f.worldgfx_settings[world] or f.worldgfx_settings.default
end

-- system.light(game_dir, name) -> { r, g, b, intensity } of a light of gfx/lights/*.asset
-- (`light = { name color = { r = { 1.0 } g = { 1.0 } b = { 1.0 } } intensity = 2.5 ... }`), or nil
local lights
function system.light(game_dir, name)
    if not lights then
        lights = {}
        for _, rel in ipairs(source.files(game_dir, "gfx/lights", "asset")) do
            for _, e in ipairs(source.parse(game_dir, rel) or {}) do
                if e.op and e.key and e.key.text == "light" and type(e.value) == "table" then
                    local b = e.value
                    local n = get(b, "name")
                    local c = get(b, "color")
                    local function channel(k)
                        local v = get(c, k)
                        if type(v) == "table" then
                            for _, t in ipairs(v) do
                                if t.text then
                                    return tonumber(t.text)
                                end
                            end
                        end
                        return tonumber(v) or 1
                    end
                    if n then
                        local i = get(b, "intensity")
                        lights[n] = { channel("r"), channel("g"), channel("b"), tonumber(type(i) == "string" and i:match("[%d%.]+") or i) or 1 }
                    end
                end
            end
        end
    end
    return lights[name]
end

return system
