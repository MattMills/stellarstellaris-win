-- engine/first_contact.lua : first contact (common/first_contact), the way the game advances it
-- (GOG 4.5.2, docs/situations.md section 2), on the save's store
--
--   first_contacts = { contacts = { 17 = { owner = 16777219 country = 16777224 location = 38
--       leader = 167772180 date = "2207.06.20" last_roll = 2 days_left = 9.7 difficulty = 7
--       clues = 1 stage = "default_stage_2" status = in_progress events = { } completed = { } } } }
--   country = { 6 = { first_contact = { contacts = { 19 } } } }
--
-- Every day, in CCountry::DailyUpdateSerial (CCountry::UpdateContacts, before the country's events),
-- CFirstContactsData::DailyUpdate (0x8d8790) walks the country's contacts from the last: a contact
-- whose owner or contact country is gone is taken out of the list and destroyed (a message when it
-- was still going on); one in progress gets CFirstContact::DailyUpdateSerial (0x8db580):
--
--   locked (status 1), no envoy (`leader` not a living leader), finished or aborted: nothing;
--   the owner's intel on the contact country >= FIRST_CONTACT_INTEL_TARGET: Finish;
--   newly added clues = 0;
--   days_left -= CalcDiscoverySpeed (0x8dd380) = 1 + the owner's first_contact_speed_mult;
--   when days_left reaches 0:
--     days_left = FIRST_CONTACT_DISCOVERY_DAYS for a human owner (CCountry::_HumanIds) else
--                 FIRST_CONTACT_DISCOVERY_DAYS_AI
--     x = one draw (line 682); last_roll = noise(noise(x, 0x5EA6A49F), 0) % (MAX - MIN + 1) + MIN
--         (FIRST_CONTACT_DICE_ROLL_MIN/MAX; the noise is CRandom's, without the final mask)
--     MAX - MIN + 1 more draws (CRandom::GetIntegersForMacro, line 688; unused)
--     score (CalcCurrentDiscoveryScore 0x8dd1c0) = clues - difficulty - malus + bonus + last_roll
--       bonus (CalcDiscoveryBonus 0x8ddcb0, the owner's modifiers) =
--             int(intel_decryption_add * max(1 + intel_decryption_mult, 0)) + int(first_contact_clues_add)
--       malus (CalcTargetDiscoveryMalus 0x8dd9d0, the contact country's) =
--             int(intel_encryption_add * max(1 + intel_encryption_mult, 0)) when its country type is
--             Playable, + int(first_contact_defense_add)
--     score >= FIRST_CONTACT_DISCOVERY_SCORE: one draw (line 695), FireStageEvent (0x8dc4e0)
--     else: one draw (line 699), HandleRollFailed (0x8db810)
--
-- FireStageEvent: three draws for the event scopes, then each `stage_event`'s `event_weight` (a
-- CMeanTimeToHappen, base 0) with the first contact as scope; one picked by
-- GetWeightedRandomInternal<CFixedPoint> (0x1b4ad80: the draw modulo the sum of the positive
-- weights) and fired (CEventManager::TriggerEvent): this = root = the first contact, from = the
-- contact country. The stage changes through the event's script (set_first_contact_stage).
-- HandleRollFailed: the stage's `on_roll_failed` effect on the same scopes (in vanilla
-- standard_first_contact_on_roll_failed: add_stage_clues by the score, a 1-in-20 random event).
--
-- Engine effects the scripts use (implemented here when the script layer has none):
--   set_first_contact_stage (CFirstContact::SetCurrentStage 0x8d9400): the old stage appended to
--     `completed`, the stage set, one draw (line 311) for its difficulty (min + h % (range + 1):
--     vanilla stages have one value), clues = 0;
--   add_stage_clues (CAddStageCluesEffect 0x17f8130): clues += n (never below 0);
--   set_site_progress_locked (0x17b6370): status locked / in_progress unless finished or aborted;
--   finish_first_contact (CFirstContact::Finish 0x8dcd60): on_first_contact_finished (this = the
--     first contact, from = the contact country), the envoy released (its `location` cleared),
--     CCountry::EstablishCommunications (here only: `pre_communications_name` dropped from both
--     relations), status finished.
--
-- Not modelled: the creation of first contacts (CFirstContactManager::CreateContact from
-- CCountry::ContactInternal: fleets and intel), the intel that grows (the save's own value is
-- read), the AI's envoy assignment, the pending event and its interface, the rest of
-- EstablishCommunications (intel, relations, on_actions).

local world = require("engine.world")
local defs = require("engine.defs")
local bit = require("bit")
local live = require("engine.store.live")   -- the store's copy of what exploration reads (docs/data_layer.md)

world.KINDS.first_contact = world.KINDS.first_contact or "contacts"

local first_contact = {
    stats = { days = 0, updates = 0, rolls = 0, successes = 0, failures = 0, events_fired = 0, no_event = 0,
        finished = 0, finished_by_intel = 0, removed = 0, no_envoy = 0, locked = 0, stage_changes = 0,
        clues_added = 0, errors = 0, unknown_stages = 0 },
    errors = {},
    newly_added = {},  -- contact id -> clues added since the day's update (_nNewlyAddedClues)
}

local FP = 100000
local NO_ID = 4294967295
local TWO32 = 4294967296

local function fp(v)
    v = tonumber(v) or 0
    if v >= 0 then
        return math.floor(v * FP + 0.5)
    end
    return -math.floor(-v * FP + 0.5)
end
local function trunc(x)
    return x >= 0 and math.floor(x) or -math.floor(-x)
end

-- ---------------------------------------------------------------------------------------------
-- the noise function of CRandom (docs/simulation.md section 3), in unsigned 32-bit arithmetic

local function mul32(a, b)
    local al, ah = a % 65536, math.floor(a / 65536)
    local bl, bh = b % 65536, math.floor(b / 65536)
    return (((ah * bl + al * bh) % 65536) * 65536 + al * bl) % TWO32
end
local function xor32(a, b)
    return bit.bxor(a, b) % TWO32
end
local function noise(n, seed)
    local x = (seed + mul32(n % TWO32, 0xB5297A4D)) % TWO32
    x = xor32(x, math.floor(x / 256))
    x = (x + 0x68E31DA4) % TWO32
    x = xor32(x, (x * 256) % TWO32)
    x = mul32(x, 0x1B56C4E9)
    x = xor32(x, math.floor(x / 256))
    x = mul32(x, 0x92D68CA2)
    x = xor32(x, math.floor(x / 256))
    return x
end
first_contact.noise = noise

-- the die of a roll from one draw x (DailyUpdateSerial 0x8db6c9-0x8db759; SetCurrentStage
-- 0x8d978e the same): noise twice, the sign bit cleared
local function die(x, range)
    local h = noise(noise(x, 0x5EA6A49F), 0) % 2147483648
    return h % range
end
first_contact.die = die

-- ---------------------------------------------------------------------------------------------
-- defines (common/defines NGameplay)

local D
local function defines()
    if D then
        return D
    end
    local g = defs.get("common/defines", "NGameplay")
    local function d(key, default)
        local v = g and tonumber(defs.field(g.block, key))
        return v or default
    end
    D = {
        DICE_ROLL_MIN = d("FIRST_CONTACT_DICE_ROLL_MIN", 1),
        DICE_ROLL_MAX = d("FIRST_CONTACT_DICE_ROLL_MAX", 10),
        DISCOVERY_SCORE = d("FIRST_CONTACT_DISCOVERY_SCORE", 10),
        DISCOVERY_DAYS = d("FIRST_CONTACT_DISCOVERY_DAYS", 80),
        DISCOVERY_DAYS_AI = d("FIRST_CONTACT_DISCOVERY_DAYS_AI", 110),
        INTEL_TARGET = d("FIRST_CONTACT_INTEL_TARGET", 10),
        LOWER_INSIGHT_SCORE = d("FIRST_CONTACT_LOWER_INSIGHT_SCORE", 0),
        HIGHER_INSIGHT_SCORE = d("FIRST_CONTACT_HIGHER_INSIGHT_SCORE", 5),
        LOWER_INSIGHT_REWARD = d("FIRST_CONTACT_LOWER_INSIGHT_REWARD", 1),
        HIGHER_INSIGHT_REWARD = d("FIRST_CONTACT_HIGHER_INSIGHT_REWARD", 2),
    }
    return D
end

-- ---------------------------------------------------------------------------------------------
-- the stages (common/first_contact)

local stage_cache = {}
local function stage(key)
    local s = stage_cache[key]
    if s ~= nil then
        return s or nil
    end
    local d = key and defs.get("common/first_contact", key)
    if not d then
        stage_cache[key or ""] = false
        return nil
    end
    s = { key = key, file = d.file, events = {}, on_roll_failed = defs.field(d.block, "on_roll_failed") }
    local diff = defs.field(d.block, "difficulty")
    if type(diff) == "table" then
        s.min = tonumber(defs.field(diff, "min")) or 0
        s.range = math.max(0, (tonumber(defs.field(diff, "max")) or s.min) - s.min)
    else
        s.min, s.range = tonumber(diff) or 0, 0
    end
    for _, e in ipairs(d.block) do
        if e.op and e.key and e.key.text == "stage_event" and e.value.text == nil then
            s.events[#s.events + 1] = { event = defs.field(e.value, "event"), weight = defs.field(e.value, "event_weight") }
        end
    end
    stage_cache[key] = s
    return s
end
first_contact.stage = stage

-- ---------------------------------------------------------------------------------------------
-- the world

local function eval()
    return require("simscript.eval")
end

local function ref(v)
    v = tonumber(v)
    return (v and v ~= NO_ID) and v or nil
end

local function modifiers_of(country)
    local economy = package.loaded["engine.economy"]
    return economy and economy.modifiers("country", country) or {}
end

local humans
local function is_human(country)
    if humans == nil then
        humans = {}
        for _, b in ipairs(world.blocks(world.meta.player)) do
            local c = tonumber(world.field(b, "country"))
            if c then humans[c] = true end
        end
    end
    return humans[country] == true
end

local function playable(country)
    local t = world.field(world.object("country", country), "type")
    local d = t and defs.get("common/country_types", t)
    return d ~= nil and defs.field(d.block, "playable") == "yes"
end

-- the owner's intel on another country: `intel_manager = { intel = { { 16 { intel = 25.9 } } } }`
local function intel_of(owner, other)
    local im = world.field(world.object("country", owner), "intel_manager")
    for _, b in ipairs(world.blocks(world.field(im, "intel"))) do
        local id, data
        for _, e in ipairs(b) do
            if e.text then id = tonumber(e.text)
            elseif not e.op then data = e end
        end
        if id == other and data then
            return tonumber(world.field(data, "intel"))
        end
    end
    return nil
end

local function status(fc)
    return world.field(fc, "status")
end

local function err(what, e)
    first_contact.stats.errors = first_contact.stats.errors + 1
    if #first_contact.errors < 10 then
        first_contact.errors[#first_contact.errors + 1] = what .. ": " .. tostring(e)
    end
end

local function ctx_of(id, fc, file)
    local ev = eval()
    local c = ev.new_ctx(ev.S("first_contact", id), nil, nil, file)
    local from = ref(world.field(fc, "country"))
    c.from = from and ev.S("country", from) or ev.NONE
    return c
end

-- ---------------------------------------------------------------------------------------------
-- the formulas

-- CFirstContact::CalcDiscoverySpeed (0x8dd380), CFixedPoint
local function speed(fc)
    local m = modifiers_of(ref(world.field(fc, "owner")))
    return FP + fp(m.first_contact_speed_mult or 0)
end

-- int(a * max(1 + b, 0)) in CFixedPoint (truncated twice, as the game)
local function scaled(add, mult)
    local a, b = fp(add or 0), math.max(FP + fp(mult or 0), 0)
    return trunc(trunc(a * b / FP) / FP)
end

-- CFirstContact::CalcDiscoveryBonus (0x8ddcb0)
local function bonus(fc)
    local m = modifiers_of(ref(world.field(fc, "owner")))
    return scaled(m.intel_decryption_add, m.intel_decryption_mult) + trunc(m.first_contact_clues_add or 0)
end

-- CFirstContact::CalcTargetDiscoveryMalus (0x8dd9d0)
local function malus(fc)
    local target = ref(world.field(fc, "country"))
    local m = modifiers_of(target)
    local v = 0
    if target and playable(target) then
        v = scaled(m.intel_encryption_add, m.intel_encryption_mult)
    end
    return v + trunc(m.first_contact_defense_add or 0)
end

-- CFirstContact::CalcCurrentDiscoveryScore (0x8dd1c0); without the die for the _no_die trigger
local function score(fc, no_die)
    local clues = tonumber(world.field(fc, "clues")) or 0
    local difficulty = tonumber(world.field(fc, "difficulty")) or 0
    local s = clues - (difficulty + malus(fc)) + bonus(fc)
    if not no_die then
        s = s + (tonumber(world.field(fc, "last_roll")) or 0)
    end
    return s
end
first_contact.score = function(id, no_die)
    local fc = world.object("first_contact", id)
    return fc and score(fc, no_die)
end

-- ---------------------------------------------------------------------------------------------
-- the engine's actions

-- CFirstContact::SetCurrentStage (0x8d9400)
local function set_stage(id, fc, key)
    local st = stage(key)
    if not st then
        first_contact.stats.unknown_stages = first_contact.stats.unknown_stages + 1
        return
    end
    local old = world.field(fc, "stage")
    if type(old) == "string" then
        -- the old stage and today appended to _Completed (`completed = { { date = stage = } }`)
        local engine = package.loaded["engine"]
        local completed = world.child(fc, "completed")
        local b = {}
        world.append(b, "date", engine and engine.date_text and engine.date_text() or tostring(world.meta.date), true)
        world.append(b, "stage", old, true)
        world.push(completed, b)
        world.set(fc, "stage", key)
    else
        world.append(fc, "stage", key, true)
    end
    local x = E.rand() -- line 311
    world.set(fc, "difficulty", st.min + die(x, st.range + 1))
    world.set(fc, "clues", 0)
    first_contact.stats.stage_changes = first_contact.stats.stage_changes + 1
end

-- the relation of a country with another (`relations_manager = { relation = { owner country ... } }`)
local function relation(owner, other)
    local rm = world.field(world.object("country", owner), "relations_manager")
    for _, r in ipairs(type(rm) == "table" and world.fields(rm, "relation") or {}) do
        if type(r) == "table" and tonumber(world.field(r, "country")) == other then
            return r
        end
    end
    return nil
end
local function drop(block, key)
    if type(block) ~= "table" then return end
    for i = #block, 1, -1 do
        local e = block[i]
        if e.op and e.key and e.key.text == key then
            world.remove_entry(block, e)
        end
    end
end

-- CFirstContact::Finish (0x8dcd60)
local function finish(host, id, fc)
    local owner, other = ref(world.field(fc, "owner")), ref(world.field(fc, "country"))
    -- on_first_contact_finished: this = the first contact, from = the contact country
    local ev = eval()
    local from = other and { this = ev.S("country", other) } or nil
    local ok, e = pcall(require("simscript.events").on_action, "on_first_contact_finished", ev.S("first_contact", id), from)
    if not ok then err("on_first_contact_finished", e) end
    -- the envoy released: its location back to none (CLeader +0x110), its assignment cooldown 0
    local l = ref(world.field(fc, "leader"))
    local leader = l and world.object("leader", l)
    if leader then
        drop(leader, "location")
    end
    -- CCountry::EstablishCommunications (only the relations' pre-communications names here)
    if owner and other then
        drop(relation(owner, other), "pre_communications_name")
        drop(relation(other, owner), "pre_communications_name")
        live.touch("country", owner)
        live.touch("country", other)
    end
    world.set(fc, "status", "finished")
    first_contact.stats.finished = first_contact.stats.finished + 1
end

-- CMeanTimeToHappen::GetRawFactor of a stage event's event_weight (base 0), CFixedPoint
local function event_weight(b, ctx)
    local ev = eval()
    if type(b) ~= "table" then
        return 0
    end
    local acc = 0
    local function apply(k, v)
        if k == "add" or k == "weight" then acc = acc + v
        elseif k == "subtract" then acc = acc - v
        elseif k == "factor" or k == "mult" or k == "multiply" then
            local q = trunc(acc / FP)
            acc = q * v + trunc((acc - q * FP) * v / FP)
        end
    end
    local PARAMS = { add = true, subtract = true, factor = true, mult = true, multiply = true, weight = true, desc = true, base = true }
    for _, e in ipairs(b) do
        if e.op and e.key then
            local k = e.key.text:lower()
            if k == "base" or k == "weight" then
                acc = fp(ev.value(e.value, ctx, e))
            elseif k == "modifier" and e.value.text == nil then
                if ev.trigger(e.value, ctx, PARAMS) then
                    for _, x in ipairs(e.value) do
                        if x.op and x.key and PARAMS[x.key.text:lower()] and x.key.text ~= "desc" then
                            apply(x.key.text:lower(), fp(ev.value(x.value, ctx, x)))
                        end
                    end
                end
            elseif PARAMS[k] then
                apply(k, fp(ev.value(e.value, ctx, e)))
            end
        end
    end
    return acc
end

-- CFirstContact::FireStageEvent (0x8dc4e0, 0x8dc0c0)
local function fire_stage_event(host, id, fc, r)
    E.rand(); E.rand(); E.rand() -- the event scopes' randoms (line 767 and after)
    local st = stage(world.field(fc, "stage"))
    if not st then
        first_contact.stats.unknown_stages = first_contact.stats.unknown_stages + 1
        return
    end
    local ctx = ctx_of(id, fc, st.file)
    local weights, total = {}, 0
    for i, se in ipairs(st.events) do
        local w = event_weight(se.weight, ctx)
        weights[i] = w
        if w > 0 then total = total + w end
    end
    if total <= 0 then
        first_contact.stats.no_event = first_contact.stats.no_event + 1
        return
    end
    -- GetWeightedRandomInternal<CFixedPoint>: the draw modulo the total (above 2^31 - 1 the game
    -- scales the draw instead: approximated)
    local x = total <= 2147483647 and (r % total) or math.floor(r / 2147483648 * total)
    local pick
    local acc = 0
    for i, w in ipairs(weights) do
        if w > 0 then
            acc = acc + w
            if acc > x then pick = i break end
        end
    end
    local se = pick and st.events[pick]
    if se and se.event then
        local events = require("simscript.events")
        local ev = eval()
        local from = ref(world.field(fc, "country"))
        eval().sync()
        local ok, e = pcall(events.fire, se.event, ev.S("first_contact", id), nil, from and ev.S("country", from) or nil)
        if not ok then err(se.event, e) end
        first_contact.stats.events_fired = first_contact.stats.events_fired + 1
    end
end

-- CFirstContact::HandleRollFailed (0x8db810)
local function roll_failed(host, id, fc, r)
    local st = stage(world.field(fc, "stage"))
    if not st or type(st.on_roll_failed) ~= "table" then
        return
    end
    local ok, e = pcall(eval().effect, st.on_roll_failed, ctx_of(id, fc, st.file))
    if not ok then err(st.key .. " on_roll_failed", e) end
end

-- CFirstContact::DailyUpdateSerial (0x8db580)
local function update(host, id, fc)
    local st = status(fc)
    if st == "locked" then
        first_contact.stats.locked = first_contact.stats.locked + 1
        return
    end
    local l = ref(world.field(fc, "leader"))
    if not (l and world.object("leader", l)) then
        first_contact.stats.no_envoy = first_contact.stats.no_envoy + 1
        return
    end
    if st == "finished" or st == "aborted" then
        return
    end
    first_contact.stats.updates = first_contact.stats.updates + 1
    local d = defines()
    local owner, other = ref(world.field(fc, "owner")), ref(world.field(fc, "country"))
    local intel = owner and other and intel_of(owner, other)
    if intel and intel >= d.INTEL_TARGET then
        first_contact.stats.finished_by_intel = first_contact.stats.finished_by_intel + 1
        finish(host, id, fc)
        return
    end
    first_contact.newly_added[id] = 0
    local days = fp(world.field(fc, "days_left")) - speed(fc)
    if days > 0 then
        world.set(fc, "days_left", days / FP)
        return
    end
    -- the roll
    first_contact.stats.rolls = first_contact.stats.rolls + 1
    local reset = (owner and is_human(owner)) and d.DISCOVERY_DAYS or d.DISCOVERY_DAYS_AI
    world.set(fc, "days_left", reset)
    local x = E.rand() -- line 682
    local range = d.DICE_ROLL_MAX - d.DICE_ROLL_MIN + 1
    world.set(fc, "last_roll", die(x, range) + d.DICE_ROLL_MIN)
    for _ = 1, range do E.rand() end -- CRandom::GetIntegersForMacro (line 688)
    if score(fc) >= d.DISCOVERY_SCORE then
        first_contact.stats.successes = first_contact.stats.successes + 1
        fire_stage_event(host, id, fc, E.rand()) -- line 695
    else
        first_contact.stats.failures = first_contact.stats.failures + 1
        roll_failed(host, id, fc, E.rand()) -- line 699
    end
end

-- CFirstContactsData::DailyUpdate (0x8d8790): the country's contacts, from the last
function first_contact.country_daily(host, date, country)
    local c = world.object("country", country)
    local list = world.path(c, "first_contact", "contacts")
    if type(list) ~= "table" then
        return
    end
    first_contact.stats.days = first_contact.stats.days + 1
    local entries = {}
    for _, e in ipairs(list) do
        if e.text then entries[#entries + 1] = e end
    end
    for i = #entries, 1, -1 do
        local id = tonumber(entries[i].text)
        local fc = id and world.object("first_contact", id)
        local owner = fc and ref(world.field(fc, "owner"))
        local other = fc and ref(world.field(fc, "country"))
        if fc and owner and world.object("country", owner) and other and world.object("country", other) then
            local st = status(fc)
            if st ~= "finished" and st ~= "aborted" then
                update(host, id, fc)
            end
        else
            -- gone: out of the list (the last one moved into its place), the contact destroyed
            local last = entries[#entries]
            world.set_entry(list, entries[i], last.text)
            world.remove_entry(list, last)
            table.remove(entries)
            if fc then
                world.remove("first_contact", id)
            end
            first_contact.stats.removed = first_contact.stats.removed + 1
        end
    end
end

-- ---------------------------------------------------------------------------------------------
-- what the script layer reads and does with first contacts, where simscript has nothing yet
-- (registered only when absent)

local function install()
    local ev = eval()
    local S, L, T, EFF, LISTS = ev.S, ev.LINKS, ev.TRIG, ev.EFF, ev.LISTS
    local function fc_of(sc)
        return sc and sc.kind == "first_contact" and world.object("first_contact", sc.id) or nil
    end
    local function country_scope(id)
        return (id and world.object("country", id)) and S("country", id) or nil
    end
    -- owner / contact_country / leader / solar_system of a first contact
    local base_owner = L.owner
    L.owner = function(cur, ctx)
        local fc = fc_of(cur)
        if fc then return country_scope(ref(world.field(fc, "owner"))) end
        return base_owner(cur, ctx)
    end
    if not L.contact_country then
        L.contact_country = function(cur)
            local fc = fc_of(cur)
            return fc and country_scope(ref(world.field(fc, "country"))) or nil
        end
    end
    local base_leader = L.leader
    L.leader = function(cur, ctx)
        local fc = fc_of(cur)
        if fc then
            local l = ref(world.field(fc, "leader"))
            return (l and world.object("leader", l)) and S("leader", l) or nil
        end
        return base_leader(cur, ctx)
    end
    local base_system = L.solar_system
    L.solar_system = function(cur, ctx)
        local fc = fc_of(cur)
        if fc then
            local s = ref(world.field(fc, "location"))
            return (s and world.object("system", s)) and S("system", s) or nil
        end
        return base_system(cur, ctx)
    end
    -- reverse_first_contact: the contact country's first contact with the owner
    if not L.reverse_first_contact then
        L.reverse_first_contact = function(cur)
            local fc = fc_of(cur)
            if not fc then return nil end
            local owner, other = ref(world.field(fc, "owner")), ref(world.field(fc, "country"))
            for _, e in ipairs(world.list(world.path(world.object("country", other), "first_contact", "contacts"))) do
                local r = world.object("first_contact", tonumber(e))
                if r and ref(world.field(r, "country")) == owner then return S("first_contact", tonumber(e)) end
            end
            return nil
        end
    end
    -- a country's first contacts in progress (any_/every_/random_active_first_contact)
    if not LISTS.active_first_contact then
        LISTS.active_first_contact = function(sc)
            local out = {}
            if sc.kind ~= "country" then return out end
            for _, e in ipairs(world.list(world.path(world.object("country", sc.id), "first_contact", "contacts"))) do
                local id = tonumber(e)
                local fc = id and world.object("first_contact", id)
                local st = fc and status(fc)
                if st == "in_progress" or st == "locked" then out[#out + 1] = S("first_contact", id) end
            end
            return out
        end
    end
    local NAMED = { lower_insight_score = "LOWER_INSIGHT_SCORE", higher_insight_score = "HIGHER_INSIGHT_SCORE",
        lower_insight_reward = "LOWER_INSIGHT_REWARD", higher_insight_reward = "HIGHER_INSIGHT_REWARD" }
    local function int_value(e, ctx)
        local n = e.value.text and NAMED[e.value.text]
        if n then return defines()[n] end
        return trunc(ev.value(e.value, ctx, e))
    end
    if not T.is_site_current_stage_score then
        T.is_site_current_stage_score = function(e, ctx)
            local fc = fc_of(ctx.this)
            return fc ~= nil and ev.compare(score(fc), e.op, int_value(e, ctx))
        end
    end
    if not T.is_site_current_stage_score_no_die then
        T.is_site_current_stage_score_no_die = function(e, ctx)
            local fc = fc_of(ctx.this)
            return fc ~= nil and ev.compare(score(fc, true), e.op, int_value(e, ctx))
        end
    end
    if not T.is_current_stage_clues then
        T.is_current_stage_clues = function(e, ctx)
            local fc = fc_of(ctx.this)
            return fc ~= nil and ev.compare(tonumber(world.field(fc, "clues")) or 0, e.op, int_value(e, ctx))
        end
    end
    if not T.is_current_first_contact_stage then
        T.is_current_first_contact_stage = function(e, ctx)
            local fc = fc_of(ctx.this)
            return fc ~= nil and world.field(fc, "stage") == e.value.text
        end
    end
    if not T.has_active_first_contact_with then
        T.has_active_first_contact_with = function(e, ctx)
            if ctx.this.kind ~= "country" then return false end
            local found, other = ev.resolve(e.value.text or "", ctx, e)
            if not (found and other) then return false end
            for _, s in ipairs(LISTS.active_first_contact(ctx.this)) do
                if ref(world.field(world.object("first_contact", s.id), "country")) == other.id then return true end
            end
            return false
        end
    end
    if not EFF.add_stage_clues then
        EFF.add_stage_clues = function(e, ctx)
            local fc = fc_of(ctx.this)
            if not fc then return end
            local n = int_value(e, ctx)
            local clues = tonumber(world.field(fc, "clues")) or 0
            if n < 0 and n < -clues then n = -clues end
            first_contact.newly_added[ctx.this.id] = (first_contact.newly_added[ctx.this.id] or 0) + n
            world.set(fc, "clues", clues + n)
            first_contact.stats.clues_added = first_contact.stats.clues_added + n
        end
    end
    if not EFF.set_first_contact_stage then
        EFF.set_first_contact_stage = function(e, ctx)
            local fc = fc_of(ctx.this)
            if fc and e.value.text then set_stage(ctx.this.id, fc, e.value.text) end
        end
    end
    if not EFF.set_site_progress_locked then
        EFF.set_site_progress_locked = function(e, ctx)
            local fc = fc_of(ctx.this)
            if not fc then return end
            local st = status(fc)
            if st ~= "finished" and st ~= "aborted" then
                world.set(fc, "status", e.value.text == "yes" and "locked" or "in_progress")
            end
        end
    end
    if not EFF.finish_first_contact then
        EFF.finish_first_contact = function(e, ctx)
            local fc = fc_of(ctx.this)
            if fc and e.value.text ~= "no" then
                finish(require("simscript.host"), ctx.this.id, fc)
            end
        end
    end
end
install()

function first_contact.report()
    local st = first_contact.stats
    local s = string.format("first contact: %d country-days, %d contact updates (%d without an envoy, %d locked), %d rolls (%d succeeded: %d stage events fired, %d without one; %d failed), %d clues added, %d stage changes, %d finished (%d by intel), %d removed, %d unknown stages, %d errors",
        st.days, st.updates, st.no_envoy, st.locked, st.rolls, st.successes, st.events_fired, st.no_event, st.failures,
        st.clues_added, st.stage_changes, st.finished, st.finished_by_intel, st.removed, st.unknown_stages, st.errors)
    for _, m in ipairs(first_contact.errors) do s = s .. "\n  error: " .. m end
    return s
end

return first_contact
