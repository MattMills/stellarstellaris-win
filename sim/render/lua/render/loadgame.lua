-- render/loadgame.lua : the main menu's Load Game window (interface/loadgame_view.gui) filled from
-- the saves as the game's CLoadGameView fills it: one LoadGameSessionEntry per session (a save
-- folder), its newest save's empire name, date, file, flag, ruler portrait frame, ironman and
-- incompatible markers, cloud state; the selected session's details (selected_window) with its
-- own list of saves (LoadSaveGameEntry); the delete toggle.
--
--   local lg = require("render.loadgame")
--   lg.build(game_dir, db, screen, texture_size, loc, saves) -> { items, report }
--   lg.act(action) -> the path of the save to load, or nil ("loadwin:..." actions)
--
-- saves: { { name, date, file, path, dir, meta, modified } } (app.rs list_saves). The state
-- (selected session and save, the delete toggle) is RENDER_LOAD.
--
-- What the game's frames show (4.5.2, headless at the main menu with test saves; the notes in
-- docs/windows/loadgame.md):
-- - a session is a folder of saves; sessions newest first by their newest file's time, and an
--   entry shows that newest save (its meta's name and date, the file's name) [V];
-- - `ironman = yes` in the meta shows ironman_icon [V: a save with it only in the meta shows it,
--   one with it only in the gamestate does not];
-- - incompatible_save when the save's version is under 4.5 or over the game's
--   (SSaveGameMetaData::CheckIsBadVersion @0x1f1b8f0: CVersionNumber { 4, 5 }) [V];
-- - cloud_file's first frame (a local file, not in the cloud) on every entry [V];
-- - the first session selected when the window opens, its overlay lit, no save selected (Load
--   Selected greyed) [V];
-- - the delete toggle in its third frame while on, each entry's Load Latest Save replaced by its
--   delete button, each save's delete button shown [V].
-- The ruler's portrait is a 3D portrait (CPortraitObject::SetPortrait with the meta's
-- player_portrait): not drawn; its background (leader_type_bg) and frame are [stand-in].

local gui = require("render.gui")
local get = require("render.gfx").get
local widgets = require("render.newgame_widgets")

local lg = {}

local FILE = "interface/loadgame_view.gui"

