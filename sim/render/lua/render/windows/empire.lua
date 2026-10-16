-- render/windows/empire.lua : the empire view, "Colonies and Sectors" (interface/empire_view.gui,
-- CEmpireView; docs/windows/empire.md section 4): the sort buttons, one planet_list_sector_entry
-- per owned sector (its governor's paragon_portrait_container_horizontal card, name, type,
-- systems, colonies, pops and the sector's monthly balance by resource group), and under an
-- expanded sector its colonies (planet_list_planet_entry). Sectors start collapsed; a click on a
-- sector's entry expands it (CEmpireViewSectorEntry::ToggleExpanded), on a colony opens its
-- planet view.

local world = require("engine.world")
local C = require("render.windows.empire_common")
local leaders = require("render.windows.leaders_common")
local rename = require("render.windows.rename")

local M = {}

local FILE = "interface/empire_view.gui"
local V = "/empire_view"

-- the resource groups of `resources`, in the .gui's order, and what each sums
-- (interface/resource_groups/sectors_*: CSectorStrategicResourceGroupWindowController)
M.GROUPS = {
    { "sectors_energy_group", { "energy" }, neg_stored = "energy" },
    { "sectors_mineral_group", { "minerals" } },
    { "sectors_alloys_group", { "alloys" } },
    { "sectors_food_group", { "food" } },
    { "sectors_consumer_goods_group", { "consumer_goods" } },
    { "sectors_unity_group", { "unity" } },
    { "sectors_research_group", { "physics_research", "society_research", "engineering_research" }, no_neg = true },
    { "sectors_others_group", { "volatile_motes", "exotic_gases", "rare_crystals", "sr_living_metal", "sr_zro", "sr_dark_matter", "nanites", "trade" } },
}

local function profits(col)
    local out = {}
    for _, e in ipairs(world.field(col, "profits") or {}) do
        if e.op and e.key and e.value.text then
            out[e.key.text] = tonumber(e.value.text)
        end
    end
    return out
end

local function colony_data(cid_, colony_id, galaxy)
    local col = world.object("colony", colony_id)
    if not col then
        return nil
    end
    local planet, pid = leaders.colony_planet(colony_id)
    local d = {
        id = colony_id, planet_id = pid,
        name = planet and galaxy.name_block(world.field(planet, "name")),
        class = planet and C.strip(world.field(planet, "planet_class")),
        size = planet and tonumber(world.field(planet, "planet_size")),
        system = planet and tonumber(world.path(planet, "coordinate", "origin")),
        pops = tonumber(world.field(col, "num_sapient_pops")) or 0,
        profits = profits(col),
        species = {}, districts = {},
    }
    -- the pops by species, in the colony's pop groups' order (UpdatePops)
    local index = {}
    for _, g in ipairs(world.list(world.field(col, "pop_groups"))) do
        local pg = world.object("pop_group", tonumber(g))
        local sp = pg and tonumber(world.path(pg, "key", "species"))
        if sp then
            if not index[sp] then
                d.species[#d.species + 1] = { id = sp, count = 0 }
                index[sp] = d.species[#d.species]
            end
            index[sp].count = index[sp].count + (tonumber(world.field(pg, "size")) or 0)
        end
    end
    -- the districts by type (CColony::ListDistrictTypes), their levels summed [I]
    local dindex = {}
    for _, k in ipairs(world.list(world.field(col, "districts"))) do
        local dist = world.object("districts", tonumber(k))
        local t = dist and C.strip(world.field(dist, "type"))
        if t then
            if not dindex[t] then
                d.districts[#d.districts + 1] = { type = t, count = 0 }
                dindex[t] = d.districts[#d.districts]
            end
            dindex[t].count = dindex[t].count + (tonumber(world.field(dist, "level")) or 1)
        end
    end
    return d
end

function M.data(cid, state)
    local galaxy = require("render.galaxy")
    local c = world.object("country", cid)
    if not c then
        return {}
    end
    local d = { sectors = {}, stored = {} }
    for _, e in ipairs(world.path(c, "modules", "standard_economy_module", "resources") or {}) do
        if e.op and e.key and e.value.text then
            d.stored[e.key.text] = tonumber(e.value.text)
        end
    end
    -- the country's colonies, by system (a sector's colonies are those in its systems [I])
    local colonies = {}
    for _, k in ipairs(world.list(world.field(c, "controlled_colonies"))) do
        local cd = colony_data(cid, tonumber(k), galaxy)
        if cd then
            colonies[#colonies + 1] = cd
        end
    end
    for _, k in ipairs(world.list(world.path(c, "sectors", "owned"))) do
        local sid = tonumber(k)
        local s = world.object("sector", sid)
        if s then
            local systems = {}
            for _, sys in ipairs(world.list(world.field(s, "systems"))) do
                systems[tonumber(sys)] = true
            end
            local sd = {
                id = sid,
                name = galaxy.name_block(world.field(s, "name")),
                type = C.strip(world.field(s, "type")),
                systems = #world.list(world.field(s, "systems")),
                capital = tonumber(world.field(s, "local_capital")),
                colonies = {},
            }
            for _, cd in ipairs(colonies) do
                if (cd.system and systems[cd.system]) or cd.id == sd.capital then
                    sd.colonies[#sd.colonies + 1] = cd
                end
            end
            -- the governor: the sector capital's colony's (CEmpireViewSectorEntry::UpdateWithData)
            local cap = sd.capital and world.object("colony", sd.capital)
            local gov = cap and tonumber(world.field(cap, "governor"))
            sd.governor = gov and leaders.leader_data(gov, c)
            d.sectors[#d.sectors + 1] = sd
        end
    end
    return d
end

-- a balance as RESOURCE_GROUP_BALANCE_ONLY shows it ("§W+$BALANCE|*0$§!", the _NEG key in red),
-- cut toward zero (the game's frame: 24.64 "+24")
local function balance(v, neg)
    local n = v < 0 and math.ceil(v) or math.floor(v)
    if neg then
        return "§R" .. C.short(n) .. "§!"
    end
    return "§W+" .. C.short(math.max(n, 0)) .. "§!"
end

local function group_texts(prefix, values, stored)
    local text = {}
    for _, g in ipairs(M.GROUPS) do
        local v = 0
        for _, r in ipairs(g[2]) do
            v = v + (values[r] or 0)
        end
        local neg = v < 0 and not g.no_neg and (g.neg_stored == nil or (stored[g.neg_stored] or 0) < 1000)
        text[prefix .. g[1] .. "/amount"] = balance(v, neg)
    end
    return text
end

-- the sort buttons (CEmpireView::SetSort<N>): Type 0, Name 1, Output 2, Governor 3, Pops 4,
-- Districts 5; the same button again reverses the order; Districts ascending at first
M.SORTS = { sort_type = 0, sort_name = 1, sort_output = 2, sort_governor = 3, sort_pops = 4, sort_districts = 5 }

-- a sector's or a colony's sort key (CEmpireViewSectorEntry / CEmpireViewPlanetEntry::SortLessThan):
-- Output's is never filled (always 0), Governor compares nothing
local function sort_key(kind, e, sort)
    if sort == 0 then
        return e.type or e.class or ""
    elseif sort == 1 then
        return e.sort_name or ""
    elseif sort == 4 then
        return e.pops or 0
    elseif sort == 5 then
        return e.n_districts or 0
    end
    return 0
end

local function sorted(list, kind, sort, rev)
    for i, e in ipairs(list) do
        e.order = i
    end
    table.sort(list, function(a, b2)
        local ka, kb = sort_key(kind, a, sort), sort_key(kind, b2, sort)
        if ka ~= kb then
            if rev then
                return ka > kb
            end
            return ka < kb
        end
        return a.order < b2.order
    end)
    return list
end

function M.build(ctx, d, state)
    d = d or {}
    -- (before the view's data has come, its frame alone: the data is nil until the snapshot
    -- carries it)
    if d.sectors == nil then
        local b0 = C.builder(ctx)
        b0:add(FILE, "empire_view", { only = { background = true, close = true, close_button = true, heading = true }, actions = { [V .. "/close"] = "view_close" } })
        return b0.items, b0.report
    end
    local b = C.builder(ctx)
    local sort, rev = tonumber(state.sort) or 5, state.rev == "1"
    local r = b:add_named(FILE, "empire_view", { actions = {}, named = { actions = (function()
        local a = { close = "view_close" }
        for name, n in pairs(M.SORTS) do
            a[name] = "view_set:sort=" .. n .. ";rev=" .. ((n == sort and not rev) and "1" or "")
        end
        return a
    end)() } })
    local list = r.rects[V .. "/empire_list/planets_window/list"] or r.rects[V .. "/planets_window/list"]
    if not list then
        for path, rr in pairs(r.rects) do
            if path:match("/planets_window/list$") then
                list = rr
            end
        end
    end
    if not list then
        return b.items, b.report
    end
    local y, bottom = list.y, list.y + list.h
    local sectors = {}
    for _, s in ipairs(d.sectors or {}) do
        s.sort_name = C.name(ctx, s.name)
        s.pops, s.n_districts = 0, 0
        for _, cd in ipairs(s.colonies or {}) do
            cd.sort_name = C.name(ctx, cd.name)
            cd.n_districts = 0
            for _, dist in ipairs(cd.districts or {}) do
                cd.n_districts = cd.n_districts + (dist.count or 0)
            end
            s.pops = s.pops + (cd.pops or 0)
            s.n_districts = s.n_districts + cd.n_districts
        end
        sectors[#sectors + 1] = s
    end
    sorted(sectors, "sector", sort, rev)
    for i, s in ipairs(sectors) do
        if y + 100 > bottom then
            break
        end
        local prefix = "/empire_sectors/" .. i
        local p = prefix .. "/planet_list_sector_entry/"
        local values = {}
        local pops = 0
        for _, cd in ipairs(s.colonies) do
            pops = pops + cd.pops
            for k, v in pairs(cd.profits) do
                values[k] = (values[k] or 0) + v
            end
        end
        local text = group_texts(p .. "resources/", values, d.stored or {})
        text[p .. "sector_name"] = C.name(ctx, s.name)
        text[p .. "sector_type"] = s.type or ""
        text[p .. "sector_info/systems"] = tostring(s.systems)
        text[p .. "sector_info/colonies"] = tostring(#s.colonies)
        text[p .. "sector_info/pops_window/pops"] = C.short(pops)
        local expanded = state["expand_" .. s.id] == "1"
        -- a click on the entry expands or collapses it (CEmpireViewSectorEntry::ToggleExpanded); a
        -- core sector can be neither deleted nor made a vassal (CANNOT_DELETE_CORE_SECTOR,
        -- CREATE_VASSAL_CORE_SECTOR_INVALID): both disabled; rename (CEmpireViewSectorEntry::Rename:
        -- CSectorRenameDialog, render.windows.rename); edit opens a window not drawn here [not done
        -- here]
        local core = s.type == "core_sector"
        local er = b:add_named(FILE, "planet_list_sector_entry", {
            prefix = prefix, parent = { x = list.x, y = y, w = 0, h = 0 },
            text = text,
            named = { actions = { rename_button = rename.open("sector", s.id, C.name(ctx, s.name)) } },
            actions = {
                [prefix .. "/planet_list_sector_entry"] = "view_set:expand_" .. s.id .. "=" .. (expanded and "" or "1"),
            },
            disabled = core and {
                [p .. "delete_sector"] = true, [p .. "create_vassal"] = true,
            } or nil,
        })
        local pc = er.rects[p .. "leader_portrait_container"]
        if pc and s.governor then
            leaders.card(ctx, b, "paragon_portrait_container_horizontal", pc, s.governor, { prefix = prefix .. "/governor",
                named_actions = leaders.rename_actions(ctx, s.governor) })
        end
        y = y + 100 + 4
        if expanded then
            for k, cd in ipairs(sorted(s.colonies, "colony", sort, rev)) do
                if y + 95 > bottom then
                    break
                end
                local cp = prefix .. "/colonies/" .. k
                local q = cp .. "/planet_list_planet_entry/"
                local ct = group_texts(q .. "resources/", cd.profits, d.stored or {})
                ct[q .. "planet_name"] = C.name(ctx, cd.name)
                ct[q .. "planet_type"] = cd.class or ""
                ct[q .. "planet_size"] = tostring(cd.size or "")
                local pr = b:add(FILE, "planet_list_planet_entry", {
                    prefix = cp, parent = { x = list.x, y = y, w = 0, h = 0 },
                    text = ct,
                    hide = { sector_capital = cd.id ~= s.capital or nil, planetoid_render_target = true },
                    actions = { [cp .. "/planet_list_planet_entry"] = "select:planet:" .. tostring(cd.planet_id or "") },
                })
                -- the species (planet_list_pop_entry: its 3D portrait not drawn, the count) and the
                -- districts (planet_list_district_entry: the type's icon and count)
                local pops_rect = pr.rects[q .. "pops"]
                if pops_rect then
                    C.overlap(b, pops_rect, #cd.species, 50, 2, function(j, x, yy, pp)
                        b:add(FILE, "planet_list_pop_entry", {
                            prefix = cp .. pp, parent = { x = x, y = yy, w = 0, h = 0 },
                            hide = { portrait = true },
                            text = { [cp .. pp .. "/planet_list_pop_entry/num"] = "§W" .. C.short(cd.species[j].count) .. "§!" },
                        })
                    end)
                end
                local dr = pr.rects[q .. "districts"]
                if dr then
                    for j, dist in ipairs(cd.districts) do
                        local col, row = math.floor((j - 1) / 2), (j - 1) % 2
                        local dp = cp .. "/districts/" .. j
                        local def = C.defs(ctx, "common/districts")[dist.type]
                        -- (CDistrictType's icon file, gfx/interface/icons/districts/<type>.dds [I])
                        local icon = C.icon_file(ctx, "common/districts", dist.type, "gfx/interface/icons/districts/" .. dist.type .. ".dds")
                        b:add(FILE, "planet_list_district_entry", {
                            prefix = dp, parent = { x = dr.x + col * 39, y = dr.y + row * 39, w = 0, h = 0 },
                            sprites = icon and ctx.db.sprites[icon] and { [dp .. "/planet_list_district_entry/icon"] = icon } or nil,
                            textures = icon and not ctx.db.sprites[icon] and { [dp .. "/planet_list_district_entry/icon"] = icon } or nil,
                            text = { [dp .. "/planet_list_district_entry/amount"] = tostring(dist.count) },
                        })
                    end
                end
                y = y + 95 + 4
            end
        end
    end
    -- the rename dialog over the view
    rename.build(b, ctx, "empire", state, nil)
    return b.items, b.report
end

-- its commands in the simulation (views.rs: `cmd:empire:VERB:ARG...`): rename
function M.command(...)
    return require("render.windows.empire_commands").run(...)
end


-- views.rs: the view's data, read where the galaxy is read (the save's world, or the
-- simulation's), for the player's country
function M.extract(game_dir)
    return M.data(require("render.topbar").player(), {})
end


-- Escape (views.rs): the side windows in these state keys close first, else the view closes
M.escape_keys = {}
rename.install(M, "empire")

return M
