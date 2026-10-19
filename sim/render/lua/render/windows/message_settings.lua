-- render/windows/message_settings.lua : the message settings an event window's settings button
-- opens (its lambda in CEventWindow::Setup: CMainMenuView::ShowMessageSearchFilter with the
-- event's message type's setting name): the Settings window (interface/settings_view.gui
-- `settings_view`) on its Messages tab (`settings_MESSAGES`), the list filtered by that name.
-- docs/windows/events.md.
--
-- A `message_settings_entry` per message type of common/message_types whose title holds the
-- filter (MESSAGE_<KEY>_TITLE, or its message_setting_key): its notification, toast, popup and
-- auto-pause checkboxes (their frame the state: 1 off, 2 on), defaults from the type's
-- default_notification (yes), default_toast, default_popup, default_autopause (no); a type that
-- cannot be disabled (can_disable = no) has its popup fixed (the game's frame: a click leaves it
-- ticked). A type with hidden_in_message_settings is not listed (the events' other types,
-- EMPIRE_FOCUS, ENCLAVE_DIPLOMACY ...: an event of one shows an empty list [I]). The settings are the renderer's
-- (events.rs keeps them; the game's are the user's settings file): a fired event opens its window
-- when its type's popup is on and pauses the game when its auto-pause is on.

local gui = require("render.gui")
local source = require("stellar.script.source")

local M = {}

local FILE = "interface/settings_view.gui"

local types_cache

local function get(block, key)
    for _, e in ipairs(type(block) == "table" and block or {}) do
        if e.op and e.key and e.key.text == key then
            return e.value.text or e.value
        end
    end
    return nil
end

local function unquote(s)
    return s and (tostring(s):gsub('^"(.*)"$', "%1")) or nil
end

-- the message types, in file order: { key, setting, name, notification, toast, popup, pause,
-- can_disable, hidden }
function M.types(game_dir)
    if types_cache then
        return types_cache
    end
    local out = {}
    for _, f in ipairs(source.files(game_dir, "common/message_types", "txt")) do
        for _, e in ipairs(source.parse(game_dir, f) or {}) do
            if e.op and e.key and e.key.text == "message_type" and e.value.text == nil then
                local b = e.value
                local function yes(k, default)
                    local v = get(b, k)
                    if v == nil then
                        return default
                    end
                    return v == "yes"
                end
                local key = unquote(get(b, "key"))
                if key then
                    out[#out + 1] = {
                        key = key, setting = unquote(get(b, "message_setting_key")), name = unquote(get(b, "name")),
                        hidden = yes("hidden_in_message_settings", false),
                        notification = yes("default_notification", true), toast = yes("default_toast", false),
                        popup = yes("default_popup", false), pause = yes("default_autopause", false),
                        can_disable = yes("can_disable", true),
                    }
                end
            end
        end
    end
    types_cache = out
    return out
end

-- a type's title as the settings list shows it
local function title(loc, t)
    local k = t.setting or t.name or ("MESSAGE_" .. t.key .. "_TITLE")
    if loc and loc.has(k) then
        return (loc.get(k))
    end
    return t.key
end
M.title = title

