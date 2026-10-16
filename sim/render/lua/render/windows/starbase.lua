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

-- a disabled button goes in the layout's `disabled`: render.gui greys it and its label as the
-- game's Disable does (buttonstate_onlydisable.shader, GreyOutLuminosity; TextDisable)

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
-- 0x294a080, not read through): military 3, construction 2, science 1; GFX_ship_class_medium's
-- in the side view's frame the same, a colony ship 14, a defense platform 27 (the frames' order
-- is the same in both sprites [I])
local CLASS_FRAME = { constructor = 2, science = 1, colonizer = 14, military_station_small = 27, military_station_medium = 27, military_station_large = 27 }

local function days_left(q)
    -- (CalcDaysLeft: what is left over the item's speed, a day up: the game's frame shows 55 for
    -- 60 at +10%)
    return math.max(0, math.ceil(((q.needed or 0) - (q.progress or 0)) / math.max(q.speed or 1, 0.01) - 1e-6))
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
-- with a `key`, the list scrolls (the wheel over it: starbase.rs wheel; the state's `scroll`
-- KEY=PIXELS): its area and range go in M.scroll_areas, the entries that fit at the offset are drawn
M.scroll_areas = {}
local function scroll_of(key)
    for k, v in tostring((RENDER_STARBASE_STATE or {}).scroll or ""):gmatch("([^,=]+)=([^,]+)") do
        if k == key then
            return tonumber(v) or 0
        end
    end
    return 0
end
M.scroll_of = scroll_of

local function list_entries(ctx, items, report, rect, spacing, entry_h, entries, layout_one, key)
    if not rect then
        return
    end
    local off = 0
    if key then
        local total = #entries * (entry_h + spacing) - spacing
        local max = math.max(0, total - rect.h)
        off = math.min(scroll_of(key), max)
        M.scroll_areas[#M.scroll_areas + 1] = { key = key, x = rect.x, y = rect.y, w = rect.w, h = rect.h, max = max }
    end
    local y = rect.y - off
    for i, ent in ipairs(entries) do
        if y + entry_h > rect.y + rect.h + 0.5 then
            break
        end
        if y >= rect.y - 0.5 then
            local ri, rr = layout_one(i, ent, { x = rect.x, y = y, w = rect.w, h = entry_h })
            gui.merge(items, report, ri, rr)
        end
        y = y + entry_h + spacing
    end
end

-- the grid of a starbase's modules or buildings (CStarbaseComponentGridController::UpdateCustom:
-- the level's slots, GetMaxModuleCapacity / GetMaxBuildingCapacity, each a
-- starbase_view_current_component_grid_entry; CStarbaseComponentGridEntry::UpdateWithData: a
-- component's icon; an empty slot unlocked below the station's capacity (CStarbase +0x14e0, its
-- starbase_module_capacity_add), locked from it on; the green overlay only on the slot chosen)
local function component_grid(ctx, items, report, grid, slot, slots, capacity, parts, queue, prefix, kind, chosen)
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
        local hide = { progressbar = true }
        if chosen ~= i then
            hide[path .. "/planet_view_module_spaceport_buildqueue_entry_overlay"] = true
        end
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
    elseif q.kind == "starbase_module" or q.kind == "starbase_building" then
        -- (a module's and a building's names: sm_<key>; the game's frame: on both lines)
        local name = L("sm_" .. tostring(q.key))
        return 22, name, name
    elseif q.kind == "ship" then
        -- (the game's frames: "Construction Ship" / "Construction Ship"; "Defense Platform" /
        -- "Buoyant Barnacle-class")
        local design = q.design and names.format(loc, q.design) or ""
        local size = L(q.key or "")
        return CLASS_FRAME[q.key or ""] or 3, size, q.civilian and size or fmt(loc, "BUILDABLE_SHIP_NAME", { TYPE = design })
    end
    return 1, L(tostring(q.key or "")), ""
end

-- a build queue's entries (CConstructionQueueListItem: starbase_view_build_queue_list_entry, its
-- icon, title and name, the time while it is built (BUILD_TIME_REMAINING "£time£ $DAYS$", the days
-- CalcDaysLeft gives: what is left at one a day [I]) or its place behind (QUEUED_NUMBER), the
-- progress bar (GFX_queue_progressbar, progress_startend.shader: render.gui's startend bar at the
-- item's progress); its priority buttons enabled when the commands are valid: up from the second,
-- down before the last, for its own (OnPriorityUp / OnPriorityDown); the entry's cancel_button
-- (the whole entry: OnCancel) for its own)
local function queue_list(ctx, items, report, rect, queue, prefix, e, own)
    list_entries(ctx, items, report, rect, 3, 52, queue, function(i, q, r)
        local rp = prefix .. "/" .. i
        local path = rp .. "/starbase_view_build_queue_list_entry"
        local frame, title, sub = queue_texts(ctx.loc, e, q)
        local disabled, actions = {}, {}
        if not own or i == 1 then
            disabled[path .. "/priority_upwards"] = true
        elseif q.id then
            actions[path .. "/priority_upwards"] = "starbase:cmd:priority:" .. q.id .. ":up"
        end
        if not own or i == #queue then
            disabled[path .. "/priority_downwards"] = true
        elseif q.id then
            actions[path .. "/priority_downwards"] = "starbase:cmd:priority:" .. q.id .. ":down"
        end
        if own and q.id then
            actions[path .. "/cancel_button"] = "starbase:cmd:cancel:" .. q.id
        end
        local ri, rr = gui.layout(ctx.game_dir, ctx.db, FILE, "starbase_view_build_queue_list_entry", ctx.screen, {
            texture_size = ctx.texture_size, loc = ctx.loc, prefix = rp, parent = r,
            frames = { [path .. "/icon"] = frame },
            progress = { [path .. "/progressbar"] = (q.needed or 0) > 0 and (q.progress or 0) / q.needed or 0 },
            disabled = disabled, actions = actions,
            text = {
                [path .. "/title"] = title,
                [path .. "/time"] = i == 1 and fmt(ctx.loc, "BUILD_TIME_REMAINING", { DAYS = days_left(q) }) or fmt(ctx.loc, "QUEUED_NUMBER", { NUMBER = i - 1 }),
                [path .. "/name"] = sub,
            },
        })
        return ri, rr
    end, prefix)
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
    end, prefix)
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

