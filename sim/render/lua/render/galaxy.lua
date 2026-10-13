-- render/galaxy.lua : the galaxy map of the world (engine.world, a save's gamestate): every
-- system's position, its hyperlanes, the country that owns it and that country's map colour.
-- Read by the renderer (sim/render/src/galaxy.rs) after Runtime::load.
--
--   local galaxy = require("render.galaxy")
--   return galaxy.extract(game_dir)   -- flat arrays, see galaxy.extract
--
-- Where the save keeps these:
-- - position: galactic_object[id].coordinate = { x = .. y = .. } (map units; the galaxy's centre
--   is 0,0);
-- - hyperlanes: galactic_object[id].hyperlane = { { to = id length = n } ... }, written on both
--   ends of a lane;
-- - owner: a system has no owner field. It is owned by the owner of its starbase:
--   galactic_object.starbases = { id } (4294967295 when there is none) -> starbase_mgr.starbases
--   [id].station, a ship -> ships[id].fleet -> the country whose
--   fleets_manager.owned_fleets = { { fleet = id } ... } lists that fleet (fleets have no owner
--   field either);
-- - colour: country.flag.colors = { "teal" "dark_teal" ... }, colour names; the first is the
--   empire's colour. The galaxy map draws it with the `map` swatch of flags/colors.txt; where that
--   file has no such swatch, common/named_colors gives it (its `color = { r g b a }`).

local world = require("engine.world")
local defs = require("engine.defs")
local pdxscript = require("pdxscript")

local NONE = 4294967295

local galaxy = {}

-- the blocks of a list block: `{ { to = 1 } { to = 2 } }`
local function blocks(block)
    local out = {}
    if type(block) == "table" then
        for _, e in ipairs(block) do
            if not e.op and not e.text and not e.param then
                out[#out + 1] = e
            end
        end
    end
    return out
end

-- the first `key = value` of a block, as defs.field does (a token's text, or a block)
local field = defs.field

local function hsv_to_rgb(h, s, v)
    h = (h % 1) * 6
    local i = math.floor(h)
    local f = h - i
    local p, q, t = v * (1 - s), v * (1 - s * f), v * (1 - s * (1 - f))
    if i == 0 then
        return v, t, p
    elseif i == 1 then
        return q, v, p
    elseif i == 2 then
        return p, v, t
    elseif i == 3 then
        return p, q, v
    elseif i == 4 then
        return t, p, v
    end
    return v, p, q
end

-- a colour block (`{ r g b a }` or `rgb { r g b }` in 0..255, `{ 0.5 0.2 0.1 }` in 0..1,
-- `hsv { h s v }`, `hsv360 { h s v }`) -> r, g, b in 0..1, or nil
local function colour(block)
    if type(block) ~= "table" then
        return nil
    end
    local n, decimal = {}, false
    for _, e in ipairs(block) do
        if e.text then
            n[#n + 1] = tonumber(e.text)
            decimal = decimal or e.text:find(".", 1, true) ~= nil
        end
    end
    if #n < 3 or not (n[1] and n[2] and n[3]) then
        return nil
    end
    if block.type == "hsv" then
        return hsv_to_rgb(n[1], n[2], n[3])
    elseif block.type == "hsv360" then
        return hsv_to_rgb(n[1] / 360, n[2] / 100, n[3] / 100)
    elseif decimal and n[1] <= 1 and n[2] <= 1 and n[3] <= 1 then
        return n[1], n[2], n[3]
    end
    return n[1] / 255, n[2] / 255, n[3] / 255
end

-- name -> { r, g, b }: the `map` swatches of flags/colors.txt
local function map_swatches(game_dir)
    local out = {}
    local f = io.open(game_dir .. "/flags/colors.txt", "rb")
    if not f then
        return out
    end
    local text = f:read("*a")
    f:close()
    local tree = pdxscript.parse(text, "flags/colors.txt")
    local colors = tree and field(tree, "colors")
    if type(colors) ~= "table" then
        return out
    end
    for _, e in ipairs(colors) do
        if e.op and e.key and type(e.value) == "table" then
            local r, g, b = colour(field(e.value, "map"))
            if r then
                out[e.key.text] = { r, g, b }
            end
        end
    end
    return out
end

-- a colour name -> r, g, b, and where it came from ("map", "named"), or nil
local function resolve_colour(name, swatches)
    local s = swatches[name]
    if s then
        return s[1], s[2], s[3], "map"
    end
    local def = defs.get("common/named_colors", name)
    if def then
        local r, g, b = colour(field(def.block, "color"))
        if r then
            return r, g, b, "named"
        end
    end
    return nil
end

-- a name block (`name = { key = "%ADJ%" variables = { { key = "1" value = { ... } } } }`) as
-- one line: its keys that are not placeholders, in order (localisation keys, not localised)
local function name_text(block, depth)
    depth = depth or 0
    if type(block) ~= "table" or depth > 8 then
        return nil
    end
    local key = world.field(block, "key")
    local parts = {}
    if key ~= nil and not tostring(key):match("^%%") then
        parts[#parts + 1] = tostring(key)
    end
    for _, v in ipairs(blocks(world.field(block, "variables"))) do
        local t = name_text(world.field(v, "value"), depth + 1)
        if t then
            parts[#parts + 1] = t
        end
    end
    if #parts == 0 then
        return key ~= nil and tostring(key) or nil
    end
    return table.concat(parts, " ")
end

-- fleet id -> the country that owns it (country.fleets_manager.owned_fleets)
local function fleet_owners()
    local owner = {}
    for _, cid in ipairs(world.all("country")) do
        local owned = world.path(world.object("country", cid), "fleets_manager", "owned_fleets")
        for _, b in ipairs(blocks(owned)) do
            local f = tonumber(world.field(b, "fleet"))
            if f then
                owner[f] = cid
            end
        end
    end
    return owner
end

-- galaxy.extract(game_dir) -> the map as flat arrays (one value each, for the Rust side):
--   systems:   id, x, y, owner (a country id, -1 for none)
--   lanes:     a, b (indices into the systems, 0-based, a < b, each lane once)
--   countries: id, name, type, colour name, r, g, b (0..1), colour source ("map", "named", "")
--              for every country that owns a system
--   notes:     what was read, as text
function galaxy.extract(game_dir)
    local t0 = RUST.clock()
    local fleets = fleet_owners()
    local swatches = map_swatches(game_dir)

    local sys_id, sys_x, sys_y, sys_owner = {}, {}, {}, {}
    local index = {}   -- system id -> 0-based index
    local starbases, unresolved, several, disagree = 0, 0, 0, 0
    for _, id in ipairs(world.all("system")) do
        local obj = world.object("system", id)
        local x = tonumber(world.path(obj, "coordinate", "x"))
        local y = tonumber(world.path(obj, "coordinate", "y"))
        if x and y then
            -- the owner of the system's first starbase (some systems list more than one)
            local owner, n = -1, 0
            for _, sb in ipairs(world.list(world.field(obj, "starbases"))) do
                sb = tonumber(sb)
                if sb and sb ~= NONE then
                    starbases, n = starbases + 1, n + 1
                    local station = tonumber(world.field(world.object("starbase", sb), "station"))
                    local fleet = station and tonumber(world.field(world.object("ship", station), "fleet"))
                    local cid = fleet and fleets[fleet]
                    if cid == nil then
                        unresolved = unresolved + 1
                    elseif owner < 0 then
                        owner = cid
                    elseif cid ~= owner then
                        disagree = disagree + 1
                    end
                end
            end
            if n > 1 then
                several = several + 1
            end
            index[id] = #sys_id
            sys_id[#sys_id + 1] = id
            sys_x[#sys_x + 1] = x
            sys_y[#sys_y + 1] = y
            sys_owner[#sys_owner + 1] = owner
        end
    end

    local lane_a, lane_b = {}, {}
    local seen, one_sided, dangling = {}, 0, 0
    local ends = {}   -- "a:b" -> how many of the two ends list the lane
    for i, id in ipairs(sys_id) do
        local obj = world.object("system", id)
        for _, h in ipairs(blocks(world.field(obj, "hyperlane"))) do
            local to = tonumber(world.field(h, "to"))
            local j = to and index[to]
            if j == nil then
                dangling = dangling + 1
            else
                local a, b = math.min(i - 1, j), math.max(i - 1, j)
                local key = a .. ":" .. b
                ends[key] = (ends[key] or 0) + 1
                if not seen[key] and a ~= b then
                    seen[key] = true
                    lane_a[#lane_a + 1] = a
                    lane_b[#lane_b + 1] = b
                end
            end
        end
    end
    for _, n in pairs(ends) do
        if n == 1 then
            one_sided = one_sided + 1
        end
    end

    local c_id, c_name, c_type, c_colour, c_r, c_g, c_b, c_source = {}, {}, {}, {}, {}, {}, {}, {}
    local owners = {}
    for _, o in ipairs(sys_owner) do
        if o >= 0 and not owners[o] then
            owners[o] = true
            local c = world.object("country", o)
            local names = world.list(world.path(c, "flag", "colors"))
            local name = names[1] or ""
            local r, g, b, source = resolve_colour(name, swatches)
            c_id[#c_id + 1] = o
            c_name[#c_name + 1] = name_text(world.field(c, "name")) or ("country " .. o)
            c_type[#c_type + 1] = tostring(world.field(c, "type") or "")
            c_colour[#c_colour + 1] = name
            c_r[#c_r + 1], c_g[#c_g + 1], c_b[#c_b + 1] = r or 1, g or 1, b or 1
            c_source[#c_source + 1] = source or ""
        end
    end

    local n_swatches = 0
    for _ in pairs(swatches) do
        n_swatches = n_swatches + 1
    end
    local notes = string.format(
        "%d systems, %d hyperlanes (%d listed on one end only, %d to unknown systems), %d starbases " ..
        "(%d whose owner was not found; %d systems with more than one, %d of those owned by another " ..
        "country than the first), %d owners; %d map swatches in flags/colors.txt; read in %.2f s",
        #sys_id, #lane_a, one_sided, dangling, starbases, unresolved, several, disagree, #c_id, n_swatches,
        RUST.clock() - t0)
    return sys_id, sys_x, sys_y, sys_owner, lane_a, lane_b,
        c_id, c_name, c_type, c_colour, c_r, c_g, c_b, c_source, notes
end

return galaxy
