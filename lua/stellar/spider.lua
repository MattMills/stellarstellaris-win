-- spider.lua : walks the game's objects in memory, typed by the GOG build's PDB.
--
-- The game has no RTTI. tools/re/spider writes three tables, kept next to the DLL in cache/:
--   spider_types-<md5>.tsv    every class reachable from the game (typecrawl.py): its template and
--                             arguments, size, whether it has a vtable, its bases
--   spider_members-<md5>.tsv  their members: offset, name, type
--   spider_vtables-<md5>.tsv  every vtable of this build (vtmap.lua): its address -> the class, and
--                             which base's vtable it is (a pointer to that base points into the
--                             object at the base's offset)
-- From roots (the databases' instances, the game state's database), the spider visits every object
-- reachable: an object with a vtable is the class its vtable names (a CTrigger * may hold any
-- trigger), its members are followed by their types, and containers by their template:
-- CPdxArray<T> (CPdxHybridArray), TPdxRefDatabase<T, n>, std::vector, std::list, std::map /
-- std::set. Each template is walked by one function, its arguments as parameters.
--
--   local spider = require("stellar.spider")
--   local s = assert(spider.load(dir, md5))
--   local report = s:walk({ { address = a, class = "CGameStateDatabase", name = "game state" }, ... })

local ffi = require("ffi")
local stellar = require("stellar")

local spider = {}
spider.__index = spider

local SCALARS = { char = 1, int8 = 1, uint8 = 1, bool = 1, short = 2, uint16 = 2, wchar = 2, char16 = 2,
    int = 4, uint = 4, long = 4, ulong = 4, float = 4, char32 = 4, int64 = 8, uint64 = 8, double = 8 }

