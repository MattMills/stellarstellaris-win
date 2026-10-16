-- render/windows/waystation.lua : the waystation window (interface/waystation_view.gui
-- `waystation_view`, CWaystationView and CStarbaseWaystationTabController; docs/windows/starbase.md)
-- for a starbase whose type is a waystation (common/starbase_types `is_waystation = yes`: the game
-- shows this view instead of starbase_view), over the starbase chunk's values. No save at hand has
-- a waystation: the layout follows the files and the code, not a frame of the game.
--
--   require("render.windows.waystation").build(ctx, sel, e, items, report)

local gui = require("render.gui")
local names = require("render.names")
local starbase = require("render.windows.starbase")

local M = {}

local FILE = "interface/waystation_view.gui"
local W = "/waystation_view"

function M.build(ctx, sel, e, items, report)
    local loc = ctx.loc
    local state = RENDER_STARBASE_STATE or {}
    local own = e.owner == (tonumber(state.player) or -1)
    local h = ctx.screen.height >= 801 and 765 or 611
    local hide, text, sprites, tints, actions, disabled = {}, {}, {}, {}, {}, {}

    -- the header: as the starbase's (CAbstractStarbaseView)
    text[W .. "/name"] = starbase.fmt(loc, "STARBASE_NAME", { NAME = names.format(loc, e.name) })
    sprites[W .. "/planet_view_module_spaceport_portrait/spaceport_portrait_portrait"] = e.picture
    hide[W .. "/header_actions/previous_extra_shortcut"] = true
    actions[W .. "/header_actions/close"] = "close"
    actions[W .. "/header_actions/previous"] = "starbase:prev"
    actions[W .. "/header_actions/next"] = "starbase:next"
    actions[W .. "/header_actions/goto"] = "starbase:goto"
    -- one tab (CGuiButtonTabController<EWaystationsViewTabType, 1>): its _active button
    hide[W .. "/tabs/starbase_tab"] = true

    -- the portrait's boxes (CWaystationView::SetupSpecialized / UpdateSpecialized): the network's
    -- name (waystation_network_text, its connection icon), the stockpile's local and remote
    -- collection (shown while collected [I]: no collection here), the system's colonies, the owner
    local pp = W .. "/planet_view_module_spaceport_portrait"
    if e.network then
        text[pp .. "/waystation_network/waystation_network_text"] = names.format(loc, e.network)
        actions[pp .. "/waystation_network"] = "starbase:network_open:" .. tostring(e.network_id)
    else
        hide[pp .. "/waystation_network"] = true
    end
    hide[pp .. "/stockpile_local_collection"] = true
    hide[pp .. "/stockpile_remote_collection"] = true
    text[pp .. "/colonies_info/colonies_count"] = tostring(e.colonies or 0)
    -- the owner's box: hidden on the player's own (the game's frame), else its name and flag (the
    -- renderer puts the country's flag on it, M.flag_owner), the unknown flag without communications
    local known = own or not state.known or state.known[e.owner]
    M.flag_owner = (not own and known) and e.owner or nil
    if own then
        hide[pp .. "/owner"] = true
    end
    text[pp .. "/owner/name"] = e.owner_name and names.format(loc, e.owner_name) or ""
    text[pp .. "/owner/type"] = ""

    -- the tab (CStarbaseWaystationTabController::Update): the class (the abstract controller's), the
    -- cloaking row with First Contact (else empty_cloaking_replacement), the design for a designed
    -- size; no_intel_text without the player's waystation intel (NWaystationUtil::
    -- PlayerHasWaystationIntel: its own, else intel [I]: others' are shown without it), else
    -- waystation_info: the stockpile (status, list), the modules, the modifiers' text, the queue
    local tp = W .. "/starbase_tab"
    text[tp .. "/class_info/current_class_name"] = loc and (loc.get(e.size)) or e.size
    if not e.next_size then
        hide[tp .. "/class_info/upgrade"] = true
    elseif not (own and e.upgrade_ok) then
        disabled[tp .. "/class_info/upgrade"] = true
    end
    if not own then
        disabled[tp .. "/class_info/details"] = true
        disabled[tp .. "/class_info/dismantle"] = true
    end
    if e.first_contact then
        hide[tp .. "/empty_cloaking_replacement"] = true
        sprites[tp .. "/cloaking_info/cloaking_level"] = "GFX_cloaking_level_" .. tostring(e.detection or 0)
    else
        hide[tp .. "/cloaking_info"] = true
    end
    if e.uses_design then
        text[tp .. "/design_info/design_name"] = e.design and names.format(loc, e.design) or ""
    else
        hide[tp .. "/design_info"] = true
    end
    local intel = own
    if intel then
        hide[tp .. "/no_intel_text"] = true
    else
        hide[tp .. "/waystation_info"] = true
    end
    text[tp .. "/waystation_info/stockpile_info/stockpile_status"] = ""
    hide[tp .. "/waystation_info/stockpile_info/stockpile_status_progressbar"] = true
    text[tp .. "/waystation_info/starbase_modifiers_info/modifiers_text"] = ""

    local wi, wr = gui.layout(ctx.game_dir, ctx.db, FILE, "waystation_view", ctx.screen, {
        texture_size = ctx.texture_size, loc = loc,
        sizes = { [W] = { 562, h } },
        hide = hide, text = text, sprites = sprites, tints = tints, disabled = disabled, actions = actions,
    })
    gui.merge(items, report, wi, wr)
    -- an unmet owner's flag: flags/special/unknown.dds in the sprite's symbol place (as the
    -- megastructure window's; GFX_empire_flag_64's symbol_position 12, symbol_size 46) [I]
    local f = wr.rects[pp .. "/owner/flag"]
    if f and not own and not known then
        local k = f.w / 70
        items[#items + 1] = { kind = "sprite", path = pp .. "/owner/flag/emblem", sprite = "", texture = "flags/special/unknown.dds",
            sprite_kind = "spriteType", frame = 1, frames = 1, x = f.x + 12 * k, y = f.y + 12 * k, w = 46 * k, h = 46 * k }
        report.sprites = report.sprites + 1
    end
    if intel then
        starbase.grids(ctx, items, report, wr.rects, e, tp .. "/waystation_info/upgrades_info/modules_info/modules_grid", nil)
        starbase.queue(ctx, items, report, wr.rects[tp .. "/waystation_info/build_queue_info/build_queue_list"], e, own)
    end
end

return M
