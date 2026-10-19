-- render/windows/combat.lua : the combat view (interface/combat_view.gui, CCombatView), the
-- window a selected fleet in combat shows instead of the fleet view (CInGameIdler::ShowFleetView:
-- CFleet::HasCombat), filled as the game fills it (4.5.2 Linux; docs/windows/designer.md).
--
--   local combat = require("render.windows.combat")
--   local data = combat.extract(fleet_id)          -- in the runtime with the save's world
--   local items, report = combat.build(ctx, data)   -- in the GUI's runtime
--
-- What it shows (CCombatView::Update 0x2bf3c40) [V]: the selected fleet and every fleet it is in
-- combat with; the sides by a reference country (the controller most aligned with the player,
-- ties to the lower id: [I] the player, then empires, then those hostile to all): the fleets
-- fighting a reference fleet on the right, the others on the left. Each fleet is a
-- combat_view_fleet_entry (its name; the owner's flag, the emergency FTL for the player's) with
-- a combat_view_ship_entry per ship (its name and class, its hull, armor and shield rings, its
-- ship class icon). The bar at the top: the left side's share of the hull points of both,
-- round(100 L / (L + R)) in 1..100. The bottom: the damage each side has dealt to hull, armor and
-- shields and its hit ratio (the fleets' combat stats; "0%" with no shots).

local world = require("engine.world")
local gui = require("render.gui")

local combat = {}

local FILE = "interface/combat_view.gui"

local function str(v)
    return v and tostring(v):gsub('"', "") or nil
end

-- fleet id -> owner country id (the countries' fleets_manager.owned_fleets)
local function fleet_owners()
    local owners = {}
    for _, cid in ipairs(world.all("country")) do
        local c = world.object("country", cid)
        local owned = c and world.path(c, "fleets_manager", "owned_fleets")
        for _, b in ipairs(owned and world.blocks(owned) or {}) do
            local fid = tonumber(world.field(b, "fleet"))
            if fid then
                owners[fid] = tonumber(cid)
            end
        end
    end
    return owners
end

local function player_id()
    for _, b in ipairs(world.blocks(world.meta and world.meta.player)) do
        local c = tonumber(world.field(b, "country"))
        if c then
            return c
        end
    end
    return 0
end

-- the fleets a fleet is in combat with (its combat.in_combat_with), ids
local function enemies(fleet)
    local out = {}
    for _, b in ipairs(world.blocks(world.path(fleet, "combat", "in_combat_with"))) do
        -- the save's id, its generation in the high bits, is the fleet store's key
        local f = tonumber(world.field(b, "fleet"))
        if f then
            out[#out + 1] = f
        end
    end
    return out
end

-- combat.in_combat(fleet_id) -> whether the fleet is in combat (CFleet::HasCombat: [I] its save
-- block has someone in combat.in_combat_with)
function combat.in_combat(fleet_id)
    local f = world.object("fleet", fleet_id)
    return f ~= nil and #enemies(f) > 0
end

-- the first fleet in combat (by id), for `open_designer combat`
function combat.first_in_combat()
    local ids = {}
    for _, fid in ipairs(world.all("fleet")) do
        ids[#ids + 1] = tonumber(fid)
    end
    table.sort(ids)
    for _, fid in ipairs(ids) do
        if combat.in_combat(fid) then
            return fid
        end
    end
    return nil
end

-- the ship size definitions read once (pre_communications_name, the class icon frame, the class)
local sizes_cache
local function sizes(game_dir)
    if not sizes_cache then
        local source = require("stellar.script.source")
        sizes_cache = {}
        for name, d in pairs(source.definitions(game_dir, "common/ship_sizes")) do
            local g = function(k)
                for _, e in ipairs(d.block) do
                    if e.op and e.key and e.key.text == k then
                        return e.value.text
                    end
                end
                return nil
            end
            sizes_cache[name] = {
                pre = str(g("pre_communications_name")),
                frame = tonumber(g("ship_class_icon_frame")),
                class = str(g("class")),
            }
        end
    end
    return sizes_cache
end

local country_types_cache
local function country_types(game_dir)
    if not country_types_cache then
        local source = require("stellar.script.source")
        country_types_cache = {}
        for name, d in pairs(source.definitions(game_dir, "common/country_types")) do
            for _, e in ipairs(d.block) do
                if e.op and e.key and e.key.text == "pre_communications_fleet_name" then
                    country_types_cache[name] = str(e.value.text)
                end
            end
        end
    end
    return country_types_cache
end

-- GetShipClassIconFrameFromSize (docs/render.md section 12): the size's ship_class_icon_frame,
-- else a table by its class [I: the class order]
local CLASS_FRAME = { shipclass_military = 3, shipclass_constructor = 2, shipclass_science_ship = 9, shipclass_colonizer = 15,
    shipclass_starbase = 8, shipclass_mining_station = 7, shipclass_research_station = 9 }

-- combat.extract(game_dir, fleet_id) -> the view's data (a plain table), or nil when the fleet is
-- not in combat
function combat.extract(game_dir, fleet_id)
    local sel = world.object("fleet", fleet_id)
    if not sel or #enemies(sel) == 0 then
        return nil
    end
    local player = player_id()
    local owners = fleet_owners()
    local pc = world.object("country", player)
    -- the player's ethos (NO_COMMUNICATIONS_*_XENOPHOBE) and who it has communications with
    local xenophobe = false
    for _, e in ipairs(world.list(world.path(pc, "ethos", "ethics") or {}) or {}) do
        if str(e):find("xenophobe", 1, true) then
            xenophobe = true
        end
    end
    local comms = { [player] = true }
    for _, r in ipairs(world.fields(world.field(pc, "relations_manager") or {}, "relation")) do
        if world.field(r, "communications") == "yes" then
            comms[tonumber(world.field(r, "country"))] = true
        end
    end
    -- the selected fleet and its enemies, in that order [V]
    local list, seen = { fleet_id }, { [fleet_id] = true }
    for _, e in ipairs(enemies(sel)) do
        if not seen[e] and world.object("fleet", e) then
            seen[e] = true
            list[#list + 1] = e
        end
    end
    -- the reference country [I: the alignment test as player 0, an empire 1, others 2]
    local function rank(c)
        if c == player then
            return 0
        end
        local co = c and world.object("country", c)
        local t = co and str(world.field(co, "type")) or ""
        return (t == "default" or t == "fallen_empire" or t == "awakened_fallen_empire") and 1 or 2
    end
    local ref
    for _, f in ipairs(list) do
        local c = owners[f] or -1
        if ref == nil or rank(c) < rank(ref) or (rank(c) == rank(ref) and c < ref) then
            ref = c
        end
    end
    -- the right: the fleets fighting a reference fleet (IsHostile(ref) [I]); the left: the others
    local ref_fleets = {}
    for _, f in ipairs(list) do
        if owners[f] == ref then
            ref_fleets[f] = true
        end
    end
    local sz, types = sizes(game_dir), country_types(game_dir)
    local data = { player = player, selected = fleet_id, sides = { {}, {} }, hull = { 0, 0 }, hull_max = { 0, 0 } }
    for _, fid in ipairs(list) do
        local f = world.object("fleet", fid)
        local owner = owners[fid] or -1
        local hostile = false
        if owner ~= ref then
            for _, e in ipairs(enemies(f)) do
                hostile = hostile or ref_fleets[e] == true
            end
        end
        local side = hostile and 2 or 1
        local known = comms[owner] == true
        local oc = world.object("country", owner)
        local entry = { id = fid, owner = owner, known = known, own = owner == player, ships = {} }
        -- the days before its emergency FTL (0: now; nil: not at all), the player's fleets'
        if entry.own then
            local okc, ec = pcall(require, "engine.fleets.combat")
            local okd, days = pcall(function() return okc and ec.emergency_ftl_days and ec.emergency_ftl_days(fid) end)
            entry.eftl = okd and days or nil
        end
        -- the owner's flag for a country in contact (ApplyCountryToButton): its flag's parts
        if known and oc then
            local fl = world.field(oc, "flag")
            if type(fl) == "table" then
                local function part(k)
                    local p = world.field(fl, k)
                    return type(p) == "table" and { category = str(world.field(p, "category")), file = str(world.field(p, "file")) } or nil
                end
                local cols = {}
                for _, c in ipairs(world.list(world.field(fl, "colors") or {}) or {}) do
                    cols[#cols + 1] = str(c)
                end
                entry.flag = { icon = part("icon"), background = part("background"), colors = cols }
            end
        end
        -- the name (CFleet::GetLocalNamePersistent 0x292a6d0) [V]
        if known then
            entry.name = require("render.galaxy").name_block(world.field(f, "name"))
        else
            local pre = oc and types[str(world.field(oc, "type")) or ""]
            local station = world.path(f, "properties", "station") == "yes"
            entry.name = { key = pre or (station and "NO_COMMUNICATIONS_STATION") or (xenophobe and "NO_COMMUNICATIONS_FLEET_XENOPHOBE" or "NO_COMMUNICATIONS_FLEET"), vars = {} }
        end
        for _, sid in ipairs(world.list(world.field(f, "ships"))) do
            local s = world.object("ship", tonumber(sid))
            if s then
                local did = tonumber(world.path(s, "ship_design_implementation", "design"))
                local design = did and world.object("ship_design", did)
                local stage = design and world.blocks(world.field(design, "growth_stages"))[1]
                local size = stage and str(world.field(stage, "ship_size")) or ""
                local num = function(k)
                    return tonumber(world.field(s, k)) or 0
                end
                local ship = {
                    id = tonumber(sid),
                    hp = num("hitpoints"), hp_max = num("max_hitpoints"),
                    armor = num("armor_hitpoints"), armor_max = num("max_armor_hitpoints"),
                    shield = num("shield_hitpoints"), shield_max = num("max_shield_hitpoints"),
                    size = size,
                }
                local d = sz[size] or {}
                ship.frame = d.frame or CLASS_FRAME[d.class or ""] or 3
                ship.known = known
                -- the name (CCombatViewShipEntry::UpdateEntry 0x2bfa660) [V]: with communications the
                -- size's name and the ship's, and "<design>-class"; else the size's
                -- pre_communications_name or NO_COMMUNICATIONS_VESSEL(_XENOPHOBE), no class
                if known then
                    ship.name = { key = "%SIZE_AND_NAME%", vars = {
                        { key = "SIZE", value = { key = size, vars = {} } },
                        { key = "NAME", value = require("render.galaxy").name_block(world.field(s, "name")) or { key = "", vars = {} } },
                    } }
                    ship.class = design and require("render.galaxy").name_block(world.field(design, "name")) or nil
                else
                    local station = world.path(f, "properties", "station") == "yes"
                    ship.name = { key = d.pre or (station and "NO_COMMUNICATIONS_STATION") or (xenophobe and "NO_COMMUNICATIONS_VESSEL_XENOPHOBE" or "NO_COMMUNICATIONS_VESSEL"), vars = {} }
                end
                entry.ships[#entry.ships + 1] = ship
                data.hull[side] = data.hull[side] + ship.hp
                data.hull_max[side] = data.hull_max[side] + ship.hp_max
            end
        end
        local t = data.sides[side]
        t[#t + 1] = entry
    end
    -- the damage dealt (the fleets' combat stats: none kept in a save's fleet_stats [I]) and the hit
    -- ratio: "0%" with no shots
    -- each side's sums over its fleets (GetShortDescriptionForDamageOutput: hull, armor, shields as
    -- whole numbers; GetShortDescriptionForHitRatio: hits / (hits + misses + evaded), "0%" with no
    -- shots) [V 0x340af80, 0x34087e0], from the simulation's combat (engine.fleets.combat
    -- fleet_stats); a loaded save keeps none: 0
    local ok, engine = pcall(require, "engine.fleets.combat")
    local tally = ok and type(engine) == "table" and engine.fleet_stats or {}
    data.stats = {}
    for k = 1, 2 do
        local s = { hull = 0, armor = 0, shields = 0, hits = 0, shots = 0 }
        for _, f in ipairs(data.sides[k]) do
            local t = tally[f.id]
            if t then
                s.hull, s.armor, s.shields = s.hull + t.hull, s.armor + t.armor, s.shields + t.shields
                s.hits, s.shots = s.hits + t.hits, s.shots + t.hits + t.missed + t.evaded
            end
        end
        s.hit = s.shots > 0 and (string.format("%d", math.floor(100 * s.hits / s.shots)) .. "%") or "0%"
        data.stats[k] = s
    end
    return data
end

-- a sprite's frame size (as render.gui: the .gfx size, else the texture's over its frames)
local function sprite_size(ctx, name)
    local s = ctx.db.sprites[name]
    if s and s.sheet and ctx.db.sprites[s.sheet] then
        s = ctx.db.sprites[s.sheet]
    end
    if not s then
        return 0, 0
    end
    if s.size then
        return s.size[1], s.size[2]
    end
    local w, h = ctx.texture_size(s.texture)
    return (w or 0) / math.max(1, s.frames or 1), h or 0
end

local function format_name(ctx, n)
    if not n then
        return ""
    end
    if n.key == "%SIZE_AND_NAME%" then
        local names = require("render.names")
        return names.format(ctx.loc, n.vars[1].value) .. " " .. names.format(ctx.loc, n.vars[2].value)
    end
    return require("render.names").format(ctx.loc, n)
end

-- the lists' scrolling (the wheel over a list: 45 pixels a notch [I]), their places at the last
-- build; nothing while the view is not shown (combat.hide)
combat.scroll, combat.rects, combat.extent = { left = 0, right = 0 }, {}, {}

function combat.hide()
    combat.rects = {}
end

-- combat.wheel(notches, x, y) -> whether a list under the pointer scrolled
function combat.wheel(notches, x, y)
    for side, r in pairs(combat.rects) do
        if x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h then
            combat.scroll[side] = math.max(0, math.min(combat.extent[side] or 0, (combat.scroll[side] or 0) - notches * 45))
            return true
        end
    end
    return false
end

-- combat.build(ctx, data) -> items, report; ctx = { game_dir, db, screen, texture_size, loc }
function combat.build(ctx, data)
    local items = {}
    local report = { sprites = 0, texts = 0, missing_sprites = {}, skipped = {}, rects = {} }
    local function lay(window, opts)
        opts.texture_size, opts.loc = ctx.texture_size, ctx.loc
        local i, r = gui.layout(ctx.game_dir, ctx.db, FILE, window, ctx.screen, opts)
        return i, r
    end
    -- the bar: the left side's share of the hull points [V 0x2bf43ef]
    local l, r = data.hull[1], data.hull[2]
    local frame = 1
    if l + r > 0 then
        frame = math.max(1, math.min(100, math.floor(100 * l / (l + r) + 0.5)))
    end
    local bar_w = sprite_size(ctx, "GFX_fleet_combat_progressbar")
    -- the stats: only stat_value is set [V 0x2bf4870]
    local stat_text = {}
    for k, side in ipairs({ "left_stats", "right_stats" }) do
        local s = data.stats[k]
        local p = "/combat_view/" .. side
        stat_text[p .. "/outgoing_damage_hitpoints/stat_value"] = tostring(math.floor(s.hull))
        stat_text[p .. "/outgoing_damage_armor/stat_value"] = tostring(math.floor(s.armor))
        stat_text[p .. "/outgoing_damage_shields/stat_value"] = tostring(math.floor(s.shields))
        stat_text[p .. "/outgoing_hit_ratio/stat_value"] = s.hit
    end
    local wi, wr = lay("combat_view", {
        frames = { ["/combat_view/progress"] = frame },
        -- close (CCombatView::Hide: here the selection cleared, which shows it); focus_on
        -- (OnClickFocus: the camera to the combat [I: the selected fleet's system entered, the
        -- fleet followed]: designer.rs); the bar and the stats take no clicks
        actions = { ["/combat_view"] = "designer:noop", ["/combat_view/close"] = "close", ["/combat_view/focus_on"] = data.selected and ("designer:combat_focus:" .. data.selected) or nil },
        text = stat_text,
    })
    -- the bar, a progressbarType: its first texture to the progress, its second past it (the
    -- game's progress.shader cuts them; here the first is drawn over the second, squeezed to the
    -- progress [I])
    local sp = ctx.db.sprites["GFX_fleet_combat_progressbar"]
    for k, it in ipairs(wi) do
        if it.path == "/combat_view/progress" and sp and sp.texture2 then
            local red = {}
            for kk, vv in pairs(it) do
                red[kk] = vv
            end
            red.path, red.texture = it.path .. "/past", sp.texture2
            red.button = nil
            it.w = it.w * frame / 100
            table.insert(wi, k, red)
            break
        end
    end
    -- the glow at the boundary: its .gui x + frame x 0.01 x the bar's width [V]
    local glow = wr.rects["/combat_view/progress_center"]
    if glow then
        local dx = math.floor(frame * 0.01 * bar_w)
        for _, it in ipairs(wi) do
            if it.path == "/combat_view/progress_center" then
                it.x = it.x + dx
            end
        end
    end
    gui.merge(items, report, wi, wr)

    -- the lists: a fleet entry each, its ships under it (ships_list at y 140, 50 a ship), 6 apart
    -- [V: CCombatViewFleetEntry::UpdateEntry resizes the entry to its ships]
    local ring_w, ring_h = sprite_size(ctx, "GFX_ship_life_radial_progress")
    for k, side in ipairs({ "left", "right" }) do
        local list = wr.rects["/combat_view/" .. side .. "/list"]
        if list then
            combat.rects[side] = list
            local total = 0
            for _, f in ipairs(data.sides[k]) do
                total = total + 140 + 50 * #f.ships + 6
            end
            combat.extent[side] = math.max(0, total - list.h)
            combat.scroll[side] = math.min(combat.scroll[side] or 0, combat.extent[side])
            local y = list.y - (combat.scroll[side] or 0)
            local bottom = list.y + list.h
            local function add(i, rr)
                -- the list clips its entries [I: what reaches below it is dropped, a crossing
                -- background is cut]
                for _, it in ipairs(i) do
                    -- (scrolled: what starts above the list's top dropped, a background crossing
                    -- it cut)
                    if it.y < list.y then
                        if it.kind == "sprite" and it.border and it.y + it.h > list.y then
                            it.h, it.y = it.y + it.h - list.y, list.y
                        else
                            it = nil
                        end
                    end
                    if it and it.y < bottom then
                        if it.y + it.h > bottom then
                            if it.kind == "sprite" and it.border then
                                it.h = bottom - it.y
                                items[#items + 1] = it
                            end
                        else
                            items[#items + 1] = it
                        end
                    end
                end
                report.sprites = report.sprites + rr.sprites
                report.texts = report.texts + rr.texts
                for kk, v in pairs(rr.rects) do
                    report.rects[kk] = v
                end
            end
            for fi, f in ipairs(data.sides[k]) do
                if y >= bottom then
                    break
                end
                if y + 140 + 50 * #f.ships < list.y then
                    goto next_fleet
                end
                do
                local prefix = "/combat/" .. side .. "/" .. fi
                local fp = prefix .. "/combat_view_fleet_entry"
                -- the owner's flag: a country in contact its own (ApplyCountryToButton), else the
                -- sprite's own frame [I: the game's frame shows a "?"]
                local hide = { orders_hero_ship = true }
                if not f.own then
                    hide.emergency_ftl = true
                end
                local textures = nil
                local spec = f.flag and require("render.empire_preview").flag_texture(ctx, "GFX_empire_flag_32", f.flag)
                if spec then
                    textures = { [fp .. "/owner"] = spec }
                end
                local h = 140 + 50 * #f.ships
                local fi_items, fr = lay("combat_view_fleet_entry", {
                    prefix = prefix, parent = { x = list.x, y = y, w = 0, h = 0 },
                    sizes = { [fp] = { 256, h } },
                    hide = hide, textures = textures,
                    -- emergency_ftl, the player's fleets' (CCombatViewFleetEntry::EmergencyFTL),
                    -- enabled iff CanEmergencyFTL (engine.fleets.combat.emergency_ftl_days: 0)
                    disabled = f.eftl ~= 0 and { [fp .. "/emergency_ftl"] = true } or nil,
                    actions = f.eftl == 0 and { [fp .. "/emergency_ftl"] = "designer:combat_eftl:" .. f.id } or nil,
                    -- (its tooltip: EMERGENCY_FTL_DESC, else the days left)
                    tooltips = f.own and f.eftl and { [fp .. "/emergency_ftl"] = f.eftl == 0 and "EMERGENCY_FTL_DESC"
                        or (ctx.loc and ctx.loc.get("EMERGENCY_FTL_DAYS_LEFT"):gsub("%$DAYS|?Y?%$", tostring(f.eftl))) } or nil,
                    text = { [fp .. "/name"] = format_name(ctx, f.name) },
                })
                add(fi_items, fr)
                for si, s in ipairs(f.ships) do
                    local sp = prefix .. "/ships/" .. si
                    local path = sp .. "/combat_view_ship_entry"
                    local pct = function(v, m)
                        return math.max(1, math.floor((m > 0 and v / m or 0) * 100 + 0.5))
                    end
                    local shide = { destroyed = true, disengaged = true }
                    if s.armor_max <= 0 then
                        shide.armor = true
                    end
                    if s.shield_max <= 0 then
                        shide.shields = true
                    end
                    if s.hp <= 0 then
                        shide.destroyed, shide.ship_class, shide.hitpoints, shide.armor, shide.shields = nil, true, true, true, true
                    end
                    -- the rings: rotation 3.14159 about their position (41, -37): drawn over
                    -- (41 - w, 37 - h) .. (41, 37), turned half a turn (item.flip) [I: by the frame]
                    local ring_at = { 41 - ring_w, 37 - ring_h }
                    -- inspect: enabled iff CShip::CanInspectShip (contact) [V 0x2bfbefa], greyed
                    -- otherwise (buttonstate_onlydisable)
                    local si_items, sr = lay("combat_view_ship_entry", {
                        prefix = sp, parent = { x = list.x, y = y + 140 + 50 * (si - 1), w = 0, h = 0 },
                        hide = shide,
                        frames = {
                            [path .. "/hitpoints"] = pct(s.hp, s.hp_max),
                            [path .. "/armor"] = pct(s.armor, s.armor_max),
                            [path .. "/shields"] = pct(s.shield, s.shield_max),
                            [path .. "/ship_class"] = s.frame,
                        },
                        positions = { [path .. "/hitpoints"] = ring_at, [path .. "/armor"] = ring_at, [path .. "/shields"] = ring_at },
                        -- inspect (CCombatViewShipEntry::OnClickInspect 0x2bfb700: the ship view),
                        -- only after contact
                        actions = (s.known and s.id) and { [path .. "/inspect"] = "fleet:ship:" .. s.id } or nil,
                        disabled = not (s.known and s.id) and { [path .. "/inspect"] = true } or nil,
                        text = {
                            [path .. "/name"] = format_name(ctx, s.name),
                            [path .. "/size"] = s.class and ctx.loc and (ctx.loc.get("SHIP_CLASS"):gsub("%$CLASS%$", (format_name(ctx, s.class):gsub("%%", "%%%%")))) or "",
                        },
                    })
                    for _, it in ipairs(si_items) do
                        local p = it.path or ""
                        if p == path .. "/hitpoints" or p == path .. "/armor" or p == path .. "/shields" then
                            it.flip = true
                        end
                    end
                    add(si_items, sr)
                end
                end
                ::next_fleet::
                y = y + 140 + 50 * #f.ships + 6
            end
        end
    end
    return items, report
end

return combat
