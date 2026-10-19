-- simscript/handlers/empire_species.lua : the empire's species effects (the species' own data,
-- founder / built / dominant species, modification, merging, the species rights effects). Loaded
-- by handlers/empire.lua with its helpers (H). docs/script_empire.md has each one's class; the
-- Linux 4.5.2 addresses are in the comments. A species' save layout is CSpecies::WriteMembers'
-- (0x1fc3c70).

return function(eval, H)
    local S, NONE, world, E = H.S, H.NONE, H.world, H.E
    local I = H.I
    local EFF = eval.EFF
    local unq, obj, field, num, def, dfield = H.unq, H.obj, H.field, H.num, H.def, H.dfield
    local params, text_of, target, tokens, set_of = H.params, H.text_of, H.target, H.tokens, H.set_of
    local stats = I.stats
    local floor = math.floor
    local NO_ID = 4294967295

    local function wrote() stats.script = stats.script + 1 end
    local function quoted(v) return '"' .. tostring(v) .. '"' end
    local function define(group, key, default) return H.define and H.define(group, key, default) or default end
    local function date_text(days)
        local y = floor(days / 360)
        local r = days - y * 360
        return string.format("%d.%02d.%02d", y, floor(r / 30) + 1, r % 30 + 1)
    end
    local function remove_key(o, key)
        local en = world.entry(o, key)
        if en then world.remove_entry(o, en) return true end
        return false
    end
    local function copy_node(x)
        if type(x) ~= "table" then return x end
        local out = {}
        for k, v in pairs(x) do out[k] = copy_node(v) end
        return out
    end
    local function yes(p) return p ~= nil and p.value.text == "yes" end
    local function C(ctx) return ctx.this.kind == "country" and obj("country", ctx.this.id) or nil end
    local function SP(ctx) return ctx.this.kind == "species" and H.species(ctx.this.id) or nil end
    local function species_target(v, ctx)
        local sc = target(v, ctx)
        return sc and sc ~= NONE and H.species_of(sc) or nil
    end
    local function species_mod() return require("engine.species_mod") end

    -- ------------------------------------------------------------------------------------------
    -- a species' data

    local function traits_block(s) return world.child(s, "traits") end
    local function has_trait(s, t)
        for _, x in ipairs(world.fields(field(s, "traits"), "trait")) do
            if unq(x) == t then return true end
        end
        return false
    end
    -- CTraitSet::AddTrait: appended (at the list's start with add_traits_at_start_of_list) [V]
    local function add_trait(s, t, at_start)
        if not def("common/traits", t) or has_trait(s, t) then return false end
        local b = traits_block(s)
        if at_start then world.insert(b, 1, "trait", t, true) else world.append(b, "trait", t, true) end
        return true
    end
    local function remove_trait(s, t)
        local b = field(s, "traits")
        if type(b) ~= "table" then return false end
        local n = 0
        for i = #b, 1, -1 do
            local x = b[i]
            if x.op and x.key and x.key.text == "trait" and unq(x.value.text) == t then
                world.remove_entry(b, x)
                n = n + 1
            end
        end
        return n > 0
    end
    -- the +0x534 bits [V]: sapient (`sapient = no` when clear), immortal (`immortal = yes`),
    -- can_be_modified (`can_be_modified = no`), inherit_parent_rights (`inherit_parent_rights = yes`)
    local function set_bit(s, key, on, written_when_on)
        if on == written_when_on then world.set(s, key, on and "yes" or "no") else remove_key(s, key) end
    end
    local function portrait_of(v, ctx)
        local sid = species_target(v, ctx)
        local s = sid and H.species(sid)
        local p = s and field(s, "portrait")
        if p and unq(p) ~= "" then return unq(p) end
        return v.value.text and unq(v.value.text) or nil
    end
    local function base_of(sid) return H.base_of(sid) end

    -- set_species_homeworld = <planet> (CSetSpeciesHomeworldEffect 0x37719d0 → SetHomeCarrierRef) [V]:
    -- home_planet = { type = planet reference }
    EFF["set_species_homeworld"] = function(e, ctx)
        local s = SP(ctx)
        local sc = target(e, ctx)
        if not s or not sc or sc.kind ~= "planet" then return end
        local b = {}
        world.append(b, "type", "planet")
        world.append(b, "reference", sc.id)
        local en = world.entry(s, "home_planet")
        if en then world.set_entry(s, en, b) else world.append(s, "home_planet", b) end
        wrote()
    end
    -- change_species_portrait = <portrait>|<species> (CChangeSpeciesPortraitEffect 0x37830e0) [V]
    EFF["change_species_portrait"] = function(e, ctx)
        local s = SP(ctx)
        if not s or not e.value.text then return end
        local p = portrait_of(e, ctx)
        if not p then return end
        world.set(s, "portrait", quoted(p))
        wrote()
    end
    -- set_species_identity = new | <species> (CSetSpeciesIdentityEffect 0x37741d0) [V]: new: no
    -- base_ref; a species: its base species (the root [I])
    EFF["set_species_identity"] = function(e, ctx)
        local s = SP(ctx)
        if not s or not e.value.text then return end
        if e.value.text == "new" then
            if remove_key(s, "base_ref") then wrote() end
            return
        end
        local sid = species_target(e, ctx)
        local b = sid and base_of(sid)
        if not b or b == ctx.this.id then return end
        world.set(s, "base_ref", b)
        wrote()
    end
    -- the leaders a species rule applies to (CLeader::EnforceSpeciesRules 0x1d13120): portrait the
    -- species', SetGender (the design dropped)
    local function enforce_on_leaders(sid, cids)
        local p = unq(field(H.species(sid), "portrait"))
        local g = unq(field(H.species(sid), "gender"))
        for cid in pairs(cids) do
            local c = obj("country", cid)
            for _, k in ipairs(world.list(c and field(c, "owned_leaders"))) do
                local l = H.leader(tonumber(k))
                if l and tonumber(field(l, "species")) == sid then
                    if p then world.set(l, "portrait", quoted(p)) end
                    if g and g ~= "not_set" and unq(field(l, "gender")) ~= g then
                        world.set(l, "gender", g)
                        remove_key(l, "design")
                    end
                end
            end
        end
    end
    -- change_species_characteristics = { sapient immortal can_be_modified add_trait remove_trait
    -- portrait gender can_change_leader add_traits_at_start_of_list } (CChangeSpeciesCharacteristicsEffect
    -- 0x3787680) [V order]: the bits given, one trait added and one removed (the last of each),
    -- the portrait, the gender; can_change_leader: the species' leaders of the countries with its
    -- pops get its portrait and gender
    EFF["change_species_characteristics"] = function(e, ctx)
        local s = SP(ctx)
        if not s or e.value.text then return end
        local p = params(e)
        if p.sapient then set_bit(s, "sapient", yes(p.sapient), false) end
        if p.immortal then set_bit(s, "immortal", yes(p.immortal), true) end
        if p.can_be_modified then set_bit(s, "can_be_modified", yes(p.can_be_modified), false) end
        local add, rem
        for _, x in ipairs(e.value) do
            if x.op and x.key and x.value.text then
                if x.key.text == "add_trait" then add = unq(x.value.text) end
                if x.key.text == "remove_trait" then rem = unq(x.value.text) end
            end
        end
        if add then add_trait(s, add, yes(p.add_traits_at_start_of_list)) end
        if rem then remove_trait(s, rem) end
        if p.portrait then
            local pt = portrait_of(p.portrait, ctx)
            if pt then world.set(s, "portrait", quoted(pt)) end
        end
        if p.gender and p.gender.value.text then
            local sc = target(p.gender, ctx)
            local g = sc and sc.kind == "leader" and unq(field(H.leader(sc.id), "gender")) or unq(p.gender.value.text)
            world.set(s, "gender", g)
        end
        if yes(p.can_change_leader) then
            local cids = {}
            for _, id in ipairs(world.all("country")) do
                for _, x in ipairs(H.scope_species(S("country", id), false)) do
                    if x.id == ctx.this.id then cids[id] = true end
                end
            end
            enforce_on_leaders(ctx.this.id, cids)
        end
        wrote()
    end
    -- rename_species = { name = <entry>|random name_list prompt_country } (CRenameSpeciesEffect
    -- 0x37846c0) [V]: an entry of common/species_names' named_lists: name, plural, the adjective
    -- of it; name_list: one of its entries by the effect's scope random (a human prompt_country is
    -- asked instead: nothing now). name = random: CSpecies::RandomizeName [I: not modelled, reported]
    local function set_names(s, name, plural)
        local function key_block(k) local b = {} world.append(b, "key", k, true) return b end
        local function put(k, b) local en = world.entry(s, k) if en then world.set_entry(s, en, b) else world.append(s, k, b) end end
        put("name", key_block(name))
        put("plural", key_block(plural or name))
        local adj = key_block("%ADJECTIVE%")
        local var = key_block("adjective")
        world.append(var, "value", key_block(name))
        local vars = {}
        world.push(vars, var)
        world.append(adj, "variables", vars)
        put("adjective", adj)
    end
    local function named_lists()
        local out = {}
        for _, d in pairs(require("engine.defs").folder("common/species_names")) do
            if type(d) == "table" and type(d.block) == "table" then out[#out + 1] = d.block end
        end
        return out
    end
    EFF["rename_species"] = function(e, ctx)
        local s = SP(ctx)
        if not s or e.value.text then return end
        local p = params(e)
        local name, list = unq(text_of(p.name)), unq(text_of(p.name_list))
        if name == "random" then I.miss("effect", "rename_species = { name = random }", ctx, e) return end
        for _, nl in ipairs(named_lists()) do
            for _, lx in ipairs(nl) do
                if lx.op and lx.key and type(lx.value) == "table" and (not list or lx.key.text == list) then
                    local entries = {}
                    for _, en in ipairs(lx.value) do
                        if en.op and en.key and type(en.value) == "table" then entries[#entries + 1] = en end
                    end
                    if name then
                        for _, en in ipairs(entries) do
                            if en.key.text == name then
                                set_names(s, unq(dfield(en.value, "name")), unq(dfield(en.value, "plural")))
                                wrote()
                                return
                            end
                        end
                    elseif list and #entries > 0 then
                        local pc = p.prompt_country and target(p.prompt_country, ctx)
                        if pc and pc.kind == "country" and E.is_human and E.is_human(pc.id) then return end
                        local en = entries[eval.scope_draw(ctx) % #entries + 1]
                        set_names(s, unq(dfield(en.value, "name")), unq(dfield(en.value, "plural")))
                        wrote()
                        return
                    end
                end
            end
        end
    end
    -- mutate_species (CMutateSpeciesEffect 0x37724d0 → CSpecies::RandomlyMutateTraits 0x1fc9ae0) [V]:
    -- two global draws r1, r2 (each % 100); c = its traits that can be randomized; c <=
    -- MUTATION_MIN_TRAITS: only an addition; else a removal unless (c < MUTATION_MAX_TRAITS and
    -- r2 < MUTATION_ADD_CHANCE and r1 >= MUTATION_REMOVE_CHANCE), an addition when c <
    -- MUTATION_MAX_TRAITS and (r1 >= MUTATION_REMOVE_CHANCE or r2 < MUTATION_ADD_CHANCE).
    -- [I: the trait removed (one draw over them) and added (one draw over the traits its archetype
    -- allows, randomized, not held, no opposite held)]
    local function randomizable(t)
        local b = def("common/traits", t)
        return b ~= nil and dfield(b, "randomized") ~= "no"
    end
    EFF["mutate_species"] = function(e, ctx)
        local s = SP(ctx)
        if not s or e.value.text == "no" then return end
        local r1, r2 = eval.rand() % 100, eval.rand() % 100
        local mine = {}
        for _, x in ipairs(world.fields(field(s, "traits"), "trait")) do
            if randomizable(unq(x)) then mine[#mine + 1] = unq(x) end
        end
        local c = #mine
        local MIN, MAX = define("NGameplay", "MUTATION_MIN_TRAITS", 1), define("NGameplay", "MUTATION_MAX_TRAITS", 5)
        local ADD, REM = define("NGameplay", "MUTATION_ADD_CHANCE", 50), define("NGameplay", "MUTATION_REMOVE_CHANCE", 50)
        local do_remove, do_add
        if c <= MIN then
            do_add = true
        else
            do_remove = not (c < MAX and r2 < ADD and r1 >= REM)
            do_add = c < MAX and (r1 >= REM or r2 < ADD)
        end
        if do_remove and c > 0 then remove_trait(s, mine[eval.rand() % c + 1]) end
        if do_add then
            local arch = H.archetype_of(ctx.this.id)
            local have = {}
            for _, x in ipairs(world.fields(field(s, "traits"), "trait")) do have[unq(x)] = true end
            local cands = {}
            for _, x in ipairs(H.ordered("common/traits")) do
                local b = x.def.block
                local aa = dfield(b, "allowed_archetypes")
                if aa and set_of(tokens(aa))[arch] and not have[x.name] and dfield(b, "randomized") ~= "no"
                    and not dfield(b, "leader_class") then
                    local ok = true
                    for _, o in ipairs(tokens(dfield(b, "opposites"))) do if have[unq(o)] then ok = false end end
                    if ok then cands[#cands + 1] = x.name end
                end
            end
            if #cands > 0 then add_trait(s, cands[eval.rand() % #cands + 1], false) end
        end
        wrote()
    end

    -- ------------------------------------------------------------------------------------------
    -- species rights

    -- the country's entry for the species (CSpeciesRightsModule::AccessOrCreateSpeciesRights): made
    -- from `from` (else the default) when it has none
    local function rights_for(cid, sid, from)
        local c = obj("country", cid)
        local m = c and world.path(c, "modules", "standard_species_rights_module")
        if type(m) ~= "table" then return nil end
        local entry, own = H.rights_entry(cid, sid)
        if own then return entry end
        local src = from and select(1, H.rights_entry(cid, from)) or field(m, "default")
        entry = {}
        world.append(entry, "species_index", sid)
        for _, x in ipairs(type(src) == "table" and src or {}) do
            if x.op and x.key and x.key.text ~= "species_index" then world.append_entry(entry, copy_node(x)) end
        end
        world.push(world.child(m, "species_rights"), entry)
        return entry
    end
    H.rights_for = rights_for
    -- set_living_standard / set_migration_controls / set_population_controls / set_purge_type = {
    -- country type cooldown } (CSetSpeciesRightsEffect<T> 0x382b790 / 0x3830740 / 0x382f750 /
    -- 0x382d770) [V]: the scope's species' entry in the country's module (made); last_changed_value
    -- the right (before the no-change check); a new value: former_<right> the old one; cooldown:
    -- last_changed_<right> = today + SPECIES_POLICY_YEARS (the cooldown's end)
    local LOCK = {
        living_standard = "last_changed_living_standard", migration_control = "last_changed_migration_control",
        population_control = "last_changed_population_control", purge = "last_changed_purge_type",
    }
    local function rights_effect(field_name, yes_no)
        return function(e, ctx)
            if e.value.text then return end
            local sid = H.species_of(ctx.this)
            local p = params(e)
            local csc = p.country and target(p.country, ctx)
            local cid = csc and csc.kind == "country" and csc.id or H.country_of(ctx.this)
            local v = unq(text_of(p.type))
            if not sid or not cid or not v then return end
            if yes_no then
                if v == "yes" then v = field_name .. "_yes" elseif v == "no" then v = field_name .. "_no" end
            end
            local entry = rights_for(cid, sid)
            if not entry then return end
            world.set(entry, "last_changed_value", field_name)
            local old = unq(field(entry, field_name))
            if old == v then wrote() return end
            if old then world.set(entry, "former_" .. field_name, quoted(old)) end
            world.set(entry, field_name, quoted(v))
            if yes(p.cooldown) and LOCK[field_name] then
                world.set(entry, LOCK[field_name], quoted(date_text(H.now_days() + 360 * define("NGameplay", "SPECIES_POLICY_YEARS", 10))))
            end
            wrote()
        end
    end
    EFF["set_living_standard"] = rights_effect("living_standard")
    EFF["set_migration_controls"] = rights_effect("migration_control", true)
    EFF["set_population_controls"] = rights_effect("population_control", true)
    EFF["set_purge_type"] = rights_effect("purge")
    -- refresh_species_rights (CRefreshSpeciesRightsEffect 0x38218e0 → ConfigureForCountry) [V]: the
    -- entries' validity fixes [I: not modelled; no state written]
    EFF["refresh_species_rights"] = function() end

    -- ------------------------------------------------------------------------------------------
    -- founder, built and dominant species

    -- CCountry::SetFounderSpecies (0x235e620) [V]: founder_species_ref, the new species' rights from
    -- the old's, SetDefaultSpecies [I: ValidateForCountry]
    local function set_founder(cid, new)
        local c = obj("country", cid)
        if not c then return false end
        local old = tonumber(field(c, "founder_species_ref"))
        if old == new then return false end
        world.set(c, "founder_species_ref", new)
        rights_for(cid, new, old)
        world.set(world.child(c, "default_species"), tostring(base_of(new) or new), new)
        return true, old
    end
    -- CLeader::SetSpecies (0x1d07cc0): species, the portrait the new species'
    local function leader_species(l, sid)
        world.set(l, "species", sid)
        local p = field(H.species(sid), "portrait")
        if p then world.set(l, "portrait", quoted(unq(p))) end
    end
    -- change_species = <species> (CChangeSpeciesEffect 0x37207f0) [V]: a pop group's key (merging
    -- into a group of the same key [I: not done]); a leader (and its portrait); an army; a
    -- country's founder species; a colony ship's colonization species
    EFF["change_species"] = function(e, ctx)
        local sid = species_target(e, ctx)
        local sc = ctx.this
        if not sid or not H.species(sid) then return end
        if sc.kind == "leader" then
            local l = H.leader(sc.id)
            if l then leader_species(l, sid) wrote() end
        elseif sc.kind == "army" then
            local o = obj("army", sc.id)
            if o then world.set(o, "species", sid) wrote() end
        elseif sc.kind == "country" then
            if set_founder(sc.id, sid) then wrote() end
        elseif sc.kind == "pop_group" then
            local g = H.group(sc.id)
            local key = g and field(g, "key")
            if type(key) == "table" then world.set(key, "species", sid) wrote() end
        elseif sc.kind == "ship" then
            local o = obj("ship", sc.id)
            if o then world.set(o, "colonize_species", sid) wrote() end
        end
    end
    -- set_built_species = <species> (CSetBuiltSpeciesEffect 0x3720d30 → SetBuiltSpecies 0x235eed0)
    -- [V]: built_species_ref, the species' rights copied from the old built species'
    EFF["set_built_species"] = function(e, ctx)
        local c = C(ctx)
        local sid = species_target(e, ctx)
        if not c or not sid then return end
        local old = tonumber(field(c, "built_species_ref"))
        world.set(c, "built_species_ref", sid)
        rights_for(ctx.this.id, sid, old ~= NO_ID and old or nil)
        wrote()
    end
    -- the country's leaders, armies and colonies' pop groups of a species moved to another
    -- (CCountry::SwapAllSpeciesReferences 0x2360730 [I: what it covers])
    local function swap_all(cid, old, new)
        local c = obj("country", cid)
        for _, k in ipairs(world.list(field(c, "owned_leaders"))) do
            local l = H.leader(tonumber(k))
            if l and tonumber(field(l, "species")) == old then leader_species(l, new) end
        end
        for _, aid in ipairs(world.all("army")) do
            local a = obj("army", aid)
            if a and tonumber(field(a, "owner")) == cid and tonumber(field(a, "species")) == old then world.set(a, "species", new) end
        end
        for _, col in ipairs(world.list(field(c, "controlled_colonies"))) do
            species_mod().replace_groups(tonumber(col), old, new)
        end
    end
    -- change_dominant_species = { species change_all } (CChangeDominantSpeciesEffect 0x376f080) [V]:
    -- the target (last_created: the game's last created species) as the founder species; change_all:
    -- every reference of the old one swapped
    EFF["change_dominant_species"] = function(e, ctx)
        local c = C(ctx)
        if not c then return end
        local p = e.value.text and { species = e } or params(e)
        local sid
        if p.species and unq(p.species.value.text) == "last_created" then
            sid = tonumber(world.meta.last_created_species_ref)
        elseif p.species then
            sid = species_target(p.species, ctx)
        end
        if not sid or not H.species(sid) then return end
        local ok, old = set_founder(ctx.this.id, sid)
        if ok and old and yes(p.change_all) then swap_all(ctx.this.id, old, sid) end
        if ok then wrote() end
    end

    -- ------------------------------------------------------------------------------------------
    -- modification, merging, integration

    -- CSpecies::IsEqual (mode 0) [I: the class, portrait, name, base species, bits and traits]
    local KEYS = { "class", "portrait", "base_ref", "sapient", "immortal", "can_be_modified", "gender" }
    local function trait_set(s)
        local out = {}
        for _, x in ipairs(world.fields(field(s, "traits"), "trait")) do out[unq(x)] = true end
        return out
    end
    local function identical(a, b)
        for _, k in ipairs(KEYS) do
            local x, y = field(a, k), field(b, k)
            if (x and unq(x)) ~= (y and unq(y)) then return false end
        end
        if unq(field(field(a, "name") or {}, "key")) ~= unq(field(field(b, "name") or {}, "key")) then return false end
        local ta, tb = trait_set(a), trait_set(b)
        for t in pairs(ta) do if not tb[t] then return false end end
        for t in pairs(tb) do if not ta[t] then return false end end
        return true
    end
    -- modify_species = { species add_trait remove_trait add_random_species_trait sapient
    -- ideal_planet_class portrait base inherit_parent_rights add_traits_at_start_of_list
    -- change_scoped_species effect } (CModifySpecies 0x3734b00) [V order]: a copy of the source
    -- species (not its base_ref), the traits added then removed, sapient, the ideal planet class,
    -- portrait, the base species (none / auto: the source's / a target's) and
    -- inherit_parent_rights; an identical species reused, else a new one (last_created_species);
    -- the scope's species changed to it (a pop group; a planet's groups; a country's colonies,
    -- leaders); the effect in its scope. [I: add_random_species_trait not modelled, reported]
    EFF["modify_species"] = function(e, ctx)
        if e.value.text then return end
        local p = params(e)
        local src = p.species and species_target(p.species, ctx) or H.species_of(ctx.this)
        local s = src and H.species(src)
        if not s then return end
        local copy = {}
        for _, x in ipairs(s) do
            if not (x.op and x.key and x.key.text == "base_ref") then copy[#copy + 1] = copy_node(x) end
        end
        local at_start = yes(p.add_traits_at_start_of_list)
        for _, x in ipairs(e.value) do
            if x.op and x.key and x.key.text == "add_trait" and x.value.text then add_trait(copy, unq(x.value.text), at_start) end
        end
        for _, x in ipairs(e.value) do
            if x.op and x.key and x.key.text == "remove_trait" and x.value.text then remove_trait(copy, unq(x.value.text)) end
        end
        if p.add_random_species_trait then I.miss("effect", "modify_species: add_random_species_trait", ctx, e) end
        if p.sapient then set_bit(copy, "sapient", yes(p.sapient), false) end
        if p.ideal_planet_class and p.ideal_planet_class.value.text then
            world.set(copy, "ideal_planet_class", quoted(unq(p.ideal_planet_class.value.text)))
        end
        if p.portrait then
            local pt = portrait_of(p.portrait, ctx)
            if pt then world.set(copy, "portrait", quoted(pt)) end
        end
        local bv = p.base and unq(p.base.value.text)
        if bv ~= "none" then
            local b
            if not p.base or bv == "auto" then b = base_of(src) else b = base_of(species_target(p.base, ctx)) end
            if b then world.set(copy, "base_ref", b) end
        end
        set_bit(copy, "inherit_parent_rights", yes(p.inherit_parent_rights), true)
        local new
        for _, id in ipairs(world.all("species")) do
            local o = H.species(id)
            if o and id ~= 0 and identical(o, copy) then new = id break end
        end
        if not new then
            new = require("engine.script.objects").create("species", copy)
            world.meta.last_created_species_ref = new
        end
        if p.change_scoped_species == nil or yes(p.change_scoped_species) then
            local sc = ctx.this
            local old = H.species_of(sc)
            if sc.kind == "pop_group" then
                local key = field(H.group(sc.id), "key")
                if type(key) == "table" then world.set(key, "species", new) end
            elseif (sc.kind == "planet" or sc.kind == "colony") and old then
                local col = sc.kind == "colony" and sc.id or H.colony_of_planet(sc.id)
                if col then species_mod().replace_groups(col, old, new) end
            elseif sc.kind == "country" and old then
                swap_all(sc.id, old, new)
            elseif sc.kind == "leader" then
                leader_species(H.leader(sc.id), new)
            end
        end
        if p.effect and p.effect.value.text == nil then
            eval.effect(p.effect.value, eval.seed_scope(I.push(ctx, S("species", new)), eval.scope_draw(ctx)))
        end
        wrote()
    end
    -- merge_species = yes (CMergeSpeciesEffect 0x37ebcb0 → CCountry::HandleIdenticalSpeciesMerge
    -- 0x237cf60) [V]: the country's species identical to an earlier one with the same rights: its
    -- flags onto the survivor, its pops on each colony moved to it (HandleSpeciesModification)
    local function rights_equal(cid, a, b)
        local ea, eb = H.rights_entry(cid, a), H.rights_entry(cid, b)
        if type(ea) ~= "table" or type(eb) ~= "table" then return ea == eb end
        for _, x in ipairs(ea) do
            if x.op and x.key and x.key.text ~= "species_index" and x.value.text and unq(field(eb, x.key.text)) ~= unq(x.value.text) then
                return false
            end
        end
        return true
    end
    EFF["merge_species"] = function(e, ctx)
        local c = C(ctx)
        if not c or e.value.text ~= "yes" then return end
        local cid = ctx.this.id
        local list = H.scope_species(ctx.this, false)
        local merged = false
        for i = 2, #list do
            local b = list[i].id
            for j = 1, i - 1 do
                local a = list[j].id
                local sa, sb = H.species(a), H.species(b)
                if sa and sb and identical(sa, sb) and rights_equal(cid, a, b) then
                    local fb = field(sb, "flags")
                    if type(fb) == "table" then
                        local fa = world.child(sa, "flags")
                        for _, x in ipairs(fb) do world.append_entry(fa, copy_node(x)) end
                        remove_key(sb, "flags")
                    end
                    for _, col in ipairs(world.list(field(c, "controlled_colonies"))) do
                        species_mod().handle(cid, tonumber(col), b, a)
                    end
                    merged = true
                    break
                end
            end
        end
        if merged then wrote() end
    end
    -- integrate_species = yes (CIntegrateSpeciesEffect 0x37ebbb0 → CCountry::
    -- HandleSubSpeciesIntegration 0x237b2c0) [V]: [I: the integration step not modelled, reported]
    EFF["integrate_species"] = function(e, ctx)
        if not C(ctx) or e.value.text ~= "yes" then return end
        I.miss("effect", "integrate_species (HandleSubSpeciesIntegration)", ctx, e)
    end
end
