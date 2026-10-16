-- render/windows/expansion_planner.lua : the left bar's Expansion Planner (interface/
-- expansion_planner_view.gui, CExpansionPlannerView; docs/windows/economy.md), bound to the
-- save's world.
--
--   ex.extract(game_dir) -> data     the player's candidates, read where the galaxy is (views.rs)
--   ex.build(ctx, data, state) -> items, report
--
-- state (the view's own, App::view_state, `view_set:`): surveyed, colonizable, terraforming
-- ("1"/"0": the filters' checkboxes; on, off, off when the view opens), habitability (the
-- minimum, 0..100), species (a species id; none: All), dropdown (the one open), sort (a column:
-- class, habitability, name, features, size, distance) and reverse ("1": the other way).
--
-- The rows (CExpansionPlannerView::RefreshModel, ValidatePlanetFilters, RefreshPlanetData,
-- CExpansionTargetEntry::UpdateEntry): every planet of the systems the player knows at medium
-- intel or better that has no owner and a colonizable class (or a terraforming candidate's
-- modifier), not in a system of a country the player has met; an unsurveyed one only while every
-- checkbox is off, shown grey with "?". Sorted by distance to the capital, nearest first (ties in
-- planet id order).

local gui = require("render.gui")
local text = require("render.loctext")

local ex = {}

local FILE = "interface/expansion_planner_view.gui"
local V = "/expansion_planner_view"
local F = V .. "/expansion_target_filters"
local T = V .. "/expansion_target"

-- the filters when the view opens (the constructor's: surveyed on, the others off)
local DEFAULTS = { surveyed = "1", colonizable = "0", terraforming = "0" }

local function flag(state, key)
    local v = state and state[key]
    if v == nil then
        v = DEFAULTS[key]
    end
    return v == "1"
end
ex.flag = flag

-- NDefines::NGameplay's habitability thresholds: the colours of a percentage
local HABITABILITY_OPPOSITE_PLANET, HABITABILITY_WRONG_PLANET = 40, 70
local HOMEWORLD_HABITABILITY = 0.3

-- a habitability percentage coloured (red under 40, yellow under 70, else green)
function ex.habitability_text(n)
    local c = n < HABITABILITY_OPPOSITE_PLANET and "R" or n < HABITABILITY_WRONG_PLANET and "Y" or "G"
    return "§" .. c .. tostring(n) .. "%§!"
end

-- ---------------------------------------------------------------------------------------------
-- the definitions: the planet classes (icon, colonizable), the traits' habitability modifiers

local function list_files(game_dir, rel)
    local out = {}
    if RUST and RUST.list_files then
        for _, f in ipairs(RUST.list_files(game_dir .. "/" .. rel, ".", "txt")) do
            out[#out + 1] = rel .. "/" .. f:gsub("^%./", "")
        end
    else
        local p = io.popen("ls '" .. game_dir .. "/" .. rel .. "' 2>/dev/null")
        if p then
            for line in p:lines() do
                if line:match("%.txt$") then
                    out[#out + 1] = rel .. "/" .. line
                end
            end
            p:close()
        end
    end
    table.sort(out)
    return out
end

local defs_cache = {}

local function definitions(game_dir)
    if defs_cache[game_dir] then
        return defs_cache[game_dir]
    end
    local source = require("stellar.script.source")
    local get = require("render.gfx").get
    local d = { classes = {}, traits = {} }
    for _, f in ipairs(list_files(game_dir, "common/planet_classes")) do
        local ok, t = pcall(source.parse, game_dir, f)
        for _, e in ipairs(ok and t or {}) do
            if e.op and e.key and type(e.value) == "table" and e.value.text == nil and e.key.text:sub(1, 3) == "pc_" then
                d.classes[e.key.text] = {
                    icon = get(e.value, "icon"),
                    colonizable = get(e.value, "colonizable") == "yes",
                }
            end
        end
    end
    -- the traits' `<class>_habitability` modifiers, the file's @variables resolved
    for _, f in ipairs(list_files(game_dir, "common/traits")) do
        local ok, t = pcall(source.parse, game_dir, f)
        local vars = {}
        for _, e in ipairs(ok and t or {}) do
            if e.op and e.key and e.key.text:sub(1, 1) == "@" and e.value.text then
                vars[e.key.text] = tonumber(e.value.text)
            end
        end
        for _, e in ipairs(ok and t or {}) do
            if e.op and e.key and type(e.value) == "table" and e.value.text == nil then
                local m = get(e.value, "modifier")
                if type(m) == "table" then
                    local hab
                    for _, me in ipairs(m) do
                        if me.op and me.key and me.value.text and me.key.text:match("_habitability$") then
                            local v = me.value.text
                            hab = hab or {}
                            hab[me.key.text] = vars[v] or tonumber(v) or 0
                        end
                    end
                    if hab then
                        d.traits[e.key.text] = hab
                    end
                end
            end
        end
    end
    defs_cache[game_dir] = d
    return d
end
ex.definitions = definitions

-- ---------------------------------------------------------------------------------------------
-- the data, read in the world's runtime

local function numbers(block)
    local out = {}
    for _, e in ipairs(type(block) == "table" and block or {}) do
        if e.text then
            out[#out + 1] = tonumber(e.text) or 0
        end
    end
    return out
end

-- the modifiers a planet carries that are `important` (the terraforming candidates')
local IMPORTANT = { terraforming_candidate = true, frozen_terraforming_candidate = true, toxic_terraforming_candidate = true }

-- NHabitability::CalcHabitability for a species on a planet: the species' traits' modifier of
-- the planet's class (`<class>_habitability`), the homeworld's bonus, clamped to 0..1 [I: the
-- generic habitability modifiers and the colony's and country's modifiers not added]
local function habitability(world, d, species, planet_id, class)
    local c = d.classes[class]
    if not c or not c.colonizable then
        return 0
    end
    local v = 0
    for _, tr in ipairs(world.fields(world.field(species, "traits") or {}, "trait")) do
        local h = d.traits[tostring(tr):gsub('"', "")]
        if h then
            v = v + (h[class .. "_habitability"] or 0)
        end
    end
    local home = world.field(species, "home_planet")
    if type(home) == "table" and tonumber(world.field(home, "reference")) == planet_id then
        v = v + HOMEWORLD_HABITABILITY
    end
    return math.max(0, math.min(1, v))
end

-- the distance between systems along the hyperlanes (their lengths), from `from`
local function distances(world, from)
    local dist = { [from] = 0 }
    local done = {}
    local frontier = { from }
    while #frontier > 0 do
        -- the nearest not done (a small galaxy: a scan)
        local bi, best = 1, frontier[1]
        for i, s in ipairs(frontier) do
            if dist[s] < dist[best] then
                bi, best = i, s
            end
        end
        table.remove(frontier, bi)
        if not done[best] then
            done[best] = true
            for _, h in ipairs(world.blocks(world.field(world.object("system", best), "hyperlane"))) do
                local to = tonumber(world.field(h, "to"))
                local len = tonumber(world.field(h, "length")) or 0
                if to and not done[to] and (dist[to] == nil or dist[best] + len < dist[to]) then
                    dist[to] = dist[best] + len
                    frontier[#frontier + 1] = to
                end
            end
        end
    end
    return dist
end

function ex.data(cid, game_dir)
    local world = require("engine.world")
    local galaxy = require("render.galaxy")
    local d = definitions(game_dir)
    local c = world.object("country", cid)
    local out = { country = cid, rows = {}, species = {} }
    if not c then
        return out
    end
    -- the species the country may colonise with (ListColonizerSpecies: its pop groups' species
    -- in their order, colonisation allowed by its species rights: colonization_control_no)
    local rights = {}
    local sr = world.path(c, "modules", "standard_species_rights_module")
    if type(sr) == "table" then
        local function right(b)
            local s = tonumber(world.field(b, "species_index"))
            if s then
                rights[s] = tostring(world.field(b, "colonization_control") or "")
            end
        end
        local p = world.field(sr, "primary")
        if type(p) == "table" then
            right(p)
        end
        for _, b in ipairs(world.blocks(world.field(sr, "species_rights"))) do
            right(b)
        end
    end
    local seen, colonizers = {}, {}
    for _, gid in ipairs(world.ids.pop_groups or {}) do
        local g = world.object("pop_group", gid)
        local col = g and tonumber(world.field(g, "planet"))
        local colony = col and world.object("colony", col)
        local carrier = colony and world.field(colony, "carrier")
        local pl = type(carrier) == "table" and world.object("planet", tonumber(world.field(carrier, "reference")))
        if pl and tonumber(world.field(pl, "owner")) == cid then
            local sp = tonumber(world.path(g, "key", "species"))
            if sp and not seen[sp] then
                seen[sp] = true
                if rights[sp] == nil or rights[sp] == "colonization_control_no" then
                    colonizers[#colonizers + 1] = sp
                    out.species[#out.species + 1] = { id = sp, name = galaxy.name_block(world.field(world.object("species", sp), "name")) }
                end
            end
        end
    end
    -- the systems known at medium intel or better (intel_level: one value per system id)
    local intel = numbers(world.field(c, "intel_level"))
    local surveyed = {}
    for _, h in ipairs(world.blocks(world.field(c, "surveyed_deposit_holders"))) do
        if tonumber(world.field(h, "type")) == 0 then
            surveyed[tonumber(world.field(h, "id"))] = true
        end
    end
    local met = {}
    local rm = world.field(c, "relations_manager")
    for _, r in ipairs(rm and world.fields(rm, "relation") or {}) do
        local other = type(r) == "table" and tonumber(world.field(r, "country"))
        if other and world.field(r, "communications") == "yes" then
            met[other] = true
        end
    end
    local techs = {}
    for k, v in world.statements(world.field(c, "tech_status") or {}) do
        if k == "technology" then
            techs[tostring(v):gsub('"', "")] = true
        end
    end
    -- the colonisation technology (the Colonizable filter needs it)
    out.colonization_tech = techs.tech_colonization_1 == true
    -- the capital's system, the distances from it
    local capital_system
    local cap = world.object("colony", tonumber(world.field(c, "capital")))
    local carrier = cap and world.field(cap, "carrier")
    local cap_planet = type(carrier) == "table" and world.object("planet", tonumber(world.field(carrier, "reference")))
    if cap_planet then
        capital_system = tonumber(world.path(cap_planet, "coordinate", "origin"))
    end
    local dist = capital_system and distances(world, capital_system) or {}
    -- the candidates (the filters that need no view state; the others: build)
    for _, sid in ipairs(world.ids.galactic_object or {}) do
        if (intel[sid + 1] or 0) >= 2 then
            local sys = world.object("system", sid)
            local owner = world.system_owner and world.system_owner[sid]
            for _, pid in ipairs(world.fields(sys, "planet")) do
                pid = tonumber(pid)
                local p = pid and world.object("planet", pid)
                local class = p and tostring(world.field(p, "planet_class") or ""):gsub('"', "")
                local cdef = class and d.classes[class]
                local important = false
                if p then
                    for _, it in ipairs(world.blocks(world.path(p, "timed_modifier", "items"))) do
                        if IMPORTANT[tostring(world.field(it, "modifier") or ""):gsub('"', "")] then
                            important = true
                        end
                    end
                end
                local unowned = p and world.field(p, "owner") == nil
                local ok = p and ((unowned and cdef and cdef.colonizable) or important)
                if ok and owner and owner >= 0 and owner ~= cid and met[owner] then
                    ok = false
                end
                -- a terraforming candidate needs the means to terraform it [I: taken as the
                -- terraforming technology]
                if ok and important and not techs.tech_terrestrial_sculpting then
                    ok = false
                end
                if ok then
                    local is_surveyed = surveyed[pid] == true
                    -- the habitability for each coloniser (surveyed only)
                    local habs = {}
                    if is_surveyed then
                        for _, sp in ipairs(colonizers) do
                            local s = world.object("species", sp)
                            habs[#habs + 1] = { species = sp, value = s and math.floor(habitability(world, d, s, pid, class) * 100 + 1e-9) or 0 }
                        end
                    end
                    local rare = 0
                    for _, dep in ipairs(numbers(world.field(p, "deposits"))) do
                        local o = world.object("deposit", dep)
                        local ty = o and tostring(world.field(o, "type") or ""):gsub('"', "")
                        -- [I: a rare deposit: its type's name says so (d_rare_*); the
                        -- deposits' is_for_colonizable/category not read]
                        if ty and ty:find("rare", 1, true) then
                            rare = rare + 1
                        end
                    end
                    local dd = dist[sid]
                    out.rows[#out.rows + 1] = {
                        id = pid, system = sid, class = class, icon = cdef and cdef.icon or "GFX_planet_type_unknown",
                        size = tonumber(world.field(p, "planet_size")) or 0,
                        distance = dd and math.floor(dd) or -1,
                        surveyed = is_surveyed, habs = habs, rare = rare,
                        name = galaxy.name_block(world.field(p, "name")),
                        terraform = important,
                    }
                end
            end
        end
    end
    -- the order (SortModel: a stable sort of the rows in planet id order)
    table.sort(out.rows, function(a, b) return a.id < b.id end)
    return out
end

-- ex.extract(game_dir): the player's planner (views.rs: where the galaxy is read)
function ex.extract(game_dir)
    return ex.data(require("render.topbar").player(), game_dir)
end

-- ValidatePlanetFilters' checks that depend on the view's state: the rows shown, each with its
-- habitability (the most over the species chosen: All, every coloniser)
function ex.filter(data, state)
    local filters = { surveyed = flag(state, "surveyed"), colonizable = flag(state, "colonizable"), terraforming = flag(state, "terraforming") }
    local any = filters.surveyed or filters.colonizable or filters.terraforming
    local min_hab = tonumber(state.habitability) or 0
    local chosen = tonumber(state.species)
    local out = {}
    for _, r in ipairs(data.rows or {}) do
        local ok = true
        if not r.surveyed and any then
            ok = false
        end
        -- the Colonizable filter: the colonisation technology [I: CanColonize not evaluated: a
        -- surveyed planet with a habitability above 0]
        if ok and filters.colonizable and not data.colonization_tech then
            ok = false
        end
        local hab = 0
        if ok and r.surveyed then
            for _, h in ipairs(r.habs or {}) do
                if not chosen or h.species == chosen then
                    hab = math.max(hab, h.value)
                end
            end
            if hab < min_hab or (filters.colonizable and hab <= 0) or (filters.terraforming and not r.terraform) then
                ok = false
            end
        end
        if ok then
            local row = {}
            for k, v in pairs(r) do
                row[k] = v
            end
            row.habitability = hab
            out[#out + 1] = row
        end
    end
    return out
end

-- ---------------------------------------------------------------------------------------------
-- the layout

-- the sort columns: the button, its comparator (before the reverse flag)
local SORTS = {
    class = function(a, b) return a.class_name < b.class_name end,
    habitability = function(a, b) return a.surveyed and (not b.surveyed or a.habitability > b.habitability) end,
    name = function(a, b) return a.name_text < b.name_text end,
    size = function(a, b) return a.size > b.size end,
    distance = function(a, b) return a.distance < b.distance end,
    features = function(a, b) return a.surveyed and (not b.surveyed or a.rare < b.rare) end,
}
local SORT_BUTTONS = { class = "class", habitability = "habitability", name = "name", size = "size", distance = "distance", features = "features" }

local function stable_sort(rows, fn, reverse)
    for i, r in ipairs(rows) do
        r._i = i
    end
    table.sort(rows, function(a, b)
        local ab, ba = fn(a, b), fn(b, a)
        if ab ~= ba then
            if reverse then
                return ba
            end
            return ab
        end
        return a._i < b._i
    end)
end

-- ex.build(ctx, data, state): the window (ctx: game_dir, db, screen, texture_size, loc)
function ex.build(ctx, data, state)
    local game_dir, db, screen, texture_size, loc = ctx.game_dir, ctx.db, ctx.screen, ctx.texture_size, ctx.loc
    data = data or { rows = {} }
    state = state or {}
    local names = require("render.names")
    local frames, actions, texts = {}, {}, {}
    actions[V .. "/close"] = "view_close"
    -- the filters' checkboxes: frame 1 unchecked, 2 checked [I: by the game's frame]
    for key, box in pairs({ surveyed = "filter_is_surveyed", colonizable = "filter_is_colonizable", terraforming = "filter_is_terraforming_candidate" }) do
        local on = flag(state, key)
        frames[F .. "/" .. box .. "/checked"] = on and 2 or 1
        actions[F .. "/" .. box .. "/checked"] = "view_set:" .. key .. "=" .. (on and "0" or "1")
    end
    texts[F .. "/filter_habitability/selected"] = ex.habitability_text(tonumber(state.habitability) or 0)
    -- the species: All, or the one chosen
    local species = "ALL"
    for _, s in ipairs(data.species or {}) do
        if tostring(s.id) == state.species and s.name then
            species = names.format(loc, s.name)
        end
    end
    texts[F .. "/filter_species/selected"] = species
    -- the sort buttons
    local sort = SORTS[state.sort or ""] and state.sort or "distance"
    local reverse = state.reverse == "1"
    -- (OnClickSort: the same column again turns the order, another starts in its own order)
    for key, button in pairs(SORT_BUTTONS) do
        local flip = key == sort and not reverse
        actions[T .. "/" .. button] = "view_set:sort=" .. key .. ";reverse=" .. (flip and "1" or "0")
    end
    -- the drop-downs: opened by their arrow (state dropdown = habitability | species), closed by
    -- a choice or the arrow again
    local open = state.dropdown
    for _, dd in ipairs({ "habitability", "species" }) do
        actions[F .. "/filter_" .. dd .. "/expand_button"] = "view_set:dropdown=" .. (open == dd and "" or dd)
    end
    -- the window under its filters (laid out after the rows, so the filters and an open list are
    -- over them, as the .gui orders them)
    local items, report = gui.layout(game_dir, db, FILE, "expansion_planner_view", screen, {
        texture_size = texture_size, loc = loc, frames = frames, actions = actions, text = texts,
        hide = { [F] = true },
    })
    -- the rows: an expansion_target_entry each down the list, 55 apart [I: measured on the
    -- game's frame: the entry's 54 and a spacing of 1], as many as the list shows
    local rows = ex.filter(data, state)
    for _, r in ipairs(rows) do
        r.name_text = r.name and names.format(loc, r.name) or ""
        r.class_name = loc and loc.has(r.class) and loc.get(r.class) or r.class
    end
    stable_sort(rows, SORTS[sort], reverse)
    local list = report.rects[T .. "/list"]
    if list then
        local y = list.y
        for i, r in ipairs(rows) do
            if y + 55 > list.y + list.h then
                break
            end
            local prefix = T .. "/list/" .. i
            local p = prefix .. "/expansion_target_entry"
            local hide = {
                [p .. "/has_expansion_entry"] = true, [p .. "/cancel_colonize_button"] = true,
                [p .. "/has_intel_hostile"] = true, [p .. "/has_anomaly"] = true,
            }
            local t = {
                [p .. "/planet_size_amount"] = tostring(r.size),
                [p .. "/expansion_distance"] = tostring(r.distance),
            }
            if r.surveyed then
                t[p .. "/habitability_amount"] = ex.habitability_text(r.habitability)
                t[p .. "/planet_name"] = r.name_text
                t[p .. "/planet_class"] = r.class_name
                t[p .. "/rare_deposits_window/rare_deposit_num"] = tostring(r.rare)
                if not r.terraform then
                    hide[p .. "/terraforming_candidate_status"] = true
                end
            else
                t[p .. "/habitability_amount"] = "§g" .. (loc and loc.has("UNKNOWN_SHORT") and loc.get("UNKNOWN_SHORT") or "?") .. "§!"
                t[p .. "/planet_name"] = "§g" .. r.name_text .. "§!"
                t[p .. "/planet_class"] = "§g" .. r.class_name .. "§!"
                t[p .. "/rare_deposits_window/rare_deposit_num"] = "-"
                hide[p .. "/terraforming_candidate_status"] = true
            end
            local ok, it, rp = pcall(gui.layout, game_dir, db, FILE, "expansion_target_entry", screen, {
                texture_size = texture_size, loc = loc, prefix = prefix, text = t, hide = hide,
                sprites = { [p .. "/planet_class_icon"] = r.icon },
                -- (the row's button: disabled for a planet that cannot be colonised [I: an
                -- unsurveyed one]; its frame 3)
                frames = {},
                actions = { [p .. "/zoom_to_planet"] = "select:planet:" .. r.id },
                parent = { x = list.x, y = y, w = 0, h = 0 },
            })
            if ok then
                gui.merge(items, report, it, rp)
            else
                report.missing_sprites[#report.missing_sprites + 1] = "expansion_target_entry: " .. tostring(it)
            end
            y = y + 55
        end
    end
    -- the filters, an open drop-down's list: an entry per choice in its gridbox (the minimum
    -- habitability 100 80 60 40 20 0, CHabitabilityEntry; the species: All, then the
    -- colonisers, CSpeciesEntry)
    local fi, fr = gui.layout(game_dir, db, FILE, "expansion_planner_view", screen, {
        texture_size = texture_size, loc = loc, frames = frames, actions = actions, text = texts,
        only = { expansion_target_filters = true }, hide = { [V .. "/background"] = true },
        open = (open == "habitability" or open == "species") and { [F .. "/filter_" .. open] = true } or nil,
    })
    gui.merge(items, report, fi, fr)
    local grid = open and report.grids[F .. "/filter_" .. open .. "/expanded_window/gridbox"]
    if grid then
        local choices = {}
        if open == "habitability" then
            for _, n in ipairs({ 100, 80, 60, 40, 20, 0 }) do
                choices[#choices + 1] = { text = ex.habitability_text(n), action = "view_set:habitability=" .. n .. ";dropdown=" }
            end
        else
            choices[1] = { text = "ALL", action = "view_set:species=;dropdown=" }
            for _, s in ipairs(data.species or {}) do
                choices[#choices + 1] = { text = s.name and names.format(loc, s.name) or "", action = "view_set:species=" .. s.id .. ";dropdown=" }
            end
        end
        local window = open == "habitability" and "expansion_planner_habitability_dropdown_entry" or "expansion_planner_dropdown_entry"
        for i, c in ipairs(choices) do
            local x, y = gui.grid_slot(grid, i - 1, #choices)
            if x then
                local prefix = F .. "/filter_" .. open .. "/expanded_window/gridbox/" .. i
                local p = prefix .. "/" .. window
                local ok, it, rp = pcall(gui.layout, game_dir, db, FILE, window, screen, {
                    texture_size = texture_size, loc = loc, prefix = prefix,
                    text = { [p .. "/text"] = c.text }, actions = { [p] = c.action },
                    parent = { x = x, y = y, w = 0, h = 0 },
                })
                if ok then
                    gui.merge(items, report, it, rp)
                end
            end
        end
    end
    return items, report
end

return ex
