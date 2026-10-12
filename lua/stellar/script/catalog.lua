-- catalog.lua : what the game's script engine knows, read from the running game (see
-- docs/script_engine.md).
--
-- Every key the script reader understands is a token: an id the lexer (CStaticLexer) assigns to a
-- name. About 10,000 are compiled in (GetTokenArray); the rest are added while the game starts and
-- loads (CStaticLexer::AddDynamicToken), e.g. the iterators every_*, random_*, any_*, count_* of
-- the script lists. Triggers and effects are registered by token: CTriggerDatabase and
-- CEffectDatabase map a token id to an entry, which creates the trigger or effect object and
-- carries its documentation string.
--
--   local catalog = require("stellar.script.catalog")
--   local where = catalog.locate(image, stellar.read)   -- once per build
--   local c = catalog.read(where, stellar.read)
--   c.tokens[id] -> name, c.token_ids[name] -> id
--   c.triggers[name], c.effects[name] -> { id, name, description, entry, create, vtable, size }
--   c.trigger_list, c.effect_list: the same, in id order
--   c.by_vtable[vtable] -> entry, catalog.identify(c, object): what a compiled object of the game
--   is (the script the game has read is a tree of such objects)
--
-- Only checked reads are used (`read` is stellar.read in the game), so the init thread can call
-- read() while the game runs: a structure the main thread is changing gives wrong data, not a
-- crash. The trigger and effect tables do not change once the game has started; the lexer grows
-- while the game loads, so read it again from the main thread (a tick) for a consistent view.

local fnmatch = require("fnmatch")
local ffi = require("ffi")
local signatures = require("stellar.signatures")
local memory = require("stellar.script.memory")

local catalog = {}

local FUNCTIONS = {
    lexer = "CStaticLexer::AccessStaticLexer",
    registry = "CScriptListsRegistryHelper<CAgreementListBuilder>::CScriptListsRegistryHelper<CAgreementListBuilder>",
}

-- The script classes that are not created by a token's entry, and a method each has in its vtable
-- (the first match names a vtable): scripted triggers and effects (`is_xenophile = yes`), scope
-- changes (`owner = { }`), modifier blocks (`modifier = { factor = 2 <triggers> }`), random_list
-- entries, and the plain blocks (`limit = { }`, `immediate = { }`).
local STRUCTURAL = {
    { kind = "(scripted trigger)", of = "trigger", method = "CScriptedTrigger::ActualEvaluate" },
    { kind = "(scope trigger)", of = "trigger", method = "CContextTrigger::ReadMember" },
    { kind = "(modifier block)", of = "trigger", method = "CTriggerMTTHModifier::ReadMember" },
    { kind = "(scripted effect)", of = "effect", method = "CScriptedEffect::Read" },
    { kind = "(scope effect)", of = "effect", method = "CContextEffect::ReadMember" },
    { kind = "(random_list entry)", of = "effect", method = "CRandomListEffect::CEntryEffect::ReadMember" },
    { kind = "(trigger block)", of = "trigger", method = "CAndTrigger::ReadMember" },
    { kind = "(effect block)", of = "effect", method = "CEffect::ReadMember" },
}
local VTABLE_SLOTS = 12
local STRUCTURAL_OF = {}
for _, s in ipairs(STRUCTURAL) do
    STRUCTURAL_OF[s.kind] = s.of
end

-- Layouts in 4.5.2 (from the PDB)
local LEXER = {
    size = 0x88,
    dynamic_data = 0x58,   -- CPdxArray<CToken *, int> _DynamicTokens: _pData, _nSize
    dynamic_size = 0x64,
    lookup_data = 0x70,    -- CPdxArray<CString, int> _LookUp (id -> name): _pData, _nSize
    lookup_size = 0x7c,
    desired_lookup = 0x80, -- _LookUp is up to date when its size is this
    base = 0x84,           -- dynamic token i has the id _nBase + 1 + i
}
local CSTRING_SIZE = 48    -- std::basic_string with a 16-byte allocator: text at +16, size +32, capacity +40
local TOKEN_NAME = 16      -- CToken: int _LexerToken, ..., CPdxHybridArray<char> _Val (char *_pData at +16)
local TRIGGER_ENTRIES = 0x88 -- CTriggerDatabase: std::map<int, CTriggerEntryBase *> _TriggerEntries
local EFFECT_ENTRIES = 0x18  -- CEffectDatabase: std::map<int, CEffectEntryBase *> _EffectEntries

