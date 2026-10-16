-- render/windows/leaders.lua : the leaders view (interface/topbar_leaders_view.gui,
-- CTopBarLeadersView; docs/windows/empire.md section 3): the class tabs with their counts, the
-- list of the empire's leaders and of the recruitable ones (each a paragon_portrait_container_
-- horizontal_slim card in a leaders_view_gridbox_entry), the selected leader's big card
-- (paragon_portrait_container_expanded) and its buttons.

local world = require("engine.world")
local C = require("render.windows.empire_common")
local leaders = require("render.windows.leaders_common")

local M = {}

local FILE = "interface/topbar_leaders_view.gui"
local V = "/topbar_leaders_view"

-- days since 1.1.1 of a "y.m.d" date (360-day years, 30-day months)
local function days(date)
    local y, m, d = tostring(date or ""):gsub('"', ""):match("^(%d+)%.(%d+)%.(%d+)")
    if not y then
        return nil
    end
    return (tonumber(y) * 12 + tonumber(m) - 1) * 30 + tonumber(d) - 1
end

local function date_of(n)
    local y = math.floor(n / 360)
    local r = n % 360
    return string.format("%d.%02d.%02d", y, math.floor(r / 30) + 1, r % 30 + 1)
end

function M.data(cid, state)
    local c = world.object("country", cid)
    if not c then
        return {}
    end
    local d = { owned = {}, pool = {}, date = tostring(world.meta.date or ""):gsub('"', "") }
    for _, e in ipairs(world.list(world.field(c, "owned_leaders"))) do
        local id = tonumber(e.text or e)
        local l = id and leaders.leader_data(id, c)
        if l then
            d.owned[#d.owned + 1] = l
        end
    end
    local pool = world.path(c, "modules", "standard_leader_module", "leaders")
    for _, e in ipairs(world.list(pool)) do
        local id = tonumber(e.text or e)
        local l = id and leaders.leader_data(id, c)
        if l then
            d.pool[#d.pool + 1] = l
        end
    end
    return d
end

-- the classes with a tab (in common/leader_classes' order): those that are not envoys [I: the
-- class flag CTopBarLeadersView::Reload reads]
local function classes(ctx)
    local out = {}
    for _, k in ipairs(C.def_order(ctx, "common/leader_classes")) do
        local b = C.defs(ctx, "common/leader_classes")[k]
        if C.field(b, "can_be_envoy") ~= "yes" then
            out[#out + 1] = k
        end
    end
    return out
end

local function listed(ctx, l)
    local b = C.defs(ctx, "common/leader_classes")[l.class or ""]
    return b and C.field(b, "can_be_envoy") ~= "yes"
end

-- a class's leader cap: its leader_capacity (@base_leader_cap = 3) [I: modifiers left out]
local function cap(ctx, class)
    local b = C.defs(ctx, "common/leader_classes")[class]
    return tonumber(b and C.field(b, "leader_capacity")) or 3
end

function M.build(ctx, d, state)
    local b = C.builder(ctx)
    local tab = state.tab or "all"
    local owned, pool = {}, {}
    for _, l in ipairs(d.owned or {}) do
        if listed(ctx, l) and (tab == "all" or l.class == tab) then
            owned[#owned + 1] = l
        end
    end
    -- NGuiUtil::SortLeader: leaders without a location first, then by skill, else as saved
    for i, l in ipairs(owned) do
        l.order = i
    end
    table.sort(owned, function(a, b2)
        local la, lb = a.location == nil, b2.location == nil
        if la ~= lb then
            return la
        end
        if a.level ~= b2.level then
            return a.level > b2.level
        end
        return a.order < b2.order
    end)
    local class_index = {}
    for i, k in ipairs(C.def_order(ctx, "common/leader_classes")) do
        class_index[k] = i
    end
    for i, l in ipairs(d.pool or {}) do
        if listed(ctx, l) and (tab == "all" or l.class == tab) then
            l.order = i
            pool[#pool + 1] = l
        end
    end
    table.sort(pool, function(a, b2)
        local ca, cb = class_index[a.class] or 0, class_index[b2.class] or 0
        if ca ~= cb then
            return ca < cb
        end
        return a.order < b2.order
    end)
    -- the selected leader: the one clicked, else the first owned row, else the first recruitable
    local selected
    for _, l in ipairs(owned) do
        if tostring(l.id) == state.leader then
            selected = l
        end
    end
    for _, l in ipairs(pool) do
        if tostring(l.id) == state.leader then
            selected = l
        end
    end
    selected = selected or owned[1] or pool[1]
    local in_pool = selected and not (function()
        for _, l in ipairs(owned) do
            if l == selected then
                return true
            end
        end
    end)()

    local hide = { all_tab_container = true, leader_class_tab_container = true, collapsable_leader_container = true,
        collapsable_job_container = true, leaders_view_gridbox_entry = true, leaders_view_job_gridbox_entry = true,
        assign_job_list_container = true, autoselect_traits_checkbox = true, autoselect_traits_title = true,
        no_available_leader_container = selected ~= nil or nil }
    if not selected or in_pool then
        hide.dismiss_leader_button = true
        hide.assign_leader_button = true
    end
    if not selected or not in_pool then
        hide.hire_leader_button = true
    end
    local text = {}
    if not selected then
        text[V .. "/no_available_leader_container/no_available_leader_text"] = tab == "all" and "NO_LEADER_AVAILABLE" or "NO_CLASS_LEADER_AVAILABLE"
    end
    -- the view, its action buttons drawn after the big card (they are after its container in
    -- the window: over it)
    local BUTTONS = { "hire_leader_button", "dismiss_leader_button", "assign_leader_button" }
    local view_hide = {}
    for k, v in pairs(hide) do
        view_hide[k] = v
    end
    for _, n in ipairs(BUTTONS) do
        view_hide[n] = true
    end
    local r = b:add(FILE, "topbar_leaders_view", { hide = view_hide, text = text, actions = { [V .. "/close"] = "view_close" } })
    local view = r.rects[V]
    if not view then
        return b.items, b.report
    end

    -- the class tabs: "All" (all_tab_container) then one per class (leader_class_tab_container),
    -- from (6, 40), each its container's width further
    local counts = {}
    for _, l in ipairs(d.owned or {}) do
        counts[l.class or ""] = (counts[l.class or ""] or 0) + 1
    end
    local x = view.x + 6
    local tabs = { "all" }
    for _, k in ipairs(classes(ctx)) do
        tabs[#tabs + 1] = k
    end
    for i, k in ipairs(tabs) do
        local template = k == "all" and "all_tab_container" or "leader_class_tab_container"
        local prefix = "/leader_tabs/" .. i
        local p = prefix .. "/" .. template .. "/"
        local label
        if k == "all" then
            label = "all_leaders_with_icon"
        else
            local used, n = counts[k] or 0, cap(ctx, k)
            local colour = used < n and "W" or (used < 2 * n and "Y" or "R")
            label = C.loc(ctx, k .. "_plural_with_icon") .. "\n§" .. colour .. used .. "/" .. n .. "§!"
        end
        local tr = b:add(FILE, template, {
            prefix = prefix, parent = { x = x, y = view.y + 40, w = 0, h = 0 },
            positions = { ["/" .. template] = { 0, 0 }, [prefix .. "/" .. template] = { 0, 0 } },
            hide = { selected = k ~= tab or nil },
            text = { [p .. "class_title_label"] = label },
            actions = { [p .. "show_class_tab_button"] = "view_set:tab=" .. k },
        })
        local cr = tr.rects[prefix .. "/" .. template]
        x = x + (cr and cr.w or 100)
    end

    -- the list: the owned section, then the recruitable one, rows as far as the list reaches
    local list = r.rects[V .. "/leader_list_container/leader_container_list"]
    local y, bottom = list.y, list.y + list.h
    local function header(prefix, key, n, rhs)
        if y + 42 > bottom then
            return false
        end
        local p = prefix .. "/collapsable_leader_container/"
        local t = C.loc(ctx, key)
        if n then
            t = t .. " (" .. n .. ")"
        end
        b:add(FILE, "collapsable_leader_container", {
            prefix = prefix, parent = { x = list.x, y = y, w = 0, h = 0 },
            hide = { expand_button = true, item_gridbox = true },
            text = { [p .. "unexpand_button"] = t, [p .. "rhs_header_button_custom_text"] = rhs or "" },
        })
        y = y + 42
        return true
    end
    local function rows(prefix, list_of, is_pool)
        for i, l in ipairs(list_of) do
            -- a row the list would cut is left out [I: the game's list clips it]
            if y + 93 > bottom then
                return
            end
            local rp = prefix .. "/" .. i
            local er = b:add(FILE, "leaders_view_gridbox_entry", {
                prefix = rp, parent = { x = list.x, y = y, w = 0, h = 0 },
                hide = { selected_overlay = l ~= selected or nil },
                actions = { [rp .. "/leaders_view_gridbox_entry/expand_leader_button"] = "view_set:leader=" .. l.id },
            })
            local entry = er.rects[rp .. "/leaders_view_gridbox_entry"]
            leaders.card(ctx, b, "paragon_portrait_container_horizontal_slim", entry, l, {
                prefix = rp .. "/card", pool = is_pool,
                text = is_pool and { ["cost_text"] = C.raw(ctx, "LEADER_COST"):gsub("%$VALUE|?Y?%$", "§Y100§!") } or nil,
            })
            y = y + 93
        end
    end
    if header("/leader_list/owned", "CURRENT_LEADERS", #owned) then
        rows("/leader_list/owned", owned, false)
    end
    -- the pool's next refresh (LEADER_POOL_REFRESH_TIME 1800 days from the game's start [I])
    local now = days(d.date)
    local rhs
    if now then
        local start = days("2200.01.01")
        local nxt = start + (math.floor((now - start) / 1800) + 1) * 1800
        local left = math.floor((nxt - now) / 360)
        rhs = C.raw(ctx, "DAYS_UNTIL_LEADER_POOL_REFRESH"):gsub("%$DATE%$", date_of(nxt)):gsub("%$TIME%$", "§Y" .. left .. " " .. C.loc(ctx, "YEARS") .. "§!")
    end
    if header("/leader_list/pool", "AVAILABLE_LEADERS", nil, rhs) then
        rows("/leader_list/pool", pool, true)
    end

    -- the selected leader's big card
    local pc = r.rects[V .. "/leader_portrait_container"]
    if selected and pc then
        leaders.card(ctx, b, "paragon_portrait_container_expanded", pc, selected, { prefix = "/leader_card", pool = in_pool })
    end
    local only = {}
    for _, n in ipairs(BUTTONS) do
        if not hide[n] then
            only[n] = true
        end
    end
    b:add(FILE, "topbar_leaders_view", { only = only, hide = { [V .. "/background"] = true }, text = {} })
    return b.items, b.report
end

return M
