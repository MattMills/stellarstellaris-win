-- layout.lua : the C++ side of the Linux 4.5.2 build for the database prototype: where things are
-- in a database and its objects, and the game's own primitives (CString, CPdxArray, the static
-- lexer), through the FFI. The build has symbols and RTTI but no DWARF for the game's code, so the
-- offsets here are read from the Linux code (constructors, ReadMember, LoadFromReader, Init;
-- addresses in docs/databases.md); the GOG PDB gives the same classes for the Windows build, at MSVC
-- offsets.
--
-- TSingleObjectGameDatabase<DB, T, b> (Linux):
--   +0x00 vptr (TGameDatabase<DB>), +0x08 CSingleObjectGameDatabaseBase (vptr, CString _FolderPath
--   +0x10, _FileWatchListener), +0x48 CPdxArray<T const*> _Array (vptr, data +0x50, capacity +0x58,
--   size +0x5c), +0x60 CPdxUnorderedMap<CString, T const*> _Lookup (entries, count, ..., load factor
--   0.9 at +0x74), +0x78 _Mode; a database class's own members after it (+0x80)
-- TGameDatabaseObject<T> (Linux): +0x00 vptr, +0x08 int _Index, +0x10 CString _Key; CPersistent's
--   vptr after it (+0x40 when the class has no other base before it)
-- CString (Linux, 48 bytes): +0x00 16 bytes (zero for a new string), +0x10 std::string with
--   CPdxCommonStringAllocator: char *data, size_t size +0x18, local buffer / capacity +0x20

local ffi = require("ffi")

ffi.cdef [[
    uintptr_t hdb_sym(const char *name);
    uint64_t hdb_sym_size(const char *name);
    void hdb_log(const char *text);
    double hdb_now(void);
    void *calloc(size_t n, size_t size);
]]

local layout = {}

layout.HERE = os.getenv("HEADLESS_DB_LUA") or "."

local function sym(name)
    local a = ffi.C.hdb_sym(name)
    if a == 0 then
        error("symbol not found: " .. name)
    end
    return a
end
layout.sym = sym

local function ptr(a)
    return ffi.cast("uint8_t *", a)
end

local function u64(p, off)
    return ffi.cast("uint64_t *", ptr(p) + off)[0]
end
local function i32(p, off)
    return ffi.cast("int32_t *", ptr(p) + off)[0]
end

-- the mangled name of a class (a plain identifier)
local function mangle(name)
    return #name .. name
end

-- ---------------------------------------------------------------- the game's primitives

local CString_ctor = ffi.cast("void (*)(void *, const char *)", sym("_ZN7CStringC1EPKc"))

