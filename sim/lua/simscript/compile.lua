-- simscript/compile.lua : the script compiler. The trigger blocks, value blocks, weight blocks,
-- value texts, scope chains and script values that simscript/eval.lua evaluates are compiled into
-- Lua closures, once per block (text, spec) and cached on it, so that what the walker works out
-- again on every call from the raw tokens (the keyword lowercased, its handler class, tonumber, a
-- scope chain split into links, a @variable's file, a scripted trigger's or value's instance, the
-- if / else_if / else chains) is worked out once. docs/script_compiler.md has the design, the
-- measurements and the semantics matched.
--
-- Closures, not generated source (load): they share their prototypes, so LuaJIT's traces serve
-- every block of a shape (docs/script_compiler.md, section 3). A block is compiled at its second
-- evaluation with its sub-blocks; a statement's branch after the handler lookup (a scope, an
-- iterator, a scripted trigger, a flag, a property) when the statement first takes it.
--
-- What it matches, exactly (the walker stays the reference, and is what runs for a block the first
-- time it is seen):
--   - every lookup the walker makes at call time is made at call time here too: TRIG, LINKS, LISTS,
--     AMOUNTS (modules swap their entries, engine/economy/script.lua's script.with and others),
--     M.script_value, M.value, M.count_items, M.count_value, M.store, E, db's definitions;
--   - what is inlined is guarded: a handler of eval.lua's own (or, not, exists, has_global_flag,
--     ...) only while TRIG still has it, M.resolve and M.property only while they are the ones
--     installed here (else the statement goes to the walker);
--   - the order of every evaluation, every miss() and sync(), and stats.trigger_evals (one per
--     statement the walker would evaluate);
--   - no draws: triggers and values draw nothing; effects are not compiled (they are walked, their
--     triggers and values compiled), so the draws are the walker's.
--
-- STELLAR_SCRIPT_COMPILE=off: not installed (eval.lua alone). STELLAR_SCRIPT_COMPILE_AFTER=n:
-- a block is compiled at its n-th evaluation (default 2: a block evaluated once is only walked).
-- STELLAR_SCRIPT_CHECK=1: every compiled evaluation (trigger block, value block, weight, value
-- text, scope chain, script value) is followed by the walker's on the same input, and the results
-- (and the trigger evaluation counts) compared; mismatches are counted by kind and block.

local C = { stats = { trigger_blocks = 0, value_blocks = 0, weights = 0, texts = 0, chains = 0, script_values = 0,
    statements = 0, fallbacks = 0, compile_seconds = 0 } }

