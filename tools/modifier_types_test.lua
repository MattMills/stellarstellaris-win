-- modifier_types_test.lua : stellar.graph.modifier_types against a modifiers.log: every type of the
-- log made from the databases, with its categories, and nothing else.
--
--   luajit tools/modifier_types_test.lua [game dir] [modifiers.log]

local dir = (arg and arg[0] or ""):match("^(.*)[/\\]tools[/\\][^/\\]*$") or "."
package.path = dir .. "/lua/?.lua;" .. dir .. "/lib/stellar-lua-pdxscript/?.lua;" .. package.path

local source = require("stellar.script.source")
local types = require("stellar.graph.modifier_types")
local gmod = require("stellar.graph.modifiers")

local game_dir = arg[1] or "/opt/stellaris"
local log_path = arg[2] or "/opt/stellaris-captures/modifiers-2211.07.01.log"

local fs = source.filesystem(game_dir)
local cache = {}
local function folder(name)
    if cache[name] == nil then
        cache[name] = source.definitions(fs, name)
    end
    return cache[name]
end

local t0 = os.clock()
local list = types.generate(folder)
print(string.format("%d types generated in %.1f s", #list, os.clock() - t0))

local f = assert(io.open(log_path, "rb"))
local text = f:read("*a")
f:close()
local log = gmod.definitions()
local order = {}
for line in text:gmatch("[^\n]+") do
    local name = line:match("^%- ([%w_]+), Category: ")
    if name then
        order[#order + 1] = name
    end
end
log:read_log(text)

local made = gmod.definitions()
local where = {}
for i, t in ipairs(list) do
    made:add(t[1], t[2])
    where[t[1]] = i
end

-- missing: in the log, not made (runs of the log's order); wrong categories; extra: made, not in the log
local missing, wrong, extra = 0, 0, 0
local run
local function flush()
    if run then
        print(string.format("  missing %5d-%5d (%d): %s .. %s", run.a, run.b, run.b - run.a + 1, order[run.a], order[run.b]))
        run = nil
    end
end
for i, name in ipairs(order) do
    if made.ids[name] == nil then
        missing = missing + 1
        if run and run.b == i - 1 then
            run.b = i
        else
            flush()
            run = { a = i, b = i }
        end
    else
        flush()
        if made:categories(name) ~= log:categories(name) then
            wrong = wrong + 1
            if wrong <= 20 then
                print(string.format("  categories %s: %d, the log %d", name, made:categories(name), log:categories(name)))
            end
        end
    end
end
flush()
for _, t in ipairs(list) do
    if log.ids[t[1]] == nil then
        extra = extra + 1
        if extra <= 40 then
            print("  not in the log: " .. t[1])
        end
    end
end
-- the order: the made types in the log's order (the longest run of the same order)
local inversions = 0
local last = 0
for _, name in ipairs(order) do
    local i = where[name]
    if i then
        if i < last then
            inversions = inversions + 1
        end
        last = i
    end
end
print(string.format("log %d types: %d missing, %d with other categories, %d made that the log lacks; %d out of order",
    #order, missing, wrong, extra, inversions))
os.exit((missing == 0 and wrong == 0 and extra == 0) and 0 or 1)
