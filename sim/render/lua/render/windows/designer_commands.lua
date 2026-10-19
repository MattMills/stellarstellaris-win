-- render/windows/designer_commands.lua : what the ship designer's buttons do to the world, run in
-- the simulation's runtime (designer.rs: Clock::query, as the other windows' commands), through
-- the engine's own ship designer (engine.ai.designer: CCountry::CreateShipDesign's sections and
-- components, CCreateOrUpdateShipDesignCommand) (docs/windows/designer.md "The buttons").
--
--   local dc = require("render.windows.designer_commands")
--   dc.data(game_dir)                          the window's data (designer.extract), serialized
--   dc.generate(country, size, role, seed)     a stage with the best components (serialized):
--                                              Auto-Complete, a role's design, a new design's
--                                              required components; the world is not changed
--   dc.name(country, size, r)                  a name for a design of the size (randomize_name)
--   dc.save(country, base, stage, name, role, upgrade, literal)
--                                              the design added to the country (its base design,
--                                              the one it was made from, replaced in the list)
--   dc.save_many(country, list, size, ...)     a creature design's variants, each as dc.save
--   dc.delete(country, id)                     the design out of the country's list
--   dc.auto_generate(country, on)              the country's auto-generation of designs
--
-- Each returns a string: "changed ..." when the world changed, "ok ..." with a result, "refused:
-- why" when the game would not do it either. A missing object is a refusal, never an error.

local world = require("engine.world")

local dc = {}

local function designer()
    return require("engine.ai.designer")
end

local function ser(v)
    return require("render.windows.designer").serialize(v)
end

local function collection(country)
    local c = world.object("country", tonumber(country) or -1)
    if not c then
        return nil, nil
    end
    local coll = world.field(c, "ship_design_collection")
    if type(coll) ~= "table" then
        coll = world.child(c, "ship_design_collection")
    end
    return c, coll
end

function dc.data(game_dir)
    if not RENDER_MODELS then
        RENDER_MODELS = require("render.models").load(game_dir)
    end
    return ser(require("render.windows.designer").extract(game_dir))
end

-- the AI designer's stage in the window's form: components by slot
local function window_stage(stage)
    local out = { size = stage.size, sections = {}, required = {} }
    for _, s in ipairs(stage.sections or {}) do
        local cs = {}
        for _, c in ipairs(s.components or {}) do
            cs[c.slot] = c.template
        end
        out.sections[#out.sections + 1] = { template = s.template, slot = s.slot, components = cs }
    end
    for _, r in ipairs(stage.required or {}) do
        out.required[#out.required + 1] = r
    end
    return out
end

function dc.generate(country, size, role, seed)
    local ok, stage = pcall(function()
        return designer().plain(designer().generate(tonumber(country), size, role or "", tonumber(seed) or 0))
    end)
    if not ok then
        return "refused: " .. tostring(stage)
    end
    if not stage then
        return "refused: no ship size " .. tostring(size)
    end
    return "ok " .. ser(window_stage(stage))
end

-- the components the country can build on a ship of the size (the component lists)
function dc.buildable(country, size)
    local ok, list = pcall(designer().buildable, tonumber(country), size)
    if not ok then
        return "refused: " .. tostring(list)
    end
    local set = {}
    for _, k in ipairs(list) do
        set[k] = true
    end
    return "ok " .. ser(set)
end

function dc.name(country, size, r)
    local ok, key = pcall(designer().class_name, tonumber(country), size, tonumber(r) or 0)
    if not ok then
        return "refused: " .. tostring(key)
    end
    return "ok " .. tostring(key)
end

-- a block copied (a design's name with its variables)
local function copy(v)
    if type(v) ~= "table" then
        return v
    end
    local out = {}
    for k, x in pairs(v) do
        out[k] = copy(x)
    end
    return out
end

function dc.save(country, base, stage_src, name_key, role, upgrade, literal)
    local c = collection(country)
    if not c then
        return "refused: no country " .. tostring(country)
    end
    local stage = type(stage_src) == "string" and load("return " .. stage_src)() or stage_src
    if type(stage) ~= "table" or not stage.size then
        return "refused: no design"
    end
    -- the engine's form: components as a list (by slot name: the save's order [I])
    local plain = { size = stage.size, sections = {}, required = {} }
    for _, s in ipairs(stage.sections or {}) do
        local cs = {}
        for slot, t in pairs(s.components or {}) do
            cs[#cs + 1] = { slot = slot, template = t }
        end
        table.sort(cs, function(a, b) return a.slot < b.slot end)
        plain.sections[#plain.sections + 1] = { template = s.template, slot = s.slot, components = cs }
    end
    for _, r in ipairs(stage.required or {}) do
        plain.required[#plain.required + 1] = r
    end
    base = tonumber(base)
    local old = base and base > 0 and world.object("ship_design", base) or nil
    local id = designer().execute_create(tonumber(country), plain, (name_key ~= "" and name_key) or "SHIP_DESIGN", role ~= "" and role or nil)
    local d = world.object("ship_design", id)
    if d then
        -- its name: the base design's (with its variables) unless a new one was chosen
        if old and (name_key == nil or name_key == "") then
            for _, e in ipairs(d) do
                if e.op and e.key and e.key.text == "name" then
                    for _, o in ipairs(old) do
                        if o.op and o.key and o.key.text == "name" then
                            world.set_entry(d, e, copy(o.value))
                        end
                    end
                end
            end
        end
        -- a name typed in the rename box: the text itself (`literal = yes`, as a save writes a
        -- renamed design)
        if (literal == true or literal == "yes") and name_key and name_key ~= "" then
            local nb = world.field(d, "name")
            if type(nb) == "table" then
                world.set(nb, "literal", "yes")
            end
        end
        if upgrade == false or upgrade == "no" then
            world.set(d, "upgrade_ship_components", "no")
        end
    end
    -- the base design leaves the list: the game's CreateOrUpdateShipDesign replaces the design of
    -- the same name [I: its fleet templates not retrofitted]
    if old then
        dc.delete(country, base)
    end
    return "changed " .. tostring(id)
end

-- a creature design's variants (BuildAllCreatureDesignsVariants): each saved as dc.save does, the
-- answer the one of the size shown
function dc.save_many(country, list_src, size, name_key, role, upgrade, literal)
    local list = type(list_src) == "string" and load("return " .. list_src)() or list_src
    local shown_id
    for _, v in ipairs(list or {}) do
        local r = dc.save(country, v.base or 0, v.stage, name_key, role, upgrade, literal)
        local id = tonumber(r:match("^changed (%d+)"))
        if not id then
            return r
        end
        if v.stage.size == size then
            shown_id = id
        end
    end
    return "changed " .. tostring(shown_id or "")
end

function dc.delete(country, id)
    local _, coll = collection(country)
    if not coll then
        return "refused: no country " .. tostring(country)
    end
    local list = world.field(coll, "ship_design")
    if type(list) ~= "table" then
        return "refused: no designs"
    end
    local before = #list
    world.remove_value(list, tostring(id))
    if #list == before then
        return "refused: no design " .. tostring(id) .. " in the list"
    end
    return "changed deleted " .. tostring(id)
end

function dc.auto_generate(country, on)
    local _, coll = collection(country)
    if not coll then
        return "refused: no country " .. tostring(country)
    end
    if on == true or on == "1" or on == "yes" then
        world.set(coll, "auto_gen_design", "yes")
    else
        world.set(coll, "auto_gen_design", "no")
    end
    return "changed auto_gen_design " .. tostring(on)
end

return dc
