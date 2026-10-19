-- simscript/handlers/general.lua : the keywords that belong to no single window (docs/script_general.md):
-- scope links of every scope (the from chain, the galactic community's leader, the last created
-- country), control flow and tooltip triggers, the galaxy's setup, the country's own fields (its
-- name, flag, AI ratios, budget and research readings, code flags), the galactic community's
-- custodian, emperor, defense force and emergency fund, and the systems of the later DLCs that
-- keep their state in the country (patrons, contracts, the vivarium, focus cards, pre-FTL ages).
--
-- Each keyword's class in the Linux 4.5.2 build is named in its comment with [V] (read in the
-- binary: /opt/stellaris-headless/re on 10.5.0.24) or [I] (from the game's script documentation
-- and the save's fields). The world is the save (engine.world): a handler writes the fields the
-- game writes (CCountry::WriteMembers' names), so a save written after it has the change.

return function(eval)
    local I = eval._internal
    local S, NONE, compare, push, yes, sync = I.S, I.NONE, I.compare, I.push, I.yes, I.sync
    local miss, stats, state = I.miss, I.stats, I.state
    local TRIG, EFF, LINKS, LISTS = eval.TRIG, eval.EFF, eval.LINKS, eval.LISTS
    local E = I.E
    local world = require("engine.world")
    local floor = math.floor

    local NO_ID = 4294967295

    -- ------------------------------------------------------------------------------------------
    -- helpers

    local function script_write() stats.script = stats.script + 1 end

    -- the scope's country: its id and its block (a country scope only)
    local function this_country(ctx)
        local sc = ctx.this
        if not sc or sc.kind ~= "country" then return nil end
        local c = world.object("country", sc.id)
        if not c then return nil end
        return sc.id, c
    end
    -- a block parameter: its statement
    local function param(block, key)
        if type(block) ~= "table" or block.text then return nil end
        for _, x in ipairs(block) do
            if x.op and x.key and x.key.text:lower() == key then return x end
        end
        return nil
    end
    local function param_text(block, key)
        local x = param(block, key)
        return x and x.value.text or nil
    end
    -- the scope a statement's value names (`= root`, `= event_target:x`)
    local function target_scope(text, ctx, e)
        if not text then return nil end
        local found, sc = eval.resolve(text, ctx, e)
        if found and sc and sc ~= NONE then return sc end
        return nil
    end
    local function target_country(text, ctx, e)
        local sc = target_scope(text, ctx, e)
        if sc and sc.kind == "country" and world.object("country", sc.id) then return sc.id end
        return nil
    end
    -- `<trigger> <op> <value>`, or `<trigger> = { value <op> n }`
    local function compare_value(v, e, ctx)
        if v == nil then return false end
        if e.value.text then return compare(v, e.op, eval.value(e.value, ctx, e)) end
        local x = param(e.value, "value")
        if not x then return false end
        return compare(v, x.op, eval.value(x.value, ctx, x))
    end
    -- a CFixedPoint as the game keeps it (five decimals)
    local function fixed(v)
        local n = tonumber(v) or 0
        return floor(n * 100000 + 0.5) / 100000
    end
    -- a numeric trigger on the country scope: value(id, block) -> number; also a trigger value
    -- (`value = trigger:<k>`)
    local function country_value(k, value)
        TRIG[k] = function(e, ctx)
            local id, c = this_country(ctx)
            if not id then return false end
            sync()
            return compare_value(value(id, c), e, ctx)
        end
        if eval.TVAL then
            eval.TVAL[k] = function(ctx)
                local id, c = this_country(ctx)
                if not id then return 0 end
                sync()
                return value(id, c) or 0
            end
        end
    end
    -- a yes/no field of the country (`has_advisor = yes`)
    local function country_bool(c, key)
        return world.field(c, key) == "yes"
    end
    -- `key = "text"`: a quoted string (the parser keeps the text without its quotes)
    local function set_quoted(obj, key, text)
        world.set(obj, key, text)
        local t = world.token_entry(obj, key)
        if t then t.value.quoted = true end
    end
    local function set_meta(key, value)
        world.set(world.tree, key, value)
        world.meta[key] = world.field(world.tree, key)
    end
    -- the save's top-level block `key = { }`, made when it is not there
    local function meta_block(key)
        local b = world.meta[key]
        if type(b) == "table" then return b end
        b = world.child(world.tree, key)
        world.meta[key] = b
        return b
    end
    local function defines(group, key, default)
        local ok, defs = pcall(require, "engine.defs")
        local g = ok and defs.get and defs.get("common/defines", group)
        return g and tonumber(defs.field(g.block, key)) or default
    end
    local function def_of(folder, name)
        local ok, defs = pcall(require, "engine.defs")
        local d = ok and defs.get and name and defs.get(folder, name)
        return d, ok and defs or nil
    end

    -- ------------------------------------------------------------------------------------------
    -- scope links (scopes.log)

    -- the from chain past fromfrom (the ROOT of three and four events ago): the from records an
    -- event's scope keeps (CEventScope's from scopes, trimmed to 7: simscript.events from_record),
    -- the first being from [V: CEventScope::TrimFroms]
    local function from_record(ctx)
        local c = ctx
        while c do
            if c.from_rec then return c.from_rec end
            c = c.same or c.up
        end
        return nil
    end
    local function from_n(n)
        return function(_, ctx)
            if n == 3 and ctx.fromfromfrom then return ctx.fromfromfrom end
            if n == 4 and ctx.fromfromfromfrom then return ctx.fromfromfromfrom end
            local rec = from_record(ctx)
            for _ = 2, n do rec = rec and rec.from_rec end
            return rec and rec.this or NONE
        end
    end
    LINKS["fromfromfrom"] = from_n(3)
    LINKS["fromfromfromfrom"] = from_n(4)

    -- galactic_custodian / galactic_emperor: the galactic community's `leader`
    -- (CGalacticCommunity +0x178), the emperor when `empire = yes` (its flag +0x33c & 4), the
    -- custodian otherwise (CGalacticCommunity::SetCustodian 0x25db010 / SetEmperor 0x25db0d0) [V]
    local function gc_leader()
        local gc = world.meta and world.meta.galactic_community
        if type(gc) ~= "table" then return nil, false end
        local l = tonumber(world.field(gc, "leader"))
        if l == nil or l == NO_ID or not world.object("country", l) then return nil, false end
        return l, world.field(gc, "empire") == "yes"
    end
    LINKS["galactic_custodian"] = function()
        local l, empire = gc_leader()
        return (l and not empire) and S("country", l) or nil
    end
    LINKS["galactic_emperor"] = function()
        local l, empire = gc_leader()
        return (l and empire) and S("country", l) or nil
    end
    -- last_created_country: this context's create_country, else the game's (the save's
    -- `last_created_country`)
    LINKS["last_created_country"] = function(_, ctx)
        local h = ctx.created and ctx.created.country
        if h then
            sync()
            local id = E.resolve and E.resolve(h)
            if id then return S("country", id) end
        end
        local id = tonumber(world.meta and world.meta.last_created_country)
        return (id and world.object("country", id)) and S("country", id) or nil
    end
    -- no_scope: the empty scope
    LINKS["no_scope"] = function() return NONE end

    -- ------------------------------------------------------------------------------------------
    -- control flow and tooltips

    local TOOLTIP = { text = true, fail_text = true, success_text = true }
    -- the triggers of a tooltip wrapper hold as their AND; the texts are its parameters
    TRIG["custom_tooltip_icon"] = function(e, ctx)
        if e.value.text then return true end
        return eval.trigger(e.value, ctx, TOOLTIP)
    end
    TRIG["custom_tooltip_success"] = TRIG["custom_tooltip_icon"]
    -- fail_text / success_text = { text = <text> <triggers> } (desc = { trigger = { } }): the
    -- triggers' AND
    TRIG["fail_text"] = TRIG["custom_tooltip_icon"]
    TRIG["success_text"] = TRIG["custom_tooltip_icon"]
    -- text = <text>: only a text (true)
    TRIG["text"] = function() return true end
    -- hidden_progress / simple_progress = { <triggers> }: their AND (only the progress shown changes)
    TRIG["hidden_progress"] = function(e, ctx)
        if e.value.text then return true end
        return eval.trigger(e.value, ctx)
    end
    TRIG["simple_progress"] = TRIG["hidden_progress"]
    -- custom_progress = { <triggers> current_val_coeff final_val_coeff mode }
    local PROGRESS = { current_val_coeff = true, final_val_coeff = true, mode = true }
    TRIG["custom_progress"] = function(e, ctx)
        if e.value.text then return true end
        return eval.trigger(e.value, ctx, PROGRESS)
    end
    -- conditional_tooltip = { trigger = { <condition> } <triggers> }: the triggers are ignored (true)
    -- unless the condition holds
    local CONDITION = { trigger = true }
    TRIG["conditional_tooltip"] = function(e, ctx)
        if e.value.text then return true end
        local cond = param(e.value, "trigger")
        if cond and cond.value.text == nil and not eval.trigger(cond.value, ctx) then return true end
        return eval.trigger(e.value, ctx, CONDITION)
    end
    -- inverted_switch = { trigger = <key> <value> = { } default = { } }: NOT of the switch's case
    TRIG["inverted_switch"] = function(e, ctx)
        local sw = TRIG["switch"]
        if not sw then
            miss("trigger", "switch", ctx, e)
            return false
        end
        return not sw(e, ctx, "switch")
    end
    -- log = <text> (CLogTrigger 0x3bc6e90): a line in game.log; true [I: the line written, the
    -- result the trigger's own]
    TRIG["log"] = function() return true end
    -- debug_break = yes (CDebugBreakTrigger 0x3bd2360): breaks into a debugger when cheats allow;
    -- the value it is given [V docs]
    TRIG["debug_break"] = function(e) return yes(e) end
    -- logged_in_to_pdx_account (CLoggedInToPdxAccountTrigger 0x3bb9b00): the local human's Paradox
    -- account; a headless game has none [I]
    TRIG["logged_in_to_pdx_account"] = function(e) return not yes(e) end
    -- local_has_dlc: the local player's DLCs, the host's in a game of one [I]
    TRIG["local_has_dlc"] = function(e, ctx)
        local h = TRIG["host_has_dlc"]
        return h and h(e, ctx, "host_has_dlc") or false
    end

    -- break = yes (CBreakEffect::ExecuteActual 0x372a8a0: the scope's +0x168 set): CEffect's
    -- collection (CEffect::ExecuteActual 0x24f7bf0) stops after any statement that leaves it set,
    -- so the rest of the scope's statements are skipped, the blocks that hold the if as well; a
    -- scope change makes a new scope [V]. eval.effect stops on ctx.broke (eval.broke)
    EFF["break"] = function(e, ctx)
        if e.value.text == "no" then return end
        eval.set_broke(ctx)
    end
    -- debug_break: breaks into a debugger; nothing in the game [V docs]
    EFF["debug_break"] = function() end
    -- reroll_random = yes (CRerollRandomEffect::ExecuteActual 0x370ff70): a draw of the game's
    -- generator (CRandom::GetIntegerForMacro) seeds the scope's random position
    -- (CCrudeRandom::Seed: +0x68 = H(draw)) [V]
    EFF["reroll_random"] = function(e, ctx)
        if e.value.text == "no" or not eval.scope_rng then return end
        local SR = require("engine.script.scope_random")
        local r = eval.scope_rng(ctx)
        r.pos = SR.H(eval.rand())
        script_write()
    end
    -- fire_on_action = { on_action = <name> scopes = { from = X fromfrom = Y } } (CFireOnActionEffect
    -- 0x36da340: COnActionDatabase::PerformEvent in a new scope whose from scopes are the given
    -- ones) [V calls]; without scopes the on_action's from is the firing scope (as before) [I]
    EFF["fire_on_action"] = function(e, ctx)
        local name, scopes
        if e.value.text then name = e.value.text else
            name = param_text(e.value, "on_action")
            local sx = param(e.value, "scopes")
            scopes = sx and sx.value.text == nil and sx.value or nil
        end
        if not name or not eval.on_action then return end
        local from_ctx = ctx
        if scopes then
            local f = target_scope(param_text(scopes, "from"), ctx, e)
            local ff = target_scope(param_text(scopes, "fromfrom"), ctx, e)
            from_ctx = { this = f or ctx.this, from = ff or ctx.from, targets = ctx.targets }
        end
        eval.on_action(name, ctx.this, from_ctx)
    end
    -- the tooltip-only effects: their text is shown, nothing changes [V docs]
    EFF["custom_tooltip_with_params"] = function() end
    -- country_list_tooltip = { limit = { } }: a list of the countries that match, in a tooltip
    EFF["country_list_tooltip"] = function() end
    -- effects of the interface and the platform: a sound, the Shroud tab, telemetry events, the
    -- tutorial's steps; nothing of the game's state [I]
    EFF["play_sound"] = function() end
    EFF["open_shroud_tab"] = function() end
    EFF["complete_tutorial_step"] = function() end
    EFF["endgame_telemetry"] = function() end
    -- set_update_modifiers_batch = begin / end: the modifier system's full updates held between
    -- the two, done at the end (the modifiers here are updated at their barriers, so nothing is
    -- held) [I]
    EFF["set_update_modifiers_batch"] = function(e)
        local v = e.value.text
        if v == "begin" then state.modifier_batch = true elseif v == "end" then state.modifier_batch = nil end
        script_write()
    end

    -- ------------------------------------------------------------------------------------------
    -- the galaxy's setup (the save's `galaxy = { }`, `galaxy_radius`)

    local function galaxy() local g = world.meta and world.meta.galaxy return type(g) == "table" and g or nil end
    -- galaxy_shape = <shape> (CGalaxyShapeTrigger 0x3be75e0: the game state's setup +0x998) [V]
    TRIG["galaxy_shape"] = function(e)
        local g = galaxy()
        return g ~= nil and tostring(world.field(g, "shape")) == e.value.text
    end
    -- galaxy_radius <op> n: the radius the map was made with
    TRIG["galaxy_radius"] = function(e, ctx)
        local r = tonumber(world.meta and world.meta.galaxy_radius)
        return r ~= nil and compare(r, e.op, eval.value(e.value, ctx, e))
    end
    -- is_crises_allowed = yes (CIsCrisesAllowedTrigger 0x3baa390: the setup's crisis strength
    -- above 0) [V setup; I the comparison]
    TRIG["is_crises_allowed"] = function(e)
        local g = galaxy()
        local c = g and tonumber(world.field(g, "crises")) or 0
        return (c > 0) == yes(e)
    end
    -- caravaneers_enabled = yes: the setup's `caravaneers_enabled`
    TRIG["caravaneers_enabled"] = function(e)
        local g = galaxy()
        return (g ~= nil and world.field(g, "caravaneers_enabled") == "yes") == yes(e)
    end
    -- voidworms_scaling / cutholoids_scaling <op> n: the setup's presence scaling
    for _, k in ipairs({ "voidworms_scaling", "cutholoids_scaling" }) do
        TRIG[k] = function(e, ctx)
            local g = galaxy()
            local v = g and tonumber(world.field(g, k))
            if v == nil then return false end
            if e.value.text == "yes" or e.value.text == "no" then return (v > 0) == yes(e) end
            return compare(v, e.op, eval.value(e.value, ctx, e))
        end
    end
    -- is_difficulty as a value (complex_trigger_modifier: CIsDifficultyTrigger::GetTriggerValue
    -- 0x3b81230, the setup's EDifficulty at +0xa0): the level's number, civilian 0 to grand admiral
    -- 6 [V]
    local DIFFICULTY = { civilian = 0, cadet = 1, ensign = 2, captain = 3, commodore = 4, admiral = 5, grand_admiral = 6 }
    eval.TVAL["is_difficulty"] = function()
        local g = galaxy()
        return g and DIFFICULTY[(tostring(world.field(g, "difficulty")):gsub('"', ""))] or nil
    end
    -- date_distortion = yes/no (CSetDateDistortionEffect 0x37c7f30): the game state's
    -- `date_distortion` (CGameState::WriteMembers) [V]
    EFF["date_distortion"] = function(e)
        local v = e.value.text
        if v ~= "yes" and v ~= "no" then return end
        set_meta("date_distortion", v)
    end

    -- ------------------------------------------------------------------------------------------
    -- the galactic community: custodian, emperor, defense force, emergency fund
    -- (`galactic_community = { leader empire custodian_term imperial_authority
    -- galactic_defense_force emergency_fund = { balance contribution_rate is_active } }`:
    -- CGalacticCommunity::WriteMembers 0x25cf220) [V names]

    local function gc_block() return meta_block("galactic_community") end
    local function gc_unset_leader(gc)
        world.set(gc, "leader", NO_ID)
        local e = world.entry(gc, "empire")
        if e then world.remove_entry(gc, e) end
    end
    -- set_galactic_custodian = yes/no (CSetGalacticCustodianEffect 0x3800bd0): yes makes the
    -- country the custodian (SetCustodian: the emperor unset, `leader`, the term set to
    -- CUSTODIAN_TERM_LIMIT_DAYS); no unsets it when it is the custodian [V]
    EFF["set_galactic_custodian"] = function(e, ctx)
        local id = this_country(ctx)
        if not id then return end
        local gc = gc_block()
        if yes(e) then
            gc_unset_leader(gc)
            world.set(gc, "leader", id)
            world.set(gc, "custodian_term", defines("NGameplay", "CUSTODIAN_TERM_LIMIT_DAYS", 10800))
        else
            local l, empire = gc_leader()
            if l == id and not empire then gc_unset_leader(gc) end
        end
    end
    -- set_galactic_emperor = yes/no (CSetGalacticEmperorEffect 0x3800d20, SetEmperor): `leader`,
    -- `empire = yes`, the imperial authority at GALACTIC_EMPIRE_BASE_AUTHORITY; no unsets the
    -- emperor when it is this country [V]
    EFF["set_galactic_emperor"] = function(e, ctx)
        local id = this_country(ctx)
        if not id then return end
        local gc = gc_block()
        if yes(e) then
            world.set(gc, "leader", id)
            world.set(gc, "empire", "yes")
            world.set(gc, "imperial_authority", defines("NGameplay", "GALACTIC_EMPIRE_BASE_AUTHORITY", 100))
        else
            local l, empire = gc_leader()
            if l == id and empire then gc_unset_leader(gc) end
        end
    end
    -- add_custodian_term_days / set_custodian_term_days = <days> (CAddCustodianTermDaysEffect
    -- 0x38014c0, CSetCustodianTermDaysEffect 0x38015d0): the custodian's term (+0x2c8); a negative
    -- result is -1, a permanent term (AddDaysToCurrentCustodianTerm, SetCurrentCustodianTermDays);
    -- an error without a custodian [V]
    local function custodian_term(e, ctx, add)
        local l, empire = gc_leader()
        if not l or empire then return end
        local gc = gc_block()
        local n = floor(eval.value(e.value, ctx, e))
        local cur = tonumber(world.field(gc, "custodian_term")) or 0
        local v = add and cur + n or n
        if v < 0 then v = -1 end
        world.set(gc, "custodian_term", v)
    end
    EFF["add_custodian_term_days"] = function(e, ctx) custodian_term(e, ctx, true) end
    EFF["set_custodian_term_days"] = function(e, ctx) custodian_term(e, ctx, false) end
    -- set_galactic_defense_force = yes/no: the Galactic Defense Force (or Imperial Armada) made or
    -- disbanded (CGalacticCommunity::CreateDefenseForce / DisbandDefenseForce; the save's
    -- `galactic_defense_force = { }`) [V names; I the block's content]
    EFF["set_galactic_defense_force"] = function(e)
        local gc = gc_block()
        local cur = world.entry(gc, "galactic_defense_force")
        if yes(e) then
            if not cur then
                local b = world.child(gc, "galactic_defense_force")
                local l = gc_leader()
                if l then world.set(b, "owner", l) end
            end
        elseif cur then
            world.remove_entry(gc, cur)
        end
    end
    -- galactic_defense_force_exists = yes (CGalacticDefenseForceExistsTrigger 0x3c22c20:
    -- CGalacticCommunity::HasDefenseForce) [V]
    TRIG["galactic_defense_force_exists"] = function(e)
        local gc = world.meta and world.meta.galactic_community
        local has = type(gc) == "table" and world.entry(gc, "galactic_defense_force") ~= nil
        return has == yes(e)
    end
    -- set_emergency_fund_active = yes/no, set_emergency_fund_contribution_rate = <n>
    -- (CSetEmergencyFundActiveEffect 0x37e68b0, CSetEmergencyFundContributionRateEffect 0x37e7800:
    -- the community's fund, +0x2d0) [V]
    local function fund() return world.child(gc_block(), "emergency_fund") end
    EFF["set_emergency_fund_active"] = function(e)
        local v = e.value.text
        if v ~= "yes" and v ~= "no" then return end
        world.set(fund(), "is_active", v)
    end
    EFF["set_emergency_fund_contribution_rate"] = function(e, ctx)
        world.set(fund(), "contribution_rate", fixed(eval.value(e.value, ctx, e)))
    end

    -- ------------------------------------------------------------------------------------------
    -- the country's own fields

    -- is_country = <target> (CIsCountryTrigger 0x3b805e0): the scope's country is the target [V]
    TRIG["is_country"] = function(e, ctx)
        local id = this_country(ctx)
        local t = target_country(e.value.text, ctx, e)
        return id ~= nil and id == t
    end
    -- has_same_ethos = <target> (CHasSameEthosTrigger 0x3b39330: CEthos::operator==): the same set
    -- of ethics [V]
    local function ethics_of(c)
        local set, n = {}, 0
        for _, v in ipairs(world.list(world.field(world.field(c, "ethos"), "ethics"))) do
            if not set[v] then set[v] = true; n = n + 1 end
        end
        return set, n
    end
    TRIG["has_same_ethos"] = function(e, ctx)
        local id, c = this_country(ctx)
        local t = target_country(e.value.text, ctx, e)
        if not id or not t then return false end
        local a, na = ethics_of(c)
        local b, nb = ethics_of(world.object("country", t))
        if na ~= nb then return false end
        for k in pairs(a) do if not b[k] then return false end end
        return true
    end

    -- set_adjective = <text> (CSetAdjectiveEffect 0x371aca0): the country's adjective, a key or a
    -- target's adjective (CEventScope::GetObjectAdjectivePersistent) [V]; written as the save's
    -- `adjective = { key = <text> }`
    local function name_block(key)
        return { { key = { text = "key" }, op = "=", value = { text = key, quoted = true } } }
    end
    EFF["set_adjective"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not id or not e.value.text then return end
        local key = e.value.text
        local t = target_scope(key, ctx, e)
        local entry = world.entry(c, "adjective")
        if t and t.kind == "country" then
            local tc = world.object("country", t.id)
            local adj = tc and world.field(tc, "adjective")
            if type(adj) == "table" then
                local copy = require("pdxscript").parse(require("pdxscript").write(adj), "adjective")
                if entry then world.set_entry(c, entry, copy) else world.append(c, "adjective", copy) end
                return
            end
        end
        if entry then world.set_entry(c, entry, name_block(key)) else world.append(c, "adjective", name_block(key)) end
    end
    -- set_city_graphical_culture = <key> (CSetCityGraphicalCultureEffect 0x3717fa0): the country's
    -- `city_graphical_culture` [V]
    EFF["set_city_graphical_culture"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not id or not e.value.text then return end
        set_quoted(c, "city_graphical_culture", e.value.text)
    end
    -- city_graphical_culture = <key / target> (CCityGraphicalCultureTrigger 0x3b8f8b0): the
    -- country's city culture is the key, or the target country's [V]
    local function unq(v) return v and (tostring(v):gsub('"', "")) or nil end
    TRIG["city_graphical_culture"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not id or not e.value.text then return false end
        local mine = unq(world.field(c, "city_graphical_culture"))
        local t = target_country(e.value.text, ctx, e)
        if t then return mine == unq(world.field(world.object("country", t), "city_graphical_culture")) end
        return mine == e.value.text
    end
    -- change_country_flag = random / { icon background colors } (CChangeCountryFlagEffect
    -- 0x376ace0: CCountry::RandomizeFlag, CCountry::SetEmpireFlag) [V]; the save's `flag = { }`.
    -- random (CCountry::RandomizeFlag 0x2341300): one draw of the game's generator seeds a crude
    -- random (CCrudeRandom(seed): the scope random's new(seed)), then CEmpireFlag::Randomize
    -- (0x19edf40) draws the symbol (GetRandomSymbolTexture: one of the flag database's symbols, those
    -- other countries use left out while any is free), the background (a category, then a texture
    -- of it) and the colour combination (GetRandomColorCombination: flags/colors.txt's
    -- randomizable_combo, a primary colour not yet used kept while any is free; the primary then
    -- registered as used) [V the draws' order; I the lists' order: the files by name, the combos in
    -- file order]
    local flag_db
    local function flags()
        if flag_db then return flag_db end
        flag_db = { symbols = {}, backgrounds = {}, combos = {} }
        local db = I.db
        local dir = db and db.game_dir
        if RUST and RUST.list_files and dir then
            local files = RUST.list_files(dir, "flags", "dds")
            table.sort(files)
            for _, f in ipairs(files) do
                local cat, file = f:match("^flags/([^/]+)/([^/]+)$")
                if cat == "backgrounds" then
                    flag_db.backgrounds[#flag_db.backgrounds + 1] = { cat, file }
                elseif cat then
                    flag_db.symbols[#flag_db.symbols + 1] = { cat, file }
                end
            end
            local text = db.read_file(dir .. "/flags/colors.txt")
            local tree = text and require("pdxscript").parse(text, "flags/colors.txt")
            local function walk(b)
                for _, x in ipairs(b or {}) do
                    if x.op and x.key and x.key.text == "randomizable_combo" and x.value.text == nil then
                        local l = {}
                        for _, v in ipairs(x.value) do if v.text then l[#l + 1] = v.text end end
                        flag_db.combos[#flag_db.combos + 1] = l
                    elseif x.op and type(x.value) == "table" and x.value.text == nil then
                        walk(x.value)
                    end
                end
            end
            walk(tree)
        end
        return flag_db
    end
    local function random_flag(id, c)
        local SR = require("engine.script.scope_random")
        local fdb = flags()
        if #fdb.symbols == 0 or #fdb.backgrounds == 0 then return false end
        local r = SR.new(eval.rand())
        -- the symbols other countries use
        local used = {}
        for _, cid in ipairs(world.all("country")) do
            local o = cid ~= id and world.object("country", cid)
            local icon = o and world.path(o, "flag", "icon")
            if type(icon) == "table" then used[tostring(world.field(icon, "file"))] = true end
        end
        local free = {}
        for _, s in ipairs(fdb.symbols) do if not used[s[2]] then free[#free + 1] = s end end
        if #free == 0 then free = fdb.symbols end
        local sym = free[SR.draw(r) % #free + 1]
        local _ = SR.draw(r) % 1   -- the background category (one: `backgrounds`)
        local bg = fdb.backgrounds[SR.draw(r) % #fdb.backgrounds + 1]
        local combo
        if #fdb.combos > 0 then
            local usedc = {}
            for _, v in ipairs(world.fields(world.tree, "used_color")) do usedc[tostring(v)] = true end
            local fc = {}
            for _, k in ipairs(fdb.combos) do if not usedc[k[1]] then fc[#fc + 1] = k end end
            if #fc == 0 then fc = fdb.combos end
            combo = fc[SR.draw(r) % #fc + 1]
        end
        local flag = world.child(c, "flag")
        for part, v in pairs({ icon = sym, background = bg }) do
            local b = world.child(flag, part)
            set_quoted(b, "category", v[1])
            set_quoted(b, "file", v[2])
        end
        if combo then
            local list = {}
            for _, k in ipairs(combo) do list[#list + 1] = { text = k, quoted = true } end
            local entry = world.entry(flag, "colors")
            if entry then world.set_entry(flag, entry, list) else world.append(flag, "colors", list) end
            -- CGameState::RegisterUsedBorderColor: the primary among the save's `used_color`
            local have = false
            for _, v in ipairs(world.fields(world.tree, "used_color")) do if tostring(v) == combo[1] then have = true end end
            if not have then world.append(world.tree, "used_color", combo[1], true) end
        end
        return true
    end
    EFF["change_country_flag"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not id then return end
        if e.value.text then
            if e.value.text == "random" then random_flag(id, c) end
            return
        end
        local flag = world.child(c, "flag")
        for _, part in ipairs({ "icon", "background" }) do
            local x = param(e.value, part)
            if x and x.value.text == nil then
                local b = world.child(flag, part)
                for _, k in ipairs({ "category", "file" }) do
                    local v = param_text(x.value, k)
                    if v then set_quoted(b, k, v) end
                end
            end
        end
        local cx = param(e.value, "colors")
        if cx and cx.value.text == nil then
            local list = {}
            for _, v in ipairs(cx.value) do
                if v.text then list[#list + 1] = { text = v.text, quoted = true } end
            end
            local entry = world.entry(flag, "colors")
            if entry then world.set_entry(flag, entry, list) else world.append(flag, "colors", list) end
        end
    end

    -- the AI's ship design preferences (SShipDesignPreferences: the save's
    -- `ai_<x>_override` fields; CSetCountryRatioEffect / CClearCountryPreferenceEffect 0x3763830
    -- 0x3763a40: CCountry::AccessShipDesignPreferences) [V]
    local PREF = {
        set_ai_armor_ratio = { "ai_armor_ratio_override", true },
        set_ai_shields_ratio = { "ai_shields_ratio_override", true },
        set_ai_weapon_preference = { "ai_weapon_preference_override", false },
        set_ai_platform_armor_ratio = { "ai_platform_armor_ratio_override", true },
        set_ai_platform_shields_ratio = { "ai_platform_shields_ratio_override", true },
        set_ai_platform_weapon_preference = { "ai_platform_weapon_preference_override", false },
    }
    for k, spec in pairs(PREF) do
        local field, ratio = spec[1], spec[2]
        EFF[k] = function(e, ctx)
            local id, c = this_country(ctx)
            if not id then return end
            if ratio then
                world.set(c, field, fixed(eval.value(e.value, ctx, e)))
            elseif e.value.text then
                set_quoted(c, field, e.value.text)
            end
        end
        EFF["clear_" .. k:sub(5)] = function(e, ctx)
            local id, c = this_country(ctx)
            if not id or e.value.text == "no" then return end
            local entry = world.entry(c, field)
            if entry then world.remove_entry(c, entry) end
        end
    end
    -- ai_armor_ratio / ai_shields_ratio <op> n (CAiArmorRatioTrigger::GetTriggerValue 0x3bea940:
    -- SShipDesignPreferences::GetEffectiveArmorRatio(personality)): the override, else the
    -- personality's `armor_ratio` [V]
    local function personality_field(c, key)
        local d, defs = def_of("common/personalities", unq(world.field(c, "personality")))
        return d and tonumber(defs.field(d.block, key)) or nil
    end
    country_value("ai_armor_ratio", function(_, c)
        return tonumber(world.field(c, "ai_armor_ratio_override")) or personality_field(c, "armor_ratio") or 0
    end)
    country_value("ai_shields_ratio", function(_, c)
        return tonumber(world.field(c, "ai_shields_ratio_override")) or personality_field(c, "shields_ratio") or 0
    end)
    -- is_preferred_platform_weapons = <weapon type>: the platforms' override, else the empire-wide
    -- override, else the personality's weapon_preferences [V docs]
    TRIG["is_preferred_platform_weapons"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not id or not e.value.text then return false end
        local w = unq(world.field(c, "ai_platform_weapon_preference_override"))
            or unq(world.field(c, "ai_weapon_preference_override"))
        if not w then
            local d, defs = def_of("common/personalities", unq(world.field(c, "personality")))
            w = d and defs.field(d.block, "weapon_preferences")
        end
        return w == e.value.text
    end
    -- set_ai_personality = <personality> (CSetAIPersonalityEffect 0x37a10c0: CCountry::ForcePersonality):
    -- the country's `personality` [V]
    EFF["set_ai_personality"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not id or not e.value.text then return end
        if not def_of("common/personalities", e.value.text) then
            miss("personality", e.value.text, ctx, e)
            return
        end
        set_quoted(c, "personality", e.value.text)
    end

    -- set_advisor_active = yes/no, is_advisor_active = yes (CAdvisorActiveEffect 0x37294b0,
    -- CHasAdvisorTrigger 0x3b7ad50: the country's +0x2a40, the save's `has_advisor`) [V]
    EFF["set_advisor_active"] = function(e, ctx)
        local id, c = this_country(ctx)
        local v = e.value.text
        if not id or (v ~= "yes" and v ~= "no") then return end
        world.set(c, "has_advisor", v)
    end
    TRIG["is_advisor_active"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not id then return false end
        return country_bool(c, "has_advisor") == yes(e)
    end
    -- set_country_code_flags = { <flag> = yes/no ... }: the country's code flags, written as the
    -- save's `<flag> = yes/no` (has_advisor, initialized, ...) [I]
    local CODE_FLAGS = {}
    for _, k in ipairs({ "colonizer", "rebel", "track_all_situations", "custom_name", "is_in_breach_of_any",
        "has_advisor", "autopick_leader_traits", "crisis_fighter", "is_under_crisis_attack", "initialized",
        "is_affected_by_war_exhaustion", "is_nomadic", "killed" }) do
        CODE_FLAGS[k] = true
    end
    EFF["set_country_code_flags"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not id or e.value.text then return end
        for _, x in ipairs(e.value) do
            if x.op and x.key then
                local k = x.key.text:lower()
                local v = x.value.text
                if CODE_FLAGS[k] and (v == "yes" or v == "no") then
                    world.set(c, k, v)
                elseif not CODE_FLAGS[k] then
                    miss("country code flag", k, ctx, x)
                end
            end
        end
    end
    -- set_tutorial_level = 0/1/2 (CSetTutorialLevelEffect 0x372aaf0: CCountry::SetTutorialLevel,
    -- the primary human's setting, not the country's or the save's): kept in the script state for
    -- is_tutorial_level [V]
    EFF["set_tutorial_level"] = function(e, ctx)
        local id = this_country(ctx)
        if not id then return end
        local player = tonumber(world.meta and type(world.meta.player) == "table"
            and world.field(world.blocks(world.meta.player)[1], "country"))
        if player ~= id then return end
        state.tutorial_level = floor(eval.value(e.value, ctx, e))
        script_write()
    end
    TRIG["is_tutorial_level"] = function(e, ctx)
        return compare(state.tutorial_level or 0, e.op, eval.value(e.value, ctx, e))
    end

    -- add_victory_score = { source = <key> score = <n> } (CAddVictoryScoreEffect 0x37e8d60:
    -- CCountry::AddVictoryScoreFromEffect): the country's `victory_score`, and the source's part in
    -- `score_from_effects` [V names; I the block's form]
    EFF["add_victory_score"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not id or e.value.text then return end
        local sx = param(e.value, "score")
        if not sx then return end
        local n = eval.value(sx.value, ctx, sx)
        world.set(c, "victory_score", fixed((tonumber(world.field(c, "victory_score")) or 0) + n))
        local src = param_text(e.value, "source")
        if src then
            local b = world.child(c, "score_from_effects")
            world.set(b, src, fixed((tonumber(world.field(b, src)) or 0) + n))
        end
    end
    -- win = yes (CWinGameEffect 0x371fa30: CGameState::EndGame), won_the_game = yes
    -- (CWonTheGameTrigger 0x3bc8fb0: CGameState::GetWinner): the save's `winner` [V]
    EFF["win"] = function(e, ctx)
        local id = this_country(ctx)
        if not id or e.value.text == "no" then return end
        set_meta("winner", id)
    end
    TRIG["won_the_game"] = function(e, ctx)
        local id = this_country(ctx)
        local w = tonumber(world.meta and world.meta.winner)
        return (id ~= nil and w == id) == yes(e)
    end

    -- the energy budget of last month (CCountryBudget's last month: the save's
    -- `budget = { last_month = { income expenses balance } }`): balance and running_balance read
    -- its balance sum (CCountryBudget::CalcLastMonthsBalance / CalcLastMonthsRunningBalance
    -- 0x2409fa0 0x2409fd0: the same sum, +0x690), expenses its expense sum (0x2409f70, +0x670),
    -- of the first strategic resource (energy) [V]
    local function last_month(c, part)
        local b = world.path(c, "budget", "last_month", part)
        local sum = 0
        for _, v in world.statements(type(b) == "table" and b or {}) do
            if type(v) == "table" then sum = sum + (tonumber(world.field(v, "energy")) or 0) end
        end
        return sum
    end
    country_value("balance", function(_, c) return last_month(c, "balance") end)
    country_value("running_balance", function(_, c) return last_month(c, "balance") end)
    country_value("expenses", function(_, c) return last_month(c, "expenses") end)
    -- stored_physics_points / stored_society_points / stored_engineering_points: the research
    -- stored by area (`tech_status = { stored_techpoints = { <physics> <society> <engineering> } }`)
    -- [I: the areas' order]
    for i, area in ipairs({ "physics", "society", "engineering" }) do
        country_value("stored_" .. area .. "_points", function(_, c)
            local l = world.list(world.path(c, "tech_status", "stored_techpoints"))
            return tonumber(l[i]) or 0
        end)
    end
    -- command_limit <op> n (CCommandLimitTrigger 0x3bbe4b0: CCountry::CalcCommandLimit): the
    -- country_command_limit modifiers' sum [V]
    country_value("command_limit", function(id)
        if not E.modifier then return 0 end
        local add = E.modifier("country", id, "country_command_limit_add") or 0
        local mult = E.modifier("country", id, "country_command_limit_mult") or 0
        return floor(add * (1 + mult))
    end)

    -- set_visited = <system> (CSetVisitedEffect 0x371f540: CCountry::HasVisited, AddVisited): the
    -- system in the country's `visited_objects` [V]
    EFF["set_visited"] = function(e, ctx)
        local id, c = this_country(ctx)
        local t = target_scope(e.value.text, ctx, e)
        if not id or not t then return end
        local sys = t.kind == "system" and t.id or (E.system_of and E.system_of(t.kind, t.id))
        if not sys then return end
        local list = world.child(c, "visited_objects")
        for _, v in ipairs(world.list(list)) do
            if tonumber(v) == sys then return end
        end
        world.push(list, tostring(sys))
    end
    -- reset_years_of_peace = yes: the country's years of peace counted from today (CYearsOfPeaceTrigger:
    -- from `last_date_at_war`) [I]
    EFF["reset_years_of_peace"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not id or e.value.text == "no" then return end
        local d = eval.today()
        local y, m = floor(d / 360), floor((d % 360) / 30)
        set_quoted(c, "last_date_at_war", string.format("%d.%02d.%02d", y, m + 1, d % 30 + 1))
    end

    -- the systems of the later DLCs and the relations' keywords (handlers/general_systems.lua)
    require("simscript.handlers.general_systems")(eval, {
        this_country = this_country, param = param, param_text = param_text, target_scope = target_scope,
        target_country = target_country, compare_value = compare_value, fixed = fixed,
        country_value = country_value, set_quoted = set_quoted, set_meta = set_meta, meta_block = meta_block,
        defines = defines, def_of = def_of, unq = unq, script_write = script_write, name_block = name_block,
    })
end
