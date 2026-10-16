-- render/windows/technology_policies.lua : the research view's Policies popup (4.5.2 Linux;
-- docs/windows/research.md): CCategoryPoliciesView for the policy category `research`
-- (interface/category_policies_view.gui), its rows (CEmpirePolicyEntry), the confirmation
-- (CPolicyDialog on standard_dialog.gui) and CSetPolicyCommand. (No `extract`: not a view;
-- technology.lua calls it.)
--
--   policies.extract(cid, today)                -> the rows' data (in the simulation's runtime)
--   policies.build(ctx, data, state, layout, parent)
--   policies.command(cid, group, option, today) -> what it did

local policies = {}

local CATEGORY = "research"
local POLICY_YEARS = 10   -- NDefines.NGameplay.POLICY_YEARS

local function unquote(s)
    return type(s) == "string" and (s:gsub('^"(.*)"$', "%1")) or s
end

-- ---------------------------------------------------------------------------------------------
-- the simulation's side

-- the policy groups of the category (common/policies `category = research`), in the database's order
local function groups(defs)
    local list = {}
    for key, d in pairs(defs.folder("common/policies")) do
        local cat = defs.field(d.block, "category")
        if cat == CATEGORY then
            list[#list + 1] = { key = key, def = d }
        end
    end
    table.sort(list, function(a, b)
        if a.def.file ~= b.def.file then return tostring(a.def.file) < tostring(b.def.file) end
        return (a.def.line or 0) < (b.def.line or 0)
    end)
    return list
end

local function options_of(block)
    local out = {}
    for _, e in ipairs(block) do
        if e.op and e.key and e.key.text == "option" and type(e.value) == "table" and e.value.text == nil then
            out[#out + 1] = e.value
        end
    end
    return out
end

local function holds(eval, cid, block, file)
    if type(block) ~= "table" then
        return true
    end
    local ok, r = pcall(eval.trigger, block, eval.new_ctx(eval.S("country", cid), nil, nil, file))
    return ok and r and true or false
end

-- the country's entry of a policy group in active_policies (SPolicyData), or nil
local function entry_of(world, c, key)
    local ap = world.field(c, "active_policies")
    for _, b in ipairs(type(ap) == "table" and world.blocks(ap) or {}) do
        if unquote(world.field(b, "policy")) == key then
            return b, ap
        end
    end
end

-- a date "Y.M.D" as days (30-day months, 360-day years: the game's calendar)
local function days(date)
    local y, m, d = tostring(date or ""):match("(%d+)%.(%d+)%.(%d+)")
    if not y then
        return nil
    end
    return (tonumber(y) * 12 + tonumber(m) - 1) * 30 + tonumber(d) - 1
end

-- SPolicyData::CanBeChanged: never changed by the player (no date), or POLICY_YEARS after it
-- (and the group allowed: `allow`)
local function can_change(world, eval, cid, entry, def, today)
    local date = unquote(world.field(entry, "date"))
    local ok = true
    if date then
        local a, b = days(date), days(today)
        ok = not (a and b) or a + POLICY_YEARS * 360 <= b
    end
    return ok and holds(eval, cid, require("engine.defs").field(def.block, "allow"), def.file), date
end

-- policies.extract(cid, today) -> { { key, selected, until, can, options = { { name, valid } } } }:
-- the groups of the category the country has an option of and that are potential
-- (CCategoryPoliciesView::Update: HasPolicyData and CPolicyGroup::IsPotential), their options
-- that are potential (CPolicyOption::IsPotential), valid when the policy can change and the option
-- is valid for the country (IsValidForCountry: `valid`) [I: the trigger's name]
function policies.extract(cid, today)
    local world = require("engine.world")
    local defs = require("engine.defs")
    local eval = require("simscript.eval")
    local c = world.object("country", cid)
    if not c then
        return nil
    end
    local out = {}
    for _, g in ipairs(groups(defs)) do
        local entry = entry_of(world, c, g.key)
        if entry and holds(eval, cid, defs.field(g.def.block, "potential"), g.def.file) then
            local can, date = can_change(world, eval, cid, entry, g.def, today)
            local row = { key = g.key, selected = unquote(world.field(entry, "selected")), can = can, options = {} }
            if date then
                local y, m, d = tostring(date):match("(%d+)%.(%d+)%.(%d+)")
                row["until"] = y and string.format("%d.%s.%s", tonumber(y) + POLICY_YEARS, m, d) or nil
            end
            for _, o in ipairs(options_of(g.def.block)) do
                if holds(eval, cid, defs.field(o, "potential"), g.def.file) then
                    local name = unquote(defs.field(o, "name"))
                    row.options[#row.options + 1] = {
                        name = name, valid = can and holds(eval, cid, defs.field(o, "valid"), g.def.file),
                    }
                end
            end
            out[#out + 1] = row
        end
    end
    return out
end

-- policies.command(cid, group, option, today): CSetPolicyCommand (IsValid 0x22aa160: the group and
-- the option potential, the option valid, CanChangePolicy; Execute: CCountry::ChangePolicy
-- 0x2399b40 with a date): the option selected, the date set (the cooldown), policy_flags made
-- again from the options, the old option's on_disabled and the new one's on_enabled, the modifiers
-- invalidated, on_policy_changed
function policies.command(cid, group, option, today)
    local world = require("engine.world")
    local defs = require("engine.defs")
    local eval = require("simscript.eval")
    local c = world.object("country", cid)
    local d = defs.get("common/policies", group or "")
    if not c or not d then
        return "refused: no policy " .. tostring(group)
    end
    local entry = entry_of(world, c, group)
    if not entry then
        return "refused: no " .. group .. " here"
    end
    local new, old
    local current = unquote(world.field(entry, "selected"))
    for _, o in ipairs(options_of(d.block)) do
        local name = unquote(defs.field(o, "name"))
        if name == option then new = o end
        if name == current then old = o end
    end
    if not new or option == current then
        return "refused: " .. tostring(option)
    end
    local can = can_change(world, eval, cid, entry, d, today)
    if not (holds(eval, cid, defs.field(d.block, "potential"), d.file) and holds(eval, cid, defs.field(new, "potential"), d.file)
        and holds(eval, cid, defs.field(new, "valid"), d.file) and can) then
        return "refused: " .. option .. " cannot be chosen now"
    end
    -- the option and the date (SPolicyData +0x10, +0x18)
    local sel = world.token_entry(entry, "selected")
    if sel then
        world.set_entry(entry, sel, option)
    else
        world.append(entry, "selected", option, true)
    end
    if world.token_entry(entry, "date") then
        world.set(entry, "date", today)
    else
        world.append(entry, "date", today, true)
    end
    -- UpdatePolicyFlags: the flags of every active option
    local flags = {}
    for _, b in ipairs(world.blocks(world.field(c, "active_policies"))) do
        local pd = defs.get("common/policies", unquote(world.field(b, "policy")) or "")
        local sname = unquote(world.field(b, "selected"))
        for _, o in ipairs(pd and options_of(pd.block) or {}) do
            if unquote(defs.field(o, "name")) == sname then
                local pf = defs.field(o, "policy_flags")
                for _, e in ipairs(type(pf) == "table" and pf or {}) do
                    if e.text then flags[#flags + 1] = { text = e.text } end
                end
            end
        end
    end
    world.replace(world.child(c, "policy_flags"), flags)
    -- the effects, the modifiers, the on_action
    local function run(block)
        if type(block) == "table" and #block > 0 then
            pcall(eval.effect, block, eval.new_ctx(eval.S("country", cid), nil, nil, d.file))
            pcall(eval.sync)
        end
    end
    run(old and defs.field(old, "on_disabled"))
    run(defs.field(new, "on_enabled"))
    local economy = package.loaded["engine.economy"]
    if economy and economy.invalidate then
        economy.invalidate()
    end
    local host = require("simscript.host")
    if host.on_action then
        pcall(host.on_action, "on_policy_changed", "country", cid)
    end
    return group .. " = " .. option
end

-- ---------------------------------------------------------------------------------------------
-- the layout

local FILE = "interface/category_policies_view.gui"
local ROW, OPTION = 30, 27

local function name_of(loc, keys)
    for _, k in ipairs(keys) do
        if loc and loc.has(k) then
            return (loc.get(k))
        end
    end
    return keys[1]
end

-- a localised text with its $VAR$ (and $VAR|C$, in colour C) replaced
local function format(loc, key, vars)
    local t = loc and loc.has(key) and loc.raw(key) or key
    return (t:gsub("%$([%w_]+)|?(%w*)%$", function(k, colour)
        local v = vars[k]
        if v == nil then
            return nil
        end
        v = tostring(v)
        return colour ~= "" and ("\194\167" .. colour .. v .. "\194\167!") or v
    end))
end

local function option_name(loc, name)
    return name_of(loc, { name, "policy_" .. name, name .. "_name" })
end

-- policies.build(ctx, rows, state, layout, at): the popup with its top left at `at` (the
-- researched window's: NGuiUtil::OpenAtWindow), then the confirmation over it
function policies.build(ctx, rows, state, layout, at)
    rows = rows or {}
    local P = "/category_policies_view"
    local r = layout(FILE, "category_policies_view", {
        parent = { x = at.x, y = at.y, w = 0, h = 0 },
        -- the header: the category's icon and name (Show 0x30e7460)
        text = { [P .. "/header"] = "\194\163research\194\163 " .. name_of(ctx.loc, { "RESEARCH", "research" }) },
        actions = { [P .. "/close_button"] = "view_set:policies=;expand=;policy_confirm=" },
    })
    local list = r.rects[P .. "/policy_list"]
    if not list then
        return
    end
    -- the rows sorted by name (CPolicyGroup::GetName: policy_KEY)
    local sorted = {}
    for _, row in ipairs(rows) do
        sorted[#sorted + 1] = { row = row, name = name_of(ctx.loc, { "policy_" .. row.key, row.key }) }
    end
    table.sort(sorted, function(a, b) return a.name < b.name end)
    local y = list.y
    for i, s in ipairs(sorted) do
        local row = s.row
        local expanded = state.expand == row.key
        local prefix = "/policies/" .. i
        local E = prefix .. "/category_policy_entry"
        local selected = row.selected and option_name(ctx.loc, row.selected) or ""
        layout(FILE, "category_policy_entry", {
            prefix = prefix, parent = { x = list.x, y = y, w = 0, h = 0 },
            -- (the entry's own `position` is the list's business)
            positions = { [E] = { 0, 0 } },
            text = { [E .. "/policy_name"] = s.name, [E .. "/selected_option_name"] = selected },
            -- can_change: frame 2 when the policy can change, 1 locked (CanChangePolicy + 1);
            -- expand_icon 2 expanded
            frames = { [E .. "/can_change"] = row.can and 2 or 1, [E .. "/expand_icon"] = expanded and 2 or 1 },
            -- a click expands or collapses its options (OnClick 0x30ec080)
            actions = { [E .. "/background"] = "view_set:policy_confirm=;expand=" .. (expanded and "" or row.key) },
            hide = { options = true },
        })
        local h = ROW
        if expanded then
            -- the potential options, in the script's order (CEmpirePolicyEntry::Update)
            for k, o in ipairs(row.options or {}) do
                local q = prefix .. "/option/" .. k
                local O = q .. "/category_policy_option_entry"
                local current = o.name == row.selected
                local enabled = o.valid and not current
                layout(FILE, "category_policy_option_entry", {
                    prefix = q, parent = { x = list.x + 15, y = y + ROW + OPTION * (k - 1), w = 0, h = 0 },
                    text = { [O .. "/name"] = option_name(ctx.loc, o.name) },
                    -- (its text box has no maxWidth: the row's width)
                    sizes = { [O .. "/name"] = { 500, 20 } },
                    frames = { [O .. "/is_selected"] = current and 2 or 1 },
                    disabled = not o.valid and { [O .. "/option_button"] = true, [O .. "/is_selected"] = true } or nil,
                    -- a click asks for confirmation (OnPolicyOptionClicked: CPolicyDialog)
                    actions = { [O .. "/option_button"] = enabled and ("view_set:policy_confirm=" .. row.key .. ":" .. o.name) or nil },
                })
            end
            h = ROW + OPTION * #(row.options or {})
        end
        y = y + h + 1
    end
    -- the confirmation (CPolicyDialog: CHANGE_POLICY, POLICY_DIALOG with the option's description)
    if state.policy_confirm then
        local group, option = state.policy_confirm:match("^([^:]+):(.+)$")
        if group then
            local S = "/standard_dialog"
            local desc = format(ctx.loc, "POLICY_DIALOG", {
                POLICY = name_of(ctx.loc, { "policy_" .. group, group }), OPTION = option_name(ctx.loc, option),
                TIME = POLICY_YEARS, EFFECTS = name_of(ctx.loc, { option .. "_desc", "policy_" .. option .. "_desc", "" }),
            })
            layout("interface/standard_dialog.gui", "standard_dialog", {
                text = {
                    [S .. "/title"] = "CHANGE_POLICY", [S .. "/description"] = desc,
                    [S .. "/AgreeButton"] = "YES", [S .. "/DeclineButton"] = "NO",
                },
                actions = {
                    [S .. "/AgreeButton"] = "cmd:technology:policy:" .. group .. ":" .. option .. "#policy_confirm=",
                    [S .. "/DeclineButton"] = "view_set:policy_confirm=",
                },
            })
        end
    end
end

return policies
