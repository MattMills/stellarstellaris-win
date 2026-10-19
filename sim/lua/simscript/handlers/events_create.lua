-- simscript/handlers/events_create.lua : the effects of handlers/events.lua's area that make, finish
-- or remove objects (docs/script_events.md): missions and contracts, special projects, patrons'
-- first contacts, arc sites, cosmic storms and their influence fields, astral rifts, the grand
-- archive, random anomalies, and the bypass and pop faction events. Called by handlers/events.lua
-- with its helpers (M).
--
-- [V] read in the Linux 4.5.2 binary, [I] inferred (the docs, the save's fields, the game's own
-- console runs of the same effects: docs/script_events.md "The coverage save").

return function(eval, M)
    local I = eval._internal
    local S, NONE = I.S, I.NONE
    local EFF = eval.EFF
    local world = require("engine.world")
    local function lazy(name)
        return setmetatable({}, { __index = function(_, k) return require(name)[k] end })
    end
    local defs = lazy("engine.defs")
    local event_save = lazy("engine.script.event_save")
    local systems = lazy("engine.systems")
    local creation = lazy("engine.script.creation")
    local unq, ref, obj, target, param, param_text = M.unq, M.ref, M.obj, M.target, M.param, M.param_text
    local country_of, set_quoted, pick = M.country_of, M.set_quoted, M.pick

    local NO_ID = 4294967295
    -- a folder's definition keys, sorted (the draws below are deterministic)
    local function keys(folder)
        local out = {}
        for k in pairs(defs.folder(folder)) do out[#out + 1] = k end
        table.sort(out)
        return out
    end

    local function num(v, ctx, e)
        return tonumber(eval.value(v, ctx, e)) or 0
    end
    -- an on_action of the game (simscript.events), this = scope, from = from's scope
    local function on_action(name, scope, from)
        local ok, ev = pcall(require, "simscript.events")
        if ok and ev.on_action then
            ev.on_action(name, scope, from and eval.new_ctx(from) or nil)
        end
    end
    M.on_action = on_action
    -- a context from a saved scope block (engine.script.event_save's parse_scope)
    local function ctx_of(b, file)
        local p = type(b) == "table" and event_save.parse_scope(b)
        if not p then return nil end
        local ctx = eval.new_ctx(p.this, p.from_rec and p.from_rec.this or nil, p.targets, file)
        return ctx
    end
    -- an effect block run with a context
    local function run(block, ctx)
        if type(block) == "table" and block.text == nil and ctx then eval.effect(block, ctx) end
    end
    -- a scope's system (a system, or a planet's, ship's, fleet's, starbase's)
    local function system_of(sc)
        if not sc or sc == NONE then return nil end
        if sc.kind == "system" then return sc.id end
        local o = world.object(sc.kind, sc.id)
        if not o then return nil end
        if sc.kind == "planet" then return M.origin_of(o) end
        if sc.kind == "fleet" then return M.origin_of(o, "movement_manager") or tonumber(world.path(o, "movement_manager", "coordinate", "origin")) end
        if sc.kind == "ship" then
            local f = ref(world.field(o, "fleet"))
            return f and system_of(S("fleet", f))
        end
        if sc.kind == "starbase" then
            local st = ref(world.field(o, "station"))
            return st and system_of(S("ship", st))
        end
        return M.origin_of(o)
    end
    M.system_of = system_of

    -- ------------------------------------------------------------------------------------------
    -- missions (CMission; the country's events = { missions = { ids } })

    local function mission_def(key) return key and defs.get("common/missions/missions", key) end
    local function country_missions(c)
        local evb = M.events_block(c, false)
        return evb and M.id_list(evb, "missions") or {}
    end
    local function find_mission(cid, key)
        local c = world.object("country", cid)
        for _, id in ipairs(c and country_missions(c) or {}) do
            local m = world.object("mission", id)
            if m and unq(world.field(m, "mission")) == key then return id, m end
        end
        return nil
    end
    -- the mission's own effects (`on_start`, `on_success` ...): this = the operator, prev = the
    -- issuer, from = the mission's scope (99_README_MISSIONS.txt)
    local function mission_effect(id, m, name)
        local d = mission_def(unq(world.field(m, "mission")))
        local block = d and defs.field(d.block, name)
        if type(block) ~= "table" then return end
        local op = ref(world.field(m, "operator"))
        local ctx = eval.new_ctx(op and S("country", op) or NONE, nil, nil, d.file)
        local sctx = ctx_of(world.field(m, "scope"))
        if sctx then ctx.from = sctx.this end
        local iss = ref(world.field(m, "issuer"))
        if iss then ctx.prev = S("country", iss) end
        run(block, ctx)
    end
    -- enable_mission = { name = <key> } (CEnableMissionEffect -> NMissionUtil::AddMissionToCountry
    -- [V]): a mission of the type for the scope's country: its scope (the effect's), status active,
    -- operator the country, no issuer; with `location = yes` the scope's spatial object; the id added
    -- to the country's missions; then on_start. The game's own: mission 0 = { mission scope status =
    -- active operator = 0 issuer = 4294967295 }, the country's missions = { 0 }
    EFF["enable_mission"] = function(e, ctx)
        local cid, c = country_of(ctx.this)
        if not cid and ctx.this ~= NONE then
            local found, owner = eval.resolve("owner", ctx, e)
            if found and owner and owner.kind == "country" then cid, c = owner.id, world.object("country", owner.id) end
        end
        if not c or e.value.text then return end
        local key = param_text(e.value, "name")
        local d = mission_def(key)
        if not d then return end
        if find_mission(cid, key) then return end
        M.holder("mission")
        local b = {}
        world.append(b, "mission", key, true)
        world.append(b, "scope", event_save.ctx_block(ctx))
        world.append(b, "status", "active")
        if defs.field(d.block, "location") == "yes" then
            local sys = system_of(ctx.this)
            if sys then
                local loc = {}
                world.append(loc, "type", 0)
                world.append(loc, "id", sys)
                world.append(b, "location", loc)
            end
        end
        world.append(b, "operator", cid)
        world.append(b, "issuer", NO_ID)
        local id = M.next_id("mission")
        world.create("mission", id, b)
        local evb = M.events_block(c, true)
        local l = world.field(evb, "missions")
        if type(l) ~= "table" then l = world.child(evb, "missions") end
        world.append_value(l, id)
        mission_effect(id, b, "on_start")
    end
    -- a mission ended: its status, its effects (on_success, or on_cancel; then on_stop), taken out of
    -- its country's list and of the store (NMissionUtil::StopMission [V]; the order of the effects
    -- from the README [I])
    local function end_mission(id, m, status)
        world.set(m, "status", status)
        if status == "success" then mission_effect(id, m, "on_success") else mission_effect(id, m, "on_cancel") end
        mission_effect(id, m, "on_stop")
        local op = ref(world.field(m, "operator"))
        local c = op and world.object("country", op)
        local evb = c and M.events_block(c, false)
        local l = evb and world.field(evb, "missions")
        if type(l) == "table" then world.remove_value(l, id) end
        world.remove("mission", id)
    end
    M.end_mission = end_mission
    -- stop_mission = { mission = <key> status = success } (CStopMissionEffect -> NMissionUtil::
    -- StopMission [V])
    EFF["stop_mission"] = function(e, ctx)
        local cid = country_of(ctx.this)
        if not cid or e.value.text then return end
        local id, m = find_mission(cid, param_text(e.value, "mission"))
        if not id then return end
        end_mission(id, m, param_text(e.value, "status") or "success")
    end
    -- a mission's counters (`counter = { <key> = n }` in the mission [I: CObjectiveCounterTracker's
    -- label not read]), clamped to [0, the type's max]; a mission whose counters all reach their max
    -- has succeeded [I]
    local function counter_max(m, counter)
        local d = mission_def(unq(world.field(m, "mission")))
        local cb = d and defs.field(d.block, "counter")
        local x = type(cb) == "table" and defs.field(cb, counter)
        return type(x) == "table" and tonumber(defs.field(x, "max")) or nil
    end
    local function set_counter(id, m, counter, v)
        local max = counter_max(m, counter)
        if v < 0 then v = 0 end
        if max and v > max then v = max end
        local cb = world.field(m, "counter")
        if type(cb) ~= "table" then cb = world.child(m, "counter") end
        world.set(cb, counter, v)
        -- all reached: success
        local d = mission_def(unq(world.field(m, "mission")))
        local defined = d and defs.field(d.block, "counter")
        if type(defined) ~= "table" then return end
        for _, x in ipairs(defined) do
            if x.op and x.key and type(x.value) == "table" then
                local mx = tonumber(defs.field(x.value, "max"))
                if mx and (tonumber(world.field(cb, x.key.text)) or 0) < mx then return end
            end
        end
        end_mission(id, m, "success")
    end
    local function counter_target(e, ctx)
        if ctx.this.kind == "mission" then
            local m = world.object("mission", ctx.this.id)
            return ctx.this.id, m
        end
        local cid = country_of(ctx.this)
        if not cid then return nil end
        return find_mission(cid, param_text(e.value, "mission"))
    end
    -- add_mission_counter / set_mission_counter = { mission counter amount } (CSetMissionCounter
    -- Effect: CCountryEventManager::AccessMissionByType, CObjectiveCounterTracker::SetCount [V])
    EFF["add_mission_counter"] = function(e, ctx)
        if e.value.text then return end
        local id, m = counter_target(e, ctx)
        if not id then return end
        local counter = param_text(e.value, "counter")
        local x = param(e.value, "amount")
        if not counter or not x then return end
        local cb = world.field(m, "counter")
        local cur = type(cb) == "table" and tonumber(world.field(cb, counter)) or 0
        set_counter(id, m, counter, cur + math.floor(num(x.value, ctx, x)))
    end
    EFF["set_mission_counter"] = function(e, ctx)
        if e.value.text then return end
        local id, m = counter_target(e, ctx)
        if not id then return end
        local counter = param_text(e.value, "counter")
        local x = param(e.value, "amount")
        if not counter or not x then return end
        set_counter(id, m, counter, math.floor(num(x.value, ctx, x)))
    end
    -- cancel_contract = { refund = yes show_message = yes } (CCancelContractEffect: a contract's
    -- CCancelContractCommand [V]): the contract cancelled (on_cancel, on_stop), its cost back to the
    -- issuer when refund (the type's `cost` [I])
    EFF["cancel_contract"] = function(e, ctx)
        local m = obj(ctx.this, "mission")
        if not m then return end
        local d = mission_def(unq(world.field(m, "mission")))
        if not d then return end
        local refund = e.value.text == nil and param_text(e.value, "refund") ~= "no"
        if e.value.text == "no" then return end
        local iss = ref(world.field(m, "issuer"))
        local cost = defs.field(d.block, "cost")
        if refund and iss and type(cost) == "table" then
            local c = world.object("country", iss)
            local r = c and world.path(c, "modules", "standard_economy_module", "resources")
            if type(r) == "table" then
                for _, x in ipairs(cost) do
                    if x.op and x.key and tonumber(x.value.text) then
                        world.set(r, x.key.text, (tonumber(world.field(r, x.key.text)) or 0) + tonumber(x.value.text))
                    end
                end
            end
        end
        end_mission(ctx.this.id, m, "cancelled")
    end

    -- ------------------------------------------------------------------------------------------
    -- special projects (the country's events = { special_project = { id special_project scope
    -- coordinate ... } }: engine/script/creation.lua)

    -- complete_special_project = { type = <key> location = <target> } (CChangeSpecialProjectEffect
    -- <SCompleteSpecialProject>: CCountryEventManager::CompleteSpecialProjectsWithType[AndLocation]
    -- [V]): each project of the type (at the location) completed: its on_success in its own scope,
    -- taken out with its research, the country's last_completed_special_project [I: the order]
    EFF["complete_special_project"] = function(e, ctx)
        local cid, c = country_of(ctx.this)
        if not c or e.value.text then return end
        local key = param_text(e.value, "type")
        local lx = param(e.value, "location")
        local loc = lx and target(lx.value.text, ctx, lx)
        local d = key and creation.special_project_def(key)
        local evb = M.events_block(c, false)
        if not d or not evb then return end
        local done = {}
        for i = #evb, 1, -1 do
            local x = evb[i]
            if x.op and x.key and x.key.text == "special_project" and type(x.value) == "table"
                and unq(world.field(x.value, "special_project")) == key then
                local co = world.field(x.value, "coordinate")
                local at = type(co) == "table" and tonumber(world.field(co, "id"))
                if not loc or at == loc.id then
                    done[#done + 1] = { entry = x, block = x.value }
                end
            end
        end
        if #done == 0 then return end
        local ids = {}
        for _, p in ipairs(done) do
            ids[#ids + 1] = tonumber(world.field(p.block, "id"))
            world.remove_entry(evb, p.entry)
        end
        creation.remove_project_research(cid, ids)
        set_quoted(c, "last_completed_special_project", key)
        for _, p in ipairs(done) do
            local pctx = ctx_of(world.field(p.block, "scope"), d.file) or eval.new_ctx(S("country", cid), nil, nil, d.file)
            run(defs.field(d.block, "on_success"), pctx)
        end
    end
    -- fleet_action_research_special_project = { special_project target } (a fleet order to research
    -- the country's project there [I]: the fleet's queued action `research_special_project = {
    -- special_project target }`)
    EFF["fleet_action_research_special_project"] = function(e, ctx)
        if ctx.this.kind ~= "fleet" or e.value.text then return end
        local f = world.object("fleet", ctx.this.id)
        local key = param_text(e.value, "special_project")
        local tx = param(e.value, "target")
        local tg = tx and target(tx.value.text, ctx, tx)
        if not f or not key or not tg then return end
        local q = world.field(f, "action_queue")
        if type(q) ~= "table" then q = world.child(f, "action_queue") end
        local b = {}
        world.append(b, "special_project", key, true)
        local tb = {}
        world.append(tb, "type", tg.kind == "system" and "galactic_object" or tg.kind)
        world.append(tb, "id", tg.id)
        world.append(b, "target", tb)
        local a = {}
        world.append(a, "research_special_project", b)
        world.push(q, a)
    end
    -- the country's relation with a patron (the save's top-level patron_relations = { { country
    -- patron contact_state } } [I])
    local function patron_relation(cid, patron, create)
        local pr = M.meta("patron_relations")
        if type(pr) ~= "table" then
            if not create then return nil end
            pr = world.child(world.tree, "patron_relations")
            world.meta.patron_relations = pr
        end
        for _, x in ipairs(pr) do
            local v = x.op and x.value or x
            if type(v) == "table" and tonumber(world.field(v, "country")) == cid and unq(world.field(v, "patron")) == patron then
                return v
            end
        end
        if not create then return nil end
        local b = {}
        world.append(b, "country", cid)
        world.append(b, "patron", patron, true)
        world.append(b, "contact_state", "none")
        world.push(pr, b)
        return b
    end
    M.patron_relation = patron_relation
    -- set_patron_first_contact_state = { patron state = none/in_progress/completed } (the relation
    -- made when needed; completed by default)
    EFF["set_patron_first_contact_state"] = function(e, ctx)
        local cid = country_of(ctx.this)
        if not cid or e.value.text then return end
        local patron = param_text(e.value, "patron")
        if not patron then return end
        local r = patron_relation(cid, patron, true)
        world.set(r, "contact_state", param_text(e.value, "state") or "completed")
    end
    -- enable_patron_first_contact_project = { name patron owner location } (CEnablePatronFirstContact
    -- ProjectEffect: EnableSpecialProject, then CShroudCountryModule::RegisterPatronFirstContactProject
    -- [V]): the project enabled for the owner (root by default) at the location (this by default),
    -- the patron's relation in_progress when it had none
    EFF["enable_patron_first_contact_project"] = function(e, ctx)
        if e.value.text then return end
        local key, patron = param_text(e.value, "name"), param_text(e.value, "patron")
        local ox, lx = param(e.value, "owner"), param(e.value, "location")
        local owner = ox and target(ox.value.text, ctx, ox) or ctx.root
        local loc = lx and target(lx.value.text, ctx, lx) or ctx.this
        if not key or not owner or owner.kind ~= "country" then return end
        local id = systems.effects.enable_special_project({ country = owner.id, project = key,
            scope = event_save.ctx_block(ctx), location = loc and loc ~= NONE and loc or nil })
        if not id or not patron then return end
        local r = patron_relation(owner.id, patron, true)
        if world.field(r, "contact_state") == "none" then world.set(r, "contact_state", "in_progress") end
        world.set(r, "first_contact_project", id)
    end

    -- ------------------------------------------------------------------------------------------
    -- archaeological sites

    local LOC_TYPE = { system = 0, ship = 1, planet = 2, megastructure = 3, ambient_object = 4, starbase = 5 }
    local function site_type(key) return key and defs.get("common/archaeological_site_types", key) end
    local function stages_of(d)
        local out = {}
        for _, x in ipairs(d.block) do
            if x.op and x.key and x.key.text == "stage" and type(x.value) == "table" then out[#out + 1] = x.value end
        end
        return out
    end
    local function stage_difficulty(st, ctx)
        local diff = defs.field(st, "difficulty")
        local base = tonumber(diff)
        if not base and type(diff) == "table" then
            local lo, hi = tonumber(defs.field(diff, "min")), tonumber(defs.field(diff, "max"))
            if lo and hi then base = lo + pick(hi - lo + 1) - 1 end
        end
        return base or 0
    end
    -- create_archaeological_site = <type>/random (CCreateArchaeologicalSiteEffect: CGameState::
    -- CreateNewArchaeologicalSite / CreateNewRandomArchaeologicalSite at the scope's spatial object
    -- [V]): a site at the object (location = { type id }), its first stage's difficulty, the stage's
    -- days (FIRST_CONTACT_DISCOVERY_DAYS's arc site define ARCHAEOLOGY_DISCOVERY_DAYS [I]); random:
    -- a type with weight whose allow / potential holds there, by weight [I]
    function M.create_site(sc, key, ctx)
        local lt = sc and LOC_TYPE[sc.kind]
        if not lt or not world.object(sc.kind, sc.id) then return nil end
        if key == "random" then
            local cands, total = {}, 0
            for _, k in ipairs(keys("common/archaeological_site_types")) do
                local d = site_type(k)
                local w = d and tonumber(defs.field(d.block, "weight")) or 0
                local pot = d and defs.field(d.block, "potential")
                if w > 0 and (type(pot) ~= "table" or eval.trigger(pot, eval.new_ctx(sc))) then
                    cands[#cands + 1] = { k, w }
                    total = total + w
                end
            end
            if total <= 0 then return nil end
            local r = (pick(total * 1000) - 1) / 1000
            for _, c in ipairs(cands) do
                r = r - c[2]
                if r < 0 then key = c[1] break end
            end
            if key == "random" then key = cands[#cands][1] end
        end
        local d = site_type(key)
        if not d then return nil end
        local st = stages_of(d)[1]
        M.holder("archaeological_site")
        local b = {}
        local loc = {}
        world.append(loc, "type", lt)
        world.append(loc, "id", sc.id)
        world.append(b, "location", loc)
        world.append(b, "last_excavator_country", NO_ID)
        world.append(b, "excavator_fleet", NO_ID)
        world.append(b, "type", key, true)
        world.append(b, "index", 0)
        world.append(b, "clues", 0)
        world.append(b, "last_roll", 0)
        local g = defs.get("common/defines", "NGameplay")
        world.append(b, "days_left", g and tonumber(defs.field(g.block, "ARCHAEOLOGY_DISCOVERY_DAYS")) or 90)
        world.append(b, "difficulty", st and stage_difficulty(st, ctx) or 0)
        local id = M.next_id("archaeological_site")
        world.create("archaeological_site", id, b)
        return id
    end
    EFF["create_archaeological_site"] = function(e, ctx)
        local key = unq(e.value.text)
        if not key then return end
        M.create_site(ctx.this, key, ctx)
    end
    -- finish_current_stage / finish_site = yes/no/<country> (CFinishCurrentStageEffect /
    -- CFinishArchaeologicalSiteEffect: CArchaeologicalSite::FinishCurrentStage, FireStageEvent with
    -- the excavator's (the controller of its fleet) or the given country [V]): the stage completed
    -- (`completed = { index }`), the index advanced, its clues and roll reset; yes: the stage's event
    -- fired for the country (this = the site, from = the country [I]); finish_site does it for every
    -- stage left
    local function excavator_country(s)
        local f = ref(world.field(s, "excavator_fleet"))
        local fb = f and world.object("fleet", f)
        return fb and ref(world.field(fb, "owner")) or ref(world.field(s, "last_excavator_country"))
    end
    local function finish_stage(sid, s, fire, cid)
        local d = site_type(unq(world.field(s, "type")))
        if not d then return false end
        local stages = stages_of(d)
        local i = tonumber(world.field(s, "index")) or 0
        if i >= #stages then return false end
        local comp = world.field(s, "completed")
        if type(comp) ~= "table" then comp = world.child(s, "completed") end
        world.append_value(comp, i)
        local st = stages[i + 1]
        world.set(s, "index", i + 1)
        world.set(s, "clues", 0)
        world.set(s, "last_roll", 0)
        if stages[i + 2] then world.set(s, "difficulty", stage_difficulty(stages[i + 2])) end
        if fire and cid then
            local ev = st and unq(defs.field(st, "event"))
            if ev then
                local ok, events = pcall(require, "simscript.events")
                if ok and events.fire then
                    pcall(events.fire, ev, S("archaeological_site", sid), eval.new_ctx(S("country", cid)), S("country", cid))
                end
            end
        end
        return true
    end
    local function finish_args(e, ctx, s)
        if e.value.text == "no" then return false, nil end
        if e.value.text == "yes" then return true, excavator_country(s) end
        local c = target(e.value.text, ctx, e)
        return false, c and c.kind == "country" and c.id or nil
    end
    EFF["finish_current_stage"] = function(e, ctx)
        local s = M.site(ctx.this)
        if not s then return end
        local fire, cid = finish_args(e, ctx, s)
        finish_stage(ctx.this.id, s, fire, cid)
    end
    EFF["finish_site"] = function(e, ctx)
        local s = M.site(ctx.this)
        if not s then return end
        local fire, cid = finish_args(e, ctx, s)
        for _ = 1, 100 do
            if not finish_stage(ctx.this.id, s, fire, cid) then break end
        end
    end

    -- ------------------------------------------------------------------------------------------
    -- cosmic storms (common/storm_types)

    local function storm_type(key) return key and defs.get("common/storm_types", key) end
    -- the systems within a radius of a point
    local function systems_near(x, y, r)
        local out = {}
        for _, id in ipairs(world.all("system")) do
            local sx, sy = M.system_xy(id)
            if sx and ((sx - x) ^ 2 + (sy - y) ^ 2) <= r * r then out[#out + 1] = id end
        end
        return out
    end
    -- create_cosmic_storm = { type cosmic_storm_start_position storm_end_position storm_min_radius
    -- storm_max_radius storm_max_range } (CCreateCosmicStormEffect: CGameState::TryCreateStorm
    -- RandomDirection from the start system [V]): a storm of the type at the start's place, its
    -- radii (the effect's, else the type's), not activated, counter 0, its cluster over the systems
    -- within its min radius; the save's last_created_cosmic_storm; on_space_storm_created with the
    -- system. The game's own (electric_storm at the capital's system): type, start position at the
    -- system's place, storm_min_radius 25, storm_max_radius 50, activated = no, counter 0, a cluster
    -- of 4 systems, a path of 8 systems from the start. The path, name, colour and speed are the
    -- storm manager's [I: not modelled: the path is the start alone]
    EFF["create_cosmic_storm"] = function(e, ctx)
        if e.value.text then return end
        local key = param_text(e.value, "type")
        local d = storm_type(key)
        if not d then return end
        local sx = param(e.value, "cosmic_storm_start_position") or param(e.value, "storm_start_position")
        local start = sx and target(sx.value.text, ctx, sx) or ctx.this
        local sys = system_of(start)
        if not sys then return end
        local x, y = M.system_xy(sys)
        local function field_num(k, default)
            local p = param(e.value, k)
            if p then return num(p.value, ctx, p) end
            return tonumber(defs.field(d.block, k)) or default
        end
        local minr, maxr = field_num("storm_min_radius", 25), field_num("storm_max_radius", 50)
        M.holder("cosmic_storm")
        local b = {}
        world.append(b, "type", key, true)
        local pos = {}
        world.append(pos, "x", x)
        world.append(pos, "y", y)
        world.append(pos, "origin", NO_ID)
        world.append(b, "cosmic_storm_start_position", pos)
        world.append(b, "storm_current_path_index", 0)
        world.append(b, "storm_min_radius", minr)
        world.append(b, "storm_max_radius", maxr)
        world.append(b, "counter", 0)
        world.append(b, "activated", "no")
        local cl = {}
        world.append(cl, "id", "0", true)
        local cp = {}
        world.append(cp, "x", x)
        world.append(cp, "y", y)
        world.append(cp, "origin", NO_ID)
        world.append(cl, "position", cp)
        world.append(cl, "radius", minr)
        local objs = {}
        for _, id in ipairs(systems_near(x, y, minr)) do objs[#objs + 1] = { text = tostring(id) } end
        world.append(cl, "objects", objs)
        world.append(b, "cluster", cl)
        world.append(b, "allow_storm_movement", "yes")
        world.append(b, "storm_age", 0)
        world.append(b, "path", { { text = tostring(sys) } })
        local id = M.next_id("cosmic_storm")
        world.create("cosmic_storm", id, b)
        world.set(world.tree, "last_created_cosmic_storm", id)
        world.meta.last_created_cosmic_storm = tostring(id)
        on_action("on_space_storm_created", S("system", sys))
    end
    -- create_cosmic_storm_influence_field = { radius } (CCreateStormInfluenceFieldEffect: CGameState::
    -- CreateStormInfluenceField at the scope's system [V]): a field of the radius (influence 0, not
    -- timed); its center the scope's system [I: the game's own run wrote center = 4294967295]; the
    -- save's last_created_cosmic_storm_influence_field
    EFF["create_cosmic_storm_influence_field"] = function(e, ctx)
        if e.value.text then return end
        local sys = system_of(ctx.this)
        local rx = param(e.value, "radius")
        if not sys or not rx then return end
        M.holder("cosmic_storm_influence_field")
        local b = {}
        world.append(b, "center", sys)
        world.append(b, "radius", num(rx.value, ctx, rx))
        world.append(b, "timed_modifier", {})
        world.append(b, "influence", 0)
        world.append(b, "is_timed_influence_field", "no")
        local id = M.next_id("cosmic_storm_influence_field")
        world.create("cosmic_storm_influence_field", id, b)
        world.set(world.tree, "last_created_cosmic_storm_influence_field", id)
        world.meta.last_created_cosmic_storm_influence_field = tostring(id)
    end
    -- destroy_cosmic_storm_influence_field = { center = <target> } (CDestroyStormInfluenceFieldEffect:
    -- CGameState::DestroyStormInfluenceField at the target's system [V]): the fields centred there
    EFF["destroy_cosmic_storm_influence_field"] = function(e, ctx)
        local cx = e.value.text and e or param(e.value, "center")
        local c = cx and target(cx.value.text, ctx, cx) or ctx.this
        local sys = system_of(c)
        if not sys then return end
        for _, id in ipairs(M.all_of("cosmic_storm_influence_field")) do
            local f = world.object("cosmic_storm_influence_field", id)
            if ref(world.field(f, "center")) == sys or M.field_center_system(f) == sys then
                world.remove("cosmic_storm_influence_field", id)
            end
        end
    end

    -- recalculate_storm_influence_field = yes (CRecalculateStormInfluenceFieldsEffect:
    -- CCosmicStormInfluenceField::RecalculateAllSystems [V]): the field's systems again, written as
    -- its influence_groups = { systems = { ids } } [I: the group's form]
    EFF["recalculate_storm_influence_field"] = function(e, ctx)
        local f = obj(ctx.this, "cosmic_storm_influence_field")
        if not f or e.value.text == "no" then return end
        local ids = {}
        for _, id in ipairs(M.field_systems(f)) do ids[#ids + 1] = { text = tostring(id) } end
        local g = {}
        world.append(g, "systems", ids)
        M.set_block(f, "influence_groups", g)
    end

    -- ------------------------------------------------------------------------------------------
    -- astral rifts (common/astral_rifts)

    -- spawn_astral_rift = { random_pos orbit_distance orbit_angle id relative_to in_place_of
    -- init_effect ... } (CSpawnAstralRiftEffect: CGameState::SpawnAstralRiftByKey / CreateNewAstral
    -- Rift in the scoped system [V]): a rift at the system's place (the orbit's offset from it [I]),
    -- no owner, explorer or leader, status waiting_for_explorer, its type (the id, else none until
    -- exploration picks one); the init_effect in the rift's scope; on_astral_rift_spawned. The game's
    -- own (riftworld at the capital's system): coordinate { x y origin = the system }, owner,
    -- explorer_fleet, leader, explorer none, clues 0, last_roll 0, days_left 90, difficulty 0,
    -- event_choice "astral_rift.1", status waiting_for_explorer, type "riftworld", the type's flag
    EFF["spawn_astral_rift"] = function(e, ctx)
        if ctx.this.kind ~= "system" or not world.object("system", ctx.this.id) then return end
        local p = e.value.text == nil and e.value or {}
        local key = param_text(p, "id")
        if key == "none" then key = nil end
        if key and not defs.get("common/astral_rifts", key) then return end
        local dist = tonumber(param_text(p, "orbit_distance")) or 0
        local angle = math.rad(tonumber(param_text(p, "orbit_angle")) or 0)
        M.holder("astral_rift")
        local b = {}
        local nm = {}
        world.append(nm, "key", "Astral Rift", true)
        world.append(b, "name", nm)
        local co = {}
        world.append(co, "x", dist * math.cos(angle))
        world.append(co, "y", dist * math.sin(angle))
        world.append(co, "origin", ctx.this.id)
        world.append(b, "coordinate", co)
        for _, k in ipairs({ "owner", "explorer_fleet", "leader", "explorer" }) do world.append(b, k, NO_ID) end
        world.append(b, "clues", 0)
        world.append(b, "last_roll", 0)
        world.append(b, "days_left", 90)
        world.append(b, "difficulty", 0)
        world.append(b, "event_choice", "astral_rift.1", true)
        world.append(b, "on_roll_failed", "", true)
        world.append(b, "fail_probability", 0)
        world.append(b, "status", "waiting_for_explorer")
        if key then world.append(b, "type", key, true) end
        local id = M.next_id("astral_rift")
        world.create("astral_rift", id, b)
        local init = param(p, "init_effect")
        if init and init.value.text == nil then run(init.value, eval.new_ctx(S("astral_rift", id), ctx.this)) end
        on_action("on_astral_rift_spawned", S("astral_rift", id))
    end
    -- finish_astral_rift = yes (CFinishAstralRiftEffect): the exploration ended: status completed,
    -- the explorer's astral_rifts_completed + 1, on_astral_rift_exploration_complete [I]
    EFF["finish_astral_rift"] = function(e, ctx)
        local r = obj(ctx.this, "astral_rift")
        if not r or e.value.text == "no" then return end
        if world.field(r, "status") == "completed" then return end
        world.set(r, "status", "completed")
        local c = ref(world.field(r, "explorer"))
        local cb = c and world.object("country", c)
        if cb then world.set(cb, "astral_rifts_completed", (tonumber(world.field(cb, "astral_rifts_completed")) or 0) + 1) end
        on_action("on_astral_rift_exploration_complete", S("astral_rift", ctx.this.id), c and S("country", c) or nil)
    end
    -- set_next_astral_rift_event = { id on_roll_failed fail_probability } (CSetNextAstralRiftEvent
    -- Effect: CAstralRift::SetNextEventId, SetRollFailedEventId [V]; the save's event_choice,
    -- on_roll_failed, fail_probability)
    EFF["set_next_astral_rift_event"] = function(e, ctx)
        local r = obj(ctx.this, "astral_rift")
        if not r or e.value.text then return end
        local id = param_text(e.value, "id")
        if id then set_quoted(r, "event_choice", id) end
        local f = param_text(e.value, "on_roll_failed")
        if f then set_quoted(r, "on_roll_failed", f) end
        local px = param(e.value, "fail_probability")
        if px then world.set(r, "fail_probability", num(px.value, ctx, px)) end
    end
    -- fill_astral_rift_event_pool (CFillAstralRiftEventPoolEffect: CAstralRiftManager::FillAstral
    -- RiftEventPool [V]): the pool of starting events refilled with every astral rift type's (the
    -- save's astral_rift_event_pool = { "type" ... } [I])
    EFF["fill_astral_rift_event_pool"] = function(e, ctx)
        if e.value.text == "no" then return end
        local pool = M.meta("astral_rift_event_pool")
        if type(pool) ~= "table" then
            pool = world.child(world.tree, "astral_rift_event_pool")
            world.meta.astral_rift_event_pool = pool
        end
        local have = {}
        for _, x in ipairs(pool) do if x.text then have[unq(x.text)] = true end end
        for _, k in ipairs(keys("common/astral_rifts")) do
            if not have[k] then world.append_value(pool, k, true) end
        end
    end
    -- perform_astral_action_unlock_check (CPerformAstralActionUnlockCheckEffect: CCountry::
    -- PerformAstralActionUnlockCheck [V]): each astral action whose `potential` holds for the country
    -- and is not unlocked yet: unlocked (its usage state's `unlocked = yes`) [I: the trigger's name]
    EFF["perform_astral_action_unlock_check"] = function(e, ctx)
        local cid, c = country_of(ctx.this)
        if not c or e.value.text == "no" then return end
        local arr = world.field(c, "astral_actions_usage_states_array")
        if type(arr) ~= "table" then arr = world.child(c, "astral_actions_usage_states_array") end
        for _, k in ipairs(keys("common/astral_actions")) do
            local d = defs.get("common/astral_actions", k)
            local pot = d and defs.field(d.block, "potential")
            local st = world.field(arr, k)
            local unlocked = type(st) == "table" and world.field(st, "unlocked") == "yes"
            if not unlocked and (type(pot) ~= "table" or eval.trigger(pot, eval.new_ctx(S("country", cid), nil, nil, d.file))) then
                if type(st) ~= "table" then st = world.child(arr, k) end
                world.set(st, "unlocked", "yes")
            end
        end
    end

    -- ------------------------------------------------------------------------------------------
    -- the grand archive (CGrandArchiveCountryModule)

    -- an exhibit made for a category: exhibits = { id = { exhibit_state = unlocked activated = no } }
    -- with its `type`, its id added to the country's archive (CGrandArchiveCountryModule::Unlock
    -- Exhibit [V]; the fields [I])
    local function new_exhibit(c, category)
        M.holder("exhibit")
        local b = {}
        world.append(b, "exhibit_state", "unlocked")
        world.append(b, "activated", "no")
        world.append(b, "type", category, true)
        local id = M.next_id("exhibit")
        world.create("exhibit", id, b)
        local ga = M.archive(c, true)
        local l = world.field(ga, "exhibits")
        if type(l) ~= "table" then l = world.child(ga, "exhibits") end
        world.append_value(l, id)
        return id, b
    end
    local function specimen_types()
        local g = defs.get("common/defines", "NGameplay")
        local t = g and defs.field(g.block, "SPECIMEN_TYPES")
        local out = {}
        for _, x in ipairs(type(t) == "table" and t or {}) do if x.text then out[#out + 1] = unq(x.text) end end
        return out
    end
    -- unlock_exhibit = <category> (CUnlockExhibitEffect: a category of NGameplay SPECIMEN_TYPES, an
    -- exhibit more for it up to GRAND_ARCHIVE_EXHIBITS_COUNT [V])
    EFF["unlock_exhibit"] = function(e, ctx)
        local _, c = country_of(ctx.this)
        local cat = unq(e.value.text)
        if not c or not cat then return end
        local types = specimen_types()
        local known = #types == 0
        for _, t in ipairs(types) do if t == cat then known = true end end
        if not known then return end
        local g = defs.get("common/defines", "NGameplay")
        local cap = g and tonumber(defs.field(g.block, "GRAND_ARCHIVE_EXHIBITS_COUNT")) or 10
        local n = 0
        local ga = M.archive(c, false)
        for _, id in ipairs(ga and M.id_list(ga, "exhibits") or {}) do
            local x = world.object("exhibit", id)
            if x and unq(world.field(x, "type")) == cat then n = n + 1 end
        end
        if n >= cap then return end
        new_exhibit(c, cat)
    end
    -- a specimen put in a free exhibit of its category; the archive's last_acquired_exhibit;
    -- on_specimen_acquired (CGrandArchiveCountryModule::AddCollectedSpecimen [V])
    local function collect(cid, c, key, from_trade)
        if M.has_specimen(c, key) then return false end
        local xid, x = M.free_exhibit(c, M.specimen_type(key))
        if not xid then return false end
        set_quoted(x, "specimen", key)
        world.set(x, "exhibit_state", "filled")
        local ga = M.archive(c, true)
        local l = world.field(ga, "last_acquired_exhibit")
        if type(l) ~= "table" then l = world.child(ga, "last_acquired_exhibit") end
        set_quoted(l, "specimen", key)
        world.set(l, "from_trade", from_trade and "yes" or "no")
        on_action("on_specimen_acquired", S("country", cid))
        return true
    end
    -- give_specimen = { key origin targets } (CGiveSpecimenEffect: when the country has a grand
    -- archive and not the specimen: AddCollectedSpecimen [V])
    EFF["give_specimen"] = function(e, ctx)
        local cid, c = country_of(ctx.this)
        if not c or e.value.text then return end
        local key = param_text(e.value, "key")
        if not M.specimen_def(key) or not M.archive(c, false) then return end
        collect(cid, c, key, false)
    end
    -- remove_specimen = <specimen/exhibit> (CRemoveSpecimenEffect: HasSpecimen, RemoveSpecimen [V]):
    -- the exhibit emptied
    local function empty(x)
        local e = world.entry(x, "specimen")
        if e then world.remove_entry(x, e) end
        world.set(x, "exhibit_state", "unlocked")
        world.set(x, "activated", "no")
    end
    EFF["remove_specimen"] = function(e, ctx)
        local _, c = country_of(ctx.this)
        if not c then return end
        local sc = target(e.value.text, ctx, e)
        local key = unq(e.value.text)
        if sc and sc.kind == "exhibit" then
            local x = world.object("exhibit", sc.id)
            key = x and unq(world.field(x, "specimen"))
        end
        local s = key and M.has_specimen(c, key)
        if s then empty(s.block) end
    end
    -- steal_specimens = { who category count show_nofication } (CStealSpecimensEffect [V]): up to
    -- count of who's specimens of the category (all / any: every category) the country lacks and has
    -- a free exhibit for, drawn one by one (CCrudeRandom::GetFixedPoint), moved
    EFF["steal_specimens"] = function(e, ctx)
        local cid, c = country_of(ctx.this)
        if not c or e.value.text then return end
        local wx = param(e.value, "who")
        local victim = wx and target(wx.value.text, ctx, wx)
        local vc = victim and victim.kind == "country" and world.object("country", victim.id)
        if not vc or not M.archive(c, false) then return end
        local cat = param_text(e.value, "category") or "all"
        local cx = param(e.value, "count")
        local count = cx and math.floor(num(cx.value, ctx, cx)) or 1
        local cands = {}
        for _, s in ipairs(M.specimens_of(vc)) do
            if (cat == "all" or cat == "any" or M.specimen_type(s.key) == cat) and not M.has_specimen(c, s.key) then
                cands[#cands + 1] = s
            end
        end
        for _ = 1, count do
            if #cands == 0 then break end
            local i = pick(#cands)
            local s = table.remove(cands, i)
            if collect(cid, c, s.key, false) then empty(s.block) end
        end
    end

    -- ------------------------------------------------------------------------------------------
    -- anomalies: spawn_random_anomaly = { target surveyor } (CSpawnRandomAnomalyEffect: a category
    -- valid for the planet, CPlanet::OnSurvey's draw, the anomaly set for the target country [V]): a
    -- category of common/anomalies whose spawn_chance is above 0 on the planet, by its spawn_chance
    -- (one draw [I]), as add_anomaly writes it (engine/script/objects_galaxy.lua)
    EFF["spawn_random_anomaly"] = function(e, ctx)
        local p = ctx.this.kind == "planet" and world.object("planet", ctx.this.id)
        if not p or world.field(p, "anomaly") then return end
        local cands, total = {}, 0
        local pctx = eval.new_ctx(ctx.this)
        for _, k in ipairs(keys("common/anomalies")) do
            local d = defs.get("common/anomalies", k)
            local sc = d and defs.field(d.block, "spawn_chance")
            if type(sc) == "table" then
                -- (a weight block: base 0, its modifiers' add / factor: simscript.eval's weight)
                local ok, w = pcall(eval.weight, sc, pctx, 0)
                w = ok and tonumber(w) or 0
                if w > 0 then
                    cands[#cands + 1] = { k, w }
                    total = total + w
                end
            end
        end
        if total <= 0 then return end
        local r = (pick(math.floor(total * 1000)) - 1) / 1000
        local cat = cands[#cands][1]
        for _, c in ipairs(cands) do
            r = r - c[2]
            if r < 0 then cat = c[1] break end
        end
        if world.field(p, "anomaly") ~= nil then world.set(p, "anomaly", cat) else world.append(p, "anomaly", cat, true) end
        local tx = e.value.text == nil and param(e.value, "target")
        local tg = tx and target(tx.value.text, ctx, tx)
        if tg and tg.kind == "country" then world.set(p, "anomaly_owner", tg.id) end
    end

    -- ------------------------------------------------------------------------------------------
    -- bypass_event / pop_faction_event = { id days random scopes } (the events of those scopes, fired
    -- as country_event's: simscript/events.lua's fire_event_effect)
    for _, k in ipairs({ "bypass_event", "pop_faction_event" }) do
        EFF[k] = function(e, ctx)
            if eval.fire_event_effect then return eval.fire_event_effect(k, e, ctx) end
        end
    end
end
