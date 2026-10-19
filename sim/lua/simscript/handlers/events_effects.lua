-- simscript/handlers/events_effects.lua : the effects of handlers/events.lua's area
-- (docs/script_events.md): situations, relics, event chain counters, archaeological sites' stages,
-- astral rifts, cosmic storms, missions. Called by handlers/events.lua with its helpers (M).
--
-- [V] read in the Linux 4.5.2 binary, [I] inferred (the docs, the save's fields).

return function(eval, M)
    local I = eval._internal
    local S, NONE = I.S, I.NONE
    local stats = I.stats
    local EFF = eval.EFF
    local world = require("engine.world")
    local defs = setmetatable({}, { __index = function(_, k) return require("engine.defs")[k] end })
    -- (the engine's modules require simscript.eval: taken when first used, not while eval loads)
    local function lazy(name)
        return setmetatable({}, { __index = function(_, k) return require(name)[k] end })
    end
    local situations = lazy("engine.situations")
    local unq, ref, obj, target, param, param_text = M.unq, M.ref, M.obj, M.target, M.param, M.param_text
    local country_of, set_quoted = M.country_of, M.set_quoted

    local NO_ID = 4294967295
    local creation = lazy("engine.script.creation")
    -- one draw, 1..n (the game's CCrudeRandom::GetInteger: engine.script.creation's draw)
    local function pick(n)
        if n <= 0 then return nil end
        return creation.draw() % n + 1
    end
    M.pick = pick
    -- a day count as the save's date text (360 days a year)
    local function date_text(day)
        local y = math.floor(day / 360)
        local r = day - y * 360
        return string.format("%d.%02d.%02d", y, math.floor(r / 30) + 1, r % 30 + 1)
    end
    M.date_text = date_text
    -- `key = { ... }` of an object replaced (world.set takes tokens only)
    function M.set_block(o, key, block)
        local e = world.entry(o, key)
        if e then world.set_entry(o, e, block) else world.append(o, key, block) end
    end

    local function num(e, ctx)
        return tonumber(eval.value(e.value, ctx, e)) or 0
    end
    local function int(e, ctx)
        local v = num(e, ctx)
        return v >= 0 and math.floor(v) or -math.floor(-v)
    end
    -- the scope `= <event target>` names, else this
    local function target_or_this(e, ctx)
        if e.value.text then
            return target(e.value.text, ctx, e)
        end
        return ctx.this
    end

    -- ------------------------------------------------------------------------------------------
    -- situations (CSituation)

    -- add_situation_progress / set_situation_progress = 5.5 (CSituation::AddProgress, SetProgress
    -- [V]): the progress changed, then HandleProgressChanged (engine/situations.lua: clamped, the
    -- stage updated, on_fail / on_progress_complete)
    EFF["add_situation_progress"] = function(e, ctx)
        local s = obj(ctx.this, "situation")
        if not s then return end
        world.set(s, "progress", (tonumber(world.field(s, "progress")) or 0) + num(e, ctx))
        situations.progress_changed(ctx.this.id, true)
    end
    EFF["set_situation_progress"] = function(e, ctx)
        local s = obj(ctx.this, "situation")
        if not s then return end
        world.set(s, "progress", num(e, ctx))
        situations.progress_changed(ctx.this.id, true)
    end
    -- set_situation_approach = <approach>: when the type has it and its potential and allow hold
    -- (CSituationType::GetApproachByKey, CSituation::IsApproachAllowed, SetCurrentApproach [V])
    EFF["set_situation_approach"] = function(e, ctx)
        local s = obj(ctx.this, "situation")
        local key = unq(e.value.text)
        local a = s and M.approach_def(s, key)
        if not a or not M.approach_allowed(ctx.this.id, a) then return end
        set_quoted(s, "approach", key)
        -- its on_select [I]
        local sel = defs.field(a, "on_select")
        if type(sel) == "table" then eval.effect(sel, eval.new_ctx(S("situation", ctx.this.id))) end
    end
    -- set_situation_locked = yes/no (CSituation +0x661: the save's `locked` [I])
    EFF["set_situation_locked"] = function(e, ctx)
        local s = obj(ctx.this, "situation")
        if not s then return end
        if e.value.text == "no" then
            if world.field(s, "locked") ~= nil then world.set(s, "locked", "no") end
        else
            world.set(s, "locked", "yes")
        end
    end
    -- change_situation_target = none/scope (CSituation::SetTarget [V]: `target = { type id
    -- opener_id }`)
    local TYPE_NAME = { system = "galactic_object" }
    local function target_block(sc)
        local b = {}
        world.append(b, "type", sc and sc ~= NONE and (TYPE_NAME[sc.kind] or sc.kind) or "none")
        world.append(b, "id", sc and sc ~= NONE and sc.id or 0)
        world.append(b, "opener_id", NO_ID)
        return b
    end
    EFF["change_situation_target"] = function(e, ctx)
        local s = obj(ctx.this, "situation")
        if not s then return end
        local sc = e.value.text ~= "none" and target(e.value.text, ctx, e) or nil
        M.set_block(s, "target", target_block(sc))
    end
    -- start_situation = { type = <type> target = <scope> } (CStartSituationEffect -> CCountryEvent
    -- Manager::StartSituation [V]): a situation of the type for the scope's country, its target (the
    -- country by default), progress at the type's start (the first stage's start, or start_value;
    -- `initial_progress` [I]), its stages' durations, the first stage entered, the default approach;
    -- then the type's on_start with the situation as scope (one draw, CCrudeRandom::GetInteger [V]).
    -- The game's own: situation 16777228 of situation_energy_deficit, progress 15, approach
    -- deficit_approach_do_nothing, stage_flags yes no no no, on_start's flag
    function M.start_situation(cid, type_key, sc)
        local t = situations.type(type_key)
        if not t then return nil end
        local d = t.block
        local start = t.start_value
        local initial = tonumber(defs.field(d, "initial_progress"))
        local stages = {}
        local last = start
        for _, st in ipairs(t.stages) do
            local e_end = tonumber(defs.field(st.block, "end")) or last
            stages[#stages + 1] = { last, e_end }
            last = e_end
        end
        local approach, first
        for _, x in ipairs(d) do
            if x.op and x.key and x.key.text == "approach" and type(x.value) == "table" and x.value.text == nil then
                local name = unq(defs.field(x.value, "name"))
                first = first or name
                if defs.field(x.value, "default") == "yes" then approach = name end
            end
        end
        approach = approach or first
        local b = {}
        world.append(b, "country", cid)
        world.append(b, "target", target_block(sc or S("country", cid)))
        world.append(b, "type", type_key, true)
        world.append(b, "progress", initial or start)
        world.append(b, "last_month_progress", 0)
        if approach then world.append(b, "approach", approach, true) end
        local sd = {}
        for _, p in ipairs(stages) do
            local x = {}
            world.append(x, "start", p[1])
            world.append(x, "end", p[2])
            sd[#sd + 1] = { value = x }
        end
        local sdb = {}
        for _, x in ipairs(sd) do sdb[#sdb + 1] = x.value end
        world.append(b, "stage_durations", sdb)
        local flags = {}
        for i = 1, #stages do flags[#flags + 1] = { text = i == 1 and "yes" or "no" } end
        world.append(b, "stage_flags", flags)
        world.append(b, "stage", 0)
        -- the id: the store's next index [I: the game's generations of reused indices not modelled]
        local id = world.next_index("situation")
        world.create("situation", id, b)
        local on_start = defs.field(d, "on_start")
        if type(on_start) == "table" then
            eval.effect(on_start, eval.new_ctx(S("situation", id)))
        end
        return id
    end
    EFF["start_situation"] = function(e, ctx)
        local cid = country_of(ctx.this)
        if not cid or e.value.text then return end
        local key = param_text(e.value, "type")
        local tx = param(e.value, "target")
        local sc = tx and target(tx.value.text, ctx, tx) or nil
        if key then M.start_situation(cid, key, sc) end
    end
    -- abort_situation = <event target>: the type's on_abort, then the situation killed
    -- (CEndSituationEffect<SAbortSituationImpl>: CSituationType::OnAbort, SetToBeKilled [V]; the
    -- kill as destroy_situation's, engine/situations.lua)
    EFF["abort_situation"] = function(e, ctx)
        local sc = target_or_this(e, ctx)
        local s = obj(sc, "situation")
        if not s then return end
        local t = situations.type(unq(world.field(s, "type")))
        local oa = t and defs.field(t.block, "on_abort")
        if type(oa) == "table" then eval.effect(oa, eval.new_ctx(S("situation", sc.id))) end
        world.set(s, "to_be_killed", "yes")
    end

    -- ------------------------------------------------------------------------------------------
    -- relics (CCountry::AddRelic, RemoveRelic [V]: the country's `relics` list; last_received_relic,
    -- last_lost_relic)

    local function relics_block(c)
        local b = world.field(c, "relics")
        if type(b) ~= "table" then b = world.child(c, "relics") end
        return b
    end
    function M.add_relic(c, key)
        local b = relics_block(c)
        for _, x in ipairs(b) do
            if x.text and unq(x.text) == key then return false end
        end
        world.append_value(b, key, true)
        set_quoted(c, "last_received_relic", key)
        return true
    end
    function M.remove_relic(c, key)
        local b = world.field(c, "relics")
        if type(b) ~= "table" then return false end
        for _, x in ipairs(b) do
            if x.text and unq(x.text) == key then
                world.remove_value(b, x.text)
                set_quoted(c, "last_lost_relic", key)
                return true
            end
        end
        return false
    end
    -- add_relic = <key> (CAddRelicEffect: not when the country has it [V])
    EFF["add_relic"] = function(e, ctx)
        local _, c = country_of(ctx.this)
        local key = unq(e.value.text)
        if not c or not defs.get("common/relics", key) then return end
        M.add_relic(c, key)
    end
    -- remove_relic = <key> (CRemoveRelicEffect: when the country has it [V])
    EFF["remove_relic"] = function(e, ctx)
        local _, c = country_of(ctx.this)
        if not c then return end
        M.remove_relic(c, unq(e.value.text))
    end
    -- steal_relic = { target = <country> relic = <key/all/random> } (CStealRelicEffect [V]): the
    -- target's relics (one, every one, or one drawn: CCrudeRandom::GetInteger) moved to the scope's
    -- country
    EFF["steal_relic"] = function(e, ctx)
        local _, c = country_of(ctx.this)
        if not c or e.value.text then return end
        local tx = param(e.value, "target")
        local victim = tx and target(tx.value.text, ctx, tx)
        local vc = victim and victim.kind == "country" and world.object("country", victim.id)
        if not vc then return end
        local which = param_text(e.value, "relic") or "random"
        local owned = M.relics_of(vc)
        local take = {}
        if which == "all" then
            take = owned
        elseif which == "random" then
            if #owned > 0 then
                local r = pick(#owned)
                take = { owned[r] or owned[1] }
            end
        else
            for _, k in ipairs(owned) do
                if k == which then take = { k } end
            end
        end
        for _, k in ipairs(take) do
            if M.remove_relic(vc, k) then M.add_relic(c, k) end
        end
    end

    -- ------------------------------------------------------------------------------------------
    -- event chains: reset_event_chain_counter = { event_chain counter } (CResetEventChainCounter
    -- Effect: CCountryEventManager::AccessEventChain, CObjectiveCounterTracker::ResetCount [V]; the
    -- chain's `counter = { <key> = n }` as add_event_chain_counter keeps it)
    EFF["reset_event_chain_counter"] = function(e, ctx)
        local _, c = country_of(ctx.this)
        if not c or e.value.text then return end
        local chain, counter = param_text(e.value, "event_chain"), param_text(e.value, "counter")
        local evb = M.events_block(c, false)
        for _, x in ipairs(evb or {}) do
            if x.op and x.key and x.key.text == "event_chain" and type(x.value) == "table"
                and unq(world.field(x.value, "event_chain")) == chain then
                local cb = world.field(x.value, "counter")
                if type(cb) ~= "table" then cb = world.child(x.value, "counter") end
                world.set(cb, counter, 0)
                return
            end
        end
    end

    -- ------------------------------------------------------------------------------------------
    -- archaeological sites (CArchaeologicalSite)

    -- set_current_stage = n: the stage index (CArchaeologicalSite::SetStageIndex [V]; `index`)
    EFF["set_current_stage"] = function(e, ctx)
        local s = M.site(ctx.this)
        if not s then return end
        world.set(s, "index", math.max(0, int(e, ctx)))
        world.set(s, "clues", 0)
    end
    -- reset_current_stage = yes/no: the stage's clues and roll back to its start; yes also draws a
    -- new difficulty from the stage's (ResetCurrentStageAndRandomizeDifficulty / ResetCurrentStage
    -- [V]; the fields [I])
    local function site_stage(s)
        local d = defs.get("common/archaeological_site_types", unq(world.field(s, "type")))
        if not d then return nil end
        local i, n = tonumber(world.field(s, "index")) or 0, 0
        for _, x in ipairs(d.block) do
            if x.op and x.key and x.key.text == "stage" and type(x.value) == "table" then
                if n == i then return x.value, d end
                n = n + 1
            end
        end
        return nil, d
    end
    M.site_stage = site_stage
    EFF["reset_current_stage"] = function(e, ctx)
        local s = M.site(ctx.this)
        if not s then return end
        world.set(s, "clues", 0)
        world.set(s, "last_roll", 0)
        local st = site_stage(s)
        if st then
            local days = tonumber(defs.field(st, "days")) or tonumber(world.field(s, "days_left")) or 0
            world.set(s, "days_left", days)
            if e.value.text ~= "no" then
                local diff = defs.field(st, "difficulty")
                local base = tonumber(diff)
                if not base and type(diff) == "table" then
                    local lo, hi = tonumber(defs.field(diff, "min")), tonumber(defs.field(diff, "max"))
                    if lo and hi then base = lo + pick(hi - lo + 1) - 1 end
                end
                if base then world.set(s, "difficulty", base) end
            end
        end
    end
    -- expire_site_event = <event id>: the site's event of that id marked expired (CArchaeological
    -- Site::SetEventExpired [V]; its `events = { { event expired } }` [I])
    EFF["expire_site_event"] = function(e, ctx)
        local s = M.site(ctx.this)
        local id = unq(e.value.text)
        if not s or not id then return end
        local evs = world.field(s, "events")
        if type(evs) ~= "table" then evs = world.child(s, "events") end
        for _, x in ipairs(evs) do
            local v = x.op and x.value or x
            if type(v) == "table" and unq(world.field(v, "event")) == id then
                world.set(v, "expired", "yes")
                return
            end
        end
        local b = {}
        world.append(b, "event", id, true)
        world.append(b, "expired", "yes")
        world.push(evs, b)
    end
    -- add_expedition_log_entry = { title tooltip }: an entry of the current chapter's log
    -- (CArchaeologicalSite::AddExpeditionLogEntry [V]; `log = { { title tooltip index } }` [I])
    EFF["add_expedition_log_entry"] = function(e, ctx)
        local s = M.site(ctx.this)
        if not s or e.value.text then return end
        local log = world.field(s, "log")
        if type(log) ~= "table" then log = world.child(s, "log") end
        local b = {}
        world.append(b, "title", param_text(e.value, "title") or "", true)
        world.append(b, "tooltip", param_text(e.value, "tooltip") or "", true)
        world.append(b, "index", tonumber(world.field(s, "index")) or 0)
        world.push(log, b)
    end
    -- add_stage_clues = n: clues added to the current stage of an arc site, an astral rift or a
    -- first contact, never below 0 (CAddStageCluesEffect: CArchaeologicalSite / CAstralRift /
    -- CFirstContact::AddClues [V]; a first contact's through engine/first_contact.lua, which keeps
    -- the day's newly added clues)
    EFF["add_stage_clues"] = function(e, ctx)
        local sc = ctx.this
        local n = int(e, ctx)
        if sc.kind == "first_contact" then
            local ok, fcm = pcall(require, "engine.first_contact")
            if ok and fcm.add_clues then fcm.add_clues(sc.id, n) end
            return
        end
        local o = (sc.kind == "archaeological_site" or sc.kind == "astral_rift") and world.object(sc.kind, sc.id)
        if not o then return end
        local clues = tonumber(world.field(o, "clues")) or 0
        world.set(o, "clues", math.max(0, clues + n))
    end
    -- destroy_archaeological_site = <target> (CDestroyArchaeologicalSiteEffect: SetToBeKilled [V];
    -- taken out of the store here, as the game does at its next update [I])
    EFF["destroy_archaeological_site"] = function(e, ctx)
        local sc = target_or_this(e, ctx)
        if sc and sc.kind == "archaeological_site" and world.object("archaeological_site", sc.id) then
            world.remove("archaeological_site", sc.id)
        end
    end

    -- ------------------------------------------------------------------------------------------
    -- astral rifts, cosmic storms

    -- destroy_astral_rift = <target> (CDestroyAstralRiftEffect: SetToBeKilled [V])
    EFF["destroy_astral_rift"] = function(e, ctx)
        local sc = target_or_this(e, ctx)
        if sc and sc.kind == "astral_rift" and world.object("astral_rift", sc.id) then
            world.remove("astral_rift", sc.id)
        end
    end
    -- destroy_cosmic_storm: the scoped storm, and the systems it stood in (`storm`) cleared
    -- (CDestroyCosmicStormEffect [V]; the systems [I])
    function M.clear_storm_systems(id)
        for _, sid in ipairs(world.all("system")) do
            local g = world.object("system", sid)
            if g and ref(world.field(g, "storm")) == id then world.set(g, "storm", NO_ID) end
        end
    end
    EFF["destroy_cosmic_storm"] = function(e, ctx)
        if not obj(ctx.this, "cosmic_storm") or e.value.text == "no" then return end
        M.clear_storm_systems(ctx.this.id)
        world.remove("cosmic_storm", ctx.this.id)
    end
    -- lock_storm_in_place = yes/no (CLockCosmicStormInPlaceEffect [V]; the storm's `locked` [I])
    EFF["lock_storm_in_place"] = function(e, ctx)
        local s = obj(ctx.this, "cosmic_storm")
        if not s then return end
        world.set(s, "locked", e.value.text == "no" and "no" or "yes")
    end
    -- set_cosmic_storm = { cosmic_storm = <target> } / unset_cosmic_storm: the system's storm
    -- (CSetCosmicStormEffect: the system's storm, then the storm-entered on_action [V]; the system's
    -- `storm`)
    EFF["set_cosmic_storm"] = function(e, ctx)
        local g = ctx.this.kind == "system" and world.object("system", ctx.this.id)
        if not g then return end
        local tx = e.value.text and e or param(e.value, "cosmic_storm")
        local sc = tx and target(tx.value.text, ctx, tx)
        if sc and sc.kind == "cosmic_storm" and world.object("cosmic_storm", sc.id) then
            world.set(g, "storm", sc.id)
            local ok, oa = pcall(require, "simscript.on_actions")
            if ok and oa.fire then pcall(oa.fire, "on_cosmic_storm_entered_system", eval.new_ctx(S("system", ctx.this.id), sc)) end
        end
    end
    EFF["unset_cosmic_storm"] = function(e, ctx)
        local g = ctx.this.kind == "system" and world.object("system", ctx.this.id)
        if not g or e.value.text == "no" then return end
        world.set(g, "storm", NO_ID)
    end

    -- ------------------------------------------------------------------------------------------
    -- fleets: observation posts' missions, event locks

    -- set_mission = <observation mission> (the fleet's `mission = { mission progress }` [I])
    EFF["set_mission"] = function(e, ctx)
        if ctx.this.kind ~= "fleet" then return end
        local f = world.object("fleet", ctx.this.id)
        local key = unq(e.value.text)
        if not f or not defs.get("common/observation_station_missions", key) then return end
        local m = world.field(f, "mission")
        if type(m) ~= "table" then m = world.child(f, "mission") end
        set_quoted(m, "mission", key)
        world.set(m, "progress", 0)
    end
    -- add_mission_progress = <+/- float> (CAddMissionProgressEffect [V]): the progress, in [0, 1]
    -- [I]
    EFF["add_mission_progress"] = function(e, ctx)
        local m = M.fleet_mission(ctx.this)
        if not m then return end
        local v = (tonumber(world.field(m, "progress")) or 0) + num(e, ctx)
        world.set(m, "progress", math.max(0, math.min(1, v)))
    end
    -- set_event_locked = yes/no (CSetEventLockedEffect: CFleet +0x1260 [V]; `event_locked` [I])
    EFF["set_event_locked"] = function(e, ctx)
        if ctx.this.kind ~= "fleet" then return end
        local f = world.object("fleet", ctx.this.id)
        if not f then return end
        if e.value.text == "no" then
            if world.field(f, "event_locked") ~= nil then world.set(f, "event_locked", "no") end
        else
            world.set(f, "event_locked", "yes")
        end
    end

    -- ------------------------------------------------------------------------------------------
    -- astral actions: start_astral_action_cooldown = <key> (CStartAstralActionCooldownEffect: the
    -- country's usage state of the action (CCountry::AccessAstralActionUsageState), its date = today
    -- + the action's cooldown (CStellarisDate::AddDays) [V]; the save's
    -- astral_actions_usage_states_array = { <action> = { unlockable unlocked usages next_usable_date
    -- is_waiting_for_cooldown_to_start } } (SAstralActionUsageState::WriteMembers [V]))
    EFF["start_astral_action_cooldown"] = function(e, ctx)
        local _, c = country_of(ctx.this)
        local key = unq(e.value.text)
        local d = key and defs.get("common/astral_actions", key)
        if not c or not d then return end
        local cd = defs.field(d.block, "cooldown")
        -- (an @variable of the action's own file)
        local fctx = eval.new_ctx(ctx.this, nil, nil, d.file)
        local days = math.floor(tonumber(cd) or tonumber(eval.value({ text = tostring(cd or 0) }, fctx)) or 0)
        local arr = world.field(c, "astral_actions_usage_states_array")
        if type(arr) ~= "table" then arr = world.child(c, "astral_actions_usage_states_array") end
        local entry = world.field(arr, key)
        if type(entry) ~= "table" then entry = world.child(arr, key) end
        set_quoted(entry, "next_usable_date", date_text(eval.today() + days))
        world.set(entry, "is_waiting_for_cooldown_to_start", "no")
    end
end
