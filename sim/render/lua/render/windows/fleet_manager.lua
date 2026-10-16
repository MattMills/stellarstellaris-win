-- render/windows/fleet_manager.lua : the Fleet Manager, the left bar's view `fleet_manager`
-- (views.rs: one view at a time, as CInGameIdler::ToggleTopBarView): its data read with the
-- galaxy (render.windows.fleet_data), laid out by render.windows.fleet (docs/windows/fleet.md).
-- Opened from the left bar (`view:fleet_manager`, `open_view fleet_manager`) or by the fleet and
-- ship views' Fleet Manager buttons (fleetwin.rs: the view with its state).
--
--   state.fleet: the selected fleet (`view_set:fleet=ID`; else the first template's)
--   state.side:  "1": the side panel (the Build Queue) shown: opened on a fleet's template
--                (ShowFleetManagerView); from the left bar the game shows none [I: its frames]

local M = {}

function M.extract(game_dir)
    return require("render.windows.fleet_data").manager()
end

function M.build(ctx, data, state)
    data = data or { fleets = {} }
    local sel = state and tonumber(state.fleet)
    for _, f in ipairs(data.fleets or {}) do
        if f.id == sel then
            data.selected = sel
        end
    end
    data.side = state and state.side == "1" or false
    data.view = true
    return require("render.windows.fleet").build(ctx.game_dir, ctx.db, ctx.screen, ctx.texture_size, ctx.loc, { manager = data })
end

return M
