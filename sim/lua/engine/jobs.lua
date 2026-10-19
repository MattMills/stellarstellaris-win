-- engine/jobs.lua : the colonies' pop jobs (the save's `pop_jobs`) and which pops work them, the
-- way the game's jobs update does it (Linux 4.5.2, docs/pops.md "The jobs update"):
--
-- NPlanetJobs::UpdatePopJobs(date, colonies) (0x26b4520), on a batch of colonies:
--   BuildUpdateData (0x26beaf0)            the batch's pop groups and jobs (their order)
--   CollapsePopGroups (0x26c2c80)          groups of under one pop of the same key merged
--   CalculatePopGroupPossiblePreCalcFlags  per group: the pre-triggers (has_owner, is_enslaved, ...)
--     / UpdatePopGroupsWith... (0x26bd9d0)   and the possible_precalc rules (can_fill_*_job)
--   UpdateAvailableJobs (0x26bb520)        the colony's jobs made and removed: an uncapped job type
--                                            (is_capped_by_modifier = no) while a group passes its
--                                            pre-triggers, a capped one while job_<t>_add > 0
--   AssignPopsToJobs (0x26b5500)           weights, sort, the greedy assignment, the categories
--
-- run twice a day for every colony (CGameState::DailyUpdate ->
-- NColonyUpdate::MonthlyOrDailyUpdatePopJobsInColony 0x28ecf80), twice in the month's colony
-- update (after the growth), and once a new game's start script is done.
--
-- Numbers are the game's fixed point (CFixedPoint, int64, 1.0 = 100000) in LuaJIT int64. Pop group
-- sizes and job amounts are integers (100 = one pop).
--
--   local jobs = require("engine.jobs")
--   jobs.update([colonies])        -- one UpdatePopJobs pass (all colonies in store order)
--   jobs.daily(host, date)         -- the day's two passes
--   jobs.report()
--
-- STELLAR_JOBS=off leaves the jobs as they are (the save's).

local ffi = require("ffi")
local world = require("engine.world")
local defs = require("engine.defs")
local eval = require("simscript.eval")
local slice = require("engine.slice")

local jobs = {
    stats = {
        passes = 0, colony_passes = 0, created = 0, removed = 0, assigned = 0, moved = 0,
        groups_created = 0, collapsed = 0, trigger_errors = 0, rule_errors = 0,
    },
    errors = {},
    off = os.getenv("STELLAR_JOBS") == "off",
}

local DEBUG = tonumber(os.getenv("STELLAR_JOBS_DEBUG") or "")   -- a colony whose sorted entries are printed
local I64 = ffi.typeof("int64_t")
local ONE = I64(100000)
local ZERO = I64(0)
local NONE = 4294967295
local INT_MAX = 2147483647
local CAP_UNCAPPED = I64(0xffffffffffff)

-- ---------------------------------------------------------------------------------------------
-- fixed point

local function fx(v)            -- a modifier value (a float) as the game holds it
    v = tonumber(v) or 0
    if v >= 0 then return I64(math.floor(v * 100000 + 0.5)) end
    return -I64(math.floor(-v * 100000 + 0.5))
end
local function ifx(n) return I64(n) * ONE end
local function fmul(a, b) return a * b / ONE end              -- truncates toward zero, as the game
local function fdiv(a, b)
    if b == ZERO then return I64(4294967295) end
    return a * ONE / b
end
local function fceil(a)         -- the smallest integer >= a (a Lua number)
    local q = a / ONE
    if q * ONE < a then q = q + 1 end
    return tonumber(q)
end
local function num(a) return tonumber(a) / 100000 end         -- as the save writes it
local function fread(v) return fx(tonumber(v) or 0) end

local function int(v) return math.floor(tonumber(v) or 0) end
local function unq(s) return s and (tostring(s):gsub('^"(.*)"$', "%1")) end

-- ---------------------------------------------------------------------------------------------
-- the definitions

local function define(group, key, default)
    local g = defs.get("common/defines", group)
    local v = g and defs.field(g.block, key)
    return tonumber(v) or default
end

local D
local function defines()
    if D then return D end
    D = {
        WEIGHT_POWER = define("NPop", "POP_JOB_WORKFORCE_WEIGHT_POWER", 3),
        FAVORITE = fx(define("NPop", "FAVORITE_JOB_WEIGHT_MULT", 10)),
        CHANGE_THRESHOLD = define("NPop", "DEFAULT_CHANGE_JOB_THRESHOLD", 1.05),
        COLLAPSE = define("NPop", "POP_GROUP_COLLAPSING_THRESHOLD", 99),
        AUTOMATED_MAX = fx(define("NGameplay", "AUTOMATED_WORKFORCE_MAX_PERC", 1)),
    }
    return D
end

local function field(block, key) return block and defs.field(block, key) end
local function yes(block, key, default)
    local v = field(block, key)
    if v == nil then return default end
    return v == "yes"
end

-- CPopCategory: rank (+0x9b8, default 1), change_job_threshold (+0x8b8), job_reshuffle_interval
-- (+0x9bc), can_change_category (+0x9c0: yes/no, or a pre-trigger form)
local cat_cache = {}
local function category(name)
    if not name then return nil end
    local c = cat_cache[name]
    if c == nil then
        local d = defs.get("common/pop_categories", name)
        if not d then
            c = false
        else
            local b = d.block
            local cc = field(b, "can_change_category")
            c = {
                name = name,
                rank = tonumber(field(b, "rank")) or 1,
                threshold = fx(tonumber(field(b, "change_job_threshold")) or defines().CHANGE_THRESHOLD),
                reshuffle = tonumber(field(b, "job_reshuffle_interval")) or 0,
                can_change = cc == nil or cc == "yes" or (type(cc) == "table" and cc) or false,
                bonus_mod = "pop_cat_" .. name .. "_bonus_workforce_mult",
            }
        end
        cat_cache[name] = c
    end
    return c or nil
end
jobs.category = category

-- the pre-triggers (EPreTrigger) a job or a category tests: key -> wanted value
local PRE_KEYS = { "has_owner", "is_enslaved", "is_being_purged", "is_being_assimilated", "has_planet", "is_sapient", "is_robotic" }
local function pre_form(block)
    if type(block) ~= "table" then return nil end
    local f = {}
    for _, k in ipairs(PRE_KEYS) do
        local v = field(block, k)
        if v == "yes" then f[k] = true elseif v == "no" then f[k] = false end
    end
    return f
end
local function pre_holds(form, values)
    if not form then return true end
    for k, want in pairs(form) do
        if (values[k] == true) ~= want then return false end
    end
    return true
end

-- the job types in the database's order (the files in load order), split as
-- CJobTypeDatabase::PostReadInit (0x1ce65d0) does: is_capped_by_modifier (flags bit0, default yes)
local types_cache
local function job_types()
    if types_cache then return types_cache end
    local list = {}
    for name, d in pairs(defs.folder("common/pop_jobs")) do
        list[#list + 1] = { name = name, d = d }
    end
    table.sort(list, function(a, b)
        local fa, fb = tostring(a.d.file), tostring(b.d.file)
        if fa ~= fb then return fa < fb end
        return (a.d.line or 0) < (b.d.line or 0)
    end)
    local all, capped, uncapped, by = {}, {}, {}, {}
    for i, e in ipairs(list) do
        local b = e.d.block
        local t = {
            name = e.name, index = i, file = e.d.file,
            category = unq(field(b, "category")),
            capped = yes(b, "is_capped_by_modifier", true),
            first_come = yes(b, "first_come_first_served", false),
            same_rank = yes(b, "allow_only_same_rank_pops", false),
            automated = yes(b, "can_be_automated", true),
            pre = pre_form(field(b, "possible_pre_triggers")),
            precalc = unq(field(b, "possible_precalc")),
            possible = field(b, "possible"),
            weight = field(b, "weight"),
            add = "job_" .. e.name .. "_add",
            per_pop = "job_" .. e.name .. "_per_pop",
            per_crime = "job_" .. e.name .. "_per_crime",
            wf_mod = "pop_" .. e.name .. "_workforce_mult",
            bonus_mod = "pop_" .. e.name .. "_bonus_workforce_mult",
            max_add = "job_" .. e.name .. "_max_workforce_add",
            max_mult = "job_" .. e.name .. "_max_workforce_mult",
            auto_mult = "job_" .. e.name .. "_automated_workforce_mult",
        }
        if type(t.possible) ~= "table" then t.possible = nil end
        if type(t.weight) ~= "table" then t.weight = nil end
        all[#all + 1] = t
        by[e.name] = t
        if t.capped then capped[#capped + 1] = t else uncapped[#uncapped + 1] = t end
    end
    types_cache = { all = all, capped = capped, uncapped = uncapped, by = by }
    return types_cache
end
jobs.job_types = job_types

-- ---------------------------------------------------------------------------------------------
-- the world

local function modifiers(kind, id)
    local economy = package.loaded["engine.economy"]
    return economy and economy.modifiers(kind, id) or nil
end

local function colony_planet(cid)
    return world.colony_planet[cid]
end

local function owner_of(cid)
    local pid = colony_planet(cid)
    local p = pid and world.object("planet", pid)
    local o = p and tonumber(world.field(p, "owner"))
    if o == NONE then o = nil end
    return o, pid
end

local function group_key(g)
    local key = world.field(g, "key")
    if type(key) ~= "table" then return nil, nil end
    return tonumber(world.field(key, "species")), unq(world.field(key, "category"))
end

local function live_groups(c)
    local out = {}
    for _, t in ipairs(world.list(world.field(c, "pop_groups"))) do
        local id = tonumber(t)
        local g = id and world.object("pop_groups", id)
        if g and world.field(g, "killed") ~= "yes" then out[#out + 1] = id end
    end
    return out
end

local function job_ids(c)
    local out = {}
    for _, t in ipairs(world.list(world.field(c, "pop_jobs"))) do
        local id = tonumber(t)
        if id and world.object("pop_jobs", id) then out[#out + 1] = id end
    end
    return out
end

local function list_of(obj, key)
    local l = world.field(obj, key)
    if type(l) ~= "table" then l = world.child(obj, key) end
    return l
end

-- the colony's `pop_jobs = { }`, made after its `pop_groups` when missing (the save's order)
local function colony_jobs_list(c)
    local l = world.field(c, "pop_jobs")
    if type(l) == "table" then return l end
    local _, i = world.entry(c, "pop_groups")
    if not i then return list_of(c, "pop_jobs") end
    world.insert(c, i + 1, "pop_jobs", {})
    return world.field(c, "pop_jobs")
end

-- a list block's value removed by swapping the last one into its place (CPdxArray::RemoveSwap,
-- as CColony::RemovePopGroup 0x286ab70 and SetToBeKilledAndRemovePopJob 0x286c510 do)
local function remove_swap(block, id)
    local n, at = 0, nil
    for i, e in ipairs(block) do
        if e.text ~= nil then
            n = i
            if tonumber(e.text) == id and not at then at = i end
        end
    end
    if not at then return false end
    if at ~= n then
        world.set_text(block, at, block[n].text)
    end
    world.remove_at(block, n)
    return true
end

-- ---------------------------------------------------------------------------------------------
-- the job objects (CPopJob: WriteMembers 0x1ea5930, ctor 0x1ea5700)

local J = {}            -- job id -> its state for the pass { id, obj, type, ... fixed values }

local function read_job(id)
    local o = world.object("pop_jobs", id)
    if not o then return nil end
    local t = job_types().by[unq(world.field(o, "type"))]
    local j = {
        id = id, obj = o, type = t,
        auto = fread(world.field(o, "automated_workforce")),
        workforce = fread(world.field(o, "workforce")),
        max = fread(world.field(o, "max_workforce")),
        bonus = fread(world.field(o, "bonus_workforce")),
        limit = fread(world.field(o, "workforce_limit")),
        auto_limit = fread(world.field(o, "automated_workforce_limit")),
        groups = {},     -- { { gid, amount } } (SJobAssignedPopGroup)
        pop_group = tonumber(world.field(o, "pop_group")) or NONE,
    }
    for _, a in ipairs(world.blocks(world.field(o, "pop_groups"))) do
        j.groups[#j.groups + 1] = { tonumber(world.field(a, "pop_group")), int(world.field(a, "amount")) }
    end
    j.sig = nil
    return j
end

-- what the save shows of a job (its block is rewritten only when this changes)
local function signature(j)
    local t = { tostring(j.auto), tostring(j.workforce), tostring(j.max), tostring(j.bonus), tostring(j.limit),
        tostring(j.auto_limit), tostring(j.pop_group) }
    for _, a in ipairs(j.groups) do t[#t + 1] = a[1] .. ":" .. a[2] end
    return table.concat(t, ",")
end

local function write_job(j)
    local sig = signature(j)
    if sig == j.sig then return end
    j.sig = sig
    local o = j.obj
    local b = {}
    world.append(b, "type", j.type and j.type.name or unq(world.field(o, "type")))
    world.append(b, "automated_workforce", num(j.auto))
    world.append(b, "workforce", num(j.workforce))
    world.append(b, "max_workforce", num(j.max))
    world.append(b, "bonus_workforce", num(j.bonus))
    world.append(b, "workforce_limit", num(j.limit))
    world.append(b, "automated_workforce_limit", num(j.auto_limit))
    if #j.groups > 0 then
        local l = {}
        for _, a in ipairs(j.groups) do
            local e = {}
            world.append(e, "pop_group", a[1])
            world.append(e, "amount", a[2])
            world.push(l, e)
        end
        world.append(b, "pop_groups", l)
    end
    world.append(b, "planet", world.field(o, "planet") or NONE)
    world.append(b, "pop_group", j.pop_group)
    world.replace(o, b)
end

local next_job_index
-- CColony::AccessOrCreatePopJob (0x286c400) -> CGameState::CreateNewPopJob (0x1b46c80): a new
-- job at the end of the colony's list, the ctor's values (workforce_limit 0, automated limit -1)
local function create_job(cid, c, t)
    world.ensure_store("pop_jobs")
    if not next_job_index then next_job_index = world.next_index("pop_jobs") end
    local id = next_job_index
    next_job_index = next_job_index + 1
    local b = {}
    world.append(b, "type", t.name)
    world.append(b, "planet", cid)
    world.create("pop_jobs", id, b)
    world.append_value(colony_jobs_list(c), id)
    local j = read_job(id)
    j.auto, j.workforce, j.max, j.bonus, j.limit, j.auto_limit = ZERO, ZERO, ZERO, ZERO, ZERO, -ONE
    J[id] = j
    jobs.stats.created = jobs.stats.created + 1
    return j
end

-- CColony::SetToBeKilledAndRemovePopJob (0x286c510): out of the colony's list (swap with the
-- last), the object killed (removed from the store here; the save keeps no killed jobs [I])
local function remove_job(c, j)
    remove_swap(list_of(c, "pop_jobs"), j.id)
    world.remove("pop_jobs", j.id)
    J[j.id] = nil
    j.dead = true
    jobs.stats.removed = jobs.stats.removed + 1
end

-- the max workforce a new max takes the limits to (UpdateAvailableJobs 0x26bbc9c): a raise moves
-- both limits by the difference, a cut clamps them
local function apply_max(j, m)
    local d = m - j.max
    if d > ZERO then
        j.limit = j.limit + d
        j.auto_limit = j.auto_limit + d
    else
        if m < j.limit then j.limit = m end
        if m < j.auto_limit then j.auto_limit = m end
    end
    j.max = m
end

-- ---------------------------------------------------------------------------------------------
-- the pop groups' flags (CalculatePopGroupPreTriggerFlags 0x26bd7c0, the possible_precalc rules)

local pscript, escript
local function species_right(owner, sid, key)
    escript = escript or require("engine.economy.script")
    local r = owner and escript.rights and escript.rights(owner, sid)
    return r and unq(world.field(r, key))
end

local function archetype(sid)
    local class = world.field(world.object("species_db", sid), "class")
    local d = class and defs.get("common/species_classes", unq(class))
    return d and defs.field(d.block, "archetype") or "BIOLOGICAL"
end

local rule_cache, cache_day = {}, nil
local function rule(name, gid)
    local key = gid .. "/" .. name
    local v = rule_cache[key]
    if v ~= nil then return v end
    local d = defs.get("common/game_rules", name)
    if not d then return true end
    local ok, holds = pcall(eval.trigger, d.block, eval.new_ctx(eval.S("pop_group", gid)))
    if not ok then
        jobs.stats.rule_errors = jobs.stats.rule_errors + 1
        jobs.errors[name] = tostring(holds)
        holds = true
    end
    v = holds and true or false
    rule_cache[key] = v
    return v
end

local PRECALC = { "can_fill_ruler_job", "can_fill_specialist_job", "can_fill_worker_job", "can_fill_drone_job", "can_fill_precursor_job" }

local function group_flags(cid, gid, g, owner)
    local sid = group_key(g)
    local citizenship = owner and species_right(owner, sid, "citizenship")
    local arch = sid and archetype(sid) or "BIOLOGICAL"
    local f = {
        has_owner = owner ~= nil,
        has_planet = true,
        is_enslaved = owner ~= nil and citizenship == "citizenship_slavery",
        is_being_purged = owner ~= nil and citizenship == "citizenship_purge",
        is_being_assimilated = owner ~= nil and citizenship == "citizenship_assimilation",
        is_sapient = arch ~= "PRESAPIENT",
        is_robotic = arch == "ROBOT" or arch == "MACHINE",
    }
    local pre = {}
    for _, k in ipairs(PRECALC) do pre[k] = rule(k, gid) end
    return f, pre
end

-- the group's precalc flags as the save shows them (can_fill_*_job = yes)
local SAVE_PRECALC = { "can_fill_worker_job", "can_fill_specialist_job", "can_fill_ruler_job" }
local function write_precalc(g, pre)
    for _, k in ipairs(SAVE_PRECALC) do
        local now = world.field(g, k) == "yes"
        if pre[k] and not now then
            local _, i = world.entry(g, "key")
            world.insert(g, i or 1, k, "yes")
        elseif now and not pre[k] then
            local e = world.entry(g, k)
            if e then world.remove_entry(g, e) end
        end
    end
end

-- ---------------------------------------------------------------------------------------------
-- the weights: CPopJob::CalcWeight (0x1ea6d10), CJobType::IsPossible (0x1ce5cb0)

local function gmod(M, name) return M and fx(M[name]) or ZERO end

-- 1 + pop_workforce_mult + pop_<job>_workforce_mult (CPopJob::CalcWorkforceMult 0x1ea7120)
local function workforce_mult(G, t)
    return ONE + gmod(G.M, "pop_workforce_mult") + gmod(G.M, t.wf_mod)
end
-- CPopJob::CalcBonusWorkforceMultInternal (0x1ea7130): the general, the job's, its category's
local function bonus_mult(G, t)
    local c = category(t.category)
    return gmod(G.M, "pop_bonus_workforce_mult") + gmod(G.M, t.bonus_mod) + (c and gmod(G.M, c.bonus_mod) or ZERO)
end

local function power(w, f, n)
    for _ = 1, n do w = fmul(w, f) end
    return w
end

-- CJobType::CalcWeight (0x1cde150): the job's `weight` (CMeanTimeToHappen +0xa58, 1 without one)
-- in the pop group's scope
local possible_cache, weight_cache
local function job_weight(G, t)
    if not t.weight then return ONE end
    local key = G.id .. "/" .. t.name
    local v = weight_cache[key]
    if v == nil then
        local ok, w = pcall(eval.weight, t.weight, eval.new_ctx(eval.S("pop_group", G.id), nil, nil, t.file))
        if not ok then
            jobs.stats.trigger_errors = jobs.stats.trigger_errors + 1
            jobs.errors["weight " .. t.name] = tostring(w)
            w = 1
        end
        v = fx(w)
        weight_cache[key] = v
    end
    return v
end

-- CJobType::_IsPossibleInternal (0x1ce5750) and the job's pre-checks and `possible`
local function is_possible(G, t)
    if not pre_holds(t.pre, G.flags) then return false end
    if t.precalc and G.precalc[t.precalc] == false then return false end
    if G.size <= 0 then return false end
    local jc = category(t.category)
    if jc then
        local cc = jc.can_change
        local can = cc == true or (type(cc) == "table" and pre_holds(pre_form(cc), G.flags))
        if can then
            local gr = G.rank
            if (t.capped and gr > jc.rank) or (t.same_rank and gr ~= jc.rank) then return false end
        end
    end
    if not t.possible then return true end
    local key = G.id .. "/" .. t.name
    local v = possible_cache[key]
    if v == nil then
        local ok, holds = pcall(eval.trigger, t.possible, eval.new_ctx(eval.S("pop_group", G.id), nil, nil, t.file))
        if not ok then
            jobs.stats.trigger_errors = jobs.stats.trigger_errors + 1
            jobs.errors["possible " .. t.name] = tostring(holds)
            holds = false
        end
        v = holds and true or false
        possible_cache[key] = v
    end
    return v
end

-- ---------------------------------------------------------------------------------------------
-- moving pops: CColony::AccessOrAddPopGroupMoveSizeFrom (0x285b030)

local pops_mod
local function pops() pops_mod = pops_mod or require("engine.pops"); return pops_mod end

-- the colony's group of the key (the first), else a new one at the end of its list
-- (CColony::AddPopGroup 0x286a6e0)
local function access_or_add(cid, c, sid, cat, like)
    for _, gid in ipairs(live_groups(c)) do
        local s, k = group_key(world.object("pop_groups", gid))
        if s == sid and k == cat then return gid, false end
    end
    jobs.stats.groups_created = jobs.stats.groups_created + 1
    return pops().create_group(cid, sid, cat, like), true
end

-- ---------------------------------------------------------------------------------------------
-- one pass

local function total_months()
    local days = eval.today and eval.today() or 0
    local y = math.floor(days / 365)
    local doy = days - y * 365
    local m, acc = 0, 0
    local LEN = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    for i = 1, 12 do
        if doy < acc + LEN[i] then m = i - 1; break end
        acc = acc + LEN[i]
    end
    return y * 12 + m
end
jobs.total_months = total_months

-- a colony's data for the pass (BuildUpdateData)
local function load_job(jid)
    local j = J[jid]
    if j then return j end
    j = read_job(jid)
    if j then j.sig = signature(j) end
    J[jid] = j
    return j
end

local function build(cid)
    local c = world.object("colony", cid)
    if not c or not colony_planet(cid) then return nil end
    local owner = owner_of(cid)
    local C = { id = cid, c = c, owner = owner, groups = {}, jobs = {} }
    -- the colony's favourite job a category (CColony +0xee0, save `favorite_jobs = { { category
    -- job } }` [I the layout]: CSetFavoriteJobCommand)
    C.favorites = {}
    for _, fb in ipairs(world.blocks(world.field(c, "favorite_jobs"))) do
        local fc, fj = world.field(fb, "category"), world.field(fb, "job")
        if fc and fj then C.favorites[(tostring(fc):gsub('"', ""))] = (tostring(fj):gsub('"', "")) end
    end
    for _, gid in ipairs(live_groups(c)) do
        local g = world.object("pop_groups", gid)
        local sid, cat = group_key(g)
        C.groups[#C.groups + 1] = { id = gid, g = g, species = sid, cat = cat, size = int(world.field(g, "size")) }
    end
    for _, jid in ipairs(job_ids(c)) do
        local j = load_job(jid)
        if j and j.type then C.jobs[#C.jobs + 1] = j end
    end
    return C
end

-- CollapsePopGroups (0x26c2c80): by size (descending, stable), a group of at most
-- POP_GROUP_COLLAPSING_THRESHOLD merged into an earlier one of the same key within the threshold
-- (GROWTH_CAT_COLLAPSE), its job places moved to it
local function collapse(C)
    local th = defines().COLLAPSE
    local order = {}
    for i, G in ipairs(C.groups) do order[i] = G end
    for i, G in ipairs(order) do G.pos = i end
    table.sort(order, function(a, b)
        if a.size ~= b.size then return a.size > b.size end
        return a.pos < b.pos
    end)
    for i = #order, 2, -1 do
        local G = order[i]
        if G.size > 0 then
            if G.size > th then break end
            for k = i - 1, 1, -1 do
                local H = order[k]
                if H.size > 0 then
                    if H.size > th then break end
                    if H.cat == G.cat and H.species == G.species then
                        local n = G.size
                        pops().move_size(H.id, G.id, n, "GROWTH_CAT_COLLAPSE", C.id)
                        H.size, G.size = H.size + n, 0
                        G.dead = true
                        for _, j in ipairs(C.jobs) do
                            for _, a in ipairs(j.groups) do
                                if a[1] == G.id then a[1] = H.id end
                            end
                        end
                        jobs.stats.collapsed = jobs.stats.collapsed + 1
                        break
                    end
                end
            end
        end
    end
    local kept = {}
    for _, G in ipairs(C.groups) do
        if not G.dead then kept[#kept + 1] = G end
    end
    C.groups = kept
end

-- the flags and modifiers of the colony's groups
local function prepare_groups(C)
    for _, G in ipairs(C.groups) do
        G.flags, G.precalc = group_flags(C.id, G.id, G.g, C.owner)
        write_precalc(G.g, G.precalc)
        local cat = category(G.cat)
        G.rank = cat and cat.rank or 1          -- the null category's rank: the ctor's 1
        G.M = modifiers("pop_group", G.id)
        if not G.M then
            -- a group made since the modifiers were built: a sibling's of the species [I]
            for _, H in ipairs(C.groups) do
                if H ~= G and H.species == G.species then
                    G.M = modifiers("pop_group", H.id)
                    if G.M then break end
                end
            end
        end
    end
end

-- UpdateAvailableJobs (CreateAndDestroyJobs lambda 0x26bc3f0, then the serial creation)
local function available(C)
    local types = job_types()
    local M = modifiers("colony", C.id) or {}
    local have = {}
    for _, j in ipairs(C.jobs) do have[j.type.name] = j end
    local add_uncapped, add_capped = {}, {}
    for _, t in ipairs(types.uncapped) do
        local keep = false
        for _, G in ipairs(C.groups) do
            if pre_holds(t.pre, G.flags) and not (t.precalc and G.precalc[t.precalc] == false) then
                keep = true
                break
            end
        end
        if keep then add_uncapped[#add_uncapped + 1] = t
        elseif have[t.name] then remove_job(C.c, have[t.name]) end
    end
    -- CColony::CalcMaxWorkforce (0x289c880): job_<t>_add + pops * job_<t>_per_pop + crime *
    -- job_<t>_per_crime
    local pops_n = tonumber(world.field(C.c, "num_sapient_pops")) or 0
    local crime = fread(world.field(C.c, "crime"))
    local maxes = {}
    for _, t in ipairs(types.capped) do
        local m = fx(M[t.add])
        local pp = M[t.per_pop]
        if pp and pops_n > 0 then m = m + I64(pops_n) * fx(pp) end
        local pc = M[t.per_crime]
        if pc and crime > ZERO then m = m + fmul(crime, fx(pc)) end
        if m > ZERO then
            add_capped[#add_capped + 1] = t
            maxes[t.name] = m
        elseif have[t.name] then
            remove_job(C.c, have[t.name])
        end
    end
    -- CPopJob::CalcMaxWorkforce (0x1ea7c00): base * (1 + job_max_workforce_mult +
    -- job_<t>_max_workforce_mult) + job_max_workforce_add + job_<t>_max_workforce_add
    local gmult = fx(M.job_max_workforce_mult)
    local gadd = fx(M.job_max_workforce_add)
    for _, t in ipairs(add_uncapped) do
        local j = have[t.name] or create_job(C.id, C.c, t)
        apply_max(j, -ONE)
    end
    for _, t in ipairs(add_capped) do
        local j = have[t.name] or create_job(C.id, C.c, t)
        local m = fmul(maxes[t.name], ONE + gmult + fx(M[t.max_mult])) + gadd + fx(M[t.max_add])
        apply_max(j, m)
    end
end

-- NPlanetJobs::TryAssignPopsToJob (0x26b4fd0)
local function try_assign(G, j, n)
    local t = j.type
    local m = workforce_mult(G, t)
    if m <= ZERO then return 0 end
    local cap = CAP_UNCAPPED
    if t.capped then
        cap = j.max
        local free = j.limit - j.workforce
        if free <= ZERO then return 0 end
        local need = fdiv(free, m)
        if need < ONE then need = ONE end
        local k = fceil(need)
        if k < n then n = k end
    end
    if n <= 0 then return 0 end
    local found = false
    for _, a in ipairs(j.groups) do
        if a[1] == G.id then a[2] = a[2] + n; found = true; break end
    end
    if not found then j.groups[#j.groups + 1] = { G.id, n } end
    local old = j.workforce
    local w = old + I64(n) * m
    if w > cap then w = cap end
    j.workforce = w
    local b = j.bonus + fmul(w - old, bonus_mult(G, t))
    if b < -w then b = -w end
    j.bonus = b
    return n
end

-- AssignPopsToJobs for one colony (the batch's job index `base` for the reshuffle phase)
local function assign(C, entries_jobs, base, month)
    local d = defines()
    local W = {}            -- the pair entries: { w, amount, g, j, rank, ffs, stay }
    -- the pairs over the groups and the jobs as BuildUpdateData saw them (group-major)
    for gi, G in ipairs(C.groups) do
        for ji, j in ipairs(entries_jobs) do
            W[#W + 1] = { w = -ONE, amount = INT_MAX, g = gi, j = ji, rank = -1, ffs = j.type.first_come, seq = #W }
            W[#W + 1] = { w = -ONE, amount = 0, g = gi, j = ji, rank = -1, ffs = j.type.first_come, seq = #W, stay = true }
        end
    end
    -- the weights (CalculatePopJobWeights lambda 0x26b7a80)
    for i = 1, #W, 2 do
        local e, s = W[i], W[i + 1]
        local G, j = C.groups[e.g], entries_jobs[e.j]
        if not j.dead and is_possible(G, j.type) then
            local t = j.type
            local jc = category(t.category)
            local jrank = jc and jc.rank or 1
            local f = workforce_mult(G, t) + bonus_mult(G, t)
            local w = job_weight(G, t)
            if w >= ZERO then w = power(w, f, d.WEIGHT_POWER) end
            local stay_amount = 0
            for _, a in ipairs(j.groups) do
                if a[1] == G.id then stay_amount = a[2] end
            end
            local stay_w = -ONE
            if stay_amount > 0 then stay_w = fmul(w, jc and jc.threshold or fx(d.CHANGE_THRESHOLD)) end
            e.w = w
            local reshuffle = false
            local interval = jc and jc.reshuffle or 0
            if interval > 0 and (month + base + e.j - 1) % interval == 0 then
                reshuffle = true
                if stay_amount > 0 then s.w, s.amount = w, stay_amount end
            else
                s.w, s.amount = stay_w, stay_amount
            end
            -- a favourite job: both weights x FAVORITE_JOB_WEIGHT_MULT (10) where not negative
            -- (CalculatePopJobWeights $_1 0x26b7d4b)
            if C.favorites[t.category] == t.name then
                if e.w >= ZERO then e.w = e.w * 10 end
                if s.w >= ZERO then s.w = s.w * 10 end
            end
            if reshuffle or s.w >= ZERO then s.rank = jrank end
            local rank = reshuffle and jrank or G.rank
            if e.w >= ZERO then e.rank = rank end
        end
    end
    -- the per-pass reset of the jobs (0x26b5b78): pop groups cleared, the automated workforce
    local M = modifiers("colony", C.id) or {}
    local pdaw = fx(M.district_automated_workforce)
    local bam = fx(M.bonus_automated_workforce_mult)
    for _, j in ipairs(C.jobs) do
        j.groups = {}
        j.pop_group = NONE
        local max_auto = ZERO
        if j.limit > ZERO and j.type.automated then
            local p = fx(M[j.type.auto_mult]) + pdaw
            if p > d.AUTOMATED_MAX then p = d.AUTOMATED_MAX end
            max_auto = fmul(fx(M[j.type.add]), p)
        end
        if max_auto > j.limit then max_auto = j.limit end
        local x = max_auto
        if x > j.auto_limit then x = j.auto_limit end
        j.workforce, j.auto = x, x
        local b = fmul(x, bam)
        if b < -x then b = -x end
        j.bonus = b
    end
    -- the free same-rank capped places per group, its share, the jobs' room (0x26b5d.. D-G)
    local free_same = {}
    for i = 1, #W, 2 do
        local e = W[i]
        local j = entries_jobs[e.j]
        if e.w >= ZERO and not e.ffs and j.type.capped and not j.dead then
            local G = C.groups[e.g]
            local jc = category(j.type.category)
            if jc and jc.rank == G.rank then
                free_same[e.g] = (free_same[e.g] or ZERO) + (j.limit - j.workforce)
            end
        end
    end
    local ratio = {}
    for gi, G in ipairs(C.groups) do
        local f = free_same[gi]
        if f and f > ZERO then
            local r = fdiv(ifx(G.size), f)
            ratio[gi] = r < ONE and r or ONE
        else
            ratio[gi] = ONE
        end
    end
    local remaining = {}
    for ji in ipairs(entries_jobs) do remaining[ji] = INT_MAX end
    for i = 1, #W, 2 do
        local e = W[i]
        local j = entries_jobs[e.j]
        if e.w >= ZERO and not e.ffs and j.type.capped and not j.dead then
            local free = j.limit - j.workforce
            local share = fceil(fmul(free, ratio[e.g]))
            local full = fceil(free)
            local rem = remaining[e.j]
            if rem == INT_MAX then remaining[e.j] = share
            else remaining[e.j] = math.min(rem + share, full) end
        end
    end
    local incumbents = {}
    for i = 2, #W, 2 do
        local s = W[i]
        if s.amount > 0 then incumbents[s.j] = (incumbents[s.j] or 0) + s.amount end
    end
    for ji in ipairs(entries_jobs) do
        local inc = incumbents[ji]
        if remaining[ji] ~= INT_MAX and inc and inc > remaining[ji] then remaining[ji] = inc end
    end
    local left = {}
    for gi, G in ipairs(C.groups) do left[gi] = G.size end
    -- the sort (SortPopJobWeights, stable): valid first, first_come_first_served jobs first, the
    -- higher rank, the higher weight, the smaller amount
    table.sort(W, function(a, b)
        local va, vb = a.rank >= 0, b.rank >= 0
        if va ~= vb then return va end
        if not va then return a.seq < b.seq end
        if a.ffs ~= b.ffs then return a.ffs end
        if a.rank ~= b.rank then return a.rank > b.rank end
        if a.w ~= b.w then return a.w > b.w end
        if a.amount ~= b.amount then return a.amount < b.amount end
        return a.seq < b.seq
    end)
    if DEBUG == C.id then
        for _, e in ipairs(W) do
            if e.rank >= 0 then
                print(string.format("jobs %d: g%d %s rank %d w %s amount %d rem %s left %d", C.id, C.groups[e.g].id,
                    entries_jobs[e.j].type.name, e.rank, tostring(e.w), e.amount, tostring(remaining[e.j]), left[e.g]))
            end
        end
    end
    -- the greedy assignment
    for _, e in ipairs(W) do
        if e.rank < 0 then break end
        local n = math.min(e.amount, left[e.g], remaining[e.j])
        if n > 0 then
            local got = try_assign(C.groups[e.g], entries_jobs[e.j], n)
            e.amount = e.amount - got
            left[e.g] = left[e.g] - got
            remaining[e.j] = remaining[e.j] - got
            jobs.stats.assigned = jobs.stats.assigned + got
        end
    end
    -- the categories (0x26b6fc6): a group's pops in a job of another category move to the group
    -- of the job's category (GROWTH_CAT_PROMOTION), the job's entry pointed at it
    local known = {}
    for _, G in ipairs(C.groups) do known[G.id] = G end
    for _, j in ipairs(C.jobs) do
        local jcat = j.type.category
        if category(jcat) then
            for k = #j.groups, 1, -1 do
                local a = j.groups[k]
                local g = world.object("pop_groups", a[1])
                local sid, gcat = group_key(g)
                local move = true
                if category(gcat) then
                    local G = known[a[1]]
                    if not G then move = false
                    else
                        local cc = category(gcat).can_change
                        local can = cc == true or (type(cc) == "table" and pre_holds(pre_form(cc), G.flags))
                        if not can or gcat == jcat then move = false end
                    end
                end
                if move then
                    local amt = math.min(int(world.field(g, "size")), a[2])
                    local dst = access_or_add(C.id, C.c, sid, jcat, g)
                    pops().move_size(dst, a[1], amt, "GROWTH_CAT_PROMOTION", C.id)
                    table.remove(j.groups, k)
                    local found = false
                    for _, x in ipairs(j.groups) do
                        if x[1] == dst then x[2] = x[2] + amt; found = true; break end
                    end
                    if not found then j.groups[#j.groups + 1] = { dst, amt } end
                    jobs.stats.moved = jobs.stats.moved + amt
                end
            end
        end
    end
    for _, j in ipairs(C.jobs) do
        if not j.dead then write_job(j) end
    end
end

-- jobs.update([colonies]): one NPlanetJobs::UpdatePopJobs pass over the colonies (all, in the
-- store's order, by default)
local function update(cids)
    if jobs.off then return end
    local s = jobs.stats
    s.passes = s.passes + 1
    J = {}
    next_job_index = nil
    local day = eval.today and eval.today() or 0
    if day ~= cache_day or not possible_cache then
        possible_cache, weight_cache, rule_cache, cache_day = {}, {}, {}, day
    end
    if not cids then
        cids = {}
        for _, cid in ipairs(world.all("colony")) do
            if colony_planet(cid) then cids[#cids + 1] = cid end
        end
    end
    local month = total_months()
    local batch = {}
    for _, cid in ipairs(cids) do
        slice.tick("jobs build")
        local C = build(cid)
        if C then batch[#batch + 1] = C end
    end
    for _, C in ipairs(batch) do
        slice.check("jobs collapse")
        collapse(C)
        prepare_groups(C)
    end
    -- the jobs as BuildUpdateData took them, before UpdateAvailableJobs adds and removes
    local base = 0
    for _, C in ipairs(batch) do
        C.entries = {}
        for i, j in ipairs(C.jobs) do C.entries[i] = j end
        C.base = base
        base = base + #C.jobs
    end
    for _, C in ipairs(batch) do
        slice.check("jobs available")
        available(C)
        -- the colony's jobs now (its list's order)
        C.jobs = {}
        for _, jid in ipairs(job_ids(C.c)) do
            local j = load_job(jid)
            if j and j.type then C.jobs[#C.jobs + 1] = j end
        end
    end
    for _, C in ipairs(batch) do
        slice.check("jobs assign")
        assign(C, C.entries, C.base, month)
        s.colony_passes = s.colony_passes + 1
    end
    local economy = package.loaded["engine.economy"]
    if economy and economy.invalidate then economy.invalidate() end
end

function jobs.update(cids)
    pscript = pscript or require("engine.pops.script")
    return pscript.with(update, cids)
end

-- the day's update (MonthlyOrDailyUpdatePopJobsInColony with the daily flag: two passes)
function jobs.daily(host, date)
    if jobs.off then return end
    jobs.update()
    jobs.update()
end

function jobs.report()
    local s = jobs.stats
    local errs = {}
    for k, v in pairs(jobs.errors) do errs[#errs + 1] = k .. ": " .. v:sub(1, 120) end
    table.sort(errs)
    return string.format("jobs: %d passes (%d colony passes); %d jobs created, %d removed; %d pops assigned, %d moved "
        .. "between categories, %d pop groups created, %d collapsed; %d trigger errors, %d rule errors%s",
        s.passes, s.colony_passes, s.created, s.removed, s.assigned, s.moved, s.groups_created, s.collapsed,
        s.trigger_errors, s.rule_errors, #errs > 0 and ("; " .. table.concat(errs, "; ", 1, math.min(#errs, 6))) or "")
end

return jobs
