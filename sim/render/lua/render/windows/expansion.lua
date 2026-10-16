-- render/windows/market.lua : the galactic market (interface/market_view.gui), stub
local gui = require("render.gui")
local m = {}
function m.data(cid, state, game_dir)
    return { country = cid }
end
function m.build(game_dir, db, screen, texture_size, loc, data, state)
    return gui.layout(game_dir, db, "interface/expansion_planner_view.gui", "expansion_planner_view", screen, {
        texture_size = texture_size, loc = loc, 
        actions = { ["/expansion_planner_view/close"] = "close_view" },
    })
end
return m
