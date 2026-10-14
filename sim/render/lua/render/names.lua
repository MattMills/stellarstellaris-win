-- render/names.lua : a save's names localised, as the game shows them.
--
--   local names = require("render.names")
--   names.format(loc, { key = "PREFIX_NAME_FORMAT", vars = { { key = "PREFIX", value = {...} },
--       { key = "NAME", value = { key = "MOL4_SHIP_Hydrozoan" } } } })   --> "UNS Hydrozoan"
--
-- A name block is a localisation key (or the name itself with `literal = yes`) and the variables
-- its text takes: `$NAME$` (and `[NAME]`) in the text are the variable's own name, formatted the
-- same way. Keys the engine fills itself: `%ACRONYM%` (the initials of its `base`), `%SEQ%` and
-- the like (their first variable). A key that is no localisation key is the name (the name
-- lists' entries are keys of localisation/*/name_lists too; a save's own names are plain).

local names = {}

-- the initials, made up to three letters from the last word ("Uthabulan Order": UOR, as the
-- game's ship prefixes show it)
local function acronym(s)
    local out, last = {}, ""
    for w in tostring(s):gmatch("%S+") do
        out[#out + 1] = w:sub(1, 1):upper()
        last = w
    end
    local k = 2
    while #out < 3 and k <= #last do
        out[#out + 1] = last:sub(k, k):upper()
        k = k + 1
    end
    return table.concat(out)
end

local function escape(s)
    return (s:gsub("%%", "%%%%"))
end

function names.format(loc, n, depth)
    depth = depth or 0
    if type(n) ~= "table" or depth > 8 then
        return ""
    end
    local key = tostring(n.key or "")
    if n.literal then
        return key
    end
    local vars, first = {}, nil
    for _, v in ipairs(n.vars or {}) do
        local text = names.format(loc, v.value, depth + 1)
        vars[v.key] = text
        first = first or text
    end
    local engine = key:match("^%%(.+)%%$")
    if engine then
        if engine == "ACRONYM" then
            return acronym(vars.base or first or "")
        end
        if engine == "ADJECTIVE" or engine == "ADJ" then
            -- the adjective and the noun after it ("Uthabulan Order")
            local a, noun = vars.adjective or first or "", vars["1"]
            return noun and (a .. " " .. noun) or a
        end
        return vars.base or first or ""
    end
    local text = loc and loc.has(key) and loc.raw(key) or key
    -- a station's name whose text leaves out its planet ("Starbase") has the planet before it
    -- (the game's outliner: "Ithni Zerak A Sta...") [I]
    if vars.PLANET and not text:find("$PLANET$", 1, true) and not text:find("[PLANET]", 1, true) then
        text = vars.PLANET .. " " .. text
    end
    for k, v in pairs(vars) do
        local pk = k:gsub("%p", "%%%0")
        text = text:gsub("%$" .. pk .. "%$", escape(v)):gsub("%[" .. pk .. "%]", escape(v))
    end
    if loc then
        text = loc.resolve(text)
        text = loc.plain(text)
    end
    return text
end

return names
