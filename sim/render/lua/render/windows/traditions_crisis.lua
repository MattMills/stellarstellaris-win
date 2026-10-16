-- render/windows/traditions_crisis.lua : the traditions view's Ambition tab (CCrisisView,
-- topbar_traditions_view.gui `crisis_window`; 4.5.2 Linux; docs/windows/research.md):
--
--   crisis.extract(cid) -> data or nil       the country's crisis progression (nil without one:
--                                            the tab disabled)
--   crisis.build(ctx, data, state, V, opts)  the window's fields in the view's layout opts
--   crisis.lists(ctx, data, state, r, plain, items)  its lists, after the view's layout
--
-- The country's progression is the save's `crisis_progression = { path = x level = y ...
-- objective = { } }` (CCrisisProgression::WriteMembers 0x2454460), made by the effect
-- `activate_crisis_progression` (the five crisis ascension perks). Its currency is the path's
-- `crisis_currency`, a resource of the country's stockpile. The levels and objectives come from
-- common/crisis_paths, crisis_levels, crisis_objectives and menace_perks. State: crisis_tab=effects
-- (Summary; else the objectives), obj_scroll=ROWS. (No `extract` of a view: part of traditions.)

local gui = require("render.gui")

local crisis = {}

local function unquote(s)
    return type(s) == "string" and (s:gsub('^"(.*)"$', "%1")) or s
end

