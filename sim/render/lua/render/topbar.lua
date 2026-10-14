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

-- a stockpile as the bar shows it: whole units below 1000, then thousands (K) and millions (M)
-- with one decimal, cut not rounded (the game's frame: 9084 "9.0K", 4855 "4.8K", 1479 "1.4K")
function topbar.format(v)
    v = tonumber(v) or 0
    local a = math.abs(v)
    local s = v < 0 and "-" or ""
    if a >= 1e6 then
        return string.format("%s%.1fM", s, math.floor(a / 1e5) / 10)
    elseif a >= 1e3 then
        return string.format("%s%.1fK", s, math.floor(a / 1e2) / 10)
    end
    return string.format("%s%d", s, math.floor(a))
end

-- a resource as the bar shows it: the stockpile, then the monthly income with its sign
function topbar.amount(value, income)
    if income == nil then
        return topbar.format(value)
    end
    local sign = income < 0 and "-" or "+"
    return topbar.format(value) .. " " .. sign .. topbar.format(math.abs(income))
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
    -- the monthly income: the budget's current_month.balance, summed over its categories
    local income = {}
    local bal = world.path(c, "budget", "current_month", "balance")
    for _, e in ipairs(type(bal) == "table" and bal or {}) do
        if e.op and e.key and type(e.value) == "table" and e.value.text == nil then
            for _, r in ipairs(e.value) do
                if r.op and r.key and r.value and r.value.text then
                    income[r.key.text] = (income[r.key.text] or 0) + (tonumber(r.value.text) or 0)
                end
            end
        end
    end
    topbar.income = income
    local out = {}
    local function put(group, value, text, src, inc)
        out[group] = { value = value, income = inc, text = text or topbar.amount(value, inc), source = src }
    end
    for group, r in pairs(topbar.STOCKPILES) do
        if res[r] ~= nil or not OPTIONAL[group] then
            put(group, res[r] or 0, nil, "resources." .. r, income[r] or 0)
        end
    end
    local research = (res.physics_research or 0) + (res.society_research or 0) + (res.engineering_research or 0)
    local research_income = (income.physics_research or 0) + (income.society_research or 0) + (income.engineering_research or 0)
    -- research has no stockpile: the bar shows its income alone ("+39")
    put("tb_research_group", research, (research_income < 0 and "-" or "+") .. topbar.format(math.abs(research_income)),
        "income: physics_research + society_research + engineering_research", research_income)
    local strategic, strategic_income = 0, 0
    for k, v in pairs(res) do
        if not LISTED[k] then
            strategic = strategic + v
            strategic_income = strategic_income + (income[k] or 0)
        end
    end
    put("tb_others_group", strategic, nil, "resources (strategic)", strategic_income)
    put("empire_size_group", tonumber(world.field(c, "empire_size")) or 0, nil, "empire_size")
    local leaders = #world.list(world.path(c, "modules", "standard_leader_module", "leaders"))
    put("leaders_group", leaders, tostring(leaders), "standard_leader_module.leaders")
    local used, cap = tonumber(world.field(c, "starbase_capacity_used")) or 0, tonumber(world.field(c, "starbase_capacity")) or 0
    put("starbase_group", used, string.format("%d/%d", used, cap), "starbase_capacity_used/starbase_capacity")
    local navy = tonumber(world.field(c, "used_naval_capacity")) or 0
    put("navy_group", navy, topbar.format(navy), "used_naval_capacity")
    return out, res
end

-- The time controls (main.gui time_window) by the clock's state (CMainGui::UpdateTimeWindow,
-- 4.5.2): paused, pause_bg_stop (GFX_topbar_paused) and pause_glow; running, pause_bg
-- (GFX_topbar_running); start_stop_icons' frame 1 the pause bars, 2..6 the speeds 1..5;
-- time_description GAME_SPEED_0 ("Paused") or the speed's name. Clicks (CMainGui::Setup):
-- start_stop_icons and the hitbox window pause or run the clock, increase_speed and
-- decrease_speed change the speed; pause_bg and pause_bg_stop take none.
local TW = "/maingui/time_window/"
topbar.TIME_ACTIONS = {
    [TW .. "hitbox"] = "pause", [TW .. "start_stop_icons"] = "pause",
    [TW .. "increase_speed"] = "speed_up", [TW .. "decrease_speed"] = "speed_down",
}

-- topbar.build(game_dir, db, screen, texture_size, state) -> { items, report, values, country, date }
--   state: { text = { [path] = text } (the amounts, from the simulation; else read from the
--            world), date, paused, speed }
function topbar.build(game_dir, db, screen, texture_size, state)
    state = state or {}
    local cid = topbar.player()
    local paused = state.paused ~= false
    local speed = math.max(1, math.min(5, tonumber(state.speed) or 3))
    local text, hide = {}, {
    }
    if paused then
        hide.pause_bg = true
    else
        hide.pause_bg_stop = true
        hide.pause_glow = true
    end
    -- the speed's name (localised by the caller: GAME_SPEED_0 .. 5); without it, not shown
    if state.speed_name then
        text[TW .. "time_description"] = state.speed_name
    else
        hide.time_description = true
    end
    local frames = { [TW .. "start_stop_icons"] = paused and 1 or speed + 1 }
    local bound = {}
    if state.text then
        for group in pairs(topbar.STOCKPILES) do
            if not state.text["/maingui/topbar_static/" .. group .. "/amount"] then
                hide["/maingui/topbar_static/" .. group] = true
            end
        end
        for path, t in pairs(state.text) do
            text[path] = t
            bound[path] = { text = t, source = "simulation" }
        end
    else
        local values = topbar.values(cid)
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
    end
    local date = state.date or tostring(world.meta.date or ""):gsub('"', "")
    text[TW .. "time"] = date
    bound[TW .. "time"] = { text = date, source = "date" }

    local opts = {
        only = { topbar = true, topbar_extended = true, topbar_static = true, time_window = true },
        hide = hide, text = text, texture_size = texture_size, frames = frames, actions = topbar.TIME_ACTIONS,
    }
    local items, report = gui.layout(game_dir, db, "interface/main.gui", "maingui", screen, opts)
    local flag_items, flag_report = gui.layout(game_dir, db, "interface/main.gui", "maingui_flag", screen,
        { hide = hide, text = {}, texture_size = texture_size })
    -- the flag window's decoration is drawn under the bar's sprites, the empire's flag over them
    -- (the game's frame)
    local flag_button
    for i = #flag_items, 1, -1 do
        if flag_items[i].path:find("button_topbar_government", 1, true) then
            flag_button = table.remove(flag_items, i)
        end
    end
    for i, it in ipairs(items) do
        flag_items[#flag_items + 1] = it
    end
    if flag_button then
        flag_items[#flag_items + 1] = flag_button
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
