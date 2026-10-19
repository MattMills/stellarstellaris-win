-- render/windows/designer.lua : the ship designer (interface/ship_designer.gui, CShipDesigner /
-- CShipDesignerBase), as the game fills it (4.5.2 Linux; docs/windows/designer.md).
--
--   local designer = require("render.windows.designer")
--   local data = designer.extract(game_dir, country)     -- in the runtime with the save's world
--   local items, report, insets = designer.build(ctx, data, state)   -- in the GUI's runtime
--
-- state = { design = ID | nil }: the design loaded (CShipDesignEntry::Click), none right after the
-- window opens (Show: SDataUnderModification::Clear). What shows [V, addresses in the notes]:
-- - the frame: the tabs (fleet manager, the ship designer's active one, the creature designer's
--   inactive one), the title SHIP_DESIGNER_COUNTRY, the auto-generate check box (the country's
--   ship_design_collection auto_gen_design), the close button;
-- - the designs list (UpdateDesignsList, GetAllDesignsToDisplay): new_ship_design_entry, then the
--   country's designs the country can build (a designable ship size whose prerequisites it has
--   researched) by ship size in definition order, a ship_design_header_entry (the size's
--   capitalised name) where the size changes; each ship_design_entry its name, a 3D view of it,
--   "Auto-Generated" (or "Auto") for an auto-generated design, the selection's glow;
-- - no design: ship_label "Specifications", no controls, no stats, no sections;
-- - a design: ship_label LONG_SHIPCLASS_NAME, the controls (its name in the rename box, the role,
--   the bottom buttons, auto-upgrade), the stats (SetupInfo's list from first_stat_position, 25
--   for a title, 22 a line), a section_instance_entry per section slot of the size (the
--   section's name on change_section, the weapon slots in a grid from the top, the utility slots
--   from the bottom, 56 a cell, at least three columns), the required components in a column
--   centred on required_slots_position, the 3D view of the ship (an inset: render.rs).

local world = require("engine.world")
local gui = require("render.gui")

local designer = {}

local FILE = "interface/ship_designer.gui"

local function str(v)
    return v ~= nil and (tostring(v):gsub('"', "")) or nil
end

