-- render/newgame_widgets.lua : the run-time controls of the new game's screens that render.gui
-- lays out but does not draw (a spinnerType, a scrollbarType, a list's scrollbar), drawn from
-- their .gui definitions the way the Clausewitz GUI places their parts, and the clip items that
-- cut a list's rows to its box.
--
--   local w = require("render.newgame_widgets")
--   w.spinner(ctx, def, rect, text, actions)     -- the two arrow buttons
--   w.slider(ctx, def, rect, fraction, actions)  -- arrows, track, the dragger at `fraction`
--   w.clip(items, rect) / w.unclip(items)
--
-- ctx = { db, texture_size, items, report }: the layout's .gfx database and the item list the
-- parts go into.

local gfx = require("render.gfx")
local get = gfx.get

local w = {}

-- a sprite's frame size (its sheet's frame), or nil
function w.frame_size(ctx, name)
    local s = ctx.db.sprites[name]
    if s and s.sheet and ctx.db.sprites[s.sheet] then
        s = ctx.db.sprites[s.sheet]
    end
    if not s or not s.texture then
        return nil
    end
    if s.size then
        return s.size[1], s.size[2]
    end
    local tw, th = ctx.texture_size(s.texture)
    if not tw then
        return nil
    end
    return tw / math.max(1, s.frames or 1), th
end

-- a sprite item (a button when `action`); returns it
function w.sprite(ctx, path, name, x, y, ww, hh, action, frame)
    local s = ctx.db.sprites[name]
    local fr = frame
    if s and s.sheet and ctx.db.sprites[s.sheet] then
        fr = fr or s.default_frame
        name, s = s.sheet, ctx.db.sprites[s.sheet]
    end
    if not s or not s.texture then
        ctx.report.missing_sprites[#ctx.report.missing_sprites + 1] = tostring(name)
        return nil
    end
    local fw, fh = w.frame_size(ctx, name)
    local item = {
        kind = "sprite", path = path, sprite = name, texture = s.texture, sprite_kind = s.kind,
        frame = fr or 1, frames = s.frames or 1, x = x, y = y, w = ww or fw or 0, h = hh or fh or 0,
        border = s.kind == "corneredTileSpriteType" and s.border or nil,
        button = action and { name = path:match("[^/]*$"), action = action } or nil,
    }
    ctx.items[#ctx.items + 1] = item
    ctx.report.sprites = ctx.report.sprites + 1
    return item
end

-- the clip items: what follows is cut to rect, until w.unclip
function w.clip(items, r)
    items[#items + 1] = {
        kind = "sprite", path = "/clip", sprite = "", texture = "", sprite_kind = "clip",
        frame = 1, frames = 1, x = r.x, y = r.y, w = r.w, h = r.h,
    }
end
function w.unclip(items)
    items[#items + 1] = {
        kind = "sprite", path = "/clip", sprite = "", texture = "", sprite_kind = "clip",
        frame = 1, frames = 1, x = 0, y = 0, w = 0, h = 0,
    }
end

-- a child guiButtonType of a spinner or scrollbar block by name: its sprite
local function part(def, name)
    for _, e in ipairs(def) do
        if e.op and e.key and e.key.text:lower() == "guibuttontype" and type(e.value) == "table" and get(e.value, "name") == name then
            return get(e.value, "quadTextureSprite") or get(e.value, "spriteType"), e.value
        end
    end
    return nil
end

-- the arrows of a horizontal spinner or scrollbar at rect: the left one at its left edge, the
-- right one at its right edge, both centred on its height [I: the frames' arrows]
local function arrows(ctx, def, r, path, left_action, right_action)
    local lname = part(def, get(def, "leftbutton") or "")
    local rname = part(def, get(def, "rightbutton") or "")
    local lw, lh = w.frame_size(ctx, lname or "")
    local rw, rh = w.frame_size(ctx, rname or "")
    local out = {}
    if lname and lw then
        out.left = w.sprite(ctx, path .. "/left", lname, r.x, r.y + math.floor((r.h - lh) / 2), lw, lh, left_action)
    end
    if rname and rw then
        out.right = w.sprite(ctx, path .. "/right", rname, r.x + r.w - rw, r.y + math.floor((r.h - rh) / 2), rw, rh, right_action)
    end
    return out, lw or 0, rw or 0
end

-- a spinnerType at rect r (its .gui block def): its arrows
function w.spinner(ctx, def, r, path, actions)
    return arrows(ctx, def, r, path, actions.left, actions.right)
end

-- a horizontal scrollbarType at rect r: arrows, the track between them, the slider at
-- `fraction` (0..1) of the track's travel; the track takes clicks (actions.track)
function w.slider(ctx, def, r, path, fraction, actions)
    local parts, lw, rw = arrows(ctx, def, r, path, actions.left, actions.right)
    local track = part(def, get(def, "track") or "")
    local slider = part(def, get(def, "slider") or "")
    local tx, tw = r.x + lw, r.w - lw - rw
    local _, th = w.frame_size(ctx, track or "")
    if track and th then
        parts.track = w.sprite(ctx, path .. "/track", track, tx, r.y + math.floor((r.h - th) / 2), tw, th, actions.track)
    end
    local sw, sh = w.frame_size(ctx, slider or "")
    if slider and sw then
        local x = tx + math.floor((tw - sw) * math.max(0, math.min(1, fraction)) + 0.5)
        parts.slider = w.sprite(ctx, path .. "/slider", slider, x, r.y + math.floor((r.h - sh) / 2), sw, sh, nil)
    end
    parts.track_x, parts.track_w = tx, tw
    return parts
end

return w
