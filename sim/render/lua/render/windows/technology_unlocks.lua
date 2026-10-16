-- render/windows/technology_unlocks.lua : what a technology card's `unlocks` list shows, as
-- TechnologyViewAddUnlocks (0x32e2d80) fills it (4.5.2 Linux; docs/windows/research.md):
--
--   local unlocks = require("render.windows.technology_unlocks")
--   local entries = unlocks.entries(game_dir, loc, tech)
--   -- { { kind = "text", text = "§HUnlocks Building:§! ..." }
--   --   { kind = "component", header = "...", frames = { 2, 3, 4 } } ... }
--
-- In order: the modifier block (one entry, a line a modifier), then per unlock kind (ship sizes,
-- stations, armies, edicts, buildings, districts, policies, feature flags, diplomatic actions,
-- components, megastructures, starbase modules, starbase buildings, decisions, zones) the things
-- whose `prerequisites` (or `show_in_tech`) name the technology, then the technology's custom
-- `prereqfor_desc` entries. A typed `prereqfor_desc` (`ship = { title desc }`) stands for its
-- kind's lines; `hide_prereq_for_desc = KIND` hides a kind. (No `extract`: not a view.)

local source = require("stellar.script.source")
local get = require("render.gfx").get

local unlocks = {}

local function unquote(s)
    return type(s) == "string" and (s:gsub('^"(.*)"$', "%1")) or s
end

