-- render/windows/starbase.lua : the starbase window (interface/starbase_view.gui `starbase_view`,
-- CStarbaseView and its tab controllers; docs/windows/starbase.md), laid out with render.gui over
-- the values render.windows.starbase_data reads from the world.
--
--   local starbase = require("render.windows.starbase")
--   starbase.build(ctx, sel, items, report)   -- sel = { kind = "starbase", id = <station fleet> }
--
-- Globals set by the renderer (sim/render/src/starbase.rs) before the windows are laid out:
--   RENDER_STARBASE_DATA   the chunk of starbase_data.extract (Galaxy::starbases)
--   RENDER_STARBASE_STATE  { tab = 0..3, player = <country id> }
--
-- Clicks carry `starbase:tab:N`, `starbase:prev`, `starbase:next`, `starbase:goto`,
-- `starbase:planet` and `close` (render's App::act, starbase.rs).

local gui = require("render.gui")
local names = require("render.names")

local M = {}

local FILE = "interface/starbase_view.gui"
local W = "/starbase_view"

-- a disabled button: greyed out as buttonstate_onlydisable.shader's Disable effect does (a
-- negative alpha: the renderer's greyed quad, GreyOutLuminosity); its label greyed the same way,
-- white to 0.75: textcolor t (198) the nearest [I]
local DISABLED = { 1, 1, 1, -1 }
local function grey_label(text)
    return "\194\167t" .. text .. "\194\167!"
end

-- CStarbaseView's tabs (SetupSpecialized: AddTab 0..3) and their containers
M.TABS = {
    [0] = { button = "starbase_tab", window = "starbase_tab" },
    [1] = { button = "defenses_tab", window = "defenses_tab" },
    [2] = { button = "shipyard_tab", window = "ship_build_queue_tab" },
    [3] = { button = "macro_builder_tab", window = "macro_builder_tab" },
}

local parsed = { chunk = nil, data = nil }

-- the starbases' data from the chunk (parsed once per chunk)
function M.data()
    local chunk = RENDER_STARBASE_DATA
    if type(chunk) ~= "string" or chunk == "" then
        return nil
    end
    if parsed.chunk ~= chunk then
        local f = loadstring and loadstring(chunk) or load(chunk)
        local ok, t = pcall(f)
        parsed.chunk, parsed.data = chunk, ok and t or nil
    end
    return parsed.data
end

-- a localisation key's text with the game's variables filled in: `$NAME$`, `$NAME|Y$` (the value
-- in that colour); then the localisation's own references resolved (a variable wins over a key
-- of the same name: STARBASE_NAME's $NAME$ is the name, not the key NAME)
local function fmt(loc, key, vars)
    local text = loc and loc.raw(key) or key
    text = text:gsub("%$([%w_]+)|?([^$]*)%$", function(k, f)
        local v = vars and vars[k]
        if v == nil then
            return nil
        end
        v = tostring(v)
        local colour = f:match("^%a$")
        if colour then
            return "\194\167" .. colour .. v .. "\194\167!"
        end
        return v
    end)
    return loc and loc.resolve(text) or text
end
M.fmt = fmt

local function set(list)
    local s = {}
    for _, n in ipairs(list) do
        s[n] = true
    end
    return s
end

-- the game's remaining days of a queue item [I]: (needed - progress) a day at a time
-- GFX_ship_class_small's frame for a fleet: matched to the game's frame by pixels (CFleet::GetIconFrame,
-- 0x294a080, not read through): military 3, construction 2, science 1; a colony ship 6 [I]
local CLASS_FRAME = { constructor = 2, science = 1, colonizer = 6 }

local function days_left(q)
    return math.max(0, math.ceil((q.needed or 0) - (q.progress or 0)))
end

-- a starbase's tab: whether it can be shown (CStarbaseShipsTabController::IsEnabled:
-- IsShipyard or IsHatchery; CStarbaseMacroBuilderTabController::IsEnabled: its system in a sector
-- and more, not read [I])
function M.tab_enabled(e, tab)
    if tab == 2 then
        return e.shipyard or e.hatchery or e.beastport or false
    elseif tab == 3 then
        return e.has_sector or false
    end
    return true
end