-- the texts of a block's entries (`levels = { a b }`)
local function texts(block)
    local out = {}
    for _, e in ipairs(type(block) == "table" and block or {}) do
        if e.text then
            out[#out + 1] = unquote(e.text)
        end
    end
    return out
end

-- a block's entry `key = value` (its value node), or nil
local function entry(block, key)
    for _, e in ipairs(type(block) == "table" and block or {}) do
        if e.op and e.key and e.key.text == key then
            return e
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------------------------
-- the world

-- the value of a reward's `trigger:` or complex_trigger_modifier trigger for the country:
-- num_galaxy_systems (the galaxy's systems), count_playable_country (the countries of type
-- default [I: CCountry::IsPlayable]), count_galcom_member (the galactic community's members),
-- check_galaxy_setup_value (the galaxy setup's field: habitable_worlds_scale is `habitability`)
local function trigger_value(world, name, params)
    if name == "num_galaxy_systems" then
        return #world.all("galactic_object")
    elseif name == "count_playable_country" then
        local n = 0
        for _, id in ipairs(world.all("country")) do
            local c = world.object("country", id)
            if c and unquote(world.field(c, "type")) == "default" then
                n = n + 1
            end
        end
        return n
    elseif name == "count_galcom_member" then
        local ok, members = pcall(function()
            return require("engine.diplomacy").gc_members()
        end)
        return ok and type(members) == "table" and #members or 0
    elseif name == "check_galaxy_setup_value" then
        local setting = params and unquote(params.setting) or ""
        local key = setting == "habitable_worlds_scale" and "habitability" or setting
        local ok, r = pcall(require, "engine.script.runtime")
        local v = ok and r.galaxy_field and tonumber(r.galaxy_field(key)) or nil
        return v or 1
    end
    return 0
end

-- a crisis objective's reward for the country: the `reward` block's operations in their order
-- (CCrisisObjective::GetReward, a script value: base, add, mult, divide (a number or
-- `trigger:X`), complex_trigger_modifier { trigger parameters mode mult }, modifier { factor
-- <triggers> }, round, round_to, min, max)
local function reward_of(world, node, ctx, eval)
    if node.text then
        return tonumber(node.text) or 0
    end
    local function num(v)
        if not v.text then
            return 0
        end
        local t = v.text:match("^trigger:(.+)$")
        if t then
            return trigger_value(world, t)
        end
        local n = tonumber(v.text)
        if n == nil and eval and ctx then
            local ok, r = pcall(eval.value, v, ctx)
            n = ok and tonumber(r) or nil
        end
        return n or 0
    end
    local acc = 0
    for _, e in ipairs(node) do
        if e.op and e.key then
            local k = e.key.text
            if k == "base" or k == "value" then
                acc = num(e.value)
            elseif k == "add" then
                acc = acc + num(e.value)
            elseif k == "subtract" then
                acc = acc - num(e.value)
            elseif k == "mult" or k == "factor" then
                acc = acc * num(e.value)
            elseif k == "divide" then
                local d = num(e.value)
                if d ~= 0 then
                    acc = acc / d
                end
            elseif k == "min" then
                acc = math.max(acc, num(e.value))
            elseif k == "max" then
                acc = math.min(acc, num(e.value))
            elseif k == "round" and e.value.text == "yes" then
                acc = math.floor(acc + 0.5)
            elseif k == "round_to" then
                local r = num(e.value)
                if r > 0 then
                    acc = math.floor(acc / r + 0.5) * r
                end
            elseif k == "complex_trigger_modifier" and not e.value.text then
                local t, mode, mult, params = nil, "add", 1, {}
                for _, x in ipairs(e.value) do
                    if x.op and x.key then
                        if x.key.text == "trigger" then
                            t = x.value.text
                        elseif x.key.text == "mode" then
                            mode = x.value.text
                        elseif x.key.text == "mult" then
                            mult = tonumber(x.value.text) or 1
                        elseif x.key.text == "parameters" and not x.value.text then
                            for _, y in ipairs(x.value) do
                                if y.op and y.key then
                                    params[y.key.text] = y.value.text
                                end
                            end
                        end
                    end
                end
                local v = trigger_value(world, t or "", params) * mult
                if mode == "add" then
                    acc = acc + v
                elseif mode == "subtract" then
                    acc = acc - v
                elseif mode == "mult" or mode == "multiply" then
                    acc = acc * v
                elseif mode == "divide" and v ~= 0 then
                    acc = acc / v
                end
            elseif k == "modifier" and not e.value.text and eval and ctx then
                local ok, holds = pcall(eval.trigger, e.value, ctx)
                if ok and holds then
                    for _, x in ipairs(e.value) do
                        if x.op and x.key and (x.key.text == "factor" or x.key.text == "mult") then
                            acc = acc * num(x.value)
                        elseif x.op and x.key and x.key.text == "add" then
                            acc = acc + num(x.value)
                        end
                    end
                end
            end
        end
    end
    return acc
end

-- crisis.extract(cid) -> { path, currency, value, levels = { { key, required, unlocked, perks =
--   { { key, portrait, has } } } }, unlocked, progress, objectives = { { key, reward, recurring } } }
function crisis.extract(cid)
    local world = require("engine.world")
    local defs = require("engine.defs")
    local c = world.object("country", cid)
    local cp = c and world.field(c, "crisis_progression")
    if type(cp) ~= "table" then
        return nil
    end
    local path = unquote(world.field(cp, "path"))
    local pd = path and defs.get("common/crisis_paths", path)
    if not pd then
        return nil
    end
    local d = { path = path, levels = {}, objectives = {} }
    d.currency = unquote(defs.field(pd.block, "crisis_currency")) or "menace"
    -- CCountry::GetCrisisCurrency: the currency's stock
    local _, stock = require("render.topbar").values(cid)
    d.value = stock and tonumber(stock[d.currency]) or 0
    local has = {}
    for _, l in ipairs(world.fields(cp, "level")) do
        has[unquote(l)] = true
    end
    -- the path's levels in its order (UpdateLevels: an icon and an entry a level; a level's perks
    -- from common/crisis_levels, their portraits from common/menace_perks)
    for _, key in ipairs(texts(defs.field(pd.block, "levels"))) do
        local ld = defs.get("common/crisis_levels", key)
        local level = {
            key = key, unlocked = has[key] or false, perks = {},
            required = ld and tonumber(defs.field(ld.block, "required_crisis_currency")) or 0,
        }
        for _, p in ipairs(texts(ld and defs.field(ld.block, "perks"))) do
            local pdef = defs.get("common/menace_perks", p)
            level.perks[#level.perks + 1] = {
                key = p, has = level.unlocked, portrait = unquote(pdef and defs.field(pdef.block, "portrait")),
            }
        end
        d.levels[#d.levels + 1] = level
        if level.unlocked then
            d.unlocked = #d.levels
        end
    end
    -- GetNextCrisisLevelProgress: the currency over the next level's requirement, at most 1
    local next_level = d.levels[(d.unlocked or 0) + 1]
    if next_level then
        d.progress = next_level.required > 0 and math.min(1, d.value / next_level.required) or 1
    else
        d.progress = 0
    end
    -- GetAvailableCrisisObjectives: the path's objectives whose `potential` holds (the game keeps
    -- them in the progression, UpdateAvailableObjectives each day [I: the saved `objective`
    -- entries not read]); a reward is its script value for the country
    local ok, eval = pcall(require, "simscript.eval")
    for _, key in ipairs(texts(defs.field(pd.block, "objectives"))) do
        local od = defs.get("common/crisis_objectives", key)
        if od then
            local ctx = ok and eval.new_ctx(eval.S("country", cid), nil, nil, od.file) or nil
            local potential = entry(od.block, "potential")
            local shown = true
            if potential and ctx then
                local okt, r = pcall(eval.trigger, potential.value, ctx)
                shown = okt and r and true or false
            end
            if shown then
                local reward = entry(od.block, "reward")
                local value = reward and reward_of(world, reward.value, ctx, ok and eval or nil) or 0
                d.objectives[#d.objectives + 1] = {
                    key = key, reward = value or 0, recurring = defs.field(od.block, "recurring") == "yes",
                }
            end
        end
    end
    return d
end

-- ---------------------------------------------------------------------------------------------
-- the layout

local OBJ_ROW = 37   -- objectives_list_entry 35 + the list's spacing 2
local OBJ_ROWS = 10  -- the rows in the list's 368 (9 x 37 + 35)

-- a localised text with $VAR$ replaced ($VAR|C$: in colour C; $VAR|0$: a whole number)
local function format(loc, key, vars)
    local t = loc and loc.has(key) and loc.raw(key) or key
    return (t:gsub("%$([%w_]+)|?(%w*)%$", function(k, spec)
        local v = vars[k]
        if v == nil then
            return nil
        end
        if spec:match("^%d+$") then
            return string.format("%." .. spec .. "f", tonumber(v) or 0)
        end
        return spec ~= "" and ("\194\167" .. spec .. tostring(v) .. "\194\167!") or tostring(v)
    end))
end

-- crisis.build(ctx, data, state, V, rects): the window's sprites, texts, hidden elements and
-- actions put in the view's layout options (V: the view's path)
function crisis.build(ctx, data, state, V, rects)
    data = data or {}
    data.levels, data.objectives = data.levels or {}, data.objectives or {}
    local C = data.currency or "menace"
    local W = V .. "/crisis_window"
    local P = W .. "/progression_container"
    -- UpdatePathDependants: the path's sprites (SetSpriteFromCrisisPath: GFX_<path> + suffix)
    local gfx = "GFX_" .. (data.path or "nemesis_path")
    local function sprite(name)
        return ctx.db.sprites[name] and name or nil
    end
    rects.sprites[P .. "/bg"] = sprite(gfx .. "_bg")
    rects.sprites[P .. "/crisis_level_progressbar_box/crisis_level_progressbar_box_bg"] = sprite(gfx .. "_levels_frame")
    rects.sprites[W .. "/crisis_level_bar/crisis_title_box"] = sprite(gfx .. "_title_box")
    -- Update: the path's texts (C_name, C_value, C_crisis_*), the level's name
    local I = W .. "/information_box"
    local t = rects.text
    t[W .. "/crisis_level_bar/crisis_currency_container/crisis_currency_text"] = C .. "_name"
    t[W .. "/crisis_level_bar/crisis_currency_container/crisis_currency_value"] = format(ctx.loc, C .. "_value", { VAL = math.floor(data.value or 0) })
    local last = data.unlocked and data.levels[data.unlocked]
    t[W .. "/crisis_level_bar/crisis_level_number"] = last and last.key or ""
    t[I .. "/crisis_objectives_button"] = C .. "_crisis_objective"
    t[I .. "/objectives_box/objectives_header"] = C .. "_crisis_objective"
    t[I .. "/objectives_box/objectives_desc"] = C .. "_crisis_objective_gained"
    -- (the header has no maxWidth: the box's width)
    rects.sizes[I .. "/objectives_box/objectives_header"] = { 280, 20 }
    for _, k in ipairs({ "crisis_description_title", "crisis_description", "crisis_howto_title", "crisis_howto" }) do
        t[I .. "/effects_box/effects_descriptions/" .. k] = C .. "_" .. k
    end
    -- OnObjectives / OnEffects: one box shown (the objectives at first)
    local effects = state.crisis_tab == "effects"
    rects.hide[effects and "objectives_box" or "effects_box"] = true
    rects.actions[I .. "/crisis_objectives_button"] = "view_set:crisis_tab="
    rects.actions[I .. "/crisis_effects_button"] = "view_set:crisis_tab=effects"
    -- the bar is drawn here (a vertical bar, filled from the top: flipdirection)
    rects.hide.crisis_level_progressbar = true
end

-- crisis.lists(ctx, data, state, r, plain, items) lays out what the window's lists hold, after
-- the window (r: its report; plain(file, window, opts) -> report lays one out into items)
function crisis.lists(ctx, data, state, r, plain, items)
    data = data or {}
    local levels, objectives = data.levels or {}, data.objectives or {}
    local C = data.currency or "menace"
    local V = "/traditions_view/crisis_window"
    local P = V .. "/progression_container"
    local FILE = "interface/topbar_traditions_view.gui"
    -- UpdateLevelProgress: step = 100 / (levels - 1); the bar at step x (unlocked - 1) + step x
    -- the next level's progress (crisis_level_progressbar, 0..100)
    local box = r.rects[P .. "/crisis_level_progressbar_box"]
    local n = #levels
    if box and n > 1 then
        local step = 1 / (n - 1)
        local p = math.max(0, math.min(1, step * ((data.unlocked or 1) - 1) + step * (data.progress or 0)))
        local s = ctx.db.sprites["GFX_" .. (data.path or "nemesis_path") .. "_progressbar"] or ctx.db.sprites.GFX_nemesis_path_progressbar
        if s then
            local x, y, w, h = box.x + 29, box.y + 39, 10, 432
            local function quad(tex, y0, y1)
                if y1 <= y0 or not tex then
                    return
                end
                items[#items + 1] = { kind = "sprite", path = P .. "/clip", sprite = "", texture = "", sprite_kind = "clip", frame = 1, frames = 1, x = x, y = y0, w = w, h = y1 - y0 }
                items[#items + 1] = { kind = "sprite", path = P .. "/crisis_level_progressbar", sprite = "", texture = tex,
                    sprite_kind = "spriteType", frame = 1, frames = 1, x = x, y = y, w = w, h = h }
                items[#items + 1] = { kind = "sprite", path = P .. "/clip", sprite = "", texture = "", sprite_kind = "clip", frame = 1, frames = 1, x = 0, y = 0, w = 0, h = 0 }
            end
            local cut = math.floor(y + h * p + 0.5)
            quad(s.texture, y, cut)
            quad(s.texture2, cut, y + h)
        end
    end
    -- the level icons (crisis_level_icon_entry, 103 apart: frame 1 unlocked, 2 locked)
    local il = r.rects[P .. "/crisis_level_progressbar_box/crisis_level_icon_list"]
    for i, l in ipairs(levels) do
        if il then
            local p = "/crisis/icon/" .. i
            local E = p .. "/crisis_level_icon_entry"
            plain(FILE, "crisis_level_icon_entry", {
                prefix = p, parent = { x = il.x, y = il.y + 103 * (i - 1), w = 0, h = 0 },
                sprites = { [E .. "/level_icon"] = ctx.db.sprites["GFX_" .. l.key .. "_btn"] and ("GFX_" .. l.key .. "_btn") or nil },
                frames = { [E .. "/level_icon"] = l.unlocked and 1 or 2 },
            })
        end
    end
    -- the levels (level_list_entry, 100 apart): the path's boxes, the name and description, the
    -- perks in perks_grid (perk_grid_entry: the perk's portrait) [I: the frames, 1 unlocked]
    local ll = r.rects[P .. "/crisis_level_list_container/crisis_level_list"]
    for i, l in ipairs(levels) do
        if ll then
            local p = "/crisis/level/" .. i
            local E = p .. "/level_list_entry"
            local boxes = "GFX_" .. (data.path or "nemesis_path") .. "_level_boxes"
            local lr = plain(FILE, "level_list_entry", {
                prefix = p, parent = { x = ll.x, y = ll.y + 100 * (i - 1), w = 0, h = 0 },
                text = { [E .. "/level_name"] = l.key, [E .. "/level_description"] = l.key .. "_desc" },
                sprites = { [E .. "/level_entry_bg"] = ctx.db.sprites[boxes] and boxes or nil },
                frames = { [E .. "/level_entry_bg"] = l.unlocked and 2 or 1 },
            })
            local g = lr.grids and lr.grids[E .. "/perks_grid"]
            for k, perk in ipairs(l.perks or {}) do
                -- (grid_slot: the slot's place on the screen)
                local gx, gy
                if g then
                    gx, gy = gui.grid_slot(g, k - 1, #l.perks)
                end
                if gx then
                    local q = p .. "/perk/" .. k
                    local Q = q .. "/perk_grid_entry"
                    plain(FILE, "perk_grid_entry", {
                        prefix = q, parent = { x = gx, y = gy, w = 0, h = 0 },
                        sprites = { [Q .. "/perk_icon"] = perk.portrait and ctx.db.sprites[perk.portrait] and perk.portrait or nil },
                        frames = { [Q .. "/perk_icon"] = perk.has and 1 or 2 },
                    })
                end
            end
        end
    end
    -- the objectives (objectives_list_entry, 37 apart, the list's box cutting them): the name,
    -- the reward (C_crisis_objective_reward), the currency's icon, the recurring overlay
    local ol = state.crisis_tab ~= "effects" and r.rects[V .. "/information_box/objectives_box/objectives_list"]
    if ol then
        local scroll = math.max(0, math.min(tonumber(state.obj_scroll) or 0, #objectives - OBJ_ROWS))
        items[#items + 1] = { kind = "sprite", path = "/crisis/clip", sprite = "", texture = "", sprite_kind = "clip", frame = 1, frames = 1, x = ol.x, y = ol.y, w = ol.w, h = ol.h }
        for i, o in ipairs(objectives) do
            local row = i - 1 - scroll
            if row >= -1 and row <= OBJ_ROWS then
                local p = "/crisis/objective/" .. i
                local E = p .. "/objectives_list_entry"
                plain(FILE, "objectives_list_entry", {
                    prefix = p, parent = { x = ol.x, y = ol.y + OBJ_ROW * row, w = 0, h = 0 },
                    text = {
                        [E .. "/title"] = o.key .. "_name",
                        [E .. "/reward"] = format(ctx.loc, C .. "_crisis_objective_reward", { REWARD = math.floor((o.reward or 0) + 0.5) }),
                    },
                    sprites = { [E .. "/icon"] = ctx.db.sprites["GFX_resource_" .. C] and ("GFX_resource_" .. C) or nil },
                    hide = { recurring_overlay = not o.recurring or nil },
                })
            end
        end
        items[#items + 1] = { kind = "sprite", path = "/crisis/clip", sprite = "", texture = "", sprite_kind = "clip", frame = 1, frames = 1, x = 0, y = 0, w = 0, h = 0 }
    end
end

-- crisis.wheel(data, state, notches, x, y, rect) -> the action the wheel does over the
-- objectives (a row a notch), or nil
function crisis.wheel(data, state, notches, x, y, rect)
    if state.crisis_tab == "effects" or not rect then
        return nil
    end
    if x < rect.x or x > rect.x + rect.w or y < rect.y or y > rect.y + rect.h then
        return nil
    end
    local n = #((data or {}).objectives or {})
    local s = math.max(0, math.min((tonumber(state.obj_scroll) or 0) - notches, n - OBJ_ROWS))
    return "view_set:obj_scroll=" .. s
end

return crisis
