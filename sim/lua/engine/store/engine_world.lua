-- engine/store/engine_world.lua : engine.world as the shared store (engine.store.world), for the
-- main state with STELLAR_WORLD=store: the one world every state reads and writes in place, no copy
-- (docs/data_layer.md, "The world in the store").
--
-- A block of the world is a handle (a `pdx_handle`). A Lua table is a block a module is building:
-- engine.world's own functions (a second instance of the table world's module) read and write it
-- until a writer puts it into the world, which copies it into the store. A module may go on using
-- the table after that (it holds it): such a table stays the table of its store block, each write
-- through engine.world going to both, so what the module reads of it is what the store has. The
-- global type says "table" for a handle, since the engine's modules test a world value with
-- type(v) == "table" (a block, not a token); code that walks a handle as a Lua table reads it
-- through the handle's metatype (ipairs, pairs, #, h[i]: read-only views) and writes through the
-- API.
--
--   require("engine.store.engine_world").install()   -- before the engine's modules load

local M = {}

-- the functions whose first argument is a block
local READERS = { "field", "fields", "list", "blocks", "statements", "count", "key", "path", "token_entry", "entry" }
local WRITERS = { "set", "append", "insert", "append_value", "remove_value", "push", "reindex", "set_text",
    "set_key", "insert_value", "remove_at", "replace", "append_entry" }

function M.install()
    local SW = require("engine.store.world")
    if SW.installed then return SW end
    local rawtype = type
    local TW = dofile(package.searchpath("engine.world", package.path))
    local attached, handle, bid = SW.attached, SW.handle, SW.bid
    for _, name in ipairs(READERS) do
        local s, t = SW[name], TW[name]
        SW[name] = function(obj, ...)
            if rawtype(obj) == "table" then return t(obj, ...) end
            if s then return s(obj, ...) end
            return nil
        end
    end
    for _, name in ipairs(WRITERS) do
        local s, t = SW[name], TW[name]
        SW[name] = function(obj, ...)
            if rawtype(obj) == "table" then
                local a = attached[obj]
                if a then s(handle(a), ...) end
                return t(obj, ...)
            end
            return s(obj, ...)
        end
    end
    -- child: the store's child block and the table's, the one the table of the other
    do
        local s, t = SW.child, TW.child
        SW.child = function(obj, key)
            if rawtype(obj) == "table" then
                local a = attached[obj]
                local tc = t(obj, key)
                if a and attached[tc] == nil then attached[tc] = bid(s(handle(a), key)) end
                return tc
            end
            return s(obj, key)
        end
    end
    -- an entry given as the table's own (remove_entry, set_entry): the store's by its position
    local function position(obj, e)
        for j = 1, #obj do
            if obj[j] == e then return j end
        end
        return nil
    end
    do
        local s, t = SW.remove_entry, TW.remove_entry
        SW.remove_entry = function(obj, e)
            if rawtype(obj) == "table" then
                local a = attached[obj]
                local j = a and position(obj, e)
                if j then SW.remove_at(handle(a), j) end
                return t(obj, e)
            end
            return s(obj, e)
        end
        local s2, t2 = SW.set_entry, TW.set_entry
        SW.set_entry = function(obj, e, text)
            if rawtype(obj) == "table" then
                local a = attached[obj]
                local j = a and position(obj, e)
                if j then
                    local h = handle(a)
                    s2(h, h[j], text)
                end
                return t2(obj, e, text)
            end
            return s2(obj, e, text)
        end
    end
    SW.table_world = TW
    -- another save parsed into Lua tables (engine.diff), as the table world does it
    SW.parse_stores = TW.parse_stores
    SW.installed = true
    package.loaded["engine.world"] = SW
    local ffi = require("ffi")
    local istype, handle_t = ffi.istype, require("engine.store.core").handle_t
    _G.type = function(v)
        local t = rawtype(v)
        if t == "cdata" and istype(handle_t, v) then return "table" end
        return t
    end
    return SW
end

return M
