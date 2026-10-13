-- render/galaxy.lua : the galaxy map of the world (engine.world, a save's gamestate) and the game
-- files it is drawn with: every system's position, star class and star sprite, its hyperlanes,
-- the country that owns it and that country's colours; the map's settings from common/defines.
-- Read by the renderer (sim/render/src/galaxy.rs) after Runtime::load_world.
--
--   local galaxy = require("render.galaxy")
--   return galaxy.extract(game_dir)   -- a table, see galaxy.extract
--
-- Where these are:
-- - position: galactic_object[id].coordinate = { x = .. y = .. } (map units, the centre 0,0);
-- - star class: galactic_object[id].star_class ("sc_g"); common/star_classes gives its class
--   ("g_star") and icon_scale; the galaxy map draws gfx/map/star_classes/<class>.dds (the engine
--   names the file: no .gfx lists these), or <star class>.dds where there is one (sc_m_giant);
-- - hyperlanes: galactic_object[id].hyperlane = { { to = id length = n } ... }, on both ends;
-- - owner: world.system_owner (its starbase's owner, see engine/world.lua);
-- - colours: country.flag.colors = { "teal" "dark_teal" ... }; the map draws the first as the
--   border's edge and the second as its fill, each with the `map` swatch of flags/colors.txt
--   (common/named_colors where that has none);
-- - settings: common/defines NGraphics (HYPERLANE_DEFAULT_COLOR, GALAXY_STAR_ICON_SCALE,
--   BORDER_SYSTEM_RADIUS, BORDER_HYPERLANE_THICKNESS, BORDER_TEXTURE_SIZE, GALAXY_DUST_SIZE,
--   GALAXY_DUST_SIZE_EXTRA).

local world = require("engine.world")
local source = require("stellar.script.source")

local galaxy = {}

local function field(block, key)
    for _, e in ipairs(block or {}) do
        if e.op and e.key and e.key.text == key then
            return e.value.text or e.value
        end
    end
    return nil
end

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

-- the numbers of a block
local function numbers(block)
    local n, decimal = {}, false
    for _, e in ipairs(type(block) == "table" and block or {}) do
        if e.text then
            n[#n + 1] = tonumber(e.text)
            decimal = decimal or e.text:find(".", 1, true) ~= nil
        end
    end
    return n, decimal
end

-- a colour block (`{ r g b a }` or `rgb { r g b }` in 0..255, `{ 0.5 0.2 0.1 }` in 0..1,
-- `hsv { h s v }`, `hsv360 { h s v }`) -> r, g, b in 0..1, or nil
local function colour(block)
    if type(block) ~= "table" then
        return nil
    end
    local n, decimal = numbers(block)
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

local function exists(path)
    local f = io.open(path, "rb")
    if f then
        f:close()
        return true
    end
    return false
end

-- name -> { r, g, b }: the `map` swatches of flags/colors.txt
local function map_swatches(game_dir)
    local out = {}
    local tree = source.parse(game_dir, "flags/colors.txt")
    local colors = tree and field(tree, "colors")
    for _, e in ipairs(type(colors) == "table" and colors or {}) do
        if e.op and e.key and type(e.value) == "table" then
            local r, g, b = colour(field(e.value, "map"))
            if r then
                out[e.key.text] = { r, g, b }
            end
        end
    end
    return out
end

-- the defines of common/defines: namespace -> KEY -> value (a token's text or a block), files in
-- name order, a later value replacing an earlier one
local function defines(game_dir)
    local out = {}
    for _, f in ipairs(source.files(game_dir, "common/defines", "txt")) do
        local tree = source.parse(game_dir, f)
        for _, top in ipairs(tree or {}) do
            if top.op and top.key and type(top.value) == "table" then
                local ns = out[top.key.text] or {}
                out[top.key.text] = ns
                for _, e in ipairs(top.value) do
                    if e.op and e.key then
                        ns[e.key.text] = e.value.text or e.value
                    end
                end
            end
        end
    end
    return out
end

-- galaxy.extract(game_dir) -> {
--   date, notes,
--   systems = { { id, x, y, owner (country id or -1), star_class, class, texture, icon_scale } },
--   lanes = { { a, b } }      (indices into systems, 1-based, each lane once),
--   countries = { { id, name, kind, colours = { name1, name2 }, primary = {r,g,b},
--                   secondary = {r,g,b}, source } }   (the owners of systems),
--   hyperlane_colour = { r, g, b, a }, star_icon_scale, border_system_radius,
--   border_hyperlane_thickness }
function galaxy.extract(game_dir)
    local t0 = RUST.clock()
    local swatches = map_swatches(game_dir)
    local named = source.definitions(game_dir, "common/named_colors")
    local classes = source.definitions(game_dir, "common/star_classes")
    local def = defines(game_dir)
    local ng = def.NGraphics or {}

    local function resolve(name)
        local s = swatches[name]
        if s then
            return { s[1], s[2], s[3] }, "map"
        end
        local d = named[name]
        if d then
            local r, g, b = colour(field(d.block, "color"))
            if r then
                return { r, g, b }, "named"
            end
        end
        return nil
    end

    -- star class -> { class, texture, icon_scale }
    local star_info, missing_textures = {}, {}
    local function star(key)
        if star_info[key] == nil then
            local d = classes[key]
            local class = d and field(d.block, "class") or key
            local scale = d and tonumber(field(d.block, "icon_scale")) or 1
            local texture
            for _, name in ipairs({ key, class }) do
                local rel = "gfx/map/star_classes/" .. name .. ".dds"
                if exists(game_dir .. "/" .. rel) then
                    texture = rel
                    break
                end
            end
            if not texture then
                missing_textures[#missing_textures + 1] = key
            end
            star_info[key] = { class = class, texture = texture or "", icon_scale = scale }
        end
        return star_info[key]
    end

    local systems, index = {}, {}
    for _, id in ipairs(world.all("system")) do
        local obj = world.object("system", id)
        local x = tonumber(world.path(obj, "coordinate", "x"))
        local y = tonumber(world.path(obj, "coordinate", "y"))
        if x and y then
            local sc = tostring(world.field(obj, "star_class") or "sc_g")
            local info = star(sc)
            systems[#systems + 1] = {
                id = id, x = x, y = y, owner = world.system_owner[id] or -1,
                star_class = sc, class = info.class, texture = info.texture, icon_scale = info.icon_scale,
            }
            index[id] = #systems
        end
    end

    local lanes, seen = {}, {}
    for i, s in ipairs(systems) do
        for _, h in ipairs(world.blocks(world.field(world.object("system", s.id), "hyperlane"))) do
            local j = index[tonumber(world.field(h, "to"))]
            if j and j ~= i then
                local a, b = math.min(i, j), math.max(i, j)
                local key = a * 65536 + b
                if not seen[key] then
                    seen[key] = true
                    lanes[#lanes + 1] = { a, b }
                end
            end
        end
    end

    local countries, owners = {}, {}
    for _, s in ipairs(systems) do
        local o = s.owner
        if o >= 0 and not owners[o] then
            owners[o] = true
            local c = world.object("country", o)
            local names = world.list(world.path(c, "flag", "colors"))
            local p, src = resolve(names[1] or "")
            local q = resolve(names[2] or "") or p
            countries[#countries + 1] = {
                id = o, name = galaxy.name_text(world.field(c, "name")) or ("country " .. o),
                kind = tostring(world.field(c, "type") or ""),
                colours = { names[1] or "", names[2] or "" },
                primary = p or { 1, 1, 1 }, secondary = q or { 1, 1, 1 }, source = src or "",
            }
        end
    end

    local hl = numbers(ng.HYPERLANE_DEFAULT_COLOR)
    local classes_used = 0
    for _ in pairs(star_info) do
        classes_used = classes_used + 1
    end
    local out = {
        date = (tostring(world.meta.date or ""):gsub('"', "")),
        systems = systems, lanes = lanes, countries = countries,
        hyperlane_colour = #hl >= 4 and hl or { 0, 1, 1, 0.2 },
        star_icon_scale = tonumber(ng.GALAXY_STAR_ICON_SCALE) or 1.5,
        border_system_radius = tonumber(ng.BORDER_SYSTEM_RADIUS) or 35,
        border_hyperlane_thickness = tonumber(ng.BORDER_HYPERLANE_THICKNESS) or 20,
        border_texture_size = tonumber(ng.BORDER_TEXTURE_SIZE) or 2048,
        dust_size = tonumber(ng.GALAXY_DUST_SIZE) or 25,
        dust_size_extra = tonumber(ng.GALAXY_DUST_SIZE_EXTRA) or 35,
    }
    out.notes = string.format(
        "%d systems, %d hyperlanes, %d owners; %d star classes used (no texture for: %s); " ..
        "HYPERLANE_DEFAULT_COLOR {%s}, GALAXY_STAR_ICON_SCALE %s, BORDER_SYSTEM_RADIUS %s, " ..
        "BORDER_HYPERLANE_THICKNESS %s; read in %.2f s",
        #systems, #lanes, #countries, classes_used, table.concat(missing_textures, " "),
        table.concat(out.hyperlane_colour, " "), out.star_icon_scale, out.border_system_radius,
        out.border_hyperlane_thickness, RUST.clock() - t0)
    return out
end

-- a name block (`name = { key = "%ADJ%" variables = { { key = "1" value = { ... } } } }`) as one
-- line: its keys that are not placeholders, in order (localisation keys, not localised)
function galaxy.name_text(block, depth)
    depth = depth or 0
    if type(block) ~= "table" or depth > 8 then
        return nil
    end
    local key = world.field(block, "key")
    local parts = {}
    if key ~= nil and not tostring(key):match("^%%") then
        parts[#parts + 1] = tostring(key)
    end
    for _, v in ipairs(world.blocks(world.field(block, "variables"))) do
        local t = galaxy.name_text(world.field(v, "value"), depth + 1)
        if t then
            parts[#parts + 1] = t
        end
    end
    if #parts == 0 then
        return key ~= nil and tostring(key) or nil
    end
    return table.concat(parts, " ")
end

return galaxy
