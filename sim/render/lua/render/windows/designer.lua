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
    for _, b in ipairs(world.fields(world.path(c, "tech_status") or {}, "technology")) do
        data.techs[str(b)] = true
    end
    for _, b in ipairs(world.blocks(world.field(world.field(c, "tech_status") or {}, "technology"))) do
        data.techs[str(world.field(b, "technology") or b)] = true
    end
    -- tech_status = { technology = "x" level = 1 technology = "y" ... } as the save writes it
    local ts = world.field(c, "tech_status")
    for _, e in ipairs(type(ts) == "table" and ts or {}) do
        if e.op and e.key and e.key.text == "technology" and e.value.text then
            data.techs[str(e.value.text)] = true
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
            for _, e in ipairs(stage) do
                if e.op and e.key and e.key.text == "required_component" and e.value.text then
                    design.required[#design.required + 1] = str(e.value.text)
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
    local F = { sizes = {}, size_order = {}, sections = {}, components = {}, slot_templates = {}, weapons = {} }
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
        local sec = { key = key, entity = str(get(b, "entity")), cost = resources(b, "cost", vars), upkeep = resources(b, "upkeep", vars), slots = {} }
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

-- designer.build(ctx, data, state) -> items, report, insets = { [path] = design id }
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
        local i, r = gui.layout(ctx.game_dir, ctx.db, FILE, window, ctx.screen, opts)
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
    local design
    for _, d in ipairs(data.designs) do
        if d.id == state.design then
            design = d
        end
    end
    local P = "/ship_designer"

    -- the frame: Setup's tabs, the 3D view (the ship's), the help texts and controls by the design
    local hide = {
        ship_designer_tab_inactive = true, creature_designer_tab_active = true,
        ["3d_view_creature_designer"] = true, blocker = true, component_paint_help_text = true,
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
    else
        hide.weapons_help_text, hide.utilities_help_text, hide.controls, hide.content = true, true, true, true
    end
    local frames = {
        -- a check box: frame 2 down [I]
        [P .. "/auto_design"] = data.auto_generate and 2 or 1,
        [P .. "/controls/controls_bottom/upgrade_ship_components"] = (design and design.upgrade) and 2 or 1,
    }
    local r = lay("ship_designer", {
        hide = hide, text = text, frames = frames, drop = { [P .. "/3d_view"] = true },
        -- the info box with a design (UpdateControlsWindow: SetInfoPosAndSize "mecship",
        -- info_mecship_pos and info_background_mecship_size) [V]; else where the .gui has it
        positions = design and { [P .. "/info"] = { 1098 - 1272, 40 } } or nil,
        sizes = design and { [P .. "/info/info_bg_box"] = { 244, 485 } } or nil,
        actions = { [P .. "/close"] = "designer:close", [P .. "/fleet_manager_tab"] = "designer:close" },
    })
    local win = r.rects[P]
    -- the 3D view: 3d_view at its place, ship_designer_3d_view_size (740 x 584) [V 0x318e370]
    -- (with no design the viewer still draws its background)
    local v = r.rects[P .. "/3d_view"]
    if v then
        local id = design and data.models[design.id] and design.id or 0
        local path = "/designer/3d_view/" .. id
        items[#items + 1] = inset(path, { x = v.x, y = v.y, w = 740, h = 584 })
        insets[path] = id
    end
    -- the rename box (an edit box: its text, CShipDesign+0x38) [V 0x31907f8]
    local controls = r.rects[P .. "/controls"]
    if design and controls then
        items[#items + 1] = {
            kind = "text", path = P .. "/controls/rename_box", font = "cg_16b", text = fmt_name(ctx, design.name),
            spans = { { text = fmt_name(ctx, design.name), colour = ctx.db.textcolors[""] or { 1, 1, 1 } } },
            x = controls.x + 800, y = controls.y - 615, w = 160, h = 20, format = "left", valign = "top",
        }
        report.texts = report.texts + 1
    end

    -- the designs list
    local list = r.rects[P .. "/designs_list"]
    if list then
        local y = list.y
        local bottom = list.y + list.h
        lay("new_ship_design_entry", {
            prefix = "/designer/list/new", parent = { x = list.x, y = y, w = 0, h = 0 },
            text = { ["/designer/list/new/new_ship_design_entry/label"] = "NEW_DESIGN" },
        })
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
            local ehide = { delete = true, icons = true }
            if not (design and design.id == d.id) then
                ehide.selected = true
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
                actions = { [e .. "/button"] = "designer:design:" .. d.id },
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
            y = y + 91
        end
    end

    if not design then
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
            local sr = lay("section_instance_entry", { prefix = sp, parent = { x = sx, y = sy, w = 0, h = 0 }, hide = shide })
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
                    local opts = { prefix = cp, parent = { x = cx, y = cy, w = 0, h = 0 }, hide = { deselect = true, allowed = true }, frames = {}, sprites = {} }
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
            local opts = { prefix = rp, parent = { x = x, y = y + (i - 1) * 60, w = 0, h = 0 }, hide = { list = true }, sprites = {}, frames = {} }
            if chosen and chosen.icon then
                opts.sprites[e .. "/component_icon"] = chosen.icon
                opts.frames[e .. "/component_icon"] = chosen.icon_frame
            end
            lay("required_component_entry", opts)
        end
    end
    return items, report, insets
end

return designer
