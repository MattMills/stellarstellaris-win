-- engine/localisation.lua : the game's texts, from localisation/<language>/**/*.yml, read in place.
-- Shared by the engine and the renderer.
--
--   local loc = require("engine.localisation")
--   loc.load(game_dir, "english")
--   loc.get("FRONT_LOAD")          -- "Load Game": $key$ references resolved
--   loc.raw("MULT_POS")            -- "§Gx$VALUE$§!": the text as the file writes it
--   loc.spans(loc.get("MULT_POS")) -- { { text = "x$VALUE$", colour = "G" } }
--
-- The files (Paradox yml): a UTF-8 BOM, the header `l_english:`, then one ` KEY:0 "text"` per
-- line (the number is a version and may be absent), `#` comments. The text runs from the first
-- `"` to the last one on the line; `\n` is a new line and `\"` a quote. Files load in name order,
-- the files of a `replace` folder after the others; a later key replaces an earlier one.
--
-- In a text:
-- - `$KEY$` is another key's text (resolved by get; `$KEY|format$` too), unless KEY is not a
--   key (a value the game fills in at run time, such as `$VALUE$`): that stays as written;
-- - `§X ... §!` colours a part (X a letter of the fonts' textcolors), kept for the renderer:
--   spans() splits a text into { text, colour } parts, colour nil outside any;
-- - `£icon£` is an icon (spans() gives it as { icon = "icon" });
-- - `[ ... ]` is a command the game evaluates (scopes, GetName): kept as text.

local localisation = {
    texts = {},      -- key -> text as written
    language = nil,
    files = 0,
    keys = 0,
    seconds = 0,
}

local WINDOWS = package.config:sub(1, 1) == "\\"

-- the .yml files under dir, recursively, sorted (the replace folder's last): the platform's
-- RUST.list_files, or the shell's listing in a Lua state without it
local function yml_files(dir)
    local out = {}
    local cmd
    if RUST and RUST.list_files then
        for _, rel in ipairs(RUST.list_files(dir, ".", "yml")) do
            out[#out + 1] = dir .. "/" .. rel:gsub("^%./", "")
        end
    elseif WINDOWS then
        cmd = 'dir /s /b "' .. dir:gsub("/", "\\") .. '\\*.yml" 2>nul'
    else
        cmd = "find '" .. dir .. "' -name '*.yml' -type f 2>/dev/null"
    end
    local p = cmd and io.popen(cmd)
    if p then
        for line in p:lines() do
            line = line:gsub("\r$", ""):gsub("\\", "/")
            if line ~= "" then
                out[#out + 1] = line
            end
        end
        p:close()
    end
    table.sort(out, function(a, b)
        local ra, rb = a:find("/replace/", 1, true) ~= nil, b:find("/replace/", 1, true) ~= nil
        if ra ~= rb then
            return rb
        end
        return a < b
    end)
    return out
end

local function unescape(s)
    return (s:gsub("\\(.)", function(c)
        if c == "n" then
            return "\n"
        end
        return c
    end))
end

-- reads one file into texts; returns the number of keys
local function read_file(path, texts)
    local f = io.open(path, "rb")
    if not f then
        return 0
    end
    local data = f:read("*a")
    f:close()
    if data:sub(1, 3) == "\239\187\191" then
        data = data:sub(4)
    end
    local n = 0
    for line in data:gmatch("[^\n]+") do
        -- ` KEY:0 "text"` (a header line `l_english:` has no quote)
        local key, rest = line:match("^%s*([%w_%.%-@']+):%d*%s*(\".*)$")
        if key then
            local last = rest:match('^.*()"')
            if last and last > 1 then
                texts[key] = unescape(rest:sub(2, last - 1))
                n = n + 1
            end
        end
    end
    return n
end

-- localisation.load(game_dir, language) -> number of keys
function localisation.load(game_dir, language)
    language = language or "english"
    local t0 = os.clock()
    local texts = {}
    local files = yml_files(game_dir .. "/localisation/" .. language)
    local n = 0
    for _, path in ipairs(files) do
        n = n + read_file(path, texts)
    end
    localisation.texts, localisation.language = texts, language
    localisation.files = #files
    local keys = 0
    for _ in pairs(texts) do
        keys = keys + 1
    end
    localisation.keys = keys
    localisation.seconds = os.clock() - t0
    return keys
end

function localisation.has(key)
    return localisation.texts[key] ~= nil
end

-- the text as the file writes it, or nil
function localisation.raw(key)
    return localisation.texts[key]
end

-- the scripted localisations (common/scripted_loc `defined_text`, render/scripted_loc.lua):
-- name -> the key chosen for the current scope (set by a view from what its extract evaluated),
-- and name -> the text's `default`
localisation.scripted, localisation.scripted_default = {}, {}

-- a text with its $KEY$ references (to a depth of 8) and its [Name] scripted localisations
-- (CScriptedLocalisation: the key whose trigger holds, else the default) resolved; keys and names
-- that are neither stay
local function resolve(text, depth)
    if depth > 8 then
        return text
    end
    if text:find("$", 1, true) then
        text = text:gsub("%$([^$\n]+)%$", function(ref)
            local key = ref:match("^([^|]+)") or ref
            local t = localisation.texts[key]
            if t then
                return resolve(t, depth + 1)
            end
            return nil
        end)
    end
    if text:find("[", 1, true) then
        -- a pop job's commands (CPopJobType: [technician.GetName], .GetNamePlural, .GetIcon): its
        -- name keys job_X / job_X_plural, its icon £job_X£ [I: the swappable names (a gestalt's
        -- or a swap_type's) not chosen]
        text = text:gsub("%[([%w_]+)%.(Get%w+)%]", function(job, cmd)
            local key = "job_" .. job
            if not localisation.texts[key] then
                return nil
            end
            if cmd == "GetName" then
                return resolve(localisation.texts[key], depth + 1)
            elseif cmd == "GetNamePlural" then
                return resolve(localisation.texts[key .. "_plural"] or localisation.texts[key], depth + 1)
            elseif cmd == "GetIcon" then
                return "\194\163" .. key .. "\194\163"
            end
            return nil
        end)
        text = text:gsub("%[([%w_]+)%]", function(name)
            local key = localisation.scripted[name] or localisation.scripted_default[name]
            local t = key and localisation.texts[key]
            if t then
                return resolve(t, depth + 1)
            end
            return nil
        end)
    end
    return text
end
localisation.resolve = function(text)
    return resolve(text, 0)
end

-- localisation.get(key) -> the key's text, references resolved; the key itself if there is none
-- (as the game shows a missing key), and whether it was found
function localisation.get(key)
    local t = localisation.texts[key]
    if t == nil then
        return key, false
    end
    return resolve(t, 0), true
end

-- localisation.spans(text) -> { { text = "...", colour = "G" | nil } | { icon = "pop" } }: the
-- text split at its colour codes (§X opens a colour, §! closes the innermost) and icons
function localisation.spans(text)
    local out, stack = {}, {}
    local buf = {}
    local function flush()
        if #buf > 0 then
            out[#out + 1] = { text = table.concat(buf), colour = stack[#stack] }
            buf = {}
        end
    end
    local i, n = 1, #text
    while i <= n do
        local c = text:sub(i, i + 1)
        if c == "\194\167" then   -- §, two bytes in UTF-8
            flush()
            local code = text:sub(i + 2, i + 2)
            if code == "!" then
                stack[#stack] = nil
            elseif code ~= "" then
                stack[#stack + 1] = code
            end
            i = i + 3
        elseif c == "\194\163" then   -- £icon£
            local j = text:find("\194\163", i + 2, true)
            if j then
                flush()
                local icon = text:sub(i + 2, j - 1):match("^([^|]*)")
                out[#out + 1] = { icon = icon, colour = stack[#stack] }
                i = j + 2
            else
                buf[#buf + 1] = c
                i = i + 2
            end
        else
            buf[#buf + 1] = text:sub(i, i)
            i = i + 1
        end
    end
    flush()
    return out
end

-- localisation.plain(text) -> the text without colour codes and icons
function localisation.plain(text)
    local parts = {}
    for _, s in ipairs(localisation.spans(text)) do
        if s.text then
            parts[#parts + 1] = s.text
        end
    end
    return table.concat(parts)
end

return localisation
