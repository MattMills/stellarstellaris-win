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
    if engine == "SEQ" then
        -- a numbered name (an army's "1st Hardshell Defenders": { key = "%SEQ%" variables = {
        -- fmt = { key = "MOL4_HARDSHELLDEFENDERS" } num = { key = "1" } } }): fmt's text with
        -- $ORD$ the number's ordinal (the ORD localisation's rule: 11th..19th, else 1st, 2nd, 3rd,
        -- else th) and $NUM$ the number [V] the localisation, the game's frame
        local fmt, num
        for _, v in ipairs(n.vars or {}) do
            if v.key == "fmt" and type(v.value) == "table" then
                fmt = v.value.key
            elseif v.key == "num" and type(v.value) == "table" then
                num = tonumber(v.value.key)
            end
        end
        if fmt and num then
            local text = loc and loc.has(fmt) and loc.raw(fmt) or fmt
            local suffix = (num % 100 >= 10 and num % 100 <= 19) and "th"
                or ({ [1] = "st", [2] = "nd", [3] = "rd" })[num % 10] or "th"
            text = text:gsub("%$ORD%$", num .. suffix):gsub("%$NUM%$", tostring(num))
            if loc then
                text = loc.plain(loc.resolve(text))
            end
            return text
        end
    end
    if engine then
        if engine == "ACRONYM" then
            return acronym(vars.base or first or "")
        end
        if engine == "ADJECTIVE" then
            -- the adjective and the noun after it ("Uthabulan Order"); a word with an ending the
            -- localisation's adj_NN<ending> keys name takes their form, `*` the word without the
            -- ending, the longest ending first ("Mandasura": adj_NNa "*an", "Mandasuran")
            local a, noun = vars.adjective or first or "", vars["1"]
            if loc and vars.adjective then
                for n = math.min(3, #a - 1), 1, -1 do
                    local key = "adj_NN" .. a:sub(-n)
                    if loc.has(key) then
                        local form = loc.raw(key):match("^(%S*)") or "*"
                        a = (form:gsub("%*", escape(a:sub(1, -n - 1))))
                        break
                    end
                end
            end
            return noun and vars.adjective and (a .. " " .. noun) or a
        end
        if engine:match("^LEADER_%d+$") then
            -- a leader's full name: its N parts in order ("%LEADER_2%" with "Oneggon" and
            -- "Oilskin": "Oneggon Oilskin", the research view's head of research) [I]
            local parts = {}
            for i = 1, tonumber(engine:match("%d+")) do
                parts[#parts + 1] = vars[tostring(i)]
            end
            return table.concat(parts, " ")
        end
        if engine == "ADJ" then
            -- its name ("Sacred Uthabulan Order")
            return vars["1"] or first or ""
        end
        return vars.base or first or ""
    end
    local known = loc and loc.has(key)
    local text = known and loc.raw(key) or key
    -- a plain word with a name after it ("Sacred" with "Uthabulan Order") [I]
    if vars["1"] and not text:find("$", 1, true) then
        text = text .. " " .. vars["1"]
    end
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