-- CString at p <- text (the game's constructor: its allocator for long strings)
function layout.cstring_init(p, text)
    CString_ctor(p, text)
end

function layout.cstring_read(p)
    local data = ffi.cast("const char **", ptr(p) + 0x10)[0]
    local size = tonumber(ffi.cast("uint64_t *", ptr(p) + 0x18)[0])
    if data == nil then
        return nil
    end
    return ffi.string(data, size)
end

-- a virtual function of an object: slot k of its vtable, as the C type given
function layout.vcall(obj, k, ctype)
    local vt = ffi.cast("void ***", obj)[0]
    return ffi.cast(ctype, vt[k])
end

-- the static lexer's id of a word (CStaticLexer::FindTok, 0x42dfa90: 12 when it has none)
local FindTok = ffi.cast("int (*)(const char *)", sym("_ZN12CStaticLexer7FindTokEPKc"))
function layout.token(word)
    return FindTok(word)
end

local vtables = {}
local function vtable(class)
    local a = vtables[class]
    if a == nil then
        a = sym("_ZTV" .. mangle(class))
        vtables[class] = a
    end
    return a
end

-- ---------------------------------------------------------------- the game's reader, on Lua's text
--
-- For the script members (triggers, effects, script values, weights), the hybrid: Lua makes the
-- object and its data; the game compiles the script parts, reading only those statements, from a
-- reader over a text Lua gives it. The reader is made the way the game makes its own (CGameState::Load
-- 0x1b41e3e, CreateCommand 0x3c9fe00): a CMemoryFile over the text (0xa0 bytes; its name, a CString at
-- +0x20 of CFile, is the file the statements came from), a CTextLexer (0x140) and a CReader (0x3c0)
-- that owns the lexer. The text keeps the statements on their own lines, so the locations the
-- compiled objects keep ("file: x line: n") are the game's.

ffi.cdef [[
    void free(void *p);
]]
local MemoryFile_ctor = ffi.cast("void (*)(void *, const char *, int, int, int, bool)",
    sym("_ZN11CMemoryFileC1EPhi9EFileType9EFileModeb"))
local MemoryFile_dtor = ffi.cast("void (*)(void *)", sym("_ZN11CMemoryFileD1Ev"))
local TextLexer_ctor = ffi.cast("void (*)(void *, void *, bool)", sym("_ZN10CTextLexerC1EP5CFileb"))
local Reader_ctor = ffi.cast("void (*)(void *, void *, bool)", sym("_ZN7CReaderC1EP6CLexerb"))
local Reader_dtor = ffi.cast("void (*)(void *)", sym("_ZN7CReaderD1Ev"))
local Reader_ReadSimpleStatement = ffi.cast("void (*)(void *)", sym("_ZN7CReader19ReadSimpleStatementEv"))
local CString_assign = ffi.cast("void *(*)(void *, const char *)", sym("_ZN7CStringaSEPKc"))

-- read(reader) with a reader over text named file; text stays alive meanwhile
function layout.with_reader(text, file, read)
    local buf = ffi.new("char[?]", #text + 1, text)
    local mf = ffi.C.calloc(1, 0x100)
    MemoryFile_ctor(mf, buf, #text, 1, 0, false) -- EFileType 1: text (as CGameState::Load reopens it)
    CString_assign(ptr(mf) + 0x20, file)
    local lx = ffi.C.calloc(1, 0x200)
    TextLexer_ctor(lx, mf, false)
    local rd = ffi.C.calloc(1, 0x400)
    Reader_ctor(rd, lx, true) -- the reader deletes the lexer
    local ok, err = pcall(read, rd)
    Reader_dtor(rd)
    ffi.C.free(rd)
    MemoryFile_dtor(mf)
    ffi.C.free(mf)
    if not ok then
        error(err, 0)
    end
end

-- the text of statements at their own lines of their file, inside `x = { ... }`, or (when the lines
-- hold other statements too) written out by pdxscript at other lines: text, exact
function layout.statements_text(file_text, statements)
    local lines = {}
    for l in (file_text .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = l
    end
    local out, last_used, exact = {}, 0, true
    for _, st in ipairs(statements) do
        local first = st.line
        local head = lines[first] or ""
        if first <= last_used or not head:match("^%s*" .. st.key.text:gsub("%p", "%%%0") .. "%s*[=<>]") then
            exact = false
            break
        end
        -- its last line: where its braces close (comments and quoted strings left out); the line
        -- must hold nothing after the statement
        local depth, last, opened = 0, nil, false
        for l = first, #lines do
            local code = lines[l]:gsub('"[^"]*"', '""'):gsub("#.*$", "")
            for c in code:gmatch("[{}]") do
                depth = depth + (c == "{" and 1 or -1)
                opened = true
            end
            if opened and depth <= 0 then
                last = l
                break
            end
            if not opened and not (st.value and st.value.text == nil) then
                last = l -- a statement without a block: one line
                break
            end
        end
        if last == nil or depth ~= 0 then
            exact = false
            break
        end
        for l = first, last do
            out[l] = lines[l]
        end
        last_used = last
    end
    if exact then
        local text = {}
        for l = 1, last_used do
            text[l] = out[l] or ""
        end
        text[1] = "x = { " .. text[1]
        text[#text + 1] = "}"
        return table.concat(text, "\n"), true
    end
    local pdxscript = require("pdxscript")
    local parts = { "x = {" }
    for _, st in ipairs(statements) do
        parts[#parts + 1] = pdxscript.write({ st })
    end
    parts[#parts + 1] = "}"
    return table.concat(parts, "\n"), false
end

-- the null object of a class (TPdxNullObject<T>::_pInstance), what a failed lookup gives
function layout.null_object(class)
    return ffi.cast("void **", sym("_ZN14TPdxNullObjectI" .. mangle(class) .. "E10_pInstanceE"))[0]
end

-- ---------------------------------------------------------------- field types: write, read

local types = {}

-- CColor: 4 floats
function types.color(f)
    f.write = function(obj, v)
        local p = ffi.cast("float *", ptr(obj) + f.offset)
        for k = 1, 4 do
            p[k - 1] = v[k]
        end
    end
    f.read = function(obj)
        local p = ffi.cast("float *", ptr(obj) + f.offset)
        return string.format("%.9g,%.9g,%.9g,%.9g", p[0], p[1], p[2], p[3])
    end
end

-- a token id (int)
function types.token(f)
    f.write = function(obj, v)
        ffi.cast("int32_t *", ptr(obj) + f.offset)[0] = layout.token(v)
    end
    f.read = function(obj)
        return tostring(i32(obj, f.offset))
    end
end

-- bools of a struct: members = { key = offset in the object }
function types.flags(f)
    local keys = {}
    for k in pairs(f.members) do
        keys[#keys + 1] = k
    end
    table.sort(keys, function(a, b)
        return f.members[a] < f.members[b]
    end)
    f.write = function(obj, v)
        for k, b in pairs(v) do
            ptr(obj)[f.members[k]] = b and 1 or 0
        end
    end
    f.read = function(obj)
        local out = {}
        for _, k in ipairs(keys) do
            out[#out + 1] = string.format("%s:%d", k, ptr(obj)[f.members[k]])
        end
        return table.concat(out, ",")
    end
end

-- a script member: written by the game (layout.read_scripts), compared structurally (deep.lua)
function types.script(f)
    f.write = nil
    f.read = function(obj)
        return "<script>"
    end
end

-- ---------------------------------------------------------------- the schemas
--
-- Per database: the script side (folder, fields: key and value type, read by records.lua) and the
-- C++ side (the object's size, vtables, the members' offsets, the database's own work after its
-- objects: post). Only what this prototype builds.

local schemas = {}
layout.schemas = schemas

local function schema(s)
    for _, f in ipairs(s.fields) do
        types[f.type](f)
        s.has_scripts = s.has_scripts or f.type == "script"
    end
    schemas[s.name] = s
    return s
end

-- CNamedColorDatabase: common/named_colors. CNamedColor (Linux 0x58 bytes; MSVC 88):
-- TGameDatabaseObject<CNamedColor> +0, CPersistent +0x40, CColor _Color +0x48 (white by default:
-- CNamedColor::CNamedColor 0x1db72d0). ReadMember (0x1db73f0): token 86 `color`.
schema {
    name = "CNamedColorDatabase",
    object = "CNamedColor",
    folder = "common/named_colors",
    db_size = 0x80,
    size = 0x58,
    -- the vtable pointers the constructor stores: { offset, class, vtable + add }
    vtables = { { 0, "CNamedColor", 0x10 }, { 0x40, "CNamedColor", 0x40 } },
    defaults = function(obj)
        local f = ffi.cast("float *", ptr(obj) + 0x48)
        f[0], f[1], f[2], f[3] = 1, 1, 1, 1
    end,
    fields = {
        { name = "color", key = "color", type = "color", offset = 0x48 },
    },
}

-- CAIAttitudesDatabase: common/attitudes (Linux: database 0x200 bytes, CreateInstance 0x1a9fdf0;
-- object 0x60, LoadFromReader 0x26e78c0). CAIAttitude (CAIAttitude::CAIAttitude 0x26e5760,
-- ReadMember 0x26e58a0): +0x48 SBehaviour _Behaviour (a CPersistent: vptr, then 6 bools,
-- SBehaviour::ReadMember 0x26e45f0), +0x58 int _Token (token 225 `type`: the value's token id,
-- 13262 `null` by default). Token 11560 `behaviour`.
-- The database's own Init (CAIAttitudesDatabase::Init 0x26e6760) reads the folder, then caches 24
-- attitudes by key in its TCachedDBPtr<CAIAttitude> members ({ pointer, bool }: the object, or
-- the null object and "Failed to cache an item"): CacheItem<CAIAttitudesDatabase, CAIAttitude>
-- 0x26e6db0.
schema {
    name = "CAIAttitudesDatabase",
    object = "CAIAttitude",
    folder = "common/attitudes",
    db_size = 0x200,
    size = 0x60,
    vtables = { { 0, "CAIAttitude", 0x10 }, { 0x40, "CAIAttitude", 0x40 }, { 0x48, "SBehaviour", 0x10 } },
    defaults = function(obj)
        ffi.cast("int32_t *", ptr(obj) + 0x58)[0] = 13262
    end,
    fields = {
        { name = "behaviour", key = "behaviour", type = "flags", members = { attack = 0x50, weaken = 0x51,
            alliance = 0x52, coexist = 0x53, trade = 0x54, vassalize = 0x55 } },
        { name = "type", key = "type", type = "token", offset = 0x58 },
    },
    cached = { { 0x1e0, "enigmatic" }, { 0x1f0, "berserker" }, { 0x170, "dismissive" }, { 0x180, "custodial" },
        { 0x190, "patronizing" }, { 0x1a0, "angry" }, { 0x1b0, "arrogant" }, { 0x1c0, "imperious" },
        { 0x1d0, "belligerent" }, { 0x80, "threatened" }, { 0x90, "hostile" }, { 0xa0, "friendly" },
        { 0xd0, "protective" }, { 0xe0, "domineering" }, { 0xb0, "loyal" }, { 0xc0, "disloyal" },
        { 0xf0, "overlord" }, { 0x130, "unfriendly" }, { 0x100, "wary" }, { 0x110, "receptive" },
        { 0x120, "neutral" }, { 0x140, "cordial" }, { 0x150, "rival" }, { 0x160, "null" } },
}

-- CTraitTagDatabase, CJobTagDatabase: common/trait_tags, common/job_tags, KeysOnly databases
-- (_Mode 1: the files are lists of words; LoadFromReader's other branch). CTraitTag / CJobTag
-- (0x40 bytes, constructors 0x1a998c0 / 0x1a99bc0): TGameDatabaseObject only, one vptr. Other
-- databases' objects look them up by key: traits (ReadKeyReference<CTraitTagDatabase>), jobs
-- (ReadKeyReferenceUniform<CJobTagDatabase>), and so find Lua's objects.
for _, t in ipairs({ { "CTraitTagDatabase", "CTraitTag", "common/trait_tags" },
    { "CJobTagDatabase", "CJobTag", "common/job_tags" } }) do
    schema {
        name = t[1],
        object = t[2],
        folder = t[3],
        keys_only = true,
        db_size = 0x80,
        size = 0x40,
        vtables = { { 0, t[2], 0x10 } },
        fields = {},
    }
end

-- CAIEspionageOperationPoliciesDatabase: common/ai_espionage/operations (Linux: database 0x80
-- bytes, CreateInstance 0x1aa20b0; object 0x80, ReadNewEntry 0x1aaa3e0). CAIEspionageOperationPolicy
-- (constructor 0x274f640): +0x40 CScriptableValue _AIWeight (made by CScriptableValue(EScopeType
-- 0x1000000, true) 0x1d58e30; MSVC puts CPersistent first, +0x40, and the policy base +0x48), +0x78
-- CPersistent's vptr. Its Read (0x274f730, slot 3 of its vtable) reads the block through a
-- CSerializerBase whose ReadMember (0x2750270) knows one token, 593 `weight`: CReader::Read(CPersistent&)
-- on the CScriptableValue (a CMeanTimeToHappen: base, modifiers with their triggers).
schema {
    name = "CAIEspionageOperationPoliciesDatabase",
    object = "CAIEspionageOperationPolicy",
    folder = "common/ai_espionage/operations",
    db_size = 0x80,
    size = 0x80,
    persistent = 0x78, -- CPersistent's part
    vtables = { { 0, "CAIEspionageOperationPolicy", 0x10 }, { 0x78, "CAIEspionageOperationPolicy", 0x40 } },
    defaults = function(obj)
        ffi.cast("void (*)(void *, int, bool)", sym("_ZN16CScriptableValueC1E10EScopeTypeb"))(ptr(obj) + 0x40,
            0x1000000, true)
    end,
    -- how the game reads an object's block: slot 3 of the object's own vtable
    read = { offset = 0, slot = 3 },
    fields = {
        { name = "weight", key = "weight", type = "script", offset = 0x40 },
    },
}

-- the script members of an object, compiled by the game: one reader over their statements, the
-- object's own Read on it (only those statements are in the text: the data members are Lua's)
function layout.read_scripts(s, obj, scripts, file, file_text)
    local statements = {}
    for _, f in ipairs(s.fields) do
        for _, st in ipairs(scripts[f.name] or {}) do
            statements[#statements + 1] = st
        end
    end
    if #statements == 0 then
        return true
    end
    table.sort(statements, function(a, b)
        return a.line < b.line
    end)
    local text, exact = layout.statements_text(file_text, statements)
    local target = ptr(obj) + s.read.offset
    local read = layout.vcall(target, s.read.slot, "void (*)(void *, void *)")
    layout.with_reader(text, file, function(rd)
        Reader_ReadSimpleStatement(rd) -- `x = {`, as LoadFromReader reads `key = {`
        read(target, rd)
    end)
    return exact
end

-- ---------------------------------------------------------------- a single-object database

local instances = {}

-- the live instance (CreateInstance made it, empty)
function layout.instance(s)
    local a = instances[s.name]
    if a == nil then
        a = sym("_ZN13TGameDatabaseI" .. mangle(s.name) .. "E10_pInstanceE")
        instances[s.name] = a
    end
    local inst = ffi.cast("void **", a)[0]
    assert(inst ~= nil, s.name .. ": no instance")
    return inst
end

-- a new instance made by the database's own constructor (calloc + C1, as CreateInstance does)
function layout.construct_database(s)
    local inst = ffi.C.calloc(1, s.db_size)
    local ctor = ffi.cast("void (*)(void *)", sym("_ZN" .. mangle(s.name) .. "C1Ev"))
    ctor(inst)
    return inst
end

function layout.array_of(inst, s)
    return ptr(inst) + 0x48
end

function layout.count(inst, s)
    return i32(inst, 0x5c)
end

function layout.at(inst, s, i)
    local data = ffi.cast("void ***", ptr(inst) + 0x50)[0]
    return data[i]
end

function layout.key_of(obj)
    return layout.cstring_read(ptr(obj) + 0x10)
end

-- a new object: calloc, its vtables, _Index, _Key, the defaults of its constructor
function layout.new_object(s, index, key)
    local obj = ffi.C.calloc(1, s.size)
    for _, v in ipairs(s.vtables) do
        ffi.cast("uintptr_t *", ptr(obj) + v[1])[0] = vtable(v[2]) + v[3]
    end
    ffi.cast("int32_t *", ptr(obj) + 8)[0] = index
    layout.cstring_init(ptr(obj) + 0x10, key)
    if s.defaults then
        s.defaults(obj)
    end
    return obj
end

-- append obj to the database's _Array (the game's CPdxArray<T const*>::InsertAtEmplace)
local inserters = {}
function layout.append(s, arr, obj)
    local f = inserters[s.object]
    if f == nil then
        local name = "_ZN9CPdxArrayIPK" .. mangle(s.object) .. "iE15InsertAtEmplaceIJRKS2_EEERS2_iDpOT_"
        f = ffi.cast("void *(*)(void *, int, void **)", sym(name))
        inserters[s.object] = f
    end
    local box = ffi.new("void *[1]", obj)
    local n = ffi.cast("int32_t *", arr + 0x14)[0]
    f(arr, n, box)
end

-- What CPersistent::Read does after an object's block (0x42e4c10): InitPostRead() and
-- InitPostRead(file, first line, last line), slots 6 and 7 of the CPersistent vtable. A class that
-- overrides them validates, resolves or makes modifiers there; a Lua-built object must get the same
-- (here: refuse such a class). nil if the class keeps CPersistent's own (empty) ones.
function layout.check_init_post_read(s, obj)
    if s.keys_only then
        return nil -- no CPersistent part: nothing is read for these objects
    end
    local off = s.persistent or 0x40
    local vt = ffi.cast("uintptr_t *", ffi.cast("uintptr_t *", ptr(obj) + off)[0])
    local a = sym("_ZN11CPersistent12InitPostReadEv")
    local b = sym("_ZN11CPersistent12InitPostReadERK7CStringii")
    if vt[6] ~= a or vt[7] ~= b then
        return string.format("%s overrides InitPostRead (slots %x %x)", s.object, tonumber(vt[6]), tonumber(vt[7]))
    end
end

-- the database's own work after its objects (what its Init override does after the base Init)
function layout.post(s, inst)
    if s.cached then
        -- CacheItem: the first object with the key, else the null object (and the game's error)
        local by_key = {}
        for i = layout.count(inst, s) - 1, 0, -1 do
            local o = layout.at(inst, s, i)
            by_key[layout.key_of(o)] = o
        end
        local missing = {}
        for _, c in ipairs(s.cached) do
            local o = by_key[c[2]]
            if o == nil then
                o = layout.null_object(s.object)
                missing[#missing + 1] = c[2]
            end
            ffi.cast("void **", ptr(inst) + c[1])[0] = o
            ptr(inst)[c[1] + 8] = 1
        end
        return missing
    end
end

-- the database's members that post sets, as text (for the comparison)
function layout.describe_post(s, inst)
    if not s.cached then
        return ""
    end
    local out = {}
    for _, c in ipairs(s.cached) do
        local o = ffi.cast("void **", ptr(inst) + c[1])[0]
        local k = (o ~= nil and o ~= layout.null_object(s.object)) and layout.key_of(o) or "<null object>"
        out[#out + 1] = string.format("%s=%s/%d", c[2], k, ptr(inst)[c[1] + 8])
    end
    return table.concat(out, " ")
end

-- one line per object: what the comparison and the dump compare
function layout.describe(s, obj)
    local parts = { string.format("%d", i32(obj, 8)), layout.key_of(obj) or "<null>" }
    local vts = {}
    for _, v in ipairs(s.vtables) do
        vts[#vts + 1] = string.format("%x", tonumber(u64(obj, v[1]) - vtable(v[2])))
    end
    parts[#parts + 1] = "vt=" .. table.concat(vts, ",")
    for _, f in ipairs(s.fields) do
        parts[#parts + 1] = f.name .. "=" .. f.read(obj)
    end
    return table.concat(parts, " ")
end

-- the census: the number of objects of a database, if its kind's layout is known
function layout.census_count(db, kind)
    if kind ~= "single" and kind ~= "extendable" then
        return nil
    end
    local a = ffi.C.hdb_sym("_ZN13TGameDatabaseI" .. mangle(db) .. "E10_pInstanceE")
    if a == 0 then
        return nil
    end
    local inst = ffi.cast("void **", a)[0]
    if inst == nil then
        return nil
    end
    return i32(inst, 0x5c)
end

return layout
