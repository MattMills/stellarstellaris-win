-- render/texture_set.lua : the textures a game can show, by what shows them (docs/profiling.md
-- section 13): what the renderer reads ahead, compressed, at a load.
--
--   require("render.texture_set").world(game_dir, player)   -- where the world is (the simulation's
--     runtime) -> lines `KIND<TAB>NAME`: `culture NAME` (the player's ships'), `ship ENTITY` (every ship design's frame, sections and turrets, as
--        render.system.design_model makes them), `planet ENTITY` (every planet's and star's, its
--        class's entity and variant, as render.system.extract), `portrait ENTITY` and
--        `portrait_texture PATH` (the portraits of the species present: their portrait groups'
--        portraits, render.portraits' database)
--   require("render.texture_set").gui()   -- where RENDER_GFX is (the front end's runtime)
--     -> lines `gui<TAB>PATH`: every sprite's texture of the .gfx files the windows lay out from
--
-- The entities' textures are the models' (models.rs resolves them: their meshes' settings), read
-- by the caller.

local M = {}

local function unquote(v)
    return v and (tostring(v):gsub('"', "")) or nil
end

-- every string field `entity` or `frame` of a model table (render.system.stage_model's), any depth
local function entities_of(t, out, depth)
    if type(t) ~= "table" or (depth or 0) > 6 then
        return
    end
    for k, v in pairs(t) do
        if (k == "entity" or k == "frame") and type(v) == "string" and v ~= "" then
            out[v] = true
        elseif type(v) == "table" then
            entities_of(v, out, (depth or 0) + 1)
        end
    end
end

-- every string value of a parsed block (any depth) ending in an image's extension, and every
-- value naming a key of `names`
local function scan_block(b, images, refs, names, depth)
    if type(b) ~= "table" or (depth or 0) > 12 then
        return
    end
    for _, e in ipairs(b) do
        local v = e.value or e
        local text = v and v.text
        if text then
            local s = unquote(text)
            local low = s:lower()
            if low:match("%.dds$") or low:match("%.tga$") then
                images[s] = true
            elseif names and names[s] then
                refs[s] = true
            end
        elseif type(v) == "table" then
            scan_block(v, images, refs, names, (depth or 0) + 1)
        end
        if e.key and e.key.text and names and names[e.key.text] then
            refs[e.key.text] = true
        end
    end
end

function M.world(game_dir, player)
    local world = require("engine.world")
    local system = require("render.system")
    local out = {}
    local seen = {}
    local function add(kind, name)
        local k = kind .. "\t" .. name
        if not seen[k] then
            seen[k] = true
            out[#out + 1] = k
        end
    end
    -- the player's ships' culture (their entities are named after it: read first)
    local pc = player and world.object("country", player)
    local culture = pc and unquote(world.field(pc, "graphical_culture"))
    if culture and culture ~= "" then
        add("culture", culture)
    end
    -- the ships: every design's model (stations' too)
    for _, id in ipairs(world.all("ship_design")) do
        local ok, model = pcall(system.design_model, game_dir, tonumber(id) or id, nil)
        if ok and model then
            local set = {}
            entities_of(model, set)
            for e in pairs(set) do
                add("ship", e)
            end
        end
    end
    -- the planets and stars: their class's entity, the planet's variant
    local source = require("stellar.script.source")
    local classes = source.definitions(game_dir, "common/planet_classes")
    local db = RENDER_MODELS or require("render.models").load(game_dir)
    RENDER_MODELS = db
    local function first(names)
        for _, n in ipairs(names) do
            if db.entities[n] or db.meshes[n] then
                return n
            end
        end
    end
    for _, pid in ipairs(world.all("planet")) do
        local p = world.object("planet", tonumber(pid) or pid)
        if p then
            local class = unquote(world.field(p, "planet_class") or "")
            local d = classes[class]
            local base
            for _, e in ipairs(d and d.block or {}) do
                if e.op and e.key and e.key.text == "entity" and e.value.text then
                    base = unquote(e.value.text)
                end
            end
            if base then
                local variant = tonumber(world.field(p, "entity")) or 0
                local ent = first({ string.format("%s_%02d_entity", base, variant + 1), base .. "_01_entity", base .. "_entity", base })
                if ent then
                    add("planet", ent)
                end
            end
        end
    end
    -- the species' portraits: the portrait groups of the species present, their portraits
    local portraits = require("render.portraits").db(game_dir)
    local keys = {}
    for _, sid in ipairs(world.all("species")) do
        local s = world.object("species", tonumber(sid) or sid)
        local key = s and unquote(world.field(s, "portrait"))
        if key and key ~= "" then
            keys[key] = true
        end
    end
    for key in pairs(keys) do
        local images, refs = {}, {}
        local group = portraits.groups[key]
        if group then
            scan_block(group, images, refs, portraits.portraits)
        elseif portraits.portraits[key] then
            refs[key] = true
        end
        for name in pairs(refs) do
            local p = portraits.portraits[name]
            local inner = {}
            scan_block(p, images, inner, nil)
            for _, e in ipairs(p or {}) do
                if e.op and e.key and e.key.text == "entity" and e.value.text then
                    add("portrait", unquote(e.value.text))
                end
            end
        end
        for path in pairs(images) do
            add("portrait_texture", path)
        end
    end
    return table.concat(out, "\n")
end

function M.gui()
    local out, seen = {}, {}
    for _, s in pairs((RENDER_GFX and RENDER_GFX.sprites) or {}) do
        local t = type(s) == "table" and s.texture
        if t and t ~= "" and not seen[t] then
            seen[t] = true
            out[#out + 1] = "gui\t" .. t
        end
    end
    table.sort(out)
    return table.concat(out, "\n")
end

return M