local function split(line)
    local out = {}
    for field in (line .. "\t"):gmatch("([^\t]*)\t") do
        out[#out + 1] = field
    end
    return out
end

-- the template's arguments, split at the top level
local function arguments(text)
    local out, depth, current = {}, 0, {}
    for c in text:gmatch(".") do
        if c == "<" then
            depth = depth + 1
        elseif c == ">" then
            depth = depth - 1
        end
        if c == "|" and depth == 0 then
            out[#out + 1] = table.concat(current):match("^%s*(.-)%s*$")
            current = {}
        else
            current[#current + 1] = c
        end
    end
    local last = table.concat(current):match("^%s*(.-)%s*$")
    if last ~= "" then
        out[#out + 1] = last
    end
    return out
end

-- spider.load(dir, md5) -> spider | nil, why
function spider.load(dir, md5)
    local s = setmetatable({ types = {}, vtables = {}, descs = {} }, spider)
    local path = dir .. "\\spider_types-" .. md5 .. ".tsv"
    local f = io.open(path, "r")
    if not f then
        return nil, "no " .. path .. " (tools/re/spider)"
    end
    f:read("*l")
    for line in f:lines() do
        local c = split(line)
        -- class, template, arguments, size, depth, reached_from, vtable, bases, members, derived, persisted
        if c[4] ~= "" then
            local bases = {}
            for b, off in (c[8] or ""):gmatch("([^;]+)@(%d+)") do
                bases[#bases + 1] = { name = b, offset = tonumber(off) }
            end
            s.types[c[1]] = { name = c[1], template = c[2], args = arguments(c[3] or ""), size = tonumber(c[4]) or 0,
                vtable = c[7] == "yes", bases = bases, members = {} }
        end
    end
    f:close()
    path = dir .. "\\spider_members-" .. md5 .. ".tsv"
    f = io.open(path, "r")
    if not f then
        return nil, "no " .. path
    end
    f:read("*l")
    for line in f:lines() do
        local c = split(line)
        local t = s.types[c[1]]
        if t then
            t.members[#t.members + 1] = { offset = tonumber(c[2]), name = c[3], type = c[4] }
        end
    end
    f:close()
    path = dir .. "\\spider_vtables-" .. md5 .. ".tsv"
    f = io.open(path, "r")
    if not f then
        return nil, "no " .. path
    end
    f:read("*l")
    for line in f:lines() do
        local c = split(line)
        -- target_rva, gog_rva, slots, found, agree, how, name: const X::`vftable'{for `B'}
        local cls = c[7] and c[7]:match("^const (.-)::`vftable'")
        if cls then
            cls = cls:gsub("class ", ""):gsub("struct ", ""):gsub(", ", ",")
            local base = c[7]:match("{for `(.-)'}")
            base = base and base:gsub("class ", ""):gsub("struct ", ""):gsub(", ", ",")
            local rva = tonumber(c[1], 16)
            if rva and not s.vtables[rva] then
                s.vtables[rva] = { class = cls, base = base }
            end
        end
    end
    f:close()
    -- PDB names spell template arguments "A *,int"; the vtables' names "class A *, int": both normalized
    local normalized = {}
    for name, t in pairs(s.types) do
        normalized[(name:gsub(", ", ","))] = t
    end
    s.normalized = normalized
    return s
end

function spider:class(name)
    return self.types[name] or (name and self.normalized[(name:gsub("class ", ""):gsub("struct ", ""):gsub(", ", ","))])
end

-- where base `name` is in class t (recursively), or nil
function spider:base_offset(t, name, depth)
    if t == nil or (depth or 0) > 8 then
        return nil
    end
    if t.name == name or (t.name:gsub(", ", ",")) == name then
        return 0
    end
    for _, b in ipairs(t.bases) do
        local off = self:base_offset(self:class(b.name), name, (depth or 0) + 1)
        if off then
            return b.offset + off
        end
    end
    return nil
end

-- whether instances of t have a vtable (t or a base introduces one)
function spider:polymorphic(t, depth)
    if t == nil or (depth or 0) > 8 then
        return false
    end
    if t.poly == nil then
        local p = t.vtable
        for _, b in ipairs(t.bases) do
            p = p or self:polymorphic(self:class(b.name), (depth or 0) + 1)
        end
        t.poly = p
    end
    return t.poly
end

-- a member's type string -> { kind = "scalar" | "pointer" | "class" | "array" | "opaque", ... }
function spider:desc(text)
    local d = self.descs[text]
    if d then
        return d
    end
    local inner, count
    if SCALARS[text] then
        d = { kind = "scalar", size = SCALARS[text] }
    elseif text:match("[%*&]$") then
        -- the class pointed to, without its qualifiers ("const CNamedColor*", "CNamedColor const *")
        local to = text:sub(1, -2):gsub("%s+$", ""):gsub("^const ", ""):gsub(" const$", ""):gsub("^volatile ", "")
        d = { kind = "pointer", to = to }
    elseif text:match("^const ") then
        d = self:desc(text:sub(7))
    elseif text:match("%[%d+ bytes%]$") then
        inner, count = text:match("^(.*)%[(%d+) bytes%]$")
        d = { kind = "array", of = inner, bytes = tonumber(count) }
    elseif self:class(text) then
        d = { kind = "class", class = self:class(text) }
    else
        d = { kind = "opaque" }
    end
    self.descs[text] = d
    return d
end

-- reading: the game's memory, checked (stellar.read: nil where it cannot be read)
local function u64(bytes, off)
    return tonumber(ffi.cast("const uint64_t *", ffi.cast("const uint8_t *", bytes) + off)[0])
end
local function i32(bytes, off)
    return ffi.cast("const int32_t *", ffi.cast("const uint8_t *", bytes) + off)[0]
end
local function u32(bytes, off)
    return ffi.cast("const uint32_t *", ffi.cast("const uint8_t *", bytes) + off)[0]
end

-- spider:walk(roots[, options]) -> report: options.max_objects (default 5,000,000). Every object is
-- read once; its members are read from those bytes at their offsets (no copies), the objects they
-- point to are queued once (by address)
function spider:walk(roots, options)
    options = options or {}
    local max_objects = options.max_objects or 5000000
    local base = stellar.module_base
    local seen = {}            -- address -> true once queued
    local counts, bytes_by = {}, {}
    local objects, unreadable, unnamed, truncated, bad = 0, 0, 0, false, 0
    local unnamed_by, unnamed_vtables = {}, {}
    local queue_address, queue_type, head, tail = {}, {}, 1, 0
    local by_template = {}

    local function push(address, t)
        if address == nil or t == nil or address < 0x10000 or address >= 0x7fffffffffff or seen[address] then
            return
        end
        seen[address] = true
        tail = tail + 1
        queue_address[tail], queue_type[tail] = address, t
    end

    -- an object of static class t at address: its dynamic class (the vtable's), and its start
    local function dynamic(address, t)
        if not self:polymorphic(t) then
            return address, t
        end
        local head_bytes = stellar.read(address, 8)
        if not head_bytes then
            unreadable = unreadable + 1
            return nil
        end
        local vtable = u64(head_bytes, 0)
        local vt = self.vtables[vtable - base]
        if not vt then
            unnamed = unnamed + 1
            unnamed_by[t.name] = (unnamed_by[t.name] or 0) + 1
            unnamed_vtables[vtable] = (unnamed_vtables[vtable] or 0) + 1
            return nil
        end
        local d = self:class(vt.class)
        if not d then
            return address, t
        end
        local off = vt.base and self:base_offset(d, vt.base) or 0
        return address - (off or 0), d
    end

    local follow_members, follow_value

    -- the size of a value of this type (0: not followed)
    local function size_of(d)
        return d.kind == "pointer" and 8 or (d.kind == "class" and d.class.size) or (d.kind == "scalar" and d.size) or 0
    end

    -- count values of type text stored from data (inline objects, or pointers)
    local function elements(data, count, text)
        if data == 0 or count <= 0 then
            return
        end
        if count > 20000000 then
            bad = bad + 1
            return
        end
        local d = self:desc(text)
        local size = size_of(d)
        if size == 0 or d.kind == "scalar" or d.kind == "opaque" then
            return
        end
        local chunk = math.max(1, math.floor(262144 / size))
        for first = 0, count - 1, chunk do
            local n = math.min(chunk, count - first)
            local raw = stellar.read(data + first * size, n * size)
            if not raw then
                unreadable = unreadable + 1
                return
            end
            for k = 0, n - 1 do
                follow_value(data + (first + k) * size, text, raw, k * size)
            end
        end
    end

    -- the templates' walkers: (t, address, bytes, at): the container's bytes start at `at`
    local templates = {}
    local function array(t, address, bytes, at)
        if #bytes >= at + 24 then
            local data, capacity, size = u64(bytes, at + 8), i32(bytes, at + 16), i32(bytes, at + 20)
            if size >= 0 and size <= capacity then
                elements(data, size, t.args[1])
            else
                bad = bad + 1
            end
        end
    end
    templates["CPdxArray<>"] = array
    templates["CPdxHybridArray<>"] = array
    templates["std::vector<>"] = function(t, address, bytes, at)
        local first, last = u64(bytes, at), u64(bytes, at + 8)
        local d = self:desc(t.args[1] or "")
        local size = size_of(d)
        if size > 0 and last >= first and first ~= 0 then
            elements(first, math.floor((last - first) / size), t.args[1])
        end
    end
    -- TPdxRefDatabase<T, n>: the lookup array (_pLookupArray, _nLookupArraySize elements of
    -- { nNextDeadElement, nPrevDeadElement, T *pObject }): every live object (the pages hold them)
    templates["TPdxRefDatabase<>"] = function(t, address, bytes, at)
        local obj = self:class(t.args[1])
        if not obj or #bytes < at + 0x28 then
            return
        end
        local lookup, n = u64(bytes, at + 0x18), u32(bytes, at + 0x20)
        if lookup == 0 or n == 0 or n > 50000000 then
            return
        end
        local list = stellar.read(lookup, n * 16)
        if not list then
            unreadable = unreadable + 1
            return
        end
        for k = 0, n - 1 do
            local p = u64(list, k * 16 + 8)
            if p ~= 0 then
                push(p, obj)
            end
        end
    end
    -- CPdxRobinHoodTable<E, ...> (CPdxUnorderedMap, CPdxUnorderedSet): _pEntries, _Size, _TableMod,
    -- _MaxDistancePlus1: mod + 1 + max distance slots of { int _Hash, uint8 _DistancePlus1 (0:
    -- empty), E at +8 }
    templates["CPdxRobinHoodTable<>"] = function(t, address, bytes, at)
        local e = t.args[1]
        if not e or #bytes < at + 0x19 then
            return
        end
        local entries, size, mod, maxd = u64(bytes, at + 8), i32(bytes, at + 0x10), i32(bytes, at + 0x14), bytes:byte(at + 0x19)
        if entries == 0 or size <= 0 or mod < 0 or mod > 50000000 or size > mod + 1 + maxd then
            if size > 0 then
                bad = bad + 1
            end
            return
        end
        local slot_type = self:class("NPdxRobinHoodTable::SEntry<" .. e .. ">")
        local d = self:desc(e)
        local slot = slot_type and slot_type.size or (8 + size_of(d))
        slot = math.ceil(slot / 8) * 8
        local slots = mod + 1 + maxd
        local chunk = math.max(1, math.floor(262144 / slot))
        for first = 0, slots - 1, chunk do
            local n = math.min(chunk, slots - first)
            local raw = stellar.read(entries + first * slot, n * slot)
            if not raw then
                unreadable = unreadable + 1
                return
            end
            for k = 0, n - 1 do
                if raw:byte(k * slot + 5) ~= 0 then
                    follow_value(entries + (first + k) * slot + 8, e, raw, k * slot + 8)
                end
            end
        end
    end
    -- std::list<T>: _Myhead (a sentinel node: _Next, _Prev, _Myval), _Mysize
    templates["std::list<>"] = function(t, address, bytes, at)
        local sentinel, size = u64(bytes, at), u64(bytes, at + 8)
        if sentinel == 0 or size > 10000000 then
            return
        end
        local d = self:desc(t.args[1] or "")
        local vsize = size_of(d)
        if vsize == 0 then
            return
        end
        local raw = stellar.read(sentinel, 8)
        local n = raw and u64(raw, 0)
        local k = 0
        while n and n ~= 0 and n ~= sentinel and k < size do
            local node = stellar.read(n, 16 + vsize)
            if not node then
                unreadable = unreadable + 1
                break
            end
            follow_value(n + 16, t.args[1], node, 16)
            n = u64(node, 0)
            k = k + 1
        end
    end
    -- std::map<K, V> / std::set<K>: _Myhead (the sentinel of a red-black tree: _Left, _Parent,
    -- _Right, _Color, _Isnil, then the value at +32), _Mysize: the nodes in order
    local function tree(sentinel, size, value_text)
        if sentinel == 0 or size == 0 or size > 50000000 or not value_text then
            return
        end
        local d = self:desc(value_text)
        local vsize = math.max(size_of(d), 8)
        local raw = stellar.read(sentinel, 26)
        if not raw then
            return
        end
        local stack, n, visited = {}, u64(raw, 8), 0
        while true do
            while n ~= 0 and n ~= sentinel do
                local r = stellar.read(n, 26)
                if not r or r:byte(26) ~= 0 then
                    break
                end
                stack[#stack + 1] = n
                n = u64(r, 0)
            end
            if #stack == 0 then
                break
            end
            n = table.remove(stack)
            visited = visited + 1
            if visited > size then
                break
            end
            local node = stellar.read(n, 32 + vsize)
            if node then
                follow_value(n + 32, value_text, node, 32)
            end
            n = node and u64(node, 16) or 0
        end
    end
    templates["std::map<>"] = function(t, address, bytes, at)
        local pair = string.format("std::pair<%s const ,%s>", t.args[1] or "", t.args[2] or "")
        tree(u64(bytes, at), u64(bytes, at + 8), self:class(pair) and pair or nil)
    end
    templates["std::set<>"] = function(t, address, bytes, at)
        tree(u64(bytes, at), u64(bytes, at + 8), t.args[1])
    end

    -- the value of type text at address, its bytes at `at` in bytes
    follow_value = function(address, text, bytes, at)
        local d = self:desc(text)
        if d.kind == "pointer" then
            if #bytes >= at + 8 then
                local p = u64(bytes, at)
                if p ~= 0 then
                    local to = self:class(d.to)
                    if to then
                        push(p, to)
                    end
                end
            end
        elseif d.kind == "class" then
            follow_members(address, d.class, bytes, at)
        elseif d.kind == "array" then
            local of = self:desc(d.of)
            local size = size_of(of)
            if size > 0 and of.kind ~= "scalar" and of.kind ~= "opaque" then
                for k = 0, math.floor(d.bytes / size) - 1 do
                    follow_value(address + k * size, d.of, bytes, at + k * size)
                end
            end
        end
    end

    -- the object (or embedded value) of class t at address, its bytes at `at` in bytes
    follow_members = function(address, t, bytes, at)
        if #bytes < at + t.size then
            return
        end
        local walker = templates[t.template]
        if walker then
            by_template[t.template] = (by_template[t.template] or 0) + 1
            walker(t, address, bytes, at)
            return
        end
        for _, b in ipairs(t.bases) do
            local bt = self:class(b.name)
            if bt then
                follow_members(address + b.offset, bt, bytes, at + b.offset)
            end
        end
        for _, m in ipairs(t.members) do
            if m.offset >= 0 then
                follow_value(address + m.offset, m.type, bytes, at + m.offset)
            end
        end
    end

    for _, r in ipairs(roots) do
        push(r.address, self:class(r.class))
    end
    while head <= tail do
        local address, t = queue_address[head], queue_type[head]
        queue_address[head], queue_type[head] = nil, nil
        head = head + 1
        local start, d = dynamic(address, t)
        if start then
            if start ~= address then
                seen[start] = true
            end
            local bytes = stellar.read(start, math.max(d.size, 8))
            if not bytes then
                unreadable = unreadable + 1
            else
                objects = objects + 1
                counts[d.name] = (counts[d.name] or 0) + 1
                bytes_by[d.name] = (bytes_by[d.name] or 0) + d.size
                follow_members(start, d, bytes, 0)
                if objects >= max_objects then
                    truncated = true
                    break
                end
            end
        end
    end
    return { objects = objects, counts = counts, bytes = bytes_by, unreadable = unreadable, unnamed = unnamed,
        unnamed_by = unnamed_by, unnamed_vtables = unnamed_vtables, truncated = truncated, templates = by_template, bad = bad }
end

-- spider.summary(report[, top]) -> text
function spider.summary(report, top)
    local list = {}
    for name, n in pairs(report.counts) do
        list[#list + 1] = { name, n, report.bytes[name] or 0 }
    end
    table.sort(list, function(a, b) return a[2] > b[2] end)
    local classes, total = #list, 0
    for _, e in ipairs(list) do
        total = total + e[3]
    end
    local lines = { string.format("%d objects of %d classes, %.1f MB; %d reads failed, %d objects whose vtable is not named, %d containers with impossible counts%s",
        report.objects, classes, total / 1e6, report.unreadable, report.unnamed, report.bad or 0, report.truncated and " (stopped at the limit)" or "") }
    for i = 1, math.min(top or 25, #list) do
        lines[#lines + 1] = string.format("  %-60s %8d  %8.1f KB", list[i][1]:sub(1, 60), list[i][2], list[i][3] / 1e3)
    end
    local un = {}
    for name, n in pairs(report.unnamed_by) do
        un[#un + 1] = { name, n }
    end
    table.sort(un, function(a, b) return a[2] > b[2] end)
    for i = 1, math.min(8, #un) do
        lines[#lines + 1] = string.format("  unnamed, expected %s: %d", un[i][1], un[i][2])
    end
    return table.concat(lines, "\n")
end

return spider
