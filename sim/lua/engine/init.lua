-- engine : the game, in Lua, from the vanilla file set and a save. The Rust side (sim/src) is the
-- platform: the Lua runtime, files and saves, the game's random number generator, the date and
-- the tick loop in the game's order. Everything the game is made of comes from the game's files:
--
-- - engine.defs: every database folder of common/ (the vanilla file set, read in place);
-- - the script layer (simscript: events, on_actions, scripted triggers, effects and values,
--   evaluated in Lua with the repo's readers);
-- - engine.world: the game state, from a save's gamestate, kept in the save's own form;
-- - engine.interface: E, what the script layer reads of the world and the engine effects it sends;
-- - engine.systems: the engine's work per phase of the tick, and the effects applied to the world.
--
-- Called by sim/src/runtime.rs: engine.load(game_dir, gamestate), engine.phase(kind, name, date),
-- engine.command(kind, ...), engine.report().

local engine = {}
engine.defs = require("engine.defs")
engine.world = require("engine.world")
require("engine.interface")
engine.systems = require("engine.systems")
local host = require("simscript.host")
engine.host = host

-- engine.load(game_dir, gamestate[, docs_dir]) -> report: the definitions, the script, the world
function engine.load(game_dir, gamestate, docs_dir)
    host.init(game_dir, docs_dir)
    local db = require("simscript.db")
    engine.defs.load(db.fs, game_dir)
    local lines = { "definitions: " .. engine.defs.summary() }
    if gamestate then
        local ok, message = engine.world.load(gamestate)
        lines[#lines + 1] = ok and ("world: " .. engine.world.summary()) or ("world: not loaded: " .. tostring(message))
    end
    return table.concat(lines, "\n")
end

-- engine.phase(kind, name, year, month, day) -> whether something models it: one phase of the
-- tick, then the barrier (the engine effects queued in it applied)
function engine.phase(kind, name, year, month, day)
    local ran = engine.systems.phase(kind, name, host, { year = year, month = month, day = day })
    if E.pending() > 0 then
        E.flush()
    end
    return ran
end

-- engine.command(kind, ...): a command between ticks (a player or AI action), e.g.
-- ("effect", "scripted_effect_name", "country", 0)
function engine.command(kind, a, b, c)
    if kind == "effect" then
        host.run_effect(a, b, c)
    end
    if E.pending() > 0 then
        E.flush()
    end
end

local function top(t, n)
    local l = {}
    for k, v in pairs(t) do
        l[#l + 1] = { k, v }
    end
    table.sort(l, function(a, b) return a[2] > b[2] end)
    local out = {}
    for i = 1, math.min(n, #l) do
        out[i] = l[i][1] .. " " .. l[i][2]
    end
    return table.concat(out, ", "), #l
end

-- engine.report() -> text: what ran, and what the world does not answer yet
function engine.report()
    local lines = { host.report() }
    local s = E.stats
    local unread, n_unread = top(s.unread, 20)
    lines[#lines + 1] = string.format("engine: %d effects applied to the world; not applied (%d kinds): %s",
        s.applied, select(2, top(s.unapplied, 0)), (top(s.unapplied, 20)))
    lines[#lines + 1] = string.format("engine: reads the save does not answer yet (%d kinds): %s", n_unread, unread)
    local ran = top(engine.systems.ran, 30)
    local missing, n_missing = top(engine.systems.not_modelled, 40)
    lines[#lines + 1] = "engine: phases run: " .. ran
    lines[#lines + 1] = string.format("engine: phases not modelled yet (%d): %s", n_missing, missing)
    return table.concat(lines, "\n")
end

return engine
