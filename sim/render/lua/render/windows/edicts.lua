-- render/windows/edicts.lua : the policies and edicts view (interface/edicts_view.gui,
-- CEdictsView and CPoliciesView; docs/windows/empire.md section 6): the policy categories
-- (policy_category_header_entry, collapsed at first, sorted by name), the edicts the country can
-- take (empire_edicts_entry, in the database's order: potential and prerequisites met) with their
-- cost and upkeep, the edict fund; its tabs open the council and the factions views.

local world = require("engine.world")
local C = require("render.windows.empire_common")

local M = {}

local FILE = "interface/edicts_view.gui"
local V = "/edicts_and_policies_view"

function M.data(cid, state)
    local c = world.object("country", cid)
    if not c then
        return {}
    end
    local d = { facts = C.facts(world, c), active = {}, policies = {} }
    for _, e in ipairs(world.blocks(world.field(c, "edicts"))) do
        d.active[C.strip(world.field(e, "edict")) or ""] = true
    end
    for _, e in ipairs(world.blocks(world.field(c, "active_policies"))) do
        d.policies[C.strip(world.field(e, "policy")) or ""] = C.strip(world.field(e, "selected"))
    end
    return d
end

-- the edicts listed (CEdictsView::ReloadCountryEdicts): the database's order (common/edicts by
-- file, then file order), those whose potential holds and whose prerequisites are researched
function M.edicts(ctx, d)
    local out = {}
    local f = d.facts or { techs = {}, traditions = {}, ethics = {}, civics = {} }
    for _, k in ipairs(C.def_order(ctx, "common/edicts")) do
        local e = C.defs(ctx, "common/edicts")[k]
        local ok = C.trigger(C.raw_field(e, "potential") or {}, f)
        for _, t in ipairs(C.strings(C.raw_field(e, "prerequisites"))) do
            if not f.techs[t] then
                ok = false
            end
        end
        if ok then
            out[#out + 1] = k
        end
    end
    return out
end

-- an edict's cost or upkeep in unity: the resource's amount (through the file's variables) times
-- its multiplier (value:edict_size_effect: 1 + 0.01 x the sprawl over the cap) [I: the cost
-- modifiers and the sprawl left out]
local function amount(ctx, key, which)
    local e = C.defs(ctx, "common/edicts")[key]
    local res = C.raw_field(e, "resources")
    local b = C.raw_field(res, which)
    local v = b and C.number(ctx, "common/edicts", key, C.field(b, "unity"))
    return v
end

-- the policy groups the country has (CPoliciesView::UpdatePolicies: HasPolicyData and
-- IsPotential), by category, each sorted by its name; and a group's options (those whose
-- potential holds)
function M.policy_groups(ctx, d)
    local by_cat = {}
    for _, k in ipairs(C.def_order(ctx, "common/policies")) do
        local g = C.defs(ctx, "common/policies")[k]
        -- (CCountry::HasPolicyData: the groups the country has an active_policies entry for; their
        -- potential is not evaluated [I])
        if (d.policies or {})[k] then
            local cat = C.field(g, "category") or "uncategorized"
            by_cat[cat] = by_cat[cat] or {}
            table.insert(by_cat[cat], { key = k, name = C.loc(ctx, "policy_" .. k) })
        end
    end
    for _, list in pairs(by_cat) do
        table.sort(list, function(a, b2)
            return a.name < b2.name
        end)
    end
    return by_cat
end

function M.policy_options(ctx, d, key)
    local out = {}
    local g = C.defs(ctx, "common/policies")[key]
    for _, e in ipairs(g or {}) do
        if e.op and e.key and e.key.text == "option" and type(e.value) == "table" and e.value.text == nil then
            local name = C.field(e.value, "name")
            if name and C.trigger(C.raw_field(e.value, "potential") or {}, d.facts or {}, true) then
                out[#out + 1] = name
            end
        end
    end
    return out
end

function M.build(ctx, d, state)
    d = d or {}
    -- (before the view's data has come, its frame alone: the data is nil until the snapshot
    -- carries it)
    if d.facts == nil then
        local b0 = C.builder(ctx)
        b0:add(FILE, "edicts_and_policies_view", { only = { background = true, close = true, close_button = true, heading = true }, actions = { [V .. "/close"] = "view_close" } })
        return b0.items, b0.report
    end
    d.active = d.active or {}
    d.policies = d.policies or {}
    local b = C.builder(ctx)
    local actions = {
        [V .. "/close"] = "view_close",
        [V .. "/tab_council"] = "view:council",
        [V .. "/tab_factions"] = "view:factions",
    }
    local text = {
        [V .. "/edicts_view/edict_fund"] = require("render.windows.council").fund_text(ctx, d),
    }

    -- the policy categories (CPoliciesView::UpdatePolicies): those with policies, by their names,
    -- `uncategorized` last; all collapsed at first (the collapsed set starts with every key); a
    -- header's click expands or collapses it (ToggleCategoryCollapsed), collapse_all_button
    -- collapses every one, or expands every one when all are collapsed
    -- (ToggleAllCategoriesCollapsed)
    local groups = M.policy_groups(ctx, d)
    local cats = {}
    for _, k in ipairs(C.def_order(ctx, "common/policy_categories")) do
        if k ~= "uncategorized" and groups[k] then
            cats[#cats + 1] = { key = k, name = C.loc(ctx, "policy_category_" .. k) }
        end
    end
    table.sort(cats, function(a, b2)
        return a.name < b2.name
    end)
    if groups.uncategorized then
        cats[#cats + 1] = { key = "uncategorized", name = C.loc(ctx, "policy_category_uncategorized") }
    end
    local any_open = false
    for _, cat in ipairs(cats) do
        any_open = any_open or state["cat_" .. cat.key] == "1"
    end
    local all = {}
    for _, cat in ipairs(cats) do
        all[#all + 1] = "cat_" .. cat.key .. "=" .. (any_open and "" or "1")
    end
    actions[V .. "/policies_view/collapse_all_button"] = "view_set:" .. table.concat(all, ";")
    local r = b:add(FILE, "edicts_and_policies_view", { actions = actions, text = text, hide = { in_breach_container = true } })

    local list = r.rects[V .. "/policies_view/policy_list_window/policy_list"]
    if list then
        local y, bottom = list.y, list.y + list.h
        for i, cat in ipairs(cats) do
            if y + 28 > bottom then
                break
            end
            local cdef = C.defs(ctx, "common/policy_categories")[cat.key]
            local icon = cdef and C.field(cdef, "icon")
            local prefix = "/policy_categories/" .. i
            local p = prefix .. "/policy_category_header_entry/"
            local name = cat.name
            if icon then
                name = "£" .. icon .. "£ " .. name
            end
            local open = state["cat_" .. cat.key] == "1"
            b:add(FILE, "policy_category_header_entry", {
                prefix = prefix, parent = { x = list.x, y = y, w = 0, h = 0 },
                -- (the status dot: every policy of the category can be changed here [I])
                hide = { icon_bad = true, icon_neutral = true },
                text = { [p .. "category_name"] = "§H" .. name .. "§!" },
                -- the arrow: 1 collapsed, 2 expanded
                frames = { [p .. "expand_icon"] = open and 2 or 1 },
                actions = { [p .. "background"] = "view_set:cat_" .. cat.key .. "=" .. (open and "" or "1") },
            })
            y = y + 28 + 1
            -- its policies (empire_policy_entry): the name and the option selected; a click
            -- shows its options (policy_option_entry), the selected one's radio button set; an
            -- option's click changes the policy (the simulation's command: cmd:edicts:policy)
            for j, g in ipairs(open and groups[cat.key] or {}) do
                if y + 30 > bottom then
                    break
                end
                local gp = prefix .. "/policies/" .. j
                local q = gp .. "/empire_policy_entry/"
                local expanded = state["pol_" .. g.key] == "1"
                local selected = d.policies[g.key]
                b:add(FILE, "empire_policy_entry", {
                    prefix = gp, parent = { x = list.x, y = y, w = 0, h = 0 },
                    text = { [q .. "policy_name"] = "policy_" .. g.key, [q .. "selected_option_name"] = selected or "" },
                    -- (can_change: on, the policies can be changed here [I: CanChangePolicy's
                    -- cooldown not read])
                    frames = { [q .. "can_change"] = 2, [q .. "expand_icon"] = expanded and 2 or 1 },
                    actions = { [q .. "background"] = "view_set:pol_" .. g.key .. "=" .. (expanded and "" or "1") },
                })
                y = y + 30
                if expanded then
                    for k2, opt in ipairs(M.policy_options(ctx, d, g.key)) do
                        if y + 30 > bottom then
                            break
                        end
                        local op = gp .. "/options/" .. k2
                        local o = op .. "/policy_option_entry/"
                        b:add(FILE, "policy_option_entry", {
                            prefix = op, parent = { x = list.x + 15, y = y, w = 0, h = 0 },
                            text = { [o .. "name"] = opt },
                            frames = { [o .. "is_selected"] = opt == selected and 2 or 1 },
                            actions = { [o .. "option_button"] = opt ~= selected and ("cmd:edicts:policy:" .. g.key .. ":" .. opt) or nil },
                        })
                        y = y + 30
                    end
                end
                y = y + 1
            end
        end
    end

    -- the edicts: the checkbox takes an edict or ends a perpetual one (CEdictsEntry::Select:
    -- CAddEdictCommand / CRemoveEdictCommand, the simulation's command: cmd:edicts:edict)
    local el = r.rects[V .. "/edicts_view/edict_list_window/edict_list"]
    if el then
        local y = el.y
        for i, k in ipairs(M.edicts(ctx, d)) do
            if y + 40 > el.y + el.h then
                break
            end
            local e = C.defs(ctx, "common/edicts")[k]
            local prefix = "/edicts/" .. i
            local p = prefix .. "/empire_edicts_entry/"
            local icon = e and C.field(e, "icon")
            local cost, upkeep = amount(ctx, k, "cost"), amount(ctx, k, "upkeep")
            local active = d.active[k] == true
            b:add(FILE, "empire_edicts_entry", {
                prefix = prefix, parent = { x = el.x, y = y, w = 0, h = 0 },
                hide = { active = not active or nil, upkeep = upkeep == nil or nil },
                -- the checkbox: 2 active, 3 can be taken, 1 cannot (PerFrameUpdate)
                frames = { [p .. "select_button"] = active and 2 or 3 },
                sprites = icon and { [p .. "type_icon"] = icon } or nil,
                text = {
                    [p .. "edicts_name"] = "edict_" .. k,
                    [p .. "cost"] = cost and ("§Y£unity£" .. math.floor(cost) .. "§!") or "",
                    [p .. "upkeep"] = upkeep and ("§Y£unity£" .. math.floor(upkeep) .. "§!") or "",
                },
                actions = { [p .. "select_button"] = "cmd:edicts:edict:" .. (active and "remove" or "add") .. ":" .. k },
            })
            y = y + 40 + 1
        end
    end
    return b.items, b.report
end


-- views.rs: the view's data, read where the galaxy is read (the save's world, or the
-- simulation's), for the player's country
function M.extract(game_dir)
    return M.data(require("render.topbar").player(), {})
end


-- its buttons' commands in the simulation (views.rs: `cmd:edicts:VERB:ARG...`, between days)
function M.command(...)
    return require("render.windows.empire_commands").run(...)
end

-- Escape (views.rs): the side windows in these state keys close first, else the view closes
M.escape_keys = {}

return M
