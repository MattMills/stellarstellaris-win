-- render/windows/council.lua : the council view (interface/council_view.gui, CCouncilView;
-- docs/windows/empire.md section 5): the council room for the authority, the empire's name, the
-- ethics in the sidebar, the councillors in their slots (council_position_entry with a
-- paragon_portrait_container_council card; the ruler's paragon_portrait_container_ruler_council
-- in ruler_container), the current agenda and its progress, the launched agendas, the active
-- edicts and the edict fund; its tabs open the factions and the policies and edicts views.

local world = require("engine.world")
local C = require("render.windows.empire_common")
local leaders = require("render.windows.leaders_common")

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

function M.build(ctx, d, state)
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
        -- launching early is not possible here: the button disabled (its 4th frame, the
        -- buttonstate_onlydisable effect's) [I]
        frames[V .. "/council_agenda_container/early_activate_council_agenda_button"] = 4
        hide.activate_council_agenda_button = true
        hide.agenda_attention_glow = true
    else
        hide.agenda_progress_bar = true
    end
    hide.council_agenda_activation_effect_icon = true
    -- active edicts (PopulateActiveEdicts) and the fund (EDICT_UPKEEP_AND_FUND)
    if #d.edicts > 0 then
        hide.no_edicts_active_container = true
    end
    local actions = {
        [V .. "/close_button"] = "view_close",
        [V .. "/tab_factions"] = "view:factions",
        [V .. "/tab_edicts_and_policies"] = "view:edicts",
        [V .. "/active_edicts_container/no_edicts_active_container/no_active_edicts_button"] = "view:edicts",
    }
    text[V .. "/active_edicts_container/edict_fund"] = M.fund_text(ctx, d)
    local r = b:add(FILE, "council_view", { hide = hide, text = text, sprites = sprites, frames = frames, actions = actions })

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
            b:add(FILE, "council_position_entry", {
                prefix = prefix, parent = { x = x, y = gy, w = 0, h = 0 },
                hide = { locked_container = true, unlock_slot_container = true },
                text = { [p .. "unlocked_container/council_position_name"] = pos.type or "" },
                sprites = icon and { [p .. "unlocked_container/council_position_icon"] = icon } or nil,
            })
            if pos.leader_data then
                leaders.card(ctx, b, "paragon_portrait_container_council", { x = x, y = gy, w = 188, h = 272 }, pos.leader_data,
                    { prefix = prefix .. "/card", hide = { "council_container" } })
            end
        end
    end
    local rc = r.rects[V .. "/portrait_clipping_container/council_moveable_content_container/ruler_container"]
    if d.ruler then
        local x = gx + 2 * 198
        leaders.card(ctx, b, "paragon_portrait_container_ruler_council", { x = x, y = gy, w = rc and rc.w or 200, h = 135 }, d.ruler,
            { prefix = "/council_ruler" })
    end
    return b.items, b.report
end

-- the edict fund's text: the active edicts' upkeep over the fund (§Y$UPKEEP$ / $FUND$§!); the
-- fund is the country's country_edict_fund_add modifiers' sum [I: only the static empire_base's
-- part is read here, the rest needs the modifier graph]
function M.fund_text(ctx, d)
    local upkeep = 0
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

return M