-- the side view (CStarbaseSideView: starbase_side_view beside the window, its entries_list): the
-- tab's catalog (CStarbaseSideView::GetTitleString: STARBASE_DEFENSES, STARBASE_SHIPS,
-- STARBASE_MACRO_BUILDER_ARMIES; the Command tab's after a slot is clicked: STARBASE_MODULES /
-- STARBASE_BUILDINGS), for the player's own starbase [I]
--   designs: a sublist header each (CBuildableShipListCivilian: OUTLINER_CIVILIAN_FLEETS [I], the
--     game's "Utility Ships"; CBuildableShipListSubList: the size's <size>_plural), its up_arrow
--     open, down_arrow closed (ToggleOpenStatus: `starbase:sub:KEY`), then its designs
--     (CBuildableShipListItemBase: the class icon, the design's name (a civilian's: its size's
--     name), AUTO_GENERATED_BEST for an auto-generated military design, the build time and the
--     cost); a click builds it (CBuildableShipListItem::Build)
--   a slot: its component (starbase_view_panel_current_entry, Dismantle) or the buildables
--     (starbase_view_buildable_component_list_entry: icon, name, cost; a click queues it, greyed
--     when `possible` fails)
local SUBLIST_H, SHIP_H, COMPONENT_H, SPACING = 40, 48, 60, 3

-- a greyed entry's text (the game's frame: its name and cost grey): in textcolor t [I]
-- whether the owner's stockpile holds a cost (the game's frames grey what it cannot pay for) [I]
local function affordable(cat, cost)
    for _, c in ipairs(cost or {}) do
        if c.value > ((cat.stock or {})[c.res] or 0) + 1e-6 then
            return false
        end
    end
    return true
end

local function grey_if(grey, text)
    if not grey then
        return text
    end
    return "\194\167t" .. tostring(text):gsub("\194\167[%a!]", "") .. "\194\167!"
