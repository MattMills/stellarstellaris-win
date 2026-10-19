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
local portrait_sprites -- (below)

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
-- selectors = { KEY = def } (gfx/portraits/asset_selectors), character / character_large =
-- { w, h, scale, close_up, x, y } (the character render targets), room / character_without_room
-- = { w, h, cx, cy, cs } (the room's render target, the character's place and scale in it,
-- `orientation = lower_left`) }
function portraits.db(game_dir)
    if db then
        return db
    end
    db = {
        portraits = {}, groups = {}, selectors = {},
        character = { w = 575, h = 380, scale = 24, close_up = 2, x = 0, y = -20 },
        character_large = { w = 575, h = 500, scale = 12, close_up = 2, x = 0, y = -20 },
        room = { w = 952, h = 340, cx = 75, cy = 0, cs = 1 },
        character_without_room = { w = 952, h = 340, cx = 75, cy = 0, cs = 1 },
    }
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
                elseif k == "character" or k == "character_large" then
                    local c = db[k]
                    local size = xy(field(e.value, "size"))
                    local ent = field(e.value, "entity")
                    if size then c.w, c.h = size[1], size[2] end
                    if type(ent) == "table" then
                        c.scale = tonumber(field(ent, "scale")) or c.scale
                        c.close_up = tonumber(field(ent, "default_close_up_scale")) or c.close_up
                        local pos = xy(field(ent, "position"))
                        if pos then c.x, c.y = pos[1], pos[2] end
                    end
                elseif k == "room" or k == "character_without_room" then
                    local r = db[k]
                    local size = xy(field(e.value, "size"))
                    local ch = field(e.value, "character")
                    if size then r.w, r.h = size[1], size[2] end
                    if type(ch) == "table" then
                        local pos = xy(field(ch, "position"))
                        if pos then r.cx, r.cy = pos[1], pos[2] end
                        r.cs = tonumber(field(ch, "scale")) or r.cs
                    end
                end
            end
        end
    end
    local sel = RUST and RUST.list_files and RUST.list_files(game_dir, "gfx/portraits/asset_selectors", "txt") or {}
    table.sort(sel)
    for _, f in ipairs(sel) do
        for _, e in ipairs(source.parse(game_dir, f) or {}) do
            if e.op and e.key and e.value.text == nil then
                db.selectors[e.key.text] = e.value
            end
        end
    end
    return db
end

-- ---------------------------------------------------------------------------------------------
-- the asset selectors (the clothes' and the hair's textures: clothes_selector,
-- attachment_selector): `KEY = { default = "x.dds" game_setup = { ... } species = { ... } pop =
-- { ... } leader = { "x.dds" = { trigger } ... } ruler = { ... } }`

-- the distinct texture files a selector names, in its order (the creator's options: the ruler's
-- `clothes` / `attachment` index; creator_rules.selector_options counts the same) [I]
local function selector_textures(sel)
    local seen, out = {}, {}
    local function add(s)
        if s and s:find("%.dds") then
            s = unquote(s)
            if not seen[s] then
                seen[s] = true
                out[#out + 1] = s
            end
        end
    end
    local function walk(t, depth)
        for _, e in ipairs(type(t) == "table" and t or {}) do
            add(e.text or (e.op and e.key and e.key.text))
            if e.op and type(e.value) == "table" and depth < 5 then
                if e.value.text then
                    add(e.value.text)
                else
                    walk(e.value, depth + 1)
                end
            end
        end
    end
    walk(sel, 0)
    return out
end

-- the triggers a selector's entry can name that are evaluated here (the leader's class and gender,
-- always, AND / OR / NOT / NOR of them); any other: false [I]
local function holds(t, ctx)
    for _, e in ipairs(type(t) == "table" and t or {}) do
        if e.op and e.key then
            local k, v = e.key.text, e.value
            local ok
            if k == "leader_class" then
                ok = unquote(v.text) == ctx.class
            elseif k == "gender" then
                ok = unquote(v.text) == ctx.gender
            elseif k == "always" then
                ok = v.text == "yes"
            elseif k == "AND" then
                ok = holds(v, ctx)
            elseif k == "OR" or k == "NOR" then
                ok = false
                for _, x in ipairs(v.text == nil and v or {}) do
                    if x.op and holds({ x }, ctx) then ok = true end
                end
                if k == "NOR" then ok = not ok end
            elseif k == "NOT" then
                ok = not holds(v, ctx)
            else
                ok = false
            end
            if not ok then
                return false
            end
        end
    end
    return true
end

