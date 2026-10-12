-- source.lua : the game's script files, read from the game directory and parsed with pdxscript
-- (lib/stellar-lua-pdxscript). Vanilla files only for now: mods and the game's virtual file
-- system are not handled.
--
--   local source = require("stellar.script.source")
--   local files = source.files(game_dir, "common/scripted_triggers", "txt")  -- sorted paths
--   local defs, errors = source.definitions(game_dir, "common/scripted_triggers")
--   defs[name] = { block, file, line }: the top-level `name = { ... }` of every file of the
--   directory, in load order (files sorted by name; a later definition replaces an earlier one).

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

-- source.files(game_dir, subdir, extension) -> the paths of the subdir's files with the extension,
-- sorted (the game loads a directory in name order).
function source.files(game_dir, subdir, extension)
    local dir = game_dir .. "/" .. subdir
    local paths = {}
    for _, name in ipairs(list_directory(dir)) do
        if extension == nil or name:lower():sub(-#extension - 1) == "." .. extension then
            paths[#paths + 1] = name
        end
    end
    table.sort(paths)
    for i, name in ipairs(paths) do
        paths[i] = dir .. "/" .. name
    end
    return paths
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

-- source.parse(path [, name]) -> tree | nil, message
function source.parse(path, name)
    local text, message = read_file(path)
    if text == nil then
        return nil, message
    end
    return pdxscript.parse(text, name or path)
end

-- $PARAM$ and $PARAM|default$ in text, from params (name -> text); unknown ones stay as written.
local function substitute(text, params)
    text = text:gsub("%$([%w_]+)|([^%$\n]*)%$", function(name, default)
        return params[name] or default
    end)
    return (text:gsub("%$([%w_]+)%$", function(name)
        return params[name]
    end))
end

-- The entries of a block with its parameter blocks resolved: the entries of `[[NAME] ... ]` when
-- NAME is given, of `[[!NAME] ... ]` when it is not (recursively, in nested blocks too).
local function resolve_conditions(block, params)
    local out = { line = block.line, type = block.type, name = block.name, warnings = block.warnings }
    for _, e in ipairs(block) do
        if e.param then
            if (params[e.param] ~= nil) ~= (e.negated == true) then
                for _, inner in ipairs(resolve_conditions(e, params)) do
                    out[#out + 1] = inner
                end
            end
        else
            if e.op and e.value and e.value.text == nil then
                e.value = resolve_conditions(e.value, params)
            end
            out[#out + 1] = e
        end
    end
    return out
end

-- source.expand(game_dir, block) -> block: the block with its `inline_script` statements replaced
-- by the entries of the inline scripts, as the game reads them: common/inline_scripts/<script>.txt,
-- its $PARAM$ substituted in the text, parsed, its parameter blocks resolved, and expanded in turn.
--   inline_script = "jobs/soldiers_add"
--   inline_script = { script = jobs/soldiers_add  AMOUNT = 2  TRIGGER = "owner? = { ... }" }
-- Nested blocks are expanded too. The entries an inline script adds have `inline` = its name (their
-- lines are those of the inline script). Errors (a missing script, a parse error) are collected in
-- errors and the statement is dropped.
function source.expand(game_dir, block, errors, depth)
    depth = depth or 0
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
                            params[p.key.text] = value
                        end
                    end
                end
            end
            local path = game_dir .. "/common/inline_scripts/" .. tostring(script) .. ".txt"
            local text, message = read_file(path)
            local tree
            if text then
                tree, message = pdxscript.parse(substitute(text, params), "common/inline_scripts/" .. script .. ".txt")
            end
            if tree == nil then
                if errors then
                    errors[#errors + 1] = string.format("line %d: inline_script %s: %s", e.line, tostring(script), tostring(message))
                end
            else
                for _, inner in ipairs(source.expand(game_dir, resolve_conditions(tree, params), errors, depth + 1)) do
                    -- where it came from (its line numbers are those of the inline script)
                    inner.inline = inner.inline or script
                    out[#out + 1] = inner
                end
            end
        else
            if e.op and e.value and e.value.text == nil then
                e.value = source.expand(game_dir, e.value, errors, depth)
            end
            out[#out + 1] = e
        end
    end
    return out
end

-- source.definitions(game_dir, subdir) -> definitions, errors: the top-level `name = { ... }`
-- statements of the subdir's .txt files.
function source.definitions(game_dir, subdir)
    local defs, errors = {}, {}
    for _, path in ipairs(source.files(game_dir, subdir, "txt")) do
        local short = path:sub(#game_dir + 2)
        local tree, message = source.parse(path, short)
        if tree == nil then
            errors[#errors + 1] = message
        else
            for _, e in ipairs(tree) do
                if e.op == "=" and e.key and not e.key.quoted and e.value and e.value.text == nil then
                    defs[e.key.text] = { block = e.value, file = short, line = e.line }
                end
            end
        end
    end
    return defs, errors
end

return source
