-- render/windows/market.lua : the galactic market (interface/market_view.gui), stub
local gui = require("render.gui")
local market = {}
function market.data(cid, state, game_dir)
    return { country = cid }
end
function market.build(game_dir, db, screen, texture_size, loc, data, state)
    return gui.layout(game_dir, db, "interface/market_view.gui", "market_view", screen, {
        texture_size = texture_size, loc = loc, hide = { slave_market = true, tab_market = true, tab_slave_market_active = true },
        actions = { ["/market_view/close"] = "close_view" },
    })
end
return market
