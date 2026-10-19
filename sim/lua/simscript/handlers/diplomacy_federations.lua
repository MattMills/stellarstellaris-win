-- simscript/handlers/diplomacy_federations.lua : federations and the galactic community
-- (docs/script_diplomacy.md): members and associates, the progression (cohesion, experience, laws,
-- settings, succession, type), leaving and dissolving; the community's members, resolutions and
-- votes.
--
-- The federation is the save's `federation = { <id> = { name federation_progression members
-- associates start_date leader ... } }` (CFederation::WriteMembers 0x258f930 [V]), its progression
-- `{ federation_type experience base_cohesion cohesion laws action_settings envoy levels perks
-- succession_type succession_term ... <settings> }` (CFederationProgression 0x25a16e0 [V]); a member
-- country's `federation`, an associate's `associated_federation`. The community is the top-level
-- `galactic_community = { leader members council proposed passed failed emissaries voting last ...
-- category_timers }` (CGalacticCommunity 0x25cf220 [V]), a resolution the `resolution` store's
-- `{ type country target supporters opponents voting pass_date }` (CResolution 0x1f06510 [V]).

return function(eval, H)
    local TRIG, EFF, LINKS = eval.TRIG, eval.EFF, eval.LINKS
    local D, world = H.D, H.world
    local S = H.S
    local sync, yes = H.sync, H.yes
    local this_country, target_country, param_country, param_text = H.this_country, H.target_country,
        H.param_country, H.param_text
    local fixed = H.fixed

    -- ------------------------------------------------------------------------------------------
    -- federations

    -- the scope's federation: a federation, or a country's
    local function fed_of(ctx)
        local sc = ctx.this
        if sc.kind == "federation" then return D.fed_obj(sc.id) and sc.id or nil end
        if sc.kind == "country" then return D.federation(sc.id) end
        return nil
    end
    local function prog(f, create)
        local fo = D.fed_obj(f)
        if not fo then return nil end
        if create then return world.child(fo, "federation_progression") end
        return D.fed_progression(f)
    end

    -- alliance relations between a country and the other members (`alliance = yes` both ways), set
    -- or cleared
    local function ally(c, f, on)
        for _, m in ipairs(D.members(f)) do
            if m ~= c then
                for _, p in ipairs({ { c, m }, { m, c } }) do
                    local r = H.relation(p[1], p[2], on)
                    if r then H.set_yes(r, "alliance", on) end
                end
            end
        end
    end
    -- CFederation::AddMember [I: its body]: in `members`, the country's `federation`, the alliance
    -- relations, its associate status dropped
    local function add_member(f, c)
        local fo = D.fed_obj(f)
        if not fo or D.is_member_of(f, c) then return false end
        H.list_add(fo, "members", c)
        world.set(D.country(c), "federation", f)
        H.remove_key(D.country(c), "associated_federation")
        H.list_remove(fo, "associates", c)
        ally(c, f, true)
        return true
    end
    -- CFederation::RemoveMember (0x2590eb0, re_fed_gc_buttons.md): out of `members`, its `federation`
    -- gone, its envoys out of `envoy`, the alliance relations cleared; a leaving leader passes the
    -- lead to the first other member [I: the succession law's pick]
    local function remove_member(f, c)
        local fo = D.fed_obj(f)
        if not fo or not D.is_member_of(f, c) then return false end
        ally(c, f, false)
        H.list_remove(fo, "members", c)
        H.remove_key(D.country(c), "federation")
        local p = prog(f)
        local env = p and world.field(p, "envoy")
        for _, l in ipairs(D.id_list(env)) do
            local lo = world.object("leader", l)
            if lo and D.ref(world.field(lo, "country")) == c then world.remove_value(env, tostring(l)) end
        end
        if D.ref(world.field(fo, "leader")) == c then
            local rest = D.members(f)
            if rest[1] then world.set(fo, "leader", rest[1]) end
        end
        return true
    end
    -- CFederation::End: every member and associate out, the federation removed (the game at the
    -- next day's tick, ToBeKilled; here at once [I])
    local function end_federation(f)
        local fo = D.fed_obj(f)
        if not fo then return end
        for _, m in ipairs(D.id_list(world.field(fo, "members"))) do
            ally(m, f, false)
            H.remove_key(D.country(m), "federation")
        end
        for _, a in ipairs(D.associates(f)) do H.remove_key(D.country(a), "associated_federation") end
        world.remove("federation", f)
    end
    -- CLeaveFederationAction::ExecuteAccept (0x2654c60): RemoveMember; with each remaining member a
    -- truce (alliance) and, with the opinion penalty, opinion_broke_federation towards the leaver;
    -- cohesion FEDERATION_LEAVE_COHESION_PENALTY; fewer than 2 members end it
    local function leave(c, penalty)
        local f = D.federation(c)
        if not f then return false end
        remove_member(f, c)
        local p = prog(f)
        if p then
            local coh = H.num(world.field(p, "cohesion")) + H.define("NGameplay", "FEDERATION_LEAVE_COHESION_PENALTY", -100)
            world.set(p, "cohesion", fixed(math.max(-100, coh)))
        end
        local rest = D.members(f)
        for _, m in ipairs(rest) do
            if H.new_truce then H.set_truce_between(c, m, H.new_truce("alliance")) end
            if penalty then
                pcall(require, "engine.script.creation")
                local ok, systems = pcall(require, "engine.systems")
                if ok and systems.effects.add_opinion_modifier then
                    pcall(systems.effects.add_opinion_modifier, { kind = "country", id = m, who = c, modifier = "opinion_broke_federation" })
                end
            end
        end
        if #rest < 2 then end_federation(f) end
        return true
    end

    -- join_alliance = { who override_requirements } (CJoinAllianceEffect 0x37281a0): the scope's
    -- country leaves its federation (CLeaveFederationAction), then joins the target's
    -- (CInviteToFederationAction::ExecuteAccept); a target without one founds a new federation with
    -- it, the target leading [I: the new federation's name and type: a default_federation named
    -- NAME_<n> as the game's own new ones]
    EFF["join_alliance"] = function(e, ctx)
        local us = this_country(ctx)
        if not us or e.value.text then return end
        local them = param_country(e.value, "who", ctx)
        if not them or them == us then return end
        sync()
        local f = D.federation(them)
        if D.federation(us) and D.federation(us) ~= f then leave(us, false) end
        if not f then
            f = H.next_id("federation")
            local fo = {}
            world.create("federation", f, fo)
            local nb = {}
            H.set_quoted(nb, "key", "NAME_Rebellion")
            world.append(fo, "name", nb)
            local p = {}
            H.set_quoted(p, "federation_type", "default_federation")
            world.append(p, "experience", 0)
            world.append(p, "base_cohesion", 0)
            world.append(p, "cohesion", 0)
            world.append(p, "levels", 1)
            world.append(fo, "federation_progression", p)
            world.child(fo, "members")
            world.append(fo, "start_date", H.date_text(), true)
            world.append(fo, "leader", them)
            add_member(f, them)
        end
        if add_member(f, us) then H.script_write() end
    end
    -- leave_alliance = { override_requirements apply_opinion_penalty } (CLeaveAllianceEffect
    -- 0x3728e40): CLeaveFederationAction when proposable (override: always)
    EFF["leave_alliance"] = function(e, ctx)
        local us = this_country(ctx)
        if not us then return end
        sync()
        local penalty = not e.value.text and param_text(e.value, "apply_opinion_penalty") == "yes"
        if leave(us, penalty) then H.script_write() end
    end
    -- remove_from_federation = yes (CRemoveFromFederationEffect 0x37f3ac0): CFederation::RemoveMember
    -- only (no truce, no opinion); the federation ends with fewer than 2 members
    EFF["remove_from_federation"] = function(e, ctx)
        local us = this_country(ctx)
        if not us or e.value.text ~= "yes" then return end
        sync()
        local f = D.federation(us)
        if f and remove_member(f, us) then
            if #D.members(f) < 2 then end_federation(f) end
            H.script_write()
        end
    end
    -- dissolve_federation = yes (CDissolveFederationEffect 0x37f9840): CFederation::SetToBeKilled
    EFF["dissolve_federation"] = function(e, ctx)
        if ctx.this.kind ~= "federation" or e.value.text ~= "yes" or not D.fed_obj(ctx.this.id) then return end
        sync()
        end_federation(ctx.this.id)
        H.script_write()
    end
    -- add_associate_member = { who override_requirements } (CAddAssociateMemberEffect 0x37f9030): not
    -- a member or associate; CFederation::AddAssociate (override, else when the association offer
    -- to the leader is proposable [I: always])
    EFF["add_associate_member"] = function(e, ctx)
        if ctx.this.kind ~= "federation" or e.value.text then return end
        local f = ctx.this.id
        local fo = D.fed_obj(f)
        local who = param_country(e.value, "who", ctx)
        if not fo or not who or D.is_member_of(f, who) then return end
        sync()
        if D.ref(world.field(D.country(who), "associated_federation")) == f then return end
        H.list_add(fo, "associates", who)
        world.set(D.country(who), "associated_federation", f)
        H.script_write()
    end
    -- remove_associate_member = { who override_requirements } (CRemoveAssociateMemberEffect
    -- 0x37f94c0): an error when it is not an associate; CFederation::RemoveAssociate
    EFF["remove_associate_member"] = function(e, ctx)
        if ctx.this.kind ~= "federation" or e.value.text then return end
        local f = ctx.this.id
        local who = param_country(e.value, "who", ctx)
        if not who or D.ref(world.field(D.country(who), "associated_federation")) ~= f then return end
        sync()
        H.remove_key(D.country(who), "associated_federation")
        H.list_remove(D.fed_obj(f), "associates", who)
        H.script_write()
    end
    -- set_federation_leader = <country> (CSetFederationLeaderEffect 0x3768ef0): a federation or a
    -- country in one; the target must be a member; CFederation::SetLeader
    EFF["set_federation_leader"] = function(e, ctx)
        local f = fed_of(ctx)
        local c = target_country(e, ctx)
        if not f or not c or not D.is_member_of(f, c) then return end
        sync()
        world.set(D.fed_obj(f), "leader", c)
        H.script_write()
    end

    -- add_cohesion = <value> (CAddCohesionEffect 0x37f8e30 -> CFederationProgression::AddCohesion):
    -- within +-FEDERATION_COHESION_RANGE [I]
    EFF["add_cohesion"] = function(e, ctx)
        if ctx.this.kind ~= "federation" then return end
        local p = prog(ctx.this.id, true)
        if not p then return end
        local v = H.value(e, ctx)
        sync()
        local range = H.define("NGameplay", "FEDERATION_COHESION_RANGE", 100)
        local c = math.max(-range, math.min(range, H.num(world.field(p, "cohesion")) + v))
        world.set(p, "cohesion", fixed(c))
        H.script_write()
    end
    -- the type's levels' experience (common/federation_types `levels = { level_N = { experience } }`,
    -- the file's @variables)
    -- the folder's files' @variables (stellar.script.source.definitions' third result), once
    local file_vars
    local function variable(file, name)
        if not file_vars then
            local defs = require("engine.defs")
            local ok, _, _, vars = pcall(require("stellar.script.source").definitions, defs.fs, "common/federation_types")
            file_vars = ok and vars or {}
        end
        local v = file_vars[file]
        return v and tonumber(v[name:sub(2)]) or nil
    end
    local function level_thresholds(ftype)
        local out = {}
        local defs = require("engine.defs")
        local d = ftype and defs.get("common/federation_types", ftype)
        local lv = d and defs.field(d.block, "levels")
        for _, x in ipairs(type(lv) == "table" and lv or {}) do
            if x.op and type(x.value) == "table" then
                local v = defs.field(x.value, "experience")
                local n = tonumber(v)
                if not n and type(v) == "string" and v:sub(1, 1) == "@" then n = variable(d.file, v) end
                out[#out + 1] = n or math.huge
            end
        end
        return out
    end
    -- add_federation_experience = <value> (CAddFederationExperienceEffect 0x37f7c10 ->
    -- CFederationProgression::SetExperience(experience + value)): at least 0; the level the
    -- experience reaches (the type's thresholds) [I: the new levels' perks are not unlocked here]
    EFF["add_federation_experience"] = function(e, ctx)
        if ctx.this.kind ~= "federation" then return end
        local p = prog(ctx.this.id, true)
        if not p then return end
        local v = H.value(e, ctx)
        sync()
        local x = math.max(0, H.num(world.field(p, "experience")) + v)
        world.set(p, "experience", fixed(x))
        local th = level_thresholds(tostring(world.field(p, "federation_type") or ""):gsub('"', ""))
        if #th > 0 then
            local lv = 1
            for i = 1, #th - 1 do
                if x >= th[i] then lv = i + 1 end
            end
            world.set(p, "levels", lv)
        end
        H.script_write()
    end
    -- set_federation_law = <law> (CSetFederationLawEffect 0x37f7b30 -> CFederation::SetLaw): the law's
    -- category (common/federation_law_categories `laws`) gets it in `laws`, its on_enact runs
    -- (federation scope)
    local law_category
    local function category_of(law)
        if not law_category then
            law_category = {}
            local defs = require("engine.defs")
            for cat, d in pairs(defs.folder("common/federation_law_categories")) do
                local laws = defs.field(d.block, "laws")
                for _, x in ipairs(type(laws) == "table" and laws or {}) do
                    if x.text then law_category[x.text] = cat end
                end
            end
        end
        return law_category[law]
    end
    EFF["set_federation_law"] = function(e, ctx)
        if ctx.this.kind ~= "federation" or not e.value.text then return end
        local law = e.value.text
        local cat = category_of(law)
        local p = prog(ctx.this.id, true)
        if not cat or not p then return end
        sync()
        local laws = world.child(p, "laws")
        world.set(laws, cat, law)
        H.script_write()
        local d = H.def("common/federation_laws", law)
        if d then H.run(H.def_field(d, "on_enact"), S("federation", ctx.this.id), S("federation", ctx.this.id)) end
    end
    -- set_federation_settings = { <setting> = <value> ... } (CSetFederationSettingsEffect 0x37f8d10 ->
    -- SetSetting): the progression's settings (`commercial_pact = yes` ...)
    EFF["set_federation_settings"] = function(e, ctx)
        if ctx.this.kind ~= "federation" or e.value.text then return end
        local p = prog(ctx.this.id, true)
        if not p then return end
        sync()
        local n = 0
        for _, x in ipairs(e.value) do
            if x.op and x.key and x.value.text then
                world.set(p, x.key.text, x.value.text)
                n = n + 1
            end
        end
        if n > 0 then H.script_write() end
    end
    -- set_allow_subjects_to_join / set_equal_voting_power = yes/no (0x37f82e0, SetSetting)
    for k, setting in pairs({ set_allow_subjects_to_join = "allow_subjects_to_join", set_equal_voting_power = "equal_voting_power" }) do
        EFF[k] = function(e, ctx)
            if ctx.this.kind ~= "federation" or not e.value.text then return end
            local p = prog(ctx.this.id, true)
            if not p then return end
            sync()
            world.set(p, setting, e.value.text == "yes" and "yes" or "no")
            H.script_write()
        end
    end
    -- set_federation_succession_term / _type = <value> (0x37f80b0 / 0x37f7f20): the progression's
    -- succession_term (status_change, years_10 ... years_40) / succession_type (strongest,
    -- diplomatic_weight, rotation, challenge, random)
    local TERMS = { status_change = true, years_10 = true, years_20 = true, years_30 = true, years_40 = true }
    local TYPES = { strongest = true, diplomatic_weight = true, rotation = true, challenge = true, random = true }
    for k, spec in pairs({ set_federation_succession_term = { "succession_term", TERMS },
        set_federation_succession_type = { "succession_type", TYPES } }) do
        EFF[k] = function(e, ctx)
            if ctx.this.kind ~= "federation" or not spec[2][e.value.text or ""] then return end
            local p = prog(ctx.this.id, true)
            if not p then return end
            sync()
            world.set(p, spec[1], e.value.text)
            H.script_write()
        end
    end
    -- set_federation_type = <type> (CSetFederationTypeEffect 0x37f7d90 -> SetType)
    EFF["set_federation_type"] = function(e, ctx)
        if ctx.this.kind ~= "federation" or not e.value.text then return end
        if not H.def("common/federation_types", e.value.text) then return end
        local p = prog(ctx.this.id, true)
        if not p then return end
        sync()
        H.set_quoted(p, "federation_type", e.value.text)
        H.script_write()
    end
    -- set_diplomacy_action_setting = { action settings = { vote_type acceptance_type } }
    -- (0x37f85a0 -> SetActionSetting): the progression's `action_settings = { "<action>" = { ... } }`
    EFF["set_diplomacy_action_setting"] = function(e, ctx)
        if ctx.this.kind ~= "federation" or e.value.text then return end
        local action = param_text(e.value, "action")
        local sx = H.param(e.value, "settings")
        local p = prog(ctx.this.id, true)
        if not action or not sx or type(sx.value) ~= "table" or not p then return end
        sync()
        local as = world.child(p, "action_settings")
        local b
        for _, x in ipairs(as) do
            if x.op and x.key and x.key.text == action and type(x.value) == "table" then b = x.value end
        end
        if not b then
            b = {}
            as[#as + 1] = { key = { text = action, quoted = true }, op = "=", value = b }
            world.retrack(as)
        end
        for _, x in ipairs(sx.value) do
            if x.op and x.key and x.value.text then world.set(b, x.key.text, x.value.text) end
        end
        H.script_write()
    end
    -- federation_cohesion_growth <op> x (CFederationCohesionGrowthTrigger 0x3c1c4d0 ->
    -- CFederationProgression::CalcCohesionGrowth) [I: a modifier total the game recomputes:
    -- FEDERATION_BASE_COHESION, + FEDERATION_ENVOY_BASE_EFFECT a federation envoy, - the members'
    -- distinct ethics beyond the first]
    H.num_trigger("federation_cohesion_growth", function(ctx)
        local f = fed_of(ctx)
        local p = f and prog(f)
        if not p then return nil end
        local g = H.define("NGameplay", "FEDERATION_BASE_COHESION", 5)
        g = g + #D.id_list(world.field(p, "envoy")) * H.define("NGameplay", "FEDERATION_ENVOY_BASE_EFFECT", 1)
        local ethics = {}
        local n = 0
        for _, m in ipairs(D.members(f)) do
            local eb = world.path(D.country(m), "ethos")
            for _, x in ipairs(type(eb) == "table" and eb or {}) do
                if x.op and x.key and x.key.text == "ethic" and x.value.text and not ethics[x.value.text] then
                    ethics[x.value.text] = true
                    n = n + 1
                end
            end
        end
        return fixed(g - math.max(0, n - 1))
    end)
    -- is_alliance_fleet = yes/no (CIsAllianceFleet 0x3bf6d80 -> CFleet::IsFederationFleet 0x2931170
    -- [V]): the fleet's first ship's owner type is the federation (CShip::GetOwnerType: its design's
    -- `ship_owner_type = federation`, the ship's `ship_design_implementation = { design }`)
    TRIG["is_alliance_fleet"] = function(e, ctx)
        local r = false
        if ctx.this.kind == "fleet" then
            local f = world.object("fleet", ctx.this.id)
            local ships = f and world.field(f, "ships")
            local first = type(ships) == "table" and tonumber(world.list(ships)[1])
            local s = first and world.object("ship", first)
            local impl = s and world.field(s, "ship_design_implementation")
            local did = type(impl) == "table" and tonumber(world.field(impl, "design"))
            local d = did and world.object("ship_design", did)
            r = d ~= nil and world.field(d, "ship_owner_type") == "federation"
        end
        return r == yes(e)
    end

    -- alliance / associated_federation (a country to its federation / the one it is associated to)
    LINKS["alliance"] = function(cur)
        if cur.kind ~= "country" then return nil end
        local f = D.federation(cur.id)
        return f and S("federation", f) or nil
    end
    LINKS["associated_federation"] = function(cur)
        if cur.kind ~= "country" then return nil end
        local f = D.ref(world.field(D.country(cur.id), "associated_federation"))
        return (f and D.fed_obj(f)) and S("federation", f) or nil
    end

    -- ------------------------------------------------------------------------------------------
    -- the galactic community

    local function gc() return D.community() end
    local function res_obj(id) return id and H.object("resolution", id) or nil end
    local function res_type(r) return r and tostring(world.field(r, "type") or ""):gsub('"', "") or nil end
    local function res_category(t)
        local defs = require("engine.defs")
        for cat, d in pairs(defs.folder("common/resolution_categories")) do
            local l = defs.field(d.block, "resolution_types")
            for _, x in ipairs(type(l) == "table" and l or {}) do
                if x.text and tostring(x.text):gsub('"', "") == t then return cat end
            end
        end
        return nil
    end

    -- CGalacticCommunity::AddMember (0x25d9400, re_fed_gc_buttons.md): `members` appended,
    -- on_galactic_community_formed for the first, on_add_community_member [the member's
    -- communications with the others not modelled]
    local function add_gc_member(c)
        local g = gc()
        if not g or D.gc_is_member(c) then return false end
        local first = #D.gc_members() == 0
        H.list_add(g, "members", c)
        if first then H.on_action("on_galactic_community_formed", S("country", c), S("country", c)) end
        H.on_action("on_add_community_member", S("country", c), S("country", c))
        return true
    end
    -- add_to_galactic_community(_no_message) = yes (0x37fe420 / 0x37fe6a0): AddMember
    for _, k in ipairs({ "add_to_galactic_community", "add_to_galactic_community_no_message" }) do
        EFF[k] = function(e, ctx)
            local us = this_country(ctx)
            if not us or e.value.text ~= "yes" then return end
            sync()
            if add_gc_member(us) then H.script_write() end
        end
    end
    -- remove_from_galactic_community = yes (0x37fe920 -> CGalacticCommunity::RemoveMember 0x25d97b0):
    -- out of `members` and the council, its emissaries out, on_remove_community_member
    EFF["remove_from_galactic_community"] = function(e, ctx)
        local us = this_country(ctx)
        if not us or e.value.text ~= "yes" then return end
        sync()
        local g = gc()
        if not g or not D.gc_is_member(us) then return end
        H.list_remove(g, "members", us)
        H.list_remove(g, "council", us)
        local em = world.field(g, "emissaries")
        for _, l in ipairs(D.id_list(em)) do
            local lo = world.object("leader", l)
            if lo and D.ref(world.field(lo, "country")) == us then world.remove_value(em, tostring(l)) end
        end
        H.script_write()
        H.on_action("on_remove_community_member", S("country", us), S("country", us))
    end
    -- has_galactic_community_emissary = yes/no (0x3c22e90 -> HasAssignedEmissaryFrom): an emissary of
    -- the country in `emissaries`
    TRIG["has_galactic_community_emissary"] = function(e, ctx)
        local us = this_country(ctx)
        local r = false
        if us then
            for _, l in ipairs(D.id_list(world.field(gc(), "emissaries"))) do
                local lo = world.object("leader", l)
                if lo and D.ref(world.field(lo, "country")) == us then r = true break end
            end
        end
        return r == yes(e)
    end

    -- a new resolution (CGameState::CreateNewResolution): `{ type country target supporters }`
    local function new_resolution(t, us, target)
        local id = H.next_id("resolution")
        local r = {}
        world.create("resolution", id, r)
        H.set_quoted(r, "type", t)
        world.append(r, "country", us or H.NO_ID)
        if target then world.append(r, "target", target) end
        if us then H.list_add(r, "supporters", us) end
        return id, r
    end
    -- the first (oldest) proposed, voted on or failed resolution of the type (and target)
    local function find_open(t, target)
        local g = gc()
        local ids = {}
        local v = D.ref(world.field(g, "voting"))
        if v then ids[#ids + 1] = v end
        for _, k in ipairs({ "proposed", "failed" }) do
            for _, id in ipairs(D.id_list(world.field(g, k))) do ids[#ids + 1] = id end
        end
        table.sort(ids)
        for _, id in ipairs(ids) do
            local r = res_obj(id)
            if r and res_type(r) == t and (target == nil or D.ref(world.field(r, "target")) == target) then return id, r end
        end
        return nil
    end
    -- CGalacticCommunity::PassResolutionType: the open resolution of the type (else a new one of the
    -- scope's country) passed: out of the queue, its pass_date, in `passed`, `last`; the category's
    -- timer (`category_timers`, unless no_cooldown); its `effect` runs in its country's scope (the
    -- game's save after pass_resolution: the proposer's flag and modifier only)
    local function pass(t, us, target, no_cooldown)
        local g = gc()
        local d = H.def("common/resolutions", t)
        if not g or not d then return false end
        local id, r = find_open(t, target)
        if not id then id, r = new_resolution(t, us, target) end
        for _, k in ipairs({ "proposed", "failed" }) do H.list_remove(g, k, id) end
        if D.ref(world.field(g, "voting")) == id then H.remove_key(g, "voting") end
        world.set(r, "pass_date", H.date_text())
        world.token_entry(r, "pass_date").value.quoted = true
        H.list_add(g, "passed", id)
        world.set(g, "last", id)
        if not no_cooldown then
            local cat = res_category(t)
            if cat then
                local ct = world.child(g, "category_timers")
                world.set(ct, cat, H.date_text())
                world.token_entry(ct, cat).value.quoted = true
            end
        end
        local owner = D.ref(world.field(r, "country")) or us
        H.run(H.def_field(d, "effect"), S("country", owner), target and S("country", target) or nil)
        return true
    end
    -- pass_resolution / pass_resolution_no_cooldown = <type> (0x37ffb00 / 0x37ffc20), and
    -- pass_targeted_resolution = { resolution target } (0x3801820: the target not validated)
    EFF["pass_resolution"] = function(e, ctx)
        if not e.value.text then return end
        sync()
        if pass(e.value.text, this_country(ctx), nil, false) then H.script_write() end
    end
    EFF["pass_resolution_no_cooldown"] = function(e, ctx)
        if not e.value.text then return end
        sync()
        if pass(e.value.text, this_country(ctx), nil, true) then H.script_write() end
    end
    EFF["pass_targeted_resolution"] = function(e, ctx)
        if e.value.text then return end
        local t = param_text(e.value, "resolution")
        local target = param_country(e.value, "target", ctx)
        if not t or not target then return end
        sync()
        if pass(t, this_country(ctx), target, false) then H.script_write() end
    end
    -- propose_resolution = { resolution target } (0x37ffe90 -> CGalacticCommunity::ProposeResolution):
    -- a new resolution of the scope's country, in `proposed`, the country supporting it
    EFF["propose_resolution"] = function(e, ctx)
        local us = this_country(ctx)
        if not us or e.value.text then return end
        local t = param_text(e.value, "resolution")
        if not t or not H.def("common/resolutions", t) or not gc() then return end
        local target = param_country(e.value, "target", ctx)
        sync()
        local id = new_resolution(t, us, target)
        H.list_add(gc(), "proposed", id)
        H.script_write()
    end
    -- cancel_resolution = <type> (0x3800500 -> CGalacticCommunity::CancelResolution): the latest
    -- resolution of the type, whatever its state, removed from the community's lists and the store
    EFF["cancel_resolution"] = function(e, ctx)
        local t = e.value.text
        local g = gc()
        if not t or not g then return end
        sync()
        local best
        for _, id in ipairs(H.all("resolution")) do
            local r = res_obj(id)
            if r and res_type(r) == t and (not best or id > best) then best = id end
        end
        if not best then return end
        for _, k in ipairs({ "proposed", "passed", "failed" }) do H.list_remove(g, k, best) end
        for _, k in ipairs({ "voting", "last" }) do
            if D.ref(world.field(g, k)) == best then H.remove_key(g, k) end
        end
        world.remove(H.STORE.resolution, best)
        H.script_write()
    end

    -- has_passed_resolution = { days / months / years } (CHasPassedResolutionTrigger 0x3c23110): a
    -- passed resolution of the country's within that time
    TRIG["has_passed_resolution"] = function(e, ctx)
        local us = this_country(ctx)
        if not us or e.value.text then return false end
        local within
        for unit, mult in pairs({ days = 1, months = 30, years = 360 }) do
            local x = H.param(e.value, unit)
            if x then within = eval.value(x.value, ctx, x) * mult end
        end
        if not within then return false end
        for _, id in ipairs(D.id_list(world.field(gc(), "passed"))) do
            local r = res_obj(id)
            local d = r and D.date_days(world.field(r, "pass_date"))
            if r and D.ref(world.field(r, "country")) == us and d and eval.today() - d <= within then return true end
        end
        return false
    end
    -- is_proposing_resolution = <type / any> (CIsProposingResolution 0x3c20f00): a proposed
    -- resolution of the country's (of the type)
    TRIG["is_proposing_resolution"] = function(e, ctx)
        local us = this_country(ctx)
        local want = e.value.text
        if not us or not want then return false end
        for _, id in ipairs(D.id_list(world.field(gc(), "proposed"))) do
            local r = res_obj(id)
            if r and D.ref(world.field(r, "country")) == us and (want == "any" or res_type(r) == want) then return true end
        end
        return false
    end
    -- is_voting_on_resolution = <type / any> (0x3c20cb0): the community's `voting` resolution
    TRIG["is_voting_on_resolution"] = function(e)
        local r = res_obj(D.ref(world.field(gc(), "voting")))
        if not r or not e.value.text then return false end
        return e.value.text == "any" or res_type(r) == e.value.text
    end
    -- last_resolution_changed = <type>, last_resolution_category_changed = <category> (0x3c210d0 /
    -- 0x3c21210): the community's `last` resolution
    TRIG["last_resolution_changed"] = function(e)
        local r = res_obj(D.ref(world.field(gc(), "last")))
        return r ~= nil and res_type(r) == e.value.text
    end
    TRIG["last_resolution_category_changed"] = function(e)
        local r = res_obj(D.ref(world.field(gc(), "last")))
        return r ~= nil and res_category(res_type(r)) == e.value.text
    end
    -- position_on_current_resolution / position_on_last_resolution = support/oppose/abstain: the
    -- country among the `voting` / `last` resolution's supporters, opponents, else abstaining
    local function position(r, us)
        if H.list_has(world.field(r, "supporters"), us) then return "support" end
        if H.list_has(world.field(r, "opponents"), us) then return "oppose" end
        return "abstain"
    end
    for k, key in pairs({ position_on_current_resolution = "voting", position_on_last_resolution = "last" }) do
        TRIG[k] = function(e, ctx)
            local us = this_country(ctx)
            local r = res_obj(D.ref(world.field(gc(), key)))
            if not us or not r then return false end
            return position(r, us) == e.value.text
        end
    end
    -- used_favors_on_last_resolution <op> n (CUsedFavorsOnLastResolutionTrigger 0x3c235f0 ->
    -- CCountry::GetNumFavorsUsedForResolution(last)) [I: not in the saves read: kept in the script
    -- state by resolution, 0 without]
    H.num_trigger("used_favors_on_last_resolution", function(ctx)
        local us = this_country(ctx)
        local last = D.ref(world.field(gc(), "last"))
        if not us or not last then return 0 end
        local st = eval.state.favors_on_resolution or {}
        return st[us .. ":" .. last] or 0
    end)
end
