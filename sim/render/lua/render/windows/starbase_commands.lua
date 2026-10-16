-- render/windows/starbase_commands.lua : what the starbase windows' buttons do to the world, run in
-- the simulation's runtime between days (starbase.rs: the action `starbase:cmd:VERB:ARG...`,
-- Clock::query; then a snapshot published), as the game's commands do (docs/windows/starbase.md):
--
--   upgrade SB                     CStarbaseAbstractStarbaseTabController::Upgrade: the next level
--                                  (NConstruction::CreateAddBuildableCommand(country, starbase,
--                                  level) -> CAddBuildableToQueueCommand) in the build queue
--   module SB SLOT KEY             a side view's module (CStarbaseBuildableComponentEntry): in the slot
--   building SB SLOT KEY           a side view's building, the same
--   ship SB DESIGN                 a side view's design (CBuildableShipListItem::Build): a ship in the
--                                  shipyard queue, a defense platform in the build queue
--   cancel ITEM                    CConstructionQueueListItem::OnCancel: the item out of its queue,
--                                  its resources back (CRemoveBuildableFromQueueCommand [I])
--   priority ITEM up|down          OnPriorityUp / OnPriorityDown: the item a place earlier / later
--   disband_all SB                 CStarbaseDefensesTabController::DisbandAll: the platforms gone
--
-- Each returns a short text: "ok ..." when the world changed, "refused: why" when the game's IsValid
-- would refuse it too, "not done: why" for what the engine does not model. A missing object is a
-- refusal, never an error (the other windows keep drawing).

local world = require("engine.world")

local M = {}

local NO_ID = 4294967295
local ITEMS, QUEUES = "construction.item_mgr.items", "construction.queue_mgr.queues"

local function unq(v)
    return v ~= nil and (tostring(v):gsub('"', "")) or nil
end

local function defs()
    return require("engine.defs")
end

-- the player's country (world.meta.player = { { country = N } })
local function player()
    local pl = world.meta and world.meta.player
    local id = 0
    if type(pl) == "table" then
        for _, b in ipairs(world.blocks(pl)) do
            id = tonumber(world.field(b, "country")) or id
        end
    end
    return id
end

-- a starbase's block and owner (its station's fleet's)
local function starbase(sbid)
    sbid = tonumber(sbid)
    local s = sbid and world.object("starbases", sbid)
    if not s then
        return nil
    end
    local ship = world.object("ships", tonumber(world.field(s, "station")))
    local fleet = ship and tonumber(world.field(ship, "fleet"))
    return s, fleet and (world.fleet_owner or {})[fleet] or -1, fleet
end

-- the player's own starbase, else nil and why
local function own(sbid)
    local s, owner, fleet = starbase(sbid)
    if not s then
        return nil, "no starbase " .. tostring(sbid)
    end
    if owner ~= player() then
        return nil, "not the player's starbase"
    end
    return s, owner, fleet
end

local function queue_of(s, key)
    local q = tonumber(world.field(s, key))
    return q and q ~= NO_ID and world.object(QUEUES, q) and q or nil
end

