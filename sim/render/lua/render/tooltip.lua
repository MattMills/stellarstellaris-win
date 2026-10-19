-- render/tooltip.lua : the tooltips' texts built from the world (docs/tooltips.md): the top bar's
-- resources, the outliner's rows, the map's stars, planets and fleets. The renderer
-- (src/tooltip.rs) asks for an element's (by its GUI path) or a map thing's (kind, id); nil: the
-- element's own tooltip (a window's `tooltips`, else the .gui's pdx_tooltip) is shown, or none.
-- The texts are pdxscript texts (localisation keys or texts with colour codes and £icons£),
-- localised and drawn by render.gui.
--
-- The data: RENDER_OUTLINER.view (render.windows.outliner's extract, installed in this runtime
-- for the outliner: its `tips` part).

local M = {}

local function view()
    return RENDER_OUTLINER and RENDER_OUTLINER.view or {}
end

local function loc_text(key, vars)
    local loc = RENDER_LOC
    if not loc then
        return key
    end
    local t = loc.has(key) and loc.raw and loc.raw(key) or (loc.has(key) and loc.get(key)) or key
    for k, v in pairs(vars or {}) do
        t = t:gsub("%$" .. k .. "[^$]*%$", (tostring(v):gsub("%%", "%%%%")))
    end
    return t
end
M.loc_text = loc_text

local function fmt_name(n)
    if type(n) ~= "table" then
        return n and tostring(n) or ""
    end
    return require("render.names").format(RENDER_LOC, n)
end
M.fmt_name = fmt_name

-- a raw tooltip made a text: a localisation key localised ($KEY$s resolved), a text kept; a
-- button's shortcut (after a \2) adds the line "Hotkey: KEY" (CTooltipManager)
function M.resolve(raw)
    local head, key = tostring(raw):match("^(.-)\2(.*)$")
    head = head or tostring(raw)
    local loc = RENDER_LOC
    local text = head
    if loc and head ~= "" then
        if loc.has(head) then
            text = (loc.get(head))
        elseif head:find("$", 1, true) then
            text = (loc.resolve(head))
        end
    end
    if key and key ~= "" then
        local line = "\194\167GHotkey: " .. key:upper() .. "\194\167!"
        text = text ~= "" and (text .. "\n" .. line) or line
    end
    return text
end

-- providers by path pattern: function(path, captures...) -> text | nil
M.elements = {}
-- providers by map kind: function(id) -> text | nil
M.things = {}

function M.element(path)
    for _, p in ipairs(M.elements) do
        local caps = { path:match(p.pattern) }
        if caps[1] then
            local ok, t = pcall(p.text, path, table.unpack and table.unpack(caps) or unpack(caps))
            if ok and t and t ~= "" then
                return t
            elseif not ok then
                io.stderr:write("tooltip: " .. tostring(t) .. string.char(10))
            end
        end
    end
    return nil
end

function M.map(kind, id)
    local f = M.things[kind]
    if not f then
        return nil
    end
    local ok, t = pcall(f, tonumber(id))
    if ok then
        return t
    end
    io.stderr:write("tooltip: " .. tostring(t) .. string.char(10))
    return nil
end

