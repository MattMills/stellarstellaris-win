-- engine/ai/economy/fixed.lua : the game's CFixedPoint arithmetic for the AI's budget (int64 with
-- 1.0 = 100000; multiply and divide truncate toward zero), on Lua numbers holding the raw integers.
-- Doubles hold integers exactly up to 2^53, so products are split like the game's overflow path.
--
--   local fp = require("engine.ai.economy.fixed")
--   fp.from(0.05) -> 5000          fp.to(5000) -> 0.05
--   fp.mul(a, b)  fp.div(a, b)     (raw integers in, raw integer out)

local fp = { ONE = 100000 }

local floor = math.floor

local function trunc(x)
    if x >= 0 then
        return floor(x)
    end
    return -floor(-x)
end
fp.trunc = trunc

-- a number (a script value, a stockpile written with 5 decimals) as the raw fixed point integer
function fp.from(x)
    if x == nil then
        return 0
    end
    if x >= 0 then
        return floor(x * 100000 + 0.5)
    end
    return -floor(-x * 100000 + 0.5)
end

function fp.to(raw)
    return raw / 100000
end

-- a * b / 100000, truncated toward zero
function fp.mul(a, b)
    if a == 0 or b == 0 then
        return 0
    end
    local neg = (a < 0) ~= (b < 0)
    a, b = a < 0 and -a or a, b < 0 and -b or b
    -- a = q * 100000 + r: a * b / 100000 = q * b + r * b / 100000
    local q = floor(a / 100000)
    local r = a - q * 100000
    local v = q * b + floor(r * b / 100000)
    return neg and -v or v
end

-- a * 100000 / b, truncated toward zero (b ~= 0)
function fp.div(a, b)
    if b == 0 then
        return 0
    end
    local neg = (a < 0) ~= (b < 0)
    a, b = a < 0 and -a or a, b < 0 and -b or b
    -- a * 100000 can pass 2^53 for large a: split a = q * b + r
    local q = floor(a / b)
    local r = a - q * b
    local v = q * 100000 + floor(r * 100000 / b)
    return neg and -v or v
end

return fp
