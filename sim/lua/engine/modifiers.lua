-- engine/modifiers.lua : the modifier sources of the game's objects, from the world (a save) and the
-- vanilla files: what each object's modifier node gets from its own sources (the game's
-- CalculateModifier per object, docs/modifiers.md "Computing a node"), as the parts the game's node
-- records (CModifier::_Added): { name, mult, filter, values }, values in fixed point (1.0 =
-- 100000), the part added as value * mult / 100000 truncated toward zero, a type counted when its
-- categories meet the filter. The parents of a node (AddModifierNode: the country's node in a
-- planet's, a colony's in a pop group's) are not parts here: the graph links them
-- (stellar.graph.nodes).
--
--   local modifiers = require("engine.modifiers")
--   local src = modifiers.new({ types = graph_defs })   -- graph_defs: stellar.graph.modifiers.definitions()
--   src:parts("Country", 0)        -- the parts of country 0's node
--   src:parts("PopGroup", 148)
--   modifiers.fold(part, graph_defs) -- { [type] = value } as the part adds it
--
-- The categories (what each part is, as the 2210 capture shows the game's nodes):
--   Country: technologies (x level), traditions, ascension perks, government, authority, civics,
--     origin, the council agenda in progress, ethics, policies (the selected option), edicts,
--     timed modifiers, country type, with their triggered_modifier / triggered_country_modifier
--     blocks; council positions (x the councilor's skill: level + bonus + councilor_skill_add) and
--     the councilors' and ruler's traits (councilor_modifier, triggered_councilor_modifier); the
--     statics the engine adds (empire_base, playable_ai_empire, fallen_empire_base,
--     navy_coverage_shortage x the shortage, federation_tax).
--   Planet: planet class, timed modifiers (the random planet modifier is one), the deposits (one
--     part), the designation, the buildings (one part, their triggered blocks another), the
--     districts (one part, x level), the zones (one part; triggered_district_planet_modifier x the
--     district's level), the worked jobs (one part, x (workforce + bonus) / 100), the governor
--     (skill_<class>_planet_governor x skill; half the sector's when the colony has none).
--   Colony: the status statics (stability, amenities, housing, employment) x how far past their
--     threshold (S:colony).
--   PopGroup: pop category, the species' traits (one part, then each trait's triggered blocks),
--     the owner's species rights (living standard, citizenship, slavery / purge type, population
--     control; none in a fallen empire), low habitability.
-- Triggered blocks need the script layer (simscript.eval, loaded by engine.load); their potential
-- is evaluated in the object's scope. A block whose `mult` is another modifier's value
-- (`mult = modifier:x`) is given that value by self.resolve_ref (the graph's), when set.
-- engine/modifiers/check.lua compares all this with a capture of the game's nodes.

local bit = require("bit")
local source = require("stellar.script.source")

local M = {}

-- the category filter of each node's own parts (CModifier::_Categories of the node, as the 2210
-- capture shows it on every own part)
M.FILTER = {
    Country = 1354747902,
    Planet = 1074432514,
    Colony = 1074430466,
    PopGroup = 688130,
}
M.CATEGORIES = { "Country", "Planet", "Colony", "PopGroup" }

-- A key of a modifier block that is not a modifier type but names a static modifier
-- (`researcher_jobs_bonus_workforce_mult = 0.1`, common/static_modifiers/24_static_modifiers_jobs.txt)
-- adds that static modifier's entries times the value: a group of types under one name.

local function unq(s)
    if type(s) ~= "string" then
        return s
    end
    return (s:gsub('^"(.*)"$', "%1"))
end

-- a number of the script as the game's fixed point (1.0 = 100000)
local function fixed(x)
    local v = x * 100000
    return v >= 0 and math.floor(v + 0.5) or -math.floor(-v + 0.5)
end
M.fixed = fixed

-- the game's addition of a value with a multiplier: value * mult / 100000, truncated toward zero
local function scale(v, mult)
    if mult == 100000 then
        return v
    end
    local p = v * mult
    return (p - math.fmod(p, 100000)) / 100000
end
M.scale = scale

-- modifiers.fold(part, types) -> { [type name] = value }: what the part adds to its node (its
-- multiplier and filter applied; types: the graph's definitions, for the categories)
function M.fold(part, types)
    local out = {}
    local filter = part.filter or -1
    for t, v in pairs(part.values) do
        local ok = filter == 0 or filter == -1 or bit.band(types:categories(t), filter) ~= 0
        if ok then
            local x = scale(v, part.mult or 100000)
            if x ~= 0 then
                out[t] = (out[t] or 0) + x
            end
        end
    end
    return out
end

-- ---------------------------------------------------------------------------------------------
-- reading the vanilla files

local S = {}
S.__index = S

-- modifiers.new(opts) -> the sources: opts.types (the graph's definitions: the modifier types'
-- names, read case-insensitively as the game does), opts.defs (engine.defs), opts.world
-- (engine.world), opts.fs (the file system; default the script layer's, or opts.game_dir's)
function M.new(opts)
    opts = opts or {}
    local self = setmetatable({}, S)
    self.defs = opts.defs or require("engine.defs")
    self.world = opts.world or require("engine.world")
    self.types = opts.types
    local fs = opts.fs
    if fs == nil then
        local ok, db = pcall(require, "simscript.db")
        fs = ok and db.fs or nil
    end
    self.fs = fs or source.filesystem(opts.game_dir)
    self.canon = {}
    for _, name in pairs(self.types.names) do
        self.canon[name:lower()] = name
    end
    self.filevars, self.globalvars = {}, {}
    for _, file in ipairs(source.files(self.fs, "common/scripted_variables", "txt")) do
        local tree = source.parse(self.fs, file)
        for _, e in ipairs(tree or {}) do
            if e.op and e.key and e.key.text:sub(1, 1) == "@" and e.value.text then
                self.globalvars[e.key.text:sub(2)] = e.value.text
            end
        end
    end
    self.cache = {}
    self.stats = { unresolved = 0, missing = {}, unknown = {}, triggers = 0, triggers_true = 0, trigger_errors = 0 }
    -- triggers are evaluated by the script layer (simscript.eval over engine.interface) when it is
    -- loaded; without it a triggered modifier is left out
    local ok, eval = pcall(require, "simscript.eval")
    self.eval = ok and E and E.get and eval or nil
    self:index_world()
    return self
end

-- the scripted variables of a file
function S:vars(file)
    local v = self.filevars[file]
    if v == nil then
        v = {}
        local tree = file and source.parse(self.fs, file)
        for _, e in ipairs(tree or {}) do
            if e.op and e.key and e.key.text:sub(1, 1) == "@" and e.value.text then
                v[e.key.text:sub(2)] = e.value.text
            end
        end
        self.filevars[file] = v
    end
    return v
end

function S:number(text, file, depth)
    local n = tonumber(text)
    if n then
        return n
    end
    if type(text) == "string" and text:sub(1, 1) == "@" and (depth or 0) < 8 then
        local name = text:sub(2)
        local r = self:vars(file)[name] or self.globalvars[name]
        if r then
            return self:number(r, file, (depth or 0) + 1)
        end
    end
    return nil
end

-- the modifier entries of a block: { [type] = fixed } (nil when it has none)
function S:values(block, file)
    if type(block) ~= "table" then
        return nil
    end
    local out, n = {}, 0
    for _, e in ipairs(block) do
        if e.op and e.key and e.value then
            local k = e.key.text
            if k:lower() == "inline_script" then
                local ex = source.expand(self.fs, { e }, nil, 0, "file: " .. tostring(file))
                local inner = self:values(ex, file)
                for t, v in pairs(inner or {}) do
                    out[t] = (out[t] or 0) + v
                    n = n + 1
                end
            elseif e.value.text then
                local lk = k:lower()
                local name = self.canon[lk]
                local group = name == nil and self.defs.get("common/static_modifiers", k) and self:static(k)
                if name or group then
                    local v = self:number(e.value.text, file)
                    if v then
                        for t, x in pairs(group or { [name] = 100000 }) do
                            out[t] = (out[t] or 0) + scale(fixed(v), x)
                            n = n + 1
                        end
                    else
                        self.stats.unresolved = self.stats.unresolved + 1
                    end
                elseif lk:match("_mult$") or lk:match("_add$") then
                    self.stats.unknown[lk] = (self.stats.unknown[lk] or 0) + 1
                end
            end
        end
    end
    return n > 0 and out or nil
end

-- a definition of a folder of common/ (engine.defs), or nil (counted as missing)
function S:def(folder, name)
    local d = name and self.defs.get(folder, name)
    if d == nil then
        local k = folder .. " " .. tostring(name)
        self.stats.missing[k] = (self.stats.missing[k] or 0) + 1
    end
    return d
end

-- a definition's block with its inline scripts expanded (a trait's or a pop category's modifier
-- blocks often come from one), cached
function S:def_block(folder, name)
    local ck = "block|" .. folder .. "|" .. tostring(name)
    local b = self.cache[ck]
    if b == nil then
        b = false
        local d = self:def(folder, name)
        if d then
            b = { block = source.expand(self.fs, d.block, nil, 0, "file: " .. d.file), file = d.file }
        end
        self.cache[ck] = b
    end
    return b or nil
end

-- the values of the block `key` of a definition (key nil: the definition's own entries, as a static
-- modifier has them), cached
function S:def_values(folder, name, key)
    local ck = folder .. "|" .. tostring(name) .. "|" .. tostring(key)
    local v = self.cache[ck]
    if v == nil then
        v = false
        local d = self:def_block(folder, name)
        if d then
            local block = d.block
            if key then
                block = self.defs.field(d.block, key)
            end
            v = self:values(block, d.file) or false
        end
        self.cache[ck] = v
    end
    return v or nil
end

-- a static modifier's values
function S:static(name)
    return self:def_values("common/static_modifiers", name, nil)
end

-- a trigger block evaluated in a scope (kind, id) by the script layer -> true, false, or nil when it
-- cannot be evaluated
function S:trigger(block, kind, id, file)
    if self.eval == nil or block == nil then
        return nil
    end
    self.stats.triggers = self.stats.triggers + 1
    local ctx = self.eval.new_ctx(self.eval.S(kind, id), nil, nil, file)
    local ok, r = pcall(self.eval.trigger, block, ctx)
    if not ok then
        self.stats.trigger_errors = self.stats.trigger_errors + 1
        return nil
    end
    if r then
        self.stats.triggers_true = self.stats.triggers_true + 1
    end
    return r and true or false
end

-- the triggered blocks `key` of a definition (`key = { potential = { } <modifiers> }`, or with its
-- entries in a `modifier = { }` inside) whose potential holds in the scope (kind, id): -> a list of
-- { values, mult } (mult nil: 1). `mult` in the block is a number, or another modifier's value on
-- the object or its planet (`mult = modifier:pop_non_noxious_happiness`, `planet.modifier:x`),
-- read from the graph through self.resolve_ref (a block whose multiplier cannot be read is left
-- out). The game adds the blocks whose potential fails too, with a multiplier of 0.
function S:active(folder, name, key, kind, id)
    local out = {}
    local d = name and self:def_block(folder, name)
    if d == nil then
        return out
    end
    for _, e in ipairs(d.block) do
        if e.op and e.key and e.key.text == key and type(e.value) == "table" then
            local values = self:values(e.value, d.file)
            local inner = self.defs.field(e.value, "modifier")
            if type(inner) == "table" then
                local v = self:values(inner, d.file)
                if v then
                    values = values or {}
                    for t, x in pairs(v) do
                        values[t] = (values[t] or 0) + x
                    end
                end
            end
            if values then
                local pot = self.defs.field(e.value, "potential")
                local ok = true
                if pot ~= nil then
                    ok = self:trigger(pot, kind, id, d.file)
                end
                if ok then
                    local mult = self.defs.field(e.value, "mult")
                    local ref
                    if type(mult) == "string" then
                        local link, ty = mult:match("^([%w_]*)%.?modifier:([%w_]+)$")
                        if ty then
                            ref = { scope = link ~= "" and link or "this", type = self.canon[ty:lower()] or ty, kind = kind, id = id }
                            mult = self.resolve_ref and self.resolve_ref(ref)
                        else
                            mult = self:number(mult, d.file)
                            mult = mult and fixed(mult) or 100000
                        end
                    else
                        mult = 100000
                    end
                    if mult ~= nil and mult ~= 0 then
                        out[#out + 1] = { values = values, mult = mult, ref = ref }
                    end
                end
            end
        end
    end
    return out
end

-- the active triggered blocks as parts of their own
function S:triggered(parts, label, folder, name, key, kind, id)
    for _, b in ipairs(self:active(folder, name, key, kind, id)) do
        parts.add(label .. "#triggered", b.values, b.mult)
        if b.ref and parts[#parts] then
            parts[#parts].mult_ref = b.ref
        end
    end
end

-- values added into a sum (times mult / 100000, truncated per entry as the game adds)
local function sum_into(sum, values, mult)
    for t, x in pairs(values or {}) do
        sum[t] = (sum[t] or 0) + scale(x, mult or 100000)
    end
end

-- ---------------------------------------------------------------------------------------------
-- the world: relations not kept by engine.world

local function list_of(w, obj, key)
    local out = {}
    local b = w.field(obj, key)
    if type(b) == "table" then
        for _, e in ipairs(b) do
            if e.text then
                out[#out + 1] = unq(e.text)
            end
        end
    end
    return out
end

-- the bare blocks of a list block (`active_policies = { { ... } { ... } }`)
local function blocks_of(b)
    local out = {}
    if type(b) == "table" then
        for _, e in ipairs(b) do
            if not e.op and e.text == nil then
                out[#out + 1] = e
            end
        end
    end
    return out
end

function S:index_world()
    local w = self.world
    self.planet_of_colony = {}
    for _, id in ipairs(w.all("planet")) do
        local c = w.field(w.object("planet", id), "colony")
        if type(c) == "number" then
            self.planet_of_colony[c] = id
        end
    end
    self.federation_of = {}
    for _, id in ipairs(w.all("federation")) do
        for _, m in ipairs(list_of(w, w.object("federation", id), "members")) do
            self.federation_of[tonumber(m)] = id
        end
    end
    self.sector_of_system = {}
    for _, id in ipairs(w.all("sectors")) do
        for _, s in ipairs(list_of(w, w.object("sectors", id), "systems")) do
            self.sector_of_system[tonumber(s)] = id
        end
    end
    -- leaders: skill level and traits
    self.leaders = {}
    for _, id in ipairs(w.all("leader")) do
        local o = w.object("leader", id)
        local l = { traits = {}, level = 0 }
        for _, e in ipairs(o) do
            if e.op and e.key then
                local k = e.key.text
                if k == "traits" and e.value.text then
                    l.traits[#l.traits + 1] = unq(e.value.text)
                elseif k == "level" or k == "bonus_skill_level" then
                    l.level = l.level + (tonumber(e.value.text) or 0)
                elseif k == "class" then
                    l.class = unq(e.value.text)
                end
            end
        end
        self.leaders[id] = l
    end
    -- council positions by country
    self.council = {}
    for _, id in ipairs(w.all("council_positions")) do
        local o = w.object("council_positions", id)
        local country = w.field(o, "country")
        if type(country) == "number" then
            local l = self.council[country] or {}
            self.council[country] = l
            l[#l + 1] = { type = unq(w.field(o, "type")), leader = w.field(o, "leader") }
        end
    end
    -- the player
    self.players = {}
    local player = w.meta.player
    for _, b in ipairs(blocks_of(player)) do
        local c = w.field(b, "country")
        if c then
            self.players[c] = true
        end
    end
end

-- ---------------------------------------------------------------------------------------------
-- parts

local function new_parts(filter)
    local parts = { filter = filter }
    function parts.add(name, values, mult)
        if values ~= nil and next(values) ~= nil then
            parts[#parts + 1] = { name = name, mult = mult or 100000, filter = parts.filter, values = values }
        end
    end
    return parts
end

-- country -------------------------------------------------------------------------------------

function S:country(id)
    local w = self.world
    local c = w.object("country", id)
    local parts = new_parts(M.FILTER.Country)
    if c == nil then
        return parts
    end
    local add = parts.add
    -- a definition's block `key` (times mult), and its triggered country blocks
    -- (`triggered_modifier`, `triggered_country_modifier`) whose potential holds for the country
    local function src(label, folder, name, key, mult)
        add(label, self:def_values(folder, name, key), mult)
        self:triggered(parts, label, folder, name, "triggered_modifier", "country", id)
        self:triggered(parts, label, folder, name, "triggered_country_modifier", "country", id)
    end
    -- technologies (a repeatable's level as the multiplier)
    local ts = w.field(c, "tech_status")
    local last
    for _, e in ipairs(type(ts) == "table" and ts or {}) do
        if e.op and e.key.text == "technology" then
            last = unq(e.value.text)
        elseif e.op and e.key.text == "level" and last then
            src("technology:" .. last, "common/technology", last, "modifier", (tonumber(e.value.text) or 1) * 100000)
            last = nil
        end
    end
    for _, t in ipairs(list_of(w, c, "traditions")) do
        src("tradition:" .. t, "common/traditions", t, "modifier")
    end
    for _, t in ipairs(list_of(w, c, "ascension_perks")) do
        src("ascension_perk:" .. t, "common/ascension_perks", t, "modifier")
    end
    local gov = w.field(c, "government")
    local authority
    if type(gov) == "table" then
        local ty = unq(w.field(gov, "type"))
        if ty then
            src("government:" .. ty, "common/governments", ty, "modifier")
        end
        authority = unq(w.field(gov, "authority"))
        if authority then
            src("authority:" .. authority, "common/governments/authorities", authority, "country_modifier")
        end
        for _, civic in ipairs(list_of(w, gov, "civics")) do
            src("civic:" .. civic, "common/governments/civics", civic, "modifier")
        end
        local origin = unq(w.field(gov, "origin"))
        if origin then
            src("origin:" .. origin, "common/governments/civics", origin, "modifier")
        end
        -- the council agenda in progress
        local agenda = unq(w.field(gov, "council_agenda"))
        if agenda and agenda ~= "none" then
            src("council_agenda:" .. agenda, "common/council_agendas", agenda, "modifier")
        end
    end
    local ethos = w.field(c, "ethos")
    for _, e in ipairs(type(ethos) == "table" and list_of(w, ethos, "ethics") or {}) do
        src("ethic:" .. e, "common/ethics", e, "country_modifier")
    end
    for _, b in ipairs(blocks_of(w.field(c, "active_policies"))) do
        local policy, selected = unq(w.field(b, "policy")), unq(w.field(b, "selected"))
        local d = policy and self.defs.get("common/policies", policy)
        if d then
            for _, e in ipairs(d.block) do
                if e.op and e.key and e.key.text == "option" and type(e.value) == "table" and unq(w.field(e.value, "name")) == selected then
                    add("policy:" .. policy .. "." .. selected, self:values(self.defs.field(e.value, "modifier"), d.file))
                end
            end
        end
    end
    for _, b in ipairs(blocks_of(w.field(c, "edicts"))) do
        local edict = unq(w.field(b, "edict"))
        if edict then
            src("edict:" .. edict, "common/edicts", edict, "modifier")
        end
    end
    self:timed(parts, c)
    local ctype = unq(w.field(c, "type"))
    if ctype then
        src("country_type:" .. ctype, "common/country_types", ctype, "modifier")
    end
    -- the static modifiers the engine adds by name
    add("static:empire_base", self:static("empire_base"))
    if ctype == "default" and not self.players[id] then
        add("static:playable_ai_empire", self:static("playable_ai_empire"))
    end
    if ctype == "fallen_empire" then
        add("static:fallen_empire_base", self:static("fallen_empire_base"))
    end
    -- a federation's members (its leader too) pay federation_tax
    if self.federation_of[id] then
        add("static:federation_tax", self:static("federation_tax"))
    end
    -- naval capacity exceeded: navy_coverage_shortage times the shortage
    local cov = w.field(c, "navy_coverage")
    if type(cov) == "number" and cov < 1 then
        add("static:navy_coverage_shortage", self:static("navy_coverage_shortage"), 100000 - fixed(cov))
    end
    -- the council: each position's modifier times its councilor's skill (the leader's level, its
    -- bonus levels and the country's councilor_skill_add), the councilors' traits
    local skill_add = 0
    for _, part in ipairs(parts) do
        skill_add = skill_add + scale(part.values.councilor_skill_add or 0, part.mult)
    end
    skill_add = math.floor(skill_add / 100000)
    local function councilor(pos, leader, label)
        local l = self.leaders[leader]
        if l == nil then
            return
        end
        if pos then
            add("councilor:" .. pos, self:def_values("common/governments/councilors", pos, "modifier"), (l.level + skill_add) * 100000)
            self:triggered(parts, "councilor:" .. pos, "common/governments/councilors", pos, "triggered_country_modifier", "country", id)
        end
        for _, t in ipairs(l.traits) do
            add(label .. ":" .. t, self:def_values("common/traits", t, "councilor_modifier"))
            self:triggered(parts, label .. ":" .. t, "common/traits", t, "triggered_councilor_modifier", "leader", leader)
        end
    end
    local has_ruler_position = false
    for _, pos in ipairs(self.council[id] or {}) do
        if pos.type and pos.leader and self.leaders[pos.leader] then
            if pos.type:match("^councilor_ruler_") then
                has_ruler_position = true
            end
            councilor(pos.type, pos.leader, "councilor_trait")
        end
    end
    local ruler = w.field(c, "ruler")
    if type(ruler) == "number" and not has_ruler_position then
        councilor(authority and ("councilor_ruler_" .. authority:gsub("^auth_", "")), ruler, "ruler_trait")
    end
    return parts
end

-- timed modifiers of an object (timed_modifier = { items = { { modifier days [multiplier] } } })
function S:timed(parts, obj)
    local w = self.world
    local tm = w.field(obj, "timed_modifier")
    for _, b in ipairs(blocks_of(type(tm) == "table" and w.field(tm, "items") or nil)) do
        local m = unq(w.field(b, "modifier"))
        if m then
            local mult = w.field(b, "multiplier")
            parts.add("timed:" .. m, self:static(m), type(mult) == "number" and fixed(mult) or 100000)
        end
    end
end

-- planet --------------------------------------------------------------------------------------

function S:planet(id)
    local w = self.world
    local p = w.object("planet", id)
    local parts = new_parts(M.FILTER.Planet)
    if p == nil then
        return parts
    end
    local add = parts.add
    local class = unq(w.field(p, "planet_class"))
    if class then
        add("planet_class:" .. class, self:def_values("common/planet_classes", class, "modifier"))
    end
    -- (the random planet modifier, `planet_modifier = pm_x`, arrives as a permanent timed modifier)
    self:timed(parts, p)
    -- the deposits, summed into one part
    local dep = {}
    for _, did in ipairs(list_of(w, p, "deposits")) do
        local o = w.object("deposit", tonumber(did))
        local ty = o and unq(w.field(o, "type"))
        local v = ty and self:def_values("common/deposits", ty, "planet_modifier")
        for t, x in pairs(v or {}) do
            dep[t] = (dep[t] or 0) + x
        end
    end
    add("deposits", dep)
    local colony = w.field(p, "colony")
    local col = type(colony) == "number" and w.object("colony", colony)
    if col then
        local des = unq(w.field(col, "final_designation")) or unq(w.field(col, "designation"))
        if des then
            add("designation:" .. des, self:def_values("common/colony_types", des, "planet_modifier"))
            self:triggered(parts, "designation:" .. des, "common/colony_types", des, "triggered_planet_modifier", "planet", id)
        end
        -- a definition's planet_modifier and active triggered_planet_modifiers times a count, and
        -- its triggered_district_planet_modifiers times the district's level
        local function planet_mods(sum, folder, ty, count, level)
            sum_into(sum, self:def_values(folder, ty, "planet_modifier"), count * 100000)
            for _, b in ipairs(self:active(folder, ty, "triggered_planet_modifier", "planet", id)) do
                sum_into(sum, b.values, b.mult * count)
            end
            for _, b in ipairs(self:active(folder, ty, "triggered_district_planet_modifier", "planet", id)) do
                sum_into(sum, b.values, b.mult * level)
            end
        end
        -- the buildings, summed: their planet modifiers in one part, their triggered ones in another
        local bsum, btsum = {}, {}
        for _, bid in ipairs(list_of(w, col, "buildings_cache")) do
            local o = w.object("buildings", tonumber(bid))
            local ty = o and unq(w.field(o, "type"))
            if ty then
                sum_into(bsum, self:def_values("common/buildings", ty, "planet_modifier"))
                for _, b in ipairs(self:active("common/buildings", ty, "triggered_planet_modifier", "planet", id)) do
                    sum_into(btsum, b.values, b.mult)
                end
            end
        end
        add("buildings", bsum)
        add("buildings#triggered", btsum)
        -- the districts, summed (times their level), and their zones (times the district's level)
        local dsum, zsum = {}, {}
        for _, did in ipairs(list_of(w, col, "districts")) do
            local o = w.object("districts", tonumber(did))
            local ty = o and unq(w.field(o, "type"))
            if ty then
                local level = w.field(o, "level")
                level = type(level) == "number" and level or 1
                planet_mods(dsum, "common/districts", ty, level, level)
                for _, zid in ipairs(list_of(w, o, "zones")) do
                    local z = w.object("zones", tonumber(zid))
                    local zt = z and unq(w.field(z, "type"))
                    if zt then
                        planet_mods(zsum, "common/zones", zt, 1, level)
                    end
                end
            end
        end
        add("districts", dsum)
        add("zones", zsum)
        -- the jobs: each worked job's planet modifiers times its workforce (with the bonus) / 100
        local jsum = {}
        for _, jid in ipairs(list_of(w, col, "pop_jobs")) do
            local o = w.object("pop_jobs", tonumber(jid))
            local ty = o and unq(w.field(o, "type"))
            local wf, bonus = w.field(o, "workforce"), w.field(o, "bonus_workforce")
            if ty and type(wf) == "number" and wf > 0 then
                local amount = fixed((wf + (type(bonus) == "number" and bonus or 0)) / 100)
                sum_into(jsum, self:def_values("common/pop_jobs", ty, "planet_modifier"), amount)
                for _, b in ipairs(self:active("common/pop_jobs", ty, "triggered_planet_modifier", "planet", id)) do
                    sum_into(jsum, b.values, scale(b.mult, amount))
                end
            end
        end
        add("jobs", jsum)
        -- the governor: skill_<class>_planet_governor times its skill; a colony without a
        -- governor of its own has half of its sector's (the governor of the sector's local capital)
        local gov = w.field(col, "governor")
        local share = 100000
        if type(gov) ~= "number" then
            share = 50000
            local coord = w.field(p, "coordinate")
            local sector = type(coord) == "table" and self.sector_of_system[w.field(coord, "origin")]
            local cap = sector and w.field(w.object("sectors", sector), "local_capital")
            local cc = type(cap) == "number" and w.object("colony", cap)
            gov = cc and w.field(cc, "governor")
        end
        local l = type(gov) == "number" and self.leaders[gov]
        if l and l.class then
            add("governor", self:static("skill_" .. l.class .. "_planet_governor"), l.level * share)
        end
    end
    return parts
end

-- colony --------------------------------------------------------------------------------------

-- The colony's status modifiers (static modifiers scaled by how far the colony is past a
-- threshold; read from the 2210 capture, where each multiplier matches the save's colony fields):
--   stability above 50: planet_stability_high x (stability - 50) / 50, below: _low x (50 - s) / 50
--   amenities: planet_amenities_high x (amenities / usage - 1), _low x (1 - amenities / usage) / 0.5
--   housing: planet_housing_high x (housing / usage - 1) / 3, _low x (1 - housing / usage) / 0.5,
--     and planet_overcrowded when the free housing is negative
--   employment: planet_employment_low x the unemployed pops (workforce / 100, whole), _high x the
--     open workforce of the jobs (workforce_limit - workforce)
-- each at most 1 (employment unbounded); a gestalt country's colonies use the _no_happiness_ ones.
function S:colony(id)
    local w = self.world
    local col = w.object("colony", id)
    local parts = new_parts(M.FILTER.Colony)
    if col == nil then
        return parts
    end
    local planet = self.planet_of_colony[id]
    local owner = planet and w.field(w.object("planet", planet), "owner")
    local oc = type(owner) == "number" and w.object("country", owner)
    local gestalt = false
    local ethos = oc and w.field(oc, "ethos")
    for _, e in ipairs(type(ethos) == "table" and list_of(w, ethos, "ethics") or {}) do
        if e == "ethic_gestalt_consciousness" then
            gestalt = true
        end
    end
    local nh = gestalt and "_no_happiness" or ""
    local function num(k)
        local v = w.field(col, k)
        return type(v) == "number" and v or nil
    end
    local function status(name, x, cap)
        if x and x > 0 then
            if cap ~= false then
                x = math.min(x, 1)
            end
            parts.add("status:" .. name, self:static(name), fixed(x))
        end
    end
    local stability = num("stability")
    if stability then
        status("planet_stability" .. nh .. "_high", (stability - 50) / 50)
        status("planet_stability" .. nh .. "_low", (50 - stability) / 50)
    end
    local amenities, ausage = num("amenities"), num("amenities_usage")
    if amenities and ausage and ausage > 0 then
        local r = amenities / ausage
        status("planet_amenities" .. nh .. "_high", r - 1)
        status("planet_amenities" .. nh .. "_low", (1 - r) / 0.5)
    end
    local housing, husage = num("total_housing"), num("housing_usage")
    if housing and husage and husage > 0 then
        local r = housing / husage
        status("planet_housing" .. nh .. "_high", (r - 1) / 3)
        status("planet_housing" .. nh .. "_low", (1 - r) / 0.5)
        if housing < husage then
            parts.add("status:planet_overcrowded", self:static("planet_overcrowded"))
        end
    end
    local unemployed = num("unemploy_pop")
    if unemployed and unemployed >= 100 then
        status("planet_employment" .. nh .. "_low", math.floor(unemployed / 100), false)
    end
    -- open jobs: the workforce the jobs could still take (workforce_limit - workforce)
    local open = 0
    for _, jid in ipairs(list_of(w, col, "pop_jobs")) do
        local o = w.object("pop_jobs", tonumber(jid))
        local lim, wf = w.field(o, "workforce_limit"), w.field(o, "workforce")
        if type(lim) == "number" and lim > 0 then
            open = open + lim - math.max(type(wf) == "number" and wf or 0, 0)
        end
    end
    status("planet_employment" .. nh .. "_high", open, false)
    return parts
end

-- pop group -----------------------------------------------------------------------------------

-- the species rights a country gives a species: its entry in the country's species rights, else
-- the founder species' (primary), else the default
function S:rights(country, species)
    local w = self.world
    local c = w.object("country", country)
    local mod = c and w.path(c, "modules", "standard_species_rights_module")
    if type(mod) ~= "table" then
        return nil
    end
    for _, b in ipairs(blocks_of(w.field(mod, "species_rights"))) do
        if w.field(b, "species_index") == species then
            return b
        end
    end
    local primary = w.field(mod, "primary")
    if type(primary) == "table" and w.field(primary, "species_index") == species then
        return primary
    end
    local default = w.field(mod, "default")
    return type(default) == "table" and default or nil
end

function S:pop_group(id)
    local w = self.world
    local g = w.object("pop_group", id)
    local parts = new_parts(M.FILTER.PopGroup)
    if g == nil then
        return parts
    end
    local add = parts.add
    if w.field(g, "killed") == "yes" then
        return parts
    end
    local key = w.field(g, "key")
    local species = type(key) == "table" and w.field(key, "species")
    local category = type(key) == "table" and unq(w.field(key, "category"))
    if category then
        add("pop_category:" .. category, self:def_values("common/pop_categories", category, "pop_group_modifier"))
        self:triggered(parts, "pop_category:" .. category, "common/pop_categories", category, "triggered_pop_group_modifier", "pop_group", id)
    end
    -- the species' traits, summed into one part
    local sp = type(species) == "number" and w.object("species", species)
    if sp then
        local sum = {}
        local traits = w.field(sp, "traits")
        local names = {}
        for _, e in ipairs(type(traits) == "table" and traits or {}) do
            if e.op and e.key.text == "trait" then
                local trait = unq(e.value.text)
                names[#names + 1] = trait
                local v = self:def_values("common/traits", trait, "modifier")
                for t, x in pairs(v or {}) do
                    sum[t] = (sum[t] or 0) + x
                end
            end
        end
        add("species_traits", sum)
        -- each trait's triggered modifiers, a part each
        for _, trait in ipairs(names) do
            self:triggered(parts, "trait:" .. trait, "common/traits", trait, "triggered_pop_group_modifier", "pop_group", id)
        end
    end
    -- the owner's species rights (regular empires: a fallen empire's nodes have none)
    local colony = w.field(g, "planet")
    local planet = type(colony) == "number" and self.planet_of_colony[colony]
    local owner = planet and w.field(w.object("planet", planet), "owner")
    local oc = type(owner) == "number" and w.object("country", owner)
    local otype = oc and unq(w.field(oc, "type"))
    local td = otype and self.defs.get("common/country_types", otype)
    local fallen = td and self.defs.field(td.block, "fallen_empire") == "yes"
    local rights = oc and not fallen and type(species) == "number" and self:rights(owner, species)
    if rights then
        local R = "common/species_rights/"
        local function right(field, folder)
            local v = unq(w.field(rights, field))
            if v then
                add(field .. ":" .. v, self:def_values(R .. folder, v, "pop_group_modifier"))
                self:triggered(parts, field .. ":" .. v, R .. folder, v, "triggered_pop_group_modifier", "pop_group", id)
            end
            return v
        end
        right("living_standard", "living_standards")
        local cit = right("citizenship", "citizenship_types")
        if cit == "citizenship_slavery" then
            right("slavery", "slavery_types")
        elseif cit == "citizenship_purge" then
            right("purge", "purge_types")
        end
        right("population_control", "population_controls")
    end
    -- low habitability: pop_low_habitability times the shortfall
    local hab = w.field(g, "habitability")
    if type(hab) == "number" and hab < 1 then
        add("static:pop_low_habitability", self:static("pop_low_habitability"), 100000 - fixed(hab))
    end
    return parts
end

-- ---------------------------------------------------------------------------------------------

local BY_CATEGORY = { Country = S.country, Planet = S.planet, Colony = S.colony, PopGroup = S.pop_group }

-- src:parts(category, owner) -> the node's own parts ({ name, mult, filter, values }), or nil for a
-- category not modelled
function S:parts(category, owner)
    local f = BY_CATEGORY[category]
    return f and f(self, owner) or nil
end

return M
