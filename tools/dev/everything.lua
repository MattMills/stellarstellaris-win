-- everything.lua : every compiled trigger and effect tree, compared with our reading of its file
-- (stellar.script.shadow.everything), in the running game. Copy it to dev\run.lua next to
-- stellar-injected.dll (with dev\enabled there, see lua/stellar/dev.lua); the report is written to
-- dev\parity.txt. About 25 s.
local state = ...
local stellar = require("stellar")
local util = require("stellar.util")
for _, m in ipairs({ "stellar.signatures", "stellar.script.memory", "stellar.script.catalog", "stellar.script.native",
    "stellar.script.source", "stellar.script.shadow" }) do
    package.loaded[m] = nil
end
local catalog = require("stellar.script.catalog")
local shadow = require("stellar.script.shadow")

local t0 = util.now()
-- locate again (the signatures of the structural methods may have changed)

local fnmatch = require("fnmatch")
local image = assert(fnmatch.module("stellaris.exe", { cache = util.dirname(stellar.dll_path) .. "\\cache" }))
state.where = assert(catalog.locate(image, stellar.read))
image:close()
local c = assert(catalog.read(state.where, stellar.read))
local census = assert(catalog.census(c, state.where, stellar.read))
state.catalog, state.census = c, census
print(string.format("dev: catalog and census in %.1fs", util.now() - t0))

t0 = util.now()
local r = shadow.everything({ catalog = c, read = stellar.read, game_dir = util.dirname(stellar.module_path),
    triggers = census.triggers.all, effects = census.effects.all, max_examples = 100000,
    log = function(line) print("dev: " .. line .. string.format(" (%.1fs)", util.now() - t0)) end })
print(string.format("dev: everything in %.1fs: %d files, %d nodes match, %d mismatches, %d roots inside scripted or inline content, %d file errors",
    util.now() - t0, r.files, r.matched, r.mismatches, r.indirect, #r.file_errors))

-- the report
local out = {}
local dirs = {}
for dir in pairs(r.directories) do
    dirs[#dirs + 1] = dir
end
table.sort(dirs)
local totals = { roots = 0, compared = 0, identical = 0, matched = 0, mismatches = 0, no_statement = 0 }
out[#out + 1] = string.format("%-45s %8s %8s %9s %9s %10s %12s", "directory", "roots", "compared", "identical", "nodes", "mismatches", "no statement")
for _, dir in ipairs(dirs) do
    local d = r.directories[dir]
    out[#out + 1] = string.format("%-45s %8d %8d %9d %9d %10d %12d", dir, d.roots, d.compared, d.identical, d.matched, d.mismatches, d.no_statement)
    for k in pairs(totals) do
        totals[k] = totals[k] + d[k]
    end
end
out[#out + 1] = string.format("%-45s %8d %8d %9d %9d %10d %12d", "all", totals.roots, totals.compared, totals.identical, totals.matched, totals.mismatches, totals.no_statement)
out[#out + 1] = ""
out[#out + 1] = "empty blocks without a location: " .. r.empty
out[#out + 1] = "roots inside scripted or inline content: " .. r.indirect
for kind, k in pairs(r.indirect_kinds) do
    out[#out + 1] = string.format("  %-25s %8d   e.g. %s", kind, k.count, k.example:sub(1, 300))
    local names = {}
    for name, count in pairs(k.names) do
        names[#names + 1] = { name, count }
    end
    table.sort(names, function(a, b) return a[2] > b[2] end)
    local top = {}
    for i = 1, math.min(#names, 12) do
        top[i] = names[i][1] .. " " .. names[i][2]
    end
    out[#out + 1] = "      " .. table.concat(top, ", ")
end
out[#out + 1] = "file errors: " .. #r.file_errors
for _, e in ipairs(r.file_errors) do
    out[#out + 1] = "  " .. e
end
out[#out + 1] = "inline script errors: " .. #r.expand_errors
for i = 1, math.min(#r.expand_errors, 20) do
    out[#out + 1] = "  " .. r.expand_errors[i]
end
out[#out + 1] = ""
out[#out + 1] = "keywords that made no node (trigger or effect keywords only), with places:"
local skipped = {}
for k, n in pairs(r.skipped) do
    if c.triggers[k] or c.effects[k] then
        skipped[#skipped + 1] = { k, n }
    end
end
table.sort(skipped, function(a, b) return a[2] > b[2] end)
for i = 1, math.min(#skipped, 60) do
    local k, n = skipped[i][1], skipped[i][2]
    out[#out + 1] = string.format("  %s %d", k, n)
    for _, at in ipairs(r.skipped_at[k] or {}) do
        out[#out + 1] = "      " .. at
    end
end
out[#out + 1] = ""
out[#out + 1] = "mismatches and roots without a statement (first " .. #r.examples .. "):"
for _, e in ipairs(r.examples) do
    out[#out + 1] = "  " .. e
end
local f = assert(io.open(util.dirname(stellar.dll_path) .. "\\dev\\parity.txt", "wb"))
f:write(table.concat(out, "\n"), "\n")
f:close()
print("dev: report written to dev\\parity.txt")