-- every technology named in a `prerequisites` block (AND/OR nodes recurse)
local function techs_in(block, out)
    out = out or {}
    if type(block) == "string" then
        out[#out + 1] = unquote(block)
    elseif type(block) == "table" then
        for _, e in ipairs(block) do
            if e.text then
                out[#out + 1] = unquote(e.text)
            elseif e.op and type(e.value) == "table" then
                techs_in(e.value.text or e.value, out)
            end
        end
    end
    return out
end

-- CXxx::ShouldShowTechUnlock: `show_tech_unlock_if` for the local country. Not evaluated against
-- the country here: the vanilla conditions name what an unusual empire has (is_nomadic = yes,
-- country_uses_bio_ships = yes, an origin, a civic), so `KEY = yes` is false and `KEY = no`
-- true, AND/OR/NOR/NOT combine them, and anything else holds [I: the player's ordinary empire]
local function holds(block, any)
    local result = not any
    for _, e in ipairs(block) do
        local v
        if e.op and e.key then
            local k = e.key.text
            if type(e.value) == "table" and e.value.text == nil then
                if k == "OR" then v = holds(e.value, true)
                elseif k == "NOR" then v = not holds(e.value, true)
                elseif k == "NOT" or k == "NAND" then v = not holds(e.value, false)
                elseif k == "AND" then v = holds(e.value, false)
                else v = true end
            elseif k:match("^has_.*_dlc$") then
                -- a DLC: the save's (its DLCs are the game's: view.sh loads it with them)
                v = e.value.text == "yes"
            elseif e.value.text == "yes" then
                v = false
            else
                v = true
            end
        end
        if v ~= nil then
            if any and v then return true end
            if not any and not v then return false end
        end
    end
    return result
end

local function shown(block)
    local cond = get(block, "show_tech_unlock_if")
    return type(cond) ~= "table" or holds(cond, false)
end

-- the kinds' order (ETechUnlock) and their prereqfor_desc / hide tokens
local KINDS = { "ship", "planet", "army", "edict", "trait", "building", "district", "policy_option", "policy",
    "feature", "diplo_action", "tech", "component", "resource", "deposit_blockers", "intel", "megastructure",
    "starbase_module", "starbase_building", "decision", "zone" }

local db
local function database(game_dir)
    if db then
        return db
    end
    db = { by = {}, techs = {}, sets = {} }
    for _, k in ipairs(KINDS) do
        db.by[k] = {}
    end
    local function add(kind, tech, item)
        local t = db.by[kind][tech]
        if not t then
            t = {}
            db.by[kind][tech] = t
        end
        t[#t + 1] = item
    end
    -- named definitions with `prerequisites` (and `show_in_tech`)
    local function named(dir, kind, make, show_in_tech_only)
        for key, def in pairs(source.definitions(game_dir, dir)) do
            local b = def.block
            if shown(b) then
                local item = make(key, b)
                if item then
                    item.order = { def.file or "", def.line or 0 }
                    if not show_in_tech_only then
                        for _, t in ipairs(techs_in(get(b, "prerequisites"))) do
                            add(kind, t, item)
                        end
                    end
                    for _, t in ipairs(techs_in(get(b, "show_in_tech"))) do
                        add(kind, t, item)
                    end
                end
            end
        end
    end
    named("common/ship_sizes", "ship", function(key, b)
        return { name = key, station = get(b, "is_space_station") == "yes" }
    end)
    named("common/armies", "army", function(key) return { name = key } end)
    named("common/edicts", "edict", function(key) return { name = "edict_" .. key } end)
    named("common/buildings", "building", function(key) return { name = key } end)
    named("common/districts", "district", function(key) return { name = key } end)
    named("common/policies", "policy", function(key) return { name = "policy_" .. key } end)
    named("common/diplomatic_actions", "diplo_action", function(key) return { name = key:upper() } end)
    named("common/megastructures", "megastructure", function(key, b)
        if get(b, "show_prereqs") ~= "yes" then
            return nil
        end
        return { name = unquote(get(b, "prereq_name")) or key }
    end)
    named("common/starbase_modules", "starbase_module", function(key, b)
        return { name = "sm_" .. key, starbase_type = get(b, "starbase_type") }
    end, true)
    named("common/starbase_buildings", "starbase_building", function(key, b)
        return { name = "sm_" .. key, starbase_type = get(b, "starbase_type") }
    end, true)
    named("common/decisions", "decision", function(key) return { name = key } end)
    named("common/zones", "zone", function(key) return { name = key } end, true)
    -- the policy groups' options (`option = { name = ... prerequisites = { ... } }`)
    for key, def in pairs(source.definitions(game_dir, "common/policies")) do
        for _, e in ipairs(def.block) do
            if e.op and e.key and e.key.text == "option" and type(e.value) == "table" and e.value.text == nil then
                local name = unquote(get(e.value, "name"))
                for _, t in ipairs(techs_in(get(e.value, "prerequisites"))) do
                    add("policy_option", t, { group = "policy_" .. key, name = name, order = { def.file or "", def.line or 0 } })
                end
            end
        end
    end
    -- the component sets (common/component_sets: key, is_core_component_set, fauna)
    for _, f in ipairs(source.files(game_dir, "common/component_sets", "txt")) do
        for _, e in ipairs(source.parse(game_dir, f) or {}) do
            if e.op and e.key and e.key.text == "component_set" and type(e.value) == "table" then
                local k = unquote(get(e.value, "key"))
                if k then
                    db.sets[k] = { core = get(e.value, "is_core_component_set") == "yes",
                        fauna = get(e.value, "is_space_fauna_component_set") == "yes" }
                end
            end
        end
    end
    -- the components: weapons, then utilities, then strike craft, each in load order
    local SIZE_FRAME = { point_defence = 1, small = 2, medium = 3, large = 4, torpedo = 5, extra_large = 6,
        titanic = 7, planet_killer = 8, engulf = 9, aux = 10 }
    local files = source.files(game_dir, "common/component_templates", "txt")
    for _, kind in ipairs({ "weapon_component_template", "utility_component_template", "strike_craft_component_template" }) do
        for _, f in ipairs(files) do
            for _, e in ipairs(source.parse(game_dir, f) or {}) do
                if e.op and e.key and e.key.text == kind and type(e.value) == "table" and e.value.text == nil then
                    local b = e.value
                    if shown(b) then
                        local set = unquote(get(b, "component_set"))
                        local item = {
                            set = set, key = unquote(get(b, "key")),
                            -- GetComponentIconFrame: strike craft 12, else the slot size + 1
                            frame = kind == "strike_craft_component_template" and 12 or SIZE_FRAME[get(b, "size") or ""] or 2,
                        }
                        for _, t in ipairs(techs_in(get(b, "prerequisites"))) do
                            add("component", t, item)
                        end
                    end
                end
            end
        end
    end
    -- in database order (file, then line) [I]
    for kind, by in pairs(db.by) do
        if kind ~= "component" then
            for _, list in pairs(by) do
                table.sort(list, function(a, b)
                    if a.order[1] ~= b.order[1] then return a.order[1] < b.order[1] end
                    return a.order[2] < b.order[2]
                end)
            end
        end
    end
    -- the technologies' own parts: modifier, feature_flags, prereqfor_desc
    for key, def in pairs(source.definitions(game_dir, "common/technology")) do
        local b = def.block
        local t = { modifier = {}, features = {}, typed = {}, custom = {}, hide = {} }
        local m = get(b, "modifier")
        for _, e in ipairs(type(m) == "table" and m or {}) do
            if e.op and e.key and e.value.text and tonumber(e.value.text) then
                t.modifier[#t.modifier + 1] = { key = e.key.text, value = tonumber(e.value.text) }
            end
        end
        for _, e in ipairs(type(get(b, "feature_flags")) == "table" and get(b, "feature_flags") or {}) do
            if e.text then
                t.features[#t.features + 1] = unquote(e.text)
            end
        end
        local p = get(b, "prereqfor_desc")
        for _, e in ipairs(type(p) == "table" and p or {}) do
            if e.op and e.key then
                local k = e.key.text
                if k == "hide_prereq_for_desc" and e.value.text then
                    t.hide[unquote(e.value.text)] = true
                elseif type(e.value) == "table" and e.value.text == nil then
                    local entry = { title = unquote(get(e.value, "title")), desc = unquote(get(e.value, "desc")) }
                    if k == "custom" then
                        t.custom[#t.custom + 1] = entry
                    else
                        t.typed[k] = entry
                    end
                end
            end
        end
        db.techs[key] = t
    end
    return db
end

-- ---------------------------------------------------------------------------------------------
-- the texts

-- a localised text with its $VAR$ replaced (a value that is a key: its text)
local function format(loc, key, vars)
    local t = loc and loc.has(key) and loc.raw(key) or key
    return (t:gsub("%$([%w_]+)|?(%w*)%$", function(k, colour)
        local v = vars[k]
        if v == nil then
            return nil
        end
        if loc and loc.has(v) then
            v = loc.get(v)
        end
        return colour ~= "" and ("\194\167" .. colour .. v .. "\194\167!") or v
    end))
end

local function name_of(loc, key)
    return loc and loc.has(key) and loc.get(key) or key
end

-- a modifier's line (CPdxModifier::GetFullDescription): its name, ": ", the value coloured, with
-- a sign; a percentage x 100 with "%"; at most 2 decimals, none for a whole number, cut. The
-- modifiers' flags (percentage, good) are the engine's: here a `_mult`, `_speed` or `_chance`
-- modifier is a percentage, and one of a cost, an upkeep or damage taken is not good [I]
local function modifier_line(loc, key, value)
    local name
    for _, k in ipairs({ "mod_" .. key, "MOD_" .. key:upper(), key }) do
        if loc and loc.has(k) then
            name = loc.get(k)
            break
        end
    end
    if not name or value == 0 then
        return nil
    end
    local pct = key:find("_mult$") or key:find("_speed") or key:find("_chance")
    local v = pct and value * 100 or value
    local text
    if math.abs(v - math.floor(v + 0.5)) < 1e-9 then
        text = string.format("%d", math.floor(v + 0.5))
    else
        local cut = (v >= 0 and math.floor(v * 100 + 1e-9) or -math.floor(-v * 100 + 1e-9)) / 100
        text = string.format("%.2f", cut)
    end
    if v > 0 then
        text = "+" .. text
    end
    if pct then
        text = text .. "%"
    end
    local bad = key:find("cost") or key:find("upkeep") or key:find("_taken")
    local good = (v > 0) ~= (bad ~= nil)
    return name .. ": \194\167" .. (good and "G" or "R") .. text .. "\194\167!"
end

-- the starbase module's and building's key by its starbase_type
local MODULE_KEY = { orbital_ring = "ORBITAL", arkship = "ARKSHIP", waystation = "WAYSTATION" }

-- unlocks.entries(game_dir, loc, tech) -> the card's entries, in the game's order
function unlocks.entries(game_dir, loc, tech)
    local d = database(game_dir)
    local t = d.techs[tech] or { modifier = {}, features = {}, typed = {}, custom = {}, hide = {} }
    local out = {}
    local function text(s)
        out[#out + 1] = { kind = "text", text = s }
    end
    local lines = {}
    for _, m in ipairs(t.modifier) do
        lines[#lines + 1] = modifier_line(loc, m.key, m.value)
    end
    if #lines > 0 then
        text(table.concat(lines, "\n"))
    end
    for _, kind in ipairs(KINDS) do
        local list = d.by[kind][tech] or {}
        if kind == "trait" or kind == "tech" or t.hide[kind] then
            -- never shown, or hidden by the technology
        elseif kind ~= "component" and t.typed[kind] then
            text(name_of(loc, t.typed[kind].title or ""))
        elseif kind == "ship" then
            local ships, stations = {}, {}
            for _, s in ipairs(list) do
                local n = name_of(loc, s.name)
                if s.station then stations[#stations + 1] = n else ships[#ships + 1] = n end
            end
            if #ships > 0 then text(format(loc, "TECH_UNLOCK_SHIP", { LIST = table.concat(ships, ", ") })) end
            if #stations > 0 then text(format(loc, "TECH_UNLOCK_STATION", { LIST = table.concat(stations, ", ") })) end
        elseif kind == "feature" then
            for _, f in ipairs(t.features) do
                text(format(loc, "TECH_UNLOCK_FEATURE", { NAME = "feature_" .. f }))
            end
        elseif kind == "component" then
            -- one entry per component set, its members' size icons
            local groups, by_set = {}, {}
            for _, c in ipairs(list) do
                local key = t.typed.component and "" or (c.set or c.key)
                local g = by_set[key]
                if not g then
                    g = { set = c.set, members = {} }
                    by_set[key] = g
                    groups[#groups + 1] = g
                end
                g.members[#g.members + 1] = c
            end
            for _, g in ipairs(groups) do
                local set = d.sets[g.set or ""] or {}
                if not set.fauna then
                    local frames = {}
                    for _, c in ipairs(g.members) do
                        frames[#frames + 1] = set.core and 11 or c.frame
                    end
                    local header = t.typed.component and t.typed.component.title and name_of(loc, t.typed.component.title)
                        or format(loc, "TECH_UNLOCK_COMPONENT", { NAME = g.set or "" })
                    out[#out + 1] = { kind = "component", header = header, frames = frames }
                end
            end
        elseif kind == "policy_option" then
            for _, o in ipairs(list) do
                text(format(loc, "TECH_UNLOCK_POLICY_OPTION", { POLICY = o.group, NAME = o.name or "" }))
            end
        elseif kind == "starbase_module" or kind == "starbase_building" then
            for _, o in ipairs(list) do
                local which = MODULE_KEY[o.starbase_type or ""] or "STARBASE"
                text(format(loc, "TECH_UNLOCK_" .. which .. (kind == "starbase_module" and "_MODULE" or "_BUILDING"), { NAME = o.name }))
            end
        else
            local KEY = ({ army = "TECH_UNLOCK_ARMY", edict = "TECH_UNLOCK_EDICT", building = "TECH_UNLOCK_BUILDING",
                district = "TECH_UNLOCK_DISTRICT", policy = "TECH_UNLOCK_POLICY_GROUP", diplo_action = "TECH_UNLOCK_DIPLOMATIC_ACTION",
                megastructure = "TECH_UNLOCK_MEGASTRUCTURE", decision = "TECH_UNLOCK_DECISION", zone = "TECH_UNLOCK_ZONE" })[kind]
            if KEY then
                for _, o in ipairs(list) do
                    text(format(loc, KEY, { NAME = o.name }))
                end
            end
        end
    end
    for _, c in ipairs(t.custom) do
        text(name_of(loc, c.title or ""))
    end
    return out
end

return unlocks
