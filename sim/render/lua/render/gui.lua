-- render/gui.lua : the game's GUI windows from interface/*.gui (pdxscript), laid out the way the
-- Clausewitz GUI does it, into a flat list of sprites and texts for the renderer.
--
--   local gui = require("render.gui")
--   local items, report = gui.layout(game_dir, db, "interface/main.gui", "maingui",
--       { width = w, height = h }, { only = {...}, hide = {...}, text = {...}, texture_size = f })
--
-- An element's rectangle: its parent's content area's top left (the parent's rectangle less its
-- `margin`) + the parent's anchor point (`orientation`) + `position` - its own anchor point
-- (`origo`). Sizes may be in % of the parent ("100%%" too). An iconType or buttonType without a
-- size is the size of its sprite's frame times its `scale`. A window's background: a cornered
-- tile fills the window (nine slices), a plain sprite keeps its size. `if_scaled_resolution =
-- { min_height = 900 ... }` blocks replace the fields they give when the screen matches.
-- Scripted variables (`@x = 17`) are scoped: a window's own apply to it and its children, the
-- file's to all. Texts are localisation keys (engine.localisation), split at their colour codes
-- into spans coloured with the fonts' textcolors; a button's `buttonText` is centred on it. What
-- the game decides at run time (which elements show, texts, actions) comes from `opts`.

local source = require("stellar.script.source")
local gfx = require("render.gfx")
local get = gfx.get

local gui = {}

local ANCHOR = {
    upper_left = { 0, 0 }, upper_right = { 1, 0 }, lower_left = { 0, 1 }, lower_right = { 1, 1 },
    center = { 0.5, 0.5 }, centre = { 0.5, 0.5 }, center_up = { 0.5, 0 }, center_down = { 0.5, 1 },
    center_left = { 0, 0.5 }, center_right = { 1, 0.5 },
}

-- element kinds drawn (lists, scrollbars, edit boxes are filled at run time: not drawn)
local CONTAINERS = { containerwindowtype = true, windowtype = true, dropdownboxtype = true }
-- (a checkbox and a drop-down's expand button are buttons with a sprite, their frames the
-- states: checkboxType, expandButton)
local ICONS = { icontype = true, buttontype = true, effectbuttontype = true, guibuttontype = true, checkboxtype = true, expandbutton = true }
local TEXTS = { instanttextboxtype = true, textboxtype = true }
-- lists: laid out (their rectangle is recorded, for the rows the caller places) but not drawn
local LISTS = { smoothlistboxtype = true, listboxtype = true, gridboxtype = true, overlappingelementsboxtype = true }
gui.CONTAINERS, gui.ICONS, gui.TEXTS, gui.LISTS = CONTAINERS, ICONS, TEXTS, LISTS

local trees = {}   -- file -> tree, parsed once

local function tree_of(game_dir, file)
    local t = trees[file]
    if not t then
        local message
        t, message = source.parse(game_dir, file)
        if not t then
            error(message)
        end
        trees[file] = t
    end
    return t
end

-- the `@name = value` statements of a block, into a scope over `parent`
local function scope_of(block, parent)
    local s = setmetatable({}, { __index = parent })
    for _, e in ipairs(block) do
        if e.op and e.key and e.key.text:sub(1, 1) == "@" and e.value.text then
            s[e.key.text] = e.value.text
        end
    end
    return s
end

-- a number field through the scope's scripted variables; percent sizes against `of`
local function number(v, vars, of)
    if type(v) ~= "string" then
        return nil
    end
    if v:sub(1, 1) == "@" then
        v = vars[v] or v
    end
    local pct = v:match("^(-?[%d%.]+)%%+$")
    if pct then
        return (of or 0) * tonumber(pct) / 100
    end
    return tonumber(v)
end

-- an element's field: its last `key = value` (a key given twice takes the later value, as the
-- game reads it: expansion_planner_view's expansion_target_title has two `text`s and the game
-- shows the second)
local function last(block, key)
    key = key:lower()
    for i = #block, 1, -1 do
        local e = block[i]
        if e.op and e.key and e.key.text:lower() == key then
            return e.value.text or e.value
        end
    end
    return nil
end

