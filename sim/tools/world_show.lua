-- sim/tools/world_show.lua : objects of a save (engine.world), printed as blocks, with a plain LuaJIT.
--
--   luajit sim/tools/world_show.lua store:id[.key] ... [depth]
--     STELLAR_SAVE   the save (default /opt/stellaris-saves/autosave_2211.07.01.sav)
--
-- `planet:530` prints the object, `galactic_object:15.starbases` one of its fields; depth (default 2)
-- limits the nesting, and each block shows at most 24 entries.

local dir = (arg and arg[0] or ""):match("^(.*)[/\\]sim[/\\]tools[/\\][^/\\]*$") or "."
package.path = dir .. "/sim/lua/?.lua;" .. dir .. "/sim/lua/?/init.lua;" .. dir .. "/lib/stellar-lua-pdxscript/?.lua;"
    .. dir .. "/lua/?.lua;" .. dir .. "/lua/?/init.lua;" .. package.path

RUST = RUST or {}
RUST.clock = RUST.clock or os.clock

local save = os.getenv("STELLAR_SAVE") or "/opt/stellaris-saves/autosave_2211.07.01.sav"
local f = assert(io.open(save, "rb"))
local head = f:read(2)
f:close()
local p = head == "PK" and io.popen("unzip -p '" .. save .. "' gamestate") or io.open(save, "rb")
local text = p:read("*a")
p:close()
local world = require("engine.world")
assert(world.load(text))

local depth = 2
local targets = {}
for _, a in ipairs(arg) do
    if tonumber(a) then
        depth = tonumber(a)
    else
        targets[#targets + 1] = a
    end
end

local function show(block, d, indent)
    local n = 0
    for _, e in ipairs(block) do
        n = n + 1
        if n > 24 then
            print(indent .. "... (" .. #block .. " entries)")
            break
        end
        if e.op and e.key then
            if type(e.value) == "table" and e.value.text == nil then
                if d > 0 then
                    print(indent .. e.key.text .. " = {")
                    show(e.value, d - 1, indent .. "  ")
                    print(indent .. "}")
                else
                    print(indent .. e.key.text .. " = { " .. #e.value .. " entries }")
                end
            else
                print(indent .. e.key.text .. " = " .. tostring(e.value.text))
            end
        elseif e.text then
            print(indent .. e.text)
        elseif type(e) == "table" then
            if d > 0 then
                print(indent .. "{")
                show(e, d - 1, indent .. "  ")
                print(indent .. "}")
            else
                print(indent .. "{ " .. #e .. " entries }")
            end
        end
    end
end

for _, t in ipairs(targets) do
    local store, id, key = t:match("^([%w_.]+):(%d+)%.?([%w_.]*)$")
    local o = store and world.object(store, tonumber(id))
    print("== " .. t)
    if o == nil then
        print("  (none)")
    else
        local v = o
        if key ~= "" then
            for k in key:gmatch("[^.]+") do
                v = type(v) == "table" and world.field(v, k) or nil
            end
        end
        if type(v) == "table" then
            show(v, depth, "  ")
        else
            print("  " .. tostring(v))
        end
    end
end
