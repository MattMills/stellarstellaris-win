-- render/gui.lua : the game's GUI windows from interface/*.gui (pdxscript), laid out the way the
-- Clausewitz GUI does it, into a flat list of sprites and texts for the renderer.
--
--   local gui = require("render.gui")
--   local items = gui.layout(game_dir, db, "interface/main.gui", "maingui", { width = w, height = h },
--                            { only = { topbar = true, ... }, hide = { ... }, text = { [path] = "..." } })
--
-- An element's rectangle: its parent's top left + the parent's anchor point (orientation) +
-- position - its own anchor point (origo). Sizes may be in % of the parent ("100%%" too). An
-- iconType or buttonType is the size of its sprite's frame times its scale; a window's
-- background is stretched to the window (a corneredTileSpriteType as nine slices). Scripted
-- variables (`@topbar_amount_pos_y = 17`) are the file's. What the game decides at run time (which
-- resource groups an empire shows, the paused or running speed button, texts) comes from `opts`.

local source = require("stellar.script.source")
local gfx = require("render.gfx")
local get = gfx.get

local gui = {}

local ANCHOR = {
    upper_left = { 0, 0 }, upper_right = { 1, 0 }, lower_left = { 0, 1 }, lower_right = { 1, 1 },
    center = { 0.5, 0.5 }, centre = { 0.5, 0.5 }, center_up = { 0.5, 0 }, center_down = { 0.5, 1 },
    center_left = { 0, 0.5 }, center_right = { 1, 0.5 },
}

-- element kinds drawn, and kinds skipped (lists, scrollbars, edit boxes: filled at run time)
local CONTAINERS = { containerwindowtype = true, windowtype = true, dropdownboxtype = true }
local ICONS = { icontype = true, buttontype = true, effectbuttontype = true, guibuttontype = true }
local TEXTS = { instanttextboxtype = true, textboxtype = true }

-- a number field, through the file's scripted variables; percent sizes against `of`
local function number(v, vars, of)
    if v == nil then
        return nil
    end
    if type(v) ~= "string" then
        return nil
    end
    if v:sub(1, 1) == "@" then
        v = vars[v] or vars[v:sub(2)] or v
    end
    local pct = v:match("^(-?[%d%.]+)%%+$")
    if pct then
        return (of or 0) * tonumber(pct) / 100
    end
    return tonumber(v)
end

local function anchor(name)
    return ANCHOR[(name or "upper_left"):lower()] or ANCHOR.upper_left
end

