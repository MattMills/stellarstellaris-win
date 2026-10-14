-- render/particles.lua : the game's particle definitions, read in place from gfx/particles/**:
-- `pdxparticle = { name type scale }` in the .gfx files (a particle effect's name -> its type)
-- and `particle = { name subsystem = { ... } }` in the .asset files (the type's subsystems:
-- emitter, texture, colour, life, emission, size, rotation; its `animation` curves over a
-- particle's life, which a size or alpha names). The renderer draws a steady-state snapshot of a
-- subsystem's particles (particles.rs).
--
--   local particles = require("render.particles")
--   local db = particles.load(game_dir)
--   particles.describe(db, "a_class_star_particle") -> { scale, subsystems = { ... } }

local source = require("stellar.script.source")

local particles = {}

local function get(block, key)
    local found
    for _, e in ipairs(type(block) == "table" and block or {}) do
        if e.op and e.key and e.key.text == key then
            found = e.value.text or e.value
        end
    end
    return found
end

-- "255.000,fade_in_out" -> 255, "fade_in_out"
local function number_and_curve(v)
    if type(v) ~= "string" then
        return nil
    end
    local n, curve = v:match("^([%-%d%.]+),?(.*)$")
    return tonumber(n), curve ~= "" and curve or nil
end

-- a block of numbers ({ 4.510 0.000 }, { 0.240,size_grow 0.160 }) -> { 4.51, 0, curve = ... }
local function numbers(b)
    local out = {}
    for _, t in ipairs(type(b) == "table" and b or {}) do
        if t.text then
            local n, c = number_and_curve(t.text)
            out[#out + 1] = n or 0
            out.curve = out.curve or c
        end
    end
    return out
end

local function subsystem(b)
    local tex = get(b, "texture")
    local col = get(b, "color")
    local alpha, alpha_curve = number_and_curve(type(col) == "table" and get(col, "alpha") or nil)
    return {
        name = get(b, "name") or "",
        max_amount = tonumber(get(b, "max_amount")) or 0,
        emitter = get(b, "emitter_type") or "point",
        radius = numbers(get(b, "sphere_emitter_radius")),
        yaw = numbers(get(b, "sphere_emitter_yaw")),
        pitch = numbers(get(b, "sphere_emitter_pitch")),
        hide = get(b, "hide") == "yes",
        local_space = get(b, "local_space") == "yes",
        billboard = get(b, "billboard") ~= "no",
        texture = type(tex) == "table" and (get(tex, "file") or ""):gsub("\\", "/") or "",
        frames_x = type(tex) == "table" and tonumber(get(tex, "x")) or 1,
        frames_y = type(tex) == "table" and tonumber(get(tex, "y")) or 1,
        shader = type(tex) == "table" and get(tex, "shader") or "",
        colour = type(col) == "table" and { tonumber(get(col, "x")) or 255, tonumber(get(col, "y")) or 255, tonumber(get(col, "z")) or 255, alpha or 255 } or { 255, 255, 255, 255 },
        alpha_curve = alpha_curve,
        life = numbers(get(b, "life")),
        emission = tonumber(get(b, "emission")) or 0,
        duration = tonumber(get(b, "duration")) or -1,
        size = numbers(get(b, "size")),
        rotation = numbers(get(b, "rotation")),
        trail = get(b, "trail") == "yes",
    }
end

function particles.load(game_dir)
    local db = { effects = {}, types = {}, curves = {}, files = 0 }
    for _, rel in ipairs(RUST.list_files(game_dir, "gfx/particles", "gfx")) do
        for _, e in ipairs(source.parse(game_dir, rel) or {}) do
            local function walk(block)
                for _, x in ipairs(block) do
                    if x.op and x.key and type(x.value) == "table" and x.value.text == nil then
                        if x.key.text == "pdxparticle" then
                            local n = get(x.value, "name")
                            if n then
                                db.effects[n] = { type = get(x.value, "type"), scale = tonumber(get(x.value, "scale")) or 1 }
                            end
                        else
                            walk(x.value)
                        end
                    end
                end
            end
            walk({ e })
        end
        db.files = db.files + 1
    end
    for _, rel in ipairs(RUST.list_files(game_dir, "gfx/particles", "asset")) do
        for _, e in ipairs(source.parse(game_dir, rel) or {}) do
            if e.op and e.key and e.key.text == "particle" and type(e.value) == "table" then
                local n = get(e.value, "name")
                if n then
                    local subs, curves = {}, {}
                    for _, x in ipairs(e.value) do
                        if x.op and x.key and x.key.text == "subsystem" and type(x.value) == "table" then
                            subs[#subs + 1] = subsystem(x.value)
                        elseif x.op and x.key and x.key.text == "animation" and type(x.value) == "table" then
                            -- a curve over the particle's life: minValue + (maxValue - minValue) x
                            -- the curve's points (time, value), multiplying what names it
                            local a = x.value
                            local name = get(a, "name")
                            if name then
                                curves[name] = {
                                    min = tonumber(get(a, "minValue")) or 0,
                                    max = tonumber(get(a, "maxValue")) or 1,
                                    points = numbers(get(a, "curve")),
                                    life = get(a, "time") ~= "system",
                                }
                            end
                        end
                    end
                    db.types[n] = subs
                    db.curves[n] = curves
                end
            end
        end
        db.files = db.files + 1
    end
    return db
end

-- particles.describe(db, effect) -> { scale, subsystems } or nil, why
function particles.describe(db, name)
    local e = db.effects[name]
    if not e then
        return nil, "no particle effect " .. tostring(name)
    end
    local subs = db.types[e.type or ""]
    if not subs then
        return nil, "no particle type " .. tostring(e.type)
    end
    return { scale = e.scale, subsystems = subs, curves = db.curves[e.type or ""] or {} }
end

return particles