function C.install(M)
    local I = M._internal
    local S, NONE, E, db, state, stats = I.S, I.NONE, I.E, I.db, I.state, I.stats
    local miss, sync, push, with_file, compare = I.miss, I.sync, I.push, I.with_file, I.compare
    local list_of, var_raw, mathexpr, scripted_call = I.list_of, I.var_raw, I.mathexpr, I.scripted_call
    local LINKS, TRIG, CREATED_KIND = I.LINKS, I.TRIG, I.CREATED_KIND
    local VALUE_OPS, ITER_PARAMS, LIMIT_ONLY, TOOLTIP_PARAMS, AMOUNT =
        I.VALUE_OPS, I.ITER_PARAMS, I.LIMIT_ONLY, I.TOOLTIP_PARAMS, I.AMOUNT
    local PROP_SET = I.PROP_SET
    local trigger_tree, trigger1, trigger1_rest = I.trigger_tree, I.trigger1, I.trigger1_rest
    local apply_ops_tree, value_text_tree = I.apply_ops_tree, I.value_text_tree
    local RESOLVE0, SCRIPT_VALUE0, WEIGHT0, PROPERTY0 = M.resolve, M.script_value, M.weight, M.property
    local CS = C.stats
    local clock = os.clock
    local floor, abs, ceil, max, min = math.floor, math.abs, math.ceil, math.max, math.min

    -- eval.lua's own trigger handlers (TRIG as eval.lua leaves it)
    local B = {}
    for k, f in pairs(TRIG) do B[k] = f end

    local AFTER = tonumber(os.getenv("STELLAR_SCRIPT_COMPILE_AFTER") or "") or 2
    local CHECK = os.getenv("STELLAR_SCRIPT_CHECK") == "1"
    -- REF: while the walker runs as the reference of a check, everything goes to the walker
    local REF = false

    local WEAKK = { __mode = "k" }

    -- -----------------------------------------------------------------------------------------
    -- the check mode

    local CK = { checks = 0, mismatches = 0, where = {} }
    C.check = CK
    local function mismatch(kind, wh, detail)
        CK.mismatches = CK.mismatches + 1
        local k = kind .. " " .. wh
        local m = CK.where[k]
        if not m then
            m = { kind = kind, where = wh, count = 0, detail = detail }
            CK.where[k] = m
        end
        m.count = m.count + 1
    end
    local function same(a, b)
        return a == b or (a ~= a and b ~= b)
    end
    -- the walker's f(...) as the reference: { pcall's results }, and the statements it evaluated
    -- (its misses and its trigger evaluations not counted; REF on while it runs)
    local function reference(f, ...)
        local was = REF
        REF = true
        local missing = stats.missing
        stats.missing = {}
        local n0 = stats.trigger_evals
        local res = { pcall(f, ...) }
        local dn = stats.trigger_evals - n0
        stats.trigger_evals = n0
        stats.missing = missing
        REF = was
        return res, dn
    end
    -- a compiled evaluation's results against the walker's: res (reference's), r1 / r2 (the
    -- compiled results), dn (the compiled statements evaluated), rdn (the walker's)
    local function compare_ref(kind, wh, res, rdn, r1, dn, two, r2)
        if not res[1] then
            mismatch(kind, wh, "walker error " .. tostring(res[2]))
        elseif not same(r1, res[2]) or (two and r2 ~= res[3]) then
            mismatch(kind, wh, tostring(r1) .. (two and (" " .. tostring(r2 and r2.key)) or "") .. " / " ..
                tostring(res[2]) .. (two and (" " .. tostring(res[3] and res[3].key)) or ""))
        elseif dn ~= rdn then
            mismatch(kind .. " count", wh, dn .. " / " .. rdn)
        end
    end

    -- -----------------------------------------------------------------------------------------
    -- scope chains: `owner`, `root.owner.capital_scope`, `event_target:x`, `last_created_leader`

    -- the parts of a chain as M.resolve reads them: kind 1 a saved target (event_target: / scope:),
    -- 2 last_created_, 3 a link in first place (not a scope reference when there is no such link),
    -- 4 a link after the first (a miss when there is none)
    local function chain_parts(text)
        local parts = {}
        local first = true
        for part in text:gmatch("[^%.]+") do
            local p = part:gsub("%?$", "")
            local lp = p:lower()
            local d = { lp = lp }
            if lp:sub(1, 13) == "event_target:" or lp:sub(1, 6) == "scope:" then
                d.kind, d.name = 1, p:match(":(.*)$")
            elseif lp:sub(1, 13) == "last_created_" then
                d.kind, d.ck = 2, lp:sub(14)
                d.k = CREATED_KIND[d.ck]
            elseif first then
                d.kind = 3
            else
                d.kind = 4
            end
            parts[#parts + 1] = d
            first = false
        end
        return parts
    end

    -- the resolver of a chain: function(ctx, e) -> found, scope (M.resolve's results)
    local function make_resolver(text)
        local parts = chain_parts(text)
        local n = #parts
        CS.chains = CS.chains + 1
        if n == 0 then
            return function() return false end
        end
        if n == 1 and parts[1].kind == 3 then
            local lp = parts[1].lp
            return function(ctx)
                local link = LINKS[lp]
                if link then
                    local nxt = link(ctx.this, ctx)
                    if nxt == nil then return true, nil end
                    return true, nxt
                end
                return false
            end
        end
        return function(ctx, e)
            local cur = ctx.this
            for i = 1, n do
                local d = parts[i]
                local lp = d.lp
                local nxt
                local link = LINKS[lp]
                if link then
                    nxt = link(cur, ctx)
                else
                    local kind = d.kind
                    if kind == 1 then
                        local name = d.name
                        nxt = ctx.targets[name] or state.global_targets[name]
                    elseif kind == 2 then
                        local h = ctx.created[d.ck]
                        if not d.k then
                            miss("scope link", lp, ctx, e)
                            return true, nil
                        end
                        if h then
                            sync() -- the barrier: the created object exists only after the flush
                            local id = E.resolve(h)
                            nxt = id and S(d.k, id) or nil
                        end
                    elseif kind == 3 then
                        return false
                    else
                        miss("scope link", lp, ctx, e)
                        return true, nil
                    end
                end
                if nxt == nil then
                    return true, nil
                end
                cur = nxt
            end
            return true, cur
        end
    end

    -- the caches of texts (scope chains, value texts, script value specs): the script's own texts,
    -- a few thousand; emptied past CAP entries (what is compiled keeps its own)
    local CAP = 100000
    local RES, nRES = {}, 0
    local function resolver(text)
        local r = RES[text]
        if r == nil then
            r = make_resolver(text)
            if CHECK then
                local f = r
                r = function(ctx, e)
                    local n0 = stats.trigger_evals
                    local found, sc = f(ctx, e)
                    local dn = stats.trigger_evals - n0
                    CK.checks = CK.checks + 1
                    local res, rdn = reference(RESOLVE0, text, ctx, e)
                    compare_ref("chain", text, res, rdn, found, dn, true, sc)
                    return found, sc
                end
            end
            nRES = nRES + 1
            if nRES > CAP then RES, nRES = {}, 1 end
            RES[text] = r
        end
        return r
    end

    -- M.resolve(text, ctx, e) while compiled
    local function resolve_c(text, ctx, e)
        if REF then return RESOLVE0(text, ctx, e) end
        return resolver(text)(ctx, e)
    end

    -- -----------------------------------------------------------------------------------------
    -- value texts: numbers, yes/no, @variables, @[ inline math ], value:..., modifier:..., variables

    local VT, nVT = {}, 0
    local vt_of
    local function make_vt(t)
        CS.texts = CS.texts + 1
        local n = tonumber(t)
        if n then
            return function() return n end
        end
        if t == "yes" then return function() return 1 end end
        if t == "no" then return function() return 0 end end
        if t:sub(1, 1) == "@" then
            if t:sub(2, 2) == "[" or t:sub(2, 3) == "\\[" then
                return function(ctx, e) return mathexpr(t, ctx, e) end
            end
            -- a scripted variable: its text in the file's variables (ctx.file) or the global ones,
            -- the same for the whole run (the definitions do not change), so one per file
            local name = t:sub(2)
            local by_file = {}
            local NOFILE = by_file
            return function(ctx, e)
                local file = ctx.file
                local key = file == nil and NOFILE or file
                local f = by_file[key]
                if f == nil then
                    local raw = var_raw(name, ctx)
                    f = raw and vt_of(raw) or false
                    by_file[key] = f
                end
                if f then
                    return f(ctx, e)
                end
                miss("value", "@" .. name, ctx, e)
                return 0
            end
        end
        if t:sub(1, 6) == "value:" then
            local spec = t:sub(7)
            return function(ctx, e) return M.script_value(spec, ctx, e) end
        end
        if t:sub(1, 8) == "trigger:" then
            local name = t:sub(9):lower()
            return function(ctx, e)
                local f = M.TRIGGER_VALUES and M.TRIGGER_VALUES[name]
                if f then return f(ctx, e) end
                miss("value", t, ctx, e)
                return 0
            end
        end
        if t:sub(1, 9) == "modifier:" then
            local mod = t:sub(10)
            return function(ctx)
                sync()
                return E.modifier(ctx.this.kind, ctx.this.id, mod)
            end
        end
        -- a variable, possibly behind a scope chain (`owner.my_var`); else a script value of the
        -- name; else 0
        local chain, last = t:match("^(.*)%.([^%.]+)$")
        if chain then
            local R = resolver(chain)
            return function(ctx, e)
                local sc, name = ctx.this, t
                local found, s2
                if M.resolve == resolve_c then
                    found, s2 = R(ctx, e)
                else
                    found, s2 = M.resolve(chain, ctx, e)
                end
                if found then
                    if not s2 then return 0 end
                    sc, name = s2, last
                end
                local v = M.store.getvar(sc, name)
                if v ~= nil then
                    return v
                end
                if db.script_values[t] then
                    return M.script_value(t, ctx, e)
                end
                return 0
            end
        end
        return function(ctx, e)
            local v = M.store.getvar(ctx.this, t)
            if v ~= nil then
                return v
            end
            if db.script_values[t] then
                return M.script_value(t, ctx, e)
            end
            return 0
        end
    end
    -- the value function of a text (numbers are not kept: a caller's tostring(n) would fill it)
    vt_of = function(t)
        local f = VT[t]
        if f ~= nil then return f end
        f = make_vt(t)
        if CHECK then
            local g = f
            f = function(ctx, e)
                local n0 = stats.trigger_evals
                local v = g(ctx, e)
                local dn = stats.trigger_evals - n0
                CK.checks = CK.checks + 1
                local res, rdn = reference(value_text_tree, t, ctx, e)
                compare_ref("text", t, res, rdn, v, dn)
                return v
            end
        end
        if tonumber(t) == nil then
            nVT = nVT + 1
            if nVT > CAP then VT, nVT = {}, 1 end
            VT[t] = f
        end
        return f
    end
    local function value_text_c(t, ctx, e)
        if REF then return value_text_tree(t, ctx, e) end
        local f = VT[t]
        if f == nil then
            if not CHECK then
                local n = tonumber(t)
                if n then return n end
            end
            f = vt_of(t)
        end
        return f(ctx, e)
    end

    -- -----------------------------------------------------------------------------------------
    -- blocks: the caches, and the compiled function of a block

    local compile_trigger_block, compile_value_block, compile_weight -- forward

    local function timed(f, ...)
        local t0 = clock()
        local r = f(...)
        CS.compile_seconds = CS.compile_seconds + (clock() - t0)
        return r
    end

    local function where_of(ctx, b)
        return (ctx and ctx.file or "?") .. ":" .. tostring(b and b.line or "?")
    end

    -- a block or statement that did not compile is walked; the first messages are kept
    CS.errors = {}
    local function fallback(msg)
        CS.fallbacks = CS.fallbacks + 1
        if #CS.errors < 5 then CS.errors[#CS.errors + 1] = tostring(msg) end
    end

    -- trigger blocks, per skip table (nil: TB0)
    local TB0, SEEN0 = setmetatable({}, WEAKK), setmetatable({}, WEAKK)
    local TBS, SEENS = setmetatable({}, WEAKK), setmetatable({}, WEAKK)
    local function tcache(skip)
        if skip == nil then return TB0, SEEN0 end
        local t = TBS[skip]
        if t == nil then
            t = setmetatable({}, WEAKK)
            TBS[skip] = t
            SEENS[skip] = setmetatable({}, WEAKK)
        end
        return t, SEENS[skip]
    end

    -- the compiled function of a trigger block (compiled now if it is not yet): function(ctx) -> the
    -- walker's trigger(b, ctx, skip)
    local function block_fn(b, skip)
        local cache = tcache(skip)
        local f = cache[b]
        if f then return f end
        local ok, g = pcall(compile_trigger_block, b, skip)
        if ok then
            f = g
        else
            fallback(g)
            f = function(ctx) return trigger_tree(b, ctx, skip) end
        end
        if CHECK then
            local g = f
            f = function(ctx)
                local n0 = stats.trigger_evals
                local r = g(ctx)
                local dn = stats.trigger_evals - n0
                CK.checks = CK.checks + 1
                local res, rdn = reference(trigger_tree, b, ctx, skip)
                compare_ref("trigger", where_of(ctx, b), res, rdn, r, dn)
                return r
            end
        end
        cache[b] = f
        return f
    end

    -- the walker's trigger(b, ctx, skip) while compiled
    local function trigger_c(b, ctx, skip)
        if REF then return trigger_tree(b, ctx, skip) end
        local cache, seen = tcache(skip)
        local f = cache[b]
        if f then return f(ctx) end
        local n = (seen[b] or 0) + 1
        if n >= AFTER then
            seen[b] = nil
            f = timed(block_fn, b, skip)
            return f(ctx)
        end
        seen[b] = n
        return trigger_tree(b, ctx, skip)
    end

    -- value blocks (apply_ops), with only_ops false (VB0) or true (VB1)
    local VB0, VSEEN0 = setmetatable({}, WEAKK), setmetatable({}, WEAKK)
    local VB1, VSEEN1 = setmetatable({}, WEAKK), setmetatable({}, WEAKK)
    local function value_fn(b, only_ops)
        local cache = only_ops and VB1 or VB0
        local f = cache[b]
        if f then return f end
        local ok, g = pcall(compile_value_block, b, only_ops)
        if ok then
            f = g
        else
            fallback(g)
            f = function(ctx, acc) return apply_ops_tree(b, ctx, acc, only_ops) end
        end
        if CHECK then
            local g = f
            f = function(ctx, acc)
                local n0 = stats.trigger_evals
                local v = g(ctx, acc)
                local dn = stats.trigger_evals - n0
                CK.checks = CK.checks + 1
                local res, rdn = reference(apply_ops_tree, b, ctx, acc, only_ops)
                compare_ref("value", where_of(ctx, b), res, rdn, v, dn)
                return v
            end
        end
        cache[b] = f
        return f
    end
    local function apply_ops_c(b, ctx, acc, only_ops)
        if REF then return apply_ops_tree(b, ctx, acc, only_ops) end
        local cache, seen = VB0, VSEEN0
        if only_ops then cache, seen = VB1, VSEEN1 end
        local f = cache[b]
        if f then return f(ctx, acc) end
        local n = (seen[b] or 0) + 1
        if n >= AFTER then
            seen[b] = nil
            f = timed(value_fn, b, only_ops)
            return f(ctx, acc)
        end
        seen[b] = n
        return apply_ops_tree(b, ctx, acc, only_ops)
    end

    -- weight blocks (M.weight)
    local WB, WSEEN = setmetatable({}, WEAKK), setmetatable({}, WEAKK)
    local function weight_fn(b)
        local f = WB[b]
        if f then return f end
        local ok, g = pcall(compile_weight, b)
        if ok then
            f = g
        else
            fallback(g)
            f = function(ctx, base) return WEIGHT0(b, ctx, base) end
        end
        if CHECK then
            local g = f
            f = function(ctx, base)
                local n0 = stats.trigger_evals
                local v = g(ctx, base)
                local dn = stats.trigger_evals - n0
                CK.checks = CK.checks + 1
                local res, rdn = reference(WEIGHT0, b, ctx, base)
                compare_ref("weight", where_of(ctx, b), res, rdn, v, dn)
                return v
            end
        end
        WB[b] = f
        return f
    end
    local function weight_c(b, ctx, base)
        if REF then return WEIGHT0(b, ctx, base) end
        local f = WB[b]
        if f then return f(ctx, base) end
        local n = (WSEEN[b] or 0) + 1
        if n >= AFTER then
            WSEEN[b] = nil
            f = timed(weight_fn, b)
            return f(ctx, base)
        end
        WSEEN[b] = n
        return WEIGHT0(b, ctx, base)
    end

    -- -----------------------------------------------------------------------------------------
    -- script values: `value:name|P|v|` (M.script_value)

    local SV, nSV = {}, 0
    local function make_sv(spec)
        CS.script_values = CS.script_values + 1
        local parts = {}
        for p in (spec .. "|"):gmatch("([^|]*)|") do
            parts[#parts + 1] = p
        end
        local name = parts[1]
        local args = {}
        for i = 2, #parts - 1, 2 do
            if parts[i] ~= "" then
                args[#args + 1] = { parts[i], parts[i + 1] or "" }
            end
        end
        local memo_def, block
        return function(ctx, e)
            local def = db.script_values[name]
            if not def then
                miss("value", "value:" .. name, ctx, e)
                return 0
            end
            if def ~= memo_def then
                local b = db.instance("value", def, name, args)
                memo_def, block = def, b
            end
            if not block then
                miss("value", "instantiate " .. name, ctx, e)
                return 0
            end
            return apply_ops_c(block, with_file(ctx, def.file), 0)
        end
    end
    local function script_value_c(spec, ctx, e)
        if REF then return SCRIPT_VALUE0(spec, ctx, e) end
        local f = SV[spec]
        if f == nil then
            f = make_sv(spec)
            if CHECK then
                local g = f
                f = function(ctx2, e2)
                    local n0 = stats.trigger_evals
                    local v = g(ctx2, e2)
                    local dn = stats.trigger_evals - n0
                    CK.checks = CK.checks + 1
                    local res, rdn = reference(SCRIPT_VALUE0, spec, ctx2, e2)
                    compare_ref("script value", spec, res, rdn, v, dn)
                    return v
                end
            end
            nSV = nSV + 1
            if nSV > CAP then SV, nSV = {}, 1 end
            SV[spec] = f
        end
        return f(ctx, e)
    end

    -- -----------------------------------------------------------------------------------------
    -- statements (trigger1)

    local compile_stmt -- forward

    -- a flag's name: `x@root` is x@<the scope's id> (flag_name)
    local function flag_name_fn(text, e)
        local base, ref = text:match("^(.-)@(.+)$")
        if base and not ref:find("^%[") then
            local R = resolver(ref)
            return function(ctx)
                local found, sc = R(ctx, e)
                if found then
                    return base .. "@" .. (sc and sc.id or "none")
                end
                return text
            end
        end
        return function() return text end
    end

    -- the triggers of a block that hold, as holding() counts them: items, each function(ctx) -> the
    -- statement's (or the if chain's) result
    local chain_item
    local function holding_items(b, skip)
        local items = {}
        local i = 1
        while b[i] do
            local x = b[i]
            if x.op and x.key then
                local lk = x.key.text:lower()
                if lk == "if" then
                    local item, j = chain_item(b, i)
                    items[#items + 1] = item
                    i = j
                else
                    -- (an else_if / else not after an if: the game's reader rejects it)
                    if not (skip and skip[lk]) and lk ~= "else_if" and lk ~= "else" then
                        items[#items + 1] = compile_stmt(x)
                    end
                    i = i + 1
                end
            else
                i = i + 1
            end
        end
        return items
    end

    -- an if / else_if / else chain from b[i] (if_chain): function(ctx) -> its result, and the
    -- index after it
    chain_item = function(b, i)
        local els = {}
        while true do
            local x = b[i]
            local lk = x.key.text:lower()
            local el = { is_else = lk == "else" }
            if x.value.text == nil then
                el.body = block_fn(x.value, LIMIT_ONLY)
                local lim
                for _, y in ipairs(x.value) do
                    if y.op and y.key.text:lower() == "limit" then lim = y.value end
                end
                el.lim = lim and block_fn(lim, nil)
            end
            els[#els + 1] = el
            local j = i + 1
            while b[j] and not (b[j].op and b[j].key) do j = j + 1 end
            local nk = b[j] and b[j].key.text:lower()
            if lk == "else" or (nk ~= "else_if" and nk ~= "else") then
                local n = #els
                return function(ctx)
                    for k = 1, n do
                        local el2 = els[k]
                        local body = el2.body
                        if body then
                            local lim2 = el2.lim
                            if el2.is_else or not lim2 or lim2(ctx) then
                                return body(ctx)
                            end
                        end
                    end
                    return true
                end, j
            end
            i = j
        end
    end

    -- eval.lua's own handlers, inlined: function(ctx) -> the handler's result, or nil (call it)
    local function inline_builtin(lk, e)
        local value = e.value
        local vtext = value.text
        if lk == "or" or lk == "not" or lk == "nor" then
            local items = holding_items(value, nil)
            local n = #items
            if lk == "or" then
                return function(ctx)
                    for i = 1, n do
                        if items[i](ctx) then return true end
                    end
                    return false
                end
            end
            return function(ctx)
                for i = 1, n do
                    if items[i](ctx) then return false end
                end
                return true
            end
        elseif lk == "and" or lk == "hidden_trigger" then
            return block_fn(value, nil)
        elseif lk == "nand" then
            local f = block_fn(value, nil)
            return function(ctx) return not f(ctx) end
        elseif lk == "custom_tooltip" or lk == "custom_tooltip_fail" then
            if vtext then return function() return true end end
            return block_fn(value, TOOLTIP_PARAMS)
        elseif lk == "calc_true_if" then
            local amounts = {}
            for _, x in ipairs(value) do
                if x.op and x.key.text:lower() == "amount" then amounts[#amounts + 1] = x end
            end
            local na = #amounts
            local items = holding_items(value, AMOUNT)
            local n = #items
            return function(ctx)
                local amount = 1
                for i = 1, na do
                    local x = amounts[i]
                    amount = M.value(x.value, ctx, x)
                end
                local c = 0
                for i = 1, n do
                    if items[i](ctx) then c = c + 1 end
                end
                return c >= amount
            end
        elseif lk == "always" then
            local r = vtext ~= "no"
            return function() return r end
        elseif lk == "exists" then
            local R = resolver(vtext or "")
            local what = "exists " .. tostring(vtext)
            return function(ctx)
                local found, sc = R(ctx, e)
                local r = found and sc ~= nil and sc ~= NONE
                if not found then miss("scope link", what, ctx, e) end
                return r
            end
        elseif lk == "has_global_flag" then
            if vtext == nil then return nil end
            local name = flag_name_fn(vtext, e)
            return function(ctx) return M.store.has_flag(nil, name(ctx)) end
        elseif lk == "has_modifier" then
            local m = vtext or ""
            return function(ctx)
                sync()
                local t = ctx.this
                return E.has_modifier(t.kind, t.id, m)
            end
        end
        return nil
    end

    -- a property trigger (property_trigger): function(ctx)
    local function property_fn(e, lk)
        local v = e.value.text
        if PROP_SET[lk] then
            local set = lk
            if lk == "has_building" then set = "building" elseif lk == "has_edict" then set = "edict" end
            return function(ctx)
                local sc = ctx.this
                if sc == NONE then return false end
                sync()
                return E.has(sc.kind, sc.id, set, v)
            end
        end
        if v == "yes" or v == "no" then
            local want = v == "yes"
            return function(ctx)
                local sc = ctx.this
                if sc == NONE then return false end
                sync()
                local have = E.get(sc.kind, sc.id, lk)
                return (have == "yes" or have == true) == want
            end
        end
        return function(ctx)
            local sc = ctx.this
            if sc == NONE then return false end
            sync()
            local have = E.get(sc.kind, sc.id, lk)
            return have ~= nil and tostring(have) == v
        end
    end

    -- after the scripted triggers: a flag, a property, or nothing known: function(ctx), and whether
    -- it reads M.property (the walker's property check is reached)
    local function compile_after_scripted(e, key, lk)
        local vtext = e.value.text
        local fk = lk:match("^has_(.+)_flag$")
        if fk == "policy" then fk = nil end   -- has_policy_flag: the country's policies, not a script flag
        if fk and vtext then
            local name = flag_name_fn(vtext, e)
            if fk == "global" then
                return function(ctx) return M.store.has_flag(nil, name(ctx)) end, false
            end
            return function(ctx) return M.store.has_flag(ctx.this, name(ctx)) end, false
        end
        if PROPERTY0(lk) and vtext then
            return property_fn(e, lk), true
        end
        if lk:sub(1, 1) == "@" or lk:find("^%$") then
            local what = "unresolved " .. key:sub(1, 1)
            return function(ctx)
                miss("trigger", what, ctx, e)
                return false
            end, true
        end
        return function(ctx)
            miss("trigger", lk, ctx, e)
            return false
        end, true
    end

    -- a scripted trigger, its definition def: function(ctx, def)
    local YES = { value = { text = "yes" } }
    local function compile_scripted(e, key)
        local vtext = e.value.text
        local count_form = vtext and vtext ~= "yes" and vtext ~= "no"
        local neg = vtext == "no"
        local memo_def, only, only_lk, body, sub
        local function prepare(def)
            local o, olk = nil, nil
            if count_form then
                local by = scripted_call(def, key, YES, "trigger")
                for _, x in ipairs(by or {}) do
                    if x.op then
                        if o then o = false break end
                        o = x
                    end
                end
                olk = o and o.key.text:lower()
            end
            local b = scripted_call(def, key, e, "trigger")
            only, only_lk, body, sub = o, olk, b, nil
            memo_def = def
        end
        return function(ctx, def)
            if def ~= memo_def then prepare(def) end
            if only then
                -- `pop_amount > 10`: a scripted trigger whose body is one count iterator
                local n = M.count_value(only_lk, only.value, with_file(ctx, def.file))
                if n then
                    return compare(n, e.op, M.value(e.value, ctx, e))
                end
            end
            if not body then
                miss("trigger", "instantiate " .. key, ctx, e)
                return false
            end
            local f = sub
            if f == nil then
                f = block_fn(body, nil)
                sub = f
            end
            local r = f(with_file(ctx, def.file))
            if neg then r = not r end
            return r
        end
    end

    -- an iterator any_<list> / count_<list>: function(ctx)
    local function compile_iterator(e, lk, it, lname)
        local value = e.value
        if it == "any" then
            local sub = block_fn(value, ITER_PARAMS)
            return function(ctx)
                local list = list_of(lname, value, ctx, e)
                if list then
                    for _, s2 in ipairs(list) do
                        if sub(push(ctx, s2)) then return true end
                    end
                    return false
                end
                miss("iterator", lk, ctx, e)
                return false
            end
        end
        local counts, all = {}, {}
        for _, x in ipairs(value) do
            if x.op and x.key.text:lower() == "count" then
                counts[#counts + 1] = x
                all[#counts] = x.value.text == "all"
            end
        end
        local nc = #counts
        return function(ctx)
            local list = list_of(lname, value, ctx, e)
            if list then
                local op, want = ">=", 1
                for i = 1, nc do
                    local x = counts[i]
                    op = x.op
                    want = all[i] and -1 or M.value(x.value, ctx, x)
                end
                local n, total = M.count_items(lname, list, value, ctx)
                if want == -1 then return n == total end
                return compare(n, op, want)
            end
            miss("iterator", lk, ctx, e)
            return false
        end
    end

    -- the scope branch of a statement whose keyword is a scope reference (`owner = { ... }`,
    -- `owner = root`): function(ctx)
    local function compile_found(e, key)
        local value = e.value
        local vtext = value.text
        local R = make_resolver(key)
        if vtext then
            local RV = resolver(vtext)
            return function(ctx) -- `owner = root`: the same scope
                local _, sc = R(ctx, e)
                local f2, other = RV(ctx, e)
                return f2 and sc ~= nil and sc == other
            end
        end
        local sub -- (compiled when first reached: most keywords are no link)
        return function(ctx)
            local _, sc = R(ctx, e)
            if not sc then return false end
            local f = sub
            if f == nil then
                f = block_fn(value, nil)
                sub = f
            end
            return f(push(ctx, sc))
        end
    end

    -- one statement: function(ctx) -> trigger1(e, ctx). After TRIG (trigger1_rest): the scope
    -- reference (M.resolve: found when its first part is a link at call time, or a saved target or
    -- last_created_), else an iterator, else a scripted trigger (db's definition at call time), a
    -- flag, a property, nothing known
    local function compile_stmt_raw(e)
        CS.statements = CS.statements + 1
        local key = e.key.text
        local lk = key:lower()
        local vtext = e.value.text
        local builtin = B[lk]
        local inl = builtin and inline_builtin(lk, e)
        local parts = chain_parts(key)
        local first = parts[1]
        local always_found = first ~= nil and first.kind ~= 3 -- a saved target or last_created_
        local lp1 = first and first.kind == 3 and first.lp or nil -- found when LINKS has it
        local it, lname = lk:match("^(any)_(.+)$")
        if not it then it, lname = lk:match("^(count)_(.+)$") end
        local is_iter = not always_found and it and vtext == nil
        -- whether the walker's property check is reached (a property, or nothing known)
        local reads_property = false
        if not always_found and not is_iter then
            local fk = lk:match("^has_(.+)_flag$")
            if fk == "policy" then fk = nil end
            reads_property = not (fk and vtext)
        end
        -- the branches after TRIG, compiled when first reached (most statements only ever take one;
        -- a branch that does not compile is the walker's trigger1_rest)
        local found_f, iter_f, scripted_f, after_f
        local function walk_rest(ctx) return trigger1_rest(e, ctx, key, lk) end
        local function build(f, ...)
            local t0 = clock()
            local ok, g = pcall(f, ...)
            CS.compile_seconds = CS.compile_seconds + (clock() - t0)
            if ok then return g end
            fallback(g)
            return walk_rest
        end
        local function found(ctx)
            local f = found_f
            if f == nil then
                f = build(compile_found, e, key)
                found_f = f
            end
            return f(ctx)
        end
        local function scripted(ctx, def)
            local f = scripted_f
            if f == nil then
                f = build(compile_scripted, e, key)
                scripted_f = f
            end
            return f(ctx, def)
        end
        local function after(ctx)
            local f = after_f
            if f == nil then
                f = build(compile_after_scripted, e, key, lk)
                after_f = f
            end
            return f(ctx)
        end
        local function rest(ctx)
            if always_found or (lp1 and LINKS[lp1]) then return found(ctx) end
            if is_iter then
                local f = iter_f
                if f == nil then
                    f = build(compile_iterator, e, lk, it, lname)
                    iter_f = f
                end
                return f(ctx)
            end
            local def = db.scripted_triggers[key]
            if def then return scripted(ctx, def) end
            return after(ctx)
        end
        if inl then
            return function(ctx)
                if M.resolve ~= resolve_c or (reads_property and M.property ~= PROPERTY0) then
                    return trigger1(e, ctx)
                end
                stats.trigger_evals = stats.trigger_evals + 1
                local h = TRIG[lk]
                if h == builtin then return inl(ctx) end
                if h then return h(e, ctx, lk) end
                return rest(ctx)
            end
        end
        -- the common shape in one closure: a keyword of one part, not an iterator (a property, a
        -- flag, a scripted trigger, a link, a handler of a module)
        if lp1 and #parts == 1 and not is_iter then
            return function(ctx)
                if M.resolve ~= resolve_c or (reads_property and M.property ~= PROPERTY0) then
                    return trigger1(e, ctx)
                end
                stats.trigger_evals = stats.trigger_evals + 1
                local h = TRIG[lk]
                if h then return h(e, ctx, lk) end
                if LINKS[lp1] then return found(ctx) end
                local def = db.scripted_triggers[key]
                if def then return scripted(ctx, def) end
                local f = after_f
                if f == nil then return after(ctx) end
                return f(ctx)
            end
        end
        return function(ctx)
            if M.resolve ~= resolve_c or (reads_property and M.property ~= PROPERTY0) then
                return trigger1(e, ctx)
            end
            stats.trigger_evals = stats.trigger_evals + 1
            local h = TRIG[lk]
            if h then return h(e, ctx, lk) end
            return rest(ctx)
        end
    end
    compile_stmt = function(e)
        local ok, f = pcall(compile_stmt_raw, e)
        if ok then return f end
        fallback(f)
        return function(ctx) return trigger1(e, ctx) end
    end

    -- -----------------------------------------------------------------------------------------
    -- a trigger block (trigger_tree): AND of its statements, keys in skip left out, if / else_if /
    -- else chained by `taken`

    local function and_of(fs)
        local n = #fs
        if n == 0 then return function() return true end end
        if n == 1 then
            local a = fs[1]
            return function(ctx)
                if not a(ctx) then return false end
                return true
            end
        end
        if n == 2 then
            local a, b = fs[1], fs[2]
            return function(ctx)
                if not a(ctx) then return false end
                if not b(ctx) then return false end
                return true
            end
        end
        if n == 3 then
            local a, b, c = fs[1], fs[2], fs[3]
            return function(ctx)
                if not a(ctx) then return false end
                if not b(ctx) then return false end
                if not c(ctx) then return false end
                return true
            end
        end
        return function(ctx)
            for i = 1, n do
                if not fs[i](ctx) then return false end
            end
            return true
        end
    end

    compile_trigger_block = function(b, skip)
        CS.trigger_blocks = CS.trigger_blocks + 1
        local fs, kinds, chained = {}, {}, false
        for _, e in ipairs(b) do
            if e.op and e.key then
                local lk = e.key.text:lower()
                if not (skip and skip[lk]) then
                    if lk == "if" or lk == "else_if" or lk == "else" then
                        chained = true
                        -- kind 1: an if (taken reset), 2: else_if, 3: else; the body only for a block
                        local el = { kind = lk == "if" and 1 or (lk == "else_if" and 2 or 3) }
                        if e.value.text == nil then
                            local lim
                            for _, x in ipairs(e.value) do
                                if x.op and x.key.text:lower() == "limit" then lim = x.value end
                            end
                            el.lim = lim and block_fn(lim, nil)
                            el.body = block_fn(e.value, LIMIT_ONLY)
                        end
                        fs[#fs + 1] = el
                        kinds[#fs] = true
                    else
                        fs[#fs + 1] = compile_stmt(e)
                        kinds[#fs] = false
                    end
                end
            end
        end
        if not chained then
            return and_of(fs)
        end
        local n = #fs
        return function(ctx)
            local taken = false
            for i = 1, n do
                local f = fs[i]
                if kinds[i] then
                    local kind = f.kind
                    if kind == 1 then taken = false end
                    local body = f.body
                    if not taken and body then
                        local lim = f.lim
                        if kind == 3 or not lim or lim(ctx) then
                            taken = true
                            if not body(ctx) then return false end
                        end
                    end
                elseif not f(ctx) then
                    return false
                end
            end
            return true
        end
    end

    -- -----------------------------------------------------------------------------------------
    -- a value block (apply_ops_tree): its operations on acc, in order

    compile_value_block = function(b, only_ops)
        CS.value_blocks = CS.value_blocks + 1
        local ops, chain = {}, {} -- chain[i]: 1 an if element, 2 an else_if / else, nil an operation
        for _, e in ipairs(b) do
            if e.op and e.key and not (only_ops and not VALUE_OPS[e.key.text:lower()]) then
                local k = e.key.text:lower()
                local v = e.value
                local op
                if k == "base" or k == "value" or k == "set" then
                    op = function(ctx) return M.value(v, ctx, e) end
                elseif k == "add" then
                    op = function(ctx, acc) return acc + M.value(v, ctx, e) end
                elseif k == "subtract" then
                    op = function(ctx, acc) return acc - M.value(v, ctx, e) end
                elseif k == "mult" or k == "multiply" or k == "factor" then
                    op = function(ctx, acc) return acc * M.value(v, ctx, e) end
                elseif k == "divide" then
                    op = function(ctx, acc)
                        local d = M.value(v, ctx, e)
                        if d ~= 0 then acc = acc / d end
                        return acc
                    end
                elseif k == "modulo" then
                    op = function(ctx, acc)
                        local d = M.value(v, ctx, e)
                        if d ~= 0 then acc = acc % d end
                        return acc
                    end
                elseif k == "min" then
                    op = function(ctx, acc) return max(acc, M.value(v, ctx, e)) end
                elseif k == "max" then
                    op = function(ctx, acc) return min(acc, M.value(v, ctx, e)) end
                elseif k == "abs" then
                    op = function(_, acc) return abs(acc) end
                elseif k == "round" then
                    op = function(_, acc) return floor(acc + 0.5) end
                elseif k == "floor" then
                    op = function(_, acc) return floor(acc) end
                elseif k == "ceiling" then
                    op = function(_, acc) return ceil(acc) end
                elseif k == "modifier" and v.text == nil then
                    local cond = block_fn(v, VALUE_OPS)
                    local body = value_fn(v, true)
                    op = function(ctx, acc)
                        if cond(ctx) then return body(ctx, acc) end
                        return acc
                    end
                elseif k == "if" or k == "else_if" or k == "else" then
                    local body, lim
                    if v.text == nil then
                        local l
                        for _, x in ipairs(v) do
                            if x.op and x.key.text:lower() == "limit" then l = x.value end
                        end
                        lim = l and block_fn(l, nil)
                        body = value_fn(v, nil)
                    end
                    local is_else = k == "else"
                    -- -> acc, whether taken
                    op = function(ctx, acc)
                        if body and (is_else or not lim or lim(ctx)) then
                            return body(ctx, acc), true
                        end
                        return acc, false
                    end
                    chain[#ops + 1] = k == "if" and 1 or 2
                elseif k == "limit" or k == "weight" or k == "desc" or k == "display_name" then
                    -- handled by the caller or not a value operation
                else
                    -- `count_owned_pop_amount = { limit = { ... } }`: the iterator's count; a scope
                    local block = v.text == nil
                    local sub = block and value_fn(v, nil)
                    local key = e.key.text
                    op = function(ctx, acc)
                        local n = block and M.count_value and M.count_value(k, v, ctx)
                        if n then return n end
                        local found, sc = M.resolve(key, ctx, e)
                        if found and block then
                            if sc then return sub(push(ctx, sc), acc) end
                            return acc
                        end
                        miss("value op", k, ctx, e)
                        return acc
                    end
                end
                if op then ops[#ops + 1] = op end
            end
        end
        local n = #ops
        if next(chain) == nil then
            return function(ctx, acc)
                for i = 1, n do
                    acc = ops[i](ctx, acc)
                end
                return acc
            end
        end
        return function(ctx, acc)
            local taken = false
            for i = 1, n do
                local c = chain[i]
                if c == nil then
                    acc = ops[i](ctx, acc)
                else
                    if c == 1 then taken = false end
                    if not taken then
                        local t
                        acc, t = ops[i](ctx, acc)
                        if t then taken = true end
                    end
                end
            end
            return acc
        end
    end

    -- -----------------------------------------------------------------------------------------
    -- a weight block (M.weight)

    compile_weight = function(b)
        CS.weights = CS.weights + 1
        local ops = {}
        for _, e in ipairs(b) do
            if e.op and e.key then
                local k = e.key.text:lower()
                local v = e.value
                local op
                if k == "base" or k == "factor" or k == "weight" or k == "days" then
                    op = function(ctx) return M.value(v, ctx, e) end
                elseif k == "months" then
                    op = function(ctx) return M.value(v, ctx, e) * 30 end
                elseif k == "years" then
                    op = function(ctx) return M.value(v, ctx, e) * 360 end
                elseif k == "add" then
                    op = function(ctx, acc) return acc + M.value(v, ctx, e) end
                elseif k == "multiply" or k == "mult" then
                    op = function(ctx, acc) return acc * M.value(v, ctx, e) end
                elseif k == "modifier" and v.text == nil then
                    local cond = block_fn(v, VALUE_OPS)
                    local xs, kinds = {}, {}
                    for _, x in ipairs(v) do
                        if x.op then
                            local xk = x.key.text:lower()
                            local kind
                            if xk == "factor" or xk == "multiply" or xk == "mult" then kind = 1
                            elseif xk == "add" then kind = 2
                            elseif xk == "subtract" then kind = 3 end
                            if kind then
                                xs[#xs + 1] = x
                                kinds[#xs] = kind
                            end
                        end
                    end
                    local nx = #xs
                    op = function(ctx, acc)
                        if cond(ctx) then
                            for i = 1, nx do
                                local x = xs[i]
                                local kind = kinds[i]
                                if kind == 1 then acc = acc * M.value(x.value, ctx, x)
                                elseif kind == 2 then acc = acc + M.value(x.value, ctx, x)
                                else acc = acc - M.value(x.value, ctx, x) end
                            end
                        end
                        return acc
                    end
                elseif k == "complex_trigger_modifier" or k == "opinion_modifier" or k == "modifier" then
                    op = function(ctx, acc)
                        miss("weight op", k, ctx, e)
                        return acc
                    end
                end
                if op then ops[#ops + 1] = op end
            end
        end
        local n = #ops
        return function(ctx, base)
            local acc = base or 1
            for i = 1, n do
                acc = ops[i](ctx, acc)
            end
            return acc
        end
    end

    -- -----------------------------------------------------------------------------------------
    -- installed: the walker calls these, and so do the modules (eval.trigger, eval.resolve, ...)

    I.set("trigger", trigger_c)
    I.set("apply_ops", apply_ops_c)
    I.set("value_text", value_text_c)
    M.trigger = trigger_c
    M.value_text = value_text_c
    M.resolve = resolve_c
    M.script_value = script_value_c
    M.weight = weight_c
    M.compiler = C

    -- the report line (simscript/host.lua)
    function C.report()
        local s = string.format("script compiler: %d trigger blocks, %d statements, %d value blocks, %d weights, %d value texts, %d scope chains, %d script values compiled in %.2f s (%d left to the walker%s)",
            CS.trigger_blocks, CS.statements, CS.value_blocks, CS.weights, CS.texts, CS.chains, CS.script_values,
            CS.compile_seconds, CS.fallbacks, #CS.errors > 0 and (": " .. table.concat(CS.errors, "; ")) or "")
        if CHECK then
            local list = {}
            for _, m in pairs(CK.where) do list[#list + 1] = m end
            table.sort(list, function(a, b2)
                if a.count ~= b2.count then return a.count > b2.count end
                return a.kind .. a.where < b2.kind .. b2.where
            end)
            s = s .. string.format("\nscript compiler check: %d evaluations compared with the walker, %d mismatches in %d places",
                CK.checks, CK.mismatches, #list)
            for i = 1, math.min(30, #list) do
                local m = list[i]
                s = s .. string.format("\n  %-14s %7d  %s  (%s)", m.kind, m.count, m.where, tostring(m.detail))
            end
        end
        return s
    end
end

return C
