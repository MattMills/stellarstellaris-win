-- render/windows/planet.lua : the planet view (interface/planet_view.gui; CPlanetView and its
-- tabs, docs/windows/planet.md) for the planet selected: what the game's Update shows of it, its
-- texts and numbers from the save.
--
-- Two halves, in two runtimes:
--   planet.data(game_dir, id) -> table   the planet as the window shows it, read from the world
--                                        (engine.world: the map's runtime); planet.encode /
--                                        planet.decode carry it to the front end's runtime
--   planet.build(ctx, sel, items, report) the window laid out (render.gui) in the front end's
--                                        runtime, from RENDER_PLANET = { id, tab, data } (planet.rs)

local planet = {}

local FILE = "interface/planet_view.gui"
local P = "/planet_view"

-- ---------------------------------------------------------------------------------------------
-- numbers as the planet view writes them

-- one decimal, cut (not rounded): 1188 -> 1.1K **[I]** from the game's frames (free housing
-- 1188.2 shows 1.1K, free amenities 1920.1 1.9K, 5346 pops 5.3K)
local function cut1(v)
    local s = v < 0 and -1 or 1
    return s * math.floor(math.abs(v) * 10 + 1e-6) / 10
end

function planet.short(v)
    v = tonumber(v) or 0
    local a = math.abs(v)
    if a >= 1e6 then
        return string.format("%.1fM", cut1(v / 1e6))
    elseif a >= 1e3 then
        return string.format("%.1fK", cut1(v / 1e3))
    end
    return tostring(math.floor(v + (v < 0 and 1 - 1e-9 or 0)))
end
local short = planet.short

-- ---------------------------------------------------------------------------------------------
-- texts: a bitmap font's advances (its .fnt), for the boxes the game sizes to their text and the
-- ones it wraps

local fonts = {}

local function font_metrics(game_dir, db, name)
    local f = fonts[name]
    if f ~= nil then
        return f or nil
    end
    local def = db.fonts and db.fonts[name]
    local file = def and def.file
    local fh = file and (io.open(game_dir .. "/" .. file .. ".fnt", "rb") or io.open(game_dir .. "/" .. file:lower() .. ".fnt", "rb"))
    if not fh then
        fonts[name] = false
        return nil
    end
    f = { adv = {}, kern = {}, line = 16 }
    for line in fh:lines() do
        local tag = line:match("^(%S+)")
        if tag == "common" then
            f.line = tonumber(line:match("lineHeight=(%d+)")) or f.line
        elseif tag == "char" then
            local id, adv = line:match("id=(%d+)"), line:match("xadvance=(%-?%d+)")
            if id then
                f.adv[tonumber(id)] = tonumber(adv) or 0
            end
        elseif tag == "kerning" then
            local a, b, n = line:match("first=(%d+)"), line:match("second=(%d+)"), line:match("amount=(%-?%d+)")
            if a and b then
                f.kern[tonumber(a) * 65536 + tonumber(b)] = tonumber(n) or 0
            end
        end
    end
    fh:close()
    fonts[name] = f
    return f
end

