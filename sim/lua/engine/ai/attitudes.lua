-- engine/ai/attitudes.lua : the AI's attitudes towards the countries it knows (docs/ai.md section 3,
-- "Opinion and attitudes in Lua"), read from the GOG 4.5.2 build. No random draws.
--
-- CGameState::DailyUpdate, phase 2 (0x25d280-0x25d363): every country with an AI (in the save:
-- an `ai = { }` block; players' too) whose country type has `relations = yes`, on the days where
-- (country id + _CurrentDateInDays) % 10 == 0 (unsigned; the day count is year * 360 + day of
-- year, as eval.today()), in the game's country order -> CCountryAI::UpdateAttitudesThreaded
-- (0xb7ab60): per AI, CPerCountryRelationAttitudesFunctor (0xb7a2f0) over its relations, then the
-- new entries appended in relation order. Per relation to a country T with contact:
--
--   entry = our attitude entry for T; a forced one is kept
--   opinion = our opinion of T (engine.ai.opinion)
--   bar = entry and CalcAIWeight(entry's attitude) + ATTITUDE_CHANGE_BUFFER or -1.0
--   for each attitude of common/attitudes in database order other than the best so far:
--       weight = friendly, protective, wary, receptive and no diplomatic interest in T ? 0
--                : CalcAIWeight(attitude)
--       weight > bar -> best = it, bar = weight
--   an entry whose best is another attitude: attitude and weight changed (priority and date kept)
--   no entry: { country attitude weight priority = 0 date = 0.01.01 } appended
--
-- CAIAttitude::CalcAIWeight (0xb3a060) is code per attitude type (attitude `type`), below; the
-- weights are CFixedPoint (the save's `weight`). The priority (EAIPriority) and its date are the
-- military minister's (CCountryAI::RandomizePriority, synced AI random): not ported, kept.
--
-- The game runs this before the day's flags, construction and modifier update: the simulation's
-- first daily phase (engine.systems "daily.ai_attitudes").

local world = require("engine.world")
local defs = require("engine.defs")
local op = require("engine.ai.opinion")

local attitudes = {
    stats = { days = 0, updates = 0, relations = 0, changed = 0, appended = 0, errors = 0, seconds = 0 },
    changes = {}, -- { date, country, other, from, to, weight }
}

local FP = 100000
local NO_ID = 4294967295
local NULL_DATE = "0.01.01"

-- ---------------------------------------------------------------------------------------------
-- definitions

local D
local function defines()
    if D == nil then
        local function v(group, key, default)
            local g = defs.get("common/defines", group)
            return g and tonumber(defs.field(g.block, key)) or default
        end
        D = {
            ATTITUDE_CHANGE_BUFFER = v("NAI", "ATTITUDE_CHANGE_BUFFER", 0),
            HIGH_THREAT_THRESHOLD = op.fp(v("NAI", "HIGH_THREAT_THRESHOLD", 50)),
            CRISIS_EMPIRE_PROTECTIVE_MULT = op.fp(v("NAI", "CRISIS_EMPIRE_PROTECTIVE_MULT", 1)),
            START_YEAR = v("NGameplay", "START_YEAR", 2200),
            AI_BUDGETING_START_YEARS = v("NAI", "AI_BUDGETING_START_YEARS", 15),
            DECLINED_TO_LEAVE_FEDERATION_CASUS_BELLI_TYPE = (function()
                local g = defs.get("common/defines", "NGameplay")
                return g and defs.field(g.block, "DECLINED_TO_LEAVE_FEDERATION_CASUS_BELLI_TYPE") or "cb_secession"
            end)(),
        }
    end
    return D
end

-- common/attitudes in database order: { name, type }
local DB
local function database()
    if DB == nil then
        DB = {}
        local all = {}
        for name, d in pairs(defs.folder("common/attitudes")) do
            all[#all + 1] = { name = name, def = d }
        end
        table.sort(all, function(a, b)
            if a.def.file ~= b.def.file then return a.def.file < b.def.file end
            return (a.def.line or 0) < (b.def.line or 0)
        end)
        DB.by_name = {}
        for _, a in ipairs(all) do
            local e = { name = a.name, type = defs.field(a.def.block, "type") or a.name }
            DB[#DB + 1] = e
            DB.by_name[a.name] = e
        end
    end
    return DB
end
attitudes.database = database

-- the attitude of a type (CAIAttitudesDatabase's cached pointers: _pFriendly, ...)
local function of_type(t)
    for _, a in ipairs(database()) do
        if a.type == t then
            return a
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------------------------
-- the AI's entries (`ai = { attitude = { { country attitude weight priority date [forced] } } }`)

local function country(id)
    return world.object("country", id)
end

local function ai_block(id)
    local ai = world.field(country(id), "ai")
    return type(ai) == "table" and ai or nil
end

local function entries(id)
    local ai = ai_block(id)
    local block = ai and world.field(ai, "attitude")
    return type(block) == "table" and world.blocks(block) or {}, block
end
attitudes.entries = entries

local function entry_for(id, other)
    for _, e in ipairs(entries(id)) do
        if tonumber(world.field(e, "country")) == other then
            return e
        end
    end
    return nil
end
attitudes.entry_for = entry_for

-- CCountryAI::GetAttitude: the entry's attitude, or the database's null attitude
local function current(id, other)
    local e = entry_for(id, other)
    local name = e and world.field(e, "attitude")
    return name and database().by_name[name] or of_type("null")
end

local function priority(e)
    return e and tonumber(world.field(e, "priority")) or 0
end

-- ---------------------------------------------------------------------------------------------
-- engine reads

local function fe(id) return op.type_flag(id, "fallen_empire") end
local function afe(id) return op.type_flag(id, "awakened_fallen_empire") end

local function overlord_relation(us, other)
    return op.overlord(us) == other or op.overlord(other) == us
end

-- CCountryBorderManager::IsBorderingCountry(us, other, waystations): the relation's IsBordering
-- (`borders = yes`); the nomads' waystation bordering (CalcIsBorderingCountryWaystations) not read
local function bordering(us, other)
    return op.rflag(op.relation(us, other), "borders")
end

-- NAttitude::ShouldFightCrisis (0xb39d70): false without an active crisis (CGameState +0x9f0),
-- which the simulation has not modelled yet
local function should_fight_crisis(_)
    return false
end

-- the country is fighting the crisis (ECountrySettings IsCrisisFightingCached, not saved)
local function crisis_fighting(_)
    return false
end

-- CCountry +0x30e8 _pCrisisProgression: the country is a crisis (Nemesis)
local function is_crisis_country(id)
    local c = country(id)
    return c ~= nil and (world.field(c, "crisis_path") ~= nil or world.field(c, "crisis_type") ~= nil)
end

-- CRelation::HasMigrationPact(rel, true): `migration_access` (the federation's free migration
-- adds nothing where the alliance flag is tested beside it)
local function migration(rel)
    return op.rflag(rel, "migration_access")
end

-- CCountry::IsAllied(a, b, true) (0x716c80): not at war; one the other's overlord or both one
-- overlord's subjects; the same federation (CalcFederationAllegiance: their own, or their
-- overlord's); at war together (no wars modelled); or the relation cache's bit 2 (`friendly`)
local function allegiance(id)
    local f = op.federation(id)
    if f then return f end
    local ov = op.overlord(id)
    return ov and op.federation(ov) or nil
end
local function allied(a, b)
    if op.at_war(a, b) then return false end
    if op.overlord(a) == b or op.overlord(b) == a then return true end
    local oa, ob = op.overlord(a), op.overlord(b)
    if oa and oa == ob then return true end
    local fa, fb = allegiance(a), allegiance(b)
    if fa and fa == fb then return true end
    if oa and allegiance(oa) and allegiance(oa) == fb then return true end
    if ob and allegiance(ob) and allegiance(ob) == fa then return true end
    return op.rflag(op.relation(a, b), "friendly")
end
attitudes.allied = allied

-- CDiplomacyCountryModule::HasCasusBelli(us, type, other): `casus_belli = { { type owner country } }`
local function has_casus_belli(us, cb, other)
    local m = world.path(country(us), "modules", "standard_diplomacy_module")
    local list = type(m) == "table" and world.field(m, "casus_belli")
    for _, e in ipairs(world.blocks(type(list) == "table" and list or nil)) do
        if world.field(e, "type") == cb and tonumber(world.field(e, "country")) == other then
            return true
        end
    end
    return false
end

-- CCountryAI::HasPotentialBorderExpansion (0xb70890): the type's ai.colonizer, and border
-- expansion targets (strategy list 19) or fewer than AI_BUDGETING_START_YEARS since START_YEAR
local function potential_border_expansion(us, year)
    local ai = require("engine.ai")
    if not ai.setting(us, "colonizer") then
        return false
    end
    for _, s in ipairs(world.fields(ai_block(us), "strategy")) do
        if type(s) == "table" and tonumber(world.field(s, "type")) == 19 then
            return true
        end
    end
    local d = defines()
    return year - d.START_YEAR < d.AI_BUDGETING_START_YEARS
end

-- CCountry::HasOpinionModifier(us, other, key): a timed modifier of that key on our relation
local function has_opinion_modifier(us, other, key)
    for _, m in ipairs(world.fields(op.relation(us, other), "modifier")) do
        if type(m) == "table" and world.field(m, "modifier") == key then
            return true
        end
    end
    return false
end

-- CCountry::HasDiplomaticInterest(us, other) (0x72c700)
local function diplomatic_interest(us, other)
    if crisis_fighting(us) then return true end
    if op.is_rivaling(us, other) or op.is_rivaled(us, other) then return true end
    local range = tonumber(world.field(op.relation(us, other), "border_range")) or 1000
    if range < op.defines().RELEVANT_DISTANCE then return true end
    if op.num_shared_rivals(us, other) ~= 0 then return true end
    if op.num_allied_rivals(us, other) > 0 or op.num_allied_rivals(other, us) > 0 then return true end
    if allied(other, us) then return true end
    -- a country (among their relations) that rivals both of us
    for _, r in ipairs(select(2, op.relations_of(other))) do
        local c = tonumber(world.field(r, "country"))
        if c ~= other and op.is_rivaling(c, other) and op.is_rivaling(c, us) then
            return true
        end
    end
    return false
end
attitudes.diplomatic_interest = diplomatic_interest

-- ---------------------------------------------------------------------------------------------
-- CAIAttitude::CalcAIWeight, per type: weight(x) -> CFixedPoint. x = { us, other, rel, opinion,
-- entry, cur (our current attitude of them), year }

local function W(n) return n * FP end
local function prio(x) return priority(x.entry) end
local function cur_is(x, t) return x.cur ~= nil and x.cur.type == t end
local function rivalry(x) return op.rflag(x.rel, "is_rival") end

local function pacts(x)
    return op.associate(x.us, x.other) or op.rflag(x.rel, "defensive_pact") or op.rflag(x.rel, "alliance")
        or op.rflag(x.rel, "non_aggression_pledge") or migration(x.rel)
end

-- NAttitude::CalcHostileAIWeight (0xb39b50)
local function hostile(x)
    local us, other = x.us, x.other
    if fe(us) then return 0 end
    local cb = has_casus_belli(us, defines().DECLINED_TO_LEAVE_FEDERATION_CASUS_BELLI_TYPE, other)
    if allied(us, other) and not cb then return 0 end
    if not bordering(us, other) then return 0 end
    local subj = op.behaviour(us, "subjugator") and fe(other)
    if not (op.behaviour(us, "conqueror") or op.behaviour(us, "liberator") or subj) then return 0 end
    if op.behaviour(us, "propagator") and potential_border_expansion(us, x.year) then return 0 end
    local thr = cur_is(x, "hostile") and -80 or -100
    if rivalry(x) then
        thr = cur_is(x, "hostile") and -40 or -50
    end
    return x.opinion <= thr and W(3000) or 0
end

-- NAttitude::CalcProtectiveAIWeight (0xb39820)
local function protective(x)
    local us, other = x.us, x.other
    if fe(us) or overlord_relation(us, other) or rivalry(x) or crisis_fighting(us) or is_crisis_country(us) then
        return 0
    end
    if not op.game_rule("can_subjugate_empires", us) then return 0 end
    local is_cur = cur_is(x, "protective")
    if op.relative_power(us, other) < (is_cur and 250000 or 300000) then return 0 end
    local p = prio(x)
    if not (op.associate(us, other) or op.rflag(x.rel, "defensive_pact") or op.rflag(x.rel, "alliance")
        or op.rflag(x.rel, "guarantee") or op.rflag(x.rel, "non_aggression_pledge") or migration(x.rel)) and p ~= 3 then
        return 0
    end
    if x.opinion < (is_cur and -10 or 0) then return 0 end
    -- bordering a crisis country: x CRISIS_EMPIRE_PROTECTIVE_MULT
    for _, r in ipairs(select(2, op.relations_of(other))) do
        local c = tonumber(world.field(r, "country"))
        if c and is_crisis_country(c) and op.rflag(r, "borders") then
            return op.trunc(W(3000) * defines().CRISIS_EMPIRE_PROTECTIVE_MULT)
        end
    end
    return W(3000)
end

local loyalty = function(id) return tonumber(world.field(country(id), "loyalty")) or 0 end

local CALC = {
    neutral = function() return W(100) end,
    null = function() return -FP end,
    overlord = function(x)
        return (op.overlord(x.other) == x.us and not op.at_war(x.other, x.us)) and W(10000) or 0
    end,
    friendly = function(x)
        if fe(x.us) or overlord_relation(x.us, x.other) or rivalry(x) then return 0 end
        local thr = prio(x) == 2 and 200 or (cur_is(x, "friendly") and 80 or 100)
        return x.opinion >= thr and W(2000) or 0
    end,
    hostile = hostile,
    loyal = function(x)
        return (op.overlord(x.us) == x.other and loyalty(x.us) >= 0) and W(20000) or 0
    end,
    disloyal = function(x)
        return (op.overlord(x.us) == x.other and loyalty(x.us) < 0) and W(20000) or 0
    end,
    threatened = function(x)
        if fe(x.us) or overlord_relation(x.us, x.other) or rivalry(x) then return 0 end
        if not bordering(x.us, x.other) then return 0 end
        if op.fp(world.field(x.rel, "threat") or 0) < defines().HIGH_THREAT_THRESHOLD then return 0 end
        return x.opinion <= (cur_is(x, "threatened") and -80 or -100) and W(2000) or 0
    end,
    protective = protective,
    wary = function(x)
        local blocked = pacts(x) or crisis_fighting(x.us) or prio(x) == 3
        return blocked and 0 or W(200)
    end,
    receptive = function(x)
        if prio(x) == 2 then return 0 end
        local open = pacts(x) or crisis_fighting(x.us) or prio(x) == 3
        return open and W(200) or 0
    end,
    rival = function(x) return rivalry(x) and W(500) or 0 end,
    dismissive = function(x)
        if fe(x.us) and not afe(x.us) and not overlord_relation(x.us, x.other) then return W(500) end
        return 0
    end,
    patronizing = function(x)
        if fe(x.us) and not afe(x.us) and not overlord_relation(x.us, x.other) and x.opinion >= 50 then
            return W(1000)
        end
        return 0
    end,
    angry = function(x)
        if not fe(x.us) or afe(x.us) or overlord_relation(x.us, x.other) then return 0 end
        if op.behaviour(x.us, "enigmatic") then
            return has_opinion_modifier(x.us, x.other, "opinion_angered_fallen_machine_empire") and W(10000) or 0
        end
        if x.opinion > -100 then return 0 end
        if x.opinion <= -150 then return W(1000) end
        -- between -150 and -100: only towards a player (CCountry +0x314c), without the cheat
        return require("engine.ai").human(x.other) and W(1000) or 0
    end,
    domineering = function(x)
        local us, other = x.us, x.other
        if fe(us) or allied(us, other) or fe(other) then return 0 end
        if op.game_rule("has_borders", us) and op.game_rule("has_borders", other) and not bordering(us, other) then
            return 0
        end
        if not op.behaviour(us, "subjugator") then return 0 end
        if not op.game_rule("can_subjugate_empires", us) then return 0 end
        local is_cur = cur_is(x, "domineering")
        if op.relative_power(us, other) < (is_cur and 250000 or 300000) then return 0 end
        return x.opinion <= (is_cur and -80 or -100) and W(4000) or 0
    end,
    cordial = function(x)
        if fe(x.us) or overlord_relation(x.us, x.other) or rivalry(x) then return 0 end
        local thr = prio(x) == 2 and 100 or (cur_is(x, "cordial") and 40 or 50)
        return x.opinion >= thr and W(1000) or 0
    end,
    unfriendly = function(x)
        if fe(x.us) or overlord_relation(x.us, x.other) or rivalry(x) then return 0 end
        local p = prio(x)
        local thr
        if p == 3 then
            thr = -100
        elseif p == 2 then
            thr = 50
        else
            thr = cur_is(x, "unfriendly") and -40 or -50
        end
        return x.opinion <= thr and W(1000) or 0
    end,
    arrogant = function(x)
        if not afe(x.us) or overlord_relation(x.us, x.other) or should_fight_crisis(x.us) then return 0 end
        return W(500)
    end,
    imperious = function(x)
        if not afe(x.us) or not bordering(x.us, x.other) or overlord_relation(x.us, x.other)
            or should_fight_crisis(x.us) then
            return 0
        end
        return W(1000)
    end,
    belligerent = function(x)
        if not afe(x.us) or overlord_relation(x.us, x.other) then return 0 end
        return x.opinion <= -100 and W(2000) or 0
    end,
    custodial = function(x)
        if op.behaviour(x.us, "custodian") then return W(10000) end
        if afe(x.us) and should_fight_crisis(x.us) and not overlord_relation(x.us, x.other) and x.opinion > -100 then
            return W(1000)
        end
        return 0
    end,
    enigmatic = function(x) return op.behaviour(x.us, "enigmatic") and W(5000) or 0 end,
    berserker = function(x) return op.behaviour(x.us, "berserker") and W(10000) or 0 end,
}
attitudes.CALC = CALC

-- the types whose weight is 0 without diplomatic interest (the functor's token switch, 0xb7a52c)
local NEEDS_INTEREST = { friendly = true, protective = true, wary = true, receptive = true }

function attitudes.weight(a, x)
    local f = a and CALC[a.type]
    return f and f(x) or 0
end

-- ---------------------------------------------------------------------------------------------
-- CPerCountryRelationAttitudesFunctor: one AI's relations -> the changes and the new entries

local function update_country(us, today, year, out)
    local d = defines()
    local db = database()
    local by, list = op.relations_of(us)
    local appended = {}
    for _, rel in ipairs(list or {}) do
        local other = tonumber(world.field(rel, "country"))
        if other and other ~= NO_ID and country(other) and op.rflag(rel, "contact") then
            local e = entry_for(us, other)
            if not (e and world.field(e, "forced") == "yes") then
                attitudes.stats.relations = attitudes.stats.relations + 1
                local x = {
                    us = us, other = other, rel = rel, entry = e, year = year,
                    opinion = op.of(us, other),
                }
                x.cur = current(us, other)
                local bar, best
                local cur_attitude = e and db.by_name[world.field(e, "attitude")] or nil
                if e then
                    bar = attitudes.weight(cur_attitude, x) + d.ATTITUDE_CHANGE_BUFFER * FP
                    best = cur_attitude
                else
                    bar = -FP
                    best = nil -- TPdxNullObject<CAIAttitude>, not one of the database's
                end
                local interest = diplomatic_interest(us, other)
                for _, a in ipairs(db) do
                    if a ~= best then
                        local w
                        if NEEDS_INTEREST[a.type] and not interest then
                            w = 0
                        else
                            w = attitudes.weight(a, x)
                        end
                        if w > bar then
                            bar, best = w, a
                        end
                    end
                end
                if e then
                    if best ~= cur_attitude and best ~= nil then
                        out.changes[#out.changes + 1] = { entry = e, country = us, other = other, attitude = best.name, weight = bar,
                            from = cur_attitude and cur_attitude.name }
                    end
                elseif best ~= nil then
                    appended[#appended + 1] = { other = other, attitude = best.name, weight = bar }
                end
            end
        end
    end
    out.appended[#out.appended + 1] = { country = us, entries = appended }
end
attitudes.update_country = update_country

-- the save's form of a weight (CFixedPoint)
local function weight_text(w)
    return world.number_text(w / FP)
end

local function apply(out, today)
    for _, c in ipairs(out.changes) do
        world.set(c.entry, "attitude", c.attitude)
        -- the attitude is a quoted string in the save
        for _, f in ipairs(c.entry) do
            if f.op and f.key and f.key.text == "attitude" then f.value.quoted = true end
        end
        world.set(c.entry, "weight", weight_text(c.weight))
        attitudes.stats.changed = attitudes.stats.changed + 1
        attitudes.changes[#attitudes.changes + 1] = { date = today, country = c.country, other = c.other, from = c.from, to = c.attitude }
    end
    for _, a in ipairs(out.appended) do
        if #a.entries > 0 then
            local ai = ai_block(a.country)
            local block = world.field(ai, "attitude")
            if type(block) ~= "table" then
                -- a new `attitude = { }` where the game writes it: before random_seed
                block = {}
                local pos
                for i, f in ipairs(ai) do
                    if f.op and f.key and f.key.text == "random_seed" then pos = i break end
                end
                if pos then
                    world.insert(ai, pos, "attitude", block)
                else
                    world.append(ai, "attitude", block)
                end
            end
            for _, n in ipairs(a.entries) do
                local e = {}
                world.append(e, "country", n.other)
                world.append(e, "attitude", n.attitude, true)
                world.append(e, "weight", weight_text(n.weight))
                world.append(e, "priority", 0)
                world.append(e, "date", NULL_DATE, true)
                world.push(block, e)
                attitudes.stats.appended = attitudes.stats.appended + 1
                attitudes.changes[#attitudes.changes + 1] = { date = today, country = a.country, other = n.other, to = n.attitude, new = true }
            end
        end
    end
end

-- the countries whose attitudes the game updates today
local function due(day)
    local out = {}
    for _, id in ipairs(world.all("country")) do
        if ai_block(id) and op.type_flag(id, "relations") then
            if (id + day) % 4294967296 % 10 == 0 then
                out[#out + 1] = id
            end
        end
    end
    return out
end
attitudes.due = due

-- attitudes.part_text(ids, today, year) -> the update of the countries ids (on a worker: engine.store
-- .worker's `attitudes` job), as text: per country "U <id> <relations> <error or ->", then its
-- changed entries "C <other> <attitude> <weight> <from>" and new ones "A <other> <attitude> <weight>"
function attitudes.part_text(ids, today, year)
    local lines = {}
    for _, us in ipairs(ids) do
        local out = { changes = {}, appended = {} }
        local r0 = attitudes.stats.relations
        local ok, err = pcall(update_country, us, today, year, out)
        lines[#lines + 1] = string.format("U %d %d %s", us, attitudes.stats.relations - r0,
            ok and "-" or tostring(err):gsub("\n", " "))
        for _, c in ipairs(out.changes) do
            lines[#lines + 1] = string.format("C %d %s %.17g %s", c.other, c.attitude, c.weight, c.from or "-")
        end
        for _, a in ipairs(out.appended) do
            for _, n in ipairs(a.entries) do
                lines[#lines + 1] = string.format("A %d %s %.17g", n.other, n.attitude, n.weight)
            end
        end
    end
    return table.concat(lines, "\n")
end

-- the workers' texts read back into out, in the order of list (the game's: the changes are applied
-- after the parallel part, in country order)
local function merge(texts, list, out)
    local by, cur = {}, nil
    for _, text in ipairs(texts) do
        for line in tostring(text):gmatch("[^\n]+") do
            local tag = line:sub(1, 1)
            if tag == "U" then
                local id, n, err = line:match("^U (%d+) (%d+) (.*)$")
                cur = { changes = {}, entries = {} }
                by[tonumber(id)] = cur
                attitudes.stats.relations = attitudes.stats.relations + tonumber(n)
                if err ~= "-" then
                    attitudes.stats.errors = attitudes.stats.errors + 1
                    attitudes.last_error = err
                end
            elseif tag == "C" then
                local other, a, w, from = line:match("^C (%d+) (%S+) (%S+) (%S+)$")
                cur.changes[#cur.changes + 1] = { other = tonumber(other), attitude = a, weight = tonumber(w),
                    from = from ~= "-" and from or nil }
            elseif tag == "A" then
                local other, a, w = line:match("^A (%d+) (%S+) (%S+)$")
                cur.entries[#cur.entries + 1] = { other = tonumber(other), attitude = a, weight = tonumber(w) }
            end
        end
    end
    for _, us in ipairs(list) do
        local r = by[us]
        if r then
            for _, c in ipairs(r.changes) do
                c.country, c.entry = us, entry_for(us, c.other)
                out.changes[#out.changes + 1] = c
            end
            out.appended[#out.appended + 1] = { country = us, entries = r.entries }
        end
    end
end

-- attitudes.daily(host, date): the day's attitude update (CCountryAI::UpdateAttitudesThreaded)
function attitudes.daily(host, date)
    if not (date and date.year) then
        return
    end
    local day = date.year * 360 + (date.month - 1) * 30 + (date.day - 1)
    local today = string.format("%d.%02d.%02d", date.year, date.month, date.day)
    attitudes.stats.days = attitudes.stats.days + 1
    local t0 = RUST and RUST.clock and RUST.clock()
    -- the parallel part reads only (each AI its own entries); the changes are written after
    local out = { changes = {}, appended = {} }
    local list = due(day)
    local parallel = require("engine.store.parallel")
    if #list > 0 and parallel.enabled("attitudes") then
        -- on the workers (STELLAR_PARALLEL=attitudes): each takes every Nth country of the list
        attitudes.stats.updates = attitudes.stats.updates + #list
        local ids = {}
        for i, us in ipairs(list) do ids[i] = tostring(us) end
        merge(parallel.run("attitudes", today .. " " .. date.year .. " " .. table.concat(ids, ",")), list, out)
    else
        for _, us in ipairs(list) do
            attitudes.stats.updates = attitudes.stats.updates + 1
            local ok, err = pcall(update_country, us, today, date.year, out)
            if not ok then
                attitudes.stats.errors = attitudes.stats.errors + 1
                attitudes.last_error = tostring(err)
            end
        end
    end
    apply(out, today)
    if t0 then
        attitudes.stats.seconds = attitudes.stats.seconds + (RUST.clock() - t0)
    end
end

-- attitudes.evaluate(us, other) -> the attitude the update would choose now and its weight, the
-- opinion, and every weight (for checks)
function attitudes.evaluate(us, other)
    local rel = op.relation(us, other)
    local e = entry_for(us, other)
    local year = tonumber(tostring(world.meta.date or ""):match("^(%d+)")) or 0
    local x = { us = us, other = other, rel = rel, entry = e, year = year, opinion = op.of(us, other) }
    x.cur = current(us, other)
    local all = {}
    local interest = diplomatic_interest(us, other)
    for _, a in ipairs(database()) do
        local w = (NEEDS_INTEREST[a.type] and not interest) and 0 or attitudes.weight(a, x)
        all[#all + 1] = { a.name, w / FP }
    end
    return x.opinion, interest, all
end

function attitudes.report()
    local s = attitudes.stats
    return string.format("attitudes: %d days, %d AI updates, %d relations, %d changed, %d appended, %d errors, %.1f s%s",
        s.days, s.updates, s.relations, s.changed, s.appended, s.errors, s.seconds,
        attitudes.last_error and (" (" .. attitudes.last_error .. ")") or "")
end

return attitudes
