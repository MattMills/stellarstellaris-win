-- render/windows/fleet.lua : the fleet windows (docs/windows/fleet.md) laid out from the game's
-- GUI files with what the save holds (render.windows.fleet_data): the selected fleet's
-- fleet_view (interface/fleet_view.gui), a ship's ship_view (ship_view.gui), the Fleet Manager
-- (fleet_manager_view.gui).
--
--   local items, report = require("render.windows.fleet").build(game_dir, db, screen,
--       texture_size, loc, { fleet = ..., ship = ..., manager = ... })
--
-- Which children show, their texts and sprites follow the game's code (CFleetViewEntry::OnUpdate,
-- CFleetView::UpdateOrders, CNewFleetViewSummary, CNewFleetViewSubEntry, CShipView::Update,
-- CFleetManagerView::Update: docs/windows/fleet.md, with what was read [V] and what is inferred
-- [I]). Two kinds of sprite the renderer draws through derived textures (fleetwin.rs makes them):
-- a disabled button's frame greyed as the game's buttonstate shader does (`@grey:TEXTURE`), and a
-- progress bar filled to its value (`@bar:FULL|EMPTY|VALUE|v|h`).

local gui = require("render.gui")
local names = require("render.names")
local source = require("stellar.script.source")
local gfx = require("render.gfx")
local get = gfx.get

local fleet = {}

local FLEET_GUI = "interface/fleet_view.gui"
local SHIP_GUI = "interface/ship_view.gui"
local MANAGER_GUI = "interface/fleet_manager_view.gui"
local PARAGON_GUI = "interface/paragon_ui_types.gui"

