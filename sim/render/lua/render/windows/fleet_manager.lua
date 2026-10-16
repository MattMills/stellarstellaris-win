-- render/windows/fleet_manager.lua : the Fleet Manager as a left bar view (win-research's view
-- mechanism, views.rs: `open_view fleet_manager`): its data read with the galaxy
-- (render.windows.fleet_data), laid out by render.windows.fleet (docs/windows/fleet.md). The
-- fleet windows' own route (fleetwin.rs: the fleet and ship views' Fleet Manager buttons, the left
-- bar's `view:fleet_manager`) lays out the same window.
--
--   state.fleet: the selected fleet (`view_set:fleet=ID`; else the first template's)

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
    -- opened from the left bar: no side panel (the game's frames); the view's actions; no derived
    -- textures (fleetwin.rs makes them): disabled buttons and bars drawn plain
    data.side, data.view = false, true
    return require("render.windows.fleet").build(ctx.game_dir, ctx.db, ctx.screen, ctx.texture_size, ctx.loc, { manager = data, plain = true })
end

return M
