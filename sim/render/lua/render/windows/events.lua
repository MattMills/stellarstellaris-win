-- render/windows/events.lua : the event windows (interface/eventwindow.gui, CEventWindow) and the
-- popups (interface/popup.gui, CPopupMessage*), laid out by render.gui with the texts of
-- render.windows.events_data (docs/windows/events.md).
--
--   local events = require("render.windows.events")
--   local items, report = events.build(game_dir, db, screen, texture_size, loc, data, state)
--
-- data: render.windows.events_data's table; state = { open = { event ids, the top one last },
-- popups = { { kind = "ok"|"yes_no", title, text } } }.
--
-- The event window (CEventWindow::Setup, 4.5.2 Linux 0x2d2ed70) [V]: `EventWindow` centred on the
-- screen; its Title, the picture (the event's `picture`, in `event_picture`), the description in
-- `description_frame` (at its GUI place got and set again: GetPosition gives the place after the
-- anchors, SetPosition takes it as a position, so the frame's x is 14, not 0; y 220 plus the
-- situation and event chain panels' height, none here), the frame as high as the text + 32, the
-- tts button hidden; an `event_window_option_entry` per option shown, from the frame's bottom + 5
-- at event_option_offset (x 7, 30 apart); the window as high as the last option's bottom + 10 (the
-- frame's bottom + 10 without options). The focus button shows for an event with a `location`,
-- else the message settings button takes its x. The texts wrap at the text box's maxWidth, a line
-- of the font's line height (cg_16b: 16).

local gui = require("render.gui")
local names = require("render.names")

local M = {}

local FILE = "interface/eventwindow.gui"
local POPUPS = "interface/popup.gui"

-- ---------------------------------------------------------------------------------------------
-- text: localised, the [commands] the data resolved put in, wrapped at a width

-- the event's names for its [commands] (names.format), the rest kept as the game shows an
-- unresolved command: as text [I]
local function resolve(loc, text, ev)
    if not loc then
        return text
    end
    if loc.has(text) then
        text = loc.get(text)
    elseif text:find("$", 1, true) then
        text = loc.resolve(text)
    end
    local cache = {}
    return (text:gsub("%[([^%[%]]+)%]", function(cmd)
        local key = cmd:lower():gsub("%s", "")
        local n = ev and ev.names and ev.names[key]
        if not n then
            return nil
        end
        if cache[key] == nil then
            cache[key] = names.format(loc, n)
        end
        return cache[key]
    end))
end
M.resolve = resolve

-- the width of a string in a font (RENDER_FONT_METRICS, from the renderer's font: the advances
-- and the kerning, as font.rs measures)
local function metrics(font)
    local m = RENDER_FONT_METRICS and RENDER_FONT_METRICS[font]
    return m
end

-- the code points of a UTF-8 string (LuaJIT has no utf8 library)
local function codes(s)
    return coroutine.wrap(function()
        for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
            local b = { ch:byte(1, -1) }
            local c = b[1]
            if c >= 240 then
                c = (c % 8) * 262144 + (b[2] % 64) * 4096 + ((b[3] or 128) % 64) * 64 + ((b[4] or 128) % 64)
            elseif c >= 224 then
                c = (c % 16) * 4096 + (b[2] % 64) * 64 + ((b[3] or 128) % 64)
            elseif c >= 192 then
                c = (c % 32) * 64 + ((b[2] or 128) % 64)
            end
            coroutine.yield(c)
        end
    end)
end

local function width(m, s)
    if not m then
        return #s * 7
    end
    local w, prev = 0, nil
    for c in codes(s) do
        local a = m.adv[c]
        if a then
            w = w + a + (prev and m.kern[prev * 65536 + c] or 0)
        end
        prev = c
    end
    return w
end
M.width = width

-- a text's spans (loc.spans: { text, colour } and { icon }) cut into lines no wider than `w`: at
-- the spaces, a new line at "\n" -> lines of { { text, colour } }
local function wrap(loc, text, font, w, db, base)
    local m = metrics(font)
    local spans = loc and loc.spans(text) or { { text = text } }
    local lines, line, used = {}, {}, 0
    local function colour(s)
        return db.textcolors[s.colour or ""] or base
    end
    local function push(t, c)
        local last = line[#line]
        if last and last.colour == c then
            last.text = last.text .. t
        else
            line[#line + 1] = { text = t, colour = c }
        end
    end
    local function newline()
        -- the line's trailing spaces are not drawn
        local last = line[#line]
        if last then
            last.text = last.text:gsub("%s+$", "")
        end
        lines[#lines + 1] = line
        line, used = {}, 0
    end
    for _, s in ipairs(spans) do
        if s.text then
            local c = colour(s)
            local first = true
            for part in (s.text .. "\n"):gmatch("([^\n]*)\n") do
                if not first then
                    newline()
                end
                first = false
                -- words with the spaces after them
                for word, space in part:gmatch("([^ ]*)( *)") do
                    if word ~= "" or space ~= "" then
                        local ww = width(m, word)
                        if used > 0 and used + ww > w then
                            newline()
                        end
                        if not (used == 0 and word == "" and #lines > 0) then
                            push(word .. space, c)
                            used = used + ww + width(m, space)
                        end
                    end
                end
            end
        end
    end
    if #line > 0 then
        newline()
    end
    return lines, m and m.line or 16
end
M.wrap = wrap

-- text items for wrapped lines at (x, y), each line `lh` high
local function line_items(path, font, lines, lh, x, y, w, format)
    local items = {}
    for k, l in ipairs(lines) do
        local plain, spans = {}, {}
        for _, s in ipairs(l) do
            plain[#plain + 1] = s.text
            spans[#spans + 1] = { text = s.text, colour = s.colour }
        end
        items[#items + 1] = {
            kind = "text", path = path .. "/" .. k, font = font, text = table.concat(plain), spans = spans,
            x = x, y = y + (k - 1) * lh, w = w, h = lh, format = format or "left", valign = "top",
        }
    end
    return items
end
M.line_items = line_items

local function new_report()
    return { sprites = 0, texts = 0, missing_sprites = {}, skipped = {}, rects = {} }
end

-- ---------------------------------------------------------------------------------------------
-- the event window

local function event_window(ctx, ev, k, items, report)
    local loc, db = ctx.loc, ctx.db
    local prefix = "/events/" .. k
    local root = prefix .. "/EventWindow"
    -- the description: its lines and height
    local font = "cg_16b"
    local desc = resolve(loc, ev.desc or "", ev)
    local base = db.textcolors.E or { 1, 1, 1 }
    local lines, lh = wrap(loc, desc, font, 436, db, base)
    local text_h = #lines * lh
    local frame_y = 220
    local frame_h = text_h + 32
    local opts = ev.options or {}
    if #opts == 0 then
        -- no valid option: the game adds one, "event_option_error" (an OK)
        opts = { { name = "OK", error = true } }
    end
    local first = frame_y + frame_h + 5
    local h = first + (#opts - 1) * 30 + 32 + 10
    local w = 490
    local hide = { tts_button = true, event_chain_subview = true, situations_progress_subview = true, description = true }
    local positions = { [root .. "/description_frame"] = { 0, frame_y } }
    if not ev.location or not ev.location_system then
        hide.focus_button = true
        positions[root .. "/message_settings_button"] = { 415, 19 }
    end
    local sprites = {}
    if ev.picture and db.sprites[ev.picture] then
        sprites[root .. "/event_picture"] = ev.picture
    else
        hide.event_picture = true
    end
    local wi, wr = gui.layout(ctx.game_dir, db, FILE, "EventWindow", ctx.screen, {
        texture_size = ctx.texture_size, loc = loc, prefix = prefix, hide = hide, positions = positions,
        sizes = { [root] = { w, h }, [root .. "/description_frame"] = { 462, frame_h } },
        sprites = sprites,
        text = { [root .. "/Title"] = resolve(loc, ev.title or "", ev) },
        actions = {
            [root] = "event:front:" .. ev.id,
            [root .. "/close"] = "event:close:" .. ev.id,
            [root .. "/focus_button"] = "event:focus:" .. ev.id,
        },
    })
    gui.merge(items, report, wi, wr)
    local fr = wr.rects[root .. "/description_frame"]
    if fr then
        for _, it in ipairs(line_items(root .. "/description_frame/description", font, lines, lh, fr.x + 13, fr.y + 12, 436)) do
            items[#items + 1] = it
            report.texts = report.texts + 1
        end
    end
    local win = wr.rects[root]
    for i, o in ipairs(opts) do
        local op = prefix .. "/option/" .. i
        local path = op .. "/event_window_option_entry"
        local oi, orr = gui.layout(ctx.game_dir, db, FILE, "event_window_option_entry", ctx.screen, {
            texture_size = ctx.texture_size, loc = loc, prefix = op,
            parent = { x = win.x + 7, y = win.y + first + (i - 1) * 30, w = 0, h = 0 },
            hide = { selector_gui_presence_icon = true },
            -- the option's index among the event's options (simscript.events.answer)
            actions = { [path .. "/event_option_button"] = "event:option:" .. ev.id .. ":" .. (o.index or i) },
        })
        gui.merge(items, report, oi, orr)
        -- the option's name on its button (the .gui gives the button no buttonText: the game sets
        -- it, in the button's font, centred)
        local b = orr.rects[path .. "/event_option_button"]
        if b then
            local label = o.error and resolve(loc, "event_option_error", ev) or resolve(loc, o.name or "OK", ev)
            local ls = wrap(loc, label, font, 10000, db, db.textcolors.W or { 1, 1, 1 })
            for _, it in ipairs(line_items(path .. "/event_option_button/text", font, { ls[1] or {} }, lh, b.x, b.y + (b.h - lh) / 2, b.w, "center")) do
                items[#items + 1] = it
                report.texts = report.texts + 1
            end
        end
    end
end

-- ---------------------------------------------------------------------------------------------
-- the popups (popup.gui): `ok_popup_window` (CPopupMessageOK) and `yes_no_popup_window`, at their
-- .gui place from the screen's centre [I: CPopupMessage's placement not read]

local function popup(ctx, p, k, items, report)
    local window = p.kind == "yes_no" and "yes_no_popup_window" or "ok_popup_window"
    local prefix = "/popups/" .. k
    local root = prefix .. "/" .. window
    local pi, pr = gui.layout(ctx.game_dir, ctx.db, POPUPS, window, ctx.screen, {
        texture_size = ctx.texture_size, loc = ctx.loc, prefix = prefix,
        parent = { x = ctx.screen.width / 2, y = ctx.screen.height / 2, w = 0, h = 0 },
        text = {
            [root .. "/title"] = resolve(ctx.loc, p.title or "", nil),
            [root .. "/description"] = resolve(ctx.loc, p.text or "", nil),
        },
        actions = {
            [root .. "/AgreeButton"] = "popup:agree:" .. k,
            [root .. "/DeclineButton"] = "popup:decline:" .. k,
        },
    })
    gui.merge(items, report, pi, pr)
end

-- ---------------------------------------------------------------------------------------------
-- the first contact view (interface/first_contact_view.gui, CFirstContactView: "Show First
-- Contact" in the Situation Log's Findings) [V for the parts, I where marked]: centred; the
-- contact's name, its event's picture, a stage icon per stage so far (the first the starter's,
-- the current one the stage's), the event's title under them and its description in the text
-- list (no name: the description moved up), its options (`stage_event_option`, 35 apart);
-- "Stage N" (STAGE_TITLE, N its event's index + 1 [I]); the species panel with the unknown
-- portrait while there are no communications. The leader, progress, difficulty and modifier
-- panels are hidden as the game's frame shows them for a contact without an envoy [I].

local FC_FILE = "interface/first_contact_view.gui"

local function first_contact_window(ctx, fc, items, report, open_ids)
    local loc, db = ctx.loc, ctx.db
    local root = "/first_contact_view"
    local view = fc.view or {}
    local picture = fc.picture or view.picture
    -- the contact's event answered (no longer an open player event): "nothing to report", its
    -- text and options gone (the view's no_report_icon and no_report_text) [I]
    local answered = fc.player_event and not open_ids[fc.player_event]
    local hide = {
        no_report_icon = not answered or nil, no_report_text = not answered or nil, tts_button = true, leader_window = true,
        chapter_progress = true, chapter_difficulty = true, chapter_modifiers = true, block_window = true,
        species = true, species_type = true,
    }
    if answered then
        hide.expedition_window, hide.options_box_container, hide.chapter_subtitle = true, true, true
    end
    local sprites = {}
    if picture and db.sprites[picture] then
        sprites[root .. "/site_type_window/event_picture"] = picture
    else
        hide.event_picture = true
    end
    local stage = loc and loc.raw("STAGE_TITLE") or "Stage $STAGE$"
    stage = stage:gsub("%$STAGE%$", tostring((fc.index or 0) + 1))
    local wi, wr = gui.layout(ctx.game_dir, db, FC_FILE, "first_contact_view", ctx.screen, {
        texture_size = ctx.texture_size, loc = loc, hide = hide, sprites = sprites,
        text = {
            [root .. "/site_name"] = names.format(loc, fc.name),
            [root .. "/chapter_subtitle"] = "§H" .. resolve(loc, view.title or "", view) .. "§!",
            [root .. "/title_chapter/title_text"] = stage,
        },
        actions = {
            [root] = "fc:front",
            [root .. "/close"] = "fc:close",
            [root .. "/goto_site_button"] = fc.location and ("fc:focus:" .. fc.location) or nil,
        },
    })
    gui.merge(items, report, wi, wr)
    -- the stages: the starter, then one a stage, 50 apart [I]
    local box = wr.rects[root .. "/chapters_window/chapters_box"]
    if box then
        for i = 0, (fc.index or 0) do
            local p = "/fc_stages/" .. i
            local path = p .. "/stages_box_entry"
            local si, sr = gui.layout(ctx.game_dir, db, FC_FILE, "stages_box_entry", ctx.screen, {
                texture_size = ctx.texture_size, loc = loc, prefix = p,
                parent = { x = box.x + i * 53, y = box.y, w = 0, h = 0 },
                -- (the current stage without its progress ring in the game's frame [I])
                hide = i == 0 and { chapter_button = true, chapter_progress = true } or { rune_button = true, chapter_progress = true },
            })
            gui.merge(items, report, si, sr)
        end
    end
    -- the description, from the text list's top (no name: moved up to the name's place)
    local list = not answered and wr.rects[root .. "/expedition_window/text_list"]
    if list then
        local desc = resolve(loc, view.desc or "", view)
        local lines, lh = wrap(loc, desc, "cg_16b", 520, db, db.textcolors.W or { 1, 1, 1 })
        local keep = {}
        for i = 1, math.min(#lines, math.floor((list.h - 5) / lh)) do
            keep[i] = lines[i]
        end
        for _, it in ipairs(line_items(root .. "/expedition_window/text_list/description", "cg_16b", keep, lh, list.x + 5, list.y + 5, 520)) do
            items[#items + 1] = it
            report.texts = report.texts + 1
        end
    end
    -- the options
    local ob = not answered and wr.rects[root .. "/options_box_container/options_box"]
    if ob then
        for i, o in ipairs(view.options or {}) do
            local p = "/fc_options/" .. i
            local path = p .. "/stage_event_option"
            local oi, orr = gui.layout(ctx.game_dir, db, FC_FILE, "stage_event_option", ctx.screen, {
                texture_size = ctx.texture_size, loc = loc, prefix = p,
                parent = { x = ob.x, y = ob.y + (i - 1) * 35, w = 0, h = 0 },
                text = { [path .. "/text"] = resolve(loc, o.name or "OK", view) },
                -- (the contact's event is an open player event: the option answers it)
                actions = { [path] = "fc:option:" .. tostring(fc.player_event or -1) .. ":" .. (o.index or i) },
            })
            gui.merge(items, report, oi, orr)
        end
    end
end

-- events.build(game_dir, db, screen, texture_size, loc, data, state) -> items, report
function M.build(game_dir, db, screen, texture_size, loc, data, state)
    local ctx = { game_dir = game_dir, db = db, screen = screen, texture_size = texture_size, loc = loc }
    local items, report = {}, new_report()
    -- the first contact view (under the event windows)
    if state and state.first_contact then
        for _, fc in ipairs(data and data.first_contacts or {}) do
            if fc.id == state.first_contact then
                local open_ids = {}
                for _, ev in ipairs(data.events or {}) do
                    open_ids[ev.id] = true
                end
                local ok, err = pcall(first_contact_window, ctx, fc, items, report, open_ids)
                if not ok then
                    report.missing_sprites[#report.missing_sprites + 1] = "first contact: " .. tostring(err)
                end
            end
        end
    end
    local by_id = {}
    for _, ev in ipairs(data and data.events or {}) do
        by_id[ev.id] = ev
    end
    for k, id in ipairs(state and state.open or {}) do
        local ev = by_id[id]
        if ev then
            local ok, err = pcall(event_window, ctx, ev, k, items, report)
            if not ok then
                report.missing_sprites[#report.missing_sprites + 1] = "event " .. tostring(id) .. ": " .. tostring(err)
            end
        end
    end
    for k, p in ipairs(state and state.popups or {}) do
        local ok, err = pcall(popup, ctx, p, k, items, report)
        if not ok then
            report.missing_sprites[#report.missing_sprites + 1] = "popup: " .. tostring(err)
        end
    end
    return items, report
end

return M
