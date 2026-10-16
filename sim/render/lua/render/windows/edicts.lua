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
    for _, k in ipairs(C.def_order(ctx, "common/edicts")) do
        local e = C.defs(ctx, "common/edicts")[k]
        local ok = C.trigger(C.raw_field(e, "potential") or {}, d.facts)
        for _, t in ipairs(C.strings(C.raw_field(e, "prerequisites"))) do
            if not d.facts.techs[t] then
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

function M.build(ctx, d, state)
    local b = C.builder(ctx)
    local actions = {
        [V .. "/close"] = "view_close",
        [V .. "/tab_council"] = "view:council",
        [V .. "/tab_factions"] = "view:factions",
    }
    local text = {
        [V .. "/edicts_view/edict_fund"] = require("render.windows.council").fund_text(ctx, d),
    }
    local r = b:add(FILE, "edicts_and_policies_view", { actions = actions, text = text, hide = { in_breach_container = true } })

    -- the policy categories (CPoliciesView::UpdatePolicies): those with policies, by their names,
    -- `uncategorized` last; all collapsed at first
    local list = r.rects[V .. "/policies_view/policy_list_window/policy_list"]
    if list then
        local cats = {}
        for _, k in ipairs(C.def_order(ctx, "common/policy_categories")) do
            if k ~= "uncategorized" then
                cats[#cats + 1] = { key = k, name = C.loc(ctx, "policy_category_" .. k) }
            end
        end
        table.sort(cats, function(a, b2)
            return a.name < b2.name
        end)
        local y = list.y
        for i, cat in ipairs(cats) do
            local cdef = C.defs(ctx, "common/policy_categories")[cat.key]
            local icon = cdef and C.field(cdef, "icon")
            local prefix = "/policy_categories/" .. i
            local p = prefix .. "/policy_category_header_entry/"
            local name = cat.name
            if icon then
                name = "£" .. icon .. "£ " .. name
            end
            b:add(FILE, "policy_category_header_entry", {
                prefix = prefix, parent = { x = list.x, y = y, w = 0, h = 0 },
                hide = { icon_bad = true, icon_neutral = true },
                text = { [p .. "category_name"] = "§H" .. name .. "§!" },
                frames = { [p .. "expand_icon"] = 1 },
            })
            y = y + 28 + 1
        end
    end

    -- the edicts
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

return M
