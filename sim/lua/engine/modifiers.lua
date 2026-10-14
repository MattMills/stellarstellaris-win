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
--   Ship: the design's sections and components, the size, auras, docked repairs (S:ship).
--   Fleet: its system's star class, its leader's class skill and trait blocks (S:fleet).
--   Army: the species' traits, its general's class skill and army_modifier blocks (S:army).
--   Sector: its capital's governor's sector_modifier blocks. GalacticObjectTimed: the system's
--     timed modifiers.
--   Leader: the species' traits, the leader's traits' self_modifier and triggered_self_modifier.
--   LeaderSkill: the skill statics x level (S:leader_skill), a ruler's council position x level,
--     the traits' `modifier` blocks.
--   StarbaseExternal: the governors of its system's colonies, skill_<class>_planet_governor and
--     their skill statics x level.
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
    Ship = 49276,
    Leader = 525312,
    Fleet = 1342882558,
    Army = 524800,
    Sector = 1077926654,
    GalacticObjectTimed = 1076878078,
}
M.CATEGORIES = { "Country", "Planet", "Colony", "PopGroup", "Ship", "Fleet", "Army", "Sector",
    "GalacticObjectTimed", "Leader", "LeaderSkill", "Starbase", "StarbaseCountry", "StarbaseExternal",
    "StarbaseSystem", "StarbaseDefensePlatform", "Orbital" }

-- A key of a modifier block that is not a modifier type but names a static modifier
-- (`researcher_jobs_bonus_workforce_mult = 0.1`, common/static_modifiers/24_static_modifiers_jobs.txt)
-- adds that static modifier's entries times the value: a group of types under one name.

local byte, sub = string.byte, string.sub
local function unq(s)
    if type(s) ~= "string" then
        return s
    end
    -- (s:gsub('^"(.*)"$', "%1")) without the pattern: a string of at least two characters
    -- quoted at both ends loses the quotes
    if #s >= 2 and byte(s, 1) == 34 and byte(s, -1) == 34 then
        return sub(s, 2, -2)
    end
    return s
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

-- the scripted variables, read once per file system: the files do not change during a run, and
-- the monthly rebuild makes a new source each time (it had parsed them all again every month)
local vars_of_fs = setmetatable({}, { __mode = "k" })

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
    local vars = vars_of_fs[self.fs]
    if vars == nil then
        vars = { files = {}, global = {} }
        for _, file in ipairs(source.files(self.fs, "common/scripted_variables", "txt")) do
            local tree = source.parse(self.fs, file)
            for _, e in ipairs(tree or {}) do
                if e.op and e.key and e.key.text:sub(1, 1) == "@" and e.value.text then
                    vars.global[e.key.text:sub(2)] = e.value.text
                end
            end
        end
        vars_of_fs[self.fs] = vars
    end
    self.filevars, self.globalvars = vars.files, vars.global
    self.cache = {}
    self.active_cache = {}
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

-- the definitions of a folder whose entries are named by a `key = "X"` inside them (component and
-- section templates: `utility_component_template = { key = "HYPER_DRIVE_1" ... }`; engine.defs
-- keeps one per wrapper name): key -> { block (inline scripts expanded), file }, a later file's
-- definition replacing an earlier one
function S:keyed(folder)
    local ck = "keyed|" .. folder
    local index = self.cache[ck]
    if index == nil then
        index = {}
        for _, file in ipairs(source.files(self.fs, folder, "txt")) do
            for _, e in ipairs(source.parse(self.fs, file) or {}) do
                if e.op and e.key and type(e.value) == "table" and e.value.text == nil then
                    local key = unq(self.defs.field(e.value, "key"))
                    if key then
                        index[key] = { block = source.expand(self.fs, e.value, nil, 0, "file: " .. file), file = file }
                    end
                end
            end
        end
        self.cache[ck] = index
    end
    return index
end

-- the values of the block `field` of a keyed definition, cached
function S:keyed_values(folder, key, field)
    local ck = "kv|" .. folder .. "|" .. tostring(key) .. "|" .. field
    local v = self.cache[ck]
    if v == nil then
        local d = key and self:keyed(folder)[key]
        v = d and self:values(self.defs.field(d.block, field), d.file) or false
        self.cache[ck] = v
    end
    return v or nil
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
                -- the last block of that key (civic_catalytic_processing has an empty `modifier`
                -- and then its attunement one)
                block = nil
                for _, e in ipairs(d.block) do
                    if e.op and e.key and e.key.text == key then
                        block = e.value
                    end
                end
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

-- a define (common/defines: NDefines = { NGroup = { KEY = value } }), any group
function S:define(key)
    local v = self.cache["define|" .. key]
    if v == nil then
        v = false
        for _, d in pairs(self.defs.folder("common/defines")) do
            for _, e in ipairs(d.block) do
                if e.op and type(e.value) == "table" and v == false then
                    local x = self.defs.field(e.value, key)
                    if x ~= nil then
                        v = x
                    end
                end
            end
        end
        self.cache["define|" .. key] = v
    end
    return v or nil
end

-- the galaxy's scale of the NPCs' difficulty bonuses: 1 at SCALED_DIFFICULTY_MAX_GALAXY_SIZE systems
-- and more, smaller ones less (SCALED_DIFFICULTY_GALAXY_SIZE_MULT of the shortfall); 596 systems:
-- 1 - 0.75 * (1 - 596 / 1000) = 0.697, as the capture's difficulty parts have it
function S:difficulty_scale()
    local max = tonumber(self:define("SCALED_DIFFICULTY_MAX_GALAXY_SIZE")) or 1000
    local mult = tonumber(self:define("SCALED_DIFFICULTY_GALAXY_SIZE_MULT")) or 0.75
    local size = #self.world.all("galactic_object")
    return 1 - mult * (1 - math.min(1, size / max))
end

-- triggers the sources read that the script layer does not answer yet (is_immortal, has_relic:
-- filled in below, by "the world"), installed while a trigger is evaluated with the economy's
-- (engine/economy/script.lua)
local EXTRA_TRIGGERS = {}
local econ_script
do
    local ok, m = pcall(require, "engine.economy.script")
    econ_script = ok and m or nil
end

