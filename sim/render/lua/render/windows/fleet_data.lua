-- render/windows/fleetdata.lua : what the fleet windows show of a save (docs/windows/fleet.md),
-- read from the world (engine.world) in the runtime that has it, as a plain table that crosses
-- to the GUI's runtime as Lua source (fleetdata.serialize; render.windows.fleet lays it out).
--
--   local fd = require("render.windows.fleetdata")
--   local src = fd.serialize(fd.fleet(fid))          -- fleet_view: one fleet, its ships
--   local src = fd.serialize(fd.ship(sid))           -- ship_view: one ship
--   local src = fd.serialize(fd.manager())           -- fleet_manager_view: the player's fleets
--
-- Names are name blocks (render.galaxy.name_block: localised on the GUI's side by render.names);
-- what the game computes from its definitions (sizes, command limit, design names) is read here
-- from the save's own values where it has them, else left to the GUI's side.

local world = require("engine.world")
local galaxy = require("render.galaxy")

local fd = {}

local NONE = 4294967295

local function unquote(v)
    return v and (tostring(v):gsub('"', "")) or nil
end

local function num(v)
    return tonumber(v)
end

-- the player's country id (the save's `player = { { name country } }`)
function fd.player()
    local player = 0
    local pl = world.meta and world.meta.player
    if type(pl) == "table" then
        for _, b in ipairs(world.blocks(pl)) do
            player = tonumber(world.field(b, "country")) or player
        end
    end
    return player
end

-- whether `a` has communications with country `b` (relations_manager.relation communications)
local function communications(a, b)
    if a == b then
        return true
    end
    local c = world.object("country", a)
    local rm = c and world.field(c, "relations_manager")
    for _, r in ipairs(world.fields(rm or {}, "relation")) do
        if tonumber(world.field(r, "country")) == b then
            return world.field(r, "communications") == "yes"
        end
    end
    return false
end

