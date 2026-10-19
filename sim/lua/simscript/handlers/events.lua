-- simscript/handlers/events.lua : the keywords of events, situations, anomalies, archaeology,
-- relics, special projects, first contacts, astral rifts, cosmic storms, the grand archive's
-- exhibits and specimens, missions and event chains (docs/script_events.md).
--
-- Each keyword's class in the Linux 4.5.2 build is named in its comment with [V] (read in the
-- binary: /opt/stellaris-headless/re on 10.5.0.24) or [I] (from the game's script documentation and
-- the save's fields, CX::WriteMembers' names). The world is the save (engine.world): a handler reads
-- and writes the fields the game writes, so a save written after it has the change. The effects
-- that make or remove objects are in handlers/events_effects.lua.
--
-- The objects of these scopes and their stores in the save:
--   archaeological_site  archaeological_sites = { sites = { id = { location type index clues ... } } }
--   astral_rift          astral_rifts = { rifts = { id = { coordinate owner explorer leader ... } } }
--   cosmic_storm         storms = { storms = { id = { type cosmic_storm_start_position ... } } }
--   cosmic_storm_influence_field  storm_influence_fields = { storm_influence_fields = { id = { center
--                        radius influence ... } } }
--   mission              missions = { id = { mission scope status operator issuer ... } }
--   exhibit              exhibits = { id = { exhibit_state activated specimen } }
--   first_contact, situation  (engine/first_contact.lua, engine/situations.lua)

