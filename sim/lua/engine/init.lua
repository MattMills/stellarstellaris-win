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
-- STELLAR_WORLD=store: the world lives in the shared store, the one copy every state reads and
-- writes (engine.store.engine_world); else as Lua tables (engine.world)
if os.getenv("STELLAR_WORLD") == "store" then
    require("engine.store.engine_world").install()
end
engine.slice = require("engine.slice")
engine.defs = require("engine.defs")
engine.world = require("engine.world")
require("engine.interface")
engine.systems = require("engine.systems")
local host = require("simscript.host")
engine.host = host

-- engine.load(game_dir, gamestate[, docs_dir]) -> report: the definitions, the script, the world.
-- gamestate: a save's text, or a tree in pdxscript's form (a new game's: engine.newgame)
function engine.load(game_dir, gamestate, docs_dir)
    host.init(game_dir, docs_dir)
    local db = require("simscript.db")
    engine.defs.load(db.fs, game_dir)
    local lines = { "definitions: " .. engine.defs.summary() }
    if gamestate then
        local ok, message
        if type(gamestate) == "table" then
            ok, message = engine.world.load_tree(gamestate)
        else
            ok, message = engine.world.load(gamestate)
        end
        lines[#lines + 1] = ok and ("world: " .. engine.world.summary()) or ("world: not loaded: " .. tostring(message))
        if ok then
            -- the script's flags and variables are the save's
            require("engine.scriptstate").install()
            -- the modifiers every system reads (economy.modifiers): by default the rewrite's own
            -- graph built from the world (engine.economy.world_source, rebuilt each month), its
            -- modifier types built from the game's files (or read from the game's modifier
            -- documentation given in STELLAR_MODIFIER_TYPES); with STELLAR_MODIFIERS=capture, or
            -- when the world graph cannot be built, the game's capture of the save's moment
            -- (STELLAR_CAPTURE), held as it was
            local capture = os.getenv("STELLAR_CAPTURE")
            local mode = os.getenv("STELLAR_MODIFIERS") or "world"
            local types = os.getenv("STELLAR_MODIFIER_TYPES")
            if (types == nil or types == "") and docs_dir
                and not require("stellar.graph.modifiers").game_definitions then
                types = docs_dir .. "/modifiers.log"
            end
            local built = false
            if mode == "world" then
                local economy = require("engine.economy")
                local source, why = require("engine.economy.world_source").new(types)
                if source then
                    source.rebuild()
                    economy.set_modifier_source(source.get)
                    engine.modifier_source = source
                    built = true
                    lines[#lines + 1] = "economy: modifiers from the world (" .. source.report() .. ")"
                else
                    lines[#lines + 1] = "economy: no modifiers from the world: " .. tostring(why)
                end
            end
            if not built and capture and capture ~= "" then
                local economy = require("engine.economy")
                local done, why = economy.use_capture(capture)
                lines[#lines + 1] = done and ("economy: modifiers from the capture " .. capture .. " (held as captured)")
                    or ("economy: no modifiers: " .. tostring(why))
            elseif not built then
                lines[#lines + 1] = "economy: no modifier source (no modifier types for the world graph, STELLAR_CAPTURE unset): the budget phase does nothing"
            end
            -- what the first day would make otherwise, made with the load (nothing of the world
            -- read or changed, no draws): the shared store's statics and the worker pool that
            -- exploration's pass runs on (engine.store.bridge), so no frame has to hold them
            -- (docs/frame_timing.md)
            if require("engine.store.live").on and os.getenv("STELLAR_EXPLORATION") ~= "off" then
                require("engine.store.bridge").prepare()
            end
            -- and the phases on the workers (STELLAR_PARALLEL): the world's copy and the workers'
            -- engines (seconds of work) made with the load, not in the first phase that asks
            local parallel = require("engine.store.parallel")
            if next(parallel.on) then
                parallel.start()
                lines[#lines + 1] = "parallel: " .. (parallel.started and string.format("the workers' engines in %.1f s",
                    parallel.stats.start_seconds) or ("not started: " .. tostring(parallel.failed)))
            end
            -- the engine's modules the phases load on first use, loaded now
            local function have(m) return package.searchpath(m, package.path) ~= nil end
            for _, m in ipairs({ "engine.ai.attitudes", "engine.ethics", "engine.exploration", "engine.colonies",
                "engine.construction", "engine.first_contact", "engine.research", "engine.situations",
                "engine.ai.strategy", "engine.leaders", "engine.pops", "engine.jobs", "engine.fleets.orders", "engine.fleets.movement",
                "engine.ai", "engine.ai.research", "engine.ai.budget", "engine.ai.shipbuilding", "engine.diplomacy",
                "engine.traditions" }) do
                if have(m) then require(m) end
            end
            for _, name in ipairs((package.loaded["engine.ai"] or {}).INTERIOR or {}) do
                if have("engine.ai." .. name) then require("engine.ai." .. name) end
            end
            -- and the files read on first use, parsed now (caches of the files alone)
            require("engine.economy.units").components()
            local create = require("engine.fleets.create")
            create.components()
            create.sections()
            create.scripted_globals()
            require("engine.fleets.movement").scripted_globals()
            require("engine.fleets.path").defines()
            require("engine.script.creation").special_project_def("")
            require("engine.research").project_type("")
            local shipbuilding = require("engine.ai.shipbuilding")
            shipbuilding.db_index("common/ship_sizes")
            shipbuilding.db_index("common/armies")
            -- the load's garbage collected with it (about a second): the collector's next cycle,
            -- which marks the whole heap a step at a time in the frames, comes only once the heap
            -- has doubled again, not straight away (docs/frame_timing.md)
            collectgarbage("collect")
        end
    end
    return table.concat(lines, "\n")
end

-- engine.load_world(gamestate) -> report: only the world (tools, the renderer: no definitions, no
-- script layer)
function engine.load_world(gamestate)
    local ok, message = engine.world.load(gamestate)
    return ok and ("world: " .. engine.world.summary()) or ("world: not loaded: " .. tostring(message))
end

-- engine.phase(kind, name, year, month, day) -> whether something models it: one phase of the
-- tick, then the barrier (the engine effects queued in it applied). The platform may run it as a
-- coroutine that yields at engine.slice's checks (docs/frame_timing.md).
function engine.phase(kind, name, year, month, day)
    local key = kind .. "." .. name
    engine.slice.begin(key)
    local ran = engine.systems.phase(kind, name, host, { year = year, month = month, day = day })
    if E.pending() > 0 then
        engine.slice.check("barrier " .. key)
        E.flush()
    end
    engine.slice.finish(key)
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

-- the date as the save writes it ("2210.02.01") from the platform's hours
local function date_text()
    local days = math.floor((E.date() - 43800000) / 24)
    local year = math.floor(days / 360)
    local in_year = days - year * 360
    return string.format("%d.%02d.%02d", year, math.floor(in_year / 30) + 1, in_year % 30 + 1)
end
engine.date_text = date_text

-- engine.save(state) -> the gamestate's text: the world as it is now, dated today, in the game's
-- layout (engine.savegame). state (optional): { tick, seed, position }, the platform's tick within
-- the day and synchronized generator, written as the save's tick, random_seed, random_count.
function engine.save(state)
    local savegame = require("engine.savegame")
    state = state or {}
    savegame.prepare({ date = date_text(), tick = state.tick, seed = state.seed, position = state.position })
    return savegame.write(engine.world.tree)
end

-- engine.save_meta(old) -> the `meta` text from the world (old: the loaded save's meta, or nil)
function engine.save_meta(old)
    return require("engine.savegame").meta(old)
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
    if engine.modifier_source then
        lines[#lines + 1] = engine.modifier_source.report()
    end
    for _, m in ipairs({ "engine.research", "engine.leaders", "engine.construction", "engine.traditions", "engine.ai", "engine.ai.attitudes", "engine.ai.strategy", "engine.ai.traditions", "engine.pops", "engine.jobs", "engine.colonies", "engine.ethics", "engine.situations", "engine.first_contact", "engine.script.creation", "engine.script.objects", "engine.draws", "engine.fleets.actions", "engine.fleets.automove" }) do
        local mod = package.loaded[m]
        if type(mod) == "table" and mod.report then
            lines[#lines + 1] = mod.report()
        end
    end
    return table.concat(lines, "\n")
end

return engine
