-- render/windows/serial.lua : a table of strings, numbers and booleans (nested) as a Lua table
-- constructor, `return { ... }`: how a window's data crosses from the world's runtime to the
-- runtime that lays the window out (sim/render/src/economy.rs).
--
--   local s = require("render.windows.serial").dump(t)   -- load(s)() is a copy of t

local serial = {}

local function value(v, out)
    local t = type(v)
    if t == "table" then
        out[#out + 1] = "{"
        local n = #v
        for i = 1, n do
            value(v[i], out)
            out[#out + 1] = ","
        end
        for k, x in pairs(v) do
            if not (type(k) == "number" and k >= 1 and k <= n and k == math.floor(k)) then
                out[#out + 1] = "["
                value(k, out)
                out[#out + 1] = "]="
                value(x, out)
                out[#out + 1] = ","
            end
        end
        out[#out + 1] = "}"
    elseif t == "string" then
        out[#out + 1] = string.format("%q", v)
    elseif t == "number" then
        if v ~= v then
            out[#out + 1] = "0/0"
        elseif v == math.huge or v == -math.huge then
            out[#out + 1] = v > 0 and "math.huge" or "-math.huge"
        elseif v == math.floor(v) and math.abs(v) < 2 ^ 53 then
            out[#out + 1] = string.format("%d", v)
        else
            out[#out + 1] = string.format("%.17g", v)
        end
    elseif t == "boolean" then
        out[#out + 1] = tostring(v)
    else
        out[#out + 1] = "nil"
    end
end

function serial.dump(t)
    local out = { "return " }
    value(t, out)
    return table.concat(out)
end

return serial