return function(eval)
    local I = eval._internal
    local S, NONE, compare, sync = I.S, I.NONE, I.compare, I.sync
    local stats = I.stats
    local TRIG, EFF, LINKS, LISTS = eval.TRIG, eval.EFF, eval.LINKS, eval.LISTS
    local E = I.E
    local world = require("engine.world")
    local defs = setmetatable({}, { __index = function(_, k) return require("engine.defs")[k] end })

    local NO_ID = 4294967295
    local M = {}   -- shared with handlers/events_effects.lua (eval._events)
    eval._events = M

    -- ------------------------------------------------------------------------------------------
    -- the stores

    -- the scope kinds of these objects and their stores (inner names: two are nested in the save)
    local STORES = {
        archaeological_site = { "archaeological_sites", "sites" },
        astral_rift = { "astral_rifts", "rifts" },
        cosmic_storm = { "storms", "storms" },
        cosmic_storm_influence_field = { "storm_influence_fields", "storm_influence_fields" },
        mission = { nil, "missions" },
        exhibit = { nil, "exhibits" },
    }
    for kind, s in pairs(STORES) do
        world.KINDS[kind] = world.KINDS[kind] or s[2]
    end
    -- a store's holder, registered with engine.world when the save has it empty (world.ensure_store
    -- only finds top-level ones: these are nested)
    function M.holder(kind)
        local s = STORES[kind]
        local name = world.KINDS[kind]
        if world.store_blocks[name] then return world.store_blocks[name] end
        if not s or not world.tree then return nil end
        local holder
        if s[1] then
            local outer
            for _, e in ipairs(world.tree) do
                if e.op and e.key and e.key.text == s[1] and type(e.value) == "table" and e.value.text == nil then
                    outer = e.value
                    break
                end
            end
            if not outer then
                outer = {}
                world.tree[#world.tree + 1] = { key = { text = s[1] }, op = "=", value = outer }
            end
            holder = world.field(outer, s[2])
            if type(holder) ~= "table" then holder = world.child(outer, s[2]) end
        else
            return world.ensure_store(kind)
        end
        world.stores[name], world.ids[name], world.entries[name] = world.stores[name] or {}, world.ids[name] or {}, world.entries[name] or {}
        world.store_blocks[name] = holder
        return holder
    end
    -- the next id of a store (one past the highest)
    function M.next_id(kind)
        local max = -1
        for _, id in ipairs(world.all(kind)) do
            if id > max then max = id end
        end
        return max + 1
    end

    local function obj(sc, kind)
        if not sc or sc == NONE or sc.kind ~= kind then return nil end
        return world.object(kind, sc.id)
    end
    M.obj = obj
    local function unq(v)
        if type(v) ~= "string" then return v end
        return (v:gsub('^"(.*)"$', "%1"))
    end
    M.unq = unq
    local function ref(v)
        local n = tonumber(v)
        if not n or n == NO_ID then return nil end
        return n
    end
    M.ref = ref
    local function set_quoted(o, key, text)
        world.set(o, key, text)
        local t = world.token_entry(o, key)
        if t then t.value.quoted = true end
    end
    M.set_quoted = set_quoted
    local function script_write() stats.script = stats.script + 1 end
    M.script_write = script_write
    local function scopes(kind, ids)
        local out = {}
        for _, id in ipairs(ids) do out[#out + 1] = S(kind, id) end
        return out
    end
    local function all_of(kind)
        local out = {}
        for _, id in ipairs(world.all(kind)) do
            local o = world.object(kind, id)
            if o and not (world.field(o, "to_be_killed") == "yes") then out[#out + 1] = id end
        end
        return out
    end
    M.all_of = all_of
    local function country_of(sc)
        if not sc or sc == NONE then return nil end
        if sc.kind == "country" then return sc.id, world.object("country", sc.id) end
        return nil
    end
    M.country_of = country_of
    -- the scope a statement's value names (`= root`, `= event_target:x`)
    local function target(text, ctx, e)
        if not text then return nil end
        local found, sc = eval.resolve(text, ctx, e)
        if found and sc and sc ~= NONE then return sc end
        return nil
    end
    M.target = target
    -- a block parameter's statement / text
    local function param(block, key)
        if type(block) ~= "table" or block.text then return nil end
        for _, x in ipairs(block) do
            if x.op and x.key and x.key.text:lower() == key then return x end
        end
        return nil
    end
    M.param = param
    local function param_text(block, key)
        local x = param(block, key)
        return x and x.value.text and unq(x.value.text) or nil
    end
    M.param_text = param_text
    -- `<trigger> <op> <value>` on a number
    local function cmp(v, e, ctx)
        if v == nil then return false end
        if e.value.text == nil then
            local x = param(e.value, "value")
            if not x then return false end
            return compare(v, x.op, eval.value(x.value, ctx, x))
        end
        return compare(v, e.op, eval.value(e.value, ctx, e))
    end
    M.cmp = cmp
    local function want_yes(e) return e.value.text ~= "no" end
    -- the save's top-level field
    local function meta(key)
        return world.meta and world.meta[key] or (world.tree and world.field(world.tree, key))
    end
    M.meta = meta

    -- a country's modules block (`modules = { grand_archive_module = { } }`)
    local function module_of(c, name, create)
        local m = world.field(c, "modules")
        if type(m) ~= "table" then
            if not create then return nil end
            m = world.child(c, "modules")
        end
        local b = world.field(m, name)
        if type(b) ~= "table" then
            if not create then return nil end
            b = world.child(m, name)
        end
        return b
    end
    M.module_of = module_of
    -- the country's events block (CCountryEventManager: missions, event_chain, special_project)
    local function events_block(c, create)
        local b = world.field(c, "events")
        if type(b) ~= "table" then
            if not create then return nil end
            b = world.child(c, "events")
        end
        return b
    end
    M.events_block = events_block

    -- a list of ids written `key = { 1 2 3 }`
    local function id_list(b, key)
        local out = {}
        local l = world.field(b, key)
        for _, x in ipairs(type(l) == "table" and l or {}) do
            local n = tonumber(x.text)
            if n then out[#out + 1] = n end
        end
        return out
    end
    M.id_list = id_list
    -- a list of strings written `key = { "a" "b" }`
    local function text_list(b, key)
        local out = {}
        local l = world.field(b, key)
        for _, x in ipairs(type(l) == "table" and l or {}) do
            if x.text then out[#out + 1] = unq(x.text) end
        end
        return out
    end
    M.text_list = text_list

    -- a coordinate's system (`coordinate = { x y origin = <system> }`)
    local function origin_of(b, key)
        local c = world.field(b, key or "coordinate")
        return type(c) == "table" and ref(world.field(c, "origin")) or nil
    end
    M.origin_of = origin_of

    -- a spatial location `location = { type = 2 id = 925 }` (0 system, 1 ship, 2 planet [I])
    local LOC_KIND = { ["0"] = "system", ["1"] = "ship", ["2"] = "planet", ["3"] = "megastructure",
        ["4"] = "ambient_object", ["5"] = "starbase" }
    M.LOC_KIND = LOC_KIND

    -- ------------------------------------------------------------------------------------------
    -- lists (every_, random_, ordered_, any_, count_ of each)

    -- every astral rift (CAstralRiftListBuilder [I])
    LISTS["astral_rift"] = function() return scopes("astral_rift", all_of("astral_rift")) end
    -- every cosmic storm in the galaxy (CCosmicStormManager::GetStorms [V])
    LISTS["cosmic_storm"] = function() return scopes("cosmic_storm", all_of("cosmic_storm")) end
    -- the systems a storm can start or end in: the galaxy's systems without a storm of their own and
    -- outside every storm's influence [I: the list builders' conditions not read]
    local function storm_free_systems()
        local out = {}
        for _, id in ipairs(world.all("system")) do
            local g = world.object("system", id)
            if g and not ref(world.field(g, "storm")) then out[#out + 1] = S("system", id) end
        end
        return out
    end
    LISTS["cosmic_storm_start_position"] = storm_free_systems
    LISTS["cosmic_storm_end_position"] = storm_free_systems
    -- a country's collected exhibits (CExhibitListBuilder: CGrandArchiveCountryModule::
    -- GetCollectedExhibits [V]; the module's `exhibits = { ids }`)
    LISTS["exhibit"] = function(sc)
        local _, c = country_of(sc)
        local ga = c and module_of(c, "grand_archive_module", false)
        if not ga then return {} end
        local out = {}
        for _, id in ipairs(id_list(ga, "exhibits")) do
            local x = world.object("exhibit", id)
            if x and world.field(x, "specimen") then out[#out + 1] = S("exhibit", id) end
        end
        return out
    end
    -- the first contacts a country is engaging in, active and complete (the contacts it owns)
    LISTS["first_contact"] = function(sc)
        local cid = country_of(sc)
        if not cid then return {} end
        local out = {}
        for _, id in ipairs(world.all("first_contact")) do
            local fc = world.object("first_contact", id)
            if fc and ref(world.field(fc, "owner")) == cid then out[#out + 1] = S("first_contact", id) end
        end
        return out
    end
    -- the missions a country issued (CMission `issuer`) and the ones it has (`operator` [I])
    local function missions_by(field)
        return function(sc)
            local cid = country_of(sc)
            if not cid then return {} end
            local out = {}
            for _, id in ipairs(all_of("mission")) do
                if ref(world.field(world.object("mission", id), field)) == cid then out[#out + 1] = S("mission", id) end
            end
            return out
        end
    end
    LISTS["issued_mission"] = missions_by("issuer")
    LISTS["owned_mission"] = missions_by("operator")
    -- the systems an influence field covers: its center's system and the systems within its radius
    -- of it [I: CCosmicStormInfluenceField's influence_groups are not read]
    local function field_center_system(f)
        local c = ref(world.field(f, "center"))
        if not c then return nil end
        return world.object("planet", c) and tonumber(world.path(world.object("planet", c), "coordinate", "origin")) or nil
    end
    M.field_center_system = field_center_system
    local function system_xy(id)
        local g = world.object("system", id)
        local c = g and world.field(g, "coordinate")
        if type(c) ~= "table" then return nil end
        return tonumber(world.field(c, "x")) or 0, tonumber(world.field(c, "y")) or 0
    end
    M.system_xy = system_xy
    local function field_systems(f)
        local center = field_center_system(f)
        local out = {}
        if not center then return out end
        local cx, cy = system_xy(center)
        local r = tonumber(world.field(f, "radius")) or 0
        for _, id in ipairs(world.all("system")) do
            local x, y = system_xy(id)
            if x and cx and ((x - cx) ^ 2 + (y - cy) ^ 2) <= r * r then out[#out + 1] = id end
        end
        return out
    end
    M.field_systems = field_systems
    LISTS["system_in_cosmic_storm_influence_field"] = function(sc)
        local f = obj(sc, "cosmic_storm_influence_field")
        if not f then return {} end
        return scopes("system", field_systems(f))
    end
    -- the situations targeting a colony carrier (a planet or a ship: CTargetingSituationListBuilder
    -- [V]: the situations whose `target` is it)
    local TARGET_TYPE = { planet = "planet", ship = "ship" }
    LISTS["targeting_situation"] = function(sc)
        if not sc or not TARGET_TYPE[sc.kind] then return {} end
        local out = {}
        for _, id in ipairs(all_of("situation")) do
            local tg = world.field(world.object("situation", id), "target")
            if type(tg) == "table" and tostring(world.field(tg, "type")) == TARGET_TYPE[sc.kind]
                and tonumber(world.field(tg, "id")) == sc.id then
                out[#out + 1] = S("situation", id)
            end
        end
        return out
    end

    -- ------------------------------------------------------------------------------------------
    -- links

    -- astral_rift: the astral rift in a system (its coordinate's origin), or the one a leader is
    -- exploring (the rift's `leader`) [I]
    LINKS["astral_rift"] = function(cur)
        if not cur or cur == NONE then return nil end
        for _, id in ipairs(all_of("astral_rift")) do
            local r = world.object("astral_rift", id)
            if (cur.kind == "system" and origin_of(r) == cur.id) or (cur.kind == "leader" and ref(world.field(r, "leader")) == cur.id) then
                return S("astral_rift", id)
            end
        end
        return nil
    end
    -- excavator_fleet: the fleet excavating an arc site (`excavator_fleet`)
    LINKS["excavator_fleet"] = function(cur)
        local s = obj(cur, "archaeological_site")
        local f = s and ref(world.field(s, "excavator_fleet"))
        return (f and world.object("fleet", f)) and S("fleet", f) or nil
    end
    -- explorer: the country whose leader is exploring, or explored, an astral rift (`explorer`)
    LINKS["explorer"] = function(cur)
        local r = obj(cur, "astral_rift")
        local c = r and ref(world.field(r, "explorer"))
        return (c and world.object("country", c)) and S("country", c) or nil
    end
    -- issuer: a mission's issuer (`issuer`)
    LINKS["issuer"] = function(cur)
        local m = obj(cur, "mission")
        local c = m and ref(world.field(m, "issuer"))
        return (c and world.object("country", c)) and S("country", c) or nil
    end
    -- last_created_cosmic_storm / _influence_field: the save's `last_created_cosmic_storm` (the
    -- game's last created; the effects below set it)
    LINKS["last_created_cosmic_storm"] = function()
        local id = ref(meta("last_created_cosmic_storm"))
        return (id and world.object("cosmic_storm", id)) and S("cosmic_storm", id) or nil
    end
    LINKS["last_created_cosmic_storm_influence_field"] = function()
        local id = ref(meta("last_created_cosmic_storm_influence_field"))
        return (id and world.object("cosmic_storm_influence_field", id)) and S("cosmic_storm_influence_field", id) or nil
    end

    -- ------------------------------------------------------------------------------------------
    -- situations

    -- (engine.situations requires simscript.eval: taken when first used, not while eval loads)
    local situations = setmetatable({}, { __index = function(_, k) return require("engine.situations")[k] end })
    -- the bar's bounds (CSituation: the first stage's start, the last one's end; the type's
    -- start_value without stage durations)
    local function situation_bounds(s)
        local d = world.blocks(world.field(s, "stage_durations"))
        local t = situations.type(unq(world.field(s, "type")))
        local start = d[1] and tonumber(world.field(d[1], "start")) or (t and t.start_value or 0)
        local stop = d[#d] and tonumber(world.field(d[#d], "end")) or 100
        return start, stop, t
    end
    M.situation_bounds = situation_bounds
    -- situation_progress_percent >= 33: the progress as a percentage of the bar (from its start to
    -- its end) [I: CSituationProgressPercentTrigger not read; the docs]
    TRIG["situation_progress_percent"] = function(e, ctx)
        local s = obj(ctx.this, "situation")
        if not s then return false end
        local start, stop = situation_bounds(s)
        local p = tonumber(world.field(s, "progress")) or 0
        local pct = stop ~= start and (p - start) * 100 / (stop - start) or 0
        return cmp(pct, e, ctx)
    end
    -- an approach of a situation's type (`approach = { name = <key> potential allow ... }`)
    local function approach_def(s, key)
        local _, _, t = situation_bounds(s)
        if not t then return nil end
        for _, e in ipairs(t.block) do
            if e.op and e.key and e.key.text == "approach" and type(e.value) == "table" and e.value.text == nil
                and unq(defs.field(e.value, "name")) == key then
                return e.value
            end
        end
        return nil
    end
    M.approach_def = approach_def
    -- CSituation::IsApproachAllowed: its potential and allow with the situation as scope [V: the
    -- trigger and the effect both call it]
    local function approach_allowed(sid, a)
        local ctx = eval.new_ctx(S("situation", sid))
        local pot = defs.field(a, "potential")
        if type(pot) == "table" and not eval.trigger(pot, ctx) then return false end
        local allow = defs.field(a, "allow")
        if type(allow) == "table" and not eval.trigger(allow, ctx) then return false end
        return true
    end
    M.approach_allowed = approach_allowed
    -- can_set_situation_approach = <approach> (CCanSetSituationApproachTrigger [V])
    TRIG["can_set_situation_approach"] = function(e, ctx)
        local s = obj(ctx.this, "situation")
        local a = s and approach_def(s, unq(e.value.text))
        return a ~= nil and approach_allowed(ctx.this.id, a)
    end

    -- ------------------------------------------------------------------------------------------
    -- relics (CCountry: `relics = { "a" }`, last_received_relic, last_lost_relic,
    -- last_activated_relic)

    local function relics_of(c) return text_list(c, "relics") end
    M.relics_of = relics_of
    -- num_owned_relics > 1 (CNumOwnedRelics [V])
    TRIG["num_owned_relics"] = function(e, ctx)
        local _, c = country_of(ctx.this)
        if not c then return false end
        return cmp(#relics_of(c), e, ctx)
    end
    -- last_activated_relic / last_received_relic / last_lost_relic = <key> (CCountry::
    -- GetLastActivatedRelic ... [V]); is_last_lost_relic / is_last_received_relic the same reading
    -- (CIsLastLostRelic, CIsLastReceivedRelic [V])
    local function last_relic(field)
        return function(e, ctx)
            local _, c = country_of(ctx.this)
            if not c then return false end
            return unq(world.field(c, field)) == unq(e.value.text)
        end
    end
    TRIG["last_activated_relic"] = last_relic("last_activated_relic")
    TRIG["last_received_relic"] = last_relic("last_received_relic")
    TRIG["last_lost_relic"] = last_relic("last_lost_relic")
    TRIG["is_last_received_relic"] = last_relic("last_received_relic")
    TRIG["is_last_lost_relic"] = last_relic("last_lost_relic")

    -- ------------------------------------------------------------------------------------------
    -- the grand archive (CGrandArchiveCountryModule: the country's modules' grand_archive_module =
    -- { exhibits = { ids } storage_slots rarity last_acquired_exhibit ... }; an exhibit =
    -- { exhibit_state activated specimen }; common/specimens: type (the collection category) and
    -- rarity)

    local function specimen_def(key)
        local d = key and defs.get("common/specimens", key)
        return d and d.block or nil
    end
    M.specimen_def = specimen_def
    -- a specimen's rarity (its inline script grand_archive/set_specimen_rarity RARITY = x: expanded
    -- by engine.defs into `rarity = x` [I])
    local function specimen_rarity(key)
        local b = specimen_def(key)
        return b and unq(defs.field(b, "rarity")) or nil
    end
    local function specimen_type(key)
        local b = specimen_def(key)
        return b and unq(defs.field(b, "type")) or nil
    end
    M.specimen_rarity, M.specimen_type = specimen_rarity, specimen_type
    local function archive(c, create) return module_of(c, "grand_archive_module", create) end
    M.archive = archive
    -- the country's collected specimens (the exhibits that hold one)
    local function specimens_of(c)
        local ga = archive(c, false)
        local out = {}
        for _, id in ipairs(ga and id_list(ga, "exhibits") or {}) do
            local x = world.object("exhibit", id)
            local sp = x and unq(world.field(x, "specimen"))
            if sp then out[#out + 1] = { id = id, key = sp, block = x } end
        end
        return out
    end
    M.specimens_of = specimens_of
    local function has_specimen(c, key)
        for _, s in ipairs(specimens_of(c)) do
            if s.key == key then return s end
        end
        return nil
    end
    M.has_specimen = has_specimen
    -- an exhibit slot free for a specimen of a category (an unlocked exhibit of that type with no
    -- specimen [I: HasAvailableExhibit not read])
    local function free_exhibit(c, category)
        local ga = archive(c, false)
        for _, id in ipairs(ga and id_list(ga, "exhibits") or {}) do
            local x = world.object("exhibit", id)
            if x and not world.field(x, "specimen") and (category == nil or unq(world.field(x, "type")) == category) then
                return id, x
            end
        end
        return nil
    end
    M.free_exhibit = free_exhibit
    -- acquired_specimen_count > n (CAcquiredSpecimenCount: GetCollectedSpecimens [V])
    TRIG["acquired_specimen_count"] = function(e, ctx)
        local _, c = country_of(ctx.this)
        if not c then return false end
        return cmp(#specimens_of(c), e, ctx)
    end
    -- has_specimen = <specimen/exhibit> (CHasSpecimen [V])
    TRIG["has_specimen"] = function(e, ctx)
        local _, c = country_of(ctx.this)
        if not c then return false end
        local sc = target(e.value.text, ctx, e)
        if sc and sc.kind == "exhibit" then
            local x = world.object("exhibit", sc.id)
            return x ~= nil and has_specimen(c, unq(world.field(x, "specimen"))) ~= nil
        end
        return has_specimen(c, unq(e.value.text)) ~= nil
    end
    -- can_give_specimen = <specimen>: not had yet and an exhibit slot free (CCanGiveSpecimen:
    -- HasAvailableExhibit, HasSpecimen [V])
    TRIG["can_give_specimen"] = function(e, ctx)
        local _, c = country_of(ctx.this)
        local key = unq(e.value.text)
        if not c or not specimen_def(key) then return false end
        if has_specimen(c, key) then return false end
        return free_exhibit(c, specimen_type(key)) ~= nil
    end
    -- the last acquired exhibit (`last_acquired_exhibit = { specimen from_trade }` [I])
    local function last_acquired(c)
        local ga = archive(c, false)
        local l = ga and world.field(ga, "last_acquired_exhibit")
        return type(l) == "table" and l or nil
    end
    M.last_acquired = last_acquired
    TRIG["is_last_acquired_specimen"] = function(e, ctx)
        local _, c = country_of(ctx.this)
        local l = c and last_acquired(c)
        return l ~= nil and unq(world.field(l, "specimen")) == unq(e.value.text)
    end
    TRIG["is_last_acquired_specimen_from_trade"] = function(e, ctx)
        local _, c = country_of(ctx.this)
        local l = c and last_acquired(c)
        if not l then return false end
        return (world.field(l, "from_trade") == "yes") == want_yes(e)
    end
    TRIG["is_last_acquired_specimen_rarity"] = function(e, ctx)
        local _, c = country_of(ctx.this)
        local l = c and last_acquired(c)
        return l ~= nil and specimen_rarity(unq(world.field(l, "specimen"))) == unq(e.value.text)
    end
    -- is_exhibit_active = yes (CIsExhibitActive: the exhibit's `activated` [I])
    TRIG["is_exhibit_active"] = function(e, ctx)
        local x = obj(ctx.this, "exhibit")
        if not x then return false end
        return (world.field(x, "activated") == "yes") == want_yes(e)
    end
    -- is_specimen_category / is_specimen_rarity = <key>: the exhibit's specimen's type / rarity
    TRIG["is_specimen_category"] = function(e, ctx)
        local x = obj(ctx.this, "exhibit")
        return x ~= nil and specimen_type(unq(world.field(x, "specimen"))) == unq(e.value.text)
    end
    TRIG["is_specimen_rarity"] = function(e, ctx)
        local x = obj(ctx.this, "exhibit")
        return x ~= nil and specimen_rarity(unq(world.field(x, "specimen"))) == unq(e.value.text)
    end

    -- ------------------------------------------------------------------------------------------
    -- archaeological sites, first contacts and astral rifts: their stages

    local function site(sc) return obj(sc, "archaeological_site") end
    M.site = site
    -- the stage's site of a scope of the three (`days_left`, `last_roll`, `difficulty` are fields of
    -- all three)
    local function staged(sc)
        if not sc or sc == NONE then return nil end
        if sc.kind == "archaeological_site" or sc.kind == "first_contact" or sc.kind == "astral_rift" then
            return world.object(sc.kind, sc.id)
        end
        return nil
    end
    -- is_site_at_stage >= n: the site's stage index (`index`)
    TRIG["is_site_at_stage"] = function(e, ctx)
        local s = site(ctx.this)
        return s ~= nil and cmp(tonumber(world.field(s, "index")) or 0, e, ctx)
    end
    -- is_site_days_to_next_die_roll >= n: `days_left` (a first contact's GetDaysLeftUntilRoll [V])
    TRIG["is_site_days_to_next_die_roll"] = function(e, ctx)
        local s = staged(ctx.this)
        if not s or ctx.this.kind == "astral_rift" then return false end
        return cmp(math.floor(tonumber(world.field(s, "days_left")) or 0), e, ctx)
    end
    -- is_site_last_die_result >= n: `last_roll`
    TRIG["is_site_last_die_result"] = function(e, ctx)
        local s = staged(ctx.this)
        return s ~= nil and cmp(tonumber(world.field(s, "last_roll")) or 0, e, ctx)
    end
    -- is_current_stage_difficulty >= n: an arc site's `difficulty`, a rift's GetCurrentDifficulty, a
    -- first contact's GetCurrentStageDifficulty (its difficulty + the contact country's malus:
    -- engine/first_contact.lua) [V]
    TRIG["is_current_stage_difficulty"] = function(e, ctx)
        local s = staged(ctx.this)
        if not s then return false end
        local d = tonumber(world.field(s, "difficulty")) or 0
        if ctx.this.kind == "first_contact" then
            local ok, fcm = pcall(require, "engine.first_contact")
            if ok and fcm.malus then d = d + fcm.malus(ctx.this.id) end
        end
        return cmp(d, e, ctx)
    end
    -- is_site_last_excavator = <country> (`last_excavator_country`)
    TRIG["is_site_last_excavator"] = function(e, ctx)
        local s = site(ctx.this)
        local c = target(e.value.text, ctx, e)
        return s ~= nil and c ~= nil and c.kind == "country" and ref(world.field(s, "last_excavator_country")) == c.id
    end
    -- is_site_locked = yes (`locked`)
    TRIG["is_site_locked"] = function(e, ctx)
        local s = site(ctx.this)
        if not s then return false end
        return (world.field(s, "locked") == "yes") == want_yes(e)
    end
    -- is_site_type = <type>
    TRIG["is_site_type"] = function(e, ctx)
        local s = site(ctx.this)
        return s ~= nil and unq(world.field(s, "type")) == unq(e.value.text)
    end
    -- is_site_under_excavation = yes: an excavator fleet (`excavator_fleet`) [I]
    TRIG["is_site_under_excavation"] = function(e, ctx)
        local s = site(ctx.this)
        if not s then return false end
        local f = ref(world.field(s, "excavator_fleet"))
        return (f ~= nil and world.object("fleet", f) ~= nil) == want_yes(e)
    end
    -- is_current_excavator_fleet = <fleet>
    TRIG["is_current_excavator_fleet"] = function(e, ctx)
        local s = site(ctx.this)
        local f = target(e.value.text, ctx, e)
        return s ~= nil and f ~= nil and f.kind == "fleet" and ref(world.field(s, "excavator_fleet")) == f.id
    end
    -- can_spawn_random_archaeological_site = yes: a planet with no site at it (CArchaeologicalSite
    -- Manager::CanCreateRandomSite [V]; its conditions [I]: no site at the planet and a site type
    -- whose potential holds there)
    local function site_at(kind, id)
        for _, sid in ipairs(all_of("archaeological_site")) do
            local l = world.field(world.object("archaeological_site", sid), "location")
            if type(l) == "table" and LOC_KIND[tostring(world.field(l, "type"))] == kind and tonumber(world.field(l, "id")) == id then
                return sid
            end
        end
        return nil
    end
    M.site_at = site_at
    TRIG["can_spawn_random_archaeological_site"] = function(e, ctx)
        if ctx.this.kind ~= "planet" or not world.object("planet", ctx.this.id) then return false end
        local ok = site_at("planet", ctx.this.id) == nil
        return ok == want_yes(e)
    end

    -- astral rifts
    -- has_astral_rift = yes: a rift in the system (CHasAstralRiftTrigger [V])
    TRIG["has_astral_rift"] = function(e, ctx)
        if ctx.this.kind ~= "system" then return false end
        return (LINKS.astral_rift(ctx.this) ~= nil) == want_yes(e)
    end
    -- astral_rifts_completed >= n (the country's `astral_rifts_completed` [I])
    TRIG["astral_rifts_completed"] = function(e, ctx)
        local _, c = country_of(ctx.this)
        if not c then return false end
        return cmp(tonumber(world.field(c, "astral_rifts_completed")) or 0, e, ctx)
    end
    -- is_astral_rift_explored = <rift id>: a rift of that type explored by the country (its
    -- `explorer`, or the country among a completed rift's explorers) [I: IsAstralRiftExploredBy
    -- Country not read]
    TRIG["is_astral_rift_explored"] = function(e, ctx)
        local cid = country_of(ctx.this)
        if not cid then return false end
        local want = unq(e.value.text)
        for _, id in ipairs(world.all("astral_rift")) do
            local r = world.object("astral_rift", id)
            if r and ref(world.field(r, "explorer")) == cid and (unq(world.field(r, "type")) == want or tostring(id) == want) then
                return true
            end
        end
        return false
    end
    -- is_astral_rift_pool_empty = yes: the game's astral rift event pool (the save's
    -- `astral_rift_event_pool`) has no event left [I]
    TRIG["is_astral_rift_pool_empty"] = function(e, ctx)
        local p = meta("astral_rift_event_pool")
        local n = 0
        if type(p) == "table" then
            for _, x in ipairs(p) do
                if x.text or x.op then n = n + 1 end
            end
        end
        return (n == 0) == want_yes(e)
    end
    -- astral_rift_relative_difficulty >= n: the explorer leader's level less the rift's current
    -- difficulty (CAstralRiftRelativeDifficultyTrigger: GetExplorerLeader, GetCurrentDifficulty [V])
    TRIG["astral_rift_relative_difficulty"] = function(e, ctx)
        local r = obj(ctx.this, "astral_rift")
        if not r then return false end
        local l = ref(world.field(r, "leader"))
        local lb = l and world.object("leader", l)
        if not lb then return false end
        local level = tonumber(world.field(lb, "level")) or 0
        return cmp(level - (tonumber(world.field(r, "difficulty")) or 0), e, ctx)
    end

    -- ------------------------------------------------------------------------------------------
    -- cosmic storms

    -- num_cosmic_storms > n: the storms there are (CNumCosmicStormsTrigger: GetStorms [V])
    TRIG["num_cosmic_storms"] = function(e, ctx) return cmp(#all_of("cosmic_storm"), e, ctx) end
    if eval.TVAL then eval.TVAL["num_cosmic_storms"] = function() return #all_of("cosmic_storm") end end
    -- num_unique_cosmic_storms_encountered > n (the country's `num_unique_cosmic_storms_encountered`,
    -- CCountry +0x35f4 [V: the offset; the name from the token table])
    TRIG["num_unique_cosmic_storms_encountered"] = function(e, ctx)
        local _, c = country_of(ctx.this)
        if not c then return false end
        return cmp(tonumber(world.field(c, "num_unique_cosmic_storms_encountered")) or 0, e, ctx)
    end
    -- the influence of storms on a system (CGalacticObject +0x1378: cosmic_storm_influence_value and
    -- cosmic_storm_system_influence read the same value [V]): the sum of the fields' influence over
    -- the systems they cover [I]
    local function system_influence(sid)
        local v = 0
        for _, fid in ipairs(all_of("cosmic_storm_influence_field")) do
            local f = world.object("cosmic_storm_influence_field", fid)
            for _, s in ipairs(field_systems(f)) do
                if s == sid then v = v + (tonumber(world.field(f, "influence")) or 0) end
            end
        end
        return v
    end
    M.system_influence = system_influence
    TRIG["cosmic_storm_influence_value"] = function(e, ctx)
        if ctx.this.kind ~= "system" then return false end
        return cmp(system_influence(ctx.this.id), e, ctx)
    end
    TRIG["cosmic_storm_system_influence"] = TRIG["cosmic_storm_influence_value"]
    -- the galaxy setup's cosmic storm settings (the save's galaxy = { cosmic_storm_* })
    local SETTINGS = {
        num_cosmic_storm_early_game_spawn_chance_scale_setting = "cosmic_storm_early_game_spawn_chance_scale",
        num_cosmic_storm_mid_game_spawn_chance_scale_setting = "cosmic_storm_mid_game_spawn_chance_scale",
        num_cosmic_storm_late_game_spawn_chance_scale_setting = "cosmic_storm_late_game_spawn_chance_scale",
        num_cosmic_storm_early_game_spawn_max_cap_setting = "cosmic_storm_early_game_spawn_max_cap",
        num_cosmic_storm_mid_game_spawn_max_cap_setting = "cosmic_storm_mid_game_spawn_max_cap",
        num_cosmic_storm_late_game_spawn_max_cap_setting = "cosmic_storm_late_game_spawn_max_cap",
        num_cosmic_storm_spawn_cooldown_scale_setting = "cosmic_storm_spawn_cooldown_scale",
    }
    for k, field in pairs(SETTINGS) do
        local function value()
            local g = meta("galaxy")
            return type(g) == "table" and tonumber(world.field(g, field)) or 0
        end
        TRIG[k] = function(e, ctx) return cmp(value(), e, ctx) end
        if eval.TVAL then eval.TVAL[k] = function() return value() end end
    end

    -- ------------------------------------------------------------------------------------------
    -- missions (CMission) and observation posts (CFleet's `mission = { type progress }` [I])

    -- is_mission_type = <type> (`mission`)
    TRIG["is_mission_type"] = function(e, ctx)
        local m = obj(ctx.this, "mission")
        return m ~= nil and unq(world.field(m, "mission")) == unq(e.value.text)
    end
    local function fleet_mission(sc)
        if not sc or sc.kind ~= "fleet" then return nil end
        local f = world.object("fleet", sc.id)
        local m = f and world.field(f, "mission")
        return type(m) == "table" and m or nil, f
    end
    M.fleet_mission = fleet_mission
    -- has_mission = <observation mission> (CFleet::HasMission [V])
    TRIG["has_mission"] = function(e, ctx)
        local m = fleet_mission(ctx.this)
        return m ~= nil and unq(world.field(m, "mission") or world.field(m, "type")) == unq(e.value.text)
    end
    -- mission_progress > 0.7 (the fleet's mission's progress, CFleet +0x488 [V: the offset])
    TRIG["mission_progress"] = function(e, ctx)
        local m = fleet_mission(ctx.this)
        if not m then return false end
        return cmp(tonumber(world.field(m, "progress")) or 0, e, ctx)
    end

    -- ------------------------------------------------------------------------------------------
    -- event chains and special projects (the country's events = { event_chain completed_event_chain
    -- special_project })

    -- has_completed_event_chain = <key> (CCountryEventManager::HasCompletedEventChain: the
    -- `completed_event_chain` entries [V])
    TRIG["has_completed_event_chain"] = function(e, ctx)
        local _, c = country_of(ctx.this)
        local evb = c and events_block(c, false)
        if not evb then return false end
        local want = unq(e.value.text)
        for _, x in ipairs(world.fields(evb, "completed_event_chain")) do
            if unq(type(x) == "table" and world.field(x, "event_chain") or x) == want then return true end
        end
        return false
    end
    -- is_researching_special_project = <key>: a project of that type in the country's research
    -- queues (CTechnologyStatus::FindProjectType [V]); for a leader, its country's project whose
    -- fleets hold the leader [I: the country's]
    local function researching(cid, key)
        local c = world.object("country", cid)
        local evb = c and events_block(c, false)
        local ids = {}
        for _, x in ipairs(evb and world.fields(evb, "special_project") or {}) do
            if type(x) == "table" and unq(world.field(x, "special_project")) == key then
                ids[tonumber(world.field(x, "id")) or -1] = true
            end
        end
        local status = c and world.field(c, "tech_status")
        local found = false
        local function scan(b, depth)
            if found or depth > 4 or type(b) ~= "table" then return end
            for _, x in ipairs(b) do
                local v = x.op and x.value or x
                if type(v) == "table" and not v.text then
                    if ids[tonumber(world.field(v, "special_project")) or -2] then found = true return end
                    scan(v, depth + 1)
                end
            end
        end
        scan(status, 0)
        return found
    end
    TRIG["is_researching_special_project"] = function(e, ctx)
        local cid = ctx.this.kind == "country" and ctx.this.id
        if ctx.this.kind == "leader" then
            local l = world.object("leader", ctx.this.id)
            cid = l and ref(world.field(l, "country"))
        end
        if not cid then return false end
        return researching(cid, unq(e.value.text))
    end
    -- last_completed_special_project_has_research_cost = yes: the country's last completed project
    -- (`last_completed_special_project`, CCountry +0x3070) has a cost (CSpecialProjectDatabase::
    -- FindProjectType [V]; its `cost` above 0 [I])
    TRIG["last_completed_special_project_has_research_cost"] = function(e, ctx)
        local _, c = country_of(ctx.this)
        local key = c and unq(world.field(c, "last_completed_special_project"))
        if not key then return false end
        local ok, creation = pcall(require, "engine.script.creation")
        local d = ok and creation.special_project_def and creation.special_project_def(key)
        local cost = d and tonumber(defs.field(d.block, "cost")) or 0
        return (cost > 0) == want_yes(e)
    end

    -- ------------------------------------------------------------------------------------------
    -- the rest

    -- is_event_leader = no (CEventLeaderTrigger: the leader's `event_leader` [I])
    TRIG["is_event_leader"] = function(e, ctx)
        if ctx.this.kind ~= "leader" then return false end
        local l = world.object("leader", ctx.this.id)
        if not l then return false end
        return (world.field(l, "event_leader") == "yes") == want_yes(e)
    end
    -- is_preventing_anomaly = yes: a planet's `prevent_anomaly` (CPlanet +0xcb4, set by
    -- prevent_anomaly [V]); a ship's planet [I: the colony carrier's]
    TRIG["is_preventing_anomaly"] = function(e, ctx)
        local p = ctx.this.kind == "planet" and world.object("planet", ctx.this.id)
        if not p then return false end
        return (world.field(p, "prevent_anomaly") == "yes") == want_yes(e)
    end
    -- can_spawn_random_anomaly = <ship/fleet>: a planet not surveyed by the fleet's country, with no
    -- anomaly and not preventing one (CAnomalyTypeDatabase::HasValidAnomalyFor [V]; the conditions
    -- [I])
    TRIG["can_spawn_random_anomaly"] = function(e, ctx)
        local p = ctx.this.kind == "planet" and world.object("planet", ctx.this.id)
        if not p then return false end
        if world.field(p, "prevent_anomaly") == "yes" or world.field(p, "anomaly") then return false end
        local sc = target(e.value.text, ctx, e)
        if not sc then return false end
        local fid = sc.kind == "fleet" and sc.id or (sc.kind == "ship" and tonumber(world.field(world.object("ship", sc.id) or {}, "fleet")))
        local f = fid and world.object("fleet", fid)
        local owner = f and ref(world.field(f, "owner"))
        for _, c in ipairs(world.fields(p, "surveyed_by")) do
            if tonumber(c) == owner then return false end
        end
        return f ~= nil
    end
    -- can_have_first_contact_site_with = <country>: another country with no first contact of the
    -- scope's with it yet [I: CCanHaveFirstContactSiteWithTrigger reads the diplomacy module]
    TRIG["can_have_first_contact_site_with"] = function(e, ctx)
        local cid = country_of(ctx.this)
        local other = target(e.value.text, ctx, e)
        if not cid or not other or other.kind ~= "country" or other.id == cid then return false end
        for _, s in ipairs(LISTS.first_contact(ctx.this)) do
            if ref(world.field(world.object("first_contact", s.id), "country")) == other.id then return false end
        end
        return true
    end
    -- is_espionage_operation_auto_accept_events = yes (the operation's `auto_accept_events` [I])
    TRIG["is_espionage_operation_auto_accept_events"] = function(e, ctx)
        if ctx.this.kind ~= "espionage_operation" then return false end
        local o = world.object("espionage_operation", ctx.this.id)
        if not o then return false end
        return (world.field(o, "auto_accept_events") == "yes") == want_yes(e)
    end

    require("simscript.handlers.events_effects")(eval, M)
end
