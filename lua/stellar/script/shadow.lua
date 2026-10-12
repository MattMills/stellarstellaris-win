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

-- Whether a statement (its key, lower case) made a native node. k can also be a value that names a
-- trigger: `trigger:pop_amount`, `owner.trigger:num_ascension_perks` (the trigger it names).
local function makes(ctx, k, child)
    k = k:match("trigger:([%w_]+)$") or k
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
        -- `hidden:owner = { }` is the scope change owner without its tooltip
        k = k:gsub("^hidden:", "")
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
-- body compared with the definition read as the game does (source.instantiate, no arguments).
local function scripted(kind, options)
    local fs = source.filesystem_of(options.game_dir)
    local defs, errors = source.definitions(fs, kind.directory)
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
            local block, message = source.instantiate(fs, def, {}, result.expand_errors)
            if block == nil then
                result.expand_errors[#result.expand_errors + 1] = name .. ": " .. tostring(message)
            else
                compare_block(ctx, block, decompile(n, body), string.format("%s:%d %s", def.file, def.line, name))
                result.compared = result.compared + 1
                if ctx.mismatches == before then
                    result.identical = result.identical + 1
                end
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
--   options: catalog (after a census), read, game_dir (the game directory, or a source.filesystem
--   with mods), calls (the CScriptedTrigger / CScriptedEffect objects of the census)
function shadow.scripted_triggers(options)
    return scripted(KINDS.trigger, options)
end

function shadow.scripted_effects(options)
    return scripted(KINDS.effect, options)
end

-- Everything the game compiled ------------------------------------------------------------------

-- An event's picture reads a `picture = { ... }` inside its block as more of itself: vanilla puts
-- inline scripts that make whole picture blocks inside a picture block, and the game reads all
-- their triggers into one (the first, then the others appended, merged_siblings). The nested blocks'
-- entries are spliced in place; entries from an inline script keep its location.
local function flatten_pictures(block)
    for _, e in ipairs(block) do
        if e.op and e.key and is_block(e) then
            if e.key.text:lower() == "picture" then
                local out, nested = {}, false
                for _, inner in ipairs(e.value) do
                    if inner.op and inner.key and inner.key.text:lower() == "picture" and is_block(inner) then
                        nested = true
                        for _, x in ipairs(inner.value) do
                            x.inline = x.inline or inner.inline
                            out[#out + 1] = x
                        end
                    else
                        out[#out + 1] = inner
                    end
                end
                if nested then
                    for i = #e.value, 1, -1 do
                        e.value[i] = nil
                    end
                    for i, x in ipairs(out) do
                        e.value[i] = x
                    end
                end
            end
            flatten_pictures(e.value)
        end
    end
end

-- The place of a location: its file and its key in that file's index (index_lines). The key is
-- the line for " file: events/x.txt line: 123", and the whole location for the content of inline
-- scripts, " file: events/x.txt:12(inline_script) common/inline_scripts/y.txt line: 3" (a chain
-- when inline scripts include others). Other locations are inside scripted triggers or effects
-- (" path:line @ scripted effect x at ...") or script values.
local function place(location)
    location = location or ""
    local file, line = location:match("^%s*file: (%S+) line: (%d+)%s*$")
    if file then
        return file, tonumber(line)
    end
    file = location:match("^%s*file: (%S-):%d+%(inline_script%) ")
    if file and location:find("^%s*file: [^@]- line: %d+%s*$") then
        return file, (location:gsub("^%s+", ""):gsub("%s+$", ""))
    end
end

-- The statements of an expanded tree by place (of the key, and of the `{` when it is on another
-- line), outer ones first, each with its parent block. The place is the line, or for the content
-- of an inline script the location the game gives it (source.expand's `inline` and the line in the
-- inline script, place's key).
local function index_lines(block, by_line, where)
    local function add(line, e, w)
        local key = w and (w .. " line: " .. line) or line
        local list = by_line[key]
        if list == nil then
            list = {}
            by_line[key] = list
        end
        list[#list + 1] = e
    end
    for _, e in ipairs(block) do
        local w = e.inline or where
        if e.op and e.key then
            e.parent = block
            add(e.line, e, w)
            if is_block(e) then
                if e.value.line and e.value.line ~= e.line then
                    add(e.value.line, e, w)
                end
                index_lines(e.value, by_line, w)
            end
        elseif e.param or e.text == nil then
            -- a parameter block, or a block in a list (`{ name = x trigger = { } }` in ship_sizes)
            index_lines(e, by_line, w)
        end
    end
end

local function new_ctx(catalog, kind, max_examples)
    return { catalog = catalog, kind = kind, matched = 0, mismatches = 0, nullable_differences = 0,
        skipped = {}, skipped_at = {}, examples = {}, max_examples = max_examples }
end

local function merge(into, from)
    into.matched = into.matched + from.matched
    into.mismatches = into.mismatches + from.mismatches
    into.nullable_differences = into.nullable_differences + from.nullable_differences
    for k, n in pairs(from.skipped) do
        into.skipped[k] = (into.skipped[k] or 0) + n
        local at = into.skipped_at[k] or {}
        into.skipped_at[k] = at
        for _, place_at in ipairs(from.skipped_at[k] or {}) do
            if #at < 3 then
                at[#at + 1] = place_at
            end
        end
    end
    for _, example in ipairs(from.examples) do
        if #into.examples < into.max_examples then
            into.examples[#into.examples + 1] = example
        end
    end
end

-- The keyword in `trigger = ...` of a switch block, lower case.
local function switch_trigger(block)
    for _, e in ipairs(block) do
        if e.op and e.key and e.key.text:lower() == "trigger" and e.value.text then
            return e.value.text:lower()
        end
    end
end

local BLOCKS = { ["(trigger block)"] = true, ["(effect block)"] = true, ["(modifier block)"] = true,
    ["(random_list entry)"] = true }
local SWITCHES = { switch = true, inverted_switch = true }

-- Whether a value of a statement of the block names the node (`amount = x@root.trigger:fleet_integrity`).
local function names_in_block(ctx, block, node)
    for _, e in ipairs(block) do
        if e.op and e.value and e.value.text and e.value.text:find("trigger:", 1, true)
            and makes(ctx, e.value.text:lower(), node) then
            return true
        end
    end
    return false
end

-- The entries of a block statement followed by those of the later statements with the same key in
-- the same block, or nil if there are none.
local function merged_siblings(e)
    if e.parent == nil then
        return nil
    end
    local k, after, merged = e.key.text:lower(), false, nil
    for _, s in ipairs(e.parent) do
        if s == e then
            after = true
            merged = {}
            for _, inner in ipairs(e.value) do
                merged[#merged + 1] = inner
            end
        elseif after and s.op and s.key and s.key.text:lower() == k and is_block(s) then
            merged.extended = true
            for _, inner in ipairs(s.value) do
                merged[#merged + 1] = inner
            end
        end
    end
    return merged and merged.extended and merged or nil
end

-- The statement at a root's line that made it: the first one without a mismatch, else the one with
-- the fewest. Returns the scratch context of that comparison, or nil if no statement fits.
local function compare_root(catalog, kind, root, candidates, where)
    local best
    local has_children = (root.children and #root.children > 0) or root.next or root.else_children
    local empty_block = not has_children and (root.children ~= nil or BLOCKS[root.name])
    for _, e in ipairs(candidates) do
        local ctx = new_ctx(catalog, kind, 10)
        local k = e.key.text:lower()
        local at = string.format("%s > %s (line %d)", where, e.key.text, e.line)
        if has_children then
            if is_block(e) then
                compare_block(ctx, e.value, root, at)
                -- the same key again in the same block: the game appends their content to the
                -- first one (two init_effect blocks of a system initializer)
                local merged = merged_siblings(e)
                if ctx.mismatches > 0 and merged then
                    local again = new_ctx(catalog, kind, 10)
                    compare_block(again, merged, root, at .. " (merged with the later " .. e.key.text .. ")")
                    if again.mismatches < ctx.mismatches then
                        ctx = again
                    end
                end
            else
                ctx = nil
            end
        elseif makes(ctx, k, root) or (e.value and e.value.text and makes(ctx, e.value.text:lower(), root)) then
            -- the statement makes it (`has_x = yes`), or names it (`trigger = num_districts`)
            ctx.matched = 1
        elseif SWITCHES[k] and is_block(e) and switch_trigger(e.value) and makes(ctx, switch_trigger(e.value), root) then
            -- the trigger a switch compares its cases with (`switch = { trigger = has_ethic ... }`):
            -- the game makes one per case, at the line of the switch
            ctx.matched = 1
        elseif not root.children and is_block(e) and names_in_block(ctx, e.value, root) then
            -- a trigger a member of the block names (`hostile_military_power = { value > root.trigger:fleet_power }`):
            -- the game places it at the line of the block's statement
            ctx.matched = 1
        elseif empty_block then
            -- an empty block: `on_fail = { }`, or a value (`weight = 0.2` in a weight block)
            if is_block(e) then
                compare_block(ctx, e.value, root, at)
            end
            ctx.matched = ctx.matched + 1
        else
            ctx = nil
        end
        if ctx then
            if ctx.mismatches == 0 then
                return ctx
            elseif best == nil or ctx.mismatches < best.mismatches then
                best = ctx
            end
        end
    end
    return best
end

-- shadow.everything(options) -> result: every compiled trigger and effect tree the game read from a
-- file (not from a scripted trigger or effect or an inline script, which are the content of a tree),
-- compared with the statement at its place in our reading of that file.
--   options: catalog (after a census), read, game_dir (the game directory, or a source.filesystem
--   with mods), triggers, effects (every object: the census' all lists), log (progress),
--   max_examples
-- The roots are the objects no other object points to (native:links); members a trigger or effect
-- keeps outside its children (the limit of count_*, ...) are roots of their own, compared at their
-- own place. result.directories[dir] = { roots, compared, identical, matched, mismatches,
-- no_statement }, plus indirect (roots placed in scripted or inline content), files (read),
-- file_errors, examples, skipped.
function shadow.everything(options)
    local log = options.log or function() end
    local catalog = options.catalog
    local n = native.new(catalog, options.read)
    n:learn(options.triggers)

    -- the roots
    local roots = {}
    for _, kind in ipairs({ "trigger", "effect" }) do
        local objects = kind == "trigger" and options.triggers or options.effects
        local pointed = {}
        for _, object in ipairs(objects) do
            n:links(object, kind, pointed)
        end
        local count = 0
        for _, object in ipairs(objects) do
            if not pointed[object] then
                roots[#roots + 1] = { object = object, kind = kind }
                count = count + 1
            end
        end
        log(string.format("shadow: %d %s objects, %d roots", #objects, kind, count))
    end

    local result = { directories = {}, indirect = 0, indirect_kinds = {}, files = 0, file_errors = {},
        expand_errors = {}, empty = 0, instances = 0, instance_errors = {} }
    local total = new_ctx(catalog, nil, options.max_examples or 200)
    local function directory(dir)
        local d = result.directories[dir]
        if d == nil then
            d = { roots = 0, compared = 0, identical = 0, matched = 0, mismatches = 0, no_statement = 0 }
            result.directories[dir] = d
        end
        return d
    end
    local function account(d, ctx, what)
        if ctx == nil then
            d.no_statement = d.no_statement + 1
            if #total.examples < total.max_examples then
                total.examples[#total.examples + 1] = what
            end
        else
            d.compared = d.compared + 1
            d.matched = d.matched + ctx.matched
            d.mismatches = d.mismatches + ctx.mismatches
            if ctx.mismatches == 0 then
                d.identical = d.identical + 1
            end
            merge(total, ctx)
        end
    end

    -- scripted calls: an instance is a definition read with a call's arguments, shared by the calls
    -- with the same arguments; by_call finds the instance of the content placed
    -- `@ scripted effect x at <the call's location>`
    local fs = source.filesystem_of(options.game_dir)
    local defs = { trigger = source.definitions(fs, "common/scripted_triggers"),
        effect = source.definitions(fs, "common/scripted_effects") }
    local by_call, by_body, instances = {}, {}, {}
    for _, kind in ipairs({ "trigger", "effect" }) do
        local scripted = KINDS[kind].scripted
        local lower = {}
        for name, def in pairs(defs[kind]) do
            lower[name:lower()] = def
        end
        for _, object in ipairs(kind == "trigger" and options.triggers or options.effects) do
            if n:name(object) == scripted then
                local call = n[kind](n, object, 64)
                if call.tag and call.body ~= 0 then
                    local instance = by_body[call.body]
                    if instance == nil then
                        instance = { kind = kind, tag = call.tag, body = call.body, def = lower[call.tag:lower()],
                            args = n:arguments(object, kind) or {}, roots = {} }
                        by_body[call.body] = instance
                        instances[#instances + 1] = instance
                    end
                    by_call[call.tag .. " at " .. (call.location or ""):gsub("^%s+", "")] = instance
                end
            end
        end
    end
    by_body = nil
    log(string.format("shadow: %d scripted instances", #instances))

    -- the places of the roots: a file, or the instance of a scripted call
    local by_file, files = {}, {}
    for _, root in ipairs(roots) do
        local decompile = root.kind == "trigger" and n.trigger or n.effect
        local location = decompile(n, root.object, 64).location
        local file, line = place(location)
        if file == nil and (location == nil or location == "") then
            -- no location: the blocks an object of a database has whether its script sets them or
            -- not (empty), and blocks the game reads without noting where (an event's immediate
            -- and options): those are placed by their first child, which has a location
            local node = decompile(n, root.object, 63)
            if not (node.children and #node.children > 0) and not node.next then
                result.empty = result.empty + 1
                file = false
            else
                file, line = place(decompile(n, node.children[1].object, 64).location)
                root.via_child = file ~= nil
            end
        end
        if file == nil then
            -- inside a scripted trigger or effect: `<definition file>:<line> @ scripted effect <tag> at <the call's location>`
            local def_line, tag, rest = tostring(location):match("^%s*%S+:(%d+) @ [%a ]-scripted %a+ (%S+) at (.*)$")
            local instance = tag and by_call[tag .. " at " .. rest]
            if instance then
                root.line = tonumber(def_line)
                instance.roots[#instance.roots + 1] = root
                file = false
            end
        end
        if file then
            root.line = line
            local list = by_file[file]
            if list == nil then
                list = {}
                by_file[file] = list
                files[#files + 1] = file
            end
            list[#list + 1] = root
        elseif file == nil then
            result.indirect = result.indirect + 1
            -- what it is inside: the first marker of the location
            local s = tostring(location)
            local kind = (s == "" or s == "nil") and "no location"
                or s:match("^%s*[^@]-@ (in scripted trigger)") or s:match("^%s*[^@]-@ (scripted trigger)")
                or s:match("^%s*[^@]-@ (scripted effect)") or s:match("(script value)")
                or (s:find("(inline_script)", 1, true) and "inline script") or "other"
            local k = result.indirect_kinds[kind]
            if k == nil then
                k = { count = 0, example = s, names = {} }
                result.indirect_kinds[kind] = k
            end
            k.count = k.count + 1
            local name = (n:name(root.object) or "?") .. " (" .. root.kind .. ")"
            k.names[name] = (k.names[name] or 0) + 1
        end
    end
    roots, by_call = nil, nil
    table.sort(files)
    collectgarbage()
    log(string.format("shadow: roots in %d files and %d instances, %d elsewhere", #files, #instances, result.indirect))

    -- compares the roots of a source with its reading, indexed by line
    local function compare_roots(list, by_line, d, label)
        d.roots = d.roots + #list
        for _, root in ipairs(list) do
            local kind = KINDS[root.kind]
            local node = (root.kind == "trigger" and n.trigger or n.effect)(n, root.object)
            -- root.line: a line of the source, or the game's location of inline script content
            local where = type(root.line) == "number" and (label .. ":" .. root.line) or root.line
            local ctx
            if by_line == nil then
                ctx = nil
            elseif root.via_child then
                -- the block of the statement at its first child's line
                for _, e in ipairs(by_line[root.line] or {}) do
                    if e.parent then
                        local try = new_ctx(catalog, kind, 10)
                        compare_block(try, e.parent, node, where .. " (the block of its first child)")
                        if ctx == nil or try.mismatches < ctx.mismatches then
                            ctx = try
                        end
                    end
                end
            else
                ctx = compare_root(catalog, kind, node, by_line[root.line] or {}, where)
            end
            account(d, ctx, string.format("%s: no statement for the game's %s %s", where, root.kind, describe(node)))
        end
    end

    -- each file: read, index, compare its roots
    for _, file in ipairs(files) do
        local tree, message = source.parse(fs, file)
        result.files = result.files + 1
        local by_line
        if tree == nil then
            result.file_errors[#result.file_errors + 1] = message
        else
            by_line = {}
            local expanded = source.expand(fs, tree, result.expand_errors, 0, "file: " .. file)
            flatten_pictures(expanded)
            index_lines(expanded, by_line)
        end
        -- the file's own statements, and the content of the inline scripts it calls
        local own, inline = {}, {}
        for _, root in ipairs(by_file[file]) do
            local list = type(root.line) == "number" and own or inline
            list[#list + 1] = root
        end
        local dir = file:match("^(common/[^/]+)/") or file:match("^([^/]+)/") or file
        compare_roots(own, by_line, directory(dir), file)
        compare_roots(inline, by_line, directory("(inline script content)"), file)
        by_file[file] = nil
    end

    -- each instance: read the definition with its arguments, compare its body and its roots
    for i, instance in ipairs(instances) do
        local kind = KINDS[instance.kind]
        local d = directory("(scripted " .. instance.kind .. " instances)")
        d.roots = d.roots + 1
        result.instances = result.instances + 1
        local def = instance.def
        local label = string.format("%s %s%s", def and def.file or "?", instance.tag, #instance.args > 0 and " (with arguments)" or "")
        local block, message
        if def then
            block, message = source.instantiate(fs, def, instance.args, result.expand_errors)
        end
        if block == nil and #result.instance_errors < 50 then
            result.instance_errors[#result.instance_errors + 1] = instance.tag .. ": " .. tostring(message or "no definition")
        end
        local ctx
        if block then
            ctx = new_ctx(catalog, kind, 10)
            compare_block(ctx, block, n[kind.decompile](n, instance.body), string.format("%s:%d", label, def.line))
        end
        account(d, ctx, label .. ": no definition, or it cannot be read")
        if #instance.roots > 0 then
            local by_line
            if block then
                by_line = {}
                index_lines(block, by_line)
            end
            compare_roots(instance.roots, by_line, directory("(content of scripted " .. instance.kind .. "s)"), label)
        end
        instances[i] = nil
        if i % 2000 == 0 then
            collectgarbage("step", 0)
        end
    end
    result.examples, result.skipped, result.skipped_at = total.examples, total.skipped, total.skipped_at
    result.matched, result.mismatches = total.matched, total.mismatches
    return result
end

return shadow