-- EShipClass (the game's enum: GetShipClassTokenFromEnum) by the save's ship_class token
fleet.CLASS = {
    shipclass_military = 0, shipclass_constructor = 1, shipclass_colonizer = 2, shipclass_science_ship = 3,
    shipclass_transport = 4, shipclass_mining_station = 5, shipclass_research_station = 6,
    shipclass_military_station = 7, shipclass_habitat_station = 8,
}
-- GetShipClassIconFrameFromEnum: the frame of GFX_ship_class_* by EShipClass
fleet.CLASS_ICON_FRAME = { [0] = 3, 2, 14, 1, 15, 7, 9, 10, 6, 13, 8, 28, 1, 62 }
-- GetShipClassColorFromEnum: "RHEBWWWWWWWRB" (a ship row's design line, CShip::GetTextColor)
fleet.CLASS_COLOUR = { [0] = "R", "H", "E", "B", "W", "W", "W", "W", "W", "W", "W", "R", "B" }
-- CShip::GetTextIcon: the text icon before a ship's design by EShipClass [V: its jump table's
-- strings; the classes of the cases not each read: I]
fleet.CLASS_TEXT_ICON = { [0] = "military_ship", "construction_ship", "colony_ship", "science_ship", "army_ship" }

---------------------------------------------------------------- definitions (read once)

local cache = {}

-- the scripted variables of common/scripted_variables (`@name = value`)
local function scripted_variables(game_dir)
    if cache.vars then
        return cache.vars
    end
    local vars = {}
    for _, file in ipairs(source.files(game_dir, "common/scripted_variables", "txt")) do
        local tree = source.parse(game_dir, file)
        for _, e in ipairs(tree or {}) do
            if e.op and e.key and e.key.text:sub(1, 1) == "@" and e.value and e.value.text then
                vars[e.key.text] = e.value.text
            end
        end
    end
    cache.vars = vars
    return vars
end

local function value(game_dir, v)
    if type(v) ~= "string" then
        return nil
    end
    if v:sub(1, 1) == "@" then
        v = scripted_variables(game_dir)[v] or v
    end
    return tonumber(v)
end

-- common/ship_sizes: name -> { class, size_multiplier, icon, max_hitpoints, ... }
function fleet.ship_sizes(game_dir)
    if cache.sizes then
        return cache.sizes
    end
    local sizes = {}
    for name, d in pairs(source.definitions(game_dir, "common/ship_sizes")) do
        local b = d.block
        sizes[name] = {
            class = get(b, "class"),
            size_multiplier = value(game_dir, get(b, "size_multiplier")) or 1,
            fleet_slot_size = value(game_dir, get(b, "fleet_slot_size")) or 1,
            icon = get(b, "icon"),
            max_hitpoints = value(game_dir, get(b, "max_hitpoints")),
            max_speed = value(game_dir, get(b, "max_speed")),
        }
    end
    cache.sizes = sizes
    return sizes
end

-- common/governments/councilors: name -> its icon sprite
local function councilors(game_dir)
    if cache.councilors then
        return cache.councilors
    end
    local out = {}
    for name, d in pairs(source.definitions(game_dir, "common/governments/councilors")) do
        out[name] = { icon = get(d.block, "icon") }
    end
    cache.councilors = out
    return out
end

-- common/traits: a leader trait's icon sprite
local function traits(game_dir)
    if cache.traits then
        return cache.traits
    end
    -- the named colours (common/named_colors: `name = { color = { r g b a } }`, 0..255)
    local colours = {}
    for name, d in pairs(source.definitions(game_dir, "common/named_colors")) do
        local c = get(d.block, "color")
        local n = {}
        for _, e in ipairs(type(c) == "table" and c or {}) do
            local v = tonumber(e.text or (e.value and e.value.text))
            if v then
                n[#n + 1] = v
            end
        end
        if #n >= 3 then
            colours[name] = { n[1] / 255, n[2] / 255, n[3] / 255, (n[4] or 255) / 255 }
        end
    end
    local fs = source.filesystem(game_dir)
    local out = {}
    for name, d in pairs(source.definitions(game_dir, "common/traits")) do
        local b = source.expand(fs, d.block, {})
        local icon = get(b, "icon")
        local layers = {}
        if type(icon) == "table" then
            -- the layers in order: `layer = { icon color visible }`, or a sprite alone
            for _, e in ipairs(icon) do
                if e.op and e.key and e.key.text == "layer" and type(e.value) == "table" then
                    local col = get(e.value, "color")
                    layers[#layers + 1] = {
                        sprite = (get(e.value, "icon") or ""):gsub('"', ""),
                        tint = col and colours[col:gsub('"', "")] or nil,
                        conditional = get(e.value, "visible") ~= nil,
                    }
                elseif e.op and e.key and e.key.text == "icon" and e.value and e.value.text then
                    layers[#layers + 1] = { sprite = e.value.text:gsub('"', "") }
                end
            end
        elseif type(icon) == "string" then
            layers[1] = { sprite = icon:gsub('"', "") }
        end
        out[name] = { layers = layers }
    end
    cache.traits = out
    return out
end

-- a name block localised; a leader's `%LEADER_2%` full name: its parts in order
local function name_text(loc, n)
    if type(n) ~= "table" then
        return ""
    end
    local count = tostring(n.key or ""):match("^%%LEADER_(%d+)%%$")
    if count then
        local parts = {}
        for _, v in ipairs(n.vars or {}) do
            parts[#parts + 1] = names.format(loc, v.value)
        end
        return table.concat(parts, " ")
    end
    return names.format(loc, n)
end
fleet.name_text = name_text

-- a value as a `$VAR|format$` asks: an upper-case letter is its colour, digits its decimals, `*`
-- an SI number (K, M), `%` a percent of a fraction [I: the formats' meaning, from their uses]
local function formatted(v, fmt)
    local colour = fmt:match("%u")
    local digits = tonumber(fmt:match("%d"))
    if type(v) == "number" then
        if fmt:find("%", 1, true) then
            v = v * 100
        end
        if fmt:find("*", 1, true) then
            v = fleet.si_number(v)
        elseif digits then
            v = string.format("%." .. digits .. "f", v)
        elseif v == math.floor(v) then
            v = string.format("%d", v)
        end
        if fmt:find("%", 1, true) then
            v = v .. "%"
        end
    end
    v = tostring(v)
    if colour then
        return "§" .. colour .. v .. "§!"
    end
    return v
end

-- a localisation key's text (as the file writes it) with $VAR$ and $VAR|format$ replaced by
-- `vars`, then its other $KEY$ references resolved
local function loc_text(loc, key, vars)
    local t = loc and loc.raw(key) or key
    t = t:gsub("%$([^$\n]+)%$", function(ref)
        local name, fmt = ref:match("^([^|]+)|?(.*)$")
        local v = vars and vars[name]
        if v == nil then
            return nil
        end
        return formatted(v, fmt or "")
    end)
    return loc and loc.resolve(t) or t
end
fleet.loc_text = loc_text

-- SI_NUMBER ("$VALUE|1*$"): whole below 1000, then K / M with one decimal
function fleet.si_number(v)
    v = tonumber(v) or 0
    local a = math.abs(v)
    if a >= 1e6 then
        return string.format("%.1fM", v / 1e6)
    elseif a >= 1e3 then
        return string.format("%.1fK", v / 1e3)
    end
    return string.format("%d", math.floor(v + 0.5))
end

-- CreateGreenRedPercent(fraction, 0 decimals, true): "§G<round(f x 100)>%§!" (§R below 0) [V]
local function green_red_percent(f)
    local p = math.floor(f * 100 + 0.5)
    return (p >= 0 and "§G" or "§R") .. p .. "%§!"
end

local function merge(items, report, i, r)
    gui.merge(items, report, i, r)
end

local function layout(ctx, file, window, opts)
    opts.texture_size = ctx.texture_size
    opts.loc = ctx.loc
    -- a sprite set at run time (SetSpriteType) shows its own frame, not the .gui's `frame`: a
    -- frame of a sheet its default_frame, else the first
    for path, name in pairs(opts.sprites or {}) do
        opts.frames = opts.frames or {}
        if opts.frames[path] == nil then
            local s = ctx.db.sprites[name]
            opts.frames[path] = s and s.default_frame or 1
        end
    end
    local ok, i, r = pcall(gui.layout, ctx.game_dir, ctx.db, file, window, ctx.screen, opts)
    if not ok then
        ctx.report.missing_sprites[#ctx.report.missing_sprites + 1] = window .. ": " .. tostring(i)
        return {}, { rects = {} }
    end
    merge(ctx.items, ctx.report, i, r)
    return i, r
end

local function set(list)
    local s = {}
    for _, n in ipairs(list) do
        s[n] = true
    end
    return s
end

-- the items whose path starts with `prefix` (laid out just now: from index `from`) greyed: a
-- disabled button (`@grey:` texture, fleetwin.rs)
local function grey(ctx, from, prefix)
    if ctx.plain then
        return
    end
    for i = from, #ctx.items do
        local it = ctx.items[i]
        if it.kind == "sprite" and it.path:sub(1, #prefix) == prefix and it.texture:sub(1, 1) ~= "@" then
            it.texture = "@grey:" .. it.texture
            if it.button then
                it.button.action = nil
            end
        elseif it.kind == "text" and it.path:sub(1, #prefix) == prefix then
            -- its text greyed the same way (buttonstate.shader's TextDisable)
            for _, s in ipairs(it.spans or {}) do
                local c = s.colour or { 1, 1, 1 }
                local g = 0.212671 * c[1] + 0.715160 * c[2] + 0.072169 * c[3]
                s.colour = { (g * 0.85 + c[1] * 0.15) * 0.75, (g * 0.85 + c[2] * 0.15) * 0.75, (g * 0.85 + c[3] * 0.15) * 0.75 }
            end
        end
    end
end

-- a progress bar sprite (progressbarType) at `value` 0..100: its texture made of the full and
-- empty textures (progress.shader: texture one where the bar's coordinate <= the state)
local function bar(ctx, path, value)
    if ctx.plain then
        return
    end
    for i = #ctx.items, 1, -1 do
        local it = ctx.items[i]
        if it.path == path and it.kind == "sprite" then
            local s = ctx.db.sprites[it.sprite]
            if s and s.texture2 then
                it.texture = string.format("@bar:%s|%s|%d|%s", s.texture, s.texture2, math.floor(value + 0.5), s.horizontal and "h" or "v")
                it.frames, it.frame = 1, 1
            end
            return
        end
    end
end

-- the order buttons that need a target (the game's OnClick(planet / system / fleet / coordinate)
-- overloads [V: their signatures]): a click arms them (`fleet:arm:FID:NAME`), the next map click
-- is the target; the others act at once (`fleet:do:FID:NAME`)
local TARGETED = {
    move = true, attack = true, home_base = true, survey = true, research = true, jump = true,
    mia_jump = true, build_starbase = true, build_mining = true, build_research = true,
    build_observation = true,
}
fleet.TARGETED = TARGETED

-- a grid of buttons (fleet_view_order_button / fleet_view_action_button windows) in the slots of
-- the gridbox at `rect`: { name, sprite, disabled } each, for the fleet `fid`; `right`:
-- UPPER_RIGHT (the first at the right, going left), `per_row`: max_slots_horizontal. An armed
-- order's button shows its `_selected` sprite, as the game's while its cursor mode is on.
local function button_grid(ctx, window, rect, slot_w, slot_h, buttons, prefix, right, per_row, fid)
    for i, b in ipairs(buttons) do
        local k = i - 1
        local col, row = k, 0
        if per_row and per_row > 0 then
            col, row = k % per_row, math.floor(k / per_row)
        end
        local x = right and (rect.x - (col + 1) * slot_w) or (rect.x + col * slot_w)
        local y = rect.y + row * slot_h
        local p = prefix .. "/" .. i
        local from = #ctx.items + 1
        local sprite = b.sprite
        local armed = ctx.armed and ctx.armed[1] == fid and ctx.armed[2] == b.name
        if armed and ctx.db.sprites[sprite .. "_selected"] then
            sprite = sprite .. "_selected"
        end
        local action = b.action
        if not action and fid and b.name then
            action = (TARGETED[b.name] and "fleet:arm:" or "fleet:do:") .. fid .. ":" .. b.name
        end
        layout(ctx, FLEET_GUI, window, {
            prefix = p,
            parent = { x = x, y = y, w = 0, h = 0 },
            sprites = { [p .. "/" .. window .. "/button"] = sprite },
            actions = { [p .. "/" .. window .. "/button"] = action },
        })
        if b.disabled then
            grey(ctx, from, p)
        end
    end
end

---------------------------------------------------------------- the orders

-- CFleetView::BuildPossibleActionsList's fleet-wide buttons (the header: EFleetOrderButtonType
-- 0-3, 26-28, 30, the ones not fleet-specific) for one fleet the player commands [V: the types,
-- their sprites; which are potential and enabled: I, as the game's frames show them]
-- the current order's line (fleet_data's order_line: a key, name blocks, values), else NO_ORDERS
-- a text given as { key, vars = { VAR = text }, names = { VAR = name block }, nested = { VAR =
-- such a text } } (fleet_data's order lines, fleet_rightclick's entries)
local function line_text(loc, o)
    local vars = {}
    for k, v in pairs(o.vars or {}) do
        vars[k] = v
    end
    for k, n in pairs(o.names or {}) do
        vars[k] = name_text(loc, n)
    end
    for k, n in pairs(o.nested or {}) do
        vars[k] = type(n) == "table" and line_text(loc, n) or ""
    end
    return loc_text(loc, o.key or "", vars)
end

function fleet.order_text(loc, d)
    local o = d and d.order_line
    if type(o) ~= "table" or not o.key then
        return loc_text(loc, "NO_ORDERS")
    end
    return line_text(loc, o)
end

local function header_orders(d)
    if not d.player then
        return {}
    end
    return {
        -- merge: another of the owner's fleets of the class in the system (fleet_data's mergeable)
        { name = "merge", sprite = "GFX_fleet_order_button_merge", disabled = not d.mergeable },
        { name = "stop", sprite = "GFX_fleet_order_button_stop", disabled = d.state == "move_idle" and #(d.orders or {}) == 0 },
        { name = "return", sprite = "GFX_fleet_order_button_return" },
        { name = "move", sprite = "GFX_fleet_order_button_move" },
        { name = "jump", sprite = "GFX_fleet_action_button_jump", disabled = true },
    }
end

-- the fleet-specific order buttons (EFleetOrderButtonType 4-25, 29, 31-38, in enum order) that are
-- potential for the fleet [V: the types and sprites; their IsPotential not read: I, per ship class
-- as the game's frames show a military, a science and a construction fleet]
local STANCE = { aggressive = "GFX_fleet_order_button_stance_aggressive", evasive = "GFX_fleet_order_button_stance_evasive" }
local function fleet_orders(d)
    local c = fleet.CLASS[d.class]
    local out = {}
    local function add(name, sprite, disabled)
        out[#out + 1] = { name = name, sprite = sprite, disabled = disabled }
    end
    if not d.player then
        return out
    end
    if c == 0 then
        add("attack", "GFX_fleet_order_button_attack")
        add("ground_support", "GFX_fleet_order_button_ground_support_" .. (d.ground_support_stance ~= "" and d.ground_support_stance or "selective"))
    end
    if c == 1 then
        add("build_starbase", "GFX_fleet_order_button_build_starbase_station")
        add("build_mining", "GFX_fleet_order_button_build_mining_station")
        add("build_research", "GFX_fleet_order_button_build_research_station")
        add("build_observation", "GFX_fleet_order_button_build_observation_station")
        add("auto_construct", "GFX_fleet_order_auto_construct")
    end
    if c == 3 then
        add("survey", "GFX_fleet_order_button_survey")
        add("research", "GFX_fleet_order_button_research")
    end
    if d.mobile then
        add("stance", STANCE[d.stance] or "GFX_fleet_order_button_stance_passive")
    end
    if c == 3 then
        add("auto_explore", "GFX_fleet_order_auto_explore")
    end
    if c == 0 then
        add("home_base", "GFX_fleet_order_set_home_base")
    end
    if c == 1 then
        add("megastructure", "GFX_fleet_order_button_build_megastructure", true)
    end
    if c == 3 then
        add("mia_jump", "GFX_fleet_order_button_mia_jump", true)
    end
    if c == 0 then
        add("follow", "GFX_fleet_order_button_follow_friendlies_off_large")
    end
    return out
end

-- the actions grid (EFleetActionButtonType 0-6 in order, IsPotential(type, fleet), the first at
-- the right) [V: types, sprites, the potentials of repair (mobile), transfer (not civilian),
-- split (2 ships), reinforce (a template); upgrade: a ship with a newer design (I); the enabled
-- states: I]
local function fleet_actions(d)
    local out = {}
    local c = fleet.CLASS[d.class]
    local damaged = false
    for _, s in ipairs(d.ships) do
        if s.hp < s.hp_max or s.armor < s.armor_max or s.shield < s.shield_max then
            damaged = true
        end
    end
    if d.mobile then
        out[#out + 1] = { name = "repair", sprite = "GFX_fleet_action_button_repair", disabled = not damaged }
    end
    if d.upgradable then
        out[#out + 1] = { name = "upgrade", sprite = "GFX_fleet_action_button_upgrade" }
    end
    if c == 0 and d.player then
        out[#out + 1] = { name = "mercenary", sprite = "GFX_fleet_action_button_turn_into_merc", disabled = true }
    end
    if not d.civilian then
        out[#out + 1] = { name = "transfer", sprite = "GFX_fleet_action_button_new" }
    end
    if #d.ships >= 2 then
        out[#out + 1] = { name = "split", sprite = "GFX_fleet_action_button_split" }
    end
    if d.template then
        out[#out + 1] = { name = "reinforce", sprite = "GFX_fleet_action_button_reinforce", disabled = (d.template_ships or 0) <= #d.ships }
    end
    return out
end

---------------------------------------------------------------- the leader (CParagonPortraitContainer)

-- leader class -> the frame of GFX_leader_icons / GFX_leader_class_bg_horizontal [I: the
-- textures' colours: commander red, official green, scientist blue]
local LEADER_FRAME = { commander = 1, official = 2, scientist = 3 }

-- paragon_portrait_container_horizontal (paragon_ui_types.gui) in `rect`: the class banner and
-- icon, the skill (GFX_leader_skill frame = level + 1), the council position's icon and title or
-- the class's name, the name; traits as icons [I: the portrait itself (the species' animated
-- portrait) is not drawn]
local function paragon(ctx, leader, rect, prefix)
    local loc = ctx.loc
    local w = "paragon_portrait_container_horizontal"
    local p = prefix .. "/" .. w
    local lp = p .. "/leader_container"
    local frame = LEADER_FRAME[leader.class] or 1
    local council = leader.council and councilors(ctx.game_dir)[leader.council]
    local text = {
        [lp .. "/name_without_title_text"] = name_text(loc, leader.name),
        [lp .. "/councilor_title"] = leader.council and loc_text(loc, leader.council) or "",
        [lp .. "/leader_class_text"] = leader.council and "" or loc_text(loc, "leader_" .. leader.class),
    }
    local _, r = layout(ctx, PARAGON_GUI, w, {
        prefix = prefix,
        parent = rect,
        hide = set({
            "character_portrait_container_clipping_mask", "no_character_container", "on_hover_assign_container",
            "on_hover_assign_container_disabled", "on_hover_replace_container", "on_hover_replace_container_disabled",
            "assign_character_button", "rename_leader",
            leader.council and "leader_class_text" or "councilor_title",
            council and "rename_leader" or "council_container",
        }),
        text = text,
        frames = {
            [p .. "/leader_class_banner"] = frame, [lp .. "/leader_type"] = frame,
            [lp .. "/skill_icon"] = math.min(11, (leader.level or 0) + 1), [p .. "/leader_rarity_icon"] = 1,
        },
        sprites = council and council.icon and { [lp .. "/council_container/council_position_icon"] = council.icon } or nil,
    })
    -- the traits, left to right in their box
    local box = r.rects[lp .. "/traits_overlapping_box"]
    if box then
        local tdefs = traits(ctx.game_dir)
        local x = box.x
        -- each trait's icon: its layers (common/traits `icon`, the trait/icon inline scripts)
        -- drawn over each other in their named colours, a square of the box's height; the
        -- layers shown only by a trigger (`visible`: GFX_trait_disabled for a leader not on
        -- the council) left out [I]
        local h = box.h
        for i, t in ipairs(leader.traits or {}) do
            local def = tdefs[t]
            for k, l in ipairs(def and def.layers or {}) do
                local name, frame = l.sprite, 1
                local s = ctx.db.sprites[name]
                if s and s.sheet and ctx.db.sprites[s.sheet] then
                    name, frame = s.sheet, s.default_frame or 1
                    s = ctx.db.sprites[name]
                end
                if s and s.texture and not l.conditional then
                    ctx.items[#ctx.items + 1] = {
                        kind = "sprite", path = lp .. "/traits/" .. i .. "/" .. k, sprite = name, texture = s.texture,
                        sprite_kind = s.kind, frame = frame, frames = s.frames or 1, x = x, y = box.y, w = h, h = h,
                        tint = l.tint,
                    }
                end
            end
            x = x + h + 2
        end
    end
end

---------------------------------------------------------------- fleet_view

-- the header background by ship class (CFleetViewEntry::CFleetViewEntry, OnUpdate,
-- UpdateMilitaryFleetBackground) [V]
local function header_sprite(d)
    if not d.communications then
        return "GFX_fleet_view_main_precom_bg"
    end
    local c = fleet.CLASS[d.class]
    if c == 0 or c == 7 then
        return "GFX_fleet_view_main_military_bg"
    elseif c == 3 then
        return "GFX_fleet_view_main_science_bg"
    elseif c == 4 then
        return "GFX_fleet_view_main_transport_bg"
    elseif d.civilian then
        return "GFX_fleet_view_main_civilian_bg"
    end
    return nil
end

-- the ships list's rows: the summary (one entry per ship size), then one row per ship
local SUMMARY_H, ROW_H, SPACING = 43, 42, 1
local ENTRY_H = 259

local function fraction(v, max)
    if not max or max <= 0 then
        return 1
    end
    return v / max
end

-- a ship row's text (CShip::GetLocalNameWithType -> GetNameWithType): "SHIP_SIZE_NAME" (the size,
-- the name) over the design ("SHIP_ICON_CLASS": the class's text icon, "SHIP_CLASS"), the design
-- line in the class's colour [V]; the first line's colour H [I]
local function ship_lines(ctx, d, s)
    local loc = ctx.loc
    if not d.communications then
        return loc_text(loc, d.xenophobe and "NO_COMMUNICATIONS_VESSEL_XENOPHOBE" or "NO_COMMUNICATIONS_VESSEL"), ""
    end
    local sizes = fleet.ship_sizes(ctx.game_dir)
    local c = fleet.CLASS[(sizes[s.size] or {}).class or ""] or 0
    local line1 = "§H" .. loc_text(loc, "SHIP_SIZE_NAME", { SHIP_SIZE = loc_text(loc, s.size), SHIP_NAME = name_text(loc, s.name) }) .. "§!"
    local icon = fleet.CLASS_TEXT_ICON[c]
    local class = loc_text(loc, "SHIP_CLASS", { CLASS = name_text(loc, s.design_name) })
    local line2 = "§" .. (fleet.CLASS_COLOUR[c] or "W") .. (icon and ("£" .. icon .. "£") or "") .. class .. "§!"
    return line1, line2
end

function fleet.fleet_view(ctx, d)
    local loc = ctx.loc
    local sizes = fleet.ship_sizes(ctx.game_dir)
    -- the ships sorted by size and name (SSortFleetShipBySizeAndName: the larger first [I])
    table.sort(d.ships, function(a, b)
        local za, zb = (sizes[a.size] or {}).size_multiplier or 0, (sizes[b.size] or {}).size_multiplier or 0
        if za ~= zb then
            return za > zb
        end
        return name_text(loc, a.name) < name_text(loc, b.name)
    end)
    -- the rows: the summary when the fleet has 2 ships or more, a row per ship [V]
    local summary = #d.ships >= 2
    local heights = {}
    if summary then
        heights[#heights + 1] = SUMMARY_H
    end
    for _ = 1, #d.ships do
        heights[#heights + 1] = ROW_H
    end
    local list_h = 0
    for i, h in ipairs(heights) do
        list_h = list_h + h + (i > 1 and SPACING or 0)
    end
    local entry_h = ENTRY_H + list_h + (#heights > 0 and 0 or 0)
    -- CFleetView::UpdateSize: the header's height and the list's, at most the screen's less
    -- fleet_view_max_height_subtraction (115) [V]
    local h = math.min(50 + entry_h, ctx.screen.height - 115)
    local _, wr = layout(ctx, FLEET_GUI, "fleet_view", {
        sizes = { ["/fleet_view"] = { 510, h }, ["/fleet_view/fleets"] = { 500, h - 50 } },
        actions = { ["/fleet_view/header/close"] = "close" },
    })
    local list = wr.rects["/fleet_view/fleets"]
    if not list then
        return
    end
    local grid = wr.rects["/fleet_view/header/orders/orders"]
    if grid then
        button_grid(ctx, "fleet_view_order_button", grid, 34, 30, header_orders(d), "/fleet_view/header_orders", false, nil, d.id)
    end

    local p = "/fleet_view/fleets/fleet_view_entry"
    local cls = fleet.CLASS[d.class]
    -- without communications: CFleet::GetLocalName's NO_COMMUNICATIONS_FLEET (_XENOPHOBE for a
    -- xenophobe observer) [I: the keys; the game's frame shows "Alien Menace"]
    local name = d.communications and name_text(loc, d.name)
        or loc_text(loc, d.xenophobe and "NO_COMMUNICATIONS_FLEET_XENOPHOBE" or "NO_COMMUNICATIONS_FLEET")
    -- CFleet::GetTypeName [V]: the first ship's size name; none for the classes of the mask
    -- 0x771 (EShipClass 0, 4-6, 8-10) unless the fleet's property bit 9 (mobile [I])
    local type_name = ""
    local first = d.ships[1]
    if first then
        local c = fleet.CLASS[(sizes[first.size] or {}).class or ""] or 0
        local masked = c == 0 or c == 4 or c == 5 or c == 6 or (c >= 8 and c <= 10)
        if not masked or d.mobile then
            type_name = loc_text(loc, first.size)
        end
    end
    -- the fleet's hull, armor, shields (CFleet::CalcHitPointsPercent ...: over its ships)
    local hp, hpm, ar, arm, sh, shm, used = 0, 0, 0, 0, 0, 0, 0
    for _, s in ipairs(d.ships) do
        hp, hpm = hp + s.hp, hpm + s.hp_max
        ar, arm = ar + s.armor, arm + s.armor_max
        sh, shm = sh + s.shield, shm + s.shield_max
        local z = sizes[s.size]
        used = used + (z and z.size_multiplier or 1)
    end
    -- the leader block, the orders grid (CFleetView::UpdateOrders) [V]
    local leader_shown = d.leader ~= nil and (d.player or d.communications)
    local can_lead = cls == 0 or cls == 3 or cls == 2
    local orders_window = nil
    if d.communications then
        if not can_lead and cls ~= 9 and cls ~= 2 then
            orders_window = "orders_large"
        elseif cls == 9 then
            orders_window = "observation_orders"
        else
            orders_window = "orders_small"
        end
    end
    local tpl = d.template_size
    local size_text = loc_text(loc, "FLEET_TEMPLATE_SIZE_WITH_LIMIT", {
        SIZE_STRING = loc_text(loc, "VALUE_OUT_OF_MAX", { VALUE = used, MAX = d.command_limit or 50 }),
        LIMIT_STRING = loc_text(loc, (tpl and tpl > used) and "FLEET_TEMPLATE_SIZE_LIMIT_UNREACHED_VALUE_FORMAT" or "FLEET_TEMPLATE_SIZE_LIMIT_REACHED_VALUE_FORMAT", { VALUE = tpl or used }),
    })
    local power_text = cls == 4 and loc_text(loc, "ARMY_POWER", { VALUE = fleet.si_number(d.military_power) })
        or loc_text(loc, d.template and "FLEET_TEMPLATE_MILITARY_POWER" or "MILITARY_POWER", {
            POWER_STRING = loc_text(loc, "FLEET_TEMPLATE_POWER_MAX_REACHED_VALUE_FORMAT", { CURRENT_STRING = fleet.si_number(d.military_power) }),
            VALUE = fleet.si_number(d.military_power),
        })
    local orders_text = fleet.order_text(loc, d)
    local text = {
        [p .. "/top/fleet_name"] = name,
        [p .. "/top/fleet_type"] = d.communications and type_name or "",
        [p .. "/top/unknown_faction_name"] = d.communications and "" or loc_text(loc, "YELLOW_COLOR", { KEY = loc_text(loc, "UNKNOWN_COUNTRY") }),
        [p .. "/bottom/hull_points"] = loc_text(loc, "HULL_STATE", { VALUE = green_red_percent(fraction(hp, hpm)) }),
        [p .. "/bottom/armor_points"] = loc_text(loc, "ARMOR_STATE", { VALUE = green_red_percent(fraction(ar, arm)) }),
        [p .. "/bottom/shield_points"] = loc_text(loc, "SHIELD_STATE", { VALUE = green_red_percent(fraction(sh, shm)) }),
        [p .. "/bottom/size_limit"] = size_text,
        [p .. "/bottom/fleet_power"] = power_text,
        [p .. "/bottom/orders"] = orders_text,
        [p .. "/bottom/activity"] = d.activity_text or "",
    }
    local only = {
        top = true, bottom = true, drop_area = false,
        portrait_container = leader_shown,
        precommunications = not d.communications,
    }
    if orders_window then
        only[orders_window] = true
    end
    local hide = {
        rename_button = true, toggle_armada_commanding_mode = true, go_to_planet_view = true,
        cloaking_values = true,
        [p .. "/top/unknown_faction_name"] = d.communications,
        [p .. "/top/open_fleet_manager"] = cls ~= 0,
        [p .. "/bottom/hull_points"] = not d.communications, [p .. "/bottom/armor_points"] = not d.communications,
        [p .. "/bottom/shield_points"] = not d.communications,
        [p .. "/bottom/size_limit"] = not (d.player and (cls == 0)),
        [p .. "/bottom/fleet_power"] = not (d.communications and (cls == 0 or cls == 4)),
        [p .. "/bottom/activity"] = (d.activity_text or "") == "",
        [p .. "/bottom/orders"] = not d.player and not d.communications,
    }
    -- the disband button's sprite: a leased fleet's, a fleet of command points over 1, others'
    -- (fleet+0x1280 < 100001) [V]
    local disband = used > 1 and "GFX_delete_template_button" or "GFX_fleetview_destroy_fleet"
    local entry_from = #ctx.items + 1
    local _, er = layout(ctx, FLEET_GUI, "fleet_view_entry", {
        prefix = "/fleet_view/fleets",
        parent = { x = list.x, y = list.y, w = 510, h = entry_h },
        sizes = { [p] = { 510, entry_h } },
        only = only, hide = hide, text = text,
        frames = { [p .. "/top/icon"] = d.communications and fleet.CLASS_ICON_FRAME[cls or 0] or 11 },
        sprites = { [p .. "/top/header_button"] = header_sprite(d), [p .. "/top/disband"] = disband },
        actions = {
            [p .. "/top/deselect"] = "close",
            [p .. "/top/open_fleet_manager"] = "fleet:manager:" .. d.id,
            [p .. "/top/focus_on"] = "fleet:focus:" .. d.id,
            [p .. "/top/disband"] = "fleet:do:" .. d.id .. ":disband",
        },
    })
    -- another's fleet: its disband and fleet manager buttons disabled (CanBeDisbandedBy, the
    -- template the observer's) [V]; Investigate without an active first contact [I]
    -- without communications the flag is the unknown one (PRE_COMMUNICATIONS_EMPIRE_FLAG: made by
    -- fleetwin.rs)
    if not d.communications then
        for i = entry_from, #ctx.items do
            local it = ctx.items[i]
            if it.path == p .. "/top/flag" and it.kind == "sprite" then
                it.sprite_kind = "unknownFlag"
            end
        end
    end
    if not d.player then
        grey(ctx, entry_from, p .. "/top/disband")
        grey(ctx, entry_from, p .. "/top/open_fleet_manager")
        grey(ctx, entry_from, p .. "/precommunications/investigate")
    end
    -- the leader (portrait_container: CParagonPortraitContainer)
    local pc = er.rects[p .. "/portrait_container"]
    if leader_shown and pc then
        paragon(ctx, d.leader, { x = pc.x, y = pc.y, w = pc.w, h = pc.h }, "/fleet_view/leader")
    end
    -- the orders grid of the window shown, the actions grid
    if orders_window then
        local g = er.rects[p .. "/" .. orders_window .. "/orders"]
        local SLOTS = { orders_small = { 51, 50, 4 }, orders_large = { 49, 50, 5 }, observation_orders = { 50, 48, 4 } }
        local sl = SLOTS[orders_window]
        if g and sl then
            button_grid(ctx, "fleet_view_order_button", g, sl[1], sl[2], fleet_orders(d), "/fleet_view/orders", false, sl[3], d.id)
        end
    end
    local ag = er.rects[p .. "/bottom/actions"]
    if ag and d.communications then
        button_grid(ctx, "fleet_view_action_button", ag, 34, 34, fleet_actions(d), "/fleet_view/actions", true, nil, d.id)
    end

    -- the ships: the summary, then a row each
    local y = list.y + 256
    if summary then
        local sp = "/fleet_view/summary/fleet_view_summary"
        layout(ctx, FLEET_GUI, "fleet_view_summary", {
            prefix = "/fleet_view/summary",
            parent = { x = list.x, y = y, w = 510, h = SUMMARY_H },
            hide = { interactable_bg = true },
        })
        -- an entry per ship size (DivideShipsToGroups: in the order first seen) [V]
        local groups, order = {}, {}
        for _, s in ipairs(d.ships) do
            local g = groups[s.size]
            if not g then
                g = { size = s.size, ships = {} }
                groups[s.size] = g
                order[#order + 1] = g
            end
            g.ships[#g.ships + 1] = s
        end
        for gi, g in ipairs(order) do
            local z = sizes[g.size] or {}
            local gp = "/fleet_view/summary/" .. gi
            local ep = gp .. "/fleet_view_summary_entry"
            local hpf, arf, shf, damaged = 0, 0, 0, false
            for _, s in ipairs(g.ships) do
                hpf = hpf + fraction(s.hp, s.hp_max)
                arf = arf + fraction(s.armor, s.armor_max)
                shf = shf + fraction(s.shield, s.shield_max)
                damaged = damaged or s.hp < s.hp_max
            end
            local n = #g.ships
            local upgradable = false
            for _, s in ipairs(g.ships) do
                upgradable = upgradable or (d.player and s.upgradable)
            end
            local count = tostring(n)
            local tcount = d.template_counts and d.template_counts[g.size]
            if tcount and d.player then
                count = "§W" .. loc_text(loc, "VALUE_OUT_OF_MAX", { VALUE = n, MAX = tcount }) .. "§!"
            end
            local icon = z.icon and ("GFX_" .. z.icon .. "_top") or nil
            layout(ctx, FLEET_GUI, "fleet_view_summary_entry", {
                prefix = gp,
                parent = { x = list.x + (gi - 1) * 94, y = y, w = 94, h = 42 },
                hide = { icon = damaged, icon_damaged = not damaged, upgradable = not upgradable },
                sprites = icon and { [ep .. "/icon"] = icon, [ep .. "/icon_damaged"] = icon .. "_damaged" } or nil,
                text = { [ep .. "/count"] = count },
            })
            bar(ctx, ep .. "/health", 100 * hpf / n)
            bar(ctx, ep .. "/armor", 100 * arf / n)
            bar(ctx, ep .. "/shields", 100 * shf / n)
        end
        y = y + SUMMARY_H + SPACING
    end
    for i, s in ipairs(d.ships) do
        local rp = "/fleet_view/ship/" .. i
        local sp = rp .. "/fleet_view_subentry"
        local z = sizes[s.size] or {}
        local line1, line2 = ship_lines(ctx, d, s)
        local from = #ctx.items + 1
        local _, rr = layout(ctx, FLEET_GUI, "fleet_view_subentry", {
            prefix = rp,
            parent = { x = list.x, y = y, w = 510, h = ROW_H },
            hide = { inspect_army = true },
            sprites = z.icon and { [sp .. "/icon"] = "GFX_" .. z.icon } or nil,
            text = { [sp .. "/name"] = line1 },
            actions = { [sp .. "/inspect"] = "fleet:ship:" .. s.id, [sp .. "/disband"] = "fleet:ship_do:" .. s.id .. ":disband" },
        })
        -- the disband button: the observer's fleets only (CanBeDisbandedBy) [V]
        if not d.player then
            grey(ctx, from, sp .. "/disband")
        end
        -- inspect: CanInspectShip (no communications: not) [I: the game's dimmer icon]
        if not d.communications then
            grey(ctx, from, sp .. "/inspect")
        end
        -- the two lines of the name box (44 high, centred): the second under the first, laid out
        -- as the same element again [I: the renderer draws one line a text]
        if line2 ~= "" then
            local l2 = rp .. "/line2"
            layout(ctx, FLEET_GUI, "fleet_view_subentry", {
                prefix = l2,
                parent = { x = list.x, y = y, w = 510, h = ROW_H },
                only = { name = true },
                text = { [l2 .. "/fleet_view_subentry/name"] = line2 },
            })
            for k = from, #ctx.items do
                local it = ctx.items[k]
                if it.kind == "text" and (it.path == sp .. "/name" or it.path == l2 .. "/fleet_view_subentry/name") then
                    local second = it.path ~= sp .. "/name"
                    it.valign, it.y, it.h = "top", it.y + (second and 22 or 6), 16
                end
            end
        end
        bar(ctx, sp .. "/health", 100 * fraction(s.hp, s.hp_max))
        bar(ctx, sp .. "/armor", 100 * fraction(s.armor, s.armor_max))
        bar(ctx, sp .. "/shields", 100 * fraction(s.shield, s.shield_max))
        y = y + ROW_H + SPACING
    end
end

---------------------------------------------------------------- ship_view

-- the `@name = value` statements at a file's top (a definition file's own variables)
local function file_variables(tree)
    local vars = {}
    for _, e in ipairs(tree or {}) do
        if e.op and e.key and e.key.text:sub(1, 1) == "@" and e.value and e.value.text then
            vars[e.key.text] = e.value.text
        end
    end
    return vars
end

-- the numbers of a modifier block: name -> value
local function modifier_values(game_dir, b, vars)
    local out = {}
    for _, e in ipairs(type(b) == "table" and b or {}) do
        if e.op and e.key and e.value and e.value.text then
            local v = e.value.text
            out[e.key.text] = tonumber(vars[v] or v) or value(game_dir, v)
        end
    end
    return out
end

-- common/component_templates: key -> { kind (weapon_component_template, utility_...), icon,
-- icon_frame, size, power, modifier = { name -> value }, order (the load order) } with the weapons'
-- stats of weapon_components.csv (power, damage, windup, cooldown, accuracy)
function fleet.components(game_dir)
    if cache.components then
        return cache.components
    end
    local out, order = {}, 0
    for _, file in ipairs(source.files(game_dir, "common/component_templates", "txt")) do
        local tree = source.parse(game_dir, file)
        local vars = file_variables(tree)
        for _, e in ipairs(tree or {}) do
            if e.op and e.key and type(e.value) == "table" and e.value.text == nil then
                local b = e.value
                local key = get(b, "key")
                if key then
                    order = order + 1
                    local p = get(b, "power")
                    out[key:gsub('"', "")] = {
                        kind = e.key.text, icon = get(b, "icon"), icon_frame = tonumber(get(b, "icon_frame")),
                        size = get(b, "size"), component_set = get(b, "component_set"),
                        power = p and (tonumber(vars[p] or p) or value(game_dir, p)) or nil,
                        modifier = modifier_values(game_dir, get(b, "modifier"), vars), order = order,
                    }
                end
            end
        end
    end
    -- weapon_components.csv: key;cost;power;min_damage;max_damage;...;min_windup;max_windup;cooldown;
    -- range;accuracy;tracking;...
    local fs = source.filesystem(game_dir)
    local path = fs:path("common/component_templates/weapon_components.csv")
    local f = path and io.open(path, "r")
    if f then
        local cols
        for line in f:lines() do
            if line:sub(1, 1) ~= "#" then
                local cells = {}
                for c in (line .. ";"):gmatch("([^;]*);") do
                    cells[#cells + 1] = c
                end
                if cells[1] == "key" then
                    cols = {}
                    for i, c in ipairs(cells) do
                        cols[c] = i
                    end
                elseif cols and out[cells[1]] then
                    local w = {}
                    for _, k in ipairs({ "power", "min_damage", "max_damage", "min_windup", "max_windup", "cooldown", "accuracy" }) do
                        w[k] = tonumber(cells[cols[k]])
                    end
                    out[cells[1]].weapon = w
                    out[cells[1]].power = out[cells[1]].power or w.power
                end
            end
        end
        f:close()
    end
    cache.components = out
    return out
end

-- EComponentSlotSize [I: GFX_ship_designer_slot's frames], EComponentType (0 weapon, 1 utility,
-- 2 strike craft, 4 any)
local SLOT_SIZE = { point_defence = 0, small = 1, medium = 2, large = 3, torpedo = 4, extra_large = 5, titanic = 6, planet_killer = 7, aux = 9 }
local SLOT_TYPE = { weapon = 0, utility = 1, strike_craft = 2 }

-- common/section_templates: key -> its slots in order { name, size, type }: the component_slot
-- entries (their component_slot_templates' size and component), then <size>_utility_slots
-- (SMALL_UTILITY_1 ...) and aux_utility_slots (AUX_UTILITY_1 ...)
local function sections(game_dir)
    if cache.sections then
        return cache.sections
    end
    local slot_t = {}
    for name, d in pairs(source.definitions(game_dir, "common/component_slot_templates")) do
        slot_t[name] = { size = get(d.block, "size"), component = get(d.block, "component") }
    end
    local out = {}
    for _, file in ipairs(source.files(game_dir, "common/section_templates", "txt")) do
        local tree = source.parse(game_dir, file)
        for _, e in ipairs(tree or {}) do
            if e.op and e.key and type(e.value) == "table" and e.value.text == nil then
                local b = e.value
                local key = get(b, "key")
                if key then
                    local slots = {}
                    for _, s in ipairs(b) do
                        if s.op and s.key and s.key.text == "component_slot" and type(s.value) == "table" then
                            local t = slot_t[(get(s.value, "template") or ""):gsub('"', "")] or {}
                            slots[#slots + 1] = { name = (get(s.value, "name") or ""):gsub('"', ""), size = t.size, type = t.component }
                        end
                    end
                    for _, size in ipairs({ "small", "medium", "large", "aux" }) do
                        for i = 1, tonumber(get(b, size .. "_utility_slots")) or 0 do
                            slots[#slots + 1] = { name = size:upper() .. "_UTILITY_" .. i, size = size, type = "utility" }
                        end
                    end
                    out[key:gsub('"', "")] = slots
                end
            end
        end
    end
    cache.sections = out
    return out
end

-- static modifiers used here: name -> { modifier -> value }
local function static_modifiers(game_dir)
    if cache.static then
        return cache.static
    end
    local out = {}
    for name, d in pairs(source.definitions(game_dir, "common/static_modifiers")) do
        out[name] = modifier_values(game_dir, d.block, {})
    end
    cache.static = out
    return out
end

-- a number cut (not rounded) to `n` decimals, as the game's frames show the ship's stats
-- ("7.69" for 7.696, "62.3" for 62.33) [I]
local function cut(v, n)
    local m = 10 ^ n
    return math.floor(v * m + 1e-9) / m
end

-- the ship's stats as CShip::CalcMaxDisplaySpeed, CalcEvasion and CalcAverageDamagePerDay give
-- them, from its design [I: the formulas fitted to the game's numbers of the 2210 corvette, the
-- terms read in the game's files]:
--   power: the reactor's (the core components' positive power) x (1 + ship_reactor_power_mult)
--   against the other components' use; excess e = (made - used) / made, and the static modifier
--   ship_excess_power (+10% speed, evasion, weapon damage) x e when e >= EXCESS_POWER_BONUS_
--   THRESHOLD_MIN (0.05), at most 1;
--   speed: the ship size's max_speed x (1 + ship_speed_mult);
--   evasion: (the size's ship_evasion_add + the components') x (1 + ship_evasion_mult), in %;
--   damage a day: over the weapons, (min + max) / 2 x (1 + ship_weapon_damage) x accuracy x (1 +
--   ship_fire_rate_mult) / ((cooldown + (min_windup + max_windup) / 2) / 10);
--   the fire rate: the admiral's skill (skill_commander_navy x level). Modifiers of the country
--   (technologies, traditions) are not counted: the game's capture of the 2210 save has none on
--   the player's ships.
function fleet.ship_stats(game_dir, d)
    local comps = fleet.components(game_dir)
    local sizes = fleet.ship_sizes(game_dir)
    local statics = static_modifiers(game_dir)
    local all = {}
    for _, c in ipairs(d.components or {}) do
        all[#all + 1] = comps[c.template]
    end
    for _, r in ipairs(d.required or {}) do
        all[#all + 1] = comps[r]
    end
    local made, used = 0, 0
    local mods = {}
    local function add(m, k)
        for n, v in pairs(m or {}) do
            mods[n] = (mods[n] or 0) + v * (k or 1)
        end
    end
    for _, c in pairs(all) do
        local p = c.power or 0
        if p > 0 then
            made = made + p
        else
            used = used - p
        end
        add(c.modifier)
    end
    made = made * (1 + (mods.ship_reactor_power_mult or 0))
    local e = made > 0 and (made - used) / made or 0
    if e >= 0.05 then
        add(statics.ship_excess_power, math.min(e, 1))
    end
    local leader = d.fleet_leader
    if leader and leader.class == "commander" then
        add(statics.skill_commander_navy, leader.level or 0)
    end
    local z = sizes[d.size] or {}
    local size_mods = {}
    for _, def in pairs({ source.definitions(game_dir, "common/ship_sizes")[d.size] }) do
        size_mods = modifier_values(game_dir, get(def.block, "modifier"), {})
    end
    local speed = (z.max_speed or 0) * (1 + (mods.ship_speed_mult or 0))
    local evasion = ((size_mods.ship_evasion_add or 0) + (mods.ship_evasion_add or 0)) * (1 + (mods.ship_evasion_mult or 0))
    local damage = 0
    for _, c in pairs(all) do
        local w = c.weapon
        if w and w.min_damage and w.cooldown then
            local period = (w.cooldown + ((w.min_windup or 0) + (w.max_windup or 0)) / 2) / 10
            if period > 0 then
                damage = damage + (w.min_damage + w.max_damage) / 2 * (1 + (mods.ship_weapon_damage or 0))
                    * (w.accuracy or 1) * (1 + (mods.ship_fire_rate_mult or 0)) / period
            end
        end
    end
    return { speed = cut(speed, 0), evasion = cut(evasion, 1), damage = cut(damage, 2) }
end

-- the ship's ranks by experience (static modifiers ship_rank_*) [I: the thresholds not read; a
-- ship of the save without experience is Regular]
local function ship_rank(d)
    return "ship_rank_regular"
end

-- a ship view component entry: a sprite and frame of the component, the slot's frame
local function slot_frame(slot, comp)
    local t = slot and SLOT_TYPE[slot.type] or 4
    local sz = slot and SLOT_SIZE[slot.size] or 11
    if t == 4 and comp then
        t = comp.kind == "weapon_component_template" and 0 or comp.kind == "strike_craft_component_template" and 2 or 1
    end
    if t == 1 then
        return sz == 9 and 13 or sz
    elseif t == 2 then
        return 13 + sz
    end
    return sz + 4
end

function fleet.ship_view(ctx, d)
    local loc = ctx.loc
    local sizes = fleet.ship_sizes(ctx.game_dir)
    local comps = fleet.components(ctx.game_dir)
    local st = fleet.ship_stats(ctx.game_dir, d)
    local military = (fleet.CLASS[(sizes[d.size] or {}).class or ""] or 0) == 0
    local text = {
        ["/ship_view/name"] = name_text(loc, d.name),
        -- the design's long name: LONG_SHIPCLASS_NAME ("$NAME$-class $SIZE$") [I: the key]
        ["/ship_view/type"] = loc_text(loc, "LONG_SHIPCLASS_NAME", { NAME = name_text(loc, d.design_name), SIZE = loc_text(loc, d.size) }),
        ["/ship_view/stats/hitpoints_value"] = loc_text(loc, "SHIP_STAT_HITPOINTS_VALUE", { VALUE = d.hp_max }),
        ["/ship_view/stats/armor_value"] = loc_text(loc, "SHIP_STAT_ARMOR_VALUE", { VALUE = d.armor_max }),
        ["/ship_view/stats/shields_value"] = loc_text(loc, "SHIP_STAT_SHIELDS_VALUE", { VALUE = d.shield_max }),
        ["/ship_view/stats/speed_value"] = loc_text(loc, "SHIP_STAT_SPEED_VALUE", { VALUE = st.speed }),
        ["/ship_view/stats/evasion_value"] = loc_text(loc, "SHIP_STAT_EVASION_VALUE", { VALUE = st.evasion }),
        ["/ship_view/stats/damage_value"] = loc_text(loc, "SHIP_STAT_DAMAGE_VALUE", { VALUE = st.damage }),
        ["/ship_view/stats/rank_value"] = "§Y" .. loc_text(loc, ship_rank(d)) .. "§!",
        ["/ship_view/buttons/open_designer"] = loc_text(loc, "OPEN_DESIGNER"),
    }
    local from = #ctx.items + 1
    local hide = set({ "cloaking", "cloaking_level", "growth", "rename_button", "ship_model" })
    if not military then
        hide.rank, hide.rank_value = true, true
    end
    local _, wr = layout(ctx, SHIP_GUI, "ship_view", {
        hide = hide,
        text = text,
        actions = {
            ["/ship_view/close"] = "fleet:close_ship",
            ["/ship_view/buttons/open_fleet_manager"] = "fleet:manager:" .. tostring(d.fleet or ""),
            ["/ship_view/buttons/open_designer"] = "fleet:designer:" .. tostring(d.upgrade_to and d.upgrade_to ~= 4294967295 and d.upgrade_to or d.design or ""),
        },
    })
    -- the buttons: the local player's ship that can be upgraded (CShip::CanBeUpgraded) [V]
    if not (d.player and d.upgradable) then
        grey(ctx, from, "/ship_view/buttons/")
    end
    -- the core components: the design's required list, in order (UpdateComponents) [V]
    local grid = wr.rects["/ship_view/components/components"]
    if grid then
        for i, key in ipairs(d.required or {}) do
            local c = comps[key]
            local col, row = (i - 1) % 6, math.floor((i - 1) / 6)
            local p = "/ship_view/core/" .. i
            local ep = p .. "/ship_view_required_component_entry"
            layout(ctx, SHIP_GUI, "ship_view_required_component_entry", {
                prefix = p,
                parent = { x = grid.x + col * 58, y = grid.y + row * 78, w = 0, h = 0 },
                hide = { icon = c == nil or c.icon == nil },
                sprites = c and c.icon and { [ep .. "/icon"] = c.icon } or nil,
                frames = c and c.icon and { [ep .. "/icon"] = c.icon_frame or 1 } or nil,
            })
        end
    end
    -- the armaments and utilities: every slot of the design's sections (empty ones too), by the
    -- slot's type, each list in the order of the slot's size, then the component's [V]
    local secs = sections(ctx.game_dir)
    local placed = {}
    for _, c in ipairs(d.components or {}) do
        placed[c.section .. "/" .. c.slot] = c.template
    end
    local arms, utils = {}, {}
    for _, sec in ipairs(d.sections or {}) do
        for _, sl in ipairs(secs[sec] or {}) do
            local key = placed[sec .. "/" .. sl.name]
            local c = key and comps[key]
            local t = SLOT_TYPE[sl.type] or 4
            if t == 4 and c then
                t = c.kind == "weapon_component_template" and 0 or 1
            end
            local e = { slot = sl, comp = c, size = SLOT_SIZE[sl.size] or 11, order = c and c.order or 1e9 }
            local list = (t == 0 or t == 2) and arms or utils
            e.index = #list + 1
            list[#list + 1] = e
        end
    end
    local function by_size(a, b)
        if a.size ~= b.size then
            return a.size < b.size
        end
        if a.order ~= b.order then
            return a.order < b.order
        end
        return a.index < b.index
    end
    table.sort(arms, by_size)
    table.sort(utils, by_size)
    local sets = wr.rects["/ship_view/component_sets"]
    if sets then
        local y = sets.y
        for k, part in ipairs({ { "ship_view_armaments", "armaments", arms }, { "ship_view_utilities", "utilities", utils } }) do
            local p = "/ship_view/sets/" .. k
            local _, sr = layout(ctx, SHIP_GUI, part[1], { prefix = p, parent = { x = sets.x, y = y, w = 0, h = 0 } })
            local g = sr.rects[p .. "/" .. part[1] .. "/list/" .. part[2]]
            if g then
                for i, e in ipairs(part[3]) do
                    local col, row = (i - 1) % 10, math.floor((i - 1) / 10)
                    local ip = p .. "/" .. i
                    local ep = ip .. "/ship_view_component_entry"
                    local c = e.comp
                    layout(ctx, SHIP_GUI, "ship_view_component_entry", {
                        prefix = ip,
                        parent = { x = g.x + col * 56, y = g.y + row * 56, w = 0, h = 0 },
                        hide = { icon = c == nil or c.icon == nil },
                        sprites = c and c.icon and { [ep .. "/icon"] = c.icon } or nil,
                        frames = { [ep .. "/icon"] = c and c.icon_frame or 1, [ep .. "/icon_bg"] = slot_frame(e.slot, c) },
                    })
                end
            end
            y = y + 150
        end
    end
    return wr
end

---------------------------------------------------------------- fleet_manager_view

-- a fleet's command size ("§Y15§!/§Y50§! (15)": BuildFleetTemplateCountString) [V]
local function template_count(loc, game_dir, f)
    local sizes = fleet.ship_sizes(game_dir)
    local used = 0
    for _, s in ipairs(f.ships) do
        used = used + ((sizes[s.size] or {}).size_multiplier or 1)
    end
    local tpl = f.template_size or used
    return loc_text(loc, "FLEET_TEMPLATE_SIZE_WITH_LIMIT", {
        SIZE_STRING = loc_text(loc, "VALUE_OUT_OF_MAX", { VALUE = "§Y" .. used .. "§!", MAX = "§Y" .. (f.command_limit or 50) .. "§!" }),
        LIMIT_STRING = loc_text(loc, tpl > used and "FLEET_TEMPLATE_SIZE_LIMIT_UNREACHED_VALUE_FORMAT" or "FLEET_TEMPLATE_SIZE_LIMIT_REACHED_VALUE_FORMAT", { VALUE = tpl }),
    }), used
end

-- the country's naval capacity (CCountry::CalcNavalCapacity): NAVAL_CAPACITY_BASE 50 plus
-- country_naval_cap_add, times 1 + country_naval_cap_mult, cut to a whole number [I: the terms
-- counted are the councilors' traits' councilor_modifier]
local function naval_capacity(game_dir, d)
    local add, mult = 0, 0
    for _, file in ipairs(source.files(game_dir, "common/traits", "txt")) do
        cache.trait_files = cache.trait_files or {}
        if not cache.trait_files[file] then
            cache.trait_files[file] = true
            local tree = source.parse(game_dir, file)
            cache.councilor_mods = cache.councilor_mods or {}
            for _, e in ipairs(tree or {}) do
                if e.op and e.key and type(e.value) == "table" and e.value.text == nil then
                    cache.councilor_mods[e.key.text] = modifier_values(game_dir, get(e.value, "councilor_modifier"), file_variables(tree))
                end
            end
        end
    end
    for _, t in ipairs(d.councilor_traits or {}) do
        local m = (cache.councilor_mods or {})[t] or {}
        add = add + (m.country_naval_cap_add or 0)
        mult = mult + (m.country_naval_cap_mult or 0)
    end
    return math.floor((50 + add) * (1 + mult) + 1e-9)
end

function fleet.manager_view(ctx, d)
    local loc = ctx.loc
    local sizes = fleet.ship_sizes(ctx.game_dir)
    local sel
    for _, f in ipairs(d.fleets) do
        if f.id == d.selected then
            sel = f
        end
    end
    local W = "/fleet_manager_view"
    local cap = naval_capacity(ctx.game_dir, d)
    local used_cap = d.used_naval_capacity or 0
    -- the reinforcement: the fleets with fewer ships than their template (CalcAllShipsToReinforce)
    local need = 0
    for _, f in ipairs(d.fleets) do
        if (f.template_ships or 0) > #f.ships then
            need = need + 1
        end
    end
    local text = {
        [W .. "/box2/naval_capacity/naval_capacity_text"] = loc_text(loc, "NAVY_LIMIT_VALUE", {
            NAVY_SIZE_TITLE = loc_text(loc, "NAVY_SIZE_TITLE"),
            SIZE = used_cap > cap and ("§R" .. used_cap .. "§!") or used_cap, LIMIT = cap,
        }),
        [W .. "/box2/reinforcement/reinforce_fleet_text"] = need == 0 and loc_text(loc, "FLEET_MANAGER_VIEW_NO_REINFORCE_TEXT") or "",
    }
    local hide = { available_window = true, retrofit_window = true }
    local only_hide = {}
    if sel then
        local lp = W .. "/box1/fleet_orders/stats"
        local tc = template_count(loc, ctx.game_dir, sel)
        local hp, hpm, ar, arm, sh, shm = 0, 0, 0, 0, 0, 0
        for _, s in ipairs(sel.ships) do
            hp, hpm, ar, arm, sh, shm = hp + s.hp, hpm + s.hp_max, ar + s.armor, arm + s.armor_max, sh + s.shield, shm + s.shield_max
        end
        text[W .. "/box1/fleet_name"] = name_text(loc, sel.name)
        text[lp .. "/template_size"] = tc
        text[lp .. "/offensive_power"] = loc_text(loc, "FLEET_TEMPLATE_MILITARY_POWER", {
            POWER_STRING = loc_text(loc, "FLEET_TEMPLATE_POWER_MAX_REACHED_VALUE_FORMAT", { CURRENT_STRING = fleet.si_number(sel.military_power) }),
        })
        text[lp .. "/health"] = loc_text(loc, "FLEET_MANAGER_HEALTH", { VALUE = fraction(hp, hpm) })
        text[lp .. "/armor"] = loc_text(loc, "FLEET_MANAGER_ARMOR", { VALUE = fraction(ar, arm) })
        text[lp .. "/shields"] = loc_text(loc, "FLEET_MANAGER_SHIELD", { VALUE = fraction(sh, shm) })
        text[lp .. "/current_order"] = fleet.order_text(loc, sel)
        text[lp .. "/current_activity"] = ""
        local used = 0
        for _, s in ipairs(sel.ships) do
            used = used + ((sizes[s.size] or {}).size_multiplier or 1)
        end
        text[W .. "/box2/box2_3/fleet_info/command_limit/command_limit_header"] = loc_text(loc, "COMMAND_LIMIT_VALUE", {
            COMMAND_LIMIT = loc_text(loc, "COMMAND_LIMIT"), CURRENT = sel.template_size or used, LIMIT = sel.command_limit or 50,
        })
        hide.select_template_hint = true
    else
        hide.fleet_orders, hide.fleet_info = true, true
    end
    -- box1's background (the selected fleet's red bar) is a plain sprite at its own position:
    -- drawn below at (317, 103)
    hide[W .. "/box1/background"] = true
    local from = #ctx.items + 1
    -- the buttons: the selected fleet's as the fleet window's (fleet:do:FID:NAME, render.windows.
    -- fleet_commands), the others with no fleet (fid 0)
    local actions = {
        [W .. "/close"] = d.view and "view_close" or "fleet:close_manager",
        [W .. "/ship_designer_tab"] = "fleet:designer",
        [W .. "/create_new_fleet"] = "fleet:do:0:create_new_fleet",
        [W .. "/reinforce_all"] = "fleet:do:0:reinforce_all",
        [W .. "/policies"] = "fleet:do:0:policies",
    }
    if sel then
        local fa = "fleet:do:" .. sel.id .. ":"
        local FA = W .. "/box2/box2_3/fleet_info/actions/"
        actions[W .. "/box1/fleet_orders/header/stop"] = fa .. "stop"
        actions[W .. "/box1/fleet_orders/header/return"] = fa .. "return"
        actions[W .. "/box1/fleet_orders/header/take_point"] = fa .. "take_point"
        actions[W .. "/box1/fleet_orders/stats/change_stance"] = fa .. "stance"
        actions[W .. "/box1/fleet_orders/stats/home_base_button"] = fa .. "home_base"
        actions[W .. "/box1/rename_button"] = fa .. "rename"
        actions[FA .. "overwrite_design_with_current"] = fa .. "overwrite"
        actions[FA .. "reinforce"] = fa .. "reinforce"
        actions[FA .. "repair"] = fa .. "repair"
        actions[FA .. "upgrade"] = fa .. "upgrade"
        actions[FA .. "disband"] = fa .. "disband"
        actions[FA .. "copy_template"] = fa .. "copy_template"
    end
    local _, wr = layout(ctx, MANAGER_GUI, "fleet_manager_view", {
        hide = hide, text = text,
        sprites = { [W .. "/box1/fleet_orders/stats/change_stance"] = sel and (STANCE[sel.stance] or "GFX_fleet_order_button_stance_passive") or nil },
        actions = actions,
    })
    -- the disabled ones: Space Fauna (artificial breeding), reinforce all (nothing to reinforce),
    -- stop (no orders), the fleet's reinforce (complete) and repair (undamaged) [V: their
    -- conditions; I: their states here]
    local disabled = { W .. "/creature_designer_tab", W .. "/reinforce_all" }
    if not sel or (sel.state == "move_idle" and #(sel.orders or {}) == 0) then
        disabled[#disabled + 1] = W .. "/box1/fleet_orders/header/stop"
    end
    if sel then
        local damaged = false
        for _, s in ipairs(sel.ships) do
            damaged = damaged or s.hp < s.hp_max or s.armor < s.armor_max or s.shield < s.shield_max
        end
        if (sel.template_ships or 0) <= #sel.ships then
            disabled[#disabled + 1] = W .. "/box2/box2_3/fleet_info/actions/reinforce"
        end
        if not damaged then
            disabled[#disabled + 1] = W .. "/box2/box2_3/fleet_info/actions/repair"
        end
        if not sel.upgradable then
            disabled[#disabled + 1] = W .. "/box2/box2_3/fleet_info/actions/upgrade"
        end
    end
    for _, p in ipairs(disabled) do
        for i = from, #ctx.items do
            local it = ctx.items[i]
            if not ctx.plain and it.kind == "sprite" and it.path == p and it.texture:sub(1, 1) ~= "@" then
                it.texture = "@grey:" .. it.texture
                if it.button then
                    it.button.action = nil
                end
            end
        end
    end
    local box1 = wr.rects[W .. "/box1"]
    if sel and box1 then
        local s = ctx.db.sprites.GFX_fleet_manager_fleet_bg_horizontal
        local tw, th
        if s and s.texture then
            tw, th = ctx.texture_size(s.texture)
        end
        if tw and th then
            -- drawn under the fleet's name: before the items laid out after the window's background
            table.insert(ctx.items, from + 1, {
                kind = "sprite", path = W .. "/box1/planet_view_bg", sprite = "GFX_fleet_manager_fleet_bg_horizontal",
                texture = s.texture, sprite_kind = s.kind, frame = 1, frames = s.frames or 1,
                x = box1.x + 317, y = box1.y + 103, w = tw / math.max(1, s.frames or 1), h = th,
            })
        end
    end
    -- the fleets' list (the templates' rows)
    local tg = wr.rects[W .. "/box1/templates/templates_grid"]
    if tg then
        for i, f in ipairs(d.fleets) do
            local rp = W .. "/templates/" .. i
            local ep = rp .. "/fleet_manager_fleet_template_entity"
            layout(ctx, MANAGER_GUI, "fleet_manager_fleet_template_entity", {
                prefix = rp,
                parent = { x = tg.x, y = tg.y + (i - 1) * 42, w = 0, h = 0 },
                hide = { selected_overlay = f.id ~= d.selected },
                text = {
                    [ep .. "/fleet_name"] = name_text(loc, f.name),
                    [ep .. "/fleet_size"] = (template_count(loc, ctx.game_dir, f)),
                    [ep .. "/offensive_power"] = loc_text(loc, "MILITARY_POWER_YELLOW", { VALUE = fleet.si_number(f.military_power) }),
                },
                actions = { [ep] = d.view and ("view_set:fleet=" .. f.id) or ("fleet:manager_fleet:" .. f.id) },
            })
        end
    end
    if sel then
        -- the leader
        local lc = wr.rects[W .. "/box1/fleet_orders/leader_portrait_container"]
        if lc and sel.leader then
            paragon(ctx, sel.leader, { x = lc.x, y = lc.y, w = lc.w, h = lc.h }, W .. "/leader")
        end
        -- the command limit's bar: the size over the limit, in %
        local used = 0
        for _, s in ipairs(sel.ships) do
            used = used + ((sizes[s.size] or {}).size_multiplier or 1)
        end
        bar(ctx, W .. "/box2/box2_3/fleet_info/command_limit/progress", 100 * (sel.template_size or used) / (sel.command_limit or 50))
        -- the composition: per ship size of the template, the fleet's ships over the template's,
        -- centred in its grid
        local cg = wr.rects[W .. "/box2/box2_3/fleet_info/fleet_composition/fleet_composition_grid"]
        local groups, order = {}, {}
        for _, e in ipairs(sel.template_designs or {}) do
            local g = groups[e.size]
            if not g then
                g = { size = e.size, template = 0, fleet = 0 }
                groups[e.size] = g
                order[#order + 1] = g
            end
            g.template = g.template + e.count
        end
        for _, s in ipairs(sel.ships) do
            if groups[s.size] then
                groups[s.size].fleet = groups[s.size].fleet + 1
            end
        end
        table.sort(order, function(a, b)
            return ((sizes[a.size] or {}).size_multiplier or 0) < ((sizes[b.size] or {}).size_multiplier or 0)
        end)
        if cg then
            local x0 = cg.x + (cg.w - #order * 83) / 2
            for i, g in ipairs(order) do
                local p = W .. "/composition/" .. i
                local ep = p .. "/fleet_manager_fleet_composition_entity"
                local z = sizes[g.size] or {}
                layout(ctx, MANAGER_GUI, "fleet_manager_fleet_composition_entity", {
                    prefix = p,
                    parent = { x = x0 + (i - 1) * 83, y = cg.y, w = 0, h = 0 },
                    sprites = z.icon and { [ep .. "/icon"] = "GFX_" .. z.icon } or nil,
                    text = { [ep .. "/template_count"] = loc_text(loc, "VALUE_OUT_OF_MAX", { VALUE = "§W" .. g.fleet .. "§!", MAX = "§W" .. g.template .. "§!" }) },
                })
            end
        end
        -- the Ships rows: the template's designs by size, then name [V]
        local dg = wr.rects[W .. "/box2/box2_3/designs/designs_grid"]
        local rows = {}
        for _, e in ipairs(sel.template_designs or {}) do
            rows[#rows + 1] = e
        end
        table.sort(rows, function(a, b)
            local za, zb = (sizes[a.size] or {}).size_multiplier or 0, (sizes[b.size] or {}).size_multiplier or 0
            if za ~= zb then
                return za < zb
            end
            return name_text(loc, a.name) < name_text(loc, b.name)
        end)
        if dg then
            for i, e in ipairs(rows) do
                local p = W .. "/designs/" .. i
                local ep = p .. "/fleet_manager_current_template_ship_design_entity"
                local z = sizes[e.size] or {}
                -- the ships of the slot (its design, or upgrading to it) and those already of it
                local F, E = 0, 0
                for _, s in ipairs(sel.ships) do
                    if s.design == e.design or s.upgrade_to == e.design then
                        F = F + 1
                    end
                    if s.design == e.design then
                        E = E + 1
                    end
                end
                local count
                if E >= e.count then
                    count = loc_text(loc, "FLEET_MANAGER_SHIP_DESIGN_COUNT_FULL", { TEMPLATE_COUNT = e.count })
                elseif E < F then
                    count = loc_text(loc, "FLEET_MANAGER_SHIP_DESIGN_UPGRADABLE_COUNT", { FLEET_COUNT = F, TEMPLATE_COUNT = e.count })
                else
                    count = loc_text(loc, "FLEET_MANAGER_SHIP_DESIGN_COUNT", { FLEET_COUNT = F, TEMPLATE_COUNT = e.count })
                end
                local from_row = #ctx.items + 1
                layout(ctx, MANAGER_GUI, "fleet_manager_current_template_ship_design_entity", {
                    prefix = p,
                    parent = { x = dg.x, y = dg.y + (i - 1) * 42, w = 0, h = 0 },
                    hide = { selected_overlay = true, auto_gen = not e.auto_design },
                    sprites = z.icon and { [ep .. "/icon"] = "GFX_" .. z.icon } or nil,
                    text = {
                        [ep .. "/size"] = loc_text(loc, e.size),
                        [ep .. "/name"] = loc_text(loc, "BUILDABLE_SHIP_NAME", { TYPE = name_text(loc, e.name) }),
                        [ep .. "/ship_count"] = count,
                        -- the fleet's strength (the designs' own, CalcMilitaryPower, not computed
                        -- here: the fleet's whole [I])
                        [ep .. "/offensive_power"] = loc_text(loc, "FLEET_MANAGER_SHIP_OFFENSIVE_POWER_FULL", { TEMPLATE_POWER = fleet.si_number(sel.military_power) }),
                    },
                    -- the template's count +-1 (fleet_commands.template), the design in the
                    -- designer; retrofit and the row's disband not done here
                    actions = {
                        [ep .. "/increase_button"] = "fleet:tpl:" .. sel.id .. ":" .. tostring(e.design) .. ":1",
                        [ep .. "/decrease_button"] = "fleet:tpl:" .. sel.id .. ":" .. tostring(e.design) .. ":-1",
                        [ep .. "/inspect"] = "fleet:designer:" .. tostring(e.design),
                        [ep .. "/retrofit"] = "fleet:do:" .. sel.id .. ":retrofit",
                        [ep .. "/disband"] = "fleet:do:" .. sel.id .. ":row_disband",
                    },
                })
                if e.count <= F then
                    grey(ctx, from_row, ep .. "/decrease_button")
                end
            end
        end
    end
    -- the side panel: the Build Queue (CFleetManagerSideView's default mode), empty; only when
    -- opened on a fleet's template (not from the left bar: the game's frames) [I]
    local win = wr.rects[W]
    if win and d.side then
        layout(ctx, MANAGER_GUI, "fleet_manager_side_view", {
            parent = { x = win.x, y = win.y, w = win.w, h = win.h },
            hide = { available_window = true, retrofit_window = true },
        })
    end
end

---------------------------------------------------------------- the order selector, its popup

-- a right click's menu and Yes/No popup (render.windows.fleet_rightclick; fleetwin.rs keeps
-- them): CMainGui's order_selector (main.gui) with an order_window per entry, and popup.gui's
-- yes_no_popup_window (docs/windows/fleet.md "Right click")
local MAIN_GUI = "interface/main.gui"
local POPUP_GUI = "interface/popup.gui"

-- a cost: its resources as icon and amount, in the resources' order (common/strategic_resources:
-- influence before alloys) [V: the game's frame "(£influence£60 £alloys£90)"]
local RESOURCE_ORDER = { "energy", "minerals", "food", "physics_research", "society_research", "engineering_research",
                         "influence", "unity", "consumer_goods", "alloys" }
local function cost_text(cost)
    local rank = {}
    for i, k in ipairs(RESOURCE_ORDER) do
        rank[k] = i
    end
    local keys = {}
    for k in pairs(cost or {}) do
        keys[#keys + 1] = k
    end
    table.sort(keys, function(a, b)
        local ra, rb = rank[a] or 99, rank[b] or 99
        if ra ~= rb then return ra < rb end
        return a < b
    end)
    local parts = {}
    for _, k in ipairs(keys) do
        local v = tonumber(cost[k]) or 0
        parts[#parts + 1] = "£" .. k .. "£" .. (v % 1 == 0 and string.format("%d", v) or string.format("%.1f", v))
    end
    return table.concat(parts, " ")
end

-- an entry's label: its key with its names and values, " (cost)" after a station's; the fail
-- prefix (TRIGGER_FAIL, CreateTriggerPassFailText(false)) on one not possible [V]
local function order_label(loc, e)
    -- (a value may be a key of its own with its names: the home base's "$PLANET$ Station")
    local t = line_text(loc, e)
    if e.cost and next(e.cost) then
        -- (the brackets and amounts in the label's highlight colour [V: the game's frame])
        t = t .. " §H(" .. cost_text(e.cost) .. ")§!"
    end
    if e.possible == false then
        t = loc_text(loc, "TRIGGER_FAIL") .. t
    end
    return t
end

-- ShowOrderSelector (0x2f3a5c0) [V]: at the cursor, pushed back inside the screen's right and
-- bottom edges (none at the left and top); the list's height its entries' (28 each). The game's
-- frames [V, 2210.01.01]: the window 380 x 62 at the cursor (one entry), the list 25 below its
-- top (the gui), the entry's button (452 wide from x -25) cut to the window
function fleet.order_menu(ctx, m)
    local entries = type(m) == "table" and m.menu or nil
    if type(entries) ~= "table" or #entries == 0 then
        return
    end
    local W = "/order_selector"
    local w, h = 380, 25 + #entries * 28 + 9
    local at = m.at or { 0, 0 }
    local x = math.min(tonumber(at[1]) or 0, ctx.screen.width - w)
    local y = math.min(tonumber(at[2]) or 0, ctx.screen.height - h)
    layout(ctx, MAIN_GUI, "order_selector", {
        parent = { x = x, y = y, w = 0, h = 0 },
        sizes = { [W] = { w, h }, [W .. "/orders"] = { 253, #entries * 28 } },
        text = { [W .. "/label"] = loc_text(ctx.loc, "ORDERS") },
    })
    for i, e in ipairs(entries) do
        local p = W .. "/entry/" .. i
        local ep = p .. "/order_window"
        local from = #ctx.items + 1
        layout(ctx, MAIN_GUI, "order_window", {
            prefix = p,
            parent = { x = x + 10, y = y + 25 + (i - 1) * 28, w = 0, h = 0 },
            text = { [ep .. "/text"] = order_label(ctx.loc, e) },
            actions = { [ep .. "/background"] = "fleet:menu:" .. i },
        })
        if e.possible == false then
            grey(ctx, from, ep .. "/background")
        end
        -- the button cut to the window (its part from x to x + w drawn: the item's clip)
        for j = from, #ctx.items do
            local it = ctx.items[j]
            if it.kind == "sprite" and it.path == ep .. "/background" and (it.w or 0) > 0 then
                local a = math.max(0, (x - it.x) / it.w)
                local b = math.min(1, (x + w - it.x) / it.w)
                if a > 0 or b < 1 then
                    it.clip = { a, b }
                end
            end
        end
    end
end

-- the Yes/No popup (yes_no_popup_window: centred; AgreeButton yes, DeclineButton no)
function fleet.order_popup(ctx, p)
    if type(p) ~= "table" then
        return
    end
    local W = "/yes_no_popup_window"
    layout(ctx, POPUP_GUI, "yes_no_popup_window", {
        text = { [W .. "/title"] = loc_text(ctx.loc, p.title or ""), [W .. "/description"] = loc_text(ctx.loc, p.desc or "") },
        actions = { [W .. "/AgreeButton"] = "fleet:popup_yes", [W .. "/DeclineButton"] = "fleet:popup_no" },
    })
end

---------------------------------------------------------------- the windows

-- fleet.build(game_dir, db, screen, texture_size, loc, data) -> items, report
function fleet.build(game_dir, db, screen, texture_size, loc, data)
    local ctx = {
        game_dir = game_dir, db = db, screen = screen, texture_size = texture_size, loc = loc, plain = data.plain, armed = data.armed,
        items = {}, report = { sprites = 0, texts = 0, missing_sprites = {}, skipped = {}, rects = {} },
    }
    if data.fleet then
        fleet.fleet_view(ctx, data.fleet)
    end
    if data.manager then
        fleet.manager_view(ctx, data.manager)
    end
    if data.ship then
        fleet.ship_view(ctx, data.ship)
    end
    -- a right click's menu, then its popup, over the windows
    if data.order_menu then
        fleet.order_menu(ctx, data.order_menu)
    end
    if data.order_popup then
        fleet.order_popup(ctx, data.order_popup)
    end
    return ctx.items, ctx.report
end

return fleet
