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
-- The 3D parts (render.portraits' insets, portraits.rs): the ruler in the room (portrait_window's
-- GFX_portrait_gamesetup_mask: the room's render target), the species' portrait (species_window),
-- the home world's planet (home_world/3d_icon) and the ship (ship_preview/render_target). The
-- room: its texture (gfx/portraits/city_sets/<room>.dds) over the city (<city culture>_city_l03.dds)
-- [I: the room's planet layer, portraits' `room = { planet }`].

local C = require("render.windows.empire_common")
local rules = require("render.creator_rules")
local portraits = require("render.portraits")

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
    -- (@grey and @white: the flag editor's background patterns, drawn in greys)
    local plain = { ["@grey"] = { 0.4, 0.4, 0.4 }, ["@white"] = { 0.85, 0.85, 0.85 } }
    for i = 1, 4 do
        local n = (flag.colors or {})[i] or ""
        local c = plain[n] or cols[n]
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

-- preview.planet_entity(game_dir, class) -> the entity of a planet class (common/planet_classes
-- `entity`: its first variant, <entity>_01_entity, else <entity>_entity, else itself), or nil
local planet_entities = {}
function preview.planet_entity(game_dir, class)
    if planet_entities[class] == nil then
        local source = require("stellar.script.source")
        local base
        for _, f in ipairs(RUST and RUST.list_files and RUST.list_files(game_dir, "common/planet_classes", "txt") or {}) do
            for _, e in ipairs(source.parse(game_dir, f) or {}) do
                if not base and e.op and e.key and e.key.text == class and type(e.value) == "table" then
                    base = C.raw_field(e.value, "entity")
                    base = type(base) == "string" and base:gsub('"', "") or nil
                end
            end
        end
        planet_entities[class] = base and (base .. "_01_entity") or false
    end
    return planet_entities[class] or nil
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
    if opts.only_background then
        return r0, d
    end
    local pw = r0.rects and r0.rects[P .. "/portrait_window"]
    local wrect = r0.rects and r0.rects[P]
    if wrect then
        -- the portrait window's place (its own layout gives it; laid out below)
        local px, py = wrect.x + 6, wrect.y + 60
        -- (cut to the portrait window, 771 x 285, which clips: `clipping = yes`)
        b.items[#b.items + 1] = { kind = "sprite", path = "/clip", sprite = "", texture = "", sprite_kind = "clip",
            frame = 1, frames = 1, x = px + 4, y = py + 4, w = 952 * 0.8, h = 340 * 0.8 }
        if d then
            local s = 0.8
            local rw, rh = 952 * s, 340 * s
            local city = "gfx/portraits/city_sets/" .. (d.city_graphical_culture or "mammalian_01") .. "_city_l03.dds"
            local tw, th = ctx.texture_size(city)
            -- the home world's landscape behind the city (species_preview_backgrounds) [I]
            local sky = "gfx/portraits/species_preview_backgrounds/species_preview_bg_"
                .. (d.planet_class or "pc_continental"):gsub("^pc_", "") .. ".dds"
            local sw, sh = ctx.texture_size(sky)
            if tw and sw then
                local cw, ch = tw * 0.714 * s, th * 0.714 * s
                b:texture("/preview/sky", sky, px + 4 + rw - cw, py + 4 - 23 * s, cw, ch)
            end
            if tw then
                local cw, ch = tw * 0.714 * s, th * 0.714 * s
                b:texture("/preview/city", city, px + 4 + rw - cw, py + 4 - 23 * s, cw, ch)
            end
            local room = "gfx/portraits/city_sets/" .. ((d.room and d.room ~= "") and d.room or "default_room") .. ".dds"
            if ctx.texture_size(room) then
                b:texture("/preview/room", room, px + 4, py + 4, rw, rh)
            end
            -- the ruler in the room (CPortraitObject::SetEmpireDesign)
            portraits.put(ctx.game_dir, b.items, portraits.ruler(ctx.game_dir, d),
                portraits.element(ctx.game_dir, FILE, "species_preview", { "portrait_window", "portrait" }),
                { x = px, y = py, w = 771, h = 285 }, nil, "/preview/ruler")
        end
        b.items[#b.items + 1] = { kind = "sprite", path = "/clip", sprite = "", texture = "", sprite_kind = "clip",
            frame = 1, frames = 1, x = 0, y = 0, w = 0, h = 0 }
    end
    -- the lower part (the empire selection's: CSpeciesPreviewWindow::SetDesign): the government
    -- type, its authority, the species' name and class
    local GE, SW = P .. "/government_and_ethics", P .. "/species_window"
    if d and not opts.hide_lower then
        local gov = d.government
        if not gov or gov == "" then
            local ok, g = pcall(rules.government, R, d)
            gov = ok and g or nil
        end
        o.text[GE .. "/government_type_name"] = gov and loc(ctx, gov) or ""
        if d.authority then
            o.text[GE .. "/government_authority_name"] = loc(ctx, d.authority)
            o.textures[GE .. "/government_authority_icon"] = C.icon_file(ctx, "common/governments/authorities", d.authority,
                "gfx/interface/icons/governments/authorities/" .. d.authority .. ".dds")
        end
        o.text[SW .. "/species_name"] = text_of(ctx, d.species.name)
        o.text[SW .. "/species_class"] = loc(ctx, d.species.class or "")
    end
    -- the window (its background already drawn)
    o.hide[P .. "/background"] = true
    o.hide[P .. "/species_window/portrait/portrait"] = true
    -- the ship's render target (drawn below at its size) and the bioships' warning (a bioship
    -- culture's [I: by its name])
    o.hide[P .. "/ship_preview/render_target"] = true
    if not (d and (d.graphical_culture or ""):find("bio", 1, true)) then
        o.hide[P .. "/ship_preview/bioship_warning"] = true
    end
    local n_window = #b.items
    local r = b:add(FILE, "species_preview", o)
    -- its lists: the civics, the ethics (species_preview_civic / _ethic), the species' traits
    -- (species_preview_trait), each entry under the one before
    if d and not opts.hide_lower then
        local function list(path, window, entries)
            local lr = r.rects[path]
            if not lr then
                return
            end
            local y = lr.y
            for i, e in ipairs(entries) do
                local E_ = path .. "/" .. i .. "/" .. window
                local er = b:add(FILE, window, {
                    prefix = path .. "/" .. i, parent = { x = lr.x, y = y, w = lr.w, h = 33 },
                    text = { [E_ .. "/name"] = e.name }, textures = { [E_ .. "/icon"] = e.texture },
                    sprites = { [E_ .. "/icon"] = e.sprite },
                    -- a civic's icon file at the entry's sprite's size (GFX_government_authority, 29) [I]
                    sizes = e.size and { [E_ .. "/icon"] = e.size } or nil,
                })
                local rr = er.rects and er.rects["/" .. window] or er.rects and er.rects[path .. "/" .. i .. "/" .. window]
                y = y + ((rr and rr.h) or 33)
            end
        end
        local civics = {}
        for _, k in ipairs(d.civics or {}) do
            civics[#civics + 1] = { name = loc(ctx, k), size = { 29, 29 }, texture = C.icon_file(ctx, "common/governments/civics", k,
                "gfx/interface/icons/governments/civics/" .. k .. ".dds") }
        end
        list(GE .. "/civics", "species_preview_civic", civics)
        local ethics = {}
        for _, k in ipairs(d.ethics or {}) do
            local sprite = "GFX_" .. k
            if ctx.db and ctx.db.sprites and not ctx.db.sprites[sprite] then
                sprite = "GFX_" .. k:gsub("_fanatic", "")
            end
            ethics[#ethics + 1] = { name = loc(ctx, k), sprite = sprite }
        end
        list(GE .. "/ethics", "species_preview_ethic", ethics)
        local traits = {}
        for _, k in ipairs(d.species.traits or {}) do
            traits[#traits + 1] = { name = loc(ctx, k), texture = C.icon_file(ctx, "common/traits", k,
                "gfx/interface/icons/traits/" .. k .. ".dds") }
        end
        list(SW .. "/traits", "species_preview_trait", traits)
    end
    -- the species' portrait (species_window/portrait/portrait), under its frame
    if d and not opts.hide_lower then
        local at
        for i = n_window + 1, #b.items do
            if not at and (b.items[i].path or ""):find(SW .. "/species_frame", 1, true) == 1 then
                at = i
            end
        end
        portraits.put(ctx.game_dir, b.items, portraits.species(ctx.game_dir, d),
            portraits.element(ctx.game_dir, FILE, "species_preview", { "species_window", "portrait", "portrait" }),
            r.rects[SW .. "/portrait"], at, "/preview/species")
    end
    -- the home world (CSpeciesPreviewWindow::CreateHomeworldPreview: the planet class's entity, one
    -- of its variants [I: the game draws one at random], in 3d_icon) and the ship (the country's
    -- latest design of ship class 3 (GetLatestShipDesignOfClass(3, 2) [I: the science ship, by the
    -- game's frame: humanoid_01's]): its culture's science ship, in ship_preview/render_target)
    if d then
        local hw = r.rects[P .. "/home_world/3d_icon"]
        local ent = hw and preview.planet_entity(ctx.game_dir, d.planet_class or "pc_continental")
        if ent then
            b.items[#b.items + 1] = { kind = "sprite", path = "/preview/model|planet|" .. ent, sprite = "", texture = "",
                sprite_kind = "inset", frame = 1, frames = 1, x = hw.x, y = hw.y, w = hw.w, h = hw.h }
        end
        local sp = not opts.hide_lower and r.rects[P .. "/ship_preview"]
        if sp then
            -- (render_target at (7, 8), its image at its size, 396 x 160: the button's sprite is
            -- drawn at its texture's size here, hidden)
            local sr = { x = sp.x + 7, y = sp.y + 8, w = 396, h = 160 }
            b:texture("/preview/ship_bg", "gfx/interface/ship_designer/ship_design_entry_bg.dds", sr.x, sr.y, sr.w, sr.h)
            local cols = table.concat((d.empire_flag or {}).colors or {}, ",")
            b.items[#b.items + 1] = { kind = "sprite", path = "/preview/model|ship|" .. (d.graphical_culture or "mammalian_01")
                .. "|science|DEFAULT_SCIENCESHIP_SECTION|mid|" .. cols,
                sprite = "", texture = "", sprite_kind = "inset", frame = 1, frames = 1, x = sr.x, y = sr.y, w = sr.w, h = sr.h }
        end
    end
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
