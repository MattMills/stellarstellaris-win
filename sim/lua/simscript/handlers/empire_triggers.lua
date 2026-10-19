-- simscript/handlers/empire_triggers.lua : the empire's triggers (species and traits, leaders, the
-- council, policies, civics and the government, ethics, pop groups and factions). Loaded by
-- handlers/empire.lua with its helpers (H). docs/script_empire.md has each one's class.

return function(eval, H)
    local S, NONE, world, E = H.S, H.NONE, H.world, H.E
    local I = H.I
    local compare, yes, sync = I.compare, I.yes, I.sync
    local TRIG, TVAL = eval.TRIG, eval.TVAL
    local unq, obj, field, num, def, dfield = H.unq, H.obj, H.field, H.num, H.def, H.dfield
    local tokens, set_of, params, text_of, target = H.tokens, H.set_of, H.params, H.text_of, H.target
    local compare_value, numeric, boolean = H.compare_value, H.numeric, H.boolean
    local country, gov, leader = H.country, H.gov, H.leader
    local floor = math.floor
    -- a trigger asked for its number (eval.TVAL, complex_trigger_modifier): VALUE set, it returns the
    -- number it would compare instead of comparing
    local VALUE = false
    local function as_value(name)
        TVAL[name] = function(ctx, e)
            if not e or e.value.text then return 0 end
            VALUE = true
            local ok, v = pcall(TRIG[name], e, ctx)
            VALUE = false
            return ok and type(v) == "number" and v or 0
        end
    end

    -- a define (common/defines NGroup.KEY), or a default
    local function define(group, key, default)
        for _, d in pairs(require("engine.defs").folder("common/defines")) do
            local g = H.dfield(d.block, group)
            local v = g and H.dfield(g, key)
            if v ~= nil then return tonumber(v) or v end
        end
        return default
    end
    local function modifier(kind, id, name)
        if E.modifier then
            local v = E.modifier(kind, id, name)
            return tonumber(v) or 0
        end
        return 0
    end

    -- a game rule (common/game_rules: a trigger block) with this and from
    local function rule(name, this, from)
        local b, file = def("common/game_rules", name)
        if type(b) ~= "table" then return true end
        local c = eval.new_ctx(this, from, nil, file)
        return eval.trigger(b, c) == true
    end
    H.rule = rule
    -- the country's runtime-only last changed policy group (CCountry +0x2a98: set by ChangePolicy,
    -- not saved [V]); the policy effects and commands set it
    H.last_policy = H.last_policy or {}

    -- ------------------------------------------------------------------------------------------
    -- leaders

    local function L(sc) return sc.kind == "leader" and leader(sc.id) or nil end
    -- leader_age (CLeaderAgeTrigger): the leader's `age`
    numeric("leader_age", { "leader" }, function(sc) local l = L(sc) return l and num(field(l, "age")) end)
    -- has_experience (CHasExperienceTrigger): `experience`
    numeric("has_experience", { "leader" }, function(sc) local l = L(sc) return l and num(field(l, "experience")) end)
    -- has_total_skill (CHasTotalSkillTrigger): the level and its bonus (level + bonus_skill_level)
    numeric("has_total_skill", { "leader" }, function(sc)
        local l = L(sc)
        return l and (num(field(l, "level")) + num(field(l, "bonus_skill_level")))
    end)
    -- leader_years_of_service (CLeaderYearsOfServiceTrigger): whole years since the leader was
    -- recruited (recruitment_date, else date)
    numeric("leader_years_of_service", { "leader" }, function(sc)
        local l = L(sc)
        if not l then return nil end
        local d = H.days_of(field(l, "recruitment_date")) or H.days_of(field(l, "date"))
        if not d then return 0 end
        return floor((H.now_days() - d) / 360)
    end)
    -- leader_lifespan (CLeaderLifespanTrigger @3b91630 → CLeader::GetLifespan @1d13600 [V]):
    -- trunc((LEADER_LIFESPAN_DEATH_CHANCE_AGE + trunc(leader_lifespan_add) +
    -- trunc(<class>_lifespan_add)) x (1 + leader_lifespan_mult + <class>_lifespan_mult + (organic:
    -- leader_organic_lifespan_mult))), the leader's modifiers [the organic test, the game rule
    -- is_leader_organic: not a robotic species I]
    local function trunc(x) return x < 0 and -floor(-x) or floor(x) end
    numeric("leader_lifespan", { "leader" }, function(sc)
        local l = L(sc)
        if not l then return nil end
        local class = unq(field(l, "class")) or ""
        local add = trunc(modifier("leader", sc.id, "leader_lifespan_add")) + trunc(modifier("leader", sc.id, class .. "_lifespan_add"))
        local mult = 1 + modifier("leader", sc.id, "leader_lifespan_mult") + modifier("leader", sc.id, class .. "_lifespan_mult")
        local sid = tonumber(field(l, "species"))
        if sid and not H.robotic_archetype(H.archetype_of(sid)) then
            mult = mult + modifier("leader", sc.id, "leader_organic_lifespan_mult")
        end
        return trunc((define("NGameplay", "LEADER_LIFESPAN_DEATH_CHANCE_AGE", 80) + add) * mult)
    end)
    -- gender = female/male/indeterminable (CGenderTrigger): the leader's `gender`
    TRIG["gender"] = function(e, ctx)
        local l = L(ctx.this)
        if not l or not e.value.text then return false end
        return (unq(field(l, "gender")) or "indeterminable") == unq(e.value.text)
    end
    -- has_ruler_trait = <trait> (CHasRulerTraitTrigger): the trait among the leader's traits (its
    -- ruler traits are kept with the others)
    TRIG["has_ruler_trait"] = function(e, ctx)
        local l = L(ctx.this)
        if not l or not e.value.text then return false end
        return set_of(H.leader_traits(l))[unq(e.value.text)] == true
    end
    -- is_idle (CIsIdleTrigger @3b93250 → CLeader::IsIdle @1d0d4f0 [V]): not idle when its location
    -- holds it (a colony's governor, a ship's leader); for a country that cannot change its
    -- councillors (game rule can_country_change_councilors) not when it is the ruler or on the
    -- council; else idle unless it is the ruler [I: the envoy, federation and community posts not
    -- read]
    boolean("is_idle", { "leader" }, function(sc)
        local l = L(sc)
        if not l then return nil end
        local loc = field(l, "location")
        if type(loc) == "table" then
            local t, id = unq(field(loc, "type")), tonumber(field(loc, "id"))
            if t == "planet" and tonumber(field(obj("colony", id), "governor")) == sc.id then return false end
            if t == "ship" and tonumber(field(obj("ship", id), "leader")) == sc.id then return false end
        end
        local cid = tonumber(field(l, "country"))
        local c = cid and obj("country", cid)
        local ruler = c and tonumber(field(c, "ruler")) == sc.id
        if c and not rule("can_country_change_councilors", S("country", cid)) then
            if ruler then return false end
            local cl = field(l, "council_location")
            if type(cl) == "table" and tonumber(field(cl, "id")) and tonumber(field(cl, "id")) ~= 4294967295 then return false end
        end
        return not ruler
    end)
    -- num_candidate_supported (CNumCandidateSupported @3bfba20 [V]): the times the country's
    -- election supported the leader (CElection::GetNumTimesLeaderSupported); no election: 0 [I:
    -- the election's save form not read: 0]
    numeric("num_candidate_supported", { "leader" }, function(sc)
        local l = L(sc)
        if not l then return nil end
        local c = obj("country", tonumber(field(l, "country")))
        if not c then return nil end
        local el = field(c, "election")
        if type(el) ~= "table" then return 0 end
        local ids, counts = world.list(field(el, "leaders")), world.list(field(el, "supported"))
        for i, id in ipairs(ids) do
            if tonumber(id) == sc.id then return tonumber(counts[i]) or 0 end
        end
        return 0
    end)
    -- num_leader_traits = { value is_councilor negative count_tiers contains_modifier is_subclass }
    -- (CNumLeaderTraitsTrigger @3b98c00 [V]): the leader's traits that pass the filters (each yes,
    -- no or any): negative and is_subclass the trait's leader_trait_type (negative, subclass),
    -- is_councilor its councilor modifier blocks, contains_modifier a modifier whose name holds the
    -- string (type yes by default [I]); count_tiers adds each trait's tiers
    TRIG["num_leader_traits"] = function(e, ctx)
        local l = L(ctx.this)
        if not l then return false end
        local p = params(e)
        local function tri(x)
            local t = text_of(x)
            if t == "yes" then return true elseif t == "no" then return false end
            return nil
        end
        local is_councilor, negative, is_subclass = tri(p.is_councilor), tri(p.negative), tri(p.is_subclass)
        local count_tiers = text_of(p.count_tiers) == "yes"
        local cm = p.contains_modifier
        local cm_string, cm_type
        if cm and cm.value.text == nil then
            local cp = params(cm)
            cm_string = text_of(cp.string)
            if cp.type then cm_type = tri(cp.type) else cm_type = true end
        end
        local n = 0
        for _, t in ipairs(H.leader_traits(l)) do
            local b = H.trait_def(t)
            local ok = b ~= nil
            local function inline(k)
                local is = b and dfield(b, "inline_script")
                return type(is) == "table" and unq(dfield(is, k)) or nil
            end
            if ok and is_councilor ~= nil then
                ok = ((inline("COUNCIL") == "yes") or dfield(b, "councilor_modifier") ~= nil) == is_councilor
            end
            local ltype = b and (unq(dfield(b, "leader_trait_type")) or inline("RARITY")) or nil
            if ok and negative ~= nil then ok = (ltype == "negative") == negative end
            if ok and is_subclass ~= nil then ok = (ltype == "subclass") == is_subclass end
            if ok and cm_string then
                local has = false
                for _, mk in ipairs({ "modifier", "councilor_modifier", "self_modifier", "triggered_modifier" }) do
                    local m = dfield(b, mk)
                    for _, x in ipairs(type(m) == "table" and m or {}) do
                        if x.key and x.key.text:find(cm_string, 1, true) then has = true end
                    end
                end
                if cm_type ~= nil then ok = has == cm_type else ok = ok and true end
            end
            if ok then
                n = n + (count_tiers and (tonumber(inline("TIER")) or 1) or 1)
            end
        end
        if VALUE then return n end
        return compare_value(n, e, ctx)
    end

    -- ------------------------------------------------------------------------------------------
    -- traits of species and pops

    -- the traits a trait-count trigger reads: a leader's own; a species', a pop group's species',
    -- a country's founder species' [I: a leader's per docs]
    local function traits_for(sc)
        if sc.kind == "leader" then
            local l = leader(sc.id)
            return l and H.leader_traits(l) or nil
        end
        local sid = H.species_of(sc)
        return sid and H.species_traits(sid) or nil
    end
    -- (positive / negative: the cost in the trigger's scope; trait points: CTrait::GetCost with the
    -- scope's country: the country, a pop group's owner, a leader's owner, none for a species
    -- [V @3b97e20, @20f5240])
    local function trait_cost_in(sc, t)
        if sc.kind == "species" then return H.trait_cost(t, nil) end
        return H.trait_cost(t, H.country_of(sc))
    end
    -- num_positive_traits / num_negative_traits (cost > 0 / < 0), num_trait_points (the costs)
    local TRAIT_SCOPES = { "country", "pop", "pop_group", "leader", "species" }
    numeric("num_positive_traits", TRAIT_SCOPES, function(sc)
        local ts = traits_for(sc)
        if not ts then return nil end
        local n = 0
        for _, t in ipairs(ts) do if trait_cost_in(sc, t) > 0 then n = n + 1 end end
        return n
    end)
    numeric("num_negative_traits", TRAIT_SCOPES, function(sc)
        local ts = traits_for(sc)
        if not ts then return nil end
        local n = 0
        for _, t in ipairs(ts) do if trait_cost_in(sc, t) < 0 then n = n + 1 end end
        return n
    end)
    numeric("num_trait_points", TRAIT_SCOPES, function(sc)
        local ts = traits_for(sc)
        if not ts then return nil end
        local n = 0
        for _, t in ipairs(ts) do n = n + trait_cost_in(sc, t) end
        return n
    end)
    -- count_species_traits = { limit category cost count } (CCountSpeciesTraitsTrigger): the
    -- species' traits that pass the limit (in the trait's scope), of the category, of the cost
    TRIG["count_species_traits"] = function(e, ctx)
        local sid = H.species_of(ctx.this)
        if not sid or e.value.text then return false end
        local p = params(e)
        local cat = text_of(p.category)
        local n = 0
        for _, t in ipairs(H.species_traits(sid)) do
            local b = H.trait_def(t)
            local ok = b ~= nil
            if ok and cat then ok = unq(dfield(b, "category")) == cat end
            if ok and p.cost then ok = compare(H.trait_cost(t, H.country_of(ctx.this)), p.cost.op, eval.value(p.cost.value, ctx, p.cost)) end
            if ok and p.limit and p.limit.value.text == nil then ok = eval.trigger(p.limit.value, I.push(ctx, S("trait", t))) end
            if ok then n = n + 1 end
        end
        if VALUE then return n end
        if not p.count then return n > 0 end
        return compare(n, p.count.op, eval.value(p.count.value, ctx, p.count))
    end
    -- trait_has_all_tags / trait_has_any_tag = { tags } (a trait scope): the trait's `tags`
    local function trait_tags(sc)
        if sc.kind ~= "trait" then return nil end
        return set_of(tokens(dfield(H.trait_def(sc.id), "tags")))
    end
    TRIG["trait_has_all_tags"] = function(e, ctx)
        local tags = trait_tags(ctx.this)
        if not tags or e.value.text then return false end
        for _, t in ipairs(tokens(e.value)) do if not tags[t] then return false end end
        return true
    end
    TRIG["trait_has_any_tag"] = function(e, ctx)
        local tags = trait_tags(ctx.this)
        if not tags or e.value.text then return false end
        for _, t in ipairs(tokens(e.value)) do if tags[t] then return true end end
        return false
    end

    -- ------------------------------------------------------------------------------------------
    -- species

    -- species_gender = female/male/indeterminable/not_set (CSpeciesGenderTrigger): the species'
    -- `gender` (none: not_set)
    TRIG["species_gender"] = function(e, ctx)
        if ctx.this.kind ~= "species" or not e.value.text then return false end
        return (unq(field(H.species(ctx.this.id), "gender")) or "not_set") == unq(e.value.text)
    end
    -- uplift_is_archetype = <archetype> (CUpliftIsArchetypeTrigger @3c3b320 [V]): the archetype of
    -- the class the species' class is uplifted into (`uplifted_into`); none: false (no inversion)
    TRIG["uplift_is_archetype"] = function(e, ctx)
        if ctx.this.kind ~= "species" or not e.value.text then return false end
        local cb = def("common/species_classes", unq(field(H.species(ctx.this.id), "class")))
        local into = cb and unq(dfield(cb, "uplifted_into"))
        if not into then return false end
        return H.class_archetype(into) == unq(e.value.text)
    end
    -- the game rule species_has_happiness (CCountry::SpeciesHasHappiness @23b6580 [V]): this the
    -- species, from the country (none without an owner)
    local function species_has_happiness(sid, cid)
        return rule("species_has_happiness", S("species", sid), cid and S("country", cid) or NONE)
    end
    H.species_has_happiness = species_has_happiness
    -- species_has_happiness_with_owner = <country> (CSpeciesHasHappinessTrigger @3be3e50 [V]): that
    -- rule; an invalid country or species: false; `= no` not applied
    TRIG["species_has_happiness_with_owner"] = function(e, ctx)
        if ctx.this.kind ~= "species" or not H.species(ctx.this.id) then return false end
        local sc = target(e, ctx)
        if not sc or sc.kind ~= "country" or not obj("country", sc.id) then return false end
        return species_has_happiness(ctx.this.id, sc.id)
    end
    -- inherits_parent_rights (CInheritsParentRights @3b8da40 [V]): a sub-species' (base_ref)
    -- `inherit_parent_rights`; a base species: false; no pop group nor species: (value ~= yes)
    TRIG["inherits_parent_rights"] = function(e, ctx)
        local sc = ctx.this
        if sc.kind ~= "pop_group" and sc.kind ~= "species" then return false end
        local sid = H.species_of(sc)
        local s = sid and H.species(sid)
        if not s then return not yes(e) end
        local r = tonumber(field(s, "base_ref")) ~= nil and H.species(tonumber(field(s, "base_ref"))) ~= nil
            and field(s, "inherit_parent_rights") == "yes"
        return r == yes(e)
    end
    -- is_robot_pop (CIsRobotPopTrigger): the pop group's species is robotic (its archetype)
    boolean("is_robot_pop", { "pop", "pop_group" }, function(sc)
        local sid = H.species_of(sc)
        if not sid then return nil end
        return H.robotic_archetype(H.archetype_of(sid))
    end)
    -- is_default_species = <species> (CIsDefaultSpeciesTrigger): the country's default of the
    -- species' group (default_species map; the built species for its base; the base itself)
    TRIG["is_default_species"] = function(e, ctx)
        local c = ctx.this.kind == "country" and obj("country", ctx.this.id)
        local sc = target(e, ctx)
        if not c or not sc or sc.kind ~= "species" then return false end
        local b = H.base_of(sc.id)
        local map = field(c, "default_species")
        local d = type(map) == "table" and tonumber(field(map, tostring(b))) or nil
        if not d then
            local built = tonumber(field(c, "built_species_ref"))
            if built and (built == sc.id or H.base_of(built) == b) then d = built else d = b end
        end
        return d == sc.id
    end

    -- ------------------------------------------------------------------------------------------
    -- planets and their pops

    local PLANETS = { "planet", "ship", "colony" }
    -- the species on a planet by pop size
    local function planet_species_pops(sc)
        local out = {}
        for _, g in ipairs(H.pop_groups(sc)) do
            local s = H.group_species(g)
            if s then out[s] = (out[s] or 0) + H.group_size(g) end
        end
        return out
    end
    -- is_majority_species = <species> (CIsMajoritySpeciesTrigger): the species with the most pops
    TRIG["is_majority_species"] = function(e, ctx)
        if ctx.this.kind ~= "planet" then return false end
        local sc = target(e, ctx)
        if not sc then return false end
        local sid = H.species_of(sc)
        sync()
        local best, bv = nil, -1
        for s, n in pairs(planet_species_pops(ctx.this)) do
            if n > bv or (n == bv and s < best) then best, bv = s, n end
        end
        return best ~= nil and best == sid
    end
    -- nb_pop_exact_species = { species value } (CNbPopExactSpeciesTrigger)
    TRIG["nb_pop_exact_species"] = function(e, ctx)
        if ctx.this.kind ~= "planet" or e.value.text then return false end
        local p = params(e)
        local sc = target(p.species, ctx)
        local sid = sc and H.species_of(sc)
        if not sid or (not p.value and not VALUE) then return false end
        sync()
        if VALUE then return planet_species_pops(ctx.this)[sid] or 0 end
        return compare(planet_species_pops(ctx.this)[sid] or 0, p.value.op, eval.value(p.value.value, ctx, p.value))
    end
    -- is_original_owner = <country> (CIsOriginalOwnerTrigger): the planet's `original_owner`
    TRIG["is_original_owner"] = function(e, ctx)
        if ctx.this.kind ~= "planet" then return false end
        local sc = target(e, ctx)
        if not sc or sc.kind ~= "country" then return false end
        return tonumber(field(obj("planet", ctx.this.id), "original_owner")) == sc.id
    end
    -- has_current_purge (CPlanetPurgingPopsTrigger @3be2ef0 → CColony::IsPurging [V]): a pop group of
    -- the colony not killed and being purged: its species' rights in the owner say purge
    -- (CPopGroup::IsBeingPurged: the citizenship's purge; a pre-sapient's: the pre-sapient
    -- policy [I: not read, false])
    local function being_purged(g, cid)
        local sid = H.group_species(g)
        if not sid or H.archetype_of(sid) == "PRESAPIENT" then return false end
        local entry = cid and H.rights_entry(cid, sid)
        local cit = entry and unq(field(entry, "citizenship"))
        local b = cit and def("common/species_rights/citizenship_types", cit)
        if b and dfield(b, "purge") ~= nil then return dfield(b, "purge") == "yes" end
        return cit == "citizenship_purge"
    end
    boolean("has_current_purge", PLANETS, function(sc)
        if sc.kind ~= "planet" then return false end
        local cid = H.planet_owner(sc.id)
        for _, g in ipairs(H.pop_groups(sc)) do
            if field(H.group(g), "killed") ~= "yes" and being_purged(g, cid) then return true end
        end
        return false
    end)
    -- organic_pops_last_month_growth / artificial_pops_last_month_growth: the planet's pop groups'
    -- last_month_growth of organic / robotic species
    local function growth(sc, robotic)
        if sc.kind ~= "planet" then return nil end
        local n = 0
        for _, g in ipairs(H.pop_groups(sc)) do
            local s = H.group_species(g)
            if s and H.robotic_archetype(H.archetype_of(s)) == robotic then
                local v = num(field(H.group(g), "last_month_growth"))
                if v > 0 then n = n + v end
            end
        end
        return n
    end
    numeric("organic_pops_last_month_growth", PLANETS, function(sc) return growth(sc, false) end)
    numeric("artificial_pops_last_month_growth", PLANETS, function(sc) return growth(sc, true) end)
    -- pop_ethics_divergence (CPopEthicsDivergenceTrigger @3b7c2f0 [V]): per pop group its size less
    -- the pops of an ethic the owner holds (its regular or fanatic form too), over the sizes;
    -- false with no pops
    numeric("pop_ethics_divergence", PLANETS, function(sc)
        if sc.kind ~= "planet" then return nil end
        local c = country(sc)
        local own = {}
        for _, eth in ipairs(c and H.country_ethics(c) or {}) do
            own[eth] = true
            own[(eth:gsub("^ethic_fanatic_", "ethic_"))] = true
        end
        local total, diverging = 0, 0
        for _, g in ipairs(H.pop_groups(sc)) do
            local size = H.group_size(g)
            local matching = 0
            for _, ep in ipairs(H.group_ethics(g)) do
                if own[ep[1]] or own[(ep[1]:gsub("^ethic_fanatic_", "ethic_"))] then matching = matching + ep[2] end
            end
            total = total + size
            diverging = diverging + size - matching
        end
        if total <= 0 then return nil end
        return floor(diverging / total * 100000) / 100000
    end)

    -- ------------------------------------------------------------------------------------------
    -- pop groups

    local POPS = { "pop", "pop_group" }
    -- happiness (CHappinessTrigger): the pop group's `happiness`
    numeric("happiness", POPS, function(sc)
        if sc.kind ~= "pop_group" then return nil end
        return tonumber(field(H.group(sc.id), "happiness"))
    end)
    -- pop_has_happiness (CPopHasHappinessTrigger @3be3310 [V]): the game rule species_has_happiness
    -- for its species, from its owner (none: no country)
    boolean("pop_has_happiness", POPS, function(sc)
        if sc.kind ~= "pop_group" then return nil end
        local sid = H.group_species(sc.id)
        if not sid then return false end
        return H.species_has_happiness(sid, H.group_owner(sc.id))
    end)
    -- can_join_factions (CCanJoinFactionsTrigger @3bc7aa0 → CPopGroup::CanJoinFactions [V]): a
    -- sapient species and the game rule pop_group_can_join_factions (this the pop group); another
    -- scope: false (no inversion)
    TRIG["can_join_factions"] = function(e, ctx)
        local sc = ctx.this
        if sc.kind ~= "pop_group" then return false end
        local sid = H.group_species(sc.id)
        local r = sid ~= nil and H.archetype_of(sid) ~= "PRESAPIENT"
            and rule("pop_group_can_join_factions", sc, NONE)
        return r == yes(e)
    end
    -- member_of_faction = <faction type> / <faction scope> / other (CMemberOfFactionTrigger @3b9cb30
    -- [V]): the pop group's `factions` hold one of that type, that faction, or any; `= no` not
    -- applied (the result as it is)
    TRIG["member_of_faction"] = function(e, ctx)
        if ctx.this.kind ~= "pop_group" or not e.value.text then return false end
        local fs = world.list(field(H.group(ctx.this.id), "factions"))
        local v = unq(e.value.text)
        if def("common/pop_faction_types", v) then
            for _, f in ipairs(fs) do
                if unq(field(obj("pop_factions", tonumber(f)), "type")) == v then return true end
            end
            return false
        end
        local found, sc = eval.resolve(e.value.text, ctx, e)
        if found then
            if not sc or sc.kind ~= "pop_faction" then return false end
            for _, f in ipairs(fs) do if tonumber(f) == sc.id then return true end end
            return false
        end
        return #fs > 0
    end
    -- former_<right>_type = <option> (CFormer...TypeTrigger): the pop group's species' rights entry's
    -- former_<right> in its owner
    local function former(right)
        return function(e, ctx)
            if ctx.this.kind ~= "pop_group" or not e.value.text then return false end
            local cid = H.group_owner(ctx.this.id)
            local entry = cid and H.rights_entry(cid, H.group_species(ctx.this.id))
            return entry ~= nil and unq(field(entry, "former_" .. right)) == unq(e.value.text)
        end
    end
    TRIG["former_living_standard_type"] = former("living_standard")
    TRIG["former_migration_control_type"] = former("migration_control")
    TRIG["former_population_control_type"] = former("population_control")
    TRIG["former_purge_type"] = former("purge")
    -- last_changed_species_rights_type = <right> (a pop group's or leader's species, its owner's
    -- entry's last_changed_value; none: none)
    TRIG["last_changed_species_rights_type"] = function(e, ctx)
        local sc = ctx.this
        if (sc.kind ~= "pop_group" and sc.kind ~= "leader") or not e.value.text then return false end
        local sid = H.species_of(sc)
        local cid = sc.kind == "pop_group" and H.group_owner(sc.id) or tonumber(field(leader(sc.id), "country"))
        local entry = cid and sid and H.rights_entry(cid, sid)
        local v = entry and unq(field(entry, "last_changed_value")) or "none"
        return v == unq(e.value.text)
    end
    -- has_migration_control = { type country } (CHasMigrationControlTrigger): the scope's species'
    -- migration_control in the country (default: the pop group's owner)
    TRIG["has_migration_control"] = function(e, ctx)
        local sid = H.species_of(ctx.this)
        if not sid then return false end
        local p = params(e)
        local csc = p.country and target(p.country, ctx)
        local cid = csc and csc.kind == "country" and csc.id or H.country_of(ctx.this)
            or (ctx.this.kind == "pop_group" and H.group_owner(ctx.this.id))
        if not cid then return false end
        local entry = H.rights_entry(cid, sid)
        local v = entry and unq(field(entry, "migration_control"))
        local want = text_of(p.type) or (e.value.text and unq(e.value.text)) or "yes"
        if want == "yes" or want == "no" then
            local prevented = v ~= nil and v ~= "migration_control_no"
            return prevented == (want == "yes")
        end
        return v == want
    end
    -- pop_maintenance_cost = { value resource } (CPopMaintenanceCostTrigger @3bd54d0 [V]): the whole
    -- group's upkeep of the resource (its category's `upkeep` x size / POP_BULK_UNIT_SIZE) [I: the
    -- economic unit's modifiers not taken]
    TRIG["pop_maintenance_cost"] = function(e, ctx)
        if ctx.this.kind ~= "pop_group" or e.value.text then return false end
        local p = params(e)
        local res = text_of(p.resource)
        if not res or not p.value then return false end
        local cat = H.group_category(ctx.this.id)
        local b = def("common/pop_categories", cat)
        local v = 0
        local r = dfield(b, "resources")
        local up = type(r) == "table" and dfield(r, "upkeep")
        if type(up) == "table" then v = tonumber(dfield(up, res)) or 0 end
        v = v * H.group_size(ctx.this.id) / 100
        return compare(v, p.value.op, eval.value(p.value.value, ctx, p.value))
    end

    -- ------------------------------------------------------------------------------------------
    -- pops in a scope: shares and ethics

    -- pop_amount_percentage = { percentage limit exclude } (CPopAmountPercentageTrigger): the
    -- scope's pop groups' sizes passing limit over those not excluded
    TRIG["pop_amount_percentage"] = function(e, ctx)
        if e.value.text then return false end
        local p = params(e)
        if not p.percentage and not VALUE then return false end
        sync()
        local total, hit = 0, 0
        for _, g in ipairs(H.pop_groups(ctx.this)) do
            local c2 = I.push(ctx, S("pop_group", g))
            local excluded = p.exclude and p.exclude.value.text == nil and #p.exclude.value > 0 and eval.trigger(p.exclude.value, c2)
            if not excluded then
                local n = H.group_size(g)
                total = total + n
                if not p.limit or p.limit.value.text ~= nil or eval.trigger(p.limit.value, c2) then hit = hit + n end
            end
        end
        -- (no pops: the raw 0xffffffff, 42949.67295, and the comparison still made [V @3c332af])
        local v = total > 0 and floor(hit / total * 100000) / 100000 or 42949.67295
        if VALUE then return v end
        return compare(v, p.percentage.op, eval.value(p.percentage.value, ctx, p.percentage))
    end
    -- pop_ethic_amount / pop_ethic_percentage = { amount|percentage ethic (= or !=) }: the pops
    -- of the scope following (or not) the ethic; as a value: the amount / the share
    local function ethic_pops(sc, ethic, negate)
        local total, hit = 0, 0
        for _, g in ipairs(H.pop_groups(sc)) do
            for _, ep in ipairs(H.group_ethics(g)) do
                total = total + ep[2]
                if (ep[1] == ethic) ~= negate then hit = hit + ep[2] end
            end
        end
        return hit, total
    end
    local function pop_ethic(kind)
        return function(e, ctx)
            if e.value.text then return false end
            local p = params(e)
            local ex = p.ethic
            if not ex or not ex.value.text then return false end
            sync()
            local hit, total = ethic_pops(ctx.this, unq(ex.value.text), ex.op == "!=")
            if VALUE then
                if kind == "amount" then return hit end
                return total > 0 and hit / total or 0
            end
            if p.amount then return compare(hit, p.amount.op, eval.value(p.amount.value, ctx, p.amount)) end
            if p.percentage then
                if total <= 0 then return false end
                return compare(hit / total, p.percentage.op, eval.value(p.percentage.value, ctx, p.percentage))
            end
            return false
        end
    end
    TRIG["pop_ethic_amount"] = pop_ethic("amount")
    TRIG["pop_ethic_percentage"] = pop_ethic("percentage")
    -- num_species (CNumSpeciesTrigger @3bc85c0 [V]): the base species of the scope's pops (a
    -- country's: of every pop group, size 0 and pre-sapient too; a planet's: with pops there)
    numeric("num_species", { "planet", "country", "ship", "pop_faction", "colony" }, function(sc)
        return #H.scope_species(sc, true)
    end)
    -- num_ethics (CNumEthicsTrigger): a country's ethics; a pop group's
    numeric("num_ethics", { "country", "pop", "pop_group" }, function(sc)
        if sc.kind == "country" then return #H.country_ethics(obj("country", sc.id)) end
        if sc.kind == "pop_group" then
            local n = 0
            for _, ep in ipairs(H.group_ethics(sc.id)) do if ep[2] > 0 then n = n + 1 end end
            return n
        end
        return nil
    end)

    -- ------------------------------------------------------------------------------------------
    -- countries: the government, civics, policies, the council

    local function C(sc) return sc.kind == "country" and obj("country", sc.id) or nil end
    local function civics(c)
        local out = {}
        for _, v in ipairs(world.list(field(gov(c), "civics"))) do out[#out + 1] = unq(v) end
        return out
    end
    -- civics_count (CCivicsCountTrigger): the government's civics
    numeric("civics_count", { "country" }, function(sc) local c = C(sc) return c and #civics(c) end)
    -- has_total_civic_points (CHasTotalCivicPointsTrigger): GOVERNMENT_CIVIC_POINTS_BASE +
    -- country_government_civic_points_add; has_unused_civic_points: that less the civics' costs
    local function civic_points(sc)
        return define("NGameplay", "GOVERNMENT_CIVIC_POINTS_BASE", 2)
            + floor(modifier("country", sc.id, "country_government_civic_points_add"))
    end
    numeric("has_total_civic_points", { "country" }, function(sc) return C(sc) and civic_points(sc) end)
    numeric("has_unused_civic_points", { "country" }, function(sc)
        local c = C(sc)
        return c and (civic_points(sc) - #civics(c))
    end)
    -- has_civic_in_slot = { civic index } (CHasCivicInSlotTrigger): the civic at that index
    -- (1-based [I])
    TRIG["has_civic_in_slot"] = function(e, ctx)
        local c = C(ctx.this)
        if not c or e.value.text then return false end
        local p = params(e)
        local i = p.index and tonumber(eval.value(p.index.value, ctx, p.index))
        local civ = text_of(p.civic)
        return i ~= nil and civ ~= nil and civics(c)[i] == civ
    end
    -- has_invalid_civic = <civic> (CHasInvalidCivicTrigger): the government has the civic and its
    -- `possible` fails for the government (ethics, authority, other civics, origin) [I: the
    -- requirement lists only]
    local function requirement_ok(block, cfg)
        if type(block) ~= "table" then return true end
        local function list_ok(b, have)
            for _, x in ipairs(b) do
                if x.op and x.key then
                    local k = x.key.text
                    if k == "value" then
                        if not have[unq(x.value.text)] then return false end
                    elseif k == "OR" or k == "NOT" or k == "NOR" or k == "AND" then
                        local hit, n = 0, 0
                        for _, y in ipairs(x.value) do
                            if y.op and y.key and y.key.text == "value" then
                                n = n + 1
                                if have[unq(y.value.text)] then hit = hit + 1 end
                            end
                        end
                        if k == "OR" and hit == 0 then return false end
                        if (k == "NOT" or k == "NOR") and hit > 0 then return false end
                        if k == "AND" and hit < n then return false end
                    end
                end
            end
            return true
        end
        for _, x in ipairs(block) do
            if x.op and x.key and type(x.value) == "table" and x.value.text == nil then
                local have = cfg[x.key.text]
                if have and not list_ok(x.value, have) then return false end
            end
        end
        return true
    end
    TRIG["has_invalid_civic"] = function(e, ctx)
        local c = C(ctx.this)
        if not c or not e.value.text then return false end
        local civ = unq(e.value.text)
        local list = civics(c)
        if not set_of(list)[civ] then return false end
        local cfg = {
            ethics = set_of(H.country_ethics(c)), civics = set_of(list),
            authority = set_of({ unq(field(gov(c), "authority")) or "" }),
            origin = set_of({ unq(field(gov(c), "origin")) or "" }),
            country_type = set_of({ unq(field(c, "type")) or "" }),
        }
        cfg.civics[civ] = nil
        local b = def("common/governments/civics", civ)
        return not requirement_ok(dfield(b, "possible"), cfg)
    end
    -- the policies: active_policies' entry of a group
    local function policy_entry(c, group)
        for _, b in ipairs(world.blocks(field(c, "active_policies"))) do
            if unq(field(b, "policy")) == group then return b end
        end
        return nil
    end
    -- can_change_policy = <group> (CCanChangePolicyTrigger @3ba7fd0 → SPolicyData::CanBeChanged
    -- [V]): the country's active_policies entry of the group (none: false); never changed (no
    -- date): true; else POLICY_YEARS since and the group's `allow`; `= no` not applied
    TRIG["can_change_policy"] = function(e, ctx)
        local c = C(ctx.this)
        if not c or not e.value.text then return false end
        local group = unq(e.value.text)
        local b = policy_entry(c, group)
        if not b then return false end
        local d = H.days_of(field(b, "date"))
        if not d or d <= 0 then return true end
        if H.now_days() - d < define("NGameplay", "POLICY_YEARS", 10) * 360 then return false end
        local gb, file = def("common/policies", group)
        local allow = gb and dfield(gb, "allow")
        return type(allow) ~= "table" or eval.trigger(allow, eval.new_ctx(ctx.this, nil, nil, file))
    end
    -- can_set_policy = { policy option } (CCanSetPolicyTrigger @3ba8510 → CPolicyOption::
    -- IsValidForCountry [V]): the option's potential and its `valid` block in the country's scope
    TRIG["can_set_policy"] = function(e, ctx)
        local c = C(ctx.this)
        if not c or e.value.text then return false end
        local p = params(e)
        local group, option = text_of(p.policy), text_of(p.option)
        local gb, file = def("common/policies", group)
        if not gb or not option then return false end
        local cctx = eval.new_ctx(ctx.this, nil, nil, file)
        for _, x in ipairs(gb) do
            if x.op and x.key and x.key.text == "option" and type(x.value) == "table" and unq(dfield(x.value, "name")) == option then
                for _, k in ipairs({ "potential", "valid" }) do
                    local blk = dfield(x.value, k)
                    if type(blk) == "table" and not eval.trigger(blk, cctx) then return false end
                end
                return true
            end
        end
        return false
    end
    -- last_changed_policy = <group> (CLastChangedPolicyTrigger @3bab4f0 [V]): the group the
    -- country changed last in this session (CCountry +0x2a98: not saved, so false after a load
    -- until a policy changes; H.last_policy)
    TRIG["last_changed_policy"] = function(e, ctx)
        local c = C(ctx.this)
        if not c or not e.value.text then return false end
        return H.last_policy[ctx.this.id] == unq(e.value.text)
    end
    -- the council's agenda: council_agenda_progress (its progress), _percent (over its cost)
    local function agenda_cost(c)
        local key = unq(field(gov(c), "council_agenda"))
        local b, file = def("common/council_agendas", key)
        if not b then return nil end
        local e = nil
        for _, x in ipairs(b) do if x.op and x.key and x.key.text == "agenda_cost" then e = x end end
        if not e then return nil end
        local ok, v = pcall(eval.value, e.value, eval.new_ctx(S("country", 0), nil, nil, file), e)
        return ok and tonumber(v) or nil
    end
    numeric("council_agenda_progress", { "country" }, function(sc)
        local c = C(sc)
        return c and num(field(gov(c), "council_agenda_progress"))
    end)
    numeric("council_agenda_progress_percent", { "country" }, function(sc)
        local c = C(sc)
        if not c then return nil end
        local cost = agenda_cost(c)
        if not cost or cost <= 0 then return 0 end
        return num(field(gov(c), "council_agenda_progress")) / cost
    end)
    -- has_agenda_selected = yes/any/no/none/<agenda> (CHasAgendaSelectedTrigger)
    TRIG["has_agenda_selected"] = function(e, ctx)
        local c = C(ctx.this)
        if not c or not e.value.text then return false end
        local a = unq(field(gov(c), "council_agenda"))
        local has = a ~= nil and a ~= "" and a ~= "none"
        local v = unq(e.value.text)
        if v == "yes" or v == "any" then return has end
        if v == "no" or v == "none" then return not has end
        return a == v
    end
    -- council_legitimacy (CNumCouncilLegitimacy @3bfbc90 → CGovernment::CalcCouncilLegitimacy [V]):
    -- the country's pop factions' support_percent x faction_approval summed (none: 0); no
    -- government: false
    numeric("council_legitimacy", { "country" }, function(sc)
        local c = C(sc)
        if not c or type(gov(c)) ~= "table" then return nil end
        local v = 0
        for _, fid in ipairs(world.all("pop_factions")) do
            local f = obj("pop_factions", fid)
            if f and tonumber(field(f, "country")) == sc.id then
                v = v + num(field(f, "support_percent")) * num(field(f, "faction_approval"))
            end
        end
        return v
    end)
    -- get_councilor_level = { type value } (CGetCouncilorLevel @3b776c0 [V]): the first council
    -- position of that type with a leader: its level + bonus_skill_level + councilor_skill_add;
    -- none: false
    local function councilor_level(c, ctype, cid)
        for _, p in ipairs(H.councils(c)) do
            if unq(field(p, "type")) == ctype then
                local l = leader(tonumber(field(p, "leader")))
                if l then
                    return num(field(l, "level")) + num(field(l, "bonus_skill_level"))
                        + trunc(modifier("country", cid, "councilor_skill_add"))
                end
            end
        end
        return nil
    end
    TRIG["get_councilor_level"] = function(e, ctx)
        local c = C(ctx.this)
        if not c or e.value.text then return false end
        local p = params(e)
        local n = councilor_level(c, text_of(p.type), ctx.this.id)
        if n == nil then return false end
        if p.value then return compare(n, p.value.op, eval.value(p.value.value, ctx, p.value)) end
        return true
    end
    TVAL["get_councilor_level"] = function(ctx, e)
        local c = C(ctx.this)
        if not c or not e or e.value.text then return 0 end
        return councilor_level(c, text_of(params(e).type), ctx.this.id) or 0
    end
    -- is_ethic_represented_on_council = <ethic> (CIsEthicRepresentedOnCouncilTrigger): a
    -- councillor (or the ruler) with that ethic
    TRIG["is_ethic_represented_on_council"] = function(e, ctx)
        local c = C(ctx.this)
        if not c or not e.value.text then return false end
        local want = unq(e.value.text)
        for _, p in ipairs(H.councils(c)) do
            local l = leader(tonumber(field(p, "leader")))
            if l and unq(field(l, "ethic")) == want then return true end
        end
        local r = leader(tonumber(field(c, "ruler")))
        return r ~= nil and unq(field(r, "ethic")) == want
    end
    -- num_owned_leaders (CNumOwnedLeadersTrigger): owned leaders not of a class that can be an
    -- envoy (the ruler counted)
    numeric("num_owned_leaders", { "country" }, function(sc)
        local c = C(sc)
        if not c then return nil end
        local n = 0
        for _, id in ipairs(H.owned_leaders(c)) do
            local l = leader(id)
            local cb = l and def("common/leader_classes", unq(field(l, "class")))
            if l and not (cb and dfield(cb, "can_be_envoy") == "yes") then n = n + 1 end
        end
        return n
    end)
    -- empire_sprawl (CEmpireSprawlTrigger, the same as empire_size); its cap fraction
    -- (@3b959a0: size / cap, cap 0: 42949.67295) and the part over the cap (@3b955c0: size -
    -- floor(cap), may be negative) [V]: the admin cap (EMPIRE_SIZE_BASE + country_admin_cap_add) x
    -- max(0, 1 + country_admin_cap_mult), not rounded
    local function sprawl(sc) local c = C(sc) return c and num(field(c, "empire_size")) end
    local function admin_cap(sc)
        return (define("NGameplay", "EMPIRE_SIZE_BASE", 100) + modifier("country", sc.id, "country_admin_cap_add"))
            * math.max(0, 1 + modifier("country", sc.id, "country_admin_cap_mult"))
    end
    numeric("empire_sprawl", { "country" }, sprawl)
    numeric("empire_sprawl_cap_fraction", { "country" }, function(sc)
        local s = sprawl(sc)
        if not s then return nil end
        local cap = admin_cap(sc)
        if cap == 0 then return 42949.67295 end
        return trunc(s / cap * 100000) / 100000
    end)
    numeric("empire_sprawl_over_cap", { "country" }, function(sc)
        local s = sprawl(sc)
        if not s then return nil end
        return s - floor(admin_cap(sc))
    end)
    -- opposing_ethics_divergence = { steps who } (COpposingEthicsDivergenceTrigger @3ba9010 [V]):
    -- the most category_value steps between one of `who`'s ethics and the scope country's ethic
    -- of that category (category_value 0 fanatic A, 1 A, 3 B, 4 fanatic B; a category the scope
    -- country has no ethic in counts as 0, not neutral)
    local function category_values(c)
        local out = {}
        for _, eth in ipairs(H.country_ethics(c)) do
            local b = def("common/ethics", eth)
            local cat = b and unq(dfield(b, "category"))
            if cat then out[#out + 1] = { cat, tonumber(dfield(b, "category_value")) or 0 } end
        end
        return out
    end
    TRIG["opposing_ethics_divergence"] = function(e, ctx)
        local c = C(ctx.this)
        if not c or e.value.text then return false end
        local p = params(e)
        local w = target(p.who, ctx)
        local o = w and w.kind == "country" and obj("country", w.id)
        if not o or (not p.steps and not VALUE) then return false end
        local mine = {}
        for _, cv in ipairs(category_values(c)) do mine[cv[1]] = cv[2] end
        local steps = 0
        for _, cv in ipairs(category_values(o)) do
            steps = math.max(steps, math.abs((mine[cv[1]] or 0) - cv[2]))
        end
        if VALUE then return steps end
        return compare(steps, p.steps.op, eval.value(p.steps.value, ctx, p.steps))
    end
    -- has_extorted_faction (CHasExtortedFactionTrigger): a pop faction of the country extorted
    boolean("has_extorted_faction", { "country" }, function(sc)
        for _, fid in ipairs(world.all("pop_factions")) do
            local f = obj("pop_factions", fid)
            if f and tonumber(field(f, "country")) == sc.id and field(f, "extorted") == "yes" then return true end
        end
        return false
    end)
    -- faction_approval (CFactionApprovalTrigger): the pop faction's `approval`
    numeric("faction_approval", { "pop_faction" }, function(sc)
        return tonumber(field(obj("pop_factions", sc.id), "approval"))
    end)

    -- ------------------------------------------------------------------------------------------
    -- the galaxy

    local function galaxy() return world.meta and world.meta.galaxy or nil end
    local function gfield(k) local g = galaxy() return type(g) == "table" and tonumber(field(g, k)) or nil end
    -- the game setup (the save's `galaxy`): num_empires (the AI empires asked for), fallen and
    -- marauder empires, the fallen empires' strength scale
    numeric("num_ai_empires_setting", nil, function() return gfield("num_empires") end)
    numeric("num_fallen_empires_setting", nil, function() return gfield("num_fallen_empires") end)
    numeric("num_marauder_empires_to_spawn", nil, function() return gfield("num_marauder_empires") end)
    numeric("fallen_empire_strength_scale", nil, function() return gfield("fallen_empire_strength_scale") end)
    -- num_empires (CNumEmpiresTrigger @3ba2bd0 [V]): the countries whose type is playable, dead
    -- ones included; num_fallen_empires (@3ba2810 [V]): those whose type is a fallen_empire, the
    -- ones passing game rule count_as_split_fallen_empire together counting as one
    local function country_type_has(c, key)
        local b = def("common/country_types", unq(field(c, "type")))
        return b and dfield(b, key) == "yes" or false
    end
    numeric("num_empires", nil, function()
        local n = 0
        for _, id in ipairs(world.all("country")) do
            local c = obj("country", id)
            if c and country_type_has(c, "playable") then n = n + 1 end
        end
        return n
    end)
    numeric("num_fallen_empires", nil, function()
        local normal, split = 0, 0
        for _, id in ipairs(world.all("country")) do
            local c = obj("country", id)
            if c and country_type_has(c, "fallen_empire") then
                if H.rule("count_as_split_fallen_empire", S("country", id), NONE) and def("common/game_rules", "count_as_split_fallen_empire") then
                    split = split + 1
                else
                    normal = normal + 1
                end
            end
        end
        return normal + (split > 0 and 1 or 0)
    end)
    -- is_years_since_council_establishment (@3c219d0 → CGalacticCommunity::
    -- GetYearsSinceCouncilEstablishment [V]): the current year less the year of
    -- galactic_community.council_established (calendar years); -1 when it is absent
    numeric("is_years_since_council_establishment", nil, function()
        local gc = world.meta and world.meta.galactic_community
        local d = type(gc) == "table" and H.days_of(field(gc, "council_established")) or nil
        if not d then return -1 end
        return floor(H.now_days() / 360) - floor(d / 360)
    end)
    -- name_list_category (a dlc_recommendation scope: the empire creator's) [I: no such object in the
    -- simulation; false]
    TRIG["name_list_category"] = function() return false end

    -- ------------------------------------------------------------------------------------------
    -- flags

    -- timed_flag_days_left = { flag days } (CTimedFlagDaysLeftTrigger @3b4ac50 [V]): the timed
    -- flag's days left (`name = { flag_date flag_days }`; a permanent flag -1); no flag: false.
    -- `value` is read as well as `days`
    TRIG["timed_flag_days_left"] = function(e, ctx)
        if e.value.text then return false end
        local p = params(e)
        local name = p.flag and p.flag.value.text and I.flag_name(p.flag.value.text, ctx, p.flag)
        local cmp = p.days or p.value
        if not name or (not cmp and not VALUE) then return false end
        local o = ctx.this ~= NONE and world.object(ctx.this.kind, ctx.this.id)
        local f = o and field(o, "flags")
        local b = type(f) == "table" and field(f, name)
        if b == nil then return false end
        local left = type(b) == "table" and num(field(b, "flag_days")) or -1
        if VALUE then return left end
        return compare(left, cmp.op, eval.value(cmp.value, ctx, cmp))
    end
    for _, k in ipairs({ "count_species_traits", "nb_pop_exact_species", "num_leader_traits", "opposing_ethics_divergence",
        "pop_amount_percentage", "pop_ethic_amount", "pop_ethic_percentage", "timed_flag_days_left" }) do
        as_value(k)
    end
end