-- a selector's texture: with an index (a design's ruler), its index-th texture; else in the scope's
-- section the first `"x.dds" = { trigger }` that holds, the section's default, the selector's
-- default (a section's `random` lists: their first entry [I])
local function selector_texture(game_dir, key, scope, ctx, index)
    local sel = key and key ~= "no_texture" and portraits.db(game_dir).selectors[key]
    if not sel then
        return ""
    end
    if index then
        local list = selector_textures(sel)
        return list[index + 1] or list[1] or ""
    end
    local section = field(sel, scope)
    local default
    for _, e in ipairs(type(section) == "table" and section or {}) do
        if e.op and e.key then
            local k = e.key.text
            if k == "default" and e.value.text then
                default = default or unquote(e.value.text)
            elseif k:find("%.dds") and e.value.text == nil and holds(e.value, ctx) then
                return unquote(k)
            elseif k == "random" and e.value.text == nil then
                default = default or texts(field(e.value, "list"))[1]
            end
        end
    end
    return default or field(sel, "default") or ""
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

-- a portrait definition's parts: { key, entity, texture, clothes, hair, def } (texture: the
-- index-th character texture; clothes, hair: the selectors' for the scope)
local function portrait_of(game_dir, key, tex_index, scope, ctx, clothes_index, hair_index)
    local def = key and portraits.db(game_dir).portraits[key]
    if type(def) ~= "table" then
        return nil
    end
    local entity = field(def, "entity")
    if not entity then
        return nil
    end
    -- (the textures: plain names, or `tied_texture = { texture = "x.dds" evolution_variants }`)
    local tex = texts(field(def, "character_textures"))
    for _, e in ipairs(type(field(def, "character_textures")) == "table" and field(def, "character_textures") or {}) do
        if e.op and e.key and e.value.text == nil then
            local t = field(e.value, "texture")
            if t then
                tex[#tex + 1] = t
            end
        end
    end
    return {
        key = key, entity = entity, def = def,
        texture = #tex > 0 and tex[(tex_index or 0) % #tex + 1] or "",
        clothes = selector_texture(game_dir, field(def, "clothes_selector"), scope, ctx, clothes_index),
        hair = selector_texture(game_dir, field(def, "attachment_selector"), scope, ctx, hair_index),
    }
end

-- portraits.leader(game_dir, l) -> a portrait for a leader { id, portrait, gender, class }: its
-- portrait (a group: one of the group's leader portraits for the gender, by the leader's id [I],
-- else its default), the character texture by the leader's id [I: the game draws it from the
-- scope's random, CPortraitObject::GetRandomCharacterVariationIndex], the selectors' `leader`
-- textures for its class (the ruler's: their `ruler` section)
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
    return portrait_of(game_dir, key, id, l.ruler and "ruler" or "leader", { class = l.class, gender = l.gender })
end

-- a group's game_setup portraits for the ruler's gender (creator_rules.portrait_options' list)
local function setup_list(group, gender)
    local out = {}
    for _, add in ipairs(type(field(group, "game_setup")) == "table" and field(group, "game_setup") or {}) do
        if add.op and add.key and add.key.text == "add" and add.value.text == nil then
            local trig = field(add.value, "trigger")
            local ok = true
            local ruler = type(trig) == "table" and field(trig, "ruler")
            if type(ruler) == "table" then
                ok = false
                local function scan(t)
                    for _, e in ipairs(t) do
                        if e.op and e.key and e.key.text == "gender" and unquote(e.value.text) == gender then
                            ok = true
                        elseif e.op and e.value.text == nil then
                            scan(e.value)
                        end
                    end
                end
                scan(ruler)
            end
            if ok then
                for _, p in ipairs(texts(field(add.value, "portraits"))) do
                    out[#out + 1] = p
                end
            end
        end
    end
    return out
end

-- portraits.ruler(game_dir, design) -> the portrait of an empire design's ruler (render.creator_rules'
-- design: ruler = { portrait, gender, texture, attachment, clothes, phenotype }, species = {
-- portrait }): the ruler's portrait (a group: its game_setup portraits for the gender, the
-- phenotype-th), its texture, clothes and hair by the design's indices (CPortraitObject::
-- SetEmpireDesign) [I: the indices over the selectors' textures in their order]
function portraits.ruler(game_dir, design)
    local r = design and design.ruler or {}
    local key = r.portrait or (design and design.species and design.species.portrait)
    local group = key and portraits.db(game_dir).groups[key]
    if group then
        local list = setup_list(group, r.gender or "female")
        key = list[(r.phenotype or 0) + 1] or list[1] or field(group, "default")
    end
    return portrait_of(game_dir, key, r.texture, "game_setup", { class = r.leader_class, gender = r.gender },
        tonumber(r.clothes) or 0, tonumber(r.attachment) or 0)
end

-- portraits.species(game_dir, design) -> the portrait of a design's species (the preview's species
-- panel): its portrait (a group: its `species` section's portraits for the species' gender, the
-- first [I], else its default; a species of no gender (`not_set`) as a male one: the game's frames
-- show Human's male portraits [I: the game's choice among them not traced]), the selectors'
-- `species` textures; with look = { clothes, attachment } (the creator's portrait grid: the design
-- ruler's indices, as the game's frame shows: clothes 4 of a new design is new_human's
-- general_01, mammalian_normal_outfit_admiral for humanoid_hp_07, the massive admiral for
-- humanoid_hp_08 and _12 [V]) those indices' textures of the selectors instead
function portraits.species(game_dir, design, look)
    local sp = design and design.species or {}
    local gender = (sp.gender == "female" or sp.gender == "male") and sp.gender or "male"
    local key = sp.portrait
    local group = key and portraits.db(game_dir).groups[key]
    if group then
        local section = field(group, "species")
        local list = {}
        for _, e in ipairs(type(section) == "table" and section or {}) do
            if e.op and e.key and e.key.text == "add" and e.value.text == nil then
                -- (`NOT = { species = { species_gender = X } }`: not for the other gender)
                local trig = field(e.value, "trigger")
                local excluded
                local function scan(t, neg)
                    for _, x in ipairs(type(t) == "table" and t or {}) do
                        if x.op and x.key and x.key.text == "species_gender" then
                            if neg and unquote(x.value.text) == gender then excluded = true end
                        elseif x.op and x.value.text == nil then
                            scan(x.value, neg or x.key.text == "NOT")
                        end
                    end
                end
                scan(trig, false)
                if not excluded then
                    for _, p in ipairs(texts(field(e.value, "portraits"))) do
                        list[#list + 1] = p
                    end
                end
            end
        end
        key = list[1] or field(group, "default")
    end
    local p = portrait_of(game_dir, key, 0, "species", { gender = gender },
        look and tonumber(look.clothes), look and tonumber(look.attachment))
    if os.getenv and os.getenv("STELLAR_PORTRAIT_DEBUG") and p then
        io.stderr:write("portraits: species " .. tostring(sp.portrait) .. " -> " .. tostring(key) .. " clothes " .. tostring(p.clothes) .. " hair " .. tostring(p.hair) .. "\n")
    end
    return p
end

-- the close-up's default scale and offset: measured on the game's frame of the creator's portrait
-- grid (the human portraits' heads, GFX_portrait_character_close_up at 0.36) [I: the game's
-- default_close_up_scale = 2 is not applied as a plain factor; how it is, not traced]
local CLOSE_UP_SCALE, CLOSE_UP_OFFSET = 1.1, { 0, 50 }

-- the framing of a mode: the scale over the character layout's and the position offset (render
-- target pixels, + y down): `close_up` the portrait's custom_close_up_*, else the defaults above;
-- `mid_close_up` the portrait's custom_mid_close_up_*, else 1.5 and { 0 220 } (the head kept in the
-- target: by the human portraits) [I]
local function framing(d, p, mode)
    local def = p.def
    if mode == "close_up" then
        -- (a portrait's own values as they are: the game's frame of the creator's grid shows the
        -- psionic portraits' 1.8 and { 30 200 } that way [I])
        local off = xy(field(def, "custom_close_up_position_offset"))
        local scale = tonumber(field(def, "custom_close_up_scale"))
        return scale or CLOSE_UP_SCALE, off or CLOSE_UP_OFFSET
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
    if not p or not icon then
        return nil
    end
    local d = portraits.db(game_dir)
    local k = icon.scale or 1
    -- the render target: a room's (room, character_without_room: the character's target placed in
    -- it, `orientation = lower_left`), else the character's (character, character_large)
    local room = (icon.type == "room" or icon.type == "character_without_room") and d[icon.type] or nil
    local c = icon.type == "character_large" and d.character_large or d.character
    local rt_w, rt_h = room and room.w or c.w, room and room.h or c.h
    -- the character's target's top left in the render target, and its scale there
    local ox, oy, cs = 0, 0, 1
    if room then
        cs = room.cs or 1
        ox, oy = room.cx, room.h - c.h * cs - room.cy
    end
    local mult, off = framing(d, p, mode)
    -- the entity's anchor in the character's target (centre bottom, the layout's position and the
    -- framing's offset), on the screen
    local ax = icon.x + k * (ox + cs * (c.w / 2 + c.x + off[1]))
    -- (the layout's position y: up from the bottom, -20 below it: the game's frame of the
    -- empire selection's room [I])
    local ay = icon.y + k * (oy + cs * (c.h - c.y + off[2]))
    -- the render target's rectangle on the screen, cut to the clip
    clip = clip or { x = icon.x, y = icon.y, w = k * rt_w, h = k * rt_h }
    local x0, y0 = math.max(icon.x, clip.x), math.max(icon.y, clip.y)
    local x1, y1 = math.min(icon.x + k * rt_w, clip.x + clip.w), math.min(icon.y + k * rt_h, clip.y + clip.h)
    if x1 <= x0 or y1 <= y0 then
        return nil
    end
    local ppu = c.scale * mult * k * cs
    local path = string.format("/portrait|%s|%s|%.4f|%.2f|%.2f|%s|%s", p.entity, p.texture or "", ppu, ax - x0, ay - y0,
        p.clothes or "", p.hair or "")
    return { kind = "sprite", path = (icon.prefix or "") .. path, sprite = "", texture = "", sprite_kind = "inset", frame = 1, frames = 1,
        x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
end

-- portraits.element(game_dir, file, window, names) -> { x, y, scale, type, mode, parent, clip } |
-- nil: the element at the end of the name path names (from window down: { "portrait_container",
-- "portrait" }) of a .gui file: its position in its parent container, its scale, its portrait
-- sprite's type and framing, the parent's name and whether it clips (`clipping = yes`)
local elements = {}
function portraits.element(game_dir, file, window, names)
    local key = file .. "|" .. window .. "|" .. table.concat(names, "/")
    if elements[key] ~= nil then
        return elements[key] or nil
    end
    local function find(block, name)
        for _, e in ipairs(type(block) == "table" and block or {}) do
            if e.op and e.key and e.value.text == nil then
                if field(e.value, "name") == name then
                    return e.value
                end
                local f = find(e.value, name)
                if f then
                    return f
                end
            end
        end
        return nil
    end
    local node = find(source.parse(game_dir, file) or {}, window)
    local parent
    for i, n in ipairs(names) do
        if not node then
            break
        end
        if i == #names then
            parent = node
        end
        node = find(node, n)
    end
    local found
    if node then
        local pos = xy(field(node, "position")) or { 0, 0 }
        local sprite = field(node, "quadTextureSprite") or field(node, "spriteType") or ""
        local sd = portrait_sprites(game_dir)[sprite]
        found = {
            x = pos[1], y = pos[2], scale = tonumber(field(node, "scale")) or 1,
            type = sd and sd.type or "character", mode = sd and sd.mode or nil,
            parent = parent and field(parent, "name"), clip = parent and field(parent, "clipping") == "yes",
        }
    end
    elements[key] = found or false
    return found
end

-- portraits.put(game_dir, items, p, el, parent_rect, at, prefix, cut) -> whether an inset was put:
-- the portrait p at the element el (portraits.element) of a window laid out with its parent at
-- parent_rect (cut to it when it clips, and to cut: a scrolled list's box), inserted at items'
-- index at (else at the end); prefix: before the inset's path (its marker after it)
function portraits.put(game_dir, items, p, el, parent_rect, at, prefix, cut)
    if not p or not el or not parent_rect then
        return false
    end
    local icon = { x = parent_rect.x + el.x, y = parent_rect.y + el.y, scale = el.scale, type = el.type, prefix = prefix }
    local clip = el.clip and parent_rect or nil
    if cut then
        local a = clip or { x = icon.x, y = icon.y, w = 1e6, h = 1e6 }
        local x0, y0 = math.max(a.x, cut.x), math.max(a.y, cut.y)
        local x1, y1 = math.min(a.x + a.w, cut.x + cut.w), math.min(a.y + a.h, cut.y + cut.h)
        clip = { x = x0, y = y0, w = math.max(0, x1 - x0), h = math.max(0, y1 - y0) }
    end
    local item = portraits.inset(game_dir, p, icon, clip, el.mode)
    if not item then
        return false
    end
    table.insert(items, at or (#items + 1), item)
    return true
end

-- the portrait sprites of interface/*.gfx (`portraitType = { name type close_up mid_close_up
-- masking_texture }`): name -> { type, mode }, read once
local sprites
function portrait_sprites(game_dir)
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
                        cut = cuts[clip], mode = sd and sd.mode or nil, type = sd and sd.type or "character",
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
    local at_icon = p and { x = clip.x + icon.x, y = clip.y + icon.y, scale = icon.scale, type = icon.type }
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
