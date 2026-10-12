-- resolve.lua : the game functions of functions.lua, found in the running build by their
-- stellar-fnmatch signatures (signatures.lua: the signatures they have in the reference builds,
-- tried in order). All of them in one bundle: one analysis, and the symbol relations between them
-- resolve. Done once per image.
--
--   local resolve = require("stellar.resolve")
--   local found, run = resolve.functions(image)   -- found[name] = address, nil when not found

local fnmatch = require("fnmatch")
local signatures = require("stellar.signatures")
local functions = require("stellar.functions")

local resolve = {}

-- The signatures of a function (of an overload, default the first) in every reference build, as
-- alternatives, the newest build's first.
function resolve.alternatives(name, overload)
    local list = {}
    local overloads = signatures.functions[name]
    for _, from in ipairs(overloads and overloads[overload or 1] or {}) do
        for _, sig in ipairs(from.signatures) do
            list[#list + 1] = sig
        end
    end
    return list
end

local done = setmetatable({}, { __mode = "k" })

-- resolve.functions(image) -> found, run: the address of every function of functions.lua that was
-- found (none is required: the modules that use them say what they miss), and the bundle's report.
function resolve.functions(image)
    local d = done[image]
    if d == nil then
        local bundle = fnmatch.bundle(image)
        local entries = {}
        for _, f in ipairs(functions) do
            entries[f.name] = bundle:register({ name = f.name, signatures = resolve.alternatives(f.name),
                required = false })
        end
        local run = bundle:run()
        local found = {}
        for name, e in pairs(entries) do
            found[name] = e.found and e.address or nil
        end
        d = { found = found, run = run }
        done[image] = d
    end
    return d.found, d.run
end

return resolve