-- the tab shown: the one chosen, or Command when it cannot be (UpdateSpecialized:
-- ShowTabView<0> when the shipyard tab is not enabled)
function M.current_tab(e, state)
    local tab = tonumber(state and state.tab) or 0
    if not M.TABS[tab] or not M.tab_enabled(e, tab) then
        tab = 0
    end
    return tab
end

-- a list's entries (a smoothListBoxType: one under the other, `spacing` apart, as many as fit)
local function list_entries(ctx, items, report, rect, spacing, entry_h, entries, layout_one)
    if not rect then
        return
    end
    local y = rect.y
    for i, ent in ipairs(entries) do
        if y + entry_h > rect.y + rect.h + 0.5 then
            break
        end
        local ri, rr = layout_one(i, ent, { x = rect.x, y = y, w = rect.w, h = entry_h })
        gui.merge(items, report, ri, rr)
        y = y + entry_h + spacing
    end
end

-- the grid of a starbase's modules or buildings (CStarbaseComponentGridController::UpdateCustom:
-- the level's slots, GetMaxModuleCapacity / GetMaxBuildingCapacity, each a
-- starbase_view_current_component_grid_entry; CStarbaseComponentGridEntry::UpdateWithData: a
-- component's icon; an empty slot unlocked below the station's capacity (CStarbase +0x14e0, its
-- starbase_module_capacity_add), locked from it on; the green overlay only on the slot chosen)
local function component_grid(ctx, items, report, grid, slot, slots, capacity, parts, queue, prefix, kind)
    if not grid or slots <= 0 then
        return
    end
    local by_slot = {}
    for _, p in ipairs(parts) do
        by_slot[p.slot] = p
    end
    for i = 1, slots do
        local col, row = (i - 1) % 3, math.floor((i - 1) / 3)
        local p = by_slot[i]
        local rp = prefix .. "/" .. i
        local path = rp .. "/starbase_view_current_component_grid_entry"
        local hide = { [path .. "/planet_view_module_spaceport_buildqueue_entry_overlay"] = true, progressbar = true }
        local sprites, frames = {}, {}
        if p then
            hide.locked, hide.unlocked = true, true
            sprites[path .. "/icon"] = p.icon
            frames[path .. "/icon"] = p.frame
        else
            hide.icon = true
            if i <= capacity then
                hide.locked = true
            else
                hide.unlocked = true
            end
        end
        local ri, rr = gui.layout(ctx.game_dir, ctx.db, FILE, "starbase_view_current_component_grid_entry", ctx.screen, {
            texture_size = ctx.texture_size, loc = ctx.loc, prefix = rp,
            parent = { x = grid.x + col * slot, y = grid.y + row * slot, w = 0, h = 0 },
            hide = hide, sprites = sprites, frames = frames,
            actions = { [path] = "starbase:slot:" .. kind .. ":" .. i },
        })
        gui.merge(items, report, ri, rr)
    end
end

-- a progress bar as the game draws a progressbarType: its empty texture under the whole bar, its
-- full texture over the part done (stretched to it [I]: the game crops it)
local function progress_items(ctx, items, report, sprite, rect, fraction)
    local s = ctx.db.sprites[sprite]
    if not s or not rect then
        return
    end
    if s.texture2 then
        items[#items + 1] = { kind = "sprite", path = rect.path .. "/empty", sprite = sprite, texture = s.texture2, sprite_kind = "spriteType",
            frame = 1, frames = 1, x = rect.x, y = rect.y, w = rect.w, h = rect.h }
        report.sprites = report.sprites + 1
    end
    local f = math.max(0, math.min(1, fraction or 0))
    if f > 0 then
        items[#items + 1] = { kind = "sprite", path = rect.path, sprite = sprite, texture = s.texture, sprite_kind = "spriteType",
            frame = 1, frames = 1, x = rect.x, y = rect.y, w = rect.w * f, h = rect.h }
        report.sprites = report.sprites + 1
    end
end