-- a meta's fields: { name, date, version, portrait, flag, fleets, planets, ironman, dlcs }
local function parse_meta(text)
    local ok, pdx = pcall(require, "pdxscript")
    local tree = ok and pdx.parse(text or "", "meta") or {}
    local m = { dlcs = {} }
    local function words(block)
        local out = {}
        for _, e in ipairs(type(block) == "table" and block or {}) do
            if e.text then
                out[#out + 1] = (e.text:gsub('^"(.*)"$', "%1"))
            end
        end
        return out
    end
    local function str(v)
        return type(v) == "string" and (v:gsub('^"(.*)"$', "%1")) or nil
    end
    m.name = str(get(tree, "name")) or ""
    m.date = str(get(tree, "date")) or ""
    m.version = str(get(tree, "version")) or ""
    m.portrait = str(get(tree, "player_portrait"))
    m.fleets = tonumber(get(tree, "meta_fleets"))
    m.planets = tonumber(get(tree, "meta_planets"))
    m.ironman = get(tree, "ironman") == "yes"
    m.dlcs = words(get(tree, "required_dlcs"))
    local f = get(tree, "flag")
    if type(f) == "table" then
        local function part(k)
            local p = get(f, k)
            return type(p) == "table" and { category = str(get(p, "category")), file = str(get(p, "file")) } or nil
        end
        m.flag = { icon = part("icon") or {}, background = part("background") or {}, colors = words(get(f, "colors")) }
    end
    return m
end

-- "Cygnus v4.5.2" -> { 4, 5, 2 }
local function version_of(s)
    local v = {}
    local digits = tostring(s):match("v(%d[%d%.]*)") or tostring(s):match("(%d+%.%d[%d%.]*)") or ""
    for n in digits:gmatch("%d+") do
        v[#v + 1] = tonumber(n)
    end
    return v
end
local function less(a, b)
    for i = 1, math.max(#a, #b) do
        local x, y = a[i] or 0, b[i] or 0
        if x ~= y then
            return x < y
        end
    end
    return false
end

-- the game's version (launcher-settings.json's rawVersion or version)
local game_version
local function game_version_of(game_dir)
    if game_version == nil then
        local f = io.open(game_dir .. "/launcher-settings.json", "rb")
        local text = f and f:read("*a") or ""
        if f then
            f:close()
        end
        game_version = version_of(text:match('"rawVersion"%s*:%s*"([^"]*)"') or text:match('"version"%s*:%s*"([^"]*)"') or "")
    end
    return game_version
end

-- CheckIsBadVersion: under 4.5, or newer than the game
local function bad_version(game_dir, v)
    local sv = version_of(v)
    if #sv == 0 then
        return false
    end
    return less(sv, { 4, 5 }) or less(game_version_of(game_dir), sv)
end

-- the saves into sessions: { { dir, saves = { newest first } } }, newest session first. A session
-- is a folder (its name, in lower case: BuildSessionsList); both sorts are the game's stable
-- descending sorts by the file's time in whole seconds (DescendingFileDateSort,
-- DescendingFileDateGameSessionSort), so saves of the same second keep the order they came in
-- (the directory's) [V: the frames]
local function sessions_of(saves)
    local by, out = {}, {}
    for i, s in ipairs(saves) do
        s.order = i
        local k = (((s.dir or ""):gsub(string.char(92), "/")):match("([^/]*)/*$") or ""):lower()
        if not by[k] then
            by[k] = { dir = s.dir, saves = {} }
            out[#out + 1] = by[k]
            by[k].order = #out
        end
        local list = by[k].saves
        list[#list + 1] = s
    end
    local function newer(a, b)
        local ta, tb = math.floor(a.modified or 0), math.floor(b.modified or 0)
        if ta ~= tb then
            return ta > tb
        end
        return a.order < b.order
    end
    for _, ss in ipairs(out) do
        table.sort(ss.saves, newer)
    end
    table.sort(out, function(a, b)
        local ta, tb = math.floor(a.saves[1].modified or 0), math.floor(b.saves[1].modified or 0)
        if ta ~= tb then
            return ta > tb
        end
        return a.order < b.order
    end)
    return out
end

local function state()
    RENDER_LOAD = RENDER_LOAD or { session = 1, delete = false }
    return RENDER_LOAD
end

-- an empire flag on a flag element's sprite (render.empire_preview's composition)
local function set_flag(ctx, items, path, sprite, flag)
    if not flag then
        return
    end
    local ok, preview = pcall(require, "render.empire_preview")
    local tex = ok and preview.flag_texture(ctx, sprite, flag)
    for _, it in ipairs(tex and items or {}) do
        if it.path == path and it.kind == "sprite" then
            it.texture = tex
            it.sprite_kind = "flagSpriteType"
            it.frames, it.frame = 1, 1
        end
    end
end

local function count(n)
    return n and string.format("%d", n) or ""
end

function lg.build(game_dir, db, screen, texture_size, loc, saves)
    local st = state()
    for _, s in ipairs(saves) do
        s.m = s.m or parse_meta(s.meta)
    end
    local sessions = sessions_of(saves)
    st.sessions = sessions
    if not sessions[st.session] then
        st.session, st.save = 1, nil
    end
    local sel = sessions[st.session]
    local ctx = { game_dir = game_dir, db = db, texture_size = texture_size, loc = loc }
    local S = "/LoadGameScreen"
    local W = S .. "/selected_window"
    local opts = {
        texture_size = texture_size, loc = loc,
        hide = { syncing_label = true, [W .. "/portrait_window/portrait"] = true },
        text = {}, frames = {}, disabled = {},
        actions = {
            [S .. "/hide"] = "close_load", [S .. "/delete_toggle"] = "loadwin:delete",
            [W .. "/load_selected"] = "loadwin:load_selected",
        },
    }
    opts.frames[S .. "/delete_toggle"] = st.delete and 3 or nil
    if #sessions > 0 then
        opts.hide.nosaves_label = true
    end
    if not sel then
        opts.hide.selected_window = true
    else
        local top = sel.saves[1]
        opts.text[W .. "/name"] = top.m.name ~= "" and top.m.name or top.name
        opts.text[W .. "/date"] = top.m.date ~= "" and top.m.date or top.date
        opts.text[W .. "/fleets"] = count(top.m.fleets)
        opts.text[W .. "/planets"] = count(top.m.planets)
        if not (st.save and sel.saves[st.save]) then
            opts.disabled[W .. "/load_selected"] = true
        end
    end
    local items, report = gui.layout(game_dir, db, FILE, "LoadGameScreen", screen, opts)
    if sel then
        set_flag(ctx, items, W .. "/flag", "GFX_empire_flag_128", sel.saves[1].m.flag)
    end
    local out = { items = items, report = report }

    -- the sessions: LoadGameSessionEntry rows, spacing -5 (a row every 97 pixels)
    local list = report.rects[S .. "/list"]
    local entry = gui.find(game_dir, FILE, "LoadGameSessionEntry")
    local esize = entry and get(entry, "size")
    local eh = tonumber(esize and get(esize, "height")) or 102
    local shown = 0
    if list then
        widgets.clip(items, list)
        for i, ss in ipairs(sessions) do
            local y = list.y + (i - 1) * (eh - 5)
            if y >= list.y + list.h then
                break
            end
            shown = i
            local top = ss.saves[1]
            local p = S .. "/list/" .. i
            local E = p .. "/LoadGameSessionEntry"
            local eopts = {
                texture_size = texture_size, loc = loc, prefix = p,
                parent = { x = list.x, y = y, w = list.w, h = eh },
                hide = {
                    [E .. "/portrait_window/portrait"] = true,
                    [E .. "/selected_overlay"] = i ~= st.session,
                    [E .. "/ironman_icon"] = not top.m.ironman,
                    [E .. "/incompatible_save"] = not bad_version(game_dir, top.m.version),
                    [E .. "/delete"] = not st.delete,
                    [E .. "/load_latest"] = st.delete,
                },
                text = {
                    [E .. "/name"] = top.m.name ~= "" and top.m.name or top.name,
                    [E .. "/date"] = top.m.date ~= "" and top.m.date or top.date,
                    [E .. "/save_name"] = top.file,
                },
                frames = { [E .. "/cloud_file"] = 1 },
                actions = {
                    [E .. "/select"] = "loadwin:session:" .. i,
                    [E .. "/load_latest"] = "loadwin:latest:" .. i,
                    [E .. "/delete"] = "loadwin:delete_session:" .. i,
                },
            }
            local it, r = gui.layout(game_dir, db, FILE, "LoadGameSessionEntry", screen, eopts)
            set_flag(ctx, it, E .. "/flag", "GFX_empire_flag_64", top.m.flag)
            gui.merge(items, report, it, r)
        end
        widgets.unclip(items)
    end
    report.saves_shown = shown

    -- the selected session's saves: LoadSaveGameEntry rows, spacing -4
    local slist = report.rects[W .. "/list"]
    local sentry = gui.find(game_dir, FILE, "LoadSaveGameEntry")
    local ssize = sentry and get(sentry, "size")
    local sw = tonumber(ssize and get(ssize, "width")) or 581
    local sh = tonumber(ssize and get(ssize, "height")) or 58
    if sel and slist then
        widgets.clip(items, slist)
        for i, s in ipairs(sel.saves) do
            local y = slist.y + (i - 1) * (sh - 4)
            if y >= slist.y + slist.h then
                break
            end
            local p = W .. "/list/" .. i
            local E = p .. "/LoadSaveGameEntry"
            local sopts = {
                texture_size = texture_size, loc = loc, prefix = p,
                -- (the entry is `orientation = center`: its parent's centre is the slot's corner
                -- plus half the entry)
                parent = { x = slist.x - sw / 2, y = y - sh / 2, w = sw, h = sh },
                hide = {
                    [E .. "/selected_overlay"] = i ~= st.save,
                    [E .. "/ironman_icon"] = not s.m.ironman,
                    [E .. "/incompatible_save"] = not bad_version(game_dir, s.m.version),
                    [E .. "/delete"] = not st.delete,
                },
                text = {
                    [E .. "/name"] = (s.file or ""):gsub("%.sav$", ""),
                    [E .. "/date"] = s.m.date ~= "" and s.m.date or s.date,
                    [E .. "/filename"] = s.file,
                    [E .. "/fleets"] = count(s.m.fleets),
                    [E .. "/planets"] = count(s.m.planets),
                },
                frames = { [E .. "/cloud_file"] = 1 },
                actions = {
                    [E .. "/select"] = "loadwin:save:" .. i,
                    [E .. "/delete"] = "loadwin:delete_save:" .. i,
                },
            }
            local it, r = gui.layout(game_dir, db, FILE, "LoadSaveGameEntry", screen, sopts)
            gui.merge(items, report, it, r)
        end
        widgets.unclip(items)
    end
    return out
end

-- an action: the save to load, or nil
function lg.act(action)
    local st = state()
    local verb, arg = action:match("^loadwin:([%w_]+):?(.*)$")
    local i = tonumber(arg)
    local sessions = st.sessions or {}
    if verb == "open" then
        RENDER_LOAD = { session = 1, delete = false, sessions = st.sessions }
    elseif verb == "session" and i then
        st.session, st.save = i, nil
    elseif verb == "save" and i then
        st.save = i
    elseif verb == "delete" then
        st.delete = not st.delete
    elseif verb == "latest" and i then
        local ss = sessions[i]
        return ss and ss.saves[1] and ss.saves[1].path or nil
    elseif verb == "load_selected" then
        local ss = sessions[st.session]
        local s = ss and st.save and ss.saves[st.save]
        return s and s.path or nil
    end
    -- (delete_session, delete_save: the game asks, then deletes the files; not done here)
    return nil
end

return lg
