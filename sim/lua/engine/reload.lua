-- engine/reload.lua : the game's files that changed, read again in a running Lua state
-- (docs/script_loading.md, 3.3 and 3.4).
--
--   local reload = require("engine.reload")
--   reload.scan()            -- the disk compared with what was read (RUST.vfs_scan), then poll()
--   reload.poll()            -- the changes this state has not applied yet (any state's scan, a watcher)
--   reload.files({ rel })    -- these files, by name
--   reload.on(function(report) ... end)   -- after each reload (a module that keeps its own copy)
--
-- The changes are the shared file system's change log (sim/src/vfs.rs): one log for every Lua
-- state of the process, each state at its own place in it. A change invalidates the file there (a
-- new version: the parse cache reads it again); here each product built from it is rebuilt, the
-- rest kept:
--   common/<folder>/...          engine.defs: the folder's definitions (changed ones in place)
--   common/scripted_triggers, scripted_effects, script_values: simscript.db (and their instances)
--   common/scripted_variables    the global variables
--   common/inline_scripts/...    every definition, events file and on_actions file that read it
--   common/on_actions            the on_actions
--   common/static_modifiers      the static modifiers
--   events/...                   that file's events (and the MTTH index)
--   *.yml                        the localisation
-- then the compiled script is dropped (simscript.compile: compiled again at its next use), and the
-- listeners run. What a module copied out of the definitions at its start is its own to reload
-- (reload.on); the report says what changed.

local source = require("stellar.script.source")

local reload = {
    seq = {},         -- file system key -> the last change applied in this state
    listeners = {},
    last = nil,       -- the last report
}

function reload.on(fn)
    reload.listeners[#reload.listeners + 1] = fn
end

local function clock()
    return RUST and RUST.clock and RUST.clock() or os.clock()
end

-- the file systems of this state with the shared one under them
local function filesystems()
    local out, seen = {}, {}
    local db = package.loaded["simscript.db"]
    local candidates = source.filesystems()
    table.insert(candidates, 1, db and db.fs or false)
    for _, fs in ipairs(candidates) do
        if fs and fs.vfs and not seen[fs.vfs] then
            seen[fs.vfs] = true
            out[#out + 1] = fs
        end
    end
    return out
end

-- reload.apply(list) -> report: the products of these changed files rebuilt
function reload.apply(list)
    local t0 = clock()
    local db = package.loaded["simscript.db"]
    local defs = package.loaded["engine.defs"]
    local loc = package.loaded["engine.localisation"]
    local report = { files = list, defs = {}, scripted = {}, events = {}, reexpanded = {} }
    local folders, scripted, events, inline = {}, {}, {}, {}
    local on_actions, vars, statics, texts, script = false, false, false, false, false
    for _, rel in ipairs(list) do
        if rel:match("%.yml$") then
            texts = true
        elseif rel:match("^events/") then
            events[rel], script = true, true
        elseif rel:match("^common/") then
            script = true
            if rel:match("^common/inline_scripts/") then inline[rel] = true end
            if rel:match("^common/on_actions/") then on_actions = true end
            if rel:match("^common/scripted_variables/") then vars = true end
            if rel:match("^common/static_modifiers/") then statics = true end
            local s = rel:match("^(common/scripted_triggers)/") or rel:match("^(common/scripted_effects)/")
                or rel:match("^(common/script_values)/")
            if s then scripted[s] = true end
            local f = defs and defs.folder_of and defs.folder_of(rel)
            if f and f ~= "common/inline_scripts" then folders[f] = true end
        end
        if db and db.forget_filevars then db.forget_filevars(rel) end
    end
    -- an inline script: what read it
    if next(inline) then
        if defs and defs.reexpand then report.reexpanded = defs.reexpand(inline) end
        if db then
            for file, used in pairs(db.file_inlines or {}) do
                for f in pairs(inline) do
                    if used[f] then events[file] = true end
                end
            end
            for f in pairs(inline) do
                if db.on_action_inlines and db.on_action_inlines()[f] then on_actions = true end
            end
            db.forget_instances()
        end
    end
    if defs and defs.reload_folder then
        for f in pairs(folders) do
            report.defs[f] = defs.reload_folder(f)
        end
    end
    if db and db.fs then
        if vars then db.reload_globalvars() end
        for f in pairs(scripted) do report.scripted[f] = db.reload_scripted(f) end
        if statics then db.reload_static_modifiers() end
        if on_actions then db.reload_on_actions(); report.on_actions = true end
        local any = false
        for file in pairs(events) do
            report.events[file] = db.reload_event_file(file)
            any = true
        end
        local ev = package.loaded["simscript.events"]
        if any and ev and ev.reindex then ev.reindex() end
    end
    if texts and loc and loc.language and loc.game_dir then
        loc.load(loc.game_dir, loc.language)
        report.localisation = loc.keys
    end
    local eval = package.loaded["simscript.eval"]
    if script and eval and eval.compiler and eval.compiler.flush then
        eval.compiler.flush()
        report.compiled = "dropped"
    end
    report.seconds = clock() - t0
    for _, fn in ipairs(reload.listeners) do
        local ok, err = pcall(fn, report)
        if not ok then report.listener_error = tostring(err) end
    end
    reload.last = report
    return report
end

-- reload.poll() -> report | nil: the changes of the shared file systems this state has not applied
function reload.poll()
    local all = {}
    for _, fs in ipairs(filesystems()) do
        local list, last = fs.rust.vfs_changes(fs.vfs, reload.seq[fs.vfs] or 0)
        reload.seq[fs.vfs] = last
        for _, rel in ipairs(list) do all[#all + 1] = rel end
    end
    if #all == 0 then return nil end
    return reload.apply(all)
end

-- reload.scan() -> report | nil: the disk compared with what was read, then poll()
function reload.scan()
    for _, fs in ipairs(filesystems()) do
        fs.rust.vfs_scan(fs.vfs)
    end
    return reload.poll()
end

-- reload.files(rels) -> report | nil: these files changed (logged, so every state applies them)
function reload.files(rels)
    for _, fs in ipairs(filesystems()) do
        fs.rust.vfs_changed(fs.vfs, rels)
    end
    return reload.poll()
end

-- reload.summary(report) -> one line
function reload.summary(r)
    if not r then return "reload: nothing changed" end
    local function n(t) local c = 0 for _ in pairs(t or {}) do c = c + 1 end return c end
    local parts = {}
    for f, x in pairs(r.defs) do
        parts[#parts + 1] = string.format("%s +%d ~%d -%d", f, #x.added, #x.changed, #x.removed)
    end
    for f, x in pairs(r.scripted) do
        if not r.defs[f] then
            parts[#parts + 1] = string.format("%s +%d ~%d -%d", f, #x.added, #x.changed, #x.removed)
        end
    end
    if n(r.events) > 0 then parts[#parts + 1] = n(r.events) .. " events files" end
    if n(r.reexpanded) > 0 then parts[#parts + 1] = "inline scripts expanded again in " .. n(r.reexpanded) .. " folders" end
    if r.on_actions then parts[#parts + 1] = "on_actions" end
    if r.localisation then parts[#parts + 1] = "localisation " .. r.localisation .. " keys" end
    table.sort(parts)
    return string.format("reload: %d files in %.3f s: %s", #r.files, r.seconds,
        #parts > 0 and table.concat(parts, "; ") or "no products")
end

return reload