-- a leader: name, class, level, portrait, the council position's type (its title), traits
function fd.leader(lid)
    local l = lid and lid ~= NONE and world.object("leaders", lid)
    if not l then
        return nil
    end
    local name = world.field(l, "name")
    local full = name and world.field(name, "full_names")
    local out = {
        id = lid,
        name = galaxy.name_block(full or name),
        class = unquote(world.field(l, "class")) or "",
        level = num(world.field(l, "level")) or 1,
        portrait = unquote(world.field(l, "portrait")) or "",
        species = num(world.field(l, "species")),
        gender = unquote(world.field(l, "gender")) or "",
        traits = {},
    }
    for _, t in ipairs(world.fields(l, "traits")) do
        out.traits[#out.traits + 1] = unquote(t)
    end
    local cl = world.field(l, "council_location")
    local pid = cl and num(world.field(cl, "id"))
    local pos = pid and pid ~= NONE and world.object("council_positions", pid)
    if pos and tonumber(world.field(pos, "leader")) == lid then
        out.council = unquote(world.field(pos, "type"))
    end
    return out
end

-- a ship: its name, design (name, size, the components), hull, armor, shields
function fd.ship(sid)
    local s = sid and world.object("ships", sid)
    if not s then
        return nil
    end
    local sdi = world.field(s, "ship_design_implementation")
    local did = sdi and num(world.field(sdi, "design"))
    local design = did and world.object("ship_design", did)
    local stage = design and world.blocks(world.field(design, "growth_stages"))[1]
    local out = {
        id = sid,
        name = galaxy.name_block(world.field(s, "name")),
        fleet = num(world.field(s, "fleet")),
        design = did,
        design_name = design and galaxy.name_block(world.field(design, "name")) or nil,
        auto_design = design and world.field(design, "auto_gen_design") == "yes" or false,
        size = stage and unquote(world.field(stage, "ship_size")) or "",
        culture = unquote(world.field(s, "graphical_culture")) or "",
        hp = num(world.field(s, "hitpoints")) or 0,
        hp_max = num(world.field(s, "max_hitpoints")) or 0,
        armor = num(world.field(s, "armor_hitpoints")) or 0,
        armor_max = num(world.field(s, "max_armor_hitpoints")) or 0,
        shield = num(world.field(s, "shield_hitpoints")) or 0,
        shield_max = num(world.field(s, "max_shield_hitpoints")) or 0,
        experience = num(world.field(s, "experience")) or 0,
        leader = num(world.field(s, "leader")),
        -- a newer design to upgrade to (ship_design_implementation.upgrade) [I]
        upgrade_to = sdi and num(world.field(sdi, "upgrade")),
        upgradable = (function()
            local u = sdi and num(world.field(sdi, "upgrade"))
            return u ~= nil and u ~= NONE and u ~= did
        end)(),
        components = {},
        required = {},
    }
    -- the design's components by slot (the ship's own sections name the weapons it carries)
    out.sections = {}
    if stage then
        for _, sec in ipairs(world.fields(stage, "section")) do
            out.sections[#out.sections + 1] = unquote(world.field(sec, "template")) or ""
            for _, c in ipairs(world.fields(sec, "component")) do
                out.components[#out.components + 1] = {
                    slot = unquote(world.field(c, "slot")) or "",
                    template = unquote(world.field(c, "template")) or "",
                    section = unquote(world.field(sec, "template")) or "",
                }
            end
        end
        for _, r in ipairs(world.fields(stage, "required_component")) do
            out.required[#out.required + 1] = unquote(r)
        end
    end
    return out
end

-- the fleet's orders as the game keeps them (movement_manager.state, the order queue)
local function orders(f)
    local mm = world.field(f, "movement_manager")
    local state = mm and tostring(world.field(mm, "state") or "move_idle") or "move_idle"
    local list = {}
    local fa = world.field(f, "fleet_actions")
    for _, e in ipairs(type(fa) == "table" and fa or {}) do
        if e.op and e.key then
            list[#list + 1] = e.key.text
        end
    end
    local queue = world.field(f, "orders")
    for _, e in ipairs(type(queue) == "table" and queue or {}) do
        if e.op and e.key then
            list[#list + 1] = e.key.text
        end
    end
    return state, list
end

-- fd.fleet(fid [, observer]) -> the fleet_view's data, as the observer (the player) sees it
function fd.fleet(fid, observer)
    local f = fid and world.object("fleet", fid)
    if not f then
        return nil
    end
    observer = observer or fd.player()
    local owner = world.fleet_owner and world.fleet_owner[fid] or -1
    local mm = world.field(f, "movement_manager")
    local origin = mm and num(world.path(mm, "coordinate", "origin")) or NONE
    local state, order_list = orders(f)
    local out = {
        id = fid,
        name = galaxy.name_block(world.field(f, "name")),
        owner = owner,
        observer = observer,
        player = owner == observer,
        communications = communications(observer, owner),
        class = unquote(world.field(f, "ship_class")) or "",
        station = world.path(f, "properties", "station") == "yes",
        civilian = world.path(f, "properties", "civilian") == "yes",
        mobile = world.path(f, "properties", "mobile") == "yes",
        military_power = num(world.field(f, "military_power")) or 0,
        hit_points = num(world.field(f, "hit_points")) or 0,
        template = num(world.field(f, "fleet_template")),
        -- the save writes a stance that is not the default (passive) [I]
        stance = unquote(world.field(f, "fleet_stance")) or "passive",
        ground_support_stance = unquote(world.field(f, "ground_support_stance")) or "selective",
        system = origin ~= NONE and origin or nil,
        state = state,
        orders = order_list,
        ships = {},
    }
    local country = owner >= 0 and world.object("country", owner)
    if country then
        out.owner_name = galaxy.name_block(world.field(country, "name"))
        out.adjective = galaxy.name_block(world.field(country, "adjective"))
    end
    for _, v in ipairs(world.list(world.field(f, "ships"))) do
        local s = fd.ship(tonumber(v))
        if s then
            out.ships[#out.ships + 1] = s
            if s.leader and s.leader ~= NONE and not out.leader then
                out.leader = fd.leader(s.leader)
            end
        end
    end
    -- the fleet's template: its size in command points ("(15)"), its ships by size ("3/3")
    local t = out.template and world.object("fleet_template", out.template)
    if t then
        out.template_fleet = num(world.field(t, "fleet"))
        out.template_size = num(world.field(t, "fleet_size"))
        out.template_counts = {}
        out.template_designs = {}
        local n = 0
        for _, d in ipairs(world.blocks(world.field(t, "fleet_template_design"))) do
            local did = num(world.path(d, "ship_design_implementation", "design")) or num(world.field(d, "design"))
            local entry = { design = did, count = num(world.field(d, "count")) or 0 }
            local design = did and world.object("ship_design", did)
            local stage = design and world.blocks(world.field(design, "growth_stages"))[1]
            entry.size = stage and unquote(world.field(stage, "ship_size")) or ""
            entry.name = design and galaxy.name_block(world.field(design, "name")) or nil
            entry.auto_design = design and world.field(design, "auto_gen_design") == "yes" or false
            out.template_designs[#out.template_designs + 1] = entry
            out.template_counts[entry.size] = (out.template_counts[entry.size] or 0) + entry.count
            n = n + entry.count
        end
        out.template_ships = n
    end
    for _, s in ipairs(out.ships) do
        out.upgradable = out.upgradable or s.upgradable
    end
    -- the country's command limit (CalcCommandLimit: COMMAND_LIMIT_BASE 50 and the country's
    -- modifiers; the modifiers are the simulation's: without them the base [I])
    out.command_limit = 50
    return out
end

-- fd.ship_view(sid [, observer]) -> the ship_view's data: the ship, its fleet's owner
function fd.ship_view(sid, observer)
    local s = fd.ship(sid)
    if not s then
        return nil
    end
    observer = observer or fd.player()
    s.owner = s.fleet and world.fleet_owner and world.fleet_owner[s.fleet] or -1
    s.player = s.owner == observer
    s.observer = observer
    local f = s.fleet and world.object("fleet", s.fleet)
    s.class = f and unquote(world.field(f, "ship_class")) or ""
    -- the fleet's leader (an admiral's skill counts in the ship's fire rate)
    for _, v in ipairs(f and world.list(world.field(f, "ships")) or {}) do
        local o = world.object("ships", tonumber(v))
        local lid = o and num(world.field(o, "leader"))
        if lid and lid ~= NONE then
            s.fleet_leader = fd.leader(lid)
            break
        end
    end
    return s
end

-- fd.manager([observer [, selected]]) -> the fleet manager's data: the player's fleets
-- (owned_fleets order) that are not stations nor civilian ships, the selected one (else the
-- first) in full, and the country's naval capacity
function fd.manager(observer, selected)
    observer = observer or fd.player()
    local pc = world.object("country", observer)
    local out = { observer = observer, fleets = {} }
    if not pc then
        return out
    end
    out.used_naval_capacity = num(world.field(pc, "used_naval_capacity")) or 0
    -- the councilors' traits' councilor_modifier (country_naval_cap_add, _mult): the naval
    -- capacity's terms the renderer counts [I: technologies, traditions, starbase modules not]
    out.councilor_traits = {}
    for _, pid in ipairs(world.list(world.path(pc, "government", "council_positions"))) do
        local pos = world.object("council_positions", tonumber(pid))
        local lid = pos and num(world.field(pos, "leader"))
        local l = lid and lid ~= NONE and world.object("leaders", lid)
        if l then
            for _, t in ipairs(world.fields(l, "traits")) do
                out.councilor_traits[#out.councilor_traits + 1] = unquote(t)
            end
        end
    end
    -- the country's templates in its order (fleet_template_manager), each with its fleet
    for _, tid in ipairs(world.list(world.path(pc, "fleet_template_manager", "fleet_template"))) do
        local t = world.object("fleet_template", tonumber(tid))
        local fid = t and num(world.field(t, "fleet"))
        local f = fid and world.object("fleet", fid)
        if f then
            local d = fd.fleet(fid, observer)
            d.template_id = tonumber(tid)
            out.fleets[#out.fleets + 1] = d
        end
    end
    -- the selected template (kept while it is listed), else the first
    local listed = false
    for _, f in ipairs(out.fleets) do
        listed = listed or f.id == selected
    end
    out.selected = listed and selected or (out.fleets[1] and out.fleets[1].id)
    return out
end

-- a table of strings, numbers, booleans and tables as Lua source (`return {...}`)
function fd.serialize(v)
    local out = {}
    local function put(x)
        local t = type(x)
        if t == "table" then
            out[#out + 1] = "{"
            local n = #x
            for i = 1, n do
                put(x[i])
                out[#out + 1] = ","
            end
            for k, y in pairs(x) do
                if not (type(k) == "number" and k >= 1 and k <= n and k % 1 == 0) then
                    out[#out + 1] = "["
                    put(k)
                    out[#out + 1] = "]="
                    put(y)
                    out[#out + 1] = ","
                end
            end
            out[#out + 1] = "}"
        elseif t == "string" then
            out[#out + 1] = string.format("%q", x)
        elseif t == "number" then
            out[#out + 1] = x ~= x and "0/0" or string.format("%.17g", x)
        elseif t == "boolean" then
            out[#out + 1] = tostring(x)
        else
            out[#out + 1] = "nil"
        end
    end
    put(v)
    return "return " .. table.concat(out)
end

return fd
