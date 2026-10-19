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
    -- and its label dimmed (the game's frames: a disabled button's text is grey too)
    self.dimmed[path .. "/text"] = true
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
    -- the clicks: the view's own actions (the window's `planet:` actions)
    o.actions = o.actions or self.actions
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
    -- previous / next planet of the owner's, the camera to the planet (planet.rs act)
    self.actions[P .. "/header_actions/previous_planet"] = "planet:prev"
    self.actions[P .. "/header_actions/next_planet"] = "planet:next"
    self.actions[P .. "/header_actions/zoom_to_planet_button"] = "planet:zoom"
    -- the name: CColonyRenameDialog (the player's colony); move capital: CMoveCapitalDialog
    if self.mine then
        self.actions[P .. "/colony_rename_button"] = "planet:dialog:rename"
        self.actions[P .. "/header_actions/move_capital"] = "planet:dialog:move_capital"
    end
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
    if not (d and d.decision) then
        hide[A .. "/decision_progress_window"] = true
    elseif self.mine then
        self.actions[A .. "/decision_progress_window/cancel_decisions_button"] = "planet:cmd:cancel_decision"
    end
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
        self.actions[P .. "/" .. t .. "_tab"] = "planet:tab:" .. t
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
        -- a star's description begins with its luminosity (its class's `climate`, luminosity_N:
        -- "Luminosity: Strong", the game's frame of the home star) **[V]** the frame
        local desc = d and self:L(d.class .. "_desc") or ""
        if d and d.climate and d.climate:match("^luminosity") then
            desc = self:L(d.climate) .. "\n" .. desc
        end
        text[S .. "/uncolonizable_planet_window/planet_desc_window/planet_desc"] = desc
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
        if self.mine then
            self.actions[DB .. "/designation_button"] = "planet:side:designation"
            -- the gear: the automation settings in the side bar (the game's frames: the button
            -- keeps its frame, the side bar shows Automation Settings)
            self.actions[DB .. "/automated_development_button"] = "planet:side:automation"
        end
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
        -- terraforming a star: disabled (IsTerraformable; the game's frame of the home star)
        if d.star or not d.can_terraform then
            self:disable(SS .. "/terraform_button")
        else
            self.actions[SS .. "/terraform_button"] = "planet:side:terraform"
        end
        if self.mine then
            self.actions[SS .. "/decisions_button"] = "planet:side:decisions"
        end
        -- the build queue (CConstructionQueueListController)
        self.later[#self.later + 1] = function(r)
            self:queue_list(r.rects[S .. "/summary_side_window/summary_build_queue_window/build_queue_subwindow/build_queue"], S .. "/queue")
        end
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
            -- a click: its details in the side bar (the building's own entry: building_details)
            if b.id then
                self.actions[E .. "/open_building_button"] = "planet:side:building:" .. b.id
                if self.side == "building:" .. b.id then
                    hide[E .. "/selected_building_icon"] = nil
                end
            end
        else
            hide[E .. "/building_slot_icons/building_bg"] = true
            hide[E .. "/building_slot_icons/building_icon"] = true
            -- an empty slot: the buildings the zone takes (construction, the player's colony)
            if self.mine and zone.id then
                self.actions[E .. "/open_building_button"] = "planet:side:construction:" .. zone.id .. ":" .. i
                if self.side == "construction:" .. zone.id .. ":" .. i then
                    hide[E .. "/selected_building_icon"] = nil
                end
            end
        end
        self:entry("planet_building_entry", p, x, y, grid.w, grid.h, { hide = hide, grid = true })
    end
end

-- a zone slot: its zone's buildings, else the new-zone button, else what unlocks it
function View:zone_slot(entry_window, base, zpath, zone, inner, dist)
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
            -- the zones the slot takes (zone_construction)
            if dist and dist.district_id and zone.slot then
                self.actions[zpath .. "/zone_button"] = "planet:side:zone_construction:" .. dist.district_id .. ":" .. zone.slot
            end
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
    else
        -- Build: the district's next level queued (the simulation: planet.command)
        self.actions[E .. "/build_district"] = "planet:cmd:build_district:" .. dist.type
    end
    -- a click on the entry: the district's details in the side bar
    self.actions[E .. "/district_button"] = "planet:side:district:" .. dist.type
    if self.side == "district:" .. dist.type then
        self.hide_e[E .. "/selection_highlight"] = nil
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
    local zgrid = self:zone_slot(window, E, E .. "/zone", zone, { "zone", "buildings_box" }, dist)
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
            local bgrid = self:zone_slot("zone_entry", zp, Z, z, { "buildings_box" }, dist)
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
        later = {}, retexture = {}, bg_frames = {}, icon_frames = {}, zone_sprites = {}, resprite = {}, tints = {}, dimmed = {},
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
        -- (nothing but the summary until the planet's data has come: RENDER_PLANET.data is nil
        -- while the simulation has not answered, and the window then shows its frame and name)
        summary = true, management = d ~= nil,
        population = v.completed, armies = v.completed, corporate = v.completed,
    }
    if not can[v.tab] then
        v.tab = "summary"
    end
    v.can_open = can
    local first = #items + 1

    v.side = st.side
    v:header()
    v:tabs()
    if v.side and v.completed then
        v:side_bar()
    end
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
    -- the rename button: "size set by code to match name": the name's own rectangle takes the
    -- click (CColonyRenameDialog)
    local nr = r.rects[P .. "/planet_name"]
    local inv = ctx.db.sprites.GFX_invisible
    if v.mine and nr and inv and inv.texture then
        items[#items + 1] = {
            kind = "sprite", path = P .. "/colony_rename_button/hit", sprite = "GFX_invisible", texture = inv.texture,
            sprite_kind = "spriteType", frame = 1, frames = inv.frames or 1, x = nr.x, y = nr.y, w = nr.w, h = nr.h,
            button = { name = "colony_rename_button", action = "planet:dialog:rename" },
        }
    end
    v:portrait(r, first)
    -- the colonize window, over the planet view
    if st.colonize and d and d.colonizable then
        v:colonize_window()
    end
    if v.side and v.side:match("^resettle") and v.mine then
        v:resettle_window()
    end
    if st.dialog then
        v:dialog(st.dialog, st.text)
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
    for i = first, #items do
        local it = items[i]
        if it.kind == "text" and v.dimmed[it.path] then
            for _, sp in ipairs(it.spans or {}) do
                local c = sp.colour or { 1, 1, 1 }
                sp.colour = { c[1] * 0.55, c[2] * 0.55, c[3] * 0.55 }
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

-- ---------------------------------------------------------------------------------------------
-- the side bar (side_bar_window; CPlanetView +0x390, UpdateSidebarContents @0x306b870): the
-- window of what was clicked, its list, its buttons

local SB = P .. "/side_bar_window"
local SIDE_WINDOWS = {
    district = "district_details_window", building = "building_details_window", construction = "construction_window",
    zone_construction = "zone_construction_window", designation = "designation_selection_window",
    decisions = "decisions_window", terraform = "terraform_window", automation = "automation_settings_window",
    queue = "build_queue_window", pop = "pop_details_window", job = "job_summary_window",
    district_construction = "district_construction_window",
}
local ALL_SIDE = {
    "building_details_window", "district_details_window", "pop_details_window", "terraform_window",
    "automation_settings_window", "decisions_window", "job_summary_window", "designation_selection_window",
    "construction_window", "district_construction_window", "zone_construction_window", "build_queue_window",
}

-- a cost as the game's GetCostDesc writes it: its days, then its resources
local function cost_text(cost, time)
    local parts = {}
    if time and time > 0 then
        parts[#parts + 1] = "\194\163time\194\163 " .. math.floor(time + 0.5)
    end
    for _, c in ipairs(cost or {}) do
        parts[#parts + 1] = "\194\163" .. c[1] .. "\194\163 " .. col("Y", math.floor(c[2] + 0.5))
    end
    return table.concat(parts, " ")
end

function View:side_bar()
    local kind = self.side:match("^([%w_]+)")
    local win = SIDE_WINDOWS[kind or ""]
    if not win then
        return
    end
    self.only.side_bar_window = true
    for _, w in ipairs(ALL_SIDE) do
        if w ~= win then
            self.hide[SB .. "/" .. w] = true
        end
    end
    self.hide[SB .. "/category_tabs"] = true
    self.actions[SB .. "/close"] = "planet:side_close"
    local sd = self.d.side or {}
    local text, hide = self.text, self.hide
    if kind == "district" then
        local W = SB .. "/district_details_window"
        local dist
        for _, x in ipairs(self.d.districts or {}) do
            if x.type == sd.type then
                dist = x
            end
        end
        text[W .. "/district_info/district_name/district_name"] = self:L(sd.type or "")
        -- (its effects, upkeep and jobs, and the specializations' details: not done here)
        text[W .. "/district_info/district_effects"] = ""
        if dist and dist.icon then
            self.retexture[W .. "/district_info/district_icon/district_icon"] = dist.icon
        end
        if dist and dist.overlay then
            self.sprites[W .. "/district_info/district_icon/district_overlay_icon"] = dist.overlay
        else
            hide[W .. "/district_info/district_icon/district_overlay_icon"] = true
        end
        if self.mine then
            self.actions[W .. "/build_district"] = "planet:cmd:build_district:" .. (sd.type or "")
            -- Downgrade: CDestroyDistrictDialog (its Yes: remove_district); Replace: the district
            -- construction window (side bar 10); Clear Blocker: the planet's blocker queued
            self.actions[W .. "/destroy_district"] = "planet:dialog:destroy_district:" .. (sd.type or "")
            self.actions[W .. "/replace_district"] = "planet:side:district_construction:" .. (sd.type or "")
            self.actions[W .. "/quick_clear_blocker"] = "planet:cmd:quick_clear_blocker"
        end
        -- the district's zones (zone_details_entry: "District Specialization N Details", the
        -- zone, Replace: zone construction for its slot)
        self.later[#self.later + 1] = function(r)
            local i = 0
            self:side_list(r.rects[W .. "/zones_list"], W .. "/z", "zone_details_entry", sd.zones or {}, function(E, z)
                i = i + 1
                return {
                    [E .. "/zone_details_text"] = self:F("zone_details_text", { NUM = i }),
                    [E .. "/zone_details/zone_name/zone_name"] = self:L(z.type),
                    [E .. "/zone_details/zone_effects"] = "",
                }, {}, (self.mine and sd.district) and ("planet:side:zone_construction:" .. sd.district .. ":" .. z.slot) or nil,
                    E .. "/replace_zone", { [E .. "/zone_details/zone_icon/zone_icon"] = z.icon }
            end)
        end
    elseif kind == "district_construction" then
        -- Replace's list: a district type instead of the one replaced (replace_district)
        local W = SB .. "/district_construction_window"
        self.later[#self.later + 1] = function(r)
            self:side_list(r.rects[W .. "/district_constructions_list"], W .. "/d", "planet_district_construction_entry", sd.list or {}, function(E, e)
                return {
                    [E .. "/district_name/district_name"] = self:L(e.type),
                    [E .. "/district_cost"] = cost_text(e.cost, e.time),
                    [E .. "/district_effects"] = "",
                }, { [E .. "/district_icon/district_icon"] = e.icon },
                    self.mine and ("planet:cmd:replace_district:" .. tostring(sd.replace) .. ":" .. e.type) or nil, E .. "/background"
            end)
        end
    elseif kind == "building" then
        local W = SB .. "/building_details_window"
        text[W .. "/building_info/building_name/building_name"] = self:L(sd.type or "")
        text[W .. "/building_info/building_effects"] = ""
        if sd.icon then
            self.retexture[W .. "/building_info/building_icon/building_icon"] = sd.icon
        end
        if not sd.ruined then
            hide[W .. "/building_info/building_icon/ruined_building_icon"] = true
        end
        -- the destroy button: Downgrade for a building something upgrades into (the game's
        -- frames: the capital's) **[I]**; its Yes: destroy_building
        text[W .. "/destroy_building"] = self:L(sd.downgrade and "DOWNGRADE" or "DESTROY")
        text[W .. "/enable_disable_building"] = self:L(sd.disabled and "ENABLE" or "DISABLE")
        if self.mine and sd.id then
            if sd.can_demolish ~= false then
                self.actions[W .. "/destroy_building"] = "planet:dialog:destroy_building:" .. sd.id
            else
                self:disable(W .. "/destroy_building")
            end
            self.actions[W .. "/enable_disable_building"] = "planet:cmd:toggle_building:" .. sd.id
            self.actions[W .. "/repair_building"] = "planet:cmd:repair_building:" .. sd.id
            if sd.zone and sd.slot then
                self.actions[W .. "/replace_building"] = "planet:side:construction:" .. sd.zone .. ":" .. sd.slot .. ":" .. sd.id
            end
        end
        if not sd.ruined then
            self:disable(W .. "/repair_building")
            self.actions[W .. "/repair_building"] = nil
        end
        if #(sd.upgrades or {}) == 0 then
            hide[W .. "/upgrades"] = true
        end
        self.later[#self.later + 1] = function(r)
            self:side_list(r.rects[W .. "/upgrades/upgrades_list"], W .. "/up", "planet_construction_entry", sd.upgrades or {}, function(E, e)
                return {
                    [E .. "/building_name/building_name"] = self:L(e.type),
                    [E .. "/building_cost"] = cost_text(e.cost, e.time),
                    [E .. "/building_effects"] = "",
                }, { [E .. "/building_icon/building_icon"] = e.icon },
                    self.mine and ("planet:cmd:upgrade_building:" .. sd.id .. ":" .. e.type) or nil, E .. "/button_build"
            end)
        end
    elseif kind == "construction" then
        local W = SB .. "/construction_window"
        -- by name (the game's frames: Alloy Foundries, Civilian Industries, Commercial Zones, ...)
        -- **[I]** (the category tabs above: not done here)
        local list = {}
        for i, e in ipairs(sd.list or {}) do
            list[i] = e
        end
        table.sort(list, function(x, y) return self:L(x.type) < self:L(y.type) end)
        self.later[#self.later + 1] = function(r)
            self:side_list(r.rects[W .. "/constructions_list"], W .. "/c", "planet_construction_entry", list, function(E, e)
                return {
                    [E .. "/building_name/building_name"] = self:L(e.type),
                    [E .. "/building_cost"] = cost_text(e.cost, e.time),
                    [E .. "/building_effects"] = "",
                }, { [E .. "/building_icon/building_icon"] = e.icon },
                    (self.mine and e.allowed) and (sd.replace and ("planet:cmd:replace_building:" .. sd.replace .. ":" .. e.type)
                        or ("planet:cmd:build_building:" .. sd.zone .. ":" .. e.type)) or nil, E .. "/button_build"
            end)
        end
    elseif kind == "zone_construction" then
        local W = SB .. "/zone_construction_window"
        self.later[#self.later + 1] = function(r)
            self:side_list(r.rects[W .. "/zone_constructions_list"], W .. "/z", "planet_zone_construction_entry", sd.list or {}, function(E, e)
                return {
                    [E .. "/zone_name/zone_name"] = self:L(e.type),
                    [E .. "/zone_cost"] = cost_text(e.cost, e.time),
                    [E .. "/zone_effects"] = "",
                }, {}, (self.mine and e.allowed) and ("planet:cmd:build_zone:" .. sd.district .. ":" .. sd.slot .. ":" .. e.type) or nil,
                    E .. "/button_build", { [E .. "/zone_icon/zone_icon"] = e.icon }
            end)
        end
    elseif kind == "designation" then
        local W = SB .. "/designation_selection_window"
        self.later[#self.later + 1] = function(r)
            self:side_list(r.rects[W .. "/designations_list"], W .. "/d", "planet_designation_entry", sd.list or {}, function(E, e)
                -- the automatic entry: SET_DESIGNATION_AUTOMATIC and its _DESC (the game's frames)
                -- **[I]** its icon (the game's is a planet with a gear)
                local auto = e.type == "auto"
                return {
                    [E .. "/designation_name/designation_name"] = self:L(auto and "SET_DESIGNATION_AUTOMATIC" or e.type),
                    [E .. "/designation_effects/designation_effects"] = self:L(auto and "SET_DESIGNATION_AUTOMATIC_DESC" or (e.type .. "_desc")),
                }, {}, self.mine and ("planet:cmd:designation:" .. e.type) or nil, E .. "/button_designation",
                    { [E .. "/designation_icon"] = e.icon }
            end)
        end
    elseif kind == "decisions" then
        local W = SB .. "/decisions_window"
        -- by name (the game's frames: Declare Population Controls, Distribute Luxury Goods, ...)
        local list = {}
        for i, e in ipairs(sd.list or {}) do
            list[i] = e
        end
        table.sort(list, function(x, y) return self:L(x.type) < self:L(y.type) end)
        self.later[#self.later + 1] = function(r)
            self:side_list(r.rects[W .. "/decisions_list"], W .. "/d", "planet_decision_entry", list, function(E, e)
                -- a click enacts it (CEnactDecisionCommand: allow, the cost) (its effects' text:
                -- not done here)
                local icon = e.icon and ("GFX_" .. e.icon)
                if self.mine and e.allowed then
                    self.actions[E .. "/button_decision"] = "planet:cmd:decision:" .. e.type
                end
                return {
                    [E .. "/decision_name/decision_name"] = self:L(e.type),
                    [E .. "/decision_effects/decision_effects"] = "",
                    [E .. "/decision_cost"] = cost_text(e.cost),
                }, {}, nil, nil, { [E .. "/decision_icon"] = icon and self.ctx.db.sprites[icon] and icon or nil }
            end)
        end
    elseif kind == "terraform" then
        local W = SB .. "/terraform_window"
        if self.d.terraforming then
            -- the ongoing terraforming: its target, days left, Abort (CCancelTerraformationCommand)
            local T = W .. "/terraforming_ongoing_window"
            local left = math.max(0, math.ceil((self.d.terraforming.total or 0) - (self.d.terraforming.progress or 0)))
            text[T .. "/terraforming_time"] = "\194\163time\194\163 " .. left
            text[T .. "/abort"] = self:L("ABORT")
            if self.mine then
                self.actions[T .. "/abort"] = "planet:cmd:cancel_terraform"
            end
        else
            hide[W .. "/terraforming_ongoing_window"] = true
        end
        local links = {}
        for _, e in ipairs(sd.list or {}) do
            if e.shown ~= false then
                links[#links + 1] = e
            end
        end
        self.later[#self.later + 1] = function(r)
            self:side_list(r.rects[W .. "/terraform_list"], W .. "/t", "planet_terraforming_entry", links, function(E, e)
                if self.mine and e.allowed and e.index and not self.d.terraforming then
                    self.actions[E .. "/terraform_button"] = "planet:cmd:terraform:" .. e.index
                end
                -- (terraforming: not done here)
                return {
                    [E .. "/planet_class_name/planet_class_name"] = self:L(e.to or ""),
                    [E .. "/planet_class_name/habitability"] = "",
                    [E .. "/terraforming_cost"] = cost_text(e.cost),
                    [E .. "/terraforming_time"] = e.duration and ("\194\163time\194\163 " .. e.duration) or "",
                }, {}, nil, nil, { [E .. "/planet_class_from_icon"] = self.d.class_icon, [E .. "/planet_class_to_icon"] = e.icon }
            end)
        end
    elseif kind == "queue" then
        local W = SB .. "/build_queue_window"
        self.later[#self.later + 1] = function(r)
            self:queue_list(r.rects[W .. "/build_queue_subwindow/build_queue"], W .. "/q")
        end
    end
end

-- a side bar list: an entry per element (fill(E, e) -> texts, retextures, action, the button the
-- action is on, sprites), the list's spacing, entries while they fit
function View:side_list(rect, prefix, window, list, fill)
    if not rect then
        return
    end
    local h = height_of(self.ctx.game_dir, window)
    local y = rect.y
    for i, e in ipairs(list) do
        if y + h > rect.y + rect.h + 1 then
            break
        end
        local p = prefix .. "/" .. i
        local E = p .. "/" .. window
        local texts, tex, action, button, sprites = fill(E, e)
        for k, v in pairs(tex or {}) do
            self.retexture[k] = v
        end
        if action and button then
            self.actions[button] = action
        end
        self:entry(window, p, rect.x, y, rect.w, h, { text = texts, sprites = sprites or {} })
        y = y + h + 4
    end
end

-- the planet's build queue (planet_build_queue_item_entry): the item being built, its time left
-- (BUILD_TIME_REMAINING "£time£ N" in the active slots, else QUEUED_NUMBER "#N"), its progress
function View:queue_list(rect, prefix)
    if not rect then
        return
    end
    local h = height_of(self.ctx.game_dir, "planet_build_queue_item_entry")
    for i, q in ipairs(self.d.queue or {}) do
        local y = rect.y + (i - 1) * h
        if y + h > rect.y + rect.h + 1 then
            break
        end
        local p = prefix .. "/" .. i
        local E = p .. "/planet_build_queue_item_entry"
        local left = math.max(0, (q.needed or 0) - (q.progress or 0))
        local frac = (q.needed or 0) > 0 and (q.progress or 0) / q.needed or 0
        self.icon_frames[E .. "/progressbar"] = math.max(1, math.min(100, math.floor(frac * 100 + 0.5)))
        -- the row cancels it (CRemoveBuildableFromQueueCommand, its resources back); the arrows
        -- move it a place (Shift: to the end **[I]** not read here)
        local hd = {}
        if self.mine and q.id then
            self.actions[E .. "/cancel_button"] = "planet:cmd:queue_cancel:" .. q.id
            self.actions[E .. "/priority_upwards"] = "planet:cmd:queue_up:" .. q.id
            self.actions[E .. "/priority_downwards"] = "planet:cmd:queue_down:" .. q.id
        end
        if #(self.d.queue or {}) < 2 or not self.mine then
            hd[E .. "/priority_upwards"], hd[E .. "/priority_downwards"] = true, true
        end
        self:entry("planet_build_queue_item_entry", p, rect.x, y, rect.w, h, {
            text = {
                [E .. "/title"] = q.kind == "decision" and self:L(q.type or "") or self:L(q.type or ""),
                [E .. "/time"] = q.active and self:F("BUILD_TIME_REMAINING", { DAYS = math.ceil(left) }) or self:F("QUEUED_NUMBER", { NUMBER = q.position }),
                [E .. "/name"] = "",
            },
            hide = hd,
        })
    end
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
function View:checkbox(path, sprite, x, y, checked, action)
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
        button = { name = path:match("[^/]+$"), action = action },
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
                local on = c[1] == "deploy_in_orbit_checkbox" and colony.deploy_in_orbit ~= false or c[1] == "army_builder_checkbox" and colony.army_builder ~= false
                self:checkbox(D .. "/armies_stats_window/" .. c[1], "GFX_checkbox_20_20_01", sw.x + c[2], sw.y + c[3], on,
                    self.mine and ("planet:cmd:" .. (c[1] == "deploy_in_orbit_checkbox" and "deploy_in_orbit" or "army_builder")) or nil)
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
            else
                self.actions[E .. "/disband_army"] = "planet:dialog:disband:" .. a.id
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
            -- a click recruits it (the army queue: the simulation)
            self.actions[E .. "/recruit_button"] = "planet:cmd:recruit:" .. a.type .. ":" .. tostring(a.species or "")
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
        if dep.blocker and self.mine then
            self.actions[E .. "/clear_blocker_button"] = "planet:cmd:clear_blocker:" .. dep.id
        end
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
    else
        -- the manual resettlement window; Restore Jobs: every job's limit its maximum
        self.actions[PW .. "/resettle_button"] = "planet:side:resettle"
        self.actions[PW .. "/restore_jobs_button"] = "planet:cmd:restore_jobs"
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


-- ---------------------------------------------------------------------------------------------
-- the view's dialogs: CColonyRenameDialog (rename_dialog.gui), and the confirmations
-- (CPopupMessageYesNo, popup.gui yes_no_popup_window): CDestroyBuildingDialog,
-- CDestroyDistrictDialog, CMoveCapitalDialog, the army's disband. OK / Yes: planet:dialog_ok (the
-- command, planet.rs); Cancel / No: planet:dialog_close; Escape closes, Return accepts.

function View:dialog(kind, typed)
    local what, arg = kind:match("^([%w_]+):?(.*)$")
    if what == "rename" then
        local P = "/rename_dialog"
        -- the edit box: the name typed, else the planet's (the game's box starts with it)
        local text = typed or self.name
        local r = self:lay("rename_dialog", {
            file = "interface/rename_dialog.gui",
            hide = { [P .. "/RandomizeButton"] = true },
            actions = { [P .. "/AgreeButton"] = "planet:dialog_ok", [P .. "/DeclineButton"] = "planet:dialog_close" },
        })
        local rect = r.rects[P .. "/editbox"]
        if rect then
            self.items[#self.items + 1] = {
                kind = "text", path = P .. "/editbox/text", font = "malgun_goth_24", text = text .. "|",
                spans = { { text = text .. "|", colour = { 1, 1, 1 } } }, x = rect.x + 4, y = rect.y, w = rect.w - 8, h = rect.h,
                format = "left", valign = "center", fixed = true,
            }
        end
        return
    end
    local P = "/yes_no_popup_window"
    local title, desc
    if what == "destroy_building" then
        local sd = self.d.side or {}
        title = self:L("DESTROY_BUILDING_TITLE")
        desc = self:F("DESTROY_BUILDING_DESC", { NAME = self:L(sd.type or "") })
    elseif what == "destroy_district" then
        title = self:L("DESTROY_DISTRICT_TITLE")
        desc = self:F("DESTROY_DISTRICT_DESC", { NAME = self:L(arg) })
    elseif what == "move_capital" then
        title = self:L("MOVE_CAPITAL")
        desc = self:F("MOVE_CAPITAL_CONFIRM", { PLANET = self.name, EXTRA = "", COST = 0 })
    elseif what == "disband" then
        title = self:L("DISBAND_TITLE")
        desc = self:L("DISBAND_DESC")
    else
        return
    end
    self:lay("yes_no_popup_window", {
        file = "interface/popup.gui",
        text = { [P .. "/title"] = title, [P .. "/description"] = desc },
        actions = { [P .. "/AgreeButton"] = "planet:dialog_ok", [P .. "/DeclineButton"] = "planet:dialog_close" },
    })
end

-- ---------------------------------------------------------------------------------------------
-- the manual resettlement window (manual_resettlement_view.gui, ShowManualResettlementView): this
-- colony on the left, another of the player's on the right (its dropdown: the next one on a
-- click), each side's pop groups; a left group's Resettle moves POP_BULK_UNIT_SIZE of it right

local RFILE = "interface/manual_resettlement_view.gui"
local RW = "/manual_resettlement_view"

function View:resettle_window()
    local sd = self.d.side or {}
    local cols, target = sd.colonies or {}, sd.target
    local names = require("render.names")
    local text, actions, hide = {}, {}, {}
    actions[RW .. "/close"] = "planet:side_close"
    text[RW .. "/left_planet/current"] = self.name
    hide[RW .. "/left_planet/expand_button"] = true
    hide[RW .. "/left_planet/expanded_window"] = true
    hide[RW .. "/right_planet/expanded_window"] = true
    if target then
        text[RW .. "/right_planet/current"] = names.format(self.loc, target.name)
        -- the dropdown: the next colony (the game's expanded list **[I]**)
        local nxt
        for i, x in ipairs(cols) do
            if x.planet == target.planet then
                nxt = cols[i % #cols + 1]
            end
        end
        if nxt then
            actions[RW .. "/right_planet/expand_button"] = "planet:side:resettle:" .. nxt.planet
        end
    else
        text[RW .. "/right_planet/current"] = self:L("PLANET_VIEW_RESETTLE_NOT_ENOUGH_PLANETS")
    end
    local r = self:lay("manual_resettlement_view", { file = RFILE, text = text, actions = actions, hide = hide })
    local function groups(list, rect, prefix, window, can)
        if not rect then
            return
        end
        local h = 75
        for i, g in ipairs(list) do
            local y = rect.y + (i - 1) * h
            if y + h > rect.y + rect.h + 1 then
                break
            end
            local p = prefix .. "/" .. i
            local E = p .. "/" .. window
            local acts = {}
            if can and target then
                acts[E .. "/resettle"] = "planet:cmd:resettle:" .. g.id .. ":" .. target.colony
            end
            self:entry(window, p, rect.x, y, rect.w, h, {
                file = RFILE, actions = acts,
                text = {
                    [E .. "/pop_group_desc/species_name"] = self.species_names[g.species] or "",
                    [E .. "/pop_group_desc/category_name"] = self:L("pop_cat_" .. tostring(g.category or "")),
                    [E .. "/pop_group_desc/pop_amount"] = tostring(g.size or 0),
                },
                hide = can and {} or { [E .. "/resettle"] = true },
            })
        end
    end
    groups(self.d.colony and self.d.colony.pop_groups or {}, r.rects[RW .. "/manual_resettlement_view_planet_entry/pops_jobs_list_left"], RW .. "/l",
        "resettlement_pop_entry_left", true)
    groups(target and target.pop_groups or {}, r.rects[RW .. "/manual_resettlement_view_planet_entry/pops_jobs_list_right"], RW .. "/r",
        "resettlement_pop_entry_right", false)
end

local CFILE = "interface/colonize_planet_view.gui"
local CW = "/expansion_planner_surface_view"

function View:colonize_window()
    local d = self.d
    local c = d.colonize or { species = {}, cost = {} }
    local text, hide, actions = {}, {}, {}
    text[CW .. "/title"] = self:F("EXPANSION_PLANNER_SURFACE_VIEW", { TARGET_PLANET = self.name })
    actions[CW .. "/close"] = "planet:colonize_close"
    -- (no hostiles known: HasHostiles **[I]**)
    hide[CW .. "/has_intel_hostile"] = true
    text[CW .. "/modifiers_container/planet_class_container/planet_class_name"] = self:L(d.class)
    text[CW .. "/modifiers_container/planet_class_container/planet_size_container/planet_size_amount"] = tostring(d.size)
    hide[CW .. "/designation_container/designation_desc_container"] = true
    -- the districts' header: the planet's slots (DASH while not surveyed)
    local DH = CW .. "/districts_window/districts_window_title_bar/planet_total_districts_container"
    text[DH .. "/planet_num_districts/planet_districts_amount"] = d.surveyed and d.district_slots and tostring(d.district_slots.max) or self:L("DASH")
    -- Colonize: greyed until a source is selected (CExpansionSourceSpeciesEntry::Select), then
    -- CCountryExpansionCommand (planet.colonize)
    local source = RENDER_PLANET and RENDER_PLANET.source
    -- a colony ship chosen (expansion_source_fleet_entry): CFleetColonizePlanetCommand
    -- (planet.command colonize_fleet: the colonize order), from the fleet menu only that fleet
    local source_fleet = RENDER_PLANET and RENDER_PLANET.source_fleet
    local filter = RENDER_PLANET and RENDER_PLANET.colonize_fleet
    local tints = {}
    if source_fleet then
        actions[CW .. "/colonize_button"] = "planet:cmd:colonize_fleet:" .. source_fleet
        source = source_fleet
    elseif source and not filter then
        actions[CW .. "/colonize_button"] = "planet:cmd:colonize:" .. source
    else
        tints[CW .. "/colonize_button"] = { 0.45, 0.45, 0.45, 1 }
    end
    local r = self:lay("expansion_planner_surface_view", {
        file = CFILE, text = text, hide = hide, actions = actions, tints = tints,
    })
    if not source then
        self.dimmed[CW .. "/colonize_button/text"] = true
    end
    -- the checkboxes: the founder-species filter and the automation, unchecked
    for _, cb in ipairs({ { CW .. "/expansion_source/expansion_source_container_title_bar/main_species_filter", "checked" },
        { CW .. "/designation_container/designation_container_title_bar/automation_toggle", "automation_checkbox" } }) do
        local rr = r.rects[cb[1]]
        if rr then
            self:checkbox(cb[1] .. "/" .. cb[2], "GFX_checkbox_20_20_01", rr.x, rr.y, false)
        end
    end
    -- the colony ships first (expansion_source_fleet_entry: idle ones; with a filter, that one),
    -- then the colonizing species (expansion_source_planet_sub_entry; none with a filter) [V
    -- RefreshExpansionSources]
    local lr = r.rects[CW .. "/expansion_source/expansion_source_list_container/expansion_source_list"]
    local nf = 0
    if lr then
        local h = 77
        for _, f in ipairs(c.fleets or {}) do
            if (filter and f.id == filter) or (not filter and f.idle) then
                local p = CW .. "/fleets/" .. f.id
                local E = p .. "/expansion_source_fleet_entry"
                local hab = math.floor((f.habitability or 0) * 100 + 1e-6)
                local names = require("render.names")
                self:entry("expansion_source_fleet_entry", p, lr.x, lr.y + nf * h, 725, h, {
                    file = CFILE, actions = { [E] = "planet:source_fleet:" .. tostring(f.id) },
                    text = {
                        [E .. "/species_container/species_name_text"] = f.species_name and names.format(self.loc, f.species_name) or "",
                        [E .. "/species_container/ship_type_text"] = self:L("colonizer"),
                        [E .. "/habitability_container/habitability_percentage"] = col(hab > 0 and "G" or "R", hab .. "%"),
                        [E .. "/colony_ship_container/ship_name"] = f.ship_name and names.format(self.loc, f.ship_name) or "",
                        [E .. "/ship_location"] = f.location and names.format(self.loc, f.location) or "",
                    },
                    hide = { [E .. "/selected_overlay"] = source_fleet ~= f.id or nil },
                    frames = { [E .. "/habitability_container/habitability_icon"] = hab > 0 and 2 or 1 },
                })
                nf = nf + 1
            end
        end
        for i, s in ipairs(filter and {} or c.species) do
            local y = lr.y + (nf + i - 1) * h
            local p = CW .. "/sources/" .. i
            local E = p .. "/expansion_source_planet_sub_entry"
            local hab = math.floor((s.habitability or 0) * 100 + 1e-6)
            local cost = {}
            for _, k in ipairs(c.cost) do
                cost[#cost + 1] = "\194\163" .. k[1] .. "\194\163" .. k[2]
            end
            local selected = s.id and RENDER_PLANET and RENDER_PLANET.source == s.id
            local er = self:entry("expansion_source_planet_sub_entry", p, lr.x, y, 725, h, {
                file = CFILE, actions = { [E] = "planet:source:" .. tostring(s.id) },
                text = {
                    [E .. "/species_container/species_name_text"] = require("render.names").format(self.loc, s.name),
                    [E .. "/species_container/ship_type_text"] = self:L("colonizer"),
                    [E .. "/habitability_container/habitability_percentage"] = col(hab > 0 and "G" or "R", hab .. "%"),
                    [E .. "/colonization_cost_container/colony_ship_cost"] = table.concat(cost, " "),
                },
                hide = { [E .. "/selected_overlay"] = not selected or nil },
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
                        local ze = { id = tonumber(zid), slot = k - 1, type = unquote(world.field(z, "type")), buildings = {} }
                        for _, bid in ipairs(world.list(world.field(z, "buildings"))) do
                            local bb = world.object("buildings", tonumber(bid))
                            local bt = bb and unquote(world.field(bb, "type"))
                            if bt then
                                local bdef = block_of(game_dir, "common/buildings", bt)
                                ze.buildings[#ze.buildings + 1] = {
                                    id = tonumber(bid), type = bt, icon = "gfx/interface/icons/buildings/" .. (dfield(bdef, "icon") or bt) .. ".dds",
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
                        e.zones[k] = { open = true, slot = k - 1 }
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
        e.district_id = e.ids and e.ids[1] or nil
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
    local out = { species = {}, cost = {}, fleets = {} }
    if not pc then
        return out
    end
    local climate = dfield(block_of(game_dir, "common/planet_classes", d.class), "climate")
    -- a species' entry: its name, traits' icons, habitability on this planet
    local function species_entry(fs)
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
        return {
            id = fs, name = galaxy.name_block(world.field(s, "name")), traits = traits,
            habitability = math.max(0, math.min(1, hab)),
        }
    end
    end
    out.species[1] = species_entry(num(world.field(pc, "founder_species_ref")))
    -- the player's colony ships (RefreshExpansionSources: colonizer fleets, idle, with their
    -- colonization data, as expansion_source_fleet_entry; opened from a fleet's Colonize Planet
    -- only that fleet: the window filters, RENDER_PLANET.colonize_fleet) [V]
    local NONE = 4294967295
    for _, fid in ipairs(world.all("fleet")) do
        local f = world.object("fleet", fid)
        if f and world.fleet_owner and world.fleet_owner[fid] == d.player
            and tostring(world.field(f, "ship_class") or ""):gsub('"', "") == "shipclass_colonizer" then
            local sid = num(world.list(world.field(f, "ships") or {})[1])
            local ship = sid and world.object("ships", sid)
            local cd = ship and world.field(ship, "colonization_data")
            local spec = type(cd) == "table" and num(world.field(cd, "species"))
            if spec and spec ~= NONE then
                local e = species_entry(spec) or {}
                local origin = num(world.path(f, "movement_manager", "coordinate", "origin"))
                local g = origin and world.object("galactic_object", origin)
                local idle = world.field(f, "current_order") == nil
                out.fleets[#out.fleets + 1] = {
                    id = fid, species = spec, species_name = e.name, traits = e.traits, habitability = e.habitability,
                    ship_name = galaxy.name_block(world.field(ship, "name")),
                    location = g and galaxy.name_block(world.field(g, "name")), idle = idle,
                }
            end
        end
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


-- ---------------------------------------------------------------------------------------------
-- the side bar's data (CPlanetView +0x390's windows), read only for the window open, and the
-- planet's build queue

-- a buildable's cost and build time (engine.ai.economy.buildables: with the colony's modifiers);
-- the definition's own first cost table where that cannot be read
local function buildable_cost(b)
    local ok, B = pcall(require, "engine.ai.economy.buildables")
    if ok then
        local ok2, cost = pcall(B.cost, b)
        local ok3, time = pcall(B.build_time, b)
        if ok2 and type(cost) == "table" then
            local list = {}
            for r, v in pairs(cost) do
                if v ~= 0 then
                    list[#list + 1] = { r, v }
                end
            end
            table.sort(list, function(x, y) return x[1] < y[1] end)
            return list, ok3 and tonumber(time) or nil
        end
    end
    return {}, nil
end

-- the definitions of a folder whose `<sets_key>` share a set with `sets`, in load order
local function in_sets(game_dir, folder, sets_key, sets)
    local want = {}
    for _, s in ipairs(sets) do
        want[s] = true
    end
    local out = {}
    for _, name in ipairs(ordered(game_dir, folder)) do
        local def = expand(game_dir, block_of(game_dir, folder, name))
        for _, s in ipairs(words(dfield(def, sets_key))) do
            if want[s] then
                out[#out + 1] = name
                break
            end
        end
    end
    return out
end

-- the planet's construction queue: its items (construction.item_mgr.items) in order, each its
-- kind, type, progress (CConstructionQueueListController: the planet queue's items)
local function queue_items(world, p)
    local out = {}
    local qid = tonumber(world.field(p, "build_queue"))
    local q = qid and world.object("construction.queue_mgr.queues", qid)
    local simultaneous = q and tonumber(world.field(q, "simultaneous")) or 1
    for i, iid in ipairs(q and world.list(world.field(q, "items")) or {}) do
        local item = world.object("construction.item_mgr.items", tonumber(iid))
        if item then
            local kind, b
            for k, v in world.statements(item) do
                if k:sub(1, 10) == "buildable_" then
                    kind, b = k:sub(11), v
                end
            end
            local t = b and unquote(world.field(b, (kind == "district" or kind == "replace_district") and "district"
                or kind == "zone" and "zone" or kind == "decision" and "decision" or kind == "clear_deposit_blocker" and "deposit"
                or kind == "army" and "type" or "building"))
            local progress = tonumber(world.field(item, "progress")) or 0
            local needed = tonumber(world.field(item, "progress_needed")) or 0
            out[#out + 1] = {
                id = tonumber(iid), kind = kind, type = t, progress = progress, needed = needed,
                active = i <= simultaneous, position = i,
            }
        end
    end
    return out
end

local function side_of(game_dir, world, p, id, d, side)
    local kind, a1, a2, a3 = side:match("^([%w_]+):?([^:]*):?([^:]*):?([^:]*)$")
    local out = { kind = kind }
    local cid = d.colony and d.colony.id
    local b0 = { colony = cid, planet = id, owner = d.owner }
    if kind == "construction" then
        -- the buildings a zone takes (99_HOW_TO_ZONE: `include` names buildings or `all`,
        -- included_building_sets the building's building_sets; `exclude` and
        -- excluded_building_sets take them out), then can_build, the owner's technologies,
        -- potential and allow **[I]** the game's lists also by category tab
        local zone = world.object("zones", tonumber(a1))
        local ztype = zone and unquote(world.field(zone, "type"))
        local zdef = ztype and expand(game_dir, block_of(game_dir, "common/zones", ztype))
        local function set_of(key)
            local t = {}
            for _, w in ipairs(words(dfield(zdef, key))) do
                t[w] = true
            end
            return t
        end
        local include, exclude = set_of("include"), set_of("exclude")
        local inc_sets, exc_sets = set_of("included_building_sets"), set_of("excluded_building_sets")
        local techs = techs_of(world, world.object("country", d.owner)) or {}
        local list = {}
        for _, name in ipairs(ordered(game_dir, "common/buildings")) do
            local def = block_of(game_dir, "common/buildings", name)
            local sets = words(dfield(def, "building_sets"))
            local inside, outside = include.all or include[name], exclude[name]
            for _, s in ipairs(sets) do
                inside = inside or inc_sets[s]
                outside = outside or exc_sets[s]
            end
            local ok = inside and not outside and dfield(def, "can_build") ~= "no"
            for _, pre in ipairs(words(dfield(def, "prerequisites"))) do
                ok = ok and techs[pre] == true
            end
            ok = ok and trigger(game_dir, dfield(def, "potential"), "planet", id, "country", d.owner) ~= false
            if ok then
                local b = { colony = cid, planet = id, owner = d.owner, kind = "planet_building", type = name, zone = tonumber(a1) }
                local cost, time = buildable_cost(b)
                list[#list + 1] = {
                    type = name, icon = "gfx/interface/icons/buildings/" .. (dfield(def, "icon") or name) .. ".dds",
                    cost = cost, time = time,
                    allowed = trigger(game_dir, dfield(def, "allow"), "planet", id, "country", d.owner) ~= false,
                }
            end
        end
        -- a building's Replace: the slot's building replaced (replace_building)
        out.zone, out.list, out.replace = tonumber(a1), list, tonumber(a3)
    elseif kind == "zone_construction" then
        -- the zones a district's slot takes (the slot's included_zone_sets, the zone's zone_sets;
        -- potential and unlock in the planet's scope)
        local did, slot = tonumber(a1), tonumber(a2)
        local dist = world.object("districts", did)
        local dtype = dist and unquote(world.field(dist, "type"))
        local ddef = dtype and expand(game_dir, block_of(game_dir, "common/districts", dtype))
        local sname = words(dfield(ddef, "zone_slots"))[(slot or 0) + 1]
        local sdef = sname and block_of(game_dir, "common/zone_slots", sname)
        local list = {}
        for _, name in ipairs(in_sets(game_dir, "common/zones", "zone_sets", words(dfield(sdef, "included_zone_sets")))) do
            local def = expand(game_dir, block_of(game_dir, "common/zones", name))
            if trigger(game_dir, dfield(def, "potential"), "planet", id, "country", d.owner) ~= false then
                local b = { colony = cid, planet = id, owner = d.owner, kind = "zone", type = name, district = did, zone_slot = slot }
                local cost, time = buildable_cost(b)
                list[#list + 1] = {
                    type = name, icon = dfield(def, "icon"), cost = cost, time = time,
                    allowed = trigger(game_dir, dfield(def, "unlock"), "planet", id, "country", d.owner) ~= false,
                }
            end
        end
        out.district, out.slot, out.list = did, slot, list
    elseif kind == "building" then
        -- a building: its type, icon, the types it upgrades to (`upgrades`) with their costs
        local bb = world.object("buildings", tonumber(a1))
        local btype = bb and unquote(world.field(bb, "type"))
        local def = btype and block_of(game_dir, "common/buildings", btype)
        out.id, out.type = tonumber(a1), btype
        -- ruined (Repair shown), disabled (the toggle reads Enable), its zone and slot (Replace)
        out.ruined = bb and world.field(bb, "ruined") == "yes"
        out.can_demolish = dfield(def, "can_demolish") ~= "no"
        out.disabled = bb and world.field(bb, "disabled") == "yes"
        for _, x in ipairs(d.districts or {}) do
            for _, z in ipairs(x.zones or {}) do
                for k, zb in ipairs(z and z.buildings or {}) do
                    if zb.id == out.id then
                        out.zone, out.slot = z.id, k
                    end
                end
            end
        end
        out.icon = btype and ("gfx/interface/icons/buildings/" .. (dfield(def, "icon") or btype) .. ".dds")
        out.upgrades = {}
        -- a building something upgrades into: its destroy button reads Downgrade (the game's
        -- frames of the capital; Demolish otherwise)
        for _, name in ipairs(btype and ordered(game_dir, "common/buildings") or {}) do
            for _, u in ipairs(words(dfield(block_of(game_dir, "common/buildings", name), "upgrades"))) do
                out.downgrade = out.downgrade or u == btype
            end
        end
        -- the upgrades shown: their technologies researched, their potential (the capital's
        -- major capital is not listed without tech_colonial_centralization)
        local techs = techs_of(world, world.object("country", d.owner)) or {}
        for _, up in ipairs(words(dfield(def, "upgrades"))) do
            local udef = block_of(game_dir, "common/buildings", up)
            local shown = trigger(game_dir, dfield(udef, "potential"), "planet", id, "country", d.owner) ~= false
            for _, pre in ipairs(words(dfield(udef, "prerequisites"))) do
                shown = shown and techs[pre] == true
            end
            if shown then
                local b = { colony = cid, planet = id, owner = d.owner, kind = "planet_upgrade_building", type = up, upgrade_building = tonumber(a1) }
                local cost, time = buildable_cost(b)
                out.upgrades[#out.upgrades + 1] = {
                    type = up, icon = "gfx/interface/icons/buildings/" .. (dfield(udef, "icon") or up) .. ".dds", cost = cost, time = time,
                }
            end
        end
    elseif kind == "district" then
        -- a district type: its cost and time for the next one
        local b = { colony = cid, planet = id, owner = d.owner, kind = "district", type = a1 }
        out.type = a1
        out.cost, out.time = buildable_cost(b)
        -- its zones by slot (zones_list: zone_details_entry, Replace opens zone construction)
        out.zones = {}
        for _, x in ipairs(d.districts or {}) do
            if x.type == a1 then
                out.district = x.district_id
                for k, z in ipairs(x.zones or {}) do
                    -- (the first slot is the district's own zone, shown in its entry: the game's
                    -- frames list Archives and Mixed Industry as specializations 1 and 2)
                    if k > 1 and z and z.type then
                        local zdef = block_of(game_dir, "common/zones", z.type)
                        out.zones[#out.zones + 1] = { slot = k - 1, type = z.type, icon = dfield(zdef, "icon") }
                    end
                end
            end
        end
    elseif kind == "district_construction" then
        -- Replace: the district types the planet takes instead (potential in the planet's scope,
        -- not the one replaced), their costs
        local list = {}
        for _, name in ipairs(ordered(game_dir, "common/districts")) do
            local def = expand(game_dir, block_of(game_dir, "common/districts", name))
            if name ~= a1 and dfield(def, "is_capped_by_modifier") == nil
                and trigger(game_dir, dfield(def, "potential"), "planet", id, "country", d.owner) == true then
                local b = { colony = cid, planet = id, owner = d.owner, kind = "district", type = name }
                local cost, time = buildable_cost(b)
                list[#list + 1] = { type = name, icon = "gfx/interface/icons/districts/" .. (dfield(def, "icon") or name) .. ".dds", cost = cost, time = time }
            end
        end
        out.replace, out.list = a1, list
    elseif kind == "designation" then
        -- the colony types whose potential holds (CColonyType::IsPotential, the planet's scope,
        -- the owner as FROM), the automatic one first
        local list = { { type = "auto" } }
        for _, name in ipairs(ordered(game_dir, "common/colony_types")) do
            local def = block_of(game_dir, "common/colony_types", name)
            if trigger(game_dir, dfield(def, "potential"), "planet", id, "country", d.owner) == true then
                list[#list + 1] = { type = name, icon = dfield(def, "icon") }
            end
        end
        out.list = list
    elseif kind == "decisions" then
        -- the planet decisions whose potential holds (common/decisions, the planet's scope)
        local list = {}
        for _, name in ipairs(ordered(game_dir, "common/decisions")) do
            local def = block_of(game_dir, "common/decisions", name)
            if trigger(game_dir, dfield(def, "potential"), "planet", id, "country", d.owner) == true then
                -- its cost: the economy's (the cost tables whose triggers hold: the luxury goods'
                -- by the planet's pops; planet.def_cost on the simulation's thread), else the
                -- first table's
                local cost = {}
                local ok, c = pcall(planet.def_cost, "common/decisions", name, nil, id, d.owner, cid)
                if ok and type(c) == "table" and next(c) then
                    for r, v in pairs(c) do
                        cost[#cost + 1] = { r, v }
                    end
                    table.sort(cost, function(x, y) return x[1] < y[1] end)
                else
                    local cb = dfield(dfield(def, "resources"), "cost")
                    for _, e in ipairs(type(cb) == "table" and cb or {}) do
                        if e.op and e.key and e.value and e.value.text and tonumber(e.value.text) then
                            cost[#cost + 1] = { e.key.text, tonumber(e.value.text) }
                        end
                    end
                end
                list[#list + 1] = {
                    type = name, icon = dfield(def, "icon"), cost = cost,
                    allowed = trigger(game_dir, dfield(def, "allow"), "planet", id, "country", d.owner) ~= false,
                }
            end
        end
        out.list = list
    elseif kind == "terraform" then
        -- the terraforming links from the planet's class (common/terraform: from, to)
        local list = {}
        local ok, links = pcall(planet.terraform_links, game_dir)
        for i, def in ipairs(ok and links or {}) do
            if dfield(def, "from") == d.class then
                local to = dfield(def, "to")
                local cdef = block_of(game_dir, "common/planet_classes", to or "")
                local okc, c = pcall(planet.def_cost, nil, nil, def, id, d.owner, cid)
                local cost = {}
                for r, v in pairs(okc and type(c) == "table" and c or {}) do
                    cost[#cost + 1] = { r, v }
                end
                table.sort(cost, function(x, y) return x[1] < y[1] end)
                list[#list + 1] = {
                    index = i, to = to, icon = dfield(cdef, "icon"), duration = tonumber(dfield(def, "duration")), cost = cost,
                    allowed = trigger(game_dir, dfield(def, "condition"), "country", d.owner) ~= false,
                    shown = trigger(game_dir, dfield(def, "potential"), "planet", id, "country", d.owner) ~= false,
                }
            end
        end
        out.list = list
    elseif kind == "resettle" then
        -- the manual resettlement window: the player's other colonies (the right side's
        -- dropdown), the one shown (a1, else the first), its pop groups
        local cols = {}
        for _, pid in ipairs(world.planets_of and world.planets_of[d.player] or {}) do
            local ocid = world.planet_colony and world.planet_colony[pid]
            if pid ~= id and ocid then
                local pp = world.object("planet", pid)
                cols[#cols + 1] = { planet = pid, colony = ocid, name = require("render.galaxy").name_block(world.field(pp, "name")) }
            end
        end
        out.colonies = cols
        local pick = tonumber(a1) or (cols[1] and cols[1].planet)
        for _, x in ipairs(cols) do
            if x.planet == pick then
                out.target = x
                local oc = world.object("colony", x.colony)
                x.pop_groups = {}
                for _, gid in ipairs(oc and world.list(world.field(oc, "pop_groups")) or {}) do
                    local g = world.object("pop_groups", tonumber(gid))
                    if g then
                        x.pop_groups[#x.pop_groups + 1] = {
                            id = tonumber(gid), species = num(world.path(g, "key", "species")),
                            category = unquote(world.path(g, "key", "category")), size = num(world.field(g, "size")) or 0,
                        }
                    end
                end
            end
        end
    end
    return out
end

-- planet.data(game_dir, id[, side]) -> table | nil: the planet `id` of the world as the window
-- shows it; `side`: the side bar's window open (its data too)
function planet.data(game_dir, id, side)
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
    d.climate = dfield(cdef, "climate")
    d.star = dfield(cdef, "star") == "yes"
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
        -- the summary's automation button, the armies tab's checkboxes (planet.command flips them)
        local auto = world.field(c, "automation")
        col.automation = type(auto) == "table" and world.field(auto, "enabled") == "yes"
        col.deploy_in_orbit = world.field(p, "deploy_armies_in_orbit") ~= "no"
        col.army_builder = world.field(c, "include_in_army_builder") ~= "no"
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
    if c then
        d.queue = queue_items(world, p)
    end
    -- the terraform button: the player's tech_terraforming (the game's frames of the capital at
    -- 2210 show it greyed without it) **[I]** the game's own test (CanTerraform: a link the
    -- player may use)
    local tp = world.field(p, "terraform_process")
    if type(tp) == "table" then
        d.terraforming = {
            to = unquote(world.field(tp, "terraform_type")), progress = num(world.field(tp, "progress")) or 0,
            total = num(world.field(tp, "total")) or 1,
        }
    end
    for _, q in ipairs(d.queue or {}) do
        if q.kind == "decision" then
            d.decision = d.decision or q
        end
    end
    local ptechs = d.player and techs_of(world, world.object("country", d.player))
    d.can_terraform = (not d.star) and ptechs ~= nil and ptechs.tech_terraforming == true
    if side and side ~= "" and c then
        d.side = side_of(game_dir, world, p, id, d, side)
    end
    if #trigger_errors > 0 then
        d.errors = trigger_errors
    end
    return d
end


-- ---------------------------------------------------------------------------------------------
-- the planet view's changes to the game, done in the simulation's world (planet.rs run_pending:
-- Clock::query): what the game's commands do, through the simulation's own construction orders
-- (engine.ai.economy.orders, buildables: the cost with the colony's modifiers, paid from the
-- stockpile, the item appended to the planet's queue; engine.construction finishes it)
--
--   planet.command(game_dir, planet, verb, args...) -> "ok ..." | "invalid ..." | "not done ..."

local function colony_of(world, planet)
    local p = world.object("planet", planet)
    local cid = p and tonumber(world.field(p, "colony"))
    return p, cid, cid and world.object("colony", cid), p and tonumber(world.field(p, "owner"))
end

-- the resources in the stockpile's order (the cost's write order)
local function cost_order(cost)
    local o = {}
    for r in pairs(cost) do
        o[#o + 1] = r
    end
    table.sort(o)
    return o
end

-- a buildable queued as the game's CAddBuildableToQueueCommand does (IsValid: the planet the
-- player's, the cost payable)
local function queue_buildable(world, b)
    local B = require("engine.ai.economy.buildables")
    local orders = require("engine.ai.economy.orders")
    local cost = B.cost(b)
    if not orders.can_pay(b.owner, cost) then
        return "invalid: cannot pay"
    end
    local queue = B.queue(b)
    if not queue then
        return "invalid: no build queue"
    end
    local id, why = orders.add({
        country = b.owner, colony = b.colony, queue = queue, kind = b.kind, fields = B.fields(b),
        cost = cost, cost_order = cost_order(cost), build_time = B.build_time(b),
    })
    return id and ("ok queued " .. b.kind .. " " .. b.type .. " item " .. id) or ("invalid: " .. tostring(why))
end

-- an army type's cost for the colony (CArmyType::GetCost: its cost tables whose triggers hold,
-- the colony's modifiers)
local function army_cost(country, colony, planet, army_type)
    local defs = require("engine.defs")
    local d = defs.get("common/armies", army_type)
    local e = require("engine.economy")
    e.init()
    local block = d and defs.field(require("engine.economy.units").expanded(d), "resources")
    local t = block and e.template(block, d.file)
    if not t then
        return {}
    end
    local eval = require("simscript.eval")
    local ctx = eval.new_ctx(eval.S("planet", planet), eval.S("country", country), nil, d.file)
    local base = {}
    for _, b in ipairs(t.cost or {}) do
        local ok, holds = true, true
        if b.trigger then
            ok, holds = pcall(eval.trigger, b.trigger, ctx)
        end
        if ok and holds then
            local m = b.mult and e.value_of(b.mult, ctx) or 1
            for _, rv in ipairs(b.values) do
                local okv, v = pcall(e.value_of, rv[2], ctx)
                if okv and v then
                    base[rv[1]] = (base[rv[1]] or 0) + v * m
                end
            end
        end
    end
    return e.apply(t.category or "armies", "cost", base, 1, e.modifiers("colony", colony) or {}, ctx)
end


-- ---------------------------------------------------------------------------------------------
-- the planet view's other commands (wire-planet-2): buildings and districts demolished, replaced,
-- repaired; the queue's items cancelled and moved; blockers, decisions, terraforming; the planet
-- renamed, colonized, its pops resettled, the capital moved; jobs' workforce

local QUEUES, ITEMS = "construction.queue_mgr.queues", "construction.item_mgr.items"

-- a definition's cost for the planet (its `resources` cost tables whose triggers hold, with the
-- colony's modifiers: CEconomyResourceTemplate as the army's cost)
local function def_cost(folder, key, block, planet_id, country, colony)
    local defs = require("engine.defs")
    local e = require("engine.economy")
    e.init()
    local d = block and { block = block, file = "" } or defs.get(folder, key)
    if not d then
        return {}, "", {}
    end
    local units = require("engine.economy.units")
    local rb = defs.field(block or units.expanded(d), "resources")
    local t = rb and e.template(rb, d.file)
    if not t then
        return {}, "", {}
    end
    local eval = require("simscript.eval")
    local ctx = eval.new_ctx(eval.S("planet", planet_id), eval.S("country", country), nil, d.file)
    local base = {}
    for _, b in ipairs(t.cost or {}) do
        local ok, holds = true, true
        if b.trigger then
            ok, holds = pcall(eval.trigger, b.trigger, ctx)
        end
        if ok and holds then
            local m = b.mult and e.value_of(b.mult, ctx) or 1
            for _, rv in ipairs(b.values) do
                local okv, v = pcall(e.value_of, rv[2], ctx)
                if okv and v then
                    base[rv[1]] = (base[rv[1]] or 0) + v * m
                end
            end
        end
    end
    local cat = t.category or "decisions"
    return e.apply(cat, "cost", base, 1, colony and e.modifiers("colony", colony) or {}, ctx), cat, ctx
end
planet.def_cost = def_cost

-- the country's stockpile: a resource added (a refund) or taken (fixed point, as orders.add)
local function add_stock(country, cost, sign)
    local fp = require("engine.ai.economy.fixed")
    local c = require("engine.world").object("country", country)
    local world = require("engine.world")
    local module = world.path(c, "modules", "standard_economy_module")
    local stock = type(module) == "table" and world.child(module, "resources") or nil
    if not stock then
        return
    end
    for r, v in pairs(cost or {}) do
        if v ~= 0 then
            local now = fp.from(tonumber(world.field(stock, r)) or 0)
            world.set(stock, r, fp.to(now + sign * fp.from(v)))
        end
    end
end

-- a queue item of ours added: its buildable's kind and fields, its cost paid
local function queue_item(world, owner, cid, queue, kind, fields, cost, time)
    local orders = require("engine.ai.economy.orders")
    if not orders.can_pay(owner, cost) then
        return nil, "invalid: cannot pay"
    end
    local order = {}
    for r in pairs(cost) do
        order[#order + 1] = r
    end
    table.sort(order)
    local id, why = orders.add({
        country = owner, colony = cid, queue = queue, kind = kind, fields = fields,
        cost = cost, cost_order = order, build_time = time,
    })
    return id, why
end

-- the queue item's list and its index in it
local function item_place(world, iid)
    local item = world.object(ITEMS, iid)
    local q = item and world.object(QUEUES, tonumber(world.field(item, "queue")))
    local list = q and world.field(q, "items")
    for i, x in ipairs(list and world.list(list) or {}) do
        if tonumber(x) == iid then
            return item, q, list, i
        end
    end
    return item, q, list, nil
end

-- the building types something upgrades into this one from (its predecessor: Downgrade)
local function predecessor(btype)
    local defs = require("engine.defs")
    for name, d in pairs(defs.folder("common/buildings") or {}) do
        for _, e in ipairs(d.block or {}) do
            if e.op and e.key and e.key.text == "upgrades" and type(e.value) == "table" then
                for _, u in ipairs(e.value) do
                    if u.text and u.text:gsub('"', "") == btype then
                        return name
                    end
                end
            end
        end
    end
end

-- the terraform links (common/terraform: every `terraform_link`, all of one name) in file order
local link_cache
local function terraform_links(game_dir)
    if link_cache then
        return link_cache
    end
    local okd, defs = pcall(require, "engine.defs")
    local source = require("stellar.script.source")
    local fs = okd and defs.fs or (game_dir and source.filesystem(game_dir))
    local out = {}
    for _, short in ipairs(fs and source.files(fs, "common/terraform", "txt") or {}) do
        local tree = source.parse(fs, short)
        for _, e in ipairs(tree or {}) do
            if e.op == "=" and e.key and e.key.text == "terraform_link" and type(e.value) == "table" then
                local ok, x = pcall(source.expand, fs, e.value, nil, 0, "file: " .. short)
                out[#out + 1] = ok and x or e.value
            end
        end
    end
    link_cache = out
    return out
end
planet.terraform_links = terraform_links

local more = {}

-- a building demolished (CDestroyBuildingDialog's Yes): Downgrade (the type something upgrades
-- into it from) or gone, the zone's positions renumbered
function more.destroy_building(world, x, a1)
    local bid = tonumber(a1)
    local bl = bid and world.object("buildings", bid)
    if not bl then
        return "invalid: no building " .. tostring(a1)
    end
    local btype = tostring(world.field(bl, "type")):gsub('"', "")
    -- CanDestroyBuilding: the type's can_demolish (DESTROY_BUILDING_NOT_POSSIBLE)
    local bdef = require("engine.defs").get("common/buildings", btype)
    if bdef and require("engine.defs").field(bdef.block, "can_demolish") == "no" then
        return "invalid: " .. btype .. " can not be demolished"
    end
    local prev = predecessor(btype)
    if prev then
        world.set(bl, "type", '"' .. prev .. '"')
        x.rebuild()
        return "ok downgraded " .. btype .. " to " .. prev
    end
    for _, did in ipairs(world.list(world.field(x.c, "districts"))) do
        local d = world.object("districts", tonumber(did))
        for _, z in ipairs(d and world.list(world.field(d, "zones")) or {}) do
            local zb = tonumber(z) and world.object("zones", tonumber(z))
            local bl2 = zb and world.field(zb, "buildings")
            for _, b in ipairs(bl2 and world.list(bl2) or {}) do
                if tonumber(b) == bid then
                    world.remove_value(bl2, bid)
                    world.remove("buildings", bid)
                    for i, rest in ipairs(world.list(bl2)) do
                        local rb = world.object("buildings", tonumber(rest))
                        if rb then
                            world.set(rb, "position", i - 1)
                        end
                    end
                    x.rebuild()
                    return "ok demolished " .. btype
                end
            end
        end
    end
    return "invalid: building " .. bid .. " not on the colony"
end

-- CToggleBuildingEnabledCommand: the building's `disabled` **[I]** the key (runtime.lua's)
function more.toggle_building(world, x, a1)
    local bl = world.object("buildings", tonumber(a1))
    if not bl then
        return "invalid: no building " .. tostring(a1)
    end
    local off = world.field(bl, "disabled") == "yes"
    if off then
        world.remove_entry(bl, world.entry(bl, "disabled"))
    else
        world.set(bl, "disabled", "yes")
    end
    return "ok building " .. a1 .. (off and " enabled" or " disabled")
end

-- the building's queue items (repair, replace): the new type's cost and time
local function building_item(world, x, kind, bid, btype, extra)
    local B = require("engine.ai.economy.buildables")
    local b = { kind = "planet_building", type = btype, colony = x.cid, planet = x.pid, owner = x.owner }
    local cost, time = B.cost(b), B.build_time(b)
    local fields = { { "building", btype, true }, { "planet", x.cid }, extra }
    local id, why = queue_item(world, x.owner, x.cid, x.queue, kind, fields, cost, time)
    return id and ("ok queued " .. kind .. " " .. btype .. " item " .. id) or (why or "invalid")
end

function more.repair_building(world, x, a1)
    local bl = world.object("buildings", tonumber(a1))
    if not bl then
        return "invalid: no building " .. tostring(a1)
    end
    return building_item(world, x, "planet_repair_building", a1, tostring(world.field(bl, "type")):gsub('"', ""), { "repair_building", tonumber(a1) })
end

function more.replace_building(world, x, a1, a2)
    if not world.object("buildings", tonumber(a1)) then
        return "invalid: no building " .. tostring(a1)
    end
    return building_item(world, x, "planet_replace_building", a1, a2, { "replace_building", tonumber(a1) })
end

-- CDestroyDistrictDialog's Yes: one level of the district gone (remove_district)
function more.destroy_district(world, x, a1)
    require("engine.script.objects_colony")
    local systems = require("engine.systems")
    local r = systems.effects.remove_district({ kind = "planet", id = x.pid, district = a1 })
    return "ok removed district " .. tostring(a1) .. " (" .. tostring(r) .. ")"
end

-- a district replaced by another type (district construction's entry: buildable_replace_district)
function more.replace_district(world, x, a1, a2)
    local B = require("engine.ai.economy.buildables")
    local b = { kind = "district", type = a2, colony = x.cid, planet = x.pid, owner = x.owner }
    local id, why = queue_item(world, x.owner, x.cid, x.queue, "replace_district",
        { { "district", a2, true }, { "planet", x.cid }, { "replace_district", a1, true } }, B.cost(b), B.build_time(b))
    return id and ("ok queued replace_district " .. a1 .. " -> " .. a2 .. " item " .. id) or (why or "invalid")
end

-- a blocker cleared (CBuildableClearDepositBlocker): its type's cost and time
function more.clear_blocker(world, x, a1)
    local dep = world.object("deposit", tonumber(a1))
    if not dep then
        return "invalid: no deposit " .. tostring(a1)
    end
    local key = tostring(world.field(dep, "type")):gsub('"', "")
    local defs = require("engine.defs")
    local d = defs.get("common/deposits", key)
    local cost = def_cost("common/deposits", key, nil, x.pid, x.owner, x.cid)
    local M = require("engine.economy").modifiers("colony", x.cid) or {}
    for r, v in pairs(cost) do
        cost[r] = v * (1 + (M.planet_clear_blocker_cost_mult or 0))
    end
    local time = (tonumber(d and defs.field(d.block, "time")) or 0) * (1 + (M.planet_clear_blocker_time_mult or 0))
    local id, why = queue_item(world, x.owner, x.cid, x.queue, "clear_deposit_blocker",
        { { "deposit", tonumber(a1) }, { "planet", x.cid } }, cost, time)
    return id and ("ok queued clear_deposit_blocker " .. key .. " item " .. id) or (why or "invalid")
end

-- the district details' Clear Blocker: the first blocker deposit of the planet (CalcQuickClear-
-- BlockerDeposit **[I]**: the one blocking the district's type)
function more.quick_clear_blocker(world, x)
    local colony = require("engine.script.objects_colony")
    for _, did in ipairs(world.list(world.field(x.p, "deposits"))) do
        local dep = world.object("deposit", tonumber(did))
        local key = dep and tostring(world.field(dep, "type")):gsub('"', "")
        if key and colony.is_blocker_type and colony.is_blocker_type(key) then
            return more.clear_blocker(world, x, tostring(did))
        end
    end
    return "invalid: no blocker"
end

-- CRemoveBuildableFromQueueCommand: the item out of its queue, its resources back
function more.queue_cancel(world, x, a1)
    local iid = tonumber(a1)
    local item, q, list, i = item_place(world, iid)
    if not i then
        return "invalid: no item " .. tostring(a1)
    end
    local back = {}
    for k, v in world.statements(world.field(item, "resources")) do
        back[k] = tonumber(v)
    end
    add_stock(tonumber(world.field(item, "paying_country")) or x.owner, back, 1)
    world.remove_value(list, iid)
    world.remove(ITEMS, iid)
    return "ok cancelled item " .. iid
end

-- the priority arrows (C{In,De}crease{Once,Max}BuildablePriorityCommand): one place, or to the end
local function move_item(world, a1, dir, max)
    local iid = tonumber(a1)
    local _, _, list, i = item_place(world, iid)
    if not i then
        return "invalid: no item " .. tostring(a1)
    end
    local ids = world.list(list)
    local j = max and (dir < 0 and 1 or #ids) or (i + dir)
    if j < 1 or j > #ids or j == i then
        return "invalid: cannot move"
    end
    table.remove(ids, i)
    table.insert(ids, j, tostring(iid))
    world.replace(list, {})
    for _, v in ipairs(ids) do
        world.append_value(list, tonumber(v))
    end
    return "ok moved item " .. iid .. " to " .. j
end
function more.queue_up(world, x, a1, a2)
    return move_item(world, a1, -1, a2 == "max")
end
function more.queue_down(world, x, a1, a2)
    return move_item(world, a1, 1, a2 == "max")
end

-- CEnactDecisionCommand: allow holds and the cost is paid; enactment_time: an item of the planet's
-- queue (its effect when done), else the effect now
function more.decision(world, x, a1)
    local defs = require("engine.defs")
    local d = defs.get("common/decisions", a1)
    if not d then
        return "invalid: no decision " .. tostring(a1)
    end
    local cost, _, ctx = def_cost("common/decisions", a1, nil, x.pid, x.owner, x.cid)
    local eval = require("simscript.eval")
    for _, key in ipairs({ "potential", "allow" }) do
        local t = defs.field(d.block, key)
        if type(t) == "table" then
            local ok, holds = pcall(eval.trigger, t, ctx)
            if ok and not holds then
                return "invalid: " .. key .. " does not hold"
            end
        end
    end
    local time = tonumber(defs.field(d.block, "enactment_time"))
    if time and time > 0 then
        local id, why = queue_item(world, x.owner, x.cid, x.queue, "decision",
            { { "decision", a1, true }, { "planet", x.cid } }, cost, time)
        return id and ("ok queued decision " .. a1 .. " item " .. id) or (why or "invalid")
    end
    local orders = require("engine.ai.economy.orders")
    if not orders.can_pay(x.owner, cost) then
        return "invalid: cannot pay"
    end
    add_stock(x.owner, cost, -1)
    local cp = require("engine.construction_planet")
    local ok, err = cp.run_effect(defs.field(d.block, "effect"), x.pid, x.owner)
    return ok and ("ok enacted " .. a1) or ("error " .. tostring(err))
end

-- the decision progress window's cancel: the queue's first decision item cancelled
function more.cancel_decision(world, x)
    for _, iid in ipairs(world.list(world.field(world.object(QUEUES, x.queue), "items"))) do
        local item = world.object(ITEMS, tonumber(iid))
        if item and world.field(item, "buildable_decision") then
            return more.queue_cancel(world, x, iid)
        end
    end
    return "invalid: no decision queued"
end

-- CStartTerraformationCommand: the link (its index in terraform_links) from the planet's class,
-- its condition, its cost paid, the process started (construction_planet)
function more.terraform(world, x, a1)
    local defs = require("engine.defs")
    local link = terraform_links()[tonumber(a1) or 0]
    if not link then
        return "invalid: no link " .. tostring(a1)
    end
    local from = tostring(defs.field(link, "from")):gsub('"', "")
    local class = tostring(world.field(x.p, "planet_class")):gsub('"', "")
    if from ~= class then
        return "invalid: the planet is not " .. from
    end
    local cost, _, ctx = def_cost(nil, nil, link, x.pid, x.owner, x.cid)
    local cond = defs.field(link, "condition")
    if type(cond) == "table" then
        local eval = require("simscript.eval")
        local ok, holds = pcall(eval.trigger, cond, eval.new_ctx(eval.S("country", x.owner)))
        if ok and not holds then
            return "invalid: condition does not hold"
        end
    end
    local orders = require("engine.ai.economy.orders")
    if not orders.can_pay(x.owner, cost) then
        return "invalid: cannot pay"
    end
    local to = tostring(defs.field(link, "to")):gsub('"', "")
    local M = require("engine.economy").modifiers("colony", x.cid) or {}
    local total = (tonumber(defs.field(link, "duration")) or 0) * (1 + (M.add_terraformation_total_time_mult or 0))
    if not require("engine.construction_planet").start_terraform(x.pid, to, total) then
        return "invalid: already terraforming"
    end
    add_stock(x.owner, cost, -1)
    return "ok terraforming to " .. to .. " in " .. math.floor(total) .. " days"
end

function more.cancel_terraform(world, x)
    return require("engine.construction_planet").cancel_terraform(x.pid) and "ok terraforming cancelled" or "invalid: not terraforming"
end

-- CColonyRenameDialog's OK: the planet's name (name = { key = "..." })
function more.rename(world, x, a1)
    local name = tostring(a1 or ""):gsub('"', "")
    if name == "" then
        return "invalid: empty name"
    end
    local nb = world.field(x.p, "name")
    if type(nb) == "table" then
        world.replace(nb, {})
        world.append(nb, "key", '"' .. name .. '"')
    else
        local blk = {}
        world.append(blk, "key", '"' .. name .. '"')
        world.set(x.p, "name", blk)
    end
    return "ok renamed " .. name
end

-- CMoveCapitalCommand: the colony the country's capital (set_capital)
function more.move_capital(world, x)
    require("engine.script.objects_colony")
    local countries = require("engine.script.objects_countries")
    countries.set_capital(x.owner, x.cid)
    return "ok capital " .. x.cid
end

-- the jobs' workforce: +/- (CChangeJobWorkforceLimitCommand, delta), restore (every job's limit
-- its max workforce); jobs.update after
function more.workforce(world, x, a1, a2)
    local job = world.object("pop_jobs", tonumber(a1))
    if not job then
        return "invalid: no job " .. tostring(a1)
    end
    local max = tonumber(world.field(job, "max_workforce")) or 0
    local now = tonumber(world.field(job, "workforce_limit")) or max
    local v = math.max(0, math.min(max, now + (tonumber(a2) or 0)))
    world.set(job, "workforce_limit", v)
    pcall(function() require("engine.jobs").update({ x.cid }) end)
    return "ok job " .. a1 .. " workforce limit " .. v
end

function more.restore_jobs(world, x)
    local n = 0
    for _, jid in ipairs(world.list(world.field(x.c, "pop_jobs"))) do
        local job = world.object("pop_jobs", tonumber(jid))
        if job then
            world.set(job, "workforce_limit", tonumber(world.field(job, "max_workforce")) or 0)
            n = n + 1
        end
    end
    pcall(function() require("engine.jobs").update({ x.cid }) end)
    return "ok restored " .. n .. " jobs"
end

-- manual resettlement: POP_BULK_UNIT_SIZE (100) of a pop group to the other colony (pops.move_size
-- into a group of the same species and category there)
function more.resettle(world, x, a1, a2)
    local pops = require("engine.pops")
    local g = world.object("pop_groups", tonumber(a1))
    local dst = tonumber(a2)
    local dc = dst and world.object("colony", dst)
    if not (g and dc) then
        return "invalid: no pop group or colony"
    end
    if tonumber(world.field(dc, "colonizing_species")) and tonumber(world.field(dc, "colonizing_species")) ~= 4294967295 then
        return "invalid: the colony is being colonized"
    end
    local key = world.field(g, "key")
    local sid = tonumber(world.field(key, "species"))
    local cat = tostring(world.field(key, "category") or ""):gsub('"', "")
    local target
    for _, gid in ipairs(world.list(world.field(dc, "pop_groups"))) do
        local h = world.object("pop_groups", tonumber(gid))
        local hk = h and world.field(h, "key")
        if hk and tonumber(world.field(hk, "species")) == sid and tostring(world.field(hk, "category") or ""):gsub('"', "") == cat then
            target = tonumber(gid)
        end
    end
    target = target or (pops.create_group and pops.create_group(dst, sid, world.field(key, "category"), tonumber(a1)))
    if not target then
        return "invalid: no group there"
    end
    local n = math.min(100, tonumber(world.field(g, "size")) or 0)
    pops.move_size(target, tonumber(a1), n, "GROWTH_CAT_RESETTLE", x.cid)
    return "ok resettled " .. n .. " to colony " .. dst
end

-- the colonize window's Colonize (CCountryExpansionCommand: a species of the player's, no ship):
-- the colony ship's cost paid, the planet owned and controlled, its colony colonizing with the
-- species (engine.pops grows it monthly) **[I]** the game's colonization start (its pops, its time)
function planet.colonize(planet_id, player, species)
    local world = require("engine.world")
    local p = world.object("planet", planet_id)
    if not p then
        return "invalid: no planet " .. tostring(planet_id)
    end
    if tonumber(world.field(p, "owner")) then
        return "invalid: the planet is owned"
    end
    local cost = def_cost("common/ship_sizes", "colonizer", nil, planet_id, player, nil)
    local orders = require("engine.ai.economy.orders")
    if not orders.can_pay(player, cost) then
        return "invalid: cannot pay"
    end
    add_stock(player, cost, -1)
    require("engine.script.objects_colony")
    local countries = require("engine.script.objects_countries")
    countries.set_planet_owner(planet_id, player)
    countries.set_planet_controller(planet_id, player)
    local cid = world.planet_colony[planet_id]
    local c = cid and world.object("colony", cid)
    if c and tonumber(species) then
        world.set(c, "colonizing_species", tonumber(species))
    end
    return "ok colonizing " .. planet_id .. " colony " .. tostring(cid)
end

-- the colonize window's Colonize with a colony ship (CSurfaceView::ConfirmPlaceColony with a fleet:
-- CFleetColonizePlanetCommand(fleet, planet, no queue): the fleet's orders cleared, the colonize
-- order given, engine.fleets.colonize) [V]; the colony name popup (OpenColonyNamePopup) not done:
-- the planet keeps its name
function planet.colonize_fleet(planet_id, player, fleet_id)
    local world = require("engine.world")
    local fid = tonumber(fleet_id)
    if not fid or not world.object("fleet", fid) then
        return "invalid: no fleet " .. tostring(fleet_id)
    end
    if world.fleet_owner and world.fleet_owner[fid] ~= player then
        return "invalid: not the player's fleet"
    end
    local colonize = require("engine.fleets.colonize")
    local ok, why = colonize.check(fid, planet_id)
    if not ok then
        return "invalid: " .. tostring(why)
    end
    local orders = require("engine.fleets.orders")
    orders.clear(fid)
    local id = orders.issue(fid, colonize.order(planet_id))
    return id and ("ok colonize order " .. tostring(id) .. " fleet " .. fid .. " planet " .. planet_id) or "invalid: the order was refused"
end

planet.more_commands = more

function planet.command(game_dir, planet_id, verb, a1, a2, a3)
    local world = require("engine.world")
    local p, cid, c, owner = colony_of(world, planet_id)
    if not p then
        return "invalid: no planet " .. tostring(planet_id)
    end
    local player = 0
    local pl = world.meta and world.meta.player
    if type(pl) == "table" then
        for _, b in ipairs(world.blocks(pl)) do
            player = tonumber(world.field(b, "country")) or player
        end
    end
    if verb == "colonize" then
        return planet.colonize(planet_id, player, a1)
    end
    if verb == "colonize_fleet" then
        return planet.colonize_fleet(planet_id, player, a1)
    end
    -- the game's commands are the player's own planet's (IsValid: the owner is the sender)
    if not c or owner ~= player then
        return "invalid: not the player's colony"
    end
    local b = { colony = cid, planet = planet_id, owner = owner }
    if verb == "build_district" then
        -- CPlanetDistrictEntry's Build: the district's next level (buildable_district)
        b.kind, b.type = "district", a1
        return queue_buildable(world, b)
    elseif verb == "build_zone" then
        -- a zone in a district's slot (zone construction's entry)
        b.kind, b.district, b.zone_slot, b.type = "zone", tonumber(a1), tonumber(a2), a3
        -- an occupied slot: the zone replaces it (zone_to_replace; construction_planet finishes it)
        local d = world.object("districts", b.district)
        local old = d and tonumber(world.list(world.field(d, "zones"))[(b.zone_slot or 0) + 1])
        if old and old < 4294967295 and world.object("zones", old) then
            local B = require("engine.ai.economy.buildables")
            local fields = B.fields(b)
            fields[#fields + 1] = { "zone_to_replace", old }
            local orders = require("engine.ai.economy.orders")
            local cost = B.cost(b)
            if not orders.can_pay(owner, cost) then
                return "invalid: cannot pay"
            end
            local id = orders.add({
                country = owner, colony = cid, queue = B.queue(b), kind = "zone", fields = fields,
                cost = cost, cost_order = cost_order(cost), build_time = B.build_time(b),
            })
            return id and ("ok queued zone " .. a3 .. " replacing " .. old .. " item " .. id) or "invalid: not queued"
        end
        return queue_buildable(world, b)
    elseif verb == "build_building" then
        -- a building in a zone's free slot (the construction window's entry)
        b.kind, b.zone, b.type = "planet_building", tonumber(a1), a2
        return queue_buildable(world, b)
    elseif verb == "upgrade_building" then
        b.kind, b.upgrade_building, b.type = "planet_upgrade_building", tonumber(a1), a2
        return queue_buildable(world, b)
    elseif verb == "recruit" then
        -- the recruitment entry: an army of the type (and species) in the planet's army queue,
        -- as the AI's army command does (engine.ai.shipbuilding)
        local sb = require("engine.ai.shipbuilding")
        local cost = army_cost(owner, cid, planet_id, a1)
        local cmd = sb.ctor.army_command(owner, cid, planet_id, a1, tonumber(a2), cost)
        return cmd.execute() and ("ok queued army " .. a1) or "invalid: cannot pay or no army queue"
    elseif verb == "designation" then
        -- CSetColonyTypeCommand: the colony's chosen designation (`designation`; empty: automatic)
        if a1 == nil or a1 == "" or a1 == "auto" then
            local e = world.entry(c, "designation")
            if e then
                world.remove_entry(c, e)
            end
            return "ok designation automatic"
        end
        world.set(c, "designation", '"' .. a1 .. '"')
        return "ok designation " .. a1
    elseif verb == "automation" then
        -- the colony's automation on or off (automation.enabled)
        local auto = world.field(c, "automation")
        if type(auto) ~= "table" then
            return "invalid: no automation block"
        end
        local on = world.field(auto, "enabled") == "yes"
        world.set(auto, "enabled", on and "no" or "yes")
        return "ok automation " .. (on and "off" or "on")
    elseif verb == "deploy_in_orbit" or verb == "army_builder" then
        -- the armies tab's checkboxes (planet +0xcb4 bit 0x40 `deploy_armies_in_orbit`; colony
        -- +0x1060 bit 0x8 `include_in_army_builder`): checked by default, the save writes `no`
        -- when unchecked **[I]** the keys
        local holder, key = verb == "deploy_in_orbit" and p or c, verb == "deploy_in_orbit" and "deploy_armies_in_orbit" or "include_in_army_builder"
        local now = world.field(holder, key) ~= "no"
        world.set(holder, key, now and "no" or "yes")
        return "ok " .. key .. " " .. (now and "no" or "yes")
    elseif verb == "disband" then
        -- CDisbandArmyCommand: the army gone, from the colony's list
        local aid = tonumber(a1)
        if not world.object("army", aid) then
            return "invalid: no army " .. tostring(a1)
        end
        world.remove_value(world.field(c, "army"), tostring(aid))
        world.remove("army", aid)
        return "ok disbanded " .. aid
    end
    local f = planet.more_commands[verb]
    if f then
        local x = {
            p = p, pid = planet_id, cid = cid, c = c, owner = owner, queue = tonumber(world.field(p, "build_queue")),
            rebuild = function()
                local colony = require("engine.script.objects_colony")
                colony.rebuild_cache(c)
            end,
        }
        return f(world, x, a1, a2, a3)
    end
    return "not done: " .. tostring(verb)
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
