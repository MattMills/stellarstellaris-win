-- engine/ai/commands.lua : the AI's commands across worker states (docs/data_layer.md section 12).
--
-- A command is a table whose execute function is a closure over its constructor's arguments, made
-- while an AI country decides and executed after every country decided (engine.ai). On a worker
-- (engine.store.worker) a closure cannot reach the main state, so there commands.make gives a
-- recipe instead: the module, the constructor's name and the arguments, which the main state turns
-- into the command itself by calling the same constructor. In the main state commands.make is the
-- constructor's own command.
--
--   cmds.make("engine.ai.starbases", "command", command, country, sb, ...)  -- in a module
--   cmds.serialize(cmd, cmds.paths(ai_block)) -> text; cmds.rebuild(text, env) -> the command  (the worker job)
--
-- A recipe's arguments travel as data: numbers, texts, booleans, plain tables (copied), a block of
-- the shared world as its block id (B(id): the main state's table for it, engine.store.full), the
-- country's own AI block as A(), a loaded module as M(name).

local C = {}

function C.make(module, name, ctor, ...)
    if _G.STELLAR_WORKER then
        return { recipe = { module = module, name = name, n = select("#", ...), args = { ... } } }
    end
    return ctor(...)
end

-- the modules loaded, by their tables (a module given as an argument, e.g. simscript.host)
local function module_name(t)
    for name, m in pairs(package.loaded) do
        if m == t then return name end
    end
    return nil
end

local rawtype = type
local ffi = require("ffi")
local block_ptr

local function ser(v, paths, seen, out)
    local t = rawtype(v)
    if t == "nil" then
        out[#out + 1] = "nil"
    elseif t == "boolean" then
        out[#out + 1] = tostring(v)
    elseif t == "number" then
        if v ~= v then
            out[#out + 1] = "0/0"
        elseif v == math.huge or v == -math.huge then
            out[#out + 1] = v > 0 and "1/0" or "-1/0"
        else
            out[#out + 1] = string.format("%.17g", v)
        end
    elseif t == "string" then
        out[#out + 1] = (string.format("%q", v):gsub("\\\n", "\\n"))
    elseif t == "cdata" then
        block_ptr = block_ptr or ffi.typeof("pdx_block *")
        if not ffi.istype(block_ptr, v) then error("a command argument of an unknown cdata type") end
        out[#out + 1] = "B(" .. tostring(tonumber(v - require("engine.store.core").B)) .. ")"
    elseif t == "table" then
        local p = paths and paths[v]
        if p then
            out[#out + 1] = "A(" .. p .. ")"
            return
        end
        local name = module_name(v)
        if name then
            out[#out + 1] = "M(" .. string.format("%q", name) .. ")"
            return
        end
        if seen[v] then error("a command argument refers to itself") end
        seen[v] = true
        out[#out + 1] = "{"
        for k, x in pairs(v) do
            out[#out + 1] = "["
            ser(k, paths, seen, out)
            out[#out + 1] = "]="
            ser(x, paths, seen, out)
            out[#out + 1] = ","
        end
        out[#out + 1] = "}"
        seen[v] = nil
    else
        error("a command argument of type " .. t)
    end
end

-- C.paths(ai) -> every block and entry of the AI block ai (the worker's table) -> its path from ai, the
-- arguments of A(): an index into a block, "v" for an entry's value
function C.paths(ai)
    local map = { [ai] = "" }
    local function walk(b, p)
        for j, x in ipairs(b) do
            local q = p == "" and tostring(j) or (p .. "," .. j)
            map[x] = q
            if x.op then
                map[x.value] = q .. ",'v'"
                if x.value.text == nil then walk(x.value, q .. ",'v'") end
            elseif x.text == nil then
                walk(x, q)
            end
        end
    end
    walk(ai, "")
    return map
end

-- C.serialize(cmd, paths) -> one line: a recipe ("R ...") or a plain command ("P ...") as Lua
-- source; paths = C.paths of the country's AI block (its tables sent as A(<path>), not copied)
function C.serialize(cmd, paths)
    local out = {}
    if cmd.recipe then
        out[1] = "R "
        ser(cmd.recipe, paths, {}, out)
    else
        if cmd.execute then error("a command with a closure, not made by commands.make: " .. tostring(cmd.kind)) end
        out[1] = "P "
        ser(cmd, paths, {}, out)
    end
    return table.concat(out)
end

-- C.rebuild(line, env) -> the command: env.B(id) -> the main state's block, env.A(...) -> the
-- country's AI block or what the path names in it, env.M(name) -> a module
function C.rebuild(line, env)
    local tag, src = line:sub(1, 1), line:sub(3)
    local f = assert(load("return " .. src, "command", "t", env))
    local v = f()
    if tag == "P" then return v end
    local ctor = require(v.module).ctor[v.name]
    return ctor(unpack(v.args, 1, v.n))
end

-- C.merge(dst, src): the main state's block dst made equal to src (the same block parsed from a
-- worker's text), in place: where both have a block at the same place under the same key, dst's
-- table is kept (its copy in the store keeps its block, engine.store.full) and merged in turn; a
-- changed block is reindexed (engine.world)
function C.merge(dst, src)
    local world = require("engine.world")
    local changed = #dst ~= #src
    for j = 1, #src do
        local s, d = src[j], dst[j]
        local sv = s.op and s.value or s
        local dv = d and (d.op and d.value or d)
        local same_key = d ~= nil and ((s.op and d.op and s.key.text == d.key.text) or (not s.op and not d.op))
            and not s.param and not d.param
        if same_key and sv.text == nil and dv.text == nil and sv.type == dv.type then
            if s.op and (d.op ~= s.op or d.key.quoted ~= s.key.quoted) then
                d.op, d.key.quoted = s.op, s.key.quoted
                changed = true
            end
            C.merge(dv, sv)
        elseif same_key and sv.text ~= nil and dv.text ~= nil then
            if dv.text ~= sv.text or dv.quoted ~= sv.quoted then
                dv.text, dv.quoted = sv.text, sv.quoted
                changed = true
            end
            if s.op and (d.op ~= s.op or d.key.quoted ~= s.key.quoted) then
                d.op, d.key.quoted = s.op, s.key.quoted
                changed = true
            end
        else
            dst[j] = s
            changed = true
        end
    end
    for j = #dst, #src + 1, -1 do
        dst[j] = nil
    end
    if changed then world.reindex(dst) end
end

return C
