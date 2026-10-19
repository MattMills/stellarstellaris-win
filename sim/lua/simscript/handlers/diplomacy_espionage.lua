-- simscript/handlers/diplomacy_espionage.lua : spy networks, espionage operations and assets
-- (docs/script_diplomacy.md).
--
-- A spy network is the save's `spy_networks = { <id> = { owner target power stored_assets
-- active_operations timed_modifiers formed variables flags leader } }` (CSpyNetwork::WriteMembers
-- 0x2017040 [V]); an operation `espionage_operations = { operations = { <id> = { target spy_network
-- type completed index log last_roll days_left difficulty info events assigned_assets
-- timed_modifiers timed_stage_modifiers flags auto_accept variables locked } } }`
-- (CEspionageOperation 0x25173d0 [V]); an asset `espionage_assets = { <id> = { type species_ref
-- variables flags } }` (CEspionageAsset 0x2512ec0 [V]). An operation's type is
-- common/espionage_operation_types (`categories`, `stages`, `spy_power_cost`, `stage = { difficulty
-- event }`).

return function(eval, H)
    local TRIG, EFF, LINKS, LISTS = eval.TRIG, eval.EFF, eval.LINKS, eval.LISTS
    local D, world = H.D, H.world
    local S = H.S
    local sync, yes = H.sync, H.yes
    local this_country, param_country, param_text = H.this_country, H.param_country, H.param_text
    local compare_value, fixed = H.compare_value, H.fixed

    local function network(ctx) return H.scoped(ctx, "spy_network") end
    local function operation(ctx) return H.scoped(ctx, "espionage_operation") end
    local function op_type(o) return tostring(world.field(o, "type") or ""):gsub('"', "") end
    local function op_def(o) return H.def("common/espionage_operation_types", op_type(o)) end
    local function asset_type(id)
        local a = H.object("espionage_asset", id)
        return a and tostring(world.field(a, "type") or ""):gsub('"', "") or nil
    end
    -- the network or operation scope's asset list (stored_assets / assigned_assets)
    local function asset_list(ctx, create)
        local _, n = network(ctx)
        if n then return create and world.child(n, "stored_assets") or world.field(n, "stored_assets"), n end
        local _, o = operation(ctx)
        if o then return create and world.child(o, "assigned_assets") or world.field(o, "assigned_assets"), o end
        return nil
    end
    -- the first asset of a type in a list (GetAssetOfType)
    local function asset_of_type(list, t)
        for _, id in ipairs(D.id_list(list)) do
            if asset_type(id) == t then return id end
        end
        return nil
    end
    local function network_of_op(o)
        local nid = D.ref(world.field(o, "spy_network"))
        return nid, nid and H.object("spy_network", nid)
    end

    -- ------------------------------------------------------------------------------------------
    -- networks

    -- the network's level (its `power`, CSpyNetwork::GetCurrentSpyPower)
    local function level(n) return H.num(world.field(n, "power")) end
    -- its maximum level (SPY_NETWORK_LEVELS; the encryption against decryption term [I: the
    -- countries' encryption and decryption are modifier totals not read here, so 0]), at most
    -- SPY_NETWORK_MAX_LEVELS
    local function max_level()
        return math.min(H.define("NGameplay", "SPY_NETWORK_LEVELS", 50), H.define("NGameplay", "SPY_NETWORK_MAX_LEVELS", 100))
    end
    -- the spy power its running operations take (their types' spy_power_cost) [I:
    -- CalcAvailableSpyPower]
    local function used_power(n)
        local used = 0
        for _, oid in ipairs(D.id_list(world.field(n, "active_operations"))) do
            local o = H.object("espionage_operation", oid)
            local d = o and op_def(o)
            used = used + (tonumber(H.def_field(d, "spy_power_cost")) or 0)
        end
        return used
    end

    -- add_spy_network_level = <n> (CAddSpyNetworkLevelEffect 0x37f6f70 -> AddNetworkLevel): the
    -- level within 0..SPY_NETWORK_MAX_POWER [I: the bound]
    EFF["add_spy_network_level"] = function(e, ctx)
        local _, n = network(ctx)
        if not n then return end
        local v = math.floor(H.value(e, ctx))
        sync()
        local p = math.max(0, math.min(H.define("NGameplay", "SPY_NETWORK_MAX_POWER", 100), level(n) + v))
        world.set(n, "power", p)
        H.script_write()
    end
    H.num_trigger("has_spy_power", function(ctx)
        local _, n = network(ctx)
        return n and level(n) or nil
    end)
    H.num_trigger("has_spynetwork_value", function(ctx)
        local _, n = network(ctx)
        return n and level(n) or nil
    end)
    H.num_trigger("is_spynetwork_level", function(ctx)
        local _, n = network(ctx)
        return n and level(n) or nil
    end)
    H.num_trigger("is_spynetwork_max_level", function(ctx)
        local _, n = network(ctx)
        return n and max_level() or nil
    end)
    -- has_available_spy_power <op> n (CHasAvailableSpyPowerTrigger 0x3c18ec0)
    H.num_trigger("has_available_spy_power", function(ctx)
        local _, n = network(ctx)
        return n and (level(n) - used_power(n)) or nil
    end)
    -- has_spynetwork = yes/no: a network of the country's with a level above 0
    TRIG["has_spynetwork"] = function(e, ctx)
        local us = this_country(ctx)
        local r = false
        if us then
            for _, id in ipairs(H.all("spy_network")) do
                local n = H.object("spy_network", id)
                if n and D.ref(world.field(n, "owner")) == us and level(n) > 0 then r = true break end
            end
        end
        return r == yes(e)
    end
    -- spynetwork (an operation's network, a spymaster envoy's: its location `type = spy_network`)
    LINKS["spynetwork"] = function(cur)
        if cur.kind == "espionage_operation" then
            local o = H.object("espionage_operation", cur.id)
            local nid = o and D.ref(world.field(o, "spy_network"))
            return (nid and H.object("spy_network", nid)) and S("spy_network", nid) or nil
        end
        if cur.kind == "leader" then
            local l = world.object("leader", cur.id)
            local loc = l and world.field(l, "location")
            if type(loc) == "table" and world.field(loc, "type") == "spy_network" then
                local nid = D.ref(world.field(loc, "id"))
                return (nid and H.object("spy_network", nid)) and S("spy_network", nid) or nil
            end
        end
        return nil
    end

    -- ------------------------------------------------------------------------------------------
    -- assets

    -- create_espionage_asset = { type effect } (CCreateEspionageAssetEffect 0x37f5b00): a new asset
    -- of the type (CGameState::CreateEspionageAsset) in the network's stored_assets; the effect runs
    -- in its scope
    EFF["create_espionage_asset"] = function(e, ctx)
        local _, n = network(ctx)
        if not n or e.value.text then return end
        local t = param_text(e.value, "type")
        if not t or not H.def("common/espionage_assets", t) then return end
        sync()
        local id = H.next_id("espionage_asset")
        local a = {}
        world.create(H.STORE.espionage_asset, id, a)
        H.set_quoted(a, "type", t)
        H.list_add(n, "stored_assets", id)
        H.script_write()
        local x = H.param(e.value, "effect")
        if x and type(x.value) == "table" then
            local c = eval._internal.push(ctx, S("espionage_asset", id))
            pcall(eval.effect, x.value, c)
        end
    end
    -- destroy_espionage_asset = <type> (CDestroyEspionageAssetEffect 0x37f5dc0): the first asset of
    -- the type in the network or operation, out of its list and killed
    EFF["destroy_espionage_asset"] = function(e, ctx)
        local list = asset_list(ctx, false)
        local id = list and e.value.text and asset_of_type(list, e.value.text)
        if not id then return end
        sync()
        world.remove_value(list, tostring(id))
        world.remove(H.STORE.espionage_asset, id)
        H.script_write()
    end
    -- assign_espionage_asset = <type> (0x37f60f0): the operation's network's asset of the type moved
    -- to the operation's assigned_assets; unassign_espionage_asset (0x37f62f0) moves it back
    EFF["assign_espionage_asset"] = function(e, ctx)
        local _, o = operation(ctx)
        if not o or not e.value.text then return end
        local _, n = network_of_op(o)
        local id = n and asset_of_type(world.field(n, "stored_assets"), e.value.text)
        if not id then return end
        sync()
        H.list_remove(n, "stored_assets", id)
        H.list_add(o, "assigned_assets", id)
        H.script_write()
    end
    EFF["unassign_espionage_asset"] = function(e, ctx)
        local _, o = operation(ctx)
        if not o or not e.value.text then return end
        local id = asset_of_type(world.field(o, "assigned_assets"), e.value.text)
        local _, n = network_of_op(o)
        if not id or not n then return end
        sync()
        H.list_remove(o, "assigned_assets", id)
        H.list_add(n, "stored_assets", id)
        H.script_write()
    end
    -- has_espionage_asset = <type> (CHasEspionageAssetTrigger 0x3c18b00)
    TRIG["has_espionage_asset"] = function(e, ctx)
        local list = asset_list(ctx, false)
        return list ~= nil and e.value.text ~= nil and asset_of_type(list, e.value.text) ~= nil
    end
    -- num_espionage_assets <op> n (CNumEspionageAssetsTrigger 0x3c18ca0: GetAllAssets)
    H.num_trigger("num_espionage_assets", function(ctx)
        local list = asset_list(ctx, false)
        if not list then
            if ctx.this.kind ~= "spy_network" and ctx.this.kind ~= "espionage_operation" then return nil end
            return 0
        end
        return #D.id_list(list)
    end)

    -- ------------------------------------------------------------------------------------------
    -- operations

    -- add_espionage_information = <value> (CAddEspionageInformationEffect 0x37f6dc0): the current
    -- stage's information (`info`) [I: the field]
    EFF["add_espionage_information"] = function(e, ctx)
        local _, o = operation(ctx)
        if not o then return end
        local v = H.value(e, ctx)
        sync()
        world.set(o, "info", fixed(H.num(world.field(o, "info")) + v))
        H.script_write()
    end
    -- add_stage_modifier = { modifier days } (CAddStageModifierEffect 0x3807e80): an operation's
    -- `timed_stage_modifiers`, an astral rift's stage modifiers (its `timed_stage_modifiers` [I]):
    -- `{ modifier days }` (-1: never expires)
    local function stage_holder(ctx)
        local _, o = operation(ctx)
        if o then return o end
        if ctx.this.kind == "astral_rift" then
            for _, store in ipairs({ "astral_rifts", "astral_rift" }) do
                local r = world.object(store, ctx.this.id)
                if r then return r end
            end
        end
        return nil
    end
    local function stage_items(h, create)
        local t = create and world.child(h, "timed_stage_modifiers") or world.field(h, "timed_stage_modifiers")
        if type(t) ~= "table" then return nil end
        return create and world.child(t, "items") or world.field(t, "items")
    end
    EFF["add_stage_modifier"] = function(e, ctx)
        local h = stage_holder(ctx)
        if not h or e.value.text then return end
        local m = param_text(e.value, "modifier")
        if not m then return end
        local days = math.floor(H.param_value(e.value, "days", ctx, -1))
        sync()
        local item = {}
        H.set_quoted(item, "modifier", m)
        world.append(item, "days", days)
        world.push(stage_items(h, true), item)
        H.script_write()
    end
    EFF["remove_stage_modifier"] = function(e, ctx)
        local h = stage_holder(ctx)
        local items = h and stage_items(h, false)
        if type(items) ~= "table" or not e.value.text then return end
        sync()
        for i = #items, 1, -1 do
            local it = items[i]
            if not it.text and not it.op and tostring(world.field(it, "modifier") or ""):gsub('"', "") == e.value.text then
                world.remove_at(items, i)
                H.script_write()
                return
            end
        end
    end
    TRIG["has_stage_modifier"] = function(e, ctx)
        local h = stage_holder(ctx)
        local items = h and stage_items(h, false)
        for _, it in ipairs(type(items) == "table" and world.blocks(items) or {}) do
            if tostring(world.field(it, "modifier") or ""):gsub('"', "") == e.value.text then return true end
        end
        return false
    end
    -- finish_current_operation_stage = yes/no (CFinishCurrentOperationStageEffect 0x37f5700 ->
    -- FinishCurrentStage): the next stage (`index` + 1), its information and roll reset; with yes the
    -- stage's event fires (FireStageEvent: the stage's `event`, this = the operation [I]); past the
    -- last stage the operation is completed
    EFF["finish_current_operation_stage"] = function(e, ctx)
        local oid, o = operation(ctx)
        if not o then return end
        sync()
        local d = op_def(o)
        local idx = H.num(world.field(o, "index"))
        local stages = {}
        for _, x in ipairs(d and d.block or {}) do
            if x.op and x.key and x.key.text == "stage" and type(x.value) == "table" then stages[#stages + 1] = x.value end
        end
        local cur = stages[idx + 1]
        world.set(o, "index", idx + 1)
        world.set(o, "info", 0)
        world.set(o, "last_roll", 0)
        if idx + 1 >= #stages then world.set(o, "completed", "yes") end
        H.script_write()
        if e.value.text == "yes" and cur then
            local ev = require("engine.defs").field(cur, "event")
            local ok, events = pcall(require, "simscript.events")
            if ev and ok and events.fire then
                pcall(events.fire, ev, S("espionage_operation", oid), eval.new_ctx(S("espionage_operation", oid), ctx.this))
            end
        end
    end
    -- set_espionage_operation_progress_locked = yes/no (0x37f6010: the operation's +0x2e8, `locked`)
    EFF["set_espionage_operation_progress_locked"] = function(e, ctx)
        local _, o = operation(ctx)
        if not o or (e.value.text ~= "yes" and e.value.text ~= "no") then return end
        sync()
        world.set(o, "locked", e.value.text)
        H.script_write()
    end
    -- destroy_espionage_operation = <event target> (CDestroyEspionageOperationEffect 0x37f6c20): the
    -- operation's assets back to its network (ReturnAllAssetsTo), out of the network's
    -- active_operations, the operation removed
    EFF["destroy_espionage_operation"] = function(e, ctx)
        local sc = e.value.text and H.scope_of(e.value.text, ctx, e)
        if not sc or sc.kind ~= "espionage_operation" then return end
        local o = H.object("espionage_operation", sc.id)
        if not o then return end
        sync()
        local _, n = network_of_op(o)
        for _, a in ipairs(D.id_list(world.field(o, "assigned_assets"))) do
            if n then H.list_add(n, "stored_assets", a) end
        end
        if n then H.list_remove(n, "active_operations", sc.id) end
        world.remove(H.STORE.espionage_operation, sc.id)
        H.script_write()
    end
    -- has_espionage_type = <type>, has_espionage_category = <category> (the type's `categories`)
    TRIG["has_espionage_type"] = function(e, ctx)
        local _, o = operation(ctx)
        return o ~= nil and op_type(o) == e.value.text
    end
    TRIG["has_espionage_category"] = function(e, ctx)
        local _, o = operation(ctx)
        local cats = o and H.def_field(op_def(o), "categories")
        for _, x in ipairs(type(cats) == "table" and cats or {}) do
            if x.text == e.value.text then return true end
        end
        return false
    end
    -- the operation's numbers: chapter (index, +0x2e4), days to the next roll (days_left, +0x2c8),
    -- difficulty, last roll; the score: CalcOperationSkill (the network's level / 10 [I]) - the
    -- difficulty + the last roll (without it: _no_die)
    local function op_num(k, f)
        H.num_trigger(k, function(ctx)
            local _, o = operation(ctx)
            return o and f(o) or nil
        end)
    end
    local function skill(o)
        local _, n = network_of_op(o)
        return n and level(n) / 10 or 0
    end
    op_num("is_espionage_operation_chapter", function(o) return H.num(world.field(o, "index")) end)
    op_num("is_espionage_operation_days_to_next_die_roll", function(o) return H.num(world.field(o, "days_left")) end)
    op_num("is_espionage_operation_difficulty", function(o) return H.num(world.field(o, "difficulty")) end)
    op_num("is_espionage_operation_last_die_result", function(o) return H.num(world.field(o, "last_roll")) end)
    op_num("is_espionage_operation_score", function(o)
        return skill(o) - H.num(world.field(o, "difficulty")) + H.num(world.field(o, "last_roll"))
    end)
    op_num("is_espionage_operation_score_no_die", function(o)
        return skill(o) - H.num(world.field(o, "difficulty"))
    end)
    -- is_running_espionage_operation = yes/no (0x3c19270): a network with active operations, a
    -- country with a network that has one
    TRIG["is_running_espionage_operation"] = function(e, ctx)
        local r = false
        local _, n = network(ctx)
        if n then
            r = #D.id_list(world.field(n, "active_operations")) > 0
        else
            local us = this_country(ctx)
            for _, id in ipairs(us and H.all("spy_network") or {}) do
                local x = H.object("spy_network", id)
                if x and D.ref(world.field(x, "owner")) == us and #D.id_list(world.field(x, "active_operations")) > 0 then r = true break end
            end
        end
        return r == yes(e)
    end
    -- is_counter_espionage <op> n (CIsCounterEspionageTrigger 0x3c18a00 ->
    -- CCountryEspionageManager::GetCounterIntelligenceValue) [I: a modifier total not in the save; 0]
    H.num_trigger("is_counter_espionage", function(ctx)
        return this_country(ctx) and 0 or nil
    end)
    -- relative_encryption_decryption = { target value } (CRelativeEncryptionDecryptionTrigger
    -- 0x3c195a0): the scope's encryption over the target's decryption [I: both modifier totals not in
    -- the save; 1]
    TRIG["relative_encryption_decryption"] = function(e, ctx)
        if e.value.text then return false end
        local k = ctx.this.kind
        if k ~= "country" and k ~= "spy_network" and k ~= "espionage_operation" then return false end
        return compare_value(1, e, ctx)
    end

    -- the lists: an operation's / a network's / every asset; a country's (its networks'), a
    -- network's, every operation
    LISTS["espionage_asset"] = function(sc)
        local out = {}
        if sc and (sc.kind == "spy_network" or sc.kind == "espionage_operation") then
            local o = H.object(sc.kind, sc.id)
            local key = sc.kind == "spy_network" and "stored_assets" or "assigned_assets"
            for _, id in ipairs(D.id_list(o and world.field(o, key) or nil)) do out[#out + 1] = S("espionage_asset", id) end
            return out
        end
        for _, id in ipairs(H.all("espionage_asset")) do
            if H.object("espionage_asset", id) then out[#out + 1] = S("espionage_asset", id) end
        end
        return out
    end
    LISTS["espionage_operation"] = function(sc)
        local out = {}
        for _, id in ipairs(H.all("espionage_operation")) do
            local o = H.object("espionage_operation", id)
            if o then
                local nid, n = network_of_op(o)
                local keep = true
                if sc and sc.kind == "spy_network" then keep = nid == sc.id
                elseif sc and sc.kind == "country" then keep = n ~= nil and D.ref(world.field(n, "owner")) == sc.id end
                if keep then out[#out + 1] = S("espionage_operation", id) end
            end
        end
        return out
    end
end
