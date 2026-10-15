-- engine/diplomacy.lua : what the game knows about war, peace and diplomacy, read from the world
-- (the save's own fields), for the script layer (simscript/handlers/diplomacy.lua), the AI's
-- opinion and attitudes (engine/ai) and the fleets' access (engine/fleets). One implementation:
-- the triggers, the opinion terms and the pathfinder read the same functions.
--
-- docs/script_diplomacy.md has the semantics of each, from the GOG 4.5.2 build (addresses are GOG
-- RVAs). Everything here only reads; nothing draws.
--
--   relations      relations_of(c) -> by, list; relation(a, b); flag(a, b, name); rflag(rel, name)
--   pacts          has_commercial_pact(a, b) ... (CRelation::Has*(true): the relation's flag, or a
--                  federation whose settings grant it); counts(c) (UpdateDiplomaticCache)
--   rivals         rivals(c), is_rivaling(a, b)
--   wars           wars_of(c) (RecalcWarsCache), at_war(c), at_war_with(a, b), war_participants
--   attitudes      attitude(us, other) -> the AI's attitude name ("null" without an entry)
--   subjects       overlord(c), subjects(c), agreement(a, b)
--   federations    federation(c), members(f), associates(f), federation_type(f), ...
--   community      community(), is_member(c), council(), passed resolutions
--   access         has_access(us, level, other), has_access_system(us, level, system),
--                  has_access_cached(us, system, level), is_friendly(a, b), restricted(us, system),
--                  fleet_level(fleet); install_access_hooks() fills the pathfinder's and the
--                  movement's hooks

local world = require("engine.world")
local slice = require("engine.slice")   -- a phase in pieces (docs/frame_timing.md)
local defs = require("engine.defs")

local D = { stats = { access = 0, denied = 0 } }

local NO_ID = 4294967295
local floor = math.floor

local function country(id)
    return id and world.object("country", id)
end
D.country = country

-- a reference field (a TPdxRef): the id, or nil for none
local function ref(v)
    v = tonumber(v)
    if v == nil or v == NO_ID then return nil end
    return v
end
D.ref = ref

-- a country that is there. The game's CCountry::IsAlive (0x6eb190) also asks for planets, fleets
-- and colony ships when the country NeedsColony; a dead country is removed from the save by the
-- game soon after [I: existing = alive]
local function alive(id)
    return id ~= nil and country(id) ~= nil
end
D.alive = alive

-- the days since the epoch as the game counts them (year * 360 + day of year), of a save date
-- "y.m.d" (nil for an unset date: "0.01.01" counts as day 0 + ...)
local function date_days(s)
    local y, m, d = tostring(s or ""):match("^(%-?%d+)%.(%d+)%.(%d+)$")
    if not y then return nil end
    return tonumber(y) * 360 + (tonumber(m) - 1) * 30 + (tonumber(d) - 1)
end
D.date_days = date_days

-- today, as eval.today(): days since year 0
local function today()
    local E = rawget(_G, "E")
    if E and E.date then
        return floor((E.date() - 43800000) / 24)
    end
    return date_days(world.meta and world.meta.date) or 0
end
D.today = today

-- ---------------------------------------------------------------------------------------------
-- country types and instance properties

local type_cache = {}
-- a key of the country's type (common/country_types), e.g. `relations`, `enforces_borders`;
-- default when the type does not set it
local function type_key(id, key, default)
    local ty = world.field(country(id), "type")
    local k = tostring(ty) .. "/" .. key
    local v = type_cache[k]
    if v == nil then
        local d = ty and defs.get("common/country_types", ty)
        local f = d and defs.field(d.block, key)
        if f == nil then
            v = default
        else
            v = f == "yes"
        end
        type_cache[k] = v
    end
    return v
end
D.type_key = type_key

-- ECountryTypeFlags: Relations (128), EnforcesBorders (default yes), DiplomaticWars
function D.type_relations(id) return type_key(id, "relations", false) end
function D.type_enforces_borders(id) return type_key(id, "enforces_borders", true) end

-- SCountryInstanceProperties (CCountry +0x1b08): the save's `faction = { properties = n }`, else the
-- country type's `faction = { ... }` keys (needs_border_access, hostile, ... with their defaults)
local PROP_BIT = { hostile = 1, hostile_when_attacked = 2, always_neutral = 4, copy_parent_hostility = 8,
    auto_delete = 16, needs_border_access = 32, generate_borders = 64, needs_colony = 128, primitive = 256,
    can_have_revolts = 512, space_creatures = 1024, intel_effects_surveyed = 2048 }
local PROP_DEFAULT = { hostile_when_attacked = true, auto_delete = true, needs_border_access = true,
    generate_borders = true, needs_colony = true, intel_effects_surveyed = true }
local type_faction_cache = {}
local function property(id, name)
    local c = country(id)
    if not c then return false end
    local f = world.field(c, "faction")
    local p = type(f) == "table" and tonumber(world.field(f, "properties"))
    if p then
        return floor(p / PROP_BIT[name]) % 2 == 1
    end
    local ty = world.field(c, "type")
    local k = tostring(ty) .. "/" .. name
    local v = type_faction_cache[k]
    if v == nil then
        local d = ty and defs.get("common/country_types", ty)
        local tf = d and defs.field(d.block, "faction")
        local x = type(tf) == "table" and defs.field(tf, name)
        if x == nil or x == false then
            v = PROP_DEFAULT[name] == true
        else
            v = x == "yes"
        end
        type_faction_cache[k] = v
    end
    return v
end
D.property = property

-- ---------------------------------------------------------------------------------------------
-- relations: `relations_manager = { relation = { owner country <flag> = yes ... } }`
-- (CCountryRelationsManager, CRelation::WriteMembers 0x669d30)

local rel_index = setmetatable({}, { __mode = "k" }) -- relations_manager block -> { n, list, by }
local function relations_of(id)
    local rm = world.field(country(id), "relations_manager")
    if type(rm) ~= "table" then
        return {}, {}
    end
    local key, n = world.key(rm), world.count(rm)
    local idx = rel_index[key]
    if idx == nil or idx.n ~= n then
        idx = { n = n, list = {}, by = {} }
        for _, r in ipairs(world.fields(rm, "relation")) do
            if type(r) == "table" then
                local c = tonumber(world.field(r, "country"))
                if c then
                    idx.list[#idx.list + 1] = r
                    idx.by[c] = r
                end
            end
        end
        rel_index[key] = idx
    end
    return idx.by, idx.list
end
D.relations_of = relations_of

local function relation(a, b)
    if a == nil or b == nil then return nil end
    return (relations_of(a))[b]
end
D.relation = relation

-- ERelationFlags (CRelation +0x120) by bit, as the save writes them (`<name> = yes`); bit 17
-- (AtWar) is the relation's `wars` (written as a list)
D.FLAG_BITS = {
    [0] = "hostile", "neutral", "friendly", "communications", "borders", "defensive_pact", "alliance",
    "subject", "guarantee", "support_independence", "non_aggression_pledge", "commercial_pact",
    "research_agreement", "migration_access", "is_rival", "closed_borders", "contact", "at_war",
    "embassy", "capitals_connected_through_relay_network", "capitals_connected_through_relay_network_before",
    "secret_fealty", "acquainted_with", "is_under_societal_enlightenment",
    "is_under_open_technological_enlightenment", "is_under_stratified_technological_enlightenment",
    "has_pre_ftl_trade", "waystation_pact",
}

local function rel_wars(rel)
    local w = rel and world.field(rel, "wars")
    if type(w) ~= "table" then return {} end
    local out = {}
    for _, v in ipairs(world.list(w)) do
        local id = ref(v)
        if id and world.object("war", id) then out[#out + 1] = id end
    end
    return out
end
D.rel_wars = rel_wars

local function rflag(rel, name)
    if rel == nil then return false end
    if name == "at_war" then return #rel_wars(rel) > 0 end
    return world.field(rel, name) == "yes"
end
D.rflag = rflag

-- CCountry::GetRelationFlag(a, b): a's relation towards b
local function flag(a, b, name)
    return rflag(relation(a, b), name)
end
D.flag = flag

-- ---------------------------------------------------------------------------------------------
-- federations (`federation = { id = { members = { } associates? leader federation_progression =
-- { federation_type ... laws perks ... commercial_pact = yes ... } } }`, CCountry +0x1c38)

local function federation(id)
    local f = ref(world.field(country(id), "federation"))
    return (f and world.object("federation", f)) and f or nil
end
D.federation = federation

local function fed_obj(f) return f and world.object("federation", f) end
D.fed_obj = fed_obj

local function fed_progression(f)
    local p = world.field(fed_obj(f), "federation_progression")
    return type(p) == "table" and p or nil
end
D.fed_progression = fed_progression

local function id_list(block)
    local out = {}
    for _, v in ipairs(world.list(type(block) == "table" and block or nil)) do
        local id = ref(v)
        if id then out[#out + 1] = id end
    end
    return out
end
D.id_list = id_list

function D.members(f)
    local out = {}
    for _, c in ipairs(id_list(world.field(fed_obj(f), "members"))) do
        if alive(c) then out[#out + 1] = c end
    end
    return out
end
-- the associates: the countries whose `associated_federation` is the federation [I: the save's
-- federation block writes no associates list; CCountry +0x1c3c]
function D.associates(f)
    local out = {}
    if not f then return out end
    for _, c in ipairs(world.all("country")) do
        slice.tick("diplomacy.lua:246")
        if ref(world.field(country(c), "associated_federation")) == f then out[#out + 1] = c end
    end
    return out
end
-- CFederation::IsMember
function D.is_member_of(f, c)
    for _, m in ipairs(id_list(world.field(fed_obj(f), "members"))) do
        if m == c then return true end
    end
    return false
end
-- a setting of the federation's progression (CFederationProgression +0x2bc, `<name> = yes`)
function D.fed_setting(f, name)
    local p = fed_progression(f)
    return p ~= nil and world.field(p, name) == "yes"
end

-- both in the same valid federation whose settings grant the pact (CRelation::Has*(true))
local function fed_grants(a, b, setting)
    local fa = federation(a)
    return fa ~= nil and fa == federation(b) and D.fed_setting(fa, setting)
end

-- CRelation::HasCommercialPact(true) 0x66b270 (bit 11 or the federation's commercial_pact),
-- HasResearchAgreement(true) 0x66ba80 (bit 12, research_agreement), HasMigrationPact(true) 0x66bbc0
-- (bit 13 `migration_access`, free_migration), HasWaystationPact(true) 0x66bd00 (bit 27,
-- waystation_pact). The federation part reads the relation's owner and other.
function D.has_commercial_pact(a, b)
    return flag(a, b, "commercial_pact") or fed_grants(a, b, "commercial_pact")
end
function D.has_research_agreement(a, b)
    return flag(a, b, "research_agreement") or fed_grants(a, b, "research_agreement")
end
function D.has_migration_pact(a, b)
    return flag(a, b, "migration_access") or fed_grants(a, b, "free_migration")
end
function D.has_waystation_pact(a, b)
    return flag(a, b, "waystation_pact") or fed_grants(a, b, "waystation_pact")
end

-- CCountry::HasAssociateStatusWith(a, b)
function D.associate(a, b)
    local fa = ref(world.field(country(a), "associated_federation"))
    if fa and fa == federation(b) then return true end
    local f = federation(a)
    return f ~= nil and f == ref(world.field(country(b), "associated_federation"))
end

-- ---------------------------------------------------------------------------------------------
-- subjects and overlords (`overlord = c`, CCountry +0x2630; `subjects = { }`, +0x2670)

function D.overlord(id)
    local o = ref(world.field(country(id), "overlord"))
    return alive(o) and o or nil
end
function D.subjects(id)
    local out = {}
    for _, s in ipairs(id_list(world.field(country(id), "subjects"))) do
        if alive(s) then out[#out + 1] = s end
    end
    return out
end
-- the count of the subjects array as saved (CSubjectsTrigger reads CCountry +0x2684, the count)
function D.num_subjects(id)
    return #id_list(world.field(country(id), "subjects"))
end

-- agreements (`agreements = { agreements = { id = { owner target ... } } }`, the game's
-- CAgreementManager +0x9c0 list): the agreement between a and b, either way
local function agreements()
    local out = {}
    local root = world.stores and world.stores["agreements"]
    if type(root) == "table" then
        for id, a in pairs(root) do
            if type(a) == "table" then out[#out + 1] = { id = id, block = a } end
        end
        table.sort(out, function(x, y) return x.id < y.id end)
    end
    return out
end
D.agreements = agreements
function D.agreement(a, b)
    for _, ag in ipairs(agreements()) do
        local o, t = ref(world.field(ag.block, "owner")), ref(world.field(ag.block, "target"))
        if (o == a and t == b) or (o == b and t == a) then return ag end
    end
    return nil
end

-- ---------------------------------------------------------------------------------------------
-- rivals: the diplomacy module's `rivals = { }` (CDiplomacyCountryModule +0x20), in order

local function diplomacy_module(id)
    local m = world.path(country(id), "modules", "standard_diplomacy_module")
    return type(m) == "table" and m or nil
end
D.diplomacy_module = diplomacy_module

function D.rivals(id)
    local m = diplomacy_module(id)
    local out = {}
    for _, v in ipairs(world.list(m and world.field(m, "rivals") or nil)) do
        local r = tonumber(v)
        if r then out[#out + 1] = r end
    end
    return out
end
-- CCountry::IsRivaling(a, b) 0x72c240: b among a's rivals
function D.is_rivaling(a, b)
    for _, r in ipairs(D.rivals(a)) do
        if r == b then return true end
    end
    return false
end
-- the diplomacy module's `threats = { }` (+0x38)
function D.threats(id)
    local m = diplomacy_module(id)
    local out = {}
    for _, v in ipairs(world.list(m and world.field(m, "threats") or nil)) do
        local r = tonumber(v)
        if r then out[#out + 1] = r end
    end
    return out
end

-- CDiplomacyCountryModule::UpdateDiplomaticCache (0x6a2c90): over the country's relations whose
-- other country exists, both alive and both of a type with `relations = yes` (none when ours is not)
local COUNT_FLAGS = {
    defensive_pacts = "defensive_pact", guarantees = "guarantee", supports = "support_independence",
    naps = "non_aggression_pledge", rivalries = "is_rival", closed_borders = "closed_borders",
    secret_fealties = "secret_fealty",
}
function D.counts(id)
    local n = { defensive_pacts = 0, guarantees = 0, supports = 0, commercial_pacts = 0, research_agreements = 0,
        naps = 0, migration_pacts = 0, waystation_pacts = 0, rivalries = 0, closed_borders = 0, truces = 0,
        secret_fealties = 0 }
    if not alive(id) or not D.type_relations(id) then return n end
    local _, list = relations_of(id)
    for _, r in ipairs(list) do
        local other = tonumber(world.field(r, "country"))
        if alive(other) and D.type_relations(other) then
            for k, f in pairs(COUNT_FLAGS) do
                if rflag(r, f) then n[k] = n[k] + 1 end
            end
            if D.has_commercial_pact(id, other) then n.commercial_pacts = n.commercial_pacts + 1 end
            if D.has_research_agreement(id, other) then n.research_agreements = n.research_agreements + 1 end
            if D.has_migration_pact(id, other) then n.migration_pacts = n.migration_pacts + 1 end
            if D.has_waystation_pact(id, other) then n.waystation_pacts = n.waystation_pacts + 1 end
            if D.truce_of(r) then n.truces = n.truces + 1 end
        end
    end
    return n
end

-- ---------------------------------------------------------------------------------------------
-- truces (`truce = { id = { ... } }`; the relation's `truce = id`, CRelation +0x30)

function D.truce_of(rel)
    local t = rel and ref(world.field(rel, "truce"))
    return (t and world.object("truce", t)) and t or nil
end
-- CCountry::HasTruceWith(a, b) (0x701c20) [I: the relation's truce, either way]
function D.has_truce(a, b)
    return D.truce_of(relation(a, b)) ~= nil or D.truce_of(relation(b, a)) ~= nil
end

-- ---------------------------------------------------------------------------------------------
-- wars (`war = { id = { attackers = { { call_type country caller } } defenders = { } ... } }`,
-- CWar::WriteMembers 0x8ce8e0, SWarParticipant::WriteMembers 0x8f8220)

-- CCountryRelationsManager::RecalcWarsCache (0xab76c0): the wars of the country's relations' `wars`
-- lists, in relation order, each once (CCountry +0x2ba0, what is_at_war and any_war read)
function D.wars_of(id)
    local out, seen = {}, {}
    local _, list = relations_of(id)
    for _, r in ipairs(list) do
        for _, w in ipairs(rel_wars(r)) do
            if not seen[w] then
                seen[w] = true
                out[#out + 1] = w
            end
        end
    end
    return out
end
function D.at_war(id)
    return #D.wars_of(id) > 0
end
-- CIsAtWarWithTrigger (0x194e280): the relation's wars (CRelation +0xe0) not empty
function D.at_war_with(a, b)
    if a == b then return false end
    return #rel_wars(relation(a, b)) > 0
end

local function war_obj(w) return w and world.object("war", w) end
D.war_obj = war_obj

-- a side's participants (SWarParticipant: `country`), in order
function D.war_side(w, side)
    local out = {}
    for _, p in ipairs(world.blocks(world.field(war_obj(w), side))) do
        local c = ref(world.field(p, "country"))
        if c then out[#out + 1] = c end
    end
    return out
end
-- CWarParticipantListBuilder::BuildIDArray (0x18177d0): the attackers, then the defenders
function D.war_participants(w)
    local out = D.war_side(w, "attackers")
    for _, c in ipairs(D.war_side(w, "defenders")) do out[#out + 1] = c end
    return out
end
-- the side of a country in a war: "attackers", "defenders" or nil (CWar::IsPartOfWar)
function D.side_in(w, c)
    for _, side in ipairs({ "attackers", "defenders" }) do
        for _, x in ipairs(D.war_side(w, side)) do
            if x == c then return side end
        end
    end
    return nil
end

-- the dates the country keeps (CCountry +0x1424 _LastWarLost, +0x1428 _LastAtWar)
function D.last_war_lost(id) return date_days(world.field(country(id), "last_date_war_lost")) end
function D.last_at_war(id) return date_days(world.field(country(id), "last_date_at_war")) end

-- ---------------------------------------------------------------------------------------------
-- the AI's attitudes (`ai = { attitude = { { country attitude weight ... } } }`, CCountryAI +0x490)

-- the country has an AI (CCountry +0x1b28 not null): an `ai = { }` block
function D.has_ai(id)
    local ai = world.field(country(id), "ai")
    return type(ai) == "table"
end
-- CCountryAI::GetAttitude (0xb7b2b0): the entry's attitude, or the database's `null` attitude
function D.attitude(us, other)
    local ai = world.field(country(us), "ai")
    local block = type(ai) == "table" and world.field(ai, "attitude")
    if type(block) == "table" then
        for _, e in ipairs(world.blocks(block)) do
            if tonumber(world.field(e, "country")) == other then
                return world.field(e, "attitude") or "null"
            end
        end
    end
    return "null"
end

-- ---------------------------------------------------------------------------------------------
-- the galactic community (`galactic_community = { leader members = { } council = { } passed = { }
-- community_formed council_established empire ... }`, CGalacticCommunity::WriteMembers 0x622c50)

local function community()
    for _, e in ipairs(world.tree or {}) do
        if e.op and e.key and e.key.text == "galactic_community" and e.value.text == nil then
            return e.value
        end
    end
    return nil
end
D.community = community

function D.gc_members()
    return id_list(world.field(community(), "members"))
end
function D.gc_council()
    return id_list(world.field(community(), "council"))
end
function D.gc_leader()
    return ref(world.field(community(), "leader"))
end
-- the Galactic Empire's bit of the community (+0x35c & 4): the save's `empire` [I: no save of ours
-- has one]
function D.gc_empire()
    local e = world.field(community(), "empire")
    if e == nil then return false end
    local n = tonumber(e)
    if n then return floor(n / 4) % 2 == 1 end
    return e == "yes" or type(e) == "table"
end
function D.gc_is_member(c)
    for _, m in ipairs(D.gc_members()) do
        if m == c then return true end
    end
    return false
end
function D.gc_formed()
    return world.field(community(), "community_formed") ~= nil
end
function D.gc_council_established()
    return world.field(community(), "council_established") ~= nil
end
-- the passed resolutions, oldest first: their types (the `resolution` store's `type`) [I: no save
-- of ours has a community]
function D.gc_passed_types()
    local out = {}
    for _, id in ipairs(id_list(world.field(community(), "passed"))) do
        local r = world.object("resolution", id)
        out[#out + 1] = r and world.field(r, "type") or tostring(id)
    end
    return out
end

-- ---------------------------------------------------------------------------------------------
-- borders and access

-- the owner of a system (CGalacticObject +0x1370): its primary starbase's owner (world.system_owner)
local function system_owner(sid)
    return world.system_owner and world.system_owner[sid] or nil
end
D.system_owner = system_owner

-- the systems a country owns (CCountry +0x2ea8), in id order, from world.system_owner (indexed
-- once per owner table)
local owned_index = setmetatable({}, { __mode = "k" })
function D.systems_of(cid)
    local so = world.system_owner
    if type(so) ~= "table" then return {} end
    local idx = owned_index[so]
    if not idx then
        idx = {}
        for _, sid in ipairs(world.all("system")) do
            slice.tick("diplomacy.lua:568")
            local o = so[sid]
            if o then
                idx[o] = idx[o] or {}
                idx[o][#idx[o] + 1] = sid
            end
        end
        owned_index[so] = idx
    end
    return idx[cid] or {}
end

-- the restricted systems of a country (CCountry +0x2748 `restricted_systems`)
function D.restricted(us, sid)
    if us == nil or system_owner(sid) == us then return false end
    for _, s in ipairs(id_list(world.field(country(us), "restricted_systems"))) do
        if s == sid then return true end
    end
    return false
end

-- the countries that fight beside us (CCountry +0x2f90 `war_allies`)
local function war_allies(us)
    return id_list(world.field(country(us), "war_allies"))
end

-- a country flag, as has_country_flag reads it (the script store over the save's flags)
function D.has_country_flag(id, name)
    local ok, eval = pcall(require, "simscript.eval")
    if ok and type(eval) == "table" and eval.store then
        return eval.store.has_flag(eval.S("country", id), name) == true
    end
    local flags = world.field(country(id), "flags")
    return type(flags) == "table" and world.field(flags, name) ~= nil
end

-- the galactic community grants us its members' territory: its leader, or our flag
-- can_access_community_territory (CGalacticCommunity::CanAccessAllMemberTerritory)
local function gc_access(us, other)
    if not D.gc_is_member(other) then return false end
    if D.gc_leader() == us then return true end
    return D.has_country_flag(us, "can_access_community_territory")
end

-- an active agreement between a subject and its overlord whose subject may not do diplomacy on its
-- own [I: CAgreement +0x28 == 0 and +0xed == 0; the save's agreement without `terminated`]
local function subject_agreement(a, b)
    local ag = D.agreement(a, b)
    return ag ~= nil and world.field(ag.block, "terminated") == nil
end

-- CCountry::HasAccess(us, level, other) (0x71bdc0): whether us may enter other's borders.
-- level (EAccessLevel): 3 a fleet, 4 a military station, 5 always (cloaked, or ignores closed
-- borders), 6 no fleet.
local function has_access(us, level, other)
    for _ = 1, 8 do -- other may become its overlord; overlords chain at most a few times
        if not alive(other) or us == other then return true end
        -- a truce and the game rule is_expelled_from (this = us, from = other: the country flag
        -- expelled_from_@<other>)
        if D.has_truce(us, other) and D.has_country_flag(us, "expelled_from_@" .. other) then return false end
        if not property(us, "needs_border_access") then return true end
        if level == 5 then return true end
        if not D.type_enforces_borders(other) then return true end
        local f = federation(us)
        if f and D.is_member_of(f, other) then return true end
        if D.at_war_with(us, other) then return true end
        for _, a in ipairs(war_allies(us)) do
            if a == other then return true end
        end
        if gc_access(us, other) then return true end
        local ov = D.overlord(us)
        if ov and ov ~= other and subject_agreement(us, ov) then
            return has_access(ov, level, other)
        end
        local ovo = D.overlord(other)
        if ovo and ovo ~= us and subject_agreement(other, ovo) then
            other = ovo
        else
            -- closed to us: communications, the other's rivalry or closed borders towards us, no
            -- forced open borders, no truce both ways
            if flag(us, other, "communications") then
                local r2 = relation(other, us)
                if rflag(r2, "closed_borders") or rflag(r2, "is_rival") then
                    local forced = date_days(world.field(relation(us, other), "forced_open_borders"))
                    if not (forced and forced >= today()) then
                        if not (D.truce_of(relation(us, other)) and D.truce_of(r2)) then
                            return false
                        end
                    end
                end
            end
            return level ~= 4
        end
    end
    return true
end
D.has_access = has_access

-- CCountry::HasAccess(us, level, system) (0x71bcf0): NeedsBorderAccess, a storm that opens the
-- borders (not modelled: none in the saves), then the system's owner
function D.has_access_system(us, level, sid)
    if not property(us, "needs_border_access") then return true end
    return has_access(us, level, system_owner(sid))
end
-- CCountry::HasAccessLevelCached(us, system, level) (0x74e3d0): the system status cache's bit
-- level + 8 (HasAccess against the system's owner, UpdateSystemStatusCache 0x74dd10) or bit 4
-- (a storm opening the borders: not modelled); computed when asked [I: the cache's update times]
function D.has_access_cached(us, sid, level)
    D.stats.access = D.stats.access + 1
    local ok = has_access(us, level, system_owner(sid))
    if not ok then D.stats.denied = D.stats.denied + 1 end
    return ok
end

-- CCountry::IsAllied(a, b, true) (0x716c80, engine.ai.attitudes' port)
local function allied(a, b)
    if D.at_war_with(a, b) then return false end
    if D.overlord(a) == b or D.overlord(b) == a then return true end
    local oa, ob = D.overlord(a), D.overlord(b)
    if oa and oa == ob then return true end
    local function allegiance(id)
        return federation(id) or (D.overlord(id) and federation(D.overlord(id))) or nil
    end
    local fa, fb = allegiance(a), allegiance(b)
    if fa and fa == fb then return true end
    if oa and allegiance(oa) and allegiance(oa) == fb then return true end
    if ob and allegiance(ob) and allegiance(ob) == fa then return true end
    return flag(a, b, "friendly")
end
D.allied = allied

-- CCountry::IsFriendlyCached(a, b) (0x74e5d0): a == b, or not hostile and allied. IsHostile
-- (0x702100) is the relation's hostile bit here [I: its parent-country, forced and diplomatic-wars
-- rules are not ported]
function D.is_friendly(a, b)
    if a == nil or b == nil or not alive(b) then return false end
    if a == b then return true end
    if flag(a, b, "hostile") then return false end
    return allied(a, b)
end

-- the fleet's access level (SFleetPathfindAccessData 0xe6af60, CFleet::HasAccess 0xc821b0): 5 when
-- cloaked or when every ship's size ignores closed borders, 4 for a military station, else 3
local size_ignores = {}
local function ship_size_ignores(size)
    local v = size_ignores[size]
    if v == nil then
        local d = size and defs.get("common/ship_sizes", size)
        v = d ~= nil and defs.field(d.block, "ignores_closed_borders") == "yes"
        size_ignores[size] = v
    end
    return v
end
local function ship_size_of(sid)
    local s = world.object("ship", sid)
    local impl = world.field(s, "ship_design_implementation")
    local design = world.object("ship_design", tonumber(world.field(impl, "design")))
    local stage = tonumber(world.field(impl, "growth_stage")) or 0
    local g = world.blocks(world.field(design, "growth_stages"))[stage + 1]
    return g and world.field(g, "ship_size")
end
-- CFleet::IgnoresClosedBorders (0xc6bb90): every ship's size has the flag (an empty fleet too)
function D.fleet_ignores_closed_borders(fid)
    for _, s in ipairs(world.list(world.field(world.object("fleet", fid), "ships"))) do
        if not ship_size_ignores(ship_size_of(tonumber(s))) then return false end
    end
    return true
end
function D.fleet_level(fid)
    local f = world.object("fleet", fid)
    if not f then return 6 end
    -- TFleetFlags bit 13 Cloaked (CFleet +0x1268), saved in `properties` [I: the name]
    if world.path(f, "properties", "cloaked") == "yes" then return 5 end
    if D.fleet_ignores_closed_borders(fid) then return 5 end
    return world.field(f, "ship_class") == "shipclass_military_station" and 4 or 3
end

-- the pathfinder's and the movement's access hooks: SFindFleetPathValidatorFuncBase::EvalShared
-- (0xe73660): a system is closed when its owner is not the fleet's country, not friendly to it,
-- and HasAccessLevelCached says no; CFleet::HasAccess for the movement's own checks
function D.install_access_hooks()
    if os.getenv("STELLAR_ACCESS") == "off" then return false end
    local ok, path = pcall(require, "engine.fleets.path")
    if ok and type(path) == "table" and path.hooks then
        path.hooks.has_access = function(data, sys)
            local us = data.country
            if us == nil then return true end
            local owner = system_owner(sys)
            if owner == nil or owner == us then return true end
            if D.is_friendly(owner, us) then return true end
            local level = data.access_level
            if level == nil then
                level = data.fleet and D.fleet_level(data.fleet) or 6
                data.access_level = level
            end
            return D.has_access_cached(us, sys, level)
        end
        path.hooks.restricted = function(data, sys)
            return data.country ~= nil and D.restricted(data.country, sys)
        end
    end
    local ok2, movement = pcall(require, "engine.fleets.movement")
    if ok2 and type(movement) == "table" and movement.hooks then
        movement.hooks.has_access = function(fid, sys)
            local us = world.fleet_owner and world.fleet_owner[fid]
            if us == nil or not alive(us) then return false end
            return D.has_access_system(us, D.fleet_level(fid), sys)
        end
    end
    return true
end

return D
