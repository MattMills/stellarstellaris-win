-- engine/exploration.lua : each country's knowledge of the galaxy, the way the game keeps it
-- (GOG 4.5.2, docs/exploration.md): the sensor coverage of its systems, the intel levels per
-- system, the known hyperlanes, unexplored space (terra incognita) and the fleets it sees.
--
--   country = { 0 = {
--       visited_objects = { 401 142 238 476 }          -- CCountry::SSafePrivate::_VisitedGalacticObjects
--       intel_level = { 0 0 3 ... }                     -- _IntelLevelCache, one per system (0 to 4)
--       highest_intel_level = { 0 0 3 ... }             -- _HighestIntelLevelCache (shared intel)
--       hyperlane_systems = { 401 238 ... }             -- _HyperlaneCache, in the order it was found
--       terra_incognita = { size = 256 data = { <runs> } systems = { <sorted> } }   -- CTerraIncognitaMap
--       sensor_range_fleets = { 0 1 2 ... }             -- _FleetsCanSeeInSensorRange, sorted
--   } }
--
-- When (CGameState::DailyUpdate 0x25cde0, the countries' parallel phase after the first
-- CModifierNodeManager::Update; the sim's `daily.countries_parallel`):
--   lambda_26 CCountry::DailyUpdateOnlyChangeSafePrivate (0x6efbf0): UpdateVisitedGalacticObjects
--     (0x6ee430), CCountrySensorManager::Update (0xad5c90), UpdateIntelCache (0x6ec200),
--     UpdateHyperlaneRange (0x6ec740)
--   lambda_27 CCountry::UpdateHighestIntelCache (0x6ed240)
--   lambda_28 CCountry::ClearTerraIncognitaInSensorRange (0x73f350), UpdateFleetsInSensorRange (0x7131b0)
-- and once at load (CGameState::RecalculateCachedData: CCountry::InitCachedValues 0x745da0 and
-- FinalizeCachedValues 0x7460f0), the same without the visited systems: exploration.load_pass,
-- run before the first day. The deposit holders the shared intel surveys or unsurveys wait for
-- CCountry::DailyUpdateSerial (`daily.countries_serial`, exploration.country_serial).
--
-- Not modelled: the intel values themselves (CIntelManager::DailyUpdate: the save's are read),
-- cloaking and detection, the bypass checks beyond the country's usable_bypasses, intel reports,
-- sensor-sharing overlord agreements and trade deals, the clearing done by fleets as they enter
-- a system (CGalacticObject::OnFleetEntered).

local world = require("engine.world")
local defs = require("engine.defs")
local bit = require("bit")
local ok_ffi, ffi = pcall(require, "ffi")

local X = {
    stats = { days = 0, load_passes = 0, countries = 0, ti_cleared = 0, ti_written = 0,
        rule_errors = 0, seconds = 0, pixel_table_seconds = 0, sections = {} },
    errors = {},
    -- for measuring what a part changes: intel_part = the intel on other countries' systems in
    -- the shared intel (UpdateHighestIntelCache's lambda_4)
    -- record_wanted = keep the planets the intel would survey (exploration.wanted[country][planet])
    options = { intel_part = true, record_wanted = false },
}

local FP = 100000
local NO_ID = 4294967295

local function fp(v)
    v = tonumber(v) or 0
    if v >= 0 then
        return math.floor(v * FP + 0.5)
    end
    return -math.floor(-v * FP + 0.5)
end
local function tdiv(a, b) -- C integer division (toward zero)
    local q = math.floor(math.abs(a) / math.abs(b))
    if (a >= 0) ~= (b >= 0) then q = -q end
    return q
end
local function fpmul(a, b) -- CFixedPoint * CFixedPoint, truncated
    return tdiv(a * b, FP)
end
local function fp_int(v) -- CFixedPoint -> int, truncated (the x / 100000 of the game's code)
    return tdiv(v, FP)
end

local function unq(v)
    return type(v) == "string" and (v:gsub('^"(.*)"$', "%1")) or v
end
local function num(v)
    v = tonumber(v)
    if v == nil or v == NO_ID then return nil end
    return v
end
local function numbers(block)
    local out = {}
    if type(block) == "table" then
        for _, e in ipairs(block) do
            if e.text then
                out[#out + 1] = tonumber(e.text)
            end
        end
    end
    return out
end

-- ---------------------------------------------------------------------------------------------
-- defines and definitions

local D
local function defines()
    if D then return D end
    local g = defs.get("common/defines", "NGameplay")
    local function d(key, default)
        local v = g and tonumber(defs.field(g.block, key))
        return v or default
    end
    D = {
        PLANET_SENSOR_RANGE = d("PLANET_SENSOR_RANGE", 1),
        PLANET_HYPERLANE_RANGE = d("PLANET_HYPERLANE_RANGE", 2),
        TI_TEXTURE_SIZE = d("TI_TEXTURE_SIZE", 256),
        TI_CORE_SCALE = fp(d("TI_CORE_SCALE", 0.9)),
    }
    return D
end

-- country type flags (common/country_types; CCountryType::_Flags, ECountryTypeFlags):
-- NeedsSurvey (bit 21), HasCompleteSensor (bit 22), IsEnclave (bit 9)
local type_cache = {}
local function ctype(c)
    local name = unq(world.field(c, "type")) or "default"
    local t = type_cache[name]
    if t == nil then
        local d = defs.get("common/country_types", name)
        local b = d and d.block
        t = {
            needs_survey = b and defs.field(b, "needs_survey") == "yes" or false,
            complete_sensor = b and defs.field(b, "has_complete_sensor") == "yes" or false,
            enclave = b and defs.field(b, "enclave") == "yes" or name == "enclave" or false,
        }
        type_cache[name] = t
    end
    return t
end

-- the component templates' sensor_range and hyperlane_range by key (common/component_templates:
-- repeated `*_component_template = { key = ... }`, values often a file's `@variable`)
local components
local function component(key)
    if components == nil then
        components = {}
        local db = require("simscript.db")
        local source = require("stellar.script.source")
        local globals = {}
        for name, d in pairs(defs.folder("common/scripted_variables") or {}) do
            globals[name] = d.value or (d.block and d.block.text)
        end
        for _, file in ipairs(source.files(db.fs, "common/component_templates", "txt")) do
            local tree = source.parse(db.fs, file)
            local vars = {}
            for _, e in ipairs(tree or {}) do
                if e.op and e.key and e.key.text:sub(1, 1) == "@" and e.value.text then
                    vars[e.key.text] = e.value.text
                end
            end
            local function value(v)
                if type(v) == "string" and v:sub(1, 1) == "@" then
                    v = vars[v] or globals[v] or globals[v:sub(2)]
                end
                return tonumber(v) or 0
            end
            for _, e in ipairs(tree or {}) do
                if e.op and e.key and e.value.text == nil then
                    local k = unq(defs.field(e.value, "key"))
                    if k then
                        components[k] = { sensor = value(defs.field(e.value, "sensor_range")),
                            hyperlane = value(defs.field(e.value, "hyperlane_range")) }
                    end
                end
            end
        end
    end
    return components[key]
end

-- the intel levels (common/intel_levels: `intel = { min max }` and the category levels) and the
-- categories (common/intel_categories: per level, the information it gives)
local INTEL
local function intel_defs()
    if INTEL then return INTEL end
    INTEL = { levels = {}, categories = {} }
    for name, d in pairs(defs.folder("common/intel_levels") or {}) do
        local range = numbers(defs.field(d.block, "intel"))
        local cat = {}
        for _, e in ipairs(d.block) do
            if e.op and e.key and e.value.text and tonumber(e.value.text) and e.key.text ~= "frame" then
                cat[e.key.text] = tonumber(e.value.text)
            end
        end
        INTEL.levels[#INTEL.levels + 1] = { name = name, min = range[1] or 0, max = range[2] or -1, cat = cat }
    end
    table.sort(INTEL.levels, function(a, b) return a.min < b.min end)
    for name, d in pairs(defs.folder("common/intel_categories") or {}) do
        local lv = {}
        for _, e in ipairs(d.block) do
            if e.op and e.key and e.key.text == "intel_level" and e.value.text == nil then
                local items = {}
                for _, x in ipairs(e.value) do
                    if x.text then items[#items + 1] = x.text end
                end
                lv[#lv + 1] = items
            end
        end
        INTEL.categories[name] = lv
    end
    return INTEL
end

-- the information an intel value and the diplomatic pacts give (CIntelData::UpdateCachedValues
-- 0x7ae850: CIntelLevel::GetAvailableInformation, the cumulative levels of each category, then
-- GetMinIntelFromDiplomaticPacts 0x7ad6a0): a set of the categories' item names
local function add_category(info, cat, level)
    local lv = intel_defs().categories[cat]
    if not lv then return end
    for i = 1, math.min(level + 1, #lv) do
        for _, item in ipairs(lv[i]) do info[item] = true end
    end
end
local function intel_info(intel, pacts)
    local info = {}
    local v = fp_int(intel)
    for _, l in ipairs(intel_defs().levels) do
        if v >= l.min and v <= l.max then
            for cat, level in pairs(l.cat) do add_category(info, cat, level) end
            break
        end
    end
    for _, cat in ipairs(pacts or {}) do add_category(info, cat, 0) end
    return info
end
X.intel_info = intel_info

-- ---------------------------------------------------------------------------------------------
-- the galaxy: systems in index order, hyperlanes (CGalacticObject::_Hyperlanes, the save's order)

local G
local function galaxy()
    if G then return G end
    G = { ids = {}, hyper = {}, coord = {}, valid = {} }
    for _, sid in ipairs(world.all("system")) do
        G.ids[#G.ids + 1] = sid
    end
    table.sort(G.ids)
    G.max = (G.ids[#G.ids] or -1) + 1   -- the galactic object database's size (the caches' size)
    for _, sid in ipairs(G.ids) do
        local s = world.object("system", sid)
        G.valid[sid] = true
        local h = {}
        for _, b in ipairs(world.blocks(world.field(s, "hyperlane"))) do
            local to = num(world.field(b, "to"))
            if to then h[#h + 1] = to end
        end
        G.hyper[sid] = h
        local c = world.field(s, "coordinate")
        G.coord[sid] = { fp(world.field(c, "x")), fp(world.field(c, "y")) }
    end
    -- the bypasses of each system (galactic_object.bypasses), and each bypass's system
    G.bypasses, G.bypass_system = {}, {}
    for _, sid in ipairs(G.ids) do
        local list = {}
        for _, b in ipairs(world.list(world.field(world.object("system", sid), "bypasses"))) do
            local id = num(b)
            if id then
                list[#list + 1] = id
                G.bypass_system[id] = sid
            end
        end
        G.bypasses[sid] = list
    end
    -- the nebulae (top-level `nebula = { galactic_object = <id> ... }`)
    G.nebula = {}
    for _, e in ipairs(world.tree or {}) do
        if e.op and e.key and e.key.text == "nebula" and e.value.text == nil then
            for _, v in ipairs(world.fields(e.value, "galactic_object")) do
                local id = tonumber(v)
                if id then G.nebula[id] = true end
            end
        end
    end
    return G
end
X.galaxy = galaxy

-- a system's planets with a colony (CGalacticObject::_PlanetColonies), upgraded starbase
local function system_colonies(sid)
    local n = 0
    for _, v in ipairs(world.fields(world.object("system", sid), "planet")) do
        if world.planet_colony[tonumber(v)] then n = n + 1 end
    end
    return n
end
local function upgraded_starbase(sid)
    for _, sb in ipairs(world.list(world.field(world.object("system", sid), "starbases"))) do
        local b = world.object("starbase", tonumber(sb))
        if b then
            local level = unq(world.field(b, "level"))
            return level ~= nil and level ~= "starbase_level_outpost"
        end
    end
    return false
end

-- the system of a planet (its coordinate's origin)
local function planet_system(pid)
    local p = pid and world.object("planet", pid)
    return p and num(world.path(p, "coordinate", "origin"))
end
local function colony_system(cid)
    return planet_system(cid and world.colony_planet[cid])
end
local function fleet_system(f)
    return f and num(world.path(f, "movement_manager", "coordinate", "origin"))
end
-- NFleetUtil::GetNearestSystem (0xe616d0): a fleet's system; in an FTL jump (move_galaxy) the end
-- of the jump nearer to the fleet's coordinate (the `to` on a tie)
local function nearest_system(f)
    local sid = fleet_system(f)
    if sid then return sid end
    local mm = f and world.field(f, "movement_manager")
    local jump = type(mm) == "table" and world.field(mm, "last_ftl_jump")
    if type(jump) ~= "table" or world.field(mm, "state") ~= "move_galaxy" then return nil end
    local from = num(world.path(jump, "from", "origin"))
    local to = num(world.field(jump, "to"))
    local g = galaxy()
    local c = world.field(mm, "coordinate")
    local x, y = fp(world.field(c, "x")), fp(world.field(c, "y"))
    local function d2(s)
        local p = s and g.coord[s]
        if not p then return nil end
        return (p[1] - x) * (p[1] - x) + (p[2] - y) * (p[2] - y)
    end
    local a, b = d2(from), d2(to)
    if a and b then return a < b and from or to end
    return to or from
end

-- ---------------------------------------------------------------------------------------------
-- the terra incognita pixel table (CTerraIncognitaMap::CreatePixelSystemOwnershipTable 0x995150,
-- TransformCoordinateToPixel 0x994f40): every pixel of the TI_TEXTURE_SIZE square belongs to the
-- system nearest in pixels (|dx| + |dy|, the first by index on a tie), except the galactic core's
-- circle (owner -1); each system's box of pixels

local PIX
local function pixel_table()
    if PIX then return PIX end
    local t0 = RUST.clock()
    local g, d = galaxy(), defines()
    local size = d.TI_TEXTURE_SIZE
    -- scale = TI_TEXTURE_SIZE / ceil(500 - (-500)): the galaxy's 1000 units on the texture
    local scale = tdiv(size * FP * FP, 1000 * FP)
    local half = tdiv(size, 2) * FP
    local function topix(x, y)
        return fp_int(fpmul(x, scale) + half), fp_int(fpmul(y, scale) + half)
    end
    local n = #g.ids
    local px, py = {}, {}
    for i, sid in ipairs(g.ids) do
        px[i], py[i] = topix(g.coord[sid][1], g.coord[sid][2])
    end
    local cx, cy = topix(0, 0)
    local galaxy_setup = world.meta.galaxy
    local core_radius = fp(type(galaxy_setup) == "table" and world.field(galaxy_setup, "core_radius") or 0)
    local r = fp_int(fpmul(fpmul(core_radius, scale), d.TI_CORE_SCALE))
    local r2 = r * r
    local own = ok_ffi and ffi.new("int32_t[?]", size * size) or {}
    local boxes = {}
    for i = 1, n do boxes[i] = { size - 1, size - 1, 0, 0 } end
    local core, core_set = {}, {}
    for x = 0, size - 1 do
        for y = 0, size - 1 do
            local best, bi = 2147483647, -1
            for i = 1, n do
                local dd = math.abs(py[i] - y) + math.abs(px[i] - x)
                if dd < best then best, bi = dd, i end
            end
            local p = y * size + x
            if bi > 0 then
                if (cx - x) * (cx - x) + (cy - y) * (cy - y) < r2 then
                    own[p] = -1
                    local sid = g.ids[bi]
                    if not core_set[sid] then core_set[sid] = true core[#core + 1] = sid end
                else
                    own[p] = g.ids[bi]
                    local b = boxes[bi]
                    if x < b[1] then b[1] = x end
                    if y < b[2] then b[2] = y end
                    if x > b[3] then b[3] = x end
                    if y > b[4] then b[4] = y end
                end
            else
                own[p] = -1
            end
        end
    end
    local box_of = {}
    for i, sid in ipairs(g.ids) do box_of[sid] = boxes[i] end
    PIX = { size = size, own = own, box = box_of, core = core, core_box = { cx - r, cy - r, 2 * r, 2 * r } }
    X.stats.pixel_table_seconds = RUST.clock() - t0
    return PIX
end
X.pixel_table = pixel_table

-- ---------------------------------------------------------------------------------------------
-- the save's fields: lists of numbers in a country's block, edited in place

local function entry(obj, key)
    for _, e in ipairs(obj) do
        if e.op and e.key and e.key.text == key then return e end
    end
    return nil
end
-- the list `key = { a b c }` set to values (written as the game writes it: an empty list is left out)
local function set_list(obj, key, values)
    local e = entry(obj, key)
    if #values == 0 then
        if e then world.remove_entry(obj, e) end
        return
    end
    local block
    if e and e.value.text == nil then
        block = e.value
        for i = #block, 1, -1 do block[i] = nil end
    else
        if e then world.remove_entry(obj, e) end
        block = {}
        world.append(obj, key, block)
    end
    for i, v in ipairs(values) do block[i] = { text = tostring(v) } end
end
local function copy(t)
    local out = {}
    for i = 1, #t do out[i] = t[i] end
    return out
end
local function same_list(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do if a[i] ~= b[i] then return false end end
    return true
end

-- ---------------------------------------------------------------------------------------------
-- a country's relations (relations_manager.relation = { owner country communications = yes ... })

local REL
local function relations()
    if REL then return REL end
    REL = {}
    for _, cid in ipairs(world.all("country")) do
        local c = world.object("country", cid)
        local t = {}
        for _, r in ipairs(world.fields(world.field(c, "relations_manager"), "relation")) do
            if type(r) == "table" then
                local other = num(world.field(r, "country"))
                if other then t[other] = r end
            end
        end
        REL[cid] = t
    end
    return REL
end
local function rel_flag(a, b, key)
    local r = relations()[a]
    r = r and r[b]
    return r ~= nil and world.field(r, key) == "yes"
end

-- ---------------------------------------------------------------------------------------------
-- the game rules through the script layer (cached for the day: they read the system's own state)

local rule_day = {}
local function rule(name, kind, id, root)
    local key = name .. "|" .. kind .. "|" .. id .. "|" .. tostring(root)
    local v = rule_day[key]
    if v ~= nil then return v end
    local d = defs.get("common/game_rules", name)
    if not d then
        v = false
    else
        local eval = require("simscript.eval")
        local ctx = eval.new_ctx(eval.S(kind, id), nil, nil, d.file)
        if root then ctx.root = eval.S("country", root) end
        local ok, holds = pcall(eval.trigger, d.block, ctx)
        if not ok then
            X.stats.rule_errors = X.stats.rule_errors + 1
            X.errors[name] = tostring(holds)
            holds = false
        end
        v = holds and true or false
    end
    rule_day[key] = v
    return v
end

local DAY = {}   -- what a pass computes once for every country (reset by each pass)
local function forced_systems()
    if DAY.forced == nil then
        DAY.forced = {}
        for _, sid in ipairs(galaxy().ids) do
            -- CGameRules::CanForceSeeFleetsInSystem (can_force_see_fleets_in_system: a solar storm)
            if rule("can_force_see_fleets_in_system", "system", sid) then DAY.forced[sid] = true end
        end
    end
    return DAY.forced
end
-- the systems each country owns (world.system_owner: by starbase), in index order
local function owned_systems(cid)
    if DAY.owned == nil then
        DAY.owned = {}
        for _, sid in ipairs(galaxy().ids) do
            local o = world.system_owner[sid]
            if o then
                local l = DAY.owned[o]
                if not l then l = {} DAY.owned[o] = l end
                l[#l + 1] = sid
            end
        end
    end
    return DAY.owned[cid] or {}
end

-- ---------------------------------------------------------------------------------------------
-- ships: sensor and hyperlane range (NShipUtil::CalcSensorRange 0xa14760, CShip::RecalcAllCachedValues:
-- the design's stat + trunc(ship_sensor_range_add); the hyperlane range the same with
-- ship_hyperlane_range_add, UpdateHyperlaneRange 0x6ecd1e)

local design_cache = {}
local function design_stats(ship)
    local impl = world.field(ship, "ship_design_implementation")
    local did = type(impl) == "table" and num(world.field(impl, "design"))
    local stage = type(impl) == "table" and tonumber(world.field(impl, "growth_stage")) or 0
    if not did then return 0, 0 end
    local key = did .. ":" .. stage
    local st = design_cache[key]
    if st then return st[1], st[2] end
    local design = world.object("ship_design", did)
    local gs = design and world.blocks(world.field(design, "growth_stages"))[stage + 1]
    local sensor, hyper = 0, 0
    local function add(template)
        -- CBaseDesignImplementation::AddComponentSpecialValues (0xcd31a0): the best component's
        local c = component(unq(template))
        if c then
            if c.sensor > sensor then sensor = c.sensor end
            if c.hyperlane > hyper then hyper = c.hyperlane end
        end
    end
    if gs then
        for _, e in ipairs(gs) do
            if e.op and e.key then
                if e.key.text == "required_component" then
                    add(e.value.text)
                elseif e.key.text == "section" and e.value.text == nil then
                    for _, comp in ipairs(world.fields(e.value, "component")) do
                        if type(comp) == "table" then add(world.field(comp, "template")) end
                    end
                end
            end
        end
    end
    design_cache[key] = { sensor, hyper }
    return sensor, hyper
end

local function modifiers(kind, id)
    local eco = package.loaded["engine.economy"]
    local m = eco and eco.has_modifier_source and eco.has_modifier_source() and eco.modifiers(kind, id)
    return m or {}
end
local function mod_int(m, key)
    return fp_int(fp(m[key] or 0))
end

local function ship_alive(s)
    return s ~= nil and (tonumber(world.field(s, "hitpoints")) or 1) > 0
end
local function ship_ranges(sid)
    DAY.ships = DAY.ships or {}
    local v = DAY.ships[sid]
    if v == nil then
        local s = world.object("ship", sid)
        if not ship_alive(s) then
            v = false
        else
            local sensor, hyper = design_stats(s)
            local m = modifiers("ship", sid)
            v = { sensor + mod_int(m, "ship_sensor_range_add"), hyper + mod_int(m, "ship_hyperlane_range_add") }
        end
        DAY.ships[sid] = v
    end
    if not v then return nil end
    return v[1], v[2]
end
X.ship_ranges = ship_ranges
X.design_stats = design_stats

-- a fleet's flags (properties = { mia = yes cloaked = yes ... }, TFleetFlags)
local function fleet_prop(f, key)
    return world.field(world.field(f, "properties"), key) == "yes"
end
-- MIA (EFleetFlags bit 5; `mia_type` stays in the save after the fleet is back)
local function fleet_mia(f)
    return fleet_prop(f, "mia")
end

local function owned_fleets(c)
    local out = {}
    for _, e in ipairs(world.blocks(world.path(c, "fleets_manager", "owned_fleets"))) do
        local fid = num(world.field(e, "fleet"))
        if fid then out[#out + 1] = fid end
    end
    return out
end

-- ---------------------------------------------------------------------------------------------
-- the priority queue of the range expansion (CPriorityQueue over CPdxPreAllocatedArray<SPrioPair>,
-- 0x760650): ascending by priority, ties in insertion order; popped from the end. Built from a
-- range per system (the systems with a range >= 0, in index order, then a stable sort); a
-- system already queued with a lower priority is taken out and put back at its new place
-- (upper bound), one finished is never queued again (NSensorRange::ExpandRange 0xad7920, 0x760850)

local function pq_new(range)
    local g = galaxy()
    local q, pos = {}, {}
    for _, sid in ipairs(g.ids) do
        local r = range[sid]
        if r and r > -1 then q[#q + 1] = { sid, r, #q } end
    end
    table.sort(q, function(a, b)
        if a[2] ~= b[2] then return a[2] < b[2] end
        return a[3] < b[3]
    end)
    for i, e in ipairs(q) do pos[e[1]] = i end
    return { q = q, pos = pos }
end
local function pq_push(pq, sid, prio)
    local q, pos = pq.q, pq.pos
    local old = pos[sid]
    if old == -2 then return end
    if old then
        if q[old][2] >= prio then return end
        table.remove(q, old)
    end
    -- upper bound: after every element with a priority <= prio
    local lo, hi = 1, #q + 1
    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        if prio >= q[mid][2] then lo = mid + 1 else hi = mid end
    end
    table.insert(q, lo, { sid, prio })
    local from = old and math.min(old, lo) or lo
    for i = from, #q do pos[q[i][1]] = i end
end
local function pq_pop(pq)
    local q = pq.q
    local e = q[#q]
    q[#q] = nil
    pq.pos[e[1]] = -2
    return e[1], e[2]
end

-- ---------------------------------------------------------------------------------------------
-- the sensor coverage (CCountrySensorManager::Update 0xad5c90 and AccountSystemsInRange 0xad60e0):
-- per system, bit 1 known, 2 in sensor range, 4 in the range of a cloaked fleet, 8 surveyed

local INTEL_OF_FLAGS = { [0] = 0, 1, 3, 3, 3, 3, 3, 3, 2, 2, 4, 4, 3, 3, 3, 3 } -- 0x1423860d0

-- CGameRules::IsSystemBlockingSensorsWithScope (common/game_rules system_blocks_sensors, root =
-- the country): vanilla's rule reads only the system (nebulae, storms, star flags), so it is
-- evaluated once a day per system
local function blocks_sensors(sid, cid)
    return rule("system_blocks_sensors", "system", sid)
end

-- the systems a system's bypasses extend the range to (ExpandRange 0xad7df0, 0x760bb8): a bypass of
-- a type that extends_sensors, active, that the country has seen when the type requires exploration
-- and the country needs surveys; then CBypassType::HasPrereqs, CBypass::NeedsExploration,
-- CanPotentiallyBeUsedByCountry, CanBeUsedByCountry and CanPassThroughLock, here the country's
-- usable_bypasses (CCountry::UpdateAvailableBypasses' result) [I]; its active connections' systems
local bypass_type_cache = {}
local function bypass_type(name)
    local t = bypass_type_cache[name]
    if t == nil then
        local d = defs.get("common/bypass", name)
        t = { extends = d and defs.field(d.block, "extends_sensors") == "yes" or false,
            exploration = d and defs.field(d.block, "requires_exploration") == "yes" or false }
        bypass_type_cache[name] = t
    end
    return t
end
local function bypass_targets(cid, c, sid, usable)
    local g = galaxy()
    local out
    for _, bid in ipairs(g.bypasses[sid] or {}) do
        local b = world.object("bypasses", bid)
        local tname = b and unq(world.field(b, "type"))
        local t = tname and bypass_type(tname)
        if t and t.extends and world.field(b, "active") == "yes" and usable[bid] then
            local seen = true
            if t.exploration and ctype(c).needs_survey then
                seen = false
                for _, v in ipairs(world.list(world.field(c, "seen_bypass_types"))) do
                    if unq(v) == tname then seen = true end
                end
            end
            if seen then
                local links = numbers(world.field(b, "connections"))
                local linked = num(world.field(b, "linked_to"))
                if linked then links[#links + 1] = linked end
                for _, l in ipairs(links) do
                    local ts = g.bypass_system[l]
                    if ts then
                        out = out or {}
                        out[#out + 1] = ts
                    end
                end
            end
        end
    end
    return out
end
local function usable_bypasses(c)
    local set = {}
    for _, v in ipairs(numbers(world.field(c, "usable_bypasses"))) do set[v] = true end
    return set
end

-- NSensorRange::ExpandRange: each system popped gets the bit; one with range > 1 lends range - 1
-- to its hyperlane neighbours, unless it blocks sensors (a neighbour that blocks is not entered)
-- (the systems reached do not depend on the order the queue pops them in: each is popped once, with
-- the best range any source lends it, so the expansion runs here by buckets of range, highest first)
local function expand_sensor(range, flags, bitv, cid, c, usable)
    local g = galaxy()
    local best, bucket, top = {}, {}, -1
    for sid, r in pairs(range) do
        if r > -1 then
            best[sid] = r
            local b = bucket[r]
            if not b then b = {} bucket[r] = b end
            b[#b + 1] = sid
            if r > top then top = r end
        end
    end
    local done = {}
    for r = top, 0, -1 do
        local b = bucket[r]
        local i = 1
        while b and i <= #b do
            local sid = b[i]
            i = i + 1
            if not done[sid] and best[sid] == r then
                done[sid] = true
                flags[sid] = bit.bor(flags[sid] or 0, bitv)
                if r > 1 and not blocks_sensors(sid, cid) then
                    local function lend(n)
                        if g.valid[n] and not done[n] and (best[n] or -1) < r - 1 and not blocks_sensors(n, cid) then
                            best[n] = r - 1
                            local nb = bucket[r - 1]
                            if not nb then nb = {} bucket[r - 1] = nb end
                            nb[#nb + 1] = n
                        end
                    end
                    for _, n in ipairs(g.hyper[sid] or {}) do lend(n) end
                    for _, n in ipairs(bypass_targets(cid, c, sid, usable) or {}) do lend(n) end
                end
            end
        end
    end
end

local function maxr(t, sid, r)
    if sid and (t[sid] == nil or t[sid] < r) then t[sid] = r end
end

local function capital_system(o)
    -- the country's custom capital location (location = { type id }) or its capital colony's system
    local loc = world.field(o, "location")
    if type(loc) == "table" then
        local t, id = tonumber(world.field(loc, "type")), num(world.field(loc, "id"))
        if id then
            if t == 2 then return planet_system(id) end
            if t == 3 then return fleet_system(world.object("fleet", id)) end
            if t == 4 then return id end
        end
    end
    return colony_system(num(world.field(o, "capital")))
end

-- the intel data of a country: { { country = id, intel = fixed } } (intel_manager.intel)
local function intel_items(c)
    local out = {}
    for _, item in ipairs(world.blocks(world.path(c, "intel_manager", "intel"))) do
        -- `{ 6 { intel = 0 ... } }`, which the reader takes as `6 = { ... }`
        local id, data
        for _, e in ipairs(item) do
            if e.op and e.key and tonumber(e.key.text) and e.value.text == nil then
                id, data = tonumber(e.key.text), e.value
            elseif e.text then id = tonumber(e.text)
            elseif not e.op then data = e end
        end
        if id and data then
            out[#out + 1] = { country = id, intel = fp(world.field(data, "intel")) }
        end
    end
    return out
end

-- the diplomatic pacts' intel categories between two countries (GetMinIntelFromDiplomaticPacts:
-- the pacts readable from the save's relations; federations by their type)
local PACTS = {
    communications = "communications", closed_borders = "closed_borders",
    commercial_pact = "commercial_pact", migration_access = "migration_treaty",
    research_agreement = "research_agreement", embassy = "embassy", defensive_pact = "defensive_pact",
    guarantee = "guarantee_independence", non_aggression_pact = "non_aggression_pact",
}
local function pacts_between(a, b)
    local out = {}
    for key, cat in pairs(PACTS) do
        if rel_flag(a, b, key) or rel_flag(b, a, key) then out[#out + 1] = cat end
    end
    local fa = num(world.field(world.object("country", a), "federation"))
    local fb = num(world.field(world.object("country", b), "federation"))
    if fa and fa == fb then
        local f = world.object("federation", fa)
        local ft = f and unq(world.path(f, "federation_progression", "federation_type"))
        if ft then out[#out + 1] = ft end
    end
    table.sort(out)
    return out
end

-- the information cid has on another country (its intel item), once a pass
local function info_of(cid, it)
    DAY.info = DAY.info or {}
    local key = cid .. ":" .. it.country
    local v = DAY.info[key]
    if v == nil then
        v = intel_info(it.intel, pacts_between(cid, it.country))
        DAY.info[key] = v
    end
    return v
end

local function sensor_flags(cid, c, visited)
    local g, d = galaxy(), defines()
    local t = ctype(c)
    local flags = {}
    if t.needs_survey then
        for _, sid in ipairs(visited) do
            if g.valid[sid] then flags[sid] = 1 end
        end
    else
        for _, sid in ipairs(g.ids) do flags[sid] = 1 end
    end
    -- CGameRules::HasFullSensorRange (has_full_sensor_range: the spy orb)
    if rule("has_full_sensor_range", "country", cid) then
        for _, sid in ipairs(g.ids) do flags[sid] = bit.bor(flags[sid] or 0, 2) end
        return flags
    end
    local range1, range2 = {}, {}
    local function colony(col)
        local sid = colony_system(col)
        if not sid or not g.valid[sid] then return end
        flags[sid] = bit.bor(flags[sid] or 0, 3)
        maxr(range1, sid, d.PLANET_SENSOR_RANGE + mod_int(modifiers("colony", col), "planet_sensor_range_add"))
    end
    -- AccountOwnedColonies, AccountHoldingsColonies, AccountControlledColonies
    for _, col in ipairs(numbers(world.field(c, "owned_planets"))) do colony(col) end
    for _, col in ipairs(numbers(world.field(c, "controlled_colonies"))) do colony(col) end
    -- AccountFleets: the owned fleets not MIA, at their system: the fleet's range (its ships' best)
    for _, fid in ipairs(owned_fleets(c)) do
        local f = world.object("fleet", fid)
        local sid = fleet_system(f)
        if f and not fleet_mia(f) and sid and g.valid[sid] then
            local cloaked = fleet_prop(f, "cloaked")
            flags[sid] = bit.bor(flags[sid] or 0, cloaked and 5 or 3)
            local r = 0
            for _, ship in ipairs(numbers(world.field(f, "ships"))) do
                local s = ship_ranges(ship)
                if s and s > r then r = s end
            end
            maxr(cloaked and range2 or range1, sid, r)
        end
    end
    -- the armies on a planet: range 1
    for _, aid in ipairs(numbers(world.field(c, "owned_armies"))) do
        local a = world.object("army", aid)
        local pl = a and num(world.field(a, "planet"))
        if pl and (tonumber(world.field(a, "health")) or 0) > 0 then
            local sid = planet_system(pl) or colony_system(pl)
            if sid and g.valid[sid] then
                flags[sid] = bit.bor(flags[sid] or 0, 3)
                maxr(range1, sid, 1)
            end
        end
    end
    -- the megastructures: the type's sensor range
    for _, mid in ipairs(numbers(world.field(c, "owned_megastructures"))) do
        local m = world.object("megastructure", mid)
        local sid = m and num(world.path(m, "coordinate", "origin"))
        if sid and g.valid[sid] and world.field(m, "disabled") ~= "yes" then
            flags[sid] = bit.bor(flags[sid] or 0, 3)
            local md = defs.get("common/megastructures", unq(world.field(m, "type")))
            maxr(range1, sid, md and tonumber(defs.field(md.block, "sensor_range")) or 0)
        end
    end
    -- AccountEnclaves: the enclaves we have communications with: their capital's system is known
    for other in pairs(relations()[cid] or {}) do
        local o = world.object("country", other)
        if o and rel_flag(cid, other, "communications") and ctype(o).enclave then
            local sid = capital_system(o)
            if sid and g.valid[sid] then flags[sid] = bit.bor(flags[sid] or 0, 1) end
        end
    end
    -- AccountIntel: the capitals our intel shows (CapitalLocation)
    for _, it in ipairs(intel_items(c)) do
        local o = world.object("country", it.country)
        if o and world.field(o, "is_nomadic") ~= "yes" then
            local info = info_of(cid, it)
            if info.capital_location then
                local sid = capital_system(o)
                if sid and g.valid[sid] then flags[sid] = bit.bor(flags[sid] or 0, 1) end
            end
        end
    end
    -- AccountSurveyedSystems: the owned systems and the fully surveyed ones (every planet and
    -- astral rift surveyed); every system for a country that needs no survey
    if t.needs_survey then
        for _, sid in ipairs(owned_systems(cid)) do
            flags[sid] = bit.bor(flags[sid] or 0, 8)
        end
        local count = {}
        for _, h in ipairs(world.blocks(world.field(c, "surveyed_deposit_holders"))) do
            local id = num(world.field(h, "id"))
            local sid = id and planet_system(id)
            if sid then count[sid] = (count[sid] or 0) + 1 end
        end
        for sid, n in pairs(count) do
            local s = world.object("system", sid)
            local need = #world.fields(s, "planet") + #world.list(world.field(s, "astral_rifts"))
            if n >= need then flags[sid] = bit.bor(flags[sid] or 0, 8) end
        end
    else
        for _, sid in ipairs(g.ids) do flags[sid] = bit.bor(flags[sid] or 0, 8) end
    end
    local usable = usable_bypasses(c)
    expand_sensor(range1, flags, 2, cid, c, usable)
    expand_sensor(range2, flags, 4, cid, c, usable)
    return flags
end
X.sensor_flags = sensor_flags

-- CCountry::UpdateIntelCache: TABLE[flags & 0xCF] per system (index order)
local function intel_levels(flags)
    local g = galaxy()
    local out = {}
    for i, sid in ipairs(g.ids) do
        out[i] = INTEL_OF_FLAGS[bit.band(flags[sid] or 0, 0xCF)] or 0
    end
    return out
end

-- ---------------------------------------------------------------------------------------------
-- CCountry::UpdateHyperlaneRange: the hyperlanes known, in the order the expansion finds them

local function hyperlane_range(cid, c, previous)
    local g, d = galaxy(), defines()
    if rule("has_full_sensor_range", "country", cid) then
        return copy(g.ids)
    end
    local range = {}
    for _, sid in ipairs(previous) do
        if g.valid[sid] then maxr(range, sid, 1) end
    end
    local function colony(col)
        local sid = colony_system(col)
        if sid and g.valid[sid] then
            maxr(range, sid, d.PLANET_HYPERLANE_RANGE + mod_int(modifiers("colony", col), "planet_hyperlane_range_add"))
        end
    end
    for _, col in ipairs(numbers(world.field(c, "owned_planets"))) do colony(col) end
    for _, col in ipairs(numbers(world.field(c, "controlled_colonies"))) do colony(col) end
    for _, fid in ipairs(owned_fleets(c)) do
        local f = world.object("fleet", fid)
        local sid = fleet_system(f)
        if f and not fleet_mia(f) and sid and g.valid[sid] then
            local r = 0
            for _, ship in ipairs(numbers(world.field(f, "ships"))) do
                local _, h = ship_ranges(ship)
                if h and h > r then r = h end
            end
            maxr(range, sid, r)
        end
    end
    for _, aid in ipairs(numbers(world.field(c, "owned_armies"))) do
        local a = world.object("army", aid)
        local pl = a and num(world.field(a, "planet"))
        if pl and (tonumber(world.field(a, "health")) or 0) > 0 then
            maxr(range, planet_system(pl) or colony_system(pl), 1)
        end
    end
    for _, mid in ipairs(numbers(world.field(c, "owned_megastructures"))) do
        local m = world.object("megastructure", mid)
        local sid = m and num(world.path(m, "coordinate", "origin"))
        if sid and g.valid[sid] and world.field(m, "disabled") ~= "yes" then
            local md = defs.get("common/megastructures", unq(world.field(m, "type")))
            maxr(range, sid, md and tonumber(defs.field(md.block, "hyperlane_range")) or 0)
        end
    end
    local out = {}
    local usable = usable_bypasses(c)
    local pq = pq_new(range)
    while #pq.q > 0 do
        local sid, r = pq_pop(pq)
        out[#out + 1] = sid
        if r > 1 then
            for _, n in ipairs(g.hyper[sid] or {}) do
                if g.valid[n] then pq_push(pq, n, r - 1) end
            end
            for _, n in ipairs(bypass_targets(cid, c, sid, usable) or {}) do
                if g.valid[n] then pq_push(pq, n, r - 1) end
            end
        end
    end
    return out
end

-- ---------------------------------------------------------------------------------------------
-- CCountry::ListCountriesGivingSensor (0x713ab0): the federation's members (or the country) and
-- their subjects not at war with them, then the overlord's (not modelled: no agreements), the
-- sensor links of trade deals (not modelled), the war allies (not modelled)

local function subjects(c)
    return numbers(world.field(c, "subjects"))
end
local function givers(cid, c)
    local out, seen = {}, {}
    local function add(id)
        if not seen[id] and world.object("country", id) then
            seen[id] = true
            out[#out + 1] = id
        end
    end
    local function country_and_subjects(id)
        add(id)
        for _, s in ipairs(subjects(world.object("country", id))) do add(s) end
    end
    local fid = num(world.field(c, "federation"))
    local f = fid and world.object("federation", fid)
    if f then
        for _, m in ipairs(numbers(world.field(f, "members"))) do country_and_subjects(m) end
    else
        country_and_subjects(cid)
    end
    return out
end

-- CCountry::UpdateHighestIntelCache: the intel the country's information on others gives about
-- their systems (lambda_4: the system category's level, 2 on an upgraded starbase with
-- MilitaryStarbases, the colonies' level on a system with colonies), then the best intel level
-- of every country giving it sensor. A country with complete sensor (or the cheat) empties the
-- cache when it has one, and computes it when it is empty: it alternates day by day.
local SYSTEM_LEVEL = { intel_economy_systems_low = 1, intel_economy_systems_med = 2,
    intel_economy_systems_high = 3, intel_economy_systems_full = 4 }
local COLONY_LEVEL = { intel_economy_colonies_low = 1, intel_economy_colonies_med = 2,
    intel_economy_colonies_high = 3, intel_economy_colonies_full = 4 }

-- a planet's owner and controller (the save's `controller`, else its owner)
local function planet_owner(p)
    return p and num(world.field(p, "owner"))
end
local function planet_controller(p)
    return p and (num(world.field(p, "controller")) or num(world.field(p, "owner")))
end

-- the deposit holders the intel on a country surveys or unsurveys (lambda_4's planets and the
-- controlled colonies' loop of UpdateHighestIntelCache, into SSafePrivate::_NewSurveyed and
-- _NewUnsurveyed): a colonized planet when the colonies' level is High or Full, another when the
-- system level is High or Full or the intel shows the deposits (EconomyDeposits); a planet the
-- country has not surveyed then is added, one it has (or is auto-surveyed) without it is taken
-- out, unless it is occupied (owner ~= controller)
local function intel_survey(cid, pid, colony_want, other_want, ns)
    if not ns or not pid then return end
    local survey = package.loaded["engine.fleets.survey"] or select(2, pcall(require, "engine.fleets.survey"))
    if type(survey) ~= "table" or not survey.has_surveyed then return end
    local want = world.planet_colony[pid] and colony_want or other_want
    if want and X.options.record_wanted then
        local w = X.wanted or {}
        X.wanted = w
        w[cid] = w[cid] or {}
        w[cid][pid] = true
    end
    local surveyed = survey.has_surveyed(cid, 0, pid)
    if want then
        if not surveyed then ns.add[#ns.add + 1] = pid end
    elseif surveyed then
        local p = world.object("planet", pid)
        if planet_owner(p) == planet_controller(p) then ns.remove[#ns.remove + 1] = pid end
    end
end

local function highest_intel(cid, c, state, levels_of, ns)
    local g = galaxy()
    if ctype(c).complete_sensor and #state.highest > 0 then
        return {}
    end
    local h = {}
    for i = 1, g.max do h[i] = 0 end
    for _, it in ipairs(X.options.intel_part and intel_items(c) or {}) do
        local o = world.object("country", it.country)
        local props = o and tonumber(world.path(o, "faction", "properties"))
        local effects = props == nil or bit.band(props, 2048) ~= 0      -- IntelEffectsSurveyed
        if o and effects and (it.country == cid or rel_flag(it.country, cid, "communications")) then
            local info = info_of(cid, it)
            local la, lc = 0, 0
            for k, l in pairs(SYSTEM_LEVEL) do if info[k] and l > la then la = l end end
            for k, l in pairs(COLONY_LEVEL) do if info[k] and l > lc then lc = l end end
            local lb = info.intel_military_starbases and 2 or 0
            local colony_want = lc >= 3
            local other_want = la >= 3 or info.intel_economy_deposits == true
            for _, sid in ipairs(owned_systems(it.country)) do
                local i = sid + 1
                h[i] = la
                if lb > h[i] and upgraded_starbase(sid) then h[i] = lb end
                local colonies = system_colonies(sid)
                if la >= 3 or colonies > 0 then
                    if lc > h[i] then h[i] = lc end
                end
                -- the system's planets (none for a system without colonies when nothing shows)
                if (other_want or colonies > 0) and (h[i] ~= 0 or other_want) then
                    for _, v in ipairs(world.fields(world.object("system", sid), "planet")) do
                        local pid = tonumber(v)
                        local ctrl = planet_controller(world.object("planet", pid))
                        if ctrl == nil or ctrl == it.country then
                            intel_survey(cid, pid, colony_want, other_want, ns)
                        end
                    end
                end
            end
            for _, col in ipairs(numbers(world.field(o, "controlled_colonies"))) do
                intel_survey(cid, world.colony_planet[col], colony_want, other_want, ns)
            end
        end
    end
    for _, gid in ipairs(givers(cid, c)) do
        local lv = levels_of(gid)
        if lv then
            for i = 1, math.min(#lv, #h) do
                if lv[i] > h[i] then h[i] = lv[i] end
            end
        end
    end
    return h
end

-- CCountry::GetIntelLevel (0x713ef0): 4 with complete sensor, else the highest cache; at least 2
-- for a country that needs no survey; 1 for a first contact's system
local function intel_level_at(c, state, sid)
    local t = ctype(c)
    local l = 0
    if t.complete_sensor then
        l = 4
    elseif sid and state.highest[sid + 1] then
        l = state.highest[sid + 1]
    end
    if not t.needs_survey then
        return l < 2 and 2 or l
    end
    return l
end

-- ---------------------------------------------------------------------------------------------
-- terra incognita: the save's map (runs of 0 and 255 from 0), cleared by system
-- (CTerraIncognitaMap::ClearSystem 0x994c50)

local function ti_load(state, c)
    local ti = world.field(c, "terra_incognita")
    if type(ti) ~= "table" then return nil end
    local size = tonumber(world.field(ti, "size")) or defines().TI_TEXTURE_SIZE
    local runs = numbers(world.field(ti, "data"))
    local data = ok_ffi and ffi.new("uint8_t[?]", size * size) or {}
    local p, v = 0, 0
    for _, r in ipairs(runs) do
        for i = p, math.min(p + r, size * size) - 1 do data[i] = v end
        p = p + r
        v = 255 - v
    end
    for i = p, size * size - 1 do data[i] = 0 end
    local cleared = numbers(world.field(ti, "systems"))
    local set = {}
    for _, s in ipairs(cleared) do set[s] = true end
    state.ti = { block = ti, size = size, data = data, cleared = cleared, set = set, dirty = false }
    return state.ti
end

local function ti_clear(ti, sid)
    if ti.set[sid] then return end
    local pix = pixel_table()
    local b = pix.box[sid]
    if not b then return end
    -- the sorted list of cleared systems
    local lo, hi = 1, #ti.cleared + 1
    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        if ti.cleared[mid] < sid then lo = mid + 1 else hi = mid end
    end
    table.insert(ti.cleared, lo, sid)
    ti.set[sid] = true
    ti.dirty = true
    X.stats.ti_cleared = X.stats.ti_cleared + 1
    local size, own, data = ti.size, pix.own, ti.data
    for x = b[1], b[3] do
        for y = b[2], b[4] do
            local p = y * size + x
            if own[p] == sid and data[p] == 0 then data[p] = 255 end
        end
    end
    -- the galactic core, once every core system is cleared
    if not ti.core_cleared then
        for _, cs in ipairs(pix.core) do
            if not ti.set[cs] then return end
        end
        ti.core_cleared = true
        local cb = pix.core_box
        for x = cb[1], cb[1] + cb[3] do
            for y = cb[2], cb[2] + cb[4] do
                if x >= 0 and y >= 0 and x < size and y < size then
                    local p = y * size + x
                    if own[p] == -1 and data[p] == 0 then data[p] = 255 end
                end
            end
        end
    end
end

local function ti_write(ti)
    if not ti.dirty then return end
    local runs = {}
    local v, n = 0, 0
    local total = ti.size * ti.size
    for p = 0, total - 1 do
        local x = ti.data[p]
        if x ~= v then
            runs[#runs + 1] = n
            v, n = x, 0
        end
        n = n + 1
    end
    runs[#runs + 1] = n
    set_list(ti.block, "data", runs)
    set_list(ti.block, "systems", ti.cleared)
    ti.dirty = false
    X.stats.ti_written = X.stats.ti_written + 1
end

-- ---------------------------------------------------------------------------------------------
-- CCountry::UpdateFleetsInSensorRange / CanSee (0x7141b0): the fleets the country sees, sorted

-- the fleets that can be seen at all (alive: fewer ships removed than it has; not MIA), with what
-- CanSee reads of them, once a pass
local function visible_fleets()
    if DAY.fleets then return DAY.fleets end
    local list = {}
    for _, fid in ipairs(world.all("fleet")) do
        local f = world.object("fleet", fid)
        local nships = f and #numbers(world.field(f, "ships")) or 0
        local removed = f and tonumber(world.field(f, "cached_combined_removed_ships")) or 0
        if f and removed < nships and not fleet_mia(f) then
            local owner = world.fleet_owner[fid]
            local o = owner and world.object("country", owner)
            list[#list + 1] = { id = fid, owner = owner, enclave = o and ctype(o).enclave or false,
                here = fleet_system(f), near = nearest_system(f), cloaked = fleet_prop(f, "cloaked") }
        end
    end
    DAY.fleets = list
    return list
end

local function fleets_seen(cid, c, state)
    local forced = forced_systems()
    local out = {}
    for _, v in ipairs(visible_fleets()) do
        local see = false
        if v.owner == cid then
            see = true
        elseif v.enclave and rel_flag(v.owner, cid, "communications") then
            see = true
        elseif v.here and forced[v.here] then
            see = true
        elseif intel_level_at(c, state, v.near) >= 3 then
            see = not v.cloaked   -- CFleet::CalcIsHiddenFrom: detection not modelled
        end
        if see then out[#out + 1] = v.id end
    end
    table.sort(out)
    return out
end

-- ---------------------------------------------------------------------------------------------
-- UpdateVisitedGalacticObjects (0x6ee430): appended, in this order, the systems within the
-- borders, of the owned colonies, of the controlled planets, of the owned fleets, of the armies

local function visited_update(cid, c, list)
    local g = galaxy()
    local i = 1
    while i <= #list do
        if not g.valid[list[i]] then
            list[i] = list[#list]
            list[#list] = nil
        else
            i = i + 1
        end
    end
    local seen = {}
    for _, s in ipairs(list) do seen[s] = true end
    local function add(sid)
        if sid and g.valid[sid] and not seen[sid] then
            seen[sid] = true
            list[#list + 1] = sid
        end
    end
    for _, sid in ipairs(owned_systems(cid)) do add(sid) end
    for _, col in ipairs(numbers(world.field(c, "owned_planets"))) do add(colony_system(col)) end
    for _, pid in ipairs(numbers(world.field(c, "controlled_planets"))) do add(planet_system(pid)) end
    for _, fid in ipairs(owned_fleets(c)) do add(fleet_system(world.object("fleet", fid))) end
    for _, aid in ipairs(numbers(world.field(c, "owned_armies"))) do
        local a = world.object("army", aid)
        local pl = a and num(world.field(a, "planet"))
        if pl then add(planet_system(pl) or colony_system(pl)) end
    end
    return list
end

-- ---------------------------------------------------------------------------------------------
-- the passes

local STATE = {}   -- country id -> { visited, intel, highest, hyperlanes, fleets, ti }
local function state_of(cid, c)
    local s = STATE[cid]
    if s == nil then
        s = {
            visited = numbers(world.field(c, "visited_objects")),
            intel = numbers(world.field(c, "intel_level")),
            highest = numbers(world.field(c, "highest_intel_level")),
            hyperlanes = numbers(world.field(c, "hyperlane_systems")),
            fleets = numbers(world.field(c, "sensor_range_fleets")),
        }
        STATE[cid] = s
    end
    return s
end
X.state = STATE

-- one pass over every country: with_visited for the day (DailyUpdateOnlyChangeSafePrivate), not
-- at load (InitCachedValues); then the shared intel (lambda_27); then the clearing and the fleets
-- (lambda_28). write = false keeps the world as it is (exploration.check).
local function pass(with_visited, write)
    local t0 = RUST.clock()
    rule_day = {}
    REL = nil
    DAY = {}
    local ids = world.all("country")
    local computed = {}
    local T = X.stats.sections
    local function lap(name, t)
        local now = RUST.clock()
        T[name] = (T[name] or 0) + (now - t)
        return now
    end
    local t = t0
    for _, cid in ipairs(ids) do
        local c = world.object("country", cid)
        local st = state_of(cid, c)
        local r = { st = st }
        r.visited = with_visited and visited_update(cid, c, copy(st.visited)) or st.visited
        t = lap("visited", t)
        local flags = sensor_flags(cid, c, r.visited)
        r.flags = flags
        r.intel = intel_levels(flags)
        t = lap("sensor", t)
        r.hyperlanes = hyperlane_range(cid, c, st.hyperlanes)
        t = lap("hyperlanes", t)
        computed[cid] = r
    end
    local function levels_of(gid)
        local r = computed[gid]
        return r and r.intel
    end
    for _, cid in ipairs(ids) do
        local c = world.object("country", cid)
        local r = computed[cid]
        -- the surveys the intel adds or removes wait in the state for the country's serial day
        -- (they accumulate: the game empties _NewSurveyed / _NewUnsurveyed only there)
        local ns = write and (r.st.surveys or { add = {}, remove = {} }) or nil
        r.highest = highest_intel(cid, c, r.st, levels_of, ns)
        if write then r.st.surveys = ns end
    end
    t = lap("highest", t)
    for _, cid in ipairs(ids) do
        local c = world.object("country", cid)
        local r = computed[cid]
        local st = r.st
        local view = { highest = r.highest }
        r.fleets = fleets_seen(cid, c, view)
        t = lap("fleets", t)
        if write then
            local ti = st.ti or ti_load(st, c)
            if ti then
                for i = 1, #r.highest do
                    if r.highest[i] >= 1 and not ti.set[i - 1] then ti_clear(ti, i - 1) end
                end
                ti_write(ti)
            end
            -- written when changed (the world's lists are the state's)
            if not same_list(st.visited, r.visited) then set_list(c, "visited_objects", r.visited) end
            if not same_list(st.intel, r.intel) then set_list(c, "intel_level", r.intel) end
            if not same_list(st.highest, r.highest) then set_list(c, "highest_intel_level", r.highest) end
            if not same_list(st.hyperlanes, r.hyperlanes) then set_list(c, "hyperlane_systems", r.hyperlanes) end
            if not same_list(st.fleets, r.fleets) then set_list(c, "sensor_range_fleets", r.fleets) end
            st.visited, st.intel, st.highest, st.hyperlanes, st.fleets = r.visited, r.intel, r.highest, r.hyperlanes, r.fleets
            t = lap("write", t)
        end
    end
    X.stats.countries = #ids
    X.stats.seconds = X.stats.seconds + (RUST.clock() - t0)
    return computed
end

-- the load's own pass (CGameState::RecalculateCachedData), once before the first day
function X.load_pass()
    if X.loaded then return end
    X.loaded = true
    pass(false, true)
    X.stats.load_passes = X.stats.load_passes + 1
end

-- the day (systems.lua `daily.countries_parallel`); STELLAR_EXPLORATION=off leaves the save's
-- fields as they are (to measure what the module changes)
local OFF = os.getenv("STELLAR_EXPLORATION") == "off"
-- STELLAR_STORE=ffi: the pass over the shared store, on the worker pool (engine.store.bridge,
-- docs/data_layer.md); the surveys it finds come back into STATE for country_serial
local STORE = os.getenv("STELLAR_STORE") == "ffi"
function X.countries_daily(host, date)
    if OFF then return end
    if STORE then
        require("engine.store.bridge").countries_daily(host, date)
        X.stats.days = X.stats.days + 1
        return
    end
    X.load_pass()
    pass(true, true)
    X.stats.days = X.stats.days + 1
end

-- CCountry::DailyUpdateSerial, after UpdateContacts / UpdateVisited / UpdatePoliciesSerial and
-- before the country's events (systems.lua `daily.countries_serial`): every deposit holder of
-- _NewSurveyed through CCountry::AddSurveyedDepositHolder (0x71b0d0: the sorted insert, three
-- draws, on_planet_surveyed; engine.fleets.survey's), then every one of _NewUnsurveyed through
-- RemoveSurveyedDepositHolder (0x71bb60: taken out of the sorted list, nothing else); both emptied
local function remove_surveyed(cid, ty, id)
    local c = world.object("country", cid)
    local b = c and world.field(c, "surveyed_deposit_holders")
    if type(b) ~= "table" then return false end
    for i, e in ipairs(b) do
        if not e.text and not e.op and (tonumber(world.field(e, "type")) or 0) == ty
            and tonumber(world.field(e, "id")) == id then
            table.remove(b, i)
            X.stats.unsurveyed = (X.stats.unsurveyed or 0) + 1
            return true
        end
    end
    return false
end
function X.country_serial(host, date, cid)
    if OFF then return end
    local st = STATE[cid]
    local ns = st and st.surveys
    if not ns or (#ns.add == 0 and #ns.remove == 0) then return end
    st.surveys = nil
    local survey = package.loaded["engine.fleets.survey"] or select(2, pcall(require, "engine.fleets.survey"))
    for _, pid in ipairs(ns.add) do
        if type(survey) == "table" and survey.add_surveyed and survey.add_surveyed(cid, 0, pid, nil, host) then
            X.stats.surveyed = (X.stats.surveyed or 0) + 1
        end
    end
    for _, pid in ipairs(ns.remove) do remove_surveyed(cid, 0, pid) end
end

-- exploration.check() -> report: every field computed from the world as the load computes it,
-- against the world's own (nothing written)
function X.check()
    local computed = pass(false, false)
    local fields = { "intel_level", "highest_intel_level", "hyperlane_systems", "sensor_range_fleets" }
    local key_of = { intel_level = "intel", highest_intel_level = "highest", hyperlane_systems = "hyperlanes",
        sensor_range_fleets = "fleets" }
    local lines = {}
    for _, f in ipairs(fields) do
        local same, diff, values, values_diff = 0, 0, 0, 0
        local bad = {}
        for _, cid in ipairs(world.all("country")) do
            local c = world.object("country", cid)
            local want = numbers(world.field(c, f))
            local got = computed[cid][key_of[f]]
            if same_list(want, got) then same = same + 1 else
                diff = diff + 1
                if #bad < 8 then bad[#bad + 1] = cid end
            end
            for i = 1, math.max(#want, #got) do
                values = values + 1
                if want[i] ~= got[i] then values_diff = values_diff + 1 end
            end
        end
        lines[#lines + 1] = string.format("%-22s countries same %d differ %d; values %d differ %d; e.g. %s",
            f, same, diff, values, values_diff, table.concat(bad, " "))
    end
    return table.concat(lines, "\n"), computed
end

function X.report()
    local s = X.stats
    local parts = {}
    for _, k in ipairs({ "visited", "sensor", "hyperlanes", "highest", "fleets", "write" }) do
        parts[#parts + 1] = string.format("%s %.1f", k, s.sections[k] or 0)
    end
    return string.format("exploration: %d days, %d load passes, %d countries, %d systems cleared from terra incognita (%d maps written), %d deposit holders surveyed and %d unsurveyed by intel, %.1f s (%s; pixel table %.2f s), %d rule errors",
        s.days, s.load_passes, s.countries, s.ti_cleared, s.ti_written, s.surveyed or 0, s.unsurveyed or 0,
        s.seconds, table.concat(parts, ", "), s.pixel_table_seconds, s.rule_errors)
end

return X
