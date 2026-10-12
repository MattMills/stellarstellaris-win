-- shadow.lua : our reading of the game's script, next to the game's own (docs/script_engine.md).
--
-- The script files parsed in Lua (stellar.script.source) are compared, node by node, with what the
-- game compiled from them (stellar.script.native). The children of a native node are aligned, in
-- order, with the statements of the block they were read from: each child must be made by a
-- following statement (after inline scripts are expanded, as the game does), by the same trigger or
-- effect class (aliases such as any_owned_planet and any_owned_colony share one), scope chain or
-- scripted trigger or effect name, and have the same children. Statements that make no child are
-- skipped and counted by key: what a trigger or effect reads into its own members (limit, count,
-- text in custom_tooltip, ...) and else / else_if, which the game attaches to the preceding if.
--
--   local shadow = require("stellar.script.shadow")
--   local result = shadow.scripted_triggers({ catalog = c, read = stellar.read, game_dir = dir,
--       calls = <CScriptedTrigger objects from a census> })   -- and shadow.scripted_effects

local native = require("stellar.script.native")
local source = require("stellar.script.source")

local shadow = {}

local LOGIC = { ["and"] = true, ["or"] = true, ["not"] = true, ["nor"] = true, ["nand"] = true }

-- What differs between triggers and effects
local KINDS = {
    trigger = { entries = "triggers", scripted = "(scripted trigger)", scope = "(scope trigger)",
        decompile = "trigger", directory = "common/scripted_triggers" },
    effect = { entries = "effects", scripted = "(scripted effect)", scope = "(scope effect)",
        decompile = "effect", directory = "common/scripted_effects" },
}

-- Whether a statement (its key, lower case) made a native node.
local function makes(ctx, k, child)
    local bare = k:gsub("%?$", "")
    local entry = ctx.catalog[ctx.kind.entries][bare]
    if entry and child.vtable and entry.vtable then
        if child.vtable == entry.vtable then
            return true
        end
    elseif (ctx.kind == KINDS.trigger and LOGIC[bare]) or entry then
        if child.name == bare then
            return true
        end
    end
    if child.name == ctx.kind.scripted then
        return (child.tag or ""):lower() == bare
    elseif child.name == ctx.kind.scope then
        local target = (child.target or ""):lower()
        if target == k then
            return true
        elseif target:gsub("%?", "") == k:gsub("%?", "") then
            -- the same chain, but a `?` on another link
            ctx.nullable_differences = ctx.nullable_differences + 1
            return true
        end
    elseif child.name == "(random_list entry)" then
        -- random_list = { 10 = { ... } 20 = { ... } }
        return k:find("^%d") ~= nil
    end
    return false
end