-- a provider of texts for the elements whose path matches a Lua pattern (the windows' own texts
-- built at run time; static ones go through their layout's `tooltips` option)
function M.add_element(pattern, text)
    M.elements[#M.elements + 1] = { pattern = pattern, text = text }
end

-- ---------------------------------------------------------------------------------------------
-- the texts (docs/tooltips.md: the game's functions and keys)
-- ---------------------------------------------------------------------------------------------

local S = "\194\167"

local function tips()
    return view().tips or {}
end

-- a number with up to `dec` decimals, trailing zeros cut (WriteFixedPointToStrBuffer)
local function num(v, dec)
    local s = string.format("%." .. (dec or 2) .. "f", v or 0)
    if s:find("%.") then
        s = s:gsub("0+$", ""):gsub("%.$", "")
    end
    return s
end
M.num = num

-- `$VALUE|+=$`: signed, green or red by sign
local function signed(v, dec)
    if (v or 0) < 0 then
        return S .. "R" .. num(v, dec) .. S .. "!"
    end
    return S .. "G+" .. num(v, dec) .. S .. "!"
end

local function yellow(s)
    return S .. "Y" .. tostring(s) .. S .. "!"
end

local function header(key_or_text)
    return S .. "H" .. loc_text(key_or_text) .. S .. "!"
end

local function lines(list)
    local out = {}
    for _, l in ipairs(list) do
        if l and l ~= "" then
            out[#out + 1] = l
        end
    end
    return table.concat(out, "\n")
end

-- the resources of the top bar's single-resource groups
local GROUP_RES = {
    tb_energy_group = "energy", tb_mineral_group = "minerals", tb_food_group = "food",
    tb_consumer_goods_group = "consumer_goods", tb_alloys_group = "alloys", tb_trade_group = "trade",
    tb_influence_group = "influence", tb_unity_group = "unity",
}

-- a single resource's (GetToolTipForTopBarResources @0x329d0b0): its name, stored (of its max),
-- the monthly gain, produced and consumed with their rows (NAMED_RESOURCE_TABLE), monthly
-- trades; under it, its description (<res>_desc, in §L)
local function resource_tip(res)
    local e = (tips().economy or {})[res]
    if not e then
        return nil
    end
    local out = { header(res) }
    if e.max then
        out[#out + 1] = loc_text("RESOURCES_STORED_MAX", { VALUE = yellow(math.floor(e.stock)), MAX = yellow(num(e.max, 0)) })
    else
        out[#out + 1] = loc_text("RESOURCES_STORED", { VALUE = yellow(math.floor(e.stock)) })
    end
    out[#out + 1] = loc_text("RESOURCES_GAINED", { GAIN = signed(e.balance) })
    local function rows(list)
        for _, r in ipairs(list or {}) do
            out[#out + 1] = loc_text("NAMED_RESOURCE_TABLE", { NAME = loc_text(r.cat), TABLE = yellow(string.format("%.2f", r.value)) })
        end
    end
    if (e.produced or 0) ~= 0 then
        out[#out + 1] = loc_text("PRODUCED", { VALUE = signed(e.produced) })
        rows(e.income)
    end
    if (e.consumed or 0) ~= 0 then
        out[#out + 1] = loc_text("CONSUMED", { VALUE = signed(-e.consumed) })
        rows(e.expenses)
    end
    if (e.trade or 0) ~= 0 then
        out[#out + 1] = loc_text("MONTHLY_TRADE_TT", { VALUE = signed(e.trade) })
    end
    -- (its description, <res>_desc, the tooltip's `desc` part, does not show in the game's frame
    -- after 2 s of rest [I: when the game draws a desc not read])
    return lines(out)
end

-- research (BuildTooltipForResources): the category's header, a line per area
local function research_tip()
    local r = tips().research or {}
    local out = { header("RESEARCH") }
    for _, area in ipairs({ "physics_research", "society_research", "engineering_research" }) do
        out[#out + 1] = "\194\163" .. area .. "\194\163 " .. loc_text(area) .. ": " .. S .. "W+" .. num(r[area] or 0, 0) .. S .. "!"
    end
    return lines(out)
end

-- the counters (CTopBarCountry*Controller::GetToolTip): their header and value [I: the
-- breakdowns not built; their desc part not shown, as the resources']
local function counter_tip(group)
    local c = tips().counters or {}
    if group == "empire_size_group" then
        return header("EMPIRE_SIZE") .. "\n" .. loc_text("EMPIRE_SIZE_TOTAL", { VALUE = yellow(num(c.empire_size, 0)) })
    elseif group == "starbase_group" then
        return header("STARBASE_CAPACITY_TITLE") .. "\n" .. loc_text("STARBASE_CAPACITY_TOOLTIP", { MAX = yellow(num(c.starbase_cap, 0)) })
    elseif group == "navy_group" then
        return header("NAVY_SIZE_TITLE") .. "\n" .. loc_text("NAVY_SIZE_TOOLTIP", { MAX = yellow(num(c.navy_cap, 0)) })
    end
    return nil
end

M.add_element("^/maingui/topbar_static/(tb_[%w_]+_group)", function(_, group)
    if GROUP_RES[group] then
        return resource_tip(GROUP_RES[group])
    elseif group == "tb_research_group" then
        return research_tip()
    end
    return nil
end)
M.add_element("^/maingui/topbar_static/([%w_]+_group)", function(_, group)
    return counter_tip(group)
end)

-- the date and the speed buttons (CMainGui's time window): paused or running, its keys
M.add_element("^/maingui/time_window/(.*)", function(_, el)
    local paused = RENDER_TOOLTIP_PAUSED
    if el:find("increase_speed", 1, true) then
        return lines({ header("INCREASE_GAME_SPEED"), loc_text("HOTKEY_KP_PLUS") })
    elseif el:find("decrease_speed", 1, true) then
        return lines({ header("DECREASE_GAME_SPEED"), loc_text("HOTKEY_KP_MINUS") })
    end
    return lines({ header("GAME_SPEED_" .. (paused and 0 or (RENDER_TOOLTIP_SPEED or 3))), loc_text(paused and "TIME_RESUME" or "TIME_PAUSE"),
        loc_text("MOUSE_SHORTCUT", { KEY = "Mouse5" }), loc_text("HOTKEY_SPACE"), loc_text("HOTKEY_JUMP_TO_NEXT_DAY") })
end)

-- a ship (CShip::GetToolTip @0x2abb830): its size and name (§H), its class in its class's
-- colour with its icon, the owner (§Y), hull, armor and shields (current §G, §R when under the
-- maximum; the maximum §Y), FTL
local CLASS_LOOK = {
    shipclass_science = { "B", "science_ship|1" }, shipclass_constructor = { "H", "construction_ship" },
    shipclass_colonizer = { "E", "colony_ship" }, shipclass_military = { "R", "military_ship" },
    shipclass_transport = { "G", "army_ship" }, shipclass_starbase = { "W", "military_ship" },
}
function M.ship_text(s)
    if not s then
        return nil
    end
    local look = CLASS_LOOK[s.class] or { "W", "military_ship" }
    local title = S .. "H" .. loc_text(s.size) .. S .. "! " .. S .. "H" .. fmt_name(s.name) .. S .. "!"
    local class = S .. look[1] .. "\194\163" .. look[2] .. "\194\163 " .. fmt_name(s.design) .. "-class" .. S .. "!"
    local function hp(key, cur, max)
        local c = (cur or 0) < (max or 0) and "R" or "G"
        return loc_text(key) .. ": " .. S .. c .. num(cur, 0) .. S .. "!/" .. yellow(num(max, 0))
    end
    return lines({
        title, class, S .. "Y" .. fmt_name(s.owner) .. S .. "!",
        hp("HITPOINTS", s.hp, s.max_hp), hp("ARMOR", s.armor, s.max_armor), hp("SHIELDS", s.shields, s.max_shields),
        loc_text("SHIP_FTL_YES"),
    })
end

-- a fleet (CFleet::GetToolTip @0x2934cb0): a civilian one as its lead ship; a military one its
-- name, power, hull points, then its composition
function M.fleet_text(f)
    if not f then
        return nil
    end
    if f.civilian or f.station then
        return M.ship_text(f.lead)
    end
    local out = { S .. "H" .. fmt_name(f.name) .. S .. "!" }
    if (f.power or 0) > 0 then
        out[#out + 1] = loc_text("MILITARY_POWER_TIP", { VALUE = yellow(num(f.power, 0)) })
    end
    out[#out + 1] = loc_text("HITPOINTS") .. ": " .. S .. ((f.hp < f.max_hp) and "R" or "G") .. num(f.hp, 0) .. S .. "!/" .. yellow(num(f.max_hp, 0))
    out[#out + 1] = ""
    out[#out + 1] = header("FLEET_COMPOSITION")
    for _, c in ipairs(f.sizes or {}) do
        out[#out + 1] = loc_text(c.size) .. ": " .. yellow(c.n)
    end
    return table.concat(out, "\n")
end

M.things.fleet = function(id)
    return M.fleet_text((tips().fleets or {})[id])
end
M.things.ship = function(id)
    return M.ship_text((tips().ships or {})[id])
end

-- a system (CGalacticObject::GetToolTip @0x2605440): its name, "---", whose space it lies in
M.things.system = function(id)
    local s = (tips().systems or {})[id]
    if not s then
        return nil
    end
    local out = { S .. "H" .. fmt_name(s.name) .. S .. "!" }
    if s.type then
        out[#out + 1] = S .. "E" .. loc_text(s.type) .. S .. "!"
    end
    out[#out + 1] = "---"
    if s.owner then
        out[#out + 1] = loc_text("BORDERS_WITHIN_DESC", { COUNTRY = yellow(fmt_name(s.owner)) })
    end
    if s.star then
        out[#out + 1] = ""
        out[#out + 1] = S .. "H" .. loc_text(s.star) .. S .. "!"
    end
    return table.concat(out, "\n")
end

-- a planet (CPlanet::GetToolTip @0x2a669e0): its name (§H), its class (§Y)
function M.planet(name, class)
    return lines({ S .. "H" .. fmt_name(name) .. S .. "!", class and class ~= "" and (S .. "Y" .. loc_text(class) .. S .. "!") or nil })
end

-- a colony in the outliner (CColony::GetToolTip @0x28664a0): its name, owner, population and
-- dominant species; then the select hint
function M.colony_text(name, owner, c)
    local out = { S .. "H" .. fmt_name(name) .. S .. "!" }
    if owner then
        out[#out + 1] = loc_text("OWNER_COUNTRY", { COUNTRY = yellow(fmt_name(owner)) })
    end
    if c then
        out[#out + 1] = loc_text("PLANET_POPULATION", { NUM_POPS = yellow(num(c.pops, 0)), POP_POPS = loc_text(c.pops == 1 and "POP" or "POPS") })
        if c.species then
            out[#out + 1] = loc_text("DOMINANT_SPECIES", { SPECIES = yellow(fmt_name(c.species)) })
        end
    end
    return lines(out) .. "\n\n" .. loc_text("OUTLINER_MEMBER_SELECT_DESC")
end

-- the outliner's select hint (OUTLINER_MEMBER_SELECT_DESC) after a text
function M.with_select_hint(text)
    if not text then
        return nil
    end
    return text .. "\n" .. loc_text("OUTLINER_MEMBER_SELECT_DESC")
end

return M
