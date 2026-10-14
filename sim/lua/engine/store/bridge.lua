-- engine/store/bridge.lua : the main thread's side of exploration over the store
-- (docs/data_layer.md, "The transition: a mirror"). With STELLAR_STORE=ffi, engine.exploration's
-- day runs here:
--
-- 1. the world exploration reads is kept in the store: a mirror of the table world (engine.world,
--    still the engine's) for the stores and keys exploration reads, synced every day (in place where
--    the shape is the same; a block whose shape changed is built again);
-- 2. the inputs the store does not hold yet go to typed arrays: the game rules (script triggers,
--    evaluated here), the modifier values, the world's indexes, the pixel table, the components;
-- 3. the pass runs on the worker pool (STELLAR_WORKERS=N, RUST.pool_run) or in this state
--    (STELLAR_WORKERS=0): parts a, b, c with a barrier after each; the list changes the workers
--    handed back are done here, in country order;
-- 4. what changed goes back to the table world (the lists, the terra incognita, the surveys the
--    country's serial day takes).
--
-- B.check(days) compares it with engine.exploration on the loaded world (no simulation).

local S = require("engine.store.core")
local A = require("engine.store.arrays")
local O = require("engine.store.objects")
local SD = require("engine.store.defs")
local X = require("engine.store.exploration")
local world = require("engine.world")
local defs = require("engine.defs")
local ffi = require("ffi")

local Bm = { stats = { days = 0, passes = 0, sync = 0, inputs = 0, parts = { a = 0, b = 0, c = 0 }, merge = 0,
    worker = { a = 0, b = 0, c = 0 }, rebuilt = 0, built = 0, seconds = 0, setup = 0, rule_errors = 0, prof = {}, sync_by = {} } }

local E, BL
local sid = S.id
local OPS = S.OPS
local FP = 100000

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
local function mod_int(m, key) return tdiv(fp(m[key] or 0), FP) end

-- ---------------------------------------------------------------------------------------------
-- the mirror: the stores and keys exploration reads

-- synced every day
local MIRROR = {
    country = { "type", "visited_objects", "intel_level", "highest_intel_level", "hyperlane_systems",
        "sensor_range_fleets", "owned_planets", "controlled_colonies", "controlled_planets", "owned_armies",
        "owned_megastructures", "fleets_manager", "relations_manager", "intel_manager", "federation",
        "subjects", "usable_bypasses", "seen_bypass_types", "surveyed_deposit_holders", "location",
        "capital", "is_nomadic", "faction" },
    fleet = { "movement_manager", "properties", "ships", "cached_combined_removed_ships" },
    ships = { "hitpoints", "ship_design_implementation" },
    planet = { "owner", "controller" },
    galactic_object = { "planet", "starbases", "astral_rifts" },
    starbases = { "level" },
    army = { "planet", "health" },
    megastructures = { "disabled", "type" },
    bypasses = { "type", "active", "connections", "linked_to" },
    federation = { "members", "federation_progression" },
    ship_design = {},
}
-- taken at the object's first build only: exploration's own state (the store's copy is the one it
-- changes), and what does not move (the galaxy's geometry, which engine.exploration also reads
-- once; a design, which it caches for good)
local STATIC_KEYS = {
    country = { "terra_incognita" },
    planet = { "coordinate" },
    galactic_object = { "hyperlane", "coordinate", "bypasses" },
    megastructures = { "coordinate" },
    ship_design = { "growth_stages" },
}

local KID = setmetatable({}, { __index = function(t, k)
    local id = sid(k)
    t[k] = id
    return id
end })

local MB = {}       -- store name -> { [id] = block id } (the mirror's objects)
local NSTATIC = {}  -- store name -> { [id] = how many static entries begin the block }
local MTAB = {}     -- store name -> { [id] = the table object the block was last built from }
local function rebuilt()
    Bm.stats.rebuilt = Bm.stats.rebuilt + 1
    return nil
end

-- the store block bid synced to the Lua block t (pdxscript form): in place when the shape is the
-- same (the same count, keys and kinds), else built again; returns the block id (bid or a new one)
local sync_block
local function sync_entries(bid, t)
    local r = BL[bid]
    local n = #t
    if r.count ~= n then return rebuilt() end
    local first = r.first
    -- the shape first, so that a mismatch changes nothing
    for j = 1, n do
        local x = t[j]
        local e = E[first + j - 1]
        if x.op then
            if e.op == 0 or e.key ~= sid(x.key.text) then return rebuilt() end
        elseif x.param or e.op ~= 0 then
            return rebuilt()
        end
    end
    for j = 1, n do
        local x = t[j]
        local e = E[first + j - 1]
        local v = x.op and x.value or x
        if x.op then e.op = OPS[x.op] end
        if v.text then
            e.kind = 1
            e.v.u.a = sid(v.text)
            e.v.u.b = 0
            e.flags = (x.op and x.key.quoted and 1 or 0) + (v.quoted and 2 or 0)
        else
            if e.kind == 3 then
                e.v.u.a = sync_block(e.v.u.a, v)
            else
                e.kind = 3
                e.v.u.a = S.build(v)
            end
            e.v.u.b = v.type and sid(v.type) or 0
            e.flags = x.op and x.key.quoted and 1 or 0
        end
    end
    return true
end
function sync_block(bid, t)
    if sync_entries(bid, t) then return bid end
    return S.build(t)
end

-- an object's mirrored values, from the table world's field index (engine.world.fields): the
-- keys' ids and their values (a text, or a Lua block), the keys in the list's order
local function values_of(tobj, keys)
    local kids, vals = {}, {}
    for _, k in ipairs(keys) do
        local kid = KID[k]
        for _, v in ipairs(world.fields(tobj, k)) do
            kids[#kids + 1] = kid
            vals[#vals + 1] = v
        end
    end
    return kids, vals
end

-- the entries [off, off + #vals) of block bid synced to (kids, vals), in place: true, or nil
-- when the shape differs (nothing changed)
local function sync_values(bid, kids, vals, off)
    local r = BL[bid]
    local n = #vals
    if r.count ~= off + n then return rebuilt() end
    local first = r.first + off
    for j = 1, n do
        local e = E[first + j - 1]
        if e.op == 0 or e.key ~= kids[j] then return rebuilt() end
    end
    for j = 1, n do
        local e = E[first + j - 1]
        local v = vals[j]
        if type(v) == "string" then
            e.kind = 1
            e.v.u.a = sid(v)
            e.v.u.b = 0
        else
            if e.kind == 3 then
                e.v.u.a = sync_block(e.v.u.a, v)
            else
                e.kind = 3
                e.v.u.a = S.build(v)
            end
            e.v.u.b = v.type and sid(v.type) or 0
        end
    end
    return true
end

-- a new block: the static values, then the dynamic ones
local function build_object(statics, kids, vals)
    local t = {}
    for i, v in ipairs(statics.vals) do
        t[#t + 1] = { key = { text = S.str(statics.kids[i]) }, op = "=", value = type(v) == "string" and { text = v } or v }
    end
    for i, v in ipairs(vals) do
        t[#t + 1] = { key = { text = S.str(kids[i]) }, op = "=", value = type(v) == "string" and { text = v } or v }
    end
    return S.build(t)
end

-- a mirror object's block: its static entries first (only the first build takes them from the
-- table), then the dynamic ones (synced every day; a list a pass adds goes at the end, and the
-- next sync, which finds another shape, builds the dynamic part again)
local function sync_object(name, id, tobj)
    local mb, ns = MB[name], NSTATIC[name]
    local b = mb[id]
    local keys = MIRROR[name]
    if b and #keys == 0 and MTAB[name][id] == tobj then return b end
    local kids, vals = values_of(tobj, keys)
    if not b or MTAB[name][id] ~= tobj then
        local sk, sv = values_of(tobj, STATIC_KEYS[name] or {})
        b = build_object({ kids = sk, vals = sv }, kids, vals)
        mb[id], ns[id], MTAB[name][id] = b, #sv, tobj
        Bm.stats.built = Bm.stats.built + 1
        return b
    end
    local nst = ns[id]
    if sync_values(b, kids, vals, nst) then return b end
    -- another shape: the static entries' records kept, the dynamic ones built again
    local tmp = build_object({ kids = {}, vals = {} }, kids, vals)
    local nb = S.new_block(nst + #vals)
    local r = BL[b]
    for i = r.first, r.first + nst - 1 do S.append_entry(nb, i) end
    local tr = BL[tmp]
    for i = tr.first, tr.first + tr.count - 1 do S.append_entry(nb, i) end
    mb[id] = nb
    return nb
end

-- ---------------------------------------------------------------------------------------------
-- keeping the mirror current: the objects the writers marked (engine.store.live), the new ones
-- and the replaced ones are brought in; the others are left. With STELLAR_STORE_CHECK=1 the others
-- are compared with the table world (read-only) and a stale one is counted by store and key, then
-- brought in. STELLAR_STORE_SYNC=all brings every object in every day (the first version).

local live = require("engine.store.live")
local SYNC_ALL = os.getenv("STELLAR_STORE_SYNC") == "all"
Bm.stats.stale, Bm.stats.stale_ids, Bm.stats.synced, Bm.stats.checked = {}, {}, 0, 0

-- whether store block bid holds what the Lua block t holds (keys, kinds, texts; not the quoting)
local same_block
function same_block(bid, t)
    local r = BL[bid]
    local n = #t
    if r.count ~= n then return false end
    local first = r.first
    for j = 1, n do
        local x = t[j]
        local i = first + j - 1
        local e = E[i]
        local v
        if x.op then
            if e.op == 0 or e.key ~= sid(x.key.text) then return false end
            v = x.value
        else
            if x.param or e.op ~= 0 then return false end
            v = x
        end
        if v.text then
            if (e.kind ~= 1 and e.kind ~= 2) or S.text(i) ~= v.text then return false end
        elseif e.kind ~= 3 or not same_block(e.v.u.a, v) then
            return false
        end
    end
    return true
end

-- whether the store's values of key k in block bid are the table's (vals, in order; the order of
-- different keys does not matter: a list exploration adds goes at the block's end)
local function same_key(bid, k, vals)
    local i = S.find(bid, k)
    for j = 1, #vals do
        if not i then return false end
        local e = E[i]
        local v = vals[j]
        if type(v) == "string" then
            if (e.kind ~= 1 and e.kind ~= 2) or S.text(i) ~= v then return false end
        elseif e.kind ~= 3 or not same_block(e.v.u.a, v) then
            return false
        end
        i = S.find_next(bid, k, i)
    end
    return i == nil
end

-- the check of an unmarked object: the key that went stale ("static:" for a static key), or nil
local function stale_key(name, id, tobj)
    local b = MB[name][id]
    for _, part in ipairs({ { STATIC_KEYS[name] or {}, "static:" }, { MIRROR[name], "" } }) do
        for _, k in ipairs(part[1]) do
            if not same_key(b, sid(k), world.fields(tobj, k)) then return part[2] .. k end
        end
    end
    return nil
end

local mirror_root
local LIVE = {}   -- store name -> the number of live objects last published
-- B.sync(): the mirror made current from the table world, and the object tables published
function Bm.sync()
    local t0 = RUST.clock()
    local dirty = live.take()
    for name in pairs(MIRROR) do
        MB[name] = MB[name] or {}
        NSTATIC[name] = NSTATIC[name] or {}
        MTAB[name] = MTAB[name] or {}
        local ts = RUST.clock()
        local store = world.stores[name] or {}
        local ids = world.ids[name] or {}
        local mb, mt = MB[name], MTAB[name]
        local d = dirty[name]
        local every = SYNC_ALL or d == true
        local changed, n = false, 0
        local live_ids = {}
        for _, id in ipairs(ids) do
            local t = store[id]
            if t then
                n = n + 1
                live_ids[n] = id
                local b = mb[id]
                local bring = every or not b or mt[id] ~= t or (d and d[id])
                if not bring and live.check then
                    Bm.stats.checked = Bm.stats.checked + 1
                    local k = stale_key(name, id, t)
                    if k then
                        local key = name .. "." .. k
                        Bm.stats.stale[key] = (Bm.stats.stale[key] or 0) + 1
                        local ex = Bm.stats.stale_ids[key] or {}
                        if #ex < 6 then ex[#ex + 1] = id end
                        Bm.stats.stale_ids[key] = ex
                        bring = true
                        if k:sub(1, 7) == "static:" then mt[id] = nil end   -- built again, statics too
                    end
                end
                if bring then
                    Bm.stats.synced = Bm.stats.synced + 1
                    if sync_object(name, id, t) ~= b then changed = true end
                end
            end
        end
        Bm.stats.sync_by[name] = (Bm.stats.sync_by[name] or 0) + (RUST.clock() - ts)
        -- the object table again when an object came, went or moved to another block
        if changed or n ~= LIVE[name] then
            O.publish(name, live_ids, mb)
            LIVE[name] = n
        end
    end
    if not mirror_root then
        -- the world's root in the mirror: the top-level nebulae (exploration's galaxy reads them)
        local top = {}
        for _, e in ipairs(world.tree or {}) do
            if e.op and e.key and e.key.text == "nebula" and e.value.text == nil then top[#top + 1] = e end
        end
        mirror_root = S.build(top)
        S.H.roots[0] = mirror_root
    end
    Bm.stats.sync = Bm.stats.sync + (RUST.clock() - t0)
end

-- B.stale_report() -> text: what the check found
function Bm.stale_report()
    local l = {}
    for k, n in pairs(Bm.stats.stale) do l[#l + 1] = { k, n } end
    table.sort(l, function(a, b) return a[2] > b[2] end)
    local out = { string.format("store check: %d objects compared, %d brought in; %d stale keys", Bm.stats.checked, Bm.stats.synced, #l) }
    for _, x in ipairs(l) do
        out[#out + 1] = string.format("  %-50s %6d  e.g. %s", x[1], x[2], table.concat(Bm.stats.stale_ids[x[1]], " "))
    end
    return table.concat(out, "\n")
end

-- B.full(): the whole world's tree in the store instead of the mirror (engine.store.world), its
-- object tables published (B.check, the benchmarks)
function Bm.full()
    local W = require("engine.store.world")
    W.build(world.tree)
    O.publish_world(W)
    return W
end

-- ---------------------------------------------------------------------------------------------
-- the inputs

local ok_eval, eval
local rule_def = {}
local function rule(name, kind, id, root)
    local d = rule_def[name]
    if d == nil then
        d = defs.get("common/game_rules", name) or false
        rule_def[name] = d
    end
    if not d then return false end
    eval = eval or require("simscript.eval")
    local ctx = eval.new_ctx(eval.S(kind, id), nil, nil, d.file)
    if root then ctx.root = eval.S("country", root) end
    local ok, holds = pcall(eval.trigger, d.block, ctx)
    if not ok then
        Bm.stats.rule_errors = Bm.stats.rule_errors + 1
        holds = false
    end
    return holds and true or false
end

local function max_id(ids)
    local m = -1
    for _, id in ipairs(ids) do if id > m then m = id end end
    return m
end

-- the component templates' ranges (engine.exploration's component(): common/component_templates,
-- repeated `*_component_template = { key = ... }`, values often a file's @variable)
local function components_tree()
    local db = require("simscript.db")
    local source = require("stellar.script.source")
    local globals = {}
    for name, d in pairs(defs.folder("common/scripted_variables") or {}) do
        globals[name] = d.value or (d.block and d.block.text)
    end
    local comps, order = {}, {}
    for _, file in ipairs(source.files(db.fs, "common/component_templates", "txt")) do
        local tree = source.parse(db.fs, file)
        local vars = {}
        for _, e in ipairs(tree or {}) do
            if e.op and e.key and e.key.text:sub(1, 1) == "@" and e.value.text then vars[e.key.text] = e.value.text end
        end
        local function value(v)
            if type(v) == "string" and v:sub(1, 1) == "@" then v = vars[v] or globals[v] or globals[v:sub(2)] end
            return tonumber(v) or 0
        end
        for _, e in ipairs(tree or {}) do
            if e.op and e.key and e.value.text == nil then
                local k = defs.field(e.value, "key")
                k = type(k) == "string" and (k:gsub('^"(.*)"$', "%1")) or k
                if k then
                    if not comps[k] then order[#order + 1] = k end
                    comps[k] = { value(defs.field(e.value, "sensor_range")), value(defs.field(e.value, "hyperlane_range")) }
                end
            end
        end
    end
    local block = {}
    for _, k in ipairs(order) do
        block[#block + 1] = { key = { text = tostring(k) }, op = "=", value = {
            { key = { text = "sensor" }, op = "=", value = { text = tostring(comps[k][1]) } },
            { key = { text = "hyperlane" }, op = "=", value = { text = tostring(comps[k][2]) } } } }
    end
    return { { key = { text = "components" }, op = "=", value = block } }
end

local setup_done = false
-- B.setup(): what is built once: the definitions, the components, the pixel table
function Bm.setup()
    if setup_done then return end
    setup_done = true
    local t0 = RUST.clock()
    S.attach()
    E, BL = S.E, S.B
    -- the folders exploration reads (STELLAR_STORE_DEFS=all: every folder, 0.3 s more)
    if os.getenv("STELLAR_STORE_DEFS") == "all" then
        SD.build(defs)
    else
        SD.build(defs, { "common/bypass", "common/country_types", "common/defines", "common/intel_categories",
            "common/intel_levels", "common/megastructures" })
    end
    Bm.stats.defs = SD.seconds
    S.H.roots[3] = S.build(components_tree())
    -- the pixel table, from engine.exploration's (the galaxy's systems are static)
    local TX = require("engine.exploration")
    local pix = TX.pixel_table()
    local g = TX.galaxy()
    local size = pix.size
    local own = A.make("x_pix_own", "int32_t", size * size)
    for p = 0, size * size - 1 do own[p] = pix.own[p] end
    local box = A.make("x_pix_box", "int32_t", 4 * g.max)
    for s = 0, g.max - 1 do box[4 * s + 2] = -1 end
    for s, b in pairs(pix.box) do
        if s < g.max then
            box[4 * s], box[4 * s + 1], box[4 * s + 2], box[4 * s + 3] = b[1], b[2], b[3], b[4]
        end
    end
    local core = A.make("x_pix_core", "int32_t", #pix.core)
    for i, s in ipairs(pix.core) do core[i - 1] = s end
    local meta = A.make("x_pix_meta", "int32_t", 5)
    meta[0], meta[1], meta[2], meta[3], meta[4] = size, pix.core_box[1], pix.core_box[2], pix.core_box[3], pix.core_box[4]
    Bm.stats.setup = RUST.clock() - t0
end

-- B.inputs(): the day's typed arrays (the main thread, before part a)
local IP = {}
Bm.stats.input_parts = IP
local SHIP_GEN, SHIP_S, SHIP_H   -- the ships' modifier values, by the modifier source's build
local function ilap(name, t)
    local now = RUST.clock()
    IP[name] = (IP[name] or 0) + (now - t)
    return now
end
function Bm.inputs()
    local t0 = RUST.clock()
    local tl = t0
    local NONE = -9.9e300
    local sys = world.all("system")
    local sf = {}
    for _, s in ipairs(sys) do
        local f = 0
        if rule("system_blocks_sensors", "system", s) then f = f + 1 end
        if rule("can_force_see_fleets_in_system", "system", s) then f = f + 2 end
        sf[s] = f
    end
    A.publish_map("x_sys_flags", sf)
    tl = ilap("rules_systems", tl)
    local cids = world.all("country")
    local cf = {}
    for _, c in ipairs(cids) do
        cf[c] = rule("has_full_sensor_range", "country", c) and 1 or 0
    end
    A.publish_map("x_country_flags", cf)
    tl = ilap("rules_countries", tl)
    -- each country's terra incognita record (kept from the day before; 0: not made yet)
    local ti_get = A.map("x_ti_off")
    local ti = {}
    for _, c in ipairs(cids) do ti[c] = ti_get(c) or 0 end
    A.publish_map("x_ti_off", ti)
    -- the modifier values exploration reads: every ship's, every colony a country lists
    local economy = package.loaded["engine.economy"]
    local has = economy and economy.has_modifier_source and economy.has_modifier_source()
    local function mods(kind, id)
        return has and economy.modifiers(kind, id) or {}
    end
    -- the ships' values are the modifier source's, which holds them by id until it is built
    -- again (the monthly rebuild): kept until then, published when a ship is new
    local engine_ = package.loaded["engine"]
    local src = engine_ and engine_.modifier_source
    local gen = src and src.stats and src.stats.builds or 0
    if gen ~= SHIP_GEN then
        SHIP_GEN, SHIP_S, SHIP_H = gen, {}, {}
    end
    local new = false
    for _, id in ipairs(world.all("ship")) do
        if SHIP_S[id] == nil then
            local m = mods("ship", id)
            SHIP_S[id], SHIP_H[id] = mod_int(m, "ship_sensor_range_add"), mod_int(m, "ship_hyperlane_range_add")
            new = true
        end
    end
    if new then
        A.publish_map("x_ship_sensor", SHIP_S, "double", NONE)
        A.publish_map("x_ship_hyper", SHIP_H, "double", NONE)
    end
    tl = ilap("ship_modifiers", tl)
    local cs, ch = {}, {}
    for _, c in ipairs(cids) do
        local o = world.object("country", c)
        for _, key in ipairs({ "owned_planets", "controlled_colonies" }) do
            local b = world.field(o, key)
            if type(b) == "table" then
                for _, e in ipairs(b) do
                    local v = e.text and tonumber(e.text)
                    if v and v >= 0 and cs[v] == nil then
                        local m = mods("colony", v)
                        cs[v], ch[v] = mod_int(m, "planet_sensor_range_add"), mod_int(m, "planet_hyperlane_range_add")
                    end
                end
            end
        end
    end
    A.publish_map("x_colony_sensor", cs, "double", NONE)
    A.publish_map("x_colony_hyper", ch, "double", NONE)
    tl = ilap("colony_modifiers", tl)
    -- the world's indexes
    A.publish_map("x_planet_colony", world.planet_colony or {})
    A.publish_map("x_colony_planet", world.colony_planet or {})
    A.publish_map("x_system_owner", world.system_owner or {})
    A.publish_map("x_fleet_owner", world.fleet_owner or {})
    -- the shared intel levels: a slot of every system per country
    local nids = #require("engine.exploration").galaxy().ids
    A.make("x_intel", "uint8_t", math.max(1, #cids * nids))
    -- the fleets' visibility records (part b fills them)
    O.refresh()
    A.make("x_vfleets", "pdx_vfleet", math.max(1, #O.ids("fleet")))
    ilap("indexes", tl)
    Bm.stats.inputs = Bm.stats.inputs + (RUST.clock() - t0)
end

-- ---------------------------------------------------------------------------------------------
-- the pass

local POOL = 0
local function workers()
    return POOL
end

-- parses a part's outputs: { countries = { [cid] = { mask, add = {}, remove = {} } }, deferred = { } }
local function parse(text, out)
    for line in text:gmatch("[^\n]+") do
        local tag = line:sub(1, 1)
        if tag == "C" then
            local cid, mask, adds, removes = line:match("^C (%d+) (%d+) ([^|]*)|(.*)$")
            local add, remove = {}, {}
            for v in adds:gmatch("[^,]+") do add[#add + 1] = tonumber(v) end
            for v in removes:gmatch("[^,]+") do remove[#remove + 1] = tonumber(v) end
            out.countries[tonumber(cid)] = { mask = tonumber(mask), add = add, remove = remove }
        elseif tag == "D" then
            local cid, key, values = line:match("^D (%d+) (%S+) (.*)$")
            local vals = false
            if values ~= "-" then
                vals = {}
                for v in values:gmatch("[^,]+") do vals[#vals + 1] = tonumber(v) end
            end
            out.deferred[#out.deferred + 1] = { tonumber(cid), key, vals }
        elseif tag == "T" then
            local part, secs = line:match("^T (%a) (%S+)")
            out.times[part] = math.max(out.times[part] or 0, tonumber(secs))
        elseif tag == "P" then
            local cid, secs = line:match("^P (%d+) (%S+)")
            out.costs[tonumber(cid)] = tonumber(secs)
        elseif tag == "S" then
            out.setup = math.max(out.setup or 0, tonumber(line:match("^S (%S+)")))
        elseif tag == "Q" then
            local name, secs = line:match("^Q (%S+) (%S+)")
            local p = Bm.stats.prof[name] or { sum = 0, max = 0, n = 0 }
            p.sum = p.sum + tonumber(secs)
            p.max = math.max(p.max, tonumber(secs))
            Bm.stats.prof[name] = p
        end
    end
end

-- B.pass(with_visited, write) -> outputs: the three parts, on the pool or here
local COSTS = {}   -- country id -> its part a's time in the pass before (the order of the next)
function Bm.pass(with_visited, write)
    local out = { countries = {}, deferred = {}, times = {}, costs = {} }
    local arg_v, arg_w = with_visited and "1" or "0", write and "1" or "0"
    -- the order the countries are taken in: the costliest first (by the pass before), so that
    -- the last ones taken are short (longest processing time first)
    local ids = world.all("country")
    local order = {}
    for i, id in ipairs(ids) do order[i] = id end
    local pos = {}
    for i, id in ipairs(ids) do pos[id] = i end
    table.sort(order, function(a, b)
        local ca, cb = COSTS[a] or 1e9, COSTS[b] or 1e9
        if ca ~= cb then return ca > cb end
        return pos[a] < pos[b]
    end)
    local op = A.make("x_order", "double", #order)
    for i, id in ipairs(order) do op[i - 1] = id end
    S.H.counters[2] = 0
    S.H.counters[3] = 0
    for _, part in ipairs({ "a", "b", "c" }) do
        local t0 = RUST.clock()
        if workers() > 0 then
            local results = RUST.pool_run("part", part .. arg_v .. arg_w)
            for _, r in ipairs(results) do parse(r, out) end
        else
            local was = S.serial
            S.serial = false
            parse(X.run_part(part, with_visited, write), out)
            S.serial = was
        end
        Bm.stats.parts[part] = Bm.stats.parts[part] + (RUST.clock() - t0)
        Bm.stats.worker[part] = Bm.stats.worker[part] + (out.times[part] or 0)
    end
    for cid, c in pairs(out.costs) do COSTS[cid] = c end
    -- the list changes the workers handed back, in country order
    table.sort(out.deferred, function(a, b)
        if a[1] ~= b[1] then return a[1] < b[1] end
        return a[2] < b[2]
    end)
    for _, d in ipairs(out.deferred) do
        local c = O.get("country", d[1])
        if c then X.set_list(c, d[2], d[3] or {}) end
    end
    Bm.stats.passes = Bm.stats.passes + 1
    return out
end

-- ---------------------------------------------------------------------------------------------
-- back to the table world

local LISTS = { [1] = "visited_objects", [2] = "intel_level", [4] = "highest_intel_level",
    [8] = "hyperlane_systems", [16] = "sensor_range_fleets" }

local function entry(obj, key)
    for _, e in ipairs(obj) do
        if e.op and e.key and e.key.text == key then return e end
    end
    return nil
end
-- engine.exploration's set_list, on the table world
local function tset_list(obj, key, values)
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

local function store_list(b, key)
    return S.numbers(b and S.blk(b, key))
end

-- B.merge(outputs): the changed lists, terra incognita maps and surveys into the table world
function Bm.merge(out)
    local t0 = RUST.clock()
    local STATE = require("engine.exploration").state
    local cids = {}
    for cid in pairs(out.countries) do cids[#cids + 1] = cid end
    table.sort(cids)
    for _, cid in ipairs(cids) do
        local o = out.countries[cid]
        local tc = world.object("country", cid)
        local sc = O.get("country", cid)
        if tc and sc then
            for bitv, key in pairs(LISTS) do
                if bit.band(o.mask, bitv) ~= 0 then tset_list(tc, key, store_list(sc, key)) end
            end
            if bit.band(o.mask, 32) ~= 0 then
                local tti = world.field(tc, "terra_incognita")
                local sti = S.blk(sc, "terra_incognita")
                if type(tti) == "table" and sti then
                    tset_list(tti, "data", store_list(sti, "data"))
                    tset_list(tti, "systems", store_list(sti, "systems"))
                end
            end
        end
        local st = STATE[cid]
        if not st then
            st = {}
            STATE[cid] = st
        end
        local ns = st.surveys or { add = {}, remove = {} }
        for _, v in ipairs(o.add) do ns.add[#ns.add + 1] = v end
        for _, v in ipairs(o.remove) do ns.remove[#ns.remove + 1] = v end
        st.surveys = ns
    end
    Bm.stats.merge = Bm.stats.merge + (RUST.clock() - t0)
end

-- ---------------------------------------------------------------------------------------------
-- the day (engine.exploration.countries_daily with STELLAR_STORE=ffi)

local started = false
local function start()
    if started then return end
    started = true
    S.attach()
    E, BL = S.E, S.B
    Bm.setup()
    -- STELLAR_WORKERS=N (0: the pass in this state); by default 4, or one less than the machine's
    -- threads when it has fewer than 5
    local n = tonumber(os.getenv("STELLAR_WORKERS") or "")
    if n == nil then
        n = math.max(0, math.min(4, (RUST.cpus and RUST.cpus() or 1) - 1))
    end
    if n > 0 then
        RUST.pool_start(n)
        POOL = n
    end
end

local loaded = false
function Bm.countries_daily(host, date)
    local t0 = RUST.clock()
    start()
    Bm.sync()
    Bm.inputs()
    if not loaded then
        loaded = true
        Bm.merge(Bm.pass(false, true))
        -- the load's pass changed lists the next pass reads: the mirror made current again
        Bm.sync()
    end
    Bm.merge(Bm.pass(true, true))
    Bm.stats.days = Bm.stats.days + 1
    Bm.stats.seconds = Bm.stats.seconds + (RUST.clock() - t0)
end

function Bm.report()
    local s = Bm.stats
    local by = {}
    for k, v in pairs(s.sync_by) do by[#by + 1] = string.format("%s %.2f", k, v) end
    table.sort(by)
    return string.format("store exploration: %d days on %d workers, %.2f s (setup %.2f s, definitions %.2f s; sync %.2f, inputs %.2f, parts a %.2f b %.2f c %.2f (the slowest worker's a %.2f b %.2f c %.2f), merge %.2f); %d objects built, %d blocks built again; %d rule errors; the store %s",
        s.days, POOL, s.seconds, s.setup, s.defs or 0, s.sync, s.inputs, s.parts.a, s.parts.b, s.parts.c,
        s.worker.a, s.worker.b, s.worker.c, s.merge, s.built, s.rebuilt, s.rule_errors, S.usage()) .. "; the sync by store (s): " .. table.concat(by, ", ")
        .. string.format("; %d objects brought in, %d marks", s.synced, live.marks)
        .. (function()
            local p = {}
            for k, v in pairs(s.input_parts) do p[#p + 1] = string.format("%s %.2f", k, v) end
            table.sort(p)
            return "; the inputs (s): " .. table.concat(p, ", ")
        end)()
        .. (live.check and ("\n" .. Bm.stale_report()) or "")
end

-- ---------------------------------------------------------------------------------------------
-- B.check(days[, workers]): engine.exploration and the store's on the loaded world, day after day
-- (only exploration runs): the countries' lists, maps and surveys compared after each pass

local function tnumbers(b)
    local out = {}
    if type(b) == "table" then
        for _, e in ipairs(b) do if e.text then out[#out + 1] = tonumber(e.text) end end
    end
    return out
end
local function same(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do if a[i] ~= b[i] then return false end end
    return true
end

-- B.scale(counts, reps[, warm]) -> text: the store's daily pass on the loaded world (the whole
-- tree in the store), `reps` passes for each worker count (after `warm` passes), the time of each
-- part (the barrier to barrier time, and the slowest worker's own); 0 workers is this state
function Bm.scale(counts, reps, warm)
    S.attach()
    E, BL = S.E, S.B
    Bm.setup()
    Bm.full()
    Bm.inputs()
    Bm.pass(false, true)
    local lines = {}
    -- the countries' costs in part a, this state (a profile of the balance)
    do
        S.H.counters[2] = 0
        X.begin()
        local costs = {}
        for _, cid in ipairs(O.ids("country")) do
            local t0 = RUST.clock()
            X.part_a(cid, true)
            costs[#costs + 1] = { cid, RUST.clock() - t0 }
        end
        table.sort(costs, function(a, b) return a[2] > b[2] end)
        local total = 0
        for _, c in ipairs(costs) do total = total + c[2] end
        local top = {}
        for i = 1, math.min(8, #costs) do top[i] = string.format("%d %.2f", costs[i][1], costs[i][2] * 1000) end
        lines[#lines + 1] = string.format("part a by country (ms), this state: %.1f in all, the largest: %s", total * 1000, table.concat(top, ", "))
    end
    for _, n in ipairs(counts) do
        if n > 0 then
            RUST.pool_start(n)
        else
            RUST.pool_stop()
        end
        POOL = n
        for _ = 1, warm or 5 do Bm.pass(true, true) end
        Bm.stats.prof = {}
        local sums = { a = {}, b = {}, c = {}, total = {}, wa = {}, wb = {}, wc = {}, setup = {}, cpu = {} }
        for _ = 1, reps do
            local p0 = { a = Bm.stats.parts.a, b = Bm.stats.parts.b, c = Bm.stats.parts.c }
            local t0 = RUST.clock()
            local out = Bm.pass(true, true)
            local dt = RUST.clock() - t0
            sums.total[#sums.total + 1] = dt
            sums.setup[#sums.setup + 1] = out.setup or 0
            local cpu = 0
            for _, c in pairs(out.costs) do cpu = cpu + c end
            sums.cpu[#sums.cpu + 1] = cpu
            for _, p in ipairs({ "a", "b", "c" }) do
                sums[p][#sums[p] + 1] = Bm.stats.parts[p] - p0[p]
                sums["w" .. p][#sums["w" .. p] + 1] = out.times[p] or 0
            end
        end
        local function median(t)
            table.sort(t)
            return t[math.floor((#t + 1) / 2)] * 1000
        end
        if os.getenv("STELLAR_STORE_PROF") then
            local l = {}
            for name, p in pairs(Bm.stats.prof) do l[#l + 1] = string.format("%s %.2f", name, p.sum * 1000 / reps) end
            table.sort(l)
            lines[#lines + 1] = "  prof (ms a pass, summed over the workers): " .. table.concat(l, ", ")
        end
        if os.getenv("SCALE_COSTS") then
            local l = {}
            for cid, c in pairs(COSTS) do l[#l + 1] = { cid, c } end
            table.sort(l, function(a, b) return a[1] < b[1] end)
            local parts = {}
            for _, x in ipairs(l) do parts[#parts + 1] = string.format("%d:%.2f", x[1], x[2] * 1000) end
            lines[#lines + 1] = "  costs (ms): " .. table.concat(parts, " ")
        end
        lines[#lines + 1] = string.format("%2d workers: a pass %.1f ms (median of %d): parts a %.1f b %.1f c %.1f; the slowest worker a %.1f b %.1f c %.1f; part a's countries %.1f ms of work, its setup %.2f ms",
            n, median(sums.total), reps, median(sums.a), median(sums.b), median(sums.c), median(sums.wa), median(sums.wb), median(sums.wc),
            median(sums.cpu), median(sums.setup))
    end
    return table.concat(lines, "\n")
end

-- B.read_scale(counts, reps) -> text: pure reads of the store on N workers at once (every fleet's
-- movement_manager.coordinate.origin, reps times each): each worker's time
function Bm.read_scale(counts, reps, job)
    S.attach()
    E, BL = S.E, S.B
    Bm.setup()
    Bm.full()
    local lines = {}
    for _, n in ipairs(counts) do
        RUST.pool_start(n)
        POOL = n
        RUST.pool_run(job or "read_bench", tostring(reps))
        local times = {}
        for _ = 1, 5 do
            local r = RUST.pool_run(job or "read_bench", tostring(reps))
            for _, s in ipairs(r) do times[#times + 1] = tonumber(s:match("^(%S+)")) end
        end
        table.sort(times)
        lines[#lines + 1] = string.format("%2d workers: each worker's %s (ms): min %.1f median %.1f max %.1f",
            n, job or "read_bench", times[1] * 1000, times[math.floor((#times + 1) / 2)] * 1000, times[#times] * 1000)
    end
    return table.concat(lines, "\n")
end

function Bm.check(days, nworkers, mirror)
    local TX = require("engine.exploration")
    S.attach()
    E, BL = S.E, S.B
    Bm.setup()
    if mirror then Bm.sync() else Bm.full() end
    if nworkers and nworkers > 0 and POOL == 0 then
        RUST.pool_start(nworkers)
        POOL = nworkers
    end
    local lines = {}
    local surveys = {}   -- cid -> the store's accumulated { add, remove }
    for day = 0, days do
        -- the table pass (day 0: the load's pass only)
        local t0 = RUST.clock()
        if day == 0 then TX.load_pass() else TX.countries_daily(nil, nil) end
        local t_table = RUST.clock() - t0
        -- the store's
        t0 = RUST.clock()
        Bm.inputs()
        local t_in = RUST.clock() - t0
        t0 = RUST.clock()
        local out = Bm.pass(day > 0, true)
        local t_store = RUST.clock() - t0
        for cid, o in pairs(out.countries) do
            local ns = surveys[cid] or { add = {}, remove = {} }
            for _, v in ipairs(o.add) do ns.add[#ns.add + 1] = v end
            for _, v in ipairs(o.remove) do ns.remove[#ns.remove + 1] = v end
            surveys[cid] = ns
        end
        -- compared
        local same_n, diff_n, bad = 0, 0, {}
        for _, cid in ipairs(world.all("country")) do
            local tc, sc = world.object("country", cid), O.get("country", cid)
            local ok = true
            for _, key in pairs(LISTS) do
                if not same(tnumbers(world.field(tc, key)), store_list(sc, key)) then ok = false bad[#bad + 1] = cid .. ":" .. key end
            end
            local tti = world.field(tc, "terra_incognita")
            local sti = sc and S.blk(sc, "terra_incognita")
            if type(tti) == "table" then
                for _, key in ipairs({ "data", "systems" }) do
                    if not same(tnumbers(world.field(tti, key)), store_list(sti, key)) then ok = false bad[#bad + 1] = cid .. ":ti." .. key end
                end
            end
            local tst = TX.state[cid] and TX.state[cid].surveys or { add = {}, remove = {} }
            local sst = surveys[cid] or { add = {}, remove = {} }
            if not same(tst.add, sst.add) or not same(tst.remove, sst.remove) then ok = false bad[#bad + 1] = cid .. ":surveys" end
            if ok then same_n = same_n + 1 else diff_n = diff_n + 1 end
        end
        lines[#lines + 1] = string.format("day %d: %d countries the same, %d differ%s; engine.exploration %.1f ms, the store's %.1f ms (its inputs %.1f ms; the slowest worker's parts a %.1f b %.1f c %.1f)",
            day, same_n, diff_n, #bad > 0 and (" (" .. table.concat(bad, " ", 1, math.min(#bad, 12)) .. ")") or "",
            t_table * 1000, t_store * 1000, t_in * 1000,
            (out.times.a or 0) * 1000, (out.times.b or 0) * 1000, (out.times.c or 0) * 1000)
        if mirror then Bm.sync() end
    end
    local parts = {}
    for k, v in pairs(IP) do parts[#parts + 1] = string.format("%s %.1f ms", k, v * 1000 / (days + 1)) end
    table.sort(parts)
    lines[#lines + 1] = "inputs a day: " .. table.concat(parts, ", ")
    lines[#lines + 1] = string.format("exploration's own sections (s, all days): %s",
        (function()
            local o = {}
            for k, v in pairs(require("engine.exploration").stats.sections) do o[#o + 1] = string.format("%s %.3f", k, v) end
            table.sort(o)
            return table.concat(o, ", ")
        end)())
    return table.concat(lines, "\n")
end

return Bm
