-- sim/tools/scriptprobe.lua: script uses run with real targets in a loaded save, for the script coverage
-- reviews (docs/script_coverage.md): what a docs mod use cannot show (its target missing) shown on
-- objects the probe makes first. Run from sim/:
--   PROBE=tools/scriptprobe_events.txt STELLARIS_DIR=<game> STELLAR_LUA=tools/scriptprobe.lua \
--   <target>/release/examples/run 0 <save.sav>
-- The lines of PROBE (# comments kept):
--   E <kind> <id> <effect text>      an effect in that scope: the world writes it made (and the
--                                    engine effects applied), the misses it recorded
--   T <kind> <id> <trigger text>     a trigger: its value
--   V <kind> <id> <trigger> [p = { parameters }]  a numeric trigger's value (eval.trigger_value)
--   S <kind> <id> <field[.field...]> a field of the object (a block printed as its text)
--   L <kind> <id> <link>             a link: the scope it reaches
-- An id is a number, `player` (the human player's country), `$new:<kind>` (the last object of that
-- kind the run created), `$<kind>` (the highest id of the kind) or `$first:<kind>` (the lowest);
-- `$<kind>` also works inside the text.
local eval = require("simscript.eval")
local pdxscript = require("pdxscript")
local world = require("engine.world")
local out = {}

-- the world's writes, counted
local writes = 0
for _, f in ipairs({ "set", "append", "append_value", "remove_value", "remove", "create", "set_entry",
    "push", "remove_entry", "insert", "remove_at", "set_text", "replace", "append_entry" }) do
    local orig = world[f]
    world[f] = function(...)
        writes = writes + 1
        return orig(...)
    end
end

-- the objects created during the run, by kind (`$new:<kind>`: the last one)
local created = {}
do
    local orig = world.create
    world.create = function(kind, id, block)
        created[kind] = id
        return orig(kind, id, block)
    end
end

local function player()
    local b = world.blocks(world.meta.player)[1]
    return tonumber(b and world.field(b, "country"))
end
local function newest(kind, first)
    local best
    for _, id in ipairs(world.all(kind)) do
        if world.object(kind, id) and (best == nil or (first and id < best) or (not first and id > best)) then best = id end
    end
    return best
end
local function id_of(s)
    if s == "player" then return player() end
    local k = s:match("^%$new:(.+)$")
    if k then return created[k] end
    k = s:match("^%$first:(.+)$")
    if k then return newest(k, true) end
    k = s:match("^%$(.+)$")
    if k then return newest(k) end
    return tonumber(s)
end
local function show(v)
    if type(v) ~= "table" then return tostring(v) end
    local ok, t = pcall(pdxscript.write, v)
    t = ok and t or "<block>"
    t = t:gsub("%s+", " ")
    return #t > 300 and t:sub(1, 300) .. " ..." or t
end
local function misses()
    local m = {}
    for k, x in pairs(eval.stats.missing) do m[k] = x.count end
    return m
end
for line in io.lines(os.getenv("PROBE")) do
    local op, kind, ids, rest = line:match("^(%u) (%S+) (%S+) ?(.*)$")
    if op then
        local id = id_of(ids)
        rest = rest:gsub("%$(%a[%w_]*)", function(k)
            if k == "player" then return tostring(player()) end
            return tostring(newest(k) or "none")
        end)
        local sc = eval.S(kind, id)
        local ctx = eval.new_ctx(sc, nil, nil, "probe")
        local before = misses()
        local w0 = writes
        local ok, res = pcall(function()
            if op == "E" then
                eval.effect(pdxscript.parse(rest, "probe"), ctx)
                if E and E.flush then E.flush() end
                return "done"
            elseif op == "T" then
                return tostring(eval.trigger(pdxscript.parse(rest, "probe"), ctx))
            elseif op == "V" then
                local name, params = rest:match("^(%S+)%s*(.*)$")
                local pb = params ~= "" and pdxscript.parse(params, "probe")[1] or nil
                return tostring(eval.trigger_value(name, pb and pb.value or {}, ctx))
            elseif op == "S" then
                local o = world.object(kind, id)
                for k in rest:gmatch("[^%.]+") do o = type(o) == "table" and world.field(o, k) or nil end
                return show(o)
            elseif op == "L" then
                local found, s = eval.resolve(rest, ctx)
                return found and s and (s.kind .. ":" .. tostring(s.id)) or "none"
            end
        end)
        local m = {}
        for k, c in pairs(misses()) do
            if c ~= (before[k] or 0) then m[#m + 1] = k end
        end
        local w = op == "E" and string.format(" (%d world writes)", writes - w0) or ""
        out[#out + 1] = line:gsub("^(%u %S+) %S+", "%1 " .. tostring(id)) .. "\n   -> " .. tostring(res) .. w
            .. (ok and "" or " (ERROR)") .. (#m > 0 and (" missing: " .. table.concat(m, " ")) or "")
    else
        out[#out + 1] = line
    end
end
return table.concat(out, "\n")
