-- render/models.lua : the game's 3D model definitions, read in place from gfx/models/**:
-- `objectTypes = { pdxmesh = { name file scale meshsettings = { name texture_diffuse
-- texture_normal texture_specular shader } animation ... } }` in the .gfx files, and
-- `entity = { name pdxmesh scale meshsettings = { ... } attach = { locator = "entity" }
-- state = { ... } }` in the .asset files (docs/render.md section 7). Portraits are skipped.
--
--   local models = require("render.models")
--   local db = models.load(game_dir)
--   models.describe(db, "desert_planet_01_entity")
--     -> { kind = "entity", name, pdxmesh, file, scale, settings = { { shape, diffuse, normal,
--          specular, shader } }, attach = { { locator, entity } } }

local source = require("stellar.script.source")

local models = {}

-- a key's value; the last one when the key is repeated, as the game reads it [I]
-- (mammalian_01_science_mesh: `scale = 1.0` ... `scale = 2.8`)
local function get(block, key)
    key = key:lower()
    local found
    for _, e in ipairs(type(block) == "table" and block or {}) do
        if e.op and e.key and e.key.text:lower() == key then
            found = e.value.text or e.value
        end
    end
    return found
end

local function each(block, key, f)
    key = key:lower()
    for _, e in ipairs(type(block) == "table" and block or {}) do
        if e.op and e.key and e.key.text:lower() == key and type(e.value) == "table" and e.value.text == nil then
            f(e.value)
        end
    end
end

-- f(block) for each block under `key` anywhere in a tree (not inside another such block)
local function find(block, key, f)
    key = key:lower()
    for _, e in ipairs(type(block) == "table" and block or {}) do
        if e.op and e.key and type(e.value) == "table" and e.value.text == nil then
            local k = e.key.text:lower()
            if k == key then
                f(e.value)
            elseif k ~= "meshsettings" and k ~= "animation" and k ~= "state" then
                find(e.value, key, f)
            end
        end
    end
end

local function settings_of(block)
    local out = {}
    each(block, "meshsettings", function(m)
        out[#out + 1] = {
            -- a Maya path (a|b|cShape) names its last shape
            shape = (get(m, "name") or ""):match("([^|]*)$"),
            diffuse = get(m, "texture_diffuse"), normal = get(m, "texture_normal"),
            specular = get(m, "texture_specular"), shader = get(m, "shader"),
        }
    end)
    return out
end

