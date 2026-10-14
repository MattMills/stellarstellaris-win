-- dbbuild.lua : Lua builds game databases in the running game (the Linux 4.5.2 build, headless),
-- instead of the game's readers. Called by db_headless.c:
--   dbbuild.init(name, mode)          in place of TGameDatabase<name>::InitInstance
--   dbbuild.after_load(census, dump)  when the save is launched (every database and post-read done)
--
-- The pieces (docs/databases.md):
--   records.lua  the game's files -> definition records (the shared representation: what the
--                simulation reads too); no game memory involved
--   layout.lua   the C++ side of this build: object layouts, vtables, the game's own primitives
--                (CString, CPdxArray, the static lexer), through the FFI
--   dbbuild.lua  records -> C++ objects in the database the game made (CreateInstance), the
--                database's own work after them, the shadow comparison with the game's own Init, the
--                dump and the census
--
-- Modes: "lua" (the game's Init never runs for this database), "shadow" (the game's Init also runs,
-- into a second instance, and every object is compared), "game" (the game's Init, for control).
-- Controls: HEADLESS_DB_NOPOST=1 leaves out the database's own work after its objects;
-- HEADLESS_DB_PERTURB="<key>.<field>[.<member>]=<value>" changes one record before it is built.

local ffi = require("ffi")
local records = require("records")
local layout = require("layout")

local dbbuild = {}

local function log(fmt, ...)
    ffi.C.hdb_log(string.format(fmt, ...))
end
dbbuild.log = log

local GAME_DIR = os.getenv("HEADLESS_DB_GAME") or "."

local function schema_of(name)
    local s = layout.schemas[name]
    if s == nil then
        error("no schema for " .. name)
    end
    return s
end

-- what each hooked database became: name -> { mode, instance, records, seconds, shadow = {...} }
dbbuild.built = {}

-- HEADLESS_DB_PERTURB: one value of one record changed (to show the game runs on these records)
local function perturb(recs)
    local spec = os.getenv("HEADLESS_DB_PERTURB")
    if not spec or spec == "" then
        return
    end
    local drop = spec:match("^drop:(.+)$")
    if drop then
        -- one record left out, the ones after it numbered again
        for i, r in ipairs(recs) do
            if r.key == drop then
                table.remove(recs, i)
                for k = i, #recs do
                    recs[k].index = k - 1
                end
                log("perturbed: %s", spec)
                break
            end
        end
        return
    end
    local key, path, value = spec:match("^([^.]+)%.([^=]+)=(.*)$")
    for _, r in ipairs(recs) do
        if r.key == key then
            local field, member = path:match("^([^.]+)%.?(.*)$")
            local v = value == "yes" and true or value == "no" and false or tonumber(value) or value
            if member ~= "" then
                r.fields[field] = r.fields[field] or {}
                r.fields[field][member] = v
            else
                r.fields[field] = v
            end
            log("perturbed: %s", spec)
        end
    end
end

-- records -> objects, appended to the live database instance; then the database's own work
local function build(s, inst, recs)
    local arr = layout.array_of(inst, s)
    local inexact = 0
    for i, r in ipairs(recs) do
        local obj = layout.new_object(s, r.index, r.key)
        if i == 1 then
            local why = layout.check_init_post_read(s, obj)
            if why then
                error(why .. ": not built by Lua yet")
            end
        end
        local scripts
        for _, f in ipairs(s.fields) do
            local v = r.fields[f.name]
            if v ~= nil then
                if f.write then
                    f.write(obj, v)
                else
                    scripts = scripts or {}
                    scripts[f.name] = v
                end
            end
        end
        if scripts then
            -- the hybrid: the game compiles the script members, from their own lines
            local file = r.file
            for _, v in pairs(scripts) do
                file = v.file or file
            end
            if not layout.read_scripts(s, obj, scripts, file, records.file_text(GAME_DIR, file)) then
                inexact = inexact + 1
            end
        end
        layout.append(s, arr, obj)
    end
    if inexact > 0 then
        log("%s: %d objects' script members not at their own lines (written out by pdxscript)", s.name, inexact)
    end
    if os.getenv("HEADLESS_DB_NOPOST") ~= "1" then
        local missing = layout.post(s, inst)
        for _, k in ipairs(missing or {}) do
            log("%s: Failed to cache an item for %s! Key: %s", s.name, s.name, k)
        end
    else
        log("%s: the database's own work after its objects left out (HEADLESS_DB_NOPOST)", s.name)
    end
end

-- the game's own Init, into a new instance made by the database's own constructor (the shadow)
local function game_instance(s)
    local inst = layout.construct_database(s)
    layout.vcall(inst, 2, "void (*)(void *)")(inst)
    return inst
end

-- compare two instances object by object: { objects = n, mismatches = { text... } }
local function compare(s, a, b)
    local out = { objects = 0, mismatches = {} }
    local na, nb = layout.count(a, s), layout.count(b, s)
    if na ~= nb then
        out.mismatches[#out.mismatches + 1] = string.format("count %d (lua) vs %d (game)", na, nb)
    end
    for i = 0, math.min(na, nb) - 1 do
        local da, db = layout.describe(s, layout.at(a, s, i)), layout.describe(s, layout.at(b, s, i))
        out.objects = out.objects + 1
        if da ~= db then
            out.mismatches[#out.mismatches + 1] = string.format("#%d: lua %s | game %s", i, da, db)
        end
    end
    local pa, pb = layout.describe_post(s, a), layout.describe_post(s, b)
    if pa ~= pb then
        out.mismatches[#out.mismatches + 1] = string.format("database: lua %s | game %s", pa, pb)
    end
    if s.has_scripts then
        -- the script members: the objects' whole graphs, without their types (deep.lua)
        local d = require("deep").new()
        out.deep, out.padding = 0, 0
        for i = 0, math.min(na, nb) - 1 do
            -- +0x14: the padding of the key CString's allocator (strategy int, then 4 bytes the
            -- constructor copies from a temporary: garbage)
            local ms = d:compare(layout.at(a, s, i), layout.at(b, s, i), s.size, nil, { [0x10] = 0xffffffff })
            out.deep = out.deep + 1
            out.padding = out.padding + d.padding
            for _, m in ipairs(ms) do
                out.mismatches[#out.mismatches + 1] = string.format("#%d deep %s", i, m)
            end
        end
    end
    return out
end

-- In shadow mode the game's allocations are filled with one byte pattern while both copies are
-- built (glibc mallopt M_PERTURB = -6): what the game's constructors leave uninitialized (padding,
-- the unused part of inline buffers) is then the same in both, and the deep comparison sees only
-- what was written.
ffi.cdef [[ int mallopt(int param, int value); ]]
local function perturb_malloc(on)
    if (os.getenv("MALLOC_PERTURB_") or "") == "" then
        ffi.C.mallopt(-6, on and 0xa5 or 0)
    end
end

function dbbuild.init(name, mode)
    local s = schema_of(name)
    if mode == "shadow" and s.has_scripts then
        perturb_malloc(true)
    end
    local ok, err = pcall(dbbuild.init_db, s, name, mode)
    perturb_malloc(false)
    if not ok then
        error(err, 0)
    end
    return err
end

function dbbuild.init_db(s, name, mode)
    local inst = layout.instance(s)
    local entry = { mode = mode, instance = inst }
    dbbuild.built[name] = entry
    if mode == "game" then
        local t = ffi.C.hdb_now()
        layout.vcall(inst, 2, "void (*)(void *)")(inst)
        entry.seconds = ffi.C.hdb_now() - t
        log("%s: the game's Init, %d objects, %.4f s", name, layout.count(inst, s), entry.seconds)
        return true
    end
    local t0 = ffi.C.hdb_now()
    local recs, errors = records.read(GAME_DIR, s)
    perturb(recs)
    local t1 = ffi.C.hdb_now()
    build(s, inst, recs)
    local t2 = ffi.C.hdb_now()
    entry.records, entry.seconds = recs, t2 - t0
    for _, e in ipairs(errors) do
        log("%s: %s", name, e)
    end
    log("%s: Lua built %d objects: read and parse %.4f s, objects %.4f s", name, #recs, t1 - t0, t2 - t1)
    if mode == "shadow" then
        local t3 = ffi.C.hdb_now()
        local g = game_instance(s)
        local t4 = ffi.C.hdb_now()
        local c = compare(s, inst, g)
        entry.shadow = { instance = g, compare = c, seconds = t4 - t3 }
        log("%s: shadow: the game's Init %.4f s; %d objects compared, %d mismatches%s", name, t4 - t3, c.objects,
            #c.mismatches, c.deep and string.format(" (object graphs compared: %d; %d padding qwords left out)", c.deep,
                c.padding) or "")
        for k = 1, math.min(#c.mismatches, 20) do
            log("  %s", c.mismatches[k])
        end
    end
    return true
end

-- the census of every single-object database (counts), and the dump of the hooked ones
function dbbuild.after_load(census, dump)
    if census ~= "" then
        local f = assert(io.open(census, "w"))
        f:write("database\tkind\tobject\tcount\n")
        local n, total = 0, 0
        for line in io.lines(layout.HERE .. "/databases_452.tsv") do
            local db, kind, object = line:match("^([^#\t][^\t]*)\t([^\t]*)\t([^\t]*)")
            if db and db ~= "database" then
                local count = layout.census_count(db, kind)
                f:write(string.format("%s\t%s\t%s\t%s\n", db, kind, object, count or ""))
                if count then
                    n, total = n + 1, total + count
                end
            end
        end
        f:close()
        log("census: %d databases counted, %d objects -> %s", n, total, census)
    end
    if dump ~= "" then
        local f = assert(io.open(dump, "w"))
        local names = {}
        for name in pairs(dbbuild.built) do
            names[#names + 1] = name
        end
        table.sort(names)
        for _, name in ipairs(names) do
            local entry = dbbuild.built[name]
            local s = schema_of(name)
            local inst = layout.instance(s)
            local n = layout.count(inst, s)
            f:write(string.format("== %s %d\n", name, n))
            for i = 0, n - 1 do
                f:write(layout.describe(s, layout.at(inst, s, i)), "\n")
            end
            f:write("database: ", layout.describe_post(s, inst), "\n")
            -- after the post-read passes, the shadow too
            if entry.shadow then
                local c = compare(s, inst, entry.shadow.instance)
                f:write(string.format("-- shadow after the post-reads: %d compared, %d mismatches\n", c.objects,
                    #c.mismatches))
                for _, m in ipairs(c.mismatches) do
                    f:write("-- ", m, "\n")
                end
            end
        end
        f:close()
        log("dump -> %s", dump)
    end
    return true
end

return dbbuild
