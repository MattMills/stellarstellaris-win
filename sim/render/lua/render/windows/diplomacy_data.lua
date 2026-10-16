-- render/windows/diplomacy_data.lua : what the diplomacy windows show of the world (engine.world:
-- a save's gamestate, or the simulation's), read where the world is (the save's runtime, or the
-- simulation's thread when it takes a snapshot) and carried to the front end's runtime as a Lua
-- chunk (render.windows.diplomacy lays the windows out from it). docs/windows/diplomacy.md.
--
--   local data = require("render.windows.diplomacy_data")
--   local chunk = data.extract(game_dir, player, add_country)   -- "return { ... }"
--   local t = data.load(chunk)                                   -- the table again
--
-- The table:
--   player             the player's country id (-1: none)
--   date               the world's date ("2212.07.01")
--   countries = { [id] = {
--       id, type, name (a name block, render.names), adjective (name block), government,
--       authority, civics = { }, ethics = { }, personality, origin, species = { name (block),
--       class, portrait }, ruler (leader id), capital (planet id), capital_system,
--       military_power, economy_power, tech_power, fleet_size, empire_size, pops, victory_rank,
--       federation (id), overlord (id), subjects = { }, at_war (bool), first_contact (bool:
--       the player's first contact with it in progress), ai (bool), flag (bool: it has one),
--   } }
--   order = { ids in the world's order }
--   relations = { [id] = the player's relation to id: { contact, communications, borders,
--       closed_borders, trust, threat, border_range, opinion_current, modifiers = { { key,
--       value } }, flags = { name = true } (ERelationFlags as the save writes them), truce,
--       wars = { }, pre_communications_name (block), envoys_positive, envoys_negative,
--       rival_date } }
--   their = { [id] = id's relation to the player (the same fields) }
--   opinion = { [id] = { of_us = their opinion of the player, ours = the player's of them } }
--                       (engine.ai.opinion; absent when it cannot be computed: a world without
--                       the game's definitions)
--   attitude = { [id] = their AI's attitude towards the player ("null": none) }
--   intel = { [id] = the player's intel level on id (intel_manager) }
--   federations = { [id] = { name (block), type, leader, members = { }, associates = { },
--       cohesion, experience, laws = { category = law }, president } }
--   wars = { [id] = { name (block), attackers = { }, defenders = { }, war_goal, start_date,
--       attacker_war_exhaustion, defender_war_exhaustion } }
--   community = { members = { }, council = { }, leader, formed (bool), election }

local world = require("engine.world")

local data = {}

local NONE = 4294967295

local function ref(v)
    v = tonumber(v)
    if v == nil or v == NONE then
        return nil
    end
    return v
end

local function text(v)
    if v == nil then
        return nil
    end
    return (tostring(v):gsub('"', ""))
end

local function ids(block)
    local out = {}
    for _, v in ipairs(world.list(type(block) == "table" and block or nil)) do
        local id = ref(v)
        if id then
            out[#out + 1] = id
        end
    end
    return out
end

local function texts(block)
    local out = {}
    for _, v in ipairs(world.list(type(block) == "table" and block or nil)) do
        out[#out + 1] = text(v)
    end
    return out
end

-- a name block as plain tables (render.galaxy.name_block)
local function name_block(b)
    return require("render.galaxy").name_block(b)
end

-- ERelationFlags as the save writes them (engine.diplomacy.FLAG_BITS)
local FLAGS = {
    "hostile", "neutral", "friendly", "communications", "borders", "defensive_pact", "alliance",
    "subject", "guarantee", "support_independence", "non_aggression_pledge", "commercial_pact",
    "research_agreement", "migration_access", "is_rival", "closed_borders", "contact", "embassy",
    "secret_fealty", "acquainted_with", "has_pre_ftl_trade", "waystation_pact",
}

local function relation(r)
    if type(r) ~= "table" then
        return nil
    end
    local out = {
        trust = tonumber(world.field(r, "trust")) or 0,
        threat = tonumber(world.field(r, "threat")) or 0,
        border_range = tonumber(world.field(r, "border_range")) or 0,
        shared_rivals = tonumber(world.field(r, "shared_rivals")) or 0,
        favors = tonumber(world.field(r, "favors")) or 0,
        opinion_current = tonumber(world.field(r, "relation_current")),
        opinion_last_month = tonumber(world.field(r, "relation_last_month")),
        truce = ref(world.field(r, "truce")),
        wars = ids(world.field(r, "wars")),
        envoys_positive = tonumber(world.field(r, "envoy_opinion_positive")),
        envoys_negative = tonumber(world.field(r, "envoy_opinion_negative")),
        rival_date = text(world.field(r, "rival_date")),
        pre_communications_name = name_block(world.field(r, "pre_communications_name")),
        modifiers = {},
        flags = {},
    }
    for _, f in ipairs(FLAGS) do
        if world.field(r, f) == "yes" then
            out.flags[f] = true
        end
    end
    out.contact = out.flags.contact or false
    out.communications = out.flags.communications or false
    for _, m in ipairs(world.fields(r, "modifier")) do
        if type(m) == "table" then
            out.modifiers[#out.modifiers + 1] = {
                key = text(world.field(m, "modifier")),
                value = tonumber(world.field(m, "value")) or 0,
                decay = world.field(m, "decay") == "yes" or nil,
                start = text(world.field(m, "start_date")),
            }
        end
    end
    return out
end

local function relations_of(c)
    local by = {}
    local rm = c and world.field(c, "relations_manager")
    for _, r in ipairs(type(rm) == "table" and world.fields(rm, "relation") or {}) do
        local other = type(r) == "table" and ref(world.field(r, "country"))
        if other then
            by[other] = r
        end
    end
    return by
end

local function top_block(key)
    for _, e in ipairs(world.tree or {}) do
        if e.op and e.key and e.key.text == key and e.value.text == nil then
            return e.value
        end
    end
    return nil
end

-- data.extract(game_dir, player, add_country) -> the chunk; add_country(id) gives the galaxy's
-- country (its flag) to each country the windows list
function data.extract(game_dir, player, add_country)
    local t0 = RUST and RUST.clock and RUST.clock() or os.clock()
    local out = {
        player = player or -1,
        date = text(world.meta and world.meta.date) or "",
        countries = {}, order = {}, relations = {}, their = {}, opinion = {}, attitude = {},
        intel = {}, federations = {}, wars = {}, community = nil,
    }
    local pc = player and player >= 0 and world.object("country", player) or nil
    local ours = relations_of(pc)
    -- the human players' names (`player = { { name country } }`: "Played By: $PLAYER$")
    out.player_names = {}
    local pl = world.meta and world.meta.player
    for _, b in ipairs(type(pl) == "table" and world.blocks(pl) or {}) do
        local c = ref(world.field(b, "country"))
        if c then
            out.player_names[c] = text(world.field(b, "name")) or ""
        end
    end

    -- the player's intel (intel_manager = { intel = { { ID { intel = N } } ... } }: each pair
    -- reads as the statement `ID = { ... }`)
    local im = pc and world.path(pc, "intel_manager", "intel")
    for _, pair in ipairs(world.blocks(im)) do
        for k, b in world.statements(pair) do
            local id = ref(k)
            if id and type(b) == "table" then
                out.intel[id] = tonumber(world.field(b, "intel")) or 0
            end
        end
    end

    local ok_op, opinion = pcall(require, "engine.ai.opinion")
    local ok_d, D = pcall(require, "engine.diplomacy")

    for _, id in ipairs(world.all("country")) do
        local c = world.object("country", id)
        if c then
            local gov = world.field(c, "government")
            local sp = ref(world.field(c, "founder_species_ref"))
            local spo = sp and world.object("species", sp)
            local e = {
                id = id,
                type = text(world.field(c, "type")) or "",
                name = name_block(world.field(c, "name")),
                adjective = name_block(world.field(c, "adjective")),
                government = text(type(gov) == "table" and world.field(gov, "type")) or "",
                authority = text(type(gov) == "table" and world.field(gov, "authority")) or "",
                origin = text(type(gov) == "table" and world.field(gov, "origin")),
                civics = texts(type(gov) == "table" and world.field(gov, "civics") or nil),
                ethics = texts(world.path(c, "ethos", "ethics")),
                personality = text(world.field(c, "personality")),
                ruler = ref(world.field(c, "ruler")),
                capital = ref(world.field(c, "capital")),
                military_power = tonumber(world.field(c, "military_power")) or 0,
                economy_power = tonumber(world.field(c, "economy_power")) or 0,
                tech_power = tonumber(world.field(c, "tech_power")) or 0,
                fleet_size = tonumber(world.field(c, "fleet_size")) or 0,
                empire_size = tonumber(world.field(c, "empire_size")) or 0,
                pops = tonumber(world.field(c, "num_sapient_pops")) or 0,
                victory_rank = tonumber(world.field(c, "victory_rank")),
                federation = ref(world.field(c, "federation")),
                overlord = ref(world.field(c, "overlord")),
                subjects = ids(world.field(c, "subjects")),
                ai = type(world.field(c, "ai")) == "table",
                planets = #world.list(world.field(c, "owned_planets")),
                flag = type(world.field(c, "flag")) == "table",
            }
            -- the ruler's name (the `leaders` store: name = { full_names = { key } })
            local ok_r, ruler = pcall(world.object, "leaders", e.ruler or -1)
            ruler = ok_r and ruler or nil
            if ruler then
                e.ruler_name = name_block(world.path(ruler, "name", "full_names"))
            end
            if spo then
                e.species = {
                    name = name_block(world.field(spo, "name")),
                    class = text(world.field(spo, "class")),
                    portrait = text(world.field(spo, "portrait")),
                }
            end
            out.countries[id] = e
            out.order[#out.order + 1] = id
            if pc and id ~= player then
                local r = ours[id]
                if r then
                    out.relations[id] = relation(r)
                    out.their[id] = relation(relations_of(c)[player])
                    if add_country and e.flag then
                        add_country(id)
                    end
                    if ok_op then
                        local ok1, of_us = pcall(opinion.of, id, player)
                        local ok2, mine = pcall(opinion.of, player, id)
                        if ok1 or ok2 then
                            out.opinion[id] = { of_us = ok1 and of_us or nil, ours = ok2 and mine or nil }
                        end
                    end
                    if ok_d then
                        local ok3, a = pcall(D.attitude, id, player)
                        out.attitude[id] = ok3 and a or "null"
                    end
                end
            elseif not pc and add_country and e.flag then
                add_country(id)
            end
        end
    end

    for _, fid in ipairs(world.all("federation")) do
        local f = world.object("federation", fid)
        if f then
            local prog = world.field(f, "federation_progression")
            local laws = {}
            local lb = type(prog) == "table" and world.field(prog, "laws")
            for k, v in world.statements(type(lb) == "table" and lb or nil) do
                laws[k] = text(v)
            end
            out.federations[fid] = {
                name = name_block(world.field(f, "name")),
                type = text(type(prog) == "table" and world.field(prog, "federation_type")),
                experience = type(prog) == "table" and tonumber(world.field(prog, "experience")) or 0,
                cohesion = type(prog) == "table" and tonumber(world.field(prog, "cohesion")) or 0,
                leader = ref(world.field(f, "leader")),
                start_date = text(world.field(f, "start_date")),
                members = ids(world.field(f, "members")),
                associates = ids(world.field(f, "associates")),
                laws = laws,
            }
        end
    end

    for _, wid in ipairs(world.all("war")) do
        local w = world.object("war", wid)
        if w then
            local function side(k)
                local s = {}
                for _, p in ipairs(world.blocks(world.field(w, k))) do
                    local cid = ref(world.field(p, "country"))
                    if cid then
                        s[#s + 1] = cid
                    end
                end
                return s
            end
            out.wars[wid] = {
                name = name_block(world.field(w, "name")),
                attackers = side("attackers"), defenders = side("defenders"),
                start_date = text(world.field(w, "start_date")),
                attacker_war_exhaustion = tonumber(world.field(w, "attacker_war_exhaustion")) or 0,
                defender_war_exhaustion = tonumber(world.field(w, "defender_war_exhaustion")) or 0,
            }
        end
    end

    -- a country in any war (CCountry::IsInAnyWar), an attacker in one (IsInOffensiveWar [I])
    for _, w in pairs(out.wars) do
        for _, side in ipairs({ "attackers", "defenders" }) do
            for _, cid in ipairs(w[side]) do
                local c = out.countries[cid]
                if c then
                    c.at_war = true
                    c.offensive_war = c.offensive_war or side == "attackers"
                end
            end
        end
    end

    local gc = top_block("galactic_community")
    if gc then
        out.community = {
            members = ids(world.field(gc, "members")),
            council = ids(world.field(gc, "council")),
            leader = ref(world.field(gc, "leader")),
            formed = world.field(gc, "community_formed") ~= nil,
            election = tonumber(world.field(gc, "election")),
        }
    end

    out.ms = math.floor(((RUST and RUST.clock and RUST.clock() or os.clock()) - t0) * 1000 + 0.5)
    return data.serialize(out)
end

-- a table of strings, numbers, booleans and tables as a Lua chunk ("return { ... }")
function data.serialize(v)
    local parts = {}
    local function put(x)
        local t = type(x)
        if t == "table" then
            parts[#parts + 1] = "{"
            local n = #x
            for i = 1, n do
                put(x[i])
                parts[#parts + 1] = ","
            end
            for k, y in pairs(x) do
                if not (type(k) == "number" and k >= 1 and k <= n and k % 1 == 0) then
                    if type(k) == "number" then
                        parts[#parts + 1] = "[" .. string.format("%.17g", k) .. "]="
                    else
                        parts[#parts + 1] = "[" .. string.format("%q", tostring(k)) .. "]="
                    end
                    put(y)
                    parts[#parts + 1] = ","
                end
            end
            parts[#parts + 1] = "}"
        elseif t == "number" then
            parts[#parts + 1] = string.format("%.17g", x)
        elseif t == "boolean" then
            parts[#parts + 1] = x and "true" or "false"
        elseif t == "string" then
            parts[#parts + 1] = string.format("%q", x)
        else
            parts[#parts + 1] = "nil"
        end
    end
    put(v)
    return "return " .. table.concat(parts)
end

-- the chunk again as a table (cached by the chunk: the front end lays the windows out often)
local cache_chunk, cache_table
function data.load(chunk)
    if chunk == nil or chunk == "" then
        return nil
    end
    if chunk ~= cache_chunk then
        local f = assert((loadstring or load)(chunk, "=diplomacy_data"))
        cache_table = f()
        cache_chunk = chunk
    end
    return cache_table
end

return data
