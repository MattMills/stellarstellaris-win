-- render/windows/technology.lua : the research view (interface/technology_view.gui,
-- `technology_view_window`), as CTechnologyView fills it (4.5.2 Linux; docs/windows/research.md):
--
--   technology.extract(game_dir) -> data    the player's research: per area its queue's first
--                                           technology and progress, the offered technologies,
--                                           auto research, the efficiency; the head of research;
--                                           the researched technologies
--   technology.build(ctx, data, state)      the view laid out (render.gui); state.select = the
--                                           area whose select_window is open, state.researched =
--                                           the area of the researched_window
--
-- The three areas (technology_view_area_window, Physics, Society, Engineering down the grid):
-- with a technology in the area's queue its card (`research`: the technology, its progress
-- "123/456", the bar, the months left), else `choose` (Select Research). Select opens
-- select_window with the area's alternatives (technology_view_tech_entry_window each);
-- Researched opens researched_window (one technology_view_tech_researched_entry_window per level,
-- newest first). Not drawn: the cards' unlock lists, the leader's portrait.

local gui = require("render.gui")
local source = require("stellar.script.source")
local get = require("render.gfx").get

local technology = {}

local FILE = "interface/technology_view.gui"
local AREAS = { "physics", "society", "engineering" }   -- ETechArea 0, 1, 2: the grid's order
local AREA_INDEX = { physics = 1, society = 2, engineering = 3 }

local function unquote(s)
    return type(s) == "string" and (s:gsub('^"(.*)"$', "%1")) or s
end

-- ---------------------------------------------------------------------------------------------
-- the world

local function field(block, key)
    for _, e in ipairs(type(block) == "table" and block or {}) do
        if e.op and e.key and e.key.text == key then
            return e.value.text or e.value
        end
    end
    return nil
end

