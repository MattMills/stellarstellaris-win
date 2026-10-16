-- render/galaxy.lua : the galaxy map of the world (engine.world, a save's gamestate) and the game
-- files it is drawn with: every system's position, star class and star sprite, its hyperlanes,
-- the country that owns it and that country's colours; the map's settings from common/defines.
-- Read by the renderer (sim/render/src/galaxy.rs) after Runtime::load_world.
--
--   local galaxy = require("render.galaxy")
--   return galaxy.extract(game_dir)   -- a table, see galaxy.extract
--
-- Where these are:
-- - position: galactic_object[id].coordinate = { x = .. y = .. } (map units, the centre 0,0);
-- - star class: galactic_object[id].star_class ("sc_g"); common/star_classes gives its class
--   ("g_star") and icon_scale; the galaxy map draws gfx/map/star_classes/<class>.dds (the engine
--   names the file: no .gfx lists these), or <star class>.dds where there is one (sc_m_giant);
-- - hyperlanes: galactic_object[id].hyperlane = { { to = id length = n } ... }, on both ends;
-- - owner: world.system_owner (its starbase's owner, see engine/world.lua);
-- - colours: country.flag.colors = { "teal" "dark_teal" ... }; the map draws the first as the
--   border's edge and the second as its fill, each with the `map` swatch of flags/colors.txt
--   (common/named_colors where that has none);
-- - settings: common/defines NGraphics (HYPERLANE_DEFAULT_COLOR, GALAXY_STAR_ICON_SCALE,
--   BORDER_SYSTEM_RADIUS, BORDER_HYPERLANE_THICKNESS, BORDER_TEXTURE_SIZE, GALAXY_DUST_SIZE,
--   GALAXY_DUST_SIZE_EXTRA).

local world = require("engine.world")
local source = require("stellar.script.source")

local galaxy = {}

local function field(block, key)
    for _, e in ipairs(block or {}) do
        if e.op and e.key and e.key.text == key then
            return e.value.text or e.value
        end
    end
    return nil
end

local function hsv_to_rgb(h, s, v)
    h = (h % 1) * 6
    local i = math.floor(h)
    local f = h - i
    local p, q, t = v * (1 - s), v * (1 - s * f), v * (1 - s * (1 - f))
    if i == 0 then
        return v, t, p
    elseif i == 1 then
        return q, v, p
    elseif i == 2 then
        return p, v, t
    elseif i == 3 then
        return p, q, v
    elseif i == 4 then
        return t, p, v
    end
    return v, p, q
end

-- the numbers of a block
local function numbers(block)
    local n, decimal = {}, false
    for _, e in ipairs(type(block) == "table" and block or {}) do
        if e.text then
            n[#n + 1] = tonumber(e.text)
            decimal = decimal or e.text:find(".", 1, true) ~= nil
        end
    end
    return n, decimal
end

-- a colour block (`{ r g b a }` or `rgb { r g b }` in 0..255, `{ 0.5 0.2 0.1 }` in 0..1,
-- `hsv { h s v }`, `hsv360 { h s v }`) -> r, g, b in 0..1, or nil
local function colour(block)
    if type(block) ~= "table" then
        return nil
    end
    local n, decimal = numbers(block)
    if #n < 3 or not (n[1] and n[2] and n[3]) then
        return nil
    end
    if block.type == "hsv" then
        return hsv_to_rgb(n[1], n[2], n[3])
    elseif block.type == "hsv360" then
        return hsv_to_rgb(n[1] / 360, n[2] / 100, n[3] / 100)
    elseif decimal and n[1] <= 1 and n[2] <= 1 and n[3] <= 1 then
        return n[1], n[2], n[3]
    end
    return n[1] / 255, n[2] / 255, n[3] / 255
end

local function exists(path)
    local f = io.open(path, "rb")
    if f then
        f:close()
        return true
    end
    return false
end

-- name -> { r, g, b }: the `map` swatches of flags/colors.txt (and the `flag` swatches)
local function map_swatches(game_dir)
    local out, flag = {}, {}
    local tree = source.parse(game_dir, "flags/colors.txt")
    local colors = tree and field(tree, "colors")
    for _, e in ipairs(type(colors) == "table" and colors or {}) do
        if e.op and e.key and type(e.value) == "table" then
            local r, g, b = colour(field(e.value, "map"))
            if r then
                out[e.key.text] = { r, g, b }
            end
            local fr, fg, fb = colour(field(e.value, "flag"))
            if fr then
                flag[e.key.text] = { fr, fg, fb }
            end
        end
    end
    return out, flag
end

-- the defines of common/defines: namespace -> KEY -> value (a token's text or a block), files in
-- name order, a later value replacing an earlier one
local function defines(game_dir)
    local out = {}
    for _, f in ipairs(source.files(game_dir, "common/defines", "txt")) do
        local tree = source.parse(game_dir, f)
        for _, top in ipairs(tree or {}) do
            if top.op and top.key and type(top.value) == "table" then
                local ns = out[top.key.text] or {}
                out[top.key.text] = ns
                for _, e in ipairs(top.value) do
                    if e.op and e.key then
                        ns[e.key.text] = e.value.text or e.value
                    end
                end
            end
        end
    end
    return out
end

-- galaxy.extract(game_dir) -> {
--   date, notes,
--   systems = { { id, x, y, owner (country id or -1), star_class, class, texture, icon_scale } },
--   lanes = { { a, b } }      (indices into systems, 1-based, each lane once),
--   countries = { { id, name, kind, colours = { name1, name2 }, primary = {r,g,b},
--                   secondary = {r,g,b}, source } }   (the owners of systems),
--   hyperlane_colour = { r, g, b, a }, star_icon_scale, border_system_radius,
--   border_hyperlane_thickness }
function galaxy.extract(game_dir)
    local t0 = RUST.clock()
    local swatches, flag_swatches = map_swatches(game_dir)
    local named = source.definitions(game_dir, "common/named_colors")
    local classes = source.definitions(game_dir, "common/star_classes")
    local def = defines(game_dir)
    local ng = def.NGraphics or {}

    local function resolve(name)
        local s = swatches[name]
        if s then
            return { s[1], s[2], s[3] }, "map"
        end
        local d = named[name]
        if d then
            local r, g, b = colour(field(d.block, "color"))
            if r then
                return { r, g, b }, "named"
            end
        end
        return nil
    end

    -- star class -> { class, texture, icon_scale }
    local star_info, missing_textures = {}, {}
    local function star(key)
        if star_info[key] == nil then
            local d = classes[key]
            local class = d and field(d.block, "class") or key
            local scale = d and tonumber(field(d.block, "icon_scale")) or 1
            -- the sprite: the class's `icon`, by default its `class` (CGalaxyGraphics::Init:
            -- sc_m_giant draws m_star.dds), then the key
            local icon = d and field(d.block, "icon") or class
            local texture
            for _, name in ipairs({ icon, class, key }) do
                local rel = "gfx/map/star_classes/" .. name .. ".dds"
                if exists(game_dir .. "/" .. rel) then
                    texture = rel
                    break
                end
            end
            if not texture then
                missing_textures[#missing_textures + 1] = key
            end
            star_info[key] = { class = class, texture = texture or "", icon_scale = scale }
        end
        return star_info[key]
    end

    local systems, index = {}, {}
    for _, id in ipairs(world.all("system")) do
        local obj = world.object("system", id)
        local x = tonumber(world.path(obj, "coordinate", "x"))
        local y = tonumber(world.path(obj, "coordinate", "y"))
        if x and y then
            local sc = tostring(world.field(obj, "star_class") or "sc_g")
            local info = star(sc)
            systems[#systems + 1] = {
                id = id, x = x, y = y, owner = world.system_owner[id] or -1,
                star_class = sc, class = info.class, texture = info.texture, icon_scale = info.icon_scale,
                -- the star's height over the galaxy's plane (the game's world: y = visual_height)
                height = tonumber(world.path(obj, "coordinate", "visual_height")) or 0,
                name = galaxy.name_block(world.field(obj, "name")),
            }
            index[id] = #systems
        end
    end

    local lanes, seen = {}, {}
    for i, s in ipairs(systems) do
        for _, h in ipairs(world.blocks(world.field(world.object("system", s.id), "hyperlane"))) do
            local j = index[tonumber(world.field(h, "to"))]
            if j and j ~= i then
                local a, b = math.min(i, j), math.max(i, j)
                local key = a * 65536 + b
                if not seen[key] then
                    seen[key] = true
                    lanes[#lanes + 1] = { a, b }
                end
            end
        end
    end

    local countries, owners = {}, {}
    local function add_country(o)
        if o >= 0 and not owners[o] then
            owners[o] = true
            local c = world.object("country", o)
            local names = world.list(world.path(c, "flag", "colors"))
            for k, n in ipairs(names) do
                names[k] = tostring(n):gsub('"', "")
            end
            local p, src = resolve(names[1] or "")
            -- the fill: whichever of the second and third colours is further from the first
            -- (CEmpireFlag::GetMapSecondaryColor)
            local q = resolve(names[2] or "")
            local q3 = resolve(names[3] or "")
            if p and q3 and (not q or (q3[1] - p[1]) ^ 2 + (q3[2] - p[2]) ^ 2 + (q3[3] - p[3]) ^ 2 > (q[1] - p[1]) ^ 2 + (q[2] - p[2]) ^ 2 + (q[3] - p[3]) ^ 2) then
                q = q3
            end
            q = q or p
            -- the flag (flag = { icon = { category file } background = { category file } colors
            -- = { names } }): its emblem, background and colours (the `flag` swatches)
            local fl = world.field(c, "flag")
            local function part(k)
                local p = fl and world.field(fl, k)
                if type(p) ~= "table" then
                    return nil
                end
                return {
                    category = tostring(world.field(p, "category") or ""):gsub('"', ""),
                    file = tostring(world.field(p, "file") or ""):gsub('"', ""),
                }
            end
            local fcolours = {}
            for k, n in ipairs(names) do
                fcolours[k] = flag_swatches[n] or { 1, 1, 1 }
            end
            countries[#countries + 1] = {
                flag = fl and { icon = part("icon"), background = part("background"), colours = fcolours } or nil,
                id = o, name = galaxy.name_text(world.field(c, "name")) or ("country " .. o),
                name_block = galaxy.name_block(world.field(c, "name")),
                government = tostring(world.path(c, "government", "type") or ""):gsub('"', ""),
                kind = tostring(world.field(c, "type") or ""),
                colours = { names[1] or "", names[2] or "" },
                primary = p or { 1, 1, 1 }, secondary = q or { 1, 1, 1 }, source = src or "",
            }
        end
    end
    for _, s in ipairs(systems) do
        add_country(s.owner)
    end

    -- fleets: where they are on the map (a fleet's coordinate is in its system's own space,
    -- `origin` the system; between systems the origin is none and the coordinate the galaxy's),
    -- their owner, and where an FTL jump takes them (the path's first node in another system)
    local NONE = 4294967295
    local function system_xy(sid)
        local i = index[sid]
        if i then
            return systems[i].x, systems[i].y
        end
        return nil
    end
    local fleets = {}
    local fleet_owner = world.fleet_owner or {}
    for _, fid in ipairs(world.all("fleet")) do
        local f = world.object("fleet", fid)
        local mm = world.field(f, "movement_manager")
        if type(mm) == "table" then
            local c = world.field(mm, "coordinate")
            local origin = tonumber(world.field(c, "origin")) or NONE
            local x, y = system_xy(origin)
            if not x then
                x, y = tonumber(world.field(c, "x")) or 0, tonumber(world.field(c, "y")) or 0
            end
            local state = tostring(world.field(mm, "state") or "move_idle")
            local owner = fleet_owner[fid] or -1
            add_country(owner)
            local fl = {
                id = fid, owner = owner, x = x, y = y, state = state,
                station = world.path(f, "properties", "station") == "yes",
                ships = #world.list(world.field(f, "ships")),
                military = (tonumber(world.field(f, "military_power")) or 0) > 0,
                military_power = tonumber(world.field(f, "military_power")) or 0,
                name = galaxy.name_block(world.field(f, "name")),
                system = origin ~= NONE and origin or nil,
            }
            if state == "move_galaxy" or state == "move_jump_anim" or state == "move_wind_up" or state == "move_wind_down" then
                for _, n in ipairs(world.fields(world.field(mm, "path") or {}, "node")) do
                    local o = tonumber(world.path(n, "coordinate", "origin"))
                    if o and o ~= origin and system_xy(o) then
                        fl.from_x, fl.from_y = x, y
                        fl.to_x, fl.to_y = system_xy(o)
                        break
                    end
                end
            end
            fleets[#fleets + 1] = fl
        end
    end

    -- nebulae: the save's top-level `nebula = { coordinate name radius galactic_object ... }`
    local nebulae = {}
    for _, e in ipairs(world.tree or {}) do
        if e.op and e.key and e.key.text == "nebula" and type(e.value) == "table" then
            local c = world.field(e.value, "coordinate")
            nebulae[#nebulae + 1] = {
                x = tonumber(world.field(c, "x")) or 0, y = tonumber(world.field(c, "y")) or 0,
                radius = tonumber(world.field(e.value, "radius")) or 30,
                name = tostring(world.path(e.value, "name", "key") or ""),
                -- the systems in it (each gets a dust cloud of the nebula: CGalaxyGraphics::InitNebulas)
                systems = {},
            }
            for _, v in ipairs(world.fields(e.value, "galactic_object")) do
                local n = nebulae[#nebulae]
                n.systems[#n.systems + 1] = tonumber(v)
            end
        end
    end

    -- the player's terra incognita (country.terra_incognita = { size data = { runs } systems }):
    -- run lengths over the size x size bitmap, row by row, the first run unknown (0x00), then
    -- known (0xFF), alternating (CTerraIncognitaMap::WriteMembers)
    local player = 0
    local pl = world.meta and world.meta.player
    if type(pl) == "table" then
        for _, b in ipairs(world.blocks(pl)) do
            player = tonumber(world.field(b, "country")) or player
        end
    end
    local ti
    local pc = world.object("country", player)
    -- the countries the player has communications with (relations_manager.relation =
    -- { country communications = yes }): only their systems get borders and coloured pins
    -- (CBorderShapeCalculator::CalculateOwnerIds: CCountry::ListCommunications plus the player)
    -- the player's capital: its planet (`capital` is a colony id) and system
    local capital
    do
        local cap = pc and tonumber(world.field(pc, "capital"))
        if cap and not world.colony_planet and world.index then
            world.index()
        end
        local pid = cap and (world.colony_planet and world.colony_planet[cap] or cap)
        local p = pid and world.object("planet", pid)
        local sid = p and tonumber(world.path(p, "coordinate", "origin"))
        if sid then
            capital = { planet = pid, system = sid }
        end
    end
    -- the player's planets (the outliner's colonies): `owned_planets` are colony ids
    local planets = {}
    if not world.colony_planet and world.index then
        world.index()
    end
    for _, c in ipairs(pc and world.list(world.field(pc, "owned_planets")) or {}) do
        local pid = world.colony_planet and world.colony_planet[tonumber(c)] or tonumber(c)
        local p = pid and world.object("planet", pid)
        if p then
            planets[#planets + 1] = {
                id = pid, name = galaxy.name_block(world.field(p, "name")),
                class = tostring(world.field(p, "planet_class") or ""):gsub('"', ""),
                system = tonumber(world.path(p, "coordinate", "origin")) or -1,
            }
        end
    end
    -- the player's alerts (CAlertManager::Update; common/alerts.txt: icon, priority), as far as
    -- read: a research area with nothing researched (ShouldShowTechAlert: no `<area>_queue`)
    local alerts = {}
    local alert_defs = {}
    do
        local tree = source.parse(game_dir, "common/alerts.txt")
        local list = tree and field(tree, "alerts")
        for _, e in ipairs(type(list) == "table" and list or {}) do
            if e.op and e.key and type(e.value) == "table" then
                alert_defs[e.key.text] = {
                    icon = tostring(field(e.value, "icon") or ""):gsub('"', ""),
                    priority = tostring(field(e.value, "priority") or "LOW"),
                }
            end
        end
    end
    local ts = pc and world.field(pc, "tech_status")
    if type(ts) == "table" then
        for _, area in ipairs({ "physics", "society", "engineering" }) do
            local q = world.field(ts, area .. "_queue")
            if not (type(q) == "table" and #world.blocks(q) > 0) then
                local key = "alert_" .. area .. "_research"
                local d = alert_defs[key] or {}
                alerts[#alerts + 1] = { key = key, icon = d.icon or "", priority = d.priority or "MEDIUM" }
            end
        end
    end
    -- the outliner's members (COutlinerGroup*: docs/render.md section 12): the player's fleets by
    -- kind (utility: by ship class, then the owned-fleet order; military; the starbases: with a
    -- shipyard module for Shipyards, other upgraded ones for Starbases), its sectors and their
    -- colonies (a sector's systems; the colony's final_designation)
    local outliner, sectors = {}, {}
    if pc then
        local function ship_size(sid)
            local ship = world.object("ship", tonumber(sid))
            local did = ship and tonumber(world.path(ship, "ship_design_implementation", "design"))
            local design = did and world.object("ship_design", did)
            local stage = design and world.blocks(world.field(design, "growth_stages"))[1]
            return stage and tostring(world.field(stage, "ship_size") or ""):gsub('"', "") or ""
        end
        -- the starbases by their station ship
        local starbase_of = {}
        for _, sb in ipairs(world.all("starbase")) do
            local s = world.object("starbase", sb)
            local st = s and tonumber(world.field(s, "station"))
            if st then
                starbase_of[st] = s
            end
        end
        -- EShipClass order of the utility ships (construction before science, the frame's) [I]
        local CLASS = { constructor = 1, science = 2, colonizer = 3 }
        local civilian, military, yards, bases = {}, {}, {}, {}
        local owned = world.blocks(world.path(pc, "fleets_manager", "owned_fleets"))
        for k, o in ipairs(owned) do
            local fid = tonumber(world.field(o, "fleet"))
            local f = fid and world.object("fleet", fid)
            local ships = f and world.list(world.field(f, "ships")) or {}
            if f and #ships > 0 then
                local mm = world.field(f, "movement_manager")
                local origin = tonumber(world.path(mm, "coordinate", "origin")) or -1
                local e = {
                    id = fid, name = galaxy.name_block(world.field(f, "name")), system = origin,
                    power = tonumber(world.field(f, "military_power")) or 0, order = k,
                }
                if world.path(f, "properties", "station") == "yes" then
                    local sb = starbase_of[tonumber(ships[1])]
                    if sb then
                        local level = tostring(world.field(sb, "level") or ""):gsub('"', "")
                        local has_yard = false
                        local mods = world.field(sb, "modules")
                        if type(mods) == "table" then
                            for _, m in ipairs(mods) do
                                if m.value and m.value.text == "shipyard" then
                                    has_yard = true
                                end
                            end
                        end
                        e.sub = tostring(world.field(sb, "type") or ""):gsub('"', "")
                        if has_yard then
                            e.kind = "shipyard"
                            yards[#yards + 1] = e
                        elseif level ~= "starbase_level_outpost" then
                            e.kind = "starbase"
                            bases[#bases + 1] = e
                        end
                    end
                elseif world.field(f, "ship_class") == "shipclass_military" or e.power > 0 then
                    e.kind = "military"
                    military[#military + 1] = e
                else
                    e.kind = "civilian"
                    e.sub = ship_size(ships[1])
                    e.class = CLASS[e.sub] or 9
                    civilian[#civilian + 1] = e
                end
            end
        end
        table.sort(civilian, function(a, b)
            if a.class ~= b.class then
                return a.class < b.class
            end
            return a.order < b.order
        end)
        for _, list in ipairs({ civilian, military, yards, bases }) do
            for _, e in ipairs(list) do
                outliner[#outliner + 1] = e
            end
        end
        for _, sid in ipairs(world.all("sector")) do
            local s = world.object("sector", sid)
            if s and tonumber(world.field(s, "owner")) == player then
                local systems = {}
                for _, v in ipairs(world.list(world.field(s, "systems"))) do
                    systems[tonumber(v)] = true
                end
                -- the capital's system (the map's sector name sits there: GenerateSectorNames):
                -- local_capital is a colony, on a planet
                local lc = tonumber(world.field(s, "local_capital"))
                local cp = lc and world.colony_planet and world.colony_planet[lc]
                local cpo = cp and world.object("planet", cp)
                local capital = cpo and tonumber(world.path(cpo, "coordinate", "origin"))
                sectors[#sectors + 1] = { id = sid, name = galaxy.name_block(world.field(s, "name")), capital = capital }
                for _, p in ipairs(planets) do
                    if systems[p.system] then
                        local col = world.planet_colony and world.planet_colony[p.id]
                        local c = col and world.object("colony", col)
                        outliner[#outliner + 1] = {
                            kind = "planet", id = p.id, name = p.name, system = p.system, sector = sid, power = 0,
                            sub = c and tostring(world.field(c, "final_designation") or ""):gsub('"', "") or "",
                        }
                    end
                end
            end
        end
    end
    if pc then
        local function alert(key, banner)
            local d = alert_defs[key] or {}
            alerts[#alerts + 1] = { key = key, icon = d.icon or "", priority = banner or d.priority or "LOW" }
        end
        -- alert_unlock_tradition (CCountry::CanActivateAnyTradition) [I]: the unity for the next
        -- tradition, (TRADITION_COST_AMOUNTS 300 + (TRADITION_COST_TRADITION 8 x adopted) ^
        -- TRADITION_COST_TRADITION_EXP 1.8) x (1 + EMPIRE_SIZE_TRADITION_COST_PENALTY 0.002 x
        -- empire size); the cost modifiers and the empire size's base not applied
        local adopted = #world.list(world.field(pc, "traditions"))
        local unity = tonumber(world.path(pc, "modules", "standard_economy_module", "resources", "unity")) or 0
        local size = tonumber(world.field(pc, "empire_size")) or 0
        if unity >= (300 + (8 * adopted) ^ 1.8) * (1 + 0.002 * size) then
            alert("alert_unlock_tradition")
        end
        -- alert_first_contact_stage_done: a first contact of the player's (country first_contact
        -- contacts) in progress with its stage's event pending (sorts MEDIUM, its banner LOW)
        for _, cid in ipairs(world.list(world.path(pc, "first_contact", "contacts"))) do
            local c = world.object("first_contact", tonumber(cid))
            local ev = c and world.field(c, "event")
            if c and tonumber(world.field(c, "owner")) == player and world.field(c, "status") == "in_progress"
                and type(ev) == "table" and world.field(ev, "expired") ~= "yes" then
                alert("alert_first_contact_stage_done", "LOW")
                break
            end
        end
        -- alert_council_agenda_ready_for_activation (CGovernment::IsAgendaFinished): the agenda's
        -- progress at its cost (@base_agenda_cost 7000) [I: modifiers to the cost not applied]
        local progress = tonumber(world.path(pc, "government", "council_agenda_progress"))
        if progress and progress >= 7000 then
            alert("alert_council_agenda_ready_for_activation")
        end
    end
    local communications = {}
    local rm = pc and world.field(pc, "relations_manager")
    for _, r in ipairs(rm and world.fields(rm, "relation") or {}) do
        local other = type(r) == "table" and tonumber(world.field(r, "country"))
        if other and world.field(r, "communications") == "yes" then
            communications[#communications + 1] = other
        end
    end
    local tib = pc and world.field(pc, "terra_incognita")
    if type(tib) == "table" then
        local runs = {}
        for _, v in ipairs(world.list(world.field(tib, "data"))) do
            runs[#runs + 1] = tonumber(v) or 0
        end
        local known = {}
        for _, v in ipairs(world.list(world.field(tib, "systems"))) do
            known[#known + 1] = tonumber(v)
        end
        ti = { size = tonumber(world.field(tib, "size")) or 256, runs = runs, systems = known }
    end
    local core_radius
    for _, e in ipairs(world.tree or {}) do
        if e.op and e.key and e.key.text == "galaxy" and type(e.value) == "table" then
            core_radius = tonumber(world.field(e.value, "core_radius"))
        end
    end

    local hl = numbers(ng.HYPERLANE_DEFAULT_COLOR)
    local classes_used = 0
    for _ in pairs(star_info) do
        classes_used = classes_used + 1
    end
    local out = {
        date = (tostring(world.meta.date or ""):gsub('"', "")),
        systems = systems, lanes = lanes, countries = countries, fleets = fleets, nebulae = nebulae,
        hyperlane_colour = #hl >= 4 and hl or { 0, 1, 1, 0.2 },
        star_icon_scale = tonumber(ng.GALAXY_STAR_ICON_SCALE) or 1.5,
        border_system_radius = tonumber(ng.BORDER_SYSTEM_RADIUS) or 35,
        border_hyperlane_thickness = tonumber(ng.BORDER_HYPERLANE_THICKNESS) or 20,
        border_texture_size = tonumber(ng.BORDER_TEXTURE_SIZE) or 2048,
        dust_size = tonumber(ng.GALAXY_DUST_SIZE) or 25,
        dust_size_extra = tonumber(ng.GALAXY_DUST_SIZE_EXTRA) or 35,
        terra_incognita = ti, core_radius = core_radius or 0, player = player,
        communications = pc and communications or nil,
        planets = planets,
        alerts = alerts,
        outliner = outliner, sectors = sectors,
        capital = capital,
    }
    -- what the map labels show (render.windows.mapicons)
    out.mapicons = require("render.windows.mapicons").extract(game_dir, pc and player or nil)
    out.notes = string.format(
        "%d fleets, %d nebulae; " ..
        "%d systems, %d hyperlanes, %d owners; %d star classes used (no texture for: %s); " ..
        "HYPERLANE_DEFAULT_COLOR {%s}, GALAXY_STAR_ICON_SCALE %s, BORDER_SYSTEM_RADIUS %s, " ..
        "BORDER_HYPERLANE_THICKNESS %s; read in %.2f s",
        #fleets, #nebulae, #systems, #lanes, #countries, classes_used, table.concat(missing_textures, " "),
        table.concat(out.hyperlane_colour, " "), out.star_icon_scale, out.border_system_radius,
        out.border_hyperlane_thickness, RUST.clock() - t0)
    return out
end

-- a name block as plain tables, for render.names to localise: { key, literal, vars = { { key,
-- value = <name> } } } (nil without a block)
function galaxy.name_block(block, depth)
    depth = depth or 0
    if type(block) ~= "table" or depth > 8 then
        return nil
    end
    local out = {
        key = tostring(world.field(block, "key") or ""):gsub('"', ""),
        literal = world.field(block, "literal") == "yes",
        vars = {},
    }
    for _, v in ipairs(world.blocks(world.field(block, "variables"))) do
        local value = galaxy.name_block(world.field(v, "value"), depth + 1)
        if value then
            out.vars[#out.vars + 1] = { key = tostring(world.field(v, "key") or ""):gsub('"', ""), value = value }
        end
    end
    return out
end

-- a name block (`name = { key = "%ADJ%" variables = { { key = "1" value = { ... } } } }`) as one
-- line: its keys that are not placeholders, in order (localisation keys, not localised)
function galaxy.name_text(block, depth)
    depth = depth or 0
    if type(block) ~= "table" or depth > 8 then
        return nil
    end
    local key = world.field(block, "key")
    local parts = {}
    if key ~= nil and not tostring(key):match("^%%") then
        parts[#parts + 1] = tostring(key)
    end
    for _, v in ipairs(world.blocks(world.field(block, "variables"))) do
        local t = galaxy.name_text(world.field(v, "value"), depth + 1)
        if t then
            parts[#parts + 1] = t
        end
    end
    if #parts == 0 then
        return key ~= nil and tostring(key) or nil
    end
    return table.concat(parts, " ")
end

return galaxy
