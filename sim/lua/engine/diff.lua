-- engine/diff.lua : the world against another save of the same game, field by field. Run the
-- simulation from one save to the date of a later one the game wrote, then compare: what the game
-- did that the simulation does not (and the other way round) shows by store and by field. The
-- player's and the AI's commands in between are not in the saves, so some differences are theirs;
-- the report is a map of where to look, not a verdict.
--
--   local diff = require("engine.diff")
--   local report = diff.run(other_gamestate_text [, top])

local world = require("engine.world")

local diff = {}

-- every scalar of an object, by path (`modules.standard_economy_module.resources.energy`); a key
-- written more than once gets #2, #3, ... (lists of blocks: their position)
local function flatten(block, prefix, out, depth)
    out = out or {}
    if depth > 6 then
        return out
    end
    local seen = {}
    local n_values = 0
    for _, e in ipairs(block) do
        if e.op and e.key then
            local k = e.key.text
            seen[k] = (seen[k] or 0) + 1
            local path = prefix .. k .. (seen[k] > 1 and ("#" .. seen[k]) or "")
            if e.value.text then
                out[path] = e.value.text
            else
                flatten(e.value, path .. ".", out, depth + 1)
            end
        elseif e.text then
            n_values = n_values + 1
            out[prefix .. "[" .. n_values .. "]"] = e.text
        else
            n_values = n_values + 1
            flatten(e, prefix .. "[" .. n_values .. "].", out, depth + 1)
        end
    end
    return out
end

local function same(a, b)
    if a == b then
        return true
    end
    local x, y = tonumber(a), tonumber(b)
    if x and y then
        return math.abs(x - y) <= 1e-3 * math.max(1, math.abs(x), math.abs(y))
    end
    return false
end

-- a path with its object-specific parts (positions, ids in keys) made general, to count by field
local function general(path)
    return (path:gsub("%[%d+%]", "[]"):gsub("#%d+", ""):gsub("%.%d+%.", ".<id>."))
end