-- gui.layout(game_dir, db, file, window, screen, opts) -> items, report
--   items: { kind = "sprite", path, sprite, texture, frame, frames, x, y, w, h, border = {x,y}|nil,
--            sprite_kind } and { kind = "text", path, font, text, x, y, w, h, format }
--   opts.only: names of the window's children to lay out (all if nil)
--   opts.hide: element paths ("maingui/topbar_static/tb_biomass_group") or names not drawn
--   opts.text: element path -> text
--   opts.texture_size(path) -> w, h (the renderer's: the texture's pixels)
function gui.layout(game_dir, db, file, window_name, screen, opts)
    opts = opts or {}
    local tree, message = source.parse(game_dir, file)
    if not tree then
        error(message)
    end
    local vars = {}
    local window
    local function scan(block)
        for _, e in ipairs(block) do
            if e.op and e.key then
                local k = e.key.text
                if k:sub(1, 1) == "@" and e.value.text then
                    vars[k] = e.value.text
                    vars[k:sub(2)] = e.value.text
                elseif type(e.value) == "table" then
                    local kl = k:lower()
                    if kl == "guitypes" then
                        scan(e.value)
                    elseif CONTAINERS[kl] and get(e.value, "name") == window_name and not window then
                        window = e.value
                    end
                end
            end
        end
    end
    scan(tree)
    if not window then
        error(file .. ": no window " .. window_name)
    end

    local items, report = {}, { sprites = 0, texts = 0, missing_sprites = {}, skipped = {} }

    local function sprite_item(path, name, frame, x, y, w, h, stretch)
        local s = db.sprites[name]
        if not s or not s.texture then
            report.missing_sprites[#report.missing_sprites + 1] = tostring(name)
            return nil
        end
        local tw, th = opts.texture_size(s.texture)
        if not tw then
            report.missing_sprites[#report.missing_sprites + 1] = tostring(name) .. " (" .. s.texture .. ")"
            return nil
        end
        local fw = tw / math.max(1, s.frames)
        if not stretch then
            w, h = w or fw, h or th
        end
        local item = {
            kind = "sprite", path = path, sprite = name, texture = s.texture, sprite_kind = s.kind,
            frame = math.max(1, frame or 1), frames = s.frames, x = x, y = y, w = w or fw, h = h or th,
            border = s.kind == "corneredTileSpriteType" and s.border or nil,
        }
        items[#items + 1] = item
        report.sprites = report.sprites + 1
        return item
    end

    local function hidden(path, name)
        return opts.hide and (opts.hide[path] or opts.hide[name])
    end

    local function element(kind, b, parent, parent_path, depth)
        local name = get(b, "name") or "?"
        local path = parent_path .. "/" .. name
        if hidden(path, name) or (depth == 1 and opts.only and not opts.only[name]) then
            return
        end
        local pos = get(b, "position")
        local px = number(type(pos) == "table" and get(pos, "x") or nil, vars) or 0
        local py = number(type(pos) == "table" and get(pos, "y") or nil, vars) or 0
        local size = get(b, "size")
        local w = number(type(size) == "table" and (get(size, "width") or get(size, "x")) or nil, vars, parent.w)
        local h = number(type(size) == "table" and (get(size, "height") or get(size, "y")) or nil, vars, parent.h)
        local scale = number(get(b, "scale"), vars) or 1
        local sprite = get(b, "spriteType") or get(b, "quadTextureSprite")
        local frame = number(get(b, "frame"), vars)

        if ICONS[kind] and sprite and (w == nil or h == nil) then
            local s = db.sprites[sprite]
            local tw, th
            if s and s.texture then
                tw, th = opts.texture_size(s.texture)
            end
            if tw then
                w = w or tw / math.max(1, s.frames) * scale
                h = h or th * scale
            end
        elseif TEXTS[kind] then
            w = w or number(get(b, "maxWidth"), vars) or 100
            h = h or number(get(b, "maxHeight"), vars) or 16
        end
        w, h = w or 0, h or 0
        local a = anchor(get(b, "orientation"))
        local o = anchor(get(b, "origo"))
        local x = parent.x + a[1] * parent.w + px - o[1] * w
        local y = parent.y + a[2] * parent.h + py - o[2] * h
        local rect = { x = x, y = y, w = w, h = h }

        if CONTAINERS[kind] then
            for _, e in ipairs(b) do
                if e.op and e.key and type(e.value) == "table" and e.value.text == nil then
                    local k = e.key.text:lower()
                    if k == "background" then
                        -- a cornered tile fills the window; a plain sprite keeps its own size
                        local bs = get(e.value, "spriteType") or get(e.value, "quadTextureSprite")
                        local s = bs and db.sprites[bs]
                        local fill = s and s.kind == "corneredTileSpriteType"
                        if bs and not hidden(path .. "/background", "") then
                            sprite_item(path .. "/background", bs, number(get(e.value, "frame"), vars), x, y,
                                fill and w or nil, fill and h or nil, fill)
                        end
                    elseif CONTAINERS[k] or ICONS[k] or TEXTS[k] then
                        -- a drop-down's expanded window is closed until it is clicked
                        if not (kind == "dropdownboxtype" and get(e.value, "name") == "expanded_window") then
                            element(k, e.value, rect, path, depth + 1)
                        end
                    elseif k ~= "position" and k ~= "size" and k ~= "hide_position" and k ~= "show_position" then
                        report.skipped[k] = (report.skipped[k] or 0) + 1
                    end
                end
            end
        elseif ICONS[kind] then
            if sprite then
                sprite_item(path, sprite, frame, x, y, w, h, true)
            end
        elseif TEXTS[kind] then
            local text = opts.text and opts.text[path]
            if text == nil then
                text = get(b, "text") or ""
            end
            items[#items + 1] = {
                kind = "text", path = path, font = get(b, "font") or "cg_16b", text = tostring(text),
                x = x, y = y, w = w, h = h, format = (get(b, "format") or "left"):lower(),
            }
            report.texts = report.texts + 1
        end
    end

    element("containerwindowtype", window, { x = 0, y = 0, w = screen.width, h = screen.height }, "", 0)
    return items, report
end

return gui
