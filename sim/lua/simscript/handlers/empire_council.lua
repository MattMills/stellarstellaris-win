-- simscript/handlers/empire_council.lua : the galactic council's effects (membership, permanent
-- seats, size, veto, emergency measures, the emperor's authority) and the federation's free
-- migration. Loaded by handlers/empire.lua with its helpers (H). The community is the top-level
-- `galactic_community` block (CGalacticCommunity, g_CurrentGameState +0x748; WriteMembers
-- 0x25cf220) [V]; the shared notes' empire_re/coverage_effects_council.md has the layout.

return function(eval, H)
    local S, NONE, world, E = H.S, H.NONE, H.world, H.E
    local I = H.I
    local EFF = eval.EFF
    local unq, obj, field = H.unq, H.obj, H.field
    local stats = I.stats
    local floor = math.floor
    local SR = require("engine.script.scope_random")

    local function wrote() stats.script = stats.script + 1 end
    local function yes(e) return e.value.text == "yes" end
    local function define(group, key, default) return H.define and H.define(group, key, default) or default end
    local function today_text()
        local d = H.now_days()
        local y = floor(d / 360)
        local r = d - y * 360
        return string.format("%d.%02d.%02d", y, floor(r / 30) + 1, r % 30 + 1)
    end

    -- the block's key order (WriteMembers) [V]: a new key goes before the first later one present
    local ORDER = { "leader", "members", "council", "permanent_council", "proposed", "passed", "failed", "emissaries",
        "focus", "voting", "last", "vote_length", "days", "cooldown", "election", "custodian_term", "community_formed",
        "council_established", "category_timers", "type_timers", "veto_timers", "emergency_measure_timers",
        "council_positions", "council_veto", "council_emergency_measures", "empire", "imperial_authority",
        "emperor_can_change_council_members", "could_end_senate_session", "ship_design_collection",
        "galactic_defense_force", "emergency_fund" }
    local RANK = {}
    for i, k in ipairs(ORDER) do RANK[k] = i end
    local function gc()
        local b = world.meta.galactic_community
        if type(b) ~= "table" then
            b = {}
            world.meta.galactic_community = b
        end
        return b
    end
    local function put(b, key, value)
        local en, i = world.entry(b, key)
        if value == nil then
            if en then world.remove_entry(b, en) end
            return
        end
        if en then
            world.remove_entry(b, en)
            world.insert(b, i, key, value)
            return
        end
        local r = RANK[key] or 1e9
        for j, x in ipairs(b) do
            if x.op and x.key and (RANK[x.key.text] or 1e9) > r then
                world.insert(b, j, key, value)
                return
            end
        end
        world.insert(b, #b + 1, key, value)
    end
    local function get(key) return field(gc(), key) end
    local function num(key, default) return tonumber(get(key)) or default end
    -- the id lists (`members = { 0 12 }`, written when not empty), in order
    local function list(key)
        local out = {}
        for _, v in ipairs(world.list(get(key))) do out[#out + 1] = tonumber(v) end
        return out
    end
    local function write_list(key, ids)
        if #ids == 0 then put(gc(), key, nil) return end
        local b = {}
        for _, id in ipairs(ids) do b[#b + 1] = { text = tostring(id) } end
        put(gc(), key, b)
    end
    local function has(ids, id)
        for _, x in ipairs(ids) do if x == id then return true end end
        return false
    end
    local function remove_first(ids, id)
        for i, x in ipairs(ids) do
            if x == id then table.remove(ids, i) return true end
        end
        return false
    end
    -- the flags word (+0x33c) [V]: veto (default no), emergency measures (default yes), empire,
    -- the emperor's say over the members
    local function flag(key, default)
        local v = get(key)
        if v == nil then return default end
        return v == "yes"
    end
    -- an on_action of the community: one global draw seeds its scope, this = the country [V]
    local function fire(name, cid, seed)
        local ok = pcall(require("simscript.events").on_action, name, S("country", cid), nil, SR.new(seed))
        return ok
    end
    local function dlc()
        if not E.has_dlc then return true end
        return E.has_dlc("Federations") or E.has_dlc("Nemesis")
    end
    local function rule(name, cid)
        return H.rule(name, S("country", cid), NONE)
    end

    -- CGalacticCommunity::AddMember (0x25d9400) [V]: the rule (can_be_part_of_galactic_empire with
    -- an empire, else ..._community); a member already: nothing; one global draw; the first member
    -- of a community never formed: community_formed today, on_galactic_community_formed; appended;
    -- on_add_community_member. [I: EstablishCommunications with each member, the notifications
    -- and the defense force owner's designs not modelled]
    local function add_member(cid)
        if not rule(flag("empire", false) and "can_be_part_of_galactic_empire" or "can_be_part_of_galactic_community", cid) then
            return false
        end
        local members = list("members")
        if has(members, cid) then return true end
        local s = eval.rand()
        if #members == 0 and get("community_formed") == nil then
            put(gc(), "community_formed", '"' .. today_text() .. '"')
            fire("on_galactic_community_formed", cid, s)
        end
        members = list("members")
        members[#members + 1] = cid
        write_list("members", members)
        fire("on_add_community_member", cid, s)
        return true
    end
    -- CGalacticCommunity::AddToCouncil (0x25d5340) [V]: Federations or Nemesis, the rule
    -- can_be_part_of_galactic_council, AddMember; on the council already: nothing; one global draw;
    -- the first councillor of a council never established: council_established today and
    -- on_galactic_council_established (before the seat); appended (no size check);
    -- on_add_to_council
    local function add_to_council(cid)
        if not dlc() or not rule("can_be_part_of_galactic_council", cid) then return false end
        if not add_member(cid) then return false end
        local council = list("council")
        if has(council, cid) then return true end
        local s = eval.rand()
        if #council == 0 and get("council_established") == nil then
            put(gc(), "council_established", '"' .. today_text() .. '"')
            fire("on_galactic_council_established", cid, s)
        end
        council = list("council")
        council[#council + 1] = cid
        write_list("council", council)
        fire("on_add_to_council", cid, s)
        return true
    end
    local function country_of(ctx)
        return ctx.this.kind == "country" and obj("country", ctx.this.id) and ctx.this.id or nil
    end

    -- add_to_galactic_council = yes (CAddToGalacticCouncilEffect 0x37feba0) [V]
    EFF["add_to_galactic_council"] = function(e, ctx)
        local cid = country_of(ctx)
        if not cid or not yes(e) then return end
        if add_to_council(cid) then wrote() end
    end
    -- remove_from_galactic_council = yes (CRemoveFromGalacticCouncilEffect 0x37fee20 →
    -- RemoveFromCouncil 0x25d4e80) [V]: out of the council and the permanent seats (still a member);
    -- always one global draw and on_remove_from_council
    EFF["remove_from_galactic_council"] = function(e, ctx)
        local cid = country_of(ctx)
        if not cid or not yes(e) then return end
        local council, perm = list("council"), list("permanent_council")
        if remove_first(council, cid) then write_list("council", council) end
        if remove_first(perm, cid) then write_list("permanent_council", perm) end
        fire("on_remove_from_council", cid, eval.rand())
        wrote()
    end
    -- add_permanent_councillor = yes (CAddPermanentCouncillorEffect 0x3800600 →
    -- AddPermanentCouncillor 0x25dd710) [V]: the permanent seats filling the council's size:
    -- nothing; AddToCouncil, then appended to permanent_council
    EFF["add_permanent_councillor"] = function(e, ctx)
        local cid = country_of(ctx)
        if not cid or not yes(e) then return end
        local perm = list("permanent_council")
        if #perm >= num("council_positions", define("NGameplay", "DEFAULT_COUNCIL_SIZE", 0)) then return end
        if not add_to_council(cid) then return end
        perm = list("permanent_council")
        if not has(perm, cid) then
            perm[#perm + 1] = cid
            write_list("permanent_council", perm)
        end
        wrote()
    end
    -- remove_permanent_councillor = yes (CRemovePermanentCouncillorEffect 0x3800880) [V]: out of the
    -- permanent seats only
    EFF["remove_permanent_councillor"] = function(e, ctx)
        local cid = country_of(ctx)
        if not cid or not yes(e) then return end
        local perm = list("permanent_council")
        if remove_first(perm, cid) then
            write_list("permanent_council", perm)
            wrote()
        end
    end
    -- CGalacticCommunity::SetNumCouncilPositions (0x25dd330) [V]: below 0: 0; a size over 0 with
    -- no DLC or from 0: election = COUNCIL_ELECTION_SOON_CUTOFF; no upper bound, no seat emptied;
    -- council_positions written when not DEFAULT_COUNCIL_SIZE
    local function set_size(n)
        local default = define("NGameplay", "DEFAULT_COUNCIL_SIZE", 0)
        local old = num("council_positions", default)
        if n < 0 then
            n = 0
        elseif n ~= 0 and (not dlc() or old == 0) then
            put(gc(), "election", define("NGameplay", "COUNCIL_ELECTION_SOON_CUTOFF", 180))
        end
        put(gc(), "council_positions", n ~= default and n or nil)
        wrote()
    end
    -- set_council_size = <int> / increase_council_size = yes / decrease_council_size = yes
    -- (CSetCouncilSizeEffect 0x37ff0a0, CIncreaseCouncilSizeEffect 0x37ff260,
    -- CDecreaseCouncilSizeEffect 0x37ff4c0) [V]: any scope
    EFF["set_council_size"] = function(e, ctx)
        local v = eval.value(e.value, ctx, e)
        if v then set_size(v < 0 and -floor(-v) or floor(v)) end
    end
    EFF["increase_council_size"] = function(e)
        if yes(e) then set_size(num("council_positions", define("NGameplay", "DEFAULT_COUNCIL_SIZE", 0)) + 1) end
    end
    EFF["decrease_council_size"] = function(e)
        if yes(e) then set_size(num("council_positions", define("NGameplay", "DEFAULT_COUNCIL_SIZE", 0)) - 1) end
    end
    -- set_council_veto / set_council_emergency_measures = yes|no (CSetCouncilVetoEffect 0x37ff720,
    -- CSetCouncilEmergencyMeasuresEffect 0x37ff8d0) [V]: the flag, written when not its default
    -- (veto no, emergency measures yes)
    local function bool_key(key, default)
        return function(e)
            local v = e.value.text
            if v ~= "yes" and v ~= "no" then return end
            local on = v == "yes"
            put(gc(), key, on ~= default and v or nil)
            wrote()
        end
    end
    EFF["set_council_veto"] = bool_key("council_veto", define("NGameplay", "DEFAULT_COUNCIL_VETO", "no") == "yes")
    EFF["set_council_emergency_measures"] = bool_key("council_emergency_measures",
        define("NGameplay", "DEFAULT_COUNCIL_EMERGENCY_MEASURES", "yes") ~= "no")
    -- set_emperor_can_change_council_members = yes|no (CSetEmperorCanChangeCouncilMembersEffect
    -- 0x3800e70) [V]: the flag (saved only with a galactic empire: kept in world.meta's block
    -- regardless [I])
    EFF["set_emperor_can_change_council_members"] = bool_key("emperor_can_change_council_members", false)
    -- add_imperial_authority = <value> (CAddImperialAuthorityEffect 0x3800b00 → AddImperialAuthority
    -- 0x25d5820) [V]: clamped to [0, GALACTIC_EMPIRE_MAX_AUTHORITY]; no empire check (saved only
    -- with one)
    EFF["add_imperial_authority"] = function(e, ctx)
        local v = tonumber(eval.value(e.value, ctx, e))
        if not v then return end
        local ia = math.max(0, math.min(define("NGameplay", "GALACTIC_EMPIRE_MAX_AUTHORITY", 200),
            num("imperial_authority", 0) + v))
        put(gc(), "imperial_authority", floor(ia * 100000 + 0.5) / 100000)
        wrote()
    end

    -- set_free_migration = yes|no (CSetFreeMigrationEffect 0x37f86c0 → CFederationProgression::
    -- SetSetting(3) 0x25ac070) [V]: a federation's federation_progression.free_migration (the law not
    -- changed); yes: ClearRedundantManualPacts: every pair of members, both ways, loses the manual
    -- pacts its settings now cover (commercial_pact, research_agreement, waystation_pact,
    -- free_migration: `migration_access` and its diplo_action_dates slot) [I: the other pacts'
    -- relation keys]. Another scope: nothing (the game reads the null federation)
    local PACTS = {
        free_migration = { "migration_access", 4 }, commercial_pact = { "commercial_pact" },
        research_agreement = { "research_agreement" }, waystation_pact = { "waystation_pact" },
    }
    local function relation(cid, other)
        local c = obj("country", cid)
        local rm = c and field(c, "relations_manager")
        if type(rm) ~= "table" then return nil end
        for _, r in ipairs(world.fields(rm, "relation")) do
            if type(r) == "table" and tonumber(field(r, "country")) == other then return r end
        end
        return nil
    end
    EFF["set_free_migration"] = function(e, ctx)
        if ctx.this.kind ~= "federation" then return end
        local v = e.value.text
        if v ~= "yes" and v ~= "no" then return end
        local f = obj("federation", ctx.this.id)
        if not f then return end
        local prog = world.child(f, "federation_progression")
        world.set(prog, "free_migration", v)
        if v == "yes" then
            local members = {}
            for _, m in ipairs(world.list(field(f, "members"))) do members[#members + 1] = tonumber(m) end
            for i = 1, #members do
                for j = i + 1, #members do
                    for _, pair in ipairs({ { members[i], members[j] }, { members[j], members[i] } }) do
                        local r = relation(pair[1], pair[2])
                        if r then
                            for setting, p in pairs(PACTS) do
                                if field(prog, setting) == "yes" then
                                    local en = world.entry(r, p[1])
                                    if en then
                                        world.remove_entry(r, en)
                                        local dates = p[2] and field(r, "diplo_action_dates")
                                        if type(dates) == "table" then
                                            local k = 0
                                            for idx, x in ipairs(dates) do
                                                if x.text then
                                                    k = k + 1
                                                    if k == p[2] then world.set_text(dates, idx, '"-5070.07.21"') end
                                                end
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        wrote()
    end
end
