-- engine/defs.lua : the game's definitions: every database folder of common/ in the vanilla file
-- set, read in place from the game directory the game's way (stellar.script.source.definitions:
-- the files of a folder in load order, a later definition replacing an earlier one, scripted
-- variables and parameter blocks as the game reads them).
--
--   local defs = require("engine.defs")
--   defs.load(fs, game_dir)
--   defs.folder("common/strategic_resources")   -- name -> { block, file, line, ... }
--   defs.get("common/technology", "tech_lasers_1")

local source = require("stellar.script.source")
local slice = require("engine.slice")   -- a phase in pieces (docs/frame_timing.md)

local defs = {
    folders = {},   -- "common/x" -> { [name] = def }
    order = {},     -- the folders, sorted
    counts = {},    -- folder -> number of definitions
    errors = {},    -- { folder, message }
    seconds = 0,
}

-- defs.load(fs, game_dir): every folder under common/ that has .txt files
function defs.load(fs, game_dir)
    local t0 = RUST.clock()
    defs.fs = fs
    local folders = {}
    if fs and fs.vfs then
        -- every mount's folders (a folder only a mod has too), those with .txt files
        -- (common/ itself too, as before: its loose files, alerts.txt and achievements.txt). A
        -- folder the game lists at more than one level (common/inline_scripts) has its subfolders'
        -- files in its own listing: they are not folders of their own.
        local all = fs.rust.vfs_dirs(fs.vfs, "common")
        table.insert(all, 1, "common")
        local deep = {}
        for _, folder in ipairs(all) do
            local parent = folder:match("^(.*)/[^/]*$")
            local inside = false
            while parent do
                if deep[parent] then inside = true break end
                parent = parent:match("^(.*)/[^/]*$")
            end
            if not inside then
                if folder ~= "common" and fs.rust.vfs_depth(folder, "txt") ~= 0 then
                    deep[folder] = true
                end
                if #fs.rust.vfs_list(fs.vfs, folder, "txt") > 0 then
                    folders[folder] = true
                end
            end
        end
    else
        for _, file in ipairs(RUST.list_files(game_dir, "common")) do
            local folder = file:match("^(.*)/[^/]*$")
            if folder then
                folders[folder] = true
            end
        end
    end
    for folder in pairs(folders) do
        defs.order[#defs.order + 1] = folder
    end
    table.sort(defs.order)
    for _, folder in ipairs(defs.order) do
        local d, errors, vars = source.definitions(fs, folder)
        defs.folders[folder] = d
        -- the files' own variables, read in the same parse (simscript.db reads them on demand)
        local db = package.loaded["simscript.db"]
        if db and db.set_filevars and vars then
            for file, v in pairs(vars) do db.set_filevars(file, v) end
        end
        local n = 0
        for _ in pairs(d) do
            n = n + 1
        end
        defs.counts[folder] = n
        for _, m in ipairs(errors or {}) do
            defs.errors[#defs.errors + 1] = { folder = folder, message = tostring(m) }
        end
    end
    defs.seconds = RUST.clock() - t0
end

-- a definition's inline scripts expanded (in place, once), as the game reads them at load: what
-- reads a definition sees the same block wherever and whenever it reads it. (stellar.script.source
-- .expand writes a nested block's expansion into the block itself, so before this a definition
-- read before some other module had expanded it differed from one read after.)
local function expand(folder, d)
    if d and not d.expanded then
        d.expanded = true
        local fs = defs.fs
        if fs and d.block then
            local ok, x = pcall(source.expand, fs, d.block, nil, 0, "file: " .. tostring(d.file))
            if ok and x then d.block = x end
        end
    end
    return d
end

local expanded_folders = {}
function defs.folder(folder)
    local f = defs.folders[folder]
    if f == nil then return {} end
    if not expanded_folders[folder] then
        expanded_folders[folder] = true
        for _, d in pairs(f) do
            slice.tick("definitions")
            expand(folder, d)
        end
    end
    return f
end

function defs.get(folder, name)
    local f = defs.folders[folder]
    return f and expand(folder, f[name])
end

-- the first value of `key` in a definition's block (a token's text, or a block), or nil
function defs.field(block, key)
    for _, e in ipairs(block or {}) do
        if e.op and e.key and e.key.text == key then
            return e.value.text or e.value
        end
    end
    return nil
end

-- defs.summary() -> text: the folders and their definitions
function defs.summary()
    local total = 0
    for _, n in pairs(defs.counts) do
        total = total + n
    end
    return string.format("%d folders of common/, %d definitions, %d files that did not parse, in %.1f s",
        #defs.order, total, #defs.errors, defs.seconds)
end

return defs
