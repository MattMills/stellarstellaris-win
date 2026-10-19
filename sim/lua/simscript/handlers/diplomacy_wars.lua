-- simscript/handlers/diplomacy_wars.lua : wars (docs/script_diplomacy.md): declaring, joining and
-- leaving them, war goals, war exhaustion, proxy wars, the hypothetical war's participants.
--
-- The war is the save's `war = { <id> = { name start_date attackers defenders battles
-- attacker_war_goal defender_war_goal have_defender_war_goal instigator peak_participants
-- attacker_war_exhaustion defender_war_exhaustion ... } }` (CWar::WriteMembers 0x213a240 [V]), a
-- participant `{ call_type country caller fleets_gone_mia }` (SWarParticipant 0x2156160), a war goal
-- `{ type war actor target win }` (CWarGoal 0x21467e0); each relation between the sides lists the war
-- in `wars`.

return function(eval, H)
    local TRIG, EFF, LINKS = eval.TRIG, eval.EFF, eval.LINKS
    local D, world = H.D, H.world
    local S = H.S
    local sync, yes = H.sync, H.yes
    local this_country, target_country, param_country, param_text = H.this_country, H.target_country,
        H.param_country, H.param_text
    local compare_value, fixed = H.compare_value, H.fixed

    -- ------------------------------------------------------------------------------------------
    -- helpers

    local function side_of(w, c) return D.side_in(w, c) end
    local function other_side(side) return side == "attackers" and "defenders" or "attackers" end
    local function main_of(w, side)
        local first
        for _, p in ipairs(world.blocks(world.field(D.war_obj(w), side))) do
            local c = D.ref(world.field(p, "country"))
            if c then
                if world.field(p, "call_type") == "primary" then return c end
                first = first or c
            end
        end
        return first
    end
    -- the relations of a country and every country on the other side list (or drop) the war
    local function link(w, c, on)
        local side = side_of(w, c)
        if not side then return end
        for _, o in ipairs(D.war_side(w, other_side(side))) do
            for _, p in ipairs({ { c, o }, { o, c } }) do
                local r = H.relation(p[1], p[2], on)
                if r then
                    if on then
                        H.list_add(r, "wars", w)
                    else
                        H.list_remove(r, "wars", w)
                        local l = world.field(r, "wars")
                        if type(l) == "table" and #world.list(l) == 0 then H.remove_key(r, "wars") end
                    end
                end
            end
        end
    end
    -- a participant added to a side (CWar::AddAttacker / AddDefender): `{ call_type country caller
    -- fleets_gone_mia }`, the relations linked, peak_participants kept, last_date_at_war set
    local function add_participant(w, side, c, call, caller)
        local wo = D.war_obj(w)
        if not wo or side_of(w, c) then return false end
        local p = {}
        world.append(p, "call_type", call or "primary")
        world.append(p, "country", c)
        world.append(p, "caller", caller or H.NO_ID)
        world.append(p, "fleets_gone_mia", 0)
        world.push(world.child(wo, side), p)
        link(w, c, true)
        local n = #D.war_side(w, "attackers") + #D.war_side(w, "defenders")
        if n > H.num(world.field(wo, "peak_participants")) then world.set(wo, "peak_participants", n) end
        world.set(D.country(c), "last_date_at_war", H.date_text())
        return true
    end
    H.add_participant = add_participant
    -- CWar::RemoveParticipant: off its side, the relations unlinked
    local function remove_participant(w, c)
        local wo = D.war_obj(w)
        local side = wo and side_of(w, c)
        if not side then return false end
        link(w, c, false)
        local list = world.field(wo, side)
        for i = #list, 1, -1 do
            local p = list[i]
            if not p.text and not p.op and D.ref(world.field(p, "country")) == c then world.remove_at(list, i) end
        end
        return true
    end
    H.remove_participant = remove_participant

    -- NWar::ValidateNotAtWarAgainstParticipants [I]: joining a side is refused when the country is
    -- already in the war
    local function can_join(w, c) return D.war_obj(w) ~= nil and side_of(w, c) == nil end

    -- the countries a new war calls to each side (CWarParticipants::NewWar) [I: the call rules read:
    -- the defender's defensive pacts (defensive), its federation (alliance), its guarantors
    -- (guarantee) and its overlord (overlord); the attacker's subjects that join overlord wars
    -- (subject); each once, not the other main]
    local function new_war_sides(att, def)
        local sides = { attackers = { { att, "primary" } }, defenders = { { def, "primary" } } }
        local taken = { [att] = true, [def] = true }
        local function add(side, c, call, caller)
            if c and D.alive(c) and not taken[c] then
                taken[c] = true
                local l = sides[side]
                l[#l + 1] = { c, call, caller }
            end
        end
        local _, list = D.relations_of(def)
        for _, r in ipairs(list) do
            local o = D.ref(world.field(r, "country"))
            if o and D.flag(def, o, "defensive_pact") then add("defenders", o, "defensive", def) end
        end
        local f = D.federation(def)
        if f then
            for _, m in ipairs(D.members(f)) do add("defenders", m, "alliance", def) end
        end
        for _, id in ipairs(world.all("country")) do
            if D.alive(id) and D.flag(id, def, "guarantee") then add("defenders", id, "guarantee", def) end
        end
        add("defenders", D.overlord(def), "overlord", def)
        for _, s in ipairs(D.subjects(att)) do
            local ag = D.agreement(att, s)
            local td = ag and world.field(ag.block, "term_data")
            local j = td and world.field(td, "joins_overlord_wars")
            if j == "offensive" or j == "all" then add("attackers", s, "subject", att) end
        end
        return sides
    end
    H.new_war_sides = new_war_sides

    -- a side's war exhaustion (CWar::CalcWarExhaustion): attrition (the war's
    -- attacker/defender_war_exhaustion) and the battles' up to WAR_EXHAUSTION_FROM_UNITS_CUTOFF
    local function war_exhaustion(w, side)
        local wo = D.war_obj(w)
        if not wo then return 0 end
        local key = side == "attackers" and "attacker" or "defender"
        local v = H.num(world.field(wo, key .. "_war_exhaustion"))
        local cutoff = H.define("NGameplay", "WAR_EXHAUSTION_FROM_UNITS_CUTOFF", 1)
        for _, b in ipairs(world.blocks(world.field(wo, "battles"))) do
            if v >= cutoff then break end
            local t = world.field(b, "type")
            if t == "ships" or t == "armies" or t == "static_war_exhaustion" then
                v = v + math.min(H.num(world.field(b, key .. "_war_exhaustion")), math.max(0, cutoff - v))
            end
        end
        return v
    end

    -- ------------------------------------------------------------------------------------------
    -- declaring, joining, leaving

    -- declare_war = { target name attacker_war_goal } (CDeclareWarEffect 0x3727290): not when already
    -- at war with the target; CDeclareWarAction::ExecuteAccept makes the war: its name (`name`, else
    -- war_adj_vs_name [I]), both mains and the countries the war calls, the attackers' war goal; then
    -- on_war_beginning for every participant (root = country, from = the war)
    EFF["declare_war"] = function(e, ctx)
        local us = this_country(ctx)
        if not us or e.value.text then return end
        local them = param_country(e.value, "target", ctx)
        if not them or them == us then return end
        sync()
        if D.at_war_with(us, them) then return end
        local wid = H.next_id("war")
        local wo = {}
        world.create("war", wid, wo)
        local nb = {}
        local nm = param_text(e.value, "name")
        H.set_quoted(nb, "key", nm or "war_adj_vs_name")
        world.append(wo, "name", nb)
        world.append(wo, "start_date", H.date_text(), true)
        world.child(wo, "attackers")
        world.child(wo, "defenders")
        local sides = new_war_sides(us, them)
        for _, side in ipairs({ "attackers", "defenders" }) do
            for _, p in ipairs(sides[side]) do add_participant(wid, side, p[1], p[2], p[3]) end
        end
        local wg = param_text(e.value, "attacker_war_goal")
        local g = {}
        if wg then
            H.set_quoted(g, "type", wg)
            world.append(g, "war", wid)
            world.append(g, "actor", us)
            world.append(g, "target", them)
        end
        world.append(wo, "attacker_war_goal", g)
        world.append(wo, "defender_war_goal", {})
        world.set(wo, "attacker_war_exhaustion", 0)
        world.set(wo, "defender_war_exhaustion", 0)
        H.script_write()
        for _, side in ipairs({ "attackers", "defenders" }) do
            for _, c in ipairs(D.war_side(wid, side)) do H.on_action("on_war_beginning", S("country", c), S("war", wid)) end
        end
    end
    -- join_war = <country> (CJoinWarEffect 0x37279f0): every war of the target, on its side (its
    -- defenders: AddDefender, else AddAttacker), when not already in it
    EFF["join_war"] = function(e, ctx)
        local us = this_country(ctx)
        local them = us and target_country(e, ctx)
        if not them or them == us then return end
        sync()
        local n = 0
        for _, w in ipairs(D.wars_of(them)) do
            local side = side_of(w, them)
            if side and can_join(w, us) and add_participant(w, side, us, "free", them) then n = n + 1 end
        end
        if n > 0 then H.script_write() end
    end
    -- join_war_on_side = { war side } (CJoinWarOnSideEffect 0x3847440): the war's attackers or
    -- defenders, or the side of a country in it (an error when it is not in the war)
    EFF["join_war_on_side"] = function(e, ctx)
        local us = this_country(ctx)
        if not us or e.value.text then return end
        local w = H.param_scope(e.value, "war", ctx)
        if not w or w.kind ~= "war" or not D.war_obj(w.id) then return end
        local s = param_text(e.value, "side")
        local side
        if s == "attackers" or s == "defenders" then
            side = s
        else
            local c = param_country(e.value, "side", ctx)
            side = c and side_of(w.id, c)
        end
        if not side then return end
        sync()
        if can_join(w.id, us) and add_participant(w.id, side, us, "free", main_of(w.id, side)) then H.script_write() end
    end
    -- remove_war_participant = <country> (CRemoveWarParticipantEffect 0x375f4c0): a war scope;
    -- CWar::RemoveParticipant (its left-war messages are not modelled)
    EFF["remove_war_participant"] = function(e, ctx)
        if ctx.this.kind ~= "war" or not D.war_obj(ctx.this.id) then return end
        local c = target_country(e, ctx)
        if not c then return end
        sync()
        if remove_participant(ctx.this.id, c) then H.script_write() end
    end
    -- set_war_goal = { type target enemy } (CSetWarGoalEffect 0x3769da0): a country at war with the
    -- enemy (its war with it), or a war; the goal set on the side of the scope's country (a war: of
    -- the target's) [I: the war scope's side]: `{ type war actor target }`
    EFF["set_war_goal"] = function(e, ctx)
        if e.value.text then return end
        local t = param_text(e.value, "type")
        local target = param_country(e.value, "target", ctx)
        local enemy = param_country(e.value, "enemy", ctx)
        if not t then return end
        sync()
        local w, actor
        if ctx.this.kind == "country" then
            actor = ctx.this.id
            if not enemy or not D.at_war_with(actor, enemy) then return end
            for _, x in ipairs(D.wars_of(actor)) do
                local s1, s2 = side_of(x, actor), side_of(x, enemy)
                if s1 and s2 and s1 ~= s2 then w = x break end
            end
        elseif ctx.this.kind == "war" and D.war_obj(ctx.this.id) then
            w = ctx.this.id
            actor = target and side_of(w, target) and target or nil
        end
        if not w or not actor then return end
        local side = side_of(w, actor)
        local opp = enemy or main_of(w, other_side(side))
        local g = {}
        H.set_quoted(g, "type", t)
        world.append(g, "war", w)
        world.append(g, "actor", actor)
        world.append(g, "target", target and target ~= actor and target or opp)
        local wo = D.war_obj(w)
        local key = side == "attackers" and "attacker_war_goal" or "defender_war_goal"
        H.remove_key(wo, key)
        world.append(wo, key, g)
        if side == "defenders" then world.set(wo, "have_defender_war_goal", "yes") end
        H.script_write()
    end
    -- add_static_war_exhaustion = { attacker location value_for_planet_destruction } (0x3846210): the
    -- war between the scope's country and the attacker (an error without one), a battle of type
    -- static_war_exhaustion at the location's colony (CWar::AddBattle), the scope's side's exhaustion
    -- WAR_EXHAUSTION_PLANET_DESTRUCTION_MULT x the value [I: CalcSingleBattleWarExhaustionForDestructedPlanet's
    -- planet size term]
    EFF["add_static_war_exhaustion"] = function(e, ctx)
        local us = this_country(ctx)
        if not us or e.value.text then return end
        local att = param_country(e.value, "attacker", ctx)
        local loc = H.param_scope(e.value, "location", ctx)
        if not att or not loc or (loc.kind ~= "planet" and loc.kind ~= "colony") then return end
        sync()
        local w
        for _, x in ipairs(D.wars_of(us)) do
            local s1, s2 = side_of(x, us), side_of(x, att)
            if s1 and s2 and s1 ~= s2 then w = x break end
        end
        if not w then return end
        local v = H.param_value(e.value, "value_for_planet_destruction", ctx, 1)
        v = v * H.define("NGameplay", "WAR_EXHAUSTION_PLANET_DESTRUCTION_MULT", 5) / 100
        local us_att = side_of(w, us) == "attackers"
        local b = {}
        local defs_l, atts_l = {}, {}
        world.append_value(defs_l, us)
        world.append_value(atts_l, att)
        world.append(b, "defenders", us_att and atts_l or defs_l)
        world.append(b, "attackers", us_att and defs_l or atts_l)
        local E = rawget(_G, "E")
        local sys = E and E.system_of and tonumber(E.system_of("planet", loc.id))
        world.append(b, "system", sys or H.NO_ID)
        world.append(b, "colony", loc.id)
        world.append(b, "attacker_war_exhaustion", fixed(us_att and v or 0))
        world.append(b, "defender_war_exhaustion", fixed(us_att and 0 or v))
        world.append(b, "date", H.date_text(), true)
        world.append(b, "type", "static_war_exhaustion")
        world.push(world.child(D.war_obj(w), "battles"), b)
        H.script_write()
    end

    -- ------------------------------------------------------------------------------------------
    -- triggers

    -- count_war_participants = { side limit count } (CCountWarParticipantsTrigger 0x3bb7320): a war,
    -- the participants on the side of the `side` country that the limit holds for
    local function count_matching(list, block, ctx)
        local limit = H.param(block, "limit")
        local n = 0
        for _, c in ipairs(list) do
            if not limit or H.holds(limit.value, S("country", c), ctx.this) then n = n + 1 end
        end
        return n
    end
    local function count_compare(n, total, block, ctx)
        local x = H.param(block, "count")
        if not x then return n > 0 end
        if x.value.text == "all" then return n == total end
        return H.compare(n, x.op, eval.value(x.value, ctx, x))
    end
    TRIG["count_war_participants"] = function(e, ctx)
        if e.value.text or ctx.this.kind ~= "war" or not D.war_obj(ctx.this.id) then return false end
        local c = param_country(e.value, "side", ctx)
        local side = c and side_of(ctx.this.id, c)
        if not side then return false end
        sync()
        local list = D.war_side(ctx.this.id, side)
        return count_compare(count_matching(list, e.value, ctx), #list, e.value, ctx)
    end
    -- count_potential_war_participants = { attacker defender side limit count }
    -- (CCountPotentialWarParticipantsTrigger 0x3bb7e40): the side (of the `side` country) of a new war
    -- between the two (CWarParticipants::NewWar)
    local function hypothetical_side(block, ctx)
        local att = param_country(block, "attacker", ctx)
        local def = param_country(block, "defender", ctx)
        local s = param_country(block, "side", ctx)
        if not att or not def or not s then return nil end
        local sides = new_war_sides(att, def)
        for _, side in ipairs({ "attackers", "defenders" }) do
            for _, p in ipairs(sides[side]) do
                if p[1] == s then
                    local ids = {}
                    for i, q in ipairs(sides[side]) do ids[i] = q[1] end
                    return ids
                end
            end
        end
        return nil
    end
    TRIG["count_potential_war_participants"] = function(e, ctx)
        if e.value.text then return false end
        sync()
        local ids = hypothetical_side(e.value, ctx)
        if not ids then return false end
        return count_compare(count_matching(ids, e.value, ctx), #ids, e.value, ctx)
    end
    -- would_join_war = { attacker defender side } (CWouldJoinWarTrigger 0x3bb8220): the scope's
    -- country is on the side of the `side` country in that new war
    TRIG["would_join_war"] = function(e, ctx)
        local us = this_country(ctx)
        if not us or e.value.text then return false end
        sync()
        for _, c in ipairs(hypothetical_side(e.value, ctx) or {}) do
            if c == us then return true end
        end
        return false
    end
    -- def_war_exhaustion_sum / off_war_exhaustion_sum <op> x (0x3b4ddb0 / 0x3b4d980): over the
    -- country's wars it defends / attacks in, CWar::CalcWarExhaustion of its side, summed
    for k, want in pairs({ def_war_exhaustion_sum = "defenders", off_war_exhaustion_sum = "attackers" }) do
        H.num_trigger(k, function(ctx)
            local us = this_country(ctx)
            if not us then return nil end
            local s = 0
            for _, w in ipairs(D.wars_of(us)) do
                if side_of(w, us) == want then s = s + war_exhaustion(w, want) end
            end
            return fixed(s)
        end)
    end
    -- is_from_proxy_war = yes/no (CIsFromProxyWarTrigger 0x3c0c160 -> CWar::IsFromProxyWar): the war
    -- has an instigator [I]
    TRIG["is_from_proxy_war"] = function(e, ctx)
        if ctx.this.kind ~= "war" then return false end
        local wo = D.war_obj(ctx.this.id)
        local i = wo and D.ref(world.field(wo, "instigator"))
        return (i ~= nil) == yes(e)
    end
    -- num_proxy_war <op> n (CNumProxyWarTrigger 0x3c0c580 -> GetNumProxyWars): the wars this country
    -- instigated [I]
    H.num_trigger("num_proxy_war", function(ctx)
        local us = this_country(ctx)
        if not us then return nil end
        local n = 0
        for _, w in ipairs(world.all("war")) do
            local wo = D.war_obj(w)
            if wo and D.ref(world.field(wo, "instigator")) == us then n = n + 1 end
        end
        return n
    end)
    -- instigator (a war's proxy-war instigator)
    LINKS["instigator"] = function(cur)
        if cur.kind ~= "war" then return nil end
        local wo = D.war_obj(cur.id)
        local i = wo and D.ref(world.field(wo, "instigator"))
        return (i and D.alive(i)) and S("country", i) or nil
    end
    -- war_begun_num_fleets_gone_mia = { who value } (a war): who's participant entry's fleets_gone_mia
    TRIG["war_begun_num_fleets_gone_mia"] = function(e, ctx)
        if e.value.text or ctx.this.kind ~= "war" or not D.war_obj(ctx.this.id) then return false end
        local who = param_country(e.value, "who", ctx)
        if not who then return false end
        for _, side in ipairs({ "attackers", "defenders" }) do
            for _, p in ipairs(world.blocks(world.field(D.war_obj(ctx.this.id), side))) do
                if D.ref(world.field(p, "country")) == who then
                    return compare_value(H.num(world.field(p, "fleets_gone_mia")), e, ctx)
                end
            end
        end
        return false
    end
    -- is_war_leader = yes/no (CIsWarLeaderTrigger 0x3ba7a20 -> CDiplomacyCountryModule::IsAWarLeader):
    -- the main attacker or defender of one of its wars; a pop faction's country is not read [I]
    TRIG["is_war_leader"] = function(e, ctx)
        local us = this_country(ctx)
        local r = false
        if us then
            for _, w in ipairs(D.wars_of(us)) do
                local s = side_of(w, us)
                if s and main_of(w, s) == us then r = true break end
            end
        end
        return r == yes(e)
    end
    -- has_war_goal = yes (CHasWarGoalTrigger 0x3bbd480): only in the diplomatic phrases (the
    -- diplomatic action being shown): its war's goal of the actor's side is valid; elsewhere false
    TRIG["has_war_goal"] = function(e, ctx)
        local a = ctx.diplo_action
        local r = false
        if a and a.war and D.war_obj(a.war) then
            local side = side_of(a.war, a.actor or -1)
            local g = side and world.field(D.war_obj(a.war), side == "attackers" and "attacker_war_goal" or "defender_war_goal")
            r = type(g) == "table" and world.field(g, "type") ~= nil
        end
        return r == yes(e)
    end
    -- can_declare_war = { target attacker_war_goal } (CCanDeclareWarTrigger 0x3b9fac0 ->
    -- CDeclareWarAction::IsProposable) [I: its conditions as the action's script and the game's
    -- rules read: not oneself, communications, not at war with it already, no truce, not in one
    -- federation, not its overlord or subject, the war goal (when given) defined and its `potential`
    -- (this = us, from = the target) holding]
    TRIG["can_declare_war"] = function(e, ctx)
        local us = this_country(ctx)
        if not us or e.value.text then return false end
        local them = param_country(e.value, "target", ctx)
        if not them or them == us then return false end
        sync()
        if not D.flag(us, them, "communications") or D.at_war_with(us, them) or D.has_truce(us, them) then return false end
        local f = D.federation(us)
        if f and f == D.federation(them) then return false end
        if D.overlord(us) == them or D.overlord(them) == us then return false end
        local wg = param_text(e.value, "attacker_war_goal")
        if wg then
            local d = H.def("common/war_goals", wg)
            if not d then return false end
            if not H.holds(H.def_field(d, "potential"), S("country", us), S("country", them)) then return false end
        end
        return true
    end
end