local function note(ctx, message)
    ctx.mismatches = ctx.mismatches + 1
    if #ctx.examples < ctx.max_examples then
        ctx.examples[#ctx.examples + 1] = message
    end
end

local function describe(child)
    return string.format("%s%s%s%s (%s)", child.name, child.target and (" " .. child.target) or "",
        child.display and (" [" .. child.display .. "]") or "",
        child.tag and (" " .. child.tag) or "", child.location or "?")
end

local compare_block

-- A statement that made no native node: counted by key, with the first places it is at.
local function skip(ctx, e, where)
    local k = e.key.text:lower()
    ctx.skipped[k] = (ctx.skipped[k] or 0) + 1
    local at = ctx.skipped_at[k] or {}
    ctx.skipped_at[k] = at
    if #at < 3 then
        at[#at + 1] = string.format("%s > %s (line %d)", where, e.key.text, e.line)
    end
end

local function is_block(e)
    return e.value and e.value.text == nil
end

-- The else_if / else statements after an if (statements[j], ...), against the chain of the native
-- if node: each else_if is the next if of the chain (_pElse); an else is the else block of the
-- last effect if (_Else), or the last trigger if of the chain. Returns the index after them.
local function compare_else(ctx, statements, j, node, where)
    local current = node
    while statements[j] do
        local e = statements[j]
        local k = e.key.text:lower()
        local other
        if k == "else_if" then
            other = current.next
        elseif k == "else" then
            other = current.next
            if other == nil and current.else_children then
                other = { name = "else", children = current.else_children }
            end
        else
            break
        end
        local at = string.format("%s > %s (line %d)", where, e.key.text, e.line)
        if other == nil then
            note(ctx, at .. ": the game has no " .. k .. " here")
        else
            ctx.matched = ctx.matched + 1
            if is_block(e) then
                compare_block(ctx, e.value, other, at)
            end
            current = other
        end
        j = j + 1
        if k == "else" then
            break
        end
    end
    return j
end

-- Aligns the children of a native node with the statements of the AST block they came from. An
-- `else` inside an effect if's own block (the old form, `if = { limit = { } ... else = { } }`) is
-- that if's else block (_Else).
compare_block = function(ctx, block, node, where)
    local statements = {}
    for _, e in ipairs(block) do
        if e.op and e.key then
            if node.else_children and e.key.text:lower() == "else" and is_block(e) then
                ctx.matched = ctx.matched + 1
                compare_block(ctx, e.value, { name = "else", children = node.else_children },
                    string.format("%s > %s (line %d)", where, e.key.text, e.line))
            else
                statements[#statements + 1] = e
            end
        end
    end
    local j = 1
    for _, child in ipairs(node.children or {}) do
        local found
        for s = j, #statements do
            if makes(ctx, statements[s].key.text:lower(), child) then
                found = s
                break
            end
        end
        if found then
            for s = j, found - 1 do
                skip(ctx, statements[s], where)
            end
            local e = statements[found]
            local at = string.format("%s > %s (line %d)", where, e.key.text, e.line)
            ctx.matched = ctx.matched + 1
            j = found + 1
            if is_block(e) and (child.children or child.next or child.else_children) then
                compare_block(ctx, e.value, child, at)
            end
            if child.next ~= nil or child.else_children ~= nil or e.key.text:lower() == "if" then
                j = compare_else(ctx, statements, j, child, where)
            end
        else
            note(ctx, string.format("%s: no statement for the game's %s", where, describe(child)))
        end
    end
    for s = j, #statements do
        skip(ctx, statements[s], where)
    end
end

-- Every scripted trigger or effect the game instantiated without arguments (from its calls), its
-- body compared with the definition parsed from the files.
local function scripted(kind, options)
    local defs, errors = source.definitions(options.game_dir, kind.directory)
    local n = native.new(options.catalog, options.read)
    local decompile = n[kind.decompile]
    local ctx = { catalog = options.catalog, kind = kind, matched = 0, mismatches = 0, nullable_differences = 0,
        skipped = {}, skipped_at = {}, examples = {}, max_examples = options.max_examples or 25 }

    -- one call without arguments per definition: its body is the instantiated definition
    local bodies, calls_with_args = {}, 0
    for _, object in ipairs(options.calls) do
        local call = decompile(n, object, 64) -- the call only, not its children
        if call.args == 0 and call.tag and call.body ~= 0 then
            bodies[call.tag:lower()] = bodies[call.tag:lower()] or call.body
        elseif call.args ~= 0 then
            calls_with_args = calls_with_args + 1
        end
    end

    local result = { definitions = 0, compared = 0, not_instantiated = 0, identical = 0, parse_errors = errors,
        expand_errors = {} }
    for name, def in pairs(defs) do
        result.definitions = result.definitions + 1
        local body = bodies[name:lower()]
        if body == nil then
            result.not_instantiated = result.not_instantiated + 1
        else
            local before = ctx.mismatches
            local block = source.expand(options.game_dir, def.block, result.expand_errors)
            compare_block(ctx, block, decompile(n, body), string.format("%s:%d %s", def.file, def.line, name))
            result.compared = result.compared + 1
            if ctx.mismatches == before then
                result.identical = result.identical + 1
            end
        end
    end
    result.calls_with_args = calls_with_args
    result.matched, result.mismatches, result.examples = ctx.matched, ctx.mismatches, ctx.examples
    result.skipped, result.skipped_at, result.nullable_differences = ctx.skipped, ctx.skipped_at, ctx.nullable_differences
    result.sample_location = next(bodies) and decompile(n, select(2, next(bodies)), 64).location
    return result
end

-- shadow.scripted_triggers(options), shadow.scripted_effects(options) -> result
--   options: catalog (after a census), read, game_dir, calls (the CScriptedTrigger /
--   CScriptedEffect objects of the census)
function shadow.scripted_triggers(options)
    return scripted(KINDS.trigger, options)
end

function shadow.scripted_effects(options)
    return scripted(KINDS.effect, options)
end

return shadow
