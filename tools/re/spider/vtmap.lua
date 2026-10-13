-- vtmap.lua <gog.exe> <gog.sig> <steam.exe> <data.tsv> <out.tsv> <cache dir> <refs.tsv> : every vtable the
-- GOG build's PDB names (data.tsv: "rva<TAB>const X::`vftable'..."), found in another build of the
-- same version with stellar-fnmatch (lua_fnmatch on LUA_CPATH). The game has no RTTI: this is how a
-- running game names its objects' classes.
--
-- Exactly, from the code that loads the vtable (refs.tsv, vtrefs.py: a constructor's
-- lea reg, [rip + vtable], by its ordinal among the function's rip-relative leas): that function
-- is found in the other build by its signatures (the .sig file of the GOG build), and its lea of the
-- same ordinal is the vtable there. A vtable no code loads is found by its slots: each slot's
-- function found by signature, the array of pointers to them, in that order, in the read-only data
-- (of candidates that agree as well, the nearest to the last delta: the read-only data is in the
-- same order in both builds).
-- Output: target_rva, gog_rva, slots, slots found by signature, slots that agree, how, name.

local fnmatch = require("fnmatch")
local ffi = require("ffi")
local gog_path, sig_path, target_path, data_path, out_path, cache, refs_path = arg[1], arg[2], arg[3], arg[4], arg[5], arg[6], arg[7]

-- the sections of a PE file, to read its data by RVA
local function pe(path)
    local f = assert(io.open(path, "rb"))
    local data = f:read("*a")
    f:close()
    local p = ffi.cast("const uint8_t *", data)
    local function u16(o) return p[o] + p[o + 1] * 256 end
    local function u32(o) return ffi.cast("const uint32_t *", p + o)[0] end
    local at = u32(0x3c)
    local count, first = u16(at + 6), at + 24 + u16(at + 20)
    local sections = {}
    for i = 0, count - 1 do
        local s = first + 40 * i
        sections[#sections + 1] = { name = ffi.string(p + s, 8):gsub("%z.*", ""), va = u32(s + 12),
            size = math.max(u32(s + 8), u32(s + 16)), raw = u32(s + 20) }
    end
    local image = { data = data, p = p, sections = sections }
    function image.qword(rva)
        for _, s in ipairs(sections) do
            if rva >= s.va and rva + 8 <= s.va + s.size and s.raw + rva - s.va + 8 <= #data then
                return ffi.cast("const uint64_t *", p + s.raw + rva - s.va)[0]
            end
        end
        return nil
    end
    function image.section(name)
        for _, s in ipairs(sections) do
            if s.name == name then
                return s
            end
        end
    end
    return image
end

local BASE = 0x140000000ULL
local gog_pe, target_pe = pe(gog_path), pe(target_path)
local reference = assert(fnmatch.sig_file(sig_path))
local target = assert(fnmatch.file(target_path, { cache = cache }))
local target_base = target:base()

-- GOG function rva -> target function rva (by its signatures), cached
local mapped_fn = {}
local function map_function(rva)
    local m = mapped_fn[rva]
    if m == nil then
        m = false
        local sigs = reference:signatures(rva)
        for _, sig in ipairs(sigs or {}) do
            local found = target:find(sig)
            if found and #found == 1 then
                m = found[1] - target_base
                break
            end
        end
        mapped_fn[rva] = m
    end
    return m or nil
end

-- the vtable a function of the target loads with its ordinal-th rip-relative lea (rva), or nil
local function lea_target(fn_rva, ordinal)
    local fd = target:function_at(target_base + fn_rva)
    if not fd then
        return nil
    end
    local code
    for _, sec in ipairs(target_pe.sections) do
        if fn_rva >= sec.va and fn_rva < sec.va + sec.size then
            local off = sec.raw + fn_rva - sec.va
            code = target_pe.data:sub(off + 1, off + (fd.end_address - fd.address))
        end
    end
    if not code then
        return nil
    end
    local pos, n = 1, 0
    while pos <= #code do
        local i = fnmatch.decode(code, fd.address, pos)
        if not i then
            break
        end
        if i.rip_relative and i.text:match('^lea ') then
            if n == ordinal then
                return i.target and (i.target - target_base) or nil
            end
            n = n + 1
        end
        pos = pos + i.length
    end
    return nil
end
local refs = {}
for line in io.lines(refs_path) do
    local v, fn, o = line:match('^(%x+)\t(%x+)\t(%d+)$')
    if v then
        local list = refs[tonumber(v, 16)] or {}
        list[#list + 1] = { tonumber(fn, 16), tonumber(o) }
        refs[tonumber(v, 16)] = list
    end
end

-- the target's read-only data: function rva -> places pointing to it
local rdata = assert(target_pe.section(".rdata"))
local text = assert(target_pe.section(".text"))
local pointed = {}
do
    local p = ffi.cast("const uint64_t *", target_pe.p + rdata.raw)
    for i = 0, math.floor(rdata.size / 8) - 1 do
        local v = p[i]
        if v >= BASE + text.va and v < BASE + text.va + text.size then
            local f = tonumber(v - BASE)
            local list = pointed[f]
            if not list then
                list = {}
                pointed[f] = list
            end
            list[#list + 1] = rdata.va + 8 * i
        end
    end
end

-- the GOG vtables and where their slots end (the next symbol)
local symbols, vtables = {}, {}
for line in io.lines(data_path) do
    local a, name = line:match("^(%x+)\t(.*)$")
    if a then
        local rva = tonumber(a, 16)
        symbols[#symbols + 1] = rva
        if name:find("`vftable'", 1, true) then
            vtables[#vtables + 1] = { rva = rva, name = name }
        end
    end
end
table.sort(symbols)
table.sort(vtables, function(a, b) return a.rva < b.rva end)
local gog_text = assert(gog_pe.section(".text"))
local function next_symbol(rva)
    local lo, hi = 1, #symbols
    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        if symbols[mid] <= rva then lo = mid + 1 else hi = mid end
    end
    return symbols[lo] > rva and symbols[lo] or rva + 8 * 1024
end
local function slots(rva)
    local out, stop = {}, next_symbol(rva)
    local a = rva
    while a < stop and #out < 2048 do
        local v = gog_pe.qword(a)
        if not v or v < BASE + gog_text.va or v >= BASE + gog_text.va + gog_text.size then
            break
        end
        out[#out + 1] = tonumber(v - BASE)
        a = a + 8
    end
    return out
end

local out = assert(io.open(out_path, "w"))
out:write("target_rva\tgog_rva\tslots\tfound\tagree\thow\tname\n")
local done, unmatched, ambiguous = 0, 0, 0
-- the two builds keep their read-only data in the same order, shifted by a slowly drifting delta:
-- of candidates that agree as well, the nearest to the last vtable's delta
local delta = nil
local by_code = 0
for _, vt in ipairs(vtables) do
    -- exactly, from the code that loads it
    local exact
    for _, r in ipairs(refs[vt.rva] or {}) do
        local fn = map_function(r[1])
        exact = fn and lea_target(fn, r[2])
        if exact then
            break
        end
    end
    local s = slots(vt.rva)
    -- the slots found in the target, and the candidates from the first one found
    local want, found = {}, 0
    for i, f in ipairs(s) do
        want[i] = map_function(f)
        found = found + (want[i] and 1 or 0)
    end
    local candidates = {}
    for i = 1, #s do
        if want[i] then
            for _, at in ipairs(pointed[want[i]] or {}) do
                candidates[at - 8 * (i - 1)] = true
            end
            break
        end
    end
    local best, best_agree, tie = nil, -1, false
    for at in pairs(candidates) do
        local agree = 0
        for i = 1, #s do
            local v = target_pe.qword(at + 8 * (i - 1))
            if want[i] and v and tonumber(v - BASE) == want[i] then
                agree = agree + 1
            end
        end
        if agree > best_agree then
            best, best_agree, tie = at, agree, false
        elseif agree == best_agree then
            if delta and math.abs(at - vt.rva - delta) < math.abs(best - vt.rva - delta) then
                best = at
            end
            tie = not delta
        end
    end
    if exact then
        done, by_code = done + 1, by_code + 1
        delta = exact - vt.rva
        out:write(string.format("%x\t%x\t%d\t%d\t%s\t%s\t%s\n", exact, vt.rva, #s, found, '-', 'code', vt.name))
    elseif best and best_agree >= math.max(1, math.ceil(found * 0.9)) and not tie then
        done = done + 1
        delta = best - vt.rva
        out:write(string.format("%x\t%x\t%d\t%d\t%d\t%s\t%s\n", best, vt.rva, #s, found, best_agree, 'slots', vt.name))
    elseif best and tie then
        ambiguous = ambiguous + 1
    else
        unmatched = unmatched + 1
    end
end
out:close()
local fns, fns_found = 0, 0
for _, m in pairs(mapped_fn) do
    fns = fns + 1
    fns_found = fns_found + (m and 1 or 0)
end
io.stderr:write(string.format("vtables %d: found %d (%d exactly from the code that loads them), ambiguous %d, not found %d; functions %d, found by signature %d\n",
    #vtables, done, by_code, ambiguous, unmatched, fns, fns_found))