-- a gridBoxType's `format` (CGridBoxType::StringToFormat: these exact names; any other is UP)
local GRID_FORMATS = {
    UP = 0, DOWN = 1, LEFT = 2, RIGHT = 3, UPPER_LEFT = 4, LOWER_LEFT = 5, UPPER_RIGHT = 6,
    LOWER_RIGHT = 7, CENTERED_UP = 8, CENTERED_DOWN = 9, CENTERED_LEFT = 10, CENTERED_RIGHT = 11,
    CENTERED_UP_BY_LINE = 12,
}

local function anchor(name)
    return ANCHOR[(type(name) == "string" and name or "upper_left"):lower()] or ANCHOR.upper_left
end

-- the window `name` of a .gui file (a containerWindowType or windowType at its top), and the
-- file's scope
function gui.find(game_dir, file, name)
    local tree = tree_of(game_dir, file)
    local scope = scope_of(tree, nil)
    local found
    local function scan(block)
        for _, e in ipairs(block) do
            if e.op and e.key and type(e.value) == "table" and e.value.text == nil then
                local kl = e.key.text:lower()
                if kl == "guitypes" then
                    for k, v in pairs(scope_of(e.value, nil)) do
                        rawset(scope, k, v)
                    end
                    scan(e.value)
                elseif CONTAINERS[kl] and get(e.value, "name") == name and not found then
                    found = e.value
                end
            end
        end
    end
    scan(tree)
    return found, scope
end