-- designer.serialize(value) -> Lua source that rebuilds a plain table (strings, numbers,
-- booleans, tables), to carry data from the world's runtime to the GUI's
function designer.serialize(v)
    local t = type(v)
    if t == "string" then
        return string.format("%q", v)
    elseif t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then
            return "0"
        end
        return string.format("%.17g", v)
    elseif t == "boolean" then
        return tostring(v)
    elseif t == "table" then
        local out = {}
        for k, x in pairs(v) do
            local key = type(k) == "number" and ("[" .. k .. "]") or ("[" .. string.format("%q", tostring(k)) .. "]")
            out[#out + 1] = key .. "=" .. designer.serialize(x)
        end
        return "{" .. table.concat(out, ",") .. "}"
    end
    return "nil"
end

-- ---------------------------------------------------------------------------------- the world

local function player_id()
    for _, b in ipairs(world.blocks(world.meta and world.meta.player)) do
        local c = tonumber(world.field(b, "country"))
        if c then
            return c
        end
    end
    return 0
end

-- designer.extract(game_dir, country) -> { country, auto_generate, techs = { [tech] = true },
-- designs = { { id, name, size, role, auto_gen, upgrade, sections = { { template, slot,
-- components = { [slot] = template } } }, required = { template ... } } }, models = { [id] = model } }
function designer.extract(game_dir, country)
    country = country or player_id()
    local c = world.object("country", country)
    local data = { country = country, techs = {}, designs = {}, models = {} }
    if not c then
        return data
    end
    local coll = world.field(c, "ship_design_collection")
    data.auto_generate = world.field(coll or {}, "auto_gen_design") ~= "no"
    -- tech_status = { technology = "x" level = 1 technology = "y" ... } as the save writes it
    -- (world.statements: the world as tables or in its store)
    local ts = world.field(c, "tech_status")
    if type(ts) == "table" then
        for key, v in world.statements(ts) do
            if key == "technology" and type(v) ~= "table" then
                data.techs[str(v)] = true
            end
        end
    end
    local system = require("render.system")
    for _, v in ipairs(world.list(world.field(coll or {}, "ship_design"))) do
        -- the save's id, its generation in the high bits, is the store's key
        local id = tonumber(v)
        local d = id and world.object("ship_design", id)
        local stage = d and world.blocks(world.field(d, "growth_stages"))[1]
        if stage then
            local design = {
                id = id,
                name = require("render.galaxy").name_block(world.field(d, "name")),
                size = str(world.field(stage, "ship_size")) or "",
                role = str(world.field(d, "role")),
                auto_gen = world.field(d, "auto_gen_design") == "yes",
                upgrade = world.field(d, "upgrade_ship_components") == "yes",
                culture = str(world.field(d, "graphical_culture")),
                sections = {},
                required = {},
            }
            for _, s in ipairs(world.fields(stage, "section")) do
                local sec = { template = str(world.field(s, "template")) or "", slot = str(world.field(s, "slot")) or "", components = {} }
                for _, x in ipairs(world.fields(s, "component")) do
                    sec.components[str(world.field(x, "slot")) or ""] = str(world.field(x, "template"))
                end
                design.sections[#design.sections + 1] = sec
            end
            for key, v in world.statements(stage) do
                if key == "required_component" and type(v) ~= "table" then
                    design.required[#design.required + 1] = str(v)
                end
            end
            data.designs[#data.designs + 1] = design
            local ok, m = pcall(system.design_model, game_dir, id, country)
            if ok and m then
                data.models[id] = m
            end
        end
    end
    return data
end

-- ------------------------------------------------------------------------------ the game files

local source
local files_cache

-- the value of a number field through the file's own scripted variables and the global ones
local function value(v, vars)
    if type(v) ~= "string" then
        return nil
    end
    if v:sub(1, 1) == "@" then
        v = vars[v]
    end
    return tonumber(v)
end

local function get(block, key)
    for _, e in ipairs(type(block) == "table" and block or {}) do
        if e.op and e.key and e.key.text == key then
            return e.value.text or e.value
        end
    end
    return nil
end

-- a resources block's cost or upkeep: { resource = amount }
local function resources(block, kind, vars)
    local out = {}
    local r = get(block, "resources")
    local t = type(r) == "table" and get(r, kind)
    for _, e in ipairs(type(t) == "table" and t or {}) do
        if e.op and e.key and e.value.text then
            out[e.key.text] = value(e.value.text, vars) or 0
        end
    end
    return out
end

-- a modifier block: { name = amount }
local function modifier(block, vars)
    local out = {}
    for _, e in ipairs(type(block) == "table" and block or {}) do
        if e.op and e.key and e.value.text then
            out[e.key.text] = value(e.value.text, vars) or 0
        end
    end
    return out
end

-- every top-level definition of a folder's .txt files in file order, with each file's variables
local function each_definition(game_dir, folder, globals, fn)
    for _, f in ipairs(source.files(game_dir, folder, "txt")) do
        local tree = source.parse(game_dir, f) or {}
        local vars = setmetatable({}, { __index = globals })
        for _, e in ipairs(tree) do
            if e.op and e.key and e.key.text:sub(1, 1) == "@" and e.value.text then
                vars[e.key.text] = e.value.text
            end
        end
        for _, e in ipairs(tree) do
            if e.op and e.key and type(e.value) == "table" and e.value.text == nil and e.key.text:sub(1, 1) ~= "@" then
                fn(e.key.text, e.value, vars)
            end
        end
    end
end

-- slot sizes in the game's enum [I: by GFX_ship_designer_slot's frames: weapon frame = size + 4,
-- utility frame = size (NComponentUtils::GetComponentSlotIconFrame 0x230a580)]
local SLOT_SIZE = { small = 0, medium = 1, large = 2, torpedo = 3, extra_large = 4, titanic = 5, planet_killer = 6, aux = 11 }

local function files(game_dir)
    if files_cache then
        return files_cache
    end
    source = source or require("stellar.script.source")
    local globals = {}
    for _, f in ipairs(source.files(game_dir, "common/scripted_variables", "txt")) do
        for _, e in ipairs(source.parse(game_dir, f) or {}) do
            if e.op and e.key and e.key.text:sub(1, 1) == "@" and e.value.text then
                globals[e.key.text] = e.value.text
            end
        end
    end
    local F = { sizes = {}, size_order = {}, sections = {}, components = {}, slot_templates = {}, weapons = {}, section_count = 0, component_count = 0 }
    -- ship sizes, in definition order
    each_definition(game_dir, "common/ship_sizes", globals, function(name, b, vars)
        local s = {
            name = name, order = #F.size_order + 1,
            hp = value(get(b, "max_hitpoints"), vars) or 0,
            speed = value(get(b, "max_speed"), vars) or 0,
            build_time = value(get(b, "base_buildtime"), vars) or 0,
            size = value(get(b, "size_multiplier"), vars) or 1,
            designable = get(b, "is_designable") ~= "no",
            modifier = modifier(get(b, "modifier"), vars),
            upkeep = resources(b, "upkeep", vars),
            cost = resources(b, "cost", vars),
            prerequisites = {}, slots = {}, required = {}, roles = {},
        }
        for _, e in ipairs(type(get(b, "prerequisites")) == "table" and get(b, "prerequisites") or {}) do
            if e.text then
                s.prerequisites[#s.prerequisites + 1] = str(e.text)
            end
        end
        local ss = get(b, "section_slots")
        for _, e in ipairs(type(ss) == "table" and ss or {}) do
            if e.op and e.key then
                s.slots[#s.slots + 1] = str(e.key.text)
            end
        end
        for _, e in ipairs(b) do
            if e.op and e.key and e.key.text == "required_component_set" and e.value.text then
                s.required[#s.required + 1] = str(e.value.text)
            end
        end
        for _, e in ipairs(type(get(b, "ship_roles")) == "table" and get(b, "ship_roles") or {}) do
            if e.text then
                s.roles[#s.roles + 1] = e.text
            end
        end
        if not F.sizes[name] then
            F.size_order[#F.size_order + 1] = name
        end
        F.sizes[name] = s
    end)
    -- slot templates: size and kind
    each_definition(game_dir, "common/component_slot_templates", globals, function(name, b)
        F.slot_templates[name] = { size = str(get(b, "size")) or "small", kind = str(get(b, "component")) or "weapon" }
    end)
    -- section templates: their component slots in order (component_slot blocks, then the utility
    -- slots their counts make: SMALL_UTILITY_1.., MEDIUM_UTILITY_1.., LARGE_UTILITY_1.., AUX_UTILITY_1..)
    each_definition(game_dir, "common/section_templates", globals, function(kind, b, vars)
        if kind ~= "ship_section_template" then
            return
        end
        local key = str(get(b, "key"))
        if not key then
            return
        end
        local sec = { key = key, entity = str(get(b, "entity")), cost = resources(b, "cost", vars), upkeep = resources(b, "upkeep", vars), slots = {},
            size = str(get(b, "ship_size")), fits = str(get(b, "fits_on_slot")), order = F.section_count + 1, prerequisites = {} }
        F.section_count = F.section_count + 1
        local pre = get(b, "prerequisites")
        for _, e in ipairs(type(pre) == "table" and pre or {}) do
            if e.text then
                sec.prerequisites[#sec.prerequisites + 1] = str(e.text)
            end
        end
        for _, e in ipairs(b) do
            if e.op and e.key and e.key.text == "component_slot" and type(e.value) == "table" then
                local t = F.slot_templates[str(get(e.value, "template")) or ""] or {}
                sec.slots[#sec.slots + 1] = { name = str(get(e.value, "name")), size = t.size or "small", kind = t.kind == "weapon" and "weapon" or (t.kind == "strike_craft" and "strike_craft" or t.kind) }
            end
        end
        for _, u in ipairs({ { "small", "SMALL" }, { "medium", "MEDIUM" }, { "large", "LARGE" }, { "aux", "AUX" } }) do
            local n = value(get(b, u[1] .. "_utility_slots"), vars) or 0
            for i = 1, n do
                sec.slots[#sec.slots + 1] = { name = u[2] .. "_UTILITY_" .. i, size = u[1], kind = "utility" }
            end
        end
        F.sections[key] = sec
    end)
    -- component templates
    each_definition(game_dir, "common/component_templates", globals, function(kind, b, vars)
        local key = str(get(b, "key"))
        if not key then
            return
        end
        F.components[key] = {
            key = key, kind = kind, size = str(get(b, "size")),
            icon = str(get(b, "icon")), icon_frame = tonumber(get(b, "icon_frame")) or 1,
            power = value(get(b, "power"), vars) or 0,
            cost = resources(b, "cost", vars), upkeep = resources(b, "upkeep", vars),
            modifier = modifier(get(b, "modifier"), vars),
            sensor = value(get(b, "sensor_range"), vars),
            set = str(get(b, "component_set")),
            upgrades_to = str(get(b, "upgrades_to")),
            prerequisites = (function()
                local out = {}
                local pre = get(b, "prerequisites")
                for _, e in ipairs(type(pre) == "table" and pre or {}) do
                    if e.text then
                        out[#out + 1] = str(e.text)
                    end
                end
                return out
            end)(),
            order = (function()
                F.component_count = F.component_count + 1
                return F.component_count
            end)(),
        }
    end)
    -- the weapons' numbers (common/component_templates/weapon_components.csv)
    for _, csv in ipairs({ "common/component_templates/weapon_components.csv" }) do
        local fh = io.open(game_dir .. "/" .. csv, "r")
        if fh then
            local cols
            for line in fh:lines() do
                if line:sub(1, 1) ~= "#" then
                    local cells = {}
                    for c in (line .. ";"):gmatch("([^;]*);") do
                        cells[#cells + 1] = c
                    end
                    if not cols then
                        cols = {}
                        for i, c in ipairs(cells) do
                            cols[c] = i
                        end
                    elseif cells[1] and cells[1] ~= "" then
                        local n = function(k)
                            return tonumber(cells[cols[k] or 0] or "") or 0
                        end
                        F.weapons[cells[1]] = {
                            cost = n("cost"), power = n("power"), min = n("min_damage"), max = n("max_damage"),
                            windup_min = n("min_windup"), windup_max = n("max_windup"), cooldown = n("cooldown"), accuracy = n("accuracy"),
                        }
                    end
                end
            end
            fh:close()
        end
    end
    files_cache = F
    return F
end

-- ------------------------------------------------------------------------------ the stats

-- CShipDesignStats from the files (CalcStat's sources, 0x31971e0): the size's base, the
-- components' and sections' numbers. [I] The country's modifiers are not applied (the game's frame
-- of 2210.01.01 has speed, evasion and damage x 1.0389 and the upkeep x 0.955 over these).
local function stats(F, d)
    local size = F.sizes[d.size] or { hp = 0, speed = 0, build_time = 0, size = 1, modifier = {}, upkeep = {}, cost = {} }
    local st = { hp = size.hp, armor = 0, shields = 0, evasion = 0, speed = size.speed, damage = 0, sensor = 0,
        build_time = size.build_time, size = size.size, naval = size.size, power_out = 0, power_use = 0,
        cost = {}, upkeep = {} }
    local mods = {}
    local function add_mods(m)
        for k, v in pairs(m or {}) do
            mods[k] = (mods[k] or 0) + v
        end
    end
    local function add(t, r)
        for k, v in pairs(r or {}) do
            t[k] = (t[k] or 0) + v
        end
    end
    add_mods(size.modifier)
    add(st.upkeep, size.upkeep)
    add(st.cost, size.cost)
    local comps = {}
    for _, s in ipairs(d.sections) do
        local sec = F.sections[s.template]
        if sec then
            add(st.cost, sec.cost)
            add(st.upkeep, sec.upkeep)
        end
        for _, t in pairs(s.components) do
            comps[#comps + 1] = t
        end
    end
    for _, t in ipairs(d.required) do
        comps[#comps + 1] = t
    end
    for _, key in ipairs(comps) do
        local c = F.components[key]
        if c then
            local w = F.weapons[key]
            local power = w and w.power or c.power
            if power > 0 then
                st.power_out = st.power_out + power
            else
                st.power_use = st.power_use - power
            end
            add(st.cost, next(c.cost) and c.cost or (w and { alloys = w.cost } or {}))
            add(st.upkeep, c.upkeep)
            add_mods(c.modifier)
            if c.sensor then
                st.sensor = math.max(st.sensor, c.sensor)
            end
            if w then
                -- CalcAverageDamagePerDay [I]: the mean damage x the accuracy over the cooldown and the
                -- mean wind-up, in days (10 ticks)
                local per = (w.cooldown + (w.windup_min + w.windup_max) / 2) / 10
                if per > 0 then
                    st.damage = st.damage + (w.min + w.max) / 2 * w.accuracy / per
                end
            end
        end
    end
    st.armor = (mods.ship_armor_add or 0) * (1 + (mods.ship_armor_mult or 0))
    st.shields = (mods.ship_shield_add or 0) * (1 + (mods.ship_shield_mult or 0))
    st.hp = (st.hp + (mods.ship_hitpoints_add or 0)) * (1 + (mods.ship_hitpoints_mult or 0))
    st.evasion = ((mods.ship_evasion_add or 0)) * (1 + (mods.ship_evasion_mult or 0))
    st.speed = (st.speed + (mods.ship_speed_add or 0)) * (1 + (mods.ship_speed_mult or 0))
    st.power = st.power_out * (1 + (mods.ship_reactor_power_mult or 0)) - st.power_use
    return st
end

-- a number with `decimals` places, as CString(CFixedPoint, n)
local function fixed(v, decimals)
    return string.format("%." .. decimals .. "f", v)
end

-- a resource table as CResourceTable::BuildString(2, 0) [I]: "£resource£ amount" each, by
-- resource order (energy, minerals, food, alloys ...)
local RESOURCE_ORDER = { "energy", "minerals", "food", "consumer_goods", "alloys", "volatile_motes", "exotic_gases", "rare_crystals", "sr_dark_matter", "sr_living_metal", "sr_zro", "influence", "unity" }
local function resource_string(ctx, t)
    local out = {}
    for _, r in ipairs(RESOURCE_ORDER) do
        local v = t[r]
        if v and math.abs(v) > 1e-9 then
            -- the resource's text icon: GFX_text_<r>, else GFX_text_basic_resources_<r> [I: alloys]
            local icon = r
            if not ctx.db.sprites["GFX_text_" .. r] and ctx.db.sprites["GFX_text_basic_resources_" .. r] then
                icon = "basic_resources_" .. r
            end
            out[#out + 1] = "£" .. icon .. "£" .. fixed(v, 2)
        end
    end
    return table.concat(out, " ")
end

-- ------------------------------------------------------------------------------ the layout

local function sprite_size(ctx, name)
    local s = ctx.db.sprites[name]
    if s and s.sheet and ctx.db.sprites[s.sheet] then
        s = ctx.db.sprites[s.sheet]
    end
    if not s then
        return 0, 0
    end
    if s.size then
        return s.size[1], s.size[2]
    end
    local w, h = ctx.texture_size(s.texture)
    return (w or 0) / math.max(1, s.frames or 1), h or 0
end

local function loc(ctx, key)
    if ctx.loc and ctx.loc.has(key) then
        return ctx.loc.get(key)
    end
    return key
end

local function fmt_name(ctx, n)
    return n and require("render.names").format(ctx.loc, n) or ""
end

-- the size's capitalised (family) name: <size>_cap, else <size> [I]
local function size_name(ctx, size)
    if ctx.loc and ctx.loc.has(size .. "_cap") then
        local s = ctx.loc.get(size .. "_cap")
        if s:find("$", 1, true) then
            s = ctx.loc.resolve(s)
        end
        return s
    end
    return loc(ctx, size)
end

-- an inset (render.rs: a 3D view in the GUI) where a 3D view element is
local function inset(path, r)
    return { kind = "sprite", path = path, sprite = "", texture = "", sprite_kind = "inset", frame = 1, frames = 1, x = r.x, y = r.y, w = r.w, h = r.h }
end

-- ------------------------------------------------------------------------------ the buttons

-- The window's state between frames (in the GUI's runtime), as CShipDesignerBase keeps it
-- (SDataUnderModification: the designs changed and not saved, each by the design it was loaded
-- from, a new one as "new"): the design shown, the popup open (the size selector, the section
-- selector, the component selector, a required component's templates, the roles, the save of an
-- auto-generated design), the component selector's choice and filters, a request to the
-- simulation waiting for its answer.
local function fresh_ui()
    return { works = {}, key = nil, current = nil, popup = nil, picked = nil, filter_size = true, hide_obsolete = true, pending = nil, buildable = {}, scroll = {}, rects = {}, extent = {},
        edit = nil, paint = nil, hover = nil }
end
designer.ui = fresh_ui()

-- designer.reset(): the window opened anew (Show: the designs under modification cleared when
-- the owner changes [V 0x3190398]; here at each opening)
function designer.reset()
    designer.ui = fresh_ui()
end

local function deep(v)
    if type(v) ~= "table" then
        return v
    end
    local out = {}
    for k, x in pairs(v) do
        out[k] = deep(x)
    end
    return out
end

local function saved(data, id)
    for _, d in ipairs(data and data.designs or {}) do
        if d.id == id then
            return d
        end
    end
    return nil
end

-- the design shown: its working copy, else the saved one
local function shown(data)
    local ui = designer.ui
    if ui.current == "new" then
        return ui.works.new
    end
    return ui.current and (ui.works[ui.current] or saved(data, ui.current)) or nil
end
designer.shown = shown

-- the design shown, as a working copy (made on its first change)
local function work(data)
    local ui = designer.ui
    if ui.current == "new" then
        return ui.works.new
    end
    if not ui.current then
        return nil
    end
    if not ui.works[ui.current] then
        local d = saved(data, ui.current)
        if not d then
            return nil
        end
        ui.works[ui.current] = deep(d)
    end
    return ui.works[ui.current]
end

local function section_of(d, slot)
    for _, s in ipairs(d.sections) do
        if s.slot == slot then
            return s
        end
    end
    return nil
end

local function researched(data, list)
    for _, t in ipairs(list or {}) do
        if not (data.techs and data.techs[t]) then
            return false
        end
    end
    return true
end
designer.researched = researched

-- the components that fit a slot (its kind; its size with the filter on), the country can build
-- (their prerequisites [I: `potential` not evaluated]), the obsolete ones hidden (one it can build
-- upgrades them) with that filter, one per component set (its newest) [I], in definition order
local function fitting(F, data, sl, filter_size, hide_obsolete, size)
    -- the components the simulation says the country can build on the size (potential triggers
    -- evaluated: designer_commands.buildable), else their prerequisites alone
    local can = size and designer.ui.buildable[size]
    local kinds = { weapon = "weapon_component_template", utility = "utility_component_template", strike_craft = "strike_craft_component_template" }
    local want = kinds[sl.kind]
    local by_set, out = {}, {}
    for _, c in pairs(F.components) do
        if c.kind == want and (not filter_size or c.size == sl.size) and (can and can[c.key] or (not can and researched(data, c.prerequisites))) then
            local up = c.upgrades_to and F.components[c.upgrades_to]
            local obsolete = up and researched(data, up.prerequisites)
            if not (hide_obsolete and obsolete) then
                local key = c.set or c.key
                if not by_set[key] or by_set[key].order < c.order then
                    by_set[key] = c
                end
            end
        end
    end
    for _, c in pairs(by_set) do
        out[#out + 1] = c
    end
    table.sort(out, function(a, b) return a.order < b.order end)
    return out
end
designer.fitting = fitting

local function q(v)
    return string.format("%q", tostring(v))
end

local function sim(code)
    return "sim:" .. code
end

local function dc_call(name, ...)
    local args = {}
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        args[i] = type(v) == "string" and q(v) or tostring(v)
    end
    return "return require('render.windows.designer_commands')." .. name .. "(" .. table.concat(args, ", ") .. ")"
end

-- a component fits a slot: its kind and size, buildable (the `allowed` mark's frame 2) [I]
function designer.allowed(F, data, sl, key, size)
    for _, c in ipairs(fitting(F, data, sl, true, false, size)) do
        if c.key == key then
            return true
        end
    end
    -- (an obsolete one is still allowed: fitting keeps a set's newest only)
    local c = F.components[key]
    local kinds = { weapon = "weapon_component_template", utility = "utility_component_template", strike_craft = "strike_craft_component_template" }
    local can = designer.ui.buildable[size]
    return c ~= nil and c.kind == kinds[sl.kind] and c.size == sl.size and (can == nil or can[key] == true)
end

-- the name typed in the rename box made the design's (RenameDesign)
function designer.commit_edit(data)
    local ui = designer.ui
    local text = ui.edit
    ui.edit = nil
    if not text or text == "" or text == ui.name_text then
        return
    end
    local w = work(data)
    if w then
        w.name, w.name_key, w.name_literal, w.dirty = { key = text, literal = true, vars = {} }, text, true, true
    end
end

-- designer.typed(token) -> the designer's action for a key the rename box takes (the creator's
-- tokens: creator:text:C, creator:key:K), or nil when it has no focus
function designer.typed(token)
    if not designer.ui.edit then
        return nil
    end
    local c = token:match("^creator:text:(.*)$")
    if c then
        return "designer:ui:type:" .. c
    end
    local k = token:match("^creator:key:(.*)$")
    return k and ("designer:ui:typekey:" .. k) or nil
end

-- designer.act(action, data, game_dir) -> "" (the window laid out again), "sim:CODE" (CODE run in
-- the simulation's runtime; its answer given to designer.done), "design:ID" / "design:none" (the
-- design to show)
function designer.act(action, data, game_dir)
    local ui = designer.ui
    local F = files(game_dir)
    local a = action:gsub("^designer:ui:", "")
    local parts = {}
    for p in a:gmatch("[^:]+") do
        parts[#parts + 1] = p
    end
    local verb = parts[1] or ""
    local d = shown(data)
    -- the rename box loses the keyboard on any other click: the name typed is the design's
    -- (RenameBoxFocus(false) -> RenameDesign) [I: the name kept as typed, literal]
    if ui.edit and verb ~= "type" and verb ~= "typekey" and verb ~= "edit" then
        designer.commit_edit(data)
    end
    if verb == "popup_close" then
        ui.popup = nil
    elseif verb == "edit" and d then
        -- rename_box clicked: it takes the keyboard (the edit box's focus), its text the name's
        ui.edit = ui.name_text or ""
    elseif verb == "type" and ui.edit then
        -- a character typed (CEditBox): appended, at most 32 [I: as the rename dialogs]
        local c = a:match("^type:(.*)$") or ""
        if #ui.edit < 32 then
            ui.edit = ui.edit .. c
        end
    elseif verb == "typekey" and ui.edit then
        if parts[2] == "backspace" then
            -- (the last UTF-8 character)
            ui.edit = ui.edit:gsub("[%z\1-\127\194-\244][\128-\191]*$", "")
        elseif parts[2] == "return" then
            designer.commit_edit(data)
        end
    elseif verb == "hover" then
        -- the entry under the mouse shows its delete button (CShipDesignEntry::PerFrameUpdate:
        -- `button` IsOrWasMouseOver) [V 0x319d020]
        ui.hover = tonumber(parts[2])
    elseif verb == "new" then
        -- new_ship_design_entry: ShowShipSizeSelectDialog, the `selector` of sizes [V 0x31989c0]
        ui.popup = { kind = "size" }
    elseif verb == "new_size" and parts[2] then
        -- CSelectorItemShipSize::OnClick (0x31a40a0): a design of the size with its growth stages
        -- made and nothing in them (CShipDesign::CreateGrowthStages), loaded; its required
        -- components the best (FixRequiredComponents [I]) and a name from the name list
        -- (RandomizeName [I]): asked of the simulation
        ui.popup = nil
        ui.pending = { kind = "new", size = parts[2] }
        return sim(dc_call("generate", data.country, parts[2], "", 0))
    elseif verb == "delete" and tonumber(parts[2]) then
        -- the entry's delete: CShipDesignerBase::Delete (0x3198d50) asks first, a
        -- CPopupMessageDeleteCancel (`delete_cancel_popup_window`: POPUP_DELETE_DESIGN_TITLE,
        -- CAN_REMOVE_SHIP_DESIGN_COUNTRY) [V]
        ui.popup = { kind = "delete", id = tonumber(parts[2]) }
    elseif verb == "delete_yes" and ui.popup and ui.popup.kind == "delete" then
        -- its Delete: ConfirmedDeleteCallback -> ConfirmedDelete (CRemoveShipDesignCommand)
        local id = ui.popup.id
        ui.popup = nil
        ui.works[id] = nil
        ui.pending = { kind = "delete", id = id }
        return sim(dc_call("delete", data.country, id))
    elseif verb == "auto" then
        -- auto_design: ToggleAutoDesign (the country's auto-generation of designs)
        ui.pending = { kind = "auto" }
        return sim(dc_call("auto_generate", data.country, data.auto_generate and "0" or "1"))
    elseif not d then
        return ""
    elseif verb == "upgrade" then
        -- upgrade_ship_components: AutoUpgradeComponents (the design's flag)
        local w = work(data)
        w.upgrade = not w.upgrade
        w.dirty = true
    elseif verb == "clear" then
        -- clear_button: ClearDesignComponents (the sections' components cleared) [I: the sections and
        -- the required components kept]
        local w = work(data)
        for _, s in ipairs(w.sections) do
            s.components = {}
        end
        w.dirty = true
    elseif verb == "complete" then
        -- complete_button: Finish (every empty section and slot filled with the best: the AI
        -- designer's choice for the size and the design's role) [I]
        ui.pending = { kind = "complete" }
        return sim(dc_call("generate", data.country, d.size, d.role or "", 0))
    elseif verb == "randomize" then
        -- randomize_name: RandomizeName (a name of the size from the name list)
        ui.pending = { kind = "name" }
        return sim(dc_call("name", data.country, d.size, math.random(0, 9999)))
    elseif verb == "roles" then
        -- choose_role: CShipRoleSelectionView::Show (the size's roles; disabled without any)
        local size = F.sizes[d.size]
        if size and #size.roles > 0 then
            ui.popup = { kind = "role" }
        end
    elseif verb == "role" and parts[2] then
        -- a role chosen: GenerateDesignOfRole (the design made anew for it)
        ui.popup = nil
        ui.pending = { kind = "role", role = parts[2] }
        return sim(dc_call("generate", data.country, d.size, parts[2], 0))
    elseif verb == "section" and tonumber(parts[2]) then
        -- change_section: ShowSectionSelectDialog (the sections of the size that fit the slot)
        ui.popup = { kind = "section", index = tonumber(parts[2]) }
    elseif verb == "set_section" and tonumber(parts[2]) and parts[3] then
        -- CSectionSelector::ItemClicked: SetSectionTemplateOnSlot; the components of the slots the
        -- new section has too kept [I]
        local w = work(data)
        local size = F.sizes[w.size]
        local slot = size and size.slots[tonumber(parts[2])]
        local tpl = F.sections[parts[3]]
        if slot and tpl then
            local old = section_of(w, slot)
            local keep = {}
            for _, sl in ipairs(tpl.slots) do
                keep[sl.name] = old and old.components[sl.name] or nil
            end
            if old then
                old.template, old.components = parts[3], keep
            else
                w.sections[#w.sections + 1] = { template = parts[3], slot = slot, components = keep }
            end
            w.dirty = true
        end
        ui.popup = nil
    elseif (verb == "filter_size" or verb == "filter_obsolete") then
        ui.scroll.component = 0
        if verb == "filter_size" then
            ui.filter_size = not ui.filter_size
        else
            ui.hide_obsolete = not ui.hide_obsolete
        end
    elseif verb == "paint_cancel" then
        -- a right click while painting (component_paint_help_text: "right click to cancel")
        ui.paint = nil
    elseif verb == "clear_slot" and tonumber(parts[2]) and parts[3] then
        -- a right click on a slot: ClearSlot (its component taken off)
        local w = work(data)
        local size = F.sizes[w.size]
        local s = size and section_of(w, size.slots[tonumber(parts[2])] or "")
        if s and s.components[parts[3]] then
            s.components[parts[3]] = nil
            w.dirty = true
        end
    elseif verb == "paint" and tonumber(parts[2]) and parts[3] and ui.paint then
        -- a slot clicked while a component is chosen (HasValidSelectedElement): it is put there
        -- when it fits (IsCurrentlySelectedComponentAllowedOnSlot; the slot's `allowed` mark)
        local w = work(data)
        local size = F.sizes[w.size]
        local s = size and section_of(w, size.slots[tonumber(parts[2])] or "")
        local sl
        for _, x in ipairs(s and (F.sections[s.template] or { slots = {} }).slots or {}) do
            if x.name == parts[3] then
                sl = x
            end
        end
        if sl and designer.allowed(F, data, sl, ui.paint, w.size) then
            s.components[sl.name] = ui.paint
            w.dirty = true
        end
    elseif verb == "slot" and tonumber(parts[2]) and parts[3] then
        -- a slot: ShowComponentSelectDialog (the component selector for the slot); the components
        -- the country can build on the size asked of the simulation once
        ui.popup = { kind = "component", index = tonumber(parts[2]), slot = parts[3] }
        ui.scroll.component = 0
        if not ui.buildable[d.size] then
            ui.pending = { kind = "buildable", size = d.size }
            return sim(dc_call("buildable", data.country, d.size))
        end
    elseif verb == "set_comp" and parts[2] and ui.popup and ui.popup.kind == "component" then
        -- a component chosen: SetComponentOnSlot (the slot clicked), kept as the selected one
        -- (Fill Empty)
        local w = work(data)
        local size = F.sizes[w.size]
        local s = size and section_of(w, size.slots[ui.popup.index] or "")
        if s then
            s.components[ui.popup.slot] = parts[2]
            w.dirty = true
        end
        ui.picked = parts[2]
        -- the component chosen is painted on the slots clicked next (SetSelectedComponentSet)
        ui.paint = parts[2]
    elseif verb == "fill" and ui.picked then
        -- apply_on_empty: ApplySelectedElementOnAllEmptySlots (every empty slot it fits)
        local w = work(data)
        local c = F.components[ui.picked]
        for _, s in ipairs(w.sections) do
            for _, sl in ipairs((F.sections[s.template] or { slots = {} }).slots) do
                if not s.components[sl.name] and c then
                    for _, f in ipairs(fitting(F, data, sl, true, false, w.size)) do
                        if f.key == c.key then
                            s.components[sl.name] = c.key
                        end
                    end
                end
            end
        end
        w.dirty = true
    elseif verb == "required" and tonumber(parts[2]) then
        -- show_templates_button: the entry's list of the set's components (CRequiredComponentEntry::Open)
        local i = tonumber(parts[2])
        if ui.popup and ui.popup.kind == "required" and ui.popup.index == i then
            ui.popup = nil
        else
            ui.popup = { kind = "required", index = i }
            if not ui.buildable[d.size] then
                ui.pending = { kind = "buildable", size = d.size }
                return sim(dc_call("buildable", data.country, d.size))
            end
        end
    elseif verb == "set_req" and tonumber(parts[2]) and parts[3] then
        -- SetRequiredComponent: the set's component replaced
        local w = work(data)
        local size = F.sizes[w.size]
        local set = size and size.required[tonumber(parts[2])]
        local done = false
        for k, t in ipairs(w.required) do
            if (F.components[t] or {}).set == set then
                w.required[k], done = parts[3], true
            end
        end
        if not done then
            w.required[#w.required + 1] = parts[3]
        end
        w.dirty = true
        ui.popup = nil
    elseif verb == "save" or verb == "save_confirm" then
        -- save_button: Save -> ConfirmedSave (CCreateOrUpdateShipDesignCommand); an auto-generated
        -- design asks first (`rename_autogen`: saved, it is no longer auto-generated) [V names]
        if d.auto_gen and verb == "save" and not d.new then
            ui.popup = { kind = "autogen" }
            return ""
        end
        ui.popup = nil
        local stage = { size = d.size, sections = d.sections, required = d.required }
        ui.pending = { kind = "save", key = ui.current }
        return sim(dc_call("save", data.country, d.new and 0 or (d.id or 0), designer.serialize(stage), d.name_key or "", d.role or "", d.upgrade and "yes" or "no", d.name_literal and "yes" or "no"))
    end
    return ""
end

-- designer.done(answer, data, game_dir) -> as designer.act: what the simulation answered
function designer.done(answer, data, game_dir)
    local ui = designer.ui
    local p = ui.pending
    ui.pending = nil
    if not p or type(answer) ~= "string" then
        return ""
    end
    local ok = answer:match("^ok (.*)$")
    local changed = answer:match("^changed ?(.*)$")
    local F = files(game_dir)
    if p.kind == "buildable" and ok then
        ui.buildable[p.size] = load("return " .. ok)()
    elseif p.kind == "new" and ok then
        local stage = load("return " .. ok)()
        ui.works.new = {
            new = true, size = p.size, culture = (data.designs[1] or {}).culture, role = "", upgrade = true, auto_gen = false, sections = {},
            required = stage.required or {}, name = { key = p.size, vars = {} }, dirty = true,
        }
        ui.current = "new"
        ui.pending = { kind = "name" }
        return sim(dc_call("name", data.country, p.size, math.random(0, 9999)))
    elseif p.kind == "name" and ok then
        local w = work(data)
        if w then
            w.name, w.name_key, w.dirty = { key = ok, vars = {} }, ok, true
        end
    elseif p.kind == "complete" and ok then
        local g = load("return " .. ok)()
        local w = work(data)
        for _, gs in ipairs(g.sections or {}) do
            local s = section_of(w, gs.slot)
            if not s then
                w.sections[#w.sections + 1] = deep(gs)
            elseif s.template == gs.template then
                for slot, t in pairs(gs.components) do
                    s.components[slot] = s.components[slot] or t
                end
            else
                -- another section: its empty slots get the newest component that fits [I]
                for _, sl in ipairs((F.sections[s.template] or { slots = {} }).slots) do
                    if not s.components[sl.name] then
                        local best = fitting(F, data, sl, true, true, w.size)
                        s.components[sl.name] = best[#best] and best[#best].key or nil
                    end
                end
            end
        end
        local sets = {}
        for _, t in ipairs(w.required) do
            sets[(F.components[t] or {}).set or t] = true
        end
        for _, t in ipairs(g.required or {}) do
            if not sets[(F.components[t] or {}).set or t] then
                w.required[#w.required + 1] = t
            end
        end
        w.dirty = true
    elseif p.kind == "role" and ok then
        local g = load("return " .. ok)()
        local w = work(data)
        w.sections, w.required, w.role, w.dirty = g.sections or {}, g.required or {}, p.role, true
    elseif p.kind == "save" and changed then
        local id = tonumber(changed)
        if p.key then
            ui.works[p.key] = nil
        end
        ui.current = id
        return id and ("design:" .. id) or "design:none"
    elseif p.kind == "delete" and changed then
        if ui.current == p.id then
            ui.current = nil
            return "design:none"
        end
    end
    return ""
end

-- designer.build(ctx, data, state) -> items, report, insets = { [path] = design id (-1: the
-- design under modification, designer.stage) }
function designer.build(ctx, data, state)
    state = state or {}
    local F = files(ctx.game_dir)
    local items = {}
    local report = { sprites = 0, texts = 0, missing_sprites = {}, skipped = {}, rects = {} }
    local insets = {}
    -- opts.drop: element paths laid out (their rectangles kept) but not drawn: the 3D views'
    -- render targets, drawn as insets instead
    local function lay(window, opts)
        opts.texture_size, opts.loc = ctx.texture_size, ctx.loc
        local i, r = gui.layout(ctx.game_dir, ctx.db, opts.file or FILE, window, ctx.screen, opts)
        if opts.drop then
            local kept = {}
            for _, it in ipairs(i) do
                if not opts.drop[it.path] then
                    kept[#kept + 1] = it
                end
            end
            i = kept
        end
        gui.merge(items, report, i, r)
        return r
    end
    designer.ui.rects = {}
    -- the design shown: the one the window was given (a click in the list, `open_designer design
    -- ID`, the ship view's Open Designer), or the one made here (a new design), as modified
    local ui = designer.ui
    if state.design ~= ui.key then
        ui.key, ui.current, ui.popup, ui.edit = state.design, state.design, nil, nil
    end
    data.designs = data.designs or {}
    data.techs = data.techs or {}
    data.models = data.models or {}
    local design = shown(data)
    local P = "/ship_designer"

    -- the frame: Setup's tabs, the 3D view (the ship's), the help texts and controls by the design
    local hide = {
        ship_designer_tab_inactive = true, creature_designer_tab_active = true,
        ["3d_view_creature_designer"] = true, blocker = true,
        -- the info box at info_mecship_pos with info_background_mecship_size (below)
        cloaking_values = true,
    }
    local text = {
        [P .. "/design_name"] = "SHIP_DESIGNER_COUNTRY",
        [P .. "/ship_label"] = "SHIP_NAME_STATS",
    }
    local st
    if design then
        st = stats(F, design)
        text[P .. "/ship_label"] = ((ctx.loc and ctx.loc.raw("LONG_SHIPCLASS_NAME") or "$NAME$-class $SIZE$"):gsub("%$NAME%$", (fmt_name(ctx, design.name):gsub("%%", "%%%%"))):gsub("%$SIZE%$", (size_name(ctx, design.size):gsub("%%", "%%%%"))))
        -- the help texts: a slot kind with slots and none filled [V 0x31926ac]
        local has, any = {}, {}
        for _, s in ipairs(design.sections) do
            for _, sl in ipairs((F.sections[s.template] or { slots = {} }).slots) do
                has[sl.kind] = true
                if s.components[sl.name] then
                    any[sl.kind] = true
                end
            end
        end
        if not (has.weapon and not any.weapon) then
            hide.weapons_help_text = true
        end
        if not (has.utility and not any.utility) then
            hide.utilities_help_text = true
        end
        text[P .. "/controls/choose_role"] = design.role or ""
        hide.bioship_stage, hide.stage_spinner = true, true
        -- component_paint_help_text: while a component is chosen (HasValidSelectedElement) [V]
        if not ui.paint then
            hide.component_paint_help_text = true
        end
    else
        hide.component_paint_help_text = true
        hide.weapons_help_text, hide.utilities_help_text, hide.controls, hide.content = true, true, true, true
    end
    local frames = {
        -- a check box: frame 2 down [I]
        [P .. "/auto_design"] = data.auto_generate and 2 or 1,
        [P .. "/controls/controls_bottom/upgrade_ship_components"] = (design and design.upgrade) and 2 or 1,
    }
    -- the disabled ones (greyed, no click) [V UpdateControlsWindow 0x3194450, Update 0x3192150]:
    -- the creature designer's tab without artificial breeding [I: never here]; choose_role
    -- without roles; complete_button unless the stage has sections and the first has slots;
    -- save_button unless the design can be saved (IsValidToSaveForCountry [I: every section slot
    -- and required set filled, a name])
    local disabled = { [P .. "/creature_designer_tab_inactive"] = true }
    if design then
        local size = F.sizes[design.size] or { slots = {}, required = {}, roles = {} }
        if #size.roles == 0 then
            disabled[P .. "/controls/choose_role"] = true
        end
        local first = design.sections[1] and F.sections[design.sections[1].template]
        if not (first and #first.slots > 0) then
            disabled[P .. "/controls/controls_bottom/complete_button"] = true
        end
        local ok = (fmt_name(ctx, design.name) ~= "")
        for _, slot in ipairs(size.slots) do
            ok = ok and section_of(design, slot) ~= nil
        end
        for _, set in ipairs(size.required) do
            local has = false
            for _, t in ipairs(design.required) do
                has = has or (F.components[t] or {}).set == set
            end
            ok = ok and has
        end
        if not ok then
            disabled[P .. "/controls/controls_bottom/save_button"] = true
        end
    end
    local actions = {
        -- (the window's background takes the clicks: nothing under it on the map)
        [P] = "designer:noop",
        [P .. "/close"] = "designer:close", [P .. "/fleet_manager_tab"] = "designer:fleet_manager",
        [P .. "/auto_design"] = "designer:ui:auto",
        [P .. "/controls/randomize_name"] = "designer:ui:randomize",
        [P .. "/controls/choose_role"] = "designer:ui:roles",
        [P .. "/controls/controls_bottom/clear_button"] = "designer:ui:clear",
        [P .. "/controls/controls_bottom/complete_button"] = "designer:ui:complete",
        [P .. "/controls/controls_bottom/save_button"] = "designer:ui:save",
        [P .. "/controls/controls_bottom/upgrade_ship_components"] = "designer:ui:upgrade",
    }
    for path in pairs(disabled) do
        actions[path] = nil
    end
    local r = lay("ship_designer", {
        hide = hide, text = text, frames = frames, drop = { [P .. "/3d_view"] = true }, disabled = disabled,
        -- the info box with a design (UpdateControlsWindow: SetInfoPosAndSize "mecship",
        -- info_mecship_pos and info_background_mecship_size) [V]; else where the .gui has it
        positions = design and { [P .. "/info"] = { 1098 - 1272, 40 } } or nil,
        sizes = design and { [P .. "/info/info_bg_box"] = { 244, 485 } } or nil,
        -- the buttons (CShipDesignerBase::Setup's observers [V 0x318e2e0])
        actions = actions,
    })
    local win = r.rects[P]
    -- the 3D view: 3d_view at its place, ship_designer_3d_view_size (740 x 584) [V 0x318e370]
    -- (with no design the viewer still draws its background)
    local v = r.rects[P .. "/3d_view"]
    if v then
        local id = design and ((design.dirty or design.new) and -1 or (data.models[design.id] and design.id)) or 0
        local path = "/designer/3d_view/" .. id
        -- (under the window's texts over it: the help texts, drawn after it in the .gui)
        local at = #items + 1
        for k, it in ipairs(items) do
            local p = it.path or ""
            if at > k and (p:find("_help_text", 1, true) or p:find(P .. "/ship_label", 1, true)) then
                at = k
            end
        end
        table.insert(items, at, inset(path, { x = v.x, y = v.y, w = 740, h = 584 }))
        insets[path] = id
    end
    -- the rename box (an edit box: its text, CShipDesign+0x38) [V 0x31907f8]
    local controls = r.rects[P .. "/controls"]
    if design and controls then
        ui.name_text = fmt_name(ctx, design.name)
        local shown_text = ui.edit and (ui.edit .. "|") or ui.name_text
        -- (the box's frame takes the click: the edit box's focus)
        for _, it in ipairs(items) do
            if it.path == P .. "/controls/ship_designer_rename_box" then
                it.button = { name = "rename_box", action = "designer:ui:edit" }
            end
        end
        items[#items + 1] = {
            kind = "text", path = P .. "/controls/rename_box", font = "cg_16b", text = shown_text,
            spans = { { text = shown_text, colour = ctx.db.textcolors[""] or { 1, 1, 1 } } },
            x = controls.x + 800, y = controls.y - 615, w = 160, h = 20, format = "left", valign = "top",
        }
        report.texts = report.texts + 1
    end

    -- the designs list
    local list = r.rects[P .. "/designs_list"]
    if list then
        -- scrolled by the wheel (designer.wheel): what starts above the list's top is not drawn
        ui.rects.designs = list
        local y = list.y - (ui.scroll.designs or 0)
        local bottom = list.y + list.h
        if y >= list.y then
            lay("new_ship_design_entry", {
                prefix = "/designer/list/new", parent = { x = list.x, y = y, w = 0, h = 0 },
                text = { ["/designer/list/new/new_ship_design_entry/label"] = "NEW_DESIGN" },
                actions = { ["/designer/list/new/new_ship_design_entry/button"] = "designer:ui:new" },
            })
        end
        y = y + 90
        -- the designs the country can build: a designable size, its prerequisites researched [I:
        -- CanCountryBuildPotential's potential triggers not evaluated], by size order (stable)
        local shown = {}
        for _, d in ipairs(data.designs) do
            local s = F.sizes[d.size]
            local ok = s and s.designable
            for _, t in ipairs(s and s.prerequisites or {}) do
                ok = ok and data.techs[t] == true
            end
            if ok then
                shown[#shown + 1] = d
            end
        end
        for i, d in ipairs(shown) do
            d._i = i
        end
        table.sort(shown, function(a, b)
            local oa, ob = F.sizes[a.size].order, F.sizes[b.size].order
            if oa ~= ob then
                return oa < ob
            end
            return a._i < b._i
        end)
        local last
        for _, d in ipairs(shown) do
            if y >= bottom then
                break
            end
            if d.size ~= last and y < list.y then
                y, last = y + 18, d.size
            end
            if d.size ~= last then
                local hp = "/designer/list/h" .. d.id
                lay("ship_design_header_entry", {
                    prefix = hp, parent = { x = list.x, y = y, w = 0, h = 0 },
                    text = { [hp .. "/ship_design_header_entry/label"] = size_name(ctx, d.size) },
                })
                y = y + 18
                last = d.size
            end
            local ep = "/designer/list/" .. d.id
            local e = ep .. "/ship_design_entry"
            if y >= list.y then
            -- delete: under the mouse only (PerFrameUpdate: `button` IsOrWasMouseOver) [V]
            local ehide = { icons = true }
            if not (design and design.id == d.id) then
                ehide.selected = true
            end
            if ui.hover ~= d.id then
                ehide.delete = true
            end
            if not d.auto_gen then
                ehide.auto_gen = true
            end
            local er = lay("ship_design_entry", {
                prefix = ep, parent = { x = list.x, y = y, w = 0, h = 0 }, hide = ehide,
                -- its render target's frame (ship_design_entry_bg) stays under the inset [I]
                text = {
                    [e .. "/label"] = fmt_name(ctx, d.name),
                    [e .. "/auto_gen"] = data.auto_generate and "AUTO_GENERATED_BEST" or "AUTO_GENERATED_STANDARD",
                },
                actions = { [e .. "/button"] = "designer:design:" .. d.id, [e .. "/delete"] = "designer:ui:delete:" .. d.id },
            })
            -- its 3D view (render_target: the design's entity) under the label
            local rt = er.rects[e .. "/render_target"]
            if rt and data.models[d.id] then
                local path = "/designer/thumb/" .. d.id
                -- the inset goes under the entry's texts: before them in the items
                local at = #items + 1
                for k = #items, 1, -1 do
                    local ip = items[k].path
                    if ip and ip:sub(1, #e + 1) == e .. "/" and ip ~= e .. "/button" and ip ~= e .. "/render_target" then
                        at = k
                    end
                end
                table.insert(items, at, inset(path, rt))
                insets[path] = d.id
            end
            end
            y = y + 91
        end
        ui.extent.designs = math.max(0, (#shown > 0 and 0 or 0) + y + (ui.scroll.designs or 0) - list.y - list.h)
    end

    if not design then
        designer.popups(ctx, data, nil, lay, items, report, insets, r)
        return items, report, insets
    end

    -- the stats: SetupInfo's list from first_stat_position, value_title 25, value_line 22 [V]
    local content = r.rects[P .. "/info/content"]
    if content then
        local x, y = content.x - 72, content.y + 55
        local function title(key)
            local p = "/designer/stat/" .. y
            lay("value_title", { prefix = p, parent = { x = x, y = y, w = 0, h = 0 }, text = { [p .. "/value_title/text"] = key } })
            y = y + 25
        end
        local function line(label, val)
            local p = "/designer/stat/" .. y
            lay("value_line", { prefix = p, parent = { x = x, y = y, w = 0, h = 0 }, text = { [p .. "/value_line/text"] = label, [p .. "/value_line/value"] = val } })
            y = y + 22
        end
        local function value_of(key, v)
            -- PdxLocalize(key_VALUE, VALUE pre-formatted) [V 0x318d81c]: the format's colour, the
            -- number as given (its digits flag does not round a string: the frame's "60.00")
            local f = loc(ctx, key .. "_VALUE")
            return (f:gsub("%$VALUE|?([^$]*)%$", function(flags)
                local c = flags:match("%u")
                return c and ("§" .. c .. v .. "§!") or v
            end))
        end
        title("PRODUCTION_COST")
        line("SHIP_STAT_BUILD_TIME", value_of("SHIP_STAT_BUILD_TIME", fixed(st.build_time, 2)))
        line("SHIP_STAT_UPKEEP", resource_string(ctx, st.upkeep))
        line("SHIP_STAT_COST", resource_string(ctx, st.cost))
        title("")
        title("SHIP_STATS")
        line("SHIP_STAT_SIZE", value_of("SHIP_STAT_SIZE", fixed(st.size, 0)))
        line("SHIP_STAT_NAVAL_CAP", value_of("SHIP_STAT_NAVAL_CAP", fixed(st.naval, 2)))
        -- CreateGreenRedValueDiff: a whole number with its sign, green or red [V 0x318d6db]
        local p = math.floor(st.power + 0.5)
        line("SHIP_STAT_POWER_USAGE", (p >= 0 and "§G+" or "§R") .. tostring(p) .. "§!")
        line("SHIP_STAT_HITPOINTS", value_of("SHIP_STAT_HITPOINTS", fixed(st.hp, 2)))
        line("SHIP_STAT_ARMOR", value_of("SHIP_STAT_ARMOR", fixed(st.armor, 2)))
        line("SHIP_STAT_SHIELDS", value_of("SHIP_STAT_SHIELDS", fixed(st.shields, 2)))
        -- min(evasion, the cap) x 100 [V 0x318d7c2]: NShip.MAX_EVASION [I: 90]
        line("SHIP_STAT_EVASION", value_of("SHIP_STAT_EVASION", fixed(math.min(st.evasion, 90), 1)))
        line("SHIP_STAT_SPEED", value_of("SHIP_STAT_SPEED", fixed(st.speed, 2)))
        line("SHIP_STAT_DAMAGE", value_of("SHIP_STAT_DAMAGE", fixed(st.damage, 2)))
        -- the sensor range's label: "Sensor Range: $VALUE|Y0$" localised without VALUE [V]
        line((loc(ctx, "SHIP_STAT_SENSOR_RANGE"):gsub("%s*%$VALUE[^$]*%$", "")), value_of("SHIP_STAT_SENSOR_RANGE", fixed(st.sensor, 0)))
    end

    -- the sections: a section_instance_entry per section slot of the size, in the `sections` box
    -- (spacing 10, centred) [V 0x317fad0]
    local box = r.rects[P .. "/sections"]
    local size = F.sizes[design.size]
    if box and size then
        local n = #size.slots
        local total = n * 192 + math.max(0, n - 1) * 10
        local x0 = box.x + (box.w - total) / 2
        for i, slot in ipairs(size.slots) do
            local sec
            for _, s in ipairs(design.sections) do
                if s.slot == slot then
                    sec = s
                end
            end
            local tpl = sec and F.sections[sec.template]
            local sp = "/designer/section/" .. i
            local e = sp .. "/section_instance_entry"
            local sx, sy = x0 + (i - 1) * 202, box.y
            local shide = { weapons_mask = true, utilities_mask = true }
            if sec then
                shide.is_empty = true
            end
            local sr = lay("section_instance_entry", {
                prefix = sp, parent = { x = sx, y = sy, w = 0, h = 0 }, hide = shide,
                actions = { [e .. "/change_section"] = "designer:ui:section:" .. i },
            })
            -- the section's name on change_section (CSectionTemplate::GetName: its key localised),
            -- NO_SECTION for an empty slot [V 0x31809e0]
            local cs = sr.rects[e .. "/change_section"]
            if cs then
                local name = loc(ctx, sec and sec.template or "NO_SECTION")
                items[#items + 1] = {
                    kind = "text", path = e .. "/change_section/text", font = "cg_16b", text = name,
                    spans = { { text = name, colour = ctx.db.textcolors[""] or { 1, 1, 1 } } },
                    x = cs.x, y = cs.y, w = cs.w, h = cs.h, format = "center", valign = "center",
                }
                report.texts = report.texts + 1
            end
            -- the slot grids: 56 a cell, max(3, ceil(n / 3)) columns centred, the weapons from the
            -- top (UPPER_LEFT), the utilities from the bottom (LOWER_LEFT) [V 0x3181770]
            local function grid(kinds, rect, from_bottom)
                local slots = {}
                for _, sl in ipairs(tpl and tpl.slots or {}) do
                    if kinds[sl.kind] then
                        slots[#slots + 1] = sl
                    end
                end
                if not rect then
                    return
                end
                local cols = math.max(3, math.ceil(#slots / 3))
                local gx = sx + 28 + (168 - 56 * cols) / 2
                -- the grid's background: GFX_ship_designer_grid_<cols>_2 (two rows of cells) under the
                -- slots, from the grid's top (weapons) or bottom (utilities) [I: by the frame]
                local gs = ctx.db.sprites["GFX_ship_designer_grid_" .. cols .. "_2"]
                if gs and gs.texture and #slots > 0 then
                    local gw, gh = ctx.texture_size(gs.texture)
                    gw, gh = gw or 56 * cols + 6, gh or 114
                    items[#items + 1] = {
                        kind = "sprite", path = sp .. "/" .. (from_bottom and "u" or "w") .. "/grid", sprite = "GFX_ship_designer_grid_" .. cols .. "_2",
                        texture = gs.texture, sprite_kind = gs.kind, frame = 1, frames = 1,
                        x = gx - (gw - 56 * cols) / 2, y = from_bottom and (rect.y + rect.h - 112 - (gh - 112) / 2) or (rect.y - (gh - 112) / 2), w = gw, h = gh,
                    }
                    report.sprites = report.sprites + 1
                end
                for k = 1, #slots do
                    local col, row = (k - 1) % cols, math.floor((k - 1) / cols)
                    local cx = gx + col * 56
                    local cy = from_bottom and (rect.y + rect.h - 56 * (row + 1)) or (rect.y + 56 * row)
                    local cp = sp .. "/" .. (from_bottom and "u" or "w") .. k
                    local c = cp .. "/component_slot"
                    local sl = slots[k]
                    local opts = { prefix = cp, parent = { x = cx, y = cy, w = 0, h = 0 }, hide = { deselect = true, allowed = true }, frames = {}, sprites = {}, actions = {} }
                    -- the slot clicked: the component selector for it; the slot selected shows
                    -- its `deselect` mark [I]
                    if sl then
                        -- a click: the component selector, or the component painted; a right click
                        -- (`LEFT||RIGHT`): the painting cancelled, else the slot cleared (ClearSlot)
                        local left = ui.paint and ("designer:ui:paint:" .. i .. ":" .. sl.name) or ("designer:ui:slot:" .. i .. ":" .. sl.name)
                        local right = ui.paint and "designer:ui:paint_cancel" or ("designer:ui:clear_slot:" .. i .. ":" .. sl.name)
                        opts.actions[c .. "/component_slot_button"] = left .. "||" .. right
                        local pp = ui.popup
                        if pp and pp.kind == "component" and pp.index == i and pp.slot == sl.name then
                            opts.hide.deselect = nil
                        end
                        -- `allowed` while painting: frame 2 where the component fits, 1 where not
                        -- (CComponentSlotEntry::Update 0x3182560) [V]
                        if ui.paint then
                            opts.hide.allowed = nil
                            opts.frames[c .. "/allowed"] = designer.allowed(F, data, sl, ui.paint, design.size) and 2 or 1
                        end
                    end
                    -- the cell's own position (22, -5) is the box's; the grid places it [I]
                    opts.positions = { [c] = { 0, 0 } }
                    if sl then
                        local size_i = SLOT_SIZE[sl.size] or 0
                        local frame = sl.kind == "weapon" and size_i + 4 or (size_i == 9 and 13 or size_i)
                        if sl.size == "point_defence" then
                            frame = 3
                        end
                        opts.frames[c .. "/component_slot_button"] = frame + 1
                        local comp = F.components[sec.components[sl.name] or ""]
                        if comp and comp.icon then
                            opts.sprites[c .. "/icon"] = comp.icon
                            opts.frames[c .. "/icon"] = comp.icon_frame
                        else
                            opts.hide.icon = true
                        end
                    else
                        opts.hide.icon, opts.hide.component_slot_button = true, true
                    end
                    lay("component_slot", opts)
                end
            end
            grid({ weapon = true, strike_craft = true }, sr.rects[e .. "/weapon_slots"], false)
            local ur = sr.rects[e .. "/utility_slots"]
            if ur then
                -- the utility grid is 270 high from its place [V gui]
                ur = { x = ur.x, y = ur.y, w = ur.w, h = 270 }
            end
            grid({ utility = true }, ur, true)
        end
        -- the section's name: change_section's text, CSectionTemplate::GetName (its key, localised) [V]
    end

    -- the required components: one required_component_entry each, 60 high, in a column at
    -- required_slots_position (945, 374) centred on y [V 0x31942e0]
    if win and size then
        local n = #size.required
        local x, y = win.x + 945, win.y + 374 - n * 60 / 2
        for i, set in ipairs(size.required) do
            local chosen
            for _, t in ipairs(design.required) do
                if (F.components[t] or {}).set == set then
                    chosen = F.components[t]
                end
            end
            local rp = "/designer/required/" .. i
            local e = rp .. "/required_component_entry"
            local opts = { prefix = rp, parent = { x = x, y = y + (i - 1) * 60, w = 0, h = 0 }, hide = { list = true }, sprites = {}, frames = {},
                actions = { [e .. "/show_templates_button"] = "designer:ui:required:" .. i } }
            if chosen and chosen.icon then
                opts.sprites[e .. "/component_icon"] = chosen.icon
                opts.frames[e .. "/component_icon"] = chosen.icon_frame
            end
            lay("required_component_entry", opts)
        end
    end
    designer.popups(ctx, data, design, lay, items, report, insets, r)
    return items, report, insets
end


-- the size's roles' icon (GFX_role_<role>, else the brawler's) [I]
local function role_icon(ctx, role)
    return ctx.db.sprites["GFX_role_" .. role] and ("GFX_role_" .. role) or "GFX_role_brawler"
end

-- the slot sizes' frames of GFX_component_slot_icons (component_set_entry's icons: pd 1, small 2,
-- medium 3, large 4, torpedo 5, extra large 6, titanic 7, planet killer 8, engulf 9, aux 10,
-- strike craft 12)
local SLOT_ICON = { point_defence = 1, small = 2, medium = 3, large = 4, torpedo = 5, extra_large = 6, titanic = 7, planet_killer = 8, aux = 10 }

-- designer.popups(...): the popup open over the window (designer.ui.popup), its entries' clicks
function designer.popups(ctx, data, design, lay, items, report, insets, r)
    local ui = designer.ui
    local pp = ui.popup
    if not pp then
        return
    end
    local F = files(ctx.game_dir)
    local P = "/ship_designer"
    local win = r.rects[P]
    local function text_item(path, text, x, y, w, h, format)
        items[#items + 1] = {
            kind = "text", path = path, font = "cg_16b", text = text,
            spans = { { text = text, colour = ctx.db.textcolors[""] or { 1, 1, 1 } } },
            x = x, y = y, w = w, h = h, format = format or "left", valign = "center",
        }
        report.texts = report.texts + 1
    end
    if pp.kind == "size" then
        -- the `selector` (CShipSelector::Update 0x31a00a0): a selector_item per ship size the country
        -- can build (NUtil::CanBuildShipOfSize: a designable size, its prerequisites [I]), three a row
        local wr = lay("selector", {
            text = { ["/selector/title"] = "NEW_DESIGN" },
            actions = { ["/selector"] = "designer:noop", ["/selector/close"] = "designer:ui:popup_close" },
        })
        local grid = wr.rects["/selector/ship_grid_window/ship_sizes_grid"]
        if grid then
            local k = 0
            for _, name in ipairs(F.size_order) do
                local s = F.sizes[name]
                if s and s.designable and #s.slots > 0 and researched(data, s.prerequisites) then
                    local x, y = grid.x + (k % 3) * 269, grid.y + math.floor(k / 3) * 144
                    if y + 139 <= grid.y + grid.h then
                        local pfx = "/designer/size/" .. name
                        local e = pfx .. "/selector_item"
                        lay("selector_item", {
                            prefix = pfx, parent = { x = x, y = y, w = 0, h = 0 }, hide = { selected = true },
                            text = { [e .. "/title"] = size_name(ctx, name) },
                            actions = { [e .. "/choose_ship_type_button"] = "designer:ui:new_size:" .. name },
                        })
                    end
                    k = k + 1
                end
            end
        end
        return
    end
    if not design and pp.kind ~= "delete" then
        return
    end
    local size = design and F.sizes[design.size]
    if pp.kind == "role" and size then
        -- select_ship_role (CShipRoleSelectionView): a ship_role_entry per role of the size, four a
        -- row (158 x 256, 24 apart), the window as wide as they are; the role chosen selected
        local n = #size.roles
        local cols = math.min(4, n)
        local w = math.max(500, 12 + cols * 182 + 12)
        local h = 50 + math.ceil(n / 4) * 280 + 12
        local wr = lay("select_ship_role", {
            sizes = { ["/select_ship_role"] = { w, h } },
            positions = { ["/select_ship_role/close_button"] = { w - 41, 9 } },
            actions = { ["/select_ship_role"] = "designer:noop", ["/select_ship_role/close_button"] = "designer:ui:popup_close" },
            file = "interface/ship_designer_role_selection.gui",
        })
        local box = wr.rects["/select_ship_role/ship_roles_container"]
        for k, role in ipairs(size.roles) do
            if box then
                local x, y = box.x + ((k - 1) % 4) * 182, box.y + math.floor((k - 1) / 4) * 280
                local pfx = "/designer/role/" .. role
                local e = pfx .. "/ship_role_entry"
                lay("ship_role_entry", {
                    prefix = pfx, parent = { x = x, y = y, w = 0, h = 0 },
                    hide = { selected_overlay = role ~= design.role or nil },
                    sprites = { [e .. "/role_icon"] = role_icon(ctx, role) },
                    text = { [e .. "/role_name"] = role },
                    actions = { [e .. "/select_role_button"] = "designer:ui:role:" .. role },
                    file = "interface/ship_designer_role_selection.gui",
                })
            end
        end
    elseif pp.kind == "section" and size then
        -- section_select_window (CSectionSelector): the sections of the size that fit the slot and
        -- the country can build, in definition order, two a row (section_entries_per_row), each its
        -- name and its weapon and utility slots by size (section_component_slot_entry); a click
        -- puts it on the slot (ItemClicked)
        local slot = size.slots[pp.index]
        local wr = lay("section_select_window", { actions = { ["/section_select_window"] = "designer:noop", ["/section_select_window/close"] = "designer:ui:popup_close" } })
        local list = wr.rects["/section_select_window/list"]
        local secs = {}
        for _, sec in pairs(F.sections) do
            if sec.size == design.size and (sec.fits == nil or sec.fits == slot) and researched(data, sec.prerequisites) then
                secs[#secs + 1] = sec
            end
        end
        table.sort(secs, function(a, b) return a.order < b.order end)
        if list then
            ui.rects.section = list
            ui.extent.section = math.max(0, math.ceil(#secs / 2) * 275 - list.h)
        end
        for k, sec in ipairs(secs) do
            if list then
                local x, y = list.x + ((k - 1) % 2) * 278, list.y + math.floor((k - 1) / 2) * 275 - (ui.scroll.section or 0)
                if y >= list.y and y + 275 <= list.y + list.h + 1 then
                    local pfx = "/designer/sections/" .. sec.key
                    local e = pfx .. "/section_entry"
                    local er = lay("section_entry", {
                        prefix = pfx, parent = { x = x, y = y, w = 0, h = 0 },
                        text = { [e .. "/name"] = sec.key },
                        actions = { [e .. "/render_target"] = "designer:ui:set_section:" .. pp.index .. ":" .. sec.key },
                    })
                    for _, kind in ipairs({ "weapon", "utility" }) do
                        local box = er.rects[e .. "/" .. kind .. "_slots"]
                        local count, order = {}, {}
                        for _, sl in ipairs(sec.slots) do
                            if sl.kind == kind or (kind == "weapon" and sl.kind == "strike_craft") then
                                if not count[sl.size] then
                                    order[#order + 1] = sl.size
                                end
                                count[sl.size] = (count[sl.size] or 0) + 1
                            end
                        end
                        if box then
                            local bx = box.x + (box.w - #order * 48) / 2
                            for j, sz in ipairs(order) do
                                local cp = e .. "/" .. kind .. "/" .. sz
                                lay("section_component_slot_entry", {
                                    prefix = cp, parent = { x = bx + (j - 1) * 48, y = box.y + 7, w = 0, h = 0 },
                                    frames = { [cp .. "/section_component_slot_entry/icon"] = SLOT_ICON[sz] or 2 },
                                    text = { [cp .. "/section_component_slot_entry/count"] = tostring(count[sz]) },
                                })
                            end
                        end
                    end
                end
            end
        end
    elseif pp.kind == "component" and size and win then
        -- component_select_window (CComponentSelector), over the designs list [I: its place]: the
        -- components that fit the slot (the filters: its slot size, obsolete ones hidden), a
        -- component_set_entry each; a click puts it on the slot; Fill Empty puts the one chosen on
        -- every empty slot it fits
        local sec
        for _, s in ipairs(design.sections) do
            if s.slot == size.slots[pp.index] then
                sec = s
            end
        end
        local sl
        for _, x in ipairs(sec and (F.sections[sec.template] or { slots = {} }).slots or {}) do
            if x.name == pp.slot then
                sl = x
            end
        end
        if not sl then
            ui.popup = nil
            return
        end
        local W = "/component_select_window"
        local wr = lay("component_select_window", {
            parent = { x = win.x, y = win.y, w = 0, h = 0 },
            frames = {
                [W .. "/filter_slot_size"] = ui.filter_size and 2 or 1,
                [W .. "/filter_obsolete"] = ui.hide_obsolete and 2 or 1,
                [W .. "/current_filter_slot_size"] = SLOT_ICON[sl.size] or 2,
            },
            actions = {
                [W] = "designer:noop",
                [W .. "/close"] = "designer:ui:popup_close", [W .. "/apply_on_empty"] = "designer:ui:fill",
                [W .. "/filter_slot_size"] = "designer:ui:filter_size", [W .. "/filter_obsolete"] = "designer:ui:filter_obsolete",
            },
        })
        local list = wr.rects[W .. "/list"]
        local current = sec.components[sl.name]
        local fits = fitting(F, data, sl, ui.filter_size, ui.hide_obsolete, design.size)
        if list then
            ui.rects.component = list
            ui.extent.component = math.max(0, #fits * 66 - list.h)
        end
        for k, c in ipairs(fits) do
            if list then
                local y = list.y + (k - 1) * 66 - (ui.scroll.component or 0)
                if y >= list.y and y + 60 <= list.y + list.h then
                    local pfx = "/designer/components/" .. c.key
                    local e = pfx .. "/component_set_entry"
                    local hide = { unique_mutation_icon = true }
                    for nm in pairs({ pd_icon = 1, small_icon = 1, medium_icon = 1, large_icon = 1, torpedo_icon = 1, extra_large_icon = 1, titanic_icon = 1, planet_killer_icon = 1, engulf_icon = 1, aux_icon = 1, strike_craft_icon = 1 }) do
                        hide[nm] = true
                    end
                    local shown_icon = ({ point_defence = "pd_icon", small = "small_icon", medium = "medium_icon", large = "large_icon", torpedo = "torpedo_icon", extra_large = "extra_large_icon", titanic = "titanic_icon", planet_killer = "planet_killer_icon", aux = "aux_icon" })[c.size or ""]
                    if shown_icon then
                        hide[shown_icon] = nil
                    end
                    if c.key ~= current and c.key ~= ui.picked then
                        hide.selected_overlay = true
                    end
                    local w = F.weapons[c.key]
                    local power = w and w.power or c.power
                    local stats = (power ~= 0 and ("£ship_stats_power£" .. string.format("%d", power) .. " ") or "") .. resource_string(ctx, next(c.cost) and c.cost or (w and { alloys = w.cost } or {}))
                    lay("component_set_entry", {
                        prefix = pfx, parent = { x = list.x + 5, y = y + 4, w = 0, h = 0 }, hide = hide,
                        sprites = c.icon and { [e .. "/icon"] = c.icon } or nil,
                        frames = { [e .. "/icon"] = c.icon_frame },
                        text = { [e .. "/name"] = c.key, [e .. "/stats"] = stats },
                        actions = { [e .. "/component_entry_bg"] = "designer:ui:set_comp:" .. c.key },
                    })
                end
            end
        end
    elseif pp.kind == "required" and size and win then
        -- the required component entry's `list` (LOWER_RIGHT, from x -60): the set's components the
        -- country can build, leftward [I]; a click sets it (SetRequiredComponent)
        local n = #size.required
        local x0, y0 = win.x + 945, win.y + 374 - n * 60 / 2 + (pp.index - 1) * 60
        local set = size.required[pp.index]
        local list = {}
        local can = ui.buildable[design.size]
        for _, c in pairs(F.components) do
            if c.set == set and (can and can[c.key] or (not can and researched(data, c.prerequisites))) then
                list[#list + 1] = c
            end
        end
        table.sort(list, function(a, b) return a.order < b.order end)
        for k, c in ipairs(list) do
            local pfx = "/designer/required_list/" .. c.key
            local e = pfx .. "/required_component_template_entry"
            lay("required_component_template_entry", {
                prefix = pfx, parent = { x = x0 - 60 * k, y = y0, w = 0, h = 0 }, hide = { allowed = true },
                sprites = c.icon and { [e .. "/component_icon"] = c.icon } or nil,
                frames = { [e .. "/component_icon"] = c.icon_frame },
                actions = { [e .. "/select_this_button"] = "designer:ui:set_req:" .. pp.index .. ":" .. c.key },
            })
        end
    elseif pp.kind == "delete" then
        -- delete_cancel_popup_window (CPopupMessageDeleteCancel): Delete (RETURN) or Cancel (ESCAPE)
        lay("delete_cancel_popup_window", {
            file = "interface/popup.gui",
            text = {
                ["/delete_cancel_popup_window/title"] = "POPUP_DELETE_DESIGN_TITLE",
                ["/delete_cancel_popup_window/description"] = "CAN_REMOVE_SHIP_DESIGN_COUNTRY",
            },
            actions = {
                ["/delete_cancel_popup_window"] = "designer:noop",
                ["/delete_cancel_popup_window/AgreeButton"] = "designer:ui:delete_yes",
                ["/delete_cancel_popup_window/DeclineButton"] = "designer:ui:popup_close",
            },
        })
    elseif pp.kind == "autogen" then
        -- rename_autogen: an auto-generated design saved under a name (it is no longer
        -- auto-generated); Save, or the close button (nothing saved)
        local wr = lay("rename_autogen", {
            actions = {
                ["/rename_autogen"] = "designer:noop",
                ["/rename_autogen/save_and_close"] = "designer:ui:save_confirm", ["/rename_autogen/close"] = "designer:ui:popup_close",
                ["/rename_autogen/rename_container/randomize_name"] = "designer:ui:randomize",
            },
        })
        local rc = wr.rects["/rename_autogen/rename_container"]
        if rc then
            text_item("/rename_autogen/rename_container/rename_box", fmt_name(ctx, design.name), rc.x + 55, rc.y - 8, 220, 20)
        end
    end
end

-- designer.wheel(notches, x, y) -> whether a list under the pointer took the wheel (the designs,
-- the component selector's, the section selector's: a smoothListBox scrolls, 45 pixels a notch
-- [I]); the popups' lists first
function designer.wheel(notches, x, y)
    local ui = designer.ui
    local open = ui.popup and ui.popup.kind
    for _, name in ipairs({ open == "component" and "component" or "", open == "section" and "section" or "", "designs" }) do
        local r = ui.rects[name]
        if r and x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h then
            local s = (ui.scroll[name] or 0) - notches * 45
            ui.scroll[name] = math.max(0, math.min(ui.extent[name] or 0, s))
            return true
        end
    end
    return false
end

-- designer.escape() -> whether Escape closed a popup (its close button's ESCAPE shortcut: the
-- innermost window first); else the window closes
function designer.escape()
    local ui = designer.ui
    if ui.edit then
        -- the edit box's Escape: the text typed dropped
        ui.edit = nil
        return true
    end
    if ui.popup then
        ui.popup = nil
        return true
    end
    if ui.paint then
        ui.paint = nil
        return true
    end
    return false
end

-- designer.stage() -> the design under modification's stage (its 3D view's model), serialized
function designer.stage()
    local d = designer.ui.current and (designer.ui.current == "new" and designer.ui.works.new or designer.ui.works[designer.ui.current])
    if not d then
        return nil
    end
    local culture = d.culture
    for _, x in ipairs((RENDER_DESIGNER_DATA or {}).designs or {}) do
        culture = culture or x.culture
    end
    return designer.serialize({ size = d.size, sections = d.sections, required = d.required, culture = culture })
end

return designer