-- the particle effects an entity's default state starts (`default_state = "idle"`, `state = {
-- name = "idle" event = { node particle ... } }`): { { particle, node } }
local function state_particles(e)
    local want = get(e, "default_state") or "idle"
    local out = {}
    each(e, "state", function(s)
        if get(s, "name") == want then
            each(s, "event", function(ev)
                local p = get(ev, "particle")
                if p then
                    out[#out + 1] = { particle = p, node = get(ev, "node") or "" }
                end
            end)
        end
    end)
    return out
end

-- the files of gfx/models with an extension, recursively, no portraits
local function files(game_dir, ext)
    local out = {}
    local list
    if RUST and RUST.list_files then
        list = RUST.list_files(game_dir, "gfx/models", ext)
    else
        list = {}
    end
    for _, rel in ipairs(list) do
        if not rel:find("/portraits/", 1, true) then
            out[#out + 1] = rel
        end
    end
    return out
end

-- models.load(game_dir) -> { meshes = { [name] = def }, entities = { [name] = def }, files, seconds }
function models.load(game_dir)
    local t0 = RUST.clock()
    local db = { meshes = {}, entities = {}, files = 0, errors = 0 }
    for _, f in ipairs(files(game_dir, "gfx")) do
        local tree = source.parse(game_dir, f)
        if tree then
            db.files = db.files + 1
            -- `pdxmesh` blocks wherever they are: in objectTypes, or at the top level after a brace
            -- that closes objectTypes early (gfx/models/ships/aquatic_01/_aquatic_01_ships_meshes.gfx)
            find(tree, "pdxmesh", function(m)
                local name = get(m, "name")
                if name then
                    db.meshes[name] = {
                        name = name, file = (get(m, "file") or ""):gsub("\\", "/"),
                        scale = tonumber(get(m, "scale")) or 1, settings = settings_of(m), source = f,
                    }
                end
            end)
        else
            db.errors = db.errors + 1
        end
    end
    for _, f in ipairs(files(game_dir, "asset")) do
        local tree = source.parse(game_dir, f)
        if tree then
            db.files = db.files + 1
            find(tree, "entity", function(e)
                local name = get(e, "name")
                if name then
                    local attach = {}
                    each(e, "attach", function(a)
                        for _, s in ipairs(a) do
                            if s.op and s.key and s.value.text then
                                attach[#attach + 1] = { locator = s.key.text, entity = s.value.text }
                            end
                        end
                    end)
                    db.entities[name] = {
                        name = name, pdxmesh = get(e, "pdxmesh"), clone = get(e, "clone"), scale = tonumber(get(e, "scale")) or 1,
                        settings = settings_of(e), attach = attach, source = f, particles = state_particles(e),
                    }
                end
            end)
        else
            db.errors = db.errors + 1
        end
    end
    db.seconds = RUST.clock() - t0
    return db
end

-- an entity with `clone = "other"` and no pdxmesh of its own: the other's mesh, settings and
-- attachments, its own settings over them [I]
local function resolve(db, e, depth)
    if e.pdxmesh or not e.clone or depth > 8 then
        return e
    end
    local base = db.entities[e.clone]
    if not base then
        return e
    end
    base = resolve(db, base, depth + 1)
    local settings = {}
    for _, s in ipairs(base.settings or {}) do
        settings[#settings + 1] = s
    end
    for _, s in ipairs(e.settings or {}) do
        settings[#settings + 1] = s
    end
    return {
        name = e.name, pdxmesh = base.pdxmesh, scale = (base.scale or 1) * (e.scale or 1),
        settings = settings, attach = #(e.attach or {}) > 0 and e.attach or base.attach,
        source = e.source, clone = e.clone,
        particles = #(e.particles or {}) > 0 and e.particles or base.particles,
    }
end

-- a model by name: an entity (its pdxmesh's file, the entity's settings over the pdxmesh's) or a
-- pdxmesh; nil, why if neither
function models.describe(db, name)
    local e = db.entities[name]
    if e then
        e = resolve(db, e, 0)
    end
    local m
    local out = { name = name, settings = {}, attach = {} }
    if e then
        out.kind = "entity"
        m = e.pdxmesh and db.meshes[e.pdxmesh]
        if not m then
            if not e.pdxmesh then
                return nil, "entity " .. name .. ": no pdxmesh (a locator dummy or an effect)"
            end
            return nil, "entity " .. name .. ": its pdxmesh " .. e.pdxmesh .. " is not defined"
        end
        out.pdxmesh = e.pdxmesh
        out.scale = (e.scale or 1) * (m.scale or 1)
        out.attach = e.attach
        out.particles = e.particles or {}
    else
        m = db.meshes[name]
        if not m then
            return nil, "no entity or pdxmesh " .. name
        end
        out.kind = "pdxmesh"
        out.pdxmesh = name
        out.scale = m.scale or 1
    end
    out.file = m.file
    -- the directories a texture name of the settings is looked for in: the entity's file's, the
    -- pdxmesh's file's (then the mesh file's)
    out.dirs = {}
    for _, src in ipairs({ e and e.source or false, m.source or false }) do
        if src then
            out.dirs[#out.dirs + 1] = src:match("^(.*)/[^/]*$") or ""
        end
    end
    -- the pdxmesh's settings, then the entity's over them (by shape)
    local by_shape = {}
    for _, s in ipairs(m.settings) do
        by_shape[s.shape] = s
    end
    for _, s in ipairs(e and e.settings or {}) do
        local base = by_shape[s.shape] or {}
        by_shape[s.shape] = {
            shape = s.shape, diffuse = s.diffuse or base.diffuse, normal = s.normal or base.normal,
            specular = s.specular or base.specular, shader = s.shader or base.shader,
        }
    end
    for _, s in pairs(by_shape) do
        out.settings[#out.settings + 1] = s
    end
    return out
end

-- the entity a planet class draws (common/planet_classes `entity`, `entity_scale`): the class's
-- entity name with `_01_entity` (the first of its variants), or `_entity`
function models.planet_entity(db, defs, class)
    local d = defs and defs.get and defs.get("common/planet_classes", class)
    local base = d and get(d.block, "entity")
    local scale = d and tonumber(get(d.block, "entity_scale")) or nil
    local colour = d and get(d.block, "atmosphere_color")
    if not base then
        return nil
    end
    for _, n in ipairs({ base .. "_01_entity", base .. "_entity", base }) do
        if db.entities[n] then
            return n, scale, colour
        end
    end
    return nil
end

return models