-- technology.extract(game_dir) -> {
--   areas = { { area, queue = { { tech, progress } ... }, alternatives = { tech ... },
--               auto, efficiency, monthly } x 3 },
--   costs = { [tech] = cost }, stored = { [tech] = points }, always = tech,
--   researched = { { tech, level } ... } (tech_status's order), head = { name, level } | nil,
--   galaxy = { tech_cost, difficulty, tech_scaling } }
function technology.extract(game_dir)
    local world = require("engine.world")
    local cid = require("render.topbar").player()
    local c = world.object("country", cid)
    local status = c and world.field(c, "tech_status")
    if type(status) ~= "table" then
        return nil
    end
    local okr, research = pcall(require, "engine.research")
    if not okr then
        research = nil
    end
    local d = { areas = {}, costs = {}, stored = {}, researched = {} }
    local function cost_of(tech)
        if research and d.costs[tech] == nil then
            local ok, v = pcall(research.cost, cid, tech)
            d.costs[tech] = ok and v or false
        end
    end
    -- the researched technologies: `technology = name` then its `level`
    local cur
    for _, e in ipairs(status) do
        if e.op and e.key then
            if e.key.text == "technology" then
                cur = unquote(e.value.text)
            elseif e.key.text == "level" and cur then
                d.researched[#d.researched + 1] = { tech = cur, level = tonumber(e.value.text) or 1 }
                cur = nil
            end
        end
    end
    local alternatives = field(status, "alternatives")
    for i, area in ipairs(AREAS) do
        local a = { area = area, queue = {}, alternatives = {}, auto = field(status, "auto_researching_" .. area) == "yes" }
        local queue = field(status, area .. "_queue")
        for _, item in ipairs(type(queue) == "table" and world.blocks(queue) or {}) do
            if type(item) == "table" then
                local tech = unquote(field(item, "technology"))
                if tech then
                    a.queue[#a.queue + 1] = { tech = tech, progress = tonumber(field(item, "progress")) or 0 }
                    cost_of(tech)
                end
            end
        end
        for _, t in ipairs(world.list(field(alternatives, area))) do
            a.alternatives[#a.alternatives + 1] = unquote(t)
            cost_of(unquote(t))
        end
        if research then
            local first = a.queue[1] and research.tech(a.queue[1].tech)
            local ok, e = pcall(research.efficiency, cid, area, first)
            a.efficiency = ok and e or nil
            local okm, m = pcall(research.month, cid, area)
            a.monthly = okm and m or nil
        end
        d.areas[i] = a
    end
    for _, e in ipairs(type(field(status, "stored_techpoints_for_tech")) == "table" and field(status, "stored_techpoints_for_tech") or {}) do
        if e.op and e.key then
            d.stored[e.key.text] = tonumber(e.value.text) or 0
        end
    end
    d.always = unquote(field(status, "always_available_tech"))
    -- the areas' stored points (stored_techpoints = { physics society engineering })
    local stored = field(status, "stored_techpoints")
    for i, v in ipairs(type(stored) == "table" and world.list(stored) or {}) do
        if d.areas[i] then
            d.areas[i].stored = tonumber(v)
        end
    end
    -- the head of research (CGovernment::GetHeadScientist): the leader of the country's council
    -- position of COUNCIL_RESEARCH_POSITIONS
    local research_positions = { councilor_gestalt_cognitive = true, councilor_research = true, councilor_research_nomadic = true }
    for _, id in ipairs(world.all("council_positions")) do
        local p = world.object("council_positions", id)
        if p and tonumber(world.field(p, "country")) == cid and research_positions[unquote(world.field(p, "type")) or ""] then
            local leader = world.object("leader", tonumber(world.field(p, "leader")) or -1)
            if leader then
                local galaxy = require("render.galaxy")
                -- its name: `name = { full_names = { key = "%LEADER_2%" variables ... } }`
                local name = world.field(leader, "name")
                d.head = {
                    name = galaxy.name_block(world.field(name, "full_names") or name),
                    level = tonumber(world.field(leader, "level")) or 1,
                    position = unquote(world.field(p, "type")),
                }
            end
        end
    end
    -- the galaxy's settings (the base cost's fallback without the simulation's definitions)
    for _, e in ipairs(world.tree or {}) do
        if e.op and e.key and e.key.text == "galaxy" and e.value.text == nil then
            local g = e.value
            d.galaxy = {
                tech_cost = tonumber(world.field(g, "technology")) or 1,
                difficulty = unquote(world.field(g, "difficulty")),
                tech_scaling = unquote(world.field(g, "technology_difficulty_scale")),
            }
        end
    end
    d.empire_size = tonumber(world.field(c, "empire_size")) or 0
    return d
end

-- ---------------------------------------------------------------------------------------------
-- the game's files: the technologies (common/technology), their categories, scripted variables

local files
local function definitions(game_dir)
    if files then
        return files
    end
    files = { techs = {}, categories = {}, vars = {}, councilors = {} }
    -- the council positions' icons (common/governments/councilors `icon`)
    for key, def in pairs(source.definitions(game_dir, "common/governments/councilors")) do
        files.councilors[key] = unquote(get(def.block, "icon"))
    end
    for _, f in ipairs(source.files(game_dir, "common/scripted_variables", "txt")) do
        for _, e in ipairs(source.parse(game_dir, f) or {}) do
            if e.op and e.key and e.key.text:sub(1, 1) == "@" and e.value.text then
                files.vars[e.key.text] = tonumber(e.value.text)
            end
        end
    end
    for key, def in pairs(source.definitions(game_dir, "common/technology/category")) do
        files.categories[key] = unquote(get(def.block, "icon"))
    end
    for key, def in pairs(source.definitions(game_dir, "common/technology")) do
        local b = def.block
        local cats = {}
        for _, e in ipairs(type(get(b, "category")) == "table" and get(b, "category") or {}) do
            if e.text then
                cats[#cats + 1] = unquote(e.text)
            end
        end
        local cost = get(b, "cost")
        if type(cost) == "table" then
            cost = get(cost, "factor") or get(cost, "base")
        end
        files.techs[key] = {
            area = get(b, "area"), tier = tonumber(get(b, "tier")) or 0, categories = cats,
            rare = get(b, "is_rare") == "yes", dangerous = get(b, "is_dangerous") == "yes",
            insight = get(b, "is_insight") == "yes", start = get(b, "start_tech") == "yes",
            gateway = get(b, "gateway") ~= nil, icon = unquote(get(b, "icon")),
            cost = cost, levels = tonumber(get(b, "levels")),
        }
    end
    return files
end

local DIFFICULTY = { civilian = 0, cadet = 1, ensign = 2, captain = 3, commodore = 4, admiral = 5, grand_admiral = 6 }
local TECH_SCALING = { scaling_off = 0, scaling_low = 1, scaling_normal = 2, scaling_high = 3, scaling_extreme = 4 }

-- a technology's cost: the simulation's (research.cost), else its base cost with the difficulty's
-- scaling and the galaxy's setting [I: the modifiers and the empire size penalty not applied]
local function cost_of(defs, data, tech)
    local c = data.costs and data.costs[tech]
    if c then
        return c
    end
    local t = defs.techs[tech]
    if not t then
        return 0
    end
    local base = tonumber(t.cost) or defs.vars[t.cost or ""] or 0
    local g = data.galaxy or {}
    local scale = 0.025 * t.tier * (DIFFICULTY[g.difficulty or ""] or 2) * (TECH_SCALING[g.tech_scaling or ""] or 2)
    return math.floor(base * (1 + scale) + 0.5) * (g.tech_cost or 1)
end

-- an engine-named texture as a sprite (the technologies' and categories' icons have no .gfx
-- entry: CTechnology::GetIcon, an instant sprite over a template sprite's settings)
local function icon_sprite(db, name, texture)
    if texture and not db.sprites[name] then
        db.sprites[name] = { kind = "spriteType", texture = texture, frames = 1 }
    end
    return db.sprites[name] and name or nil
end

local function tech_icon(db, defs, tech)
    local t = defs.techs[tech] or {}
    local path = t.icon and ("gfx/interface/icons/technologies/" .. t.icon .. ".dds")
        or ("gfx/interface/icons/technologies/" .. tech .. ".dds")
    return icon_sprite(db, "GFX_render_tech_" .. tech, path)
end

local function category_icon(db, defs, tech)
    local t = defs.techs[tech]
    local cat = t and t.categories[1]
    local path = cat and defs.categories[cat]
    return path and icon_sprite(db, "GFX_render_tech_category_" .. cat, path)
end

-- CTechEntryWindowUpdate: the card's background by the technology's flags, first match
local function option_bg(defs, tech)
    local t = defs.techs[tech] or {}
    if t.dangerous and t.rare then
        return "GFX_tech_entry_dangerous_rare_bg"
    elseif t.dangerous then
        return "GFX_tech_entry_dangerous_bg"
    elseif t.rare then
        return "GFX_tech_entry_rare_bg"
    elseif t.insight then
        return "GFX_tech_entry_insight_bg"
    end
    return "GFX_tech_entry_" .. (t.area or "physics") .. "_bg"
end

-- a localised text with its $VAR$ (and $VAR|C$, in colour C) replaced
local function format(loc, key, vars)
    local t = loc and loc.has(key) and loc.raw(key) or key
    return (t:gsub("%$([%w_]+)|?(%w*)%$", function(k, colour)
        local v = vars[k]
        if v == nil then
            return nil
        end
        if loc and type(v) == "string" and loc.has(v) then
            v = loc.get(v)
        end
        return colour ~= "" and ("\194\167" .. colour .. tostring(v) .. "\194\167!") or tostring(v)
    end))
end

local function whole(v)
    return string.format("%d", math.floor((tonumber(v) or 0) + 0.5))
end

-- a technology's name: its key, a repeatable's with its level [I: the suffix's format]
local function tech_name(loc, defs, tech, level)
    local t = defs.techs[tech]
    local name = loc and loc.has(tech) and loc.get(tech) or tech
    if t and t.levels and t.levels ~= 1 and level then
        name = name .. " " .. level
    end
    return name
end

-- ---------------------------------------------------------------------------------------------
-- the layout

-- a sprite's frame size: a button with a plain sprite is drawn at it whatever its `size` (the
-- game's frames: the tech view's Select Research 411 x 58 where `size` says 411 x 85, the
-- traditions' Select at its sprite's width, not 298) [V: frames; the rule I]
local function native(ctx, name)
    local s = ctx.db.sprites[name]
    local w, h = s and s.texture and ctx.texture_size(s.texture)
    if not w then
        return nil
    end
    return w / math.max(1, s.frames or 1), h
end
technology.native = native

-- the shared card (CTechEntryWindowUpdate::UpdateEntry) for a window's path `W`
local function card(opts, defs, ctx, W, tech, level)
    local t = defs.techs[tech] or {}
    opts.sprites[W .. "/tech_option_bg"] = option_bg(defs, tech)
    local icon = tech_icon(ctx.db, defs, tech)
    if icon then
        opts.sprites[W .. "/icon"] = icon
    else
        opts.hide[W .. "/icon"] = true
    end
    local cat = category_icon(ctx.db, defs, tech)
    if cat then
        opts.sprites[W .. "/category_icon"] = cat
    else
        opts.hide[W .. "/category_icon"] = true
    end
    opts.text[W .. "/name"] = tech_name(ctx.loc, defs, tech, level)
    if not t.dangerous then
        opts.hide[W .. "/risk_icon"] = true
    end
end

-- technology.build(ctx, data, state) -> items, report
function technology.build(ctx, data, state)
    local defs = definitions(ctx.game_dir)
    data = data or { areas = {}, researched = {} }
    state = state or {}
    local items = {}
    local report = { sprites = 0, texts = 0, missing_sprites = {}, skipped = {}, rects = {} }
    local function layout(window, opts)
        opts.texture_size, opts.loc = ctx.texture_size, ctx.loc
        local i, r = gui.layout(ctx.game_dir, ctx.db, FILE, window, ctx.screen, opts)
        gui.merge(items, report, i, r)
        return r
    end

    -- the window (Reload: select_window and researched_window hidden until opened)
    local V = "/technology_view_window"
    local hide = { select_window = not state.select or nil, researched_window = not state.researched or nil }
    local text, actions = {}, {
        [V .. "/close"] = "view_close",
        [V .. "/researched"] = "view_set:select=;researched=" .. (state.researched and "" or (state.select or "physics")),
        [V .. "/select_window/close"] = "view_set:select=",
        [V .. "/researched_window/close"] = "view_set:researched=",
    }
    local sel_area = state.select and AREA_INDEX[state.select]
    if sel_area then
        text[V .. "/select_window/header"] = format(ctx.loc, "SELECT_TECHNOLOGY", { AREA = state.select:upper() })
        text[V .. "/select_window/desc"] = format(ctx.loc, "SELECT_TECHNOLOGY_DESC", { NUM = 3 })
    end
    local res_area = state.researched and AREA_INDEX[state.researched]
    if res_area then
        text[V .. "/researched_window/header"] = format(ctx.loc, "RESARCHED_TECHNOLOGY", { AREA = state.researched:upper() })
        -- UpdateTabVisibility: the area's tab active, the others inactive
        for _, a in ipairs(AREAS) do
            hide[(a == state.researched) and ("tab_" .. a) or ("tab_" .. a .. "_active")] = true
            actions[V .. "/researched_window/tab_" .. a] = "view_set:select=;researched=" .. a
        end
    end
    -- UpdatePopOutButtonStates: Researched active while its window shows
    -- (NGuiUtil::SetButtonActive: the frame 4 x active - 1, 3)
    local frames = { [V .. "/researched"] = state.researched and 3 or nil }
    local r = layout("technology_view_window", { hide = hide, text = text, actions = actions, frames = frames })
    -- the description's lines (SELECT_TECHNOLOGY_DESC has "\n"s), 17 apart [I: measured]
    for i = #items, 1, -1 do
        local it = items[i]
        if it.kind == "text" and it.text:find("\n", 1, true) then
            table.remove(items, i)
            local lines, line = {}, {}
            for _, s in ipairs(it.spans) do
                local parts = {}
                for p in (s.text .. "\n"):gmatch("(.-)\n") do
                    parts[#parts + 1] = p
                end
                for k, p in ipairs(parts) do
                    if k > 1 then
                        lines[#lines + 1], line = line, {}
                    end
                    if p ~= "" then
                        line[#line + 1] = { text = p, colour = s.colour }
                    end
                end
            end
            lines[#lines + 1] = line
            for k, spans in ipairs(lines) do
                local plain = {}
                for _, s in ipairs(spans) do
                    plain[#plain + 1] = s.text
                end
                local copy = {}
                for key, v in pairs(it) do
                    copy[key] = v
                end
                copy.path, copy.spans, copy.text = it.path .. "/" .. k, spans, table.concat(plain)
                copy.y, copy.h, copy.valign = it.y + 17 * (k - 1), 17, "top"
                table.insert(items, i + k - 1, copy)
            end
        end
    end

    -- the head of research (paragon_portrait_container_research in research_container): its
    -- background, the council position's icon, the leader's name and the position's title
    local slot = r.rects[V .. "/research_container"]
    if slot then
        local P = "/head/paragon_portrait_container_research"
        local head = data.head
        local name = head and head.name and require("render.names").format(ctx.loc, head.name) or ""
        local ok, hi, hr = pcall(gui.layout, ctx.game_dir, ctx.db, "interface/paragon_ui_types.gui", "paragon_portrait_container_research", ctx.screen, {
            texture_size = ctx.texture_size, loc = ctx.loc, prefix = "/head",
            parent = { x = slot.x, y = slot.y, w = 0, h = 0 },
            hide = {
                assign_character_button = true, character_portrait_container_clipping_mask = true,
                leader_rarity_icon = true, leader_type = true, leader_subclass_layered_icon_locator_0 = true,
                skill_icon_bg = true, skill_icon = true, rename_leader = true, leader_class_text = true,
                traits_overlapping_box = true,
                no_character_container = head and true or nil, leader_container = not head or nil,
            },
            sprites = {
                [P .. "/leader_container/council_position_icon"] = head and defs.councilors[head.position] or nil,
            },
            text = {
                [P .. "/leader_container/name_without_title_text"] = name,
                [P .. "/leader_container/councilor_title"] = head and head.position or "",
            },
        })
        if ok then
            gui.merge(items, report, hi, hr)
        end
    end

    -- the areas (CTechnologyViewAreaEntry::UpdateEntry), slot i of the grid (480 x 160)
    local grid = r.rects[V .. "/areas_window/grid"]
    for i, area in ipairs(AREAS) do
        local a = data.areas[i] or { queue = {}, alternatives = {} }
        local prefix = "/areas/" .. i
        local W = prefix .. "/technology_view_area_window"
        local opts = {
            prefix = prefix, parent = { x = grid.x, y = grid.y + 160 * (i - 1), w = 480, h = 160 },
            -- bottom_line is below the window's 150 (clipping = yes)
            hide = { bottom_line = true, special_project = true }, text = {}, sprites = {}, frames = {}, progress = {},
            actions = {
                [W .. "/choose/select"] = "view_set:researched=;select=" .. (state.select == area and "" or area),
            },
        }
        opts.sprites[W .. "/topbar"] = "GFX_scientist_top_bar_" .. area
        opts.sprites[W .. "/area_icon"] = "GFX_resource_" .. area
        -- ApplyModifierToButton(ModifierType 0xae): the research speed's icon [V: the game's frame
        -- shows this sprite; the enum's name I]
        opts.sprites[W .. "/modifier_icon"] = "GFX_mod_country_all_tech_research_speed"
        -- the button is drawn at its sprite's size, not its `size` (411 x 58 in the game's frame)
        opts.sizes = { [W .. "/choose/select"] = { native(ctx, "GFX_button_411_58_animated") } }
        opts.text[W .. "/area_name"] = area:upper()
        -- modifier_value: CreateGreenRedPercentDiff(CalcResearchEfficiency) [I: the format]
        if a.efficiency then
            local pct = math.floor(a.efficiency * 100 + 0.5)
            opts.text[W .. "/modifier_value"] = (pct >= 0 and "\194\167G+" or "\194\167R") .. pct .. "%\194\167!"
        else
            opts.hide.modifier_value = true
        end
        -- auto_research: frame 3 when on, 2 when off
        opts.frames[W .. "/auto_research"] = a.auto and 3 or 2
        local item = a.queue[1]
        if item then
            opts.hide[W .. "/choose"] = true
            local R = W .. "/research"
            card(opts, defs, ctx, R, item.tech)
            local cost = cost_of(defs, data, item.tech)
            opts.text[R .. "/progress_value"] = whole(item.progress) .. "/" .. whole(cost)
            opts.progress[R .. "/tech_progress/progress"] = cost > 0 and math.floor(100 * item.progress / cost + 0.5) / 100 or 0
            -- CTechQueueItem::CalcMonthsLeft: CalcMonthsToResearch(cost, progress + the points
            -- stored for the technology) = ceil(what is left / CalcResearchPerMonth), -1 when that
            -- is not positive [V]; the month's research: the area's resource with the efficiency,
            -- and as much again of the area's stored points (DailyResearch's A + B) [I]
            local per = a.monthly or 0
            local monthly = per * (1 + (a.efficiency or 0)) + math.min(per, math.max(0, a.stored or 0))
            if monthly > 0 then
                local done = item.progress + (data.stored and data.stored[item.tech] or 0)
                local months = math.max(0, math.ceil((cost - done) / monthly))
                opts.text[R .. "/tech_progress/eta"] = format(ctx.loc, "TECH_MONTHS_REMAINING", { VALUE = months })
            elseif a.monthly then
                opts.text[R .. "/tech_progress/eta"] = "NO_PROGRESS"
            else
                opts.hide.eta = true
            end
        else
            opts.hide[W .. "/research"] = true
        end
        layout("technology_view_area_window", opts)
    end

    -- select_window's list: the area's alternatives (CanResearch), 120 apart [I: the rows are
    -- resized to their unlocks]
    if sel_area then
        local list = r.rects[V .. "/select_window/list"]
        local a = data.areas[sel_area] or { alternatives = {} }
        local y = list.y
        for k, tech in ipairs(a.alternatives) do
            if y + 120 > list.y + list.h then
                break
            end
            local prefix = "/select/" .. k
            local E = prefix .. "/technology_view_tech_entry_window"
            local opts = { prefix = prefix, parent = { x = list.x, y = y, w = 0, h = 0 }, hide = {}, text = {}, sprites = {} }
            card(opts, defs, ctx, E, tech)
            if tech ~= data.always then
                opts.hide[E .. "/always_available"] = true
            end
            if not (defs.techs[tech] or {}).gateway then
                opts.hide[E .. "/gateway_icon"] = true
            end
            -- the cost: Free; the points stored for it over it; the cost
            local cost = cost_of(defs, data, tech)
            local stored = data.stored and data.stored[tech] or 0
            opts.text[E .. "/cost"] = cost == 0 and "COST_FREE" or (stored > 0 and (whole(stored) .. "/" .. whole(cost)) or whole(cost))
            layout("technology_view_tech_entry_window", opts)
            y = y + 120
        end
    end

    -- researched_window's list: the area's researched technologies, newest first, a row a
    -- level, 90 + 15 apart
    if res_area then
        local list = r.rects[V .. "/researched_window/list"]
        local y, k = list.y, 0
        for n = #data.researched, 1, -1 do
            local e = data.researched[n]
            local t = defs.techs[e.tech]
            if t and t.area == state.researched then
                for level = e.level, 1, -1 do
                    if y + 90 > list.y + list.h then
                        break
                    end
                    k = k + 1
                    local prefix = "/researched/" .. k
                    local E = prefix .. "/technology_view_tech_researched_entry_window"
                    local opts = { prefix = prefix, parent = { x = list.x, y = y, w = 0, h = 0 }, hide = {}, text = {}, sprites = {} }
                    card(opts, defs, ctx, E, e.tech, level)
                    opts.text[E .. "/cost"] = t.start and "TECH_STARTING" or whole(cost_of(defs, data, e.tech))
                    layout("technology_view_tech_researched_entry_window", opts)
                    y = y + 105
                end
            end
        end
    end
    return items, report
end

return technology
