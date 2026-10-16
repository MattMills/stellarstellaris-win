-- render/windows/megastructure.lua : the megastructure window (interface/megastructure_view.gui
-- `megastructure_view`, CMegaStructureView; docs/windows/starbase.md), laid out with render.gui over
-- the values render.windows.starbase_data reads from the world (the chunk's `megastructures`).
--
--   require("render.windows.megastructure").build(ctx, id, items, report)
--
-- Clicks carry `starbase:mega_close` and `starbase:mega_focus` (sim/render/src/starbase.rs).

local gui = require("render.gui")
local names = require("render.names")
local starbase = require("render.windows.starbase")

local M = {}

local FILE = "interface/megastructure_view.gui"
local W = "/megastructure_view"

-- the window's megastructure (its id), its values
function M.entry(id)
    local data = starbase.data()
    return data and data.megastructures and data.megastructures[id]
end

function M.build(ctx, id, items, report)
    local e = M.entry(id)
    if not e then
        return
    end
    local loc = ctx.loc
    local state = RENDER_STARBASE_STATE or {}
    local own = e.owner == (tonumber(state.player) or -1)
    local hide, text, sprites, tints, actions, disabled = {}, {}, {}, {}, {}, {}

    -- the header (CMegaStructureView::UpdateHeader: the name, CMegaStructure::GetLocalizedName; the
    -- owner's flag, CGameGraphics::ApplyCountryToButton: the renderer puts the country's flag on it)
    text[W .. "/header/title"] = e.name and names.format(loc, e.name) or (loc and (loc.get(e.type)) or e.type)
    actions[W .. "/header/close"] = "starbase:mega_close"
    actions[W .. "/header/focus"] = "starbase:mega_focus"

    -- the tabs (UpdateSelectableTabs: the shipyard tab for a megastructure that builds ships, the
    -- overclocking tab with potential overclocks [I]: neither here): the main tab's _active button
    for _, n in ipairs({ "megastructure_tab", "shipyard_tab", "shipyard_tab_active", "overclocking_tab", "overclocking_tab_active" }) do
        hide[W .. "/tabs/" .. n] = true
    end
    hide[W .. "/shipyard_tab"] = true
    hide[W .. "/overclocking_tab"] = true
    -- the timer box shows an upgrade under way [I]: none here
    hide[W .. "/timer_box"] = true

    -- the main tab (SMainTab::Show / Update): the description (CMegaStructureType::GetDescription,
    -- "%s_DESC"), the portrait (the type's `portrait`); the effects, production and upkeep boxes
    -- hidden while they have nothing to say (the types' modifiers and economic tables [I]: not read
    -- here); Upgrade shown with a potential upgrade, Complete without one (Update: GetPotentialUpgrade),
    -- enabled with a valid CCountryUpgradeMegaStructureCommand [I]: its own's; Dismantle the same
    local tp = W .. "/megastructure_tab"
    text[tp .. "/desc"] = loc and (loc.get(e.type .. "_DESC")) or (e.type .. "_DESC")
    sprites[tp .. "/megastructure_portrait_window/megastructure_portrait"] = e.portrait
    for _, n in ipairs({ "effects_box", "production_box", "upkeep_box", "upgrading_content", "grand_archive_details",
        "dismantle_window", "scripted_action", "abort_dismantle" }) do
        hide[tp .. "/" .. n] = true
    end
    local can_upgrade = e.upgrade ~= nil and own
    hide[tp .. (can_upgrade and "/complete" or "/upgrade")] = true
    if not own then
        for _, n in ipairs({ "complete", "upgrade", "dismantle" }) do
            disabled[tp .. "/" .. n] = true
        end
    else
        -- OnUpgrade (CCountryUpgradeMegaStructureCommand), OnDismantle (its standard_dialog),
        -- OnAbortDismantle (CAbortDismantleMegastructureCommand): starbase_commands
        actions[tp .. "/upgrade"] = "starbase:cmd:mega_upgrade:" .. id
        actions[tp .. "/complete"] = "starbase:cmd:mega_upgrade:" .. id
        actions[tp .. "/dismantle"] = "starbase:dialog:mega_dismantle:" .. id
        actions[tp .. "/abort_dismantle"] = "starbase:cmd:mega_abort:" .. id
    end
    if e.dismantling then
        hide[tp .. "/dismantle"] = true
        hide[tp .. "/abort_dismantle"] = nil
        hide[tp .. "/dismantle_window"] = nil
    end

    local wi, wr = gui.layout(ctx.game_dir, ctx.db, FILE, "megastructure_view", ctx.screen, {
        texture_size = ctx.texture_size, loc = loc,
        hide = hide, text = text, sprites = sprites, tints = tints, disabled = disabled, actions = actions,
    })
    gui.merge(items, report, wi, wr)
    -- without an owner the header's flag is the null country's (GetOwner's null object, which
    -- ApplyCountryToButton leaves): its emblem flags/special/abandoned.dds ("Ø", the game's frame);
    -- an owner the player has no communications with, the unknown flag (CCountry::GetLocalEmpireFlag:
    -- flags/special/unknown.dds, "?"); each in the sprite's symbol place (symbol_position 12,
    -- symbol_size 46, at the button's scale) [I]
    local f = wr.rects[W .. "/header/flag"]
    local known = e.owner == (tonumber(state.player) or -1) or not state.known or state.known[e.owner]
    local emblem = e.owner == -1 and "flags/special/abandoned.dds" or (not known and "flags/special/unknown.dds") or nil
    if f and emblem then
        local k = f.w / 70
        items[#items + 1] = { kind = "sprite", path = W .. "/header/flag/emblem", sprite = "", texture = emblem,
            sprite_kind = "spriteType", frame = 1, frames = 1, x = f.x + 12 * k, y = f.y + 12 * k, w = 46 * k, h = 46 * k }
        report.sprites = report.sprites + 1
    end
end

-- the owner of the open megastructure (the renderer gives the header's flag its country) -> { id }
function M.owner(id)
    local e = M.entry(id)
    return e and { e.owner } or {}
end

return M
