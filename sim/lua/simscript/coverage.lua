-- simscript/coverage.lua : parse every vanilla script file with pdxscript; count the trigger and
-- effect keywords vanilla uses and how many of those uses the Lua layer implements.
--
-- The census reads each file's tree in context: blocks named like trigger blocks (`trigger`,
-- `limit`, `potential`, `allow`, ...) hold triggers, effect blocks (`immediate`, `effect`, `option`,
-- `on_built`, ...) hold effects, weight blocks (`ai_chance`, `mean_time_to_happen`, `weight`, ...)
-- hold `modifier = { }` blocks of triggers; scripted triggers are trigger blocks, scripted effects
-- effect blocks. Inside, logic, `if`, scope changes and iterators are followed; other blocks are a
-- trigger's or effect's parameters. Inline script files are not walked (their content is counted
-- nowhere: their context is the caller's).

local pdxscript = require("pdxscript")
local db = require("simscript.db")
local eval = require("simscript.eval")

local C = {}

local function set(list)
    local t = {}
    for _, k in ipairs(list) do t[k] = true end
    return t
end

local TRIGGER_BLOCKS = set({
    "trigger", "limit", "potential", "allow", "possible", "pre_triggers", "is_valid", "valid", "condition",
    "conditions", "show_tech_unlock_if", "destroy_trigger", "can_build", "active", "can_be_activated",
    "can_activate", "available", "visible", "is_visible", "shown", "enabled", "requirement", "requirements",
    "can_start", "can_end", "can_cancel", "can_join", "can_leave", "can_enact", "can_repeal",
    "potential_trigger", "valid_target", "complete_trigger", "can_create", "leader_potential",
    "triggered_modifier_potential", "planet_modifier_potential", "show_in_outliner", "can_use",
    "can_research", "can_upgrade", "can_downgrade", "can_be_built", "should_abort", "abort_trigger",
    "target_potential", "selectable", "exclusive_trigger", "is_situation_valid", "fail_trigger",
})
local EFFECT_BLOCKS = set({
    "immediate", "effect", "after", "option", "on_queued", "on_unqueued", "on_built", "on_destroy",
    "on_enabled", "on_disabled", "on_success", "on_fail", "on_failure", "on_start", "on_end", "on_monthly",
    "on_activate", "on_deactivate", "on_add", "on_remove", "on_gain", "on_loss", "on_completion",
    "on_complete", "on_cancel", "on_expire", "on_enact", "on_repeal", "on_accept", "on_decline",
    "on_finished", "on_progress", "on_yearly", "on_daily", "on_upgraded", "on_downgraded", "on_repaired",
    "on_destroyed", "on_created", "on_select", "on_unselect", "on_spawn", "abort_effect", "on_join",
    "on_leave", "on_abort", "on_timeout", "on_fire", "on_roll_failed", "on_roll_success", "on_enabled_effect",
    "on_researched", "on_unlock", "on_gained", "on_lost", "on_stage_start", "on_stage_end", "on_resolve",
})
local WEIGHT_BLOCKS = set({
    "ai_chance", "ai_weight", "weight", "mean_time_to_happen", "chance", "ai_will_do", "weight_modifier",
    "spawn_chance", "ai_priority", "ai_value", "ai_resolution_value", "acceptance", "value",
})
local LOGIC = set({ "and", "or", "not", "nor", "nand", "hidden_trigger", "custom_tooltip", "calc_true_if",
    "if", "else_if", "else", "hidden_effect", "while", "random", "custom_tooltip_fail" })
local PARAMS = set({ "factor", "add", "multiply", "mult", "subtract", "base", "weight", "count", "text",
    "fail_text", "amount", "chance", "days", "months", "years", "order_by", "position", "max", "min",
    "list", "check_range_bounds", "success_text", "divide", "value", "desc" })
-- the parameters of an event option (not effects)
local OPTION_PARAMS = set({ "name", "response_text", "is_dialog_only", "default_hide_option", "custom_gui",
    "tooltip", "sound", "highlight", "is_exclusive_option", "show_unlock_hint", "title", "desc", "modifier" })
local OPTION_TRIGGERS = set({ "trigger", "allow", "exclusive_trigger" })

local census = { trigger = {}, effect = {} }

local function record(kind, key, file, line)
    if key:find("[%$@%[]") or tonumber(key) then return end
    local t = census[kind]
    local r = t[key]
    if not r then
        r = { key = key, count = 0, first = file .. ":" .. tostring(line) }
        t[key] = r
    end
    r.count = r.count + 1
end

local walk

local function is_followed(kind, key, lk)
    if LOGIC[lk] then return true end
    local st = eval.status(kind, key)
    if st == "scope" or st == "iterator" then return true end
    if lk:match("^any_") or lk:match("^count_") or lk:match("^every_") or lk:match("^random_")
        or lk:match("^ordered_") then return true end
    return false
end

walk = function(b, ctx, file)
    for _, e in ipairs(b) do
        if e.op and e.key then
            local key = e.key.text
            local lk = key:lower()
            local v = e.value
            local block = v and v.text == nil
            if ctx == nil then
                if block then
                    if TRIGGER_BLOCKS[lk] then walk(v, "trigger", file)
                    elseif EFFECT_BLOCKS[lk] then walk(v, "effect", file)
                    elseif WEIGHT_BLOCKS[lk] then walk(v, "weight", file)
                    else walk(v, nil, file) end
                end
            elseif ctx == "weight" then
                if block then
                    if lk == "modifier" then walk(v, "trigger", file)
                    elseif lk == "if" or lk == "else_if" or lk == "else" or lk == "limit" then walk(v, "trigger", file)
                    else walk(v, "weight", file) end
                end
            elseif ctx == "effect" and OPTION_PARAMS[lk] then
                -- an option's or a block's parameters
            elseif ctx == "effect" and OPTION_TRIGGERS[lk] and block then
                walk(v, "trigger", file)
            elseif ctx == "effect" and lk == "ai_chance" and block then
                walk(v, "weight", file)
            elseif PARAMS[lk] or lk == "limit" then
                if block and lk == "limit" then walk(v, "trigger", file)
                elseif block and lk == "modifier" then walk(v, "trigger", file) end
            else
                record(ctx, key, file, e.line)
                if block then
                    if ctx == "effect" and lk == "random_list" then
                        for _, x in ipairs(v) do
                            if x.op and x.value.text == nil then walk(x.value, "effect", file) end
                        end
                    elseif is_followed(ctx, key, lk) then
                        walk(v, ctx, file)
                    elseif lk == "modifier" then
                        walk(v, "trigger", file)
                    end
                end
            end
        end
    end
end

local ROOTS = { "common", "events", "map", "prescripted_countries", "flags" }

function C.run()
    local t0 = RUST.clock()
    local folders, order = {}, {}
    local failures = {}
    local total_files, total_failed, total_warn = 0, 0, 0
    census = { trigger = {}, effect = {} }
    for _, root in ipairs(ROOTS) do
        for _, rel in ipairs(RUST.list_files(db.game_dir, root)) do
            local folder = rel:match("^(common/[^/]+)/") or rel:match("^(map/[^/]+)/") or rel:match("^([^/]+)/") or rel
            local f = folders[folder]
            if not f then
                f = { name = folder, files = 0, failed = 0, warnings = 0 }
                folders[folder] = f
                order[#order + 1] = folder
            end
            f.files = f.files + 1
            total_files = total_files + 1
            local text = db.read_file(db.game_dir .. "/" .. rel)
            local tree, msg = nil, "unreadable"
            if text then tree, msg = pdxscript.parse(text, rel) end
            if not tree then
                f.failed = f.failed + 1
                total_failed = total_failed + 1
                failures[#failures + 1] = msg
            else
                f.warnings = f.warnings + #tree.warnings
                total_warn = total_warn + #tree.warnings
                if not rel:match("^common/inline_scripts/") then
                    local ctx
                    if rel:match("^common/scripted_triggers/") then ctx = "trigger"
                    elseif rel:match("^common/scripted_effects/") then ctx = "effect"
                    elseif rel:match("^common/script_values/") then ctx = "weight" end
                    if ctx then
                        for _, e in ipairs(tree) do
                            if e.op and e.value and e.value.text == nil then walk(e.value, ctx, rel) end
                        end
                    else
                        walk(tree, nil, rel)
                    end
                end
            end
        end
    end
    table.sort(order)
    local out = {}
    local function p(fmt, ...) out[#out + 1] = string.format(fmt, ...) end
    p("parse: %d files, %d failed, %d with warnings counted (%d warnings), %.1f s", total_files, total_failed, 0, total_warn, RUST.clock() - t0)
    for _, name in ipairs(order) do
        local f = folders[name]
        if f.failed > 0 or f.warnings > 0 then
            p("  %-45s %5d files  %3d failed  %3d warnings", name, f.files, f.failed, f.warnings)
        end
    end
    p("  (folders not listed: every file parsed without warnings)")
    for i = 1, math.min(20, #failures) do p("  failure: %s", failures[i]) end
    for _, kind in ipairs({ "trigger", "effect" }) do
        local list = {}
        for _, r in pairs(census[kind]) do list[#list + 1] = r end
        table.sort(list, function(a, b) if a.count ~= b.count then return a.count > b.count end return a.key < b.key end)
        local by = {}
        local doc = kind == "trigger" and db.doc_triggers or db.doc_effects
        local miss_doc, miss_other = {}, {}
        local uses, kws = 0, 0
        for _, r in ipairs(list) do
            local st = eval.status(kind, r.key) or (doc[r.key:lower()] and "missing (documented)" or "missing (not a documented " .. kind .. ")")
            local b = by[st]
            if not b then b = { kws = 0, uses = 0 }; by[st] = b end
            b.kws = b.kws + 1
            b.uses = b.uses + r.count
            uses = uses + r.count
            kws = kws + 1
            if st == "missing (documented)" then miss_doc[#miss_doc + 1] = r
            elseif st:sub(1, 7) == "missing" then miss_other[#miss_other + 1] = r end
        end
        p("%s keywords in vanilla: %d distinct, %d uses", kind, kws, uses)
        local names = {}
        for st in pairs(by) do names[#names + 1] = st end
        table.sort(names)
        local impl_k, impl_u = 0, 0
        for _, st in ipairs(names) do
            p("  %-40s %5d keywords %8d uses (%5.1f%%)", st, by[st].kws, by[st].uses, 100 * by[st].uses / math.max(1, uses))
            if st:sub(1, 7) ~= "missing" and st ~= "engine-unmodelled" then
                impl_k, impl_u = impl_k + by[st].kws, impl_u + by[st].uses
            end
        end
        p("  evaluated by the Lua layer: %d of %d keywords, %d of %d uses (%.1f%%)", impl_k, kws, impl_u, uses, 100 * impl_u / math.max(1, uses))
        p("  top missing documented %ss (uses, first use):", kind)
        for i = 1, math.min(25, #miss_doc) do
            p("    %-45s %7d  %s", miss_doc[i].key, miss_doc[i].count, miss_doc[i].first)
        end
        p("  top undocumented keys in %s context (parameters or unresolved names):", kind)
        for i = 1, math.min(10, #miss_other) do
            p("    %-45s %7d  %s", miss_other[i].key, miss_other[i].count, miss_other[i].first)
        end
    end
    return table.concat(out, "\n")
end

return C