local function utf8_codes(s)
    local out = {}
    for _, c in utf8 and utf8.codes and utf8.codes(s) or function() end do
        out[#out + 1] = c
    end
    if #out == 0 then
        for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
            local b = ch:byte(1)
            local c = b
            if #ch == 2 then
                c = (b % 32) * 64 + ch:byte(2) % 64
            elseif #ch == 3 then
                c = (b % 16) * 4096 + (ch:byte(2) % 64) * 64 + ch:byte(3) % 64
            end
            out[#out + 1] = c
        end
    end
    return out
end

local function text_width(f, s)
    local w, prev = 0, nil
    for _, c in ipairs(utf8_codes(s)) do
        w = w + (f.adv[c] or 0) + (prev and f.kern[prev * 65536 + c] or 0)
        prev = c
    end
    return w
end

-- The texts of items[first..]: a box the game sizes to its text (an instantTextBox with neither a
-- size nor a maxWidth: render.gui gives it 100 x 16) is not cut; a box of several lines
-- (maxHeight) is wrapped at its width, a line a text item, `\n` a new line **[I]** (the game's
-- frames: "Colony Summary" whole in a box without maxWidth; descriptions on several lines).
local function settle_texts(game_dir, db, items, first, texture_size)
    -- an icon span's width: its texture's frame (render.gui: "\1texture\1frames\1frame")
    local function icon_width(text, line)
        local tex, frames = text:match("^\1([^\1]*)\1(%d+)")
        local tw = tex and texture_size and texture_size(tex)
        return tw and tw / math.max(1, tonumber(frames) or 1) or line
    end
    local out = {}
    for i = first, #items do
        local it = items[i]
        if it.kind ~= "text" then
            out[#out + 1] = it
        else
            local f = font_metrics(game_dir, db, it.font)
            local lines_fit = f and math.floor((it.h + 1) / f.line) or 1
            local multi = f and (lines_fit >= 2 or it.text:find("\n", 1, true))
            if f and it.w == 100 and lines_fit < 2 and (it.format == "left") and not it.text:find("\n", 1, true) then
                it.w = 0
                out[#out + 1] = it
            elseif multi and #it.spans > 0 then
                -- words with their colours, wrapped
                local lines, cur, cur_w = {}, {}, 0
                local function flush()
                    lines[#lines + 1] = cur
                    cur, cur_w = {}, 0
                end
                local space = text_width(f, " ")
                for _, sp in ipairs(it.spans) do
                    if sp.text:sub(1, 1) == "\1" then
                        -- an icon: its frame's width
                        local iw = icon_width(sp.text, f.line)
                        if cur_w + iw > it.w and #cur > 0 then
                            flush()
                        end
                        cur[#cur + 1] = { text = sp.text, colour = sp.colour }
                        cur_w = cur_w + iw
                    else
                        local pieces = {}
                        for part, nl in (sp.text .. "\n"):gmatch("([^\n]*)(\n)") do
                            pieces[#pieces + 1] = part
                        end
                        for pi, part in ipairs(pieces) do
                            if pi > 1 then
                                flush()
                            end
                            local lead = part:match("^%s") ~= nil
                            local words = {}
                            for wd in part:gmatch("%S+") do
                                words[#words + 1] = wd
                            end
                            for wi, wd in ipairs(words) do
                                local ww = text_width(f, wd)
                                local sep = (#cur > 0 and (wi > 1 or lead)) and space or 0
                                -- a word fits with the space after it (the frames: 379 + 4 > 380 wraps)
                                if #cur > 0 and cur_w + sep + ww + space > it.w then
                                    flush()
                                    sep = 0
                                end
                                cur[#cur + 1] = { text = (sep > 0 and " " or "") .. wd, colour = sp.colour }
                                cur_w = cur_w + sep + ww
                            end
                            if part:match("%s$") and #cur > 0 then
                                cur[#cur + 1] = { text = " ", colour = sp.colour }
                                cur_w = cur_w + space
                            end
                        end
                    end
                end
                if #cur > 0 then
                    flush()
                end
                local max_lines = math.max(1, lines_fit)
                -- vertical_alignment = center: the lines centred in the box
                local n = math.min(#lines, it.text:find("\n", 1, true) and #lines or max_lines)
                local y0 = it.y
                if it.valign == "center" or it.valign == "centre" then
                    y0 = it.y + math.floor((it.h - n * f.line) / 2 + 0.5)
                end
                for li, l in ipairs(lines) do
                    if li > max_lines and not it.text:find("\n", 1, true) then
                        break
                    end
                    local plain = {}
                    for _, s in ipairs(l) do
                        plain[#plain + 1] = s.text
                    end
                    out[#out + 1] = {
                        kind = "text", path = it.path .. (li > 1 and ("#" .. li) or ""), font = it.font,
                        text = table.concat(plain), spans = l, x = it.x, y = y0 + (li - 1) * f.line,
                        w = it.w, h = f.line, format = it.format, valign = "top",
                    }
                end
            else
                out[#out + 1] = it
            end
        end
    end
    for i = #items, first, -1 do
        items[i] = nil
    end
    for _, it in ipairs(out) do
        items[#items + 1] = it
    end
end
planet.settle_texts = settle_texts

-- ---------------------------------------------------------------------------------------------
-- the layout

-- the block of the element `path` ({ "a", "b" }: names) under a window's block
local function node(block, path)
    local get = require("render.gfx").get
    local b = block
    for _, name in ipairs(path) do
        local found
        for _, e in ipairs(b) do
            if e.op and e.key and type(e.value) == "table" and e.value.text == nil and get(e.value, "name") == name then
                found = e.value
                break
            end
        end
        if not found then
            return nil
        end
        b = found
    end
    return b
end

-- a grid box's slots: { slot_w, slot_h, max_h, max_v, horizontal }
local function grid_of(game_dir, window, path)
    local gui = require("render.gui")
    local get = require("render.gfx").get
    local w = gui.find(game_dir, FILE, window)
    local b = w and node(w, path)
    if not b then
        return nil
    end
    local ss = get(b, "slotsize")
    return {
        w = tonumber(type(ss) == "table" and get(ss, "width") or nil) or 0,
        h = tonumber(type(ss) == "table" and get(ss, "height") or nil) or 0,
        max_h = tonumber(get(b, "max_slots_horizontal")) or 1,
        max_v = tonumber(get(b, "max_slots_vertical")) or 1,
        horizontal = get(b, "add_horizontal") ~= "no",
        format = tostring(get(b, "format") or "UPPER_LEFT"):upper(),
    }
end

-- the slot `i` (1-based) of a grid at `rect`: x, y
local function slot(g, rect, i)
    local k = i - 1
    local col, row
    if g.horizontal then
        col, row = k % g.max_h, math.floor(k / g.max_h)
    else
        row, col = k % g.max_v, math.floor(k / g.max_v)
    end
    local x = rect.x + col * g.w
    if g.format:find("RIGHT") then
        x = rect.x + rect.w - (col + 1) * g.w
    end
    return x, rect.y + row * g.h
end


local function col(c, s)
    return "\194\167" .. c .. tostring(s) .. "\194\167!"
end

-- the window's state while it is laid out: the planet's data, the tab, the planet_view layout's
-- options (only, hide, text, frames, sprites, actions) and the lists laid out after it (they
-- need its rectangles); the textures a laid-out sprite is changed to and the frames of
-- backgrounds (planet.build applies both)
local View = {}
View.__index = View

function View:L(key)
    local loc = self.loc
    return loc and loc.has(key) and loc.get(key) or key
end

-- a localisation key's text with its $NAME$ / $NAME|Y$ variables (a letter: that colour)
function View:F(key, vars)
    local loc = self.loc
    local t = loc and loc.raw(key) or key
    t = t:gsub("%$([^$|\n]+)|?([^$\n]*)%$", function(name, how)
        local v = vars[name]
        if v == nil then
            return loc and loc.has(name) and loc.get(name) or nil
        end
        local c = how:match("%a")
        v = tostring(v)
        return c and col(c, v) or v
    end)
    return t
end

-- a disabled button (Disable(): the buttonstate shader greys it **[I]** a darker tint)
function View:disable(path)
    self.tints[path] = { 0.45, 0.45, 0.45, 1 }
end

-- an icon's sprite set at run time, with its sheet's frame (the element's own `frame` is the
-- sheet's first otherwise)
function View:sprite(path, name)
    local sp = name and self.ctx.db.sprites[name]
    if not sp then
        return
    end
    self.sprites[path] = name
    if sp.default_frame then
        self.frames[path] = sp.default_frame
    end
end

function View:lay(window, o)
    local gui = require("render.gui")
    o.texture_size, o.loc = self.ctx.texture_size, self.loc
    local i, r = gui.layout(self.ctx.game_dir, self.ctx.db, o.file or FILE, window, self.ctx.screen, o)
    gui.merge(self.items, self.report, i, r)
    return r
end

-- an entry window `window` laid out at `x, y` (a list's slot), its paths under `prefix`
function View:entry(window, prefix, x, y, w, h, o)
    o = o or {}
    o.prefix = prefix
    o.parent = { x = x, y = y, w = w or 0, h = h or 0 }
    -- a smooth list's entry is at its slot, its own position not added; a grid box's keeps it
    -- **[I]** (the game's frames: planet_deposit_entry's y = 82 is not where the deposits list's
    -- first entry shows; colonize_district_entry's 10, 12 is where the colonize window's districts
    -- show)
    if not o.grid then
        o.positions = o.positions or {}
        o.positions[prefix .. "/" .. window] = { 0, 0 }
    end
    return self:lay(window, o)
end

-- the numbers of a colony's pops
local function pop_totals(colony)
    local total, by_cat = 0, {}
    for _, g in ipairs(colony.pop_groups) do
        total = total + g.size
        by_cat[g.category or ""] = (by_cat[g.category or ""] or 0) + g.size
    end
    return total, by_cat
end

-- ---------------------------------------------------------------------------------------------
-- the header (CPlanetView::UpdatePlanetTopBar, UpdatePlanetTabState; docs/windows/planet.md)

function View:header()
    local d, only, hide, text, sprites = self.d, self.only, self.hide, self.text, self.sprites
    text[P .. "/planet_name"] = self.name
    self.actions[P .. "/header_actions/close"] = "close"
    -- the header's buttons: previous / next planet for a planet with an owner, move capital on
    -- a colony of the player's not the capital, the orbital ring's with a ring, the observation
    -- post's on an observed world; close and zoom always
    hide[P .. "/header_actions/open_orbital_ring"] = true
    hide[P .. "/header_actions/previous_planet_extra_shortcut"] = true
    hide[P .. "/header_actions/go_to_observation_post"] = true
    if not (self.mine and d.owner_capital ~= nil and d.colony and d.colony.id ~= d.owner_capital) then
        hide[P .. "/header_actions/move_capital"] = true
    end
    if not (d and d.owner) then
        hide[P .. "/header_actions/previous_planet"] = true
        hide[P .. "/header_actions/next_planet"] = true
    end
    -- the portrait window: the arkship's top bar hidden; the flag the owner's (an unowned
    -- planet's: the unknown flag)
    hide[P .. "/planet_portrait_window/arkship_planet_top_bar"] = true
    -- (an unowned planet's flag: planet.rs composes the unknown flag)
    -- the colonize button: an unowned planet of a colonizable class
    if d and not d.owner and d.colonizable then
        only.colonize_button_container = true
        -- disabled until the player can colonize it (CanColonizeIncludingTerraform: a colony
        -- ship; the game's frames of 2210 show it greyed) **[I]**
        self:disable(P .. "/colonize_button_container/colonize_button")
    end
    only.governor_window = true
    only.sector_governor_window = true

    local colony = d and d.colony
    -- the stats row (planet_actions_window, always shown for planets: UpdateArkshipTabUiVisibilities)
    only.planet_actions_window = true
    local A = P .. "/planet_actions_window"
    hide[A .. "/colonizing_planet_window"] = true
    hide[A .. "/decision_progress_window"] = true
    if not self.completed then
        -- its numbers only for a completed colony (UpdatePlanetTopBar @0x30668a3)
        for _, n in ipairs({ "planet_stability", "planet_pops", "crime_status_window/planet_crime", "crime_status_window/planet_housing",
            "crime_status_window/planet_amenities", "crime_status_window/planet_jobs", "crime_status_window/planet_unemployed" }) do
            hide[A .. "/" .. n] = true
        end
        return
    end
    only.colony_type = true
    -- its numbers: stability, pops, crime, housing, amenities, jobs, unemployed (colours:
    -- CPlanetView::UpdatePlanetTopBar)
    hide[A .. "/crime_status_window/planet_amenities/planet_amenities_no_happiness_icon"] = true
    hide[A .. "/crime_status_window/planet_unemployed/unemployed_stratas"] = true
    local pops, by_cat = pop_totals(colony)
    local unemployed = by_cat.civilian or 0
    local free_jobs = 0
    for _, j in ipairs(colony.jobs) do
        if j.max_workforce > 0 and j.workforce < j.max_workforce then
            free_jobs = free_jobs + (j.max_workforce - math.max(0, j.workforce))
        end
    end
    local stab = math.floor(colony.stability)
    local crime = math.floor(colony.crime)
    local function sign_col(v)
        return v < 0 and "R" or v == 0 and "Y" or "G"
    end
    text[A .. "/planet_stability/planet_stability_amount"] = col(stab > 50 and "G" or stab == 50 and "Y" or "R", stab .. "%")
    text[A .. "/planet_pops/planet_pops_amount"] = short(pops)
    text[A .. "/crime_status_window/planet_crime/planet_crime_amount"] = col(crime > 50 and "R" or crime > 0 and "Y" or "G", crime .. "%")
    text[A .. "/crime_status_window/planet_housing/planet_housing_amount"] = col(sign_col(colony.free_housing), short(colony.free_housing))
    text[A .. "/crime_status_window/planet_amenities/planet_amenities_amount"] = col(sign_col(colony.free_amenities), short(colony.free_amenities))
    text[A .. "/crime_status_window/planet_jobs/planet_jobs_amount"] = free_jobs == 0 and col("Y", "0") or short(free_jobs)
    text[A .. "/crime_status_window/planet_unemployed/planet_unemployed_amount"] = col(unemployed < 500 and "G" or "Y", short(unemployed))
    -- the designation
    if colony.designation then
        text[P .. "/colony_type/colony_type_text"] = self:L(colony.designation)
        sprites[P .. "/colony_type/colony_type_icon"] = colony.designation_icon
    end
    hide[P .. "/colony_type/governance_skill"] = true
end

-- the tabs: each shown, the current one as its `_active` button; a click opens its tab
-- (CPlanetView::Update: X_tab when not current, X_tab_active when current; a tab that cannot be
-- opened falls back to the summary)
local TABS = { "summary", "management", "population", "armies", "corporate" }

function View:tabs()
    local only = self.only
    for _, t in ipairs(TABS) do
        only[t .. "_tab"] = t ~= self.tab or nil
        only[t .. "_tab_active"] = t == self.tab or nil
        self.actions[P .. "/" .. t .. "_tab"] = "planet_tab:" .. t
    end
    only.tabs_transparent_bg = true
    only[self.tab .. "_window"] = true
end

-- ---------------------------------------------------------------------------------------------
-- the summary tab (CPlanetView::UpdateSummaryTab and its colony / colonizable / uncolonizable
-- parts)

local S = P .. "/summary_window"

-- a resource line as the summary writes it (CPlanetView::UpdateResourcesDisplay): each
-- resource's icon and value, rounded up, `+` on a gain, green / yellow / red, one space between
local function resource_text(list, want, decimals)
    local parts = {}
    for _, r in ipairs(list) do
        local k, v = r[1], r[2]
        if (want > 0 and v > 0) or (want < 0 and v < 0) or want == 0 then
            local s
            if decimals then
                s = string.format("%." .. decimals .. "f", v)
            else
                s = tostring(math.ceil(v - 1e-9))
                if v > 0 then
                    s = "+" .. s
                end
            end
            -- (the research resources' text icons are £physics£, £society£, £engineering£)
            local icon = k:gsub("_research$", "")
            parts[#parts + 1] = "\194\163" .. icon .. "|1\194\163 " .. col(v > 0 and "G" or v == 0 and "Y" or "R", s)
        end
    end
    return table.concat(parts, " ")
end

function View:summary()
    local d, hide, text, sprites = self.d, self.hide, self.text, self.sprites
    local colony = d and d.colony
    hide[S .. "/archaeological_site_window"] = true
    if self.completed then
        hide[S .. "/uncolonizable_planet_window"] = true
        hide[S .. "/colonized_planet_window/planet_primitives_window"] = true
        hide[S .. "/colonizable_planet_window/planet_desc_window"] = true
        local R = S .. "/colonized_planet_window/planetary_resources"
        text[R .. "/planetary_production_output_amount"] = resource_text(colony.net or {}, 1)
        text[R .. "/planetary_consumption_output_amount"] = resource_text(colony.net or {}, -1)
        self.later[#self.later + 1] = function(r)
            self:available_districts(r)
        end
    elseif d and d.colonizable then
        hide[S .. "/uncolonizable_planet_window"] = true
        hide[S .. "/colonized_planet_window"] = true
        text[S .. "/colonizable_planet_window/planet_desc_window/planet_desc"] = self:L(d.class .. "_desc")
    else
        hide[S .. "/colonizable_planet_window"] = true
        hide[S .. "/colonized_planet_window"] = true
        text[S .. "/uncolonizable_planet_window/planet_desc_window/planet_desc"] = d and self:L(d.class .. "_desc") or ""
        local res = {}
        for _, dep in ipairs(d and d.deposits or {}) do
            for _, r in ipairs(dep.resources) do
                res[#res + 1] = r
            end
        end
        text[S .. "/uncolonizable_planet_window/planetary_resources/planetary_resources_amount"] =
            #res > 0 and resource_text(res, 0, 2) or self:L("DASH")
    end
    if not self.completed then
        hide[S .. "/summary_side_window/designation_button_container"] = true
        hide[S .. "/summary_side_window/summary_build_queue_window"] = true
    else
        -- the designation chosen (colony +0x108: the save's `designation`), else "Auto
        -- Designated" (the game's frame of the capital: final_designation col_capital, none chosen)
        local DB = S .. "/summary_side_window/designation_button_container"
        if colony.manual_designation then
            text[DB .. "/designation_name"] = self:L(colony.manual_designation)
            sprites[DB .. "/designation_icon"] = colony.manual_designation_icon
        else
            text[DB .. "/designation_name"] = self:L("COLONY_AUTOMATIC_DESIGNATION")
            hide[DB .. "/designation_icon"] = true
        end
    end
    if d then
        local SS = S .. "/summary_side_window/planet_summary"
        text[SS .. "/management_planet_class_text"] = col("G", self:L(d.class))
        text[SS .. "/management_habitability"] = self:F("HABITABILITY_TEXT", { VALUE = d.habitability and col(d.habitability > 0 and "G" or "R", math.floor(d.habitability * 100 + 1e-6) .. "%") or self:L("UNKNOWN_SHORT") })
        text[SS .. "/colonization_date"] = self:F("COLONIZATION_DATE", { DATE = self.completed and d.colonize_date or self:L("UNKNOWN_SHORT") })
        text[SS .. "/planet_size"] = self:F("PLANET_SIZE_TEXT", { SIZE = (self.completed or d.colonizable) and d.size or self:L("DASH") })
        self:sprite(SS .. "/management_planet_class_icon", d.class_icon_large)
        hide[SS .. "/terraform_label"] = true
        hide[SS .. "/decisions_button"] = not self.mine or nil
    end
    -- the districts (colony or colonizable): the header's free slots, the main district's wide
    -- entry, the others' narrow ones
    if d and (self.completed or d.colonizable) then
        local H = S .. "/colonizable_planet_window/districts_header_bg"
        local free = d.district_slots and (d.district_slots.max - d.district_slots.built) or nil
        text[H .. "/planet_num_districts/planet_districts_amount"] = free and col(free > 0 and "G" or "Y", free) or self:L("DASH")
        self.later[#self.later + 1] = function(r)
            self:districts(r)
        end
    end
end

-- the box grid of a district entry: `max` rectangles, the built ones frame 1, the buildable
-- frame 2, the rest frame 3
function View:district_boxes(entry_window, prefix, rect, dist)
    local g = grid_of(self.ctx.game_dir, entry_window, { "district_box", "district_box_grid" })
    if not g or not rect then
        return
    end
    local n = math.min(dist.max or 0, g.max_h * g.max_v)
    for i = 1, n do
        local x, y = slot(g, rect, i)
        local p = prefix .. "/box" .. i
        local fr = i <= (dist.built or 0) and 1 or i <= (dist.cap or dist.max or 0) and 2 or 3
        self.bg_frames[p .. "/rectangle_district_grid_box_entry/background"] = fr
        local rs = dist.gridbox and ("GFX_" .. dist.gridbox .. "_box_icon_rectangle")
        if rs and self.ctx.db.sprites[rs] then
            self.resprite[p .. "/rectangle_district_grid_box_entry/background"] = rs
        end
        self:entry("rectangle_district_grid_box_entry", p, x, y, g.w, g.h, { grid = true })
    end
end

-- a zone's buildings: its buildings, then empty slots up to its max
function View:buildings(grid, rect, prefix, zone)
    if not grid or not rect then
        return
    end
    local n = math.max(#zone.buildings, zone.max_buildings or 0)
    n = math.min(n, grid.max_h * grid.max_v)
    for i = 1, n do
        local x, y = slot(grid, rect, i)
        local b = zone.buildings[i]
        local p = prefix .. "/b" .. i
        local E = p .. "/planet_building_entry"
        local hide = {
            [E .. "/progressbar"] = true, [E .. "/selected_building_icon"] = true,
            [E .. "/upgrade_building"] = true, [E .. "/disabled_building"] = true,
            [E .. "/building_slot_icons/locked_building_button"] = true,
            [E .. "/building_slot_icons/ruined_building_icon"] = true,
        }
        if b then
            hide[E .. "/building_slot_icons/add_building_bg"] = true
            if b.icon then
                self.retexture[E .. "/building_slot_icons/building_icon"] = b.icon
            end
        else
            hide[E .. "/building_slot_icons/building_bg"] = true
            hide[E .. "/building_slot_icons/building_icon"] = true
        end
        self:entry("planet_building_entry", p, x, y, grid.w, grid.h, { hide = hide, grid = true })
    end
end

-- a zone slot: its zone's buildings, else the new-zone button, else what unlocks it
function View:zone_slot(entry_window, base, zpath, zone, inner)
    local hide, text = self.hide_e, self.text_e
    hide[zpath .. "/selection_highlight"] = true
    hide[zpath .. "/progressbar"] = true
    if zone and zone.type and zone.buildings then
        hide[zpath .. "/zone_button"] = true
        hide[zpath .. "/zone_available"] = true
        hide[zpath .. "/zone_unavailable"] = true
        if text[zpath .. "/zone_title"] == nil then
            text[zpath .. "/zone_title"] = self:L(zone.type)
        end
        if zone.icon then
            self.zone_sprites[zpath .. "/zone_icon"] = zone.icon
        end
        local grid = grid_of(self.ctx.game_dir, entry_window, inner)
        inner = nil
        return grid
    end
    hide[zpath .. "/buildings_box"] = true
    hide[zpath .. "/zone_icon"] = true
    hide[zpath .. "/zone_title"] = true
    if zone and zone.open then
        hide[zpath .. "/zone_unavailable"] = true
        if not self.mine then
            hide[zpath .. "/zone_button"] = true
            hide[zpath .. "/zone_available"] = true
        else
            text[zpath .. "/zone_available"] = self:L("zone_available")
        end
    else
        -- a locked slot: what unlocks it (zone_unavailable_tech and the slot's unlock tooltip)
        hide[zpath .. "/zone_button"] = true
        hide[zpath .. "/zone_available"] = true
        text[zpath .. "/zone_unavailable"] = zone and zone.requires and (self:L("zone_unavailable_tech") .. self:L(zone.requires)) or ""
    end
    return nil
end

function View:district_entry(window, prefix, x, y, w, h, dist)
    local E = prefix .. "/" .. window
    self.hide_e, self.text_e = {
        [E .. "/selection_highlight"] = true, [E .. "/progressbar"] = true, [E .. "/not_surveyed"] = true,
    }, {
        [E .. "/name"] = self:L(dist.name or dist.type),
        [E .. "/triggered_name"] = dist.triggered and self:L(dist.triggered) or "",
        [E .. "/planet_district_cap_container/num_districts_text"] = (dist.built or 0) .. "/" .. (dist.max or 0),
    }
    if not self.mine then
        self.hide_e[E .. "/build_district"] = true
    end
    if dist.icon then
        self.retexture[E .. "/district_icon"] = dist.icon
    end
    -- the district's own art: its background, its cap box (CPlanetViewDistrictEntry @0x3078973)
    local bg = dist.background and ("GFX_" .. dist.background .. "_bg")
    if bg and self.ctx.db.sprites[bg] then
        self.resprite[E .. "/background"] = bg
    end
    if dist.gridbox then
        self.retexture[E .. "/planet_district_cap_container/cap_background"] = "gfx/interface/icons/districts/grid_box/" .. dist.gridbox .. "_big.dds"
    end
    local sprites = {}
    if dist.overlay then
        sprites[E .. "/district_overlay_icon"] = dist.overlay
    else
        self.hide_e[E .. "/district_overlay_icon"] = true
    end
    -- the first zone slot in the entry's `zone`
    local zone = dist.zones and dist.zones[1]
    local zgrid = self:zone_slot(window, E, E .. "/zone", zone, { "zone", "buildings_box" })
    if not (dist.zones and #dist.zones > 0) then
        self.hide_e[E .. "/zone"] = true
    end
    for k, v in pairs(self.zone_sprites) do
        sprites[k] = v
    end
    local r = self:entry(window, prefix, x, y, w, h, { hide = self.hide_e, text = self.text_e, sprites = sprites })
    self:district_boxes(window, E, r.rects[E .. "/district_box/district_box_grid"], dist)
    if zgrid and zone then
        self:buildings(zgrid, r.rects[E .. "/zone/buildings_box"], E .. "/zone/bb", zone)
    end
    -- the other zone slots: zone entries in the zones grid
    local zr = r.rects[E .. "/zones_grid_box"]
    local zg = zr and grid_of(self.ctx.game_dir, window, { "zones_grid_box" })
    if zg then
        for i = 2, #(dist.zones or {}) do
            local zx, zy = slot(zg, zr, i - 1)
            local zp = E .. "/zones/" .. i
            local Z = zp .. "/zone_entry"
            self.hide_e, self.text_e = {}, {}
            local z = dist.zones[i]
            local bgrid = self:zone_slot("zone_entry", zp, Z, z, { "buildings_box" })
            local zr2 = self:entry("zone_entry", zp, zx, zy, zg.w, zg.h, { hide = self.hide_e, text = self.text_e, sprites = self.zone_sprites, grid = true })
            if bgrid and z then
                self:buildings(bgrid, zr2.rects[Z .. "/buildings_box"], Z .. "/bb", z)
            end
        end
    end
end

function View:districts(r)
    local d = self.d
    local list = d.districts or {}
    local W = S .. "/colonizable_planet_window"
    -- the main district: the wide entry in the main grid
    local main_rect = r.rects[W .. "/districts_window/main_districts_grid_box"]
    local main_g = grid_of(self.ctx.game_dir, "planet_view", { "summary_window", "colonizable_planet_window", "districts_window", "main_districts_grid_box" })
    local rest_rect = r.rects[W .. "/districts_grid_window/districts_grid_box"]
    local rest_g = grid_of(self.ctx.game_dir, "planet_view", { "summary_window", "colonizable_planet_window", "districts_grid_window", "districts_grid_box" })
    local k = 0
    for i, dist in ipairs(list) do
        if dist.main and main_rect and main_g then
            local x, y = slot(main_g, main_rect, 1)
            self:district_entry("planet_district_entry_width_2", W .. "/main", x, y, 561, 170, dist)
        elseif rest_rect and rest_g then
            k = k + 1
            if k <= rest_g.max_h * rest_g.max_v then
                local x, y = slot(rest_g, rest_rect, k)
                self:district_entry("planet_district_entry_width_1", W .. "/d" .. i, x, y, 279, 170, dist)
            end
        end
    end
end

-- ---------------------------------------------------------------------------------------------

function planet.build(ctx, sel, items, report)
    local names = require("render.names")
    local st = RENDER_PLANET or {}
    local d = st.data
    local v = setmetatable({
        ctx = ctx, loc = ctx.loc, items = items, report = report, d = d,
        only = {
            planet_view_bg = true, planet_portrait_window = true, planet_name = true,
            side_bar_window_always_open = true, header_actions = true,
        },
        hide = {}, text = {}, frames = {}, sprites = {}, actions = {},
        later = {}, retexture = {}, bg_frames = {}, icon_frames = {}, zone_sprites = {}, resprite = {}, tints = {},
    }, View)
    v.name = (d and d.name and names.format(ctx.loc, d.name)) or sel.name or ""
    local colony = d and d.colony
    v.species_names = {}
    for _, s in ipairs(colony and colony.species or {}) do
        v.species_names[s.id] = names.format(ctx.loc, s.name)
    end
    -- a completed colony whose details the player sees (NPlanetViewUtil::CanSeeColonyDetails:
    -- the player's own; another country's with intel, not read yet: shown)
    v.completed = colony ~= nil and d.owner ~= nil
    v.mine = v.completed and d.owner == d.player
    -- the tab: the asked one if it can open (a colony's), else the summary
    -- (CPlanetView::CanOpenTab @0x30645f0: summary always; management for a colony whose details
    -- the player sees or a planet whose details it sees **[I]** any planet the window opens on;
    -- population and armies for a completed colony; holdings for a completed colony)
    v.tab = st.tab or "summary"
    local can = {
        summary = true, management = true,
        population = v.completed, armies = v.completed, corporate = v.completed,
    }
    if not can[v.tab] then
        v.tab = "summary"
    end
    v.can_open = can
    local first = #items + 1

    v:header()
    v:tabs()
    if v.tab == "summary" then
        v:summary()
    elseif v.tab == "management" and v.management then
        v:management()
    elseif v.tab == "population" and v.population then
        v:population()
    elseif v.tab == "armies" and v.armies then
        v:armies()
    elseif v.tab == "corporate" and v.corporate then
        v:corporate()
    end

    local r = v:lay("planet_view", {
        sizes = { [P] = { 1162, 680 } },
        only = v.only, hide = v.hide, text = v.text, frames = v.frames, sprites = v.sprites, actions = v.actions,
        tints = v.tints,
    })
    for _, f in ipairs(v.later) do
        f(r)
    end
    v:portrait(r, first)
    -- the colonize window, over the planet view
    if st.colonize and d and d.colonizable then
        v:colonize_window()
    end
    -- sprites the game sets from a texture (district and building icons, the unknown flag), the
    -- frames of backgrounds
    for i = first, #items do
        local it = items[i]
        if it.kind == "sprite" then
            local base = it.path
            local tex = v.retexture[base]
            if tex then
                -- the new texture at the element's scale (an icon without a size is its sprite's
                -- frame x its `scale`: the same scale of the new texture)
                local ow, oh
                if it.texture and it.texture:sub(1, 1) ~= "@" then
                    ow, oh = ctx.texture_size(it.texture)
                    ow = ow and ow / math.max(1, it.frames or 1)
                end
                it.texture, it.sprite, it.frame, it.frames, it.sprite_kind = tex, tex, 1, 1, "spriteType"
                local tw, th = nil, nil
                if tex:sub(1, 1) ~= "@" then
                    tw, th = ctx.texture_size(tex)
                end
                if tw and (it.w == 0 or it.h == 0) then
                    it.w, it.h = tw, th
                elseif tw and ow and oh and ow > 0 and oh > 0 then
                    it.w, it.h = it.w * tw / ow, it.h * th / oh
                end
            end
            local rs = v.resprite[base]
            local sp = rs and ctx.db.sprites[rs]
            if sp then
                local name, frame = rs, nil
                if sp.sheet and ctx.db.sprites[sp.sheet] then
                    name, frame = sp.sheet, sp.default_frame
                    sp = ctx.db.sprites[sp.sheet]
                end
                if sp.texture then
                    it.sprite, it.texture, it.frames, it.sprite_kind = name, sp.texture, sp.frames or 1, sp.kind
                    it.frame = frame or it.frame
                    it.border = sp.kind == "corneredTileSpriteType" and sp.border or nil
                end
            end
            local fr = v.bg_frames[base] or v.icon_frames[base]
            if fr then
                it.frame = fr
            end
        end
    end
    settle_texts(ctx.game_dir, ctx.db, items, first, ctx.texture_size)
    -- PLANET_DUMP=<text>: the window's items whose path has the text, to stderr
    local dump = os.getenv("PLANET_DUMP")
    if dump then
        for i = first, #items do
            local it = items[i]
            if it.path and it.path:find(dump, 1, true) then
                io.stderr:write(string.format("planet item %s %s %s %.1f %.1f %.1f %.1f\n", it.kind, it.path, tostring(it.texture or it.text),
                    it.x or 0, it.y or 0, it.w or 0, it.h or 0))
            end
        end
    end
    return r
end

-- a smooth list box's spacing
local function list_of(game_dir, window, path)
    local gui = require("render.gui")
    local get = require("render.gfx").get
    local w = gui.find(game_dir, FILE, window)
    local b = w and node(w, path)
    return b and (tonumber(get(b, "spacing")) or 0) or 0
end

-- an entry window's height (its `size`)
local function height_of(game_dir, window)
    local gui = require("render.gui")
    local get = require("render.gfx").get
    local w = gui.find(game_dir, FILE, window)
    local s = w and get(w, "size")
    return tonumber(type(s) == "table" and (get(s, "height") or get(s, "y")) or nil) or 0
end

-- entries down a smooth list box at `rect`: each laid out by fill(i, x, y) -> its height, or nil
-- to stop (the renderer does not clip: an entry is drawn while it fits, where the game shows the
-- last one cut)
function View:stack(rect, spacing, n, fill)
    if not rect then
        return
    end
    local y = rect.y
    for i = 1, n do
        local h = fill(i, rect.x, y)
        if not h then
            break
        end
        y = y + h + spacing
    end
end

-- an army type's cost (CArmyType::GetCostDesc): its days (TIME_COST_VALUE), then its resources
function View:army_cost(a)
    local parts = {}
    if a.time and a.time > 0 then
        parts[#parts + 1] = self:F("TIME_COST_VALUE", { DAYS = a.time })
    end
    for _, c in ipairs(a.cost or {}) do
        parts[#parts + 1] = "\194\163" .. c[1] .. "\194\163 " .. col("Y", c[2])
    end
    return table.concat(parts, " ")
end

-- a checkbox (checkboxType, which render.gui does not draw): its sprite's frame 1 unchecked, 2
-- checked **[I]**
function View:checkbox(path, sprite, x, y, checked)
    local s = self.ctx.db.sprites[sprite]
    if not s or not s.texture then
        return
    end
    local tw, th = self.ctx.texture_size(s.texture)
    if not tw then
        return
    end
    local frames = math.max(1, s.frames or 1)
    self.items[#self.items + 1] = {
        kind = "sprite", path = path, sprite = sprite, texture = s.texture, sprite_kind = s.kind,
        frame = checked and math.min(2, frames) or 1, frames = frames, x = x, y = y, w = tw / frames, h = th,
        button = { name = path:match("[^/]+$") },
    }
    self.report.sprites = self.report.sprites + 1
end

-- ---------------------------------------------------------------------------------------------
-- the armies tab (CPlanetView::UpdateArmiesTab @0x3070f70, UpdateArmiesTabDefenses @0x3079010)

local AW = P .. "/armies_window"

function View:armies()
    local d, hide, text = self.d, self.hide, self.text
    local colony = d.colony
    -- no ground combat on the planet: the defenses
    hide[AW .. "/ground_combat_window"] = true
    local D = AW .. "/defenses_window"
    text[D .. "/armies_stats_window/garrison_power"] = self:F("GARRISON_POWER_INFO", { VALUE = math.floor((colony.military_strength or 0) + 0.5) })
    text[D .. "/armies_stats_window/garrison_assault_power"] = self:F("GARRISON_ASSAULT_POWER_INFO", { VALUE = math.floor((colony.assault_strength or 0) + 0.5) })
    text[D .. "/armies_list_window/armies_count"] = self:F("PLANET_VIEW_ARMIES_COUNT", { VALUE = #colony.armies })
    if #colony.armies > 0 then
        hide[D .. "/armies_list_window/planet_armies/no_armies"] = true
    end
    -- the side: the recruitment list on the player's planet, else the orbiting armies
    if self.mine then
        hide[D .. "/orbiting_armies_window"] = true
    else
        hide[D .. "/recruitment_list_window"] = true
    end
    self.later[#self.later + 1] = function(r)
        -- the checkboxes: both checked by default (planet +0xcb4 bit 0x40, colony +0x1060 bit 0x8)
        local sw = r.rects[D .. "/armies_stats_window"]
        if sw then
            for _, c in ipairs({ { "deploy_in_orbit_checkbox", 470, -7 }, { "army_builder_checkbox", 470, 14 } }) do
                self:checkbox(D .. "/armies_stats_window/" .. c[1], "GFX_checkbox_20_20_01", sw.x + c[2], sw.y + c[3], true)
            end
        end
        -- the colony's armies, in the save's order
        local lr = r.rects[D .. "/armies_list_window/planet_armies/armies_list"]
        local h = height_of(self.ctx.game_dir, "planet_army_entry")
        local sp = list_of(self.ctx.game_dir, "planet_view", { "armies_window", "defenses_window", "armies_list_window", "planet_armies", "armies_list" })
        self:stack(lr, sp, #colony.armies, function(i, x, y)
            if y + h > lr.y + lr.h + 1 then
                return nil
            end
            local a = colony.armies[i]
            local p = D .. "/armies/" .. i
            local E = p .. "/planet_army_entry"
            local hp = (a.max_health and a.max_health > 0) and (a.health or 0) / a.max_health or 1
            local hd = {}
            if not self.mine then
                hd[E .. "/disband_army"] = true
            end
            local species = a.species and self.species_names[a.species]
            if not species then
                hd[E .. "/army_species"] = true
            end
            self:entry("planet_army_entry", p, x, y, 485, h, {
                text = {
                    [E .. "/army_name"] = a.name and require("render.names").format(self.loc, a.name) or "",
                    [E .. "/army_species"] = species or "",
                    [E .. "/army_power"] = self:F("ARMY_POWER_YELLOW", { VALUE = math.floor((a.power or 0) + 0.5) }),
                    [E .. "/army_health"] = "\194\163ship_stats_hitpoints\194\163 " .. col(hp >= 1 and "G" or "R", math.floor(hp * 100 + 1e-6) .. "%"),
                },
                hide = hd, sprites = { [E .. "/army_icon"] = a.icon },
            })
            return h
        end)
        -- the recruitment list: the buildable army types, each for the colony's species, by type
        -- name
        local rr = r.rects[D .. "/recruitment_list_window/recruitment_window/recruitment_list"]
        local rh = height_of(self.ctx.game_dir, "planet_recruitment_entry")
        local rsp = list_of(self.ctx.game_dir, "planet_view", { "armies_window", "defenses_window", "recruitment_list_window", "recruitment_window", "recruitment_list" })
        local rec = {}
        for i, a in ipairs(self.mine and d.recruitable or {}) do
            rec[i] = a
        end
        -- SArmyComparator: by the type's name, then the species
        table.sort(rec, function(a, b)
            local na, nb = self:L(a.type), self:L(b.type)
            if na ~= nb then
                return na < nb
            end
            return (a.species or 0) < (b.species or 0)
        end)
        self:stack(rr, rsp, #rec, function(i, x, y)
            if y + rh > rr.y + rr.h + 1 then
                return nil
            end
            local a = rec[i]
            local p = D .. "/recruit/" .. i
            local E = p .. "/planet_recruitment_entry"
            self:entry("planet_recruitment_entry", p, x, y, 310, rh, {
                text = {
                    [E .. "/army_name"] = self:L(a.type),
                    [E .. "/army_species"] = a.species and self.species_names[a.species] or "",
                    [E .. "/army_cost"] = self:army_cost(a),
                },
                hide = { [E .. "/army_species"] = not a.species or nil },
                sprites = { [E .. "/army_icon"] = a.icon },
            })
            return rh
        end)
    end
end

-- ---------------------------------------------------------------------------------------------
-- the holdings tab (CPlanetView::UpdatePlanetTabCorporate @0x306ae60; the holding types
-- @0x3492110): a holding_type_entry per type (Corporate with the Megacorp DLC, then Overlord),
-- each with its countries' holdings, else its empty text

function View:corporate()
    local d = self.d
    local C = P .. "/corporate_window"
    local R = C .. "/corporate_side_window/holdings_planet_owner_resources"
    self.text[R .. "/holdings_planet_owner_production_output_amount"] = ""
    self.text[R .. "/holdings_planet_owner_consumption_output_amount"] = ""
    self.later[#self.later + 1] = function(r)
        local lr = r.rects[C .. "/holdings_container/holding_type_box"]
        local types = {}
        if d.megacorp then
            types[#types + 1] = "corporate"
        end
        types[#types + 1] = "subject_holding"
        if not lr then
            return
        end
        -- a horizontal list (horizontal = 1, spacing 5); an entry fitted to its contents
        -- (FitWindowSizeToContent): with no holdings, its empty text's container below its title
        local sp = list_of(self.ctx.game_dir, "planet_view", { "corporate_window", "holdings_container", "holding_type_box" })
        local x = lr.x
        for i, t in ipairs(types) do
            local p = C .. "/holdings/" .. i
            local E = p .. "/holding_type_entry"
            local h = 20 + 350
            self:entry("holding_type_entry", p, x, lr.y, 417, h, {
                sizes = { [E] = { 417, h } },
                text = {
                    [E .. "/title_general/holding_type_title"] = self:L(t),
                    [E .. "/empty_text_container/empty_text"] = self:L("HOLDINGS_EMPTY_" .. t),
                },
                hide = { [E .. "/holdings_per_country_container"] = true },
            })
            x = x + 417 + sp
        end
    end
end

-- the header's free district slots: the available ones frame 2, then the blocked ones frame 3
-- (UpdateSummaryTabColonizable @0x307774b)
function View:available_districts(r)
    local d = self.d
    local H = S .. "/colonizable_planet_window/districts_header_bg/available_districts_window/available_districts_grid_box"
    local rect = r.rects[H]
    local g = grid_of(self.ctx.game_dir, "planet_view", { "summary_window", "colonizable_planet_window", "districts_header_bg", "available_districts_window", "available_districts_grid_box" })
    if not rect or not g or not d.district_slots then
        return
    end
    local free = math.max(0, d.district_slots.max - d.district_slots.built)
    local blocked = 0
    for _, dep in ipairs(d.deposits) do
        for _, m in ipairs(dep.modifiers) do
            if m[1] == "planet_max_districts_add" and m[2] < 0 then
                blocked = blocked - m[2]
            end
        end
    end
    for i = 1, math.min(free + blocked, g.max_h * g.max_v) do
        local x, y = slot(g, rect, i)
        local p = H .. "/" .. i
        self.icon_frames[p .. "/available_planet_district_grid_box_entry/icon"] = i <= free and 2 or 3
        self:entry("available_planet_district_grid_box_entry", p, x, y, g.w, g.h, { grid = true })
    end
end

-- the planet's portrait (planet.rs composes `@planet_portrait:...`): the 800 x 400 picture at the
-- portrait button, the rows its container shows, under the window's other parts
function View:portrait(r, first)
    local d = self.d
    if not d or not d.picture then
        return
    end
    local B = r.rects[P .. "/planet_portrait_window/portrait/portrait"]
    local C = r.rects[P .. "/planet_portrait_window/portrait"]
    if not B or not C then
        return
    end
    local W, H = 800, 400
    local y0 = math.max(B.y, C.y)
    local y1 = math.min(B.y + H, C.y + C.h)
    if y1 <= y0 then
        return
    end
    -- the city: the owner's city set, as many layers as the main district's level **[I]**
    local level = 0
    if d.colony then
        for _, dist in ipairs(d.districts or {}) do
            if dist.main then
                level = math.min(6, dist.built or 0)
            end
        end
    end
    local name = string.format("@planet_portrait:%s:%s:%d:%d:%d", d.picture, d.colony and d.city or "", level,
        math.floor(y0 - B.y + 0.5), math.floor(y1 - y0 + 0.5))
    local item = {
        kind = "sprite", path = P .. "/planet_portrait_window/portrait/portrait", sprite = name, texture = name,
        sprite_kind = "spriteType", frame = 1, frames = 1, x = B.x, y = y0, w = W, h = y1 - y0,
    }
    -- under the portrait window's own parts: before its first item
    local at = #self.items + 1
    for i = first, #self.items do
        if self.items[i].path and self.items[i].path:find(P .. "/planet_portrait_window", 1, true) == 1 then
            at = i
            break
        end
    end
    table.insert(self.items, at, item)
    self.report.sprites = self.report.sprites + 1
end

-- ---------------------------------------------------------------------------------------------
-- the management tab (CPlanetView::UpdatePlanetTabManagement @0x30699a0, UpdateDepositsView
-- @0x306d300, NPlanetView::CDemographicsView, CSectorInfoView)

local M = P .. "/management_window"

-- SI_NUMBER with a sign forced and coloured by it ($AMOUNT|+=0*$): "+4" green, "0" yellow
local function signed(v)
    v = math.floor(v + 0)
    if v > 0 then
        return col("G", "+" .. short(v))
    elseif v < 0 then
        return col("R", short(v))
    end
    return col("Y", "0")
end

-- the species palette (common/colors species = { ... }; CColorsDatabase::GetSpeciesColor:
-- colors[i % n]) **[V]**, as the management agent read it
local SPECIES_COLOURS = {
    { 142 / 255, 188 / 255, 241 / 255 }, { 53 / 255, 82 / 255, 171 / 255 }, { 27 / 255, 42 / 255, 87 / 255 }, { 91 / 255, 225 / 255, 219 / 255 },
}

function View:management()
    local d, hide, text = self.d, self.hide, self.text
    local colony = d.colony or { growth = 0, growth_details = {}, pop_groups = {}, species_growth = {}, ascension_tier = 0 }
    local DW = M .. "/deposits_window/deposits_summary_window"
    local blockers, rare = 0, 0
    for _, dep in ipairs(d.deposits) do
        if dep.blocker then
            blockers = blockers + 1
        elseif dep.important then
            rare = rare + 1
        end
    end
    -- the features: counted when the player sees them (CanSeePlanetFeatures: its colony, or the
    -- planet surveyed by it), else "?" and the no-intel text (UpdateDepositsView @0x306d300)
    local features = self.completed or d.surveyed
    if features then
        text[DW .. "/blocker_deposits_window/blocker_deposit_num"] = self:F("NUM_MULT", { NUM = blockers })
        text[DW .. "/rare_deposits_window/blocker_deposit_num"] = self:F("NUM_MULT", { NUM = rare })
        hide[M .. "/deposits_window/deposits_no_intel"] = true
    else
        text[DW .. "/blocker_deposits_window/blocker_deposit_num"] = self:L("UNKNOWN_SHORT")
        text[DW .. "/rare_deposits_window/blocker_deposit_num"] = self:L("UNKNOWN_SHORT")
        text[M .. "/deposits_window/deposits_no_intel"] = self:L("DEPOSITS_NO_INTEL")
    end
    -- the monthly pop summary
    local SD = M .. "/management_side_window/demographics_summary"
    local gd = colony.growth_details or {}
    local growth = (gd.GROWTH_CAT_GROWTH or 0) + (gd.GROWTH_CAT_DECLINE or 0)
    local migration = (gd.GROWTH_CAT_IMMIGRATION or 0) - (gd.GROWTH_CAT_EMIGRATION or 0)
    local function growth_sprite(v)
        return v > 0 and "GFX_growth_positive" or v < 0 and "GFX_growth_negative" or "GFX_growth_neutral"
    end
    text[SD .. "/total_growth"] = signed(colony.growth or 0)
    self.sprites[SD .. "/pop_group_growth_icon"] = growth_sprite(colony.growth or 0)
    text[SD .. "/demographics_data/growth_data/value"] = signed(growth)
    self.sprites[SD .. "/demographics_data/growth_data/pop_group_growth_icon"] = growth_sprite(growth)
    text[SD .. "/demographics_data/migration_data/value"] = signed(migration)
    text[SD .. "/demographics_data/assembly_data/value"] = signed(gd.GROWTH_CAT_ASSEMBLY or 0)
    hide[SD .. "/demographics_piechart_window/demographics_piechart_hover"] = true
    -- the sector (the system's; its name and type) **[I]** names from the galaxy's sectors are
    -- not in the data yet: the core sector's
    local SI = M .. "/management_side_window/sector_info"
    text[SI .. "/sector_name"] = d.sector_name and require("render.names").format(self.loc, d.sector_name) or self:L("NO_SECTOR")
    text[SI .. "/sector_type"] = d.sector_type and self:L(d.sector_type) or self:L("FRONTIER_PLANET")
    -- the sector's button: delete on its capital, move the capital elsewhere in it, a new sector
    -- outside one (CSectorInfoView::Update @0x306eb50)
    if not (d.sector_type and self.mine) then
        -- (enabled on the player's own sector only: the game's frames of an unowned planet)
        self:disable(SI .. "/sector_action_button")
        self:disable(SI .. "/sector_edit_button")
    end
    self.sprites[SI .. "/sector_action_button"] = not d.sector_type and "GFX_button_sector_new"
        or (colony.id ~= nil and d.sector_capital == colony.id and "GFX_button_sector_delete" or "GFX_button_move_sector_capital")
    -- ascension
    local AI = M .. "/management_side_window/ascension_info"
    text[AI .. "/ascension_tier"] = self:L("PLANET_ASCENSION_NONE")
    text[AI .. "/ascension_text"] = self:L("PLANET_ASCENSION_TEXT_DESC") .. "\n\n" .. self:L("PLANET_ASCENSION_TEXT_NONE")
    self.frames[AI .. "/ascension_tier_icon"] = (colony.ascension_tier or 0) + 1
    -- enabled when the colony can rise a tier (CColony::CanIncreaseAscensionTier) **[I]** not
    -- at 2210's capital
    self:disable(AI .. "/upgrade_ascension_tier_button")
    self.later[#self.later + 1] = function(r)
        if features then
            self:deposits(r)
        end
        self:demographics(r, colony)
    end
end

function View:deposits(r)
    local d = self.d
    local list = {}
    for _, dep in ipairs(d.deposits) do
        if dep.listed then
            list[#list + 1] = dep
        end
    end
    table.sort(list, function(a, b)
        if a.blocker ~= b.blocker then
            return a.blocker
        end
        if a.important ~= b.important then
            return a.important
        end
        if a.index ~= b.index then
            return a.index < b.index
        end
        return (a.id or 0) < (b.id or 0)
    end)
    local lr = r.rects[M .. "/deposits_window/deposits_list"]
    local h = height_of(self.ctx.game_dir, "planet_deposit_entry")
    local sp = list_of(self.ctx.game_dir, "planet_view", { "management_window", "deposits_window", "deposits_list" })
    self:stack(lr, sp, #list, function(i, x, y)
        if y + h > lr.y + lr.h + 1 then
            return nil
        end
        local dep = list[i]
        local p = M .. "/deposits/" .. i
        local E = p .. "/planet_deposit_entry"
        local name = "§H" .. self:L(dep.type) .. "§!"
        if not dep.blocker and (dep.count or 1) >= 2 then
            name = name .. " " .. self:F("NUM_DEPOSITS", { NUM = dep.count })
        end
        local effects = {}
        if #dep.resources > 0 then
            effects[#effects + 1] = self:L("PRODUCES_RESOURCES") .. resource_text(dep.resources, 0, 0)
        end
        for _, m in ipairs(dep.modifiers) do
            local v = m[2] * (dep.blocker and 1 or (dep.count or 1))
            -- the modifier with its text icon (CModifier::GetFullDescriptionWithTextIcons): the
            -- district caps' icon is £district£ **[I]** (the frame's small district icon)
            local icon = m[1]:match("district") and "\194\163district\194\163 " or (self:L("mod_" .. m[1]) .. ": ")
            effects[#effects + 1] = icon .. col(v >= 0 and "G" or "R", (v > 0 and "+" or "") .. v)
        end
        local hd = { [E .. "/rare_deposit_frame"] = not (not dep.blocker and dep.important) or nil }
        local t = { [E .. "/deposit_name/deposit_name"] = name, [E .. "/deposit_effects"] = table.concat(effects, "\n") }
        local fr = {}
        if dep.blocker then
            local cost = {}
            if dep.time then
                cost[#cost + 1] = "\194\163time\194\163" .. dep.time
            end
            for _, c in ipairs(dep.cost) do
                cost[#cost + 1] = "\194\163" .. c[1] .. "\194\163" .. c[2]
            end
            t[E .. "/clear_blocker_cost"] = table.concat(cost, " ")
            fr[E .. "/blocker_frame"] = 1
            if dep.swap_icon then
                self.retexture[E .. "/clear_blocker_deposit_icon"] = dep.swap_icon
            else
                hd[E .. "/clear_blocker_deposit_icon"] = true
            end
        else
            hd[E .. "/blocker_frame"] = true
            hd[E .. "/clear_blocker_button"] = true
            hd[E .. "/clear_blocker_cost"] = true
            hd[E .. "/clear_blocker_deposit_icon"] = true
        end
        self.retexture[E .. "/deposit_icon"] = dep.icon
        self:entry("planet_deposit_entry", p, x, y, 270, h, { text = t, hide = hd, frames = fr })
        return h
    end)
end

function View:demographics(r, colony)
    local d = self.d
    -- the species: the pop groups by species (the database index), each a species entry
    local by, order = {}, {}
    for _, g in ipairs(colony.pop_groups) do
        if g.species then
            if not by[g.species] then
                by[g.species] = 0
                order[#order + 1] = g.species
            end
            by[g.species] = by[g.species] + g.size
        end
    end
    local pie = {}
    for i, s in ipairs(order) do
        pie[i] = s
    end
    table.sort(order, function(a, b)
        return (a % 16777216) < (b % 16777216)
    end)
    local growth_of = {}
    for _, sg in ipairs(colony.species_growth or {}) do
        growth_of[sg[1]] = sg[2]
    end
    local lr = r.rects[M .. "/demographics_window/demographics_list"]
    local sp = list_of(self.ctx.game_dir, "planet_view", { "management_window", "demographics_window", "demographics_list" })
    local h = 59
    self:stack(lr, sp, #order, function(i, x, y)
        if y + h > lr.y + lr.h + 1 then
            return nil
        end
        local s = order[i]
        local p = M .. "/species/" .. i
        local E = p .. "/demographics_species_entry"
        local g = growth_of[s] or 0
        self:entry("demographics_species_entry", p, x, y, 530, h, {
            text = {
                [E .. "/species_info/species_name"] = self.species_names[s] or "",
                [E .. "/portrait/amount"] = short(by[s]),
                [E .. "/species_growth/species_growth"] = signed(g),
            },
            sprites = { [E .. "/species_growth/species_growth_icon"] = g > 0 and "GFX_growth_positive" or g < 0 and "GFX_growth_negative" or "GFX_growth_neutral" },
            hide = { [E .. "/collapse_arrow_window/open_arrow"] = true, [E .. "/species_categories"] = true },
        })
        return h
    end)
    -- the pie chart's legend: the species in the order of the colony's pop groups, coloured from
    -- the species palette
    local LR = r.rects[M .. "/management_side_window/demographics_summary/demographics_piechart_window/demographics_list"]
    self:legend(LR, M .. "/legend", pie, function(s)
        return self.species_names[s] or ""
    end)
end

-- a pie chart's legend (strata_piechart_entry): its plupp in the palette's colour **[V]**
function View:legend(rect, prefix, list, name_of)
    if not rect then
        return
    end
    local h = height_of(self.ctx.game_dir, "strata_piechart_entry")
    for i, v in ipairs(list) do
        local y = rect.y + (i - 1) * h
        if y + h > rect.y + rect.h + 1 then
            break
        end
        local p = prefix .. "/" .. i
        local E = p .. "/strata_piechart_entry"
        local c = SPECIES_COLOURS[(i - 1) % #SPECIES_COLOURS + 1]
        self:entry("strata_piechart_entry", p, rect.x, y, 148, h, {
            text = { [E .. "/name"] = name_of(v) }, tints = { [E .. "/strata_plupp"] = { c[1], c[2], c[3], 1 } },
        })
    end
end

-- ---------------------------------------------------------------------------------------------
-- the population tab (CPlanetView::UpdatePlanetTabPopulation @0x306a2a0, UpdatePopulationTab
-- @0x306f170, CPlanetViewPopCategoryEntry, CPlanetViewJobTypeEntry)

local PW = P .. "/population_window"

function View:population()
    local colony = self.d.colony
    local hide, text = self.hide, self.text
    if not self.mine then
        hide[PW .. "/resettle_button"] = true
    end
    text[PW .. "/restore_jobs_button"] = self:L("RESTORE_JOBS")
    -- the jobs kept: workforce >= 0 or pops in them, in the save's order
    local jobs = {}
    for _, j in ipairs(colony.jobs) do
        if j.max_workforce >= 0 or j.assigned > 0 then
            jobs[#jobs + 1] = j
        end
    end
    text[PW .. "/strata_summary_side_window/strata_summary/strata_piechart_window/job_types_amount"] = self:F("JOB_TYPES_AMOUNT", { AMOUNT = #jobs })
    hide[PW .. "/strata_summary_side_window/strata_summary/strata_piechart_window/strata_piechart_hover"] = true
    -- the categories: by the display category's rank, high first, then its database index; a run
    -- of one display category an entry; jobs in it by their own category's rank (stable)
    local idx = {}
    for i, j in ipairs(jobs) do
        idx[j] = i
    end
    table.sort(jobs, function(a, b)
        if a.display_rank ~= b.display_rank then
            return a.display_rank > b.display_rank
        end
        if a.display_index ~= b.display_index then
            return a.display_index < b.display_index
        end
        if a.rank ~= b.rank then
            return a.rank > b.rank
        end
        return idx[a] < idx[b]
    end)
    local cats = {}
    for _, j in ipairs(jobs) do
        local c = cats[#cats]
        if not c or c.display ~= j.display then
            c = { display = j.display, icon = j.category_icon, jobs = {}, amount = 0 }
            cats[#cats + 1] = c
        end
        c.jobs[#c.jobs + 1] = j
        c.amount = c.amount + math.max(0, j.assigned)
    end
    self.later[#self.later + 1] = function(r)
        local lr = r.rects[PW .. "/pop_categories_list"]
        local sp = list_of(self.ctx.game_dir, "planet_view", { "population_window", "pop_categories_list" })
        local h = 128
        self:stack(lr, sp, #cats, function(i, x, y)
            if y + h > lr.y + lr.h + 1 then
                return nil
            end
            self:pop_category(cats[i], PW .. "/cats/" .. i, x, y, h)
            return h
        end)
        local LR = r.rects[PW .. "/strata_summary_side_window/strata_summary/strata_piechart_window/strata_list"]
        self:legend(LR, PW .. "/legend", cats, function(c)
            return self:plural(c.display)
        end)
    end
end

-- a pop category's plural name (pop_cat_<key>_plural, else <key>_plural)
function View:plural(cat)
    local loc = self.loc
    for _, k in ipairs({ "pop_cat_" .. cat .. "_plural", cat .. "_plural" }) do
        if loc and loc.has(k) then
            return loc.get(k)
        end
    end
    return cat
end

function View:pop_category(c, p, x, y, h)
    local E = p .. "/planet_pop_category_entry"
    local r = self:entry("planet_pop_category_entry", p, x, y, 1123, h, {
        sizes = { [E] = { 1123, h } },
        text = {
            [E .. "/pop_category_collapsed_info/pop_category_name"] = self:plural(c.display),
            [E .. "/pop_strata_icon_total_container/category_amount"] = short(c.amount),
            [E .. "/pop_category_collapsed_production_info/collapsed_upkeep_frame/collapsed_upkeep"] = "",
            [E .. "/pop_category_collapsed_production_info/collapsed_production_frame/collapsed_production"] = "",
        },
        hide = {
            [E .. "/pop_strata_icon_collapsed_container"] = true, [E .. "/pop_category_jobs"] = true,
        },
        frames = { [E .. "/pop_category_collapsed_info/strata_header_arrow"] = 1 },
    })
    self.retexture[E .. "/pop_strata_icon_total_container/category_icon"] = c.icon
    -- the arrow between upkeep and production (rotation = 1.56: planet.rs turns its texture)
    self.retexture[E .. "/pop_category_collapsed_production_info/leads_to_arrows_test"] = "@planet_rot90:gfx/interface/planetview/strata_arrow.dds"
    -- the job types (planet_job_type_entry) side by side in job_types_box
    local box = r.rects[E .. "/pop_category_info/job_types_box"]
    if box then
        local jw = 64
        for k, j in ipairs(c.jobs) do
            local jx = box.x + (k - 1) * jw
            if jx + jw > box.x + box.w + 1 then
                break
            end
            local jp = E .. "/jobs/" .. k
            local J = jp .. "/planet_job_type_entry"
            self.retexture[J .. "/job_icon"] = j.icon
            local pct = j.max_workforce > 0 and math.floor(100 * math.max(0, j.workforce) / math.max(j.max_workforce, 1) + 0.5) or 100
            self.icon_frames[J .. "/workforce_bar/bar_icon"] = math.max(1, math.min(100, pct))
            self:entry("planet_job_type_entry", jp, jx, box.y, jw, 74, {
                text = { [J .. "/amount"] = short(j.assigned) },
                hide = {
                    [J .. "/favorite_icon"] = true,
                    [J .. "/downprio_icon"] = not (j.limit >= 0 and j.limit < j.max_workforce) or nil,
                },
            })
        end
    end
end

-- ---------------------------------------------------------------------------------------------
-- the colonize window (interface/colonize_planet_view.gui, expansion_planner_surface_view;
-- CSurfaceView::ShowWithPlanet @0x2bcabb0, Update @0x2bd0050): opened by the planet view's
-- colonize button (CPlanetView::OnColonize -> NExpansionView::OpenColoniseView)

local CFILE = "interface/colonize_planet_view.gui"
local CW = "/expansion_planner_surface_view"

function View:colonize_window()
    local d = self.d
    local c = d.colonize or { species = {}, cost = {} }
    local text, hide, actions = {}, {}, {}
    text[CW .. "/title"] = self:F("EXPANSION_PLANNER_SURFACE_VIEW", { TARGET_PLANET = self.name })
    actions[CW .. "/close"] = "colonize_close"
    -- (no hostiles known: HasHostiles **[I]**)
    hide[CW .. "/has_intel_hostile"] = true
    text[CW .. "/modifiers_container/planet_class_container/planet_class_name"] = self:L(d.class)
    text[CW .. "/modifiers_container/planet_class_container/planet_size_container/planet_size_amount"] = tostring(d.size)
    hide[CW .. "/designation_container/designation_desc_container"] = true
    -- the districts' header: the planet's slots (DASH while not surveyed)
    local DH = CW .. "/districts_window/districts_window_title_bar/planet_total_districts_container"
    text[DH .. "/planet_num_districts/planet_districts_amount"] = d.surveyed and d.district_slots and tostring(d.district_slots.max) or self:L("DASH")
    local r = self:lay("expansion_planner_surface_view", {
        file = CFILE, text = text, hide = hide, actions = actions, tints = { [CW .. "/colonize_button"] = { 0.45, 0.45, 0.45, 1 } },
    })
    -- the checkboxes: the founder-species filter and the automation, unchecked
    for _, cb in ipairs({ { CW .. "/expansion_source/expansion_source_container_title_bar/main_species_filter", "checked" },
        { CW .. "/designation_container/designation_container_title_bar/automation_toggle", "automation_checkbox" } }) do
        local rr = r.rects[cb[1]]
        if rr then
            self:checkbox(cb[1] .. "/" .. cb[2], "GFX_checkbox_20_20_01", rr.x, rr.y, false)
        end
    end
    -- the colonizing species (expansion_source_planet_sub_entry)
    local lr = r.rects[CW .. "/expansion_source/expansion_source_list_container/expansion_source_list"]
    if lr then
        local h = 77
        for i, s in ipairs(c.species) do
            local y = lr.y + (i - 1) * h
            local p = CW .. "/sources/" .. i
            local E = p .. "/expansion_source_planet_sub_entry"
            local hab = math.floor((s.habitability or 0) * 100 + 1e-6)
            local cost = {}
            for _, k in ipairs(c.cost) do
                cost[#cost + 1] = "\194\163" .. k[1] .. "\194\163" .. k[2]
            end
            local er = self:entry("expansion_source_planet_sub_entry", p, lr.x, y, 725, h, {
                file = CFILE,
                text = {
                    [E .. "/species_container/species_name_text"] = require("render.names").format(self.loc, s.name),
                    [E .. "/species_container/ship_type_text"] = self:L("colonizer"),
                    [E .. "/habitability_container/habitability_percentage"] = col(hab > 0 and "G" or "R", hab .. "%"),
                    [E .. "/colonization_cost_container/colony_ship_cost"] = table.concat(cost, " "),
                },
                hide = { [E .. "/selected_overlay"] = true },
                frames = { [E .. "/habitability_container/habitability_icon"] = hab > 0 and 2 or 1 },
            })
            -- the species' traits, side by side at the entry's right (traits_list)
            local tr = er.rects[E .. "/traits_list"]
            if tr then
                -- an overlapping elements box: the icons overlap to fit its width
                local n = #(s.traits or {})
                local step = n > 1 and math.min(24, (tr.w - 24) / (n - 1)) or 24
                for k, icon in ipairs(s.traits or {}) do
                    local tx = tr.x + (k - 1) * step
                    self.items[#self.items + 1] = {
                        kind = "sprite", path = E .. "/traits_list/" .. k, sprite = icon, texture = icon, sprite_kind = "spriteType",
                        frame = 1, frames = 1, x = tx, y = tr.y, w = 24, h = 24,
                    }
                end
            end
        end
    end
    -- the districts shown on uncolonized planets: their icons, "?" until surveyed
    local gr = r.rects[CW .. "/districts_window/districts_grid_container/districts_grid_box"]
    if gr then
        local k = 0
        for _, dist in ipairs(d.districts or {}) do
            k = k + 1
            if k > 4 then
                break
            end
            local p = CW .. "/districts/" .. k
            local E = p .. "/colonize_district_entry"
            self.retexture[E .. "/district_icon"] = dist.icon
            self:entry("colonize_district_entry", p, gr.x + (k - 1) * 70, gr.y, 70, 80, {
                file = CFILE, grid = true,
                hide = { [E .. "/district_box"] = not d.surveyed or nil, [E .. "/not_surveyed"] = d.surveyed or nil },
                text = { [E .. "/district_box/district_amount_text"] = tostring(dist.max or 0) },
            })
        end
    end
    -- the planet's deposits (colonize_deposit_entry), sorted as the planet view's
    local dr = r.rects[CW .. "/deposits_window/deposits_list_container/deposits_list"]
    if dr then
        local list = {}
        for _, dep in ipairs(d.deposits) do
            if dep.listed then
                list[#list + 1] = dep
            end
        end
        table.sort(list, function(a, b)
            if a.blocker ~= b.blocker then
                return a.blocker
            end
            if a.important ~= b.important then
                return a.important
            end
            return a.index < b.index
        end)
        local y = dr.y
        for i, dep in ipairs(list) do
            if y + 90 > dr.y + dr.h + 1 then
                break
            end
            local p = CW .. "/deposits/" .. i
            local E = p .. "/colonize_deposit_entry"
            local effects = {}
            for _, m in ipairs(dep.modifiers) do
                local v = m[2]
                effects[#effects + 1] = (m[1]:match("district") and "\194\163district\194\163 " or "") .. col(v >= 0 and "G" or "R", (v > 0 and "+" or "") .. v)
            end
            local cost = {}
            if dep.time then
                cost[#cost + 1] = "\194\163time\194\163" .. dep.time
            end
            for _, cc in ipairs(dep.cost) do
                cost[#cost + 1] = "\194\163" .. cc[1] .. "\194\163" .. cc[2]
            end
            self.retexture[E .. "/deposit_icon"] = dep.icon
            if dep.swap_icon then
                self.retexture[E .. "/clear_blocker_deposit_icon"] = dep.swap_icon
            end
            self:entry("colonize_deposit_entry", p, dr.x, y, 270, 90, {
                file = CFILE,
                text = {
                    [E .. "/deposit_name/deposit_name"] = "\194\167H" .. self:L(dep.type) .. "\194\167!",
                    [E .. "/deposit_effects"] = table.concat(effects, "\n"),
                    [E .. "/clear_blocker_cost"] = dep.blocker and table.concat(cost, " ") or "",
                },
                -- a blocker's frame 2: not clearable by the player on a planet not its own **[I]**
                frames = { [E .. "/blocker_frame"] = 2 },
                hide = {
                    [E .. "/blocker_frame"] = not dep.blocker or nil, [E .. "/rare_deposit_frame"] = not (not dep.blocker and dep.important) or nil,
                    [E .. "/clear_blocker_deposit_icon"] = not (dep.blocker and dep.swap_icon) or nil,
                },
            })
            y = y + 90 + 4
        end
    end
    -- the designations: the automatic one first (CColonyDesignationEntry with no type)
    local dg = r.rects[CW .. "/designation_container/designation_list/designation_grid_container/designation_gridbox"]
    if dg then
        local p = CW .. "/designations/1"
        local E = p .. "/designation_grid_entry"
        self:entry("designation_grid_entry", p, dg.x, dg.y, 120, 80, {
            file = CFILE, grid = true,
            text = { [E .. "/designation_name"] = self:L("COLONY_AUTOMATIC_DESIGNATION") },
            sprites = { [E .. "/designation_icon"] = "GFX_colony_type_automatic" },
        })
    end
    -- the planet's picture in the designation's frame (planet_portrait_button, the masked
    -- portrait: its environment without a city)
    local B = r.rects[CW .. "/designation_container/planet_portrait_window/planet_portrait_container/planet_portrait_button"]
    local C = r.rects[CW .. "/designation_container/planet_portrait_window/planet_portrait_container"]
    if B and C and d.picture then
        local y0, y1 = math.max(B.y, C.y), math.min(B.y + 400, C.y + C.h)
        local x0, x1 = math.max(B.x, C.x), math.min(B.x + 800, C.x + C.w)
        if y1 > y0 and x1 > x0 then
            local name = string.format("@planet_portrait:%s::0:%d:%d:%d:%d", d.picture, math.floor(y0 - B.y + 0.5), math.floor(y1 - y0 + 0.5),
                math.floor(x0 - B.x + 0.5), math.floor(x1 - x0 + 0.5))
            local item = {
                kind = "sprite", path = CW .. "/designation_container/planet_portrait_window/planet_portrait_container/planet_portrait_button",
                sprite = name, texture = name, sprite_kind = "spriteType", frame = 1, frames = 1, x = x0, y = y0, w = x1 - x0, h = y1 - y0,
            }
            -- under the frame's art: before the portrait window's other items
            local at = #self.items + 1
            for i = 1, #self.items do
                local ip = self.items[i].path
                if ip and ip:find(CW .. "/designation_container/planet_portrait_window", 1, true) == 1 then
                    at = i
                    break
                end
            end
            table.insert(self.items, at, item)
        end
    end
end

-- ---------------------------------------------------------------------------------------------
-- the data: in the world's runtime (engine.world, a save loaded), plain tables of what the window
-- shows, for the front end's runtime (planet.encode, planet.decode carry them across)

local defs_cache, order_cache, vars_cache = {}, {}, {}

-- the game's definitions of a directory (common/...): name -> { block, file, line }
local function defs(game_dir, subdir)
    local d = defs_cache[subdir]
    if not d then
        local source = require("stellar.script.source")
        local v
        d, _, v = source.definitions(game_dir, subdir)
        d = d or {}
        defs_cache[subdir] = d
        vars_cache[subdir] = v or {}
    end
    return d
end

-- the definitions' names in the game's load order (the files by name, each top to bottom: the
-- database index)
local function ordered(game_dir, subdir)
    local o = order_cache[subdir]
    if not o then
        o = {}
        for name, def in pairs(defs(game_dir, subdir)) do
            o[#o + 1] = { name = name, file = tostring(def.file or ""), line = tonumber(def.line) or 0 }
        end
        table.sort(o, function(a, b)
            if a.file ~= b.file then
                return a.file < b.file
            end
            return a.line < b.line
        end)
        for i, e in ipairs(o) do
            o[i] = e.name
        end
        order_cache[subdir] = o
    end
    return o
end

local function block_of(game_dir, subdir, name)
    local def = defs(game_dir, subdir)[name]
    return def and (def.block or def) or nil
end

local function unquote(v)
    if v == nil then
        return nil
    end
    return (tostring(v):gsub('"', ""))
end

local num = tonumber

-- a definition's field (first value; blocks as they are)
local function dfield(block, key)
    if type(block) ~= "table" then
        return nil
    end
    for _, e in ipairs(block) do
        if e.op and e.key and e.key.text == key then
            return e.value.text and unquote(e.value.text) or e.value
        end
    end
    return nil
end

-- all of a definition's `key = { ... }` blocks
local function dblocks(block, key)
    local out = {}
    for _, e in ipairs(type(block) == "table" and block or {}) do
        if e.op and e.key and e.key.text == key and type(e.value) == "table" and e.value.text == nil then
            out[#out + 1] = e.value
        end
    end
    return out
end

-- a block's bare words (`zone_slots = { a b }`)
local function words(block)
    local out = {}
    for _, e in ipairs(type(block) == "table" and block or {}) do
        if e.text then
            out[#out + 1] = unquote(e.text)
        end
    end
    return out
end

-- a block of `key = number` as a list of { key, number }
local function amounts(world, block)
    local out = {}
    for k, v in world.statements(type(block) == "table" and block or nil) do
        if tonumber(v) then
            out[#out + 1] = { k, tonumber(v) }
        end
    end
    return out
end

-- a definition's block with its inline scripts in place
local expanded = setmetatable({}, { __mode = "k" })
local function expand(game_dir, block)
    if type(block) ~= "table" then
        return block
    end
    local e = expanded[block]
    if not e then
        local source = require("stellar.script.source")
        local ok, r = pcall(source.expand, game_dir, block)
        e = ok and r or block
        expanded[block] = e
    end
    return e
end

-- The game's triggers, evaluated by the simulation's script layer (simscript.eval) in a planet's
-- scope; its scripted triggers and values read once (the map's runtime has the world only).
local trigger_errors = {}
local function trigger(game_dir, block, kind, id, from_kind, from_id)
    if type(block) ~= "table" then
        return true
    end
    local db = require("simscript.db")
    if not db.scripted_triggers or next(db.scripted_triggers) == nil then
        local source = require("stellar.script.source")
        db.game_dir = game_dir
        db.fs = db.fs or source.filesystem(game_dir)
        db.scripted_triggers = source.definitions(db.fs, "common/scripted_triggers")
        db.script_values = source.definitions(db.fs, "common/script_values")
        db.scripted_effects = db.scripted_effects or {}
        -- the flags and variables where the save keeps them (engine.load installs this; the
        -- window's triggers only read them)
    end
    -- the definitions the engine's triggers read (engine.defs: E.district_set and the like), a
    -- folder read when first asked for: the map's runtime loads none (engine.load_world)
    local edefs = require("engine.defs")
    if next(edefs.folders) == nil and not getmetatable(edefs.folders) then
        local source = require("stellar.script.source")
        edefs.fs = edefs.fs or db.fs
        setmetatable(edefs.folders, {
            __index = function(t, folder)
                local d = source.definitions(edefs.fs, folder) or {}
                rawset(t, folder, d)
                return d
            end,
        })
    end
    local eval0 = require("simscript.eval")
    -- the planet climate triggers the script layer does not have yet (is_wet: the planet class's
    -- `climate`; the farming districts' anglers names need it), only where it has none
    for _, c in ipairs({ "wet", "dry", "cold" }) do
        local key = "is_" .. c
        if eval0.TRIG and not eval0.TRIG[key] then
            eval0.TRIG[key] = function(e, ctx)
                local sc = ctx.this
                if not sc or sc.kind ~= "planet" then
                    return false
                end
                local world = require("engine.world")
                local cls = unquote(world.field(world.object("planet", sc.id), "planet_class"))
                local climate = dfield(block_of(game_dir, "common/planet_classes", cls or ""), "climate")
                return (climate == c) == (e.value.text ~= "no")
            end
        end
    end
    if not eval0.planet_view_store then
        local ok, why = pcall(function()
            require("engine.scriptstate").install()
        end)
        eval0.planet_view_store = true
        if not ok then
            trigger_errors[#trigger_errors + 1] = "scriptstate: " .. tostring(why)
        end
    end
    local eval = require("simscript.eval")
    local ctx = eval.new_ctx(eval.S(kind, id), from_kind and eval.S(from_kind, from_id) or nil, nil, "planet view")
    local ok, r = pcall(eval.trigger, block, ctx)
    if not ok then
        if #trigger_errors < 8 then
            trigger_errors[#trigger_errors + 1] = tostring(r)
        end
        return nil
    end
    -- PLANET_TRIGGER_DEBUG=1: a false trigger's statements, each with its own result (planet.rs
    -- prints them)
    if not r and os.getenv("PLANET_TRIGGER_DEBUG") and #trigger_errors < 60 then
        local parts = {}
        for _, e in ipairs(block) do
            if e.op and e.key then
                local ok2, r2 = pcall(eval.trigger, { e }, ctx)
                parts[#parts + 1] = e.key.text .. "=" .. tostring(ok2 and r2)
            end
        end
        trigger_errors[#trigger_errors + 1] = kind .. " " .. tostring(id) .. ": " .. table.concat(parts, " ")
    end
    return r and true or false
end

-- the country's technologies (tech_status.technology = { "tech_a" "tech_b" })
local function techs_of(world, country)
    local out = {}
    -- 4.5: tech_status = { technology = "tech_a" level = 1 technology = "tech_b" ... }
    for _, t in ipairs(world.fields(world.field(country, "tech_status"), "technology")) do
        if type(t) == "string" then
            out[unquote(t)] = true
        end
    end
    for _, t in ipairs(world.list(world.path(country, "tech_status", "technology"))) do
        out[unquote(t)] = true
    end
    for _, b in ipairs(world.blocks(world.path(country, "tech_status", "technology"))) do
        local t = unquote(world.field(b, "technology"))
        if t then
            out[t] = true
        end
    end
    return out
end

-- an army's military power (CArmy::CalcMilitaryPower; common/defines NArmy **[V]** the formula in
-- its comment: power = ((effective health x damage a day) ^ 0.65) x 0.25, effective health =
-- health + morale x 0.5, damage a day = damage + morale damage x 0.5, damage = the mean of
-- BASE_DAMAGE_MIN 1.5 and BASE_DAMAGE_MAX 3 x the type's `damage`; the army's modifiers not
-- read **[I]**: 5 defense armies of 250 health and morale give 33.8 each, the game's 169)
local function army_power(health, morale, damage_mult)
    local damage = (1.5 + 3.0) / 2 * (damage_mult or 1)
    local per_day = damage * 1 + damage * 1.0 * 0.5
    local eff = (health or 0) * 1 + (morale or 0) * 0.5
    if eff <= 0 or per_day <= 0 then
        return 0
    end
    return ((eff * per_day) ^ 0.65) * 0.25
end

-- the districts the summary shows (CPlanetView::UpdateSummaryTabColonizable,
-- CPlanetViewDistrictEntry): the main district's type first, then the built and potential types
-- in database order
local function districts_of(game_dir, world, p, id, colony_block, d)
    local DD = "common/districts"
    local list, by_type = {}, {}
    local built_total = 0
    local main_type
    for _, did in ipairs(colony_block and world.list(world.field(colony_block, "districts")) or {}) do
        local db = world.object("districts", tonumber(did))
        local t = db and unquote(world.field(db, "type"))
        if t then
            local e = by_type[t]
            if not e then
                e = { type = t, built = 0, ids = {}, zones = {} }
                by_type[t] = e
            end
            local lvl = num(world.field(db, "level")) or 0
            e.built = e.built + lvl
            built_total = built_total + lvl
            e.ids[#e.ids + 1] = tonumber(did)
            -- the district's zones by slot (4294967295: none)
            if #e.ids == 1 then
                for k, zid in ipairs(world.list(world.field(db, "zones"))) do
                    local z = tonumber(zid) and tonumber(zid) < 4294967295 and world.object("zones", tonumber(zid))
                    if z then
                        local ze = { type = unquote(world.field(z, "type")), buildings = {} }
                        for _, bid in ipairs(world.list(world.field(z, "buildings"))) do
                            local bb = world.object("buildings", tonumber(bid))
                            local bt = bb and unquote(world.field(bb, "type"))
                            if bt then
                                local bdef = block_of(game_dir, "common/buildings", bt)
                                ze.buildings[#ze.buildings + 1] = {
                                    type = bt, icon = "gfx/interface/icons/buildings/" .. (dfield(bdef, "icon") or bt) .. ".dds",
                                    ruined = world.field(bb, "ruined") == "yes", disabled = world.field(bb, "disabled") == "yes",
                                }
                            end
                        end
                        e.zones[k] = ze
                    else
                        e.zones[k] = false
                    end
                end
            end
            main_type = main_type or t
        end
    end
    -- the planet's district capacity: its size and its deposits' planet_max_districts_add **[I]**
    -- (the capital: 18 - 3 blockers = 15, the game's "3/18" = 15 + 3 blocked); a capped type's
    -- cap: its deposits' district_<type>_max_add (generator 1 + 2 + 3 = 6)
    local planet_max, blocked, caps = d.size or 0, 0, {}
    for _, dep in ipairs(d.deposits) do
        for _, m in ipairs(dep.modifiers) do
            if m[1] == "planet_max_districts_add" then
                planet_max = planet_max + m[2]
                if m[2] < 0 then
                    blocked = blocked - m[2]
                end
            else
                local t = m[1]:match("^(district_[%w_]+)_max_add$")
                if t then
                    caps[t] = (caps[t] or 0) + m[2]
                end
            end
        end
    end
    d.district_slots = { max = math.max(0, planet_max), built = built_total }
    local colonized = colony_block ~= nil
    local shown = {}
    for _, t in ipairs(ordered(game_dir, DD)) do
        local def = block_of(game_dir, DD, t)
        local show
        if by_type[t] then
            show = true
        elseif colonized then
            show = trigger(game_dir, dfield(def, "potential"), "planet", id)
        else
            -- (its FROM: the observing country, the player)
            local su = dfield(def, "show_on_uncolonized")
            show = su ~= nil and trigger(game_dir, su, "planet", id, "country", d.player)
        end
        if show then
            shown[#shown + 1] = t
        end
    end
    if not main_type then
        main_type = shown[1]
    end
    for _, t in ipairs(shown) do
        local def = expand(game_dir, block_of(game_dir, DD, t))
        local e = by_type[t] or { type = t, built = 0, zones = {} }
        e.main = t == main_type
        e.name = t .. "_plural"
        -- the first triggered name whose trigger holds
        for _, tn in ipairs(dblocks(def, "triggered_name")) do
            local tr = dfield(tn, "trigger")
            if tr == nil or trigger(game_dir, tr, "planet", id) then
                e.triggered = dfield(tn, "text")
                break
            end
        end
        local icon = dfield(def, "icon") or t
        e.icon = "gfx/interface/icons/districts/" .. icon .. ".dds"
        -- its grid boxes' and background's art (gridbox, district_background: the icon's name)
        e.gridbox = dfield(def, "gridbox") or icon
        e.background = dfield(def, "district_background") or icon
        e.overlay = dfield(def, "overlay_icon")
        -- capped or not (is_uncapped: an empty trigger, or one that holds)
        -- (no is_uncapped, or an empty one: uncapped; the city's 3/18, docs/district 00_DOCUMENTATION)
        local unc = dfield(def, "is_uncapped")
        local uncapped = unc == nil or (type(unc) == "table" and (#unc == 0 or trigger(game_dir, unc, "planet", id)))
        if uncapped then
            e.max = d.district_slots.max + blocked
            e.cap = d.district_slots.max
        else
            local shared = dfield(def, "shared_capacity_modifier") or t
            e.max = math.max(0, caps[shared] or 0)
            e.cap = e.max
        end
        e.uncapped = uncapped
        -- the zone slots: the zone, else whether it is unlocked, else what unlocks it
        local slots = words(dfield(def, "zone_slots"))
        if colonized then
            for k, slot in ipairs(slots) do
                if not e.zones[k] then
                    local sdef = block_of(game_dir, "common/zone_slots", slot)
                    local unlock = dfield(sdef, "unlock")
                    local ok = e.built > 0 and trigger(game_dir, unlock, "planet", id)
                    if ok then
                        e.zones[k] = { open = true }
                    else
                        local requires
                        for _, ct in ipairs(dblocks(unlock, "custom_tooltip")) do
                            requires = dfield(ct, "fail_text")
                            if requires then
                                break
                            end
                        end
                        e.zones[k] = { requires = requires or "" }
                    end
                else
                    local zdef = expand(game_dir, block_of(game_dir, "common/zones", e.zones[k].type))
                    e.zones[k].icon = dfield(zdef, "icon")
                    e.zones[k].max_buildings = tonumber(dfield(zdef, "max_buildings")) or 3
                end
            end
            for k = #slots + 1, #e.zones do
                e.zones[k] = nil
            end
        else
            e.zones = {}
        end
        e.ids = nil
        list[#list + 1] = e
    end
    return list
end

-- the game's scripted variables (common/scripted_variables: `@name = value`), read once
local scripted_vars
local function var(game_dir, text, file_vars)
    if type(text) ~= "string" or text:sub(1, 1) ~= "@" then
        return tonumber(text)
    end
    -- the file's own variables first (source.definitions: without the @)
    if file_vars and file_vars[text:sub(2)] then
        return tonumber(file_vars[text:sub(2)])
    end
    if not scripted_vars then
        scripted_vars = {}
        local source = require("stellar.script.source")
        for _, f in ipairs(source.files(game_dir, "common/scripted_variables", "txt")) do
            local tree = source.parse(game_dir, f)
            for _, e in ipairs(tree or {}) do
                if e.op and e.key and e.key.text:sub(1, 1) == "@" and e.value and e.value.text then
                    scripted_vars[e.key.text] = tonumber(e.value.text)
                end
            end
        end
    end
    return scripted_vars[text]
end

-- The colonize window's data (CSurfaceView::ShowWithPlanet, RefreshExpansionSources): the
-- player's colonizing species (its founder species **[I]**: CCountry::ListColonizerSpecies not
-- read further), each one's habitability (the species' traits' pc_<class>_habitability; an
-- aquatic species +0.2 on a wet planet, -0.2 elsewhere **[I]**: the game's frames, 100% on an
-- ocean world and 0% on a desert for the Uthabulan, ocean preference and aquatic), its
-- traits; the colony ship's cost (the colonizer ship size's costs whose triggers hold, their
-- @variables the game's).
local function colonize_of(game_dir, world, galaxy, p, id, d, pc)
    local out = { species = {}, cost = {} }
    if not pc then
        return out
    end
    local climate = dfield(block_of(game_dir, "common/planet_classes", d.class), "climate")
    local fs = num(world.field(pc, "founder_species_ref"))
    local s = fs and world.object("species", fs)
    if s then
        local traits, hab = {}, 0
        local aquatic = false
        for _, t in ipairs(world.fields(s, "traits")) do
            local tr = type(t) == "table" and world.fields(t, "trait") or { t }
            for _, name in ipairs(tr) do
                name = unquote(name)
                local tdef = block_of(game_dir, "common/traits", name or "")
                local tfile = defs(game_dir, "common/traits")[name or ""]
                local fvars = tfile and vars_cache["common/traits"][tfile.file] or nil
                if tdef then
                    -- its icon: the trait's `icon`, else gfx/interface/icons/traits/<key>.dds
                    -- where there is one
                    local icon = dfield(tdef, "icon") or ("gfx/interface/icons/traits/" .. name .. ".dds")
                    local fh = io.open(game_dir .. "/" .. icon, "rb")
                    if fh then
                        fh:close()
                        traits[#traits + 1] = icon
                    end
                    for k, v in world.statements(dfield(tdef, "modifier")) do
                        if k == d.class .. "_habitability" then
                            hab = hab + (var(game_dir, v, fvars) or 0)
                        end
                    end
                    aquatic = aquatic or name == "trait_aquatic"
                end
            end
        end
        if aquatic then
            hab = hab + (climate == "wet" and 0.2 or -0.2)
        end
        out.species[1] = {
            id = fs, name = galaxy.name_block(world.field(s, "name")), traits = traits,
            habitability = math.max(0, math.min(1, hab)),
        }
    end
    local rorder = {}
    for i, n in ipairs(ordered(game_dir, "common/strategic_resources")) do
        rorder[n] = i
    end
    local sdef = block_of(game_dir, "common/ship_sizes", "colonizer")
    for _, cb in ipairs(dblocks(dfield(sdef, "resources"), "cost")) do
        local ct = dfield(cb, "trigger")
        if ct == nil or trigger(game_dir, ct, "planet", id, "country", d.player) then
            for k, v in world.statements(cb) do
                local n = var(game_dir, v)
                if n and k ~= "mult" then
                    out.cost[#out.cost + 1] = { k, n }
                end
            end
        end
    end
    -- in the resources' database order (CResourceTable::BuildString)
    table.sort(out.cost, function(a, b)
        return (rorder[a[1]] or 1e9) < (rorder[b[1]] or 1e9)
    end)
    return out
end

-- planet.data(game_dir, id) -> table | nil: the planet `id` of the world as the window shows it
function planet.data(game_dir, id)
    local world = require("engine.world")
    local galaxy = require("render.galaxy")
    if not world.colony_planet and world.index then
        world.index()
    end
    local p = world.object("planet", id)
    if not p then
        return nil
    end
    trigger_errors = {}
    -- the player (galaxy.extract's way: the save's meta)
    local player = 0
    local pl = world.meta and world.meta.player
    if type(pl) == "table" then
        for _, b in ipairs(world.blocks(pl)) do
            player = tonumber(world.field(b, "country")) or player
        end
    end
    local class = unquote(world.field(p, "planet_class")) or ""
    local d = {
        id = id,
        name = galaxy.name_block(world.field(p, "name")),
        class = class,
        size = num(world.field(p, "planet_size")) or 0,
        owner = num(world.field(p, "owner")),
        controller = num(world.field(p, "controller")),
        system = num(world.path(p, "coordinate", "origin")),
        colonize_date = unquote(world.field(p, "colonize_date")),
        player = player,
        surveyed = false,
        deposits = {},
    }
    -- surveyed by the player (surveyed_by: a country, or several)
    for _, sv in ipairs(world.fields(p, "surveyed_by")) do
        if tonumber(sv) == player then
            d.surveyed = true
        end
    end
    for _, sv in ipairs(world.list(world.field(p, "surveyed_by"))) do
        if tonumber(sv) == player then
            d.surveyed = true
        end
    end
    local cdef = block_of(game_dir, "common/planet_classes", class)
    d.class_icon = dfield(cdef, "icon")
    d.class_icon_large = dfield(cdef, "icon_large")
    d.picture = unquote(world.field(p, "picture")) or dfield(cdef, "picture") or class
    local colonizable_class = dfield(cdef, "colonizable") == "yes"
    d.colonizable = d.owner == nil and colonizable_class
    -- the planet's deposits (deposit = { type = "d_..." }): the list the management tab shows
    -- (CPlanetView::UpdateDepositsView: every blocker, the others once a type, sorted blockers
    -- first, then important ones, then by the type's database index)
    local cats = defs(game_dir, "common/deposit_categories")
    local dorder = {}
    for i, n in ipairs(ordered(game_dir, "common/deposits")) do
        dorder[n] = i
    end
    local seen, count = {}, {}
    for _, did in ipairs(world.list(world.field(p, "deposits"))) do
        local dep = world.object("deposit", tonumber(did))
        local t = dep and unquote(world.field(dep, "type"))
        if t then
            count[t] = (count[t] or 0) + 1
            local def = block_of(game_dir, "common/deposits", t)
            local cat = dfield(def, "category")
            local cblock = cat and cats[cat] and (cats[cat].block or cats[cat])
            local blocker = dfield(cblock, "blocker") == "yes"
            local e = {
                id = tonumber(did), type = t, category = cat, blocker = blocker,
                important = dfield(cblock, "important") == "yes",
                icon = "gfx/interface/icons/deposits/" .. (dfield(def, "icon") or t) .. ".dds",
                swap = unquote(world.field(dep, "swap_type")),
                time = tonumber(dfield(def, "time")), resources = {}, cost = {}, modifiers = {},
                index = dorder[t] or 1e9,
            }
            local res = dfield(def, "resources")
            for _, pb in ipairs(dblocks(res, "produces")) do
                if dfield(pb, "trigger") == nil then
                    for k, v in world.statements(pb) do
                        if tonumber(v) then
                            e.resources[#e.resources + 1] = { k, tonumber(v) }
                        end
                    end
                end
            end
            for _, cb in ipairs(dblocks(res, "cost")) do
                for k, v in world.statements(cb) do
                    if tonumber(v) then
                        e.cost[#e.cost + 1] = { k, tonumber(v) }
                    end
                end
            end
            local mods = dfield(def, "planet_modifier")
            for k, v in world.statements(type(mods) == "table" and mods or nil) do
                if tonumber(v) then
                    e.modifiers[#e.modifiers + 1] = { k, tonumber(v) }
                end
            end
            if e.swap then
                local sdef = block_of(game_dir, "common/deposits", e.swap)
                e.swap_icon = "gfx/interface/icons/deposits/" .. (dfield(sdef, "icon") or e.swap) .. ".dds"
            end
            d.deposits[#d.deposits + 1] = e
            if blocker or not seen[t] then
                seen[t] = true
                e.listed = true
            end
        end
    end
    for _, e in ipairs(d.deposits) do
        e.count = e.blocker and 1 or count[e.type]
    end
    -- the owner: its flag (the caller's), name, capital, city set, empire base production
    local owner = d.owner and world.object("country", d.owner)
    if owner then
        d.owner_name = galaxy.name_block(world.field(owner, "name"))
        d.owner_capital = num(world.field(owner, "capital"))
        d.city = unquote(world.field(owner, "city_graphical_culture")) or unquote(world.field(owner, "graphical_culture"))
        d.base = amounts(world, world.path(owner, "budget", "current_month", "income", "country_base"))
    end
    -- the sector of the planet's system (sectors.<id>.systems), its owner the planet's
    local pc = world.object("country", player)
    for _, sid in ipairs(world.all("sectors")) do
        local sec = world.object("sectors", sid)
        if sec and num(world.field(sec, "owner")) == d.owner then
            for _, sys in ipairs(world.list(world.field(sec, "systems"))) do
                if tonumber(sys) == d.system then
                    d.sector_name = galaxy.name_block(world.field(sec, "name"))
                    d.sector_type = unquote(world.field(sec, "type"))
                    d.sector_capital = num(world.field(sec, "local_capital"))
                end
            end
        end
    end
    d.megacorp = false
    for _, dlc in ipairs(world.list(world.meta and world.meta.required_dlcs or nil)) do
        if unquote(dlc) == "Megacorp" then
            d.megacorp = true
        end
    end
    -- the colony (planet.colony names it; 4.5: a separate store)
    local cid = num(world.field(p, "colony"))
    local c = cid and world.object("colony", cid)
    d.districts = districts_of(game_dir, world, p, id, c, d)
    if c then
        local col = {
            id = cid,
            stability = num(world.field(c, "stability")) or 0,
            crime = num(world.field(c, "crime")) or 0,
            free_amenities = num(world.field(c, "free_amenities")) or 0,
            free_housing = num(world.field(c, "free_housing")) or 0,
            designation = unquote(world.field(c, "final_designation")),
            ascension_tier = num(world.field(c, "ascension_tier")) or 0,
            governor = num(world.field(c, "governor")),
            pop_groups = {}, jobs = {}, armies = {}, species = {},
        }
        col.designation_icon = dfield(block_of(game_dir, "common/colony_types", col.designation or ""), "icon")
        col.manual_designation = unquote(world.field(c, "designation"))
        col.manual_designation_icon = dfield(block_of(game_dir, "common/colony_types", col.manual_designation or ""), "icon")
        -- the summary's resources: production less upkeep, the empire's base on its capital
        local net, idx = {}, {}
        local function add(k, v)
            if not idx[k] then
                net[#net + 1] = { k, 0 }
                idx[k] = #net
            end
            net[idx[k]][2] = net[idx[k]][2] + v
        end
        for _, r in ipairs(amounts(world, world.field(c, "produces"))) do
            add(r[1], r[2])
        end
        for _, r in ipairs(amounts(world, world.field(c, "upkeep"))) do
            add(r[1], -r[2])
        end
        if d.owner_capital == cid then
            for _, r in ipairs(d.base or {}) do
                add(r[1], r[2])
            end
        end
        -- in the resources' database order (common/strategic_resources)
        local rorder = {}
        for i, n in ipairs(ordered(game_dir, "common/strategic_resources")) do
            rorder[n] = i
        end
        table.sort(net, function(a, b)
            return (rorder[a[1]] or 1e9) < (rorder[b[1]] or 1e9)
        end)
        col.net = net
        -- growth: the month's details (GROWTH_CAT_*), the last month's per species
        local lg = world.field(c, "last_month_growth_data")
        col.growth = num(world.path(lg, "growth_and_size", "growth")) or 0
        local gd, key = {}, nil
        for k, v in world.statements(world.field(lg, "current_month_growth_details")) do
            if k == "key" then
                key = unquote(v)
            elseif k == "value" and key then
                gd[key] = tonumber(v) or 0
            end
        end
        col.growth_details = gd
        local sg, skey = {}, nil
        for k, v in world.statements(world.field(lg, "species")) do
            if k == "key" then
                skey = tonumber(v)
            elseif k == "value" and skey then
                sg[#sg + 1] = { skey, num(world.path(v, "growth_and_size", "growth")) or 0 }
            end
        end
        col.species_growth = sg
        -- pop groups (key = { species category }, size)
        for _, gid in ipairs(world.list(world.field(c, "pop_groups"))) do
            local g = world.object("pop_group", tonumber(gid))
            if g then
                col.pop_groups[#col.pop_groups + 1] = {
                    id = tonumber(gid), species = num(world.path(g, "key", "species")),
                    category = unquote(world.path(g, "key", "category")), size = num(world.field(g, "size")) or 0,
                    habitability = num(world.field(g, "habitability")),
                }
            end
        end
        -- jobs: the type, its category (and the category's display category and rank), the pops
        -- working it (pop_groups = { { pop_group amount } }), its icon
        local JD, CD = "common/pop_jobs", "common/pop_categories"
        local cat_order = {}
        for i, n in ipairs(ordered(game_dir, CD)) do
            cat_order[n] = i
        end
        for _, jid in ipairs(world.list(world.field(c, "pop_jobs"))) do
            local j = world.object("pop_job", tonumber(jid))
            local t = j and unquote(world.field(j, "type"))
            if t then
                local assigned = 0
                for _, pg in ipairs(world.blocks(world.field(j, "pop_groups"))) do
                    assigned = assigned + (num(world.field(pg, "amount")) or 0)
                end
                local jdef = block_of(game_dir, JD, t)
                local cat = dfield(jdef, "category")
                local cdefb = cat and block_of(game_dir, CD, cat)
                local disp = dfield(cdefb, "display_category") or cat
                local ddef = disp and block_of(game_dir, CD, disp)
                -- its icon: the swap type whose trigger holds with the highest weight, else the
                -- default's (NPopJob::CalcIcon -> CJobType::CalcSwap), else the job's key
                local icon, best
                for _, sw in ipairs(dblocks(jdef, "swappable_data")) do
                    for _, dd in ipairs(dblocks(sw, "default")) do
                        icon = icon or dfield(dd, "icon")
                    end
                    for _, st in ipairs(dblocks(sw, "swap_type")) do
                        local w = tonumber(dfield(st, "weight")) or 0
                        if (best == nil or w > best) and trigger(game_dir, dfield(st, "trigger"), "planet", id) then
                            best = w
                            icon = dfield(st, "icon") or icon
                        end
                    end
                end
                icon = icon or dfield(jdef, "icon") or t
                local wf = num(world.field(j, "workforce")) or -1
                local maxwf = num(world.field(j, "max_workforce")) or -1
                col.jobs[#col.jobs + 1] = {
                    id = tonumber(jid), type = t, workforce = wf, max_workforce = maxwf,
                    limit = num(world.field(j, "workforce_limit")) or -1, assigned = assigned,
                    category = cat, display = disp, rank = tonumber(dfield(cdefb, "rank")) or 0,
                    display_rank = tonumber(dfield(ddef, "rank")) or 0, display_index = cat_order[disp or ""] or 1e9,
                    icon = "gfx/interface/icons/jobs/job_" .. icon .. ".dds",
                    category_icon = "gfx/interface/icons/pop_categories/pop_cat_" .. (disp or "unknown") .. ".dds",
                }
            end
        end
        -- species (their names) of the colony's pops
        for _, sid in ipairs(world.list(world.field(c, "species_refs"))) do
            local s = world.object("species", tonumber(sid))
            if s then
                col.species[#col.species + 1] = {
                    id = tonumber(sid), name = galaxy.name_block(world.field(s, "name")) or { key = unquote(world.field(s, "name")) or "" },
                }
            end
        end
        -- armies (the colony's `army` list, in its order): name, type icon, power, health
        local AD = "common/armies"
        local strength, assault = 0, 0
        for _, aid in ipairs(world.list(world.field(c, "army"))) do
            local a = world.object("army", tonumber(aid))
            if a then
                local t = unquote(world.field(a, "type"))
                local adef = block_of(game_dir, AD, t or "")
                local power = army_power(num(world.field(a, "health")), num(world.field(a, "morale")), tonumber(dfield(adef, "damage")))
                local e = {
                    id = tonumber(aid), name = galaxy.name_block(world.field(a, "name")), type = t,
                    icon = dfield(adef, "icon"), health = num(world.field(a, "health")), max_health = num(world.field(a, "max_health")),
                    species = num(world.field(a, "species")), power = power,
                }
                if dfield(adef, "defensive") == "yes" then
                    strength = strength + power
                else
                    assault = assault + power
                end
                col.armies[#col.armies + 1] = e
                if e.species then
                    local known = false
                    for _, s in ipairs(col.species) do
                        known = known or s.id == e.species
                    end
                    local s = not known and world.object("species", e.species)
                    if s then
                        col.species[#col.species + 1] = { id = e.species, name = galaxy.name_block(world.field(s, "name")) or { key = "" } }
                    end
                end
            end
        end
        col.military_strength, col.assault_strength = strength, assault
        -- the army types the colony can recruit (CPlanetView::InitRecruitmentArmies): each type in
        -- database order that is not spawned by pops, whose technologies the owner has and whose
        -- `potential` holds, for each of the colony's species when it has species; sorted by name
        -- (the caller), then species
        local techs = owner and techs_of(world, owner) or {}
        local rec = {}
        for _, t in ipairs(ordered(game_dir, AD)) do
            local adef = block_of(game_dir, AD, t)
            -- (pop-spawned and defensive types are not recruited **[I]**: the capital lists only
            -- the assault army)
            if dfield(adef, "is_pop_spawned") ~= "yes" and dfield(adef, "defensive") ~= "yes" then
                local ok = true
                for _, pre in ipairs(words(dfield(adef, "prerequisites"))) do
                    ok = ok and techs[pre] == true
                end
                -- potential_country: the owner's scope
                if ok and dfield(adef, "potential_country") ~= nil then
                    ok = trigger(game_dir, dfield(adef, "potential_country"), "country", d.owner) == true
                end
                if ok then
                    local cost = {}
                    for _, cb in ipairs(dblocks(dfield(adef, "resources"), "cost")) do
                        local ct = dfield(cb, "trigger")
                        if ct == nil or trigger(game_dir, ct, "planet", id, "country", d.owner) then
                            for k, v in world.statements(cb) do
                                if tonumber(v) then
                                    cost[#cost + 1] = { k, tonumber(v) }
                                end
                            end
                        end
                    end
                    local entry = { type = t, icon = dfield(adef, "icon"), time = tonumber(dfield(adef, "time")), cost = cost }
                    if dfield(adef, "has_species") ~= "no" then
                        -- the colony's species, its enslaved ones left out **[I]** (the capital's
                        -- Qvagh slaves recruit no assault army in the game's frame)
                        local done = {}
                        for _, es in ipairs(world.list(world.field(c, "enslaved_species_refs"))) do
                            done[tonumber(es) or -1] = true
                        end
                        for _, g in ipairs(col.pop_groups) do
                            if g.species and not done[g.species] then
                                done[g.species] = true
                                if trigger(game_dir, dfield(adef, "potential"), "planet", id, "species", g.species) then
                                    rec[#rec + 1] = { type = t, icon = entry.icon, time = entry.time, cost = cost, species = g.species }
                                end
                            end
                        end
                    elseif trigger(game_dir, dfield(adef, "potential"), "planet", id) then
                        rec[#rec + 1] = entry
                    end
                end
            end
        end
        d.recruitable = rec
        -- the summary's habitability: the best of the colony's pop groups **[I]** (the game: the
        -- best of the player's species for the planet)
        local best
        for _, g in ipairs(col.pop_groups) do
            if g.habitability and (best == nil or g.habitability > best) then
                best = g.habitability
            end
        end
        d.habitability = best
        d.colony = col
    elseif not colonizable_class then
        d.habitability = 0
    end
    if d.colonizable then
        d.colonize = colonize_of(game_dir, world, galaxy, p, id, d, pc)
    end
    if #trigger_errors > 0 then
        d.errors = trigger_errors
    end
    return d
end

-- planet.encode(value) -> text: a Lua expression of plain data (numbers, strings, booleans, tables)
function planet.encode(v)
    local t = type(v)
    if t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then
            return "0"
        end
        return string.format("%.17g", v)
    elseif t == "string" then
        return string.format("%q", v)
    elseif t == "boolean" then
        return tostring(v)
    elseif t == "table" then
        local parts = {}
        local n = #v
        for i = 1, n do
            parts[#parts + 1] = planet.encode(v[i])
        end
        for k, x in pairs(v) do
            if not (type(k) == "number" and k >= 1 and k <= n and k == math.floor(k)) then
                parts[#parts + 1] = "[" .. planet.encode(k) .. "]=" .. planet.encode(x)
            end
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "nil"
end

function planet.decode(text)
    local f = (loadstring or load)("return " .. text)
    return f and f() or nil
end

return planet