-- a queue item's icon frame, title and name (NConstruction::ApplyConstructionItemToButton:
-- GFX_ship_class_small at the buildable's GetBuildIconFrame; its GetGuiTitle, GetGuiName):
-- a starbase upgrade the starbase class's frame 8 (GetShipClassIconFrameFromSize; matched to the
-- game's frame), "Upgrade" (STARBASE_UPGRADE), "Upgrade to <level>" (STARBASE_UPGRADE_NAMED);
-- a module or building frame 22 and its name; a ship its size's class frame, its design's name
-- (BUILDABLE_SHIP_NAME) and its size (BUILD_SHIP) [I]
local function queue_texts(loc, e, q)
    local function L(k)
        return loc and (loc.get(k)) or k
    end
    if q.kind == "starbase_upgrade" then
        local nl = q.next_size or e.next_size
        return 8, L("STARBASE_UPGRADE"), fmt(loc, "STARBASE_UPGRADE_NAMED", { LEVEL = nl and L(nl) or "" })
    elseif q.kind == "starbase_module" then
        return 22, L("sm_" .. tostring(q.key)), ""
    elseif q.kind == "starbase_building" then
        return 22, L("sb_" .. tostring(q.key)), ""
    elseif q.kind == "ship" then
        local design = q.design and names.format(loc, q.design) or ""
        return CLASS_FRAME[q.key or ""] or 3, fmt(loc, "BUILDABLE_SHIP_NAME", { TYPE = design }), fmt(loc, "BUILD_SHIP", { NAME = L(q.key or "") })
    end
    return 1, L(tostring(q.key or "")), ""
end

-- a build queue's entries (CConstructionQueueListItem: starbase_view_build_queue_list_entry, its
-- icon, title and name, the time while it is built (BUILD_TIME_REMAINING "£time£ $DAYS$", the days
-- CalcDaysLeft gives: what is left at one a day [I]) or its place behind (QUEUED_NUMBER), the
-- progress bar; its priority buttons enabled when the commands are valid: up from the second, down
-- before the last, for its own)
local function queue_list(ctx, items, report, rect, queue, prefix, e, own)
    list_entries(ctx, items, report, rect, 3, 52, queue, function(i, q, r)
        local rp = prefix .. "/" .. i
        local path = rp .. "/starbase_view_build_queue_list_entry"
        local frame, title, sub = queue_texts(ctx.loc, e, q)
        local tints = {}
        if not own or i == 1 then
            tints[path .. "/priority_upwards"] = DISABLED
        end
        if not own or i == #queue then
            tints[path .. "/priority_downwards"] = DISABLED
        end
        local ri, rr = gui.layout(ctx.game_dir, ctx.db, FILE, "starbase_view_build_queue_list_entry", ctx.screen, {
            texture_size = ctx.texture_size, loc = ctx.loc, prefix = rp, parent = r,
            hide = { progressbar = true },
            frames = { [path .. "/icon"] = frame },
            tints = tints,
            text = {
                [path .. "/title"] = title,
                [path .. "/time"] = i == 1 and fmt(ctx.loc, "BUILD_TIME_REMAINING", { DAYS = days_left(q) }) or fmt(ctx.loc, "QUEUED_NUMBER", { NUMBER = i - 1 }),
                [path .. "/name"] = sub,
            },
        })
        -- the progress bar where the .gui puts it (iconType progressbar at 1, 35)
        local bar = { path = path .. "/progressbar", x = r.x + 1, y = r.y + 35, w = 210, h = 14 }
        local s = ctx.db.sprites.GFX_queue_progressbar
        if s and s.size then
            bar.w, bar.h = s.size[1], s.size[2]
        end
        progress_items(ctx, ri, rr, "GFX_queue_progressbar", bar, (q.needed or 0) > 0 and (q.progress or 0) / q.needed or 0)
        return ri, rr
    end)
end


-- the fleets in orbit (CFleetOrbitalListController: a starbase_view_fleet_list_entry each, its
-- class icon, its health bar, its name; `repairing` while it repairs, not read [I])
local function fleet_list(ctx, items, report, rect, fleets, prefix)
    list_entries(ctx, items, report, rect, 3, 52, fleets, function(i, f, r)
        local rp = prefix .. "/" .. i
        local path = rp .. "/starbase_view_fleet_list_entry"
        return gui.layout(ctx.game_dir, ctx.db, FILE, "starbase_view_fleet_list_entry", ctx.screen, {
            texture_size = ctx.texture_size, loc = ctx.loc, prefix = rp, parent = r,
            hide = { repairing = true },
            frames = { [path .. "/fleet_type"] = f.military and 3 or CLASS_FRAME[f.size or ""] or 3 },
            text = { [path .. "/name"] = names.format(ctx.loc, f.name) },
            actions = { [path] = "select:fleet:" .. f.id },
        })
    end)
