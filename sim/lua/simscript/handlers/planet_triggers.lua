-- simscript/handlers/planet_triggers.lua : the planet package's triggers (loaded by
-- handlers/planet.lua). [V] read in the 4.5.2 Linux binary's trigger class, [I] inferred;
-- /root/wp/re_script.md on .24 has the notes.

return function(eval, H)
    local I = eval._internal
    local TRIG = eval.TRIG
    local S, NONE, sync, compare, yes = I.S, I.NONE, I.sync, I.compare, I.yes
    local world = H.world
    local ref, unq, ids, params, target = H.ref, H.unq, H.ids, H.params, H.target
    local defs = require("engine.defs")

    local function value_of(e, ctx)
        return eval.value(e.value, ctx, e)
    end
    -- `<trigger> <op> <number>` against v (false without a v)
    local function cmp(v, e, ctx)
        if v == nil then return false end
        return compare(v, e.op, value_of(e, ctx))
    end
    -- a block's `value <op> <number>` against v
    local function cmp_param(v, x, ctx)
        if v == nil or not x then return false end
        return compare(v, x.op, eval.value(x.value, ctx, x))
    end
    local function def(folder, key)
        local d = key and defs.get(folder, key)
        return d and d.block or nil
    end
    local function dfield(block, key)
        return block and defs.field(block, key) or nil
    end
    local function planet(sc)
        local p, pid = H.planet_obj(sc)
        return p, pid
    end
    local function colony(sc)
        return H.colony_obj(sc)
    end
    -- the date as days since 1.1.1 (360-day years)
    local function days_of(text)
        local y, m, d = tostring(text or ""):gsub('"', ""):match("^(%d+)%.(%d+)%.(%d+)")
        if not y then return nil end
        return (tonumber(y) * 12 + tonumber(m) - 1) * 30 + tonumber(d) - 1
    end
    local function today()
        return days_of(world.meta and world.meta.date)
    end
    H.days_of, H.today = days_of, today

    -- -----------------------------------------------------------------------------------------
    -- the planet itself

    -- colony_age <op> months / colony_age_years <op> years (CColonyAgeTrigger): the months (years)
    -- since the planet's `colonize_date`; false without a colony
    local function colony_months(sc)
        local p, pid = planet(sc)
        if not p or not H.colony_of_planet(pid) then return nil end
        local d0, d1 = days_of(world.field(p, "colonize_date")), today()
        if not (d0 and d1) then return nil end
        return math.floor((d1 - d0) / 30)
    end
    TRIG["colony_age"] = function(e, ctx)
        sync()
        return cmp(colony_months(ctx.this), e, ctx)
    end
    TRIG["colony_age_years"] = function(e, ctx)
        sync()
        local m = colony_months(ctx.this)
        return cmp(m and math.floor(m / 12), e, ctx)
    end

    -- colony_type = <key> | <planet scope> (CColonyTypeTrigger): the colony's designation
    -- (`final_designation`), or the same as the target planet's
    TRIG["colony_type"] = function(e, ctx)
        sync()
        local c = colony(ctx.this)
        local t = c and unq(world.field(c, "final_designation"))
        if not t then return false end
        local tgt = target(e, ctx)
        if tgt and tgt.kind == "planet" then
            local c2 = colony(tgt)
            return c2 ~= nil and unq(world.field(c2, "final_designation")) == t
        end
        return t == e.value.text
    end

    -- is_planet = <target> (CIsPlanetTrigger): the scope is the target planet
    TRIG["is_planet"] = function(e, ctx)
        local t = target(e, ctx)
        return t ~= nil and ctx.this ~= NONE and t.kind == "planet" and ctx.this.kind == "planet" and t.id == ctx.this.id
    end

    -- num_deposits <op> n (CNumDepositsTrigger): the planet's deposits
    TRIG["num_deposits"] = function(e, ctx)
        sync()
        local p = planet(ctx.this)
        return cmp(p and #ids(world.field(p, "deposits")), e, ctx)
    end
    -- num_moons <op> n (CNumMoonsTrigger): the planet's `moons`
    TRIG["num_moons"] = function(e, ctx)
        sync()
        local p = planet(ctx.this)
        return cmp(p and #ids(world.field(p, "moons")), e, ctx)
    end

    -- is_primary_star = yes/no (CIsPrimaryStarTrigger): the planet is its system's star (the
    -- system's first planet of a star class)
    TRIG["is_primary_star"] = function(e, ctx)
        sync()
        local p, pid = planet(ctx.this)
        if not p then return false end
        local R = require("engine.script.runtime")
        local sys = R.system_of("planet", pid)
        local star = sys and R.star_planet(sys)
        return (star == pid) == yes(e)
    end
    -- is_ideal = yes/no (CIsIdealTrigger): the planet class's `ideal = yes` (planet_classes)
    TRIG["is_ideal"] = function(e, ctx)
        sync()
        local p = planet(ctx.this)
        if not p then return false end
        local cdef = def("common/planet_classes", unq(world.field(p, "planet_class")))
        return (dfield(cdef, "ideal") == "yes") == yes(e)
    end

    -- has_planet_class = <class> | <planet scope> (a system: CHasPlanetClassTrigger): a planet of
    -- the system is of the class (the target's class)
    TRIG["has_planet_class"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "system" then return false end
        sync()
        local want = e.value.text
        local t = target(e, ctx)
        if t and t.kind == "planet" then
            local tp = world.object("planet", t.id)
            want = tp and unq(world.field(tp, "planet_class"))
        end
        if not want then return false end
        for _, v in ipairs(world.fields(world.object("galactic_object", sc.id), "planet")) do
            local p = world.object("planet", tonumber(v))
            if p and unq(world.field(p, "planet_class")) == want then return true end
        end
        return false
    end

    -- -----------------------------------------------------------------------------------------
    -- the colony's numbers (the colony's own fields: CColony)

    local function colony_num(key)
        return function(e, ctx)
            sync()
            local c = colony(ctx.this)
            return cmp(c and tonumber(world.field(c, key)), e, ctx)
        end
    end
    -- planet_stability, planet_crime <op> n (CPlanetStabilityTrigger, CPlanetCrimeTrigger): the
    -- colony's `stability`, `crime`
    TRIG["planet_stability"] = colony_num("stability")
    TRIG["planet_crime"] = colony_num("crime")
    -- num_housing <op> n (CNumHousingTrigger): the colony's `total_housing`
    TRIG["num_housing"] = colony_num("total_housing")

    -- is_occupied_flag = yes/no (CIsOccupiedFlagTrigger): the planet's controller is not its owner
    TRIG["is_occupied_flag"] = function(e, ctx)
        sync()
        local p = planet(ctx.this)
        if not p or not H.colony_of_planet(H.planet_id(ctx.this)) then return false end
        local o, c = ref(world.field(p, "owner")), ref(world.field(p, "controller"))
        return (o ~= nil and c ~= nil and o ~= c) == yes(e)
    end

    -- -----------------------------------------------------------------------------------------
    -- jobs

    local function job_def(jt)
        return def("common/pop_jobs", jt)
    end
    local function job_of(sc)
        if sc == NONE or sc.kind ~= "job" then return nil end
        return world.object("pop_jobs", sc.id)
    end
    -- has_job_category = <category> (a job: CHasJobCategoryTrigger): the job type's `category`
    TRIG["has_job_category"] = function(e, ctx)
        sync()
        local j = job_of(ctx.this)
        local jd = j and job_def(unq(world.field(j, "type")))
        return jd ~= nil and unq(dfield(jd, "category")) == e.value.text
    end
    -- is_job_of_pop_category = { job category } (CIsJobOfPopCategoryTrigger): the job type's
    -- category, wherever it is used
    TRIG["is_job_of_pop_category"] = function(e, ctx)
        local p = params(e)
        local jt = p.job and p.job.value.text
        local cat = p.category and p.category.value.text
        local jd = job_def(jt)
        return jd ~= nil and cat ~= nil and unq(dfield(jd, "category")) == cat
    end
    -- num_pops_assigned_to_job = { pop_group value } (a job: CNumPopsAssignedToJobTrigger): the
    -- pops working it (its pop_groups' amounts), or the given pop group's
    TRIG["num_pops_assigned_to_job"] = function(e, ctx)
        sync()
        local j = job_of(ctx.this)
        if not j then return false end
        local p = params(e)
        local only
        if p.pop_group and p.pop_group.value.text then
            local found, sc = eval.resolve(p.pop_group.value.text, ctx, p.pop_group)
            only = found and sc and sc ~= NONE and sc.id or -1
        end
        local n = 0
        for _, b in ipairs(world.blocks(world.field(j, "pop_groups"))) do
            if not only or ref(world.field(b, "pop_group")) == only then
                n = n + (tonumber(world.field(b, "amount")) or 0)
            end
        end
        return cmp_param(n, p.value, ctx)
    end
    -- the colony's jobs (the planet's colony's `pop_jobs`)
    local function colony_jobs(sc)
        local c = colony(sc)
        local out = {}
        for _, jid in ipairs(c and ids(world.field(c, "pop_jobs")) or {}) do
            local j = world.object("pop_jobs", jid)
            if j then out[#out + 1] = j end
        end
        return out
    end
    H.colony_jobs = colony_jobs
    -- free_jobs_of_type = { job | category, include_deprioritized_jobs, value } (CFreeJobsOfType):
    -- the colony's jobs of the type (or category): their limit (with deprioritized jobs: their
    -- maximum) less their workforce
    TRIG["free_jobs_of_type"] = function(e, ctx)
        sync()
        local p = params(e)
        local jt = p.job and p.job.value.text
        local cat = p.category and p.category.value.text
        local depr = p.include_deprioritized_jobs and p.include_deprioritized_jobs.value.text == "yes"
        local n = 0
        for _, j in ipairs(colony_jobs(ctx.this)) do
            local t = unq(world.field(j, "type"))
            local match = (jt and t == jt) or (cat and unq(dfield(job_def(t), "category")) == cat)
            if match then
                local wf = tonumber(world.field(j, "workforce")) or 0
                local top = depr and tonumber(world.field(j, "max_workforce")) or tonumber(world.field(j, "workforce_limit"))
                n = n + math.max(0, (top or 0) - wf)
            end
        end
        return cmp_param(n, p.value, ctx)
    end
    -- total_workforce_with_job_tag = { tags = { ... } value } (a colony), total_country_workforce_
    -- with_job_tag (a country): the workforce of jobs whose type has all the tags (`tags`)
    local function has_tags(jt, want)
        local jd = job_def(jt)
        local tags = {}
        local tb = dfield(jd, "tags")
        for _, x in ipairs(type(tb) == "table" and tb or {}) do
            if x.text then tags[unq(x.text)] = true end
        end
        for _, w in ipairs(want) do
            if not tags[w] then return false end
        end
        return #want > 0
    end
    local function tag_list(p)
        local out = {}
        local tb = p.tags and p.tags.value
        for _, x in ipairs(type(tb) == "table" and tb.text == nil and tb or {}) do
            if x.text then out[#out + 1] = unq(x.text) end
        end
        return out
    end
    local function workforce_with_tags(pids, want)
        local n = 0
        for _, pid in ipairs(pids) do
            for _, j in ipairs(colony_jobs(S("planet", pid))) do
                if has_tags(unq(world.field(j, "type")), want) then
                    n = n + (tonumber(world.field(j, "workforce")) or 0)
                end
            end
        end
        return n
    end
    TRIG["total_workforce_with_job_tag"] = function(e, ctx)
        sync()
        local pid = H.planet_id(ctx.this)
        if not pid then return false end
        local p = params(e)
        return cmp_param(workforce_with_tags({ pid }, tag_list(p)), p.value, ctx)
    end
    TRIG["total_country_workforce_with_job_tag"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "country" then return false end
        sync()
        local p = params(e)
        return cmp_param(workforce_with_tags(H.colonies_under(sc), tag_list(p)), p.value, ctx)
    end

    -- -----------------------------------------------------------------------------------------
    -- the game's own state the simulation does not show

    -- is_paused, is_on_galaxy_map (the player's client: paused, viewing the galaxy map): the
    -- simulation runs its scripts unpaused and has no map view; false [I]
    TRIG["is_paused"] = function(e) return not yes(e) end
    TRIG["is_on_galaxy_map"] = function(e) return not yes(e) end

    -- is_scope_set = <target> (CIsScopeSetTrigger): the target resolves to an object
    TRIG["is_scope_set"] = function(e, ctx)
        if not e.value.text then return false end
        local found, sc = eval.resolve(e.value.text, ctx, e)
        return found and sc ~= nil and sc ~= NONE
    end
    -- is_valid = yes/no (a planet, country or army: CIsValidTrigger): the scope's object exists
    TRIG["is_valid"] = function(e, ctx)
        local sc = ctx.this
        local store = sc ~= NONE and ({ planet = "planet", country = "country", army = "army" })[sc.kind]
        local ok = store ~= nil and world.object(store, sc.id) ~= nil
        return ok == yes(e)
    end
end
