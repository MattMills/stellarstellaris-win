-- init_steps.lua : the steps of CGameApplication::InitGame that Lua runs itself, ahead of the game,
-- each on a thread of its own as soon as what it needs is made; the game's own call of the step
-- then waits for that run and returns its result (stellar.run_async, stellar.defer_mark).
--
-- A step is a function the load marks (stellar.loading MILESTONES), started at a point of the load
-- Lua sees ("databases": SetupDatabases begins; "post_reads": the PostReadInitInstance calls are
-- done), with its arguments ("application": the CGameApplication).
--
--   local init_steps = require("stellar.init_steps")
--   init_steps.bind(marks)          -- the marks hooked (with id and trampoline)
--   init_steps.start("databases")   -- from the game's thread, at that point
--   init_steps.report()             -- once the load is done

local stellar = require("stellar")

local init_steps = {}

-- locks: the step writes the tables the databases share (the trigger and effect sets, ...): it
-- runs ahead only where those functions are serialized (databases in parallel), with the shared
-- lock taken until the last step is joined
init_steps.STEPS = {
    { name = "CApplication::CalculateGameFilesChecksum", at = "databases", args = { "application" },
        why = "hashes the game's files into the application (+800), 1.1s; nothing the load makes is read" },
    { name = "CStaticModifierDatabase::Init", at = "post_reads", args = { "static_modifier_database", 0 }, locks = true,
        why = "common/static_modifiers again, 0.8s; the modifier definitions are final after the PostReads" },
    -- the scripted triggers' and effects' passes in the game's order, one after another (run side
    -- by side they made different triggers: the census was 1,317,090 and 1,318,659 for 1,318,141)
    { name = "CTriggerDatabase::PostInit", at = "post_reads", args = { "trigger_database" }, locks = true,
        chain = "scripted", why = "the scripted triggers called with arguments, 2.6s; every scripted trigger is read by then" },
    { name = "CTriggerDatabase::PostValidate", at = "post_reads", args = { "trigger_database" }, locks = true,
        chain = "scripted", why = "checks every trigger: before the effects' pass adds theirs, as in the game" },
    { name = "CEffectDatabase::PostInit", at = "post_reads", args = { "effect_database" }, locks = true,
        chain = "scripted", why = "the scripted effects called with arguments, 2.3s; after the triggers' pass, as in the game" },
    { name = "CEffectDatabase::PostValidate", at = "post_reads", args = { "effect_database" }, locks = true,
        chain = "scripted", why = "checks every effect" },
    { name = "CModifier::LogDefinitions", at = "post_reads", args = {},
        why = "writes modifiers.log, 4.3s; the modifier definitions are final after the PostReads" },
}

local by_name, started = {}, {}
local sources = {}      -- name -> function returning an argument's value
local locks = false     -- whether the shared tables' functions are serialized
local locked_now = false

-- init_steps.bind(marks, argument_sources, serialized) -> bound, missing: each step's mark (by
-- name, kind milestone); where the named arguments come from ({ name = function }); whether the
-- shared tables' functions are serialized (steps with locks run ahead only then)
function init_steps.bind(marks, argument_sources, serialized)
    sources = argument_sources or {}
    locks = serialized and true or false
    local missing = {}
    for _, m in ipairs(marks) do
        if m.kind == "milestone" and m.id and m.trampoline then
            by_name[m.name] = m
        end
    end
    local bound = 0
    for _, step in ipairs(init_steps.STEPS) do
        if by_name[step.name] then
            bound = bound + 1
        else
            missing[#missing + 1] = step.name
        end
    end
    return bound, missing
end

local function argument(a)
    if a == "application" then
        return stellar.loading_application()
    elseif type(a) == "string" then
        return sources[a] and sources[a]() or nil
    end
    return a
end

-- init_steps.start(at) -> started: the steps of that point, each on a thread of its own; the
-- game's call of each waits for it
function init_steps.start(at)
    local n = 0
    -- the steps of this point that can start, as { step, mark, function and arguments }, alone or
    -- in their chains (one thread each, in the table's order)
    local alone, chains, chain_order = {}, {}, {}
    for _, step in ipairs(init_steps.STEPS) do
        local m = by_name[step.name]
        if step.at == at and m and not started[step.name] and (locks or not step.locks) then
            local call, ok = { m.trampoline }, true
            for i, a in ipairs(step.args) do
                call[i + 1] = argument(a)
                ok = ok and call[i + 1] ~= nil
            end
            if ok then
                local item = { step = step, mark = m, call = call }
                if step.chain then
                    if not chains[step.chain] then
                        chains[step.chain] = {}
                        chain_order[#chain_order + 1] = step.chain
                    end
                    table.insert(chains[step.chain], item)
                else
                    alone[#alone + 1] = item
                end
            end
        end
    end
    -- the shared tables locked from now until the last step is joined
    local function lock_if_needed(item)
        if item.step.locks and not locked_now then
            stellar.serialize_until_joined()
            locked_now = true
        end
    end
    local function defer(item, id)
        stellar.defer_mark(item.mark.id, id)
        started[item.step.name] = id
        n = n + 1
    end
    for _, item in ipairs(alone) do
        lock_if_needed(item)
        local id = stellar.run_async(item.call[1], item.call[2], item.call[3], item.call[4], item.call[5])
        if id then
            defer(item, id)
        end
    end
    for _, name in ipairs(chain_order) do
        local calls = {}
        for i, item in ipairs(chains[name]) do
            lock_if_needed(item)
            calls[i] = item.call
        end
        local ids = stellar.run_async_chain(calls)
        for i, item in ipairs(chains[name]) do
            if ids and ids[i] then
                defer(item, ids[i])
            end
        end
    end
    return n
end

-- init_steps.report() -> text: each step started, how long it ran, and the waits for them
function init_steps.report()
    local parts = {}
    for _, step in ipairs(init_steps.STEPS) do
        local call = started[step.name]
        if call then
            local code, what = stellar.join_async(call, 0)
            if code == nil then
                parts[#parts + 1] = step.name .. " still running"
            else
                parts[#parts + 1] = string.format("%s %.2fs%s", step.name, (what.finish or 0) - (what.start or 0),
                    code ~= 0 and string.format(" (failed: 0x%08x)", code) or "")
            end
        end
    end
    local joins, waited, pending = stellar.deferred_stats()
    return string.format("%s; the game waited %.2fs in %d calls (%d not called)", table.concat(parts, ", "), waited,
        joins, pending)
end

return init_steps
