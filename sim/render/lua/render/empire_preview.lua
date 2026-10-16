-- render/empire_preview.lua : an empire design's preview (interface/new_game_setup.gui
-- `species_preview`): its name, flag, the ruler's room with the city and home world, the
-- government, ethics and civics, the species and its traits, the origin. The empire selection
-- (render.frontend_newgame) and the empire creator (render.newgame_creator) both show it.
--
--   local preview = require("render.empire_preview")
--   preview.build(ctx, b, design, opts)  -- b: render.windows.empire_common's builder; design: a
--                                        -- creator design table or a prescripted block
--   opts.hide_lower = true               -- only the top (the creator's editors cover the rest)
--   opts.actions                         -- element path -> action (the flag, the room, the planet)
--
-- The 3D parts are not drawn: the ruler's portrait (a character in the room), the home world's
-- planet. In their place: the room's texture (gfx/portraits/city_sets/<room>.dds) over the city
-- (<city culture>_city_l03.dds) [I: the room's planet layer, portraits' `room = { planet }`], the
-- planet class's name.

local C = require("render.windows.empire_common")
local rules = require("render.creator_rules")

local preview = {}

local FILE = "interface/new_game_setup.gui"
local P = "/species_preview"

-- flags/colors.txt: colour name -> { r, g, b } 0..1 of its `flag` value
local colours_cache = {}
function preview.flag_colours(game_dir)
    if colours_cache[game_dir] then
        return colours_cache[game_dir]
    end
    local source = require("stellar.script.source")
    local out = {}
    local tree = source.parse(game_dir, "flags/colors.txt") or {}
    local block = C.raw_field(tree, "colors")
    for _, e in ipairs(type(block) == "table" and block or {}) do
        if e.op and e.key and type(e.value) == "table" then
            local f = C.raw_field(e.value, "flag")
            -- `flag = rgb { r g b }`: the parser gives the block after the rgb token
            local nums = {}
            local function grab(t)
                for _, x in ipairs(type(t) == "table" and t or {}) do
                    if x.text and tonumber(x.text) then
                        nums[#nums + 1] = tonumber(x.text)
                    elseif type(x) == "table" and not x.text then
                        grab(x)
                    end
                end
            end
            if type(f) == "table" then
                grab(f)
            end
            if #nums < 3 then
                -- the value may follow as `rgb` then a block entry
                for i, x in ipairs(e.value) do
                    if x.op and x.key and x.key.text == "flag" then
                        local nxt = e.value[i + 1]
                        if nxt and type(nxt) == "table" then
                            grab(nxt)
                        end
                    end
                end
            end
            if #nums >= 3 then
                out[e.key.text] = { nums[1] / 255, nums[2] / 255, nums[3] / 255, map = nil }
            end
        end
    end
    colours_cache[game_dir] = out
    return out
end

-- the colour names of flags/colors.txt in file order (the flag editor's palette)
function preview.colour_names(game_dir)
    local source = require("stellar.script.source")
    local tree = source.parse(game_dir, "flags/colors.txt") or {}
    local block = C.raw_field(tree, "colors")
    local out = {}
    for _, e in ipairs(type(block) == "table" and block or {}) do
        if e.op and e.key then
            out[#out + 1] = e.key.text
        end
    end
    return out
end

-- a flag sprite's texture name for the renderer: "@flag:" and the flagSpriteType's parts and the
-- flag's (src/flag.rs compose_spec reads it): frame|mask|texture_size|bg|symbol|mask_rect|icon
-- category/file|background file|colours
function preview.flag_texture(ctx, sprite, flag)
    local s = ctx.db.sprites[sprite]
    if not (s and s.texture) or not flag then
        return nil
    end
    local function rect(p, z)
        local a, b = s[p], s[z]
        if type(a) ~= "table" or type(b) ~= "table" then
            return ""
        end
        return string.format("%g,%g,%g,%g", a[1] or 0, a[2] or 0, b[1] or 0, b[2] or 0)
    end
    local cols = preview.flag_colours(ctx.game_dir)
    local cs = {}
    for i = 1, 4 do
        local c = cols[(flag.colors or {})[i] or ""]
        cs[i] = c and string.format("%.4f,%.4f,%.4f", c[1], c[2], c[3]) or "0,0,0"
    end
    local icon = flag.icon or {}
    local bg = flag.background or {}
    return table.concat({
        "@flag:" .. s.texture, s.mask or "", s.texture_size or "",
        rect("bg_position", "bg_size"), rect("symbol_position", "symbol_size"), rect("mask_offset", "mask_size"),
        (icon.category or "") .. "/" .. (icon.file or ""), bg.file or "", table.concat(cs, ";"),
    }, "|")
end

-- a design table from what the caller has (a creator design, or a prescripted block)
local function design_of(ctx, d)
    if type(d) ~= "table" then
        return nil
    end
    if d.species and type(d.species) == "table" and d.species.class then
        return d
    end
    return rules.from_block(d)
end

local function loc(ctx, key)
    return C.loc(ctx, key)
end

-- a name the player typed, or a localisation key
local function text_of(ctx, s)
    if not s or s == "" then
        return ""
    end
    if ctx.loc and ctx.loc.has(s) then
        return C.loc(ctx, s)
    end
    return s
end
preview.text_of = text_of

function preview.build(ctx, b, design, opts)
    opts = opts or {}
    local d = design_of(ctx, design)
    local R = rules.load(ctx.game_dir)
    local o = {
        text = {}, hide = {}, textures = {}, sprites = {}, actions = opts.actions or {},
        -- the portrait's 3D character is not drawn
        hide_names = nil,
    }
    o.hide[P .. "/portrait_window/portrait"] = true
    o.hide[P .. "/home_world/arkship_warning"] = true
    if opts.hide_lower then
        for _, n in ipairs({ "government_and_ethics", "species_description_bg", "origin_window", "species_window",
            "ship_window", "dlc_window", "traits_window", "species" }) do
            o.hide[P .. "/" .. n] = true
        end
    end
    if d then
        o.text[P .. "/empire_name/label"] = text_of(ctx, d.name)
        o.text[P .. "/home_world/class/selected"] = loc(ctx, d.planet_class or "")
        o.text[P .. "/home_world/homeworld_name/field"] = text_of(ctx, d.planet_name)
        if d.origin then
            o.textures[P .. "/origin_window/origin_icon"] = C.icon_file(ctx, "common/governments/civics", d.origin,
                "gfx/interface/icons/governments/civics/" .. d.origin .. ".dds")
            o.text[P .. "/origin_window/origin_name"] = loc(ctx, d.origin)
            o.text[P .. "/origin_window/origin_desc"] = loc(ctx, d.origin .. "_desc")
        end
    end
    -- the room under the window's frames: the city behind, the room over it, cut to the window
    local r0 = b:add(FILE, "species_preview", { only = { background = true }, hide = { empire_name = true, origin_window = true,
        portrait_window = true, empire_flag = true, home_world = true, government_and_ethics = true, species_description_bg = true } })
    local pw = r0.rects and r0.rects[P .. "/portrait_window"]
    local wrect = r0.rects and r0.rects[P]
    if wrect then
        -- the portrait window's place (its own layout gives it; laid out below)
        local px, py = wrect.x + 6, wrect.y + 60
        if d then
            local s = 0.8
            local rw, rh = 952 * s, 340 * s
            local city = "gfx/portraits/city_sets/" .. (d.city_graphical_culture or "mammalian_01") .. "_city_l03.dds"
            local tw, th = ctx.texture_size(city)
            if tw then
                local cw, ch = tw * 0.714 * s, th * 0.714 * s
                b:texture("/preview/city", city, px + 4 + rw - cw, py + 4 - 23 * s, cw, ch)
            end
            local room = "gfx/portraits/city_sets/" .. ((d.room and d.room ~= "") and d.room or "default_room") .. ".dds"
            if ctx.texture_size(room) then
                b:texture("/preview/room", room, px + 4, py + 4, rw, rh)
            end
        end
    end
    -- the window (its background already drawn)
    o.hide[P .. "/background"] = true
    local r = b:add(FILE, "species_preview", o)
    -- the flag: its composed texture on GFX_empire_flag_200's frame
    local fr = r.rects[P .. "/empire_flag"]
    if fr and d then
        local tex = preview.flag_texture(ctx, "GFX_empire_flag_200", d.empire_flag)
        if tex then
            for i = #b.items, 1, -1 do
                local it = b.items[i]
                if it.path == P .. "/empire_flag" and it.kind == "sprite" then
                    it.texture = tex
                    it.sprite_kind = "flagSpriteType"
                    it.frames, it.frame = 1, 1
                    break
                end
            end
        end
    end
    return r, d
end

return preview