-- diff.run(text[, top]) -> report: this world against the gamestate `text`
function diff.run(text, top)
    top = top or 12
    local other, message = world.parse_stores(text)
    if not other then
        return "diff: cannot parse the other save: " .. tostring(message)
    end
    local lines = { string.format("diff: the world (%s) against the other save (%s)", tostring(world.meta.date),
        tostring(other["@date"])) }
    local names = {}
    for name in pairs(world.stores) do
        if other[name] then
            names[#names + 1] = name
        end
    end
    table.sort(names, function(a, b) return #world.ids[a] > #world.ids[b] end)
    local total_eq, total_ne = 0, 0
    for _, name in ipairs(names) do
        local mine, theirs = world.stores[name], other[name]
        local only_mine, only_theirs, both = 0, 0, 0
        local eq, ne, by_field, example = 0, 0, {}, {}
        for id, obj in pairs(mine) do
            local o = theirs[id]
            if o == nil then
                only_mine = only_mine + 1
            else
                both = both + 1
                local a, b = flatten(obj, "", nil, 0), flatten(o, "", nil, 0)
                for path, v in pairs(a) do
                    local w = b[path]
                    if same(v, w) then
                        eq = eq + 1
                    else
                        ne = ne + 1
                        local g = general(path)
                        by_field[g] = (by_field[g] or 0) + 1
                        example[g] = example[g] or string.format("%s %s: %s -> %s", name, tostring(id), tostring(v), tostring(w))
                    end
                end
                for path, w in pairs(b) do
                    if a[path] == nil then
                        ne = ne + 1
                        local g = general(path)
                        by_field[g] = (by_field[g] or 0) + 1
                        example[g] = example[g] or string.format("%s %s: (none) -> %s", name, tostring(id), tostring(w))
                    end
                end
            end
        end
        for id in pairs(theirs) do
            if mine[id] == nil then
                only_theirs = only_theirs + 1
            end
        end
        total_eq, total_ne = total_eq + eq, total_ne + ne
        lines[#lines + 1] = string.format("  %-28s %6d in both, %5d only here, %5d only there; fields %d equal, %d differ (%.1f%%)",
            name, both, only_mine, only_theirs, eq, ne, eq + ne > 0 and 100 * eq / (eq + ne) or 100)
        local fields = {}
        for g, n in pairs(by_field) do
            fields[#fields + 1] = { g, n }
        end
        table.sort(fields, function(a, b) return a[2] > b[2] end)
        for i = 1, math.min(top, #fields) do
            if fields[i][2] >= 5 then
                lines[#lines + 1] = string.format("      %7d  %-50s e.g. %s", fields[i][2], fields[i][1]:sub(1, 50),
                    example[fields[i][1]]:sub(1, 90))
            end
        end
    end
    table.insert(lines, 2, string.format("diff: %d fields equal, %d differ (%.1f%% equal) in the %d stores both have",
        total_eq, total_ne, 100 * total_eq / math.max(1, total_eq + total_ne), #names))
    return table.concat(lines, "\n")
end


-- diff.snapshot_stockpiles() -> { [country] = { [resource] = value } }: the stockpiles now (taken
-- before a run, to compare the changes with the game's)
function diff.snapshot_stockpiles()
    local out = {}
    for _, id in ipairs(world.all("country")) do
        local res = world.path(world.object("country", id), "modules", "standard_economy_module", "resources")
        local t = {}
        for _, e in ipairs(type(res) == "table" and res or {}) do
            if e.op and e.value.text then
                t[e.key.text] = tonumber(e.value.text)
            end
        end
        out[id] = t
    end
    return out
end

-- diff.stockpiles(text, before) -> report: per resource, the stockpiles' change in the game (its
-- save `text`) against the simulation's, over every country of both: how much of the game's
-- change the simulation made (the share of the absolute change explained, 1 - sum|sim - game| /
-- sum|game - before|)
function diff.stockpiles(text, before)
    local other = world.parse_stores(text)
    if not other then
        return "stockpiles: cannot parse the other save"
    end
    local now = diff.snapshot_stockpiles()
    local per = {}
    for id, b in pairs(before) do
        local o = other.country and other.country[id]
        local res = o and world.path(o, "modules", "standard_economy_module", "resources")
        local game = {}
        for _, e in ipairs(type(res) == "table" and res or {}) do
            if e.op and e.value.text then
                game[e.key.text] = tonumber(e.value.text)
            end
        end
        if o then
            for r, v0 in pairs(b) do
                local g, s = game[r] or 0, (now[id] or {})[r] or 0
                local p = per[r] or { change = 0, miss = 0, still = 0, n = 0 }
                p.change = p.change + math.abs(g - v0)
                p.miss = p.miss + math.abs(s - g)
                p.still = p.still + math.abs(v0 - g)
                p.n = p.n + 1
                per[r] = p
            end
        end
    end
    local names = {}
    for r in pairs(per) do
        names[#names + 1] = r
    end
    table.sort(names)
    local lines = { "stockpiles: per resource, over the countries of both saves: the game's change, how far the simulation ends from the game, and (for reference) how far standing still would" }
    for _, r in ipairs(names) do
        local p = per[r]
        lines[#lines + 1] = string.format("  %-22s %3d countries: game change %12.1f; sim off by %12.1f (%5.1f%% of the change explained); standing still off by %12.1f",
            r, p.n, p.change, p.miss, p.change > 0 and 100 * (1 - p.miss / p.change) or 100, p.still)
    end
    return table.concat(lines, "\n")
end

-- research: per country, the technologies it has and the first technology of each area's queue
-- with its progress, from a country block (of this world or of another save)
local AREAS = { "physics", "society", "engineering" }
local function research_of(c)
    local status = world.field(c, "tech_status")
    local out = { techs = {}, queue = {} }
    if type(status) ~= "table" then
        return out
    end
    for _, e in ipairs(status) do
        if e.op and e.key and e.key.text == "technology" and e.value.text then
            out.techs[e.value.text] = true
        end
    end
    for _, area in ipairs(AREAS) do
        local q = world.field(status, area .. "_queue")
        local first = type(q) == "table" and world.blocks(q)[1]
        if first then
            out.queue[area] = { tech = world.field(first, "technology"), progress = tonumber(world.field(first, "progress")) or 0 }
        end
    end
    return out
end

-- diff.snapshot_research() -> { [country] = research_of } now (taken before a run)
function diff.snapshot_research()
    local out = {}
    for _, id in ipairs(world.all("country")) do
        out[id] = research_of(world.object("country", id))
    end
    return out
end

-- diff.research(text, before) -> report: for each area being researched at the start, the progress
-- the game made on that technology against the simulation's (while both still research it), and
-- the technologies each completed
function diff.research(text, before)
    local other = world.parse_stores(text)
    if not other then
        return "research: cannot parse the other save"
    end
    local n, change, miss = 0, 0, 0
    local done_game, done_sim, done_both = 0, 0, 0
    local examples = {}
    for id, b in pairs(before) do
        local o = other.country and other.country[id]
        local me = world.object("country", id)
        if o and me then
            local g, s = research_of(o), research_of(me)
            for _, area in ipairs(AREAS) do
                local q0 = b.queue[area]
                if q0 and q0.tech then
                    local gq, sq = g.queue[area], s.queue[area]
                    local g_on = gq and gq.tech == q0.tech
                    local s_on = sq and sq.tech == q0.tech
                    if g_on and s_on then
                        n = n + 1
                        local dg, ds = gq.progress - q0.progress, sq.progress - q0.progress
                        change, miss = change + math.abs(dg), miss + math.abs(ds - dg)
                        if math.abs(ds - dg) > 1e-3 * math.max(1, math.abs(dg)) and #examples < 8 then
                            examples[#examples + 1] = string.format("    country %d %s %s: game +%.2f, sim +%.2f", id, area, q0.tech, dg, ds)
                        end
                    end
                end
            end
            for t in pairs(g.techs) do
                if not b.techs[t] then
                    done_game = done_game + 1
                    if s.techs[t] then done_both = done_both + 1 end
                end
            end
            for t in pairs(s.techs) do
                if not b.techs[t] then
                    done_sim = done_sim + 1
                end
            end
        end
    end
    local lines = {
        string.format("research: %d areas researching the same technology in both: game progress %.1f, sim off by %.1f (%.1f%% explained)",
            n, change, miss, change > 0 and 100 * (1 - miss / change) or 100),
        string.format("research: technologies completed: %d in the game, %d in the simulation, %d in both",
            done_game, done_sim, done_both),
    }
    for _, l in ipairs(examples) do
        lines[#lines + 1] = l
    end
    return table.concat(lines, "\n")
end

return diff
