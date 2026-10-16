-- render/windows/reform.lua : the Reform Government window (interface/government_mod_window.gui,
-- CGovernmentModWindow; docs/windows/empire.md section 13), opened from the government view's
-- government_reform button. Its state is the government view's: reform = 1, rf_auth the authority
-- chosen, rf_civics the civics chosen (a comma list), rf_scroll the available civics' first row.
-- Show starts from the country's government; OK posts the simulation's command (cmd:government:
-- reform, CChangeGovernmentCommand) and closes the window, Cancel (ESCAPE) closes it.
--
-- The authorities' and civics' rules are the empire creator's (render.creator_rules: the
-- configuration's potential, possible and playable), with the window's own: IsPossible's
-- `modification` (add / remove), can_reform, the civic points, the cooldown and the unity cost.

local C = require("render.windows.empire_common")

local F = {}

local FILE = "interface/government_mod_window.gui"
local CIVIC_FILE = "interface/customize_species_editors.gui"
local W = "/government_mod_window/"
F.KEYS = { "reform", "rf_auth", "rf_civics", "rf_scroll" }

local function rules_of(ctx)
    local rules = require("render.creator_rules")
    return rules, rules.load(ctx.game_dir)
end

local function split(s)
    local out = {}
    for k in tostring(s or ""):gmatch("[^,]+") do
        if k ~= "-" then
            out[#out + 1] = k
        end
    end
    return out
end

local function set(list)
    local s = {}
    for _, k in ipairs(list) do
        s[k] = true
    end
    return s
end

-- the action that opens the window (Show: the country's authority and civics)
function F.open_action(d)
    return "view_set:reform=1;rf_auth=" .. (d.authority or "") .. ";rf_civics=" .. (#(d.civics or {}) > 0 and table.concat(d.civics, ",") or "-") .. ";rf_scroll="
end

function F.close_action()
    return "view_set:reform=;rf_auth=;rf_civics=;rf_scroll="
end

-- the configuration (SEthicGovernmentConfiguration) with the window's authority and civics
local function config(rules, R, d, auth, civics)
    return rules.config(R, {
        ethics = d.ethics or {}, authority = auth, civics = civics, origin = d.origin,
        species = { class = d.founder and d.founder.class, traits = d.founder and d.founder.traits or {} },
    })
end

-- a civic's `modification` (no: neither added nor removed; { add = T remove = T }): CanAdd, CanRemove
local function modification(rules, R, g, which, cfg)
    local m = C.raw_field(g.block, "modification")
    if m == nil then
        return true
    end
    if type(m) == "string" then
        return m ~= "no"
    end
    local t = C.raw_field(m, which)
    if t == nil then
        return true
    end
    return rules.trigger(R, t, cfg) and true or false
end

-- CGovernmentCivicType::IsPossible(cfg, cond): potential, (cond 1) CanAdd, possible, playable
local function civic_possible(rules, R, g, cfg, add)
    if not rules.requirements(R, g.potential, cfg) then
        return false
    end
    if add and not modification(rules, R, g, "add", cfg) then
        return false
    end
    local without = cfg
    if cfg.civics[g.key] then
        without = {}
        for k, v in pairs(cfg) do
            without[k] = v
        end
        without.civics = {}
        for k in pairs(cfg.civics) do
            without.civics[k] = k ~= g.key or nil
        end
    end
    return rules.requirements(R, g.possible, without) and rules.trigger(R, g.playable, cfg) ~= false
end

local function authority_possible(rules, R, a, cfg)
    return rules.requirements(R, a.potential, cfg) and rules.requirements(R, a.possible, cfg) and rules.trigger(R, a.playable, cfg) ~= false
end

local function can_reform(a)
    return not a or C.field(a.block, "can_reform") ~= "no"
end

-- the window's state worked out: authorities listed, the selected and available civics, the
-- points, the cost, what makes OK invalid
function F.model(ctx, d, state)
    local rules, R = rules_of(ctx)
    local auth = state.rf_auth or d.authority
    local chosen = state.rf_civics and split(state.rf_civics) or d.civics or {}
    local cfg = config(rules, R, d, auth, chosen)
    local current = set(d.civics or {})
    local m = { auth = auth, chosen = chosen, authorities = {}, selected = {}, available = {} }
    -- authorities: playable and potential, in the database's order; greyed when not possible, or
    -- the country's authority cannot be reformed
    local cur_auth = R.authority[d.authority or ""]
    for _, a in ipairs(R.authorities) do
        if rules.requirements(R, a.potential, cfg) and rules.trigger(R, a.playable, cfg) ~= false then
            local ok = authority_possible(rules, R, a, cfg) and (a.key == d.authority or can_reform(cur_auth))
            m.authorities[#m.authorities + 1] = { key = a.key, ok = ok, icon = a.block and C.icon_file(ctx, "common/governments/authorities", a.key, "gfx/interface/icons/governments/authorities/" .. a.key .. ".dds") }
        end
    end
    -- the selected civics (RefreshContent: enabled when removable or not possible; red when not
    -- possible)
    local chosen_set = set(chosen)
    for _, k in ipairs(chosen) do
        local g = R.civic[k]
        if g then
            local possible = civic_possible(rules, R, g, cfg, false)
            m.selected[#m.selected + 1] = { key = k, ok = modification(rules, R, g, "remove", cfg) or not possible, possible = possible }
        end
    end
    -- the available ones: playable, potential, not origins, not selected; possible first, then by
    -- name (SGovernmentCivicSortingMethod)
    for _, g in ipairs(R.civics) do
        if not chosen_set[g.key] and rules.requirements(R, g.potential, cfg) and rules.trigger(R, g.playable, cfg) ~= false then
            local possible = civic_possible(rules, R, g, cfg, true)
            m.available[#m.available + 1] = {
                key = g.key, possible = possible, name = C.loc(ctx, g.key),
                ok = possible and (modification(rules, R, g, "add", cfg) or current[g.key] == true),
            }
        end
    end
    table.sort(m.available, function(a, b)
        if a.possible ~= b.possible then
            return a.possible
        end
        return a.name < b.name
    end)
    -- the civic points (CalcTotalCivicPoints: GOVERNMENT_CIVIC_POINTS_BASE +
    -- country_government_civic_points_add) and the cost (empire size x GOVERNMENT_CHANGE_EMPIRE_SIZE_MULT)
    m.points = R.civic_points + (d.civic_points_add or 0) - #chosen
    local mult = tonumber(C.define(ctx, "NGameplay", "GOVERNMENT_CHANGE_EMPIRE_SIZE_MULT")) or 10
    m.cost = d.free_reform and 0 or math.floor((d.empire_size or 0) * mult + 0.5)
    -- OK's validity (CChangeGovernmentCommand::IsValid): unity, the cooldown, the authority, each
    -- civic, the civics that cannot be removed kept
    local why = {}
    if not d.free_reform and (d.unity or 0) < m.cost then
        why[#why + 1] = C.raw(ctx, "GOVERNMENT_CHANGE_CANNOT_AFFORD"):gsub("%$COST[^$]*%$", tostring(m.cost))
    end
    if d.cooldown_years then
        why[#why + 1] = C.raw(ctx, "GOVERNMENT_CHANGE_YEARS"):gsub("%$YEARS[^$]*%$", tostring(d.cooldown_years)):gsub("%$DATE[^$]*%$", d.government_date or "")
    end
    local a = R.authority[auth or ""]
    if not a or (auth ~= d.authority and not can_reform(cur_auth)) or not authority_possible(rules, R, a, cfg) then
        why[#why + 1] = "TRIGGER_HAS_GOVERNMENT_AUTHORITY"
    end
    for _, k in ipairs(chosen) do
        local g = R.civic[k]
        if not g or g.is_origin then
            why[#why + 1] = "TRIGGER_HAS_CIVIC"
        elseif not (current[k] and not modification(rules, R, g, "remove", cfg)) and not civic_possible(rules, R, g, cfg, not current[k]) then
            why[#why + 1] = "TRIGGER_HAS_CIVIC"
        end
    end
    for k in pairs(current) do
        local g = R.civic[k]
        if g and not modification(rules, R, g, "remove", cfg) then
            local alt = C.field(g.block, "alternate_civic_version")
            if not chosen_set[k] and not (alt and chosen_set[alt]) then
                why[#why + 1] = "TRIGGER_NOT_HAS_CIVIC"
            end
        end
    end
    m.why = why
    -- the government type the reform gives (CGovernmentTypeDatabase::GenerateType: the creator's
    -- rule [I: the weights not read])
    m.government = rules.government(R, { ethics = d.ethics or {}, authority = auth, civics = chosen, origin = d.origin,
        species = { class = d.founder and d.founder.class, traits = {} } })
    return m
end

-- a click on an authority (OnClickGovernment): selected; each impossible civic swapped for its
-- alternate_civic_version when that one is possible
local function authority_action(ctx, d, m, key)
    local rules, R = rules_of(ctx)
    local cfg = config(rules, R, d, key, m.chosen)
    local out = {}
    for _, k in ipairs(m.chosen) do
        local g = R.civic[k]
        local alt = g and C.field(g.block, "alternate_civic_version")
        if g and alt and R.civic[alt] and not civic_possible(rules, R, g, cfg, false) then
            local without = {}
            for _, x in ipairs(m.chosen) do
                if x ~= k then
                    without[#without + 1] = x
                end
            end
            if civic_possible(rules, R, R.civic[alt], config(rules, R, d, key, without), true) then
                k = alt
            end
        end
        out[#out + 1] = k
    end
    return "view_set:rf_auth=" .. key .. ";rf_civics=" .. (#out > 0 and table.concat(out, ",") or "-")
end

-- a click on a civic (AddOrRemoveCivic): a selected one removed; another added when the points
-- allow and it is possible (or the country has it)
local function civic_action(m, key, add)
    local out = {}
    for _, k in ipairs(m.chosen) do
        if k ~= key then
            out[#out + 1] = k
        end
    end
    if add then
        out[#out + 1] = key
    end
    -- (none: "-", the state keeps no empty value)
    return "view_set:rf_civics=" .. (#out > 0 and table.concat(out, ",") or "-")
end

-- the entries' rows
local ROW = 32

local function civic_entry(ctx, b, prefix, x, y, c, action, selected)
    local P = prefix .. "/customization_selected_civic_entry/"
    local name = C.loc(ctx, c.key)
    if c.possible == false and selected then
        name = "§R" .. name .. "§!"
    end
    b:add(CIVIC_FILE, "customization_selected_civic_entry", {
        prefix = prefix, parent = { x = x, y = y, w = 0, h = 0 },
        hide = not selected and { [P .. "selected"] = true } or nil,
        sprites = { [P .. "icon"] = "GFX_government_civic" },
        textures = { [P .. "icon"] = C.icon_file(ctx, "common/governments/civics", c.key, "gfx/interface/icons/governments/civics/" .. c.key .. ".dds") },
        text = { [P .. "name"] = name, [P .. "cost"] = "1" },
        disabled = not c.ok and { [P .. "icon"] = true } or nil,
    })
    local inv = ctx.db.sprites.GFX_invisible
    if action and inv and inv.texture then
        b.items[#b.items + 1] = {
            kind = "sprite", path = prefix .. "/hit", sprite = "GFX_invisible", texture = inv.texture,
            sprite_kind = "spriteType", frame = 1, frames = inv.frames or 1, x = x, y = y, w = 302, h = ROW,
            button = { name = c.key, action = action },
        }
    end
end

-- the window drawn over the government view
function F.build(ctx, b, d, state)
    if state.reform ~= "1" then
        return
    end
    local m = F.model(ctx, d, state)
    local ok = #m.why == 0
    local r = b:add(FILE, "government_mod_window", {
        hide = { government_list = true },
        text = {
            [W .. "points_left"] = C.raw(ctx, "POINTS_LEFT_CIVICS"):gsub("%$POINTS[^$]*%$", "§H" .. m.points .. "§!"),
            [W .. "unity_cost"] = C.raw(ctx, "UNITY_TOOLTIP"):gsub("%$VALUE[^$]*%$", "§Y" .. m.cost .. "§!"),
        },
        disabled = not ok and { [W .. "ok"] = true } or nil,
        actions = {
            [W .. "cancel"] = F.close_action(),
            [W .. "ok"] = ok and ("cmd:government:reform:" .. m.auth .. ":" .. (m.government or "") .. ":" .. table.concat(m.chosen, ",") .. "#" .. F.close_action():sub(10)) or nil,
        },
    })
    -- the authorities (government_authority_entry, 50 wide, in authority_list)
    local al = r.rects[W .. "authority_list"]
    if al then
        C.overlap(b, al, #m.authorities, 50, 0, function(i, x, y, prefix)
            local a = m.authorities[i]
            local P = prefix .. "/government_authority_entry/"
            b:add(FILE, "government_authority_entry", {
                prefix = prefix, parent = { x = x, y = y, w = 50, h = 50 },
                hide = a.key ~= m.auth and { [P .. "selected"] = true } or nil,
                textures = { [P .. "icon"] = a.icon },
                disabled = not a.ok and { [P .. "icon"] = true } or nil,
                actions = a.ok and { [P .. "icon"] = authority_action(ctx, d, m, a.key) } or nil,
            })
        end)
    end
    -- the selected civics, then the available ones under them (NCivicsList::UpdateListPos)
    local sl = r.rects[W .. "selected_civics"]
    if sl then
        for i, c in ipairs(m.selected) do
            civic_entry(ctx, b, "/reform/selected/" .. i, sl.x, sl.y + (i - 1) * ROW, c, c.ok and civic_action(m, c.key, false) or nil, true)
        end
        local n = #m.selected
        local y0 = n > 0 and sl.y + 9 + n * ROW or sl.y
        local h = sl.h - (n > 0 and (n * ROW + 9) or 0)
        local rows = math.max(0, math.floor(h / ROW))
        local first = math.max(0, math.min(tonumber(state.rf_scroll) or 0, #m.available - rows))
        for i = 1, rows do
            local c = m.available[first + i]
            if not c then
                break
            end
            local add = c.ok and m.points >= 1
            civic_entry(ctx, b, "/reform/available/" .. i, sl.x, y0 + (i - 1) * ROW, c, add and civic_action(m, c.key, true) or nil, false)
        end
        F.available_rect = { x = sl.x, y = y0, w = sl.w, h = h, max = math.max(0, #m.available - rows) }
    end
end

-- the wheel over the available civics
function F.wheel(ctx, d, state, notches, x, y)
    if state.reform ~= "1" or not F.available_rect then
        return nil
    end
    local r = F.available_rect
    return C.list_wheel(r, state, "rf_scroll", notches, x, y, r.max)
end

return F
