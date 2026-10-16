-- render/portraits.lua : a leader's portrait as an inset item of a view's layout (portraits.rs
-- fills it with the portrait entity's meshes; docs/windows/portraits.md).
--
--   portraits.leader(game_dir, leader) -> { entity, texture, close_up } | nil
--   portraits.inset(game_dir, p, icon, clip, mode) -> an "inset" item (nil without a portrait)
--
-- The portraits (gfx/portraits/portraits/*.txt): `portraits = { KEY = { entity character_textures
-- = { ... } clothes_selector attachment_selector custom_close_up_position_offset ... } }` and
-- `portrait_groups = { KEY = { default leader = { add = { trigger portraits = { ... } } } ... } }`;
-- the render target's layout: `character = { size = { 575 380 } entity = { orientation =
-- center_down position = { 0 -20 } scale = 24 default_close_up_scale = 2 } }`.

local source = require("stellar.script.source")

local portraits = {}

local function unquote(s)
    return type(s) == "string" and (s:gsub('^"(.*)"$', "%1")) or s
end

local function field(block, key)
    for _, e in ipairs(type(block) == "table" and block or {}) do
        if e.op and e.key and e.key.text == key then
            return e.value.text ~= nil and unquote(e.value.text) or e.value
        end
    end
    return nil
end

local function texts(block)
    local out = {}
    for _, e in ipairs(type(block) == "table" and block or {}) do
        if e.text then
            out[#out + 1] = unquote(e.text)
        end
    end
    return out
end

local function xy(block)
    if type(block) ~= "table" then
        return nil
    end
    return { tonumber(field(block, "x")) or 0, tonumber(field(block, "y")) or 0 }
end

local db
-- the portrait database, read once: { portraits = { KEY = def }, groups = { KEY = def },
-- character = { w, h, scale, close_up, x, y } }
function portraits.db(game_dir)
    if db then
        return db
    end
    db = { portraits = {}, groups = {}, character = { w = 575, h = 380, scale = 24, close_up = 2, x = 0, y = -20 } }
    local files = RUST and RUST.list_files and RUST.list_files(game_dir, "gfx/portraits/portraits", "txt") or {}
    table.sort(files)
    for _, f in ipairs(files) do
        for _, e in ipairs(source.parse(game_dir, f) or {}) do
            if e.op and e.key and e.value.text == nil then
                local k = e.key.text
                if k == "portraits" or k == "portrait_groups" then
                    local into = k == "portraits" and db.portraits or db.groups
                    for _, p in ipairs(e.value) do
                        if p.op and p.key and p.value.text == nil then
                            into[p.key.text] = p.value
                        end
                    end
                elseif k == "character" then
                    local c = db.character
                    local size = xy(field(e.value, "size"))
                    local ent = field(e.value, "entity")
                    if size then c.w, c.h = size[1], size[2] end
                    if type(ent) == "table" then
                        c.scale = tonumber(field(ent, "scale")) or c.scale
                        c.close_up = tonumber(field(ent, "default_close_up_scale")) or c.close_up
                        local pos = xy(field(ent, "position"))
                        if pos then c.x, c.y = pos[1], pos[2] end
                    end
                end
            end
        end
    end
    return db
end

-- the portraits a group's `leader` section adds for the gender (its `add` blocks whose trigger names
-- the gender, or names none) [I: the triggers are not evaluated, the gender read from them]
local function group_list(group, gender)
    local section = field(group, "leader")
    if type(section) ~= "table" then
        section = field(group, "species")
    end
    local out = {}
    for _, e in ipairs(type(section) == "table" and section or {}) do
        if e.op and e.key and (e.key.text == "add" or e.key.text == "set") and e.value.text == nil then
            local trig = field(e.value, "trigger")
            local genders = {}
            local function scan(b)
                for _, x in ipairs(type(b) == "table" and b or {}) do
                    if x.op and x.key and x.key.text == "gender" and x.value.text then
                        genders[unquote(x.value.text)] = true
                    elseif x.op and x.value and x.value.text == nil then
                        scan(x.value)
                    end
                end
            end
            scan(trig)
            if next(genders) == nil or genders[gender or "male"] or genders.indeterminable and gender == nil then
                if e.key.text == "set" then
                    out = {}
                end
                for _, p in ipairs(texts(field(e.value, "portraits"))) do
                    out[#out + 1] = p
                end
            end
        end
    end
    return out
end

-- portraits.leader(game_dir, l) -> { key, entity, texture, def } for a leader { id, portrait,
-- gender }: its portrait (a group: one of the group's leader portraits for the gender, by the
-- leader's id [I], else its default), the character texture by the leader's id [I: the game draws
-- it from the scope's random, CPortraitObject::GetRandomCharacterVariationIndex]
function portraits.leader(game_dir, l)
    local d = portraits.db(game_dir)
    local key = l and l.portrait
    if not key or key == "" then
        return nil
    end
    local id = math.floor(tonumber(l.id) or 0)
    local group = d.groups[key]
    if group then
        local list = group_list(group, l.gender)
        key = #list > 0 and list[id % #list + 1] or field(group, "default")
    end
    local def = key and d.portraits[key]
    if type(def) ~= "table" then
        return nil
    end
    local entity = field(def, "entity")
    if not entity then
        return nil
    end
    local tex = texts(field(def, "character_textures"))
    return {
        key = key, entity = entity, texture = #tex > 0 and tex[id % #tex + 1] or "", def = def,
    }
end

-- the framing of a mode: the scale over the character layout's and the position offset (render
-- target pixels): `close_up` default_close_up_scale and the portrait's custom_close_up_*, else
-- the offset the game's files suggest (01_portraits_mammalian's commented { -25 300 }) [I];
-- `mid_close_up` the portrait's custom_mid_close_up_*, else 1.5 and { 0 220 } (the head kept in the
-- target: by the human portraits) [I]
local function framing(d, p, mode)
    local def = p.def
    if mode == "close_up" then
        local off = xy(field(def, "custom_close_up_position_offset")) or { -25, 300 }
        return tonumber(field(def, "custom_close_up_scale")) or d.character.close_up, off
    elseif mode == "mid_close_up" then
        local off = xy(field(def, "custom_mid_close_up_position_offset")) or { 0, 220 }
        return tonumber(field(def, "custom_mid_close_up_scale")) or 1.5, off
    end
    return 1, { 0, 0 }
end

-- portraits.inset(game_dir, p, icon, clip, mode) -> an inset item: the portrait p (portraits.leader)
-- in the render target the card's portrait icon shows (icon = { x, y, scale }: the icon's place and
-- scale), cut to clip (the clipping container's rectangle), in a mode (nil, "close_up",
-- "mid_close_up": the portrait sprite's)
function portraits.inset(game_dir, p, icon, clip, mode)
    if not p or not icon or not clip then
        return nil
    end
    local d = portraits.db(game_dir)
    local c = d.character
    local k = icon.scale or 1
    local mult, off = framing(d, p, mode)
    -- the entity's anchor in the render target (centre bottom, the layout's position and the
    -- framing's offset), on the screen
    local ax = icon.x + k * (c.w / 2 + c.x + off[1])
    local ay = icon.y + k * (c.h + c.y + off[2])
    -- the render target's rectangle on the screen, cut to the clip
    local x0, y0 = math.max(icon.x, clip.x), math.max(icon.y, clip.y)
    local x1, y1 = math.min(icon.x + k * c.w, clip.x + clip.w), math.min(icon.y + k * c.h, clip.y + clip.h)
    if x1 <= x0 or y1 <= y0 then
        return nil
    end
    local ppu = c.scale * mult * k
    local path = string.format("/portrait|%s|%s|%.4f|%.2f|%.2f", p.entity, p.texture or "", ppu, ax - x0, ay - y0)
    return { kind = "sprite", path = path, sprite = "", texture = "", sprite_kind = "inset", frame = 1, frames = 1,
        x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
end

-- the portrait sprites of interface/*.gfx (`portraitType = { name type close_up mid_close_up
-- masking_texture }`): name -> { type, mode }, read once
local sprites
local function portrait_sprites(game_dir)
    if sprites then
        return sprites
    end
    sprites = {}
    local files = RUST and RUST.list_files and RUST.list_files(game_dir, "interface", "gfx") or {}
    table.sort(files)
    local function scan(block)
        for _, e in ipairs(type(block) == "table" and block or {}) do
            if e.op and e.key and e.value.text == nil then
                if e.key.text == "portraitType" then
                    local name = field(e.value, "name")
                    if name then
                        sprites[name] = {
                            type = field(e.value, "type") or "character",
                            mode = field(e.value, "mid_close_up") == "yes" and "mid_close_up"
                                or (field(e.value, "close_up") == "yes" and "close_up") or nil,
                        }
                    end
                else
                    scan(e.value)
                end
            end
        end
    end
    for _, f in ipairs(files) do
        scan(source.parse(game_dir, f) or {})
    end
    return sprites
end

-- portraits.icon(game_dir, file, window) -> { x, y, scale, mode, clip } | nil: the
-- `character_portrait` icon of a window of a .gui file: its position in the container it is laid
-- out in that is named `..._clipping_mask` (clip: that container's name; the containers between
-- them add their positions [I: upper_left orientations]), its scale, its portrait sprite's
-- framing (its portraitType's close_up = yes -> "close_up", mid_close_up = yes -> "mid_close_up",
-- others the whole character), read once per window
local icons = {}
function portraits.icon(game_dir, file, window)
    local key = file .. "|" .. window
    if icons[key] ~= nil then
        return icons[key] or nil
    end
    local found
    local cuts = {}
    -- inside: in the window; clip: the clipping container's name and (ox, oy) the offset from it
    local function search(block, inside, clip, ox, oy)
        for _, e in ipairs(type(block) == "table" and block or {}) do
            if found then
                return
            end
            if e.op and e.key and e.value.text == nil then
                local name = field(e.value, "name") or ""
                local pos = xy(field(e.value, "position")) or { 0, 0 }
                if inside and clip and e.key.text == "iconType" and name == "character_portrait" then
                    local sprite = field(e.value, "quadTextureSprite") or field(e.value, "spriteType") or ""
                    local sd = portrait_sprites(game_dir)[sprite]
                    found = {
                        x = ox + pos[1], y = oy + pos[2], scale = tonumber(field(e.value, "scale")) or 1, clip = clip,
                        cut = cuts[clip], mode = sd and sd.mode or nil,
                    }
                    return
                end
                if e.key.text == "containerWindowType" then
                    if inside and name:find("clipping_mask", 1, true) then
                        cuts[name] = field(e.value, "clipping") == "yes"
                        search(e.value, true, name, 0, 0)
                    elseif inside and clip then
                        search(e.value, true, clip, ox + pos[1], oy + pos[2])
                    else
                        search(e.value, inside or name == window, clip, ox, oy)
                    end
                else
                    search(e.value, inside, clip, ox, oy)
                end
            end
        end
    end
    search(source.parse(game_dir, file) or {}, false, nil, 0, 0)
    icons[key] = found or false
    return found
end

-- portraits.card(game_dir, items, n0, rects, file, window, leader): the leader's portrait inset
-- for a card laid out from items[n0 + 1] on (rects: its layout's rectangles), put above the
-- clipping container's backgrounds (the class background, the backdrop) and under the rest of
-- the card, as the game's portrait icon is; whether one was put
local card
function portraits.card(...)
    -- (a portrait that fails leaves the card as it is: the error on stderr, once)
    local ok, r = pcall(card, ...)
    if not ok then
        if not portraits.failed then
            portraits.failed = true
            io.stderr:write("render.portraits: " .. tostring(r) .. "\n")
        end
        return false
    end
    return r
end

function card(game_dir, items, n0, rects, file, window, leader)
    local icon = portraits.icon(game_dir, file, window)
    local clip, card_rect
    for path, r in pairs(icon and rects or {}) do
        if path:sub(-#icon.clip - 1) == "/" .. icon.clip then
            clip = r
        elseif path:sub(-#window - 1) == "/" .. window then
            card_rect = r
        end
    end
    local p = icon and clip and portraits.leader(game_dir, leader)
    local at_icon = p and { x = clip.x + icon.x, y = clip.y + icon.y, scale = icon.scale }
    -- what cuts it: the clipping container (`clipping = yes`), within the card (a container of
    -- `width = 100%` too); without clipping the render target's whole rectangle
    local c = portraits.db(game_dir).character
    local cut = p and { x = at_icon.x, y = at_icon.y, w = c.w * icon.scale, h = c.h * icon.scale }
    if p and icon.cut then
        local x0, y0, x1, y1 = clip.x, clip.y, clip.x + clip.w, clip.y + clip.h
        if card_rect then
            x0, y0 = math.max(x0, card_rect.x), math.max(y0, card_rect.y)
            x1, y1 = math.min(x1, card_rect.x + card_rect.w), math.min(y1, card_rect.y + card_rect.h)
        end
        cut = { x = x0, y = y0, w = math.max(0, x1 - x0), h = math.max(0, y1 - y0) }
    end
    local item = p and portraits.inset(game_dir, p, at_icon, cut, icon.mode)
    if not item then
        return false
    end
    local at
    for i = n0 + 1, #items do
        local path = items[i].path or ""
        if path:find("/" .. icon.clip .. "/", 1, true) then
            at = i + 1
        elseif not at and path:find("/leader_container", 1, true) then
            at = i
        end
    end
    table.insert(items, at or (#items + 1), item)
    return true
end

return portraits
