-- simscript/handlers/general_systems.lua : the second part of handlers/general.lua
-- (docs/script_general.md): the keywords of the relations between two countries (favors, secret
-- fealty, hostility, treaties, loyalty), the Shroud's patrons, contracts, the Grand Archive
-- (DNA, the vivarium), focus cards, pre-FTL ages, the country's backups, notification modifiers and
-- fog machine, and the galaxy's clusters, messages, storms and carriers.
--
-- As in general.lua, each keyword names its class in the Linux 4.5.2 build with [V] (read in the
-- binary) or [I]; a handler writes the save's own fields where the game's WriteMembers names
-- them. Where the save's form of a state was not read, the state is kept in the script state
-- (eval.state.general, not saved) and says so.

return function(eval, H)
    local I = eval._internal
    local S, NONE, compare, push, yes, sync = I.S, I.NONE, I.compare, I.push, I.yes, I.sync
    local miss, stats, state = I.miss, I.stats, I.state
    local TRIG, EFF, LINKS, LISTS = eval.TRIG, eval.EFF, eval.LINKS, eval.LISTS
    local E = I.E
    local world = require("engine.world")
    local D = require("engine.diplomacy")
    local floor = math.floor

    local this_country, param, param_text = H.this_country, H.param, H.param_text
    local target_scope, target_country, compare_value = H.target_scope, H.target_country, H.compare_value
    local fixed, country_value, set_quoted, set_meta = H.fixed, H.country_value, H.set_quoted, H.set_meta
    local meta_block, defines, def_of, unq, script_write = H.meta_block, H.defines, H.def_of, H.unq, H.script_write

    local NO_ID = 4294967295

    -- the script state of this module (not in the save): eval.state.general
    local function gstate()
        local g = state.general
        if not g then g = {}; state.general = g end
        return g
    end
    local function per_country(key, id)
        local g = gstate()
        local t = g[key]
        if not t then t = {}; g[key] = t end
        local c = t[id]
        if not c then c = {}; t[id] = c end
        return c
    end
    local function unmodelled(key, ctx, e)
        local m = stats.unmodelled[key]
        if not m then
            m = { key = key, count = 0, first = (ctx and ctx.file or "?") .. ":" .. tostring(e and e.line or "?") }
            stats.unmodelled[key] = m
        end
        m.count = m.count + 1
    end
    -- a date as the save writes it ("y.mm.dd"), of eval.today()'s day count
    local function date_text(d)
        return string.format("%d.%02d.%02d", floor(d / 360), floor((d % 360) / 30) + 1, d % 30 + 1)
    end
    local function deep_copy(block)
        local pdx = require("pdxscript")
        return pdx.parse(pdx.write(block), "copy")
    end
    local function list_has(block, value)
        for _, v in ipairs(world.list(block)) do
            if v == value then return true end
        end
        return false
    end

    -- ------------------------------------------------------------------------------------------
    -- relations between two countries (the country's `relations_manager = { relation = { country
    -- ... } }`, CRelation::WriteMembers 0x1eedf00: num_favors, hostile, secret_fealty,
    -- support_independence, the agreements' flags) [V names]

    -- a's relation towards b, made when create (CDiplomacyCountryModule::AccessOrCreateRelation)
    local function relation(a, b, create)
        local r = D.relation(a, b)
        if r or not create then return r end
        local c = world.object("country", a)
        if not c then return nil end
        local rm = world.child(c, "relations_manager")
        r = {}
        world.append(r, "owner", a)
        world.append(r, "country", b)
        world.append(rm, "relation", r)
        world.reindex(rm)
        return D.relation(a, b) or r
    end
    local function rel_set(r, key, v)
        if v then
            world.set(r, key, "yes")
        else
            local e = world.entry(r, key)
            if e then world.remove_entry(r, e) end
        end
    end
    local function favors_args(e, ctx)
        if e.value.text then return nil end
        local t = target_country(param_text(e.value, "target"), ctx, e)
        local vx = param(e.value, "value")
        return t, vx
    end
    -- add_favors = { target value } (CAddFavorsEffect 0x379f310, CRelation::AddFavors 0x1ef1b50):
    -- the scope's relation towards the target (made if needed) gets value favors, capped at
    -- FAVOR_CAP; nothing for value <= 0 [V]. (The game also fires its favor on_actions.)
    EFF["add_favors"] = function(e, ctx)
        local id = this_country(ctx)
        local t, vx = favors_args(e, ctx)
        if not id or not t or not vx then return end
        local n = floor(eval.value(vx.value, ctx, vx))
        if n <= 0 then return end
        local r = relation(id, t, true)
        local cur = tonumber(world.field(r, "num_favors")) or 0
        world.set(r, "num_favors", math.min(cur + n, defines("NGameplay", "FAVOR_CAP", 10)))
    end
    -- remove_favors = { target value = n/all } (CRemoveFavorsEffect 0x37a0200,
    -- CRelation::RemoveFavors 0x1ef1db0): only when the relation has at least n [V]
    EFF["remove_favors"] = function(e, ctx)
        local id = this_country(ctx)
        local t, vx = favors_args(e, ctx)
        if not id or not t or not vx then return end
        local r = relation(id, t, false)
        if not r then return end
        local cur = tonumber(world.field(r, "num_favors")) or 0
        local n = vx.value.text == "all" and cur or floor(eval.value(vx.value, ctx, vx))
        if cur >= n then world.set(r, "num_favors", cur - n) end
    end
    -- num_favors = { target value <op> n } (CNumFavorsTrigger 0x3be6110: the relation's +0x108) [V]
    TRIG["num_favors"] = function(e, ctx)
        local id = this_country(ctx)
        if not id or e.value.text then return false end
        local t = target_country(param_text(e.value, "target"), ctx, e)
        if not t then return false end
        local r = D.relation(id, t)
        return compare_value(tonumber(r and world.field(r, "num_favors")) or 0, e, ctx)
    end
    -- has_secret_fealty_with = <c> (CHasSecretFealtyWithTrigger 0x3c16980: either relation's
    -- flag 0x20 of +0x122, `secret_fealty`) [V]
    TRIG["has_secret_fealty_with"] = function(e, ctx)
        local id = this_country(ctx)
        local t = target_country(e.value.text, ctx, e)
        if not id or not t then return false end
        return D.flag(id, t, "secret_fealty") or D.flag(t, id, "secret_fealty")
    end
    -- remove_secret_fealty = <c> (CRemoveSecretFealtyEffect 0x37f2ed0): the pact between the
    -- subject (the scope) and the target, either way [V docs]
    EFF["remove_secret_fealty"] = function(e, ctx)
        local id = this_country(ctx)
        local t = target_country(e.value.text, ctx, e)
        if not id or not t then return end
        for _, pair in ipairs({ { id, t }, { t, id } }) do
            local r = D.relation(pair[1], pair[2])
            if r and D.rflag(r, "secret_fealty") then rel_set(r, "secret_fealty", false) end
        end
    end
    -- num_support_independence <op> n: the relations where the country supports the other's
    -- independence (`support_independence = yes`) [I]
    country_value("num_support_independence", function(id)
        local n = 0
        local _, list = D.relations_of(id)
        for _, r in ipairs(list) do
            if D.rflag(r, "support_independence") and D.alive(D.ref(world.field(r, "country"))) then n = n + 1 end
        end
        return n
    end)
    -- set_hostile = <c> (CSetHostileEffect 0x36e0030: AccessOrCreateNewRelation, both relations'
    -- caches updated): the relation towards the target `hostile`; not on itself [V calls; I both ways]
    EFF["set_hostile"] = function(e, ctx)
        local id = this_country(ctx)
        local t = target_country(e.value.text, ctx, e)
        if not id or not t or t == id then return end
        rel_set(relation(id, t, true), "hostile", true)
        rel_set(relation(t, id, true), "hostile", true)
    end
    -- end_all_treaties_with = <c> (CEndAllTreatiesWithEffect 0x3730750: CRelation::ClearAgreements):
    -- the agreements of the relation, both ways [V call; I the flags]
    local TREATIES = { "defensive_pact", "alliance", "guarantee", "support_independence", "non_aggression_pledge",
        "commercial_pact", "research_agreement", "migration_access", "waystation_pact" }
    EFF["end_all_treaties_with"] = function(e, ctx)
        local id = this_country(ctx)
        local t = target_country(e.value.text, ctx, e)
        if not id or not t then return end
        for _, pair in ipairs({ { id, t }, { t, id } }) do
            local r = D.relation(pair[1], pair[2])
            if r then
                for _, k in ipairs(TREATIES) do
                    if D.rflag(r, k) then rel_set(r, k, false) end
                end
            end
        end
    end
    -- can_control_access_for = <c> (CCanControlAccessForTrigger 0x3bc1fe0, CCountry::CanControlAccessFor
    -- 0x237e870): a country with borders controls the access of itself and of its subjects [I]
    TRIG["can_control_access_for"] = function(e, ctx)
        local id = this_country(ctx)
        local t = target_country(e.value.text, ctx, e)
        if not id or not t then return false end
        if not D.type_enforces_borders(id) then return false end
        return t == id or D.overlord(t) == id
    end
    -- has_loyalty <op> n (CHasLoyaltyTrigger 0x3c0d9c0: a subject's CCountry +0x2618, the save's
    -- `loyalty`; a country without an overlord is false) [V]
    TRIG["has_loyalty"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not id or not D.overlord(id) then return false end
        return compare_value(tonumber(world.field(c, "loyalty")) or 0, e, ctx)
    end
    -- has_monthly_loyalty <op> n (CHasMonthlyLoyaltyTrigger 0x3c0dc30: CalcMonthlyLoyaltyChange):
    -- the subject's monthly loyalty modifiers [I: subject_loyalty_add, subject_loyalty_mult]
    TRIG["has_monthly_loyalty"] = function(e, ctx)
        local id = this_country(ctx)
        if not id or not D.overlord(id) then return false end
        local v = 0
        if E.modifier then
            local add = E.modifier("country", id, "subject_loyalty_add") or 0
            local mult = E.modifier("country", id, "subject_loyalty_mult") or 0
            v = add * (1 + mult)
        end
        return compare_value(v, e, ctx)
    end
    -- the country's trade deals (`trade_deal = { id = { first = { country ... } second = { } } }`,
    -- CTradeDeal::WriteMembers 0x20d8a50) [V names]
    local function deals_between(a, b)
        local out = {}
        for _, id in ipairs(world.all("trade_deal")) do
            local d = world.object("trade_deal", id)
            if d and world.field(d, "killed") ~= "yes" then
                local f, s = world.field(d, "first"), world.field(d, "second")
                local fc = type(f) == "table" and tonumber(world.field(f, "country"))
                local sc = type(s) == "table" and tonumber(world.field(s, "country"))
                if (fc == a and (b == nil or sc == b)) or (sc == a and (b == nil or fc == b)) then
                    out[#out + 1] = { first = f, second = s, a_first = fc == a }
                end
            end
        end
        return out
    end
    local function side_has(side, key)
        if type(side) ~= "table" then return false end
        local found = false
        local function walk(b)
            for _, x in ipairs(b) do
                if found then return end
                if x.text == key then found = true return end
                if x.op and x.key and (x.key.text == key or x.value.text == key) then found = true return end
                if x.op and type(x.value) == "table" and x.value.text == nil then walk(x.value) end
            end
        end
        walk(side)
        return found
    end
    -- is_action_active = { action with_country = <c>/any } (CIsActionActiveTrigger): a trade deal
    -- of the country with the other (any) that holds the action [I]
    TRIG["is_action_active"] = function(e, ctx)
        local id = this_country(ctx)
        if not id or e.value.text then return false end
        local action = param_text(e.value, "action")
        local w = param_text(e.value, "with_country")
        local other = (w and w:lower() ~= "any") and target_country(w, ctx, e) or nil
        if not action or (w and w:lower() ~= "any" and not other) then return false end
        for _, d in ipairs(deals_between(id, other)) do
            if side_has(d.first, action) or side_has(d.second, action) then return true end
        end
        return false
    end
    -- has_sensor_link_from = <c> (CHasSensorLinkFromTrigger 0x3c17330, CCountry::HasSensorLinkFrom
    -- 0x23a0fd0: the country's trade deals, +0x2708): a deal in which the other gives a sensor
    -- link [V the deals; I the item's key]
    TRIG["has_sensor_link_from"] = function(e, ctx)
        local id = this_country(ctx)
        local t = target_country(e.value.text, ctx, e)
        if not id or not t then return false end
        for _, d in ipairs(deals_between(id, t)) do
            local theirs = d.a_first and d.second or d.first
            if side_has(theirs, "sensor_link") then return true end
        end
        return false
    end
    -- can_afford_special_offer / is_offer_terms_actual = { target } (CCanAffordSpecialOfferTrigger,
    -- CIsOfferTermsAclualTrigger): only in the AI's trade-facility script, which has an offer in its
    -- context; elsewhere false [V docs]
    TRIG["can_afford_special_offer"] = function(e, ctx)
        local offer = ctx.special_offer
        if not offer then return false end
        return offer.affordable == true
    end
    TRIG["is_offer_terms_actual"] = function(e, ctx)
        local offer = ctx.special_offer
        if not offer then return false end
        return offer.actual == true
    end

    -- ------------------------------------------------------------------------------------------
    -- the Galactic Community's resolutions

    -- in_breach_of = <resolution> (CInBreachOfTrigger 0x3c226a0, CResolutionType::IsInBreach): the
    -- resolution's `breach = { }` triggers hold for the country [V call; I the block]
    TRIG["in_breach_of"] = function(e, ctx)
        local id = this_country(ctx)
        if not id or not e.value.text then return false end
        local d, defs = def_of("common/resolutions", e.value.text)
        if not d then return false end
        local b = defs.field(d.block, "breach")
        if type(b) ~= "table" or b.text then return false end
        return eval.trigger(b, push(ctx, ctx.this))
    end
    -- is_in_breach_of_any = yes (CIsInBreachOfAnyTrigger 0x3c21f40: the country's code flags
    -- +0x2a40 bit 0x10, the save's `is_in_breach_of_any`) [V]
    TRIG["is_in_breach_of_any"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not id then return false end
        return (world.field(c, "is_in_breach_of_any") == "yes") == yes(e)
    end

    -- ------------------------------------------------------------------------------------------
    -- the Shroud's patrons (the country's `modules = { standard_shroud_module = { attunement =
    -- { x y } patron_relations covenant = { patron level } covenant_excluded_patrons } }`,
    -- CShroudCountryModule::WriteMembers 0x1f6c850; `patron_relations = { id = { owner patron
    -- position contact deeds ... } }`, CPatronRelation::WriteMembers 0x1e26790) [V names]
    --
    -- The attunement is a point of the Shroud's wheel (a CVector2FixedPoint); each patron has a
    -- position on it (its relation's `position`, else its type's `position` in
    -- common/patrons/patron_types.txt). The attunement towards a patron is 1 minus the distance
    -- from the point (in units of MAX_ATTUNEMENT_VALUE) to the patron's position, at most 1 and at
    -- least 0 (-1 when negative values are asked for) (CShroudCountryModule::GetAttunement
    -- 0x1f71130) [V]; the game scales a cardinal patron's position first (IsPositionCardinal) [I:
    -- not done here]. Adding attunement moves the point towards the patron's position
    -- (AddAttunement 0x1f6d4a0, by the patron's NAttunementUtils::CalcAttunementMult) [I: the
    -- move's form]

    local function shroud(c, create)
        local m = world.path(c, "modules", "standard_shroud_module")
        if type(m) == "table" then return m end
        if not create then return nil end
        return world.child(world.child(c, "modules"), "standard_shroud_module")
    end
    local function patron_type(name)
        local d, defs = def_of("common/patrons", name)
        if d then return d, defs end
        return nil
    end
    local function vec(block)
        if type(block) ~= "table" then return 0, 0 end
        return tonumber(world.field(block, "x")) or 0, tonumber(world.field(block, "y")) or 0
    end
    local function country_relations(id)
        local out = {}
        for _, rid in ipairs(world.all("patron_relations")) do
            local r = world.object("patron_relations", rid)
            if r and tonumber(world.field(r, "owner")) == id then out[#out + 1] = { id = rid, block = r } end
        end
        return out
    end
    local function patron_relation(id, patron)
        for _, r in ipairs(country_relations(id)) do
            if unq(world.field(r.block, "patron")) == patron then return r end
        end
        return nil
    end
    local function patron_position(id, patron)
        local r = patron_relation(id, patron)
        if r and type(world.field(r.block, "position")) == "table" then return vec(world.field(r.block, "position")) end
        local d, defs = patron_type(patron)
        if d then return vec(defs.field(d.block, "position")) end
        return nil
    end
    local function max_attunement() return defines("NGameplay", "MAX_ATTUNEMENT_VALUE", 1000) end
    local function attunement_point(c)
        local m = shroud(c, false)
        return vec(m and world.field(m, "attunement"))
    end
    local function set_point(c, x, y)
        local cap = max_attunement()
        local len = math.sqrt(x * x + y * y)
        if len > cap then x, y = x * cap / len, y * cap / len end
        local b = world.child(shroud(c, true), "attunement")
        world.set(b, "x", fixed(x))
        world.set(b, "y", fixed(y))
    end
    -- the attunement towards a patron, -1..1
    local function attunement_to(id, c, patron, negative)
        local px, py = patron_position(id, patron)
        if not px then return nil end
        local ax, ay = attunement_point(c)
        local cap = max_attunement()
        local dx, dy = ax / cap - px, ay / cap - py
        local v = 1 - math.sqrt(dx * dx + dy * dy)
        if v > 1 then v = 1 end
        if v < (negative and -1 or 0) then v = negative and -1 or 0 end
        return v
    end
    -- add attunement towards a patron: the point moved by amount along the patron's direction (a
    -- patron at the centre, the End of the Cycle's: towards the centre)
    local function add_attunement(id, c, patron, amount)
        local px, py = patron_position(id, patron)
        if not px then return false end
        local len = math.sqrt(px * px + py * py)
        local ax, ay = attunement_point(c)
        if len == 0 then
            local alen = math.sqrt(ax * ax + ay * ay)
            if alen == 0 then return true end
            local k = math.max(0, alen - amount) / alen
            set_point(c, ax * k, ay * k)
            return true
        end
        set_point(c, ax + amount * px / len, ay + amount * py / len)
        return true
    end
    local function patrons_known(id)
        local out = {}
        for _, r in ipairs(country_relations(id)) do out[#out + 1] = unq(world.field(r.block, "patron")) end
        if #out == 0 then
            local ok, defs = pcall(require, "engine.defs")
            local folder = ok and defs.folder and defs.folder("common/patrons") or {}
            for name in pairs(folder) do out[#out + 1] = name end
            table.sort(out)
        end
        return out
    end

    -- attunement <op> n (CAttunementTrigger 0x3c3a7d0: CShroudCountryModule::GetAttunement, the
    -- point): its distance from the centre, in units of MAX_ATTUNEMENT_VALUE [I]
    country_value("attunement", function(_, c)
        local x, y = attunement_point(c)
        return math.sqrt(x * x + y * y) / max_attunement()
    end)
    -- add_attunement = { <patron> = <value> ... } (CAddAttunementEffect 0x3820490) [V]
    EFF["add_attunement"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not id or e.value.text then return end
        for _, x in ipairs(e.value) do
            if x.op and x.key then
                local patron = x.key.text
                if not add_attunement(id, c, patron, eval.value(x.value, ctx, x)) then
                    miss("patron", patron, ctx, x)
                end
            end
        end
    end
    -- set_attunement = { value patron } (CSetAttunementEffect 0x3821ea0, SetAttunement): the point
    -- put where the attunement towards the patron is value: on the line from the patron's position
    -- to the centre, 1 - value from the position (a patron at the centre: the point's own
    -- direction) [I]
    EFF["set_attunement"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not id or e.value.text then return end
        local patron = param_text(e.value, "patron")
        local vx = param(e.value, "value")
        if not patron or not vx then return end
        local px, py = patron_position(id, patron)
        if not px then miss("patron", patron, ctx, e) return end
        local cap = max_attunement()
        local d = 1 - math.max(-1, math.min(1, eval.value(vx.value, ctx, vx)))
        local len = math.sqrt(px * px + py * py)
        if len == 0 then
            local ax, ay = attunement_point(c)
            local alen = math.sqrt(ax * ax + ay * ay)
            local ux, uy = 1, 0
            if alen > 0 then ux, uy = ax / alen, ay / alen end
            set_point(c, ux * d * cap, uy * d * cap)
        else
            set_point(c, (px - px / len * d) * cap, (py - py / len * d) * cap)
        end
    end
    -- get_attunement_points_for = { patron value <op> n negative = yes/no }
    -- (CGetAttunementPointsForTrigger 0x3c3b120): the attunement towards the patron in points
    -- (times MAX_ATTUNEMENT_VALUE) [V]
    TRIG["get_attunement_points_for"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not id or e.value.text then return false end
        local patron = param_text(e.value, "patron")
        local v = patron and attunement_to(id, c, patron, param_text(e.value, "negative") == "yes")
        if v == nil then return false end
        return compare_value(v * max_attunement(), e, ctx)
    end
    -- has_most_attunement = <patron> (CHasMostAttunementTrigger 0x3c3ba10): of the country's
    -- patrons, this one has the highest attunement [V]
    TRIG["has_most_attunement"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not id or not e.value.text then return false end
        local best, best_v
        for _, p in ipairs(patrons_known(id)) do
            local v = attunement_to(id, c, p, true)
            if v and (best_v == nil or v > best_v) then best, best_v = p, v end
        end
        return best == e.value.text
    end
    -- is_cardinal_patron = <patron> (CIsCardinalPatronTrigger 0x3c3b4a0, CPatronType::IsPositionCardinal):
    -- its position on an axis of the wheel [V]
    TRIG["is_cardinal_patron"] = function(e, ctx)
        local id = this_country(ctx)
        if not id or not e.value.text then return false end
        local x, y = patron_position(id, e.value.text)
        if not x then return false end
        return (x == 0) ~= (y == 0)
    end
    -- has_patron_aura = <patron> (CHasPatronAuraTrigger 0x3c39100,
    -- GetCurrentPsionicAuraType): the country's psionic aura is the patron's (the save's top-level
    -- `psionic_auras`, an aura's `owner` and `patron`) [V call; I fields]
    TRIG["has_patron_aura"] = function(e, ctx)
        local id = this_country(ctx)
        if not id or not e.value.text then return false end
        local pa = world.meta and world.meta.psionic_auras
        local inner = type(pa) == "table" and world.field(pa, "psionic_auras")
        for _, a in world.statements(type(inner) == "table" and inner or {}) do
            if type(a) == "table" and tonumber(world.field(a, "owner")) == id
                and unq(world.field(a, "patron")) == e.value.text then
                return true
            end
        end
        return false
    end
    -- refresh_psionic_aura_type = yes: the aura's type is updated now, not at the month (the type
    -- follows the covenant and the attunement each month here as in the game) [I]: nothing to hold
    EFF["refresh_psionic_aura_type"] = function() end
    -- accept_covenant / refuse_covenant = <patron> (CAcceptCovenantEffect 0x3820e90,
    -- CShroudCountryModule::AcceptCovenant 0x1f70020: `covenant = { patron level }`, an error when
    -- one is formed, then on_covenant_formed; RefuseCovenant: the patron in
    -- `covenant_excluded_patrons`) [V]
    EFF["accept_covenant"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not id or not e.value.text then return end
        local m = shroud(c, true)
        if type(world.field(m, "covenant")) == "table" then return end
        local cov = world.child(m, "covenant")
        set_quoted(cov, "patron", e.value.text)
        world.set(cov, "level", 1)
        if eval.on_action then eval.on_action("on_covenant_formed", ctx.this, ctx) end
    end
    -- (also `refuse_covenant = { patron reset_attunement = yes }`, as vanilla writes it: the point
    -- back at the centre [I])
    EFF["refuse_covenant"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not id then return end
        local patron = e.value.text or param_text(e.value, "patron")
        if not patron then return end
        local ex = world.child(shroud(c, true), "covenant_excluded_patrons")
        if not list_has(ex, patron) then world.push(ex, { text = patron, quoted = true }) end
        if e.value.text == nil and param_text(e.value, "reset_attunement") == "yes" then set_point(c, 0, 0) end
    end
    -- complete_deed = <deed> (CCompleteDeedEffect 0x3820c70): when the deed is among the country's
    -- patrons' deeds, its patron gets the deed's `attunement` (common/patrons/deeds) [V calls]
    local function patron_of_deed(id, deed)
        for _, p in ipairs(patrons_known(id)) do
            local r = patron_relation(id, p)
            if r and list_has(world.field(r.block, "deeds"), deed) then return p end
            local d, defs = patron_type(p)
            if not r and d and list_has(defs.field(d.block, "deeds"), deed) then return p end
        end
        return nil
    end
    EFF["complete_deed"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not id or not e.value.text then return end
        local p = patron_of_deed(id, e.value.text)
        local d, defs = def_of("common/patrons/deeds", e.value.text)
        if not p or not d then return end
        add_attunement(id, c, p, tonumber(defs.field(d.block, "attunement")) or 0)
    end
    -- add_patron_objective_counter = { counter amount multiplier } (CAddPatronObjectiveCounterEffect
    -- 0x3820b90, UpdatePatronObjectives): each deed of the country's patrons counting this counter
    -- moves on; at its `max` it completes (its attunement times the multiplier) and starts again.
    -- The counts are kept in the script state [I: the save's patron_objective form not read]
    local function deed_counters(deed)
        local d, defs = def_of("common/patrons/deeds", deed)
        local ctr = d and defs.field(d.block, "counter")
        return d, defs, type(ctr) == "table" and ctr or nil
    end
    local function has_counter(id, counter)
        for _, p in ipairs(patrons_known(id)) do
            local r = patron_relation(id, p)
            local deeds = r and world.list(world.field(r.block, "deeds"))
            if not deeds or #deeds == 0 then
                local d, defs = patron_type(p)
                deeds = d and world.list(defs.field(d.block, "deeds")) or {}
            end
            for _, deed in ipairs(deeds) do
                local _, _, ctr = deed_counters(deed)
                if ctr and world.field(ctr, counter) ~= nil then return true, p, deed end
            end
        end
        return false
    end
    EFF["add_patron_objective_counter"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not id or e.value.text then return end
        local counter = param_text(e.value, "counter")
        local ax, mx = param(e.value, "amount"), param(e.value, "multiplier")
        if not counter or not ax then return end
        local amount = floor(eval.value(ax.value, ctx, ax))
        local mult = mx and eval.value(mx.value, ctx, mx) or 1
        if mult < 0 then return end
        local counts = per_country("patron_counters", id)
        for _, p in ipairs(patrons_known(id)) do
            local d, defs = patron_type(p)
            for _, deed in ipairs(d and world.list(defs.field(d.block, "deeds")) or {}) do
                local dd, ddefs, ctr = deed_counters(deed)
                local spec = ctr and world.field(ctr, counter)
                if type(spec) == "table" then
                    local max = tonumber(world.field(spec, "max")) or 1
                    local k = deed .. "." .. counter
                    local n = (counts[k] or 0) + amount
                    if n < 0 then n = 0 end
                    if n >= max then
                        n = n - max
                        add_attunement(id, c, p, (tonumber(ddefs.field(dd.block, "attunement")) or 0) * mult)
                    end
                    counts[k] = n
                    script_write()
                end
            end
        end
    end
    -- has_patron_counter = <counter> (CHasPatronCounterTrigger 0x3c3bba0, HasPatronObjective): a
    -- deed of the country's patrons counts it [V]
    TRIG["has_patron_counter"] = function(e, ctx)
        local id = this_country(ctx)
        if not id or not e.value.text then return false end
        return (has_counter(id, e.value.text))
    end
    -- refresh_accords = yes (CRefreshAccordsEffect 0x38225c0, UpdateAccordsUnlocking): the
    -- relations' unlocked accords counted again from the attunement: `unlocked_passive_accords_count`
    -- = the attunement towards the patron in quarters [I]
    EFF["refresh_accords"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not id or e.value.text == "no" then return end
        for _, r in ipairs(country_relations(id)) do
            local v = attunement_to(id, c, unq(world.field(r.block, "patron")), false) or 0
            world.set(r.block, "unlocked_passive_accords_count", floor(v * 4))
        end
    end
    -- revert_accords = <patron> (CRevertPatronAccordsEffect 0x3821f50, CPatronType::RevertAccords):
    -- each accord's on_revert effects in the country [V call]; the relation's unlocked accords
    -- cleared [I]
    EFF["revert_accords"] = function(e, ctx)
        local id = this_country(ctx)
        if not id or not e.value.text then return end
        local d, defs = patron_type(e.value.text)
        if d then
            local function walk(b)
                for _, x in ipairs(b) do
                    if x.op and x.key and type(x.value) == "table" and x.value.text == nil then
                        if x.key.text == "on_revert" then eval.effect(x.value, ctx) else walk(x.value) end
                    end
                end
            end
            walk(d.block)
        end
        local r = patron_relation(id, e.value.text)
        if r then
            world.set(r.block, "unlocked_passive_accords_count", 0)
            local u = world.entry(r.block, "unlocked_active_accords")
            if u then world.remove_entry(r.block, u) end
        end
    end
    -- remove_patron = <patron> (CRemovePatronEffect 0x3821900, RemovePatron): the relation gone from
    -- the country's shroud module and the store [V call]
    EFF["remove_patron"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not id or not e.value.text then return end
        local r = patron_relation(id, e.value.text)
        if not r then return end
        local m = shroud(c, false)
        local l = m and world.field(m, "patron_relations")
        if type(l) == "table" then world.remove_value(l, tostring(r.id)) end
        world.remove("patron_relations", r.id)
    end
    -- replace_patron = { new_patron replaced_patron } (CReplacePatronEffect 0x3821c90,
    -- ReplacePatron): the replaced relation's patron becomes the new one, keeping its position; a
    -- relation made when there is none [V docs]
    EFF["replace_patron"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not id or e.value.text then return end
        local new, old = param_text(e.value, "new_patron"), param_text(e.value, "replaced_patron")
        if not new or not old then return end
        local r = patron_relation(id, old)
        if r then
            set_quoted(r.block, "patron", new)
            return
        end
        local x, y = patron_position(id, old)
        local block = {}
        world.append(block, "owner", id)
        world.append(block, "patron", new, true)
        if x then
            local pos = {}
            world.append(pos, "x", fixed(x))
            world.append(pos, "y", fixed(y))
            world.append(block, "position", pos)
        end
        world.ensure_store("patron_relations")
        local rid = world.next_index("patron_relations")
        world.create("patron_relations", rid, block)
        world.push(world.child(shroud(c, true), "patron_relations"), tostring(rid))
    end
    -- set_ai_preferred_patron = <patron> (CSetAIPreferredPatronEffect 0x3822a10): the country's
    -- `is_preferred_patron` (CCountry::WriteMembers) [V]
    EFF["set_ai_preferred_patron"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not id or not e.value.text then return end
        set_quoted(c, "is_preferred_patron", e.value.text)
    end
    -- roll_ai_preferred_patron = yes (CRollAIPreferredPatronEffect 0x3822760): the cardinal patron
    -- with the highest attunement [V]
    EFF["roll_ai_preferred_patron"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not id or e.value.text == "no" then return end
        local best, best_v
        for _, p in ipairs(patrons_known(id)) do
            local x, y = patron_position(id, p)
            if x and (x == 0) ~= (y == 0) then
                local v = attunement_to(id, c, p, true)
                if v and (best_v == nil or v > best_v) then best, best_v = p, v end
            end
        end
        if best then set_quoted(c, "is_preferred_patron", best) end
    end

    -- ------------------------------------------------------------------------------------------
    -- contracts (the nomads' missions from common/missions/missions: CContractManager, the save's
    -- `contracts = { available = { } }`). The contracts are kept in the script state:
    -- { id, type, category, issuer, location, target, operator } [I: the mission objects' save form
    -- not read]

    local function contracts()
        local g = gstate()
        if not g.contracts then g.contracts = { next = 1, list = {} } end
        return g.contracts
    end
    local function contract_category(t)
        local d, defs = def_of("common/missions/missions", t)
        return d and unq(defs.field(d.block, "category")) or nil
    end
    -- issue_contract = { contract location target } (CContractManager::IssueContract): a contract
    -- available in the system, issued by the country, for the target (anyone) [V docs]
    EFF["issue_contract"] = function(e, ctx)
        local id = this_country(ctx)
        if not id or e.value.text then return end
        local t = param_text(e.value, "contract")
        local loc = target_scope(param_text(e.value, "location"), ctx, e)
        if not t or not loc then return end
        if not def_of("common/missions/missions", t) then miss("contract", t, ctx, e) return end
        local cs = contracts()
        local who = target_country(param_text(e.value, "target"), ctx, e)
        local sys = loc.kind == "system" and loc.id or (E.system_of and E.system_of(loc.kind, loc.id))
        cs.list[#cs.list + 1] = { id = cs.next, type = t, category = contract_category(t), issuer = id,
            location = sys, target = who }
        cs.next = cs.next + 1
        script_write()
    end
    local function owned_contracts(id)
        local out = {}
        for _, k in ipairs(contracts().list) do
            if k.issuer == id or k.operator == id then out[#out + 1] = k end
        end
        return out
    end
    local function contract_scopes(id)
        local out = {}
        for i, k in ipairs(owned_contracts(id)) do out[i] = S("mission", k.id) end
        return out
    end
    -- owned_contract: the contracts the country issued or works on (any_, every_, random_,
    -- ordered_, count_owned_contract)
    LISTS["owned_contract"] = function(sc)
        if sc.kind ~= "country" then return {} end
        return contract_scopes(sc.id)
    end
    -- has_contract / has_contract_of_category = <key>: a contract the country works on [V docs]
    TRIG["has_contract"] = function(e, ctx)
        local id = this_country(ctx)
        if not id then return false end
        for _, k in ipairs(contracts().list) do
            if k.operator == id and k.type == e.value.text then return true end
        end
        return false
    end
    TRIG["has_contract_of_category"] = function(e, ctx)
        local id = this_country(ctx)
        if not id then return false end
        for _, k in ipairs(contracts().list) do
            if k.operator == id and k.category == e.value.text then return true end
        end
        return false
    end
    -- the counts: available to the country (not taken, open to it), in progress by it, issued by
    -- it, visible to it (available and in progress) [V docs]
    local function available_to(k, id) return k.operator == nil and (k.target == nil or k.target == id) end
    country_value("count_available_contracts", function(id)
        local n = 0
        for _, k in ipairs(contracts().list) do if available_to(k, id) then n = n + 1 end end
        return n
    end)
    country_value("count_contracts_in_progress", function(id)
        local n = 0
        for _, k in ipairs(contracts().list) do if k.operator == id then n = n + 1 end end
        return n
    end)
    country_value("count_issued_contracts", function(id)
        local n = 0
        for _, k in ipairs(contracts().list) do if k.issuer == id then n = n + 1 end end
        return n
    end)
    country_value("count_visible_contracts", function(id)
        local n = 0
        for _, k in ipairs(contracts().list) do
            if available_to(k, id) or k.operator == id then n = n + 1 end
        end
        return n
    end)

    -- ------------------------------------------------------------------------------------------
    -- the Grand Archive: DNA and the vivarium (the country's `modules = { standard_grand_archive_module
    -- = { rarity = { <ship category> = <rarity> } vivarium_critters = { ids } culled_dna_list } }`,
    -- CGrandArchiveCountryModule::WriteMembers 0x1c59ec0; the critters in the top-level
    -- `vivarium_critters` store, CVivariumCritter: rarity ship_design_implementation name
    -- creation_date) [V names]

    local RARITIES = { "common", "rare", "epic", "exceptional" }
    local RANK = {}
    for i, r in ipairs(RARITIES) do RANK[r] = i end
    local function archive(c, create)
        local m = world.path(c, "modules", "standard_grand_archive_module")
        if type(m) == "table" then return m end
        if not create then return nil end
        return world.child(world.child(c, "modules"), "standard_grand_archive_module")
    end
    local function dna_rarity(c, category)
        local m = archive(c, false)
        local r = m and world.field(m, "rarity")
        return type(r) == "table" and unq(world.field(r, category)) or nil
    end
    -- give_dna = { ship_category rarity } (CGiveDnaEffect): the category's DNA at the rarity
    -- (common by default), never lowered [V docs]
    EFF["give_dna"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not id or e.value.text then return end
        local cat = param_text(e.value, "ship_category")
        local r = param_text(e.value, "rarity") or "common"
        if not cat or not RANK[r] then return end
        local cur = dna_rarity(c, cat)
        if cur and (RANK[cur] or 0) >= RANK[r] then return end
        set_quoted(world.child(archive(c, true), "rarity"), cat, r)
    end
    -- has_dna = { ship_category rarity } (CHasDnaTrigger 0x3c54670: GetRarityByShipCategory): the
    -- category's DNA, at the rarity or above when one is given [V]
    TRIG["has_dna"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not id or e.value.text then return false end
        local cat = param_text(e.value, "ship_category")
        local cur = cat and dna_rarity(c, cat)
        if not cur then return false end
        local want = param_text(e.value, "rarity")
        return want == nil or (RANK[cur] or 0) >= (RANK[want] or 99)
    end
    local function critters(c)
        local m = archive(c, false)
        local out = {}
        for _, v in ipairs(world.list(m and world.field(m, "vivarium_critters"))) do
            local cid = tonumber(v)
            local o = cid and world.object("vivarium_critters", cid)
            if o then out[#out + 1] = { id = cid, block = o } end
        end
        return out
    end
    -- num_vivarium_slots <op> n: the vivarium's critters [V docs]
    country_value("num_vivarium_slots", function(_, c) return #critters(c) end)
    -- add_to_vivarium = { design rarity amount } (CAddToVivariumEffect 0x383e5d0): amount critters
    -- of the design; rarity `highest` (the DNA's), else the given one; without one drawn from
    -- WILD_CRITTERS_RARITY_TABLE [V calls]. The critter's design is the design's name [I]
    EFF["add_to_vivarium"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not id or e.value.text then return end
        local design = param_text(e.value, "design")
        if not design then return end
        local ax = param(e.value, "amount")
        local n = ax and floor(eval.value(ax.value, ctx, ax)) or 1
        local r = param_text(e.value, "rarity")
        world.ensure_store("vivarium_critters")
        local list = world.child(archive(c, true), "vivarium_critters")
        for _ = 1, n do
            local rr = r
            if rr == "highest" or rr == nil then
                local t = { 80, 15, 4, 1 }
                local x = eval.rand() % 100
                rr = "exceptional"
                for i, w in ipairs(t) do
                    if x < w then rr = RARITIES[i] break end
                    x = x - w
                end
            end
            local block = {}
            world.append(block, "rarity", rr)
            world.append(block, "name", require("pdxscript").parse('key="' .. design .. '"', "name"))
            world.append(block, "creation_date", date_text(eval.today()), true)
            local cid = world.next_index("vivarium_critters")
            world.create("vivarium_critters", cid, block)
            world.push(list, tostring(cid))
        end
    end
    local function remove_critter(c, cid)
        local l = world.field(archive(c, false), "vivarium_critters")
        if type(l) == "table" then world.remove_value(l, tostring(cid)) end
        world.remove("vivarium_critters", cid)
    end
    -- release_vivarium_fauna = { category location owner cull_vivarium_critter }
    -- (CReleaseVivariumFaunaEffect 0x383eec0): the critters of the category (all) leave the
    -- vivarium; culled, they are counted in `culled_dna_list` [V calls]; released into the wild,
    -- their fleets are not made here (recorded as unmodelled)
    EFF["release_vivarium_fauna"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not id or e.value.text then return end
        local cull = param_text(e.value, "cull_vivarium_critter") == "yes"
        for _, k in ipairs(critters(c)) do
            remove_critter(c, k.id)
            if not cull then unmodelled("release_vivarium_fauna fleet", ctx, e) end
        end
    end
    -- release_vivarium_fauna_count = { count location owners }: the rarest critters first [V docs]
    EFF["release_vivarium_fauna_count"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not id or e.value.text then return end
        local cx = param(e.value, "count")
        local n = cx and floor(eval.value(cx.value, ctx, cx)) or 0
        local list = critters(c)
        table.sort(list, function(a, b)
            local ra, rb = RANK[unq(world.field(a.block, "rarity"))] or 0, RANK[unq(world.field(b.block, "rarity"))] or 0
            if ra ~= rb then return ra > rb end
            return a.id < b.id
        end)
        for i = 1, math.min(n, #list) do
            remove_critter(c, list[i].id)
            unmodelled("release_vivarium_fauna fleet", ctx, e)
        end
    end

    -- ------------------------------------------------------------------------------------------
    -- focus cards (the country's `focus = { active completed reward = { rewards = { { category
    -- current progress } } } }`, CCountryFocusManager::WriteMembers 0x242d4a0; the cards in the
    -- `focus_cards` store, `type` and `status`) [V names]

    -- add_focus_progress = { category amount } (CAddFocusProgressEffect,
    -- CCountryFocusRewardManager::AddProgressToCategory): the category's reward progress; at its
    -- reward's `cost` (common/country_focus/focus_rewards) the reward's on_success runs and the
    -- category's next reward (by its number) is current, the rest carried over [I]
    local function next_reward(cur)
        local base, n = tostring(cur):match("^(.-)(%d+)$")
        if not base then return nil end
        local name = base .. (tonumber(n) + 1)
        return def_of("common/country_focus/focus_rewards", name) and name or nil
    end
    EFF["add_focus_progress"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not id or e.value.text then return end
        local cat = param_text(e.value, "category")
        local ax = param(e.value, "amount")
        if not cat or not ax then return end
        local amount = eval.value(ax.value, ctx, ax)
        local rewards = world.path(c, "focus", "reward", "rewards")
        if type(rewards) ~= "table" then return end
        for _, r in ipairs(world.blocks(rewards)) do
            local rc = unq(world.field(r, "category"))
            if cat == "all" or rc == cat then
                local p = (tonumber(world.field(r, "progress")) or 0) + amount
                local cur = unq(world.field(r, "current"))
                local d, defs = def_of("common/country_focus/focus_rewards", cur)
                local cost = d and tonumber(defs.field(d.block, "cost"))
                while cost and p >= cost do
                    p = p - cost
                    local on = defs.field(d.block, "on_success")
                    if type(on) == "table" and on.text == nil then eval.effect(on, push(ctx, ctx.this)) end
                    local nxt = next_reward(cur)
                    if not nxt then break end
                    cur = nxt
                    set_quoted(r, "current", cur)
                    d, defs = def_of("common/country_focus/focus_rewards", cur)
                    cost = d and tonumber(defs.field(d.block, "cost"))
                end
                world.set(r, "progress", fixed(p))
            end
        end
    end
    -- has_completed_focus = <card> (CHasCompletedFocusTrigger): the card in the focus' `completed`
    -- [V name; I: a card of the country's with status 1 counts too]
    TRIG["has_completed_focus"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not id or not e.value.text then return false end
        local f = world.field(c, "focus")
        if type(f) ~= "table" then return false end
        if list_has(world.field(f, "completed"), e.value.text) then return true end
        for _, v in ipairs(world.list(world.field(f, "active"))) do
            local card = world.object("focus_cards", tonumber(v))
            if card and unq(world.field(card, "type")) == e.value.text and tonumber(world.field(card, "status")) == 1 then
                return true
            end
        end
        return false
    end

    -- ------------------------------------------------------------------------------------------
    -- pre-FTL ages (the country's `preftl_age`; the ages' `next_age` in
    -- common/technology_ages/preftl) [V names]

    local function next_age(age)
        local d, defs = def_of("common/technology_ages/preftl", age)
        return d and unq(defs.field(d.block, "next_age")) or nil
    end
    -- has_next_pre_ftl_age = yes (CCountry::HasNextPreFtlTechAge): pre-FTL with a next age [V]
    TRIG["has_next_pre_ftl_age"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not id then return false end
        local age = unq(world.field(c, "preftl_age"))
        return (age ~= nil and next_age(age) ~= nil) == yes(e)
    end
    -- go_to_next_pre_ftl_age = yes (CGoToNextPreFtlAgeEffect 0x37eb1c0) [V]
    EFF["go_to_next_pre_ftl_age"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not id or e.value.text == "no" then return end
        local age = unq(world.field(c, "preftl_age"))
        local nxt = age and next_age(age)
        if nxt then set_quoted(c, "preftl_age", nxt) end
    end
    -- set_pre_ftl_age = <age> (CSetPreFtlAgeEffect 0x37eb570): only on a pre-FTL country [V]
    EFF["set_pre_ftl_age"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not id or not e.value.text or world.field(c, "preftl_age") == nil then return end
        if not def_of("common/technology_ages/preftl", e.value.text) then miss("pre_ftl_age", e.value.text, ctx, e) return end
        set_quoted(c, "preftl_age", e.value.text)
    end

    -- ------------------------------------------------------------------------------------------
    -- the country's notification modifiers, fog machine, backups and end

    -- add_notification_modifier / remove_notification_modifier = <key>: the country's
    -- `notification_modifiers = { "key" }` (common/notification_modifiers) [V name; I form]
    EFF["add_notification_modifier"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not id or not e.value.text then return end
        if not def_of("common/notification_modifiers", e.value.text) then miss("notification modifier", e.value.text, ctx, e) return end
        local l = world.child(c, "notification_modifiers")
        if not list_has(l, e.value.text) then world.push(l, { text = e.value.text, quoted = true }) end
    end
    EFF["remove_notification_modifier"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not id or not e.value.text then return end
        local l = world.field(c, "notification_modifiers")
        if type(l) == "table" then world.remove_value(l, e.value.text) end
    end
    -- activate_fog_machine = <cloud type> / deactivate_fog_machine = yes: the country's
    -- `fog_machine = { cloud_type }` (CCountryFogMachineContainer::WriteMembers 0x2401590) [V name];
    -- the clouds it draws over the country's systems are the map's [I]
    EFF["activate_fog_machine"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not id or not e.value.text then return end
        set_quoted(world.child(c, "fog_machine"), "cloud_type", e.value.text)
    end
    EFF["deactivate_fog_machine"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not id or e.value.text == "no" then return end
        local f = world.field(c, "fog_machine")
        local t = type(f) == "table" and world.entry(f, "cloud_type")
        if t then world.remove_entry(f, t) end
    end
    -- store_country_backup_data = { flag room name ethics government } (CStoreCountryBackupDataEffect
    -- 0x37eafb0, CCountry::StoreBackupData): copies in the country's `backup_data`;
    -- restore_country_backup_data = yes (0x37eb030): copied back, an error without any [V calls; I
    -- the block's keys: the country's own]
    local BACKUP = { flag = "flag", room = "room", name = "name", ethics = "ethos", government = "government" }
    EFF["store_country_backup_data"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not id or e.value.text then return end
        local old = world.entry(c, "backup_data")
        if old then world.remove_entry(c, old) end
        local b = world.child(c, "backup_data")
        for k, field in pairs(BACKUP) do
            if param_text(e.value, k) == "yes" then
                local v = world.field(c, field)
                if type(v) == "table" then world.append(b, field, deep_copy(v))
                elseif v ~= nil then world.append(b, field, v, true) end
            end
        end
    end
    EFF["restore_country_backup_data"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not id or e.value.text == "no" then return end
        local b = world.field(c, "backup_data")
        if type(b) ~= "table" then return end
        for _, field in pairs(BACKUP) do
            local v = world.field(b, field)
            if v ~= nil then
                local entry = world.entry(c, field)
                local val = type(v) == "table" and deep_copy(v) or v
                if entry then world.set_entry(c, entry, val) elseif type(val) == "table" then world.append(c, field, val)
                else world.append(c, field, val, true) end
                if type(val) ~= "table" then
                    local t = world.token_entry(c, field)
                    if t then t.value.quoted = true end
                end
            end
        end
    end
    -- destroy_country = yes (CDestroyCountryEffect 0x371f8c0: CCountry::SetToBeKilled): the country's
    -- `killed` code flag; the daily update removes it [V call]
    EFF["destroy_country"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not id or e.value.text == "no" then return end
        world.set(c, "killed", "yes")
    end
    -- set_player = <old country> (CSetPlayerEffect 0x3786650): the human of the old country plays
    -- the scoped one (the save's `player = { { name country } }`) [V]
    EFF["set_player"] = function(e, ctx)
        local id = this_country(ctx)
        local old = target_country(e.value.text, ctx, e)
        if not id or not old then return end
        local p = world.meta and world.meta.player
        for _, b in ipairs(type(p) == "table" and world.blocks(p) or {}) do
            if tonumber(world.field(b, "country")) == old then
                world.set(b, "country", id)
                return
            end
        end
    end
    -- clear_uncharted_space = <system> (CRemoveUnchartedSpaceEffect 0x375ceb0,
    -- CCountry::ClearTerraIncognita): the country's `terra_incognita` map cleared around the system;
    -- the map's cells are not modelled here (recorded)
    EFF["clear_uncharted_space"] = function(e, ctx)
        local id = this_country(ctx)
        local t = target_scope(e.value.text, ctx, e)
        if not id or not t then return end
        unmodelled("clear_uncharted_space", ctx, e)
    end
    -- copy_flags_and_variables_from = <scope>: the target's script flags and variables set on this
    -- scope too [V docs]
    EFF["copy_flags_and_variables_from"] = function(e, ctx)
        local t = target_scope(e.value.text, ctx, e)
        local me = ctx.this
        if not t or not me or me == NONE then return end
        local o = world.object(t.kind, t.id)
        if o then
            local f = world.field(o, "flags")
            for name, v in world.statements(type(f) == "table" and f or {}) do
                local days = type(v) == "table" and tonumber(world.field(v, "flag_days")) or nil
                eval.store.set_flag(me, name, days)
            end
            local vars = world.field(o, "variables")
            for name, v in world.statements(type(vars) == "table" and vars or {}) do
                if tonumber(v) then eval.store.setvar(me, name, tonumber(v)) end
            end
        else
            for name, v in pairs(state.flags[t.key] or {}) do
                eval.store.set_flag(me, name, v ~= true and (v - eval.today()) or nil)
            end
            for name, v in pairs(state.vars[t.key] or {}) do eval.store.setvar(me, name, v) end
        end
        script_write()
    end
    -- run_ai_strategic_data = yes: the AI's strategic data computed again (engine.ai keeps none
    -- between days) [I]
    EFF["run_ai_strategic_data"] = function() end

    -- triumph_days_left <op> n (CTriumphDaysLeftTrigger 0x3c15730, CCountry::GetRelicCooldown
    -- 0x23b55a0: the days of the country's timed `relic_activation_cooldown`) [V]
    country_value("triumph_days_left", function(_, c)
        local items = world.path(c, "timed_modifier", "items")
        for _, m in ipairs(world.blocks(type(items) == "table" and items or {})) do
            if unq(world.field(m, "modifier")) == "relic_activation_cooldown" then return tonumber(world.field(m, "days")) or 0 end
        end
        return 0
    end)
    -- enclave_capacity_left <op> n (CEnclaveCapacityLeftTrigger 0x3c18430,
    -- CCountryEnclaveManager::CalculateCapacity): COUNTRY_ENCLAVE_CAPACITY_BASE plus
    -- country_enclave_capacity_add, times 1 + _mult, at most COUNTRY_ENCLAVE_CAPACITY_MAX, less
    -- country_enclave_usage_add [I]
    country_value("enclave_capacity_left", function(id)
        local base = defines("NGameplay", "COUNTRY_ENCLAVE_CAPACITY_BASE", 0)
        local max = defines("NGameplay", "COUNTRY_ENCLAVE_CAPACITY_MAX", 10)
        local add, mult, used = 0, 0, 0
        if E.modifier then
            add = E.modifier("country", id, "country_enclave_capacity_add") or 0
            mult = E.modifier("country", id, "country_enclave_capacity_mult") or 0
            used = E.modifier("country", id, "country_enclave_usage_add") or 0
        end
        return math.min(max, floor((base + add) * (1 + mult))) - used
    end)
    -- has_surveyed_class = <planet class> (CHasSurveyedClassTrigger 0x3b6aae0: the country's
    -- surveyed deposit holders): a surveyed planet of the class [V]
    TRIG["has_surveyed_class"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not id or not e.value.text then return false end
        local s = world.field(c, "surveyed_deposit_holders")
        for _, b in ipairs(world.blocks(type(s) == "table" and s or {})) do
            local pid = tonumber(world.field(b, "id"))
            local ty = world.field(b, "type")
            local p = pid and (ty == nil or tostring(ty) == "0" or ty == "planet") and world.object("planet", pid)
            if p and unq(world.field(p, "planet_class")) == e.value.text then return true end
        end
        return false
    end
    -- is_in_sensor_range = <ship/fleet/planet/system> (CInSensorRangeTrigger 0x3c27ac0:
    -- CCountry::CanSee for a ship or fleet, HasInSensorRange for a system or planet): the system is
    -- the country's, or holds one of its fleets or starbases [I: the sensor radii not measured]
    TRIG["is_in_sensor_range"] = function(e, ctx)
        local id = this_country(ctx)
        local t = target_scope(e.value.text, ctx, e)
        if not id or not t then return false end
        local sys = t.kind == "system" and t.id or (E.system_of and E.system_of(t.kind, t.id))
        if not sys then return false end
        if E.systems_within_border then
            for _, s in ipairs(E.systems_within_border(id)) do if s == sys then return true end end
        end
        local o = world.object("country", id)
        for _, v in ipairs(world.list(o and world.field(o, "visited_objects"))) do
            if tonumber(v) == sys and E.fleets_in_system then
                for _, f in ipairs(E.fleets_in_system(sys)) do
                    if E.owner_of and E.owner_of("fleet", f) == id then return true end
                end
            end
        end
        return false
    end

    -- ------------------------------------------------------------------------------------------
    -- the galaxy: clusters, messages, storms, carriers, blobs

    -- create_cluster = { id center radius } (CCreateClusterEffect): the systems within radius of the
    -- center make a cluster (the save's `clusters = { { id systems } }`) [V docs; I form]
    EFF["create_cluster"] = function(e, ctx)
        if e.value.text then return end
        local name = param_text(e.value, "id")
        local center = target_scope(param_text(e.value, "center"), ctx, e)
        local rx = param(e.value, "radius")
        if not name or not center then return end
        local csys = center.kind == "system" and center.id or (E.system_of and E.system_of(center.kind, center.id))
        local co = csys and world.object("system", csys)
        if not co then return end
        local function coord(o)
            local c = world.field(o, "coordinate")
            return tonumber(type(c) == "table" and world.field(c, "x")) or 0, tonumber(type(c) == "table" and world.field(c, "y")) or 0
        end
        local cx, cy = coord(co)
        local r = rx and eval.value(rx.value, ctx, rx) or 30
        local block = {}
        world.append(block, "id", name, true)
        local list = {}
        for _, sid in ipairs(world.all("system")) do
            local o = world.object("system", sid)
            if o then
                local x, y = coord(o)
                if (x - cx) ^ 2 + (y - cy) ^ 2 <= r * r then list[#list + 1] = { text = tostring(sid) } end
            end
        end
        world.append(block, "systems", list)
        world.append(meta_block("clusters"), "cluster", block)
    end
    -- create_message = { type localization days target variable ... } (CCreateMessageEffect): a
    -- message to the country in scope (the save's `message = { }`) [V docs; I form]
    EFF["create_message"] = function(e, ctx)
        if e.value.text then return end
        local ty = param_text(e.value, "type")
        if not ty then return end
        local who = ctx.this.kind == "country" and ctx.this.id or nil
        local block = {}
        world.append(block, "type", ty, true)
        local loc = param_text(e.value, "localization")
        if loc then world.append(block, "localization", loc, true) end
        if who then world.append(block, "owner", who) end
        local dx = param(e.value, "days")
        if dx then world.append(block, "days", floor(eval.value(dx.value, ctx, dx))) end
        local t = target_scope(param_text(e.value, "target"), ctx, e)
        if t then world.append(block, "target", t.id) end
        world.append(block, "date", date_text(eval.today()), true)
        world.append(meta_block("message"), "message", block)
    end
    -- the cosmic storms: spawn_random_storm, start_storm_area_placing (the player's map placing
    -- mode: nothing here), storm_apply_aftermath_modifier = { severity = { modifier days chance
    -- effect } ... }: one severity by chance, its modifier added to the scope [V docs]
    EFF["start_storm_area_placing"] = function() end
    EFF["spawn_random_storm"] = function(e, ctx) unmodelled("spawn_random_storm", ctx, e) end
    EFF["storm_apply_aftermath_modifier"] = function(e, ctx)
        if e.value.text then return end
        local list, total = {}, 0
        for _, x in ipairs(e.value) do
            if x.op and x.key and x.key.text:lower() == "severity" and x.value.text == nil then
                local cx = param(x.value, "chance")
                local w = cx and eval.value(cx.value, ctx, cx) or 1
                if w > 0 then
                    list[#list + 1] = { w = w, block = x.value }
                    total = total + w
                end
            end
        end
        if total <= 0 then return end
        local r = (eval.scope_draw and eval.scope_draw(ctx) or eval.rand()) % floor(total * 1000)
        for _, s in ipairs(list) do
            local w = floor(s.w * 1000)
            if r < w then
                local m = param_text(s.block, "modifier")
                local dx = param(s.block, "days")
                if m then
                    local add = { { key = { text = "modifier" }, op = "=", value = { text = m } } }
                    if dx then add[2] = { key = { text = "days" }, op = "=", value = dx.value } end
                    eval.effect1({ key = { text = "add_modifier" }, op = "=", value = add }, ctx)
                end
                local ex = param(s.block, "effect")
                if ex and ex.value.text == nil then eval.effect(ex.value, ctx) end
                return
            end
            r = r - w
        end
    end
    -- transfer_carrier = { source target transfer_ownership transfer_controller merge_pops
    -- destroy_colony } (CTransferCarrierEffect): a nomad colony moved to another carrier; the
    -- carriers are not modelled here (recorded)
    EFF["transfer_carrier"] = function(e, ctx)
        if e.value.text then return end
        local s = target_scope(param_text(e.value, "source"), ctx, e)
        local t = target_scope(param_text(e.value, "target"), ctx, e)
        if s and t then unmodelled("transfer_carrier", ctx, e) end
    end
    -- effect_on_blob = { center owned_planets_percentage planet_limit effect } (CEffectOnBlobEffect):
    -- the systems with the country's colonies matching planet_limit, nearest to the center first,
    -- until the share of those colonies is covered; the effect in each system [V docs]
    EFF["effect_on_blob"] = function(e, ctx)
        local id = this_country(ctx)
        if not id or e.value.text then return end
        local center = target_scope(param_text(e.value, "center"), ctx, e)
        local px = param(e.value, "owned_planets_percentage")
        local lim = param(e.value, "planet_limit")
        local ex = param(e.value, "effect")
        if not center or not ex or ex.value.text then return end
        local csys = center.kind == "system" and center.id or (E.system_of and E.system_of(center.kind, center.id))
        local co = csys and world.object("system", csys)
        if not co then return end
        local share = px and eval.value(px.value, ctx, px) or 1
        local function coord(o)
            local c = world.field(o, "coordinate")
            return tonumber(type(c) == "table" and world.field(c, "x")) or 0, tonumber(type(c) == "table" and world.field(c, "y")) or 0
        end
        local cx, cy = coord(co)
        local by_sys, systems, total = {}, {}, 0
        for _, pid in ipairs(E.colonies(id)) do
            if not lim or lim.value.text or eval.trigger(lim.value, push(ctx, S("planet", pid))) then
                local sid = E.system_of and E.system_of("planet", pid)
                if sid then
                    if not by_sys[sid] then
                        by_sys[sid] = 0
                        local o = world.object("system", sid)
                        local x, y = coord(o)
                        systems[#systems + 1] = { id = sid, d = (x - cx) ^ 2 + (y - cy) ^ 2 }
                    end
                    by_sys[sid] = by_sys[sid] + 1
                    total = total + 1
                end
            end
        end
        table.sort(systems, function(a, b) if a.d ~= b.d then return a.d < b.d end return a.id < b.id end)
        local covered = 0
        for _, s in ipairs(systems) do
            if total == 0 or covered >= share * total then break end
            eval.effect(ex.value, push(ctx, S("system", s.id)))
            covered = covered + by_sys[s.id]
        end
    end
end