-- M.build(ctx, settings, filter, applied) -> items, report: settings = { [KEY] = { notification,
-- toast, popup, pause } } (the renderer's, over the defaults), filter = the search text, applied =
-- the settings as the window opened with them
function M.build(ctx, settings, filter, applied)
    local loc, db = ctx.loc, ctx.db
    local items, report = {}, { sprites = 0, texts = 0, missing_sprites = {}, skipped = {}, rects = {} }
    local root = "/settings_view"
    local hide = {
        settings_AUDIO = true, settings_VIDEO = true, settings_GAMEPLAY = true, settings_ACCESSIBILITY = true,
        alert_col_headings = true, empty_results_text = true,
    }
    local changed = next(applied or {}) ~= nil
    local wi, wr = gui.layout(ctx.game_dir, db, FILE, "settings_view", ctx.screen, {
        texture_size = ctx.texture_size, loc = loc, hide = hide,
        -- the Messages tab's button active (frame 2; the file has the video tab's), the messages
        -- sub tab's too
        frames = {
            [root .. "/window/video_button"] = 1,
            [root .. "/window/message_tab_button"] = 2,
            [root .. "/window/settings_MESSAGES/messages_sub_tab"] = 2,
        },
        -- Reset Default: greyed while the applied settings are the defaults (the game's frames: grey
        -- before and after a change not applied yet [I])
        disabled = { [root .. "/window/settings_MESSAGES/reset_message_settings_button"] = not changed or nil },
        actions = {
            [root] = "msgset:noop",
            -- Cancel, Apply & Close, Discard Changes (events.rs keeps the settings of the opening)
            [root .. "/window/BackButton"] = "msgset:cancel",
            [root .. "/window/ApplyButton"] = "msgset:close",
            [root .. "/window/ResetButton"] = "msgset:discard",
            [root .. "/window/settings_MESSAGES/reset_message_settings_button"] = "msgset:reset",
        },
    })
    -- what the game's frame shows that the file leaves to the code: Popup Auto-Unpause ticked
    -- (the game's default setting [I]), the filters' All radios selected (GFX_radio_button frame
    -- 2), the category heading whole (a fixedSize box without maxWidth: the game does not cut it)
    for _, it in ipairs(wi) do
        local p = it.path or ""
        if p:match("/auto_unpause_value$") or p:match("/filter_all_icon$") or p:match("/filter_any_edited_icon$") then
            it.frame = 2
        elseif p:match("/category_title$") then
            it.w = math.max(it.w or 0, 250)
        end
    end
    gui.merge(items, report, wi, wr)
    -- the search box's text (the filter) in the edit box, after its borderSize (46) [I: the edit
    -- box's background is not drawn]
    local sb = wr.rects[root .. "/window/settings_MESSAGES/search_box_container"]
    if sb and filter and filter ~= "" then
        items[#items + 1] = {
            kind = "text", path = root .. "/search_text", font = "cg_16b", text = filter,
            spans = { { text = filter, colour = db.textcolors.W or { 1, 1, 1 } } },
            x = sb.x + 46, y = sb.y + 12, w = 300, h = 20, format = "left", valign = "top",
        }
        report.texts = report.texts + 1
    end
    local lr = wr.rects[root .. "/window/settings_MESSAGES/message_list_container/message_list"]
    if not lr then
        return items, report
    end
    local want = filter and filter:lower() or ""
    local y, n = lr.y, 0
    for _, t in ipairs(M.types(ctx.game_dir)) do
        local name = title(loc, t)
        -- (matched on the title without its scripted parts, [Scope.GetX], which the renderer does
        -- not resolve: the game's resolved titles of the galactic council's types hold no "Event")
        local plain = name:gsub("%b[]", "")
        if not t.hidden and (want == "" or plain:lower():find(want, 1, true)) then
            n = n + 1
            if y + 36 > lr.y + lr.h then
                break
            end
            local s = (settings or {})[t.key] or {}
            local function on(k)
                if s[k] == nil then
                    return t[k]
                end
                return s[k]
            end
            local p = "/msgset/" .. n
            local path = p .. "/message_settings_entry"
            local frames, actions = {}, {}
            for _, k in ipairs({ "notification", "toast", "popup", "pause" }) do
                frames[path .. "/" .. k .. "_checkbox"] = on(k) and 2 or 1
                if not (k == "popup" and not t.can_disable) then
                    actions[path .. "/" .. k .. "_checkbox"] = "msgset:set:" .. t.key .. ":" .. k .. ":" .. (on(k) and "0" or "1")
                end
            end
            local ei, er = gui.layout(ctx.game_dir, db, FILE, "message_settings_entry", ctx.screen, {
                texture_size = ctx.texture_size, loc = loc, prefix = p,
                parent = { x = lr.x, y = y, w = 0, h = 0 },
                -- the edited mark: a setting applied that differs (not while changed only: the
                -- game's frame after a click)
                hide = { edited_icon = next((applied or {})[t.key] or {}) == nil or nil },
                text = { [path .. "/message_title"] = name },
                frames = frames, actions = actions,
            })
            gui.merge(items, report, ei, er)
            y = y + 36
        end
    end
    return items, report
end

-- M.effective(game_dir, key, overrides) -> popup, pause: a message type's popup and auto-pause
-- after the changes (a type that cannot be disabled keeps its popup [I])
function M.effective(game_dir, key, overrides)
    for _, t in ipairs(M.types(game_dir)) do
        if t.key == key then
            local s = overrides and overrides[key] or {}
            local function on(k)
                if s[k] == nil then
                    return t[k]
                end
                return s[k]
            end
            return (on("popup") or not t.can_disable) and true or false, on("pause") and true or false
        end
    end
    return true, false
end

return M
