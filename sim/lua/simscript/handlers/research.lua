-- simscript/handlers/research.lua : the research package of the script coverage
-- (docs/script_research.md): technologies (options, progress, copying, the queues), traditions and
-- ascension perks, the planetary ascension tiers, the crisis (ambitions: crisis progression,
-- strength, sound) and the research-side readings of the council, the patrons' accords and the
-- research stations.
--
-- Each keyword names its class in the Linux 4.5.2 build with [V] (read in the binary:
-- /opt/stellaris-headless/re on 10.5.0.24) or [I] (inferred from the game's script documentation and
-- the save's fields). The world is the save (engine.world): a handler writes the fields the game
-- writes (the classes' WriteMembers names), so a save written after it has the change.

return function(eval)
    local I = eval._internal
    local S, NONE, compare, sync = I.S, I.NONE, I.compare, I.sync
    local stats = I.stats
    local TRIG, EFF, LINKS = eval.TRIG, eval.EFF, eval.LINKS
    local world = require("engine.world")
    local floor = math.floor
    local NO_ID = 4294967295
    local AREAS = { "physics", "society", "engineering" }

    -- ------------------------------------------------------------------------------------------
    -- helpers

    local function written() stats.script = stats.script + 1 end
    local function defs() return require("engine.defs") end
    local function research() return require("engine.research") end
    local function traditions() return require("engine.traditions") end
    local function unq(v)
        if type(v) ~= "string" then return v end
        return (v:gsub('^"(.*)"$', "%1"))
    end
    local function ref(v)
        local n = tonumber(unq(v))
        if not n or n == NO_ID then return nil end
        return n
    end
    local function this_country(ctx)
        local sc = ctx.this
        if not sc or sc == NONE or sc.kind ~= "country" then return nil end
        local c = world.object("country", sc.id)
        if not c then return nil end
        return sc.id, c
    end
    local function param(block, key)
        if type(block) ~= "table" or block.text then return nil end
        for _, x in ipairs(block) do
            if x.op and x.key and x.key.text:lower() == key then return x end
        end
        return nil
    end
    local function param_text(block, key)
        local x = param(block, key)
        return x and x.value.text and unq(x.value.text) or nil
    end
    local function param_num(block, key, ctx)
        local x = param(block, key)
        if not x then return nil end
        return eval.value(x.value, ctx, x)
    end
    local function param_list(block, key)
        local x = param(block, key)
        local out = {}
        if x and type(x.value) == "table" and x.value.text == nil then
            for _, v in ipairs(x.value) do
                if v.text then out[#out + 1] = unq(v.text) end
            end
        elseif x and x.value.text then
            out[1] = unq(x.value.text)
        end
        return out
    end
    local function yes_no(e) return e.value.text ~= "no" end
    -- the country a statement names (`target = FROM`, `who = root`)
    local function target_country(text, ctx, e)
        if not text then return nil end
        local found, sc = eval.resolve(text, ctx, e)
        if not found or not sc or sc == NONE then return nil end
        if sc.kind == "country" and world.object("country", sc.id) then return sc.id end
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
    -- a numeric trigger of the country scope, also a trigger value (`value = trigger:<k>`)
    local function country_value(k, value)
        TRIG[k] = function(e, ctx)
            local id, c = this_country(ctx)
            if not id then return false end
            sync()
            return compare_value(value(id, c, e, ctx), e, ctx)
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
    local function fixed(v)
        local n = tonumber(v) or 0
        return floor(n * 100000 + 0.5) / 100000
    end
    local function on_action(name, sc)
        local ok, events = pcall(require, "simscript.events")
        if ok and events.on_action then pcall(events.on_action, name, sc, nil) end
    end
    local function host()
        return { on_action = function(name, kind, id) on_action(name, S(kind, id)) end }
    end

    -- the technology helpers (engine.research's view of common/technology)
    local function tech(name) return name and research().tech(name) or nil end
    local function tech_field(name, key)
        local t = tech(name)
        return t and defs().field(t.def.block, key) or nil
    end
    local function tech_flag(name, key) return tech_field(name, key) == "yes" end
    local function tech_tier(name) return tonumber(tech_field(name, "tier")) or 0 end
    local function status_of(c, create)
        local s = world.field(c, "tech_status")
        if type(s) == "table" then return s end
        if not create then return nil end
        return world.child(c, "tech_status")
    end
    -- the country's technologies: { name = level } in the save's order, and the names
    local function researched(c)
        local s = status_of(c, false)
        local levels, order, cur = {}, {}, nil
        for _, e in ipairs(type(s) == "table" and s or {}) do
            if e.op and e.key then
                if e.key.text == "technology" then
                    cur = unq(e.value.text)
                elseif e.key.text == "level" and cur and levels[cur] == nil then
                    levels[cur] = tonumber(e.value.text) or 1
                    order[#order + 1] = cur
                end
            end
        end
        return levels, order
    end
    local function list_has(block, name)
        for _, v in ipairs(type(block) == "table" and block or {}) do
            if v.text and unq(v.text) == name then return v end
        end
        return nil
    end
    local function techs_by_order()
        local out = {}
        for name, d in pairs(defs().folder("common/technology")) do
            out[#out + 1] = { name = name, file = d.file or "", line = d.line or 0 }
        end
        table.sort(out, function(a, b)
            if a.file ~= b.file then return a.file < b.file end
            return a.line < b.line
        end)
        local names = {}
        for i, t in ipairs(out) do names[i] = t.name end
        return names
    end
    local all_techs
    local function tech_names()
        all_techs = all_techs or techs_by_order()
        return all_techs
    end
    local function has_category(name, cat)
        local t = tech(name)
        for _, c in ipairs(t and t.categories or {}) do
            if unq(c) == cat then return true end
        end
        return false
    end
    -- a draw of the game's generator in 0..n-1
    local function draw(n)
        if n <= 0 then return nil end
        local r = tonumber(eval.rand()) or 0
        return floor(r) % n
    end

    -- CTechnologyStatus::AddAlwaysAvailableTech (0x20afcf0) [V calls]: the technology added to
    -- `always_available_tech` and to its area's `alternatives` when not there and the country can
    -- research it, then the on_action on_research_option_added (one scope draw) [I: the order]
    local function add_option(id, c, name)
        local t = tech(name)
        if not t or not t.area then return false end
        local s = status_of(c, true)
        local changed = false
        local avail = world.child(s, "always_available_tech")
        if not list_has(avail, name) then
            world.append_value(avail, name, true)
            changed = true
        end
        if research().can_research(id, name) then
            local alts = world.child(world.child(s, "alternatives"), t.area)
            if not list_has(alts, name) then
                world.append_value(alts, name, true)
                changed = true
            end
        end
        if changed then
            written()
            pcall(eval.rand)
            on_action("on_research_option_added", S("country", id))
        end
        return changed
    end
    -- the area's queue items: { block, item, tech }
    local function queue_items(s, area)
        local q = world.field(s, area .. "_queue")
        local out = {}
        for _, item in ipairs(world.blocks(q)) do
            out[#out + 1] = { queue = q, item = item, tech = unq(world.field(item, "technology")),
                project = world.field(item, "special_project") }
        end
        return out
    end
    -- CTechnologyStatus::AddTechnologyStoredPoints: `stored_techpoints_for_tech = { tech = points }`
    local function add_stored(s, name, points)
        local b = world.child(s, "stored_techpoints_for_tech")
        local now = tonumber(world.field(b, name)) or 0
        world.set(b, name, fixed(now + points))
        local t = world.token_entry(b, name)
        if t then t.key.quoted = true end
    end
    -- the technology completed (CTechnologyStatus::DoResearchTechnologyCompleted, as engine.research's
    -- completion): its level, last_increased_tech, the on_action on_tech_increased, the area's
    -- options drawn again
    local function complete_tech(id, c, name, item)
        local s = status_of(c, true)
        if item then world.remove_entry(item.queue, item.item) end
        research().add_technology(id, name)
        world.set(s, "last_increased_tech", name)
        local t = world.token_entry(s, "last_increased_tech")
        if t then t.value.quoted = true end
        on_action("on_tech_increased", S("country", id))
        local tt = tech(name)
        if tt and tt.area then
            pcall(research().increase_potential, id, tt.area)
            pcall(research().update_alternatives, id, tt.area, true)
        end
        written()
    end
    -- CTechnologyStatus::IncreaseTechnologyProgress (0x20ab170) [V calls]: the points go to the
    -- technology's queue item (completed when it reaches the cost), else stored for it
    local function increase_progress(id, c, name, points)
        local s = status_of(c, true)
        local t = tech(name)
        if not t then return end
        for _, area in ipairs(AREAS) do
            for _, it in ipairs(queue_items(s, area)) do
                if it.tech == name then
                    local cost = research().cost(id, name) or 0
                    local p = (tonumber(world.field(it.item, "progress")) or 0) + points
                    if cost > 0 and p >= cost then
                        complete_tech(id, c, name, it)
                    else
                        world.set(it.item, "progress", fixed(p))
                        written()
                    end
                    return
                end
            end
        end
        add_stored(s, name, points)
        written()
    end

    -- ------------------------------------------------------------------------------------------
    -- technologies: effects

    -- add_research_option = <tech> (CAddResearchTechnologyOptionEffect 0x38387d0) [V calls]: when
    -- the country can research it (CCountry::CanResearchTechnology), AddAlwaysAvailableTech
    EFF["add_research_option"] = function(e, ctx)
        local id, c = this_country(ctx)
        local name = e.value.text and unq(e.value.text)
        if not id or not name or not research().can_research(id, name) then return end
        add_option(id, c, name)
    end

    -- add_tech_progress = { tech progress } (CAddTechProgressEffect 0x3765f80) [V calls]: progress
    -- in 0..1 (else an error, nothing done); when the country can research it, the technology made
    -- an option (AddAlwaysAvailableTech) and progress x its cost added (IncreaseTechnologyProgress)
    EFF["add_tech_progress"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not id then return end
        local name = param_text(e.value, "tech")
        local p = param_num(e.value, "progress", ctx)
        if not name or not p or p < 0 or p > 1 or not tech(name) then return end
        if not research().can_research(id, name) then return end
        add_option(id, c, name)
        local cost = research().cost(id, name) or 0
        increase_progress(id, c, name, cost * p)
    end

    -- add_random_research_option = { category area tier add_progress ignore_prereqs ignore_rare
    -- only_rare ignore_insight fail_effects } (CAddRandomResearchTechnologyOptionEffect 0x3839060,
    -- CalcRandomTechWithReset) [V calls]: a technology drawn among those matching (the category, the
    -- area, the tier; rare ones left out unless ignore_rare = no, only rare ones with only_rare;
    -- insight ones left out unless ignore_insight = no; researchable unless ignore_prereqs, where
    -- only the potential and not having it count), not an option already; made an option, its
    -- add_progress x cost stored; none: fail_effects run [I: the draw uniform, one draw]
    EFF["add_random_research_option"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not id then return end
        local b = e.value
        local cat, area = param_text(b, "category"), param_text(b, "area")
        local tier = param_num(b, "tier", ctx)
        local ignore_prereqs = param_text(b, "ignore_prereqs") == "yes"
        local ignore_rare = param_text(b, "ignore_rare") ~= "no"
        local only_rare = param_text(b, "only_rare") == "yes"
        local ignore_insight = param_text(b, "ignore_insight") ~= "no"
        local levels = researched(c)
        local s = status_of(c, false)
        local avail = s and world.field(s, "always_available_tech")
        local pool = {}
        for _, name in ipairs(tech_names()) do
            local t = tech(name)
            local ok = t and t.area and (not area or t.area == area) and (not cat or has_category(name, cat))
                and (not tier or tech_tier(name) == tier) and not list_has(avail, name)
            if ok then
                if only_rare then ok = t.rare elseif ignore_rare then ok = not t.rare end
            end
            if ok and ignore_insight and t.insight then ok = false end
            if ok then
                if ignore_prereqs then
                    ok = levels[name] == nil
                    local pot = defs().field(t.def.block, "potential")
                    if ok and type(pot) == "table" then
                        local good, holds = pcall(eval.trigger, pot, eval.new_ctx(S("country", id), nil, nil, t.def.file))
                        ok = good and holds
                    end
                else
                    ok = research().can_research(id, name)
                end
            end
            if ok then pool[#pool + 1] = name end
        end
        local i = draw(#pool)
        if not i then
            local fx = param(b, "fail_effects")
            if fx and type(fx.value) == "table" and fx.value.text == nil then eval.effect(fx.value, ctx) end
            return
        end
        local name = pool[i + 1]
        add_option(id, c, name)
        local p = param_num(b, "add_progress", ctx)
        if p and p > 0 then
            add_stored(status_of(c, true), name, (research().cost(id, name) or 0) * p)
            written()
        end
    end

    -- copy_techs_from = { target except } (CCopyTechsFromEffect 0x37888b0, CCountry::CopyTechnologies)
    -- [V calls]: the target's technologies and levels, less the exceptions, given to the country
    -- where it can research them (a repeatable up to the target's level); then the default ship
    -- designs set again (SetDefaultShipDesignsForOwnerType) [I: not modelled]
    EFF["copy_techs_from"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not id then return end
        local who = target_country(param_text(e.value, "target"), ctx, e)
        local wc = who and world.object("country", who)
        if not wc or who == id then return end
        local except = {}
        for _, n in ipairs(param_list(e.value, "except")) do except[n] = true end
        local theirs, order = researched(wc)
        for _, name in ipairs(order) do
            if not except[name] and tech(name) then
                local mine = research().level(id, name) or 0
                local guard = 0
                while mine < theirs[name] and research().can_research(id, name) and guard < 1000 do
                    research().add_technology(id, name)
                    written()
                    mine = mine + 1
                    guard = guard + 1
                end
            end
        end
    end

    -- the technologies of who the country could copy (CCountry::BuildTechnologyForCopyArray
    -- 0x2396b60): who has them, the country can research them, of the category and area when given
    local function copyable(id, who, cat, area)
        local wc = world.object("country", who)
        if not wc then return {} end
        local _, order = researched(wc)
        local out = {}
        for _, name in ipairs(order) do
            local t = tech(name)
            if t and (not area or t.area == area) and (not cat or has_category(name, cat))
                and research().can_research(id, name) then
                out[#out + 1] = name
            end
        end
        return out
    end

    -- copy_random_tech_from = { who category area progress } (CCopyRandomTechnologyFromEffect
    -- 0x3839ad0) [V calls]: one of the copyable technologies drawn; with progress, an option with
    -- progress x cost stored (completed at 1); without, researched (DoResearchTechnologyCompleted,
    -- its research removed from the queues)
    EFF["copy_random_tech_from"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not id then return end
        local who = target_country(param_text(e.value, "who"), ctx, e)
        if not who or who == id then return end
        local pool = copyable(id, who, param_text(e.value, "category"), param_text(e.value, "area"))
        local i = draw(#pool)
        if not i then return end
        local name = pool[i + 1]
        local p = param_num(e.value, "progress", ctx)
        local s = status_of(c, true)
        local item
        for _, area in ipairs(AREAS) do
            for _, it in ipairs(queue_items(s, area)) do
                if it.tech == name then item = it end
            end
        end
        if p and p < 1 then
            add_option(id, c, name)
            add_stored(s, name, (research().cost(id, name) or 0) * p)
            written()
        else
            complete_tech(id, c, name, item)
        end
    end

    -- finish_all_researches = yes (CFinishAllResearchesEffect 0x383a490,
    -- CTechnologyStatus::FinishAllResearch) [V calls]: each area's current research (its first queue
    -- item) given the progress it needs (a technology's cost, a special project's); the day's
    -- research completes it [I: the completion left to the daily update]
    EFF["finish_all_researches"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not id or not yes_no(e) then return end
        local s = status_of(c, false)
        if not s then return end
        for _, area in ipairs(AREAS) do
            local it = queue_items(s, area)[1]
            if it then
                local need
                if it.tech then
                    need = research().cost(id, it.tech)
                elseif it.project then
                    local pt = research().project_type(unq(research().project_of(id, tonumber(it.project)) or ""))
                    need = pt and pt.cost
                end
                if need then
                    world.set(it.item, "progress", fixed(need))
                    written()
                end
            end
        end
    end

    -- progress_all_researches = f (CProgressAllResearchesEffect 0x383a630,
    -- CTechnologyStatus::ProgressAllResearch) [V calls]: f in 0..1 (else an error); each area's
    -- current research advanced by f x its cost
    EFF["progress_all_researches"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not id then return end
        local f = eval.value(e.value, ctx, e)
        if not f or f < 0 or f > 1 then return end
        local s = status_of(c, false)
        if not s then return end
        for _, area in ipairs(AREAS) do
            local it = queue_items(s, area)[1]
            if it then
                local cost
                if it.tech then
                    cost = research().cost(id, it.tech)
                elseif it.project then
                    local pt = research().project_type(unq(research().project_of(id, tonumber(it.project)) or ""))
                    cost = pt and pt.cost
                end
                if cost then
                    world.set(it.item, "progress", fixed((tonumber(world.field(it.item, "progress")) or 0) + cost * f))
                    written()
                end
            end
        end
    end

    -- ------------------------------------------------------------------------------------------
    -- technologies: triggers

    -- num_researched_techs (CNumResearchedTechsTrigger, CalcTotalTechLevels) [V calls]: the levels
    -- of all the country's technologies
    country_value("num_researched_techs", function(id, c)
        local levels = researched(c)
        local n = 0
        for _, l in pairs(levels) do n = n + l end
        return n
    end)
    -- num_dangerous_techs / num_insight_techs / num_custom_N_techs (CalcNumDangerousTechs,
    -- CalcNumInsightTechs, CalcNumCustom1Techs: the technology's flag bits is_dangerous,
    -- is_insight (bit 5), is_custom_tech_1..3 (bits 6..8) of CTechnology +0x9d8) [V]: the
    -- country's technologies with the flag
    local function count_flag(flag)
        return function(id, c)
            local levels = researched(c)
            local n = 0
            for name in pairs(levels) do
                if tech_flag(name, flag) then n = n + 1 end
            end
            return n
        end
    end
    country_value("num_dangerous_techs", count_flag("is_dangerous"))
    country_value("num_insight_techs", count_flag("is_insight"))
    country_value("num_custom_1_techs", count_flag("is_custom_tech_1"))
    country_value("num_custom_2_techs", count_flag("is_custom_tech_2"))
    country_value("num_custom_3_techs", count_flag("is_custom_tech_3"))

    -- num_researched_techs_of_tier = { tier value <op> n } (CNumResearchedTechsOfTierTrigger,
    -- CalcNumTechsOfTier) [V calls]: the country's technologies of the tier
    TRIG["num_researched_techs_of_tier"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not id or e.value.text then return false end
        local tier = param_num(e.value, "tier", ctx)
        if not tier then return false end
        local n = 0
        for name in pairs((researched(c))) do
            if tech_tier(name) == tier then n = n + 1 end
        end
        return compare_value(n, e, ctx)
    end

    -- can_research_tier = { tier area } (CCanResearchTierTrigger, HasEnoughTechsForTier 0x20b28f0)
    -- [V]: tiers below 2 and tiers without `previously_unlocked` always; else the country has at
    -- least previously_unlocked researched technologies of the tier below in the area, hidden
    -- ones (`hidden`, bit 2 of +0x9d8) not counted
    TRIG["can_research_tier"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not id or e.value.text then return false end
        local tier = param_num(e.value, "tier", ctx)
        local area = param_text(e.value, "area")
        if not tier then return false end
        local d = defs().get("common/technology/tier", tostring(floor(tier)))
        local need = d and tonumber(defs().field(d.block, "previously_unlocked")) or 0
        if need <= 0 or tier < 2 then return true end
        local n = 0
        for name in pairs((researched(c))) do
            local t = tech(name)
            if t and (not area or t.area == area) and tech_tier(name) == tier - 1 and not tech_flag(name, "hidden") then
                n = n + 1
            end
        end
        return n >= need
    end

    -- count_tech_options = { area count <op> n } (CCountTechOptionsTrigger) [V: the area's
    -- alternatives' count, +0x16fc / +0x1714 / +0x172c]
    TRIG["count_tech_options"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not id or e.value.text then return false end
        local area = param_text(e.value, "area")
        local x = param(e.value, "count")
        if not area or not x then return false end
        local s = status_of(c, false)
        local alts = s and world.path(s, "alternatives", area)
        local n = 0
        for _, v in ipairs(type(alts) == "table" and alts or {}) do
            if v.text then n = n + 1 end
        end
        return compare(n, x.op, eval.value(x.value, ctx, x))
    end

    -- is_researching_technology = <tech> (CIsResearchingTechnologyTrigger, IsResearching) [V
    -- calls]: the technology in one of the queues
    TRIG["is_researching_technology"] = function(e, ctx)
        local id, c = this_country(ctx)
        local name = e.value.text and unq(e.value.text)
        if not id or not name then return false end
        local s = status_of(c, false)
        if not s then return false end
        for _, area in ipairs(AREAS) do
            for _, it in ipairs(queue_items(s, area)) do
                if it.tech == name then return true end
            end
        end
        return false
    end
    -- is_researching_any_technology = yes/no (IsResearchingAnyTechnology 0x20abfa0) [V calls]: a
    -- technology (or project) in any area's queue
    TRIG["is_researching_any_technology"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not id then return false end
        local s = status_of(c, false)
        local any = false
        for _, area in ipairs(AREAS) do
            if s and queue_items(s, area)[1] then any = true end
        end
        return any == yes_no(e)
    end

    -- is_last_increased_tech_category / _rare / _repeatable (CIsLastIncreasedTech*, the status's
    -- last increased technology +0x1758: `last_increased_tech`) [V calls]
    local function last_increased(ctx)
        local id, c = this_country(ctx)
        if not id then return nil end
        local s = status_of(c, false)
        return s and unq(world.field(s, "last_increased_tech")) or nil
    end
    TRIG["is_last_increased_tech_category"] = function(e, ctx)
        local name = last_increased(ctx)
        return name ~= nil and e.value.text ~= nil and has_category(name, unq(e.value.text))
    end
    TRIG["is_last_increased_tech_rare"] = function(e, ctx)
        local name = last_increased(ctx)
        local t = tech(name)
        return (t ~= nil and t.rare or false) == yes_no(e)
    end
    TRIG["is_last_increased_tech_repeatable"] = function(e, ctx)
        local name = last_increased(ctx)
        local lv = tonumber(tech_field(name, "levels"))
        return (name ~= nil and lv ~= nil and lv ~= 1) == yes_no(e)
    end

    -- can_copy_random_tech_from = { who category area } (CCanCopyRandomTechFromTrigger,
    -- CCountry::CanCopyRandomTechnologyFrom 0x2396b10) [V calls]: a copyable technology exists
    TRIG["can_copy_random_tech_from"] = function(e, ctx)
        local id = this_country(ctx)
        if not id or e.value.text then return false end
        local who = target_country(param_text(e.value, "who"), ctx, e)
        if not who or who == id then return false end
        return #copyable(id, who, param_text(e.value, "category"), param_text(e.value, "area")) > 0
    end

    -- tech_unlocked_ratio = { who ratio } (CTechUnlockRatio 0x3ba5ac0,
    -- CalcTotalResearchedTechCostRatio) [V calls]: the country's researched technologies' total cost
    -- over who's [I: the costs as the technologies' base cost x levels], compared with `ratio`
    -- (>= as the trigger's default comparison) [I]
    local function total_cost(id, c)
        local n = 0
        for name, l in pairs((researched(c))) do
            n = n + (research().cost(id, name) or 0) * l
        end
        return n
    end
    TRIG["tech_unlocked_ratio"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not id or e.value.text then return false end
        local who = target_country(param_text(e.value, "who"), ctx, e)
        local wc = who and world.object("country", who)
        local x = param(e.value, "ratio")
        if not wc or not x then return false end
        local theirs = total_cost(who, wc)
        local ratio = theirs > 0 and total_cost(id, c) / theirs or 0
        local op = x.op == "=" and ">=" or x.op
        return compare(ratio, op, eval.value(x.value, ctx, x))
    end

    -- has_highest_technology_score = yes/no (CHasHighestTechnologyScoreTrigger 0x3b8c610) [V: the
    -- country's tech score (+0x2f18) against every country of the game state's list]: no other
    -- country has a higher `tech_power`
    TRIG["has_highest_technology_score"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not id then return false end
        local mine = tonumber(world.field(c, "tech_power")) or 0
        local best = true
        for _, o in ipairs(world.all("country")) do
            local oc = o ~= id and world.object("country", o)
            if oc and (tonumber(world.field(oc, "tech_power")) or 0) > mine then best = false break end
        end
        return best == yes_no(e)
    end

    -- scientist_count (CScientistCount 0x3bde420) [V: the owned leaders (+0x2660) whose class has
    -- the research flag (+0x170 bit 2)]: the country's leaders of class scientist [I: the flag read
    -- as the scientist class]
    country_value("scientist_count", function(id, c)
        local n = 0
        for _, v in ipairs(world.list(world.field(c, "owned_leaders"))) do
            local l = world.object("leaders", tonumber(v)) or world.object("leader", tonumber(v))
            if l and unq(world.field(l, "class")) == "scientist" then n = n + 1 end
        end
        return n
    end)

    -- ------------------------------------------------------------------------------------------
    -- traditions and ascension perks (engine.traditions: the save's `traditions`,
    -- `tradition_categories`, `ascension_perks`)

    -- add_tradition = <tradition> (CAddTraditionEffect 0x379d640) [I: ActivateTradition without
    -- cost]: the tradition added (its category when new, last_picked_tradition, OnEnabled)
    EFF["add_tradition"] = function(e, ctx)
        local id = this_country(ctx)
        local name = e.value.text and unq(e.value.text)
        if not id or not name then return end
        local t = traditions().type(name)
        if not t or t.kind ~= traditions().TRADITION or traditions().has(id, name) then return end
        if traditions().add(id, name, host()) then written() end
    end
    -- add_ascension_perk = <perk> (CAddAscensionPerk 0x37ed520, CCountry::ActivateAscensionPerk)
    -- [V calls]: the perk added, without its slot or cost checked
    EFF["add_ascension_perk"] = function(e, ctx)
        local id = this_country(ctx)
        local name = e.value.text and unq(e.value.text)
        if not id or not name then return end
        local t = traditions().type(name)
        if not t or t.kind ~= traditions().PERK or traditions().has_perk(id, name) then return end
        if traditions().add(id, name, host()) then written() end
    end
    -- a name taken out of one of the country's lists
    local function remove_name(c, key, name)
        local b = world.field(c, key)
        local v = list_has(b, name)
        if not v then return false end
        world.remove_value(b, v.text)
        local economy = package.loaded["engine.economy"]
        if economy and economy.invalidate then economy.invalidate() end
        written()
        return true
    end
    -- remove_tradition = <tradition> (CRemoveTradition 0x37ed3c0, CCountry::RemoveTradition) [V
    -- calls]: the tradition taken out of `traditions`
    EFF["remove_tradition"] = function(e, ctx)
        local _, c = this_country(ctx)
        if not c or not e.value.text then return end
        remove_name(c, "traditions", unq(e.value.text))
    end
    -- remove_ascension_perk = <perk> (CRemoveAscensionPerk 0x37ed640) [V calls]
    EFF["remove_ascension_perk"] = function(e, ctx)
        local _, c = this_country(ctx)
        if not c or not e.value.text then return end
        remove_name(c, "ascension_perks", unq(e.value.text))
    end
    -- remove_tradition_tree = <category> (CRemoveTraditionCategory 0x37ed470,
    -- CCountry::RemoveTraditionCategory) [V calls]: the category and its traditions (adoption,
    -- finisher) taken out [I: the traditions with it]
    EFF["remove_tradition_tree"] = function(e, ctx)
        local id, c = this_country(ctx)
        if not c or not e.value.text then return end
        local cat = unq(e.value.text)
        local any = remove_name(c, "tradition_categories", cat)
        local names = {}
        for _, name in ipairs(traditions().of(id)) do names[#names + 1] = unq(name) end
        for _, name in ipairs(names) do
            local t = traditions().type(name)
            if t and t.category == cat then any = remove_name(c, "traditions", name) or any end
        end
        return any
    end
    -- copy_traditions_from / copy_ascension_perks_from = { target exceptions }
    -- (CCopyTraditionsFrom::ExecuteEffect 0x37ecc90, CCopyAscensionPerksFrom 0x37ed3a0) [I: the
    -- target's traditions (perks) in its order, less the exceptions and those the country has,
    -- added where their potential and possible triggers hold]
    local function copy_from(e, ctx, perks)
        local id = this_country(ctx)
        if not id or e.value.text then return end
        local who = target_country(param_text(e.value, "target"), ctx, e)
        if not who or who == id then return end
        local except = {}
        for _, n in ipairs(param_list(e.value, "exceptions")) do except[n] = true end
        local T = traditions()
        local list = perks and T.perks_of(who) or T.of(who)
        for _, name in ipairs(list) do
            name = unq(name)
            local has = perks and T.has_perk(id, name) or (not perks and T.has(id, name))
            if not except[name] and not has and T.is_potential(id, name) and T.fulfills_possible(id, name) then
                if T.add(id, name, host()) then written() end
            end
        end
    end
    EFF["copy_traditions_from"] = function(e, ctx) copy_from(e, ctx, false) end
    EFF["copy_ascension_perks_from"] = function(e, ctx) copy_from(e, ctx, true) end

    -- ------------------------------------------------------------------------------------------
    -- the planetary ascension tiers (the colony's `ascension_tier`, CColony +0x110)

    local function colony_of(sc)
        if not sc or sc == NONE then return nil end
        if sc.kind == "colony" then return sc.id end
        if sc.kind == "planet" then return world.planet_colony and world.planet_colony[sc.id] end
        if sc.kind == "ship" then
            local R = require("engine.script.runtime")
            return R.colony_of and R.colony_of("ship", sc.id) or nil
        end
        return nil
    end
    -- set_planetary_ascension_tier = n (CSetPlanetaryAscensionTier 0x380b330, CColony::SetAscensionTier)
    -- [V calls]
    EFF["set_planetary_ascension_tier"] = function(e, ctx)
        local cid = colony_of(ctx.this)
        local col = cid and world.object("colony", cid)
        if not col then return end
        local n = floor(eval.value(e.value, ctx, e) or 0)
        world.set(col, "ascension_tier", n)
        local economy = package.loaded["engine.economy"]
        if economy and economy.invalidate then economy.invalidate() end
        written()
    end
    -- has_planetary_ascension_tier <op> n (CHasPlanetaryAscensionTierTrigger 0x3c2ef90) [V]
    TRIG["has_planetary_ascension_tier"] = function(e, ctx)
        local cid = colony_of(ctx.this)
        local col = cid and world.object("colony", cid)
        if not col then return false end
        return compare(tonumber(world.field(col, "ascension_tier")) or 0, e.op, eval.value(e.value, ctx, e))
    end
    -- num_planetary_ascension_tiers <op> n (CNumColonyAscensionTiersTrigger 0x3c2ee00) [V: the
    -- country's colonies (+0x2690), their tiers summed]
    country_value("num_planetary_ascension_tiers", function(id, c)
        local n = 0
        for _, v in ipairs(world.list(world.field(c, "owned_planets"))) do
            local col = world.object("colony", tonumber(v))
            n = n + (col and tonumber(world.field(col, "ascension_tier")) or 0)
        end
        return n
    end)

    -- ------------------------------------------------------------------------------------------
    -- the crisis: the game state's `additional_crisis_strength`, `crisis_sound`, the galaxy's
    -- `crisis_type`, the country's `crisis_progression = { path level objective }`

    local function set_meta(key, value, quoted)
        world.set(world.tree, key, value)
        local t = world.token_entry(world.tree, key)
        if t and quoted then t.value.quoted = true end
        if world.meta then world.meta[key] = world.field(world.tree, key) end
        written()
    end
    local function meta_field(key)
        local v = world.meta and world.meta[key]
        if v == nil then v = world.field(world.tree, key) end
        return v
    end
    -- multiply_crisis_strength = f (CMultiplyCrisisStrengthEffect 0x36f27e0) [V calls: the game
    -- state's +0x130 multiplied; a negative factor an error]
    EFF["multiply_crisis_strength"] = function(e, ctx)
        local f = eval.value(e.value, ctx, e)
        if not f or f < 0 then return end
        set_meta("additional_crisis_strength", fixed((tonumber(meta_field("additional_crisis_strength")) or 1) * f))
    end
    -- additional_crisis_strength <op> n (CAdditionalCrisisStrengthTrigger 0x3bb3010) [V: +0x130]
    TRIG["additional_crisis_strength"] = function(e, ctx)
        return compare(tonumber(meta_field("additional_crisis_strength")) or 1, e.op, eval.value(e.value, ctx, e))
    end
    if eval.TVAL then
        eval.TVAL["additional_crisis_strength"] = function() return tonumber(meta_field("additional_crisis_strength")) or 1 end
    end
    -- set_crisis_sound = <sound> / stop_crisis_sound = yes (CSetCrisisSoundEffect 0x36f23b0,
    -- CStopCrisisSoundEffect 0x36f25b0, CGameState::SetCrisisSound) [V calls]: `crisis_sound`, empty
    -- when stopped
    EFF["set_crisis_sound"] = function(e, ctx)
        if not e.value.text then return end
        set_meta("crisis_sound", unq(e.value.text), true)
    end
    EFF["stop_crisis_sound"] = function(e, ctx)
        if not yes_no(e) then return end
        set_meta("crisis_sound", "", true)
    end
    -- allowed_crisis_type = <type> (CAllowedCrisisTypeTrigger 0x3baa4b0) [V]: the galaxy's
    -- crisis_type equal to the value (GetCrisisTypeEnumFromToken: any, prethoryn, unbidden,
    -- contingency, synth_queen, all are distinct values: `all` is not `any`)
    TRIG["allowed_crisis_type"] = function(e, ctx)
        local g = meta_field("galaxy")
        local v = type(g) == "table" and unq(world.field(g, "crisis_type")) or "any"
        return e.value.text ~= nil and unq(e.value.text) == v
    end
    -- can_be_crisis_terraformed = yes/no (CCanBeCrisisTerraformedTrigger 0x3c53840) [V: the system's
    -- +0x430]: its star class's `can_be_crisis_terraformed` (yes by default) [I]
    TRIG["can_be_crisis_terraformed"] = function(e, ctx)
        local sc = ctx.this
        if not sc or sc == NONE or sc.kind ~= "system" then return false end
        local sys = world.object("galactic_object", sc.id)
        local class = sys and unq(world.field(sys, "star_class"))
        local d = class and defs().get("common/star_classes", class)
        local can = not (d and defs().field(d.block, "can_be_crisis_terraformed") == "no")
        return can == yes_no(e)
    end
    -- activate_crisis_progression = <path> (CActivateCrisisProgression 0x37f1780,
    -- CCountry::ActivateCrisisProgression 0x23973c0) [V]: a new crisis progression on the path
    -- replaces the country's (`crisis_progression = { path level objective }`), then its daily
    -- update (the levels it can unlock) [I: level 0, the levels' unlocking not modelled]
    EFF["activate_crisis_progression"] = function(e, ctx)
        local id, c = this_country(ctx)
        local path = e.value.text and unq(e.value.text)
        if not id or not path or not defs().get("common/crisis_paths", path) then return end
        local old = world.entry(c, "crisis_progression")
        if old then world.remove_entry(c, old) end
        local b = {}
        world.append(b, "path", path, true)
        world.append(b, "level", 0)
        world.append(c, "crisis_progression", b)
        written()
    end
    -- complete_crisis_objective = <objective> (CCompleteCrisisObjective 0x37f18d0,
    -- CCountry::CompleteCrisisObjective 0x2396e70) [V calls]: with a crisis progression whose path
    -- lists the objective, its reward (the objective's `reward`, a value block in the country's
    -- scope) of the path's crisis_currency added to the country's stockpile
    EFF["complete_crisis_objective"] = function(e, ctx)
        local id, c = this_country(ctx)
        local obj = e.value.text and unq(e.value.text)
        if not id or not obj then return end
        local cp = world.field(c, "crisis_progression")
        local path = type(cp) == "table" and unq(world.field(cp, "path"))
        local pd = path and defs().get("common/crisis_paths", path)
        if not pd then return end
        local listed = false
        for _, v in ipairs(type(defs().field(pd.block, "objectives")) == "table" and defs().field(pd.block, "objectives") or {}) do
            if v.text and unq(v.text) == obj then listed = true end
        end
        local od = listed and defs().get("common/crisis_objectives", obj)
        if not od then return end
        local currency = unq(defs().field(pd.block, "crisis_currency"))
        local rb = defs().field(od.block, "reward")
        local reward = 0
        if type(rb) == "table" then
            local ok, v = pcall(eval.value_block, rb, eval.new_ctx(S("country", id), nil, nil, od.file))
            reward = ok and tonumber(v) or 0
        else
            reward = tonumber(rb) or 0
        end
        if currency and reward ~= 0 then
            local stock = world.child(world.child(world.child(c, "modules"), "standard_economy_module"), "resources")
            world.set(stock, currency, fixed((tonumber(world.field(stock, currency)) or 0) + reward))
        end
        world.set(cp, "objective", obj)
        local t = world.token_entry(cp, "objective")
        if t then t.value.quoted = true end
        written()
    end

    -- ------------------------------------------------------------------------------------------
    -- leaders and the council

    -- set_leader_tier = <tier> (CSetLeaderTierEffect 0x37b6090, CLeader::SetLeaderTier) [V calls]:
    -- the leader's `tier`
    EFF["set_leader_tier"] = function(e, ctx)
        local sc = ctx.this
        if not sc or sc == NONE or sc.kind ~= "leader" or not e.value.text then return end
        local l = world.object("leaders", sc.id) or world.object("leader", sc.id)
        local tier = unq(e.value.text)
        if not l or not defs().get("common/leader_tiers", tier) then return end
        world.set(l, "tier", tier)
        local t = world.token_entry(l, "tier")
        if t then t.value.quoted = true end
        written()
    end
    -- unlock_council_selection = yes (CUnlockCouncilSelection 0x3715a10) [V calls]: the
    -- government's councilor types determined again (CGovernment::DetermineCouncilorTypes:
    -- engine.script.objects_leaders council.determine)
    EFF["unlock_council_selection"] = function(e, ctx)
        local id = this_country(ctx)
        if not id or not yes_no(e) then return end
        local ok, L = pcall(require, "engine.script.objects_leaders")
        if ok and L.council and L.council.determine then
            L.council.determine(id)
            written()
        end
    end
    -- has_unlocked_council_positions <op> n (CHasUnlockedCouncilPositions 0x3bfccb0,
    -- CGovernment::GetUnlockedCouncilSlots) [V calls]: `unlocked_civic_council_slots`
    country_value("has_unlocked_council_positions", function(id, c)
        local g = world.field(c, "government")
        return type(g) == "table" and tonumber(world.field(g, "unlocked_civic_council_slots")) or 0
    end)

    -- ------------------------------------------------------------------------------------------
    -- the patrons' accords (the country's patron relations: `unlocked_passive_accords_count`,
    -- `unlocked_active_accords`)

    local function relations(id)
        local out = {}
        for _, rid in ipairs(world.all("patron_relations")) do
            local r = world.object("patron_relations", rid)
            if r and tonumber(world.field(r, "owner")) == id then out[#out + 1] = r end
        end
        return out
    end
    local function active_unlocked(r)
        local n = 0
        for _, v in ipairs(type(world.field(r, "unlocked_active_accords")) == "table" and world.field(r, "unlocked_active_accords") or {}) do
            if v.text or v.op then n = n + 1 end
        end
        return n
    end
    -- count_unlocked_active_accords <op> n (CNumUnlockedActiveAccordsTrigger 0x3c3b900) [V: the
    -- shroud module's count (+0x16c)]: the active accords the country's relations have unlocked [I]
    country_value("count_unlocked_active_accords", function(id)
        local n = 0
        for _, r in ipairs(relations(id)) do n = n + active_unlocked(r) end
        return n
    end)
    -- patron_has_all_accords_unlocked = <patron> (CPatronHasAllAccordUnlockedTrigger 0x3c3bb30) [V
    -- calls: AreAllPassiveAccordsUnlocked, AreAllActiveAccordsUnlocked]: the relation's unlocked
    -- passive count and active list cover the patron type's passive_accord and active_accord blocks
    TRIG["patron_has_all_accords_unlocked"] = function(e, ctx)
        local id = this_country(ctx)
        local patron = e.value.text and unq(e.value.text)
        if not id or not patron then return false end
        local d = defs().get("common/patrons", patron)
        if not d then return false end
        local passive, active = 0, 0
        for _, x in ipairs(d.block) do
            if x.op and x.key then
                if x.key.text == "passive_accord" then passive = passive + 1
                elseif x.key.text == "active_accord" then active = active + 1 end
            end
        end
        for _, r in ipairs(relations(id)) do
            if unq(world.field(r, "patron")) == patron then
                return (tonumber(world.field(r, "unlocked_passive_accords_count")) or 0) >= passive
                    and active_unlocked(r) >= active
            end
        end
        return false
    end

    -- ------------------------------------------------------------------------------------------
    -- research stations and frontier space

    local function planet_of(sc)
        if not sc or sc == NONE then return nil end
        if sc.kind == "planet" then return sc.id end
        if sc.kind == "colony" then return world.colony_planet and world.colony_planet[sc.id] end
        return nil
    end
    -- the planet's research station (its `shipclass_orbital_station` fleet of that class)
    local function station_of(pid)
        local p = pid and world.object("planet", pid)
        local f = p and ref(world.field(p, "shipclass_orbital_station"))
        local fl = f and world.object("fleet", f)
        if fl and unq(world.field(fl, "ship_class")) == "shipclass_research_station" then return f end
        return nil
    end
    -- research_station (planet, colony, ship carrier): the research station fleet in its orbit
    -- [I: as mining_station]
    LINKS["research_station"] = function(cur)
        local f = station_of(planet_of(cur))
        if f then return S("fleet", f) end
        return NONE
    end
    -- create_research_station = { owner } (CCreateMiningOrResearchStationEffect<SCreateResearchStation>
    -- 0x3716fd0) [V calls]: on a planet without one (CDepositHolder::HasResearchStation), the owner's
    -- latest research station design made into a station fleet in orbit
    -- (CDepositHolder::CreateOrbitalStation): a fleet of class shipclass_research_station named
    -- after the planet, owned by the owner, its ship, at the planet, the planet's
    -- `shipclass_orbital_station` [I: the fleet's fields as the save's stations]
    EFF["create_research_station"] = function(e, ctx)
        local pid = planet_of(ctx.this)
        local p = pid and world.object("planet", pid)
        if not p or station_of(pid) or ref(world.field(p, "shipclass_orbital_station")) then return end
        local owner = target_country(param_text(e.value, "owner"), ctx, e)
        if not owner then return end
        local systems = require("engine.systems")
        require("engine.script.objects_fleets")
        local fx = systems.effects
        if not (fx.set_fleet_owner and fx.create_ship) then return end
        local name = {}
        world.append(name, "key", "shipclass_research_station_name", true)
        local fid = require("engine.fleets.create").fleet({ country = nil })
        local f = fid and world.object("fleet", fid)
        if not f then return end
        world.insert(f, 1, "name", name)
        fx.set_fleet_owner({ id = fid, country = owner })
        fx.create_ship({ fleet = fid, size = "research_station" })
        world.set(f, "ship_class", "shipclass_research_station")
        local props = world.child(f, "properties")
        if world.field(props, "station") == nil then world.insert(props, 1, "station", "yes") end
        if fx.set_location then pcall(fx.set_location, { id = fid, target = { kind = "planet", id = pid } }) end
        world.set(p, "shipclass_orbital_station", fid)
        written()
    end

    -- is_in_frontier_space = yes/no (CIsInFrontierSpace 0x3b53ef0) [V]: the system (of the planet,
    -- the fleet, the ship) belongs to no sector (CGalacticObject::GetSector null); without a system,
    -- true for `no`
    TRIG["is_in_frontier_space"] = function(e, ctx)
        local sc = ctx.this
        if not sc or sc == NONE then return false end
        local R = require("engine.script.runtime")
        local sys
        if sc.kind == "system" then sys = sc.id
        else
            local kind, id = sc.kind, sc.id
            if kind == "colony" then kind, id = "planet", world.colony_planet and world.colony_planet[id] end
            sys = id and R.system_of and R.system_of(kind, id) or nil
        end
        local so = sys and world.object("galactic_object", sys)
        if not so then return not yes_no(e) end
        local sector = ref(world.field(so, "sector"))
        local in_sector = sector ~= nil and world.object("sectors", sector) ~= nil
        if not in_sector and sector ~= nil then in_sector = world.object("sector", sector) ~= nil end
        return (not in_sector) == yes_no(e)
    end

    -- ------------------------------------------------------------------------------------------
    -- the debris and agreements' readings (scopes the 2210 save has no object of)

    -- must_research = yes/no (CMustResearchDebrisTrigger 0x3be9c40) [V: the debris' `must_research`]
    TRIG["must_research"] = function(e, ctx)
        local sc = ctx.this
        if not sc or sc == NONE or sc.kind ~= "debris" then return false end
        local d = world.object("debris", sc.id)
        return (d ~= nil and world.field(d, "must_research") == "yes") == yes_no(e)
    end
    -- has_specialist_perk = <perk> / specialist_tier <op> n (CHasSpecialistPerkTrigger,
    -- CSpecialistTierTrigger) [I: the agreement's `specialist_perks` list and `specialist_tier`]
    TRIG["has_specialist_perk"] = function(e, ctx)
        local sc = ctx.this
        if not sc or sc == NONE or sc.kind ~= "agreement" or not e.value.text then return false end
        local a = world.object("agreements", sc.id) or world.object("agreement", sc.id)
        return a ~= nil and list_has(world.field(a, "specialist_perks"), unq(e.value.text)) ~= nil
    end
    TRIG["specialist_tier"] = function(e, ctx)
        local sc = ctx.this
        if not sc or sc == NONE or sc.kind ~= "agreement" then return false end
        local a = world.object("agreements", sc.id) or world.object("agreement", sc.id)
        if not a then return false end
        return compare(tonumber(world.field(a, "specialist_tier")) or 0, e.op, eval.value(e.value, ctx, e))
    end

    -- ------------------------------------------------------------------------------------------
    -- the numeric triggers as values (`complex_trigger_modifier = { trigger = <name> parameters =
    -- { ... } }`, eval.trigger_value: TVAL[name](ctx, e), e.value the parameters): the number each
    -- trigger compares (its GetTriggerValue)

    -- num_researched_techs_of_tier: the country's technologies of `parameters = { tier = n }`
    eval.TVAL["num_researched_techs_of_tier"] = function(ctx, e)
        local id, c = this_country(ctx)
        if not id then return 0 end
        local block = e and type(e.value) == "table" and e.value.text == nil and e.value or {}
        local tier = param_num(block, "tier", ctx)
        if not tier then return 0 end
        local n = 0
        for name in pairs((researched(c))) do
            if tech_tier(name) == tier then n = n + 1 end
        end
        return n
    end
    -- has_planetary_ascension_tier: the colony's tier (CHasPlanetaryAscensionTierTrigger 0x3c2ef90)
    eval.TVAL["has_planetary_ascension_tier"] = function(ctx)
        local cid = colony_of(ctx.this)
        local col = cid and world.object("colony", cid)
        return col and tonumber(world.field(col, "ascension_tier")) or 0
    end
    -- num_repeatable_techs: the levels of the country's repeatable technologies, as the trigger
    -- (CNumRepeatableTechsTrigger 0x1990580, E.num_repeatable_techs)
    eval.TVAL["num_repeatable_techs"] = function(ctx)
        local sc = ctx.this
        if not sc or sc == NONE or sc.kind ~= "country" or not I.E.num_repeatable_techs then return 0 end
        sync()
        return tonumber(I.E.num_repeatable_techs(sc.id)) or 0
    end
end
