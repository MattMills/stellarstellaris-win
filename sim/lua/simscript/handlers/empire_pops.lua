-- simscript/handlers/empire_pops.lua : the empire's pop group effects: sizes, ethics and the ethos
-- (pop groups and countries), pop factions. Loaded by handlers/empire.lua with its helpers (H).
-- docs/script_empire.md has each one's class; the Linux 4.5.2 addresses are in the comments.
--
-- Fixed point is the game's: int64 raw values, 1.0 = 100000, products and quotients truncated.
-- The scope random (eval.scope_rng, engine.script.scope_random) is the effect scope's CCrudeRandom;
-- a "global draw" is one CRandom::GetIntegerForMacro (eval.rand).

return function(eval, H)
    local S, NONE, world = H.S, H.NONE, H.world
    local I = H.I
    local EFF = eval.EFF
    local unq, obj, field, num, def, dfield = H.unq, H.obj, H.field, H.num, H.def, H.dfield
    local params, text_of, target = H.params, H.text_of, H.target
    local stats = I.stats
    local floor = math.floor
    local bit = require("bit")
    local SR = require("engine.script.scope_random")
    local noise32 = require("engine.newgame.rng").noise32
    local FP = 100000
    local TWO32 = 4294967296

    local function pops() return require("engine.pops") end
    local function ethics() return require("engine.ethics") end
    local function events() return require("simscript.events") end
    local function wrote() stats.script = stats.script + 1 end
    local function trunc(x) return x < 0 and -floor(-x) or floor(x) end
    -- a script number as raw fixed point (the parser's: nearest)
    local function raw(v)
        v = tonumber(v) or 0
        return v < 0 and -floor(-v * FP + 0.5) or floor(v * FP + 0.5)
    end
    local function value(p, ctx) return p and eval.value(p.value, ctx, p) or nil end
    local function put(o, key, block)
        local en = world.entry(o, key)
        if block == nil then
            if en then world.remove_entry(o, en) end
            return
        end
        if en then world.set_entry(o, en, block)
        else world.append_entry(o, { key = { text = key }, op = "=", value = block }) end
    end
    local function define(group, key, default)
        for _, d in pairs(require("engine.defs").folder("common/defines")) do
            local g = dfield(d.block, group)
            local v = g and dfield(g, key)
            if v ~= nil then return tonumber(v) or v end
        end
        return default
    end

    -- ------------------------------------------------------------------------------------------
    -- the scope random's draws

    -- CCrudeRandom::GetInteger(lo, hi) (0x422b100): lo + n % (hi - lo + 1), n of one noise x:
    -- (x & 0x7FFFFFFE) ^ (x >> 8); it draws when lo == hi too [V]
    local function scope_int(ctx, lo, hi)
        local r = eval.scope_rng(ctx)
        local x = noise32(r.pos, r.seed)
        r.pos = (r.pos + 1) % TWO32
        local n = bit.bxor(bit.band(x, 0x7FFFFFFE), bit.rshift(x, 8))
        if n < 0 then n = n + TWO32 end
        return lo + n % (hi - lo + 1)
    end
    -- CCrudeRandom::GetFixedPoint(lo, hi) (0x4235d00) on raw values: GetInt64 % (hi - lo + 1), two
    -- positions [V]
    local function scope_fixed(ctx, lo, hi)
        if lo > hi then lo, hi = hi, lo end
        return lo + SR.int64_mod(eval.scope_rng(ctx), hi - lo + 1)
    end

    -- NScriptUtil::SAmountOrPercent::GetValue (0x1f28440) [V]: `amount` (a bare value too) drawn in
    -- [v - random, v + random]; `percentage` drawn the same way, then times the base; neither: 0 and
    -- no draw. The draw is made with random 0 too. Raw fixed point.
    local function aop_value(e, ctx, base)
        if e.value.text then
            return scope_fixed(ctx, raw(eval.value(e.value, ctx, e)), raw(eval.value(e.value, ctx, e)))
        end
        local p = params(e)
        local r = p.random and raw(value(p.random, ctx)) or 0
        if p.amount then
            local v = raw(value(p.amount, ctx))
            return scope_fixed(ctx, v - r, v + r)
        elseif p.percentage then
            local pc = raw(value(p.percentage, ctx))
            pc = scope_fixed(ctx, pc - r, pc + r)
            return trunc(base * pc)
        end
        return 0
    end
    -- GetClampedValue(base, 0, base) (0x1f285b0) as a pop count
    local function aop_count(e, ctx, size)
        local v = aop_value(e, ctx, size)
        return trunc(math.max(0, math.min(v, size * FP)) / FP)
    end

    -- ------------------------------------------------------------------------------------------
    -- pop group sizes

    local function G(ctx)
        if ctx.this.kind ~= "pop_group" and ctx.this.kind ~= "pop" then return nil end
        return H.group(ctx.this.id)
    end
    -- CColony::RemovePopGroup and the killed flag (+0x188 bit 0, `killed = yes`) of an emptied group:
    -- out of its colony's pop_groups, the last one moved into its place [I order, as pops.move_size]
    local function kill_if_empty(gid)
        local g = H.group(gid)
        if not g or num(field(g, "size")) > 0 or field(g, "killed") == "yes" then return end
        local cid = H.group_colony(gid)
        local c = cid and obj("colony", cid)
        local list = c and field(c, "pop_groups")
        if type(list) == "table" then
            local last, at
            for i, en in ipairs(list) do
                if en.text ~= nil then
                    last = i
                    if tonumber(en.text) == gid and not at then at = i end
                end
            end
            if at then
                if at ~= last then world.set_text(list, at, list[last].text) end
                world.remove_at(list, last)
            end
        end
        world.set(g, "killed", "yes")
    end
    -- CPopGroup::AddSize (0x1e6cc50) [V]: clamped to the size; the ethos resized; the growth detail
    -- on the group and its colony (engine.pops keeps them); an emptied group killed
    local function add_size(gid, n, cat)
        local d = pops().add_size(gid, H.group_colony(gid), n, cat)
        if d ~= 0 then kill_if_empty(gid) end
        return d
    end
    H.add_pop_size = add_size

    -- add_pop_amount / remove_pop_amount = <int> | { amount random growth_category }
    -- (CAddPopAmountEffect 0x3811a70, CRemovePopAmountEffect 0x3811c40) [V]: one scope draw in
    -- [max(v - random, 0), v + random], made with random 0 too; AddSize of it (category default
    -- GROWTH_CAT_OTHER)
    local function int_effect(e, ctx)
        if e.value.text then return trunc(eval.value(e.value, ctx, e) or 0), 0, "GROWTH_CAT_OTHER" end
        local p = params(e)
        local v = p.amount and trunc(value(p.amount, ctx) or 0) or 0
        local r = p.random and trunc(value(p.random, ctx) or 0) or 0
        return v, r, unq(text_of(p.growth_category)) or "GROWTH_CAT_OTHER"
    end
    local function pop_amount(sign)
        return function(e, ctx)
            local g = G(ctx)
            if not g then return end
            local v, r, cat = int_effect(e, ctx)
            local lo, hi = math.max(v - r, 0), v + r
            if hi < lo then return end
            local n = scope_int(ctx, lo, hi)
            if n ~= 0 and add_size(ctx.this.id, sign * n, cat) ~= 0 then wrote() end
        end
    end
    EFF["add_pop_amount"] = pop_amount(1)
    EFF["remove_pop_amount"] = pop_amount(-1)
    -- scale_pop_amount = <factor> (CScalePopAmountEffect 0x3811d90) [V]: trunc(size x factor), the
    -- difference AddSize'd as GROWTH_CAT_OTHER; no draw
    EFF["scale_pop_amount"] = function(e, ctx)
        local g = G(ctx)
        if not g then return end
        local size = num(field(g, "size"))
        local new = trunc(size * raw(eval.value(e.value, ctx, e)) / FP)
        if new ~= size and add_size(ctx.this.id, new - size, "GROWTH_CAT_OTHER") ~= 0 then wrote() end
    end
    -- transfer_pop_amount = { source target amount|percentage random growth_category }
    -- (CTransferPopAmountEffect 0x38122a0) [V]: both pop groups and not the same, then the count
    -- (two scope positions; a percentage of the source's size), CPopGroup::MoveSizeFrom
    EFF["transfer_pop_amount"] = function(e, ctx)
        if e.value.text then return end
        local p = params(e)
        local src, dst = target(p.source, ctx), target(p.target, ctx)
        if not src or not dst or src.kind ~= "pop_group" or dst.kind ~= "pop_group" or src.id == dst.id then return end
        if not H.group(src.id) or not H.group(dst.id) then return end
        local n = aop_count(e, ctx, H.group_size(src.id))
        if n <= 0 then return end
        local moved = pops().move_size(dst.id, src.id, n, unq(text_of(p.growth_category)) or "GROWTH_CAT_OTHER",
            H.group_colony(src.id))
        if (moved or 0) > 0 then wrote() end
    end
    -- displace_pop_amount = { amount|percentage random } (CDisplacePopAmountEffect 0x3814820) [V]:
    -- the count (two scope positions), the size unchanged; one global draw s seeds the scopes:
    -- root the group's planet, from its owner, fromfrom the group, which gets the variable
    -- local_pop_amount; on_pop_displaced fired (its script moves the pops)
    EFF["displace_pop_amount"] = function(e, ctx)
        local g = G(ctx)
        if not g then return end
        local gid = ctx.this.id
        local n = aop_count(e, ctx, num(field(g, "size")))
        local s = eval.rand()
        local pid = H.group_planet(gid)
        local owner = H.group_owner(gid)
        eval.setvar(S("pop_group", gid), "local_pop_amount", n)
        local from_ctx = eval.new_ctx(owner and S("country", owner) or NONE, S("pop_group", gid))
        local ok = pcall(events().on_action, "on_pop_displaced", pid and S("planet", pid) or NONE, from_ctx, SR.new(s))
        if not ok then I.miss("effect", "on_pop_displaced", ctx, e) end
        wrote()
    end

    -- kill_assigned_pop_amount / sacrifice_assigned_pop_amount = { limit amount|percentage
    -- growth_category } (KillAssignedPopAmountInternal 0x381ac00) [V]: a pop job's workers
    -- (`pop_groups = { { pop_group amount } }`, in order). `random` is read and not used, no scope
    -- draw; one global draw seeds the limit's scope (from = the job); the caller's this is set to
    -- each group tested and stays on the last. A percentage takes trunc(amount x p) of each entry;
    -- an amount takes from the entries in turn until it is used up. Each: AddSize(-k), the entry's
    -- amount less k. Sacrifice: per group with k > 0, three global draws and on_pop_sacrificed
    -- (root the group, from its planet, fromfrom the owner; CColony::OnPopsSacrificed 0x2869220)
    local function kill_assigned(sacrifice)
        return function(e, ctx)
            if (ctx.this.kind ~= "pop_job" and ctx.this.kind ~= "job") or e.value.text then return end
            local job = obj("pop_jobs", ctx.this.id)
            if not job then return end
            local p = params(e)
            local pct = p.percentage ~= nil
            local v = math.max(0, raw(value(pct and p.percentage or p.amount, ctx) or 0))
            local cat = unq(text_of(p.growth_category)) or "GROWTH_CAT_OTHER"
            local lctx = eval.seed_scope(eval.new_ctx(NONE, ctx.this), eval.rand())
            local left = trunc(v / FP)
            local changed = false
            for _, en in ipairs(world.blocks(field(job, "pop_groups"))) do
                if not pct and left <= 0 then break end
                local gid = tonumber(field(en, "pop_group"))
                local g = gid and H.group(gid)
                if g then
                    ctx.this = S("pop_group", gid)
                    lctx.this, lctx.root = ctx.this, ctx.this
                    if not p.limit or eval.trigger(p.limit.value, lctx) then
                        local amt, size = num(field(en, "amount")), num(field(g, "size"))
                        local k
                        if pct then
                            k = math.min(trunc(amt * v / FP), size)
                        else
                            k = math.min(amt, left, size)
                            left = left - k
                        end
                        if k > 0 then
                            add_size(gid, -k, cat)
                            world.set(en, "amount", amt - k)
                            changed = true
                            if sacrifice then
                                local s1 = eval.rand()
                                eval.rand()
                                eval.rand()
                                local pid, owner = H.group_planet(gid), H.group_owner(gid)
                                local fctx = eval.new_ctx(pid and S("planet", pid) or NONE, owner and S("country", owner) or NONE)
                                pcall(events().on_action, "on_pop_sacrificed", S("pop_group", gid), fctx, SR.new(s1))
                            end
                        end
                    end
                end
            end
            if changed then wrote() end
        end
    end
    EFF["kill_assigned_pop_amount"] = kill_assigned(false)
    EFF["sacrifice_assigned_pop_amount"] = kill_assigned(true)

    -- ------------------------------------------------------------------------------------------
    -- a pop group's stats (CBasePopGroupStat: the ethos' ethics, the factions): { name, pops } lists

    local function db_index(name)
        local en = ethics().db().by_name[name]
        return en and en.index or 1e9
    end
    -- Sort: more pops first, a tie by `order` (the ethics' database order, a faction's id)
    local function sort_stat(st, order)
        table.sort(st, function(a, b)
            if a.pops ~= b.pops then return a.pops > b.pops end
            return order(a.name) < order(b.name)
        end)
    end
    local function stat_total(st, skip)
        local t = 0
        for i, x in ipairs(st) do if i ~= skip then t = t + x.pops end end
        return t
    end
    local function find(st, name)
        for i, x in ipairs(st) do if x.name == name then return i end end
        return nil
    end
    local function replace(st, new)
        for i = #st, 1, -1 do st[i] = nil end
        for i, x in ipairs(new) do st[i] = x end
    end
    -- Resize(size, skip) (0x1e76c40) [V]: size <= 0 empties it; else the entries but `skip` scaled
    -- to `size` (engine.ethics.resize: largest remainders), then sorted, the empty ones dropped
    local function resize_skip(st, size, skip, order)
        if size <= 0 then replace(st, {}) return end
        local others, keep = {}, nil
        for i, x in ipairs(st) do
            if i == skip then keep = x else others[#others + 1] = x end
        end
        ethics().resize(others, size)
        if keep then others[#others + 1] = keep end
        replace(st, others)
        sort_stat(st, order)
        for i = #st, 1, -1 do if st[i].pops <= 0 then table.remove(st, i) end end
    end
    -- ConvertPops(n, E) (0x1e76910) [V]: E gains n pops, the others shrink in proportion; when they
    -- have no more than n, E takes every pop. A new E must be valid
    local function convert(st, n, name, valid, order)
        if n <= 0 or #st == 0 then return false end
        local i = find(st, name)
        if not i then
            if not valid(name) then return false end
            st[#st + 1] = { name = name, pops = 0 }
            i = #st
        end
        local total = stat_total(st)
        local others = total - st[i].pops
        if others - n > 0 then
            st[i].pops = st[i].pops + n
            sort_stat(st, order)
            resize_skip(st, others - n, find(st, name), order)
        else
            replace(st, { { name = name, pops = total } })
        end
        return true
    end
    -- DeconvertPops(n, E) (0x1e773f0) [V]: E loses min(n, its pops), the others grow by them in
    -- proportion; nothing with fewer than two entries
    local function deconvert(st, n, name, order)
        if n <= 0 or #st < 2 then return false end
        local i = find(st, name)
        if not i then return false end
        local k = math.min(n, st[i].pops)
        local others = stat_total(st, i)
        st[i].pops = st[i].pops - k
        resize_skip(st, others + k, i, order)
        return true
    end
    -- TransferPops(n, A, B) (0x1e775c0) [V]: min(n, A's pops) from A to B (B appended when new and
    -- valid); A dropped when it had no more than n; sorted
    local function transfer(st, n, a, b, valid, order)
        if n <= 0 or a == b or #st < 2 then return false end
        local ia = find(st, a)
        if not ia then return false end
        local k = math.min(n, st[ia].pops)
        local ib = find(st, b)
        if not ib then
            if not valid(b) then return false end
            st[#st + 1] = { name = b, pops = 0 }
            ib = #st
        end
        st[ib].pops = st[ib].pops + k
        if st[ia].pops > n then st[ia].pops = st[ia].pops - k else table.remove(st, ia) end
        sort_stat(st, order)
        return true
    end

    -- the group's ethos (`ethos = { ethics = { } pops = { } }`; both left out when empty, CEthos::
    -- WriteMembers 0x252cfe0)
    local function read_ethos(g)
        local st = {}
        local ethos = field(g, "ethos")
        if type(ethos) ~= "table" then return st end
        local counts = world.list(field(ethos, "pops"))
        for i, n in ipairs(world.list(field(ethos, "ethics"))) do
            st[#st + 1] = { name = unq(n), pops = floor(tonumber(counts[i]) or 0) }
        end
        return st
    end
    local function write_ethos(g, st)
        local ethos = world.child(g, "ethos")
        local nb, cb = {}, {}
        for _, x in ipairs(st) do
            if x.pops > 0 then
                nb[#nb + 1] = { text = x.name, quoted = true }
                cb[#cb + 1] = { text = tostring(x.pops) }
            end
        end
        put(ethos, "ethics", #nb > 0 and nb or nil)
        put(ethos, "pops", #cb > 0 and cb or nil)
    end
    -- CPopGroupEthos::IsElementValid: an ethic with use_for_pops (not a fanatic one)
    local function pop_ethic_valid(name)
        local en = ethics().db().by_name[name]
        return en ~= nil and en.use_for_pops
    end
    -- the CPopGroup wrappers (ConvertToEthic 0x1e72710, AbandonEthic 0x1e727d0, TransferEthic
    -- 0x1e72860) [V]: nothing for a killed or empty group; n at most the size
    local function group_op(gid, n, f)
        local g = H.group(gid)
        if not g or field(g, "killed") == "yes" then return false end
        local size = num(field(g, "size"))
        if size <= 0 then return false end
        if n > size then n = size end
        local st = read_ethos(g)
        if not f(st, n) then return false end
        write_ethos(g, st)
        return true
    end

    local function is_sapient(sid)
        local s = sid and H.species(sid)
        return s ~= nil and field(s, "sapient") ~= "no"
    end
    -- a game rule with this, root and from
    local function rule(name, this, root, from)
        local b, file = def("common/game_rules", name)
        if type(b) ~= "table" then return true end
        local c = eval.new_ctx(this, from, nil, file)
        c.root = root
        return eval.trigger(b, c) == true
    end
    -- CPopGroup::CalcHasRandomEthics (0x1e6b1a0): a sapient species with happiness, and the rule
    -- pop_group_has_random_ethics (this the species, root the group, from the owner)
    local function has_random_ethics(gid)
        local sid, owner = H.group_species(gid), H.group_owner(gid)
        if not is_sapient(sid) or not H.species_has_happiness(sid, owner) then return false end
        return rule("pop_group_has_random_ethics", S("species", sid), S("pop_group", gid),
            owner and S("country", owner) or NONE)
    end
    local function ethic_param(p, key, ctx)
        local v = p[key]
        if not v then return nil end
        if v.value.text then
            local t = unq(v.value.text)
            if def("common/ethics", t) then return t end
        end
        local sc = target(v, ctx)
        return sc and sc.kind == "ethic" and sc.id or nil
    end

    -- pop_change_ethic / pop_force_add_ethic = { ethic amount|percentage random }
    -- (CAddEthicEffect<false> 0x3816000, <true> 0x3815ac0) [V]: change: nothing without random
    -- ethics (no draw); the count (clamped, two scope positions); a non-sapient group: nothing more;
    -- ConvertToEthic
    local function add_ethic(force)
        return function(e, ctx)
            local g = G(ctx)
            if not g or e.value.text then return end
            local gid = ctx.this.id
            if not force and not has_random_ethics(gid) then return end
            local p = params(e)
            local n = aop_count(e, ctx, num(field(g, "size")))
            if not is_sapient(H.group_species(gid)) then return end
            local E = ethic_param(p, "ethic", ctx)
            if not E then return end
            if group_op(gid, n, function(st, k) return convert(st, k, E, pop_ethic_valid, db_index) end) then wrote() end
        end
    end
    EFF["pop_change_ethic"] = add_ethic(false)
    EFF["pop_force_add_ethic"] = add_ethic(true)
    -- pop_remove_ethic = { ethic amount|percentage random } (CRemoveEthicEffect 0x3811640) [V]: the
    -- count (clamped, drawn), AbandonEthic
    EFF["pop_remove_ethic"] = function(e, ctx)
        local g = G(ctx)
        if not g or e.value.text then return end
        local n = aop_count(e, ctx, num(field(g, "size")))
        local E = ethic_param(params(e), "ethic", ctx)
        if E and group_op(ctx.this.id, n, function(st, k) return deconvert(st, k, E, db_index) end) then wrote() end
    end
    -- pop_force_remove_ethic (CPopForceRemoveEthicEffect 0x3814d40) [V]: the count not clamped (drawn),
    -- at most the ethic's pops, AbandonEthic
    EFF["pop_force_remove_ethic"] = function(e, ctx)
        local g = G(ctx)
        if not g or e.value.text then return end
        local n = trunc(aop_value(e, ctx, num(field(g, "size"))) / FP)
        local E = ethic_param(params(e), "ethic", ctx)
        if not E then return end
        local i = find(read_ethos(g), E)
        n = math.min(n, i and read_ethos(g)[i].pops or 0)
        if group_op(ctx.this.id, n, function(st, k) return deconvert(st, k, E, db_index) end) then wrote() end
    end
    -- pop_force_transfer_ethic = { old_ethic new_ethic amount|percentage random }
    -- (CPopForceTransferEthicEffect 0x38152d0) [V]: the count not clamped, at most old's pops,
    -- TransferEthic (a fanatic new ethic not taken)
    EFF["pop_force_transfer_ethic"] = function(e, ctx)
        local g = G(ctx)
        if not g or e.value.text then return end
        local p = params(e)
        local n = trunc(aop_value(e, ctx, num(field(g, "size"))) / FP)
        local A, B = ethic_param(p, "old_ethic", ctx), ethic_param(p, "new_ethic", ctx)
        if not A or not B then return end
        local i = find(read_ethos(g), A)
        n = math.min(n, i and read_ethos(g)[i].pops or 0)
        if group_op(ctx.this.id, n, function(st, k) return transfer(st, k, A, B, pop_ethic_valid, db_index) end) then
            wrote()
        end
    end

    -- ------------------------------------------------------------------------------------------
    -- a country's ethos

    local function C(ctx) return ctx.this.kind == "country" and obj("country", ctx.this.id) or nil end
    local function ethic_def(name) return name and def("common/ethics", name) or nil end
    local function ethic_cat(name) local b = ethic_def(name) return b and unq(dfield(b, "category")) or nil end
    local function ethic_cost(name) local b = ethic_def(name) return b and tonumber(dfield(b, "cost")) or 0 end
    local function ethic_cv(name) local b = ethic_def(name) return b and tonumber(dfield(b, "category_value")) or 0 end
    local function fanatic_of(name) local b = ethic_def(name) return b and unq(dfield(b, "fanatic_variant")) or nil end
    local function regular_of(name) local b = ethic_def(name) return b and unq(dfield(b, "regular_variant")) or name end
    local function country_list(c)
        local out = {}
        for _, v in ipairs(world.list(world.path(c, "ethos", "ethics"))) do out[#out + 1] = unq(v) end
        return out
    end
    local function write_country(c, list)
        local b = {}
        for _, n in ipairs(list) do b[#b + 1] = { text = n, quoted = true } end
        put(world.child(c, "ethos"), "ethics", #b > 0 and b or nil)
    end
    -- CCountry::OnEthosChanged (0x2376220) [V]: the government's type (AssignMatchingType) and the
    -- species rights' validation [I: not modelled here], the modifiers, then one global draw for
    -- CalculatePersonality (`personality`; the pick itself is not modelled)
    local function on_ethos_changed(cid)
        eval.rand()
        H.ethos_changed = (H.ethos_changed or 0) + 1
        return cid
    end
    -- CCountryEthos::AddEthic (0x252f5c0) [V]: not a duplicate; the first held ethic of the same
    -- category out; inserted after the held ones before it in the database; no points check
    local function country_add(list, E)
        if not ethic_def(E) then return false end
        for _, x in ipairs(list) do if x == E then return false end end
        local cat = ethic_cat(E)
        for i, x in ipairs(list) do
            if ethic_cat(x) == cat then table.remove(list, i) break end
        end
        local at = #list + 1
        for i, x in ipairs(list) do
            if db_index(x) > db_index(E) then at = i break end
        end
        table.insert(list, at, E)
        return true
    end
    local function country_remove(list, E)
        for i, x in ipairs(list) do
            if x == E then table.remove(list, i) return true end
        end
        return false
    end
    local function points(list)
        local s = 0
        for _, x in ipairs(list) do s = s + ethic_cost(x) end
        return s
    end
    -- the ethics in the database's order
    local function ethic_names()
        local out = {}
        for _, en in ipairs(ethics().db()) do out[#out + 1] = en.name end
        return out
    end
    -- GetWeightedRandom(n, w, rnd) [V]: rnd % the total of the weights over 0 (raw), the first whose
    -- running sum is above it
    local function weighted(cands, ws, rnd)
        local total = 0
        for _, w in ipairs(ws) do if w > 0 then total = total + w end end
        if total <= 0 then return nil end
        local r = rnd % total
        local run = 0
        for i, w in ipairs(ws) do
            if w > 0 then
                run = run + w
                if run > r then return cands[i] end
            end
        end
        return nil
    end

    -- country_add_ethic = <ethic> | random (CAddCountryEthicEffect 0x37490e0) [V]: random:
    -- ChooseRandomEthic (0x25302f0): the ethics of a category not held whose cost fits in
    -- ETHOS_MAX_POINTS less the held ones', weight random_weight + 1 (those over 0), one global
    -- draw; AddEthic; changed: OnEthosChanged
    EFF["country_add_ethic"] = function(e, ctx)
        local c = C(ctx)
        if not c or not e.value.text then return end
        local list = country_list(c)
        local E = unq(e.value.text)
        if E == "random" then
            local held, left = {}, define("NGameplay", "ETHOS_MAX_POINTS", 3) - points(list)
            for _, x in ipairs(list) do held[ethic_cat(x) or ""] = true end
            local cands, ws = {}, {}
            for _, name in ipairs(ethic_names()) do
                local b, file = def("common/ethics", name)
                if b and not held[ethic_cat(name) or ""] and ethic_cost(name) <= left then
                    local rw = dfield(b, "random_weight")
                    local w = type(rw) == "table" and eval.weight(rw, eval.new_ctx(ctx.this, nil, nil, file)) or 0
                    if w > 0 then
                        cands[#cands + 1] = name
                        ws[#ws + 1] = raw(w + 1)
                    end
                end
            end
            E = weighted(cands, ws, eval.rand())
            if not E then return end
        end
        if not country_add(list, E) then return end
        write_country(c, list)
        on_ethos_changed(ctx.this.id)
        wrote()
    end
    -- country_remove_ethic = <ethic> (CRemoveCountryEthicEffect 0x3749840) [V]: held: out and
    -- OnEthosChanged; else nothing
    EFF["country_remove_ethic"] = function(e, ctx)
        local c = C(ctx)
        if not c or not e.value.text then return end
        local list = country_list(c)
        if not country_remove(list, unq(e.value.text)) then return end
        write_country(c, list)
        on_ethos_changed(ctx.this.id)
        wrote()
    end
    -- clear_ethos (CClearEthosEffect 0x371fc30) [V]: a pop group's ethos emptied; a country's, then
    -- OnEthosChanged
    EFF["clear_ethos"] = function(e, ctx)
        if e.value.text == "no" then return end
        local g = G(ctx)
        if g then
            write_ethos(g, {})
            wrote()
            return
        end
        local c = C(ctx)
        if not c then return end
        write_country(c, {})
        on_ethos_changed(ctx.this.id)
        wrote()
    end

    -- CEthic::CalcCountryPopsAttraction (0x252f250) [I: the country's pops of the ethic, as raw
    -- fixed point; the game weighs its pop groups with random ethics]
    local function pops_attraction(cid, name)
        local n = 0
        for _, gid in ipairs(H.pop_groups(S("country", cid))) do
            for _, x in ipairs(read_ethos(H.group(gid))) do
                if x.name == name then n = n + x.pops end
            end
        end
        return n * FP
    end
    -- the side of an ethic on its axis (CEthic +0x118: category_value 0, 1 one side; 3, 4 the other)
    local function side(name) return ethic_cv(name) < 2 end
    -- shift_ethic = <ethic> (CShiftEthicEffect 0x371fe60 → CCountryEthos::ShiftTowardsEthic 0x252e610)
    -- [V]: the first held ethic of E's category: on E's side, made fanatic (already fanatic: only
    -- OnEthosChanged); on the other side, replaced by E; none: E added. Then RemoveOrDowngradeEthics
    -- (0x252e910) until the points are ETHOS_MAX_POINTS (at most 10000 passes): over the points, the
    -- held ethic of another category with the least score (a regular one its pops' attraction, a
    -- fanatic one its regular's / 10) out (a fanatic one back to regular); under, the most scored
    -- one not held (a free category: a regular ethic, its attraction; a held one: a fanatic one,
    -- its regular's x 10) in. A score s = x 100, k = trunc(s): k >= 5 adds (global draw % (k / 5)).
    -- Then OnEthosChanged
    EFF["shift_ethic"] = function(e, ctx)
        local c = C(ctx)
        if not c or not e.value.text then return end
        local E = unq(e.value.text)
        if not ethic_def(E) then return end
        local cid = ctx.this.id
        local list = country_list(c)
        local cat = ethic_cat(E)
        local X
        for _, x in ipairs(list) do if ethic_cat(x) == cat then X = x break end end
        local done = false
        if X and side(X) == side(E) then
            local f = fanatic_of(X)
            if f then
                country_remove(list, X)
                country_add(list, f)
            else
                done = true
            end
        elseif X then
            country_remove(list, X)
            country_add(list, E)
        else
            country_add(list, E)
        end
        if not done then
            local MAX = define("NGameplay", "ETHOS_MAX_POINTS", 3)
            local names = ethic_names()
            for _ = 1, 10000 do
                local sum = points(list)
                if sum == MAX or #list == 0 then break end
                local held, held_cat = {}, {}
                for _, x in ipairs(list) do held[x] = true held_cat[ethic_cat(x) or ""] = true end
                local best, best_s
                for _, D in ipairs(names) do
                    local dc = ethic_cat(D)
                    if dc ~= cat then
                        local fan = fanatic_of(D) == nil and regular_of(D) ~= D
                        local score
                        if sum > MAX then
                            if held[D] then
                                score = fan and trunc(pops_attraction(cid, regular_of(D)) / 10) or pops_attraction(cid, D)
                            end
                        elseif not held[D] then
                            if held_cat[dc or ""] then
                                if fan then score = pops_attraction(cid, regular_of(D)) * 10 end
                            elseif not fan then
                                score = pops_attraction(cid, D)
                            end
                        end
                        if score then
                            local s = score * 100
                            local k = trunc(s / FP)
                            if k >= 5 then s = s + (eval.rand() % trunc(k / 5)) * FP end
                            if best == nil or (sum > MAX and s < best_s) or (sum < MAX and s > best_s) then
                                best, best_s = D, s
                            end
                        end
                    end
                end
                if best then
                    local fan = fanatic_of(best) == nil and regular_of(best) ~= best
                    if sum > MAX then
                        country_remove(list, best)
                        if fan then country_add(list, regular_of(best)) end
                    elseif fan then
                        country_remove(list, regular_of(best))
                        country_add(list, best)
                    else
                        country_add(list, best)
                    end
                end
            end
        end
        write_country(c, list)
        on_ethos_changed(cid)
        wrote()
    end

    -- ------------------------------------------------------------------------------------------
    -- pop factions

    -- the group's factions (`factions = { objects = { } pops = { } }`; the unaffiliated pops, the
    -- null faction -1, are the rest of the size)
    local function read_factions(g)
        local st = {}
        local b = field(g, "factions")
        if type(b) ~= "table" then return st end
        local counts = world.list(field(b, "pops"))
        for i, id in ipairs(world.list(field(b, "objects"))) do
            st[#st + 1] = { name = tonumber(id), pops = floor(tonumber(counts[i]) or 0) }
        end
        return st
    end
    local function write_factions(g, st)
        local b = world.child(g, "factions")
        local ob, cb = {}, {}
        for _, x in ipairs(st) do
            if x.name ~= -1 and x.pops > 0 then
                ob[#ob + 1] = { text = tostring(x.name) }
                cb[#cb + 1] = { text = tostring(x.pops) }
            end
        end
        put(b, "objects", #ob > 0 and ob or nil)
        put(b, "pops", #cb > 0 and cb or nil)
    end
    local function faction_order(id) return id end
    -- set_pop_faction = { faction ratio } (CSetPopFactionEffect 0x375c150) [V]: a group that can join
    -- factions (sapient, rule pop_group_can_join_factions: this the group, root the owner); n =
    -- round(size x ratio in [0, 1]); CPopGroup::ConvertToFaction (0x1e70260): a faction type with
    -- ethics takes at most the group's pops of them less those already in it; ConvertPops with the
    -- unaffiliated pops as the null faction
    EFF["set_pop_faction"] = function(e, ctx)
        local g = G(ctx)
        if not g or e.value.text then return end
        local gid = ctx.this.id
        local p = params(e)
        local f = target(p.faction, ctx)
        local fo = f and f.kind == "pop_faction" and obj("pop_factions", f.id)
        if not fo then return end
        local owner = H.group_owner(gid)
        if not is_sapient(H.group_species(gid))
            or not rule("pop_group_can_join_factions", S("pop_group", gid), owner and S("country", owner) or NONE, NONE) then
            return
        end
        if field(g, "killed") == "yes" then return end
        local size = num(field(g, "size"))
        if size <= 0 then return end
        local ratio = math.max(0, math.min(FP, raw(value(p.ratio, ctx) or 0)))
        local n = floor(size * ratio / FP + 0.5)
        local st = read_factions(g)
        local fb = def("common/pop_faction_types", unq(field(fo, "type")))
        local guiding = fb and unq(dfield(fb, "guiding_ethic"))
        if guiding then
            -- the type's ethics [I: the guiding ethic and its fanatic variant]
            local set = { [guiding] = true }
            local fv = fanatic_of(guiding)
            if fv then set[fv] = true end
            local avail = 0
            for _, x in ipairs(read_ethos(g)) do if set[x.name] then avail = avail + x.pops end end
            local i = find(st, f.id)
            avail = avail - (i and st[i].pops or 0)
            if avail <= 0 then return end
            n = math.min(n, avail)
        end
        local null = size - stat_total(st)
        if null > 0 then st[#st + 1] = { name = -1, pops = null } end
        sort_stat(st, faction_order)
        if not convert(st, n, f.id, function() return true end, faction_order) then return end
        write_factions(g, st)
        wrote()
    end
    -- force_faction_evaluation (CForceFactionEvaluationEffect 0x375c940) [V]: the group's _Properties
    -- bit 2: the next day's faction check forced (engine.ethics.force_faction); not in the save
    EFF["force_faction_evaluation"] = function(e, ctx)
        if e.value.text == "no" then return end
        if not G(ctx) then return end
        ethics().force_faction[ctx.this.id] = true
        wrote()
    end
    -- enable_faction_of_type = <type> (CEnableFactionTypeEffect 0x375ca90 →
    -- CPopFactionsCountryModule::EvaluatePotentialFactionsOfType 0x1e9be90) [V]: the type's
    -- is_potential holds, the country type has a government, none of the type queued, a unique one
    -- not existing: `potential = { type }` appended to standard_pop_factions_module (the monthly
    -- faction pass makes it) [I: the potential members' count not checked]
    EFF["enable_faction_of_type"] = function(e, ctx)
        local c = C(ctx)
        if not c or not e.value.text then return end
        local t = unq(e.value.text)
        local b, file = def("common/pop_faction_types", t)
        if not b then return end
        local ct = def("common/country_types", unq(field(c, "type")))
        if ct and dfield(ct, "government") == "no" then return end
        local pot = dfield(b, "is_potential")
        if type(pot) == "table" and not eval.trigger(pot, eval.new_ctx(ctx.this, nil, nil, file)) then return end
        local mods = field(c, "modules")
        local m = type(mods) == "table" and field(mods, "standard_pop_factions_module")
        if type(m) ~= "table" then return end
        for _, x in ipairs(world.fields(m, "potential")) do
            if type(x) == "table" and unq(field(x, "type")) == t then return end
        end
        if dfield(b, "unique") == "yes" then
            for _, fid in ipairs(world.all("pop_factions")) do
                local f = obj("pop_factions", fid)
                if f and tonumber(field(f, "country")) == ctx.this.id and unq(field(f, "type")) == t then return end
            end
        end
        local pb = {}
        world.append(pb, "type", t, true)
        world.append_entry(m, { key = { text = "potential" }, op = "=", value = pb })
        wrote()
    end
    -- set_faction_extorted = yes|no (CSetFactionExtortedEffect 0x3811880) [V]: unchanged: nothing;
    -- yes: the first other extorted faction of the owner cleared; `extorted = yes` (written only when
    -- set)
    EFF["set_faction_extorted"] = function(e, ctx)
        if ctx.this.kind ~= "pop_faction" or not e.value.text then return end
        local f = obj("pop_factions", ctx.this.id)
        if not f then return end
        local v = e.value.text == "yes"
        if (field(f, "extorted") == "yes") == v then return end
        if v then
            local owner = tonumber(field(f, "country"))
            for _, fid in ipairs(world.all("pop_factions")) do
                local o = obj("pop_factions", fid)
                if o and fid ~= ctx.this.id and tonumber(field(o, "country")) == owner and field(o, "extorted") == "yes" then
                    put(o, "extorted", nil)
                    break
                end
            end
            world.set(f, "extorted", "yes")
        else
            put(f, "extorted", nil)
        end
        wrote()
    end

    -- the country's instance properties (`faction = { properties = <int> }`, CCountry +0x1ab8) and
    -- their bits (PropertiesReadMember 0x258d5b0) [V]
    local PROP_BITS = {
        hostile = 0, hostile_when_attacked = 1, neutral = 2, copy_hostility = 3, auto_delete = 4,
        needs_border_access = 5, generate_borders = 6, needs_colony = 7, primitive = 8,
        can_have_revolts = 9, space_creatures = 10, intel_effects_surveyed = 11,
    }
    local function props(c) return floor(num(world.path(c, "faction", "properties"))) end
    local function set_props(c, v)
        world.set(world.child(c, "faction"), "properties", v)
    end
    -- set_faction_properties = { <property> = yes|no ... } (CSetCountryBitMask ExecuteActual
    -- 0x37ee450) [V]: (props | set) & ~clear
    EFF["set_faction_properties"] = function(e, ctx)
        local c = C(ctx)
        if not c or e.value.text then return end
        local set, clear = 0, 0
        for _, x in ipairs(e.value) do
            local b = x.op and x.key and PROP_BITS[x.key.text]
            if b then
                if x.value.text == "yes" then set = bit.bor(set, bit.lshift(1, b))
                else clear = bit.bor(clear, bit.lshift(1, b)) end
            end
        end
        local v = bit.band(bit.bor(props(c), set), bit.bnot(clear))
        if v ~= props(c) then set_props(c, v) wrote() end
    end
    -- the relation of a country with another (relations_manager's `relation = { owner country }`)
    local function relation(cid, other)
        local c = obj("country", cid)
        local rm = c and world.child(c, "relations_manager")
        if not rm then return nil end
        for _, r in ipairs(world.fields(rm, "relation")) do
            if type(r) == "table" and tonumber(field(r, "country")) == other then return r end
        end
        local r = {}
        world.append(r, "owner", cid)
        world.append(r, "country", other)
        world.append_entry(rm, { key = { text = "relation" }, op = "=", value = r })
        return r
    end
    -- set_faction_hostility = { set_hostile set_neutral set_friendly target } (CSetFactionHostilityEffect
    -- 0x373bfe0) [V]: no target: hostile, neutral and copy_hostility cleared, then hostile and neutral
    -- as given (set_friendly not read); a target: both countries' relations with the other get
    -- hostile / neutral / friendly [I: the communications the game opens first not modelled]
    EFF["set_faction_hostility"] = function(e, ctx)
        local c = C(ctx)
        if not c or e.value.text then return end
        local p = params(e)
        local function flag(k) return p[k] and p[k].value.text == "yes" or false end
        local h, n, f = flag("set_hostile"), flag("set_neutral"), flag("set_friendly")
        if not p.target then
            local v = bit.band(props(c), bit.bnot(0x0d))
            if h then v = bit.bor(v, 1) end
            if n then v = bit.bor(v, 4) end
            set_props(c, v)
            wrote()
            return
        end
        local t = target(p.target, ctx)
        if not t or t.kind ~= "country" or not obj("country", t.id) then return end
        for _, pair in ipairs({ { ctx.this.id, t.id }, { t.id, ctx.this.id } }) do
            local r = relation(pair[1], pair[2])
            if r then
                for k, on in pairs({ hostile = h, neutral = n, friendly = f }) do
                    if on then world.set(r, k, "yes") else put(r, k, nil) end
                end
            end
        end
        wrote()
    end

    -- owned_leader_list_tooltip / owned_pop_faction_list_tooltip (CListTooltipEffect, ExecuteActual a
    -- bare ret) and refresh_portraits (the portraits' GUI flags) [V]: no game state
    local function nothing() end
    EFF["owned_leader_list_tooltip"] = nothing
    EFF["owned_pop_faction_list_tooltip"] = nothing
    EFF["refresh_portraits"] = nothing

    H.on_ethos_changed = on_ethos_changed
    H.country_ethic_add, H.country_ethic_list, H.write_country_ethics = country_add, country_list, write_country
    H.weighted, H.raw, H.define = weighted, raw, define
end