local function alternatives(name)
    local list = {}
    local overloads = signatures.functions[name]
    for _, from in ipairs(overloads and overloads[1] or {}) do
        for _, sig in ipairs(from.signatures) do
            list[#list + 1] = sig
        end
    end
    return list
end

-- Little-endian values in a string of bytes (offsets from 0), checked reads
local u8, i32, u32, u64 = memory.u8, memory.i32, memory.u32, memory.u64
local strict = memory.strict

-- A NUL-terminated string (an error if it cannot be read)
local function cstring(read, address, max)
    return memory.cstring(memory.strict(read), address, max)
end

-- catalog.locate(image, read) -> where | nil, message
-- where: lexer (the CStaticLexer), trigger_database and effect_database (the addresses of the
-- static pointers CTriggerDatabase::_pTriggerDatabase and CEffectDatabase::_pEffectDatabase), and
-- methods: the methods of the STRUCTURAL classes that were found (address -> kind).
function catalog.locate(image, read)
    local bundle = fnmatch.bundle(image)
    local entries = {}
    for key, name in pairs(FUNCTIONS) do
        entries[key] = bundle:register({ name = name, signatures = alternatives(name) })
    end
    local structural = {}
    for i, s in ipairs(STRUCTURAL) do
        structural[i] = bundle:register({ name = s.method, signatures = alternatives(s.method), required = false })
    end
    local run = bundle:run()
    if not run.ok then
        return nil, "fnmatch: " .. tostring(run.error)
    end
    local ok, result = pcall(function()
        local r = strict(read)
        local function code(key)
            local f = image:function_at(entries[key].address)
            return f.address, r(f.address, f.end_address - f.address)
        end
        local where = {}

        -- AccessStaticLexer returns the address of its static instance: lea rax, [rip+x]
        local at, bytes = code("lexer")
        for o = 0, #bytes - 7 do
            if u8(bytes, o) == 0x48 and u8(bytes, o + 1) == 0x8d and u8(bytes, o + 2) == 0x05 then
                local lexer = at + o + 7 + i32(bytes, o + 3)
                if where.lexer and where.lexer ~= lexer then
                    error("CStaticLexer::AccessStaticLexer: two different instances", 0)
                end
                where.lexer = lexer
            end
        end
        if not where.lexer then
            error("CStaticLexer::AccessStaticLexer: no lea rax, [rip+x]", 0)
        end

        -- The registry helper creates the databases when they do not exist yet:
        --   mov reg, [rip+_pEffectDatabase]; test reg, reg; jne; lea ecx, [reg+112]; call operator new
        --   mov reg, [rip+_pTriggerDatabase]; test reg, reg; jne; call CTriggerDatabase::CreateInstance
        at, bytes = code("registry")
        for o = 0, #bytes - 16 do
            local rex, op, modrm = u8(bytes, o), u8(bytes, o + 1), u8(bytes, o + 2)
            if (rex == 0x48 or rex == 0x4c) and op == 0x8b and modrm < 0x40 and modrm % 8 == 5
                and (u8(bytes, o + 7) == 0x48 or u8(bytes, o + 7) == 0x4d) and u8(bytes, o + 8) == 0x85
                and u8(bytes, o + 10) == 0x75 then
                local global = at + o + 7 + i32(bytes, o + 3)
                local key
                if u8(bytes, o + 12) == 0x8d and u8(bytes, o + 14) == 112 then
                    key = "effect_database"
                elseif u8(bytes, o + 12) == 0xe8 then
                    key = "trigger_database"
                end
                if key then
                    if where[key] and where[key] ~= global then
                        error("the registry helper names two different " .. key .. "s", 0)
                    end
                    where[key] = global
                end
            end
        end
        if not where.effect_database or not where.trigger_database then
            error("the registry helper does not name both databases", 0)
        end

        where.methods = {}
        for i, s in ipairs(STRUCTURAL) do
            if structural[i].found then
                where.methods[structural[i].address] = s.kind
            end
        end
        return where
    end)
    if not ok then
        return nil, result
    end
    return result
end

-- The (key, value) pairs of an MSVC std::map<int, T *> in key order: the head node (at the map's
-- address) is a sentinel; nodes are { left, parent, right, color, isnil, key at +32, value at +40 }.
local function map_pairs(r, map)
    local head = u64(r(map, 8), 0)
    local size = u64(r(map + 8, 8), 0)
    if size > 100000 then
        error(string.format("std::map at 0x%x: implausible size %d", map, size), 0)
    end
    local list = {}
    local function node(n)
        local b = r(n, 48)
        return u64(b, 0), u64(b, 16), u8(b, 25) ~= 0, i32(b, 32), u64(b, 40)
    end
    -- in-order walk without recursion
    local root = u64(r(head + 8, 8), 0)
    local stack, n = {}, root
    while true do
        while n ~= head and n ~= 0 do
            local left, _, isnil = node(n)
            if isnil then
                break
            end
            stack[#stack + 1] = n
            n = left
        end
        if #stack == 0 then
            break
        end
        n = table.remove(stack)
        local _, right, _, key, value = node(n)
        list[#list + 1] = { key, value }
        if #list > size then
            error(string.format("std::map at 0x%x: more nodes than its size %d", map, size), 0)
        end
        n = right
    end
    if #list ~= size then
        error(string.format("std::map at 0x%x: %d nodes, size %d", map, #list, size), 0)
    end
    return list
end

-- The lexer's names: id -> name.
local function read_tokens(r, lexer)
    local l = r(lexer, LEXER.size)
    local tokens, count = {}, 0
    local lookup, lookup_size = u64(l, LEXER.lookup_data), i32(l, LEXER.lookup_size)
    local stale = lookup_size ~= i32(l, LEXER.desired_lookup)
    if lookup ~= 0 and lookup_size > 0 and lookup_size < 1000000 then
        local all = r(lookup, lookup_size * CSTRING_SIZE)
        for id = 0, lookup_size - 1 do
            local o = id * CSTRING_SIZE
            local size, capacity = u64(all, o + 32), u64(all, o + 40)
            if size > 0 and size < 4096 then
                local name
                if capacity < 16 then
                    name = all:sub(o + 17, o + 16 + size)
                else
                    name = r(u64(all, o + 16), size)
                end
                tokens[id] = name
                count = count + 1
            end
        end
    end
    -- dynamic tokens added since the lookup was built
    local base, dynamic, dynamic_size = i32(l, LEXER.base), u64(l, LEXER.dynamic_data), i32(l, LEXER.dynamic_size)
    if dynamic ~= 0 and dynamic_size > 0 and dynamic_size < 1000000 then
        local pointers = r(dynamic, dynamic_size * 8)
        for i = 0, dynamic_size - 1 do
            local id = base + 1 + i
            if tokens[id] == nil then
                local token = u64(pointers, i * 8)
                tokens[id] = cstring(r, u64(r(token + TOKEN_NAME, 8), 0))
                count = count + 1
            end
        end
    end
    return tokens, count, { lookup = lookup_size, dynamic = dynamic_size, base = base, stale = stale }
end

-- The callee-saved registers (rbx, rbp, rsi, rdi, r12 to r15): only these keep the object across
-- the rest of the function; a volatile copy (rcx for a call) is soon reused for something else.
local CALLEE_SAVED = { [3] = true, [5] = true, [6] = true, [7] = true, [12] = true, [13] = true, [14] = true, [15] = true }

-- The callee-saved registers a `mov reg, source` copies source into in code[from, to) (REX.W 8b /r
-- with rm = source, or 89 /r with reg = source; register-to-register only).
local function copies(code, from, to, source, into)
    for o = from, math.min(to, #code - 3) do
        local rex, op, modrm = u8(code, o), u8(code, o + 1), u8(code, o + 2)
        if rex >= 0x48 and rex <= 0x4f and modrm >= 0xc0 then
            local r_field = math.floor(modrm / 8) % 8 + (rex >= 0x4c and 8 or 0)
            local m_field = modrm % 8 + (rex % 2 == 1 and 8 or 0)
            if op == 0x8b and m_field == source and CALLEE_SAVED[r_field] then
                into[r_field] = true
            elseif op == 0x89 and r_field == source and CALLEE_SAVED[m_field] then
                into[m_field] = true
            end
        end
    end
end

-- Scans a function up to its first epilogue (`pop reg; ret` or `add rsp, n; ret`, at most 1024
-- bytes): the size of the first `mov ecx, size; call` (operator new), the targets of the calls
-- (byte-level, so possibly a few false ones), and the vtable of the last
-- `lea reg, [rip+vtable]; mov [obj], reg` where obj holds the object: in a Create, the callee-saved
-- register rax (the result of operator new) is copied into right after the call (rax itself when
-- there is none), in a constructor the one rcx (this) is copied into in the prologue (rcx itself
-- when there is none). Stores into members do not count.
local function scan(read, address, this)
    local code = read(address, 1024) or read(address, 4096 - address % 4096)
    if code == nil then
        return {}
    end
    local s = { calls = {} }
    local obj = {}
    if this then
        copies(code, 0, 48, 1, obj)
        if next(obj) == nil then
            obj[1] = true
        end
    end
    for o = 0, #code - 10 do
        local b = u8(code, o)
        if s.size == nil and b == 0xb9 and u8(code, o + 5) == 0xe8 then
            s.size = u32(code, o + 1)
            if not this then
                copies(code, o + 10, o + 34, 0, obj)
                if next(obj) == nil then
                    obj[0] = true
                end
            end
        end
        if b == 0xe8 then
            s.calls[#s.calls + 1] = address + o + 5 + i32(code, o + 1)
        end
        local rex, op, modrm = b, u8(code, o + 1), u8(code, o + 2)
        -- lea r64, [rip+x] (48/4c 8d modrm 00 reg 101) then mov [base], r64 (48/49/4c/4d 89 modrm 00 reg base)
        if (rex == 0x48 or rex == 0x4c) and op == 0x8d and modrm < 0x40 and modrm % 8 == 5 then
            local rex2, op2, modrm2 = u8(code, o + 7), u8(code, o + 8), u8(code, o + 9)
            local reg = math.floor(modrm / 8) + (rex == 0x4c and 8 or 0)
            local reg2 = math.floor(modrm2 / 8) % 8 + ((rex2 == 0x4c or rex2 == 0x4d) and 8 or 0)
            local base = modrm2 % 8 + ((rex2 == 0x49 or rex2 == 0x4d) and 8 or 0)
            if (rex2 == 0x48 or rex2 == 0x49 or rex2 == 0x4c or rex2 == 0x4d) and op2 == 0x89 and modrm2 < 0x40
                and reg2 == reg and base % 8 ~= 4 and base % 8 ~= 5 and obj[base] then
                s.vtable = address + o + 7 + i32(code, o + 3)
            end
        end
        if u8(code, o + 1) == 0xc3 and ((b >= 0x58 and b <= 0x5f) or (o >= 1 and u8(code, o - 1) == 0xc4)) then
            break
        end
    end
    return s
end

-- catalog.decode_create(read, address) -> size, vtable: what an entry's Create function makes. It
-- allocates the object (`mov ecx, size; call operator new`), then either constructs it inline,
-- storing the class's vtable last (`lea reg, [rip+vtable]; mov [obj], reg`), or calls the
-- class's constructor, which does. A Create that is a jmp (identical functions are folded) is
-- followed. Either value is nil when the code differs.
function catalog.decode_create(read, address)
    local bytes = read(address, 5)
    if bytes == nil then
        return nil, nil
    end
    if u8(bytes, 0) == 0xe9 then
        address = address + 5 + i32(bytes, 1)
    end
    local s = scan(read, address)
    local vtable = s.vtable
    if vtable == nil and #s.calls >= 2 then
        -- operator new, ..., the constructor
        vtable = scan(read, s.calls[#s.calls], true).vtable
    end
    return s.size, vtable
end

local function read_entries(r, read, database, offset, tokens)
    local list, by_name = {}, {}
    for _, kv in ipairs(map_pairs(r, database + offset)) do
        local id, entry = kv[1], kv[2]
        local e = r(entry, 16)
        local vtable, description = u64(e, 0), u64(e, 8)
        local item = {
            id = id,
            name = tokens[id] or ("#" .. id),
            entry = entry,
            create = u64(r(vtable + 8, 8), 0),
            description = description ~= 0 and cstring(r, description, 1024) or nil,
        }
        item.size, item.vtable = catalog.decode_create(read, item.create)
        list[#list + 1] = item
        by_name[item.name] = item
    end
    return list, by_name
end

-- catalog.write_tsv(c, path [, docs [, module_base]]) -> true | nil, message: one line per trigger,
-- effect and scope link: kind, token id, name, the RVAs of its Create function and of the vtable of
-- the objects it creates, their size, supported scopes and output scope (from the game's
-- documentation, stellar.script.docs), description.
function catalog.write_tsv(c, path, docs, module_base)
    local f, message = io.open(path, "wb")
    if f == nil then
        return nil, message
    end
    local function clean(s)
        return (tostring(s or ""):gsub("[\t\r\n]+", " "))
    end
    local function rva(address)
        if address == nil then
            return ""
        end
        return string.format("0x%x", address - (module_base or 0))
    end
    f:write("kind\tid\tname\tcreate_rva\tvtable_rva\tsize\tscopes\toutput\tdescription\n")
    for _, kind in ipairs({ "trigger", "effect" }) do
        local documented = docs and docs[kind .. "s"] or {}
        for _, e in ipairs(c[kind .. "_list"]) do
            local doc = documented[e.name] or {}
            f:write(string.format("%s\t%d\t%s\t%s\t%s\t%s\t%s\t\t%s\n", kind, e.id, e.name, rva(e.create), rva(e.vtable),
                e.size or "", table.concat(doc.scopes or {}, " "), clean(e.description or doc.description)))
        end
    end
    if docs then
        for _, name in ipairs(docs.scopes_order) do
            local doc = docs.scopes[name]
            f:write(string.format("scope\t%s\t%s\t\t\t\t%s\t%s\t%s\n", c.token_ids[name] or "", name,
                table.concat(doc.scopes or {}, " "), clean(doc.output), clean(doc.description)))
        end
    end
    f:close()
    return true
end

-- catalog.identify(c, object) -> entry, kind | nil: the trigger or effect a compiled object of the
-- game is, by its vtable (read with the LuaJIT FFI: the caller makes sure `object` is one).
-- Objects of the structural classes give their kind ("(scope trigger)", ...) once a census has
-- seen their vtable.
function catalog.identify(c, object)
    local vtable = tonumber(ffi.cast("uintptr_t *", object)[0])
    local e = c.by_vtable[vtable]
    if e then
        return e, c.triggers[e.name] == e and "trigger" or "effect"
    end
    local kind = c.structural and c.structural[vtable]
    if kind then
        return { name = kind }, STRUCTURAL_OF[kind]
    end
end

-- catalog.census(c, where, read [, keep]) -> census | nil, message: every trigger and effect object
-- the game has compiled from its script (CTriggerDatabase::_Triggers, a CPdxUnorderedSet at +0x8,
-- and CEffectDatabase::_Effects, a CPdxArray at +0x0), named by their vtables.
--   census.triggers, census.effects = { total, identified, by_name = { name -> count },
--                                       unknown = { vtable -> count }, objects = { name -> list } }
-- objects has the addresses of the objects whose name is in keep ({ name -> true }).
function catalog.census(c, where, read, keep)
    local ok, result = pcall(function()
        local r = strict(read)
        -- vtable -> structural kind (or false), from the methods in its first slots
        c.structural = c.structural or {}
        local address_of = {}
        for address, kind in pairs(where.methods or {}) do
            address_of[kind] = address
        end
        local function structural(vtable)
            local kind = c.structural[vtable]
            if kind == nil then
                kind = false
                local slots = read(vtable, VTABLE_SLOTS * 8)
                if slots then
                    local present = {}
                    for i = 0, VTABLE_SLOTS - 1 do
                        present[u64(slots, i * 8)] = true
                    end
                    for _, s in ipairs(STRUCTURAL) do
                        if address_of[s.kind] and present[address_of[s.kind]] then
                            kind = s.kind
                            break
                        end
                    end
                end
                c.structural[vtable] = kind
            end
            return kind
        end
        local function count(objects)
            local s = { total = #objects, identified = 0, by_name = {}, unknown = {}, objects = {} }
            for _, object in ipairs(objects) do
                local bytes = read(object, 8)
                local vtable = bytes and u64(bytes, 0)
                local e = vtable and c.by_vtable[vtable]
                local kind = vtable and not e and structural(vtable)
                if e or kind then
                    s.identified = s.identified + 1
                    local name = e and e.name or kind
                    s.by_name[name] = (s.by_name[name] or 0) + 1
                    if keep and keep[name] then
                        local list = s.objects[name] or {}
                        s.objects[name] = list
                        list[#list + 1] = object
                    end
                elseif vtable then
                    s.unknown[vtable] = (s.unknown[vtable] or 0) + 1
                end
            end
            return s
        end

        -- the triggers: a robin hood table of { int hash, uint8 distance + 1 (0: empty), CTrigger * at +8 }
        local trigger_database = u64(r(where.trigger_database, 8), 0)
        local t = r(trigger_database + 0x8, 0x20)
        local entries, size, mod, max_distance = u64(t, 0x8), i32(t, 0x10), i32(t, 0x14), u8(t, 0x18)
        local triggers = {}
        if entries ~= 0 and size > 0 then
            local slots = mod + 1 + max_distance
            local all = read(entries, slots * 16) or r(entries, (mod + 1) * 16)
            for i = 0, #all / 16 - 1 do
                if u8(all, i * 16 + 4) ~= 0 then
                    triggers[#triggers + 1] = u64(all, i * 16 + 8)
                end
            end
        end

        -- the effects: CPdxArray<CEffect *, int>: _pData at +8, _nSize at +0x14
        local effect_database = u64(r(where.effect_database, 8), 0)
        local a = r(effect_database, 0x18)
        local data, n = u64(a, 0x8), i32(a, 0x14)
        local effects = {}
        if data ~= 0 and n > 0 then
            local pointers = r(data, n * 8)
            for i = 0, n - 1 do
                effects[#effects + 1] = u64(pointers, i * 8)
            end
        end
        return { triggers = count(triggers), effects = count(effects), trigger_set_size = size }
    end)
    if not ok then
        return nil, result
    end
    return result
end

-- catalog.read(where, read) -> catalog | nil, message
function catalog.read(where, read)
    local ok, result = pcall(function()
        local r = strict(read)
        local c = {}
        c.tokens, c.token_count, c.lexer = read_tokens(r, where.lexer)
        c.token_ids = {}
        for id, name in pairs(c.tokens) do
            c.token_ids[name] = id
        end
        local trigger_database = u64(r(where.trigger_database, 8), 0)
        local effect_database = u64(r(where.effect_database, 8), 0)
        c.trigger_list, c.triggers = read_entries(r, read, trigger_database, TRIGGER_ENTRIES, c.tokens)
        c.effect_list, c.effects = read_entries(r, read, effect_database, EFFECT_ENTRIES, c.tokens)
        -- vtable -> entry; a few classes are shared (aliases such as owned_planet / owned_colony),
        -- the first entry keeps the vtable
        c.by_vtable = {}
        for _, list in ipairs({ c.trigger_list, c.effect_list }) do
            for _, e in ipairs(list) do
                if e.vtable and c.by_vtable[e.vtable] == nil then
                    c.by_vtable[e.vtable] = e
                end
            end
        end
        return c
    end)
    if not ok then
        return nil, result
    end
    return result
end

return catalog
