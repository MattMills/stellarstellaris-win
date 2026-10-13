-- make_modifier_types.lua : writes lua/stellar/graph/modifier_types_static.lua, the part of the
-- game's modifier types that stellar.graph.modifier_types does not generate from the databases,
-- from a modifiers.log and the game's files:
--   SHIP_SIZE_STATS  the stats every ship size has a type of (shipsize_<size>_<stat>)
--   TYPES            the types the game defines in code: the log's types up to the last one no
--                    generator makes
--
--   luajit tools/make_modifier_types.lua [game dir] [modifiers.log] [output]

local dir = (arg and arg[0] or ""):match("^(.*)[/\\]tools[/\\][^/\\]*$") or "."
package.path = dir .. "/lua/?.lua;" .. dir .. "/lib/stellar-lua-pdxscript/?.lua;" .. package.path

local source = require("stellar.script.source")
local static = require("stellar.graph.modifier_types_static")
local types = require("stellar.graph.modifier_types")

local game_dir = arg[1] or "/opt/stellaris"
local log_path = arg[2] or "/opt/stellaris-captures/modifiers-2211.07.01.log"
local out_path = arg[3] or (dir .. "/lua/stellar/graph/modifier_types_static.lua")

local fs = source.filesystem(game_dir)
local cache = {}
local function folder(name)
    if cache[name] == nil then
        cache[name] = source.definitions(fs, name)
    end
    return cache[name]
end

-- the log: names in order, their category labels
local f = assert(io.open(log_path, "rb"))
local text = f:read("*a")
f:close()
local order, labels, pos = {}, {}, {}
for line in text:gmatch("[^\n]+") do
    local name, cats = line:match("^%- ([%w_]+), Category: ([^\r]*)")
    if name and pos[name] == nil then
        order[#order + 1] = name
        pos[name] = #order
        labels[name] = cats
    end
end

-- the category lists, numbered in the order first seen
local categories, category_of = {}, {}
local function category(cats)
    local i = category_of[cats]
    if i == nil then
        local list = {}
        for c in cats:gmatch("[^,]+") do
            list[#list + 1] = c:match("^%s*(.-)%s*$")
        end
        categories[#categories + 1] = list
        i = #categories
        category_of[cats] = i
    end
    return i
end
for _, name in ipairs(order) do
    category(labels[name])
end

-- the ship size stats: those every size has, in the log's order for the first size
local sizes = {}
for key, def in pairs(folder("common/ship_sizes")) do
    sizes[#sizes + 1] = { key = key, file = def.file, line = def.line }
end
table.sort(sizes, function(a, b)
    if a.file ~= b.file then
        return a.file < b.file
    end
    return a.line < b.line
end)
local count = {}
for _, s in ipairs(sizes) do
    local prefix = "shipsize_" .. s.key .. "_"
    for _, name in ipairs(order) do
        if name:sub(1, #prefix) == prefix then
            local stat = name:sub(#prefix + 1)
            count[stat] = count[stat] or {}
            count[stat][s.key] = true
        end
    end
end
local stats = {}
for stat, seen in pairs(count) do
    local all = true
    for _, s in ipairs(sizes) do
        if not seen[s.key] then
            all = false
            break
        end
    end
    if all then
        stats[#stats + 1] = stat
    end
end
local first = "shipsize_" .. sizes[1].key .. "_"
table.sort(stats, function(a, b) return pos[first .. a] < pos[first .. b] end)
static.CATEGORIES = categories
static.SHIP_SIZE_STATS = {}
for i, stat in ipairs(stats) do
    static.SHIP_SIZE_STATS[i] = { stat, category(labels[first .. stat]) }
end

-- the types no generator makes
static.TYPES = {}
local made = {}
for _, t in ipairs(types.generate(folder)) do
    made[t[1]] = true
end
local rest = {}
local run
local function flush()
    if run and os.getenv("SHOW_RUNS") then
        print(string.format("  in code %5d-%5d (%d): %s .. %s", run.a, run.b, run.b - run.a + 1, order[run.a], order[run.b]))
    end
    run = nil
end
-- (the game defines them first: every type of the log up to the last one no generator makes, a
-- few of which a database registers again later)
local last = 0
for i, name in ipairs(order) do
    if not made[name] then
        last = i
        if run and run.b == i - 1 then
            run.b = i
        else
            flush()
            run = { a = i, b = i }
        end
    end
end
flush()
for i = 1, last do
    rest[i] = { order[i], category(labels[order[i]]) }
end

local lines = {
    "-- graph/modifier_types_static.lua : the game's modifier types that stellar.graph.modifier_types does",
    "-- not generate from the databases (4.5.2). Written by tools/make_modifier_types.lua from a",
    "-- modifiers.log; not edited by hand.",
    "--   CATEGORIES       the category lists (labels as modifiers.log prints them), by number",
    "--   SHIP_SIZE_STATS  { stat, category }: the stats every ship size has a type of (shipsize_<size>_<stat>)",
    "--   TYPES            { name, category }: the types the game defines in code, in its order",
    "",
    "return {",
    "    CATEGORIES = {",
}
for i, list in ipairs(categories) do
    local q = {}
    for j, c in ipairs(list) do
        q[j] = string.format("%q", c)
    end
    lines[#lines + 1] = string.format("        { %s }, -- %d", table.concat(q, ", "), i)
end
lines[#lines + 1] = "    },"
lines[#lines + 1] = "    SHIP_SIZE_STATS = {"
for _, s in ipairs(static.SHIP_SIZE_STATS) do
    lines[#lines + 1] = string.format("        { %q, %d },", s[1], s[2])
end
lines[#lines + 1] = "    },"
lines[#lines + 1] = "    TYPES = {"
for _, t in ipairs(rest) do
    lines[#lines + 1] = string.format("        { %q, %d },", t[1], t[2])
end
lines[#lines + 1] = "    },"
lines[#lines + 1] = "}"
local o = assert(io.open(out_path, "wb"))
o:write(table.concat(lines, "\n"), "\n")
o:close()
print(string.format("%s: %d category lists, %d ship size stats (%d sizes), %d types defined in code (of %d in the log)",
    out_path, #categories, #stats, #sizes, #rest, #order))
