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
    -- while a trigger runs as a value (TVAL, below), the number it would compare is kept here: its
    -- own comparison is the one without a number (the parameters block has no `value`); the
    -- triggers it runs inside (a `limit`) compare as usual
    local capture
    local function cmp(v, e, ctx)
        if capture and type(e.value) == "table" and e.value.text == nil then capture.v = v return true end
        if v == nil then return false end
        return compare(v, e.op, value_of(e, ctx))
    end
    -- a block's `value <op> <number>` against v
    local function cmp_param(v, x, ctx)
        if capture and not x then capture.v = v return true end
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
    -- as a value (`trigger:num_moons`, an anomaly's spawn_chance): the count; not a planet: 0
    eval.TVAL["num_moons"] = function(ctx)
        sync()
        local p = planet(ctx.this)
        return p and #ids(world.field(p, "moons")) or 0
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
    -- -----------------------------------------------------------------------------------------
    -- the second batch (the notes: /root/wp/re4/part_t1..t3.md on .24)

    local NO_ID = H.NO_ID
    local function flags_of(p)
        return tonumber(world.field(p, "binary_flags")) or 0
    end
    -- a bit of the planet's flag word (CPlanet +0xcb4, saved as `binary_flags`): bit 6 deploy
    -- armies in orbit, bit 8 has a ring (+0xcb5 bit 0), bit 11 terraformed (+0xcb5 bit 3) [V the
    -- bits; I the save key: bit 6 is set on nearly every planet of the 2210 save]
    local function planet_bit(p, bit)
        return math.floor(flags_of(p) / 2 ^ bit) % 2 == 1
    end
    H.planet_bit = planet_bit

    -- has_ring = yes/no (CHasRingTrigger): bit 8; another scope: true iff `= no`
    TRIG["has_ring"] = function(e, ctx)
        sync()
        local p = planet(ctx.this)
        if not p then return not yes(e) end
        return planet_bit(p, 8) == yes(e)
    end
    -- is_terraformed = yes/no (CIsTerraformedTrigger): bit 11; another scope false
    TRIG["is_terraformed"] = function(e, ctx)
        sync()
        local p = planet(ctx.this)
        if not p then return false end
        return planet_bit(p, 11) == yes(e)
    end
    -- terraformed_by = <country> (CIsTerraformedByTrigger): the planet's `terraformed_by` [I key]
    TRIG["terraformed_by"] = function(e, ctx)
        sync()
        local p = planet(ctx.this)
        local t = target(e, ctx)
        if not p or not t or t.kind ~= "country" then return false end
        return ref(world.field(p, "terraformed_by")) == t.id
    end
    -- is_scripted_terraforming = yes/no (CIsScriptedTerraformingTrigger): a terraform process on
    -- the planet (its `terraform_process`, engine/construction_planet.lua)
    TRIG["is_scripted_terraforming"] = function(e, ctx)
        sync()
        local p = planet(ctx.this)
        local on = p ~= nil and type(world.field(p, "terraform_process")) == "table"
        return on == yes(e)
    end

    -- is_in_cluster = <cluster> (CBelongsToClusterTrigger): the system's (a planet's system's)
    -- spawning cluster (`cluster` [I key])
    TRIG["is_in_cluster"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or not e.value.text then return false end
        sync()
        local sys = sc.kind == "system" and sc.id
        if sc.kind == "planet" then sys = require("engine.script.runtime").system_of("planet", sc.id) end
        local g = sys and world.object("galactic_object", sys)
        if not g then return false end
        for _, x in ipairs(world.fields(g, "cluster")) do
            if unq(x) == e.value.text then return true end
        end
        local cl = world.field(g, "cluster")
        return type(cl) == "table" and unq(world.field(cl, "id")) == e.value.text
    end

    -- free_building_slots <op> n (CFreeBuildingSlotsTrigger): over the colony's districts' zones,
    -- the zone's max buildings less its buildings (no colony: 0)
    local function zone_max(zb, d)
        local zd = def("common/zones", unq(world.field(zb, "type")))
        local max = tonumber(dfield(zd, "max_buildings")) or 3
        local per = tonumber(dfield(zd, "districts_per_building"))
        if per and per > 0 then
            max = math.min(max, math.floor((tonumber(world.field(d, "level")) or 0) / per))
        end
        return max
    end
    TRIG["free_building_slots"] = function(e, ctx)
        sync()
        local c = colony(ctx.this)
        local n = 0
        for _, did in ipairs(c and ids(world.field(c, "districts")) or {}) do
            local d = world.object("districts", did)
            for _, z in ipairs(ids(d and world.field(d, "zones"))) do
                local zb = world.object("zones", z)
                if zb then n = n + zone_max(zb, d) - #ids(world.field(zb, "buildings")) end
            end
        end
        return cmp(n, e, ctx)
    end

    -- has_building_construction = yes/no | <building> (CHasBuildingConstructionTrigger): the
    -- planet's build queue holds a building or district item; with a type, a building of it
    TRIG["has_building_construction"] = function(e, ctx)
        sync()
        local p = planet(ctx.this)
        if not p or not colony(ctx.this) then return false end
        local q = world.object("construction.queue_mgr.queues", ref(world.field(p, "build_queue")))
        local v = e.value.text
        local found = false
        for _, iid in ipairs(q and ids(world.field(q, "items")) or {}) do
            local item = world.object("construction.item_mgr.items", iid)
            for k, b in world.statements(item or {}) do
                if k == "buildable_district" or k == "buildable_planet_building" or k == "buildable_planet_upgrade_building" then
                    if v == "yes" or v == "no" then
                        found = true
                    elseif k ~= "buildable_district" and unq(world.field(b, "building")) == v then
                        found = true
                    end
                end
            end
        end
        if v == "no" then return not found end
        return found
    end

    -- num_unemployed <op> n (CNumUnemployedTrigger): the colony's `unemploy_pop` (a country: its
    -- colonies' sum)
    TRIG["num_unemployed"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE then return false end
        sync()
        local pids = sc.kind == "country" and H.colonies_under(sc) or (H.planet_id(sc) and { H.planet_id(sc) })
        if not pids then return false end
        local n = 0
        for _, pid in ipairs(pids) do
            local c = world.object("colony", H.colony_of_planet(pid))
            n = n + (c and tonumber(world.field(c, "unemploy_pop")) or 0)
        end
        return cmp(n, e, ctx)
    end
    -- num_housing truncates (CFixedPoint / 100000)
    TRIG["num_housing"] = function(e, ctx)
        sync()
        local c = colony(ctx.this)
        local v = c and tonumber(world.field(c, "total_housing"))
        return cmp(v and (v >= 0 and math.floor(v) or -math.floor(-v)), e, ctx)
    end

    -- num_physics / num_society / num_engineering <op> n (CNumPhysicsTrigger ...): the carrier's
    -- deposits' resources of that research (CDepositHolder::GetNumResources)
    local function deposit_resource(sc, res)
        local p = planet(sc)
        if not p then return nil end
        local R = require("engine.script.runtime")
        local n = 0
        for _, did in ipairs(ids(world.field(p, "deposits"))) do
            local key = R.deposit_type and R.deposit_type(did)
            local dd = key and def("common/deposits", key)
            local resb = dd and dfield(dd, "resources")
            for _, pb in ipairs(type(resb) == "table" and resb or {}) do
                if pb.op and pb.key and pb.key.text == "produces" and type(pb.value) == "table" then
                    local v = tonumber(defs.field(pb.value, res))
                    if v then n = n + v end
                end
            end
        end
        return n
    end
    for k, res in pairs({ num_physics = "physics_research", num_society = "society_research", num_engineering = "engineering_research" }) do
        TRIG[k] = function(e, ctx)
            sync()
            return cmp(deposit_resource(ctx.this, res), e, ctx)
        end
    end

    -- planet_garrison_strength <op> n (CPlanetGarrisonStrengthTrigger): CColony::CalcArmyPowerFor
    -- the carrier's controller: its armies' power on the colony (health x damage [I the formula:
    -- the planet view's army power])
    TRIG["planet_garrison_strength"] = function(e, ctx)
        sync()
        local c, cid, pid = colony(ctx.this)
        if not c then return false end
        local p = world.object("planet", pid)
        local ctl = ref(world.field(p, "controller")) or ref(world.field(p, "owner"))
        local n = 0
        for _, aid in ipairs(ids(world.field(c, "army"))) do
            local a = world.object("army", aid)
            if a and ref(world.field(a, "owner")) == ctl then
                local ad = def("common/armies", unq(world.field(a, "type")))
                local dmg = tonumber(dfield(ad, "damage")) or 1
                n = n + (tonumber(world.field(a, "health")) or 0) * dmg / 100 * (tonumber(world.field(a, "morale")) or 100) / 100
            end
        end
        return cmp(n, e, ctx)
    end

    -- a pop group has happiness (CPopGroup::HasHappiness: its category's `has_happiness` [I]; the
    -- save keeps `happiness` for those that have it)
    local function has_happiness(g)
        return world.field(g, "happiness") ~= nil
    end
    -- happiness_planet <op> f (CPlanetHappinessTrigger): the size-weighted happiness of the colony's
    -- pop groups that have one (0 without)
    local function avg_happiness(pid)
        local total, sum = 0, 0
        for _, gid in ipairs(I.E.pop_groups(pid)) do
            local g = world.object("pop_groups", gid)
            if g and has_happiness(g) then
                local size = tonumber(world.field(g, "size")) or 0
                total = total + size
                sum = sum + size * (tonumber(world.field(g, "happiness")) or 0)
            end
        end
        return sum / math.max(1, total)
    end
    TRIG["happiness_planet"] = function(e, ctx)
        sync()
        local c, _, pid = colony(ctx.this)
        if not c then return false end
        return cmp(avg_happiness(pid), e, ctx)
    end
    -- planet_happiness_above_threshold = { threshold limit value } (a planet: its happiness less
    -- the threshold; a system: the sum over its colonies (those passing `limit`) of
    -- max(0, happiness - threshold))
    TRIG["planet_happiness_above_threshold"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE then return false end
        sync()
        local p = params(e)
        local th = p.threshold and eval.value(p.threshold.value, ctx, p.threshold) or 0
        local v
        if sc.kind == "planet" then
            if not colony(sc) then return false end
            v = avg_happiness(sc.id) - th
        elseif sc.kind == "system" then
            v = 0
            for _, pid in ipairs(H.colonies_under(sc)) do
                if not p.limit or eval.trigger(p.limit.value, eval.push(ctx, S("planet", pid))) then
                    v = v + math.max(0, avg_happiness(pid) - th)
                end
            end
        else
            return false
        end
        return cmp_param(v, p.value, ctx)
    end
    -- pop_group_crime <op> f (CPopGroupCrimeTrigger): a pop group's `crime`; a planet: its pop
    -- groups' sum
    TRIG["pop_group_crime"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE then return false end
        sync()
        if sc.kind == "pop_group" then
            local g = world.object("pop_groups", sc.id)
            return cmp(g and tonumber(world.field(g, "crime")) or 0, e, ctx)
        elseif sc.kind == "planet" then
            local n = 0
            for _, gid in ipairs(I.E.pop_groups(sc.id)) do
                local g = world.object("pop_groups", gid)
                n = n + (g and tonumber(world.field(g, "crime")) or 0)
            end
            return cmp(n, e, ctx)
        end
        return false
    end
    -- pop_group_has_happiness = yes/no (CPopGroupHasHappinessTrigger)
    TRIG["pop_group_has_happiness"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "pop_group" then return false end
        sync()
        local g = world.object("pop_groups", sc.id)
        return (g ~= nil and has_happiness(g)) == yes(e)
    end
    -- has_civilian_job_category = yes/no (CHasCivilianJobCategory, a pop group or a job): the
    -- category's `is_civilian` (pop_categories) [I key]; neither: true iff `= no`
    local function is_civilian_cat(cat)
        local cd = def("common/pop_categories", cat)
        return dfield(cd, "is_civilian") == "yes" or dfield(cd, "is_unemployment") == "yes"
    end
    TRIG["has_civilian_job_category"] = function(e, ctx)
        local sc = ctx.this
        sync()
        local cat
        if sc ~= NONE and sc.kind == "pop_group" then
            local g = world.object("pop_groups", sc.id)
            cat = g and unq(world.path(g, "key", "category"))
        elseif sc ~= NONE and sc.kind == "job" then
            local j = world.object("pop_jobs", sc.id)
            cat = j and unq(dfield(def("common/pop_jobs", unq(world.field(j, "type"))), "category"))
        end
        if not cat then return not yes(e) end
        return is_civilian_cat(cat) == yes(e)
    end

    -- habitability = { who value } (CHabitabilityTrigger): the planet's habitability for the
    -- target pop group (its `habitability` on its own planet; else its species') or species
    -- (engine.fleets.colonize.habitability)
    local colonize_ok, colonize = pcall(require, "engine.fleets.colonize")
    TRIG["habitability"] = function(e, ctx)
        sync()
        local p, pid = planet(ctx.this)
        if not p then return false end
        local pr = params(e)
        local who = pr.who and pr.who.value.text and select(2, eval.resolve(pr.who.value.text, ctx, pr.who))
        if not who or who == NONE then return false end
        local sp = who.kind == "species" and who.id or (I.E.species_of and I.E.species_of(who.kind, who.id))
        local v = sp and colonize_ok and colonize.habitability(sp, pid) or 0
        return cmp_param(v, pr.value, ctx)
    end
    -- can_live_on_planet = <planet> (CCanLiveOnPlanetTrigger, a pop, pop group or species):
    -- CPlanet::SpeciesCanLive: the species' habitability there above 0 [I]
    TRIG["can_live_on_planet"] = function(e, ctx)
        sync()
        local t = target(e, ctx)
        if not t or t.kind ~= "planet" then return false end
        local sc = ctx.this
        local sp = sc.kind == "species" and sc.id or (I.E.species_of and I.E.species_of(sc.kind, sc.id))
        return sp ~= nil and colonize_ok and colonize.habitability(sp, t.id) > 0
    end
    -- can_colonize = { who status } (CCanColonizeTrigger): CPlanet::CanColonize(who): not owned,
    -- colonizable, inside the country's borders, a species of it can live there [I the tests:
    -- engine.fleets.colonize.check's]
    TRIG["can_colonize"] = function(e, ctx)
        sync()
        local p, pid = planet(ctx.this)
        local pr = params(e)
        local who = pr.who and pr.who.value.text and select(2, eval.resolve(pr.who.value.text, ctx, pr.who))
        if not p or not who or who == NONE or who.kind ~= "country" then return false end
        local ok = ref(world.field(p, "owner")) == nil
        local okst, st = pcall(require, "engine.fleets.stations")
        if ok and okst and st.colonizable then ok = st.colonizable(pid) and true or false end
        local sys = tonumber(world.path(p, "coordinate", "origin"))
        if ok then ok = world.system_owner and world.system_owner[sys] == who.id end
        if ok then
            local sp = I.E.founder_species and I.E.founder_species(who.id)
            ok = sp ~= nil and colonize_ok and colonize.habitability(sp, pid) > 0
        end
        local status = not pr.status or pr.status.value.text ~= "no"
        return ok == status
    end
    -- controlled_colonizable <op> n (CColonizableControlled): the planets of the country's
    -- controlled systems without a colony that can be colonized
    TRIG["controlled_colonizable"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "country" then return false end
        sync()
        local okst, st = pcall(require, "engine.fleets.stations")
        local n = 0
        -- (the controlled systems: engine.world's system_owner)
        local systems = {}
        for sys, owner in pairs(world.system_owner or {}) do
            if owner == sc.id then systems[#systems + 1] = sys end
        end
        table.sort(systems)
        for _, sys in ipairs(systems) do
            for _, pid in ipairs(I.E.system_planets(sys)) do
                if not H.colony_of_planet(pid) and okst and st.colonizable and st.colonizable(pid) then n = n + 1 end
            end
        end
        return cmp(n, e, ctx)
    end
    -- can_work_specific_job = <job> (CCanWorkSpecificJobTrigger, a pop group): CPopGroup::
    -- CanWorkJob: the job's category is one the group's category can fill (`can_fill_<cat>_job`)
    -- and the job's possible triggers hold [I: the category test here]
    TRIG["can_work_specific_job"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "pop_group" or not e.value.text then return false end
        sync()
        local g = world.object("pop_groups", sc.id)
        local jd = def("common/pop_jobs", e.value.text)
        if not g or not jd then return false end
        local cat = unq(dfield(jd, "category"))
        return cat ~= nil and world.field(g, "can_fill_" .. cat .. "_job") == "yes"
    end

    -- has_ethos = <target> (a country or pop group: CHasEthosTrigger): every ethic of the target's
    -- is the scope's
    local function ethics_of(sc)
        local out = {}
        if sc.kind == "country" then
            for _, v in ipairs(world.list(world.path(world.object("country", sc.id), "ethos", "ethics"))) do out[unq(v)] = true end
        elseif sc.kind == "pop_group" then
            for _, v in ipairs(world.list(world.path(world.object("pop_groups", sc.id), "ethos", "ethics"))) do out[unq(v)] = true end
        else
            return nil
        end
        return out
    end
    TRIG["has_ethos"] = function(e, ctx)
        sync()
        local mine = ctx.this ~= NONE and ethics_of(ctx.this)
        local t = target(e, ctx)
        local theirs = t and ethics_of(t)
        if not mine or not theirs then return false end
        for k in pairs(theirs) do
            if not mine[k] then return false end
        end
        return true
    end
    -- ethos (deprecated; pop_ethics_divergence) <op> f (CPopEthicsDivergenceTrigger): the share of
    -- the colony's pops (by their ethos' pop counts) not of the owner's ethics; no pops: false
    TRIG["ethos"] = function(e, ctx)
        sync()
        local p, pid = planet(ctx.this)
        if not p or not colony(ctx.this) then return false end
        local owner = ref(world.field(p, "owner"))
        local oe = owner and ethics_of(S("country", owner)) or {}
        local function base(x) return (x:gsub("^ethic_fanatic_", "ethic_")) end
        local own = {}
        for k in pairs(oe) do own[base(k)] = true end
        local total, matched = 0, 0
        for _, gid in ipairs(I.E.pop_groups(pid)) do
            local g = world.object("pop_groups", gid)
            if g then
                total = total + (tonumber(world.field(g, "size")) or 0)
                local names = world.list(world.path(g, "ethos", "ethics"))
                local counts = world.list(world.path(g, "ethos", "pops"))
                for i, nm in ipairs(names) do
                    if own[base(unq(nm))] then matched = matched + (tonumber(counts[i]) or 0) end
                end
            end
        end
        if total <= 0 then return false end
        return cmp((total - matched) / total, e, ctx)
    end

    -- has_holding = { holding owner } (CHasHoldingTrigger): the colony has a building of the type
    -- owned by `owner` (any / none: any holding of it) (a holding: a building with `owner`)
    local function holdings(c, owner)
        local out = {}
        for _, b in ipairs(H.buildings and H.buildings(c) or {}) do
            if ref(world.field(b.block, "owner")) == owner then out[#out + 1] = unq(world.field(b.block, "type")) end
        end
        return out
    end
    H.holdings = holdings
    TRIG["has_holding"] = function(e, ctx)
        sync()
        local c = colony(ctx.this)
        local pr = params(e)
        local who = pr.owner and pr.owner.value.text and select(2, eval.resolve(pr.owner.value.text, ctx, pr.owner))
        if not c or not who or who == NONE or who.kind ~= "country" then return false end
        local h = holdings(c, who.id)
        local want = pr.holding and pr.holding.value.text or "any"
        if want == "any" then return #h > 0 end
        if want == "none" then return #h == 0 end
        for _, t in ipairs(h) do
            if t == want then return true end
        end
        return false
    end
    -- branch_office_value = { who value } (CBranchOfficeValueTrigger): CColony::
    -- CalcBranchOfficeValue: the colony's pops' share of the value [I: its pops / 100 here]
    TRIG["branch_office_value"] = function(e, ctx)
        sync()
        local c = colony(ctx.this)
        local pr = params(e)
        local who = pr.who and pr.who.value.text and select(2, eval.resolve(pr.who.value.text, ctx, pr.who))
        if not c or not who or who == NONE or who.kind ~= "country" then return false end
        return cmp_param((tonumber(world.field(c, "num_sapient_pops")) or 0) / 100, pr.value, ctx)
    end
    -- free_branch_office_building_slots <op> n: the branch office's max buildings (the planet's
    -- pops: one a 400 [I]) less its owner's buildings there
    TRIG["free_branch_office_building_slots"] = function(e, ctx)
        sync()
        local c, _, pid = colony(ctx.this)
        local owner = pid and I.E.branch_office_owner and I.E.branch_office_owner("planet", pid)
        if not c or not owner then return cmp(0, e, ctx) end
        local max = math.floor((tonumber(world.field(c, "num_sapient_pops")) or 0) / 400)
        return cmp(max - #holdings(c, owner), e, ctx)
    end

    -- num_taken_planets = { target value } (CNumTakenPlanetsTrigger): the target's relation
    -- towards the scope country's `conquered_planets` [I the relation's key]
    TRIG["num_taken_planets"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "country" then return false end
        sync()
        local pr = params(e)
        local t = pr.target and pr.target.value.text and select(2, eval.resolve(pr.target.value.text, ctx, pr.target))
        if not t or t == NONE or t.kind ~= "country" then return false end
        local rel = I.E.relation and I.E.relation(t.id, sc.id)
        local n = rel and tonumber(world.field(rel, "conquered_planets")) or 0
        return cmp_param(n, pr.value, ctx)
    end
    -- ai_terraform_plans <op> n (CAITerraformPlans): the AI's terraform plans; the simulation's AI
    -- makes none: 0 for an AI country, no value (false) for a player [I]
    TRIG["ai_terraform_plans"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "country" then return false end
        local pl = world.meta and world.meta.player
        for _, b in ipairs(type(pl) == "table" and world.blocks(pl) or {}) do
            if tonumber(world.field(b, "country")) == sc.id then return false end
        end
        return cmp(0, e, ctx)
    end
    -- num_storm_exploitation_buildings <op> n: the storm_resistant_mines / _generator / _farm
    -- buildings and their advanced_ variants on the colony (a country: its colonies)
    local STORM = {}
    for _, b in ipairs({ "storm_resistant_mines", "storm_resistant_generator", "storm_resistant_farm" }) do
        STORM["building_" .. b] = true
        STORM["building_advanced_" .. b] = true
    end
    TRIG["num_storm_exploitation_buildings"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE then return false end
        sync()
        local n = 0
        local pids = sc.kind == "country" and H.colonies_under(sc) or (H.planet_id(sc) and { H.planet_id(sc) } or {})
        for _, pid in ipairs(pids) do
            local c = world.object("colony", H.colony_of_planet(pid))
            for _, b in ipairs(c and H.buildings and H.buildings(c) or {}) do
                local t = unq(world.field(b.block, "type"))
                if STORM[t] or STORM["building_" .. tostring(t)] then n = n + 1 end
            end
        end
        return cmp(n, e, ctx)
    end
    -- check_economic_production_modifier_for_job = { job resource species_modifiers_only value }
    -- (CCheckEconomicModifierValueTrigger): the colony's job's economic mult modifiers for the
    -- resource(s): 1 + the modifier `planet_jobs_<resource>_produces_mult` [I the modifiers read]
    TRIG["check_economic_production_modifier_for_job"] = function(e, ctx)
        sync()
        local c, cid, pid = colony(ctx.this)
        if ctx.this ~= NONE and ctx.this.kind == "pop_group" then
            local g = world.object("pop_groups", ctx.this.id)
            cid = g and ref(world.field(g, "planet"))
        end
        if not cid then return false end
        local pr = params(e)
        local M = I.E.modifier and function(k) return tonumber(I.E.modifier("colony", cid, k)) or 0 end or function() return 0 end
        local v
        if pr.resource and pr.resource.value.text then
            v = 1 + M("planet_jobs_" .. pr.resource.value.text .. "_produces_mult")
        elseif pr.resource then
            v = 0
            for _, x in ipairs(pr.resource.value) do
                if x.op and x.key then
                    v = v + (1 + M("planet_jobs_" .. x.key.text .. "_produces_mult")) * (tonumber(x.value.text) or 0)
                end
            end
        end
        return cmp_param(v, pr.value, ctx)
    end
    -- has_picked_auto_mod_habitability = yes/no (a pop group): its species has an auto-mod
    -- habitability trait (`trait_auto_hab_*`) [I]
    TRIG["has_picked_auto_mod_habitability"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "pop_group" then return false end
        sync()
        local sp = I.E.species_of and I.E.species_of("pop_group", sc.id)
        local s = sp and world.object("species", sp)
        local got = false
        for _, t in ipairs(s and world.fields(world.field(s, "traits"), "trait") or {}) do
            if tostring(unq(t)):match("^trait_auto_mod_") then got = true end
        end
        return got == yes(e)
    end

    -- has_colonization_control = { type country } (a pop group, leader or species): the
    -- country's species rights for the species: `type = <x>` the current colonization_control
    -- is it; a bool: the species cannot colonize (colonization_control_yes)
    local function species_of_scope(sc)
        if sc.kind == "species" then return sc.id end
        return I.E.species_of and I.E.species_of(sc.kind, sc.id)
    end
    local function rights_country(pr, ctx)
        if pr.country and pr.country.value.text then
            local _, t = eval.resolve(pr.country.value.text, ctx, pr.country)
            return t and t ~= NONE and t.kind == "country" and t.id or nil
        end
        local _, o = eval.resolve("owner", ctx, nil)
        return o and o ~= NONE and o.kind == "country" and o.id or nil
    end
    TRIG["has_colonization_control"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE then return false end
        sync()
        local pr = params(e)
        local sp, c = species_of_scope(sc), rights_country(pr, ctx)
        if not sp or not c or not I.E.species_right then return false end
        local cur = I.E.species_right(c, sp, "colonization_control")
        local v = pr.type and pr.type.value.text
        if v == "yes" or v == "no" then
            return (cur == "colonization_control_yes") == (v == "yes")
        end
        return cur == v
    end
    -- former_colonization_control_type = <type> (a pop group): the owner's species rights'
    -- former colonization control (`former_colonization_control`)
    TRIG["former_colonization_control_type"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "pop_group" or not e.value.text then return false end
        sync()
        local sp = species_of_scope(sc)
        local _, o = eval.resolve("owner", ctx, nil)
        if not sp or not o or o == NONE or not I.E.species_right then return false end
        return I.E.species_right(o.id, sp, "former_colonization_control") == e.value.text
    end

    -- has_background_job = <job> | yes (a leader: CHasBackgroundJobTrigger): the leader's
    -- background job (`job`, the leader's save key for it) is the job; yes: any
    TRIG["has_background_job"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "leader" or not e.value.text then return false end
        sync()
        local j = unq(world.field(world.object("leader", sc.id), "job"))
        if e.value.text == "yes" then return j ~= nil end
        return j == e.value.text
    end
    -- is_background_planet = <planet | colony> (a leader): its background_planet's colony is the
    -- target's
    TRIG["is_background_planet"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "leader" then return false end
        sync()
        local t = target(e, ctx)
        local bp = H.carrier_ref(world.field(world.object("leader", sc.id), "background_planet"))
        if not t or t.kind ~= "planet" or not bp then return false end
        local c1, c2 = H.colony_of_planet(bp), H.colony_of_planet(t.id)
        return c1 ~= nil and c1 == c2
    end
    -- is_last_building_changed_capital = yes/no (a colony): its last changed building
    -- (`last_building_changed` [I key]) is a capital building; none: false
    TRIG["is_last_building_changed_capital"] = function(e, ctx)
        sync()
        local c = colony(ctx.this)
        local t = c and unq(world.field(c, "last_building_changed"))
        if not t then return false end
        return (dfield(def("common/buildings", t), "capital") == "yes") == yes(e)
    end
    -- is_custom_capital_location = yes/no (a planet, ship, fleet or system): the owner's (a
    -- ship's, fleet's: controller's) `custom_capital_location = { type id }` is the scope [I key]
    TRIG["is_custom_capital_location"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE then return false end
        sync()
        local _, o = eval.resolve(sc.kind == "planet" and "owner" or "controller", ctx, nil)
        if sc.kind == "system" then
            local so = world.system_owner and world.system_owner[sc.id]
            o = so and S("country", so)
        end
        if not o or o == NONE then return false end
        local loc = world.field(world.object("country", o.id), "custom_capital_location")
        local at = type(loc) == "table" and unq(world.field(loc, "type")) == sc.kind and ref(world.field(loc, "id")) == sc.id
        return (at and true or false) == yes(e)
    end

    -- points of interest: a country's `points_of_interest = { { id event_chain name desc
    -- location = { type id } } }` [I key], made by create_point_of_interest
    local function pois(country)
        return world.blocks(world.field(world.object("country", country), "points_of_interest"))
    end
    H.pois = pois
    local function scope_country(ctx)
        local sc = ctx.this
        if sc == NONE then return nil end
        if sc.kind == "country" then return sc.id end
        local _, o = eval.resolve("owner", ctx, nil)
        return o and o ~= NONE and o.kind == "country" and o.id or nil
    end
    H.scope_country = scope_country
    -- has_point_of_interest = { poi } (CHasPointOfInterestedTrigger): the scope's country has a
    -- point of interest of the id
    TRIG["has_point_of_interest"] = function(e, ctx)
        sync()
        local c = scope_country(ctx)
        local pr = params(e)
        local id = pr.poi and pr.poi.value.text
        if not c or not id then return false end
        for _, b in ipairs(pois(c)) do
            if unq(world.field(b, "id")) == id then return true end
        end
        return false
    end
    -- is_point_of_interest = { owner id event_chain } (CIsPointOfInterestedTrigger): a point of
    -- interest of the owner (matching id and event chain when given) located at the scope
    TRIG["is_point_of_interest"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE then return false end
        sync()
        local pr = params(e)
        local o = pr.owner and pr.owner.value.text and select(2, eval.resolve(pr.owner.value.text, ctx, pr.owner))
        if not o or o == NONE or o.kind ~= "country" then return false end
        local id = pr.id and pr.id.value.text
        local chain = pr.event_chain and pr.event_chain.value.text
        for _, b in ipairs(pois(o.id)) do
            local loc = world.field(b, "location")
            if (not id or unq(world.field(b, "id")) == id) and (not chain or unq(world.field(b, "event_chain")) == chain)
                and type(loc) == "table" and unq(world.field(loc, "type")) == sc.kind and ref(world.field(loc, "id")) == sc.id then
                return true
            end
        end
        return false
    end

    -- is_being_surveyed = { who } (CIsBeingSurveyedTrigger): another fleet of the fleet's
    -- controller has a survey order on the planet (`survey_planet_order` [I key])
    TRIG["is_being_surveyed"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "planet" then return false end
        sync()
        local pr = params(e)
        local who = pr.who and pr.who.value.text and select(2, eval.resolve(pr.who.value.text, ctx, pr.who))
        if not who or who == NONE or who.kind ~= "fleet" then return false end
        local owner = world.fleet_owner and world.fleet_owner[who.id]
        for _, fid in ipairs(world.all("fleet")) do
            if fid ~= who.id and world.fleet_owner and world.fleet_owner[fid] == owner then
                local f = world.object("fleet", fid)
                for _, ob in ipairs(world.blocks(world.path(f, "fleet_actions") or world.field(f, "orders"))) do
                    local sv = world.field(ob, "survey_planet_order")
                    if type(sv) == "table" and ref(world.field(sv, "planet")) == sc.id then return true end
                end
            end
        end
        return false
    end
    -- is_capitals_connected_through_relay_network = <country>: the relation's capitals connected
    -- by hyper relays (the relation's `relay_network = yes` [I key])
    TRIG["is_capitals_connected_through_relay_network"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "country" then return false end
        sync()
        local t = target(e, ctx)
        if not t or t.kind ~= "country" then return false end
        local rel = I.E.relation and I.E.relation(sc.id, t.id)
        return rel ~= nil and world.field(rel, "relay_network") == "yes"
    end
    -- is_in_sensor_range_of_country = <country> (CInSensorRangeOfCountryTrigger): the planet's or
    -- system's system in the country's sensor range (a system it owns or has a station in [I]);
    -- a fleet or ship: in such a system
    TRIG["is_in_sensor_range_of_country"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE then return false end
        sync()
        local t = target(e, ctx)
        if not t or t.kind ~= "country" then return false end
        local R = require("engine.script.runtime")
        local sys = sc.kind == "system" and sc.id or (R.system_of and R.system_of(sc.kind, sc.id))
        if not sys then return false end
        for _, s in ipairs(I.E.systems_within_border and I.E.systems_within_border(t.id) or {}) do
            if s == sys then return true end
        end
        return false
    end
    -- valid_planet_killer_target = <planet> (a fleet: CDestroyPlanetFleetOrder::IsPossible): the
    -- fleet has a planet killer weapon and the planet is not a star [I the tests]
    TRIG["valid_planet_killer_target"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "fleet" then return false end
        sync()
        local t = target(e, ctx)
        if not t or t.kind ~= "planet" then return false end
        local R = require("engine.script.runtime")
        if R.planet_class_flag and R.planet_class_flag(t.id, "star") then return false end
        for _, sh in ipairs(R.fleet_ships(sc.id) or {}) do
            local s = world.object("ships", sh)
            local d = s and world.object("ship_design", ref(world.field(s, "ship_design")))
            for _, sec in ipairs(d and world.blocks(world.field(d, "section")) or {}) do
                for _, cmp2 in ipairs(world.blocks(world.field(sec, "component"))) do
                    if tostring(unq(world.field(cmp2, "template"))):match("PLANET_KILLER") then return true end
                end
            end
        end
        return false
    end
    -- built_on_planet = yes/no (a megastructure: its `planet` set)
    TRIG["built_on_planet"] = function(e, ctx)
        local sc = ctx.this
        if sc == NONE or sc.kind ~= "megastructure" then return false end
        sync()
        local m = world.object("megastructures", sc.id)
        return (m ~= nil and ref(world.field(m, "planet")) ~= nil) == yes(e)
    end

    -- -----------------------------------------------------------------------------------------
    -- the numeric triggers as values (`complex_trigger_modifier = { trigger = x parameters = { } }`,
    -- the game's GetTriggerValue): the trigger run with the parameters, the number it compares
    -- taken; a scope it has no number for: 0 [I]
    for _, name in ipairs({ "branch_office_value", "check_economic_production_modifier_for_job",
        "free_jobs_of_type", "habitability", "planet_crime", "planet_happiness_above_threshold",
        "total_country_workforce_with_job_tag", "total_workforce_with_job_tag" }) do
        local trig = TRIG[name]
        eval.TVAL[name] = function(ctx, e)
            local saved = capture
            capture = {}
            local ok = pcall(trig, e, ctx)
            local v = capture.v
            capture = saved
            return ok and tonumber(v) or 0
        end
    end
end
