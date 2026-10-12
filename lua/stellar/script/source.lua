-- source.lua : the game's script files as the game reads them, parsed with pdxscript
-- (lib/stellar-lua-pdxscript): the game directory with the enabled mods over it, inline scripts
-- expanded, scripted triggers, effects and values instantiated.
--
--   local source = require("stellar.script.source")
--   local fs = source.filesystem(game_dir, source.enabled_mods(documents_dir))
--   local files = source.files(fs, "common/scripted_triggers", "txt")  -- sorted relative paths
--   local tree = source.parse(fs, "events/x.txt")
--   local defs, errors = source.definitions(fs, "common/scripted_triggers")
--   defs[name] = { block, file, line, ... }: the top-level `name = { ... }` of every file of the
--   directory, in load order (files sorted by name; a later definition replaces an earlier one).
-- Where a function takes `fs`, the game directory (a string) means the game without mods.

local pdxscript = require("pdxscript")

local source = {}

-- The names of the files in a directory (not recursive).
local list_directory
local has_ffi, ffi = pcall(require, "ffi")
if has_ffi and ffi.os == "Windows" then
    ffi.cdef [[
        typedef struct {
            uint32_t dwFileAttributes;
            uint32_t ftCreationTime[2], ftLastAccessTime[2], ftLastWriteTime[2];
            uint32_t nFileSizeHigh, nFileSizeLow, dwReserved0, dwReserved1;
            char cFileName[260];
            char cAlternateFileName[14];
        } stellar_WIN32_FIND_DATAA;
        void *FindFirstFileA(const char *pattern, stellar_WIN32_FIND_DATAA *data);
        int FindNextFileA(void *find, stellar_WIN32_FIND_DATAA *data);
        int FindClose(void *find);
    ]]
    local DIRECTORY = 0x10
    list_directory = function(dir)
        local data = ffi.new("stellar_WIN32_FIND_DATAA")
        local find = ffi.C.FindFirstFileA((dir:gsub("/", "\\")) .. "\\*", data)
        local names = {}
        if tonumber(ffi.cast("intptr_t", find)) == -1 then
            return names
        end
        repeat
            if bit.band(data.dwFileAttributes, DIRECTORY) == 0 then
                names[#names + 1] = ffi.string(data.cFileName)
            end
        until ffi.C.FindNextFileA(find, data) == 0
        ffi.C.FindClose(find)
        return names
    end
else
    list_directory = function(dir)
        local names = {}
        local p = io.popen("ls -1p '" .. dir .. "' 2>/dev/null")
        if p then
            for line in p:lines() do
                if not line:find("/$") then
                    names[#names + 1] = line
                end
            end
            p:close()
        end
        return names
    end
end

-- source.filesystem(game_dir [, mods]) -> fs: the files as the game sees them: the game directory,
-- then each mod in load order ({ path = dir, replace = { ["common/x"] = true }, name }, from
-- source.enabled_mods). A file of a later mod replaces the file with the same path, and a mod's
-- replace_path hides the files before it in that directory.
local FS = {}
FS.__index = FS

function source.filesystem(game_dir, mods)
    local roots = { { path = game_dir, name = "vanilla" } }
    for _, mod in ipairs(mods or {}) do
        roots[#roots + 1] = mod
    end
    return setmetatable({ game_dir = game_dir, roots = roots }, FS)
end

-- a game directory (a string) is the filesystem of the game without mods
local function filesystem_of(fs)
    if type(fs) == "string" then
        return source.filesystem(fs)
    end
    return fs
end
source.filesystem_of = filesystem_of

local function exists(path)
    local f = io.open(path, "rb")
    if f then
        f:close()
        return true
    end
    return false
end

local function dirname(path)
    return path:match("^(.*)/[^/]*$") or ""
end

-- fs:path(relative) -> the file the game reads for this path, or nil
function FS:path(relative)
    for i = #self.roots, 1, -1 do
        local root = self.roots[i]
        local path = root.path .. "/" .. relative
        if exists(path) then
            return path
        end
        if root.replace and root.replace[dirname(relative)] then
            return nil
        end
    end
end

-- fs:files(subdir [, extension]) -> the relative paths of the subdir's files (not recursive) with
-- the extension, sorted by name (the game loads a directory in name order)
function FS:files(subdir, extension)
    local names, seen = {}, {}
    for _, root in ipairs(self.roots) do
        if root.replace and root.replace[subdir] then
            names, seen = {}, {}
        end
        for _, name in ipairs(list_directory(root.path .. "/" .. subdir)) do
            local key = name:lower()
            if not seen[key] and (extension == nil or key:sub(-#extension - 1) == "." .. extension) then
                seen[key] = true
                names[#names + 1] = name
            end
        end
    end
    table.sort(names)
    for i, name in ipairs(names) do
        names[i] = subdir .. "/" .. name
    end
    return names
end

-- source.enabled_mods(documents_dir) -> mods | nil, message: the mods the game loads, in order,
-- from documents_dir/dlc_load.json (written by the launcher) and their descriptors
-- (documents_dir/mod/*.mod: path, replace_path); for source.filesystem.
function source.enabled_mods(documents_dir)
    local f, message = io.open(documents_dir .. "/dlc_load.json", "rb")
    if f == nil then
        return nil, message
    end
    local json = f:read("*a")
    f:close()
    local list = json:match('"enabled_mods"%s*:%s*%[(.-)%]')
    local mods = {}
    for descriptor in (list or ""):gmatch('"([^"]+)"') do
        local tree, err = source.parse(documents_dir, descriptor)
        if tree == nil then
            return nil, descriptor .. ": " .. tostring(err)
        end
        local mod = { descriptor = descriptor, replace = {} }
        for _, e in ipairs(tree) do
            local key, value = e.key and e.key.text, e.value and e.value.text
            if key == "path" or key == "archive" then
                mod[key] = value
            elseif key == "name" then
                mod.name = value
            elseif key == "replace_path" and value then
                mod.replace[(value:gsub("\\", "/"):gsub("/$", ""))] = true
            end
        end
        if mod.path == nil then
            return nil, descriptor .. ": no path" .. (mod.archive and " (zipped mods are not read)" or "")
        end
        mod.path = mod.path:gsub("\\", "/")
        if not mod.path:find("^%a:") and not mod.path:find("^/") then
            mod.path = documents_dir .. "/" .. mod.path
        end
        mods[#mods + 1] = mod
    end
    return mods
end

-- source.game_filesystem(game_dir [, documents_dir]) -> fs, mods, message: the game directory with
-- the mods the launcher enabled (documents_dir: %USERPROFILE%/Documents/Paradox
-- Interactive/Stellaris by default); without them (and a message) when they cannot be read.
function source.game_filesystem(game_dir, documents_dir)
    documents_dir = documents_dir or ((os.getenv("USERPROFILE") or ""):gsub("\\", "/")
        .. "/Documents/Paradox Interactive/Stellaris")
    local mods, message = source.enabled_mods(documents_dir)
    return source.filesystem(game_dir, mods), mods or {}, message
end

-- source.files(fs, subdir, extension) -> fs:files(subdir, extension)
function source.files(fs, subdir, extension)
    return filesystem_of(fs):files(subdir, extension)
end

local function read_file(path)
    local f, message = io.open(path, "rb")
    if f == nil then
        return nil, message
    end
    local text = f:read("*a")
    f:close()
    return text
end

-- source.parse(fs, relative) -> tree | nil, message: the file the game reads for this path
function source.parse(fs, relative)
    local path = filesystem_of(fs):path(relative)
    if path == nil then
        return nil, relative .. ": no such file"
    end
    local text, message = read_file(path)
    if text == nil then
        return nil, message
    end
    return pdxscript.parse(text, relative)
end

-- Scripted triggers, effects and values are templates (CMetaScriptTemplate): the game reads the
-- text of a definition once, and for a call it rewrites that text with the call's arguments and
-- parses the result. The rewriting, in order:
--   1. parameter blocks: `[[NAME] content ]` becomes its content when the call gives NAME, and
--      `[[!NAME] content ]` when it does not; otherwise the block is removed, newlines and all,
--      so the lines after it move up (the game's line numbers are those of the rewritten text);
--   2. arguments: `$NAME$` becomes the argument and `$NAME|default$` the default when the call
--      does not give NAME;
--   3. escapes: `\[`, `\]`, `\|` and `\$` become `[`, `]`, `|` and `$`.
-- As the game does it (4.5.2: CMetaScriptTemplate::Read, ParseForMacrosArguments,
-- ProcessSourceForMacros, ParseForArguments, GenerateSource), which is not quite what the
-- syntax suggests:
--   - The text it keeps is the definition's tokens written out again: comments are gone and
--     inline math (`@[ ]`) is already evaluated, so brackets in those do nothing. Brackets in
--     quoted strings count.
--   - Any `[` that does not follow a backslash starts a block, not only `[[`. Its name is the text
--     from two characters after it to the next `]`, and the block ends at the `]` after that one.
--     So `log = "AI [This.GetName] in [GetYear]"` loses `[This.GetName] in [GetYear]` (a block
--     named "his.GetName", which no call gives); vanilla writes `\[` in such strings.
--   - Blocks do not nest: a block ends at the first `]` after its name, and the next block is
--     looked for after it. A block without its closing `]` ends the search ("Invalid macro
--     entry" in the game's log).
--   - `$` pair up in order, whatever is between them.
-- Inline scripts are not templates: the game only replaces `$NAME$` with each parameter in
-- their text (source.expand).

-- The position of the first c at or after i that does not follow a backslash, or nil.
local function find_unescaped(text, c, i)
    while true do
        local j = text:find(c, i, true)
        if j == nil or j == 1 or text:byte(j - 1) ~= 92 then
            return j
        end
        i = j + 1
    end
end

-- The text with its comments blanked (newlines kept, so positions and lines do not change), and
-- the spans ({ first, last }) of its quoted strings and of its inline math.
local function scan(text)
    local out, strings, maths = {}, {}, {}
    local n, i, last = #text, 1, 1
    while true do
        local j = text:find('["#@]', i)
        if j == nil then
            break
        end
        local c = text:byte(j)
        if c == 34 then
            local k = j + 1
            while k <= n do
                local d = text:byte(k)
                if d == 92 then
                    k = k + 2
                elseif d == 34 then
                    break
                else
                    k = k + 1
                end
            end
            strings[#strings + 1] = { j, k }
            i = k + 1
        elseif c == 35 then
            local k = (text:find("\n", j, true) or n + 1) - 1
            out[#out + 1] = text:sub(last, j - 1)
            out[#out + 1] = string.rep(" ", k - j + 1)
            last, i = k + 1, k + 1
        elseif text:byte(j + 1) == 91 then
            local k = text:find("]", j, true) or n
            maths[#maths + 1] = { j, k }
            i = k + 1
        else
            i = j + 1
        end
    end
    out[#out + 1] = text:sub(last)
    return table.concat(out), strings, maths
end

-- source.template(text) -> { text, blocks }: a definition's text as the game keeps it (comments
-- blanked) and its parameter blocks, { first, last, name, negated, content } with first and last
-- the positions of the block's `[` and closing `]`.
function source.template(text)
    local strings, maths
    text, strings, maths = scan(text)
    -- where blocks are looked for: the text without its inline math
    local view = text
    if #maths > 0 then
        local parts, last = {}, 1
        for _, m in ipairs(maths) do
            parts[#parts + 1] = text:sub(last, m[1] - 1)
            parts[#parts + 1] = text:sub(m[1], m[2]):gsub("[^\n]", " ")
            last = m[2] + 1
        end
        parts[#parts + 1] = text:sub(last)
        view = table.concat(parts)
    end
    local blocks, i, s = {}, 1, 1
    while true do
        local open = find_unescaped(view, "[", i)
        local header = open and find_unescaped(view, "]", open + 1)
        local close = header and find_unescaped(view, "]", header + 1)
        if close == nil then
            break
        end
        while strings[s] and strings[s][2] < open do
            s = s + 1
        end
        local name, negated = text:sub(open + 2, header - 1), false
        if strings[s] and strings[s][1] < open then
            -- in a string, as it is: `!` two characters after the `[`
            if name:sub(2, 2) == "!" then
                name, negated = name:sub(4), true
            end
        elseif text:byte(open + 1) == 91 then
            -- in the tokens `[[`, `!` and `NAME]`, written out as `[[ ! NAME]`
            local after = name:match("^%s*!%s*(.*)$")
            if after then
                name, negated = after, true
            end
        end
        blocks[#blocks + 1] = { first = open, last = close, name = name, negated = negated,
            content = text:sub(header + 1, close - 1) }
        i = close + 1
    end
    return { text = text, blocks = blocks }
end

-- `$NAME$` and `$NAME|default$` in text, from params (name -> text); without an argument or a
-- default they stay as written.
local function substitute(text, params)
    local out, i = {}, 1
    while true do
        local a = find_unescaped(text, "$", i)
        local b = a and find_unescaped(text, "$", a + 1)
        if b == nil then
            break
        end
        local bar = find_unescaped(text, "|", a + 1)
        if bar and bar > b then
            bar = nil
        end
        local value = params[text:sub(a + 1, (bar or b) - 1)]
        if value == nil and bar then
            value = text:sub(bar + 1, b - 1)
        end
        out[#out + 1] = text:sub(i, a - 1)
        out[#out + 1] = value or text:sub(a, b)
        i = b + 1
    end
    out[#out + 1] = text:sub(i)
    return table.concat(out)
end

-- source.generate(template, params) -> text: a template (source.template) rewritten for a call
-- with these arguments (name -> text), as the game parses it.
function source.generate(template, params)
    local out, i, text = {}, 1, template.text
    for _, b in ipairs(template.blocks) do
        out[#out + 1] = text:sub(i, b.first - 1)
        if (params[b.name] ~= nil) ~= b.negated then
            out[#out + 1] = b.content
        end
        i = b.last + 1
    end
    out[#out + 1] = text:sub(i)
    return (substitute(table.concat(out), params):gsub("\\([%[%]|%$])", "%1"))
end

-- Every `find` in text replaced with value, as it is.
local function replace_all(text, find, value)
    local out, i = {}, 1
    while true do
        local a, b = text:find(find, i, true)
        if a == nil then
            break
        end
        out[#out + 1] = text:sub(i, a - 1)
        out[#out + 1] = value
        i = b + 1
    end
    out[#out + 1] = text:sub(i)
    return table.concat(out)
end

-- source.expand(fs, block) -> block: the block with its `inline_script` statements replaced
-- by the entries of the inline scripts, as the game reads them: common/inline_scripts/<script>.txt
-- with `$NAME$` replaced by each parameter in turn (no parameter blocks, no defaults: the game
-- does not handle them there), parsed, and expanded in turn.
--   inline_script = "jobs/soldiers_add"
--   inline_script = { script = jobs/soldiers_add  AMOUNT = 2  TRIGGER = "owner? = { ... }" }
-- Nested blocks are expanded too. The entries an inline script adds have `inline`, the location
-- the game gives that content without its line: where is that of the expanded text ("file:
-- events/x.txt" for a file), and an inline script whose statement ends at line 12 of it (the '}'
-- of `inline_script = { ... }`) adds `inline` = "file: events/x.txt:12(inline_script)
-- common/inline_scripts/y.txt" (then " line: 3" in the game's locations; inline scripts in inline
-- scripts make a chain). Errors (a missing script, a parse error) are collected in errors and the
-- statement is dropped.
function source.expand(fs, block, errors, depth, where)
    fs = filesystem_of(fs)
    depth = depth or 0
    where = where or "?"
    local out = { line = block.line, type = block.type, name = block.name, warnings = block.warnings }
    for _, e in ipairs(block) do
        if e.op and e.key and e.key.text:lower() == "inline_script" and depth < 32 then
            local script, params = nil, {}
            if e.value.text then
                script = e.value.text
            else
                for _, p in ipairs(e.value) do
                    if p.op and p.key then
                        local value = p.value.text or pdxscript.write(p.value)
                        if p.key.text:lower() == "script" then
                            script = value
                        else
                            params[#params + 1] = { p.key.text, value }
                        end
                    end
                end
            end
            local file = "common/inline_scripts/" .. tostring(script) .. ".txt"
            local path = fs:path(file)
            local text, message
            if path then
                text, message = read_file(path)
            else
                message = "no such file"
            end
            local tree
            if text then
                for _, p in ipairs(params) do
                    text = replace_all(text, "$" .. p[1] .. "$", p[2])
                end
                tree, message = pdxscript.parse(text, file)
            end
            if tree == nil then
                if errors then
                    errors[#errors + 1] = string.format("line %d: inline_script %s: %s", e.line,
                        tostring(script), tostring(message))
                end
            else
                -- the game places the call where its statement ends: `inline_script = { ... }` at
                -- the line of its '}'
                local call_line = e.value.text == nil and e.value.last or e.line
                local inner_where = string.format("%s:%d(inline_script) %s", where, call_line, file)
                for _, inner in ipairs(source.expand(fs, tree, errors, depth + 1, inner_where)) do
                    -- where it came from (its line numbers are those of the inline script)
                    inner.inline = inner.inline or inner_where
                    out[#out + 1] = inner
                end
            end
        else
            if e.op and e.value and e.value.text == nil then
                e.value = source.expand(fs, e.value, errors, depth, where)
            end
            out[#out + 1] = e
        end
    end
    return out
end

-- source.definitions(fs, subdir) -> definitions, errors: the top-level `name = { ... }`
-- statements of the subdir's .txt files.
-- A definition also has `last`, the line before the next top-level entry of its file (or the last
-- line of the file), and `path`, its file: what source.instantiate reads.
function source.definitions(fs, subdir)
    fs = filesystem_of(fs)
    local defs, errors = {}, {}
    for _, short in ipairs(fs:files(subdir, "txt")) do
        local path = fs:path(short)
        local tree, message = source.parse(fs, short)
        if tree == nil then
            errors[#errors + 1] = message
        else
            local previous
            for _, e in ipairs(tree) do
                local line = e.line
                if previous and line then
                    previous.last = line - 1
                    previous = nil
                end
                if e.op == "=" and e.key and not e.key.quoted and e.value and e.value.text == nil then
                    previous = { block = e.value, file = short, path = path, line = e.line }
                    defs[e.key.text] = previous
                end
            end
            if previous then
                previous.last = math.huge
            end
        end
    end
    return defs, errors
end

-- source.instantiate(fs, def, args [, errors]) -> block | nil, message: a scripted trigger,
-- effect or value definition (from source.definitions) as the game reads it for a call with these
-- arguments ({ { name, value }, ... }): its text (lines def.line to def.last of its file) as a
-- template (source.template, kept in def.template), rewritten for the call (source.generate),
-- parsed at its lines in its file, its inline scripts expanded. The file texts are cached.
local texts = setmetatable({}, { __mode = "v" })
function source.instantiate(fs, def, args, errors)
    if def.template == nil then
        local lines = texts[def.path]
        if lines == nil then
            local text, message = read_file(def.path)
            if text == nil then
                return nil, message
            end
            lines = { text = text }
            for line in (text .. "\n"):gmatch("([^\n]*)\n") do
                lines[#lines + 1] = line
            end
            texts[def.path] = lines
        end
        local last = math.min(def.last, #lines)
        def.template = source.template(table.concat(lines, "\n", def.line, last))
    end
    local params = {}
    for _, a in ipairs(args or {}) do
        params[a[1]] = a[2]
    end
    local text = source.generate(def.template, params)
    local tree, message = pdxscript.parse(string.rep("\n", def.line - 1) .. text, def.file)
    if tree == nil then
        return nil, message
    end
    local e = tree[1]
    if not (e and e.op and e.value and e.value.text == nil) then
        return nil, def.file .. ":" .. def.line .. ": not a definition after substitution"
    end
    return source.expand(fs, e.value, errors)
end

return source