end

-- a modifier's icon (CModifier::InitDefinitionIcons: GFX_mod_<type>, from
-- gfx/interface/icons/modifiers/mod_<type>.dds when no .gfx defines it)
local function modifier_sprite(ctx, mtype)
    local name = "GFX_mod_" .. mtype
    if not ctx.db.sprites[name] then
        local tex = "gfx/interface/icons/modifiers/mod_" .. mtype .. ".dds"
        if ctx.texture_size(tex) then
            ctx.db.sprites[name] = { texture = tex, frames = 1, kind = "spriteType" }
        else
            return "GFX_mod_unknown"
        end
    end
    return name
end

-- a modifier's value as CModifier::GetValueText writes a percentage [I]: its sign, green when
-- good, red when bad, yellow at 0
local function percent(v, good_negative)
    local n = math.floor(v * 100 + 0.5)
    local colour = n == 0 and "Y" or ((n > 0) ~= (good_negative == true)) and "G" or "R"
    return "\194\167" .. colour .. (n >= 0 and "+" or "") .. n .. "%\194\167!"
end

-- the shipyard's modifier grid (CShipyardModifierGridController::GetModifiersToDisplay: 285
-- starbase_shipyard_build_cost_mult, 283 _build_speed_mult, 284 _build_time_mult; a
-- starbase_view_modifier_grid_entry each, 82 x 30 slots, three a row)
local function modifier_grid(ctx, items, report, grid, mods, prefix)
    if not grid then
        return
    end
    for i, m in ipairs(mods) do
        local col, row = (i - 1) % 3, math.floor((i - 1) / 3)
        local rp = prefix .. "/" .. i
        local path = rp .. "/starbase_view_modifier_grid_entry"
        local ri, rr = gui.layout(ctx.game_dir, ctx.db, FILE, "starbase_view_modifier_grid_entry", ctx.screen, {
            texture_size = ctx.texture_size, loc = ctx.loc, prefix = rp,
            parent = { x = grid.x + col * 82, y = grid.y + row * 30, w = 0, h = 0 },
            sprites = { [path .. "/icon"] = modifier_sprite(ctx, m.type) },
            text = { [path .. "/amount"] = percent(m.value or 0, m.good_negative) },
        })
        gui.merge(items, report, ri, rr)
    end
end