end
local ctx_loc   -- the localisation of the layout in progress (the side view's sorting by names)

-- a cost (and a time): "£alloys£ 38 £time£ 180", whole numbers half up (the game's frame: 37.5 -> 38)
local function cost_text(cost, time)
    local parts = {}
    for _, c in ipairs(cost or {}) do
        parts[#parts + 1] = "\194\163" .. c.res .. "\194\163 " .. string.format("%d", math.floor(c.value + 0.5))
    end
    if time then
        parts[#parts + 1] = "\194\163time\194\163 " .. string.format("%d", time)
    end
    return table.concat(parts, " ")
end

-- the components a slot can take, by category (CStarbaseBuildableComponentCategoryEntry: a header
-- each, the categories by their names, the components by their cost, then their names [I: the
-- game's frame's order]); a closed category's components left out
local function component_entries(out, list, kind, slot, closed, loc)
    local by, cats = {}, {}
    for _, c in ipairs(list or {}) do
        if not by[c.category] then
            by[c.category] = {}
            cats[#cats + 1] = c.category
        end
        local l = by[c.category]
        l[#l + 1] = c
    end
    local function L(k)
        return loc and (loc.get(k)) or k
    end
    table.sort(cats, function(a, b) return L(a) < L(b) end)
    for _, cat in ipairs(cats) do
        local key = "cat:" .. cat
        out[#out + 1] = { kind = "header", key = key, label = cat, open = not closed[key] }
        if not closed[key] then
            local l = by[cat]
            table.sort(l, function(a, b)
                if a.total ~= b.total then return a.total < b.total end
                return L("sm_" .. a.key) < L("sm_" .. b.key)
            end)
            for _, c in ipairs(l) do
                out[#out + 1] = { kind = "component", c = c, component = kind, slot = slot }
            end
        end
    end
end

local function side_entries(e, state, tab)
    local cat = e.catalog
    if not cat then
        return nil
    end
    local out = {}
    local closed = {}
    for k in tostring(state.closed or ""):gmatch("[^,]+") do
        closed[k] = true
    end
    if tab == 1 or tab == 2 then
        local list = tab == 1 and cat.defenses or cat.ships
        local last
        for _, d in ipairs(list or {}) do
            local key = d.civilian and "civilian" or d.size
            if key ~= last then
                out[#out + 1] = { kind = "header", key = key, civilian = d.civilian, size = d.size, open = not closed[key] }
                last = key
            end
            if not closed[key] then
                out[#out + 1] = { kind = "ship", d = d }
            end
        end
        return out, tab == 1 and "STARBASE_DEFENSES" or "STARBASE_SHIPS"
    elseif tab == 3 then
        return out, "STARBASE_MACRO_BUILDER_ARMIES"
    end
    -- the side view of a slot of this starbase (`FLEET:kind:N`)
    local fleet, kind, slot = tostring(state.side or ""):match("^(%d+):(%a+):(%d+)$")
    if not kind or tonumber(fleet) ~= e.fleet then
        return nil
    end
    slot = tonumber(slot)
    -- a filled slot: its component (Dismantle), then its replacements ("Click to see replacement
    -- options": the game's frame lists the categories under it)
    local parts = kind == "module" and e.modules or e.buildings
    for _, p in ipairs(parts or {}) do
        if p.slot == slot then
            out[#out + 1] = { kind = "current", part = p, component = kind, slot = slot }
        end
    end
    component_entries(out, kind == "module" and cat.modules or cat.buildings, kind, slot, closed, ctx_loc)
    return out, kind == "module" and "STARBASE_MODULES" or "STARBASE_BUILDINGS"
end

local function side_view(ctx, items, report, e, state, tab, win)
    ctx_loc = ctx.loc
    local entries, title = side_entries(e, state, tab)
    if not entries or not win then
        return
    end
    local loc = ctx.loc
    local S = "/starbase_side_view"
    local wi, wr = gui.layout(ctx.game_dir, ctx.db, FILE, "starbase_side_view", ctx.screen, {
        texture_size = ctx.texture_size, loc = loc, parent = { x = win.x, y = win.y, w = win.w, h = win.h },
        text = { [S .. "/title"] = loc and (loc.get(title)) or title },
        -- (the panel takes the clicks over it, as the game's windows do)
        actions = { [S] = "starbase:none" },
    })
    gui.merge(items, report, wi, wr)
    local rect = wr.rects[S .. "/entries_list"]
    if not rect then
        return
    end
    -- the rows' places: a design list's rows 8 px above the listbox's position, 3 apart (the
    -- game's frame) [I]; a component list's categories each in a starbase_view_panel_buildables_entry
    -- (its entries list at y 10, spacing 5): 10 px below the current component or the list's top,
    -- their rows 5 apart (the game's frames: headers at 180, 485, 660 for a citadel's buildings)
    local components = title == "STARBASE_MODULES" or title == "STARBASE_BUILDINGS"
    local places, y0 = {}, components and 0 or -8
    local started = false
    for i, ent in ipairs(entries) do
        local h = ent.kind == "header" and SUBLIST_H or ent.kind == "ship" and SHIP_H or ent.kind == "current" and 59 or COMPONENT_H
        if components and ent.kind ~= "current" and not started then
            y0, started = y0 + 10, true
        end
        places[i] = { y0, h }
        y0 = y0 + h + ((components and ent.kind ~= "current") and 5 or SPACING)
    end
    -- the list's area and how far it scrolls (the wheel over it: starbase.rs wheel)
    local max = math.max(0, y0 - rect.h)
    M.scroll_areas[#M.scroll_areas + 1] = { key = "side", x = rect.x, y = rect.y, w = rect.w, h = rect.h, max = max }
    local scroll = math.min(scroll_of("side"), max)
    for i, ent in ipairs(entries) do
        local y, h = rect.y + places[i][1] - scroll, places[i][2]
        if y + h > rect.y + rect.h + 0.5 then
            break
        end
        if y >= rect.y - 8.5 then
            local rp = S .. "/entries/" .. i
            local r = { x = rect.x, y = y, w = rect.w, h = h }
            local name, o
            if ent.kind == "header" then
                name = "starbase_view_buildable_list_sublist_header"
                local path = rp .. "/" .. name
                local label = ent.label or (ent.civilian and "OUTLINER_CIVILIAN_FLEETS" or (ent.size .. "_plural"))
                o = {
                    text = { [path .. "/offset/name"] = loc and (loc.get(label)) or label },
                    hide = { [path .. "/offset/" .. (ent.open and "down_arrow" or "up_arrow")] = true },
                    actions = { [path .. "/offset"] = "starbase:sub:" .. ent.key },
                }
            elseif ent.kind == "ship" then
                name = "starbase_view_buildable_ship_list_entry"
                local path = rp .. "/" .. name
                local d = ent.d
                -- a military design's "<name>-class" (BUILDABLE_SHIP_NAME), a civilian's size name
                local label = d.civilian and (loc and (loc.get(d.size)) or d.size)
                    or fmt(loc, "BUILDABLE_SHIP_NAME", { TYPE = d.name and names.format(loc, d.name) or d.size })
                local can = affordable(e.catalog, d.cost)
                o = {
                    disabled = (not can) and { [path] = true } or nil,
                    frames = { [path .. "/ship_type"] = CLASS_FRAME[d.size] or (d.class == "shipclass_military_station" and 27) or 3 },
                    text = {
                        [path .. "/type"] = grey_if(not can, label),
                        [path .. "/auto_gen"] = (d.auto and not d.civilian) and grey_if(not can, loc and (loc.get("AUTO_GENERATED_BEST")) or "AUTO_GENERATED_BEST") or "",
                        [path .. "/time"] = d.days and grey_if(not can, "\194\163time\194\163 " .. string.format("%d", d.days)) or "",
                        [path .. "/cost"] = grey_if(not can, cost_text(d.cost)),
                    },
                    actions = can and { [path .. "/background_offset"] = "starbase:cmd:ship:" .. e.id .. ":" .. d.design } or nil,
                }
            elseif ent.kind == "component" then
                name = "starbase_view_buildable_component_list_entry"
                local path = rp .. "/" .. name
                local c = ent.c
                -- a building the starbase has or has queued is greyed (one of each: the game's
                -- frame greys a citadel's three buildings) [I]; modules repeat
                -- (`possible` is not used: the script layer evaluates some of its scopes false, a
                -- solar_system count among them, where the game lets them be built) [I]
                local can = affordable(e.catalog, c.cost)
                -- a slot with an item queued takes no other (the game's frame greys them all)
                for _, q in ipairs(e.queue or {}) do
                    if q.kind == "starbase_" .. ent.component and q.slot == ent.slot - 1 then can = false end
                end
                if ent.component == "building" then
                    for _, b in ipairs(e.buildings or {}) do
                        if b.key == c.key then can = false end
                    end
                    for _, q in ipairs(e.queue or {}) do
                        if q.kind == "starbase_building" and q.key == c.key then can = false end
                    end
                end
                o = {
                    sprites = { [path .. "/icon"] = c.icon },
                    frames = { [path .. "/icon"] = c.frame },
                    text = { [path .. "/name"] = grey_if(not can, loc and (loc.get("sm_" .. c.key)) or c.key), [path .. "/cost"] = grey_if(not can, cost_text(c.cost, c.days)) },
                    disabled = (not can) and { [path] = true } or nil,
                    actions = can and { [path] = "starbase:cmd:" .. ent.component .. ":" .. e.id .. ":" .. (ent.slot - 1) .. ":" .. c.key } or nil,
                }
            else
                name = "starbase_view_panel_current_entry"
                local path = rp .. "/" .. name
                o = {
                    sprites = { [path .. "/icon"] = ent.part.icon },
                    frames = { [path .. "/icon"] = ent.part.frame },
                    text = { [path .. "/name"] = loc and (loc.get("sm_" .. ent.part.key)) or ent.part.key },
                    actions = { [path .. "/dismantle"] = "starbase:dialog:dismantle_component:" .. e.id .. ":" .. ent.component .. ":" .. ent.slot },
                }
            end
            o.texture_size, o.loc, o.prefix, o.parent = ctx.texture_size, loc, rp, r
            local ri, rr = gui.layout(ctx.game_dir, ctx.db, FILE, name, ctx.screen, o)
            gui.merge(items, report, ri, rr)
        end
    end
end

-- the windows of this family that are not the selection's: a megastructure's (its id in
-- RENDER_STARBASE_STATE.megastructure; a selection replaces it, as selecting does in the game)
function M.extra(ctx, items, report)
    local state = RENDER_STARBASE_STATE or {}
    if state.megastructure and not state.selected then
        require("render.windows.megastructure").build(ctx, tonumber(state.megastructure), items, report)
        M.dialog(ctx, items, report, state, nil)
    end
    if state.network and not state.selected then
        require("render.windows.network").build(ctx, tonumber(state.network), items, report)
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
    M.scroll_areas = {}
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
    local hide, text, sprites, tints, actions, disabled = {}, {}, {}, {}, {}, {}

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
            disabled[b] = true
            actions[b] = nil
            local key = label or ({ [0] = "STARBASE_STARBASE_TAB", "STARBASE_DEFENSES_TAB", "STARBASE_SHIPYARD_TAB", "MACRO_BUILDER_TAB" })[k]
            label = loc and (loc.get(key)) or key
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
            disabled[tp .. "/upgrade_info/upgrade"] = true
        else
            actions[tp .. "/upgrade_info/upgrade"] = "starbase:cmd:upgrade:" .. e.id
        end
        -- the dismantle button: Return (occupied), Dismantle (the lowest level), Downgrade (a level
        -- below it) [I]: the conditions' order read, the level's test not
        if e.mobile then
            hide[tp .. "/class_info/dismantle"] = true
        elseif not own then
            disabled[tp .. "/class_info/dismantle"] = true
        end
        -- details: CShip::CanInspectShip for the player (its own; others' not [I])
        if not own then
            disabled[tp .. "/class_info/details"] = true
        elseif e.station_ship then
            actions[tp .. "/class_info/details"] = "fleet:ship:" .. e.station_ship
        end
        -- Dismantle: its dialog (the lowest level: STARBASE_DISMANTLE_DIALOG; above it the
        -- downgrade's) [I: the level test]
        if own then
            actions[tp .. "/class_info/dismantle"] = "starbase:dialog:" .. (e.next_size and e.level == "starbase_level_outpost" and "dismantle" or "downgrade") .. ":" .. e.id
        end
        -- a design's starbase (its growth stage flagged) shows its design, the others their modules
        if e.uses_design then
            hide[tp .. "/modules_info"] = true
            text[tp .. "/design_info/design_name"] = e.design and names.format(loc, e.design) or ""
            -- retrofit: CanRetrofit for the player (its own [I])
            if not own then
                disabled[tp .. "/design_info/retrofit"] = true
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
        disabled[tp .. "/capacity_info/upgrade"] = true
        if not own or (e.platforms or 0) == 0 then
            disabled[tp .. "/capacity_info/disband_all"] = true
        else
            actions[tp .. "/capacity_info/disband_all"] = "starbase:dialog:disband_all:" .. e.id .. ":" .. (e.platforms or 0)
        end
        actions[tp .. "/build_queue_info/open_defense_designs"] = "starbase:designer:defenses"
    elseif tab == 2 then
        -- CStarbaseShipsTabController::Update (CShipsTabControllerBase): the shipyards' count, the
        -- fleets in orbit, the build queue; the queue's title by the shipyard's kind
        text[tp .. "/capacity_info/module_capacity"] = fmt(loc, "STARBASE_SHIPYARD_CAPACITY", { COUNT = e.shipyard_capacity or 0 })
        text[tp .. "/build_queue_info/no_constructions"] = e.hatchery and "HATCHERY_QUEUE" or e.beastport and "BEASTPORT_QUEUE" or "SHIPYARD_QUEUE"
        if #(e.fleets or {}) > 0 then
            hide[tp .. "/fleets_info/no_orbitals"] = true
        end
        actions[tp .. "/build_queue_info/open_ship_designs"] = "starbase:designer:ships"
    elseif tab == 3 then
        -- CStarbaseMacroBuilderTabController::Update: the sector's planets [I]: the owner's colonies
        -- in the starbase's sector
        text[tp .. "/capacity_info/macro_builder_capacity"] = fmt(loc, "MACRO_BUILDER_CAPACITY", { COUNT = e.sector_planets or 0 })
    end

    local wi, wr = gui.layout(ctx.game_dir, ctx.db, FILE, "starbase_view", ctx.screen, {
        texture_size = ctx.texture_size, loc = loc,
        sizes = { [W] = { 562, h } },
        only = only, hide = hide, text = text, sprites = sprites, tints = tints, disabled = disabled, actions = actions,
    })
    gui.merge(items, report, wi, wr)
    local rects = wr.rects

    if tab == 0 then
        local side_fleet, side_kind, side_slot = tostring(state.side or ""):match("^(%d+):(%a+):(%d+)$")
        if tonumber(side_fleet) ~= e.fleet then side_kind = nil end
        side_slot = tonumber(side_slot)
        if not e.uses_design then
            component_grid(ctx, items, report, rects[tp .. "/modules_info/modules_grid"], 58, e.module_slots or 0,
                e.module_capacity or 0, e.modules or {}, e.queue, W .. "/modules", "module", side_kind == "module" and side_slot or nil)
        end
        component_grid(ctx, items, report, rects[tp .. "/buildings_info/buildings_grid"], 60, e.building_slots or 0,
            e.building_capacity or 0, e.buildings or {}, e.queue, W .. "/buildings", "building", side_kind == "building" and side_slot or nil)
        queue_list(ctx, items, report, rects[tp .. "/build_queue_info/build_queue_list"], e.queue or {}, W .. "/queue", e, own)
    elseif tab == 1 then
        -- the build queue, all of it (the game's frame: the upgrade shows there too), and the
        -- platforms (CStarbaseShipItem: starbase_view_ship_list_entry, its name, details, upgrade
        -- (CStarbase::CalcCanUpgradeDefensePlatforms not evaluated: disabled [I]), disband)
        queue_list(ctx, items, report, rects[tp .. "/build_queue_info/build_queue_list"], e.queue or {}, W .. "/defense_queue", e, own)
        list_entries(ctx, items, report, rects[tp .. "/defense_platforms_info/platforms_list"], 3, 52, e.platform_list or {}, function(i, p, r)
            local rp = W .. "/platforms/" .. i
            local path = rp .. "/starbase_view_ship_list_entry"
            local a = { [path .. "/details"] = "fleet:ship:" .. p.id }
            if own then
                a[path .. "/disband"] = "starbase:dialog:disband_ship:" .. e.id .. ":" .. p.id
            end
            return gui.layout(ctx.game_dir, ctx.db, FILE, "starbase_view_ship_list_entry", ctx.screen, {
                texture_size = ctx.texture_size, loc = ctx.loc, prefix = rp, parent = r,
                text = { [path .. "/name"] = names.format(ctx.loc, p.name) },
                disabled = { [path .. "/upgrade"] = true, [path .. "/disband"] = (not own) or nil },
                actions = a,
            })
        end, W .. "/platforms")
    elseif tab == 2 then
        queue_list(ctx, items, report, rects[tp .. "/build_queue_info/build_queue_list"], e.ship_queue or {}, W .. "/ship_queue", e, own)
        fleet_list(ctx, items, report, rects[tp .. "/fleets_info/fleets_list"], e.fleets or {}, W .. "/fleets")
        modifier_grid(ctx, items, report, rects[tp .. "/modifiers_info/modifiers_grid"], e.shipyard_mods or {}, W .. "/shipyard_mods")
    end
    if own then
        side_view(ctx, items, report, e, state, tab, rects[W])
    end
    M.dialog(ctx, items, report, state, e)
end

-- the confirmation dialog of a starbase command (`state.dialog` = the command: VERB:ARG...;
-- standard_dialog.gui `standard_dialog`, its title and text the game's: MULTIPLE_SHIPS_DISBAND_*,
-- SHIP_DISBAND_*, STARBASE_DISMANTLE_COMPONENT_DIALOG_*, STARBASE_DISMANTLE_DIALOG_*,
-- STARBASE_DOWNGRADE_DIALOG_*); Agree runs it (`starbase:dialog_yes`), Decline closes it
function M.dialog(ctx, items, report, state, e)
    local d = state.dialog
    if not d or d == "" then
        return
    end
    local loc = ctx.loc
    local verb = d:match("^(%a[%a_]*)")
    local args = {}
    for a in d:gmatch("[^:]+") do
        args[#args + 1] = a
    end
    local title, desc
    if verb == "disband_all" then
        title, desc = "MULTIPLE_SHIPS_DISBAND_TITLE", fmt(loc, "MULTIPLE_SHIPS_DISBAND_DESC", { COUNT = args[3] or 0 })
    elseif verb == "disband_ship" then
        title, desc = "SHIP_DISBAND_TITLE", "SHIP_DISBAND_DESC"
    elseif verb == "dismantle_component" then
        local key
        for _, p in ipairs((e and (args[3] == "building" and e.buildings or e.modules)) or {}) do
            if p.slot == tonumber(args[4]) then key = p.key end
        end
        title, desc = "STARBASE_DISMANTLE_COMPONENT_DIALOG_TITLE", fmt(loc, "STARBASE_DISMANTLE_COMPONENT_DIALOG_DESC", { NAME = key and (loc and (loc.get("sm_" .. key)) or key) or "" })
    elseif verb == "dismantle" then
        title, desc = "STARBASE_DISMANTLE_DIALOG_TITLE", "STARBASE_DISMANTLE_DIALOG_DESC"
    elseif verb == "mega_dismantle" then
        title, desc = "MEGASTRUCTURE_DISMANTLE_DIALOG_TITLE", "MEGASTRUCTURE_DISMANTLE_DIALOG_DESC"
    else
        title, desc = "STARBASE_DOWNGRADE_DIALOG_TITLE", "STARBASE_DOWNGRADE_DIALOG_DESC"
    end
    local P = "/standard_dialog"
    local wi, wr = gui.layout(ctx.game_dir, ctx.db, "interface/standard_dialog.gui", "standard_dialog", ctx.screen, {
        texture_size = ctx.texture_size, loc = loc,
        text = { [P .. "/title"] = title, [P .. "/description"] = desc },
        actions = { [P] = "starbase:none", [P .. "/AgreeButton"] = "starbase:dialog_yes", [P .. "/DeclineButton"] = "starbase:dialog_no" },
    })
    gui.merge(items, report, wi, wr)
end

return M
