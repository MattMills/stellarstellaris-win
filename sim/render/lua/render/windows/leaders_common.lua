-- render/windows/leaders_common.lua : leaders as the empire's views show them
-- (docs/windows/empire.md section 3): a leader's data from the save, and its card from a paragon
-- template of interface/paragon_ui_types.gui filled as CParagonPortraitContainer::Update fills
-- it (the government view's ruler, the leaders view's rows and big card, the council's slots).
-- The portraits are 3D (CPortraitObject: the species' portrait mesh): not drawn.

local C = require("render.windows.empire_common")

local L = {}

local PARAGON = "interface/paragon_ui_types.gui"

-- world side ---------------------------------------------------------------------------------

local function world()
    return require("engine.world")
end

-- the council positions (council_positions = { council_positions = { ID = { country type
-- leader } } }), by id
local function council_position(id)
    local w = world()
    -- (a store of its own: council_positions = { council_positions = { ID = ... } })
    local p = w.object("council_positions", id) or w.object("council_positions", tostring(id))
    if type(p) ~= "table" then
        return nil
    end
    return { id = id, type = C.strip(w.field(p, "type")), leader = tonumber(w.field(p, "leader")), country = tonumber(w.field(p, "country")) }
end
L.council_position = council_position

-- a colony's planet (colony = { ID = { carrier = { type = planet reference = PLANET } } }): what a
-- leader's location `type = planet` and a country's capital name (their ids are colonies')
function L.colony_planet(id)
    local w = world()
    local col = id and w.object("colony", id)
    local carrier = col and w.field(col, "carrier")
    local pid = carrier and C.strip(w.field(carrier, "type")) == "planet" and tonumber(w.field(carrier, "reference"))
    return pid and w.object("planet", pid), pid
end

-- a location { type = planet|ship|..., id } and what the card names there
local function location(block)
    local w = world()
    if type(block) ~= "table" then
        return nil
    end
    local galaxy = require("render.galaxy")
    local loc = { type = C.strip(w.field(block, "type")), id = tonumber(w.field(block, "id")) }
    if loc.type == "planet" then
        local p = L.colony_planet(loc.id)
        loc.name = p and galaxy.name_block(w.field(p, "name"))
        loc.class = p and C.strip(w.field(p, "planet_class"))
    elseif loc.type == "ship" then
        local s = w.object("ship", loc.id)
        local fid = s and tonumber(w.field(s, "fleet"))
        local f = fid and w.object("fleet", fid)
        loc.fleet = fid
        loc.name = f and galaxy.name_block(w.field(f, "name"))
    end
    return loc
end

-- leader_data(id, country) -> the leader's card data (plain values)
function L.leader_data(id, country)
    local w = world()
    local l = w.object("leader", id)
    if not l then
        return nil
    end
    local galaxy = require("render.galaxy")
    local name = w.field(l, "name")
    local d = {
        id = id,
        name = galaxy.name_block(w.field(name, "full_names") or name),
        class = C.strip(w.field(l, "class")),
        level = (tonumber(w.field(l, "level")) or 1) + (tonumber(w.field(l, "bonus_skill_level")) or 0),
        age = tonumber(w.field(l, "age")),
        experience = tonumber(w.field(l, "experience")) or 0,
        tier = C.strip(w.field(l, "tier")),
        ethic = C.strip(w.field(l, "ethic")),
        job = C.strip(w.field(l, "job")),
        gender = C.strip(w.field(l, "gender")),
        portrait = C.strip(w.field(l, "portrait")),
        traits = {},
        location = location(w.field(l, "location")),
    }
    for _, t in ipairs(w.fields(l, "traits") or {}) do
        d.traits[#d.traits + 1] = C.strip(type(t) == "table" and t.text or t)
    end
    local cl = w.field(l, "council_location")
    if type(cl) == "table" then
        d.council = council_position(tonumber(w.field(cl, "id")))
    end
    if country then
        d.ruler = tonumber(w.field(country, "ruler")) == id
        if d.ruler then
            -- the ruler's place: the capital (LEADER_RULING "Ruling From $LOCATION$")
            local cap = tonumber(w.field(country, "capital"))
            local p = L.colony_planet(cap)
            d.capital = p and galaxy.name_block(w.field(p, "name"))
            local gov = w.field(country, "government")
            d.government = C.strip(w.field(gov, "type"))
        end
    end
    return d
end

-- species_data(id) -> { id, name, class, portrait, traits }
function L.species_data(id)
    local w = world()
    local s = id and w.object("species", id)
    if not s then
        return nil
    end
    local galaxy = require("render.galaxy")
    local d = {
        id = id,
        name = galaxy.name_block(w.field(s, "name")),
        plural = galaxy.name_block(w.field(s, "plural")),
        adjective = galaxy.name_block(w.field(s, "adjective")),
        class = C.strip(w.field(s, "class")),
        portrait = C.strip(w.field(s, "portrait")),
        traits = {},
    }
    local tb = w.field(s, "traits")
    for _, t in ipairs(w.fields(tb, "trait") or {}) do
        d.traits[#d.traits + 1] = C.strip(type(t) == "table" and t.text or t)
    end
    return d
end

-- front end side -------------------------------------------------------------------------------

-- a leader's name: "%LEADER_2%" is its first and second names (SLeaderName)
function L.name(ctx, n)
    if type(n) == "table" and n.key == "%LEADER_2%" then
        local parts = {}
        for _, v in ipairs(n.vars or {}) do
            parts[#parts + 1] = C.name(ctx, v.value)
        end
        return table.concat(parts, " ")
    end
    return C.name(ctx, n)
end

-- a leader class's definition (common/leader_classes): its icon index (GFX_leader_icons' frame)
function L.class_icon(ctx, class)
    local b = C.defs(ctx, "common/leader_classes")[class or ""]
    return tonumber(b and C.field(b, "icon")) or 1
end

-- a leader tier's index (common/leader_tiers in order: default 1, renowned 2, legendary 3)
function L.tier_index(ctx, tier)
    local i = 0
    for _, k in ipairs(C.def_order(ctx, "common/leader_tiers")) do
        i = i + 1
        if k == tier then
            return i
        end
    end
    return 1
end

-- the layers of a trait's icon (its `icon = { layer = { icon color visible } ... }`, inline
-- scripts expanded): { { sprite, colour } } (layers shown by a trigger left out [I]); a trait
-- with a plain `icon = "GFX_..."` is one layer
local trait_cache = {}
function L.trait_layers(ctx, trait)
    local cached = trait_cache[trait]
    if cached then
        return cached
    end
    local block = C.defs(ctx, "common/traits")[trait]
    local layers = {}
    if block then
        local source = require("stellar.script.source")
        local ok, expanded = pcall(source.expand, ctx.game_dir, block)
        if ok and expanded then
            block = expanded
        end
        local icon = C.raw_field(block, "icon")
        if type(icon) == "table" and icon.text == nil then
            local ok2, ex = pcall(source.expand, ctx.game_dir, icon)
            if ok2 and ex then
                icon = ex
            end
            for _, e in ipairs(icon) do
                if e.op and e.key and e.key.text == "layer" and type(e.value) == "table" and e.value.text == nil then
                    local sprite = C.strip(C.field(e.value, "icon"))
                    if sprite and C.field(e.value, "visible") == nil then
                        layers[#layers + 1] = { sprite = sprite, colour = C.named_colour(ctx, C.strip(C.field(e.value, "color"))) }
                    end
                end
            end
        elseif type(icon) == "string" then
            layers[1] = { sprite = C.strip(icon) }
        end
    end
    trait_cache[trait] = layers
    return layers
end

-- a trait's icon drawn at (x, y), size s x s: its layers one over the other
function L.trait_icon(ctx, b, trait, x, y, s, path)
    for k, layer in ipairs(L.trait_layers(ctx, trait)) do
        local sp = ctx.db.sprites[layer.sprite]
        if sp then
            b:sprite(path .. "/" .. k, layer.sprite, x, y, s, s, layer.colour)
        elseif layer.sprite:find("/", 1, true) then
            b:texture(path .. "/" .. k, layer.sprite, x, y, s, s, layer.colour)
        end
    end
end

-- card(ctx, b, template, rect, leader, opts) -> report: the leader's card (a paragon template)
-- laid out in rect, filled as CParagonPortraitContainer::Update fills it. opts: prefix, hide
-- (more names), actions, selected
function L.card(ctx, b, template, rect, d, opts)
    opts = opts or {}
    local p = (opts.prefix or "") .. "/" .. template .. "/"
    local text, frames, sprites, hide, textures = {}, {}, {}, {}, {}
    for _, n in ipairs(opts.hide or {}) do
        hide[n] = true
    end
    local name = L.name(ctx, d.name)
    text.name_without_title_text = name
    local class_icon = L.class_icon(ctx, d.class)
    frames.leader_type = class_icon
    frames.leader_class_banner = class_icon
    frames.skill_icon = d.level + 1
    frames.leader_rarity_icon = L.tier_index(ctx, d.tier)
    hide.leader_rarity_council = L.tier_index(ctx, d.tier) < 2 or nil
    -- the ruler's title (the government's ruler_title) or the council position's name
    local title
    if d.ruler then
        local g = C.defs(ctx, "common/governments")[d.government or ""]
        local key = g and C.strip(C.field(g, d.gender == "female" and "ruler_title_female" or "ruler_title"))
        title = key and C.loc(ctx, key)
        text.name_with_title_text = title and C.raw(ctx, "NAME_WITH_TITLE_FORMAT"):gsub("%$TITLE%$", (title:gsub("%%", "%%%%"))):gsub("%$NAME%$", (name:gsub("%%", "%%%%"))) or name
        sprites.council_position_icon = "GFX_icon_councilor_ruler"
    else
        text.name_with_title_text = name
        hide.ruler_icon = true
    end
    if d.council and d.council.type then
        title = title or C.loc(ctx, d.council.type)
        if not d.ruler then
            local cdef = C.defs(ctx, "common/governments/councilors")[d.council.type]
            local icon = cdef and C.strip(C.field(cdef, "icon"))
            if icon then
                sprites.council_position_icon = icon
            end
        end
    end
    if title then
        text.councilor_title = title
        hide.leader_class_text = true
    else
        hide.council_container = true
        text.leader_class_text = d.class or ""
    end
    -- what the leader does (CLeader::BuildActivityString, CFleet::BuildOrdersString) and where
    local loc = d.location
    if d.ruler then
        text.activity_text = C.raw(ctx, "LEADER_RULING"):gsub("%$LOCATION|?H?%$", "§H" .. C.name(ctx, d.capital):gsub("%%", "%%%%") .. "§!")
        hide.location_text = true
        hide.location_primary_icon = true
    elseif loc and loc.type == "planet" then
        text.activity_text = C.raw(ctx, "LEADER_GOVERNING_PLANET"):gsub("%$LOCATION|?H?%$", "§H" .. C.name(ctx, loc.name):gsub("%%", "%%%%") .. "§!")
        text.location_text = "§Y" .. C.name(ctx, loc.name) .. "§!"
        if loc.class then
            -- the planet class's icon (CPlanetClass::GetIcon: common/planet_classes `icon`)
            local pc = C.defs(ctx, "common/planet_classes")[loc.class]
            sprites.location_primary_icon = pc and C.field(pc, "icon") or ("GFX_planet_type_" .. loc.class:gsub("^pc_", ""))
        end
    elseif loc and loc.type == "ship" and loc.name then
        text.activity_text = "NO_ORDERS"
        text.location_text = "§Y" .. C.name(ctx, loc.name) .. "§!"
        sprites.location_primary_icon = "GFX_fleet_status_icon"
        -- (CFleet::GetFleetStatusIconFrame: 3, the fleet in orbit with no orders [I])
        frames.location_primary_icon = 3
    else
        hide.location_text = true
        hide.location_primary_icon = true
        text.activity_text = ""
    end
    -- age (LEADER_AGE_PORTRAIT) and upkeep (the class's unity upkeep: 2 x skill [I])
    if d.age then
        text.age_text = C.raw(ctx, "LEADER_AGE_PORTRAIT"):gsub("%$AGE|?Y?%$", "§Y" .. d.age .. "§!")
    end
    text.upkeep_text = string.format("£unity£%.1f", 2 * d.level)
    if d.ethic then
        sprites.ethic_icon = "GFX_ethic"
        textures.ethic_icon = "gfx/interface/icons/ethics/" .. d.ethic .. ".dds"
        sprites.ethic_icon = "GFX_ethic"
        textures.ethic_icon = "gfx/interface/icons/ethics/" .. d.ethic .. ".dds"
    else
        hide.ethic_icon = true
    end
    -- the portrait is 3D (not drawn); the pool's and the status's parts as the leader is owned
    hide.character_portrait = true
    hide.location_secondary_button = true
    hide.in_player_pool_container = not opts.pool or nil
    -- its status: assigned (the ruler, a councillor, a place), idle, or in the pool
    local busy = d.ruler or d.council ~= nil or d.location ~= nil
    hide.busy_container = (opts.pool or not busy) or nil
    hide.available_container = (opts.pool or busy) or nil
    hide.external_leader_flag_button = true
    hide.leader_subclass_text = true
    hide.leader_rarity_text = true
    hide.faction_support_text = true
    hide.home_planet_icon = true
    hide.experience_bar = true
    for k, v in pairs(opts.text or {}) do
        text[k:match("([^/]+)$")] = v
    end
    local r = b:add_named(PARAGON, template, {
        prefix = opts.prefix, parent = { x = rect.x, y = rect.y, w = rect.w, h = rect.h },
        hide = hide, actions = opts.actions,
        named = { text = text, frames = frames, sprites = sprites, textures = textures },
    })
    -- the traits in their overlapping box (CLeaderTraitListboxEntry: the trait's layered icon)
    local box
    for path, rr in pairs(r.rects) do
        if path:match("/traits_overlapping_box$") then
            box = rr
        end
    end
    if box and #d.traits > 0 then
        local s = math.min(box.h, 32)
        C.overlap(b, box, #d.traits, s, 2, function(i, x, y)
            L.trait_icon(ctx, b, d.traits[i], x, y, s, p .. "traits/" .. i)
        end)
    end
    return r
end

return L
