-- engine/savegame.lua : a save as the game writes it (docs/saves.md): the gamestate's text in the
-- game's own layout, the `meta` made from the world, and the head the game checks on a load.
--
--   local savegame = require("engine.savegame")
--   savegame.write(tree)            -- a tree (a gamestate, a meta) as the game lays it out
--   savegame.prepare(state)         -- date, tick, random_seed / random_count set in the world
--   savegame.meta(old_meta_text)    -- the save's `meta` from the world (old: the loaded save's)
--   savegame.report(meta_text)      -- what of a save this build does not read, or reads with doubt
--
-- The layout (read from the game's own saves, 4.5.2 [V]: CPdxScriptWriter output): `key=value`
-- without spaces; a block opens on the next line at its key's indent, its entries one tab in, and
-- closes at the key's indent (`key=\n\t{\n\t}` when empty); a block's unquoted values on one line,
-- each followed by a space (`\t\t4 5 6 7 \n`); quoted values one per line; a run of blocks without
-- keys starts with a line of the indent alone and each ends with a line holding one space; only
-- `random={ a b }` (the AI's generator state) is written inline; a date value gets its indent twice.
-- The game's reader does not care about the layout; written this way a save diffs line for line
-- with the game's. What is left (docs/saves.md: ~0.05% of the lines of a save) is a few member
-- writers' own layouts the tree does not keep: `6 {` without `=` (pdxscript reads it as `6={`),
-- keys at the start of the line, starbase modules on one line.

local pdxscript = require("pdxscript")

local savegame = {}

-- the keys whose value lists the game writes inline: `random={ 0 633261057 }` [V]
local INLINE = { random = true }

-- a date ("2209.04.19", quoted): the game's date writer puts the indent before the value again
-- (`\t\tformed=\t\t"2209.04.19"`; in a list, the first date gets the indent twice) [V the saves];
-- these keys hold a date written as a plain string
local NOT_DATE = { dismantle_finish_date = true }

-- the maps the game writes as pairs, `{ 6 { intel=0 ... } }`: a value at the start of its line, a
-- space after it, then the block without `=` [V the saves: only these two]. pdxscript reads `6 {`
-- as `6={`, and the game does not read `6={` back there: written with `=`, every intel entry was
-- lost (30 days later the game had intel=0.9999 where its own save gave 10 to 29.8)
local PAIRS = { intel = true, federation_intel = true }
local function pair_of(b)
    if #b == 1 and b[1].op and b[1].value.text == nil and not b[1].value.type then return b[1] end
end

-- the lists whose blocks the game separates with an empty line instead (none after the last) [V
-- the saves]
local NO_SPACE = {
    growth_stages = true, pop_groups = true, culling_value = true, completed = true, selected = true,
    wanted_factions = true, society_queue = true, physics_queue = true, engineering_queue = true,
    stage_durations = true, log = true, killed_ship_designs = true,
}
local function is_date(t)
    return t.quoted and t.text:find("^%-?%d+%.%d+%.%d+$") ~= nil
end

local concat = table.concat

local function token_text(t)
    if t.quoted then
        return '"' .. t.text .. '"'
    end
    return t.text
end

local function all_tokens(b)
    for i = 1, #b do
        if b[i].text == nil then
            return false
        end
    end
    return true
end

-- savegame.write(tree) -> text
function savegame.write(tree)
    local out, n = {}, 0
    local function put(s)
        n = n + 1
        out[n] = s
    end
    local entries

    local function block_value(v, indent, key)
        -- (a typed block, `rgb { 1 2 3 }`: the game's saves have none; written as the parser reads it)
        if v.type then
            local parts = {}
            for i = 1, #v do
                parts[i] = token_text(v[i])
            end
            put(v.type .. " { " .. concat(parts, " ") .. " }\n")
            return
        end
        put("\n" .. indent .. "{\n")
        entries(v, indent .. "\t", key)
        put(indent .. "}\n")
    end

    function entries(b, indent, key)
        local line = nil      -- unquoted values waiting for their line
        local prev_anon = false
        for i = 1, #b do
            local e = b[i]
            if e.op then
                if line then put(indent .. concat(line, " ") .. " \n") line = nil end
                local v = e.value
                put(indent .. token_text(e.key) .. e.op)
                if v.text then
                    if indent ~= "" and is_date(v) and not NOT_DATE[e.key.text] then put(indent) end
                    put(token_text(v) .. "\n")
                elseif INLINE[e.key.text] and #v > 0 and all_tokens(v) then
                    local parts = {}
                    for j = 1, #v do
                        parts[j] = token_text(v[j])
                    end
                    put("{ " .. concat(parts, " ") .. " }\n")
                else
                    block_value(v, indent, e.key.text)
                end
                prev_anon = false
            elseif e.param then
                -- (a script's [[param] block: not in a save; kept as the parser reads it)
                if line then put(indent .. concat(line, " ") .. " \n") line = nil end
                put(indent .. "[[" .. (e.negated and "!" or "") .. e.param .. "]\n")
                entries(e, indent .. "\t")
                put(indent .. "]\n")
                prev_anon = false
            elseif e.text then
                if e.quoted then
                    if line then put(indent .. concat(line, " ") .. " \n") line = nil end
                    if i == 1 and is_date(e) then put(indent) end
                    put(indent .. token_text(e) .. "\n")
                else
                    line = line or {}
                    line[#line + 1] = e.text
                end
                prev_anon = false
            else
                if line then put(indent .. concat(line, " ") .. " \n") line = nil end
                if not prev_anon then
                    put(indent .. "\n")
                elseif NO_SPACE[key] then
                    put("\n")
                end
                local pair = PAIRS[key] and pair_of(e)
                if e.type then
                    put(indent)
                    block_value(e, indent, key)
                elseif pair then
                    put(indent .. "{\n" .. token_text(pair.key) .. " \n" .. indent .. "\t{\n")
                    entries(pair.value, indent .. "\t\t", pair.key.text)
                    put(indent .. "\t}\n" .. indent .. "}\n")
                else
                    put(indent .. "{\n")
                    entries(e, indent .. "\t", key)
                    put(indent .. "}\n")
                end
                if not NO_SPACE[key] then put(" \n") end
                prev_anon = true
            end
        end
        if line then put(indent .. concat(line, " ") .. " \n") end
    end

    entries(tree, "")
    return concat(out)
end

-- ---------------------------------------------------------------------------------------------
-- the head the game writes and reads back

local function top_entry(tree, key)
    for _, e in ipairs(tree) do
        if e.op and e.key and e.key.text == key then return e end
    end
end

-- a top-level `key=<token>` set (added after `after`, else at the end, when not there)
local function set_top(tree, key, text, quoted, after)
    local e = top_entry(tree, key)
    if e and e.value.text then
        e.value.text, e.value.quoted = text, quoted or nil
        return
    end
    local new = { key = { text = key }, op = "=", value = { text = text, quoted = quoted or nil } }
    local pos = #tree + 1
    if after then
        for i, x in ipairs(tree) do
            if x.op and x.key and x.key.text == after then pos = i + 1 break end
        end
    end
    table.insert(tree, pos, new)
end

-- a u32 as the game writes an int (random_seed is a CNoiseRandom seed, an unsigned int written
-- signed: -386941723 [V the user's saves])
local function int32_text(v)
    v = v % 4294967296
    if v >= 2147483648 then v = v - 4294967296 end
    return string.format("%d", v)
end
savegame.int32_text = int32_text

-- savegame.prepare(state): the world's head made the state's. state: { date = "2210.02.01",
-- tick = 0..9 (CGameState::_nTickCount), seed, position (the synchronized generator) }. The rest
-- of the head (version, required_dlcs, player) is the loaded save's.
function savegame.prepare(state)
    local world = require("engine.world")
    local tree = world.tree
    if state.date then
        set_top(tree, "date", state.date, true)
        world.meta.date = state.date
    end
    if state.tick then
        set_top(tree, "tick", string.format("%d", state.tick), false, "player")
        world.meta.tick = string.format("%d", state.tick)
    end
    if state.seed then
        set_top(tree, "random_seed", int32_text(state.seed))
        world.meta.random_seed = int32_text(state.seed)
    end
    if state.position then
        set_top(tree, "random_count", int32_text(state.position), false, "random_seed")
        world.meta.random_count = int32_text(state.position)
    end
end

-- ---------------------------------------------------------------------------------------------
-- the meta

-- the player's country id (the gamestate's `player = { { name country } }`), or nil
local function player_country(tree)
    local p = top_entry(tree, "player")
    if not p or p.value.text then return nil end
    for _, item in ipairs(p.value) do
        if not item.op and item.text == nil then
            for _, f in ipairs(item) do
                if f.op and f.key.text == "country" then return tonumber(f.value.text) end
            end
        end
    end
end
savegame.player_country = player_country

local function field(block, key)
    for _, e in ipairs(block or {}) do
        if e.op and e.key and e.key.text == key then return e.value end
    end
end

-- the meta's values from the world: { name, date, version, dlcs, portrait, flag (block),
-- fleets, planets } [I: compared with the game's metas, docs/saves.md]
function savegame.meta_values()
    local world = require("engine.world")
    local tree = world.tree
    local m = {}
    local function head(key)
        local v = field(tree, key)
        return v and v.text
    end
    m.version = head("version")
    m.version_control_revision = head("version_control_revision")
    m.name = head("name")
    m.date = head("date")
    m.dlcs = field(tree, "required_dlcs")
    local id = player_country(tree)
    local c = id and world.object("country", id)
    if c then
        local name = field(c, "name")
        m.flag = field(c, "flag")
        -- CGameState::WriteMembers' meta part (@0x1b08003 [V]): the player's country's species
        -- (+0x153c) portrait, the country's flag (+0x27e0), CCountry::GetFleetSize(true) (a fixed
        -- point: the save's used_naval_capacity) and its planet count (+0x269c: the owned_planets
        -- list's length [I, equal in the user's saves])
        local sp = field(c, "founder_species_ref")
        local species = sp and sp.text and world.object("species", tonumber(sp.text))
        local portrait = species and field(species, "portrait")
        m.portrait = portrait and portrait.text
        local used = field(c, "used_naval_capacity")
        m.fleets = used and used.text and tonumber(used.text) or 0
        local planets = field(c, "owned_planets")
        local np = 0
        for _, e in ipairs(type(planets) == "table" and planets.text == nil and planets or {}) do
            if e.text then np = np + 1 end
        end
        m.planets = np
        m.country_name = name
    end
    return m
end

-- savegame.meta(old) -> the `meta` text: the loaded save's meta (old, when there is one) with the
-- values the world gives set again, in the game's order: version, version_control_revision,
-- name, date, required_dlcs, player_portrait, flag, meta_fleets, meta_planets, then whatever else
-- the old meta had (ironman ...).
function savegame.meta(old)
    local tree = old and old ~= "" and pdxscript.parse(old, "meta") or {}
    local m = savegame.meta_values()
    local ordered = {}
    local function tok(key, text, quoted)
        if text then
            ordered[#ordered + 1] = { key = { text = key }, op = "=", value = { text = text, quoted = quoted or nil } }
        end
    end
    local function blk(key, v)
        if v then
            ordered[#ordered + 1] = { key = { text = key }, op = "=", value = v }
        end
    end
    local function old_value(key)
        local v = field(tree, key)
        return v
    end
    tok("version", m.version or (old_value("version") or {}).text, true)
    tok("version_control_revision", m.version_control_revision or (old_value("version_control_revision") or {}).text)
    tok("name", m.name or (old_value("name") or {}).text, true)
    tok("date", m.date or (old_value("date") or {}).text, true)
    blk("required_dlcs", m.dlcs or old_value("required_dlcs") or {})
    local portrait = m.portrait or (old_value("player_portrait") or {}).text
    tok("player_portrait", portrait, true)
    blk("flag", m.flag or old_value("flag"))
    tok("meta_fleets", m.fleets and require("engine.world").number_text(m.fleets) or (old_value("meta_fleets") or {}).text)
    tok("meta_planets", m.planets and tostring(m.planets) or (old_value("meta_planets") or {}).text)
    local known = { version = 1, version_control_revision = 1, name = 1, date = 1, required_dlcs = 1,
        player_portrait = 1, flag = 1, meta_fleets = 1, meta_planets = 1 }
    for _, e in ipairs(tree) do
        if e.op and e.key and not known[e.key.text] then ordered[#ordered + 1] = e end
    end
    return savegame.write(ordered)
end

-- ---------------------------------------------------------------------------------------------
-- what a save holds that this build does not read

-- the version this build reads (the game's: SSaveGameMetaData::IsBadVersion compares the major
-- and minor numbers) [I]
savegame.VERSION = "Cygnus v4.5.2"

-- savegame.report(meta_text) -> { lines }: the save's version against ours, ironman, the DLCs it
-- needs, and the world's top-level sections no module reads (kept and written back as read)
function savegame.report(meta_text)
    local world = require("engine.world")
    local lines = {}
    local meta = meta_text and meta_text ~= "" and pdxscript.parse(meta_text, "meta") or world.tree or {}
    local version = (field(meta, "version") or {}).text
    if version and version ~= savegame.VERSION then
        local a = version:match("v(%d+%.%d+)")
        local b = savegame.VERSION:match("v(%d+%.%d+)")
        if a ~= b then
            lines[#lines + 1] = string.format("version %s: this build reads %s; the world is read as it is, "
                .. "what changed between them is not converted", version, savegame.VERSION)
        else
            lines[#lines + 1] = string.format("version %s (this build: %s)", version, savegame.VERSION)
        end
    end
    local iron = field(meta, "ironman") or field(world.tree or {}, "ironman")
    if iron and iron.text == "yes" then
        lines[#lines + 1] = "ironman: loaded as a normal game; saves written from it are not ironman saves"
    end
    return lines
end

return savegame
