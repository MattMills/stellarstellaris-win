-- render/newgame_dlc.lua : the DLC triggers of the new game's screens, answered for a set of DLCs
-- (a prescripted design's `playable`, a setting's `visible`, a species class's or a shape's DLC
-- check): host_has_dlc / has_dlc and the scripted triggers built from them (has_lithoids,
-- has_megacorp, has_not_machine_age_dlc, empire_design_never, ...), with AND / OR / NOT / NOR /
-- NAND / always.
--
--   local dlc = require("render.newgame_dlc")
--   local set = dlc.set(names)                     -- { ["Megacorp"] = true, ... }
--   dlc.eval(game_dir, set, block_or_text)         -> true / false
--
-- The DLCs: those the game's headless reference owns (the save's required_dlcs; headless view.sh
-- loads its save's), the same list engine.newgame writes into a new game's save.

local source = require("stellar.script.source")

local dlc = {}

-- the default DLCs: engine.newgame's (the headless reference's 14 owned ones)
dlc.DEFAULT = {
    "Ancient Relics Story Pack", "Anniversary Portraits", "Apocalypse", "Aquatics Species Pack",
    "Distant Stars Story Pack", "Federations", "Horizon Signal", "Leviathans Story Pack",
    "Lithoids Species Pack", "Megacorp", "Necroids Species Pack", "Nemesis", "Overlord",
    "Plantoids Species Pack",
}

function dlc.set(names)
    local s = {}
    for _, n in ipairs(names or dlc.DEFAULT) do
        s[n] = true
    end
    return s
end

local triggers -- name -> block (common/scripted_triggers), read once
local function scripted(game_dir)
    if not triggers then
        triggers = {}
        local defs = source.definitions(game_dir, "common/scripted_triggers")
        for name, d in pairs(defs) do
            triggers[name] = d.block
        end
    end
    return triggers
end

local eval
-- one statement: true / false
local function statement(game_dir, set, key, v, depth)
    local text = type(v) == "table" and v.text or v
    if key == "host_has_dlc" or key == "has_dlc" then
        return set[text] == true
    elseif key == "always" then
        return text == "yes"
    elseif key == "AND" then
        return eval(game_dir, set, v, depth + 1)
    elseif key == "OR" or key == "NOR" then
        local any = false
        for _, e in ipairs(type(v) == "table" and v or {}) do
            if e.op and e.key and statement(game_dir, set, e.key.text, e.value, depth + 1) then
                any = true
                break
            end
        end
        if key == "OR" then
            return any
        end
        return not any
    elseif key == "NOT" or key == "NAND" then
        return not eval(game_dir, set, v, depth + 1)
    end
    local t = scripted(game_dir)[key]
    if t and depth < 16 then
        local r = eval(game_dir, set, t, depth + 1)
        if text == "no" then
            return not r
        end
        return r
    end
    -- (optimize_memory and the like: no condition)
    return key == "optimize_memory"
end

-- a block (AND of its statements) or a scripted trigger's name
function eval(game_dir, set, block, depth)
    depth = depth or 0
    if type(block) == "string" then
        return statement(game_dir, set, block, "yes", depth)
    end
    if type(block) ~= "table" then
        return true
    end
    if block.text then
        return statement(game_dir, set, block.text, "yes", depth)
    end
    for _, e in ipairs(block) do
        if e.op and e.key and not statement(game_dir, set, e.key.text, e.value, depth) then
            return false
        end
    end
    return true
end
dlc.eval = eval

return dlc