local function items_of(q)
    local qb = world.object(QUEUES, q)
    local out = {}
    for _, v in ipairs(world.list(qb and world.field(qb, "items"))) do
        out[#out + 1] = tonumber(v)
    end
    return out, qb
end

local function cost_order()
    return require("engine.economy").resources or {}
end

-- a definition's `resources` table of `kind` (cost, upkeep): its template's values, their
-- triggers and mults in the country's scope, then the economy's mults (CEconomyUnit; the same
-- path as engine.ai.shipbuilding.ship_table)
local function def_table(country, d, kind, Mods)
    local e = require("engine.economy")
    e.init()
    local rb = d and defs().field(d.block, "resources")
    if not rb then
        return {}
    end
    local t = e.template(rb, d.file)
    local eval = require("simscript.eval")
    local ctx = eval.new_ctx(eval.S("country", country), eval.S("country", country), nil, "starbase")
    local base = {}
    for _, b in ipairs(t and t[kind] or {}) do
        local ok, holds = true, true
        if b.trigger then
            ok, holds = pcall(eval.trigger, b.trigger, ctx)
        end
        if ok and holds then
            local m = 1
            if b.mult then
                local okm, x = pcall(e.value_of, b.mult, ctx)
                m = okm and x or 1
            end
            for _, rv in ipairs(b.values) do
                local okv, v = pcall(e.value_of, rv[2], ctx)
                if okv and v then
                    base[rv[1]] = (base[rv[1]] or 0) + v * m
                end
            end
        end
    end
    return e.apply(t.category or "starbase_modules", kind, base, 1, Mods or {}, ctx)
end
M.def_table = def_table

local function issued(id, what)
    if id then
        return "ok " .. what .. " (item " .. tostring(id) .. ")"
    end
    return "refused: " .. what
end

local function add(o, what)
    local orders = require("engine.ai.economy.orders")
    if not orders.can_pay(o.country, o.cost) then
        return "refused: " .. what .. ": not enough resources"
    end
    o.cost_order = cost_order()
    return issued(orders.add(o), what)
end

local C = {}

-- upgrade SB: the next level, for its own, with the next size's prerequisites and no upgrade queued
function C.upgrade(sbid)
    local s, owner = own(sbid)
    if not s then return "refused: " .. owner end
    local level = unq(world.field(s, "level"))
    local ld = defs().get("common/starbase_levels", level)
    local nxt = ld and unq(defs().field(ld.block, "next_level"))
    local nd = nxt and defs().get("common/starbase_levels", nxt)
    if not nd then return "refused: no next level" end
    local q = queue_of(s, "build_queue")
    if not q then return "refused: no build queue" end
    for _, iid in ipairs(items_of(q)) do
        local item = world.object(ITEMS, iid)
        if item and world.field(item, "buildable_starbase_upgrade") then
            return "refused: an upgrade is queued"
        end
    end
    local size = unq(defs().field(nd.block, "ship_size"))
    local cost = require("engine.fleets.stations").size_table(owner, size, "cost")
    local sd = defs().get("common/ship_sizes", size)
    local bt = sd and tonumber(defs().field(sd.block, "base_buildtime")) or 360
    return add({ country = owner, queue = q, kind = "starbase_upgrade",
        fields = { { "starbase_upgrade", nxt, true }, { "starbase", tonumber(sbid) } },
        cost = cost, build_time = bt }, "upgrade to " .. nxt)
end

-- module / building SB SLOT KEY: the component in the slot (0-based, the save's)
local function component(kind, folder, sbid, slot, key)
    local s, owner = own(sbid)
    if not s then return "refused: " .. owner end
    local d = defs().get(folder, key)
    if not d then return "refused: no " .. kind .. " " .. tostring(key) end
    local q = queue_of(s, "build_queue")
    if not q then return "refused: no build queue" end
    slot = tonumber(slot)
    for _, iid in ipairs(items_of(q)) do
        local item = world.object(ITEMS, iid)
        local b = item and world.field(item, "buildable_starbase_" .. kind)
        if type(b) == "table" and tonumber(world.field(b, "slot")) == slot then
            return "refused: the slot has a " .. kind .. " queued"
        end
    end
    local Mods = require("engine.economy").modifiers("starbase", tonumber(sbid)) or {}
    local cost = def_table(owner, d, "cost", Mods)
    local days = tonumber(defs().field(d.block, "construction_days")) or 180
    return add({ country = owner, queue = q, kind = "starbase_" .. kind,
        fields = { { "starbase_" .. kind, key, true }, { "slot", slot }, { "starbase", tonumber(sbid) } },
        cost = cost, build_time = days }, kind .. " " .. key)
end

function C.module(sbid, slot, key)
    return component("module", "common/starbase_modules", sbid, slot, key)
end

function C.building(sbid, slot, key)
    return component("building", "common/starbase_buildings", sbid, slot, key)
end

-- ship SB DESIGN: in the shipyard queue (a defense platform's size: the build queue)
function C.ship(sbid, did)
    local s, owner = own(sbid)
    if not s then return "refused: " .. owner end
    did = tonumber(did)
    local info = did and require("engine.fleets.create").design_info(did)
    if not info then return "refused: no design " .. tostring(did) end
    local ct = info.size_block and defs().field(info.size_block, "construction_type")
    local key = (ct == "starbase_defenses") and "build_queue" or "shipyard_build_queue"
    local q = queue_of(s, key)
    if not q then return "refused: no queue for it" end
    local sb = require("engine.ai.shipbuilding")
    local Mods = require("engine.economy").modifiers("starbase", tonumber(sbid)) or {}
    local cost = sb.ship_table(owner, did, "cost", Mods)
    local sdi = {}
    world.append(sdi, "design", did)
    world.append(sdi, "upgrade", NO_ID)
    world.append(sdi, "growth_stage", 0)
    local ob = {}
    world.append(ob, "starbase", tonumber(sbid))
    return add({ country = owner, queue = q, kind = "ship",
        fields = { { "ship_design_implementation", sdi }, { "orbitable", ob } },
        cost = cost, build_time = sb.build_time(did, Mods) }, "ship " .. tostring(info.size))
end

-- the player's item and its queue
local function own_item(iid)
    iid = tonumber(iid)
    local item = iid and world.object(ITEMS, iid)
    if not item then return nil, "no item " .. tostring(iid) end
    if tonumber(world.field(item, "paying_country")) ~= player() then
        return nil, "not the player's item"
    end
    return item, tonumber(world.field(item, "queue"))
end

-- cancel ITEM: out of its queue and the store, its resources back to the paying country
function C.cancel(iid)
    local item, q = own_item(iid)
    if not item then return "refused: " .. q end
    iid = tonumber(iid)
    local _, qb = items_of(q)
    local list = qb and world.field(qb, "items")
    if type(list) == "table" then
        world.remove_value(list, iid)
    end
    local c = world.object("country", tonumber(world.field(item, "paying_country")))
    local stock = c and world.path(c, "modules", "standard_economy_module")
    stock = type(stock) == "table" and world.child(stock, "resources") or nil
    local res = world.field(item, "resources")
    if stock and type(res) == "table" then
        for _, e in ipairs(res) do
            if e.op and e.key and e.value.text then
                local now = tonumber(world.field(stock, e.key.text)) or 0
                world.set(stock, e.key.text, now + (tonumber(e.value.text) or 0))
            end
        end
    end
    world.remove(ITEMS, iid)
    return "ok cancel " .. tostring(iid)
end

-- priority ITEM up|down: a place earlier or later in its queue
function C.priority(iid, dir)
    local item, q = own_item(iid)
    if not item then return "refused: " .. q end
    iid = tonumber(iid)
    local ids, qb = items_of(q)
    local at
    for i, v in ipairs(ids) do
        if v == iid then at = i end
    end
    local to = at and (dir == "up" and at - 1 or at + 1)
    if not to or to < 1 or to > #ids then return "refused: no place there" end
    local list = world.field(qb, "items")
    world.remove_value(list, iid)
    world.insert_value(list, to, iid)
    return "ok priority " .. tostring(iid) .. " " .. dir
end

-- disband_all SB: the station fleet's ships other than the station (the platforms) gone
function C.disband_all(sbid)
    local s, owner, fid = own(sbid)
    if not s then return "refused: " .. owner end
    local station = tonumber(world.field(s, "station"))
    local f = fid and world.object("fleet", fid)
    if not f then return "refused: no station fleet" end
    local ships = world.field(f, "ships")
    local gone = 0
    for _, v in ipairs(world.list(ships)) do
        local sid = tonumber(v)
        if sid and sid ~= station then
            world.remove_value(ships, sid)
            world.remove("ships", sid)
            gone = gone + 1
        end
    end
    if gone == 0 then return "refused: no platforms" end
    return "ok disband_all (" .. gone .. " platforms)"
end

-- disband_ship SB SHIP: one platform gone (CStarbaseShipItem::Disband, after its dialog)
function C.disband_ship(sbid, sid)
    local s, owner, fid = own(sbid)
    if not s then return "refused: " .. owner end
    sid = tonumber(sid)
    local f = fid and world.object("fleet", fid)
    if not f or sid == tonumber(world.field(s, "station")) then return "refused: not a platform" end
    local ships = world.field(f, "ships")
    for _, v in ipairs(world.list(ships)) do
        if tonumber(v) == sid then
            world.remove_value(ships, sid)
            world.remove("ships", sid)
            return "ok disband_ship " .. sid
        end
    end
    return "refused: no such platform"
end

-- dismantle_component SB module|building SLOT (1-based): the slot emptied (CStarbase::SetModule /
-- SetBuilding with none, after STARBASE_DISMANTLE_COMPONENT_DIALOG) [I: no refund]
function C.dismantle_component(sbid, kind, slot)
    local s, owner = own(sbid)
    if not s then return "refused: " .. owner end
    local block = world.field(s, kind == "building" and "buildings" or "modules")
    slot = tonumber(slot)
    if type(block) ~= "table" or not slot then return "refused: no such slot" end
    for _, x in ipairs(block) do
        if x.op and x.key and tonumber(x.key.text) == slot - 1 then
            world.remove_entry(block, x)
            return "ok dismantle " .. kind .. " " .. slot
        end
    end
    return "refused: the slot is empty"
end

-- dismantle / downgrade SB (after their dialogs): the starbase destroyed or made an outpost again
-- (its station's design rebuilt: CStarbase::UpgradeStationDesign) are not modelled by the engine
function C.dismantle(sbid)
    return "not done: dismantling a starbase (the engine has no starbase removal)"
end

function C.downgrade(sbid)
    return "not done: downgrading a starbase (the station's design is not rebuilt by the engine)"
end

-- the megastructure window's: Upgrade / Complete (CCountryUpgradeMegaStructureCommand), Dismantle
-- (after MEGASTRUCTURE_DISMANTLE_DIALOG: CDismantleMegastructureCommand), Abort
-- (CAbortDismantleMegastructureCommand): the engine has no megastructure commands
function C.mega_upgrade(id)
    return "not done: a megastructure's upgrade (the engine has no megastructure construction)"
end

function C.mega_dismantle(id)
    return "not done: dismantling a megastructure (the engine does not model it)"
end

function C.mega_abort(id)
    return "not done: aborting a megastructure's dismantling (the engine does not model it)"
end

-- the waystation window's cloaking button (CStarbaseWaystationTabController::OnCloakClick): the
-- engine has no cloaking
function C.cloak(sbid)
    return "not done: cloaking (the engine does not model it)"
end

-- M.run(VERB, ARG, ...) (starbase.rs): the command, what it did or why not
function M.run(verb, ...)
    local f = C[verb]
    if not f then
        return "not done: " .. tostring(verb)
    end
    local ok, r = pcall(f, ...)
    if not ok then
        r = "error: " .. verb .. ": " .. tostring(r)
    end
    io.stderr:write("starbase command " .. verb .. " " .. table.concat({ ... }, " ") .. ": " .. tostring(r) .. "\n")
    return r
end

return M
