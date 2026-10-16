-- render/loctext.lua : a localisation text with the values the game fills in at run time
-- ($NAME$, $NAME|format$), for windows whose texts the game formats (CLocalizationString's
-- variables). The result keeps the colour codes (§X ... §!) and icons (£name£) that render.gui
-- splits into spans.
--
--   local text = require("render.loctext")
--   text.format(loc, "MARKET_TRADE_FEE_VALUE", { VALUE = 0.3 })   -- "Market Fee: §Y30%§!"
--   text.number(1234.5, "Y1")                                     -- "§Y1234.5§!"
--
-- A format [I: the game's own rules read from the texts' uses, not from its formatter's code]:
-- an upper-case letter colours the value (§X); `%` shows it times 100 with a % sign; a digit
-- is the number of decimals; `*` shortens it with K and M (the top bar's); `+` writes the sign
-- and colours it, green above 0, red below; `=` is ignored. A value that is a string is put in
-- as it is (coloured if the format says so).

local text = {}

local function plain(v, decimals)
    if decimals then
        return string.format("%." .. decimals .. "f", v)
    end
    if v == math.floor(v) then
        return string.format("%d", v)
    end
    return (string.format("%.2f", v):gsub("0+$", ""):gsub("%.$", ""))
end

-- the K/M short form (one decimal, cut not rounded: the top bar's)
local function short(v, decimals)
    local a = math.abs(v)
    local s = v < 0 and "-" or ""
    if a >= 1e6 then
        return string.format("%s%.1fM", s, math.floor(a / 1e5) / 10)
    elseif a >= 1e3 then
        return string.format("%s%.1fK", s, math.floor(a / 1e2) / 10)
    end
    return s .. plain(a, decimals)
end

function text.number(v, spec)
    spec = spec or ""
    local colour = spec:match("%u")
    local decimals = tonumber(spec:match("%d"))
    local s
    if type(v) ~= "number" then
        s = tostring(v)
    else
        if spec:find("%", 1, true) then
            v = v * 100
        end
        local sign = spec:find("+", 1, true)
        if spec:find("*", 1, true) then
            s = short(v, decimals)
        else
            s = plain(v, decimals)
        end
        if spec:find("%", 1, true) then
            s = s .. "%"
        end
        if sign then
            if v > 0 then
                s = "+" .. s
            end
            colour = colour or (v > 0 and "G" or v < 0 and "R" or nil)
        end
    end
    if colour then
        return "§" .. colour .. s .. "§!"
    end
    return s
end

-- the text of `key` (or a text) with its $NAME$ references: the vars' values, else other keys'
-- texts; unknown names stay as written
function text.format(loc, key, vars, depth)
    depth = depth or 0
    local raw = (loc and loc.has(key)) and loc.raw(key) or key
    return (raw:gsub("%$([%w_%.]+)|?([^%$]*)%$", function(name, spec)
        if vars and vars[name] ~= nil then
            return text.number(vars[name], spec)
        end
        if loc and loc.has(name) and depth < 8 then
            local inner = text.format(loc, name, vars, depth + 1)
            local colour = spec:match("%u")
            return colour and ("§" .. colour .. inner .. "§!") or inner
        end
        return nil
    end))
end

return text