-- f(...) with the extra triggers installed where the script layer has none -> pcall's ok, result.
-- Inside src:scripts (a whole rebuild) they are installed already: f is only called.
function S:with_script(f, ...)
    if self.scripts_on then
        return pcall(f, ...)
    end
    local TRIG = self.eval.TRIG
    local added = {}
    for k, g in pairs(EXTRA_TRIGGERS) do
        if TRIG[k] == nil then
            added[#added + 1] = k
            TRIG[k] = function(e, ctx) return g(self, e, ctx) end
        end
    end
    local ok, r
    if econ_script then
        ok, r = pcall(econ_script.with, f, ...)
    else
        ok, r = pcall(f, ...)
    end
    for _, k in ipairs(added) do
        TRIG[k] = nil
    end
    return ok, r
end

-- src:scripts(f, ...) -> f's results: f run with the extra triggers and the economy's links and
-- triggers (engine/economy/script.lua) installed once, so that every trigger and script value
-- evaluated inside (S:with_script) only calls, instead of installing and taking them out each
-- time (a whole rebuild: the world does not change inside, so the results are the same)
function S:scripts(f, ...)
    if self.eval == nil or self.scripts_on then
        return f(...)
    end
    local TRIG = self.eval.TRIG
    local added = {}
    for k, g in pairs(EXTRA_TRIGGERS) do
        if TRIG[k] == nil then
            added[#added + 1] = k
            TRIG[k] = function(e, ctx) return g(self, e, ctx) end
        end
    end
    self.scripts_on = true
    local res
    if econ_script then
        res = { pcall(econ_script.with, f, ...) }
    else
        res = { pcall(f, ...) }
    end
    self.scripts_on = false
    for _, k in ipairs(added) do
        TRIG[k] = nil
    end
    if not res[1] then
        error(res[2], 0)
    end
    return unpack(res, 2)
end

-- src.resolve_ref, noting that the parts being computed depend on it (src.ref_used: the
-- incremental graph computes those again once the values they read are known,
-- engine/modifiers/incremental.lua); every read of self.resolve_ref goes through it
local function ref_of(self)
    self.ref_used = true
    return self.resolve_ref
end

-- a trigger block evaluated in a scope (kind, id; from: an optional { kind, id }, the scope's
-- from) by the script layer -> true, false, or nil when it cannot be evaluated. With
-- self.trigger_memo set (a table, for the time the world does not change: one incremental
-- update), a block already evaluated in the same scope (no from) and file gives its answer again.
local NO_ANSWER = {}
function S:trigger(block, kind, id, file, from)
    if self.eval == nil or block == nil then
        return nil
    end
    local memo, by_id = self.trigger_memo, nil
    if memo ~= nil and from == nil and kind ~= nil and id ~= nil then
        local m = memo[block]
        if m == nil then
            m = { file = file }
            memo[block] = m
        end
        if m.file == file then
            by_id = m[kind]
            if by_id == nil then
                by_id = {}
                m[kind] = by_id
            end
            local r = by_id[id]
            if r ~= nil then
                if r == NO_ANSWER then
                    return nil
                end
                return r
            end
        end
    end
    self.stats.triggers = self.stats.triggers + 1
    local ctx = self.eval.new_ctx(self.eval.S(kind, id), from and self.eval.S(from[1], from[2]) or nil, nil, file)
    local ok, r = self:with_script(self.eval.trigger, block, ctx)
    if not ok then
        self.stats.trigger_errors = self.stats.trigger_errors + 1
        if by_id then
            by_id[id] = NO_ANSWER
        end
        return nil
    end
    if r then
        self.stats.triggers_true = self.stats.triggers_true + 1
    end
    r = r and true or false
    if by_id then
        by_id[id] = r
    end
    return r
end

-- a potential written in the scope of an object a country owns (a situation's), evaluated for the
-- country: its `owner = { }` entries in the country's scope, the others as they are
function S:owner_trigger(block, country, file)
    for _, e in ipairs(block) do
        if e.op and e.key then
            local b = (e.key.text == "owner" and type(e.value) == "table" and e.value.text == nil) and e.value or { e }
            if not self:trigger(b, "country", country, file) then
                return false
            end
        end
    end
    return true
end

-- the triggered blocks `key` of a definition (`key = { potential = { } <modifiers> }`, or with its
-- entries in a `modifier = { }` inside) whose potential holds in the scope (kind, id): -> a list of
-- { values, mult } (mult nil: 1). `mult` in the block is a number, or another modifier's value on
-- the object or its planet (`mult = modifier:pop_non_noxious_happiness`, `planet.modifier:x`),
-- read from the graph through self.resolve_ref (a block whose multiplier cannot be read is left
-- out). The game adds the blocks whose potential fails too, with a multiplier of 0.
-- What the definition gives (each block's values, potential and multiplier) is read once
-- (S:triggered_blocks); the potentials and the multipliers read from the graph or the script are
-- evaluated on every call.
function S:active(folder, name, key, kind, id, from)
    local out = {}
    for _, b in ipairs(self:triggered_blocks(folder, name, key)) do
        local ok = true
        if b.pot ~= nil then
            ok = self:trigger(b.pot, kind, id, b.file, from)
        end
        if ok then
            local mult, ref = b.mult, nil
            if b.ref_type then
                ref = { scope = b.ref_scope, type = b.ref_type, kind = kind, id = id }
                local resolve = ref_of(self)
                mult = resolve and resolve(ref)
            elseif b.spec then
                mult = self:script_mult(b.spec, b.vlink, kind, id, b.file)
            end
            if mult ~= nil and mult ~= 0 then
                out[#out + 1] = { values = b.values, mult = mult, ref = ref }
            end
        end
    end
    return out
end

-- the triggered blocks `key` of a definition as S:active reads them, cached: { values (the block's
-- entries and its inner `modifier`'s), pot, file, and mult (a number in the fixed point), or
-- ref_scope and ref_type (`mult = [link.]modifier:x`), or spec and vlink (`mult = [link.]value:x`) }
function S:triggered_blocks(folder, name, key)
    local byf = self.active_cache[folder]
    if byf == nil then
        byf = {}
        self.active_cache[folder] = byf
    end
    local byk = byf[key]
    if byk == nil then
        byk = {}
        byf[key] = byk
    end
    if name == nil then
        return {}
    end
    local list = byk[name]
    if list ~= nil then
        return list
    end
    list = {}
    byk[name] = list
    local d = self:def_block(folder, name)
    if d == nil then
        return list
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
                local b = { values = values, pot = self.defs.field(e.value, "potential"), file = d.file }
                local mult = self.defs.field(e.value, "mult")
                if type(mult) == "string" then
                    local link, ty = mult:match("^([%w_]*)%.?modifier:([%w_]+)$")
                    local vlink, spec = mult:match("^([%w_]*)%.?value:(.+)$")
                    if ty then
                        b.ref_scope, b.ref_type = link ~= "" and link or "this", self.canon[ty:lower()] or ty
                    elseif spec then
                        b.spec, b.vlink = spec, vlink
                    else
                        mult = self:number(mult, d.file)
                        b.mult = mult and fixed(mult) or 100000
                    end
                else
                    b.mult = 100000
                end
                list[#list + 1] = b
            end
        end
    end
    return list
end

-- the economic categories a category's production multipliers come from: itself and its parents
-- (common/economic_categories `parent`), those that generate `produces` mult modifiers
function S:produces_chain(category)
    local key = "chain|" .. tostring(category)
    local chain = self.cache[key]
    if chain == nil then
        chain = {}
        local seen = {}
        local c = category
        while c and not seen[c] do
            seen[c] = true
            local d = self.defs.get("common/economic_categories", c)
            if d == nil then
                break
            end
            local gen = self.defs.field(d.block, "generate_mult_modifiers")
            for _, e in ipairs(type(gen) == "table" and gen or {}) do
                if e.text == "produces" then
                    chain[#chain + 1] = c
                end
            end
            c = unq(self.defs.field(d.block, "parent"))
        end
        self.cache[key] = chain
    end
    return chain
end

-- a block's multiplier that is a script value (`mult = value:x|P|v|`, or `owner.value:x`), in the
-- fixed point, nil when it cannot be read yet:
-- - job_total_output_modifier|JOB|j|RESOURCE|r|: 1 + the production multipliers of the job's
--   economic category chain for the resource on its colony's node (<category>_produces_mult and
--   <category>_<r>_produces_mult), rounded to 0.01 as the script value is; read from the graph
--   through self.resolve_ref (scope colony), as `mult = modifier:x` is
-- - any other: the script layer's script value in the object's scope (or its link's)
function S:script_mult(spec, link, kind, id, file)
    local p = {}
    for x in (spec .. "|"):gmatch("([^|]*)|") do
        p[#p + 1] = x
    end
    if p[1] == "job_total_output_modifier" then
        local args = {}
        for i = 2, #p - 1, 2 do
            args[p[i]] = p[i + 1]
        end
        local job, res = args.JOB, args.RESOURCE
        local jd = job and self:def_block("common/pop_jobs", job)
        local rb = jd and self.defs.field(jd.block, "resources")
        local category = type(rb) == "table" and unq(self.defs.field(rb, "category"))
        local resolve = ref_of(self)
        if not (category and res and resolve) then
            return nil
        end
        local sum = 0
        for _, c in ipairs(self:produces_chain(category)) do
            for _, t in ipairs({ c .. "_produces_mult", c .. "_" .. res .. "_produces_mult" }) do
                local v = resolve({ scope = "colony", type = self.canon[t:lower()] or t, kind = kind, id = id })
                if v == nil then
                    return nil
                end
                sum = sum + v
            end
        end
        local v = 1 + sum / 100000
        return math.floor(v * 100 + 0.5) * 1000
    end
    if p[1] == "natural_blocker_count" and kind == "planet" then
        -- the planet's deposits of category deposit_cat_blockers_natural (a count_deposits
        -- complex trigger, which the script layer does not evaluate)
        local w = self.world
        local n = 0
        local deps = w.field(w.object("planet", id), "deposits")
        for _, x in ipairs(type(deps) == "table" and deps or {}) do
            local ty = x.text and unq(w.field(w.object("deposit", tonumber(x.text)), "type"))
            local d = ty and self.defs.get("common/deposits", ty)
            if d and unq(self.defs.field(d.block, "category")) == "deposit_cat_blockers_natural" then
                n = n + 1
            end
        end
        return n * 100000
    end
    if self.eval == nil then
        return nil
    end
    local ok, v = self:with_script(function()
        local ctx = self.eval.new_ctx(self.eval.S(kind, id), nil, nil, file)
        if link and link ~= "" then
            local found, sc = self.eval.resolve(link, ctx)
            if not (found and sc) then
                return nil
            end
            ctx = self.eval.push(ctx, sc)
        end
        return self.eval.script_value(spec, ctx)
    end)
    return ok and type(v) == "number" and fixed(v) or nil
end

-- the node a multiplier that is another modifier's value is read from (ref: { scope, kind, id,
-- type }): -> category, owner. scope this: the object's own node; planet (a pop group's): its
-- colony's; colony (a planet's or a pop group's): its colony's; owner (a pop group's): its
-- country's
function S:ref_node(ref)
    local w = self.world
    if ref.scope == "this" then
        local cat = ({ pop_group = "PopGroup", planet = "Planet", country = "Country" })[ref.kind]
        return cat, ref.id
    elseif ref.kind == "pop_group" then
        local colony = w.field(w.object("pop_group", ref.id), "planet")
        if ref.scope == "planet" or ref.scope == "colony" then
            return "Colony", colony
        elseif ref.scope == "owner" then
            local planet = self.planet_of_colony[colony]
            return "Country", planet and w.field(w.object("planet", planet), "owner")
        end
    elseif ref.scope == "colony" and ref.kind == "planet" then
        return "Colony", w.field(w.object("planet", ref.id), "colony")
    end
    return nil
end

-- the active triggered blocks as parts of their own
function S:triggered(parts, label, folder, name, key, kind, id, from)
    for _, b in ipairs(self:active(folder, name, key, kind, id, from)) do
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

-- is_immortal: a leader with a trait (its own, or its species') of `immortal_leaders = yes`
function EXTRA_TRIGGERS.is_immortal(self, e, ctx)
    local r = ctx.this.kind == "leader" and self:immortal(ctx.this.id) or false
    return r == (e.value.text ~= "no")
end

-- has_relic = <relic>: in the country's relics
function EXTRA_TRIGGERS.has_relic(self, e, ctx)
    if ctx.this.kind ~= "country" then
        return false
    end
    for _, r in ipairs(list_of(self.world, self.world.object("country", ctx.this.id), "relics")) do
        if r == unq(e.value.text) then
            return true
        end
    end
    return false
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
    -- the colonized planets of each country; the planet each governor governs
    self.colonies_of, self.governed = {}, {}
    for _, pid in ipairs(w.all("planet")) do
        local p = w.object("planet", pid)
        local owner, colony = w.field(p, "owner"), w.field(p, "colony")
        if type(owner) == "number" and type(colony) == "number" then
            local l = self.colonies_of[owner] or {}
            self.colonies_of[owner] = l
            l[#l + 1] = pid
        end
        local gov = type(colony) == "number" and w.field(w.object("colony", colony), "governor")
        if type(gov) == "number" then
            self.governed[gov] = pid
        end
    end
    -- the planets of each system
    self.planets_of_system = {}
    for _, pid in ipairs(w.all("planet")) do
        local coord = w.field(w.object("planet", pid), "coordinate")
        local sys = type(coord) == "table" and tonumber(w.field(coord, "origin"))
        if sys then
            local l = self.planets_of_system[sys] or {}
            self.planets_of_system[sys] = l
            l[#l + 1] = pid
        end
    end
    -- the governors of each system's colonies; the system of each starbase
    self.governors_of_system, self.system_of_starbase = {}, {}
    for gov, pid in pairs(self.governed) do
        local coord = w.field(w.object("planet", pid), "coordinate")
        local sys = type(coord) == "table" and tonumber(w.field(coord, "origin"))
        if sys then
            local l = self.governors_of_system[sys] or {}
            self.governors_of_system[sys] = l
            l[#l + 1] = gov
        end
    end
    for _, l in pairs(self.governors_of_system) do
        table.sort(l)
    end
    for _, gid in ipairs(w.all("galactic_object")) do
        for _, sb in ipairs(list_of(w, w.object("galactic_object", gid), "starbases")) do
            self.system_of_starbase[tonumber(sb)] = gid
        end
    end
    -- the leader of each fleet: on one of its ships (location = { type = ship id = <ship> }), or
    -- its general, the leader of an army embarked in it
    self.fleet_general, self.fleet_leader = {}, {}
    for _, aid in ipairs(w.all("army")) do
        local a = w.object("army", aid)
        local leader, ship = tonumber(w.field(a, "leader")), tonumber(w.field(a, "ship"))
        local fleet = ship and tonumber(w.field(w.object("ships", ship), "fleet"))
        if leader and leader ~= 4294967295 and fleet then
            self.fleet_general[fleet] = leader
            self.fleet_leader[fleet] = leader
        end
    end
    for _, lid in ipairs(w.all("leader")) do
        local loc = w.field(w.object("leader", lid), "location")
        if type(loc) == "table" and unq(w.field(loc, "type")) == "ship" then
            local ship = tonumber(w.field(loc, "id"))
            local fleet = ship and tonumber(w.field(w.object("ships", ship), "fleet"))
            if fleet then
                self.fleet_leader[fleet] = lid
            end
        end
    end
    -- the recruited leaders of each background planet (not the recruitment pool's candidates,
    -- recruitment_date = 0.01.01)
    self.from_planet = {}
    for lid in pairs(self.leaders) do
        local o = w.object("leader", lid)
        local bg = w.field(o, "background_planet")
        local planet = type(bg) == "table" and tonumber(w.field(bg, "reference"))
        local recruited = unq(w.field(o, "recruitment_date")) ~= "0.01.01"
        if planet and planet ~= 4294967295 and recruited then
            local l = self.from_planet[planet] or {}
            self.from_planet[planet] = l
            l[#l + 1] = lid
        end
    end
    for _, l in pairs(self.from_planet) do
        table.sort(l)
    end
    -- the situations of each country
    self.situations_of = {}
    for _, sid in ipairs(w.all("situations")) do
        local c = tonumber(w.field(w.object("situations", sid), "country"))
        if c then
            local l = self.situations_of[c] or {}
            self.situations_of[c] = l
            l[#l + 1] = sid
        end
    end
    -- the country each ruler rules
    self.ruler_of = {}
    for _, cid in ipairs(w.all("country")) do
        local r = w.field(w.object("country", cid), "ruler")
        if type(r) == "number" then
            self.ruler_of[r] = cid
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

-- src:refresh([st]): the world changed (a month passed): its indexes made again and what was
-- computed from it dropped (the pop groups' shares, the new colonies, the structure: st, the
-- month's engine.modifiers.structure, or made again when needed); what was read from the files
-- (definitions' values and blocks, defines, keyed templates) is kept. A source kept so gives the
-- parts a new one would (the incremental graph keeps one; STELLAR_MODIFIER_CHECK compares)
function S:refresh(st)
    self.shared, self.new_count = nil, nil
    self.structure = st
    self:index_world()
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
    -- a definition's swap (technology_swap, tradition_swap) whose trigger holds for the country,
    -- the first: -> { values } (its own modifier; none when it does not inherit the effects; the
    -- definition's otherwise), or nil with no swap active. tech_hyper_drive_2 and _3 swap to their
    -- bio versions (no effects) for a country using bio ships; tr_unyielding_fortress_doctrine to
    -- its Nemesis version (its own modifier)
    local function swapped(folder, name, key)
        local d = self:def_block(folder, name)
        for _, e in ipairs(d and d.block or {}) do
            if e.op and e.key and e.key.text == key and type(e.value) == "table" then
                local t = self.defs.field(e.value, "trigger")
                if t and self:trigger(t, "country", id, d.file) then
                    local m = self.defs.field(e.value, "modifier")
                    if type(m) == "table" then
                        return { values = self:values(m, d.file) }
                    elseif self.defs.field(e.value, "inherit_effects") == "no" then
                        return { values = nil }
                    end
                    return nil
                end
            end
        end
        return nil
    end
    -- technologies (a repeatable's level as the multiplier)
    local ts = w.field(c, "tech_status")
    local last
    for _, e in ipairs(type(ts) == "table" and ts or {}) do
        if e.op and e.key.text == "technology" then
            last = unq(e.value.text)
        elseif e.op and e.key.text == "level" and last then
            local level = (tonumber(e.value.text) or 1) * 100000
            local swap = swapped("common/technology", last, "technology_swap")
            if swap then
                add("technology:" .. last .. ".swap", swap.values, level)
            else
                src("technology:" .. last, "common/technology", last, "modifier", level)
            end
            last = nil
        end
    end
    for _, t in ipairs(list_of(w, c, "traditions")) do
        local swap = swapped("common/traditions", t, "tradition_swap")
        if swap then
            add("tradition:" .. t .. ".swap", swap.values)
        else
            src("tradition:" .. t, "common/traditions", t, "modifier")
        end
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
            -- a swap_type whose trigger holds adds its modifier, a part of its own
            -- (civic_warrior_culture's enclave capacity with Overlord)
            local d = self:def_block("common/governments/civics", civic)
            for _, e in ipairs(d and d.block or {}) do
                if e.op and e.key and e.key.text == "swap_type" and type(e.value) == "table" then
                    local t = self.defs.field(e.value, "trigger")
                    local m = self.defs.field(e.value, "modifier")
                    if type(m) == "table" and (t == nil or self:trigger(t, "country", id, d.file)) then
                        add("civic:" .. civic .. ".swap", self:values(m, d.file))
                    end
                end
            end
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
    self:contributions(parts, id)
    -- an NPC country's difficulty bonuses: difficulty_<the galaxy's difficulty>_npc times its type's
    -- scaled_difficulty_bonuses and the galaxy's scale (S:difficulty_scale)
    local td = ctype and self.defs.get("common/country_types", ctype)
    local sdb = td and tonumber(self.defs.field(td.block, "scaled_difficulty_bonuses"))
    local galaxy = w.meta.galaxy
    local difficulty = type(galaxy) == "table" and unq(w.field(galaxy, "difficulty"))
    if sdb and sdb > 0 and difficulty then
        local name = "difficulty_" .. difficulty .. "_npc"
        add("static:" .. name, self:static(name), fixed(sdb * self:difficulty_scale()))
    end
    -- its situations: the active stage's modifier and triggered_modifier blocks, summed into one
    -- part, and the chosen approach's modifier (common/situations; the potentials are written in
    -- the situation's scope, `owner = { }` being the country)
    for _, sid in ipairs(self.situations_of[id] or {}) do
        local s = w.object("situations", sid)
        local ty = unq(w.field(s, "type"))
        local d = ty and self:def_block("common/situations", ty)
        if d then
            local stage = (tonumber(w.field(s, "stage")) or 0) + 1
            local stages = self.defs.field(d.block, "stages")
            local n, sum = 0, {}
            for _, e in ipairs(type(stages) == "table" and stages or {}) do
                if e.op and e.key and type(e.value) == "table" then
                    n = n + 1
                    if n == stage then
                        for _, x in ipairs(e.value) do
                            if x.op and x.key and type(x.value) == "table" then
                                if x.key.text == "modifier" then
                                    sum_into(sum, self:values(x.value, d.file))
                                elseif x.key.text == "triggered_modifier" then
                                    local pot = self.defs.field(x.value, "potential")
                                    if pot == nil or self:owner_trigger(pot, id, d.file) then
                                        local inner = self.defs.field(x.value, "modifier")
                                        sum_into(sum, self:values(x.value, d.file))
                                        if type(inner) == "table" then
                                            sum_into(sum, self:values(inner, d.file))
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
            add("situation:" .. ty, sum)
            local approach = unq(w.field(s, "approach"))
            for _, e in ipairs(d.block) do
                if e.op and e.key and e.key.text == "approach" and type(e.value) == "table"
                    and unq(self.defs.field(e.value, "name")) == approach then
                    local m = self.defs.field(e.value, "modifier")
                    add("situation:" .. ty .. "." .. approach, type(m) == "table" and self:values(m, d.file) or nil)
                end
            end
        end
    end
    -- resource deficits: a resource's deficit_modifier (common/strategic_resources) when its
    -- stockpile is empty and last month's balance of it negative (the resources with a
    -- deficit_situation have it as a situation). Not for a fallen empire: the 2211.07.01 one
    -- with no trade and -148 a month has no trade_deficit
    local eco = w.path(c, "modules", "standard_economy_module", "resources")
    local balance = w.path(c, "budget", "last_month", "balance")
    local ctd = self.defs.get("common/country_types", unq(w.field(c, "type")) or "")
    local fallen = ctd and self.defs.field(ctd.block, "fallen_empire") == "yes"
    if type(eco) == "table" and type(balance) == "table" and not fallen then
        for name, d in pairs(self.defs.folder("common/strategic_resources")) do
            local dm = unq(self.defs.field(d.block, "deficit_modifier"))
            local stock = tonumber(w.field(eco, name)) or 0
            if dm and stock <= 0 then
                local net = 0
                for _, e in ipairs(balance) do
                    if e.op and type(e.value) == "table" then
                        net = net + (tonumber(w.field(e.value, name)) or 0)
                    end
                end
                if net < 0 then
                    add("deficit:" .. name, self:static(dm))
                end
            end
        end
    end
    -- a federation's members (its leader too) pay federation_tax; its perks give each member their
    -- members_modifier (the leader too) and the leader their leader_modifier, and the triggered
    -- ones whose potential holds (common/federation_perks)
    local fid = self.federation_of[id]
    if fid then
        add("static:federation_tax", self:static("federation_tax"))
        local fed = w.object("federation", fid)
        local leader = tonumber(w.field(fed, "leader")) == id
        local prog = w.field(fed, "federation_progression")
        for _, b in ipairs(blocks_of(type(prog) == "table" and w.field(prog, "perks") or nil)) do
            local perk = unq(w.field(b, "type"))
            if perk then
                local F = "common/federation_perks"
                add("federation_perk:" .. perk, self:def_values(F, perk, "members_modifier"))
                self:triggered(parts, "federation_perk:" .. perk, F, perk, "member_triggered_modifier", "country", id)
                if leader then
                    add("federation_perk:" .. perk .. ".leader", self:def_values(F, perk, "leader_modifier"))
                    self:triggered(parts, "federation_perk:" .. perk .. ".leader", F, perk, "leader_triggered_modifier", "country", id)
                end
            end
        end
    end
    -- a navy short of its coverage: navy_coverage_shortage times the shortage, 1 - coverage. The
    -- coverage is the used naval capacity over half the empire size, at most 1: the target the
    -- navy_coverage of every country of both captures has (54 -> 27, 107 -> 53.5, 164 -> 82), where
    -- the save's own field can be the day before's (a country on 2210.01.01: 0.86956 saved, 75 /
    -- (161 / 2) = 0.93167 in the game). (empire_base's country_naval_coverage_mult, 1 for every
    -- country, may enter it: the captures do not tell how.) The save's field without an empire size
    local cov = w.field(c, "navy_coverage")
    local used, size = tonumber(w.field(c, "used_naval_capacity")), tonumber(w.field(c, "empire_size"))
    if used and size and size > 0 then
        -- (truncated to the fixed point, as the game keeps it: 15 / 27 is 0.55555)
        cov = math.min(1, math.floor(used / (size / 2) * 100000 + 1e-7) / 100000)
    end
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
        councilor(self:ruler_position(id), ruler, "ruler_trait")
    end
    return parts
end

-- the council position of a country's ruler: its authority's ruler_council_position, or that of
-- the first advanced_authority_swap whose trigger holds (common/governments/authorities)
function S:ruler_position(country)
    local w = self.world
    local gov = w.field(w.object("country", country), "government")
    local auth = type(gov) == "table" and unq(w.field(gov, "authority"))
    local d = type(auth) == "string" and self:def_block("common/governments/authorities", auth)
    if not d then
        return nil
    end
    local pos = self.defs.field(d.block, "ruler_council_position")
    for _, e in ipairs(d.block) do
        if e.op and e.key and e.key.text == "advanced_authority_swap" and type(e.value) == "table" then
            local p = self.defs.field(e.value, "ruler_council_position")
            local t = self.defs.field(e.value, "trigger")
            if p and t and self:trigger(t, "country", country, d.file) then
                pos = p
                break
            end
        end
    end
    return type(pos) == "string" and unq(pos) or nil
end

-- what a country's objects add to its node: the country_modifier blocks (and the
-- triggered_country_modifier blocks whose potential holds, in the object's planet's scope) of its
-- colonies' worked jobs (times their amount, (workforce + bonus) / 100) and buildings, of its
-- starbases' modules and buildings, of its megastructures
function S:contributions(parts, id)
    local w = self.world
    local jobs, buildings = {}, {}
    local function country_mods(sum, folder, ty, pid, mult)
        sum_into(sum, self:def_values(folder, ty, "country_modifier"), mult)
        for _, b in ipairs(self:active(folder, ty, "triggered_country_modifier", "planet", pid)) do
            sum_into(sum, b.values, scale(b.mult, mult or 100000))
        end
    end
    for _, pid in ipairs(self.colonies_of[id] or {}) do
        local col = w.object("colony", w.field(w.object("planet", pid), "colony"))
        for _, jid in ipairs(list_of(w, col, "pop_jobs")) do
            local o = w.object("pop_jobs", tonumber(jid))
            local ty = o and unq(w.field(o, "type"))
            local wf, bonus = w.field(o, "workforce"), w.field(o, "bonus_workforce")
            if ty and type(wf) == "number" and wf > 0 then
                country_mods(jobs, "common/pop_jobs", ty, pid, fixed((wf + (type(bonus) == "number" and bonus or 0)) / 100))
            end
        end
        for _, bid in ipairs(list_of(w, col, "buildings_cache")) do
            local o = w.object("buildings", tonumber(bid))
            local ty = o and unq(w.field(o, "type"))
            if ty then
                country_mods(buildings, "common/buildings", ty, pid)
            end
        end
    end
    parts.add("jobs#country", jobs)
    parts.add("buildings#country", buildings)
    -- (the starbases' country_modifier reach the country through their StarbaseCountry nodes)
    local mega = {}
    for _, mid in ipairs(w.all("megastructures")) do
        local o = w.object("megastructures", mid)
        if w.field(o, "owner") == id then
            sum_into(mega, self:def_values("common/megastructures", unq(w.field(o, "type")), "country_modifier"))
        end
    end
    parts.add("megastructures#country", mega)
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
    -- bombardment: planet_devastation times the devastation (bombardment_damage / 100, truncated)
    local dev = tonumber(w.field(p, "bombardment_damage"))
    if dev and dev > 0 then
        add("static:planet_devastation", self:static("planet_devastation"), math.floor(dev * 1000 + 1e-6))
    end
    -- the deposits, summed into one part: their planet_modifier and active triggered_planet_modifier
    -- blocks (a strategic resource's output once its technology is known)
    -- (an unsurveyed shielded world's deposits, those of the planet under the shield, do nothing:
    -- a guess from two worlds of the 2211.07.01 capture, the surveyed one's apply, the other's not)
    local hidden = class == "pc_shielded" and w.field(p, "surveyed_by") == nil
    local dep = {}
    for _, did in ipairs(list_of(w, p, "deposits")) do
        local o = w.object("deposit", tonumber(did))
        local ty = o and unq(w.field(o, "type"))
        if ty and not hidden then
            sum_into(dep, self:def_values("common/deposits", ty, "planet_modifier"))
            for _, b in ipairs(self:active("common/deposits", ty, "triggered_planet_modifier", "planet", id)) do
                sum_into(dep, b.values, b.mult)
            end
        end
    end
    add("deposits", dep)
    -- a habitat: the habitat_modifier of the deposits of its system's bodies (the star's, the
    -- asteroids'), one part
    if class == "pc_habitat" then
        local coord = w.field(p, "coordinate")
        local sys = type(coord) == "table" and tonumber(w.field(coord, "origin"))
        local hab = {}
        for _, pid in ipairs(sys and self.planets_of_system[sys] or {}) do
            for _, did in ipairs(list_of(w, w.object("planet", pid), "deposits")) do
                local ty = unq(w.field(w.object("deposit", tonumber(did)), "type"))
                if ty then
                    sum_into(hab, self:def_values("common/deposits", ty, "habitat_modifier"))
                end
            end
        end
        add("habitat_deposits", hab)
    end
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
        -- its own governor's skill statics and traits' planet_modifier blocks (triggered ones:
        -- this = the leader, from = the planet; common/traits/000_documentation_leader_traits.txt)
        if l and share == 100000 then
            self:skill_statics(parts, gov)
            for _, t in ipairs(l.traits) do
                add("governor:" .. t, self:def_values("common/traits", t, "planet_modifier"))
                self:triggered(parts, "governor:" .. t, "common/traits", t, "triggered_planet_modifier", "leader", gov,
                    { "planet", id })
            end
        end
    end
    -- the traits' background_planet_modifier blocks of the leaders from this planet
    for _, lid in ipairs(self.from_planet[id] or {}) do
        for _, t in ipairs(self.leaders[lid].traits) do
            add("background:" .. t, self:def_values("common/traits", t, "background_planet_modifier"))
            self:triggered(parts, "background:" .. t, "common/traits", t, "triggered_background_planet_modifier", "leader",
                lid, { "planet", id })
        end
    end
    return parts
end

-- colony --------------------------------------------------------------------------------------

-- the months from a date ("y.m.d") to the world's date
local function months_since(w, date)
    local y, m = tostring(date):match("^(%d+)%.(%d+)")
    local ny, nm = tostring(w.meta.date):gsub('"', ""):match("^(%d+)%.(%d+)")
    if not (y and ny) then
        return nil
    end
    return (tonumber(ny) - tonumber(y)) * 12 + tonumber(nm) - tonumber(m)
end

-- is_new_colony (common/game_rules): under 180 months old, under 1000 pops, not being colonized,
-- not a primitive's
function S:new_colony(id)
    local w = self.world
    local col = w.object("colony", id)
    local planet = self.planet_of_colony[id]
    local p = planet and w.object("planet", planet)
    if not (col and p) or w.field(col, "colonizing_species") ~= nil then
        return false
    end
    local owner = w.field(p, "owner")
    if type(owner) ~= "number" or unq(w.field(w.object("country", owner), "type")) == "primitive" then
        return false
    end
    local pops = w.field(col, "num_sapient_pops")
    local age = months_since(w, unq(w.field(p, "colonize_date")))
    return age ~= nil and age < 180 and type(pops) == "number" and pops < 1000
end

-- a country's new colonies and all its colonies (those being colonized too)
function S:new_colonies(country)
    self.new_count = self.new_count or {}
    local c = self.new_count[country]
    if c == nil then
        c = { 0, 0 }
        for _, pid in ipairs(self.colonies_of[country] or {}) do
            c[2] = c[2] + 1
            if self:new_colony(self.world.field(self.world.object("planet", pid), "colony")) then
                c[1] = c[1] + 1
            end
        end
        self.new_count[country] = c
    end
    return c[1], c[2]
end

-- a colony's stability (CColony::CalcPlanetStability, the engine session's docs/colonies.md
-- 3.2-3.3), from its node's values (get(type), the graph's) and its pop groups' happiness and
-- political power (the save's; a group without happiness there: 0.5 + its node's pop_happiness,
-- pop_citizen_happiness and pop_cat_<category>_happiness, at most 1); nil when the graph cannot
-- be read yet. 0 for a colony without an owner, 50 for one being colonized.
--   S = (50 + min(planet_stability_add_with_limit, ADDITIONAL_PLANET_STABILITY_LIMIT)
--        + planet_stability_add) * max(0, 1 + planet_stability_mult)
--   h = the average happiness weighted by political power, each held within (0.05, 20) below 0.5
--       and (0, 20) above (the MIN/MAX_POLITICAL_POWER_*_STABILITY_IMPACT defines)
--   S + (1 - h / 0.5) * LOW_HAPPINESS_STABILITY_EFFECT below 0.5, + (h - 0.5) / 0.5 *
--   HIGH_HAPPINESS_STABILITY_EFFECT above, within MIN/MAX_PLANET_STABILITY
-- Exact on every owned colony of both captures.
function S:colony_stability(id, get)
    local w = self.world
    local col = w.object("colony", id)
    local planet = self.planet_of_colony[id]
    local resolve = ref_of(self)
    if not (col and planet and resolve) then
        return nil
    end
    if type(w.field(w.object("planet", planet), "owner")) ~= "number" then
        return 0
    end
    local base = tonumber(self:define("BASE_PLANET_STABILITY")) or 50
    if w.field(col, "colonizing_species") ~= nil then
        return base
    end
    local add, mult, limited = get("planet_stability_add"), get("planet_stability_mult"), get("planet_stability_add_with_limit")
    if add == nil or mult == nil then
        return nil
    end
    local limit = tonumber(self:define("ADDITIONAL_PLANET_STABILITY_LIMIT")) or 15
    local s = (base + math.min((limited or 0) / 100000, limit) + add / 100000) * math.max(0, 1 + mult / 100000)
    local function def(k, d)
        return tonumber(self:define(k)) or d
    end
    local sp, sph = 0, 0
    for _, gid in ipairs(list_of(w, col, "pop_groups")) do
        local g = w.object("pop_group", tonumber(gid))
        if g and w.field(g, "killed") ~= "yes" then
            local h = tonumber(w.field(g, "happiness"))
            if h == nil then
                local cat = unq(w.field(w.field(g, "key") or {}, "category"))
                local function pv(t)
                    return resolve({ scope = "this", kind = "pop_group", id = tonumber(gid), type = self.canon[t] or t }) or 0
                end
                h = 0.5 + (pv("pop_happiness") + pv("pop_citizen_happiness") + pv("pop_cat_" .. tostring(cat) .. "_happiness")) / 100000
                h = math.max(0, math.min(1, h))
            end
            local pw = tonumber(w.field(g, "power")) or 0
            if h < 0.5 then
                pw = math.max(def("MIN_POLITICAL_POWER_NEGATIVE_STABILITY_IMPACT", 0.05),
                    math.min(def("MAX_POLITICAL_POWER_NEGATIVE_STABILITY_IMPACT", 20), pw))
            else
                pw = math.max(def("MIN_POLITICAL_POWER_POSITIVE_STABILITY_IMPACT", 0),
                    math.min(def("MAX_POLITICAL_POWER_POSITIVE_STABILITY_IMPACT", 20), pw))
            end
            sp = sp + pw
            -- (each product truncated to the fixed point, as the game's is)
            sph = sph + math.floor(pw * h * 100000 + 1e-7) / 100000
        end
    end
    if sp > 0 then
        -- (the average truncated to the fixed point, as the game's is: 0.962587 is 0.96258)
        local h = math.floor(sph / sp * 100000 + 1e-7) / 100000
        if h < 0.5 then
            s = s + (1 - h / 0.5) * def("LOW_HAPPINESS_STABILITY_EFFECT", -50)
        else
            s = s + (h - 0.5) / 0.5 * def("HIGH_HAPPINESS_STABILITY_EFFECT", 30)
        end
    end
    return math.max(def("MIN_PLANET_STABILITY", 0), math.min(def("MAX_PLANET_STABILITY", 100), s))
end

-- The colony's status modifiers (static modifiers scaled by how far the colony is past a
-- threshold; read from the 2210 capture, where each multiplier matches the save's colony fields):
--   stability (S:colony_stability) above 50: planet_stability_high x (stability - 50) / 50, below:
--     _low x (50 - s) / 50
--   amenities: planet_amenities_high x (amenities / usage - 1), _low x (1 - amenities / usage) / 0.75
--   housing: planet_housing_high x (housing / usage - 1) / 3, _low x (1 - housing / usage) / 0.5,
--     and planet_overcrowded when the free housing is negative
--   employment: planet_employment_low x the unemployed pops (workforce / 100, whole), _high x the
--     open workforce of the jobs (workforce_limit - workforce)
-- each at most 1 (employment unbounded), its multiplier truncated (not rounded) to the fixed point;
-- a gestalt country's colonies, and colonies with no pops, use the _no_happiness_ ones.
--   new_colony on a new colony (common/game_rules is_new_colony: under 180 months old, under 1000
--     pops, not being colonized; not a primitive's), old_colony on the others times the share of
--     the owner's colonies that are new (those being colonized counted, not given it)
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
    local pops = w.field(col, "num_sapient_pops")
    local nh = (gestalt or type(pops) ~= "number" or pops <= 0) and "_no_happiness" or ""
    local function num(k)
        local v = w.field(col, k)
        return type(v) == "number" and v or nil
    end
    local function status(name, x, cap)
        if x and x > 0 then
            if cap ~= false then
                x = math.min(x, 1)
            end
            parts.add("status:" .. name, self:static(name), math.floor(x * 100000 + 1e-6))
        end
    end
    -- new and old colonies
    if oc and w.field(col, "colonizing_species") == nil then
        if self:new_colony(id) then
            parts.add("status:new_colony", self:static("new_colony"))
        else
            local new, all = self:new_colonies(owner)
            if new > 0 then
                parts.add("status:old_colony", self:static("old_colony"), math.floor(new / all * 100000 + 1e-6))
            end
        end
    end
    -- a value of the colony's node, read from the graph (self.resolve_ref), or nil
    local resolve = ref_of(self)
    local function get(t)
        return resolve and planet
            and resolve({ scope = "colony", kind = "planet", id = planet, type = self.canon[t] or t }) or nil
    end
    local stability = self:colony_stability(id, get) or num("stability")
    if stability then
        status("planet_stability" .. nh .. "_high", (stability - 50) / 50)
        status("planet_stability" .. nh .. "_low", (50 - stability) / 50)
    end
    -- the amenities: the colony node's (planet_amenities_add + planet_amenities_no_happiness_add) x
    -- (1 + planet_amenities_mult + planet_amenities_no_happiness_mult), read from the graph
    -- (self.resolve_ref) where it can be: exact on every colony of the 2211.07.01 capture, where
    -- the save's field is not (the save's is the end of the previous day); else the save's. (A
    -- fallen empire's colony with both mults at 0.05: 18000 x 1.1 = 19800, as the save has it)
    local amenities, ausage = num("amenities"), num("amenities_usage")
    if resolve and planet then
        local add, mult = get("planet_amenities_add"), get("planet_amenities_mult")
        if add and mult then
            local nadd, nmult = get("planet_amenities_no_happiness_add"), get("planet_amenities_no_happiness_mult")
            amenities = (add + (nadd or 0)) / 100000 * (1 + (mult + (nmult or 0)) / 100000)
        end
    end
    -- (CColony::GetAmenitiesEffectScale: above, (r - 1) / (MAX_PLANET_AMENITIES - 1); below,
    -- 1 - (r - MIN_PLANET_AMENITIES) / (1 - MIN), MIN 0.25: the engine session's
    -- docs/colonies.md 3.5; in the fixed point, the ratio and the division truncated: 1 -
    -- 0.69614 is 0.30386, where (1 - r) / 0.75 truncated is 0.30385)
    local function trunc(x)
        return math.floor(x * 100000 + 1e-7) / 100000
    end
    local function scales(r, lo, hi)
        return (r - 1) / (hi - 1), 1 - trunc((r - lo) / (1 - lo))
    end
    if amenities and ausage and ausage > 0 then
        local high, low = scales(trunc(amenities / ausage), tonumber(self:define("MIN_PLANET_AMENITIES")) or 0.25,
            tonumber(self:define("MAX_PLANET_AMENITIES")) or 2)
        status("planet_amenities" .. nh .. "_high", high)
        status("planet_amenities" .. nh .. "_low", low)
    end
    -- the housing: its usage the sum of the pop groups' (a colony's own field can be one more:
    -- 5883 saved, 5882 the groups', as the game has it), the scale as the amenities' with
    -- MIN/MAX_PLANET_RELATIVE_HOUSING (0.5, 4), the ratio not truncated (a 2210.01.01 colony: 1300 /
    -- 1422 gives the game's 0.17159 only so)
    local housing, husage = num("total_housing"), num("housing_usage")
    local gsum, groups = 0, 0
    for _, gid in ipairs(list_of(w, col, "pop_groups")) do
        local g = w.object("pop_group", tonumber(gid))
        local u = g and w.field(g, "killed") ~= "yes" and tonumber(w.field(g, "housing_usage"))
        if u then
            gsum, groups = gsum + u, groups + 1
        end
    end
    if groups > 0 then
        husage = gsum
    end
    if housing and husage and husage > 0 then
        local high, low = scales(housing / husage, tonumber(self:define("MIN_PLANET_RELATIVE_HOUSING")) or 0.5,
            tonumber(self:define("MAX_PLANET_RELATIVE_HOUSING")) or 4)
        status("planet_housing" .. nh .. "_high", high)
        status("planet_housing" .. nh .. "_low", low)
        if housing < husage then
            parts.add("status:planet_overcrowded", self:static("planet_overcrowded"))
        end
    end
    -- the unemployed: the pops of its groups of a category with is_unemployment_job
    -- (common/pop_categories: slave_unemployment, ...), where the save's unemploy_pop can be the
    -- day before's (799 saved, 801 in the groups: the game's 8 steps)
    local unemployed = num("unemploy_pop")
    local usum, ugroups = 0, 0
    for _, gid in ipairs(list_of(w, col, "pop_groups")) do
        local g = w.object("pop_group", tonumber(gid))
        local cat = g and w.field(g, "killed") ~= "yes" and unq(w.field(w.field(g, "key") or {}, "category"))
        local cd = type(cat) == "string" and self.defs.get("common/pop_categories", cat)
        if cd then
            ugroups = ugroups + 1
            if self.defs.field(cd.block, "is_unemployment_job") == "yes" then
                usum = usum + (tonumber(w.field(g, "size")) or 0)
            end
        end
    end
    if ugroups > 0 then
        unemployed = usum
    end
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
-- the founder species' (primary), else the default (explicit: only an entry of its own)
function S:rights(country, species, explicit)
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
    if explicit then
        return nil
    end
    local primary = w.field(mod, "primary")
    if type(primary) == "table" and w.field(primary, "species_index") == species then
        return primary
    end
    local default = w.field(mod, "default")
    return type(default) == "table" and default or nil
end

-- the blocks of a colony's buildings (each building) and worked jobs (times the job's amount)
-- shared between its pop groups, divided in proportion to size (common/buildings/00_example.txt):
-- triggered_planet_pop_group_modifier_for_species (potential in each pop group's scope; between
-- the pop groups of the same species for which it holds) and _for_all (potential in the planet's;
-- between all its pop groups). -> { [pop group] = { { name, values, mult } } }, cached per colony;
-- the share truncated to the fixed point (4167 of 7384 pops: 56432)
function S:shared_pop_parts(colony)
    self.shared = self.shared or {}
    local out = self.shared[colony]
    if out then
        return out
    end
    out = {}
    self.shared[colony] = out
    local w = self.world
    local col = w.object("colony", colony)
    local planet = self.planet_of_colony[colony]
    if not (col and planet) then
        return out
    end
    local groups = {}
    for _, gid in ipairs(list_of(w, col, "pop_groups")) do
        local g = w.object("pop_group", tonumber(gid))
        local size = g and w.field(g, "size")
        if g and w.field(g, "killed") ~= "yes" and type(size) == "number" and size > 0 then
            groups[#groups + 1] = { id = tonumber(gid), size = size, species = w.field(w.field(g, "key") or {}, "species") }
        end
    end
    local function share(label, block, file, mult)
        local values = self:values(block, file)
        if not values or next(values) == nil then
            return
        end
        local pot = self.defs.field(block, "potential")
        local eligible, total = {}, {}
        for _, g in ipairs(groups) do
            local ok = pot == nil or self:trigger(pot, "pop_group", g.id, file)
            if ok then
                eligible[#eligible + 1] = g
                local k = tostring(g.species)
                total[k] = (total[k] or 0) + g.size
            end
        end
        for _, g in ipairs(eligible) do
            local frac = math.floor(g.size / total[tostring(g.species)] * 100000 + 1e-6)
            local l = out[g.id] or {}
            out[g.id] = l
            l[#l + 1] = { name = label, values = values, mult = scale(frac, mult) }
        end
    end
    local function share_all(label, block, file, mult)
        local values = self:values(block, file)
        local pot = self.defs.field(block, "potential")
        if not values or next(values) == nil or (pot ~= nil and not self:trigger(pot, "planet", planet, file)) then
            return
        end
        local total = 0
        for _, g in ipairs(groups) do
            total = total + g.size
        end
        for _, g in ipairs(groups) do
            local l = out[g.id] or {}
            out[g.id] = l
            l[#l + 1] = { name = label, values = values, mult = scale(math.floor(g.size / total * 100000 + 1e-6), mult) }
        end
    end
    local function scan(folder, ty, label, mult)
        local d = self:def_block(folder, ty)
        for _, e in ipairs(d and d.block or {}) do
            if e.op and e.key and type(e.value) == "table" then
                if e.key.text == "triggered_planet_pop_group_modifier_for_species" then
                    share(label, e.value, d.file, mult)
                elseif e.key.text == "triggered_planet_pop_group_modifier_for_all" then
                    share_all(label, e.value, d.file, mult)
                end
            end
        end
    end
    for _, bid in ipairs(list_of(w, col, "buildings_cache")) do
        local ty = unq(w.field(w.object("buildings", tonumber(bid)), "type"))
        if ty then
            scan("common/buildings", ty, "shared:" .. ty, 100000)
        end
    end
    for _, jid in ipairs(list_of(w, col, "pop_jobs")) do
        local o = w.object("pop_jobs", tonumber(jid))
        local ty = o and unq(w.field(o, "type"))
        local wf, bonus = w.field(o, "workforce"), w.field(o, "bonus_workforce")
        if ty and type(wf) == "number" and wf > 0 then
            scan("common/pop_jobs", ty, "shared:" .. ty, fixed((wf + (type(bonus) == "number" and bonus or 0)) / 100))
        end
    end
    return out
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
        -- each trait's triggered modifiers, a part each: triggered_pop_group_modifier in the pop
        -- group's scope, triggered_species_modifier in the species' with the owner as from
        -- (trait_psionic's pop_happiness for a country that is not gestalt)
        local colony = w.field(g, "planet")
        local planet = type(colony) == "number" and self.planet_of_colony[colony]
        local owner = planet and tonumber(w.field(w.object("planet", planet), "owner"))
        for _, trait in ipairs(names) do
            self:triggered(parts, "trait:" .. trait, "common/traits", trait, "triggered_pop_group_modifier", "pop_group", id)
            if owner then
                self:triggered(parts, "trait:" .. trait .. ".species", "common/traits", trait, "triggered_species_modifier",
                    "species", species, { "country", owner })
            end
        end
    end
    -- its faction approval: the static its approval_modifier names (faction_approval_high, ...)
    local approval = unq(w.field(g, "approval_modifier"))
    if type(approval) == "string" then
        add("approval:" .. approval, self:static(approval))
    end
    -- the owner's species rights. A fallen empire's: only the slavery or purge type of a species'
    -- own entry (its enslaved species), not its living standard or citizenship, nor the primary
    -- or default rights
    local colony = w.field(g, "planet")
    local planet = type(colony) == "number" and self.planet_of_colony[colony]
    local owner = planet and w.field(w.object("planet", planet), "owner")
    local oc = type(owner) == "number" and w.object("country", owner)
    local otype = oc and unq(w.field(oc, "type"))
    local td = otype and self.defs.get("common/country_types", otype)
    local fallen = td and self.defs.field(td.block, "fallen_empire") == "yes"
    local rights = oc and type(species) == "number" and self:rights(owner, species, fallen)
    if rights then
        local R = "common/species_rights/"
        local function right(field, folder, applies)
            local v = unq(w.field(rights, field))
            if v and applies ~= false then
                add(field .. ":" .. v, self:def_values(R .. folder, v, "pop_group_modifier"))
                self:triggered(parts, field .. ":" .. v, R .. folder, v, "triggered_pop_group_modifier", "pop_group", id)
            end
            return v
        end
        right("living_standard", "living_standards", not fallen)
        local cit = right("citizenship", "citizenship_types", not fallen)
        if cit == "citizenship_slavery" then
            right("slavery", "slavery_types")
        elseif cit == "citizenship_purge" then
            right("purge", "purge_types")
        end
        right("population_control", "population_controls", not fallen)
    end
    -- low habitability: pop_low_habitability times the shortfall
    local hab = w.field(g, "habitability")
    if type(hab) == "number" and hab < 1 then
        add("static:pop_low_habitability", self:static("pop_low_habitability"), 100000 - fixed(hab))
    end
    -- its share of the colony's shared blocks (S:shared_pop_parts)
    if type(colony) == "number" then
        for _, p in ipairs(self:shared_pop_parts(colony)[id] or {}) do
            add(p.name, p.values, p.mult)
        end
    end
    return parts
end

-- ship ----------------------------------------------------------------------------------------

-- A ship's own parts: the ship_modifier of each component of its design (the design's growth stage
-- of the ship: its sections' components and its required components), and of its sections.
function S:ship(id)
    local w = self.world
    local s = w.object("ships", id)
    local parts = new_parts(M.FILTER.Ship)
    if s == nil then
        return parts
    end
    -- its timed modifiers; a military ship's rank by experience (SHIP_EXP_EXPERIENCED / _VETERAN /
    -- _ELITE: ship_rank_experienced, ...; ship_rank_regular below). The transports and
    -- constructors with 100 experience in the 2211.07.01 capture have no rank
    self:timed(parts, s)
    local fleet = tonumber(w.field(s, "fleet"))
    if unq(w.field(fleet and w.object("fleet", fleet), "ship_class")) == "shipclass_military" then
        local exp = tonumber(w.field(s, "experience")) or 0
        local rank = "regular"
        for _, r in ipairs({ { "elite", "SHIP_EXP_ELITE", 10000 }, { "veteran", "SHIP_EXP_VETERAN", 1000 },
            { "experienced", "SHIP_EXP_EXPERIENCED", 100 } }) do
            if rank == "regular" and exp >= (tonumber(self:define(r[2])) or r[3]) then
                rank = r[1]
            end
        end
        parts.add("static:ship_rank_" .. rank, self:static("ship_rank_" .. rank))
    end
    local impl = w.field(s, "ship_design_implementation")
    local did = type(impl) == "table" and w.field(impl, "design")
    local stage = type(impl) == "table" and tonumber(w.field(impl, "growth_stage")) or 0
    local design = type(did) == "number" and w.object("ship_design", did)
    local gs = design and blocks_of(w.field(design, "growth_stages"))[stage + 1]
    if gs == nil then
        return parts
    end
    local C, T = "common/component_templates", "common/section_templates"
    -- the ship size's ship_modifier (a starport's armor, evasion, fire rate and range; its
    -- `modifier`, the starbase's capacities and sensor range, is not the ship's). A starbase's
    -- station is the size of the starbase's level, whatever its design says.
    self.structure = self.structure or require("engine.modifiers.structure").new(w, self.defs)
    local size = unq(w.field(gs, "ship_size"))
    -- the starbases whose station it is (station_of inverted once per structure, in its pairs
    -- order: a scan of every starbase for every ship had been)
    if self.stations_of == nil or self.stations_for ~= self.structure then
        local inv = {}
        for sb, station in pairs(self.structure.station_of) do
            local l = inv[station] or {}
            inv[station] = l
            l[#l + 1] = sb
        end
        self.stations_of, self.stations_for = inv, self.structure
    end
    for _, sb in ipairs(self.stations_of[id] or {}) do
        local level = unq(w.field(w.object("starbases", sb), "level"))
        local ld = level and self.defs.get("common/starbase_levels", level)
        size = ld and unq(self.defs.field(ld.block, "ship_size")) or size
    end
    if size then
        parts.add("ship_size:" .. size, self:def_values("common/ship_sizes", size, "ship_modifier"))
    end
    -- the auras the ship is in (the save keeps their sum: aura_modifier = { ... })
    parts.add("auras", self:values(w.field(s, "aura_modifier"), nil))
    -- repairs: ship_orbit_repair while its fleet is docked at a starbase of its own country (the
    -- 289 ships of the 2211.07.01 capture that have it, and no other)
    local fleet = tonumber(w.field(s, "fleet"))
    local mm = fleet and self.structure:fleet_movement(fleet)
    local orbit = mm and w.field(mm, "orbit")
    local at = type(orbit) == "table" and w.field(orbit, "orbitable")
    local sb = type(at) == "table" and tonumber(w.field(at, "starbase"))
    if sb and self.structure.starbase_owner[sb] == self.structure.fleet_owner[fleet] then
        parts.add("static:ship_orbit_repair", self:static("ship_orbit_repair"))
    end
    for _, e in ipairs(gs) do
        if e.op and e.key then
            local k = e.key.text
            if k == "section" and type(e.value) == "table" then
                local template = unq(w.field(e.value, "template"))
                parts.add("section:" .. tostring(template), self:keyed_values(T, template, "ship_modifier"))
                for _, c in ipairs(e.value) do
                    if c.op and c.key and c.key.text == "component" and type(c.value) == "table" then
                        local ct = unq(w.field(c.value, "template"))
                        parts.add("component:" .. tostring(ct), self:keyed_values(C, ct, "ship_modifier"))
                    end
                end
            elseif k == "required_component" and e.value.text then
                local ct = unq(e.value.text)
                parts.add("component:" .. ct, self:keyed_values(C, ct, "ship_modifier"))
            end
        end
    end
    return parts
end

-- fleets ----------------------------------------------------------------------------------------

-- the filter of a fleet's triggered parts (its plain parts have M.FILTER.Fleet)
M.FLEET_TRIGGERED_FILTER = 1074447102

-- Fleet: its system's star class `modifier`; its leader's class skill static times its level and
-- the leader's traits' modifier and fleet_modifier blocks, and their triggered blocks
-- (triggered_modifier, triggered_fleet_modifier, potential in the leader's scope) with a filter of
-- their own
function S:fleet(id)
    local w = self.world
    local parts = new_parts(M.FILTER.Fleet)
    local fl = w.object("fleet", id)
    if fl == nil then
        return parts
    end
    local mm = w.field(fl, "movement_manager")
    local coord = type(mm) == "table" and w.field(mm, "coordinate")
    local sys = type(coord) == "table" and tonumber(w.field(coord, "origin"))
    local star = sys and unq(w.field(w.object("galactic_object", sys), "star_class"))
    if type(star) == "string" then
        parts.add("star:" .. star, self:def_values("common/star_classes", star, "modifier"))
    end
    local leader = self.fleet_leader[id]
    local l = leader and self.leaders[leader]
    if l then
        self:class_skill(parts, leader)
        for _, t in ipairs(l.traits) do
            for _, key in ipairs({ "modifier", "fleet_modifier" }) do
                parts.add("trait:" .. t .. "." .. key, self:def_values("common/traits", t, key))
            end
        end
        parts.filter = M.FLEET_TRIGGERED_FILTER
        for _, t in ipairs(l.traits) do
            for _, key in ipairs({ "triggered_modifier", "triggered_fleet_modifier" }) do
                self:triggered(parts, "trait:" .. t .. "." .. key, "common/traits", t, key, "leader", leader)
            end
        end
        parts.filter = M.FILTER.Fleet
    end
    return parts
end

-- armies ----------------------------------------------------------------------------------------

-- Army: its species' traits; its general's (its own leader, or its fleet's general, not the
-- fleet's admiral) class skill times its level and traits' army_modifier and
-- triggered_army_modifier blocks
function S:army(id)
    local w = self.world
    local parts = new_parts(M.FILTER.Army)
    local a = w.object("army", id)
    if a == nil then
        return parts
    end
    parts.add("species_traits", (self:species_traits(tonumber(w.field(a, "species")))))
    local general = tonumber(w.field(a, "leader"))
    local own = general ~= nil and self.leaders[general] ~= nil
    if not own then
        local ship = tonumber(w.field(a, "ship"))
        local fleet = ship and tonumber(w.field(w.object("ships", ship), "fleet"))
        general = fleet and self.fleet_general[fleet]
    end
    local l = general and self.leaders[general]
    if l then
        self:class_skill(parts, general)
    end
    for _, t in ipairs(l and l.traits or {}) do
        parts.add("general:" .. t, self:def_values("common/traits", t, "army_modifier"))
        -- the triggered blocks only for its own leader: the capture has none from a fleet's
        -- general (their potentials read the leader, as leader_class does, which an army without
        -- one does not have)
        if own then
            self:triggered(parts, "general:" .. t, "common/traits", t, "triggered_army_modifier", "leader", general)
        end
    end
    return parts
end

-- sectors and systems ---------------------------------------------------------------------------

-- Sector: the sector_modifier and triggered_sector_modifier blocks of the traits of the governor
-- of its capital, when the capital is not occupied (common/traits/000_documentation_leader_traits.txt)
function S:sector(id)
    local w = self.world
    local parts = new_parts(M.FILTER.Sector)
    local o = w.object("sectors", id)
    local cap = o and tonumber(w.field(o, "local_capital"))
    local col = cap and w.object("colony", cap)
    local gov = col and tonumber(w.field(col, "governor"))
    local l = gov and self.leaders[gov]
    local planet = cap and self.planet_of_colony[cap]
    local p = planet and w.object("planet", planet)
    if not (l and p) then
        return parts
    end
    local controller = w.field(p, "controller")
    if controller ~= nil and controller ~= w.field(p, "owner") then
        return parts
    end
    for _, t in ipairs(l.traits) do
        parts.add("governor:" .. t, self:def_values("common/traits", t, "sector_modifier"))
        self:triggered(parts, "governor:" .. t, "common/traits", t, "triggered_sector_modifier", "leader", gov)
    end
    return parts
end

-- GalacticObjectTimed: the system's timed modifiers (turbulent_nebula, storms)
function S:system_timed(id)
    local parts = new_parts(M.FILTER.GalacticObjectTimed)
    local o = self.world.object("galactic_object", id)
    if o then
        self:timed(parts, o)
    end
    return parts
end

-- leaders ---------------------------------------------------------------------------------------

-- where a leader is: its location's type (ship, army, planet, ...) and id, or nil
function S:leader_location(id)
    local w = self.world
    local loc = w.field(w.object("leader", id), "location")
    if type(loc) ~= "table" then
        return nil
    end
    return unq(w.field(loc, "type")), tonumber(w.field(loc, "id"))
end

-- the class's skill static of a leader by where it is (common/static_modifiers skill_*): a
-- scientist's anywhere, a commander's on a ship or an army
local SKILL_AT = {
    scientist = { any = "skill_scientist" },
    commander = { ship = "skill_commander_navy", army = "skill_commander_army" },
}

-- the trait blocks of a leader's traits: key (modifier, self_modifier, fleet_modifier, ...) and its
-- triggered blocks (triggered_<key>, potential in the leader's scope)
function S:leader_traits(parts, id, key, mult)
    local l = self.leaders[id]
    for _, t in ipairs(l and l.traits or {}) do
        parts.add("trait:" .. t, self:def_values("common/traits", t, key), mult)
        self:triggered(parts, "trait:" .. t, "common/traits", t, "triggered_" .. key, "leader", id)
    end
end

-- a leader is immortal when made so (created `immortal = yes`, or set_immortal: the bit of value 2
-- in the save's leader_flags, which the caravaneers' leaders have and mortal ones with flags
-- lack), or with a trait of `immortal_leaders = yes`, its own or its species'
function S:immortal(id)
    local w = self.world
    local l = self.leaders[id]
    if l == nil then
        return false
    end
    if l.immortal == nil then
        local flags = tonumber(w.field(w.object("leader", id), "leader_flags")) or 0
        l.immortal = bit.band(flags, 2) ~= 0
        local traits = {}
        for _, t in ipairs(l.traits) do
            traits[#traits + 1] = t
        end
        local _, names = self:species_traits(tonumber(w.field(w.object("leader", id), "species")))
        for _, t in ipairs(names) do
            traits[#traits + 1] = t
        end
        for _, t in ipairs(traits) do
            local d = self:def_block("common/traits", t)
            if d and self.defs.field(d.block, "immortal_leaders") == "yes" then
                l.immortal = true
            end
        end
    end
    return l.immortal
end

-- a leader's class's skill static (SKILL_AT) times its level
function S:class_skill(parts, id)
    local l = self.leaders[id]
    local skill = SKILL_AT[l.class]
    local static = skill and (skill.any or skill[(self:leader_location(id))])
    if static then
        parts.add("skill:" .. static, self:static(static), l.level * 100000)
    end
end

-- a leader's skill statics times its level: its class's (S:class_skill), and
-- skill_<class>_background_planet_governor when the planet it governs is its background planet
-- (neither counts as equal: a leader with no background planet that governs nothing has it)
function S:skill_statics(parts, id)
    local w = self.world
    local l = self.leaders[id]
    local level = l.level * 100000
    self:class_skill(parts, id)
    local bg = w.field(w.object("leader", id), "background_planet")
    local bg_planet = type(bg) == "table" and tonumber(w.field(bg, "reference")) or 4294967295
    if (self.governed[id] or 4294967295) == bg_planet then
        local name = "skill_" .. tostring(l.class) .. "_background_planet_governor"
        parts.add("skill:" .. name, self:static(name), level)
    end
end

-- LeaderSkill: the skill statics (S:skill_statics); a ruler's council position's `modifier` times
-- its level (S:ruler_position); the traits' `modifier` blocks. Their triggered_modifier blocks are
-- not in this node in the capture (the trait files say they are there for the tooltips).
function S:leader_skill(id)
    local parts = new_parts(-1)
    local l = self.leaders[id]
    if l == nil then
        return parts
    end
    local level = l.level * 100000
    self:skill_statics(parts, id)
    local country = self.ruler_of[id]
    local pos = country and self:ruler_position(country)
    if pos then
        parts.add("ruler:" .. pos, self:def_values("common/governments/councilors", pos, "modifier"), level)
    end
    for _, t in ipairs(l.traits) do
        parts.add("trait:" .. t, self:def_values("common/traits", t, "modifier"))
    end
    return parts
end

-- the traits of a species, their `modifier` blocks summed (what a pop group, a leader or an army of
-- that species gets of them; the node's filter keeps its own types)
function S:species_traits(species)
    local w = self.world
    local sp = type(species) == "number" and w.object("species", species)
    local sum, names = {}, {}
    if not sp then
        return sum, names
    end
    local traits = w.field(sp, "traits")
    for _, e in ipairs(type(traits) == "table" and traits or {}) do
        if e.op and e.key.text == "trait" then
            local trait = unq(e.value.text)
            names[#names + 1] = trait
            sum_into(sum, self:def_values("common/traits", trait, "modifier"))
        end
    end
    return sum, names
end

-- Leader: its species' traits, the traits' self_modifier blocks
function S:leader(id)
    local w = self.world
    local parts = new_parts(M.FILTER.Leader)
    if self.leaders[id] == nil then
        return parts
    end
    local species = tonumber(w.field(w.object("leader", id), "species"))
    parts.add("species_traits", (self:species_traits(species)))
    self:leader_traits(parts, id, "self_modifier")
    return parts
end

-- starbases -------------------------------------------------------------------------------------

-- A starbase's nodes take their parts from its level and its modules and buildings (`modules = {
-- 0 = shipyard ... }`, `buildings = { ... }`), each block to its node, with the filters the captures
-- show:
--   Starbase                 its level's ship size's `modifier` (sensor range, capacities), and the
--                            station_modifier (and the active triggered_station_modifier) blocks
--   StarbaseCountry          country_modifier, triggered_country_modifier (its country reads it)
--   StarbaseExternal         planet_modifier, triggered_planet_modifier; the system's governors (S:starbase_node)
--   StarbaseSystem           system_modifier, triggered_system_modifier
--   StarbaseDefensePlatform  defense_platform_modifier (its defense platforms read it)
--   Orbital                  orbit_modifier (the fleets docked at it read it)
local STARBASE_BLOCKS = {
    Starbase = { "station_modifier", 1076806270 },
    StarbaseCountry = { "country_modifier", -1 },
    StarbaseExternal = { "planet_modifier", 1076806270 },
    StarbaseSystem = { "system_modifier", 1074317566 },
    StarbaseDefensePlatform = { "defense_platform_modifier", 540796 },
    Orbital = { "orbit_modifier", 1074282750 },
}
M.STARBASE_CATEGORIES = { "Starbase", "StarbaseCountry", "StarbaseExternal", "StarbaseSystem",
    "StarbaseDefensePlatform", "Orbital" }

function S:starbase_node(category, id)
    local w = self.world
    local o = w.object("starbases", id)
    local block, filter = STARBASE_BLOCKS[category][1], STARBASE_BLOCKS[category][2]
    local parts = new_parts(filter)
    if o == nil then
        return parts
    end
    if category == "StarbaseExternal" then
        -- the governors of the colonies in its system: skill_<class>_planet_governor and their
        -- skill statics, times their level
        for _, gov in ipairs(self.governors_of_system[self.system_of_starbase[id]] or {}) do
            local l = self.leaders[gov]
            if l then
                local name = "skill_" .. tostring(l.class) .. "_planet_governor"
                parts.add("governor:" .. name, self:static(name), l.level * 100000)
                self:skill_statics(parts, gov)
            end
        end
    end
    if category == "Starbase" then
        local level = unq(w.field(o, "level"))
        local ld = level and self.defs.get("common/starbase_levels", level)
        local size = ld and unq(self.defs.field(ld.block, "ship_size"))
        if size then
            parts.filter = 1345241726
            parts.add("level:" .. level, self:def_values("common/ship_sizes", size, "modifier"))
            parts.filter = filter
        end
    end
    for _, key in ipairs({ "modules", "buildings" }) do
        local b = w.field(o, key)
        local folder = key == "modules" and "common/starbase_modules" or "common/starbase_buildings"
        for _, e in ipairs(type(b) == "table" and b or {}) do
            local ty = e.op and e.value and unq(e.value.text)
            if ty then
                parts.add(key .. ":" .. ty, self:def_values(folder, ty, block))
                self:triggered(parts, key .. ":" .. ty, folder, ty, "triggered_" .. block, "starbase", id)
            end
        end
    end
    return parts
end

-- ---------------------------------------------------------------------------------------------

local BY_CATEGORY = { Country = S.country, Planet = S.planet, Colony = S.colony, PopGroup = S.pop_group, Ship = S.ship,
    Fleet = S.fleet, Army = S.army, Sector = S.sector, GalacticObjectTimed = S.system_timed, Leader = S.leader,
    LeaderSkill = S.leader_skill }
for _, c in ipairs(M.STARBASE_CATEGORIES) do
    BY_CATEGORY[c] = function(self, id) return self:starbase_node(c, id) end
end

-- src:parts(category, owner) -> the node's own parts ({ name, mult, filter, values }), or nil for a
-- category not modelled
function S:parts(category, owner)
    local f = BY_CATEGORY[category]
    return f and f(self, owner) or nil
end

return M
