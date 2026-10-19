-- render/windows/council.lua : the council view (interface/council_view.gui, CCouncilView;
-- docs/windows/empire.md section 5): the council room for the authority, the empire's name, the
-- ethics in the sidebar, the councillors in their slots (council_position_entry with a
-- paragon_portrait_container_council card; the ruler's paragon_portrait_container_ruler_council
-- in ruler_container), the current agenda and its progress, the launched agendas, the active
-- edicts and the edict fund; its tabs open the factions and the policies and edicts views.

local world = require("engine.world")
local C = require("render.windows.empire_common")
local leaders = require("render.windows.leaders_common")
local rename = require("render.windows.rename")

local M = {}

local FILE = "interface/council_view.gui"
local V = "/council_view"

function M.data(cid, state)
    local galaxy = require("render.galaxy")
    local c = world.object("country", cid)
    if not c then
        return {}
    end
    local gov = world.field(c, "government")
    local d = {
        name = galaxy.name_block(world.field(c, "name")),
        authority = C.strip(world.field(gov, "authority")),
        ethics = C.strings(world.path(c, "ethos", "ethics")),
        agenda = C.strip(world.field(gov, "council_agenda")),
        agenda_progress = tonumber(world.field(gov, "council_agenda_progress")) or 0,
        -- (the early launch's price: the empire's size, its unity)
        empire_size = tonumber(world.field(c, "empire_size")) or 0,
        unity = tonumber(world.path(c, "modules", "standard_economy_module", "resources", "unity")) or 0,
        positions = {},
        edicts = {},
        -- the DLCs the save names (meta.required_dlcs): has_paragon_dlc
        paragons = false,
    }
    for _, n in ipairs(C.strings(world.meta.required_dlcs)) do
        if n == "Galactic Paragons" then
            d.paragons = true
        end
    end
    -- what the agendas' potentials read
    d.facts = C.facts(world, c)
    -- the council positions in the government's order, each with its councillor
    for _, k in ipairs(world.list(world.field(gov, "council_positions"))) do
        local pos = leaders.council_position(tonumber(k))
        if pos then
            pos.leader_data = pos.leader and leaders.leader_data(pos.leader, c)
            d.positions[#d.positions + 1] = pos
        end
    end
    local ruler = tonumber(world.field(c, "ruler"))
    d.ruler = ruler and leaders.leader_data(ruler, c)
    for _, e in ipairs(world.blocks(world.field(c, "edicts"))) do
        d.edicts[#d.edicts + 1] = { edict = C.strip(world.field(e, "edict")), perpetual = world.field(e, "perpetual") == "yes" }
    end
    return d
end

-- the council room (COUNCIL_DYNAMIC_BACKGROUND, common/scripted_loc's GetScriptedCouncilBackground:
-- GFX_council_room_common without Galactic Paragons, else by the authority; _offset with an extra
-- council position) [I: the scripted loc's conditions read from the file, not evaluated]
local ROOMS = {
    auth_democratic = "GFX_council_room_democratic", auth_oligarchic = "GFX_council_room_oligarchic",
    auth_dictatorial = "GFX_council_room_dictatorial", auth_imperial = "GFX_council_room_imperial",
    auth_corporate = "GFX_council_room_corporate",
}

-- MAX_COUNCIL_POSITIONS slots, the government's positions after the ruler's placeholder, put in
-- the order of the table at @46d5520 { 4, 2, 0, 1, 3, 5 }: the ruler third
local ORDER = { 4, 2, 0, 1, 3, 5 }

-- the agendas the council can choose (CCouncilView::RefreshCouncilAgendaView: common/council_agendas
-- in database order, the current one left out): available (potential and allow hold) and
-- unavailable (potential only) [I: the order within a group]
function M.agendas(ctx, d)
    local avail, unavail = {}, {}
    for _, k in ipairs(C.def_order(ctx, "common/council_agendas")) do
        local a = C.defs(ctx, "common/council_agendas")[k]
        if k ~= d.agenda and C.trigger(C.raw_field(a, "potential") or {}, d.facts or {}) then
            if C.trigger(C.raw_field(a, "allow") or {}, d.facts or {}) then
                avail[#avail + 1] = k
            else
                unavail[#unavail + 1] = k
            end
        end
    end
    return avail, unavail
end

function M.build(ctx, d, state)
    d = d or {}
    -- (before the view's data has come, its frame alone: the data is nil until the snapshot
    -- carries it)
    if d.positions == nil then
        local b0 = C.builder(ctx)
        b0:add(FILE, "council_view", { only = { background = true, close = true, close_button = true, heading = true }, actions = { [V .. "/close_button"] = "view_close" } })
        return b0.items, b0.report
    end
    d.edicts = d.edicts or {}
    local b = C.builder(ctx)
    local hide = { choose_agenda_view = true, choose_council_slot_view = true, gestalt_councilor_positions_container = true,
        -- (the faction legitimacy shows with the pop factions' module [I: not for this save])
        faction_legitimacy_container = true }
    local text = { [V .. "/government_name"] = C.name(ctx, d.name) }
    local sprites, frames = {}, {}
    local room = d.paragons and ROOMS[d.authority or ""] or "GFX_council_room_common"
    if room and ctx.db.sprites[room] then
        sprites[V .. "/council_art_backdrop/council_background"] = room
    end
    -- the agenda (UpdateCurrentAgenda): its icon and name; launched early only when it can be
    if d.agenda then
        hide.no_agenda_selected_container = true
        sprites[V .. "/council_agenda_container/council_agenda_button_icon"] = "GFX_council_agenda_icon_" .. d.agenda
        text[V .. "/council_agenda_container/agenda_name"] = "council_agenda_" .. d.agenda .. "_name"
        -- launched when its progress has reached its cost (CGovernment::IsAgendaFinished:
        -- activate_council_agenda_button and its glow; CFinishAgendaCommand, the simulation's
        -- cmd:council:launch; CCouncilAgenda::GetCost: agenda_cost x (1 +
        -- EMPIRE_SIZE_COUNCIL_AGENDA_COST_PENALTY x the size over EMPIRE_SIZE_BASE)); early
        -- (early_activate_council_agenda_button: CEarlyFinishAgendaCommand, its cost the game rule
        -- council_agenda_early_activation_cost, render.windows.empire_commands.early_cost): enabled
        -- when the unity covers it
        local cost = C.number(ctx, "common/council_agendas", d.agenda, C.field(C.defs(ctx, "common/council_agendas")[d.agenda] or {}, "agenda_cost")) or 0
        if d.agenda_progress < cost or cost <= 0 then
            hide.activate_council_agenda_button = true
            hide.agenda_attention_glow = true
        end
    else
        hide.agenda_progress_bar = true
        hide.early_activate_council_agenda_button = true
    end
    hide.council_agenda_activation_effect_icon = true
    -- active edicts (PopulateActiveEdicts) and the fund (EDICT_UPKEEP_AND_FUND)
    if #d.edicts > 0 then
        hide.no_edicts_active_container = true
    end
    -- the agenda list (choose_agenda_view): its button opens and closes it
    -- (ToggleCouncilAgendaView), its close button (ESCAPE) closes it; an agenda's button chooses it
    -- (the simulation's command: cmd:council:agenda) and closes the list
    local agendas_open = state.agendas == "1"
    local actions = {
        [V .. "/council_agenda_container/council_agenda_button"] = "view_set:agendas=" .. (agendas_open and "" or "1"),
        [V .. "/choose_agenda_view/close_agenda_button"] = "view_set:agendas=",
        [V .. "/close_button"] = "view_close",
        [V .. "/council_agenda_container/activate_council_agenda_button"] = "cmd:council:launch",
        [V .. "/tab_factions"] = "view:factions",
        [V .. "/tab_edicts_and_policies"] = "view:edicts",
        [V .. "/active_edicts_container/no_edicts_active_container/no_active_edicts_button"] = "view:edicts",
    }
    text[V .. "/active_edicts_container/edict_fund"] = M.fund_text(ctx, d)
    if agendas_open then
        sprites[V .. "/council_agenda_container/council_agenda_button"] = "GFX_button_open_agendas_active"
    end
    local early_ok = false
    if d.agenda then
        local cost = C.number(ctx, "common/council_agendas", d.agenda, C.field(C.defs(ctx, "common/council_agendas")[d.agenda] or {}, "agenda_cost")) or 0
        local price = require("render.windows.empire_commands").early_cost(d.empire_size or 0, cost > 0 and d.agenda_progress / cost or 0)
        early_ok = price >= 0 and (d.unity or 0) >= price
        if early_ok then
            actions[V .. "/council_agenda_container/early_activate_council_agenda_button"] = "cmd:council:launch_early"
        end
    end
    local r = b:add(FILE, "council_view", { hide = hide, text = text, sprites = sprites, frames = frames, actions = actions,
        disabled = { [V .. "/council_agenda_container/early_activate_council_agenda_button"] = not early_ok or nil } })

    -- the sidebar's ethics (CListBoxItemEntry<CEthic>: object_icon), one under the other
    local box = r.rects[V .. "/council_sidebar_small/ethics"]
    if box then
        for i, e in ipairs(d.ethics or {}) do
            local prefix = "/council_ethics/" .. i
            b:add("interface/game_setup/species.gui", "object_icon", {
                prefix = prefix, parent = { x = box.x, y = box.y + (i - 1) * 34, w = 0, h = 0 },
                only = { icon = true },
                sprites = { [prefix .. "/object_icon/icon"] = "GFX_ethic" },
                textures = { [prefix .. "/object_icon/icon"] = "gfx/interface/icons/ethics/" .. e .. ".dds" },
            })
        end
    end

    -- the councillors: the grid's slots 198 apart from the moved content container (142, 110:
    -- council_view_original_council_grid_position; the grid at its y -30)
    local view = r.rects[V]
    local gx, gy = view.x + 142, view.y + 110 - 30
    local slots = { false }
    for _, p in ipairs(d.positions or {}) do
        slots[#slots + 1] = p
    end
    for k, idx in ipairs(ORDER) do
        local pos = slots[idx + 1]
        local x = gx + (k - 1) * 198
        if pos then
            local prefix = "/council_slots/" .. k
            local p = prefix .. "/council_position_entry/"
            local cdef = C.defs(ctx, "common/governments/councilors")[pos.type or ""]
            local icon = cdef and C.field(cdef, "icon")
            -- the position's name button (rename_council_position: CCouncilPositionRenameDialog)
            local ra = pos.leader_data and leaders.rename_actions(ctx, pos.leader_data).rename_leader_title
                or rename.open("position", pos.id, C.loc(ctx, pos.type or ""), C.loc(ctx, pos.type or ""), C.loc(ctx, pos.type or ""), false)
            b:add_named(FILE, "council_position_entry", {
                prefix = prefix, parent = { x = x, y = gy, w = 0, h = 0 },
                named = { actions = { rename_council_position = ra } },
                hide = { locked_container = true, unlock_slot_container = true },
                text = { [p .. "unlocked_container/council_position_name"] = pos.type or "" },
                sprites = icon and { [p .. "unlocked_container/council_position_icon"] = icon } or nil,
            })
            if pos.leader_data then
                leaders.card(ctx, b, "paragon_portrait_container_council", { x = x, y = gy, w = 188, h = 272 }, pos.leader_data,
                    { prefix = prefix .. "/card", hide = { "council_container" }, named_actions = leaders.rename_actions(ctx, pos.leader_data) })
            end
        end
    end
    local rc = r.rects[V .. "/portrait_clipping_container/council_moveable_content_container/ruler_container"]
    if d.ruler then
        local x = gx + 2 * 198
        leaders.card(ctx, b, "paragon_portrait_container_ruler_council", { x = x, y = gy, w = rc and rc.w or 200, h = 135 }, d.ruler,
            { prefix = "/council_ruler", named_actions = leaders.rename_actions(ctx, d.ruler) })
    end
    -- the agenda list over everything else of the view (its councillors' cards too)
    local ar = agendas_open and b:add(FILE, "council_view", { only = { choose_agenda_view = true }, hide = { [V .. "/background"] = true },
        actions = actions })
    local al = ar and ar.rects[V .. "/choose_agenda_view/agenda_list_window/agenda_list_box"]
    if al then
        -- the list's groups (council_agenda_collapsable_container, the game's frame): Available
        -- Agendas (potential and allow), Launched Agendas (finished, cooling down: none kept here),
        -- Unavailable Agendas (potential, not allow: their buttons disabled); each header collapses
        -- its group
        local avail, unavail = M.agendas(ctx, d)
        local y, bottom = al.y, al.y + al.h
        local groups = {
            { key = "AVAILABLE_AGENDAS", fold = "fold_avail", list = avail, ok = true },
            { key = "FINISHED_AGENDAS", fold = "fold_launched", list = {} },
            { key = "UNAVAILABLE_AGENDAS", fold = "fold_unavail", list = unavail },
        }
        for gi, g in ipairs(groups) do
            if y + 44 > bottom then
                break
            end
            local gp = "/council_agenda_groups/" .. gi
            local h = gp .. "/council_agenda_collapsable_container/"
            local folded = state[g.fold] == "1"
            b:add(FILE, "council_agenda_collapsable_container", {
                prefix = gp, parent = { x = al.x, y = y, w = 0, h = 0 },
                sizes = { [h .. "expand_button"] = { al.w, 44 }, [h .. "unexpand_button"] = { al.w, 44 } },
                hide = { item_gridbox = true, expand_button = not folded or nil, unexpand_button = folded or nil },
                text = { [h .. "expand_button"] = "       " .. C.loc(ctx, g.key), [h .. "unexpand_button"] = "       " .. C.loc(ctx, g.key) },
                actions = { [h .. "unexpand_button"] = "view_set:" .. g.fold .. "=1", [h .. "expand_button"] = "view_set:" .. g.fold .. "=" },
            })
            y = y + 44
            for i, k in ipairs(folded and {} or g.list) do
                if y + 105 > bottom then
                    break
                end
                local prefix = gp .. "/" .. i
                local p = prefix .. "/council_agenda_list_entry/"
                b:add(FILE, "council_agenda_list_entry", {
                    prefix = prefix, parent = { x = al.x, y = y, w = 0, h = 0 },
                    hide = { agenda_cooldown_bar = true },
                    sprites = { [p .. "icon"] = "GFX_council_agenda_icon_" .. k },
                    text = { [p .. "name"] = "council_agenda_" .. k .. "_name", [p .. "desc"] = "council_agenda_" .. k .. "_desc" },
                    actions = g.ok and { [p .. "agenda_selection_button"] = "cmd:council:agenda:" .. k .. "#agendas=" } or nil,
                    disabled = not g.ok and { [p .. "agenda_selection_button"] = true } or nil,
                })
                y = y + 105
            end
        end
    end
    -- the rename dialog over the view
    rename.build(b, ctx, "council", state, nil)
    return b.items, b.report
end

-- the edict fund's text: the active edicts' upkeep over the fund (§Y$UPKEEP$ / $FUND$§!); the
-- fund is the country's country_edict_fund_add modifiers' sum [I: only the static empire_base's
-- part is read here, the rest needs the modifier graph]
function M.fund_text(ctx, d)
    -- the active edicts' upkeep in unity (CCountry::CalcEdictUpkeepSum [I: its multipliers left out])
    local upkeep = 0
    local keys = {}
    for _, e in ipairs(d.edicts or {}) do
        keys[#keys + 1] = e.edict
    end
    for k in pairs(d.active or {}) do
        keys[#keys + 1] = k
    end
    for _, k in ipairs(keys) do
        local e = C.defs(ctx, "common/edicts")[k or ""]
        local res = e and C.raw_field(e, "resources")
        local up = res and C.raw_field(res, "upkeep")
        upkeep = upkeep + (C.number(ctx, "common/edicts", k, up and C.field(up, "unity")) or 0)
    end
    upkeep = math.floor(upkeep)
    local base = C.defs(ctx, "common/static_modifiers")["empire_base"]
    local fund = tonumber(base and C.field(base, "country_edict_fund_add")) or 0
    if d.fund then
        fund = d.fund
    end
    return C.raw(ctx, "EDICT_UPKEEP_AND_FUND"):gsub("%$UPKEEP%$", tostring(upkeep)):gsub("%$FUND%$", tostring(math.floor(fund)))
end


-- views.rs: the view's data, read where the galaxy is read (the save's world, or the
-- simulation's), for the player's country
function M.extract(game_dir)
    return M.data(require("render.topbar").player(), {})
end


-- its buttons' commands in the simulation (views.rs: `cmd:council:VERB:ARG...`, between days)
function M.command(...)
    return require("render.windows.empire_commands").run(...)
end

-- Escape (views.rs): the side windows in these state keys close first, else the view closes
M.escape_keys = { "agendas" }
rename.install(M, "council")

return M
