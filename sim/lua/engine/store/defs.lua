-- engine/store/defs.lua : the definitions in the store (docs/data_layer.md, "Definitions"): every
-- folder of common/ that engine.defs read, as one tree under root 1:
--
--   "common/country_types" = { default = { needs_survey = yes ... } fallen_empire = { ... } }
--
-- The blocks are the definitions' own pdxscript blocks (engine.defs: the files in load order, a
-- later definition replacing an earlier one), the names sorted. Built once by the main thread after
-- engine.defs.load; read-only after it, by any Lua state (a worker reads a definition without
-- loading the game's files).
--
--   local D = require("engine.store.defs")
--   D.build(require("engine.defs"))      -- main thread
--   local b = D.get("common/country_types", "default")   -- a block id, or nil
--   S.txt(b, "needs_survey")

local S = require("engine.store.core")

local D = { seconds = 0 }

-- D.build(defs[, folders]) -> root: engine.defs's folders (all, or the given list) into the store
function D.build(defs, folders)
    S.attach()
    local t0 = RUST.clock()
    local tree = {}
    for _, folder in ipairs(folders or defs.order) do
        local d = defs.folder(folder)
        local names = {}
        for name, def in pairs(d) do
            if def.block then names[#names + 1] = name end
        end
        table.sort(names)
        local block = {}
        for i, name in ipairs(names) do
            block[i] = { key = { text = name }, op = "=", value = d[name].block }
        end
        tree[#tree + 1] = { key = { text = folder }, op = "=", value = block }
    end
    local root = S.build(tree)
    S.H.roots[1] = root
    D.seconds = RUST.clock() - t0
    return root
end

local function root()
    S.attach()
    return S.H.roots[1]
end

-- D.folder(folder) -> the folder's block id, or nil
function D.folder(folder)
    local r = root()
    return r ~= 0 and S.blk(r, folder) or nil
end

-- D.get(folder, name) -> the definition's block id, or nil
function D.get(folder, name)
    local f = D.folder(folder)
    return f and name and S.blk(f, name) or nil
end

-- D.each(folder) -> an array of { name, block id }, in name order
function D.each(folder)
    local out = {}
    local f = D.folder(folder)
    if not f then return out end
    local B, E = S.B, S.E
    local b = B[f]
    for i = b.first, b.first + b.count - 1 do
        local e = E[i]
        if e.op ~= 0 and e.kind == S.BLOCK then
            out[#out + 1] = { S.str(e.key), e.v.u.a }
        end
    end
    return out
end

return D