-- gui.layout(game_dir, db, file, window, screen, opts) -> items, report
--   items: { kind = "sprite", path, sprite, texture, frame, frames, x, y, w, h, border = {x,y}|nil,
--            sprite_kind, button = { name, id, action } | nil }
--          { kind = "text", path, font, text, spans = { { text, colour = {r,g,b} } }, x, y, w, h,
--            format, valign }
--   report: { sprites, texts, missing_sprites, skipped, rects = { [path] = {x,y,w,h} } }
--   opts.only: names of the window's children to lay out (all if nil)
--   opts.hide: element paths or names not drawn
--   opts.text: element path -> text (else the element's text, localised)
--   opts.actions: element path -> action (what a click on that button does; on a window, its
--                 background takes the clicks)
--   opts.frames: element path -> the sprite's frame (the game's run-time state)
--   opts.sizes: element path -> { w, h } (a window the game sizes at run time)
--   opts.positions: element path -> { x, y } (a window at another of its places: hide_position)
--   opts.sprites: element path -> sprite name (an icon the game sets at run time)
--   opts.tints: element path -> { r, g, b, a } (a sprite coloured: the map labels' relation colour)
--   opts.open: drop-down path -> true (its expanded window laid out: the drop-down clicked open)
--   opts.disabled: element path -> true (it and its children drawn as the game draws a disabled
--                  button: greyed)
--   opts.progress: element path -> 0..1 (a progressbarType's state: progress.shader draws its
--                 textureFile1 where u <= the state, its textureFile2 after; an item's `clip` is
--                 the { u0, u1 } of its frame drawn, its rectangle cut the same)
--   opts.parent: the rectangle the window is laid out in (else the screen)
--   opts.prefix: a path prefix for the window's elements (else "")
--   opts.texture_size(path) -> w, h (the renderer's: the texture's pixels)
--   opts.loc: engine.localisation (texts are keys when it has them)
function gui.layout(game_dir, db, file, window_name, screen, opts)
    opts = opts or {}
    local window, file_scope = gui.find(game_dir, file, window_name)
    if not window then
        error(file .. ": no window " .. window_name)
    end
    local items = {}
    local report = { sprites = 0, texts = 0, missing_sprites = {}, skipped = {}, rects = {}, grids = {} }
    local loc = opts.loc

    -- a sprite sheet's frame stands for its sheet (with its default frame)
    local function resolve(name, frame)
        local s = db.sprites[name]
        if s and s.sheet and db.sprites[s.sheet] then
            return s.sheet, frame or s.default_frame
        end
        return name, frame
    end

    local function frame_size(sprite)
        sprite = resolve(sprite)
        local s = db.sprites[sprite]
        if s and s.size then
            return s.size[1], s.size[2]
        end
        if not s or not s.texture then
            return nil
        end
        local tw, th = opts.texture_size(s.texture)
        if not tw then
            return nil
        end
        return tw / math.max(1, s.frames), th
    end

    -- disabled: the path or one of its windows in opts.disabled (the game's Disable: the sprites
    -- greyed, GreyOutLuminosity 0.85 x 0.75; a button's text too, TextDisable)
    local function is_disabled(path)
        if not opts.disabled then
            return false
        end
        local p = path
        while p and p ~= "" do
            if opts.disabled[p] then
                return true
            end
            p = p:match("^(.*)/[^/]*$")
        end
        return false
    end
    local function grey(c)
        local g = 0.212671 * c[1] + 0.715160 * c[2] + 0.072169 * c[3]
        return { (g * 0.85 + c[1] * 0.15) * 0.75, (g * 0.85 + c[2] * 0.15) * 0.75, (g * 0.85 + c[3] * 0.15) * 0.75 }
    end

    local sprite_item
    -- a progress bar at its state: its two textures, each over its part
    local function progress_items(path, name, frame, x, y, w, h, button, p)
        local s = db.sprites[name]
        p = math.max(0, math.min(1, p))
        local fw, fh = frame_size(name)
        w, h = w or fw, h or fh
        local first = sprite_item(path, name, frame, x, y, w, h, button, { 0, p }, true)
        if s.texture2 and p < 1 then
            local item = sprite_item(path .. "/empty", name, frame, x, y, w, h, nil, { p, 1 }, true)
            if item then
                item.texture = s.texture2
            end
        end
        return first
    end

    function sprite_item(path, name, frame, x, y, w, h, button, clip, plain)
        name, frame = resolve(name, frame)
        local s = db.sprites[name]
        if not s or not s.texture then
            report.missing_sprites[#report.missing_sprites + 1] = tostring(name)
            return nil
        end
        local p = not plain and opts.progress and opts.progress[path]
        if p and s.kind == "progressbarType" then
            return progress_items(path, name, frame, x, y, w, h, button, p)
        end
        local fw, fh = frame_size(name)
        if not fw then
            report.missing_sprites[#report.missing_sprites + 1] = tostring(name) .. " (" .. s.texture .. ")"
            return nil
        end
        local item = {
            kind = "sprite", path = path, sprite = name, texture = s.texture, sprite_kind = s.kind,
            frame = math.max(1, frame or 1), frames = s.frames, x = x, y = y, w = w or fw, h = h or fh,
            border = s.kind == "corneredTileSpriteType" and s.border or nil, button = button,
            tint = opts.tints and opts.tints[path] or nil, clip = clip,
            disabled = is_disabled(path) or nil,
        }
        items[#items + 1] = item
        report.sprites = report.sprites + 1
        return item
    end

    -- a text's spans: localised, split at colour codes, coloured
    local function text_item(path, font, text, x, y, w, h, format, valign, colour_code, grows)
        local spans = {}
        local base = db.textcolors[colour_code or ""] or { 1, 1, 1 }
        if loc then
            if loc.has(text) then
                text = loc.get(text)
            elseif text:find("$", 1, true) then
                text = loc.resolve(text)
            end
            for _, s in ipairs(loc.spans(text)) do
                if s.text then
                    spans[#spans + 1] = { text = s.text, colour = db.textcolors[s.colour or ""] or base }
                elseif s.icon then
                    -- a text icon (£name£: GFX_text_<name>): "\1texture\1frames\1frame" for the renderer
                    -- (a resource's icon has no GFX_text_ sprite: its GFX_resource_ one, as the
                    -- game's frames show £food£ and £alloys£)
                    local sp = db.sprites["GFX_text_" .. s.icon] or db.sprites["GFX_resource_" .. s.icon]
                    if sp and sp.sheet and db.sprites[sp.sheet] then
                        sp = { texture = db.sprites[sp.sheet].texture, frames = db.sprites[sp.sheet].frames, frame = sp.default_frame }
                    end
                    if sp and sp.texture then
                        spans[#spans + 1] = { text = "\1" .. sp.texture .. "\1" .. (sp.frames or 1) .. "\1" .. (sp.frame or 1), colour = base }
                    end
                end
            end
        else
            spans[1] = { text = text, colour = base }
        end
        local plain = {}
        for _, s in ipairs(spans) do
            plain[#plain + 1] = s.text
        end
        items[#items + 1] = {
            kind = "text", path = path, font = font or "cg_16b", text = table.concat(plain), spans = spans,
            x = x, y = y, w = w, h = h, format = (format or "left"):lower(), valign = valign or "top",
            fixed = not grows,
        }
        report.texts = report.texts + 1
    end

    local function hidden(path, name)
        return opts.hide and (opts.hide[path] or opts.hide[name])
    end

    local function element(kind, b, parent, parent_path, depth, scope)
        local name = get(b, "name") or "?"
        local path = parent_path .. "/" .. name
        if hidden(path, name) or (depth == 1 and opts.only and not opts.only[name]) then
            return
        end
        local vars = scope_of(b, scope)
        -- the fields, with the if_scaled_resolution blocks that match the screen over them
        local over = {}
        for _, e in ipairs(b) do
            if e.op and e.key and e.key.text:lower() == "if_scaled_resolution" and e.value.text == nil then
                local c = e.value
                local ok = true
                local function bound(k, cmp)
                    local v = number(get(c, k), vars)
                    if v and not cmp(v) then
                        ok = false
                    end
                end
                bound("min_height", function(v) return screen.height >= v end)
                bound("max_height", function(v) return screen.height <= v end)
                bound("min_width", function(v) return screen.width >= v end)
                bound("max_width", function(v) return screen.width <= v end)
                if ok then
                    over[#over + 1] = c
                end
            end
        end
        local function field(k)
            for i = #over, 1, -1 do
                local v = get(over[i], k)
                if v ~= nil then
                    return v
                end
            end
            return last(b, k)
        end

        -- a window the game slides in and out is laid out where it shows (show_position)
        local pos = field("show_position") or field("position")
        local px = number(type(pos) == "table" and get(pos, "x") or nil, vars) or 0
        local py = number(type(pos) == "table" and get(pos, "y") or nil, vars) or 0
        local over_pos = opts.positions and opts.positions[path]
        if over_pos then
            px, py = over_pos[1], over_pos[2]
        end
        local size = field("size")
        local over_size = opts.sizes and opts.sizes[path]
        local w = number(type(size) == "table" and (get(size, "width") or get(size, "x")) or nil, vars, parent.w)
        local h = number(type(size) == "table" and (get(size, "height") or get(size, "y")) or nil, vars, parent.h)
        if over_size then
            w, h = over_size[1], over_size[2]
        end
        local scale = number(field("scale"), vars) or 1
        local sprite = opts.sprites and opts.sprites[path] or field("spriteType") or field("quadTextureSprite")
        -- (a sprite set at run time keeps its own frame: the element's `frame` was the file's
        -- sprite's)
        local frame = opts.frames and opts.frames[path] or (not (opts.sprites and opts.sprites[path]) and number(field("frame"), vars) or nil)

        if ICONS[kind] and sprite and (w == nil or h == nil) then
            local fw, fh = frame_size(sprite)
            if fw then
                w = w or fw * scale
                h = h or fh * scale
            end
        elseif TEXTS[kind] then
            w = w or number(field("maxWidth"), vars) or 100
            h = h or number(field("maxHeight"), vars) or 16
        end
        w, h = w or 0, h or 0
        local a = anchor(field("orientation"))
        local o = anchor(field("origo"))
        local x = parent.x + a[1] * parent.w + px - o[1] * w
        local y = parent.y + a[2] * parent.h + py - o[2] * h
        -- centerPosition: the element centred on its position
        if field("centerPosition") == "yes" then
            x, y = x - w / 2, y - h / 2
        end
        report.rects[path] = { x = x, y = y, w = w, h = h }
        -- a grid box: what places its items (gui.grid_slot)
        if kind == "gridboxtype" then
            local ss = field("slotsize")
            local mx = field("max_slots")
            report.grids[path] = {
                x = x, y = y, w = w, h = h,
                sx = number(type(ss) == "table" and (get(ss, "width") or get(ss, "x")) or nil, vars) or 0,
                sy = number(type(ss) == "table" and (get(ss, "height") or get(ss, "y")) or nil, vars) or 0,
                max_h = number(field("max_slots_horizontal"), vars) or (type(mx) == "table" and number(get(mx, "x"), vars)) or -1,
                max_v = number(field("max_slots_vertical"), vars) or (type(mx) == "table" and number(get(mx, "y"), vars)) or -1,
                format = GRID_FORMATS[field("format") or ""] or 0,
                add_horizontal = field("add_horizontal") ~= "no",
            }
        end

        if CONTAINERS[kind] then
            -- children are laid out in the window less its margin
            local m = field("margin")
            local ml, mt, mr, mb = 0, 0, 0, 0
            if type(m) == "table" then
                ml = number(get(m, "left"), vars) or 0
                mt = number(get(m, "top"), vars) or 0
                mr = number(get(m, "right"), vars) or 0
                mb = number(get(m, "bottom"), vars) or 0
            end
            local inner = { x = x + ml, y = y + mt, w = w - ml - mr, h = h - mt - mb }
            for _, e in ipairs(b) do
                if e.op and e.key and type(e.value) == "table" and e.value.text == nil then
                    local k = e.key.text:lower()
                    if k == "background" then
                        -- a cornered tile fills the window; a plain sprite keeps its own size
                        local bs = get(e.value, "spriteType") or get(e.value, "quadTextureSprite")
                        local s = bs and db.sprites[bs]
                        local fill = s and s.kind == "corneredTileSpriteType"
                        -- (hidden by its own name too: a window's second background, the
                        -- selected_overlay of a list entry, shows at run time)
                        local bname = get(e.value, "name")
                        if bs and not hidden(path .. "/background", "") and not (bname and hidden(path .. "/" .. bname, bname)) then
                            local bw, bh
                            if fill then
                                bw, bh = w, h
                            end
                            -- a window the game takes clicks on (opts.actions names it): its
                            -- background is its button, over the whole window
                            local action = opts.actions and opts.actions[path]
                            local button
                            if action then
                                bw, bh = w, h
                                button = { name = name, action = action }
                            end
                            -- its own `position` moves it from the window's corner (first_contact_view's
                            -- chapters frame at -58, -27: the game's frame shows it there); a background
                            -- that takes the clicks stays over the window
                            local bp = get(e.value, "position")
                            local ox = not button and type(bp) == "table" and number(get(bp, "x"), vars) or 0
                            local oy = not button and type(bp) == "table" and number(get(bp, "y"), vars) or 0
                            sprite_item(path .. "/background", bs, number(get(e.value, "frame"), vars), x + ox, y + oy, bw, bh, button)
                        end
                    elseif CONTAINERS[k] or ICONS[k] or TEXTS[k] or LISTS[k] or k == "expandedwindow" then
                        -- a drop-down's expanded window (expandedWindow, or a window named
                        -- expanded_window) is closed until it is clicked: laid out (at its
                        -- show_position) when opts.open names the drop-down
                        local expanded = kind == "dropdownboxtype" and (k == "expandedwindow" or get(e.value, "name") == "expanded_window")
                        if not expanded then
                            element(k, e.value, inner, path, depth + 1, vars)
                        elseif opts.open and opts.open[path] then
                            element("containerwindowtype", e.value, inner, path, depth + 1, vars)
                        end
                    elseif k ~= "position" and k ~= "size" and k ~= "hide_position" and k ~= "show_position"
                        and k ~= "margin" and k ~= "if_scaled_resolution" then
                        report.skipped[k] = (report.skipped[k] or 0) + 1
                    end
                end
            end
        elseif ICONS[kind] then
            local button
            -- buttons, and an icon the game takes clicks on (opts.actions names it: the left
            -- bar's view icons)
            if (kind ~= "icontype" or (opts.actions and opts.actions[path])) and field("alwaysTransparent") ~= "yes" then
                button = { name = name, id = field("id"), action = opts.actions and opts.actions[path] }
            end
            if sprite then
                -- a plain sprite is drawn at its frame's size (times its scale) whatever the
                -- element's `size`, which is its box (its text's, its clicks'); a cornered tile
                -- fills the size (expansion_target_entry's background: the 1158 x 74 frame of
                -- GFX_button_1134_50_animated under its size 1134 x 50, as the game draws it)
                local dw, dh = w, h
                local s = db.sprites[(resolve(sprite))]
                if type(size) == "table" and not over_size and s and s.kind ~= "corneredTileSpriteType" then
                    local fw, fh = frame_size(sprite)
                    if fw then
                        dw, dh = fw * scale, fh * scale
                    end
                end
                local item = sprite_item(path, sprite, frame, x, y, dw, dh, button)
                -- a checkbox's frame is its state: no hover or pressed frames (the game's frame:
                -- an unticked box stays unticked under the pointer)
                if item and kind == "checkboxtype" then
                    item.sprite_kind = "checkbox"
                end
            end
            -- its buttonText (or `text`: the galactic community's assign_button shows its
            -- LEADER_ASSIGNMENT in the game's frame), or a text the game sets at run time
            -- (CButton::SetText)
            local bt = field("buttonText") or (kind ~= "icontype" and field("text") or nil)
            local given = opts.text and opts.text[path]
            if (bt and bt ~= "") or (given and kind ~= "icontype") then
                local text = given or bt
                text_item(path .. "/text", field("buttonFont") or field("font"), text, x, y, w, h, "center", "center",
                    field("text_color_code"))
                if is_disabled(path) then
                    for _, s in ipairs(items[#items].spans) do
                        s.colour = grey(s.colour)
                    end
                end
            end
        elseif TEXTS[kind] then
            local text = opts.text and opts.text[path]
            if text == nil then
                text = field("text") or ""
            end
            local valign = field("vertical_alignment")
            -- (a text box without fixedSize grows with its lines)
            text_item(path, field("font"), tostring(text), x, y, w, h, field("format"),
                valign and valign:lower() or "top", field("text_color_code"), field("fixedSize") ~= "yes")
        end
    end

    local parent = opts.parent or { x = 0, y = 0, w = screen.width, h = screen.height }
    element("containerwindowtype", window, parent, opts.prefix or "", 0, file_scope)
    return items, report
end

-- gui.grid_slot(grid, n, count, row_counts) -> x, y, or nil when the grid has no room for item
-- n (0-based) of `count`: a gridBoxType's item place (TGridBox::Add: the index to a column and
-- row, by rows unless add_horizontal = no; CGridBoxBase::GetSlotPosition: the slot by `format`,
-- the default UP centring one slot across the grid's width). grid: report.grids[path].
-- row_counts: the items of each row (CENTERED_UP_BY_LINE only).
function gui.grid_slot(g, n, count, row_counts)
    local cx, cy
    if g.add_horizontal then
        if g.max_h > 0 then
            cx, cy = n % g.max_h, math.floor(n / g.max_h)
        else
            cx, cy = n, 0
        end
        if g.max_v > 0 and cy >= g.max_v then
            return nil
        end
    else
        if g.max_v > 0 then
            cx, cy = math.floor(n / g.max_v), n % g.max_v
        else
            cx, cy = 0, n
        end
        if g.max_h > 0 and cx >= g.max_h then
            return nil
        end
    end
    local function half(v)
        return v >= 0 and math.floor(v / 2) or -math.floor(-v / 2)
    end
    local W, H, sx, sy = g.w, g.h, g.sx, g.sy
    local mH = math.min(g.max_h > 0 and g.max_h or count, count)
    local mV = math.min(g.max_v > 0 and g.max_v or count, count)
    local f = g.format
    local x, y
    if f == 1 then x, y = cx * sx + half(W - sx), H - sy - cy * sy
    elseif f == 2 then x, y = cy * sx, cx * sy + half(H - sy)
    elseif f == 3 then x, y = W - sx - cy * sx, cx * sy + half(H - sy)
    elseif f == 4 then x, y = cx * sx, cy * sy
    elseif f == 5 or f == 7 then
        x = f == 5 and cx * sx or -cx * sx
        y = g.add_horizontal and (H - sy - cy * sy) or (H - sy + (cy + 1 - count) * sy)
    elseif f == 6 then x, y = W - sx - cx * sx, cy * sy
    elseif f == 8 then x, y = half(W) - half(mH * sx) + cx * sx, cy * sy
    elseif f == 9 then x, y = half(W) - half(mH * sx) + cx * sx, H - sy - cy * sy
    elseif f == 10 then x, y = cy * sx, half(H) - half(mV * sy) + cx * sy
    elseif f == 11 then x, y = W - sx - cy * sx, half(H) - half(mV * sy) + cx * sy
    elseif f == 12 then x, y = half(W) - half(((row_counts or {})[cy + 1] or mH) * sx) + cx * sx, cy * sy
    else x, y = cx * sx + half(W - sx), cy * sy
    end
    return g.x + x, g.y + y
end

-- appends b's items to a's, and merges the reports
function gui.merge(a, ra, b, rb)
    for _, it in ipairs(b) do
        a[#a + 1] = it
    end
    for _, m in ipairs(rb.missing_sprites) do
        ra.missing_sprites[#ra.missing_sprites + 1] = m
    end
    ra.sprites = ra.sprites + rb.sprites
    ra.texts = ra.texts + rb.texts
    for k, n in pairs(rb.skipped) do
        ra.skipped[k] = (ra.skipped[k] or 0) + n
    end
    for k, r in pairs(rb.rects) do
        ra.rects[k] = r
    end
    if rb.grids then
        ra.grids = ra.grids or {}
        for k, g in pairs(rb.grids) do
            ra.grids[k] = g
        end
    end
    return a, ra
end

return gui
