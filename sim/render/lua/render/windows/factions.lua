-- render/windows/factions.lua : the factions view (interface/topbar_factions_view.gui,
-- CTopBarFactionsViewImp; docs/windows/empire.md section 7): the empire's pops by ethic in the
-- header (ethics_attraction_entry: the pops holding the ethic and their monthly change, sorted
-- by pops), the factions' list (pop_faction_list_entry), the selected faction's name and stats
-- ("No Factions" without any); its tabs open the council and the policies and edicts views.

local world = require("engine.world")
local C = require("render.windows.empire_common")

local M = {}

local FILE = "interface/topbar_factions_view.gui"
local V = "/topbar_factions_view"

function M.data(cid, state)
    local galaxy = require("render.galaxy")
    local c = world.object("country", cid)
    if not c then
        return {}
    end
    local d = { distribution = {}, change = {}, factions = {} }
    for _, v in ipairs(world.list(world.field(c, "ethics_distribution"))) do
        d.distribution[#d.distribution + 1] = tonumber(v) or 0
    end
    for _, v in ipairs(world.list(world.field(c, "pops_ethics_change"))) do
        d.change[#d.change + 1] = tonumber(v) or 0
    end
    -- the country's pop factions (pop_factions = { ID = { country type name ... } })
    for _, id in ipairs(world.all("pop_factions")) do
        local f = world.object("pop_factions", id)
        if f and tonumber(world.field(f, "country")) == cid then
            d.factions[#d.factions + 1] = { id = id, type = C.strip(world.field(f, "type")), name = galaxy.name_block(world.field(f, "name")) }
        end
    end
    return d
end

function M.build(ctx, d, state)
    d = d or {}
    -- (before the view's data has come, its frame alone: the data is nil until the snapshot
    -- carries it)
    if d.distribution == nil then
        local b0 = C.builder(ctx)
        b0:add(FILE, "topbar_factions_view", { only = { background = true, close = true, close_button = true, heading = true }, actions = { [V .. "/close"] = "view_close" } })
        return b0.items, b0.report
    end
    local b = C.builder(ctx)
    local text, hide = {}, {}
    if #(d.factions or {}) == 0 then
        -- no faction selected (CTopBarFactionsViewImp::Update): NO_FACTIONS_LABEL, no stats, no
        -- icon, no actions
        text[V .. "/selected_faction_name_label"] = "NO_FACTIONS_LABEL"
        hide.stat_box = true
        hide.faction_icon = true
        hide.actions = true
    end
    hide.column_labels = true
    local actions = {
        [V .. "/close"] = "view_close",
        [V .. "/tab_council"] = "view:council",
        [V .. "/tab_edicts_and_policies"] = "view:edicts",
    }
    local r = b:add_named(FILE, "topbar_factions_view", { hide = hide, actions = actions,
        named = { text = { selected_faction_name_label = text[V .. "/selected_faction_name_label"] } } })

    -- the header: the regular ethics (not fanatic, not gestalt: the 8 with a fanatic variant's
    -- regular_variant pointing at them [I]) in common/ethics' order, their pops
    -- (ethics_distribution's index is that order) and change, sorted by pops (stable)
    local order = C.def_order(ctx, "common/ethics")
    local regular = {}
    for _, k in ipairs(order) do
        local e = C.defs(ctx, "common/ethics")[k]
        local rv = e and C.field(e, "regular_variant")
        if rv then
            regular[rv] = true
        end
    end
    local entries = {}
    for i, k in ipairs(order) do
        if regular[k] then
            entries[#entries + 1] = { key = k, pops = (d.distribution or {})[i] or 0, change = (d.change or {})[i] or 0, i = #entries }
        end
    end
    table.sort(entries, function(a, b2)
        if a.pops ~= b2.pops then
            return a.pops > b2.pops
        end
        return a.i < b2.i
    end)
    local grid
    for path, rr in pairs(r.rects) do
        if path:match("/ethics_attraction_list$") then
            grid = rr
        end
    end
    if grid then
        for i, e in ipairs(entries) do
            local prefix = "/factions_ethics/" .. i
            local p = prefix .. "/ethics_attraction_entry/"
            local label = ""
            if e.pops ~= 0 or e.change ~= 0 then
                -- (the change green when up, yellow when none, red when down [I: the frame's])
                local cc = e.change > 0 and "G" or (e.change < 0 and "R" or "Y")
                label = "§W" .. C.short(e.pops) .. "§!\n(§" .. cc .. (e.change >= 0 and "+" or "") .. e.change .. "§!)"
            end
            -- (a slot of 80 x 35 from the box's lower left: LOWER_LEFT; an icon without a label
            -- centred in its slot)
            local er = b:add(FILE, "ethics_attraction_entry", {
                prefix = prefix, parent = { x = grid.x + (i - 1) * 80, y = grid.y + grid.h - 35, w = 0, h = 0 },
                sprites = { [p .. "ethic_icon"] = "GFX_ethic" },
                textures = { [p .. "ethic_icon"] = "gfx/interface/icons/ethics/" .. e.key .. ".dds" },
                text = { [p .. "ethics_label"] = label },
                positions = label == "" and { [p .. "ethic_icon"] = { 40 - 16, 17 } } or nil,
            })
        end
    end
    return b.items, b.report
end


-- views.rs: the view's data, read where the galaxy is read (the save's world, or the
-- simulation's), for the player's country
function M.extract(game_dir)
    return M.data(require("render.topbar").player(), {})
end


-- Escape (views.rs): the side windows in these state keys close first, else the view closes
M.escape_keys = {}

return M
