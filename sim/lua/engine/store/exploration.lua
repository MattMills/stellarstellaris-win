-- engine/store/exploration.lua : engine/exploration.lua over the shared store, for any Lua state
-- (the main one or a worker): each country's knowledge of the galaxy (docs/exploration.md), the
-- same computation read from the store's blocks and typed arrays instead of the Lua tables.
--
-- The day's pass is the game's three lambdas, each a parallel loop over the countries with a
-- barrier after it (docs/data_layer.md, "Exploration on the workers"):
--
--   a  lambda_26 DailyUpdateOnlyChangeSafePrivate: visited systems, sensor coverage, intel levels,
--      hyperlanes; the intel levels go to a shared array (the next lambda reads other countries')
--   b  lambda_27 UpdateHighestIntelCache: the shared intel, the surveys the intel gives
--   c  lambda_28 ClearTerraIncognitaInSensorRange, UpdateFleetsInSensorRange; the country's lists
--      written (in place: a list block of the country's own; a list added to or taken out of the
--      country's block is a change of a block other workers read, so it is handed back and done
--      by the main thread after the barrier, in country order)
--
-- What the store does not hold yet comes as typed arrays the main thread fills before the pass
-- (engine.store.bridge): the game rules (script triggers), the modifier values, the world's
-- derived indexes (planet <-> colony, system and fleet owners), the component templates' ranges,
-- the terra incognita pixel table.
--
-- A country is computed by the worker that takes it in `a` (an atomic counter: dynamic balance);
-- the same worker does it in `b` and `c` (its results stay in that state).

local S = require("engine.store.core")
local A = require("engine.store.arrays")
local O = require("engine.store.objects")
local SD = require("engine.store.defs")
local bit = require("bit")
local ffi = require("ffi")

local X = {
    stats = { days = 0, load_passes = 0, countries = 0, ti_cleared = 0, ti_written = 0, seconds = 0,
        sections = {} },
    options = { intel_part = true },
}

local FP = 100000
local NO_ID = 4294967295
local TEXT, NUMBER, BLOCK = S.TEXT, S.NUMBER, S.BLOCK

local E, B
local find, find_next, token, text, num_of, sid = S.find, S.find_next, S.token, S.text, S.num_of, S.id

local function fp(v)
    v = tonumber(v) or 0
    if v >= 0 then return math.floor(v * FP + 0.5) end
    return -math.floor(-v * FP + 0.5)
end
local function tdiv(a, b)
    local q = math.floor(math.abs(a) / math.abs(b))
    if (a >= 0) ~= (b >= 0) then q = -q end
    return q
end
local function fpmul(a, b) return tdiv(a * b, FP) end
local function fp_int(v) return tdiv(v, FP) end
local function unq(v)
    return type(v) == "string" and (v:gsub('^"(.*)"$', "%1")) or v
end

-- ---------------------------------------------------------------------------------------------
-- reads (b a block id or nil; k a key id). As engine.world.field: the first entry of the key.

local K = setmetatable({}, { __index = function(t, s)
    local id = sid(s)
    t[s] = id
    return id
end })

-- the token value (number when it reads as one, else the text); nil for a block or no entry
local function val(b, k)
    if not b then return nil end
    local i = find(b, k)
    if not i then return nil end
    return token(i)
end
-- tonumber(world.field(b, key))
local function fnum(b, k)
    if not b then return nil end
    local i = find(b, k)
    if not i then return nil end
    local e = E[i]
    local kind = e.kind
    if kind == NUMBER then return e.v.num end
    if kind == TEXT then return num_of(e.v.u.a) or nil end
    return nil
end
-- exploration's num(): tonumber, none for NO_ID
local function fid(b, k)
    local v = fnum(b, k)
    if v == nil or v == NO_ID then return nil end
    return v
end
-- the text of a token (world.field(b, key) == "yes" and such)
local function ftext(b, k)
    if not b then return nil end
    local i = find(b, k)
    if not i then return nil end
    return text(i)
end
local function yes(b, k)
    return ftext(b, k) == "yes"
end
-- the block of a block entry
local function fblk(b, k)
    if not b then return nil end
    local i = find(b, k)
    if not i then return nil end
    local e = E[i]
    if e.kind == BLOCK then return e.v.u.a end
    return nil
end
-- the bare numbers of a list block (exploration's numbers())
local numbers = S.numbers
-- the bare blocks of a list block
local function blocks(b)
    local out, n = {}, 0
    if not b then return out end
    local r = B[b]
    for i = r.first, r.first + r.count - 1 do
        local e = E[i]
        if e.op == 0 and e.kind == BLOCK then n = n + 1; out[n] = e.v.u.a end
    end
    return out
end
-- the texts of a list block's bare values
local function list(b)
    local out, n = {}, 0
    if not b then return out end
    local r = B[b]
    for i = r.first, r.first + r.count - 1 do
        local e = E[i]
        if e.op == 0 and (e.kind == TEXT or e.kind == NUMBER) then n = n + 1; out[n] = text(i) end
    end
    return out
end
-- every value of a key, as world.fields: texts (tokens) and block ids (as { block = id })
local function each_value(b, k, f)
    if not b then return end
    local i = find(b, k)
    while i do
        local e = E[i]
        if e.kind == BLOCK then f(nil, e.v.u.a) else f(text(i), nil) end
        i = find_next(b, k, i)
    end
end
local function count_key(b, k)
    local n = 0
    each_value(b, k, function() n = n + 1 end)
    return n
end

local function obj(name, id)
    return id and O.get(name, id)
end
local function country(id) return obj("country", id) end

-- ---------------------------------------------------------------------------------------------
-- the inputs the main thread prepares (engine.store.bridge): typed arrays, looked up each pass

local IN = {}
local function inputs()
    IN.sys_flags = A.map("x_sys_flags")
    IN.country_flags = A.map("x_country_flags")
    IN.ship_sensor, IN.ship_hyper = A.map("x_ship_sensor"), A.map("x_ship_hyper")
    IN.colony_sensor, IN.colony_hyper = A.map("x_colony_sensor"), A.map("x_colony_hyper")
    IN.planet_colony = A.map("x_planet_colony")
    IN.colony_planet = A.map("x_colony_planet")
    IN.system_owner = A.map("x_system_owner")
    IN.fleet_owner = A.map("x_fleet_owner")
    local _, tp, tslot = A.map("x_ti_off")
    IN.ti_p, IN.ti_slot = tp, tslot
    IN.intel = A.ptr("x_intel", "uint8_t")
end
local function planet_colony(pid) return IN.planet_colony(pid) end
local function colony_planet(cid) return IN.colony_planet(cid) end
local function system_owner(s) return IN.system_owner(s) end
local function fleet_owner(f) return IN.fleet_owner(f) end

-- ---------------------------------------------------------------------------------------------
-- defines and definitions (the store's)

local D
local function defines()
    if D then return D end
    local g = SD.get("common/defines", "NGameplay")
    local function d(key, default)
        local v = g and fnum(g, K[key])
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

local type_cache = {}
local function ctype(c)
    local name = unq(val(c, K.type)) or "default"
    local t = type_cache[name]
    if t == nil then
        local b = type(name) == "string" and SD.get("common/country_types", name) or nil
        t = {
            needs_survey = b and ftext(b, K.needs_survey) == "yes" or false,
            complete_sensor = b and ftext(b, K.has_complete_sensor) == "yes" or false,
            enclave = b and ftext(b, K.enclave) == "yes" or name == "enclave" or false,
        }
        type_cache[name] = t
    end
    return t
end

-- the component templates' ranges (the main thread's table: root 3, components = { key = { } })
local components = {}
local function component(key)
    if key == nil then return nil end
    local c = components[key]
    if c == nil then
        local aux = S.H.roots[3]
        local cb = aux ~= 0 and fblk(aux, K.components)
        local b = cb and type(key) == "string" and S.blk(cb, key)
        c = b and { sensor = fnum(b, K.sensor) or 0, hyperlane = fnum(b, K.hyperlane) or 0 } or false
        components[key] = c
    end
    return c or nil
end

local INTEL
local function intel_defs()
    if INTEL then return INTEL end
    INTEL = { levels = {}, categories = {} }
    for _, nd in ipairs(SD.each("common/intel_levels")) do
        local name, b = nd[1], nd[2]
        local range = numbers(fblk(b, K.intel))
        local cat = {}
        local r = B[b]
        for i = r.first, r.first + r.count - 1 do
            local e = E[i]
            if e.op ~= 0 and (e.kind == TEXT or e.kind == NUMBER) then
                local v = token(i)
                if type(v) == "number" then
                    local key = S.str(e.key)
                    if key ~= "frame" then cat[key] = v end
                end
            end
        end
        INTEL.levels[#INTEL.levels + 1] = { name = name, min = range[1] or 0, max = range[2] or -1, cat = cat }
    end
    table.sort(INTEL.levels, function(a, b) return a.min < b.min end)
    for _, nd in ipairs(SD.each("common/intel_categories")) do
        local name, b = nd[1], nd[2]
        local lv = {}
        local r = B[b]
        local k = K.intel_level
        for i = r.first, r.first + r.count - 1 do
            local e = E[i]
            if e.op ~= 0 and e.key == k and e.kind == BLOCK then
                lv[#lv + 1] = list(e.v.u.a)
            end
        end
        INTEL.categories[name] = lv
    end
    return INTEL
end

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

-- ---------------------------------------------------------------------------------------------
-- the galaxy (static: built once per state)

local G
local function galaxy()
    if G then return G end
    G = { ids = {}, hyper = {}, coord = {}, valid = {} }
    for _, s in ipairs(O.ids("galactic_object")) do G.ids[#G.ids + 1] = s end
    table.sort(G.ids)
    G.max = (G.ids[#G.ids] or -1) + 1
    for _, s in ipairs(G.ids) do
        local b = obj("galactic_object", s)
        G.valid[s] = true
        local h = {}
        for _, lane in ipairs(blocks(fblk(b, K.hyperlane))) do
            local to = fid(lane, K.to)
            if to then h[#h + 1] = to end
        end
        G.hyper[s] = h
        local c = fblk(b, K.coordinate)
        G.coord[s] = { fp(val(c, K.x)), fp(val(c, K.y)) }
    end
    G.bypasses, G.bypass_system = {}, {}
    for _, s in ipairs(G.ids) do
        local l = {}
        for _, t in ipairs(list(fblk(obj("galactic_object", s), K.bypasses))) do
            local id = tonumber(t)
            if id == NO_ID then id = nil end
            if id then
                l[#l + 1] = id
                G.bypass_system[id] = s
            end
        end
        G.bypasses[s] = l
    end
    -- the nebulae: the world's top-level `nebula = { galactic_object = <id> ... }`
    G.nebula = {}
    local root = S.H.roots[0]
    if root ~= 0 then
        local r = B[root]
        local k = K.nebula
        for i = r.first, r.first + r.count - 1 do
            local e = E[i]
            if e.op ~= 0 and e.key == k and e.kind == BLOCK then
                each_value(e.v.u.a, K.galactic_object, function(t)
                    local id = tonumber(t)
                    if id then G.nebula[id] = true end
                end)
            end
        end
    end
    return G
end

local function system_colonies(s)
    local n = 0
    each_value(obj("galactic_object", s), K.planet, function(t)
        if planet_colony(tonumber(t)) then n = n + 1 end
    end)
    return n
end
local function upgraded_starbase(s)
    for _, sb in ipairs(list(fblk(obj("galactic_object", s), K.starbases))) do
        local b = obj("starbases", tonumber(sb))
        if b then
            local level = unq(val(b, K.level))
            return level ~= nil and level ~= "starbase_level_outpost"
        end
    end
    return false
end

local function planet_system(pid)
    local p = pid and obj("planet", pid)
    return p and fid(fblk(p, K.coordinate), K.origin)
end
local function colony_system(cid)
    return planet_system(cid and colony_planet(cid))
end
local function fleet_system(f)
    return f and fid(fblk(fblk(f, K.movement_manager), K.coordinate), K.origin)
end
local function nearest_system(f)
    local s = fleet_system(f)
    if s then return s end
    local mm = f and fblk(f, K.movement_manager)
    local jump = mm and fblk(mm, K.last_ftl_jump)
    if not jump or ftext(mm, K.state) ~= "move_galaxy" then return nil end
    local from = fid(fblk(jump, K.from), K.origin)
    local to = fid(jump, K.to)
    local g = galaxy()
    local c = fblk(mm, K.coordinate)
    local x, y = fp(val(c, K.x)), fp(val(c, K.y))
    local function d2(s_)
        local p = s_ and g.coord[s_]
        if not p then return nil end
        return (p[1] - x) * (p[1] - x) + (p[2] - y) * (p[2] - y)
    end
    local a, b = d2(from), d2(to)
    if a and b then return a < b and from or to end
    return to or from
end

-- the pixel table (the main thread's: x_pix_own, x_pix_box, x_pix_core, x_pix_meta)
local PIX
local function pixel_table()
    if PIX then return PIX end
    local own = A.ptr("x_pix_own", "int32_t")
    local boxp, nbox = A.ptr("x_pix_box", "int32_t")
    local corep, ncore = A.ptr("x_pix_core", "int32_t")
    local meta = A.ptr("x_pix_meta", "int32_t")
    local box = {}
    for s = 0, nbox / 4 - 1 do
        if boxp[4 * s + 2] >= 0 then
            box[s] = { boxp[4 * s], boxp[4 * s + 1], boxp[4 * s + 2], boxp[4 * s + 3] }
        end
    end
    local core = {}
    for i = 0, ncore - 1 do core[i + 1] = corep[i] end
    PIX = { size = meta[0], own = own, box = box, core = core, core_box = { meta[1], meta[2], meta[3], meta[4] } }
    return PIX
end

-- ---------------------------------------------------------------------------------------------
-- lists in the country's block

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

-- exploration's set_list on a block only this state changes (a terra incognita block): in place
local function set_list_private(b, key, values)
    local k = K[key]
    local i = find(b, k)
    if #values == 0 then
        if i then S.remove_at(b, i) end
        return
    end
    local child
    if i and E[i].kind == BLOCK then
        child = E[i].v.u.a
    else
        if i then S.remove_at(b, i) end
        child = S.append_block(b, key)
    end
    S.set_numbers(child, values)
end

-- the same on the country's block, which other workers read: a list block rewritten in place, a
-- list added or taken out handed back (deferred[] = { country, key, values or false })
local function set_list_shared(cid, b, key, values, deferred)
    local i = find(b, K[key])
    if #values == 0 then
        if i then deferred[#deferred + 1] = { cid, key, false } end
        return
    end
    if i and E[i].kind == BLOCK then
        S.set_numbers(E[i].v.u.a, values)
        return
    end
    deferred[#deferred + 1] = { cid, key, values }
end
-- exploration's set_list itself, for the main thread (the deferred changes, after the barrier)
X.set_list = set_list_private

-- ---------------------------------------------------------------------------------------------
-- relations, rules, modifiers

local REL
local function relations_of(a)
    REL = REL or {}
    local t = REL[a]
    if t == nil then
        t = {}
        each_value(fblk(country(a), K.relations_manager), K.relation, function(_, r)
            if r then
                local other = fid(r, K.country)
                if other then t[other] = r end
            end
        end)
        REL[a] = t
    end
    return t
end
local function rel_flag(a, b, key)
    local r = relations_of(a)[b]
    return r ~= nil and yes(r, K[key])
end

local DAY = {}
local function forced(s)
    local f = s and IN.sys_flags(s)
    return f ~= nil and bit.band(f, 2) ~= 0
end
local function blocks_sensors(s)
    local f = IN.sys_flags(s)
    return f ~= nil and bit.band(f, 1) ~= 0
end
local function full_sensor(cid)
    local f = IN.country_flags(cid)
    return f ~= nil and bit.band(f, 1) ~= 0
end
local function owned_systems(cid)
    if DAY.owned == nil then
        DAY.owned = {}
        for _, s in ipairs(galaxy().ids) do
            local o = system_owner(s)
            if o then
                local l = DAY.owned[o]
                if not l then l = {} DAY.owned[o] = l end
                l[#l + 1] = s
            end
        end
    end
    return DAY.owned[cid] or {}
end

local design_cache = {}
local function design_stats(ship)
    local impl = fblk(ship, K.ship_design_implementation)
    local did = impl and fid(impl, K.design)
    local stage = impl and fnum(impl, K.growth_stage) or 0
    if not did then return 0, 0 end
    local key = did .. ":" .. stage
    local st = design_cache[key]
    if st then return st[1], st[2] end
    local design = obj("ship_design", did)
    local gs = design and blocks(fblk(design, K.growth_stages))[stage + 1]
    local sensor, hyper = 0, 0
    local function add(template)
        local c = component(unq(template))
        if c then
            if c.sensor > sensor then sensor = c.sensor end
            if c.hyperlane > hyper then hyper = c.hyperlane end
        end
    end
    if gs then
        local r = B[gs]
        local kreq, ksec, kcomp, ktpl = K.required_component, K.section, K.component, K.template
        for i = r.first, r.first + r.count - 1 do
            local e = E[i]
            if e.op ~= 0 then
                if e.key == kreq then
                    if e.kind ~= BLOCK then add(text(i)) else add(nil) end
                elseif e.key == ksec and e.kind == BLOCK then
                    each_value(e.v.u.a, kcomp, function(_, comp)
                        if comp then add(val(comp, ktpl)) end
                    end)
                end
            end
        end
    end
    design_cache[key] = { sensor, hyper }
    return sensor, hyper
end

local function ship_add(id)
    return IN.ship_sensor(id) or 0, IN.ship_hyper(id) or 0
end
local function colony_add(id)
    return IN.colony_sensor(id) or 0, IN.colony_hyper(id) or 0
end

local function ship_alive(s)
    return s ~= nil and (fnum(s, K.hitpoints) or 1) > 0
end
local function ship_ranges(id)
    DAY.ships = DAY.ships or {}
    local v = DAY.ships[id]
    if v == nil then
        local s = obj("ships", id)
        if not ship_alive(s) then
            v = false
        else
            local sensor, hyper = design_stats(s)
            local ms, mh = ship_add(id)
            v = { sensor + ms, hyper + mh }
        end
        DAY.ships[id] = v
    end
    if not v then return nil end
    return v[1], v[2]
end

local function fleet_prop(f, key)
    return yes(fblk(f, K.properties), K[key])
end
local function fleet_mia(f) return fleet_prop(f, "mia") end

local function owned_fleets(c)
    local out = {}
    for _, e in ipairs(blocks(fblk(fblk(c, K.fleets_manager), K.owned_fleets))) do
        local f = fid(e, K.fleet)
        if f then out[#out + 1] = f end
    end
    return out
end

-- ---------------------------------------------------------------------------------------------
-- the range expansion's priority queue (as engine.exploration)

local function pq_new(range)
    local g = galaxy()
    local q, pos = {}, {}
    for _, s in ipairs(g.ids) do
        local r = range[s]
        if r and r > -1 then q[#q + 1] = { s, r, #q } end
    end
    table.sort(q, function(a, b)
        if a[2] ~= b[2] then return a[2] < b[2] end
        return a[3] < b[3]
    end)
    for i, e in ipairs(q) do pos[e[1]] = i end
    return { q = q, pos = pos }
end
local function pq_push(pq, s, prio)
    local q, pos = pq.q, pq.pos
    local old = pos[s]
    if old == -2 then return end
    if old then
        if q[old][2] >= prio then return end
        table.remove(q, old)
    end
    local lo, hi = 1, #q + 1
    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        if prio >= q[mid][2] then lo = mid + 1 else hi = mid end
    end
    table.insert(q, lo, { s, prio })
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
-- the sensor coverage

local INTEL_OF_FLAGS = { [0] = 0, 1, 3, 3, 3, 3, 3, 3, 2, 2, 4, 4, 3, 3, 3, 3 }

local bypass_type_cache = {}
local function bypass_type(name)
    local t = bypass_type_cache[name]
    if t == nil then
        local d = type(name) == "string" and SD.get("common/bypass", name) or nil
        t = { extends = d and ftext(d, K.extends_sensors) == "yes" or false,
            exploration = d and ftext(d, K.requires_exploration) == "yes" or false }
        bypass_type_cache[name] = t
    end
    return t
end
local function bypass_targets(cid, c, s, usable)
    local g = galaxy()
    local out
    for _, bid in ipairs(g.bypasses[s] or {}) do
        local b = obj("bypasses", bid)
        local tname = b and unq(val(b, K.type))
        local t = tname and bypass_type(tname)
        if t and t.extends and yes(b, K.active) and usable[bid] then
            local seen = true
            if t.exploration and ctype(c).needs_survey then
                seen = false
                for _, v in ipairs(list(fblk(c, K.seen_bypass_types))) do
                    if unq(v) == tname then seen = true end
                end
            end
            if seen then
                local links = numbers(fblk(b, K.connections))
                local linked = fid(b, K.linked_to)
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
    for _, v in ipairs(numbers(fblk(c, K.usable_bypasses))) do set[v] = true end
    return set
end

local function expand_sensor(range, flags, bitv, cid, c, usable)
    local g = galaxy()
    local best, bucket, top = {}, {}, -1
    for s, r in pairs(range) do
        if r > -1 then
            best[s] = r
            local b = bucket[r]
            if not b then b = {} bucket[r] = b end
            b[#b + 1] = s
            if r > top then top = r end
        end
    end
    local done = {}
    for r = top, 0, -1 do
        local b = bucket[r]
        local i = 1
        while b and i <= #b do
            local s = b[i]
            i = i + 1
            if not done[s] and best[s] == r then
                done[s] = true
                flags[s] = bit.bor(flags[s] or 0, bitv)
                if r > 1 and not blocks_sensors(s) then
                    local function lend(n)
                        if g.valid[n] and not done[n] and (best[n] or -1) < r - 1 and not blocks_sensors(n) then
                            best[n] = r - 1
                            local nb = bucket[r - 1]
                            if not nb then nb = {} bucket[r - 1] = nb end
                            nb[#nb + 1] = n
                        end
                    end
                    for _, n in ipairs(g.hyper[s] or {}) do lend(n) end
                    for _, n in ipairs(bypass_targets(cid, c, s, usable) or {}) do lend(n) end
                end
            end
        end
    end
end

local function maxr(t, s, r)
    if s and (t[s] == nil or t[s] < r) then t[s] = r end
end

local function capital_system(o)
    local loc = fblk(o, K.location)
    if loc then
        local t, id = fnum(loc, K.type), fid(loc, K.id)
        if id then
            if t == 2 then return planet_system(id) end
            if t == 3 then return fleet_system(obj("fleet", id)) end
            if t == 4 then return id end
        end
    end
    return colony_system(fid(o, K.capital))
end

local function intel_items(c)
    local out = {}
    for _, item in ipairs(blocks(fblk(fblk(c, K.intel_manager), K.intel))) do
        local id, data
        local r = B[item]
        for i = r.first, r.first + r.count - 1 do
            local e = E[i]
            if e.op ~= 0 then
                local n = tonumber(S.str(e.key))
                if n and e.kind == BLOCK then id, data = n, e.v.u.a end
            elseif e.kind == TEXT or e.kind == NUMBER then
                id = tonumber(text(i))
            elseif e.kind == BLOCK then
                data = e.v.u.a
            end
        end
        if id and data then
            out[#out + 1] = { country = id, intel = fp(val(data, K.intel)) }
        end
    end
    return out
end

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
    local fa = fid(country(a), K.federation)
    local fb = fid(country(b), K.federation)
    if fa and fa == fb then
        local f = obj("federation", fa)
        local ft = f and unq(val(fblk(f, K.federation_progression), K.federation_type))
        if ft then out[#out + 1] = ft end
    end
    table.sort(out)
    return out
end

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
        for _, s in ipairs(visited) do
            if g.valid[s] then flags[s] = 1 end
        end
    else
        for _, s in ipairs(g.ids) do flags[s] = 1 end
    end
    if full_sensor(cid) then
        for _, s in ipairs(g.ids) do flags[s] = bit.bor(flags[s] or 0, 2) end
        return flags
    end
    local range1, range2 = {}, {}
    local function colony(col)
        local s = colony_system(col)
        if not s or not g.valid[s] then return end
        flags[s] = bit.bor(flags[s] or 0, 3)
        local add = colony_add(col)
        maxr(range1, s, d.PLANET_SENSOR_RANGE + add)
    end
    for _, col in ipairs(numbers(fblk(c, K.owned_planets))) do colony(col) end
    for _, col in ipairs(numbers(fblk(c, K.controlled_colonies))) do colony(col) end
    for _, fid_ in ipairs(owned_fleets(c)) do
        local f = obj("fleet", fid_)
        local s = fleet_system(f)
        if f and not fleet_mia(f) and s and g.valid[s] then
            local cloaked = fleet_prop(f, "cloaked")
            flags[s] = bit.bor(flags[s] or 0, cloaked and 5 or 3)
            local r = 0
            for _, ship in ipairs(numbers(fblk(f, K.ships))) do
                local x = ship_ranges(ship)
                if x and x > r then r = x end
            end
            maxr(cloaked and range2 or range1, s, r)
        end
    end
    for _, aid in ipairs(numbers(fblk(c, K.owned_armies))) do
        local a = obj("army", aid)
        local pl = a and fid(a, K.planet)
        if pl and (fnum(a, K.health) or 0) > 0 then
            local s = planet_system(pl) or colony_system(pl)
            if s and g.valid[s] then
                flags[s] = bit.bor(flags[s] or 0, 3)
                maxr(range1, s, 1)
            end
        end
    end
    for _, mid in ipairs(numbers(fblk(c, K.owned_megastructures))) do
        local m = obj("megastructures", mid)
        local s = m and fid(fblk(m, K.coordinate), K.origin)
        if s and g.valid[s] and ftext(m, K.disabled) ~= "yes" then
            flags[s] = bit.bor(flags[s] or 0, 3)
            local mt = unq(val(m, K.type))
            local md = type(mt) == "string" and SD.get("common/megastructures", mt) or nil
            maxr(range1, s, md and fnum(md, K.sensor_range) or 0)
        end
    end
    for other in pairs(relations_of(cid)) do
        local o = country(other)
        if o and rel_flag(cid, other, "communications") and ctype(o).enclave then
            local s = capital_system(o)
            if s and g.valid[s] then flags[s] = bit.bor(flags[s] or 0, 1) end
        end
    end
    for _, it in ipairs(intel_items(c)) do
        local o = country(it.country)
        if o and ftext(o, K.is_nomadic) ~= "yes" then
            local info = info_of(cid, it)
            if info.capital_location then
                local s = capital_system(o)
                if s and g.valid[s] then flags[s] = bit.bor(flags[s] or 0, 1) end
            end
        end
    end
    if t.needs_survey then
        for _, s in ipairs(owned_systems(cid)) do
            flags[s] = bit.bor(flags[s] or 0, 8)
        end
        local count = {}
        for _, h in ipairs(blocks(fblk(c, K.surveyed_deposit_holders))) do
            local id = fid(h, K.id)
            local s = id and planet_system(id)
            if s then count[s] = (count[s] or 0) + 1 end
        end
        for s, n in pairs(count) do
            local sb = obj("galactic_object", s)
            local need = count_key(sb, K.planet) + #list(fblk(sb, K.astral_rifts))
            if n >= need then flags[s] = bit.bor(flags[s] or 0, 8) end
        end
    else
        for _, s in ipairs(g.ids) do flags[s] = bit.bor(flags[s] or 0, 8) end
    end
    local usable = usable_bypasses(c)
    expand_sensor(range1, flags, 2, cid, c, usable)
    expand_sensor(range2, flags, 4, cid, c, usable)
    return flags
end

local function intel_levels(flags)
    local g = galaxy()
    local out = {}
    for i, s in ipairs(g.ids) do
        out[i] = INTEL_OF_FLAGS[bit.band(flags[s] or 0, 0xCF)] or 0
    end
    return out
end

local function hyperlane_range(cid, c, previous)
    local g, d = galaxy(), defines()
    if full_sensor(cid) then
        return copy(g.ids)
    end
    local range = {}
    for _, s in ipairs(previous) do
        if g.valid[s] then maxr(range, s, 1) end
    end
    local function colony(col)
        local s = colony_system(col)
        if s and g.valid[s] then
            local _, add = colony_add(col)
            maxr(range, s, d.PLANET_HYPERLANE_RANGE + add)
        end
    end
    for _, col in ipairs(numbers(fblk(c, K.owned_planets))) do colony(col) end
    for _, col in ipairs(numbers(fblk(c, K.controlled_colonies))) do colony(col) end
    for _, fid_ in ipairs(owned_fleets(c)) do
        local f = obj("fleet", fid_)
        local s = fleet_system(f)
        if f and not fleet_mia(f) and s and g.valid[s] then
            local r = 0
            for _, ship in ipairs(numbers(fblk(f, K.ships))) do
                local _, h = ship_ranges(ship)
                if h and h > r then r = h end
            end
            maxr(range, s, r)
        end
    end
    for _, aid in ipairs(numbers(fblk(c, K.owned_armies))) do
        local a = obj("army", aid)
        local pl = a and fid(a, K.planet)
        if pl and (fnum(a, K.health) or 0) > 0 then
            maxr(range, planet_system(pl) or colony_system(pl), 1)
        end
    end
    for _, mid in ipairs(numbers(fblk(c, K.owned_megastructures))) do
        local m = obj("megastructures", mid)
        local s = m and fid(fblk(m, K.coordinate), K.origin)
        if s and g.valid[s] and ftext(m, K.disabled) ~= "yes" then
            local mt = unq(val(m, K.type))
            local md = type(mt) == "string" and SD.get("common/megastructures", mt) or nil
            maxr(range, s, md and fnum(md, K.hyperlane_range) or 0)
        end
    end
    local out = {}
    local usable = usable_bypasses(c)
    local pq = pq_new(range)
    while #pq.q > 0 do
        local s, r = pq_pop(pq)
        out[#out + 1] = s
        if r > 1 then
            for _, n in ipairs(g.hyper[s] or {}) do
                if g.valid[n] then pq_push(pq, n, r - 1) end
            end
            for _, n in ipairs(bypass_targets(cid, c, s, usable) or {}) do
                if g.valid[n] then pq_push(pq, n, r - 1) end
            end
        end
    end
    return out
end

local function givers(cid, c)
    local out, seen = {}, {}
    local function add(id)
        if not seen[id] and country(id) then
            seen[id] = true
            out[#out + 1] = id
        end
    end
    local function country_and_subjects(id)
        add(id)
        for _, s in ipairs(numbers(fblk(country(id), K.subjects))) do add(s) end
    end
    local fed = fid(c, K.federation)
    local f = fed and obj("federation", fed)
    if f then
        for _, m in ipairs(numbers(fblk(f, K.members))) do country_and_subjects(m) end
    else
        country_and_subjects(cid)
    end
    return out
end

local SYSTEM_LEVEL = { intel_economy_systems_low = 1, intel_economy_systems_med = 2,
    intel_economy_systems_high = 3, intel_economy_systems_full = 4 }
local COLONY_LEVEL = { intel_economy_colonies_low = 1, intel_economy_colonies_med = 2,
    intel_economy_colonies_high = 3, intel_economy_colonies_full = 4 }

local function planet_owner(p)
    return p and fid(p, K.owner)
end
local function planet_controller(p)
    return p and (fid(p, K.controller) or fid(p, K.owner))
end

-- engine.fleets.survey.has_surveyed(country, 0, planet) over the store
local function needs_survey(cid)
    local c = country(cid)
    local ty = c and val(c, K.type)
    local d = type(ty) == "string" and SD.get("common/country_types", ty) or nil
    return d ~= nil and ftext(d, K.needs_survey) == "yes"
end
local function has_surveyed(cid, pid)
    local c = country(cid)
    local p = obj("planet", pid)
    local s = p and fnum(fblk(p, K.coordinate), K.origin)
    if not c or not needs_survey(cid) then return true end
    if s ~= nil and system_owner(s) == cid then return true end
    local hb = fblk(c, K.surveyed_deposit_holders)
    if not hb then return false end
    local r = B[hb]
    local kt, ki = K.type, K.id
    for i = r.first, r.first + r.count - 1 do
        local e = E[i]
        if e.op == 0 and e.kind == BLOCK then
            local h = e.v.u.a
            if fnum(h, kt) == 0 and fnum(h, ki) == pid then return true end
        end
    end
    return false
end

local function intel_survey(cid, pid, colony_want, other_want, ns)
    if not ns or not pid then return end
    -- (as engine.exploration writes it: a colony's planet takes other_want when colony_want is false)
    local want = planet_colony(pid) and colony_want or other_want
    local surveyed = has_surveyed(cid, pid)
    if want then
        if not surveyed then ns.add[#ns.add + 1] = pid end
    elseif surveyed then
        local p = obj("planet", pid)
        if planet_owner(p) == planet_controller(p) then ns.remove[#ns.remove + 1] = pid end
    end
end

local SLOT = {}     -- country id -> its slot in the shared intel array (its place in the ids)
local NIDS = 0      -- systems per slot

local function highest_intel(cid, c, highest_before, ns)
    local g = galaxy()
    if ctype(c).complete_sensor and #highest_before > 0 then
        return {}
    end
    local h = {}
    for i = 1, g.max do h[i] = 0 end
    for _, it in ipairs(X.options.intel_part and intel_items(c) or {}) do
        local o = country(it.country)
        local props = o and fnum(fblk(o, K.faction), K.properties)
        local effects = props == nil or bit.band(props, 2048) ~= 0
        if o and effects and (it.country == cid or rel_flag(it.country, cid, "communications")) then
            local info = info_of(cid, it)
            local la, lc = 0, 0
            for k, l in pairs(SYSTEM_LEVEL) do if info[k] and l > la then la = l end end
            for k, l in pairs(COLONY_LEVEL) do if info[k] and l > lc then lc = l end end
            local lb = info.intel_military_starbases and 2 or 0
            local colony_want = lc >= 3
            local other_want = la >= 3 or info.intel_economy_deposits == true
            for _, s in ipairs(owned_systems(it.country)) do
                local i = s + 1
                h[i] = la
                if lb > h[i] and upgraded_starbase(s) then h[i] = lb end
                local colonies = system_colonies(s)
                if la >= 3 or colonies > 0 then
                    if lc > h[i] then h[i] = lc end
                end
                if (other_want or colonies > 0) and (h[i] ~= 0 or other_want) then
                    each_value(obj("galactic_object", s), K.planet, function(t)
                        local pid = tonumber(t)
                        local ctrl = planet_controller(obj("planet", pid))
                        if ctrl == nil or ctrl == it.country then
                            intel_survey(cid, pid, colony_want, other_want, ns)
                        end
                    end)
                end
            end
            for _, col in ipairs(numbers(fblk(o, K.controlled_colonies))) do
                intel_survey(cid, colony_planet(col), colony_want, other_want, ns)
            end
        end
    end
    for _, gid in ipairs(givers(cid, c)) do
        local slot = SLOT[gid]
        if slot then
            local base = slot * NIDS
            local p = IN.intel
            for i = 1, math.min(NIDS, #h) do
                local v = p[base + i - 1]
                if v > h[i] then h[i] = v end
            end
        end
    end
    return h
end

local function intel_level_at(c, highest, s)
    local t = ctype(c)
    local l = 0
    if t.complete_sensor then
        l = 4
    elseif s and highest[s + 1] then
        l = highest[s + 1]
    end
    if not t.needs_survey then
        return l < 2 and 2 or l
    end
    return l
end

-- ---------------------------------------------------------------------------------------------
-- terra incognita: each country's map in the store's bytes (x_ti_off[country] = its offset + 1:
-- 8 bytes of flags (1 loaded, 2 the core cleared), then size * size bytes), made at its first pass

local function ti_load(cid, c)
    local tib = fblk(c, K.terra_incognita)
    if not tib then return nil end
    local size = fnum(tib, K.size) or defines().TI_TEXTURE_SIZE
    local slot = IN.ti_slot(cid)
    local off = slot and IN.ti_p[slot] or 0
    local rec
    if off <= 0 then
        local o = S.alloc_bytes(8 + size * size)
        rec = S.bytes_ptr(o)
        if slot then IN.ti_p[slot] = o + 1 end
        local data = rec + 8
        local runs = numbers(fblk(tib, K.data))
        local p, v = 0, 0
        for _, r in ipairs(runs) do
            for i = p, math.min(p + r, size * size) - 1 do data[i] = v end
            p = p + r
            v = 255 - v
        end
        for i = p, size * size - 1 do data[i] = 0 end
        rec[0] = 1
    else
        rec = S.bytes_ptr(off - 1)
    end
    local cleared = numbers(fblk(tib, K.systems))
    local set = {}
    for _, s in ipairs(cleared) do set[s] = true end
    return { block = tib, size = size, rec = rec, data = rec + 8, cleared = cleared, set = set, dirty = false }
end

local function ti_clear(ti, s)
    if ti.set[s] then return end
    local pix = pixel_table()
    local b = pix.box[s]
    if not b then return end
    local lo, hi = 1, #ti.cleared + 1
    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        if ti.cleared[mid] < s then lo = mid + 1 else hi = mid end
    end
    table.insert(ti.cleared, lo, s)
    ti.set[s] = true
    ti.dirty = true
    X.stats.ti_cleared = X.stats.ti_cleared + 1
    local size, own, data = ti.size, pix.own, ti.data
    for x = b[1], b[3] do
        for y = b[2], b[4] do
            local p = y * size + x
            if own[p] == s and data[p] == 0 then data[p] = 255 end
        end
    end
    if bit.band(ti.rec[0], 2) == 0 then
        for _, cs in ipairs(pix.core) do
            if not ti.set[cs] then return end
        end
        ti.rec[0] = bit.bor(ti.rec[0], 2)
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
    if not ti.dirty then return false end
    local runs = {}
    local v, n = 0, 0
    local total = ti.size * ti.size
    local data = ti.data
    for p = 0, total - 1 do
        local x = data[p]
        if x ~= v then
            runs[#runs + 1] = n
            v, n = x, 0
        end
        n = n + 1
    end
    runs[#runs + 1] = n
    set_list_private(ti.block, "data", runs)
    set_list_private(ti.block, "systems", ti.cleared)
    ti.dirty = false
    X.stats.ti_written = X.stats.ti_written + 1
    return true
end

-- ---------------------------------------------------------------------------------------------
-- the fleets a country sees

-- the fleets that can be seen at all, with what CanSee reads of them: computed once a pass by all
-- the states together (part b takes chunks of the fleets from H.counters[3]) into x_vfleets, one
-- record per fleet in the ids' order; part c reads them
ffi.cdef [[ typedef struct pdx_vfleet { double id, owner, here, near; uint8_t ok, enclave, cloaked, pad[5]; } pdx_vfleet; ]]
local VCHUNK = 32
local function fleet_record(rec, f_id)
    local f = obj("fleet", f_id)
    local nships = f and #numbers(fblk(f, K.ships)) or 0
    local removed = f and fnum(f, K.cached_combined_removed_ships) or 0
    rec.id = f_id
    rec.ok = 0
    if f and removed < nships and not fleet_mia(f) then
        local owner = fleet_owner(f_id)
        local o = owner and country(owner)
        rec.ok = 1
        rec.owner = owner or -1
        rec.enclave = (o and ctype(o).enclave) and 1 or 0
        rec.here = fleet_system(f) or -1
        rec.near = nearest_system(f) or -1
        rec.cloaked = fleet_prop(f, "cloaked") and 1 or 0
    end
end
local function fleet_records()
    local ids = O.ids("fleet")
    local p = A.ptr("x_vfleets", "pdx_vfleet")
    while true do
        local first = tonumber(S.H.fetch_add(S.H, 3, VCHUNK))
        if first >= #ids then break end
        for i = first, math.min(first + VCHUNK, #ids) - 1 do fleet_record(p[i], ids[i + 1]) end
    end
end
X.fleet_records = fleet_records

local function visible_fleets()
    if DAY.fleets then return DAY.fleets end
    local l = {}
    local p, n = A.ptr("x_vfleets", "pdx_vfleet")
    for i = 0, (n or 0) - 1 do
        local r = p[i]
        if r.ok == 1 then
            l[#l + 1] = { id = r.id, owner = r.owner >= 0 and r.owner or nil, enclave = r.enclave == 1,
                here = r.here >= 0 and r.here or nil, near = r.near >= 0 and r.near or nil, cloaked = r.cloaked == 1 }
        end
    end
    DAY.fleets = l
    return l
end

local function fleets_seen(cid, c, highest)
    local out = {}
    for _, v in ipairs(visible_fleets()) do
        local see = false
        if v.owner == cid then
            see = true
        elseif v.enclave and rel_flag(v.owner, cid, "communications") then
            see = true
        elseif v.here and forced(v.here) then
            see = true
        elseif intel_level_at(c, highest, v.near) >= 3 then
            see = not v.cloaked
        end
        if see then out[#out + 1] = v.id end
    end
    table.sort(out)
    return out
end

local function visited_update(cid, c, l)
    local g = galaxy()
    local i = 1
    while i <= #l do
        if not g.valid[l[i]] then
            l[i] = l[#l]
            l[#l] = nil
        else
            i = i + 1
        end
    end
    local seen = {}
    for _, s in ipairs(l) do seen[s] = true end
    local function add(s)
        if s and g.valid[s] and not seen[s] then
            seen[s] = true
            l[#l + 1] = s
        end
    end
    for _, s in ipairs(owned_systems(cid)) do add(s) end
    for _, col in ipairs(numbers(fblk(c, K.owned_planets))) do add(colony_system(col)) end
    for _, pid in ipairs(numbers(fblk(c, K.controlled_planets))) do add(planet_system(pid)) end
    for _, f_id in ipairs(owned_fleets(c)) do add(fleet_system(obj("fleet", f_id))) end
    for _, aid in ipairs(numbers(fblk(c, K.owned_armies))) do
        local a = obj("army", aid)
        local pl = a and fid(a, K.planet)
        if pl then add(planet_system(pl) or colony_system(pl)) end
    end
    return l
end

-- STELLAR_STORE_PROF: inclusive times of the parts' functions, per state (the T lines' Q entries)
local PROF = {}
X.prof = PROF
if os.getenv("STELLAR_STORE_PROF") then
    local function wrap(name, f)
        return function(...)
            local t = RUST.clock()
            local a, b = f(...)
            PROF[name] = (PROF[name] or 0) + (RUST.clock() - t)
            return a, b
        end
    end
    relations_of = wrap("relations_of", relations_of)
    owned_systems = wrap("owned_systems", owned_systems)
    ship_ranges = wrap("ship_ranges", ship_ranges)
    intel_items = wrap("intel_items", intel_items)
    info_of = wrap("info_of", info_of)
    sensor_flags = wrap("sensor_flags", sensor_flags)
    hyperlane_range = wrap("hyperlane_range", hyperlane_range)
    visited_update = wrap("visited_update", visited_update)
    expand_sensor = wrap("expand_sensor", expand_sensor)
    obj = wrap("obj", obj)
    numbers = wrap("numbers", numbers)
    highest_intel = wrap("highest_intel", highest_intel)
    intel_survey = wrap("intel_survey", intel_survey)
    has_surveyed = wrap("has_surveyed", has_surveyed)
    fleets_seen = wrap("fleets_seen", fleets_seen)
    visible_fleets = wrap("visible_fleets", visible_fleets)
    ti_load = wrap("ti_load", ti_load)
    ti_clear = wrap("ti_clear", ti_clear)
    ti_write = wrap("ti_write", ti_write)
    set_list_shared = wrap("set_list_shared", set_list_shared)
end

-- ---------------------------------------------------------------------------------------------
-- the pass, in three parts

local MINE = {}     -- the countries this state computes this pass, in the order taken
local R = {}        -- country id -> its results (this state's countries)
local T = X.stats.sections
local function lap(name, t)
    local now = RUST.clock()
    T[name] = (T[name] or 0) + (now - t)
    return now
end

-- X.begin(): a new pass (every state, before part a)
function X.begin()
    S.attach()
    E, B = S.E, S.B
    O.refresh()
    inputs()
    DAY, REL, MINE, R = {}, nil, {}, {}
    SLOT, NIDS = {}, #galaxy().ids
    for i, id in ipairs(O.ids("country")) do SLOT[id] = i - 1 end
end

-- part a for one country: the visited systems, the sensor coverage, the intel levels (to the
-- shared array), the hyperlanes
function X.part_a(cid, with_visited)
    local t = RUST.clock()
    local c = country(cid)
    local r = {
        visited0 = numbers(fblk(c, K.visited_objects)),
        intel0 = numbers(fblk(c, K.intel_level)),
        highest0 = numbers(fblk(c, K.highest_intel_level)),
        hyperlanes0 = numbers(fblk(c, K.hyperlane_systems)),
        fleets0 = numbers(fblk(c, K.sensor_range_fleets)),
    }
    r.visited = with_visited and visited_update(cid, c, copy(r.visited0)) or r.visited0
    t = lap("visited", t)
    local flags = sensor_flags(cid, c, r.visited)
    r.intel = intel_levels(flags)
    local base, p = SLOT[cid] * NIDS, IN.intel
    for i = 1, NIDS do p[base + i - 1] = r.intel[i] or 0 end
    t = lap("sensor", t)
    r.hyperlanes = hyperlane_range(cid, c, r.hyperlanes0)
    lap("hyperlanes", t)
    MINE[#MINE + 1] = cid
    R[cid] = r
end

-- part b: the shared intel (reads the other countries' intel levels of part a)
function X.part_b(cid, write)
    local t = RUST.clock()
    local r = R[cid]
    local ns = write and { add = {}, remove = {} } or nil
    r.highest = highest_intel(cid, country(cid), r.highest0, ns)
    r.surveys = ns
    lap("highest", t)
end

-- part c: the terra incognita, the fleets seen, the country's lists written. Returns its
-- outputs: what changed, the list changes handed back
function X.part_c(cid, write, deferred)
    local t = RUST.clock()
    local r = R[cid]
    local c = country(cid)
    r.fleets = fleets_seen(cid, c, r.highest)
    t = lap("fleets", t)
    local changed = 0
    if write then
        local ti = ti_load(cid, c)
        if ti then
            for i = 1, #r.highest do
                if r.highest[i] >= 1 and not ti.set[i - 1] then ti_clear(ti, i - 1) end
            end
            if ti_write(ti) then changed = changed + 32 end
        end
        if not same_list(r.visited0, r.visited) then set_list_shared(cid, c, "visited_objects", r.visited, deferred) changed = changed + 1 end
        if not same_list(r.intel0, r.intel) then set_list_shared(cid, c, "intel_level", r.intel, deferred) changed = changed + 2 end
        if not same_list(r.highest0, r.highest) then set_list_shared(cid, c, "highest_intel_level", r.highest, deferred) changed = changed + 4 end
        if not same_list(r.hyperlanes0, r.hyperlanes) then set_list_shared(cid, c, "hyperlane_systems", r.hyperlanes, deferred) changed = changed + 8 end
        if not same_list(r.fleets0, r.fleets) then set_list_shared(cid, c, "sensor_range_fleets", r.fleets, deferred) changed = changed + 16 end
        lap("write", t)
    end
    r.changed = changed
    return r
end

-- ---------------------------------------------------------------------------------------------
-- running a part over this state's share of the countries, with outputs as text (workers) or
-- tables (the main state)

-- the next country to take (H.counters[2], reset by the main thread before part a), in the order
-- the main thread gives (x_order: the costliest first, from the pass before), else the ids'
local function take(order, n_order)
    local n = tonumber(S.H.fetch_add(S.H, 2, 1))
    if n >= n_order then return nil end
    return order[n]
end

-- X.run_part(part, with_visited, write) -> text: this state's part of the pass. Part a takes
-- countries from the shared counter until none is left; b and c do the ones a took.
function X.run_part(part, with_visited, write)
    local t0 = RUST.clock()
    local out = {}
    if part == "a" then
        X.begin()
        local order, n_order = A.ptr("x_order", "double")
        if not order then
            local ids = O.ids("country")
            order = ffi.new("double[?]", #ids + 1)
            for i, id in ipairs(ids) do order[i - 1] = id end
            n_order = #ids
        end
        out[#out + 1] = string.format("S %.6f", RUST.clock() - t0)
        while true do
            local cid = take(order, n_order)
            if not cid then break end
            local tc = RUST.clock()
            X.part_a(cid, with_visited)
            out[#out + 1] = string.format("P %d %.6f", cid, RUST.clock() - tc)
        end
    elseif part == "b" then
        for _, cid in ipairs(MINE) do X.part_b(cid, write) end
        fleet_records()
    else
        local deferred = {}
        for _, cid in ipairs(MINE) do
            local r = X.part_c(cid, write, deferred)
            -- country changed-mask; surveys added; surveys removed
            local s = r.surveys
            out[#out + 1] = string.format("C %d %d %s|%s", cid, r.changed,
                s and table.concat(s.add, ",") or "", s and table.concat(s.remove, ",") or "")
        end
        for _, d in ipairs(deferred) do
            out[#out + 1] = string.format("D %d %s %s", d[1], d[2], d[3] and table.concat(d[3], ",") or "-")
        end
    end
    for k, v in pairs(PROF) do
        out[#out + 1] = string.format("Q %s %.6f", k, v)
        PROF[k] = nil
    end
    out[#out + 1] = string.format("T %s %.6f %d", part, RUST.clock() - t0, #MINE)
    return table.concat(out, "\n")
end

-- X.results(cid) -> this state's results for a country (the main state, single-threaded)
function X.results(cid)
    return R[cid]
end

return X
