-- require in Lua (sim/src/runtime.rs installs it in every VM of the simulation): Lua 5.1's
-- ll_require (LuaJIT's lib_package.c), the same lookups in package.loaded and package.loaders, the
-- same sentinel against loops and the same errors, with the module's chunk run from Lua. Run from
-- the C function, a module's first load could not yield, and the VM could not stop it at a slice's
-- deadline (sim/src/preempt.rs). Returns require, and precompile (below).

local package, error, type, tostring, rawget = package, error, type, tostring, rawget
local loaded = package.loaded
local sentinel = {}

-- precompile(templates): every module the first templates of package.path would find, compiled now
-- (loadfile, the chunk named after its file as the file searcher names it) and found by a searcher
-- put before the file searcher. A module's first require then runs its chunk, whose compile (in C)
-- the VM could not stop either. templates: { root, "?.lua" or "?/init.lua" } in the path's order,
-- the first ones of it, so a module found here is the one the file searcher would have found.
local function precompile(templates)
    local chunks = {}
    for _, t in ipairs(templates) do
        local root, init = t[1], t[2] == "?/init.lua"
        for _, rel in ipairs(RUST.list_files(root, "", "lua")) do
            local name = rel:match(init and "^(.+)/init%.lua$" or "^(.+)%.lua$")
            -- (a name with a dot in its file name is not one require can reach)
            if name and not name:find(".", 1, true) then
                name = name:gsub("/", ".")
                if chunks[name] == nil then
                    -- (a file that does not compile is left to the file searcher and its error)
                    chunks[name] = loadfile(root .. "/" .. rel) or false
                end
            end
        end
    end
    table.insert(package.loaders, 2, function(name)
        return chunks[name] or nil
    end)
end

local function require(name)
    if type(name) ~= "string" then
        if type(name) == "number" then
            name = tostring(name)
        else
            error("bad argument #1 to 'require' (string expected, got " .. type(name) .. ")", 2)
        end
    end
    local m = loaded[name]
    if m then
        if m == sentinel then
            error("loop or previous error loading module '" .. name .. "'", 2)
        end
        return m
    end
    local loaders = package.loaders
    if type(loaders) ~= "table" then
        error("'package.loaders' must be a table", 2)
    end
    local msg, loader, i = "", nil, 0
    while true do
        i = i + 1
        local f = rawget(loaders, i)
        if f == nil then
            error("module '" .. name .. "' not found:" .. msg, 2)
        end
        local r = f(name)
        if type(r) == "function" then
            loader = r
            break
        elseif type(r) == "string" then
            msg = msg .. r
        end
    end
    loaded[name] = sentinel
    local r = loader(name)
    if r ~= nil then
        loaded[name] = r
    end
    if loaded[name] == sentinel then
        loaded[name] = true
    end
    return loaded[name]
end

return require, precompile
