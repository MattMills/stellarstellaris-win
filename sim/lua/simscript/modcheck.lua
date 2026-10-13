-- simscript/modcheck.lua : checks the simulation's model of modifiers against a capture of the
-- game's modifier nodes (every registered NModifierNode of a live game: id, category, owner, the
-- node's final values and its parts, each `multiplier|category_filter|values`).
--
--   1. internal check: does each node equal the sum of its parts (x multiplier / 100000, the
--      part's category filter applied per modifier type)?
--   2. the save: each country's sources (technologies, traditions, perks, government, civics,
--      origin, ethics, policies, edicts, timed modifiers, country type)
--   3. an index of every modifier block of the vanilla script (common/**), by content
--   4. attribution of the country nodes' parts to script sources (or to parent nodes) by content
--   5. each country's expected values from its save sources, diffed with its node
--
-- All values are fixed point, 1.0 = 100000, as the game stores them.

local pdxscript = require("pdxscript")
local source = require("stellar.script.source")
local bit = require("bit")

local M = {}

local LABELS = {
    ["Pops"] = 2, ["Orbital Stations"] = 4, ["Space Stations"] = 8, ["Military Ships"] = 16,
    ["Civilian Ships"] = 32, ["Science Ships"] = 64, ["Fleets"] = 128, ["Countries"] = 256,
    ["Armies"] = 512, ["Leaders"] = 1024, ["Planets"] = 2048, ["Ship Components"] = 4096,
    ["Pop Factions"] = 8192, ["Transport Ships"] = 16384, ["Deposits"] = 32768,
    ["Megastructures"] = 65536, ["Habitability"] = 131072, ["Starbases"] = 262144,
    ["Economic Units"] = 524288, ["Star Systems"] = 1048576, ["Waystations"] = 2097152,
    ["Federations"] = 4194304, ["Espionage"] = 8388608, ["AI Economy"] = 16777216,
    ["Ship Design Stats"] = 33554432, ["Astral Rift"] = 67108864,
    ["Cosmic Storm Influence Field"] = 134217728, ["Owned Ships"] = 268435456,
    ["Galactic Community"] = 536870912, ["Colony"] = 1073741824,
    ["Ships"] = 16508, ["All"] = 0x7FFFFFFF,
}

local function read(path)
    local f, msg = io.open(path, "rb")
    if not f then error("cannot read " .. tostring(path) .. ": " .. tostring(msg)) end
    local t = f:read("*a")
    f:close()
    return t
end

local function unq(s)
    if not s then return s end
    return (s:gsub('^"(.*)"$', "%1"))
end

-- ---------------------------------------------------------------------------------------------
-- modifier types (modifiers.log: line k of the list is type k)

local function load_types(path)
    local types = { names = {}, mask = {}, index = {}, canon = {}, unknown_labels = {} }
    for line in read(path):gmatch("[^\n]+") do
        local name, cats = line:match("^%- ([^,]+), Category: (.-)%s*$")
        if name then
            local m = 0
            for label in (cats .. ","):gmatch("%s*(.-)%s*,") do
                local b = LABELS[label]
                if b then m = bit.bor(m, b) else types.unknown_labels[label] = true end
            end
            types.names[#types.names + 1] = name
            types.index[name] = #types.names - 1
            types.mask[name] = m
            types.canon[name:lower()] = name
        end
    end
    return types
end

-- ---------------------------------------------------------------------------------------------
-- the capture

local function parse_values(s)
    local list, map = {}, {}
    if s and s ~= "" then
        for kv in s:gmatch("[^,]+") do
            local k, v = kv:match("^(.-)=(-?%d+)$")
            if k then
                v = tonumber(v)
                list[#list + 1] = { k, v }
                map[k] = (map[k] or 0) + v
            end
        end
    end
    return list, map
end

local function load_nodes(path)
    local nodes = {}
    local first = true
    for line in read(path):gmatch("[^\n]+") do
        if first then
            first = false
        else
            line = line:gsub("\r$", "")
            -- (newer captures add children, depth and categories after the parts)
            local id, cat, owner, invalid, values, parts = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t?([^\t]*)")
            if id then
                local vlist, vmap = parse_values(values)
                local node = { id = tonumber(id), cat = cat, owner = owner, values = vmap, vlist = vlist, parts = {} }
                if parts and parts ~= "" then
                    for p in parts:gmatch("[^;]+") do
                        local mult, filter, pv = p:match("^(-?%d+)|(-?%d+)|(.*)$")
                        if mult then
                            local plist, pmap = parse_values(pv)
                            node.parts[#node.parts + 1] = { mult = tonumber(mult), filter = tonumber(filter), list = plist, map = pmap }
                        end
                    end
                end
                nodes[#nodes + 1] = node
            end
        end
    end
    return nodes
end

local function scale(v, m)
    if m == 100000 then return v end
    local x = v * m / 100000
    return x >= 0 and math.floor(x) or math.ceil(x) -- toward zero
end

local function passes(types, t, filter)
    if filter == 0 or filter == -1 or filter == 4294967295 then return true end
    local m = types.mask[t]
    if m == nil then return true end
    return bit.band(m, bit.tobit(filter)) ~= 0
end

local function sum_parts(types, node)
    local acc = {}
    for _, p in ipairs(node.parts) do
        for _, kv in ipairs(p.list) do
            if passes(types, kv[1], p.filter) then
                acc[kv[1]] = (acc[kv[1]] or 0) + scale(kv[2], p.mult)
            end
        end
    end
    return acc
end

local function keys_sorted(t)
    local l = {}
    for k in pairs(t) do l[#l + 1] = k end
    table.sort(l)
    return l
end

local function top(t, n, f)
    local l = {}
    for k, v in pairs(t) do l[#l + 1] = { k, v } end
    table.sort(l, function(a, b)
        local x, y = f and f(a[2]) or a[2], f and f(b[2]) or b[2]
        if x ~= y then return x > y end
        return a[1] < b[1]
    end)
    local out = {}
    for i = 1, math.min(n, #l) do out[i] = l[i] end
    return out, #l
end

local function internal_check(types, nodes, out)
    local p = function(...) out[#out + 1] = string.format(...) end
    local with_parts, explained, exact, values_no_parts, empty = 0, 0, 0, 0, 0
    local by_cat = {}
    local missing_types, extra_types = {}, {}
    for _, n in ipairs(nodes) do
        local c = by_cat[n.cat]
        if not c then c = { nodes = 0, with_parts = 0, explained = 0, nparts = 0 }; by_cat[n.cat] = c end
        c.nodes = c.nodes + 1
        c.nparts = c.nparts + #n.parts
        if #n.parts == 0 then
            if next(n.values) then values_no_parts = values_no_parts + 1 else empty = empty + 1 end
        else
            with_parts = with_parts + 1
            c.with_parts = c.with_parts + 1
            local acc = sum_parts(types, n)
            local ok, ex = true, true
            for t, v in pairs(n.values) do
                local a = acc[t] or 0
                if a ~= v then
                    ex = false
                    if math.abs(a - v) > 1 then
                        ok = false
                        local k = n.cat .. " " .. t .. (acc[t] and " (differs)" or " (no part)")
                        missing_types[k] = (missing_types[k] or 0) + 1
                    end
                end
            end
            for t, a in pairs(acc) do
                if n.values[t] == nil and a ~= 0 then
                    ok, ex = false, false
                    local k = n.cat .. " " .. t
                    extra_types[k] = (extra_types[k] or 0) + 1
                end
            end
            if ok then explained = explained + 1; c.explained = c.explained + 1 end
            if ex then exact = exact + 1 end
        end
    end
    p("internal check: %d nodes; %d with parts, %d of them equal to the sum of their parts (%d exactly, the rest within 1 per type); %d with values and no parts; %d empty",
        #nodes, with_parts, explained, exact, values_no_parts, empty)
    p("  by node category (nodes, with parts, explained, parts):")
    for _, cat in ipairs(keys_sorted(by_cat)) do
        local c = by_cat[cat]
        p("    %-28s %6d %6d %6d %7d", cat, c.nodes, c.with_parts, c.explained, c.nparts)
    end
    local l, n = top(missing_types, 15)
    p("  values not explained by the parts: %d (category, type) kinds; most frequent:", n)
    for _, x in ipairs(l) do p("    %6d  %s", x[2], x[1]) end
    l, n = top(extra_types, 10)
    p("  part sums absent from the node: %d kinds; most frequent:", n)
    for _, x in ipairs(l) do p("    %6d  %s", x[2], x[1]) end
end

-- ---------------------------------------------------------------------------------------------
-- the script index: every block of common/** whose entries include modifier types

local function sig_of(list)
    local l = {}
    for _, kv in ipairs(list) do
        if kv[2] ~= 0 then l[#l + 1] = kv[1] .. "=" .. kv[2] end
    end
    table.sort(l)
    return table.concat(l, ",")
end

local function sig_of_map(map)
    local l = {}
    for k, v in pairs(map) do
        if v ~= 0 then l[#l + 1] = k .. "=" .. v end
    end
    table.sort(l)
    return table.concat(l, ",")
end

local function fixed(x)
    local v = x * 100000
    return v >= 0 and math.floor(v + 0.5) or -math.floor(-v + 0.5)
end

local function build_index(game_dir, types)
    local globalvars = {}
    for _, rel in ipairs(RUST.list_files(game_dir, "common/scripted_variables")) do
        local tree = pdxscript.parse(read(game_dir .. "/" .. rel), rel)
        if tree then
            for _, e in ipairs(tree) do
                if e.op and e.key.text:sub(1, 1) == "@" and e.value.text then globalvars[e.key.text:sub(2)] = e.value.text end
            end
        end
    end
    local idx = { by_sig = {}, by_obj = {}, blocks = 0, files = 0, unresolved = 0, expand_errors = {} }
    for _, rel in ipairs(RUST.list_files(game_dir, "common")) do
        if not rel:match("^common/inline_scripts/") and not rel:match("^common/scripted_") then
            local tree = pdxscript.parse(read(game_dir .. "/" .. rel), rel)
            if tree then
                -- inline scripts expanded, as the game reads the file
                tree = source.expand(game_dir, tree, idx.expand_errors, 0, "file: " .. rel)
                idx.files = idx.files + 1
                local kind = rel:gsub("^common/", ""):gsub("/[^/]*$", "")
                local vars = {}
                for _, e in ipairs(tree) do
                    if e.op and e.key.text:sub(1, 1) == "@" and e.value.text then vars[e.key.text:sub(2)] = e.value.text end
                end
                local function num(s, depth)
                    local n = tonumber(s)
                    if n then return n end
                    if s:sub(1, 1) == "@" and (depth or 0) < 5 then
                        local r = vars[s:sub(2)] or globalvars[s:sub(2)]
                        if r then return num(r, (depth or 0) + 1) end
                    end
                    return nil
                end
                local function values_of(b)
                    local list = nil
                    for _, x in ipairs(b) do
                        local cn = x.op == "=" and x.key and x.value and x.value.text and types.canon[x.key.text:lower()]
                        if cn then
                            local v = num(x.value.text)
                            if v then
                                list = list or {}
                                list[#list + 1] = { cn, fixed(v) }
                            else
                                idx.unresolved = idx.unresolved + 1
                            end
                        end
                    end
                    return list
                end
                local function add(name, path, list)
                    local src = { kind = kind, name = name, path = path, list = list, sig = sig_of(list), file = rel }
                    idx.blocks = idx.blocks + 1
                    local s = idx.by_sig[src.sig]
                    if not s then s = {}; idx.by_sig[src.sig] = s end
                    s[#s + 1] = src
                    local o = idx.by_obj[kind]
                    if not o then o = {}; idx.by_obj[kind] = o end
                    local ob = o[name]
                    if not ob then ob = {}; o[name] = ob end
                    ob[#ob + 1] = src
                end
                local function walk(b, name, path, depth)
                    for _, e in ipairs(b) do
                        if e.op and e.key and e.value and e.value.text == nil and depth < 8 then
                            local k = e.key.text
                            if k == "option" then
                                for _, x in ipairs(e.value) do
                                    if x.op and x.key.text == "name" and x.value.text then k = "option:" .. unq(x.value.text) end
                                end
                            end
                            local p = path == "" and k or (path .. "/" .. k)
                            local list = values_of(e.value)
                            if list then add(name, p, list) end
                            walk(e.value, name, p, depth + 1)
                        end
                    end
                end
                for _, e in ipairs(tree) do
                    if e.op and e.key and e.value and e.value.text == nil and e.key.text:sub(1, 1) ~= "@" then
                        local list = values_of(e.value)
                        if list then add(e.key.text, "", list) end -- the object itself (static modifiers)
                        walk(e.value, e.key.text, "", 0)
                    end
                end
            end
        end
    end
    return idx
end

-- the kind of a script source, for reports
local function source_kind(src)
    local k = src.kind
    if k == "governments/civics" then
        return src.name:match("^origin_") and "origin" or "civic"
    end
    return k
end

-- ---------------------------------------------------------------------------------------------
-- the save

local function find(b, key)
    for _, e in ipairs(b) do
        if e.op and e.key and e.key.text == key then return e.value end
    end
end

local function texts(b)
    local l = {}
    if b then
        for _, e in ipairs(b) do
            if e.text then l[#l + 1] = unq(e.text) end
        end
    end
    return l
end

local function load_save(gamestate)
    local tree, msg = pdxscript.parse(gamestate, "gamestate")
    if not tree then error(msg) end
    local save = { countries = {}, country_order = {}, planets = 0 }
    local planets = find(tree, "planets")
    local pl = planets and find(planets, "planet")
    if pl then
        for _, e in ipairs(pl) do if e.op then save.planets = save.planets + 1 end end
    end
    local countries = find(tree, "country")
    for _, e in ipairs(countries or {}) do
        if e.op and e.value and e.value.text == nil then
            local c = { id = e.key.text, src = {} }
            local b = e.value
            local function addsrc(kind, name, mult)
                c.src[#c.src + 1] = { kind = kind, name = name, mult = mult or 1 }
            end
            local ts = find(b, "tech_status")
            if ts then
                local last
                for _, x in ipairs(ts) do
                    if x.op and x.key.text == "technology" then
                        last = unq(x.value.text)
                    elseif x.op and x.key.text == "level" and last then
                        addsrc("technology", last, tonumber(x.value.text) or 1)
                        last = nil
                    end
                end
            end
            for _, t in ipairs(texts(find(b, "traditions"))) do addsrc("traditions", t) end
            for _, t in ipairs(texts(find(b, "ascension_perks"))) do addsrc("ascension_perks", t) end
            local gov = find(b, "government")
            if gov then
                local ty = find(gov, "type")
                if ty and ty.text then addsrc("governments", unq(ty.text)) end
                local au = find(gov, "authority")
                if au and au.text then addsrc("governments/authorities", unq(au.text)); c.authority = unq(au.text) end
                for _, t in ipairs(texts(find(gov, "civics"))) do addsrc("governments/civics", t) end
                local o = find(gov, "origin")
                if o and o.text then addsrc("governments/civics", unq(o.text)) end
            end
            local ethos = find(b, "ethos")
            for _, t in ipairs(texts(ethos and find(ethos, "ethics"))) do addsrc("ethics", t) end
            for _, x in ipairs(find(b, "active_policies") or {}) do
                if not x.op and x.text == nil then
                    local pol, sel = find(x, "policy"), find(x, "selected")
                    if pol and sel then addsrc("policies", unq(pol.text), 1, unq(sel.text)) ; c.src[#c.src].option = unq(sel.text) end
                end
            end
            for _, x in ipairs(find(b, "edicts") or {}) do
                if not x.op and x.text == nil then
                    local ed = find(x, "edict")
                    if ed then addsrc("edicts", unq(ed.text)) end
                end
            end
            local tm = find(b, "timed_modifier")
            for _, x in ipairs(tm and find(tm, "items") or {}) do
                if not x.op and x.text == nil then
                    local m = find(x, "modifier")
                    if m then addsrc("static_modifiers", unq(m.text)) end
                end
            end
            local ru = find(b, "ruler")
            c.ruler = ru and ru.text
            local ty = find(b, "type")
            if ty and ty.text then addsrc("country_types", unq(ty.text)) ; c.type = unq(ty.text) end
            local nm = find(b, "name")
            c.name = nm and (find(nm, "key") or {}).text
            save.countries[c.id] = c
            save.country_order[#save.country_order + 1] = c.id
        end
    end
    -- the player
    for _, x in ipairs(find(tree, "player") or {}) do
        if not x.op and x.text == nil then
            local pc = find(x, "country")
            if pc then save.player = pc.text end
        end
    end
    -- council positions and their leaders (skill, traits): CCountry::CalculateModifier adds each
    -- position's modifier scaled by the councilor's skill, and the councilors' traits
    local leaders = {}
    for _, e in ipairs(find(tree, "leaders") or {}) do
        if e.op and e.value and e.value.text == nil then
            local l = { traits = {}, level = 0 }
            for _, x in ipairs(e.value) do
                if x.op and x.key.text == "traits" and x.value.text then l.traits[#l.traits + 1] = unq(x.value.text)
                elseif x.op and x.key.text == "level" then l.level = l.level + (tonumber(x.value.text) or 0)
                elseif x.op and x.key.text == "bonus_skill_level" then l.level = l.level + (tonumber(x.value.text) or 0) end
            end
            leaders[e.key.text] = l
        end
    end
    -- the static modifiers the engine adds by name (empire_base for every country,
    -- playable_ai_empire for AI empires, fallen_empire_base for fallen empires; others, such as
    -- navy_coverage_shortage or the difficulty modifiers, depend on state not read here)
    for _, id in ipairs(save.country_order) do
        local c = save.countries[id]
        c.src[#c.src + 1] = { kind = "static_modifiers", name = "empire_base", mult = 1, engine = true }
        if c.type == "default" and id ~= save.player then
            c.src[#c.src + 1] = { kind = "static_modifiers", name = "playable_ai_empire", mult = 1, engine = true }
        end
        if c.type == "fallen_empire" then
            c.src[#c.src + 1] = { kind = "static_modifiers", name = "fallen_empire_base", mult = 1, engine = true }
        end
    end
    local cp = find(tree, "council_positions")
    cp = cp and find(cp, "council_positions")
    save.council = 0
    for _, e in ipairs(cp or {}) do
        if e.op and e.value and e.value.text == nil then
            local country, ty, leader = find(e.value, "country"), find(e.value, "type"), find(e.value, "leader")
            local c = country and save.countries[country.text]
            local l = leader and leaders[leader.text]
            if c and ty and l then
                save.council = save.council + 1
                c.src[#c.src + 1] = { kind = "governments/councilors", name = unq(ty.text), mult = l.level }
                if unq(ty.text):match("^councilor_ruler_") then c.has_ruler_position = true end
                for _, t in ipairs(l.traits) do c.src[#c.src + 1] = { kind = "traits", name = t, mult = 1 } end
            end
        end
    end
    -- the ruler: its position (councilor_ruler_<authority>) when the council list does not hold it, and
    -- its traits
    for _, id in ipairs(save.country_order) do
        local c = save.countries[id]
        local l = c.ruler and leaders[c.ruler]
        if l and not c.has_ruler_position then
            if c.authority then
                c.src[#c.src + 1] = { kind = "governments/councilors", name = "councilor_ruler_" .. c.authority:gsub("^auth_", ""), mult = l.level }
            end
            for _, t in ipairs(l.traits) do c.src[#c.src + 1] = { kind = "traits", name = t, mult = 1 } end
        end
    end
    return save
end

-- which blocks of a source feed the country node
local COUNTRY_KEYS = {
    technology = { modifier = true },
    traditions = { modifier = true },
    ascension_perks = { modifier = true },
    ["governments/civics"] = { modifier = true },
    ["governments/authorities"] = { country_modifier = true },
    governments = { modifier = true },
    ethics = { country_modifier = true },
    edicts = { modifier = true },
    static_modifiers = { [""] = true },
    country_types = { modifier = true },
    ["governments/councilors"] = { modifier = true },
    traits = { councilor_modifier = true },
}

-- static modifiers the engine applies to every country by name (CCountry::CalculateModifier)
-- (empire_base for every country, playable_ai_empire for AI empires, fallen_empire_base for fallen
-- empires; others such as navy_coverage_shortage or the difficulty modifiers depend on state)

local function source_blocks(idx, s)
    local objs = idx.by_obj[s.kind]
    local blocks = objs and objs[s.name]
    if not blocks then return nil end
    local out = {}
    for _, b in ipairs(blocks) do
        if s.kind == "policies" then
            if b.path == "option:" .. tostring(s.option) .. "/modifier" then out[#out + 1] = b end
        elseif COUNTRY_KEYS[s.kind] and COUNTRY_KEYS[s.kind][b.path] then
            out[#out + 1] = b
        end
    end
    return out
end

-- ---------------------------------------------------------------------------------------------

function M.run(opts)
    local t0 = RUST.clock()
    local out = {}
    local p = function(...) out[#out + 1] = string.format(...) end
    local types = load_types(opts.types_log)
    local nodes = load_nodes(opts.nodes_tsv)
    local nparts = 0
    for _, n in ipairs(nodes) do nparts = nparts + #n.parts end
    p("capture: %d nodes, %d parts; %d modifier types%s (%.1f s)", #nodes, nparts, #types.names,
        next(types.unknown_labels) and " (unknown category labels: " .. table.concat(keys_sorted(types.unknown_labels), ", ") .. ")" or "",
        RUST.clock() - t0)

    internal_check(types, nodes, out)

    local save = load_save(opts.gamestate)
    local cnodes = {}
    local by_owner = {}
    for _, n in ipairs(nodes) do
        if n.cat == "Country" then
            cnodes[#cnodes + 1] = n
            by_owner[n.owner] = n
        end
    end
    local matched_ids = 0
    for _, id in ipairs(save.country_order) do if by_owner[id] then matched_ids = matched_ids + 1 end end
    local planet_nodes = 0
    for _, n in ipairs(nodes) do if n.cat == "Planet" then planet_nodes = planet_nodes + 1 end end
    p("save: %d countries (%d match a Country node's owner id, of %d nodes), %d planets (%d Planet nodes) (%.1f s)",
        #save.country_order, matched_ids, #cnodes, save.planets, planet_nodes, RUST.clock() - t0)
    p("      %d council positions with their leaders; the player is country %s", save.council or 0, tostring(save.player))

    local idx = build_index(opts.game_dir, types)
    local nsig = 0
    for _ in pairs(idx.by_sig) do nsig = nsig + 1 end
    p("script index: %d modifier blocks in %d files of common/, %d distinct contents, %d values not resolved (%.1f s)",
        idx.blocks, idx.files, nsig, idx.unresolved, RUST.clock() - t0)

    -- parent nodes by content
    local node_sigs = {}
    for _, n in ipairs(nodes) do
        if next(n.values) then
            local s = sig_of_map(n.values)
            node_sigs[s] = node_sigs[s] or n.cat
        end
    end

    -- 4. attribution of the country parts
    local kinds, kinds_save = {}, {}
    local names_by_label = {}
    local unexplained = {}
    local total = 0
    for _, n in ipairs(cnodes) do
        local c = save.countries[n.owner] or { src = {} }
        local have = {}
        for _, s in ipairs(c.src) do have[s.kind .. "|" .. s.name] = true end
        for _, part in ipairs(n.parts) do
            total = total + 1
            local s = sig_of(part.list)
            local cands = idx.by_sig[s]
            local how = "raw"
            if not cands and part.mult ~= 100000 then
                local sl = {}
                for _, kv in ipairs(part.list) do sl[#sl + 1] = { kv[1], scale(kv[2], part.mult) } end
                cands = idx.by_sig[sig_of(sl)]
                how = "scaled"
            end
            local label
            if s == "" then
                label = "(empty part)"
            elseif cands then
                local insave
                for _, src in ipairs(cands) do
                    if have[src.kind .. "|" .. src.name] then insave = src break end
                end
                if insave then
                    label = source_kind(insave)
                    kinds_save[label] = (kinds_save[label] or 0) + 1
                else
                    local ks = {}
                    for _, src in ipairs(cands) do ks[source_kind(src)] = true end
                    local kl = keys_sorted(ks)
                    label = (#kl == 1 and kl[1] or "ambiguous: " .. table.concat(kl, "/")) .. " (not among the save's sources)"
                    local nb = names_by_label[label]
                    if not nb then nb = {}; names_by_label[label] = nb end
                    local src = cands[1]
                    local nm = src.name .. (src.path ~= "" and ("." .. src.path) or "") .. (#cands > 1 and (" +" .. (#cands - 1)) or "")
                    nb[nm] = (nb[nm] or 0) + 1
                end
                if part.mult ~= 100000 then label = label .. " x multiplier" end
            elseif node_sigs[s] then
                label = "parent node " .. node_sigs[s]
            else
                label = "unexplained"
                if #unexplained < 400 then unexplained[#unexplained + 1] = { n = n, part = part } end
            end
            kinds[label] = (kinds[label] or 0) + 1
        end
    end
    p("country parts: %d in %d Country nodes; attributed by content:", total, #cnodes)
    local l = top(kinds, 60)
    for _, x in ipairs(l) do p("  %6d  %5.1f%%  %s", x[2], 100 * x[2] / math.max(1, total), x[1]) end
    p("  sources matched but not among the save's (label: top names):")
    for _, x in ipairs(l) do
        local nb = names_by_label[x[1]:gsub(" x multiplier$", "")]
        if nb and x[2] >= 3 then
            local nl = top(nb, 6)
            local s = {}
            for _, y in ipairs(nl) do s[#s + 1] = y[1] .. " " .. y[2] end
            p("    %s: %s", x[1], table.concat(s, ", "))
        end
    end
    -- samples of unexplained parts, grouped by their first type
    local groups = {}
    for _, u in ipairs(unexplained) do
        local first = u.part.list[1] and u.part.list[1][1] or "?"
        local g = groups[first]
        if not g then g = { count = 0, sample = u }; groups[first] = g end
        g.count = g.count + 1
    end
    p("  unexplained parts by first type (count, multiplier, filter, values):")
    local gl = top(groups, 15, function(g) return g.count end)
    for _, x in ipairs(gl) do
        local u = x[2].sample
        local vals = {}
        for i = 1, math.min(6, #u.part.list) do vals[i] = u.part.list[i][1] .. "=" .. u.part.list[i][2] end
        p("    %4d  x%d  filter %d  %s%s", x[2].count, u.part.mult, u.part.filter, table.concat(vals, ","), #u.part.list > 6 and ",..." or "")
    end

    -- 4b. every node category: parts matched by content to a script block (any object), to a parent
    -- node, or not at all
    p("all node categories: parts matched by content (script block kinds, top 4; parent nodes; unexplained):")
    local cats = {}
    for _, n in ipairs(nodes) do
        if #n.parts > 0 then
            local c = cats[n.cat]
            if not c then c = { parts = 0, script = 0, parent = 0, none = 0, empty = 0, kinds = {} }; cats[n.cat] = c end
            for _, part in ipairs(n.parts) do
                c.parts = c.parts + 1
                local s = sig_of(part.list)
                local cands = idx.by_sig[s]
                if not cands and part.mult ~= 100000 then
                    local sl = {}
                    for _, kv in ipairs(part.list) do sl[#sl + 1] = { kv[1], scale(kv[2], part.mult) } end
                    cands = idx.by_sig[sig_of(sl)]
                end
                if s == "" then
                    c.empty = c.empty + 1
                elseif cands then
                    c.script = c.script + 1
                    local k = source_kind(cands[1])
                    c.kinds[k] = (c.kinds[k] or 0) + 1
                elseif node_sigs[s] then
                    c.parent = c.parent + 1
                else
                    c.none = c.none + 1
                end
            end
        end
    end
    for _, cat in ipairs(keys_sorted(cats)) do
        local c = cats[cat]
        local kl = top(c.kinds, 4)
        local ks = {}
        for _, x in ipairs(kl) do ks[#ks + 1] = x[1] .. " " .. x[2] end
        p("  %-24s %5d parts: script %5d (%5.1f%%) [%s], parent node %4d, empty %4d, unexplained %4d (%5.1f%%)", cat, c.parts,
            c.script, 100 * c.script / c.parts, table.concat(ks, ", "), c.parent, c.empty, c.none, 100 * c.none / c.parts)
    end

    -- 5. expected values from the save's sources
    local types_total, types_match, types_close, countries_exact = 0, 0, 0, 0
    local missing_by_type, extra_by_type, missing_src = {}, {}, {}
    local per_country = {}
    for _, n in ipairs(cnodes) do
        local c = save.countries[n.owner]
        if c then
            local exp = {}
            for _, s in ipairs(c.src) do
                local blocks = source_blocks(idx, s)
                if not blocks then
                    local k = s.kind .. " " .. s.name
                    missing_src[k] = (missing_src[k] or 0) + 1
                else
                    for _, b in ipairs(blocks) do
                        for _, kv in ipairs(b.list) do
                            exp[kv[1]] = (exp[kv[1]] or 0) + kv[2] * ((s.kind == "technology" or s.kind == "governments/councilors") and s.mult or 1)
                        end
                    end
                end
            end
            local all = {}
            for t in pairs(exp) do all[t] = true end
            for t in pairs(n.values) do all[t] = true end
            local m, nt = 0, 0
            for t in pairs(all) do
                local a, b = exp[t] or 0, n.values[t] or 0
                if a ~= 0 or b ~= 0 then
                    nt = nt + 1
                    if a == b then
                        m = m + 1
                    elseif b ~= 0 and math.abs(a - b) <= 1 then
                        m = m + 1
                        types_close = types_close + 1
                    elseif a == 0 then
                        missing_by_type[t] = (missing_by_type[t] or 0) + 1
                    else
                        extra_by_type[t] = (extra_by_type[t] or 0) + 1
                    end
                end
            end
            types_total = types_total + nt
            types_match = types_match + m
            if m == nt then countries_exact = countries_exact + 1 end
            per_country[#per_country + 1] = { id = n.owner, name = c.name, type = c.type, m = m, nt = nt, nsrc = #c.src }
        end
    end
    p("countries: %d of %d (country, type) values match (%.1f%%; %d within 1), %d countries match fully",
        types_match, types_total, 100 * types_match / math.max(1, types_total), types_close, countries_exact)
    for i, pc in ipairs(per_country) do
        if i <= 12 then
            p("  country %-10s %-22s %-18s sources %3d  values %4d of %4d match", pc.id, tostring(pc.name):sub(1, 22), tostring(pc.type), pc.nsrc, pc.m, pc.nt)
        end
    end
    l = top(missing_by_type, 25)
    p("  in the node but not expected from the save's sources (countries, type):")
    for _, x in ipairs(l) do p("    %4d  %s", x[2], x[1]) end
    l = top(extra_by_type, 12)
    p("  expected but different in the node (countries, type):")
    for _, x in ipairs(l) do p("    %4d  %s", x[2], x[1]) end
    l = top(missing_src, 12)
    p("  save sources without a script block for the country: %s", (#l == 0) and "none" or "")
    for _, x in ipairs(l) do p("    %4d  %s", x[2], x[1]) end
    p("done in %.1f s", RUST.clock() - t0)
    return table.concat(out, "\n")
end

return M