-- the owner's starbase before or after a starbase (by starbase id, in turn) [I]: the order of
-- OnPrevStarbaseClick / OnNextStarbaseClick is not read -> { fleet }
function M.neighbour(fleet, dir)
    local data = M.data()
    local e = data and data.starbases[fleet]
    if not e then
        return {}
    end
    local list = {}
    for _, s in pairs(data.starbases) do
        if s.owner == e.owner and s.level ~= "starbase_level_outpost" then
            list[#list + 1] = s
        end
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    for i, s in ipairs(list) do
        if s.id == e.id then
            local n = list[(i - 1 + dir) % #list + 1]
            return { n.fleet }
        end
    end
    return {}
end

-- the station fleet of a starbase (its save id) -> { fleet } or {}
function M.fleet_of(id)
    local data = M.data()
    for fid, s in pairs(data and data.starbases or {}) do
        if s.id == id then
            return { fid }
        end
    end
    return {}
end

-- a disabled button's label: its text greyed out as the button (GreyOutLuminosity: the colour's
-- luminance x 0.85 + the colour x 0.15, x 0.75), in the textcolor nearest that grey [I]
function M.grey(ctx, text)
    local plain = ctx.loc and ctx.loc.plain(text) or text
    local code = text:match("^\194\167(%a)")
    local c = code and ctx.db.textcolors[code] or { 1, 1, 1 }
    local lum = 0.212671 * c[1] + 0.715160 * c[2] + 0.072169 * c[3]
    local g = { (lum * 0.85 + c[1] * 0.15) * 0.75, (lum * 0.85 + c[2] * 0.15) * 0.75, (lum * 0.85 + c[3] * 0.15) * 0.75 }
    local best, bd = "t", math.huge
    for k, v in pairs(ctx.db.textcolors) do
        local d = (v[1] - g[1]) ^ 2 + (v[2] - g[2]) ^ 2 + (v[3] - g[3]) ^ 2
        if #k == 1 and d < bd then
            best, bd = k, d
        end
    end
    return "\194\167" .. best .. plain .. "\194\167!"
end

-- the windows of this family that are not the selection's: a megastructure's (its id in
-- RENDER_STARBASE_STATE.megastructure; a selection replaces it, as selecting does in the game)
function M.extra(ctx, items, report)
    local state = RENDER_STARBASE_STATE or {}
    if state.megastructure and not state.selected then
        require("render.windows.megastructure").build(ctx, tonumber(state.megastructure), items, report)
    end
end

-- a starbase's values in one line (the command protocol's reply)
function M.summary(fleet)
    local data = M.data()
    local e = data and data.starbases[fleet]
    if not e then
        return "no data"
    end
    return string.format("%s owner %d, modules %d/%d of %d, buildings %d/%d of %d, sensor %d, hyperlane %d, platforms %d/%d, queue %d, upgrade %s",
        e.level, e.owner, #e.modules, e.module_capacity, e.module_slots, #e.buildings, e.building_capacity, e.building_slots,
        e.sensor, e.hyperlane, e.platforms, e.platform_capacity, #e.queue, tostring(e.upgrade_ok))
end

-- a starbase's system and the planet its planet button opens (-1: none) -> { system, planet }
function M.place(fleet)
    local data = M.data()
    local e = data and data.starbases[fleet]
    if not e then
        return {}
    end
    return { e.system or -1, e.planet or -1 }
end

-- the module and building grids at their gridboxes (for the waystation window too; a path nil:
-- that grid not drawn)
function M.grids(ctx, items, report, rects, e, modules_path, buildings_path)
    if modules_path then
        component_grid(ctx, items, report, rects[modules_path], 58, e.module_slots or 0, e.module_capacity or 0, e.modules or {}, e.queue, W .. "/modules", "module")
    end
    if buildings_path then
        component_grid(ctx, items, report, rects[buildings_path], 60, e.building_slots or 0, e.building_capacity or 0, e.buildings or {}, e.queue, W .. "/buildings", "building")
    end
end

-- the build queue's entries in a list's rectangle (for the waystation window too)
function M.queue(ctx, items, report, rect, e, own)
    queue_list(ctx, items, report, rect, e.queue or {}, W .. "/queue", e, own)
end

function M.build(ctx, sel, items, report)
    local data = M.data()
    local e = data and data.starbases and data.starbases[sel.id]
    -- a waystation's own window (CInGameIdler::ShowWaystationView: a starbase type is_waystation)
    if e and (e.waystation or (RENDER_STARBASE_STATE or {}).waystation) then
        return require("render.windows.waystation").build(ctx, sel, e, items, report)
    end
    local h = ctx.screen.height >= 801 and 765 or 611
    if not e then
        -- no data (the starbase not in the snapshot): the frame and its name
        local wi, wr = gui.layout(ctx.game_dir, ctx.db, FILE, "starbase_view", ctx.screen, {
            texture_size = ctx.texture_size, loc = ctx.loc,
            sizes = { [W] = { 562, h } },
            only = set({ "planet_bg_top", "background_window", "starbase_bg_bottom", "empire_header_line", "hex_bg", "name", "header_actions" }),
            text = { [W .. "/name"] = sel.name or "" },
            actions = { [W .. "/header_actions/close"] = "close" },
        })
        gui.merge(items, report, wi, wr)
        return
    end
    local state = RENDER_STARBASE_STATE or {}
    local loc = ctx.loc
    local player = tonumber(state.player) or -1
    local own = e.owner == player
    local tab = M.current_tab(e, state)

    local only = set({
        "planet_bg_top", "background_window", "starbase_bg_bottom", "planet_view_module_spaceport_portrait",
        "empire_header_line", "hex_bg", "name", "starbase_rename_button", "header_actions", "tabs",
    })
    only[M.TABS[tab].window] = true
    local hide, text, sprites, tints, actions = {}, {}, {}, {}, {}

    -- the header (CAbstractStarbaseView::Update: the name CShip::GetNameWithType, STARBASE_NAME with
    -- the station's name; Show: the level's picture on spaceport_portrait_portrait)
    text[W .. "/name"] = fmt(loc, "STARBASE_NAME", { NAME = names.format(loc, e.name) })
    sprites[W .. "/planet_view_module_spaceport_portrait/spaceport_portrait_portrait"] = e.picture
    -- the planet button: UpdateSpecialized shows it for a starbase over a planet it defends [I]:
    -- here, a system with a colony of its owner
    if not e.planet then
        hide[W .. "/header_actions/open_planet"] = true
    end
    hide[W .. "/header_actions/previous_starbase_extra_shortcut"] = true
    actions[W .. "/header_actions/close"] = "close"
    actions[W .. "/header_actions/previous_starbase"] = "starbase:prev"
    actions[W .. "/header_actions/next_starbase"] = "starbase:next"
    actions[W .. "/header_actions/goto"] = "starbase:goto"
    actions[W .. "/header_actions/open_planet"] = "starbase:planet"

    -- the tabs (CGameGraphics::UpdateTabVisibility: the chosen tab's _active button, the others'
    -- plain one; UpdateSpecialized enables the shipyard and army hub tabs; the shipyard tab reads
    -- STARBASE_HATCHERY_TAB / STARBASE_BEASTPORT_TAB for those starbases)
    for k, t in pairs(M.TABS) do
        local on = k == tab
        hide[W .. "/tabs/" .. t.button .. (on and "" or "_active")] = true
        local b = W .. "/tabs/" .. t.button .. (on and "_active" or "")
        actions[b] = "starbase:tab:" .. k
        local label
        if k == 2 then
            label = e.hatchery and "STARBASE_HATCHERY_TAB" or e.beastport and "STARBASE_BEASTPORT_TAB" or nil
        end
        if not M.tab_enabled(e, k) then
            tints[b] = DISABLED
            actions[b] = nil
            local key = label or ({ [0] = "STARBASE_STARBASE_TAB", "STARBASE_DEFENSES_TAB", "STARBASE_SHIPYARD_TAB", "MACRO_BUILDER_TAB" })[k]
            label = grey_label(loc and (loc.get(key)) or key)
        end
        if label then
            text[b] = label
        end
    end

    local tp = W .. "/" .. M.TABS[tab].window
    if tab == 0 then
        -- CStarbaseAbstractStarbaseTabController::Update, CStarbaseStarbaseTabController::Update
        text[tp .. "/class_info/current_class_name"] = loc and (loc.get(e.size)) or e.size
        text[tp .. "/upgrade_info/next_class_name"] = e.next_size and (loc and (loc.get(e.next_size)) or e.next_size) or ""
        -- the upgrade button: shown with a next level, enabled when the upgrade can be queued
        -- (CAddBuildableToQueueCommand::IsValid [I]: its own, the next size's prerequisites
        -- researched, no upgrade queued)
        local queued = false
        for _, q in ipairs(e.queue or {}) do
            queued = queued or q.kind == "starbase_upgrade"
        end
        if not e.next_size then
            hide[tp .. "/upgrade_info/upgrade"] = true
        elseif not (own and e.upgrade_ok and not queued) then
            tints[tp .. "/upgrade_info/upgrade"] = DISABLED
        end
        -- the dismantle button: Return (occupied), Dismantle (the lowest level), Downgrade (a level
        -- below it) [I]: the conditions' order read, the level's test not
        if e.mobile then
            hide[tp .. "/class_info/dismantle"] = true
        elseif not own then
            tints[tp .. "/class_info/dismantle"] = DISABLED
        end
        -- details: CShip::CanInspectShip for the player (its own; others' not [I])
        if not own then
            tints[tp .. "/class_info/details"] = DISABLED
        end
        -- a design's starbase (its growth stage flagged) shows its design, the others their modules
        if e.uses_design then
            hide[tp .. "/modules_info"] = true
            text[tp .. "/design_info/design_name"] = e.design and names.format(loc, e.design) or ""
            -- retrofit: CanRetrofit for the player (its own [I])
            if not own then
                tints[tp .. "/design_info/retrofit"] = DISABLED
            end
        else
            hide[tp .. "/design_info"] = true
        end
        text[tp .. "/starbase_modifiers_info/starbase_modifiers/hyperlane_detection_value"] = tostring(e.hyperlane or 0)
        text[tp .. "/starbase_modifiers_info/starbase_modifiers/sensor_range_value"] = tostring(e.sensor or 0)
        sprites[tp .. "/starbase_modifiers_info/starbase_modifiers/cloaking_level"] = "GFX_cloaking_level_" .. tostring(e.detection or 0)
        -- the cloaking row with First Contact only (Setup: NGameDLC::IsEnabled(DLC_FIRST_CONTACT))
        if not e.first_contact then
            hide[tp .. "/starbase_modifiers_info/starbase_modifiers/cloaking"] = true
            hide[tp .. "/starbase_modifiers_info/starbase_modifiers/cloaking_level"] = true
        end
    elseif tab == 1 then
        -- CStarbaseDefensesTabController::Update
        text[tp .. "/capacity_info/defense_platform_capacity"] = fmt(loc, "STARBASE_DEFENSE_PLATFORM_CAPACITY", { COUNT = e.platforms or 0, MAX = e.platform_capacity or 0 })
        -- no_orbitals while the platforms' list is empty; disband_all enabled with platforms; the
        -- upgrade enabled when CStarbase::CalcCanUpgradeDefensePlatforms and its command hold [I]:
        -- not evaluated, disabled
        if (e.platforms or 0) > 0 then
            hide[tp .. "/defense_platforms_info/no_orbitals"] = true
        end
        -- the "Docked" label (orbitals_label, 30 above the platforms' box) is not in the game's
        -- frame [I]: what hides it is not read (the controller does not look it up)
        hide[tp .. "/defense_platforms_info/orbitals_label"] = true
        tints[tp .. "/capacity_info/upgrade"] = DISABLED
        if not own or (e.platforms or 0) == 0 then
            tints[tp .. "/capacity_info/disband_all"] = DISABLED
        end
    elseif tab == 2 then
        -- CStarbaseShipsTabController::Update (CShipsTabControllerBase): the shipyards' count, the
        -- fleets in orbit, the build queue; the queue's title by the shipyard's kind
        text[tp .. "/capacity_info/module_capacity"] = fmt(loc, "STARBASE_SHIPYARD_CAPACITY", { COUNT = e.shipyard_capacity or 0 })
        text[tp .. "/build_queue_info/no_constructions"] = e.hatchery and "HATCHERY_QUEUE" or e.beastport and "BEASTPORT_QUEUE" or "SHIPYARD_QUEUE"
        if #(e.fleets or {}) > 0 then
            hide[tp .. "/fleets_info/no_orbitals"] = true
        end
    elseif tab == 3 then
        -- CStarbaseMacroBuilderTabController::Update: the sector's planets [I]: the owner's colonies
        -- in the starbase's sector
        text[tp .. "/capacity_info/macro_builder_capacity"] = fmt(loc, "MACRO_BUILDER_CAPACITY", { COUNT = e.sector_planets or 0 })
    end

    local wi, wr = gui.layout(ctx.game_dir, ctx.db, FILE, "starbase_view", ctx.screen, {
        texture_size = ctx.texture_size, loc = loc,
        sizes = { [W] = { 562, h } },
        only = only, hide = hide, text = text, sprites = sprites, tints = tints, actions = actions,
    })
    gui.merge(items, report, wi, wr)
    local rects = wr.rects

    if tab == 0 then
        if not e.uses_design then
            component_grid(ctx, items, report, rects[tp .. "/modules_info/modules_grid"], 58, e.module_slots or 0,
                e.module_capacity or 0, e.modules or {}, e.queue, W .. "/modules", "module")
        end
        component_grid(ctx, items, report, rects[tp .. "/buildings_info/buildings_grid"], 60, e.building_slots or 0,
            e.building_capacity or 0, e.buildings or {}, e.queue, W .. "/buildings", "building")
        queue_list(ctx, items, report, rects[tp .. "/build_queue_info/build_queue_list"], e.queue or {}, W .. "/queue", e, own)
    elseif tab == 1 then
        queue_list(ctx, items, report, rects[tp .. "/build_queue_info/build_queue_list"], {}, W .. "/defense_queue", e, own)
    elseif tab == 2 then
        queue_list(ctx, items, report, rects[tp .. "/build_queue_info/build_queue_list"], e.ship_queue or {}, W .. "/ship_queue", e, own)
        fleet_list(ctx, items, report, rects[tp .. "/fleets_info/fleets_list"], e.fleets or {}, W .. "/fleets")
        modifier_grid(ctx, items, report, rects[tp .. "/modifiers_info/modifiers_grid"], e.shipyard_mods or {}, W .. "/shipyard_mods")
    end
end

return M
