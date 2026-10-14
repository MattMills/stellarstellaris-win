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

local L = { dirty = {}, marks = 0 }

-- exploration over the store unless STELLAR_STORE=off (engine.exploration asks L.on)
local mode = os.getenv("STELLAR_STORE")
L.on = mode ~= "off"
L.check = L.on and os.getenv("STELLAR_STORE_CHECK") == "1"

-- the store a scope kind lives in (engine.world.KINDS), or the name itself
local KINDS = {
    country = "country", planet = "planet", fleet = "fleet", ship = "ships", system = "galactic_object",
    army = "army", starbase = "starbases", federation = "federation", megastructure = "megastructures",
}

function L.touch(name, id)
    if not L.on or id == nil then return end
    name = KINDS[name] or name
    local d = L.dirty[name]
    if not d then
        d = {}
        L.dirty[name] = d
    end
    d[tonumber(id) or id] = true
    L.marks = L.marks + 1
end

-- every object of a store (a writer that changed many)
function L.touch_all(name)
    if not L.on then return end
    L.dirty[KINDS[name] or name] = true
end

-- the marks taken (the bridge, at each sync)
function L.take()
    local d = L.dirty
    L.dirty = {}
    return d
end

return L
