-- sim/tools/world_keys.lua : the keys of the objects of a save's stores (engine.world), to find the
-- relations between them (which fleet a ship is in, a leader's country, ...), with a plain LuaJIT.
--
--   luajit sim/tools/world_keys.lua [store,store,...] [samples]
--     STELLAR_SAVE   the save (.sav, read with `unzip -p`, or a gamestate file)
--
-- Per store: how many objects, every top-level key with how many objects have it and an example
-- value (a number, a word, or {...} for a block).

local dir = (arg and arg[0] or ""):match("^(.*)[/\\]sim[/\\]tools[/\\][^/\\]*$") or "."
package.path = dir .. "/sim/lua/?.lua;" .. dir .. "/sim/lua/?/init.lua;" .. dir .. "/lib/stellar-lua-pdxscript/?.lua;"
    .. dir .. "/lua/?.lua;" .. dir .. "/lua/?/init.lua;" .. package.path

-- the platform's helpers (sim/src/runtime.rs), when not run from it
RUST = RUST or {}
RUST.clock = RUST.clock or os.clock

local save = os.getenv("STELLAR_SAVE") or "/opt/stellaris-saves/autosave_2210.01.01.sav"
local stores = {}
for s in (arg[1] or "fleet,ships,army,leaders,starbase_mgr,sectors,spy_networks,megastructures,federation,galactic_object"):gmatch("[^,]+") do
    stores[#stores + 1] = s
end

local f = io.open(save, "rb")
local head = f:read(2)
f:close()
local p = head == "PK" and io.popen("unzip -p '" .. save .. "' gamestate") or io.open(save, "rb")
local text = p:read("*a")
p:close()

local world = require("engine.world")
world.load(text)

local function example(v)
    if type(v) == "table" then
        return "{...}"
    end
    return tostring(v)
end

for _, store in ipairs(stores) do
    local ids = world.all(store)
    local keys, order = {}, {}
    for _, id in ipairs(ids) do
        local o = world.object(store, id)
        for _, e in ipairs(type(o) == "table" and o or {}) do
            if e.op and e.key then
                local k = e.key.text
                local s = keys[k]
                if s == nil then
                    s = { n = 0, example = example(world.field(o, k)) }
                    keys[k] = s
                    order[#order + 1] = k
                end
                s.n = s.n + 1
            end
        end
    end
    local line = {}
    for _, k in ipairs(order) do
        line[#line + 1] = string.format("%s(%d)=%s", k, keys[k].n, keys[k].example:sub(1, 24))
    end
    print(string.format("%s: %d objects; %s", store, #ids, table.concat(line, " ")))
end
if os.getenv("WORLD_STORES") then
    local names = {}
    for name in pairs(world.stores) do
        names[#names + 1] = name .. " " .. #world.ids[name]
    end
    table.sort(names)
    print(table.concat(names, ", "))
end
