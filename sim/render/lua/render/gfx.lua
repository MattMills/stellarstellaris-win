-- render/gfx.lua : the game's sprite and font definitions, from interface/*.gfx and gfx/*.gfx
-- (pdxscript, read in place with stellar.script.source).
--
--   local gfx = require("render.gfx")
--   local db = gfx.load(game_dir)
--   db.sprites["GFX_resource_energy"]  -- { kind, texture, frames, border = { x, y }, file }
--   db.fonts["cg_16b"]                 -- { file = "gfx/fonts/cg_16b", color = 0xffffffff }
--
-- A .gfx file is `spriteTypes = { spriteType = { name = "GFX_x" texturefile = "gfx/..." } ... }`
-- (also corneredTileSpriteType with borderSize, frameAnimatedSpriteType, progressbarType, ...)
-- and `bitmapfonts = { bitmapfont = { name = "cg_16b" fontfiles = { "gfx/fonts/cg_16b" } } }`.
-- Keys are matched in any case (the files write both `spriteType` and `SpriteType`); a later
-- definition of a name replaces an earlier one, files in name order, interface/ after gfx/.

local source = require("stellar.script.source")

local gfx = {}

-- the first `key = value` of a block, the key in any case: a token's text, or a block
local function get(block, key)
    if type(block) ~= "table" then
        return nil
    end
    key = key:lower()
    for _, e in ipairs(block) do
        if e.op and e.key and e.key.text:lower() == key then
            return e.value.text or e.value
        end
    end
    return nil
end
gfx.get = get

local function unquote(s)
    return type(s) == "string" and s:gsub('^"(.*)"$', "%1") or s
end

-- the sprite kinds and what is read of them
local SPRITE_KINDS = {
    spritetype = "spriteType",
    corneredtilespritetype = "corneredTileSpriteType",
    frameanimatedspritetype = "frameAnimatedSpriteType",
    textspritetype = "textSpriteType",
    flagspritetype = "flagSpriteType",
    progressbartype = "progressbarType",
}

local function read_sprite(kind, b, file)
    local name = get(b, "name")
    if not name then
        return nil
    end
    local border = get(b, "borderSize")
    local texture = get(b, "texturefile") or get(b, "textureFile1")
    local function xy(k, a, c)
        local v = get(b, k)
        if type(v) ~= "table" then
            return nil
        end
        return { tonumber(get(v, a)) or 0, tonumber(get(v, c)) or 0 }
    end
    local s = {
        kind = kind,
        texture = texture and unquote(texture):gsub("\\", "/"),
        frames = tonumber(get(b, "noOfFrames")) or 1,
        border = type(border) == "table" and { x = tonumber(get(border, "x")) or 0, y = tonumber(get(border, "y")) or 0 } or nil,
        file = file,
    }
    -- a progress bar's size (progressbarType `size`: its full texture drawn at it), its empty
    -- texture and direction (progress.shader: texture one up to the bar's state, two beyond)
    if kind == "progressbarType" then
        s.size = xy("size", "x", "y")
        local t2 = get(b, "textureFile2")
        s.texture2 = t2 and unquote(t2):gsub("\\", "/")
        s.horizontal = get(b, "horizontal") ~= "no"
    end
    -- a sprite that is a frame of another (sprite_sheet_sprite_type, default_frame)
    local sheet = get(b, "sprite_sheet_sprite_type")
    if sheet then
        s.sheet = unquote(sheet)
        s.default_frame = tonumber(get(b, "default_frame")) or 1
    end
    if kind == "flagSpriteType" then
        -- the flag's parts in the frame (flag_sprite.shader's BGPos, BGSize, SymbolPos,
        -- SymbolSize, MaskOffset, MaskSize), its mask and the emblems' size
        local mask = get(b, "masking_texture")
        s.mask = mask and unquote(mask):gsub("\\", "/")
        s.texture_size = get(b, "texture_size")
        s.bg_position = xy("bg_position", "x", "y")
        s.bg_size = xy("bg_size", "width", "height")
        s.symbol_position = xy("symbol_position", "x", "y")
        s.symbol_size = xy("symbol_size", "width", "height")
        s.mask_offset = xy("mask_offset", "x", "y")
        s.mask_size = xy("mask_size", "width", "height")
    end
    return unquote(name), s
end

-- gfx.load(game_dir) -> { sprites, fonts, files, counts }
function gfx.load(game_dir)
    local t0 = RUST.clock()
    local db = { sprites = {}, fonts = {}, textcolors = {}, files = 0, counts = {}, errors = {} }
    local files = {}
    -- gfx/*.gfx and interface/**/*.gfx (its subfolders too, when the renderer can list them)
    local dirs = { "gfx", "interface" }
    for _, d in ipairs(RENDER_SUBDIRS and RENDER_SUBDIRS("interface") or {}) do
        dirs[#dirs + 1] = d
    end
    for _, dir in ipairs(dirs) do
        for _, f in ipairs(source.files(game_dir, dir, "gfx")) do
            files[#files + 1] = f
        end
    end
    for _, f in ipairs(files) do
        local tree, message = source.parse(game_dir, f)
        if not tree then
            db.errors[#db.errors + 1] = message
        else
            db.files = db.files + 1
            for _, top in ipairs(tree) do
                if top.op and type(top.value) == "table" then
                    local section = top.key.text:lower()
                    for _, e in ipairs(top.value) do
                        if e.op and e.key and type(e.value) == "table" then
                            local k = e.key.text:lower()
                            if section == "spritetypes" and SPRITE_KINDS[k] then
                                local name, s = read_sprite(SPRITE_KINDS[k], e.value, f)
                                if name then
                                    db.sprites[name] = s
                                    db.counts[s.kind] = (db.counts[s.kind] or 0) + 1
                                end
                            elseif section == "bitmapfonts" and k == "bitmapfont" then
                                -- the font's files: `fontfiles = { "gfx/fonts/x" }` or `path = "gfx/fonts/x"`
                                local name = unquote(get(e.value, "name"))
                                local ff = get(e.value, "fontfiles")
                                local first = type(ff) == "table" and ff[1] and ff[1].text or get(e.value, "path")
                                if name and type(first) == "string" then
                                    db.fonts[name] = { file = unquote(first), color = get(e.value, "color") }
                                end
                            elseif section == "bitmapfonts" and k == "textcolors" then
                                -- the colours of §X codes: X = { r g b }
                                for _, c in ipairs(e.value) do
                                    if c.op and c.key and type(c.value) == "table" and c.value.text == nil then
                                        local n = {}
                                        for _, t in ipairs(c.value) do
                                            if t.text then
                                                n[#n + 1] = tonumber(t.text)
                                            end
                                        end
                                        if #n >= 3 then
                                            db.textcolors[c.key.text] = { n[1] / 255, n[2] / 255, n[3] / 255 }
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    db.seconds = RUST.clock() - t0
    return db
end

return gfx
