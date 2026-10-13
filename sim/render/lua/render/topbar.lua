-- render/topbar.lua : the main screen's top bar, from the game's GUI files, bound to the player's
-- country in the world.
--
--   local topbar = require("render.topbar")
--   local t = topbar.build(game_dir, db, { width = w, height = h }, texture_size)
--   t.items   -- sprites and texts laid out (render.gui)
--   t.values  -- element path -> { text, value, source } for what is bound to the save
--
-- The bar is the window `maingui` of interface/main.gui: its children `topbar` (the background),
-- `topbar_static` (the resource groups: an icon over an amount) and `time_window` (the date), and
-- the window `maingui_flag` (the shield decoration at the left). Which groups an empire shows is
-- decided by the game at run time; here a group whose resource is not in the country's stockpile
-- and that only some empires have (biomass, operational reserves) is hidden.

local world = require("engine.world")
local gui = require("render.gui")

local topbar = {}

-- topbar_static's groups whose amount is a stockpile: group -> resource
topbar.STOCKPILES = {
    tb_energy_group = "energy",
    tb_mineral_group = "minerals",
    tb_food_group = "food",
    tb_consumer_goods_group = "consumer_goods",
    tb_biomass_group = "biomass",
    tb_alloys_group = "alloys",
    tb_trade_group = "trade",
    tb_operational_reserves_group = "operational_reserves",
    tb_influence_group = "influence",
    tb_unity_group = "unity",
}
-- groups only some empires show
local OPTIONAL = { tb_biomass_group = true, tb_operational_reserves_group = true }
-- the basic and advanced resources; the rest of a stockpile is the strategic ones (tb_others_group)
local LISTED = {
    energy = true, minerals = true, food = true, consumer_goods = true, biomass = true, alloys = true,
    trade = true, operational_reserves = true, influence = true, unity = true,
    physics_research = true, society_research = true, engineering_research = true,
}

-- a stockpile as the bar shows it: whole units, thousands as K from 10000
function topbar.format(v)
    v = tonumber(v) or 0
    local a = math.abs(v)
    if a >= 1e6 then
        return string.format("%.1fM", v / 1e6)
    elseif a >= 1e4 then
        return string.format("%.1fK", v / 1e3)
    end
    return string.format("%d", v >= 0 and math.floor(v) or -math.floor(-v))
end

-- the player's country id (meta.player = { { name = "..." country = 0 } }), 0 if none
function topbar.player()
    local p = world.meta.player
    if type(p) == "table" then
        for _, b in ipairs(world.blocks(p)) do
            local c = tonumber(world.field(b, "country"))
            if c then
                return c
            end
        end
    end
    return 0
end

-- topbar.values(country_id) -> group -> { text, value, source }
function topbar.values(cid)
    local c = world.object("country", cid)
    local stock = world.path(c, "modules", "standard_economy_module", "resources")
    local res = {}
    for _, e in ipairs(type(stock) == "table" and stock or {}) do
        if e.op and e.key and e.value.text then
            res[e.key.text] = tonumber(e.value.text)
        end
    end
    local out = {}
    local function put(group, value, text, src)
        out[group] = { value = value, text = text or topbar.format(value), source = src }
    end
    for group, r in pairs(topbar.STOCKPILES) do
        if res[r] ~= nil or not OPTIONAL[group] then
            put(group, res[r] or 0, nil, "resources." .. r)
        end
    end
    local research = (res.physics_research or 0) + (res.society_research or 0) + (res.engineering_research or 0)
    put("tb_research_group", research, nil, "resources.physics_research + society_research + engineering_research")
    local strategic = 0
    for k, v in pairs(res) do
        if not LISTED[k] then
            strategic = strategic + v
        end
    end
    put("tb_others_group", strategic, nil, "resources (strategic)")
    put("empire_size_group", tonumber(world.field(c, "empire_size")) or 0, nil, "empire_size")
    local leaders = #world.list(world.path(c, "modules", "standard_leader_module", "leaders"))
    put("leaders_group", leaders, tostring(leaders), "standard_leader_module.leaders")
    local used, cap = tonumber(world.field(c, "starbase_capacity_used")) or 0, tonumber(world.field(c, "starbase_capacity")) or 0
    put("starbase_group", used, string.format("%d/%d", used, cap), "starbase_capacity_used/starbase_capacity")
    local navy = tonumber(world.field(c, "used_naval_capacity")) or 0
    put("navy_group", navy, topbar.format(navy), "used_naval_capacity")
    return out, res
end

-- topbar.build(game_dir, db, screen, texture_size) -> { items, report, values, country, date }
function topbar.build(game_dir, db, screen, texture_size)
    local cid = topbar.player()
    local values = topbar.values(cid)
    local text, hide = {}, {
        -- the speed controls show the paused state (a save is loaded paused)
        pause_bg = true, pause_glow = true, time_description = true,
        -- the government button carries the empire's flag, composed at run time
        button_topbar_government = true,
    }
    local bound = {}
    for group in pairs(topbar.STOCKPILES) do
        if not values[group] then
            hide["/maingui/topbar_static/" .. group] = true
        end
    end
    for group, v in pairs(values) do
        local path = "/maingui/topbar_static/" .. group .. "/amount"
        text[path] = v.text
        bound[path] = v
    end
    local date = tostring(world.meta.date or ""):gsub('"', "")
    text["/maingui/time_window/time"] = date
    bound["/maingui/time_window/time"] = { text = date, source = "date" }

    local opts = {
        only = { topbar = true, topbar_extended = true, topbar_static = true, time_window = true },
        hide = hide, text = text, texture_size = texture_size,
    }
    local items, report = gui.layout(game_dir, db, "interface/main.gui", "maingui", screen, opts)
    local flag_items, flag_report = gui.layout(game_dir, db, "interface/main.gui", "maingui_flag", screen,
        { hide = hide, text = {}, texture_size = texture_size })
    -- the flag window is drawn under the bar's sprites
    for i, it in ipairs(items) do
        flag_items[#flag_items + 1] = it
    end
    for _, m in ipairs(report.missing_sprites) do
        flag_report.missing_sprites[#flag_report.missing_sprites + 1] = m
    end
    flag_report.sprites = flag_report.sprites + report.sprites
    flag_report.texts = flag_report.texts + report.texts
    for k, n in pairs(report.skipped) do
        flag_report.skipped[k] = (flag_report.skipped[k] or 0) + n
    end
    return { items = flag_items, report = flag_report, values = bound, country = cid, date = date }
end

return topbar
