-- render/windows/diplomacy_federation.lua : the player's federation (interface/
-- federation_view.gui, CFederationView): docs/windows/diplomacy.md section 4. The game shows it
-- only for the observed country's federation (CFederationView::Update hides the window without
-- one), on the Levels tab first. The Fleets and Laws tabs' lists are not filled.

local M = {}

local FILE = "interface/federation_view.gui"
local V = "/federation_view"

local TABS = { "levels", "members", "fleets", "laws" }

local source = require("stellar.script.source")

-- common/federation_types and common/federation_perks (once), the files' @variables
local cache = {}
local function defs(game_dir, dir)
    if not cache[dir] then
        local d, _, vars = source.definitions(game_dir, dir)
        cache[dir] = { defs = d or {}, vars = vars or {} }
    end
    return cache[dir]
end

local function field(block, key)
    for _, e in ipairs(type(block) == "table" and block or {}) do
        if e.op and e.key and e.key.text == key then
            return e.value.text or e.value
        end
    end
    return nil
end

-- a number of a definition's file, its @variable resolved
local function number(dir, def, v)
    if type(v) == "string" and v:sub(1, 1) == "@" then
        local vars = dir.vars[def.file] or {}
        v = vars[v:sub(2)]
    end
    return tonumber(v)
end

-- the type's levels (CFederationType levels: level_1 ... in order): { experience, perks = { } }
local function levels_of(game_dir, ftype)
    local dir = defs(game_dir, "common/federation_types")
    local def = dir.defs[ftype or ""]
    local out = {}
    local lv = def and field(def.block, "levels")
    for _, e in ipairs(type(lv) == "table" and lv or {}) do
        if e.op and e.key and type(e.value) == "table" and e.value.text == nil then
            local perks = {}
            for _, p in ipairs(type(field(e.value, "perks")) == "table" and field(e.value, "perks") or {}) do
                if p.text then
                    perks[#perks + 1] = p.text
                end
            end
            out[#out + 1] = { experience = number(dir, def, field(e.value, "experience")), perks = perks }
        end
    end
    return out, def
end

-- GetFirstPerkModifierDesc: the first perk's first modifier block with a description, under its
-- header (federation, president, members) [I: the order of the blocks]
local MODS = { { "federation_modifier", "FEDERATION_PERK_FED_MOD" }, { "president_modifier", "FEDERATION_PERK_LEAD_MOD" },
    { "members_modifier", "FEDERATION_PERK_MEMBER_MOD" } }
local function perk_desc(ctx, perk)
    local def = perk and defs(ctx.game_dir, "common/federation_perks").defs[perk]
    for _, m in ipairs(MODS) do
        local b = def and field(def.block, m[1])
        local d = type(b) == "table" and field(b, "description")
        if d then
            return ctx.fmt(m[2]) .. "\n" .. ctx.fmt(tostring(d))
        end
    end
    return ""
end

local function loc(ctx, key)
    return ctx.loc and key and ctx.loc.has(key) and ctx.loc.get(key) or key or ""
end

-- the federation's defines (NGameplay FEDERATION_COHESION_TO_XP [V 00_defines.txt])
local COHESION_TO_XP, COHESION_RANGE = 0.1, 100

-- the members' sort (SortAllianceMembers' sorters, by the sort buttons): name, economy, fleet,
-- technology, opinion [I: the others by name]
local SORT = {
    name = function(m) return m.name end,
    economy_power = function(m) return -(m.c.economy_power or 0) end,
    fleet_power = function(m) return -(m.c.military_power or 0) end,
    technology_power = function(m) return -(m.c.tech_power or 0) end,
}

function M.build(ctx, state)
    local data = ctx.data
    local pc = data.countries[data.player]
    -- the player's federation (the window's argument is the game's only: the observed country's)
    local fid = pc and pc.federation
    local f = fid and data.federations[fid]
    if not f then
        return
    end
    local tab = state.tab or "levels"
    local hide, text, frames, progress, sprites, textures, disabled = {}, {}, {}, {}, {}, {}, {}
    for _, t in ipairs(TABS) do
        -- UpdateTabVisibility; SwitchToTab: Levels shows levels_window, the others the cohesion
        -- header and their own window
        hide["tab_" .. t] = t == tab or nil
        hide["tab_" .. t .. "_active"] = t ~= tab or nil
        hide[t .. "_window"] = t ~= tab or nil
    end
    hide.level_cohesion_window = tab == "levels" or nil
    local levels, tdef = levels_of(ctx.game_dir, f.type)
    -- UpdateGeneralInfo
    text[V .. "/federation_name"] = ctx.name(f.name)
    text[V .. "/federation_type"] = ctx.fmt("FEDERATION_VIEW_TYPE", { TYPE = loc(ctx, f.type) })
    text[V .. "/federation_type_desc"] = (f.type or "") .. "_desc"
    text[V .. "/federation_formed"] = ctx.fmt("FEDERATION_VIEW_DATE", { DATE = f.start_date or "" })
    local icon = tdef and field(tdef.block, "icon")
    if icon then
        sprites[V .. "/federation_info_box/federation_type_button"] = tostring(icon):gsub('"', "")
    end
    local first = f.perks and f.perks[1]
    text[V .. "/federation_perk_desc"] = perk_desc(ctx, first and first.type)
    -- the law shown: the centralization [I: which category]
    local law = f.laws and f.laws.law_category_centralization
    text[V .. "/federation_law_desc"] = law and ctx.fmt("FEDERATION_VIEW_LAW_DESC",
        { NAME = loc(ctx, "law_category_centralization"), LAW = loc(ctx, law) }) or ""
    -- the leave button: Ask to Leave when not its leader and the leader decides [I: the action's
    -- acceptance type not read], else Leave Federation; requires_actor_peace (disabled at war)
    -- [I: the action's other conditions not evaluated]
    text[V .. "/leave_federation_button"] = f.leader ~= data.player and "ASK_TO_LEAVE_FEDERATION" or "FEDERATION_VIEW_LEAVE_FEDERATION"
    local can_leave = not pc.at_war
    if not can_leave then
        disabled[V .. "/leave_federation_button"] = true
    end
    -- the delegate (CAssignOfficialWindow): none assigned, its Select a Leader button only [I]
    hide.assigned_delegate = true
    hide.leader_function = true
    hide.leader_name = true
    hide.portrait_window = true
    ctx.flags[V .. "/levels_window/leader"] = f.leader

    -- UpdateLevelCohesionInfo / UpdateLevelsTab: cohesion, XP, the level
    local cohesion = f.cohesion or 0
    local level = f.levels or 1
    local nextxp = levels[level] and levels[level].experience
    local C = V .. "/levels_window/cohesion_window"
    text[C .. "/cohesion_bar_window/xp_gain_value"] = ctx.fmt("FEDERATION_XP_GAIN", { VALUE = cohesion * COHESION_TO_XP })
    -- the monthly cohesion growth (a modifier total: the ethics, the envoys) [I: not computed]
    text[C .. "/cohesion_bar_window/cohesion_infoBox/cohesion_number"] = ""
    text[C .. "/cohesion_bar_window/cohesion_infoBox/envoy_number"] = ctx.fmt("FEDERATION_ENVOY_NUMBER", { VALUE = #(f.envoys or {}) })
    progress[C .. "/cohesion_bar_window/cohesion_progress_positive"] = math.max(0, cohesion) / COHESION_RANGE
    progress[C .. "/cohesion_bar_window/cohesion_progress_negative"] = 1 - math.max(0, -cohesion) / COHESION_RANGE
    local X = V .. "/levels_window/xp_level_window"
    text[X .. "/level_num_large"] = ctx.fmt("FEDERATION_LEVEL", { LEVEL = level })
    text[X .. "/xp_total_number"] = ctx.fmt("FEDERATION_EXPERIENCE", { CURRENT = f.experience or 0, TOTAL = nextxp or 0 })
    progress[X .. "/xp_progress_bar"] = nextxp and nextxp > 0 and math.min(1, (f.experience or 0) / nextxp) or 1
    local L = V .. "/level_cohesion_window"
    text[L .. "/federation_level_short"] = ctx.fmt("FEDERATION_LEVEL_SHORT", { LEVEL = level })
    text[L .. "/cohesion_infoBox/cohesion_number"] = ctx.fmt("FEDERATION_COHESION_VALUE", { VALUE = cohesion })
    text[L .. "/cohesion_infoBox/envoy_number"] = ctx.fmt("FEDERATION_ENVOY_NUMBER", { VALUE = #(f.envoys or {}) })

    local actions = { [V] = "diplo:none", [V .. "/close"] = "diplo:close" }
    for _, t in ipairs(TABS) do
        actions[V .. "/tab_" .. t] = "diplo:tab:" .. t
    end
    if can_leave then
        actions[V .. "/leave_federation_button"] = "diplo:member:leave_federation"
    end
    local MW = V .. "/members_window/sort_buttons"
    for _, s in ipairs({ "name", "economy_power", "fleet_power", "technology_power", "opinion", "diplomacy", "envoys", "ethics" }) do
        actions[MW .. "/" .. s .. "_button"] = "diplo:sort:" .. s
    end
    local r = ctx.layout(FILE, "federation_view", {
        hide = hide, text = text, frames = frames, progress = progress, sprites = sprites, textures = textures,
        disabled = disabled, actions = actions,
    })

    local members = {}
    for _, m in ipairs(f.members or {}) do
        local c = data.countries[m]
        if c then
            members[#members + 1] = { id = m, c = c, name = ctx.name(c.name) }
        end
    end
    -- the small members list (CSmallFederationMemberItem): by economy [I], a row each (38 high,
    -- the item's own position the list's)
    local small = {}
    for i, m in ipairs(members) do small[i] = m end
    table.sort(small, function(a, b) return (a.c.economy_power or 0) > (b.c.economy_power or 0) end)
    local list = r.rects[V .. "/federation_members_small_window/members_short_list"]
    if list then
        for k, m in ipairs(small) do
            local y = list.y + (k - 1) * 38
            if y + 38 <= list.y + list.h then
                local p = "/fed_small/" .. k
                local E = p .. "/small_member_item"
                ctx.layout(FILE, "small_member_item", {
                    prefix = p, parent = { x = list.x - 15, y = y - 45, w = 0, h = 0 },
                    text = { [E .. "/name"] = m.name, [E .. "/power_amount"] = string.format("%d", math.floor((m.c.economy_power or 0) + 0.5)) },
                    hide = { [E .. "/federation_leader_border"] = m.id ~= f.leader or nil },
                    actions = { [E .. "/flag"] = "diplo:country:" .. m.id },
                })
                ctx.flags[E .. "/flag"] = m.id
            end
        end
    end

    if tab == "levels" then
        -- UpdateLevelsList: a level_item per level of the type (slots 170 x 120): its name, its
        -- background by whether it is unlocked [I: frame 1 unlocked, 2 locked], its perks' icons
        -- (gfx/interface/icons/federation/federation_perks/<perk>.dds [I])
        local G = r.rects[V .. "/levels_window/xp_level_window/levels_window/levels_grid_box"]
        for i, lv in ipairs(G and levels or {}) do
            local p = "/fed_level/" .. i
            local E = p .. "/level_item"
            local locked = i > level
            local lr = ctx.layout(FILE, "level_item", {
                prefix = p, parent = { x = G.x + (i - 1) * 170, y = G.y, w = 0, h = 0 },
                text = { [E .. "/level_name"] = ctx.fmt("FEDERATION_LEVEL", { LEVEL = i }) },
                frames = { [E .. "/perk_bg"] = locked and 2 or 1 },
                hide = { [E .. "/losing_level_icon"] = true },
            })
            local PG = lr.rects[E .. "/perks_grid_box"]
            for k, perk in ipairs(PG and lv.perks or {}) do
                if k <= 3 then
                    local pp = p .. "/perk/" .. k
                    local PE = pp .. "/perk_item"
                    ctx.layout(FILE, "perk_item", {
                        prefix = pp, parent = { x = PG.x + (k - 1) * 45, y = PG.y, w = 0, h = 0 },
                        textures = { [PE .. "/perk_icon"] = "gfx/interface/icons/federation/federation_perks/" .. perk .. ".dds" },
                        disabled = locked and { [PE] = true } or nil,
                    })
                end
            end
        end
    elseif tab == "members" then
        -- UpdateMembersTab: a federation_member_entry per member, by the sort (the same button
        -- again reverses it)
        local key = SORT[state.sort or "name"] or SORT.name
        table.sort(members, function(a, b)
            local ka, kb = key(a), key(b)
            if ka ~= kb then return ka < kb end
            return a.id < b.id
        end)
        local ML = r.rects[V .. "/members_window/members_list_window/members"]
        for k, m in ipairs(ML and members or {}) do
            local p = "/fed_member/" .. k
            local E = p .. "/federation_member_entry"
            local op = data.opinion and data.opinion[m.id]
            ctx.layout(FILE, "federation_member_entry", {
                prefix = p, parent = { x = ML.x, y = ML.y + (k - 1) * 52, w = 0, h = 0 },
                text = {
                    [E .. "/name"] = m.name, [E .. "/empire_type"] = m.c.government or "",
                    [E .. "/economy_power_amount"] = ctx.fmt("FEDERATION_ECONOMY_VALUE", { VALUE = math.floor((m.c.economy_power or 0) + 0.5) }),
                    [E .. "/fleet_power_amount"] = ctx.fmt("FEDERATION_FLEET_VALUE", { VALUE = math.floor((m.c.military_power or 0) + 0.5) }),
                    [E .. "/technology_power_amount"] = ctx.fmt("FEDERATION_TECH_VALUE", { VALUE = math.floor((m.c.tech_power or 0) + 0.5) }),
                    [E .. "/their_opinion"] = m.id == data.player and "DASH" or (op and ctx.fmt("ALLIANCE_AND_FEDERATION_VIEW_THEIR_OPINION", { VAL = op }) or "UNKNOWN_OPINION"),
                    -- the diplomatic weight and the envoys [I: not computed]
                    [E .. "/diplomacy_weight"] = "", [E .. "/envoys_count"] = "",
                },
                hide = { [E .. "/federation_leader_border"] = m.id ~= f.leader or nil, [E .. "/selected_overlay"] = true },
                actions = { [E .. "/flag"] = "diplo:country:" .. m.id },
            })
            ctx.flags[E .. "/flag"] = m.id
        end
    end
end

return M
