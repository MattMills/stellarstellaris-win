-- dry_run.lua : runs the lookups of lua/stellar/game.lua and lua/stellar/script/catalog.lua against
-- an executable file, outside the game (the code is read from the file).
--
-- Usage: luajit tools/dry_run.lua <stellaris.exe> [<cache dir>]
-- The fnmatch module (lua_fnmatch) must be on package.cpath (LUA_CPATH).

local exe, cache = arg[1], arg[2]
if exe == nil then
    io.stderr:write("usage: luajit dry_run.lua <stellaris.exe> [<cache dir>]\n")
    os.exit(2)
end
local here = (arg[0]:match("^(.*)[/\\]") or ".")
package.path = here .. "/../lua/?.lua;" .. package.path

local fnmatch = require("fnmatch")
local hex = require("stellar.util").hex

-- reads the bytes of the image at an address, from the sections of the PE file
local function file_reader(path, base)
    local f = assert(io.open(path, "rb"))
    local data = f:read("*a")
    f:close()
    local function u16(o)
        local a, b = data:byte(o + 1, o + 2)
        return a + b * 0x100
    end
    local function u32(o)
        local a, b, c, d = data:byte(o + 1, o + 4)
        return a + b * 0x100 + c * 0x10000 + d * 0x1000000
    end
    local pe = u32(0x3c)
    local count, sections = u16(pe + 6), pe + 24 + u16(pe + 20)
    return function(address, size)
        local rva = address - base
        for i = 0, count - 1 do
            local s = sections + i * 40
            local va, raw_size, raw = u32(s + 12), u32(s + 16), u32(s + 20)
            if rva >= va and rva + size <= va + raw_size then
                return data:sub(raw + rva - va + 1, raw + rva - va + size)
            end
        end
        return nil, "not in the file"
    end
end

local image = assert(fnmatch.file(exe, { cache = cache }))
local missing = 0

local base = image:base()
local where, message = require("stellar.game").locate(image, file_reader(exe, base))
if where then
    local names = { "handle_turn_tick", "update", "check_tick", "gate", "allow_get_player", "current_game_state" }
    for _, k in ipairs(names) do
        print(string.format("game: %-20s rva %s", k, hex(where[k] - base)))
    end
else
    print("game: " .. message)
    missing = missing + 1
end

-- the script engine's tables (stellar.script.catalog): only their addresses, without a process
local script, script_message = require("stellar.script.catalog").locate(image, file_reader(exe, base))
if script then
    for _, k in ipairs({ "lexer", "trigger_database", "effect_database" }) do
        print(string.format("script: %-18s rva %s", k, hex(script[k] - base)))
    end
    local methods = {}
    for address, kind in pairs(script.methods) do
        methods[#methods + 1] = kind .. " " .. hex(address - base)
    end
    table.sort(methods)
    print(string.format("script: %d structural class methods: %s", #methods, table.concat(methods, ", ")))
else
    print("script: " .. script_message)
    missing = missing + 1
end
os.exit(missing == 0 and 0 or 1)
