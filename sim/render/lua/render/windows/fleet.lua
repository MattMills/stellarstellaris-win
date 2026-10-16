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
    local out = {}
    for name, d in pairs(source.definitions(game_dir, "common/traits")) do
        out[name] = { icon = get(d.block, "icon") }
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
    for i = from, #ctx.items do
        local it = ctx.items[i]
        if it.kind == "sprite" and it.path:sub(1, #prefix) == prefix and it.texture:sub(1, 1) ~= "@" then
            it.texture = "@grey:" .. it.texture
            if it.button then
                it.button.action = nil
            end
        end
    end
end

-- a progress bar sprite (progressbarType) at `value` 0..100: its texture made of the full and
-- empty textures (progress.shader: texture one where the bar's coordinate <= the state)
local function bar(ctx, path, value)
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

-- a grid of buttons (fleet_view_order_button / fleet_view_action_button windows) in the slots of
-- the gridbox at `rect`: { sprite, action, disabled } each; `right`: UPPER_RIGHT (the first at
-- the right, going left), `per_row`: max_slots_horizontal
local function button_grid(ctx, window, rect, slot_w, slot_h, buttons, prefix, right, per_row)
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
        layout(ctx, FLEET_GUI, window, {
            prefix = p,
            parent = { x = x, y = y, w = 0, h = 0 },
            sprites = { [p .. "/" .. window .. "/button"] = b.sprite },
            actions = { [p .. "/" .. window .. "/button"] = b.action or ("fleet:order:" .. tostring(b.name or b.sprite)) },
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
local function header_orders(d)
    if not d.player then
        return {}
    end
    return {
        { name = "merge", sprite = "GFX_fleet_order_button_merge", disabled = true },
        { name = "stop", sprite = "GFX_fleet_order_button_stop", disabled = d.state == "move_idle" },
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
            council and "" or "council_container",
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
        for i, t in ipairs(leader.traits or {}) do
            local def = tdefs[t]
            local s = def and def.icon and ctx.db.sprites[def.icon]
            if s and s.texture then
                local tw, th = ctx.texture_size(s.texture)
                if tw then
                    local h = box.h
                    local sw = tw / math.max(1, s.frames) * h / th
                    ctx.items[#ctx.items + 1] = {
                        kind = "sprite", path = lp .. "/traits/" .. i, sprite = def.icon, texture = s.texture,
                        sprite_kind = s.kind, frame = 1, frames = s.frames, x = x, y = box.y, w = sw, h = h,
                    }
                    x = x + sw + 2
                end
            end
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
        return loc_text(loc, "NO_COMMUNICATIONS_VESSEL"), ""
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
        button_grid(ctx, "fleet_view_order_button", grid, 34, 30, header_orders(d), "/fleet_view/header_orders", false)
    end

    local p = "/fleet_view/fleets/fleet_view_entry"
    local cls = fleet.CLASS[d.class]
    local name = name_text(loc, d.name)
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
    local orders_text = d.orders_text or loc_text(loc, "NO_ORDERS")
    local text = {
        [p .. "/top/fleet_name"] = name,
        [p .. "/top/fleet_type"] = d.communications and type_name or "",
        [p .. "/top/unknown_faction_name"] = d.communications and "" or loc_text(loc, "YELLOW_COLOR", { KEY = name_text(loc, d.owner_name) }),
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
    local _, er = layout(ctx, FLEET_GUI, "fleet_view_entry", {
        prefix = "/fleet_view/fleets",
        parent = { x = list.x, y = list.y, w = 510, h = entry_h },
        sizes = { [p] = { 510, entry_h } },
        only = only, hide = hide, text = text,
        frames = { [p .. "/top/icon"] = d.communications and fleet.CLASS_ICON_FRAME[cls or 0] or 11 },
        sprites = { [p .. "/top/header_button"] = header_sprite(d), [p .. "/top/disband"] = disband },
        actions = {
            [p .. "/top/deselect"] = "close",
            [p .. "/top/open_fleet_manager"] = "fleet:manager",
        },
    })
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
            button_grid(ctx, "fleet_view_order_button", g, sl[1], sl[2], fleet_orders(d), "/fleet_view/orders", false, sl[3])
        end
    end
    local ag = er.rects[p .. "/bottom/actions"]
    if ag and d.communications then
        button_grid(ctx, "fleet_view_action_button", ag, 34, 34, fleet_actions(d), "/fleet_view/actions", true)
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
                upgradable = upgradable or s.upgradable
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
            actions = { [sp .. "/inspect"] = "fleet:ship:" .. s.id },
        })
        -- the two lines of the name box (44 high, centred): the second under the first, laid out
        -- as the same element again [I: the renderer draws one line a text]
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
        bar(ctx, sp .. "/health", 100 * fraction(s.hp, s.hp_max))
        bar(ctx, sp .. "/armor", 100 * fraction(s.armor, s.armor_max))
        bar(ctx, sp .. "/shields", 100 * fraction(s.shield, s.shield_max))
        y = y + ROW_H + SPACING
    end
end

---------------------------------------------------------------- ship_view

-- common/component_templates: key -> { icon, icon_frame, size, component_set, class }
function fleet.components(game_dir)
    if cache.components then
        return cache.components
    end
    local out = {}
    for _, file in ipairs(source.files(game_dir, "common/component_templates", "txt")) do
        local tree = source.parse(game_dir, file)
        for _, e in ipairs(tree or {}) do
            if e.op and e.key and type(e.value) == "table" and e.value.text == nil then
                local b = e.value
                local key = get(b, "key")
                if key then
                    out[key:gsub('"', "")] = {
                        kind = e.key.text, icon = get(b, "icon"), icon_frame = tonumber(get(b, "icon_frame")),
                        size = get(b, "size"), component_set = get(b, "component_set"), tier = get(b, "tier"),
                    }
                end
            end
        end
    end
    cache.components = out
    return out
end

function fleet.ship_view(ctx, d)
    local loc = ctx.loc
    local sizes = fleet.ship_sizes(ctx.game_dir)
    local z = sizes[d.size] or {}
    local text = {
        ["/ship_view/name"] = name_text(loc, d.name),
        ["/ship_view/type"] = d.type_text or "",
        ["/ship_view/stats/hitpoints_value"] = d.stats and d.stats.hitpoints or tostring(math.floor(d.hp + 0.5)),
        ["/ship_view/stats/armor_value"] = d.stats and d.stats.armor or tostring(math.floor(d.armor + 0.5)),
        ["/ship_view/stats/shields_value"] = d.stats and d.stats.shields or tostring(math.floor(d.shield + 0.5)),
        ["/ship_view/stats/speed_value"] = d.stats and d.stats.speed or tostring(z.max_speed or ""),
        ["/ship_view/stats/evasion_value"] = d.stats and d.stats.evasion or "",
        ["/ship_view/stats/damage_value"] = d.stats and d.stats.damage or "",
        ["/ship_view/stats/rank_value"] = d.stats and d.stats.rank or "",
    }
    local _, wr = layout(ctx, SHIP_GUI, "ship_view", {
        hide = set({ "cloaking", "cloaking_level", "growth", "rename_button" }),
        text = text,
        actions = {
            ["/ship_view/close"] = "fleet:close_ship",
            ["/ship_view/buttons/open_fleet_manager"] = "fleet:manager",
        },
    })
    return wr
end

---------------------------------------------------------------- fleet_manager_view

function fleet.manager_view(ctx, d)
    layout(ctx, MANAGER_GUI, "fleet_manager_view", {
        actions = { ["/fleet_manager_view/close"] = "fleet:close_manager" },
    })
end

---------------------------------------------------------------- the windows

-- fleet.build(game_dir, db, screen, texture_size, loc, data) -> items, report
function fleet.build(game_dir, db, screen, texture_size, loc, data)
    local ctx = {
        game_dir = game_dir, db = db, screen = screen, texture_size = texture_size, loc = loc,
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
    return ctx.items, ctx.report
end

return fleet
