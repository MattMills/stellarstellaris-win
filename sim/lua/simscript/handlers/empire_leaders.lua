-- simscript/handlers/empire_leaders.lua : the empire's leader effects (age, skill, traits, flags,
-- the recruitment pool, exiled and saved leaders, clones). Loaded by handlers/empire.lua with its
-- helpers (H). docs/script_empire.md has each one's class; the Linux 4.5.2 addresses are in the
-- comments. A leader's save layout is CLeader::WriteMembers' (0x1d037e0).

return function(eval, H)
    local S, NONE, world, E = H.S, H.NONE, H.world, H.E
    local I = H.I
    local EFF = eval.EFF
    local unq, obj, field, num, def, dfield = H.unq, H.obj, H.field, H.num, H.def, H.dfield
    local params, text_of, target, tokens, set_of = H.params, H.text_of, H.target, H.tokens, H.set_of
    local stats = I.stats
    local floor = math.floor
    local SR = require("engine.script.scope_random")
    local bit = require("bit")
    local NO_ID = 4294967295

    local function wrote() stats.script = stats.script + 1 end
    local function trunc(x) return x < 0 and -floor(-x) or floor(x) end
    local function quoted(v) return '"' .. tostring(v) .. '"' end
    local function int_value(e, ctx)
        local v = eval.value(e.value, ctx, e)
        return v and trunc(v) or nil
    end
    local function date_text(days)
        local y = floor(days / 360)
        local r = days - y * 360
        return string.format("%d.%02d.%02d", y, floor(r / 30) + 1, r % 30 + 1)
    end
    local function today() return H.now_days() end
    local function define(group, key, default) return H.define and H.define(group, key, default) or default end
    local function L(ctx) return ctx.this.kind == "leader" and H.leader(ctx.this.id) or nil end
    local function remove_key(o, key)
        local en = world.entry(o, key)
        if en then world.remove_entry(o, en) return true end
        return false
    end
    local function set_block(o, key, block)
        local en = world.entry(o, key)
        if en then world.set_entry(o, en, block)
        else world.append_entry(o, { key = { text = key }, op = "=", value = block }) end
    end
    local function copy_node(x)
        if type(x) ~= "table" then return x end
        local out = {}
        for k, v in pairs(x) do out[k] = copy_node(v) end
        return out
    end
    -- an on_action fired by the engine: the fire site seeds two event scopes, two global draws [V];
    -- this and from as given
    local function fire(name, this, from)
        local s = eval.rand()
        eval.rand()
        local ok = pcall(require("simscript.events").on_action, name, this, from and eval.new_ctx(from) or nil, SR.new(s))
        return ok
    end
    local function owner_of(l) local c = tonumber(field(l, "country")) return c ~= NO_ID and c or nil end

    -- ------------------------------------------------------------------------------------------
    -- age

    -- CLeader's age: (today + age x 360 - (date + days_frozen)) / 360, `age` only when >= 0 [V]
    local function current_age(l)
        local d = H.days_of(field(l, "date")) or today()
        local a = tonumber(field(l, "age")) or -1
        return trunc((today() + (a >= 0 and a * 360 or 0) - (d + num(field(l, "days_frozen")))) / 360)
    end
    local function write_age(l, years)
        world.set(l, "date", quoted(date_text(today() - years * 360)))
        world.set(l, "age", 0)
        remove_key(l, "days_frozen")
    end
    -- add_age = <int> (CAddLeaderAgeEffect 0x375b970 → CLeader::AddAge 0x1d133c0) [V]: the age
    -- max(1, now + n): `date` that many years back, age 0, days_frozen 0
    EFF["add_age"] = function(e, ctx)
        local l = L(ctx)
        if not l then return end
        write_age(l, math.max(1, current_age(l) + (int_value(e, ctx) or 0)))
        wrote()
    end
    -- set_age = <int> (CSetLeaderAgeEffect 0x375b770 → CLeader::SetAge 0x1d13360) [V]: not clamped
    EFF["set_age"] = function(e, ctx)
        local l = L(ctx)
        if not l then return end
        write_age(l, int_value(e, ctx) or 0)
        wrote()
    end

    -- ------------------------------------------------------------------------------------------
    -- skill

    -- the skill cap: min(LEADER_BASE_SKILL_CAP, LEADER_MAX_SKILL_CAP) [I: the leader's and class's
    -- skill cap modifiers not added]
    local function skill_cap()
        return math.min(define("NGameplay", "LEADER_BASE_SKILL_CAP", 10), define("NGameplay", "LEADER_MAX_SKILL_CAP", 10))
    end
    -- CLeader::LevelSkill(n) (0x1d07370) [V]: nothing when the clamped target is the level; else n
    -- LevelUps (the raw n; n <= 0: none), each below the cap a level and on_leader_level_up (this
    -- the owner, from the leader); the experience restored after. [I: the trait picks a level-up
    -- rolls (AssignTraitPicks) not drawn]
    local function level_skill(l, lid, n)
        local level = num(field(l, "level"))
        local cap = skill_cap()
        local tgt = math.max(define("NGameplay", "LEADER_SKILL_MIN", 1), math.min(level + n, cap))
        if tgt == level then return false end
        local changed = false
        for _ = 1, n do
            if level >= cap then break end
            level = level + 1
            world.set(l, "level", level)
            changed = true
            local owner = owner_of(l)
            fire("on_leader_level_up", owner and S("country", owner) or NONE, S("leader", lid))
        end
        return changed
    end
    -- add_skill / add_skill_without_trait_selection = <int> (CAddSkill 0x3714db0,
    -- CAddSkillWithoutTraitSelection 0x37154a0) [V]: LevelSkill
    EFF["add_skill"] = function(e, ctx)
        local l = L(ctx)
        if l and level_skill(l, ctx.this.id, int_value(e, ctx) or 0) then wrote() end
    end
    EFF["add_skill_without_trait_selection"] = EFF["add_skill"]
    -- set_skill = <int> (CSetSkill 0x3716230 → CLeader::SetSkillLevel 0x1d0c990) [V]: the level
    -- clamped to [LEADER_SKILL_MIN, LEADER_MAX_SKILL_CAP]; nothing else
    EFF["set_skill"] = function(e, ctx)
        local l = L(ctx)
        if not l then return end
        local v = math.max(define("NGameplay", "LEADER_SKILL_MIN", 1),
            math.min(int_value(e, ctx) or 1, define("NGameplay", "LEADER_MAX_SKILL_CAP", 10)))
        world.set(l, "level", v)
        wrote()
    end

    -- ------------------------------------------------------------------------------------------
    -- traits

    local function trait_def(t)
        if not t then return nil end
        return def("common/traits", t)
    end
    local function trait_type(t)
        local b = trait_def(t)
        return b and unq(dfield(b, "leader_trait_type")) or "basic"
    end
    local trait_index
    local function index_of(t)
        if not trait_index then
            trait_index = {}
            for i, x in ipairs(H.ordered("common/traits")) do trait_index[x.name] = i end
        end
        return trait_index[t] or 1e9
    end
    -- CTrait::TraitSorter (0x20f50f0) [V order; I: the sort priority and "special" fields not read]:
    -- subclass traits first, then cost 0, then the higher cost, then the database's order
    local function before(a, b)
        local sa, sb = trait_type(a) == "subclass", trait_type(b) == "subclass"
        if sa ~= sb then return sa end
        local ca = tonumber(dfield(trait_def(a) or {}, "cost")) or 0
        local cb = tonumber(dfield(trait_def(b) or {}, "cost")) or 0
        if (ca == 0) ~= (cb == 0) then return ca == 0 end
        if ca ~= cb then return ca > cb end
        return index_of(a) < index_of(b)
    end
    local function traits_of(l) return H.leader_traits(l) end
    -- the trait inserted at its upper bound among the `traits` statements
    local function insert_trait(l, t)
        local pos, last
        for i, x in ipairs(l) do
            if x.op and x.key and x.key.text == "traits" then
                last = i
                if not pos and before(t, unq(x.value.text)) then pos = i end
            end
        end
        if pos then
            world.insert(l, pos, "traits", t, true)
        elseif last then
            world.insert(l, last + 1, "traits", t, true)
        else
            local _, lv = world.entry(l, "level")
            if lv then world.insert(l, lv, "traits", t, true) else world.append(l, "traits", t, true) end
        end
    end
    -- CLeader::RemoveTrait (0x1d1b6e0): every equal entry out (timed_trait kept)
    local function remove_trait(l, t)
        local n = 0
        for i = #l, 1, -1 do
            local x = l[i]
            if x.op and x.key and x.key.text == "traits" and unq(x.value.text) == t then
                world.remove_entry(l, x)
                n = n + 1
            end
        end
        return n > 0
    end
    -- CLeader::AddTrait (0x1d16960) [V]: it must not be had already (IsForceAddLeaderTraitPossible
    -- [I: only that check]); the traits it replaces (replace_traits) out; inserted sorted;
    -- consume_selection: one available selection less (none: the pending picks dropped); its
    -- on_gained_effect run in the leader's scope, seeded by one global draw
    local function add_trait(l, lid, t, consume)
        local b, file = trait_def(t)
        if not b then return false end
        if set_of(traits_of(l))[t] then return false end
        for _, r in ipairs(tokens(dfield(b, "replace_traits"))) do remove_trait(l, unq(r)) end
        insert_trait(l, t)
        if consume then
            local n = num(field(l, "available_trait_selections"))
            if n > 0 then
                if n - 1 > 0 then world.set(l, "available_trait_selections", n - 1) else remove_key(l, "available_trait_selections") end
            else
                while remove_key(l, "available_trait") do end
            end
        end
        local og = dfield(b, "on_gained_effect")
        if type(og) == "table" then
            local c2 = eval.seed_scope(eval.new_ctx(S("leader", lid), nil, nil, file), eval.rand())
            eval.effect(og, c2)
        end
        return true
    end
    H.add_leader_trait = add_trait
    -- CLeader::AddRandomTrait (0x1d16420) [V]: the class's traits in database order of the type
    -- (random_common: basic; random_negative: negative), `randomized` not no, none of its opposites
    -- had, all it replaces had, not had, leader_potential_add holding (this the leader, from the
    -- owner), a weight over 0 (selectable_weight [I: the game's MTTH factor]); one global draw
    local function random_trait(l, lid, ttype)
        local class = unq(field(l, "class"))
        local have = set_of(traits_of(l))
        local owner = owner_of(l)
        local cands, ws = {}, {}
        for _, x in ipairs(H.ordered("common/traits")) do
            local b, file = x.def.block, x.def.file
            local lc = dfield(b, "leader_class")
            local classes = type(lc) == "table" and set_of(tokens(lc)) or (lc and { [unq(lc)] = true }) or nil
            if classes and (classes[class] or classes.all) and (unq(dfield(b, "leader_trait_type")) or "basic") == ttype
                and dfield(b, "randomized") ~= "no" and not have[x.name] then
                local ok = true
                for _, o in ipairs(tokens(dfield(b, "opposites"))) do if have[unq(o)] then ok = false end end
                for _, r in ipairs(tokens(dfield(b, "replace_traits"))) do if not have[unq(r)] then ok = false end end
                local pot = dfield(b, "leader_potential_add")
                if ok and type(pot) == "table" then
                    ok = eval.trigger(pot, eval.new_ctx(S("leader", lid), owner and S("country", owner) or NONE, nil, file)) == true
                end
                if ok then
                    local sw = dfield(b, "selectable_weight")
                    local w = type(sw) == "table" and eval.weight(sw, eval.new_ctx(S("leader", lid), owner and S("country", owner) or NONE, nil, file), 100)
                        or tonumber(sw) or 100
                    if w > 0 then
                        cands[#cands + 1] = x.name
                        ws[#ws + 1] = H.raw(w)
                    end
                end
            end
        end
        if #cands == 0 then return nil end
        return H.weighted(cands, ws, eval.rand())
    end
    -- add_trait = <trait>|random_common|random_negative | { trait consume_selection show_message }
    -- (CAddTraitEffect 0x3756630) [V]
    EFF["add_trait"] = function(e, ctx)
        local l = L(ctx)
        if not l then return end
        local p = e.value.text == nil and params(e) or {}
        local key = e.value.text and unq(e.value.text) or unq(text_of(p.trait))
        if not key then return end
        local lid = ctx.this.id
        if key == "random_common" or key == "random_negative" then
            key = random_trait(l, lid, key == "random_common" and "basic" or "negative")
            if not key then return end
        end
        if add_trait(l, lid, key, p.consume_selection and p.consume_selection.value.text == "yes") then wrote() end
    end
    -- add_timed_trait = { trait days|months|years } (CAddTimedTraitEffect 0x3756e00 → CLeader::
    -- AddTimedTrait 0x1d1c320) [V]: already timed: its end date only; else `timed_trait = { trait
    -- end_date }` appended and the trait inserted (a permanent copy not checked)
    EFF["add_timed_trait"] = function(e, ctx)
        local l = L(ctx)
        if not l or e.value.text then return end
        local p = params(e)
        local key = unq(text_of(p.trait))
        if not key or not trait_def(key) then return end
        local days = (p.days and eval.value(p.days.value, ctx, p.days)) or (p.months and eval.value(p.months.value, ctx, p.months) * 30)
            or (p.years and eval.value(p.years.value, ctx, p.years) * 360) or 0
        local end_date = date_text(today() + trunc(days))
        for _, x in ipairs(world.fields(l, "timed_trait")) do
            if type(x) == "table" and unq(field(x, "trait")) == key then
                world.set(x, "end_date", quoted(end_date))
                wrote()
                return
            end
        end
        local b = {}
        world.append(b, "trait", key, true)
        world.append(b, "end_date", end_date, true)
        local _, lv = world.entry(l, "level")
        if lv then world.insert(l, lv, "timed_trait", b) else world.append(l, "timed_trait", b) end
        insert_trait(l, key)
        wrote()
    end
    -- remove_trait = <trait>|all_negative (CRemoveTraitEffect 0x3757c10) [V]
    local function remove_where(l, f)
        local n = 0
        for _, t in ipairs(traits_of(l)) do
            if f(t) and remove_trait(l, t) then n = n + 1 end
        end
        return n
    end
    local function negative(t) return trait_type(t) == "negative" end
    EFF["remove_trait"] = function(e, ctx)
        local l = L(ctx)
        if not l or not e.value.text then return end
        local key = unq(e.value.text)
        local n = key == "all_negative" and remove_where(l, negative) or (remove_trait(l, key) and 1 or 0)
        if n > 0 then wrote() end
    end
    -- remove_all_traits / remove_all_negative_traits / remove_all_positive_traits
    -- (CRemoveTraitsEffect<2/1/0> → RemoveAllTraits, RemoveAllNegativeTraits (type negative),
    -- RemoveAllNonNegativeTraits) [V]
    EFF["remove_all_traits"] = function(_, ctx)
        local l = L(ctx) if l and remove_where(l, function() return true end) > 0 then wrote() end
    end
    EFF["remove_all_negative_traits"] = function(_, ctx)
        local l = L(ctx) if l and remove_where(l, negative) > 0 then wrote() end
    end
    EFF["remove_all_positive_traits"] = function(_, ctx)
        local l = L(ctx) if l and remove_where(l, function(t) return not negative(t) end) > 0 then wrote() end
    end

    -- ------------------------------------------------------------------------------------------
    -- class, ethic, portrait, gender, flags, cooldowns

    -- change_background_ethic = <ethic> (CChangeBackgroundEthic 0x37b19e0) [V]: `ethic`
    EFF["change_background_ethic"] = function(e, ctx)
        local l = L(ctx)
        if not l or not e.value.text then return end
        local v = unq(e.value.text)
        if not def("common/ethics", v) then return end
        world.set(l, "ethic", quoted(v))
        wrote()
    end
    -- change_leader_class = <class> (CChangeLeaderClassEffect 0x3782470 → SetLeaderClass) [V]:
    -- `class` only
    EFF["change_leader_class"] = function(e, ctx)
        local l = L(ctx)
        if not l or not e.value.text then return end
        local class = unq(e.value.text)
        if not def("common/leader_classes", class) then return end
        world.set(l, "class", quoted(class))
        wrote()
    end
    local function species_portrait(sid)
        local s = sid and H.species(sid)
        local p = s and field(s, "portrait")
        return p and unq(p) or nil
    end
    -- change_leader_portrait = <portrait>|<species> (CChangeLeaderPortraitEffect 0x3781230) [V]: a
    -- species' portrait or the key; the leader's `portrait`, its design's too
    EFF["change_leader_portrait"] = function(e, ctx)
        local l = L(ctx)
        if not l or not e.value.text then return end
        local sc = target(e, ctx)
        local p = (sc and sc ~= NONE and species_portrait(H.species_of(sc))) or unq(e.value.text)
        if not p or p == "" then return end
        world.set(l, "portrait", quoted(p))
        local d = field(l, "design")
        if type(d) == "table" and field(d, "portrait") then world.set(d, "portrait", quoted(p)) end
        wrote()
    end
    -- set_gender = <gender> (CSetGenderEffect 0x375bbf0 → CLeader::SetGender 0x1d132a0) [V]: a new
    -- gender: `gender`, the design dropped, the portrait the species'
    EFF["set_gender"] = function(e, ctx)
        local l = L(ctx)
        if not l or not e.value.text then return end
        local g = unq(e.value.text)
        local cur = unq(field(l, "gender")) or "not_set"
        if g == cur then return end
        if g == "not_set" then remove_key(l, "gender") else world.set(l, "gender", g) end
        remove_key(l, "design")
        local p = species_portrait(tonumber(field(l, "species")))
        if p then world.set(l, "portrait", quoted(p)) end
        wrote()
    end
    -- leader_flags (default 0x1c0, left out when so): 0x2 immortal, 0x8 age frozen, 0x20 to be
    -- killed, 0x40 recruitable [V]
    local DEFAULT_FLAGS = 0x1c0
    local function lflags(l) return tonumber(field(l, "leader_flags")) or DEFAULT_FLAGS end
    local function set_lflag(l, mask, on)
        local v = lflags(l)
        local nv = on and bit.bor(v, mask) or bit.band(v, bit.bnot(mask))
        if nv == v then return false end
        if nv == DEFAULT_FLAGS then remove_key(l, "leader_flags") else world.set(l, "leader_flags", nv) end
        return true
    end
    -- set_immortal / freeze_leader_age = yes|no (CSetImmortalEffect 0x37b3db0, CFreezeLeaderAgeEffect
    -- 0x37b5d40) [V]
    EFF["set_immortal"] = function(e, ctx)
        local l = L(ctx)
        if l and e.value.text and set_lflag(l, 0x2, e.value.text == "yes") then wrote() end
    end
    EFF["freeze_leader_age"] = function(e, ctx)
        local l = L(ctx)
        if l and e.value.text and set_lflag(l, 0x8, e.value.text == "yes") then wrote() end
    end
    -- set_cooldown = <days> (CSetCooldownEffect 0x3747230) [V]: `cooldown` (0 left out)
    EFF["set_cooldown"] = function(e, ctx)
        local l = L(ctx)
        if not l then return end
        local v = int_value(e, ctx) or 0
        if v == 0 then remove_key(l, "cooldown") else world.set(l, "cooldown", v) end
        wrote()
    end
    -- set_years_served = <leader> (CSetYearsServedEffect 0x3746d20) [V]: the target's
    -- recruitment_date
    EFF["set_years_served"] = function(e, ctx)
        local l = L(ctx)
        local sc = target(e, ctx)
        local o = sc and sc.kind == "leader" and H.leader(sc.id)
        if not l or not o then return end
        local d = field(o, "recruitment_date")
        if d then world.set(l, "recruitment_date", quoted(unq(d))) wrote() end
    end

    -- ------------------------------------------------------------------------------------------
    -- the country's leaders: owned, the pool, the ruler

    local function country_list(c, key)
        local l = field(c, key)
        if type(l) ~= "table" then l = world.child(c, key) end
        return l
    end
    local function pool_list(c)
        local m = world.child(world.child(c, "modules"), "standard_leader_module")
        return country_list(m, "leaders")
    end
    local function remove_id(list, id)
        local found = false
        for i = #list, 1, -1 do
            if list[i].text and tonumber(list[i].text) == id then world.remove_at(list, i) found = true end
        end
        return found
    end
    local function has_id(list, id)
        for _, x in ipairs(list) do if x.text and tonumber(x.text) == id then return true end end
        return false
    end
    -- CCountry::RemoveOwnedLeader
    local function remove_owned(cid, lid)
        local c = cid and obj("country", cid)
        if not c then return false end
        local ok = remove_id(country_list(c, "owned_leaders"), lid)
        local l = world.leaders_of and world.leaders_of[cid]
        if l then for i = #l, 1, -1 do if l[i] == lid then table.remove(l, i) end end end
        return ok
    end
    local function add_owned(cid, lid)
        local c = obj("country", cid)
        if not c then return end
        local list = country_list(c, "owned_leaders")
        if not has_id(list, lid) then world.append_value(list, lid) end
        if world.leaders_of then
            local l = world.leaders_of[cid] or {}
            world.leaders_of[cid] = l
            l[#l + 1] = lid
        end
    end
    -- CLeaderCountryModule::AddToLeaderPool (0x1d356e0) [V]: appended to the pool;
    -- on_added_to_leader_pool (this the country, from the leader)
    local function add_to_pool(cid, lid)
        local c = obj("country", cid)
        if not c then return end
        local list = pool_list(c)
        if not has_id(list, lid) then world.append_value(list, lid) end
        fire("on_added_to_leader_pool", S("country", cid), S("leader", lid))
    end
    -- recruitable = yes|no (CSetRecruitableEffect 0x3765cc0 → CLeader::SetRecruitable 0x1d1c0a0) [V]:
    -- the same: nothing; yes: the flag, date_added today, into the owner's pool; no: the flag off,
    -- out of the owner's leaders
    EFF["recruitable"] = function(e, ctx)
        local l = L(ctx)
        if not l or not e.value.text then return end
        local on = e.value.text == "yes"
        if not set_lflag(l, 0x40, on) then return end
        local cid = owner_of(l)
        if on then
            world.set(l, "date_added", quoted(date_text(today())))
            if cid then add_to_pool(cid, ctx.this.id) end
        else
            remove_owned(cid, ctx.this.id)
        end
        wrote()
    end
    -- the leader's location left (CLeaderLocation::SetLeader(null) 0x1d3c760): on_leader_unassigned
    -- (this the leader); the location's holder no longer points at it [I: a fleet's, army's,
    -- colony's `leader` / governor field]; `location` out
    local function unassign(l, lid)
        local loc = field(l, "location")
        if type(loc) ~= "table" then return false end
        local ltype, id = unq(field(loc, "type")), tonumber(field(loc, "id"))
        local holder = ltype and id and world.object(ltype == "planet" and "colony" or ltype, id)
        if holder then
            for _, k in ipairs({ "leader", "governor" }) do
                if tonumber(field(holder, k)) == lid then world.set(holder, k, NO_ID) end
            end
        end
        fire("on_leader_unassigned", S("leader", lid), nil)
        remove_key(l, "location")
        return true
    end
    -- unassign_leader = <leader> | yes (CUnassignLeaderEffect 0x3748c20) [V]: the target, or the
    -- scope's leader
    EFF["unassign_leader"] = function(e, ctx)
        local sc = e.value.text and e.value.text ~= "yes" and target(e, ctx) or nil
        local lid = sc and sc.kind == "leader" and sc.id or (ctx.this.kind == "leader" and ctx.this.id) or nil
        local l = lid and H.leader(lid)
        if l and unassign(l, lid) then wrote() end
    end
    -- the leader off its council seat (council_positions' leader none, council_location out)
    local function off_council(l)
        local cl = field(l, "council_location")
        local pid = type(cl) == "table" and tonumber(field(cl, "id"))
        local p = pid and obj("council_positions", pid)
        if p then world.set(p, "leader", NO_ID) end
        return remove_key(l, "council_location") or p ~= nil
    end
    H.off_council = off_council
    -- the country's ruler (`ruler`)
    local function set_ruler(c, lid) world.set(c, "ruler", lid or NO_ID) end

    -- ------------------------------------------------------------------------------------------
    -- exiled leaders (the game's top-level saved_leaders = { "key" = id }, CGameState +0x950) and a
    -- country's saved leaders (its own saved_leaders, CSavedLeaderManager)

    local function key_of(e, ctx)
        local t = e.value.text and unq(e.value.text) or unq(text_of(params(e).key))
        if not t then return nil end
        return I.flag_name(t, ctx, e) or t
    end
    local function exiled() return world.meta.saved_leaders end
    local function saved_get(block, key)
        if type(block) ~= "table" then return nil end
        for _, x in ipairs(block) do
            if x.op and x.key and unq(x.key.text) == key then return tonumber(x.value.text), x end
        end
        return nil
    end
    local function saved_put(block, key, lid)
        local _, en = saved_get(block, key)
        if en then world.set_entry(block, en, { text = tostring(lid) }) return end
        world.append_entry(block, { key = { text = '"' .. key .. '"' }, op = "=", value = { text = tostring(lid) } })
    end
    local function saved_clear(block, key)
        local id, en = saved_get(block, key)
        if en then world.remove_entry(block, en) end
        return id
    end
    -- CLeader::SetOwner(none): out of the owner's leaders and pool, no country [I]
    local function drop_owner(l, lid)
        local cid = owner_of(l)
        if cid then
            remove_owned(cid, lid)
            local c = obj("country", cid)
            if c then remove_id(pool_list(c), lid) end
        end
        world.set(l, "country", NO_ID)
    end
    -- CLeader::SetOwner(country) [I]: the country and its owned leaders
    local function take_owner(l, lid, cid)
        world.set(l, "country", cid)
        add_owned(cid, lid)
    end
    -- exile_leader_as = <key> (CExileLeaderAsEffect 0x3747a40) [V]: the scope's leader (a country's
    -- ruler made none) off its post and the council, owned by none, kept under the key
    EFF["exile_leader_as"] = function(e, ctx)
        local key = key_of(e, ctx)
        if not key then return end
        local lid
        if ctx.this.kind == "leader" then
            lid = ctx.this.id
        elseif ctx.this.kind == "country" then
            local c = obj("country", ctx.this.id)
            lid = c and tonumber(field(c, "ruler"))
            if lid == NO_ID then lid = nil end
            if lid then set_ruler(c, nil) end
        elseif ctx.this.kind == "fleet" or ctx.this.kind == "army" then
            local o = world.object(ctx.this.kind, ctx.this.id)
            lid = o and tonumber(field(o, "leader"))
            if lid == NO_ID then lid = nil end
        end
        local l = lid and H.leader(lid)
        if not l then return end
        unassign(l, lid)
        off_council(l)
        drop_owner(l, lid)
        if not world.meta.saved_leaders then world.meta.saved_leaders = {} end
        saved_put(exiled(), key, lid)
        wrote()
    end
    -- set_leader = <key> (CSetLeaderEffect 0x37483e0) [V]: the exiled leader under the key: a
    -- country's ruler (owned by it), a fleet's or army's leader (owned by its owner); the key cleared.
    -- A leader target instead: the objects area's set_leader
    local prev_set_leader = EFF["set_leader"]
    EFF["set_leader"] = function(e, ctx)
        local key = e.value.text and unq(e.value.text)
        local lid = key and saved_get(exiled(), key)
        if not lid then
            if prev_set_leader then return prev_set_leader(e, ctx) end
            return
        end
        local l = H.leader(lid)
        if not l then return end
        if ctx.this.kind == "country" then
            local c = obj("country", ctx.this.id)
            if not c then return end
            take_owner(l, lid, ctx.this.id)
            set_ruler(c, lid)
        elseif ctx.this.kind == "fleet" or ctx.this.kind == "army" then
            local o = world.object(ctx.this.kind, ctx.this.id)
            local owner = o and tonumber(field(o, "owner"))
            if not o or not owner then return end
            take_owner(l, lid, owner)
            world.set(o, "leader", lid)
        else
            return
        end
        saved_clear(exiled(), key)
        wrote()
    end
    -- return_leader_from_exile = <key> (CReturnLeaderFromExileEffect 0x3797ab0) [V]: owned by the
    -- scope country, no location, the key cleared
    EFF["return_leader_from_exile"] = function(e, ctx)
        if ctx.this.kind ~= "country" then return end
        local key = key_of(e, ctx)
        local lid = key and saved_get(exiled(), key)
        local l = lid and H.leader(lid)
        if not l then return end
        take_owner(l, lid, ctx.this.id)
        remove_key(l, "location")
        saved_clear(exiled(), key)
        wrote()
    end
    -- the leader killed (CLeader::SetToBeKilled: the engine's kill_leader)
    local function kill(lid)
        stats.engine = stats.engine + 1
        E.push({ type = "kill_leader", kind = "leader", id = lid })
    end
    -- kill_exiled_leader = <key> (CKillExiledLeaderEffect 0x3798520) [V]
    EFF["kill_exiled_leader"] = function(e, ctx)
        local key = key_of(e, ctx)
        local lid = key and saved_clear(exiled(), key)
        if lid and H.leader(lid) then kill(lid) wrote() end
    end
    local function country_saved(c) return world.child(c, "saved_leaders") end
    -- create_saved_leader = { key <create_leader's parameters> effect } (CCreateSavedLeaderEffect
    -- 0x37adf60) [V]: a new leader kept in the country's saved_leaders, not owned nor in the pool,
    -- on_leader_spawned, the effect [I: made through create_leader, then taken out of the owned
    -- leaders]
    EFF["create_saved_leader"] = function(e, ctx)
        local c = ctx.this.kind == "country" and obj("country", ctx.this.id)
        if not c or e.value.text or not EFF["create_leader"] then return end
        local key = key_of(e, ctx)
        if not key then return end
        local before = tonumber(world.meta.last_created_leader)
        EFF["create_leader"](e, ctx)
        local h = ctx.created and ctx.created.leader
        local lid = h and E.resolve and E.resolve(h) or tonumber(world.meta.last_created_leader)
        if not lid or lid == before then return end
        remove_owned(ctx.this.id, lid)
        saved_put(country_saved(c), key, lid)
        wrote()
    end
    -- activate_saved_leader = { key add_to_owned effect } (CActivateSavedLeaderEffect 0x37aee40) [V]:
    -- out of the country's saved leaders; recruitable ones: add_to_owned: owned, recruitment_date
    -- today; else date_added today and into the pool; `country`; on_leader_spawned, the effect
    EFF["activate_saved_leader"] = function(e, ctx)
        local c = ctx.this.kind == "country" and obj("country", ctx.this.id)
        if not c or e.value.text then return end
        local p = params(e)
        local key = key_of(e, ctx)
        local lid = key and saved_clear(country_saved(c), key)
        local l = lid and H.leader(lid)
        if not l then return end
        local cid = ctx.this.id
        if bit.band(lflags(l), 0x40) ~= 0 then
            if p.add_to_owned and p.add_to_owned.value.text == "yes" then
                add_owned(cid, lid)
                world.set(l, "recruitment_date", quoted(date_text(today())))
            else
                world.set(l, "date_added", quoted(date_text(today())))
                add_to_pool(cid, lid)
            end
            world.set(l, "country", cid)
        end
        fire("on_leader_spawned", S("country", cid), S("leader", lid))
        if p.effect and p.effect.value.text == nil then
            eval.effect(p.effect.value, eval.seed_scope(I.push(ctx, S("leader", lid)), eval.scope_draw(ctx)))
        end
        wrote()
    end
    -- remove_saved_leader = <key> (CRemoveSavedLeaderEffect 0x37aeb00) [V]: out, killed
    EFF["remove_saved_leader"] = function(e, ctx)
        local c = ctx.this.kind == "country" and obj("country", ctx.this.id)
        if not c then return end
        local key = key_of(e, ctx)
        local lid = key and saved_clear(country_saved(c), key)
        if lid and H.leader(lid) then kill(lid) end
        wrote()
    end
    -- clone_leader = { target <overrides> effect } (CCloneLeader 0x37af2b0) [V calls; I fields]: a
    -- copy of the target as a new leader of the scope country (its flags and variables too; the
    -- location, council seat and dates its own), owned; overrides: class, species, skill, gender,
    -- traits; on_leader_spawned, the effect
    EFF["clone_leader"] = function(e, ctx)
        local c = ctx.this.kind == "country" and obj("country", ctx.this.id)
        if not c or e.value.text then return end
        local p = params(e)
        local sc = p.target and target(p.target, ctx)
        local src = sc and sc.kind == "leader" and H.leader(sc.id)
        if not src then return end
        local cid = ctx.this.id
        local b = {}
        for _, x in ipairs(src) do
            local k = x.op and x.key and x.key.text
            if k and k ~= "location" and k ~= "council_location" and k ~= "country" and k ~= "date_added"
                and k ~= "recruitment_date" and k ~= "death_date" then
                b[#b + 1] = copy_node(x)
            end
        end
        local lid = require("engine.script.objects").create("leaders", b)
        local l = H.leader(lid)
        world.set(l, "country", cid)
        world.set(l, "recruitment_date", quoted(date_text(today())))
        local class = unq(text_of(p.class))
        if class and def("common/leader_classes", class) then world.set(l, "class", quoted(class)) end
        local sp = p.species and target(p.species, ctx)
        local sid = sp and H.species_of(sp)
        if sid then world.set(l, "species", sid) end
        if p.skill then world.set(l, "level", math.max(1, trunc(eval.value(p.skill.value, ctx, p.skill) or 1))) end
        local g = unq(text_of(p.gender))
        if g == "male" or g == "female" then world.set(l, "gender", g) end
        if p.traits and p.traits.value.text == nil then
            while remove_key(l, "traits") do end
            for _, x in ipairs(p.traits.value) do
                if x.op and x.value.text then insert_trait(l, unq(x.value.text)) end
            end
        end
        add_owned(cid, lid)
        world.meta.last_created_leader = lid
        if ctx.created then ctx.created.leader = nil end
        fire("on_leader_spawned", S("country", cid), S("leader", lid))
        if p.effect and p.effect.value.text == nil then
            eval.effect(p.effect.value, eval.seed_scope(I.push(ctx, S("leader", lid)), eval.scope_draw(ctx)))
        end
        wrote()
    end
    -- refresh_leader_pool (CRefreshLeaderPoolEffect 0x37b5f50 → UpdateLeaderPools(force)) [V]: every
    -- class's pool made again [I: the pool's generation is not modelled; reported]
    EFF["refresh_leader_pool"] = function(e, ctx)
        if ctx.this.kind ~= "country" or e.value.text == "no" then return end
        I.miss("effect", "refresh_leader_pool (pool generation)", ctx, e)
    end
end
