-- report.lua : where are the functions the C++ patches target (stellar.targets) in this build?
--
-- Each target is looked up two ways: by its stellar-fnmatch signatures (signatures.lua, from PDB
-- builds) and, in the game, by the byte pattern the C++ code uses (address_helper.cpp). Patches
-- that rewrite instructions inside a function (assembly_patches.cpp) are checked too: the
-- instructions must be inside the function fnmatch found, and a patched call must call the
-- function it is supposed to. Everything is logged, and returned.

local fnmatch = require("fnmatch")
local targets = require("stellar.targets")
local signatures = require("stellar.signatures")
local util = require("stellar.util")
local hex = util.hex

local report = {}

-- The alternatives of a target: its signatures from every reference build, newest first, and the
-- build each one came from.
local function alternatives(t)
    local list, origin = {}, {}
    local overloads = signatures.functions[t.name]
    for _, from in ipairs(overloads and overloads[t.overload or 1] or {}) do
        for _, sig in ipairs(from.signatures) do
            list[#list + 1] = sig
            origin[#list] = signatures.references[from.reference].id
        end
    end
    return list, origin
end

local function label(t)
    return t.overload and string.format("%s [%d]", t.name, t.overload) or t.name
end

-- report.run(options) -> results | nil, message
--   image    an fnmatch image of the game; default: the stellaris.exe module of this process
--   module   the module to analyse (default "stellaris.exe")
--   cache    fnmatch cache directory
--   memory   search the process memory with sigmatch too (only in the game)
--   log      function(line), default print
function report.run(options)
    options = options or {}
    local log = options.log or print
    local module = options.module or "stellaris.exe"
    local t0 = util.now()
    local image, opened = options.image, nil
    if image == nil then
        local message
        image, message = fnmatch.module(module, { cache = options.cache })
        if image == nil then
            log("report: " .. message)
            return nil, message
        end
        opened = image
        log(string.format("report: %s analysed in %.1fs, %d functions, md5 %s", image:path(), util.now() - t0, #image, image:md5()))
    end
    for i, r in ipairs(signatures.references) do
        log(string.format("report: reference %d: %s, %s%s", i, r.id, r.build, r.md5 == image:md5() and " (this build)" or ""))
    end

    -- fnmatch: all targets in one bundle; found targets name their functions, for the symbol
    -- relations of the others
    t0 = util.now()
    local bundle = fnmatch.bundle(image)
    local entries = {}
    for i, t in ipairs(targets) do
        local list, origin = alternatives(t)
        if #list > 0 then
            entries[i] = bundle:register({ name = t.name, signatures = list, required = false })
            entries[i].origin = origin
        end
    end
    local run = bundle:run()
    log(string.format("report: fnmatch lookups in %.2fs, %d rounds", util.now() - t0, run.rounds))

    -- sigmatch: the C++ patterns, in the memory of the game
    local sigmatch, ffi, patterns
    if options.memory then
        sigmatch = require("sigmatch")
        ffi = require("ffi")
        local process = sigmatch.this_process_target()
        patterns = sigmatch.bundle(process)
        for i, t in ipairs(targets) do
            if t.pattern then
                entries[-i] = patterns:register({ name = t.name, module = module, signature = t.pattern, count = false, required = false })
            end
        end
        patterns:run()
    end

    local results, found, agree = {}, 0, 0
    local address_of = {}
    for i, t in ipairs(targets) do
        local e = entries[i]
        local r = { target = t, name = label(t) }
        results[i] = r
        if e and e.found then
            r.address = e.address
            r["function"] = image:function_at(e.address)
            r.signature = e.signature
            r.reference = e.origin[e.alternative]
            r.alternative = e.alternative
            address_of[t.name] = address_of[t.name] or e.address
            found = found + 1
        else
            r.error = e and e.error or "not in any reference build"
        end
    end

    for i, t in ipairs(targets) do
        local r = results[i]
        log(string.format("report: %s -- %s%s: %s", r.name, t.cpp.file, t.cpp.enabled and " (ENABLED)" or "", t.cpp.what))
        if r.address then
            local f = r["function"]
            log(string.format("report:     fnmatch   %s, %d bytes, by %s from %s (alternative %d of %d)", hex(r.address),
                f and f.size or 0, type(r.signature) == "table" and table.concat(r.signature, " + ") or r.signature,
                r.reference, r.alternative, #entries[i].signatures))
        elseif entries[i] then
            -- "alternative 1: 0 functions, expected 1; alternative 2: 3 functions, ..."
            local none, several = 0, 0
            for n in tostring(r.error):gmatch("(%d+) functions, expected") do
                if tonumber(n) == 0 then
                    none = none + 1
                else
                    several = several + 1
                end
            end
            log(string.format("report:     fnmatch   not found: of %d signatures, %d are on no function and %d on several",
                #entries[i].signatures, none, several))
        else
            log("report:     fnmatch   no signatures: " .. r.error)
        end

        if options.memory then
            if r.address then
                local first = ffi.cast("const uint8_t *", r.address)[0]
                if first == 0xE9 then
                    log("report:     the function starts with a jmp: hooked (by the C++ code?)")
                end
            end
            local p = entries[-i]
            if p then
                r.pattern_matches = p.matches or {}
                local m = r.pattern_matches
                local where
                if #m == 0 then
                    where = "no match"
                elseif #m == 1 then
                    where = hex(m[1]) .. (m[1] == r.address and " (the same function)" or (r.address and " (ANOTHER address)" or ""))
                else
                    local list = {}
                    for j = 1, math.min(#m, 4) do
                        list[j] = hex(m[j])
                    end
                    where = #m .. " matches: " .. table.concat(list, " ")
                end
                if #m == 1 and m[1] == r.address then
                    agree = agree + 1
                end
                log("report:     sigmatch  C++ pattern: " .. where)
            end
            if t.inside and r.address and r["function"] then
                local f = r["function"]
                local search = sigmatch.this_process_target():in_range(f.address, f.end_address - f.address):search(t.inside.pattern)
                r.inside_matches = search:matches()
                local m = r.inside_matches
                if #m == 1 then
                    local text = string.format("report:     inside    %s at %s (+0x%x)", t.inside.what, hex(m[1]), m[1] - f.address)
                    if t.calls then
                        local rel = ffi.cast("const int32_t *", m[1] + 1)[0]
                        local callee = m[1] + 5 + rel
                        r.calls_right = callee == address_of[t.calls]
                        text = text .. string.format(", calls %s %s", hex(callee),
                            r.calls_right and ("= " .. t.calls) or ("which is NOT " .. t.calls .. " (" .. hex(address_of[t.calls]) .. ")"))
                    end
                    log(text)
                else
                    log(string.format("report:     inside    %s: %d matches in the function, the patch cannot apply", t.inside.what, #m))
                end
            end
        end
    end
    log(string.format("report: %d of %d targets found by fnmatch%s", found, #targets,
        options.memory and string.format(", %d where the C++ pattern finds the same function", agree) or ""))

    if opened then
        opened:close()
    end
    return results
end

return report
