-- engine/store/live.lua : the write-through marks (docs/data_layer.md, "Keeping the store
-- current"). The store holds a copy of what exploration reads (engine.store.bridge's mirror); a
-- module that changes one of those fields in the table world says which object it changed, and the
-- next pass brings only the marked objects into the store, instead of comparing every object every
-- day.
--
--   local live = require("engine.store.live")
--   live.touch("fleet", fid)          -- a store name or a scope kind (world.KINDS)
--
-- With the store off (STELLAR_STORE=off) a mark is a no-op. Marks are cheap (a table write), so a
-- writer marks every object it may have changed. A writer the marks miss is found by the check
-- (STELLAR_STORE_CHECK=1: every unmarked object compared with the table world each day, the stale
-- ones counted by store and key, then brought in).

-- Several copies may consume the marks: the bridge's mirror (L.dirty, L.take()) and the whole
-- world's copy for the engine on the workers (engine.store.full: L.consumer("full"),
-- L.take("full")). A mark goes to every consumer.
local L = { dirty = {}, marks = 0 }
local others = {}   -- consumer name -> its marks (store name -> { [id] = true } or true)

-- exploration over the store unless STELLAR_STORE=off (engine.exploration asks L.on)
local mode = os.getenv("STELLAR_STORE")
L.on = mode ~= "off"
L.check = L.on and os.getenv("STELLAR_STORE_CHECK") == "1"

-- the store a scope kind lives in (engine.world.KINDS), or the name itself
local KINDS = {
    country = "country", planet = "planet", fleet = "fleet", ship = "ships", system = "galactic_object",
    army = "army", starbase = "starbases", federation = "federation", megastructure = "megastructures",
}

local function mark(dirty, name, id)
    local d = dirty[name]
    if d == true then return end
    if not d then
        d = {}
        dirty[name] = d
    end
    d[id] = true
end

function L.touch(name, id)
    if not L.on or id == nil then return end
    name = KINDS[name] or name
    id = tonumber(id) or id
    mark(L.dirty, name, id)
    for _, dirty in pairs(others) do mark(dirty, name, id) end
    L.marks = L.marks + 1
end

-- every object of a store (a writer that changed many)
function L.touch_all(name)
    if not L.on then return end
    name = KINDS[name] or name
    L.dirty[name] = true
    for _, dirty in pairs(others) do dirty[name] = true end
end

-- a consumer of the marks besides the bridge (it gets every mark from now on)
function L.consumer(name)
    others[name] = others[name] or {}
end

-- a mark for one consumer only (engine.world's writers, for the whole world's copy)
function L.touch_for(consumer, name, id)
    local dirty = others[consumer]
    if not dirty or id == nil then return end
    mark(dirty, KINDS[name] or name, tonumber(id) or id)
end

-- the marks taken: the bridge's (no name, at each sync), or a named consumer's
function L.take(name)
    if name then
        local d = others[name] or {}
        others[name] = {}
        return d
    end
    local d = L.dirty
    L.dirty = {}
    return d
end

return L
