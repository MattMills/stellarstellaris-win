-- render/windows/network.lua : the waystation network window (interface/waystation_network_view.gui
-- `waystation_network_view`, CWaystationNetworkView; docs/windows/starbase.md) over the chunk's
-- `networks` (render.windows.starbase_data). No save at hand has a network: the layout follows the
-- files and CWaystationNetworkView::Update, not a frame of the game.
--
--   require("render.windows.network").build(ctx, id, items, report)
--
-- Clicks carry `starbase:network_close`, `starbase:network_prev` / `network_next` and
-- `starbase:network_open:ID` (sim/render/src/starbase.rs).

local gui = require("render.gui")
local names = require("render.names")
local starbase = require("render.windows.starbase")

local M = {}

local FILE = "interface/waystation_network_view.gui"
local W = "/waystation_network_view"

-- the window's network (its id), its values
function M.entry(id)
    local data = starbase.data()
    return data and data.networks and data.networks[id]
end

-- the network's owner (the renderer gives the list's flags their countries) -> { id }
function M.owner(id)
    local e = M.entry(id)
    return e and { e.owner } or {}
end

-- the network's name (CWaystationNetwork::GetName: its own [I] else an empty string)
local function name_of(loc, n)
    return n and n.name and names.format(loc, n.name) or ""
end

function M.build(ctx, id, items, report)
    local n = M.entry(id)
    if not n then
        return
    end
    local loc = ctx.loc
    local data = starbase.data()
    local text, hide, actions = {}, {}, {}

    -- the header: the name (rename_button sized to it, CGameGraphics::AdaptSpriteSizeToText; renaming
    -- the owner's, CanRename [I]); previous / next the owner's networks in turn [I]
    text[W .. "/name"] = name_of(loc, n)
    hide[W .. "/header_actions/previous_extra_shortcut"] = true
    actions[W .. "/header_actions/close"] = "starbase:network_close"
    actions[W .. "/header_actions/previous"] = "starbase:network_prev"
    actions[W .. "/header_actions/next"] = "starbase:network_next"
    -- the modifiers' text: the country and system modifiers (waystation_network_country_modifier,
    -- waystation_network_system_modifier) the network's buildings give [I]: not read here, so
    -- waystation_network_no_modifiers
    text[W .. "/content/modifiers_info/modifiers_text"] = loc and (loc.get("waystation_network_no_modifiers")) or ""

    local wi, wr = gui.layout(ctx.game_dir, ctx.db, FILE, "waystation_network_view", ctx.screen, {
        texture_size = ctx.texture_size, loc = loc,
        hide = hide, text = text, actions = actions,
    })
    gui.merge(items, report, wi, wr)

    -- the list (Update): a waystation_view_entry for each of the network's waystations
    -- (CWaystationViewEntry), the connection line joining them (none before the first or after the
    -- last), then with connected networks (NWaystationUtil::FindConnectedNetworksForCountry: the
    -- save's `networks`) a waystation_separator_view_entry and a waystation_network_view_entry each
    local rect = wr.rects[W .. "/content/waystation_list_container/waystation_list_listbox"]
    if not rect then
        return
    end
    local entries = {}
    for _, fleet in ipairs(n.stations or {}) do
        entries[#entries + 1] = { kind = "waystation_view_entry", h = 40, e = data.starbases[fleet] }
    end
    if #(n.networks or {}) > 0 then
        entries[#entries + 1] = { kind = "waystation_separator_view_entry", h = 20 }
        for _, other in ipairs(n.networks) do
            entries[#entries + 1] = { kind = "waystation_network_view_entry", h = 40, n = M.entry(other), id = other }
        end
    end
    local y = rect.y
    for i, ent in ipairs(entries) do
        if y + ent.h > rect.y + rect.h + 0.5 then
            break
        end
        local rp = W .. "/list/" .. i
        local path = rp .. "/" .. ent.kind
        local t, h, a = {}, {}, {}
        if i == 1 then
            h[path .. "/connection_line_before"] = true
        end
        if i == #entries or (entries[i + 1] and entries[i + 1].kind == "waystation_separator_view_entry") then
            h[path .. "/connection_line_after"] = true
        end
        if ent.kind == "waystation_view_entry" then
            local e = ent.e or {}
            -- the station: its name, type (its size's name), system; the stockpile's collection
            -- icons and status hidden without one [I]; the system's colonies
            t[path .. "/name"] = e.name and names.format(loc, e.name) or ""
            t[path .. "/starbase_type"] = e.size and loc and (loc.get(e.size)) or (e.size or "")
            t[path .. "/system"] = ""
            t[path .. "/colonies_info/colonies_count"] = tostring(e.colonies or 0)
            h[path .. "/stockpile_local_collection_icon"] = true
            h[path .. "/stockpile_remote_collection_icon"] = true
            h[path .. "/stockpile_info"] = true
            if e.fleet then
                a[path .. "/background"] = "select:fleet:" .. e.fleet
            end
        elseif ent.kind == "waystation_network_view_entry" then
            -- a connected network: its name, owner, number of stations; opening it
            t[path .. "/name"] = name_of(loc, ent.n)
            t[path .. "/owner"] = ""
            t[path .. "/stations_info/stations_count"] = tostring(ent.n and #(ent.n.stations or {}) or 0)
            a[path .. "/open_wayline_button"] = "starbase:network_open:" .. ent.id
        end
        local ri, rr = gui.layout(ctx.game_dir, ctx.db, FILE, ent.kind, ctx.screen, {
            texture_size = ctx.texture_size, loc = loc, prefix = rp, parent = { x = rect.x, y = y, w = rect.w, h = ent.h },
            text = t, hide = h, actions = a,
        })
        gui.merge(items, report, ri, rr)
        y = y + ent.h + 5
    end
end

return M
