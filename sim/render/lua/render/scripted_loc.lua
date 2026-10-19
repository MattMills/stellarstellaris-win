-- render/scripted_loc.lua : the scripted localisations (common/scripted_loc `defined_text = {
-- name text = { trigger localization_key } ... default }`), the `[Name]` of the game's texts
-- (CScriptedLocalisation: the first text whose trigger holds in the scope, else the default).
--
--   scripted_loc.defaults(game_dir)          -- engine.localisation.scripted_default filled
--   scripted_loc.evaluate(game_dir, kind, id) -> { name = key } in that scope (the simulation's
--                                               script layer: where the world is, a view's extract)
--   scripted_loc.use(map)                    -- engine.localisation.scripted set (a view's build)
--
-- Texts with `random` or `weight` blocks take their default [I: their draw not modelled].

local source = require("stellar.script.source")

local scripted_loc = {}

local function unquote(s)
    return type(s) == "string" and (s:gsub('^"(.*)"$', "%1")) or s
end

local function field(block, key)
    for _, e in ipairs(type(block) == "table" and block or {}) do
        if e.op and e.key and e.key.text == key then
            return e.value.text ~= nil and unquote(e.value.text) or e.value, e
        end
    end
    return nil
end

local defs
-- the defined texts, read once: { { name, file, texts = { { trigger, key } }, default } }
local function load(game_dir)
    if defs then
        return defs
    end
    defs = {}
    local files = RUST and RUST.list_files and RUST.list_files(game_dir, "common/scripted_loc", "txt") or {}
    table.sort(files)
    for _, f in ipairs(files) do
        for _, e in ipairs(source.parse(game_dir, f) or {}) do
            if e.op and e.key and e.key.text == "defined_text" and e.value.text == nil then
                local d = { name = field(e.value, "name"), file = f, texts = {}, default = field(e.value, "default") }
                for _, x in ipairs(e.value) do
                    if x.op and x.key and x.key.text == "text" and x.value.text == nil then
                        d.texts[#d.texts + 1] = { trigger = field(x.value, "trigger"), key = field(x.value, "localization_key") }
                    end
                end
                if d.name then
                    defs[#defs + 1] = d
                end
            end
        end
    end
    return defs
end

-- scripted_loc.defaults(game_dir): each name's default in engine.localisation (once)
local defaults_set
function scripted_loc.defaults(game_dir)
    if defaults_set then
        return
    end
    defaults_set = true
    local loc = require("engine.localisation")
    for _, d in ipairs(load(game_dir)) do
        if type(d.default) == "string" then
            loc.scripted_default[d.name] = d.default
        end
    end
end

-- scripted_loc.evaluate(game_dir, kind, id) -> { name = key }: each defined text's first text whose
-- trigger holds in the scope (kind, id) (a text without a trigger holds), by the simulation's
-- script layer; the names whose texts all fail are left out (their default applies)
local cache = {}
function scripted_loc.evaluate(game_dir, kind, id)
    local ok, eval = pcall(require, "simscript.eval")
    if not ok then
        return {}
    end
    -- (once a day for a scope)
    local okw, world = pcall(require, "engine.world")
    local k = kind .. ":" .. tostring(id) .. ":" .. tostring(okw and world.meta and world.meta.date or "")
    if cache[k] then
        return cache[k]
    end
    local out = {}
    cache = { [k] = out }
    for _, d in ipairs(load(game_dir)) do
        for _, t in ipairs(d.texts) do
            if type(t.key) == "string" then
                local holds = true
                if type(t.trigger) == "table" then
                    local good, r = pcall(eval.trigger, t.trigger, eval.new_ctx(eval.S(kind, id), nil, nil, d.file))
                    holds = good and r and true or false
                end
                if holds then
                    out[d.name] = t.key
                    break
                end
            end
        end
    end
    return out
end

-- scripted_loc.use(map): the names' keys for the texts laid out next (a view's scope)
function scripted_loc.use(map)
    local loc = require("engine.localisation")
    loc.scripted = type(map) == "table" and map or {}
end

return scripted_loc
