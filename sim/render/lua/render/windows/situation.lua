-- render/windows/situation.lua : the Situation Log (interface/situation_log.gui, CSituationLog), a
-- left bar view (views.rs: `extract` where the world is, `build` where the GUI is; ETopBarView 0,
-- "situation"). docs/windows/events.md.
--
-- The Log tab (CSituationLog::UpdateLogTab, UpdateEntries) [V for the parts, I for the rules read
-- off the game's frame]: the categories of common/situation_log/categories whose target_tab is not
-- `anomalies`, by priority, each with entries (a `situation_log_entry` header: the category's icon
-- and name, its expand arrow; a `situation_log_subentry` per entry: the entry's icon and title).
-- Entries: the player's event chains (common/event_chains: their situation_log_category, icon,
-- picture, counters; `<chain>_title`, `<chain>_desc`), special projects, situations. The Findings
-- tab: first contacts, archaeological sites, anomalies, astral rifts (the categories with
-- target_tab = anomalies). The selected entry (the first, when none is chosen) fills the panels on
-- the right: its title, picture and description (`currently_selected_header_window`) and its
-- subview (an event chain's `event_chain_subview`: "Overall Progress:" and each counter
-- "<name>: value/max").

local gui = require("render.gui")
local source = require("stellar.script.source")
local events = require("render.windows.events")

local M = {}

local FILE = "interface/situation_log.gui"

function M.extract(game_dir)
    return require("render.windows.events_data").log(game_dir)
end

-- ---------------------------------------------------------------------------------------------
-- the game's definitions (parsed once)

local defs = {}

local function get(block, key)
    for _, e in ipairs(type(block) == "table" and block or {}) do
        if e.op and e.key and e.key.text:lower() == key then
            return e.value.text or e.value
        end
    end
    return nil
end

local function unquote(s)
    return s and (tostring(s):gsub('^"(.*)"$', "%1")) or nil
end

local function definitions(game_dir, dir)
    if defs[dir] then
        return defs[dir]
    end
    local out = {}
    for _, f in ipairs(source.files(game_dir, dir, "txt")) do
        local tree = source.parse(game_dir, f)
        for _, e in ipairs(tree or {}) do
            if e.op and e.key and e.value.text == nil and e.key.text:sub(1, 1) ~= "@" then
                out[e.key.text] = e.value
            end
        end
    end
    defs[dir] = out
    return out
end

-- the categories, by priority: { key, priority, icon, findings }
local function categories(game_dir)
    local list = {}
    for k, b in pairs(definitions(game_dir, "common/situation_log/categories")) do
        list[#list + 1] = {
            key = k, priority = tonumber(get(b, "priority")) or 0, icon = unquote(get(b, "icon")),
            loc = unquote(get(b, "localization")) or k, findings = get(b, "target_tab") == "anomalies",
            default = get(b, "default") == "yes",
            collapsible = get(b, "collapsible") ~= "no",
        }
    end
    table.sort(list, function(a, b)
        if a.priority ~= b.priority then
            return a.priority < b.priority
        end
        return a.key < b.key
    end)
    return list
end

-- a texture used as a sprite (an event chain's `icon` is a .dds path)
local function texture_sprite(db, path)
    if not path then
        return nil
    end
    local name = "@texture:" .. path
    if not db.sprites[name] then
        db.sprites[name] = { name = name, texture = path, frames = 1, kind = "spriteType" }
    end
    return name
end

-- ---------------------------------------------------------------------------------------------
-- the entries

-- data -> entries { category, title, desc, icon (sprite), picture, counters = { { name, value,
-- max } }, kind, location }
local function entries(ctx, data)
    local out = {}
    local chains = definitions(ctx.game_dir, "common/event_chains")
    for _, ch in ipairs(data and data.chains or {}) do
        local d = chains[ch.key]
        local counters = {}
        for _, e in ipairs(type(get(d, "counter")) == "table" and get(d, "counter") or {}) do
            if e.op and e.key and e.value.text == nil then
                counters[#counters + 1] = { name = e.key.text, value = ch.counters and ch.counters[e.key.text] or 0, max = tonumber(get(e.value, "max")) }
            end
        end
        out[#out + 1] = {
            kind = "chain", key = ch.key, category = unquote(get(d, "situation_log_category")),
            title = ch.key .. "_title", desc = ch.key .. "_desc", icon = texture_sprite(ctx.db, unquote(get(d, "icon"))),
            picture = unquote(get(d, "picture")), counters = counters,
        }
    end
    local projects = definitions(ctx.game_dir, "common/special_projects")
    for _, p in ipairs(data and data.projects or {}) do
        local d = projects[p.key]
        out[#out + 1] = {
            kind = "project", key = p.key, category = unquote(get(d, "situation_log_category")),
            title = p.key, desc = p.key .. "_DESC", picture = unquote(get(d, "picture")),
            icon = texture_sprite(ctx.db, unquote(get(d, "icon"))),
        }
    end
    for _, s in ipairs(data and data.situations or {}) do
        local d = definitions(ctx.game_dir, "common/situations")[s.type]
        out[#out + 1] = {
            kind = "situation", key = s.type, category = unquote(get(d, "situation_log_category")) or "urgent_matters",
            title = s.type, desc = s.type .. "_desc", picture = unquote(get(d, "picture")),
            icon = unquote(get(d, "icon")),
        }
    end
    for _, f in ipairs(data and data.first_contacts or {}) do
        if f.status ~= "finished" then
            -- its picture and text: its current event's (the frame's: first_contact.1's star chart
            -- and description); its icon the category's [I]
            local v = f.view or {}
            out[#out + 1] = {
                kind = "first_contact", key = tostring(f.id), category = "first_contacts", name = f.name, title = "",
                icon = "GFX_category_first_contact", picture = v.picture, desc = v.desc, view = v,
                days_left = f.days_left, difficulty = f.difficulty, leader = f.leader, location = f.location,
            }
        end
    end
    for _, s in ipairs(data and data.sites or {}) do
        out[#out + 1] = { kind = "site", key = tostring(s.id), category = "dig_sites", title = s.type, icon = "GFX_archaeology_entry" }
    end
    for _, a in ipairs(data and data.anomalies or {}) do
        out[#out + 1] = { kind = "anomaly", key = tostring(a.planet), category = "anomalies", title = a.category, icon = "GFX_anomaly_entry" }
    end
    return out
end

local SUBVIEWS = {
    "anomaly_subview", "event_chain_subview", "special_project_subview", "special_project_multi_choice_subview",
    "contract_issuer_subview", "situation_subview", "archaeological_site_subview", "astral_rift_subview",
    "first_contact_subview",
}
local SUBVIEW_OF = { chain = "event_chain_subview", project = "special_project_subview", situation = "situation_subview",
    first_contact = "first_contact_subview", site = "archaeological_site_subview", anomaly = "anomaly_subview" }

-- M.build(ctx, data, state) -> items, report; state.tab ("log" | "anomalies"), state.selected
-- ("kind:key"), state.no_selection (an event window opened over it: the game's frame shows none)
function M.build(ctx, data, state)
    state = state or {}
    local loc, db = ctx.loc, ctx.db
    local items, report = {}, { sprites = 0, texts = 0, missing_sprites = {}, skipped = {}, rects = {} }
    local findings = state.tab == "anomalies"
    -- the entries by category, the categories of this tab in order
    local list = entries(ctx, data)
    local cats = categories(ctx.game_dir)
    local fallback
    for _, c in ipairs(cats) do
        if c.default and c.findings == findings then
            fallback = c.key
        end
    end
    local shown, selected = {}, nil
    for _, c in ipairs(cats) do
        if c.findings == findings then
            local members = {}
            for _, e in ipairs(list) do
                -- a pinned entry is in "priority" ("Pinned by the player": the game moves it there)
                local ec = state["pin:" .. e.kind .. ":" .. e.key] and "priority" or e.category
                local known = false
                for _, cc in ipairs(cats) do
                    if cc.key == ec then
                        known = true
                    end
                end
                if ec == c.key or (not known and c.key == fallback) then
                    members[#members + 1] = e
                end
            end
            if #members > 0 then
                shown[#shown + 1] = { cat = c, members = members }
                for _, e in ipairs(members) do
                    if state.selected == e.kind .. ":" .. e.key then
                        selected = e
                    end
                end
            end
        end
    end
    if not selected and not state.no_selection and shown[1] then
        selected = shown[1].members[1]
    end

    -- the window
    local root = "/situation_log"
    local hide = {
        focus_window = true, victories_window = true,
        leader_window = true, no_leader_window = true, target_container = true,
        tts_button = true, situation_log_detail = true,
        -- (the contracts' parts of the event chain subview)
        cancel = true, timeout_text = true,
    }
    hide[findings and "tab_anomalies" or "tab_log"] = true
    hide.tab_focus_active, hide.tab_victories_active = true, true
    hide[findings and "tab_log_active" or "tab_anomalies_active"] = true
    local sub = selected and SUBVIEW_OF[selected.kind]
    for _, s in ipairs(SUBVIEWS) do
        if s ~= sub then
            hide[s] = true
        end
    end
    -- the header's buttons: `track` (the pin, GFX_button_track_project) and `goto` (the focus);
    -- with goto hidden the pin takes its place (CSituationLog::UpdateTrackButtonPosition): an
    -- event chain shows the pin alone, a first contact both [I: by the frames]
    local positions = {}
    if not selected then
        hide["goto"] = true
        hide.track = true
        hide.currently_selected_header_window = true
    elseif selected.kind ~= "first_contact" then
        hide["goto"] = true
        positions[root .. "/track"] = { -80, 16 }
    end
    local text, sprites, sizes = { [root .. "/header"] = findings and "FINDINGS" or "SITUATION_LOG_HEADER" }, {}, {}
    local hw = root .. "/currently_selected_header_window"
    if selected and selected.kind == "first_contact" then
        -- (the subview's places are @findings_* variables of another window of the file, which the
        -- layout's scoped variables do not reach: given here)
        local fc = root .. "/log_window/currently_selected/first_contact_subview"
        local tc, dc = fc .. "/time_container", fc .. "/difficulty_container"
        positions[fc .. "/requirements"] = { 1, 1 }
        sizes[fc .. "/requirements"] = { 410, 20 }
        positions[tc] = { 0, 30 }
        sizes[tc] = { 483, 60 }
        positions[tc .. "/progress_bar"] = { 10, 33 }
        positions[tc .. "/time_left_label"] = { 10, 10 }
        sizes[tc .. "/time_left_label"] = { 250, 20 }
        positions[tc .. "/time_left"] = { 423, 10 }
        sizes[tc .. "/time_left"] = { 50, 20 }
        positions[dc] = { 500, 18 }
        positions[dc .. "/difficulty_type_text"] = { 0, -16 }
        sizes[dc .. "/difficulty_type_text"] = { 100, 20 }
        positions[dc .. "/difficulty_type_icon"] = { 105, -21 }
        positions[dc .. "/difficulty_type_value"] = { 140, -16 }
        sizes[dc .. "/difficulty_type_value"] = { 40, 20 }
        positions[fc .. "/view_site"] = { 497, 30 }
        local name = require("render.names").format(loc, selected.name)
        -- no envoy: "Assign an Envoy to learn more about NAME"
        local raw = loc and loc.raw("FIRST_CONTACT_ASSIGN_ENVOY") or ""
        raw = raw:gsub("%$NAME|?%a*%$", function()
            return "§Y" .. name .. "§!"
        end)
        text[fc .. "/requirements"] = loc and loc.resolve(raw) or raw
        -- the roll's time bar: nearly empty in the game's frame (its fill not drawn) [I]
        hide.progress_bar = true
        text[tc .. "/time_left"] = "§Y" .. tostring(selected.days_left or 0) .. "§!"
        -- the difficulty: the save's (the game's frame shows 7 for the save's 5: its modifiers are
        -- not applied) [I]
        text[dc .. "/difficulty_type_value"] = "§R" .. tostring(selected.difficulty or 0) .. "§!"
        text[fc .. "/view_site"] = "SHOW_FIRST_CONTACT"
    end
    -- (the description is drawn wrapped below)
    text[hw .. "/description"] = ""
    if selected then
        text[hw .. "/title"] = selected.name and require("render.names").format(loc, selected.name) or selected.title
        if selected.picture and db.sprites[selected.picture] then
            sprites[hw .. "/picture_window/picture"] = selected.picture
        end
        if sub == "event_chain_subview" then
            local lines = {}
            for _, c in ipairs(selected.counters or {}) do
                lines[#lines + 1] = (loc and loc.has(c.name) and loc.get(c.name) or c.name) .. ": " .. tostring(c.value) .. (c.max and ("/" .. c.max) or "")
            end
            text[root .. "/log_window/currently_selected/event_chain_subview/counters_text"] = table.concat(lines, "\n")
            if #lines == 0 then
                hide.counters_label = true
            end
        end
    end
    local wi, wr = gui.layout(ctx.game_dir, db, FILE, "situation_log", ctx.screen, {
        texture_size = ctx.texture_size, loc = loc, hide = hide, text = text, sprites = sprites,
        positions = positions, sizes = sizes,
        actions = {
            [root] = "view_set:noop=",
            [root .. "/close"] = "view_close",
            -- goto: the galaxy over the entry's place (events.rs); track: the entry tracked or not
            -- (its dot in the list) [I: the map's tracking marker not drawn]
            [root .. "/goto"] = selected and selected.location and ("sitlog:focus:" .. selected.location) or nil,
            [root .. "/track"] = selected and ("view_set:track:" .. selected.kind .. ":" .. selected.key .. "="
                .. (state["track:" .. selected.kind .. ":" .. selected.key] and "" or "1")) or nil,
            [root .. "/tab_log"] = "view_set:tab=",
            [root .. "/tab_anomalies"] = "view_set:tab=anomalies",
            -- "Show First Contact": the first contact view (events.rs)
            [root .. "/log_window/currently_selected/first_contact_subview/view_site"] =
                selected and selected.kind == "first_contact" and ("fc:open:" .. selected.key) or nil,
        },
    })
    gui.merge(items, report, wi, wr)
    -- the selected entry's description, wrapped, as many lines as its box shows (its scrollbar
    -- not drawn)
    local dr = wr.rects[hw .. "/description"]
    if selected and dr then
        local desc = events.resolve(loc, selected.desc or "", selected.view)
        local lines, lh = events.wrap(loc, desc, "cg_16b", dr.w, db, db.textcolors.W or { 1, 1, 1 })
        local keep = {}
        for i = 1, math.min(#lines, math.floor(dr.h / lh)) do
            keep[i] = lines[i]
        end
        for _, it in ipairs(events.line_items(hw .. "/description", "cg_16b", keep, lh, dr.x, dr.y, dr.w)) do
            items[#items + 1] = it
            report.texts = report.texts + 1
        end
    end

    -- the list: a header per category, its entries under it
    local lr = wr.rects[root .. "/log_window/entries/entries"]
    if lr then
        local y = lr.y
        for ci, s in ipairs(shown) do
            local hp = "/sitlog/" .. ci
            local hpath = hp .. "/situation_log_entry"
            -- a click on a collapsible category's header folds it (the arrow's frame 1) or opens it
            local ck = "collapsed:" .. s.cat.key
            local collapsed = s.cat.collapsible and state[ck]
            local hi, hr = gui.layout(ctx.game_dir, db, FILE, "situation_log_entry", ctx.screen, {
                texture_size = ctx.texture_size, loc = loc, prefix = hp,
                parent = { x = lr.x, y = y, w = 0, h = 0 },
                hide = { selected = true, completed = true, tracked = true, subentries = true },
                -- the arrow of an expanded category (GFX_entry_expand frame 2)
                frames = { [hpath .. "/expand_button"] = collapsed and 1 or 2 },
                actions = { [hpath .. "/button"] = s.cat.collapsible and ("view_set:" .. ck .. "=" .. (collapsed and "" or "1")) or nil },
                sprites = { [hpath .. "/entry_icon"] = s.cat.icon },
                text = { [hpath .. "/name"] = s.cat.loc },
            })
            gui.merge(items, report, hi, hr)
            y = y + 39
            for ei, e in ipairs(collapsed and {} or s.members) do
                local ep = hp .. "/" .. ei
                local epath = ep .. "/situation_log_subentry"
                local is_sel = selected == e
                local pk = "pin:" .. e.kind .. ":" .. e.key
                local ehide = {
                    progressbar = true, cost_icon = true, completed = true, subentries = true,
                    tracked = not state["track:" .. e.kind .. ":" .. e.key] or nil,
                    situation_entry_icon_background = true, situation_entry_icon = true, situation_name = true,
                    situations_progress_subview = true, selected = not is_sel or nil,
                    -- the pin: not on the tutorials' entries [I: by the frame]
                    pin_button = s.cat.key == "tutorial" or nil,
                }
                local ei_items, ei_report = gui.layout(ctx.game_dir, db, FILE, "situation_log_subentry", ctx.screen, {
                    texture_size = ctx.texture_size, loc = loc, prefix = ep,
                    parent = { x = lr.x, y = y, w = 0, h = 0 },
                    hide = ehide,
                    sprites = { [epath .. "/entry_icon"] = e.icon, [epath .. "/pin_button"] = state[pk] and "GFX_button_pin_pinned" or nil },
                    text = { [epath .. "/name"] = e.name and require("render.names").format(loc, e.name) or e.title },
                    actions = {
                        [epath .. "/button"] = "view_set:selected=" .. e.kind .. ":" .. e.key,
                        -- the pin: to Priorities and back
                        [epath .. "/pin_button"] = "view_set:" .. pk .. "=" .. (state[pk] and "" or "1"),
                    },
                })
                gui.merge(items, report, ei_items, ei_report)
                y = y + 44
            end
            -- the next category 8 below its last entry [I: by the frame]
            y = y + 8
        end
    end
    return items, report
end

-- no side windows: Escape closes the view (its close button has the shortcut ESCAPE), its tab and
-- selection are not windows to close first (views.rs escape_keys)
M.escape_keys = {}

return M
